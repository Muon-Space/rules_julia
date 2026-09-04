"""Julia package rule for depot-shaped package layout."""

load("//julia/private:julia_common.bzl", "julia_common")
load("//julia/private:providers.bzl", "JuliaInfo")

JuliaPackageInfo = provider(
    doc = "Information about a Julia package in depot-shaped layout.",
    fields = {
        "name": "str: Julia package name",
        "uuid": "str: Package UUID",
        "slug": "str: Depot slug (5-char)",
        "git_tree_sha1": "str or None: Git tree SHA1 hash",
        "depot_rel_path": "str: Relative path in depot (packages/<Name>/<slug>)",
    },
)

def _julia_package_impl(ctx):
    """Implementation of julia_package rule.

    Like julia_library but also provides JuliaPackageInfo for depot-based precompilation.
    """
    srcs = depset(ctx.files.srcs)
    deps = ctx.attr.deps
    data = ctx.files.data

    transitive_srcs = depset(
        direct = ctx.files.srcs,
        transitive = [julia_common.collect_transitive_srcs(deps)],
    )

    include = julia_common.get_include(ctx)

    includes = depset(
        [include],
        transitive = [julia_common.collect_includes(deps)],
    )

    runfiles = ctx.runfiles(files = ctx.files.srcs + data)
    for dep in deps:
        if JuliaInfo in dep:
            runfiles = runfiles.merge(dep[JuliaInfo].runfiles)
        if DefaultInfo in dep:
            runfiles = runfiles.merge(dep[DefaultInfo].default_runfiles)

    # Compute depot-relative path
    depot_rel_path = "packages/{}/{}".format(ctx.attr.pkg_name, ctx.attr.slug)

    return [
        JuliaInfo(
            app_name = ctx.label.name,
            srcs = srcs,
            deps = depset(direct = deps),
            transitive_srcs = transitive_srcs,
            include = include,
            includes = includes,
            manifest_toml = None,
            project_toml = None,
            runfiles = runfiles,
        ),
        JuliaPackageInfo(
            name = ctx.attr.pkg_name,
            uuid = ctx.attr.uuid,
            slug = ctx.attr.slug,
            git_tree_sha1 = ctx.attr.git_tree_sha1 if ctx.attr.git_tree_sha1 else None,
            depot_rel_path = depot_rel_path,
        ),
        DefaultInfo(
            files = srcs,
            default_runfiles = runfiles,
        ),
    ]

julia_package = rule(
    doc = "A Julia package with depot metadata for relocatable precompilation.",
    implementation = _julia_package_impl,
    attrs = {
        "data": attr.label_list(
            doc = "Additional files needed at runtime",
            allow_files = True,
        ),
        "deps": attr.label_list(
            doc = "Other Julia packages this package depends on",
            providers = [JuliaInfo],
        ),
        "git_tree_sha1": attr.string(
            doc = "Git tree SHA1 hash of the package",
        ),
        "pkg_name": attr.string(
            doc = "Julia package name (e.g., 'StaticArrays')",
            mandatory = True,
        ),
        "slug": attr.string(
            doc = "Depot slug (5-char hash from Base.version_slug)",
            mandatory = True,
        ),
        "srcs": attr.label_list(
            doc = "Julia source files (.jl files)",
            allow_files = [".jl"],
            mandatory = True,
        ),
        "uuid": attr.string(
            doc = "Package UUID",
            mandatory = True,
        ),
    },
    provides = [JuliaInfo, JuliaPackageInfo],
)
