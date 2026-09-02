"""
Julia Package Manifest Generator for Bazel

This script uses Julia's Pkg manager to resolve dependencies from Project.toml
and generate/update the Manifest.toml lockfile and Manifest.bazel.json with integrity values.
"""

using Pkg
using Pkg.Artifacts
using Pkg.BinaryPlatforms: HostPlatform
using SHA
using Base64
using Downloads
using TOML

include("./pkg_compiler_utils.jl")

function parse_args()
    """Parse command-line arguments from environment variables and command line flags."""
    args = Dict{String,Any}()

    # Required environment variables set by the Bazel rule
    required_vars =
        ["RULES_JULIA_PKG_COMPILER_PROJECT_TOML", "RULES_JULIA_PKG_COMPILER_MANIFEST_TOML"]

    for var in required_vars
        if !haskey(ENV, var)
            error("Environment variable $var is not set")
        end
        # Convert to absolute path
        key = lowercase(replace(var, "RULES_JULIA_PKG_COMPILER_" => ""))
        args[key] = abspath(ENV[var])
    end

    # Optional: Manifest.bazel.json path (defaults to Manifest.bazel.json next to Manifest.toml)
    if haskey(ENV, "RULES_JULIA_PKG_COMPILER_MANIFEST_BAZEL_JSON")
        args["manifest_bazel_json"] =
            abspath(ENV["RULES_JULIA_PKG_COMPILER_MANIFEST_BAZEL_JSON"])
    else
        # Derive from Manifest.toml path
        manifest_dir = dirname(args["manifest_toml"])
        args["manifest_bazel_json"] = joinpath(manifest_dir, "Manifest.bazel.json")
    end

    # Parse --add {NAME} flags from command line arguments
    packages_to_add = String[]
    i = 1
    while i <= length(ARGS)
        if ARGS[i] == "--add" && i + 1 <= length(ARGS)
            push!(packages_to_add, ARGS[i+1])
            i += 2
        else
            i += 1
        end
    end

    args["add"] = packages_to_add

    # Parse list of registries
    registries_env_var = "RULES_JULIA_PKG_COMPILER_REGISTRIES"
    if !haskey(ENV, registries_env_var)
        error("Environment variable $registries_env_var is not set")
    end
    registries = string.(split(ENV[registries_env_var], ","))
    args["registries"] = registries

    return args
end

function parse_manifest_toml(manifest_path::String)
    """Parse Manifest.toml and extract package information."""
    manifest_content = read(manifest_path, String)
    manifest = Pkg.Types.read_manifest(manifest_path)

    packages = Dict{String,Any}()

    for (uuid, pkg_entry) in manifest
        # Skip Julia stdlib packages (they don't have a tree hash)
        # Check if tree_hash field exists and is not nothing
        if !isdefined(pkg_entry, :tree_hash) || isnothing(pkg_entry.tree_hash)
            continue
        end

        name = pkg_entry.name
        tree_hash = string(pkg_entry.tree_hash)
        version = string(pkg_entry.version)
        uuid_str = string(uuid)

        # Get dependencies
        deps = String[]
        if isdefined(pkg_entry, :deps) && !isnothing(pkg_entry.deps)
            deps = collect(String, keys(pkg_entry.deps))
        end

        packages[name] = Dict(
            "uuid" => uuid_str,
            "version" => version,
            "git-tree-sha1" => tree_hash,
            "deps" => deps,
        )
    end

    return packages
end

function compute_integrity(url::String)
    """Download a package and compute its Bazel integrity value (sha256-<base64>)."""
    # Download to a temporary file
    temp_file = tempname()
    try
        Downloads.download(url, temp_file)
        # Compute SHA256 as bytes
        hash_bytes = open(SHA.sha256, temp_file)
        # Convert to base64 and prepend "sha256-"
        hash_base64 = base64encode(hash_bytes)
        return "sha256-" * hash_base64
    finally
        rm(temp_file, force = true)
    end
end

function escape_json_string(s::String)
    """Escape a string for JSON output."""
    result = IOBuffer()
    for c in s
        if c == '"'
            write(result, "\\\"")
        elseif c == '\\'
            write(result, "\\\\")
        elseif c == '\b'
            write(result, "\\b")
        elseif c == '\f'
            write(result, "\\f")
        elseif c == '\n'
            write(result, "\\n")
        elseif c == '\r'
            write(result, "\\r")
        elseif c == '\t'
            write(result, "\\t")
        elseif c < '\x20'
            write(result, "\\u$(string(Int(c), base=16, pad=4))")
        else
            write(result, c)
        end
    end
    return String(take!(result))
end

function write_json_array(io::IO, arr::AbstractVector, indent::AbstractString)
    """Write a JSON array."""
    if isempty(arr)
        write(io, "[]")
        return
    end

    write(io, "[\n")
    for (i, item) in enumerate(arr)
        write(io, indent, "  ")
        write_json_value(io, item, indent * "  ")
        if i < length(arr)
            write(io, ",")
        end
        write(io, "\n")
    end
    write(io, indent, "]")
