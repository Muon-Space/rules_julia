"""Julia providers"""

JuliaInfo = provider(
    doc = "Information about a Julia library or binary target.",
    fields = {
        "app_name": "str: The Julia project app name.",
        "deps": "depset[JuliaInfo]: of Julia dependencies",
        "include": "str: The include path of the current target.",
        "includes": "depset[str]: of include paths",
        "manifest_toml": "str or None: rlocation path to Manifest.toml for package resolution",
        "project_toml": "str or None: rlocation path to Project.toml for package resolution",
        "runfiles": "depset[File]: runfiles for this target",
        "srcs": "depset[File]: of Julia source files",
        "transitive_srcs": "depset[File]: of all Julia source files including transitive deps",
    },
)
