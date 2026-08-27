"""
Utilities intended to be used in julia_common.bzl.
"""

load(":providers.bzl", "JuliaInfo")

def collect_manifest_toml(deps):
    """Collect manifest_toml and project_toml from first dependency that has them.

    Args:
        deps: List of dependency targets.

    Returns:
        tuple: (manifest_toml, project_toml) rlocation paths, or (None, None) if not found.
    """
    for dep in deps:
        if JuliaInfo in dep:
            info = dep[JuliaInfo]
            manifest = getattr(info, "manifest_toml", None)
            project = getattr(info, "project_toml", None)
            if manifest:
                return (manifest, project)
    return (None, None)