end

function write_json_object(io::IO, obj::AbstractDict, indent::AbstractString = "")
    """Write a JSON object."""
    write(io, "{\n")

    keys_list = sort(collect(keys(obj)))  # Sort for deterministic output
    for (i, key) in enumerate(keys_list)
        value = obj[key]
        key_str = string(key)
        write(io, indent, "  \"", escape_json_string(key_str), "\": ")
        write_json_value(io, value, indent * "  ")
        if i < length(keys_list)
            write(io, ",")
        end
        write(io, "\n")
    end

    write(io, indent, "}")
end

function resolve_git_tag(remote, version)
    """
    Find the correct tag for the version we seek from `remote`, whether it has a prepended
    "v" or not.
    """
    v_tag = "v" * version
    bare_tag = version
    # Check which tag exists on the remote
    try
        output = read(`git ls-remote --tags $(remote) $(v_tag) $(bare_tag)`, String)
        if contains(output, "refs/tags/$(v_tag)")
            return v_tag
        elseif contains(output, "refs/tags/$(bare_tag)")
            return bare_tag
        end
    catch
        # Fall through to default
    end
    return v_tag
end

"""Generate Manifest.bazel.json with package metadata for Bazel.

For public packages (General registry): uses http_archive with integrity hash from pkg.julialang.org
For private packages: uses git_repository with version tag (auth handled by host's git)
For JLL packages: also extracts artifact download information for binary dependencies

Determining SHA integrity for packages from General works fine, but it's trickier with
private packages because of auth. I don't think we can assume everyone will have access to
a PAT (or can we?) so for private Julia packages we use the git_repository strategy instead
of http_archive. In any case, the tarballs we'll get from our private git repos aren't
guaranteed to be stable anyway, so relying on them as a source of SHA-stable archives is
unsafe.

Args:
    packages: Dict of package name => package data from parse_manifest_toml()
    output_path: Path to write the Manifest.bazel.json file
    private_registry_lookup: Dict of UUID => repo_url for packages from private registries
"""
function generate_bazel_lockfile(
    packages::Dict{String,Any},
    output_path::String,
    private_registry_lookup = Dict{String,String}(),
)

    lockfile = Dict{String,Any}()

    total = length(packages)
    current = 0

    pkg_items = collect(packages)
    lockfile_lock = ReentrantLock()

    Threads.@threads for (name, pkg_data) in pkg_items
        current += 1
        uuid = pkg_data["uuid"]
        tree_hash = pkg_data["git-tree-sha1"]
        version = pkg_data["version"]
        deps = pkg_data["deps"]

        # Determine package source based on whether it's from a private registry
        if haskey(private_registry_lookup, uuid)
            # Package is from a private registry - use git_repository
            # This allows Bazel to use the host's git auth (SSH keys, credential helpers, etc.)
            repo_url = private_registry_lookup[uuid]
            remote = normalize_git_url(repo_url)
            tag = resolve_git_tag(remote, version)

            println("[$current/$total] Private package: $name@$version (git)")
            flush(stdout)

            lock(lockfile_lock) do
                lockfile[name] = Dict{String,Any}(
                    "type" => "git",
                    "remote" => remote,
                    "tag" => tag,
                    "deps" => sort(deps),
                    "version" => version,
                    "uuid" => uuid,
                )
            end
        else
            # Package is from General registry - use http_archive with integrity
            url = "https://pkg.julialang.org/package/$uuid/$tree_hash"
            println("[$current/$total] Computing integrity for $name@$version... ")
            flush(stdout)

            integrity_value = ""
            try
                integrity_value = compute_integrity(url)
            catch e
                println(stderr, "Error downloading $name from $url: $e")
                rethrow(e)
            end

            pkg_entry = Dict{String,Any}(
                "type" => "http",
                "urls" => [url],
                "integrity" => integrity_value,
                "deps" => sort(deps),
                "version" => version,
                "uuid" => uuid,
            )

            # For JLL packages, extract artifact information
            if endswith(name, "_jll")
                pkg_source = find_package_source(name, uuid, tree_hash)
                if pkg_source !== nothing
                    artifacts = extract_jll_artifacts(pkg_source, name, uuid)
                    if artifacts !== nothing
                        pkg_entry["artifacts"] = artifacts
                    end
                else
                    @warn "Could not find source for JLL package $name"
                end
            end

            lock(lockfile_lock) do
                lockfile[name] = pkg_entry
            end
        end
    end

    # Write the lockfile manually (without JSON module)
    open(output_path, "w") do io
        write_json_object(io, lockfile)
        write(io, "\n")  # Add trailing newline
    end
end

