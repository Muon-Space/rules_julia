# rules_julia entrypoint

module RulesJuliaInit
import TOML
import Pkg
import UUIDs: UUID

# Check if debug logging is enabled
const DEBUG = haskey(ENV, "RULES_JULIA_DEBUG")

macro debug(msg)
    quote
        if DEBUG
            t = time()
            ms = round(Int, (t - floor(t)) * 1000)
            timestamp = Libc.strftime("%H:%M:%S", t) * "." * lpad(ms, 3, '0')
            println(stderr, "[", timestamp, "] ", $(esc(msg)))
        end
    end
end

# Function to parse command line arguments
function parse_args()
    # Validate arguments
    if length(ARGS) < 3
        println(stderr, "Usage: julia entrypoint.jl <config_file> <main.jl> -- [args...]")
        exit(1)
    end

    # Extract config and main script paths
    config_path = ARGS[1]
    main_path = ARGS[2]

    # Find `--` separator (must be after config and main paths)
    separator_index = -1
    for i = 3:length(ARGS)
        if ARGS[i] == "--"
            separator_index = i
            break
        end
    end

    if separator_index == -1
        println(stderr, "Missing -- separator after config and main script paths")
        exit(1)
    end

    # Extract extra args (after the separator)
    extra_args = ARGS[(separator_index+1):end]

    return config_path, main_path, extra_args
end

# Function to install runfiles from manifest to a directory
function install_runfiles_from_manifest(
    manifest_file::String,
    output_dir::String,
    runfiles_paths::Vector{String} = String[],
)
    """Install files from a manifest file into a directory structure.

    Args:
        manifest_file: Path to the manifest file (format: rlocation_path real_path per line)
        output_dir: Directory where files should be installed
        runfiles_paths: List of rlocation paths to install. If provided,
                       only files whose rlocation paths are in this list will be installed.
    """
    use_symlinks = !Sys.iswindows()

    # Create a set of runfiles paths for fast lookup
    runfiles_set = Set(runfiles_paths)

    # Create runfiles directory map from manifest, filtering by runfiles_paths
    runfiles_map = Dict{String,String}()
    repo_mapping_path = nothing
    total_entries = 0
    if isfile(manifest_file)
        open(manifest_file, "r") do f
            for line in eachline(f)
                line = strip(line)
                if isempty(line)
                    continue
                end
                # Parse "rlocation_path real_path" format
                parts = split(line, " ", limit = 2)
                if length(parts) == 2
                    total_entries += 1
                    rlocation = parts[1]
                    real_path = parts[2]

                    # Always capture _repo_mapping if present
                    if rlocation == "_repo_mapping"
                        repo_mapping_path = real_path
                    end

                    # Only add if it's in the runfiles_paths set
                    if rlocation in runfiles_set
                        runfiles_map[rlocation] = real_path
                    end
                end
            end
        end
    end

    @debug "Filtered manifest: $(length(runfiles_map)) of $(total_entries) entries match runfiles paths"

    # Always copy _repo_mapping if it was found in the manifest
    # This is needed for rlocation() to work correctly with repository mappings
    if repo_mapping_path !== nothing && isfile(repo_mapping_path)
        repo_mapping_dst = joinpath(output_dir, "_repo_mapping")
        mkpath(dirname(repo_mapping_dst))
        cp(repo_mapping_path, repo_mapping_dst; force = true)
        @debug "Copied _repo_mapping from manifest"
    end

    # Install files from manifest
    for (rlocation, real_path) in runfiles_map
        abs_src = normpath(real_path)
        abs_dest = normpath(joinpath(output_dir, rlocation))

        # Create parent directory
        mkpath(dirname(abs_dest))

        # Copy or symlink the file
        if isfile(abs_src)
            if use_symlinks
                try
                    symlink(abs_src, abs_dest)
                catch e
                    # If symlink fails (e.g., permissions), fall back to copy
                    @debug "Symlink failed, copying instead: $(e)"
                    cp(abs_src, abs_dest; force = true)
                end
            else
                # On Windows, always copy files
                cp(abs_src, abs_dest; force = true)
            end
        elseif isdir(abs_src)
            # For directories, we could recursively copy, but typically manifests
            # only contain files. Log a warning if we encounter a directory.
            @debug "Skipping directory in manifest: $(abs_src)"
        end
    end

    @debug "Installed $(length(runfiles_map)) files from manifest to $(output_dir)"
