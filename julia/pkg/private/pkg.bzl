"""Bazel tools for interfacing with Julia packages"""

load("@bazel_tools//tools/build_defs/repo:git.bzl", "git_repository")
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("//extras/build_templates:artifact.bzl", "ARTIFACT_BUILD_FILE")
load("//extras/build_templates:hub.bzl", "HUB_BUILD_FILE")
load("//extras/build_templates:pkg.bzl", "PKG_BUILD_FILE")
load("//extras/build_templates:jll.bzl",
    "JLL_PKG_BUILD_FILE_HEADER",
    "JLL_PKG_BUILD_FILE_CONFIG_SETTING",
    "JLL_PKG_BUILD_FILE_ARTIFACT_SELECT",
    "JLL_PKG_BUILD_FILE_FOOTER",
)

# Mapping from Julia platform keys to Bazel config_setting constraint values
# We'll leave windows and macos in here to at least have a chance of being able to build
# those
_PLATFORM_TO_CONSTRAINTS = {
    "x86_64-linux-gnu": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "x86_64-linux-musl": ["@platforms//os:linux", "@platforms//cpu:x86_64"],
    "aarch64-linux-gnu": ["@platforms//os:linux", "@platforms//cpu:aarch64"],
    "aarch64-linux-musl": ["@platforms//os:linux", "@platforms//cpu:aarch64"],
    "x86_64-apple-darwin": ["@platforms//os:macos", "@platforms//cpu:x86_64"],
    "aarch64-apple-darwin": ["@platforms//os:macos", "@platforms//cpu:aarch64"],
    "x86_64-w64-mingw32": ["@platforms//os:windows", "@platforms//cpu:x86_64"],
}

def _pkg_hub_impl(repository_ctx):
    repository_ctx.file("WORKSPACE.bazel", """workspace(name = "{}")""".format(
        repository_ctx.name,
    ))

    repository_ctx.file("BUILD.bazel", HUB_BUILD_FILE.format(
        name = repository_ctx.attr.hub_name,
        packages = json.encode_indent(repository_ctx.attr.packages, indent = " " * 4),
    ))

pkg_hub = repository_rule(
    implementation = _pkg_hub_impl,
    attrs = {
        "hub_name": attr.string(
            mandatory = True,
        ),
        "packages": attr.string_list(
            mandatory = True,
        ),
    },
)

def _read_lockfile_json(module_ctx, lockfile_path):
    """Read and parse the Manifest.bazel.json lockfile.

    Returns a dictionary mapping package names to package data including SHA256 hashes.
    """
    lockfile = module_ctx.path(lockfile_path)
    module_ctx.watch(lockfile)
    content = module_ctx.read(lockfile)

    # Parse JSON content
    packages = json.decode(content)

    return packages

def add_annotation_args(package_args, package_annotations):
    if "patches" in package_annotations:
        package_args["patches"] = package_annotations["patches"]
    if "patch_args" in package_annotations:
        package_args["patch_args"] = package_annotations["patch_args"]
    if "patch_tool" in package_annotations:
        package_args["patch_tool"] = package_annotations["patch_tool"]
    return package_args

def _sanitize_platform_key(platform_key):
    """Convert platform key to a valid Bazel target name."""
    return platform_key.replace("-", "_").replace(".", "_")

