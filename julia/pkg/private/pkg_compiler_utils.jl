"""
Build a lookup of UUID => repo_url for packages from non-General registries.

After Pkg.instantiate()/resolve(), this queries all reachable registries and
extracts the git repo URLs for packages that are NOT in the General registry.
These packages need to be downloaded from their git repos rather than from
pkg.julialang.org.

Returns:
    Dict{String, String}: Maps package UUID strings to their git repo URLs.
"""
function build_private_registry_lookup()

    lookup = Dict{String,String}()

    for reg in Pkg.Registry.reachable_registries()
        if reg.name == "General"
            continue
        end

        println("Scanning private registry: $(reg.name)")

        for (uuid, pkg_entry) in reg.pkgs
            try
                info = Pkg.Registry.registry_info(pkg_entry)
                if info.repo !== nothing && !isempty(info.repo)
                    lookup[string(uuid)] = info.repo
                end
            catch e
                # Some packages may not have registry_info available
                @warn "Could not get registry info for package $(pkg_entry.name): $e"
            end
        end
    end

    println("Found $(length(lookup)) packages from private registries")
    return lookup

end

"""Normalize a git repository URL to HTTPS format.
Args:
    repo_url: Git repository URL (may be SSH or HTTPS format)
Returns:
    String: HTTPS URL suitable for git_repository remote
"""
function normalize_git_url(repo_url::String)
    base_url = repo_url
    # Ensure it ends with .git
    if !endswith(base_url, ".git")
        base_url = base_url * ".git"
    end
    # Convert SSH format to HTTPS
    # SSH: muonspace@muonspace.ghe.com:Muon-Space/Pkg.jl.git
    # HTTPS: https://muonspace.ghe.com/Muon-Space/Pkg.jl.git
    http_url =
        replace(base_url, "muonspace@muonspace.ghe.com:" => "https://muonspace.ghe.com/")
    return http_url
end

write_json_value(io::IO, value, args...) = error("Unsupported JSON type: $(typeof(value))")
write_json_value(io::IO, value::AbstractString, args...) =
    write(io, "\"", escape_json_string(value), "\"")
write_json_value(io::IO, value::Bool, args...) = write(io, value ? "true" : "false")
write_json_value(io::IO, value::Number, args...) = write(io, string(value))
write_json_value(io::IO, value::AbstractVector, indent::AbstractString) =
    write_json_array(io, value, indent)
write_json_value(io::IO, value::AbstractDict, indent::AbstractString) =
    write_json_object(io, value, indent)
write_json_value(io::IO, ::Nothing, args...) = write(io, "null")

"""
Map Julia platform triplet components to a canonical key for Bazel.

Takes the platform components from Artifacts.toml and produces a key like
"x86_64-linux-gnu" or "aarch64-apple-darwin".
"""
function platform_to_key(entry)
    os = get(entry, "os", "")
    arch = get(entry, "arch", "")
    libc = get(entry, "libc", "")

    # Build platform key similar to Julia's platform triplets
    if os == "linux"
        libc_suffix = libc == "musl" ? "musl" : "gnu"
        return "$(arch)-linux-$(libc_suffix)"
    elseif os == "macos"
        return "$(arch)-apple-darwin"
    elseif os == "windows"
        return "$(arch)-w64-mingw32"
    elseif os == "freebsd"
        return "$(arch)-unknown-freebsd"
    else
        # Fallback: just concatenate available info
        return "$(arch)-$(os)-$(libc)"
    end
end