end

# Function to compute include paths and set up LOAD_PATH
function compute_includes(config_path)
    # Load config file in TOML format:
    # includes: Array of include paths for LOAD_PATH
    # runfiles: Array of all runfiles paths for manifest mode
    includes = String[]
    runfiles_paths = String[]
    manifest_toml = ""
    project_toml = ""

    if isfile(config_path)
        config = try
            TOML.parsefile(config_path)
        catch e
            println(stderr, "ERROR: Failed to parse config file '$(config_path)': $(e)")
            exit(1)
        end
        includes = get(config, "includes", String[])
        runfiles_paths = get(config, "runfiles", String[])
        manifest_toml = get(config, "manifest_toml", "")
        project_toml = get(config, "project_toml", "")
    end

    # Determine RUNFILES_DIR
    runfiles_dir = ""
    should_use_manifest = false

    if haskey(ENV, "RUNFILES_DIR")
        runfiles_dir = ENV["RUNFILES_DIR"]
        # Check if the directory actually exists
        if !isdir(runfiles_dir)
            @debug "RUNFILES_DIR set but directory does not exist: $(runfiles_dir)"
            # Fall through to manifest handling
            runfiles_dir = ""
            should_use_manifest = true
        else
            # Check if the runfiles directory has more than just a `MANIFEST` file and `_repo_mapping`.
            # If it only has these, consider it "empty" and fall through to manifest handling.
            entries = readdir(runfiles_dir)
            # Filter out MANIFEST and _repo_mapping
            other_entries = filter(e -> e != "MANIFEST" && e != "_repo_mapping", entries)
            if isempty(other_entries) &&
               ("MANIFEST" in entries || "_repo_mapping" in entries)
                @debug "RUNFILES_DIR set but directory only contains MANIFEST/_repo_mapping: $(runfiles_dir)"
                # If RUNFILES_MANIFEST_FILE is not set, set it to the MANIFEST file path
                if !haskey(ENV, "RUNFILES_MANIFEST_FILE") && "MANIFEST" in entries
                    manifest_path = joinpath(runfiles_dir, "MANIFEST")
                    if isfile(manifest_path)
                        ENV["RUNFILES_MANIFEST_FILE"] = manifest_path
                        @debug "Set RUNFILES_MANIFEST_FILE to: $(manifest_path)"
                    end
                end
                # Fall through to manifest handling
                runfiles_dir = ""
                should_use_manifest = true
            else
                # Directory exists and has some files, but check if the actual include paths exist
                # On Windows with manifest mode, the directory might exist but not have the actual source files
                has_actual_files = false
                for inc in includes
                    inc_path = normpath(joinpath(runfiles_dir, inc))
                    if isdir(inc_path)
                        has_actual_files = true
                        break
                    end
                end

                if !has_actual_files
                    @debug "RUNFILES_DIR exists but include paths are not present (manifest-only mode)"
                    # If RUNFILES_MANIFEST_FILE is not set, set it to the MANIFEST file path
                    if !haskey(ENV, "RUNFILES_MANIFEST_FILE") && "MANIFEST" in entries
                        manifest_path = joinpath(runfiles_dir, "MANIFEST")
                        if isfile(manifest_path)
                            ENV["RUNFILES_MANIFEST_FILE"] = manifest_path
                            @debug "Set RUNFILES_MANIFEST_FILE to: $(manifest_path)"
                        end
                    end
                    # Fall through to manifest handling
                    runfiles_dir = ""
                    should_use_manifest = true
                end
            end
        end
    else
        # RUNFILES_DIR not set, must use manifest
        should_use_manifest = true
    end

    # If no valid RUNFILES_DIR, try to create from manifest
    if isempty(runfiles_dir) && should_use_manifest && haskey(ENV, "RUNFILES_MANIFEST_FILE")
        manifest_file = ENV["RUNFILES_MANIFEST_FILE"]
        if isfile(manifest_file)
            # Create a temporary runfiles directory
            # Use TEST_TMPDIR if available (Bazel will clean it up), otherwise tempdir()
            temp_base = get(ENV, "TEST_TMPDIR", tempdir())
            runfiles_dir = mktempdir(temp_base; prefix = "runfiles_")

            @debug "Creating runfiles directory from manifest: $(runfiles_dir)"

            # Install files from manifest, filtering to runfiles_paths from config
            install_runfiles_from_manifest(manifest_file, runfiles_dir, runfiles_paths)

            ENV["RUNFILES_DIR"] = runfiles_dir
        else
            # Use manifest file location as base (fallback)
            runfiles_dir = dirname(manifest_file)
            ENV["RUNFILES_DIR"] = runfiles_dir
        end
    end

    # Error if we couldn't determine a valid runfiles location
    if isempty(runfiles_dir)
        if should_use_manifest
            println(
                stderr,
                "ERROR: RUNFILES_MANIFEST_FILE is not set or invalid, and RUNFILES_DIR is not usable.",
            )
        else
            println(
                stderr,
                "ERROR: Neither RUNFILES_DIR nor RUNFILES_MANIFEST_FILE are set or valid.",
            )
        end
        exit(1)
    end

    # Normalize path separators (important on Windows)
    runfiles_dir = normpath(runfiles_dir)

    # Make RUNFILES_DIR absolute
    if !isabspath(runfiles_dir)
        runfiles_dir = abspath(runfiles_dir)
    end
    ENV["RUNFILES_DIR"] = runfiles_dir

    # Build include paths and add them to LOAD_PATH
    # Normalize paths after joining to ensure consistent separators on Windows
    include_paths = [normpath(joinpath(runfiles_dir, inc)) for inc in includes]
    for inc_path in include_paths
        if !(inc_path in LOAD_PATH)
            push!(LOAD_PATH, inc_path)
        end
    end

    # Resolve manifest_toml and project_toml to absolute paths if provided
    manifest_toml_path = !isempty(manifest_toml) ? normpath(joinpath(runfiles_dir, manifest_toml)) : ""
    project_toml_path = !isempty(project_toml) ? normpath(joinpath(runfiles_dir, project_toml)) : ""

    return runfiles_dir, include_paths, runfiles_paths, manifest_toml_path, project_toml_path