def _create_artifact_repos(module_ctx, hub_name, package_name, package_uuid, artifacts):
    """Create http_archive repos for each artifact.

    The artifacts dict now contains only the host platform's artifacts (pre-filtered
    by select_downloadable_artifacts() in the Julia manifest compiler).

    Args:
        module_ctx: The module context.
        hub_name: Name of the package hub.
        package_name: Name of the JLL package (e.g., "boost_jll").
        package_uuid: UUID of the JLL package.
        artifacts: Dict mapping artifact names to artifact info dicts (host platform only).

    Returns:
        Dict mapping artifact names to dicts of platform_key -> repo_name.
    """
    artifact_repos = {}

    for artifact_name, artifact_info in artifacts.items():
        # artifact_info is now a single dict for the host platform (not a list)
        platform_key = artifact_info.get("platform_key", "")
        git_tree_sha1 = artifact_info.get("git_tree_sha1", "")
        downloads = artifact_info.get("download", [])

        # Skip lazy artifacts (optional, not required for basic usage)
        if artifact_info.get("lazy", False):
            continue

        if not platform_key or not git_tree_sha1 or not downloads:
            continue

        # Check if this platform is supported by Bazel
        if platform_key not in _PLATFORM_TO_CONSTRAINTS:
            # Try to map to a supported platform
            continue

        # Get first download URL and sha256
        download_info = downloads[0]
        url = download_info.get("url", "")
        sha256 = download_info.get("sha256", "")

        if not url or not sha256:
            continue

        # Create repo name for this artifact
        sanitized_platform = _sanitize_platform_key(platform_key)
        artifact_repo_name = "{}__artifact__{}__{}__{}".format(
            hub_name,
            package_name,
            artifact_name,
            sanitized_platform,
        )

        # Build metadata JSON for runtime
        metadata = {
            "pkg_name": package_name,
            "pkg_uuid": package_uuid,
            "artifact_name": artifact_name,
            "git_tree_sha1": git_tree_sha1,
            "platform_key": platform_key,
        }
        metadata_json = json.encode(metadata)
        # Escape for shell embedding
        metadata_json_escaped = metadata_json.replace("\\", "\\\\").replace("'", "'\\''")

        build_file_content = ARTIFACT_BUILD_FILE.format(
            metadata_json = metadata_json_escaped,
        )

        http_archive(
            name = artifact_repo_name,
            urls = [url],
            sha256 = sha256,
            build_file_content = build_file_content,
        )

        # Store the repo name for this artifact's platform
        artifact_repos[artifact_name] = {platform_key: artifact_repo_name}

    return artifact_repos

def _generate_jll_build_file(package_name, deps, hub_name, repo_name, version, uuid, artifact_repos):
    """Generate BUILD file content for a JLL package with artifact selects.

    Args:
        package_name: Name of the JLL package.
        deps: List of dependency names.
        hub_name: Name of the package hub.
        repo_name: Repository name.
        version: Package version.
        uuid: Package UUID.
        artifact_repos: Dict mapping artifact names to dicts of platform_key -> repo_name.

    Returns:
        str: BUILD file content.
    """
    build_content = JLL_PKG_BUILD_FILE_HEADER.format(
        dependencies = deps,
    )

    # Collect all platforms that need config_settings
    all_platforms = set()
    for artifact_name, platform_repos in artifact_repos.items():
        for platform_key in platform_repos.keys():
            all_platforms.add(platform_key)

    # Generate config_settings for each platform
    for platform_key in sorted(all_platforms):
        if platform_key in _PLATFORM_TO_CONSTRAINTS:
            sanitized_name = _sanitize_platform_key(platform_key)
            constraints = _PLATFORM_TO_CONSTRAINTS[platform_key]
            build_content += JLL_PKG_BUILD_FILE_CONFIG_SETTING.format(
                name = sanitized_name,
                constraints = constraints,
            )

    # Generate artifact selects for each artifact
    artifact_data_refs = []
    for artifact_name, platform_repos in artifact_repos.items():
        select_cases = []
        for platform_key, artifact_repo_name in sorted(platform_repos.items()):
            sanitized_platform = _sanitize_platform_key(platform_key)
            select_cases.append('        ":{}": ["@{}//:artifact"],'.format(
                sanitized_platform,
                artifact_repo_name,
            ))

        # Add a default case that fails for unsupported platforms
        # Use an empty list as fallback - the artifact simply won't be available
        select_cases.append('        "//conditions:default": [],')

        build_content += JLL_PKG_BUILD_FILE_ARTIFACT_SELECT.format(
            artifact_name = artifact_name,
            select_cases = "\n".join(select_cases),
        )
        artifact_data_refs.append(":artifact_{}".format(artifact_name))

    # Format artifact data references for the julia_library
    if artifact_data_refs:
        artifact_data = " + [\n        " + ",\n        ".join(['"{}"'.format(ref) for ref in artifact_data_refs]) + ",\n    ]"

    else:
        artifact_data = ""

    build_content += JLL_PKG_BUILD_FILE_FOOTER.format(
        name = package_name,
        hub_name = hub_name,
        repo_name = repo_name,
        version = version,
        uuid = uuid,
        artifact_data = artifact_data,
    )

    return build_content