function generate_manifest(
    project_toml_path::String,
    manifest_toml_path::String,
    manifest_bazel_json_path::String,
    registries,
    packages_to_add::Vector{String} = String[],
)
    """Generate Manifest.toml and Manifest.bazel.json from Project.toml using Pkg.

    This creates a temporary environment, copies the Project.toml,
    resolves dependencies, and generates both Manifest.toml and Manifest.bazel.json.

    Args:
        project_toml_path: Path to the Project.toml file
        manifest_toml_path: Path where Manifest.toml will be written
        manifest_bazel_json_path: Path where Manifest.bazel.json will be written
        registries: list of URLs of registries to add to the environment
        packages_to_add: Optional list of package names to add before resolving dependencies
    """
    println("=" ^ 70)
    println("Julia Package Manifest Generator")
    println("=" ^ 70)
    println("Project.toml: $project_toml_path")
    println("Manifest.toml: $manifest_toml_path")
    println("Manifest.bazel.json: $manifest_bazel_json_path")
    println()

    # Verify Project.toml exists
    if !isfile(project_toml_path)
        error("Project.toml not found: $project_toml_path")
    end

    # Create a temporary directory for the environment
    temp_env = mktempdir(prefix = "rjlpc_", cleanup = true)

    # Copy Project.toml to temp directory
    temp_project = joinpath(temp_env, "Project.toml")
    cp(project_toml_path, temp_project)

    # Copy LocalPreferences.toml if it exists (for MPI variant selection, etc.)
    local_prefs_path = joinpath(dirname(project_toml_path), "LocalPreferences.toml")
    if isfile(local_prefs_path)
        println("Copying LocalPreferences.toml to temp environment...")
        cp(local_prefs_path, joinpath(temp_env, "LocalPreferences.toml"))
    end

    println("Resolving dependencies...")

    # Activate the temporary environment
    Pkg.activate(temp_env)

    # Add additional registries using the host's available authentication methods
    # This may require user intervention in Coder environments to authenticate with the
    # Coder-supplied token for the first time
    if !isempty(registries)
        println("Adding additional registries...")
        # The General registry is auto-added only if there are no registries already
        # configured in the depot. We have registries to add, so make sure General makes It
        # in.
        Pkg.Registry.add("General")
    end
    try
        for reg in registries
            # If adding a registry takes more than 30 seconds, it's probably because git
            # is requesting a PAT or token location via CLI. We'll error out if this
            # takes too long so that we aren't stuck forever.
            t = @async Pkg.Registry.add(url = reg)
            ret = timedwait(() -> istaskdone(t), 30)
            ret == :timed_out ? error("Registry.add() timed out.") : nothing
        end
    catch err
        @error "Couldn't add user-supplied registries: $registries. \
            Is the host's git auth set up correctly?"
        rethrow(err)
    end

    # Ensure package registry is available and up-to-date
    # This is necessary when adding packages to a new environment
    if !isempty(packages_to_add)
        println("Updating package registry...")
        Pkg.update()
    end

    # Add any additional packages specified via --add flags
    if !isempty(packages_to_add)
        println("Adding packages: $(join(packages_to_add, ", "))")
        for pkg_name in packages_to_add
            Pkg.add(pkg_name)
        end
    end

    # Resolve and install dependencies
    # This creates a Manifest.toml with resolved versions
    # Note: instantiate() also downloads artifacts to the depot, but we need them
    # explicitly in Bazel so we extract their info separately
    Pkg.instantiate()
    Pkg.resolve()

    # Read the generated Manifest.toml
    temp_manifest = joinpath(temp_env, "Manifest.toml")
    if !isfile(temp_manifest)
        error("Failed to generate Manifest.toml")
    end

    # Build lookup of private registry packages (UUID => repo_url)
    # This must be done while the temp environment is still active and registries are available
    println()
    println("Building private registry lookup...")
    private_registry_lookup = build_private_registry_lookup()

    # Parse the manifest and generate Bazel lockfile
    packages = parse_manifest_toml(temp_manifest)

    println()
    println("Generating Bazel lockfile with integrity values...")
    println("(JLL packages will also have artifact download info extracted)")
    println()
    generate_bazel_lockfile(packages, manifest_bazel_json_path, private_registry_lookup)

    # Copy the generated Manifest.toml to the output location
    cp(temp_project, project_toml_path, force = true)
    cp(temp_manifest, manifest_toml_path, force = true)

    println()
    println("=" ^ 70)
    println("All files generated successfully!")
    println("=" ^ 70)
end

function main()
    # Change to workspace directory if running from Bazel
    if haskey(ENV, "BUILD_WORKSPACE_DIRECTORY") && isdir(ENV["BUILD_WORKSPACE_DIRECTORY"])
        cd(ENV["BUILD_WORKSPACE_DIRECTORY"])
    end

    # Parse arguments
    args = parse_args()
    project_toml = args["project_toml"]
    manifest_toml = args["manifest_toml"]
    manifest_bazel_json = args["manifest_bazel_json"]
    packages_to_add = args["add"]
    registries = args["registries"]

    # Generate Manifest.toml and Manifest.bazel.json
    generate_manifest(
        project_toml,
        manifest_toml,
        manifest_bazel_json,
        registries,
        packages_to_add,
    )
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