end

"""
    setup_artifact_overrides(runfiles_dir, include_paths)

Scan runfiles for JLL artifact metadata and create Overrides.toml for artifact discovery.

JLL packages reference binary artifacts by their git-tree-sha1 content hash. Julia's
artifact system looks for these in the depot's artifacts/ directory. When running in
Bazel's sandbox, artifacts are downloaded by Bazel and placed in runfiles, but Julia
doesn't know to look there.

This function:
1. Scans runfiles for _jll_artifact_meta.json files (generated by Bazel for each artifact)
2. Extracts the git-tree-sha1 content hash and the actual path to the artifact
3. Writes an Overrides.toml to the depot that maps each hash to its runfiles location

The Overrides.toml format is:
```toml
[<git-tree-sha1>]
<artifact_name> = "<absolute_path_to_artifact>"
```

But for simpler artifacts we can just use:
```toml
<git-tree-sha1> = "<absolute_path_to_artifact>"
```
"""
function setup_artifact_overrides(runfiles_dir::String, include_paths::Vector{String})
    @debug "Setting up artifact overrides from runfiles"

    # Collect all artifact metadata files from runfiles
    artifact_overrides = Dict{String, String}()  # git_tree_sha1 => path

    # Walk through include paths looking for _jll_artifact_meta.json files
    # These are placed in artifact directories by our Bazel BUILD generation
    for inc_path in include_paths
        parent_dir = dirname(inc_path)
        search_dirs = [parent_dir, inc_path]

        for search_dir in search_dirs
            if !isdir(search_dir)
                continue
            end

            # Recursively find all _jll_artifact_meta.json files
            for (root, dirs, files) in walkdir(search_dir)
                for f in files
                    if f == "_jll_artifact_meta.json"
                        meta_path = joinpath(root, f)
                        try
                            meta_content = read(meta_path, String)
                            # Parse JSON manually (avoid dependency)
                            # Format: {"pkg_name":"...", "git_tree_sha1":"...", ...}
                            meta = parse_simple_json(meta_content)

                            git_tree_sha1 = get(meta, "git_tree_sha1", "")
                            if !isempty(git_tree_sha1)
                                # The artifact directory is the parent of the metadata file
                                artifact_path = dirname(meta_path)
                                artifact_overrides[git_tree_sha1] = artifact_path
                                @debug "Found artifact: $git_tree_sha1 => $artifact_path"
                            end
                        catch e
                            @warn "Failed to parse artifact metadata at $meta_path: $e"
                        end
                    end
                end
            end
        end
    end

    # Also check if there are artifact repos in runfiles directly
    # These would be at paths like: runfiles_dir/<repo>__artifact__<pkg>__<name>__<platform>/
    if isdir(runfiles_dir)
        for entry in readdir(runfiles_dir)
            if occursin("__artifact__", entry)
                artifact_dir = joinpath(runfiles_dir, entry)
                if isdir(artifact_dir)
                    meta_path = joinpath(artifact_dir, "_jll_artifact_meta.json")
                    if isfile(meta_path)
                        try
                            meta_content = read(meta_path, String)
                            meta = parse_simple_json(meta_content)
                            git_tree_sha1 = get(meta, "git_tree_sha1", "")
                            if !isempty(git_tree_sha1)
                                artifact_overrides[git_tree_sha1] = artifact_dir
                                @debug "Found artifact in runfiles root: $git_tree_sha1 => $artifact_dir"
                            end
                        catch e
                            @warn "Failed to parse artifact metadata at $meta_path: $e"
                        end
                    end
                end
            end
        end
    end

    if isempty(artifact_overrides)
        @warn "No JLL artifacts found in runfiles"
        return nothing
    end

    @debug "Found $(length(artifact_overrides)) JLL artifact overrides"

    # Write Overrides.toml to depot
    # Julia looks for this in the first writable depot at artifacts/Overrides.toml
    depot_path = first(DEPOT_PATH)
    artifacts_dir = joinpath(depot_path, "artifacts")
    mkpath(artifacts_dir)

    overrides_path = joinpath(artifacts_dir, "Overrides.toml")

    # Build Overrides.toml content
    # Format: <sha1> = "<path>"
    overrides_content = IOBuffer()
    println(overrides_content, "# Generated by rules_julia for Bazel-managed JLL artifacts")
    println(overrides_content, "# Do not edit manually - this file is regenerated on each run")
    println(overrides_content)

    for (sha1, path) in sort(collect(artifact_overrides))
        # Escape backslashes for Windows paths in TOML
        escaped_path = replace(path, "\\" => "\\\\")
        println(overrides_content, "\"$sha1\" = \"$escaped_path\"")
    end

    overrides_str = String(take!(overrides_content))

    # Write the file
    open(overrides_path, "w") do f
        write(f, overrides_str)
    end

    @debug "Wrote artifact overrides to $overrides_path"

    return overrides_path