"""
Extract artifact information from a JLL package's Artifacts.toml.

Uses Julia's `select_downloadable_artifacts` to filter to artifacts that
match the host platform, then extracts download URLs and SHA256 hashes.

Args:
    pkg_source_path: Path to the installed package source directory
    pkg_name: Name of the package (for debugging)
    pkg_uuid: UUID of the package (enables platform augmentation, used by HDF5_jll)

Returns:
    Dict{String, Any}: Mapping of artifact names to their download info for the host platform
"""
function extract_jll_artifacts(pkg_source_path, pkg_name, pkg_uuid)

    artifacts_toml_path = joinpath(pkg_source_path, "Artifacts.toml")

    if !isfile(artifacts_toml_path)
        return nothing
    end

    println("Found Artifacts.toml in $pkg_name")

    # Get the host platform triplet for logging
    host_triplet = Base.BinaryPlatforms.host_triplet()
    println("Host platform: $host_triplet")

    # Use Julia's built-in artifact selection to get artifacts for the host platform
    # select_downloadable_artifacts returns a Dict{String, Any} where keys are artifact names
    # and values contain the download info for the matching platform
    # Passing pkg_uuid enables platform augmentation (e.g., HDF5_jll uses this to select MPI variant)
    host_platform = HostPlatform()
    selected_artifacts = Pkg.Artifacts.select_downloadable_artifacts(
        artifacts_toml_path;
        platform = host_platform,
        include_lazy = false,  # Skip lazy artifacts as they may not be needed at build time
        pkg_uuid = Base.UUID(pkg_uuid),  # Enables platform augmentation for correct variant selection
    )

    if isempty(selected_artifacts)
        println("No artifacts match host platform $host_triplet for $pkg_name")
        return nothing
    end

    result = Dict{String,Any}()

    for (artifact_name, artifact_info) in selected_artifacts

        # artifact_info is a Dict with keys like "git-tree-sha1", "download", etc.
        git_tree_sha1 = get(artifact_info, "git-tree-sha1", nothing)
        if git_tree_sha1 === nothing
            continue
        end

        # Use simplified platform key (first 3 parts of triplet) for Bazel constraints
        # e.g., "x86_64-linux-gnu-libgfortran5-cxx11-..." -> "x86_64-linux-gnu"
        # By this point, we've already collected the download URL, so we don't need to
        # keep this info around
        platform_key = join(split(host_triplet, "-")[1:3], "-")

        artifact_entry = Dict{String,Any}(
            "git_tree_sha1" => git_tree_sha1,
            "platform_key" => platform_key,
        )

        download_entries = get(artifact_info, "download", [])
        if !isempty(download_entries)
            downloads = []
            for dl in download_entries
                if !(dl isa Dict)
                    continue
                end
                dl_info = Dict{String,String}()
                if haskey(dl, "url")
                    dl_info["url"] = dl["url"]
                end
                if haskey(dl, "sha256")
                    dl_info["sha256"] = dl["sha256"]
                end
                if !isempty(dl_info)
                    push!(downloads, dl_info)
                end
            end
            if !isempty(downloads)
                artifact_entry["download"] = downloads
            end
        end

        result[artifact_name] = artifact_entry

    end

    if isempty(result)
        return nothing
    end

    println("Extracted $(length(result)) artifact(s) for platform $host_triplet")
    return result

end

"""
Find the source directory of an installed package.

After Pkg.instantiate(), packages are installed in the depot. This function
finds the actual source directory for a given package.

Args:
    pkg_uuid: UUID of the package
    pkg_name: Name of the package
    tree_hash: Git tree hash of the package version

Returns:
    String or Nothing: Path to package source directory, or nothing if not found
"""
function find_package_source(pkg_name::String, uuid, tree_hash::String)
    # Packages are installed in depot at packages/<name>/<tree_hash>/
    for depot in DEPOT_PATH
        ver_slug = version_slug(uuid, tree_hash)
        pkg_path = joinpath(depot, "packages", pkg_name, ver_slug)
        if isdir(pkg_path)
            return pkg_path
        end
    end
    return nothing
end

const slug_chars = String(['A':'Z'; 'a':'z'; '0':'9'])

function slug(x::UInt32, p::Int)
    y::UInt32 = x
    sprint(sizehint = p) do io
        n = length(slug_chars)
        for i = 1:p
            y, d = divrem(y, n)
            write(io, slug_chars[1+d])
        end
    end
end

"""
    version_slug(uuid, git_tree_sha1)::String

Get the 5 character slug used to differentiate package versions in the Julia depot.

Package code is stored at the path "DEPOT_PATH/package/slug". This code is taken from
Julia's loading.jl in Base.
"""
function version_slug(uuid, git_tree_sha1, p = 5)
    sha1_hash = hex2bytes(git_tree_sha1)
    return version_slug(Base.UUID(uuid), sha1_hash, p)
end
function version_slug(uuid::Base.UUID, sha1::Vector{UInt8}, p = 5)
    crc = Base._crc32c(sha1, Base._crc32c(uuid))
    return slug(crc, p)
end