def install(*, module_ctx, attrs, annotations = {}):
    """Instantiate the pkg module for the given `install` tag_class attributes.

    Args:
        module_ctx (module_ctx): The current module context.
        attrs (struct): The attributes from the `install` tag class.
        annotations (dict): Optional dictionary mapping package names to annotation data.

    Returns:
        str: The name of the hub repository for the current tag_class.
    """

    # Read the JSON lockfile
    packages = _read_lockfile_json(module_ctx, attrs.lockfile)

    # Get all package names for dependency filtering
    all_package_names = list(packages.keys())

    # Create repositories for all packages
    for package_name, package_data in packages.items():
        # Extract package information
        pkg_type = package_data.get("type", "http")  # default to http for backwards compatibility
        version = package_data.get("version", "")
        uuid = package_data.get("uuid", "")
        all_deps = package_data.get("deps", [])
        artifacts = package_data.get("artifacts", {})

        # Validate required fields
        if not uuid:
            fail("Package {} missing UUID in lockfile".format(package_name))

        # Filter dependencies to only include packages in this lockfile
        deps = [dep for dep in all_deps if dep in all_package_names]

        repo_name = "{}__{}".format(attrs.name, package_name)

        # Get annotations for this package if any
        package_annotations = annotations.get(package_name)

        # Check if this is a JLL package with artifacts
        is_jll_with_artifacts = artifacts and package_name.endswith("_jll")

        # Create artifact repos for JLL packages
        artifact_repos = {}
        if is_jll_with_artifacts:
            artifact_repos = _create_artifact_repos(
                module_ctx,
                attrs.name,
                package_name,
                uuid,
                artifacts,
            )

        # Generate appropriate build file content
        if is_jll_with_artifacts and artifact_repos:
            build_file_content = _generate_jll_build_file(
                package_name,
                deps,
                attrs.name,
                repo_name,
                version,
                uuid,
                artifact_repos,
            )
        else:
            # Standard package build file
            build_file_content = PKG_BUILD_FILE.format(
                name = package_name,
                dependencies = deps,
                hub_name = attrs.name,
                repo_name = repo_name,
                version = version,
                uuid = uuid,
            )

        if pkg_type == "git":
            # Private package: use git_repository
            # This allows Bazel to use the host's git auth (SSH keys, credential helpers, etc.)
            remote = package_data.get("remote", "")
            tag = package_data.get("tag", "")

            if not remote:
                fail("Package {} has type 'git' but missing 'remote' field".format(package_name))
            if not tag:
                fail("Package {} has type 'git' but missing 'tag' field".format(package_name))

            git_repository_args = {
                "name": repo_name,
                "remote": remote,
                "tag": tag,
                "build_file_content": build_file_content,
            }

            # Apply patch-related attributes if annotations exist for this package
            if package_annotations:
                git_repository_args = add_annotation_args(
                    git_repository_args,
                    package_annotations
                )

            git_repository(**git_repository_args)

        elif pkg_type == "http":
            # Public package: use http_archive with integrity verification
            urls = package_data.get("urls", [])

            if not urls:
                fail("Package {} has type 'http' but missing 'urls' field".format(package_name))

            http_archive_args = {
                "name": repo_name,
                "urls": urls,
                "integrity": package_data.get("integrity", ""),
                "sha256": package_data.get("sha256", ""),
                "type": "tar.gz",
                "build_file_content": build_file_content,
            }

            # Apply patch-related attributes if annotations exist for this package
            if package_annotations:
                http_archive_args = add_annotation_args(
                    http_archive_args,
                    package_annotations
                )

            http_archive(**http_archive_args)

        else:
            fail("Package {} has unknown pkg_type: {}".format(package_name, pkg_type))

    # Create hub with all packages
    pkg_hub(
        name = attrs.name,
        hub_name = attrs.name,
        packages = list(packages.keys()),
    )

    return attrs.name