end

"""
    parse_simple_json(content::String) -> Dict{String, String}

Simple JSON parser for flat objects with string values.
Avoids dependency on JSON.jl.
"""
function parse_simple_json(content::String)
    result = Dict{String, String}()

    # Remove whitespace and braces
    content = strip(content)
    if startswith(content, "{") && endswith(content, "}")
        content = content[2:end-1]
    end

    # Split by commas (being careful about quoted strings)
    # Simple approach: regex for "key":"value" pairs
    for m in eachmatch(r"\"([^\"]+)\"\s*:\s*\"([^\"]+)\"", content)
        key = m.captures[1]
        value = m.captures[2]
        result[key] = value
    end

    return result
end

"""
    setup_julia_environment(include_paths, runfiles_dir, manifest_toml_path, project_toml_path)

Create a Julia environment by splicing runfiles paths into an existing Manifest.toml.

This approach:
1. Uses explicit paths for Project.toml and Manifest.toml (passed from Bazel config)
2. Builds a name => runfiles_path mapping from all discovered packages
3. Parses the existing Manifest.toml which Pkg already generated with correct structure
4. Replaces `git-tree-sha1` entries with `path` entries for packages in runfiles
5. Copies Project.toml and writes modified Manifest.toml to a temp directory
6. Activates that environment

This ensures packages like Preferences.jl, JLLWrappers, etc. work correctly because
the Manifest retains all the structure Pkg expects (stdlibs, extensions, weakdeps).
"""
function setup_julia_environment(include_paths, runfiles_dir, manifest_toml_path::String, project_toml_path::String)
    # If no manifest_toml provided, nothing to do
    if isempty(manifest_toml_path) || !isfile(manifest_toml_path)
        @debug "No Manifest.toml path provided or file doesn't exist, skipping environment setup"
        return nothing
    end

    if isempty(project_toml_path) || !isfile(project_toml_path)
        @debug "No Project.toml path provided or file doesn't exist, skipping environment setup"
        return nothing
    end

    @debug "Setting up environment from manifest: $manifest_toml_path"
    @debug "Project.toml: $project_toml_path"

    # Build a name => runfiles_path mapping from all include paths
    packages = Dict{String, String}()

    for inc_path in include_paths
        project_toml_candidates = [
            joinpath(inc_path, "Project.toml"),           # inc_path = Repo.jl
            joinpath(dirname(inc_path), "Project.toml"),  # inc_path = Repo.jl/src
        ]

        for project_path in project_toml_candidates
            if !isfile(project_path)
                continue
            end
            try
                proj = TOML.parsefile(project_path)
                name = get(proj, "name", nothing)
                if name !== nothing
                    pkg_root = dirname(project_path)
                    packages[name] = pkg_root
                    @debug "Found package in runfiles: $name at $pkg_root"
                end
            catch e
                @debug "Failed to parse Project.toml at $project_path: $e"
            end
            break  # Found a valid Project.toml, don't check other candidates
        end
    end

    if isempty(packages)
        @debug "No packages found with Project.toml, skipping environment setup"
        return nothing
    end

    # Parse the existing Manifest.toml
    manifest = TOML.parsefile(manifest_toml_path)
    deps = get(manifest, "deps", nothing)
    if deps === nothing
        @debug "Manifest.toml has no deps section"
        return nothing
    end

    # Splice paths into manifest entries
    # For each package entry, if we have a runfiles path for it, replace git-tree-sha1 with path
    for (pkg_name, entries) in deps
        # entries is a Vector of Dicts (manifest format 2.0)
        if !(entries isa Vector)
            continue
        end
        for entry in entries
            if !(entry isa Dict)
                continue
            end

            # Check if this package is in our runfiles
            if haskey(packages, pkg_name)
                runfiles_path = packages[pkg_name]

                # Remove git-tree-sha1 if present (we're using path instead)
                if haskey(entry, "git-tree-sha1")
                    delete!(entry, "git-tree-sha1")
                end

                # Add or update path entry
                if haskey(entry, "path")
                    if entry["path"] == "." || entry["path"] == ".." || entry["path"] == "..." || !isabspath(entry["path"])
                        entry["path"] = runfiles_path
                    end
                else
                    entry["path"] = runfiles_path
                end

                @debug "Updated manifest entry for $pkg_name => $runfiles_path"
            end
            # Note: stdlibs and packages not in runfiles keep their original entries
        end
    end

    @debug "Processed $(length(packages)) package entries"

    # Create temp environment with modified Manifest
    temp_base = get(ENV, "TEST_TMPDIR", tempdir())
    env_dir = mktempdir(temp_base; prefix = "julia_env_")

    # Copy original Project.toml
    cp(project_toml_path, joinpath(env_dir, "Project.toml"))
    cp(joinpath(dirname(project_toml_path), "src"), joinpath(env_dir, "src"))

    # Copy LocalPreferences.toml if it exists (for MPI variant selection, etc.)
    # This ensures runtime platform augmentation selects the same artifact variant
    # that was downloaded at build time.
    local_prefs_path = joinpath(dirname(project_toml_path), "LocalPreferences.toml")
    if isfile(local_prefs_path)
        cp(local_prefs_path, joinpath(env_dir, "LocalPreferences.toml"))
        @debug "Copied LocalPreferences.toml to spliced environment"
    end
    # In this temp dir, we only have Project.toml and Manifest.toml; we don't have any
    # source files, and Pkg will attempt to check src/[Package].jl for the root package's primary
    # file. To prevent that, we create a synthetic Project.toml that lists the root package
    # as a dependency
    # proj_data = TOML.parsefile(project_toml_path)
    # deps = Dict{String,Any}(get(proj_data, "deps", Dict{String,Any}()))
    # root_name = get(proj_data, "name", nothing)
    # root_uuid = get(proj_data, "uuid", nothing)
    # if root_name !== nothing && root_uuid !== nothing
    #     deps[root_name] = root_uuid
    # end
    # synthetic = Dict{String,Any}("deps" => deps)
    # open(joinpath(env_dir, "Project.toml"), "w") do f
    #     TOML.print(f, synthetic)
    # end

    # Write modified Manifest.toml
    open(joinpath(env_dir, "Manifest.toml"), "w") do f
        TOML.print(f, manifest)
    end

    @debug "Created environment at $env_dir"

    # Activate this environment
    pushfirst!(LOAD_PATH, env_dir)

    @debug "Activated spliced environment, LOAD_PATH now has $(length(LOAD_PATH)) entries"

    return env_dir
