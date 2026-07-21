load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
load("//extras/build_templates:artifact.bzl", "ARTIFACT_BUILD_FILE")
load("//extras/build_templates:jll.bzl",
    "JLL_PKG_BUILD_FILE_HEADER",
    "JLL_PKG_BUILD_FILE_CONFIG_SETTING",
    "JLL_PKG_BUILD_FILE_ARTIFACT_SELECT",
    "JLL_PKG_BUILD_FILE_FOOTER",
)

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

def create_artifact_repos(module_ctx, hub_name, package_name, package_uuid, artifacts):
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

def generate_jll_build_file(package_name, deps, hub_name, repo_name, version, uuid, artifact_repos):
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