end

function initialize()
    # Parse arguments
    @debug "Parsing command line arguments."
    config_path, main_path, extra_args = parse_args()

    # Compute includes
    @debug "Computing includes."
    runfiles_dir, include_paths, runfiles_paths, manifest_toml_path, project_toml_path = compute_includes(config_path)

    @debug "Runfiles dir: $(runfiles_dir)"
    @debug "JULIA_DEPOT_PATH: $(get(ENV, "JULIA_DEPOT_PATH", "<not set>"))"
    @debug "Manifest.toml: $(manifest_toml_path)"
    @debug "Project.toml: $(project_toml_path)"

    # Set up the synthetic Julia environment for proper Pkg metadata
    # This enables packages like Preferences.jl, JLLWrappers, etc. to work
    @debug "Setting up synthetic Julia environment."
    setup_julia_environment(include_paths, runfiles_dir, manifest_toml_path, project_toml_path)

    # Set up artifact overrides for JLL packages
    # This writes Overrides.toml so Julia can find Bazel-managed binary artifacts
    @debug "Setting up JLL artifact overrides."
    setup_artifact_overrides(runfiles_dir, include_paths)

    # Set up ARGS for the main script
    empty!(ARGS)
    append!(ARGS, extra_args)

    # Resolve main script path
    main_full_path = if isfile(main_path)
        abspath(main_path)
    elseif isabspath(main_path)
        main_path
    else
        candidate = joinpath(runfiles_dir, main_path)
        if isfile(candidate)
            abspath(candidate)
        else
            main_path
        end
    end

    # Debug output if requested
    @debug "Main: $(main_full_path)"
    @debug "Arguments: $(ARGS)"
    @debug "Include paths: $(include_paths)"
    @debug "LOAD_PATH: $(LOAD_PATH)"

    return main_full_path, include_paths
end

end

# Run initialization and get the main script path and include paths
RULES_JULIA_PROGRAM_FILE, _ = RulesJuliaInit.initialize()

# Set PROGRAM_FILE so scripts using the `if abspath(PROGRAM_FILE) == @__FILE__`
# guard will execute their main function when include()'d.
# Uses Core.eval to set it in Base directly, which works on Julia 1.10+
# (unlike `global PROGRAM_FILE = ...` which fails on 1.10).
RULES_JULIA_ORIGINAL_PROGRAM_FILE = PROGRAM_FILE
Core.eval(Base, :(PROGRAM_FILE = $RULES_JULIA_PROGRAM_FILE))

try
    include(RULES_JULIA_PROGRAM_FILE)
catch e
    println(stderr, "Error executing Julia script:")
    showerror(stderr, e, catch_backtrace())
    println(stderr)
    exit(1)
finally
    Core.eval(Base, :(PROGRAM_FILE = $RULES_JULIA_ORIGINAL_PROGRAM_FILE))
end

RulesJuliaInit.@debug "Done"
