# Depot-shaped Architecture for Julia Precompilation

## Overview

Restructure `rules_julia` so that all Julia packages (both third-party from registries and first-party from the workspace) live in a single depot-shaped directory. This enables Julia's `@depot`-relative path tokenization, making precompiled `.ji` files relocatable and valid across build/runtime boundaries.

### Why this is needed

Julia's precompilation system embeds absolute source file paths in `.ji` cache files and rejects caches when those paths don't match at load time. In Bazel, build actions see files at execroot paths while runtime sees files at runfiles paths - different absolute locations for the same content. Julia's own solution to this is `@depot`-relative path tokenization: when packages live inside a depot at `packages/<Name>/<slug>/`, Julia stores paths relative to `@depot` rather than as absolute paths. A `.ji` file compiled in one depot location can be loaded from any other depot location. The current `rules_julia` architecture fights this by placing packages in separate Bazel repos with flat layouts and using absolute `path=` manifest entries, which Julia treats as non-relocatable.

### Architecture summary

- **Phase 1**: Restructure package fetching so all packages land in a single depot-shaped directory (`packages/<Name>/<slug>/` for sources, `artifacts/<git-tree-sha1>/` for JLL artifacts).
- **Phase 2**: Add per-package precompile actions that produce relocatable `.ji`/binary fragments, then merge them into a complete depot.
- **Phase 3**: Update the runtime wrapper and entrypoint to use the self-contained depot, eliminating manifest splicing and artifact overrides.

---

## Task Checklist

### Phase 1: Depot-shaped Package Layout
- [ ] Task 1.1: Extend `Manifest.bazel.json` with slug and git-tree-sha1
- [ ] Task 1.2: Create a single depot-shaped hub repository rule
- [ ] Task 1.2b: Parallel fetch optimization (deferrable)
- [ ] Task 1.3: Define `julia_package` target macro
- [ ] Task 1.4: Handle first-party packages in depot shape
- [ ] Task 1.5: Update module extension to use the new depot repo
- [ ] Task 1.6: Update `JuliaInfo` provider and `julia_library` to carry depot metadata

### Phase 2: Per-Package Precompilation
- [ ] Task 2.1: Define `julia_precompile` rule for a single package
- [ ] Task 2.2: Create the precompile Julia worker script
- [ ] Task 2.3: Wire precompile actions into the dep graph
- [ ] Task 2.4: Create `JULIA_CPU_TARGET` build setting
- [ ] Task 2.5: Fragment merge action
- [ ] Task 2.6: Precompile first-party packages

### Phase 3: Runtime Integration
- [ ] Task 3.1: Update `binary_wrapper.sh.tpl` for depot-based runtime
- [ ] Task 3.2: Simplify `entrypoint.jl` for depot mode
- [ ] Task 3.3: Update `_create_julia_binary_impl` to wire everything together
- [ ] Task 3.4: Add `{cpu_target}` template substitution

### Phase 4: Cleanup and Migration
- [ ] Task 4.1: Deprecate old N-repo package layout
- [ ] Task 4.2: Remove `entrypoint_utils.jl` manifest splicing
- [ ] Task 4.3: Update documentation
- [ ] Task 4.4: Add integration tests

---

## Phase 1: Depot-shaped Package Layout

**Goal**: All packages end up at `packages/<Name>/<slug>/` in a single depot directory, instead of in separate Bazel repos.

---

### Task 1.1: Extend `Manifest.bazel.json` with slug and git-tree-sha1

**File**: `julia/pkg/private/pkg_compiler.jl`

**What to do**:
- After resolving packages, for each entry with a `tree_hash`, compute `slug = Base.version_slug(UUID(uuid), SHA1(tree_hash))`.
- For each entry, also extract the raw `git-tree-sha1` string from the manifest (already available via `pkg_entry.tree_hash`).
- Write both `slug` and `git_tree_sha1` into the `Manifest.bazel.json` output.

**Output**: `Manifest.bazel.json` entries gain two new fields:
```json
{
  "StaticArrays": {
    "slug": "k7bbZ",
    "git_tree_sha1": "e206cf4850fd7ac4255ffd2b98922f563e18ac53",
    ...existing fields...
  }
}
```

**Test**: Run `bazel run //:pkg_update` on a test project, verify the new fields appear in `Manifest.bazel.json`.

---

### Task 1.2: Create a single depot-shaped hub repository rule

**New file**: `julia/pkg/private/depot_repo.bzl`

**What to do**:
- Write a new repository rule `julia_depot_repo` that replaces the current pattern of N separate `http_archive`/`git_repository` calls + one `pkg_hub`.
- The rule:
  1. Reads the `Manifest.bazel.json` lockfile.
  2. For each package, downloads the tarball (using `repository_ctx.download_and_extract`) into `packages/<Name>/<slug>/`.
  3. For JLL packages with artifacts, downloads artifacts into `artifacts/<git-tree-sha1>/`.
  4. Generates a `BUILD.bazel` at the repo root that:
     - Exports a `filegroup` for each package at `packages/<Name>/<slug>/`.
     - Exports a `filegroup` for each artifact at `artifacts/<git-tree-sha1>/`.
     - Exports an aggregate `filegroup` named after the hub.
  5. Writes the `Manifest.toml` (unchanged) into the repo root for later use by precompilation.

**Key detail**: The download loop is sequential in this task. Task 1.2b (below) optimizes it.

**Inputs**: `Manifest.bazel.json`, annotations (patches).

**Test**: Replace `@precompile_deps` with the new rule in the precompile test. Verify packages appear at `packages/<Name>/<slug>/` in the external repo.

---

### Task 1.2b (deferrable): Parallel fetch optimization

**File**: `julia/pkg/private/depot_repo.bzl` (modifies Task 1.2)

**What to do**:
- Change all `repository_ctx.download_and_extract` calls to use `block=False`.
- Collect all download futures, then call `.wait()` on each at the end.
- This parallelizes network I/O while keeping the repo rule a single unit.

**Test**: Time a clean fetch and verify it's faster than sequential.

---

### Task 1.3: Define `julia_package` target macro

**New file**: `julia/pkg/private/julia_package.bzl`

**What to do**:
- Define a `julia_package` rule (or macro wrapping `julia_library`) that:
  - Takes `name`, `uuid`, `slug`, `deps` (list of other `julia_package` labels), `srcs`, `data`.
  - Propagates a new `JuliaPackageInfo` provider containing `uuid`, `slug`, `name`, `depot_path` (the `packages/<Name>/<slug>/` relative path).
  - The generated BUILD in the depot repo (Task 1.2) uses this rule for each package.

**Provider**:
```python
JuliaPackageInfo = provider(fields = {
    "name": "str: Julia package name",
    "uuid": "str: Package UUID",
    "slug": "str: Depot slug (5-char)",
    "git_tree_sha1": "str or None",
    "depot_rel_path": "str: packages/<Name>/<slug>",
})
```

**Test**: Build a `julia_package` target, inspect the provider.

---

### Task 1.4: Handle first-party (workspace) packages in depot shape

**File**: `julia/private/julia_common.bzl` (or new file `julia/private/depot_fragment.bzl`)

**What to do**:
- When a `julia_binary`/`julia_test` has deps that include first-party `julia_library` targets (which don't have a slug), create a build action that:
  1. Computes a deterministic slug. Since `Base.version_slug(uuid, sha1)` uses `CRC32c(uuid_bytes) XOR CRC32c(sha1_bytes)` and we need a synthetic SHA1 for packages without a git-tree-sha1, we derive one by hashing the uuid + target label. The simplest approach: require first-party packages that participate in precompilation to have a `Project.toml` with a UUID, and compute the slug in the precompile action's Julia script rather than in Starlark.
  2. Copies (via `cp -RL`) the first-party source into `packages/<Name>/<slug>/` within a declared directory.
  3. Normalizes mtimes to 1 (for cache determinism and because Julia special-cases mtime=1 as "never stale").

**Test**: A `julia_test` with a first-party `julia_library` dep produces a depot fragment with the library at `packages/<Name>/<slug>/`.

---

### Task 1.5: Update module extension to use the new depot repo

**File**: `julia/pkg/extensions.bzl`

**What to do**:
- Change the `_pkg_impl` function to call the new `julia_depot_repo` (from Task 1.2) instead of the current loop of `http_archive` + `pkg_hub`.
- Keep the `pkg_annotation` tag class working (patches need to be applied after extraction into `packages/<Name>/<slug>/`).
- Preserve the public API: `use_repo(deps, "my_deps")` should still work; the repo just has a different internal layout.

**Test**: Existing tests that depend on `@rules_julia_sac` and `@rules_julia_fmt` still build.

---

### Task 1.6: Update `JuliaInfo` provider and `julia_library` to carry depot metadata

**File**: `julia/private/providers.bzl`, `julia/private/julia.bzl`

**What to do**:
- Add optional fields to `JuliaInfo`: `uuid`, `slug`, `depot_rel_path`.
- For packages coming from the depot repo, these are populated. For plain `julia_library` targets without depot metadata, they're `None`.
- The existing `includes`, `srcs`, `runfiles` fields remain and continue working for non-precompiled builds.

**Test**: Build a `julia_library` that deps on a depot package. Inspect the provider chain.

---

## Phase 2: Per-Package Precompilation

**Goal**: Each package gets a precompile action producing a depot fragment with `compiled/v1.X/<Name>/`. Fragments are merged into one depot tree artifact.

---

### Task 2.1: Define `julia_precompile` rule for a single package

**New file**: `julia/private/precompile.bzl` (rewrite of current stub)

**What to do**:
- Define a rule `julia_precompile` that takes:
  - `package`: label of a `julia_package` target (provides `JuliaPackageInfo`).
  - `deps`: labels of `julia_precompile` targets for dependencies (provides the compiled fragments).
  - Implicit: Julia toolchain.
- The rule's implementation:
  1. `ctx.actions.declare_directory` for the output depot fragment.
  2. Assembles a depot directory containing:
     - `packages/<Name>/<slug>/` - `cp -RL` from the source package (input).
     - `packages/<DepName>/<DepSlug>/` - `cp -RL` from each dep's package source.
     - `compiled/v1.X/<DepName>/` - copied from each dep's precompiled fragment.
  3. Runs Julia to precompile just this one package:
     ```
     JULIA_DEPOT_PATH=$DEPOT_DIR
     JULIA_PKG_OFFLINE=true
     julia --compiled-modules=yes -e 'import <PackageName>'
     ```
  4. Asserts `Base.isrelocatable(pkg)` in the Julia script - fails the build if not relocatable.
  5. Normalizes mtimes to 1 on outputs.
- Output: tree artifact containing `compiled/v1.X/<Name>/` (the `.ji` and `.so` files).

**Key env vars**:
- `JULIA_DEPOT_PATH=$DEPOT` (no trailing separator, so default depots can't leak in)
- `JULIA_PKG_OFFLINE=true`
- Empty `JULIA_PKG_SERVER`
- `JULIA_CPU_TARGET` from a string flag (Task 2.4)

**Test**: Precompile `StaticArraysCore` (no deps). Verify `compiled/v1.12/StaticArraysCore/` exists in the output.

---

### Task 2.2: Create the precompile Julia worker script

**File**: `julia/private/precompile_worker.jl` (rewrite)

**What to do**:
- The script receives as arguments:
  1. Path to the assembled depot directory.
  2. Package name to precompile.
  3. Package UUID.
- It:
  1. Sets `DEPOT_PATH` to just the provided depot dir.
  2. Calls `import <PackageName>` to trigger precompilation.
  3. After import, asserts `Base.isrelocatable(Base.identify_package("<PackageName>"))`.
  4. On failure, prints diagnostic info and exits non-zero.

**Test**: Run manually against a depot fragment with `StaticArraysCore`.

---

### Task 2.3: Wire precompile actions into the dep graph

**File**: `julia/pkg/private/depot_repo.bzl` or generated BUILD files

**What to do**:
- In the depot repo's generated `BUILD.bazel`, for each `julia_package`, also generate a `julia_precompile` target:
  ```python
  julia_precompile(
      name = "StaticArrays_precompile",
      package = ":StaticArrays",
      deps = [
          ":PrecompileTools_precompile",
          ":StaticArraysCore_precompile",
          ":Preferences_precompile",
      ],
  )
  ```
- The dep edges come directly from the manifest's `deps` field.

**Test**: `bazel build @my_deps//:StaticArrays_precompile` succeeds and produces a tree artifact.

---

### Task 2.4: Create `JULIA_CPU_TARGET` build setting

**New file**: `julia/settings/cpu_target.bzl` (or extend `julia/settings/settings.bzl`)

**What to do**:
- Define a `string_flag` for `JULIA_CPU_TARGET` with a default of `"generic"`.
- All precompile actions read this flag and pass it as `--cpu-target` to Julia and as env var.
- This makes CPU target part of the Bazel configuration, so remote execution workers and local builds with different CPUs don't share incompatible native-code caches.

**Test**: Build with `--//julia/settings:cpu_target=native`, verify the flag flows through to the precompile action.

---

### Task 2.5: Fragment merge action

**File**: `julia/private/precompile.bzl` (add function) or `julia/private/depot_merge.bzl`

**What to do**:
- Define a rule (or function called from `_create_julia_binary_impl`) that:
  1. Takes all precompiled fragments (from the transitive dep graph of `julia_precompile` targets) plus the depot-shaped package sources.
  2. `ctx.actions.declare_directory` for the merged depot.
  3. Copies all `packages/` and `compiled/` and `artifacts/` subdirectories from fragments into one tree.
  4. Also copies/generates the `env/Project.toml` and `env/Manifest.toml` for the target's specific dependency set.
  5. Normalizes mtimes to 1.
- This is a pure copy action: fast, deterministic, re-runs only when a fragment changes.

**Output**: A single tree artifact that is a complete, self-contained Julia depot.

**Test**: Merge fragments for a project with 4 deps. Verify the merged depot has all `packages/` and `compiled/` entries.

---

### Task 2.6: Precompile first-party packages

**File**: Uses infrastructure from Task 1.4 + Task 2.1

**What to do**:
- First-party `julia_library` targets with `precompile = True` also get `julia_precompile` actions.
- The depot fragment from Task 1.4 provides the `packages/<Name>/<slug>/` source.
- The precompile action for a first-party package depends on precompiled fragments of its third-party deps.

**Test**: A first-party library that depends on `StaticArrays` precompiles successfully. `Base.isrelocatable` assertion passes.

---

## Phase 3: Runtime Integration

**Goal**: `julia_binary` and `julia_test` use the merged precompiled depot at runtime.

---

### Task 3.1: Update `binary_wrapper.sh.tpl` for depot-based runtime

**File**: `julia/private/binary_wrapper.sh.tpl`

**What to do**:
- When a precompiled depot is provided:
  ```bash
  DEPOT="$(rlocation "{precompiled_depot}")"
  SCRATCH="${TEST_TMPDIR:-${TMPDIR:-/tmp}}/julia-scratch-depot-$$"
  mkdir -p "$SCRATCH"
  export JULIA_DEPOT_PATH="$SCRATCH:$DEPOT"
  export JULIA_LOAD_PATH="$DEPOT/env"
  export JULIA_CPU_TARGET="{cpu_target}"
  export JULIA_PKG_PRECOMPILE_AUTO=0
  COMPILED_MODULES="yes"
  ```
- Scratch depot first (writable, for any runtime compilation or eviction), precompiled depot second (read-only).
- `JULIA_LOAD_PATH` points at the depot's `env/` dir where `Project.toml` and `Manifest.toml` live.
- When no precompiled depot, fall back to existing behavior (writable depot, `--compiled-modules=no`).

**Test**: Run a `julia_test` with precompile, verify it doesn't recompile anything.

---

### Task 3.2: Simplify `entrypoint.jl` for depot mode

**File**: `julia/private/entrypoint.jl`

**What to do**:
- When `JULIA_LOAD_PATH` is set (indicating depot mode), skip:
  - Manifest splicing (`setup_julia_environment`)
  - Artifact overrides (`setup_artifact_overrides`)
  - Include path computation from config file
- The depot is self-contained: `LOAD_PATH` entries resolve through the depot's `env/`, packages are found via the depot's `packages/`, artifacts via `artifacts/`.
- The entrypoint still handles: parsing args, setting `PROGRAM_FILE`, running the main script.

**Test**: A `julia_binary` with precompile runs and can `using StaticArrays` without any manifest splicing.

---

### Task 3.3: Update `_create_julia_binary_impl` to wire everything together

**File**: `julia/private/julia_common.bzl`

**What to do**:
- When `ctx.attr.precompile` is True:
  1. Collect all `julia_precompile` fragment outputs from the transitive dep graph.
  2. Call the merge action (Task 2.5) to produce the merged depot.
  3. Pass the merged depot to `_create_julia_wrapper` as `precompiled_depot`.
  4. Add the merged depot to runfiles.
- When `ctx.attr.precompile` is False: existing behavior unchanged.

**Test**: `bazel test //julia/private/tests/precompile:test_precompile` passes with `Base.isprecompiled(sa)` returning `true`.

---

### Task 3.4: Add `{cpu_target}` template substitution

**File**: `julia/private/julia_common.bzl`, `julia/private/binary_wrapper.sh.tpl`

**What to do**:
- Read the `JULIA_CPU_TARGET` build setting (from Task 2.4).
- Pass it as a `{cpu_target}` substitution into the wrapper template.
- The wrapper exports it so runtime Julia uses the same CPU target as the precompile action.

**Test**: Build with `--//julia/settings:cpu_target=generic`, verify the runtime wrapper has `JULIA_CPU_TARGET=generic`.

---

## Phase 4: Cleanup and Migration

---

### Task 4.1: Deprecate old N-repo package layout

**File**: `julia/pkg/private/pkg.bzl`

**What to do**:
- Add a deprecation warning to the old `install()` function.
- Keep it functional for one release cycle.
- Update docs to recommend the new depot-based approach.

---

### Task 4.2: Remove `entrypoint_utils.jl` manifest splicing (once depot mode is default)

**File**: `julia/private/entrypoint_utils.jl`

**What to do**:
- Once all tests pass with depot mode, the manifest splicing and artifact override logic can be removed.
- Keep it behind a flag initially in case users need fallback.

---

### Task 4.3: Update documentation

**Files**: `README.md`, `docs/`

**What to do**:
- Document the new `precompile` attribute.
- Document `JULIA_CPU_TARGET` build setting.
- Document migration path from old N-repo layout.
- Remove the `- [ ] Precompiling` TODO from README.

---

### Task 4.4: Add integration tests

**File**: `julia/private/tests/precompile/` (expand)

**What to do**:
- Test: precompile with deps, verify `Base.isprecompiled` for all transitive deps.
- Test: precompile with JLL packages + artifacts.
- Test: first-party library precompilation.
- Test: cache invalidation - change a source file, verify only affected packages recompile.
- Test: `isrelocatable` assertion fires on a bad package.

---

## Dependency Graph

```
Task 1.1 (lockfile slug)
    |
    v
Task 1.2 (depot repo rule) <-- Task 1.3 (julia_package rule)
    |                              |
    v                              v
Task 1.5 (module extension)   Task 1.6 (provider updates)
    |                              |
    v                              v
Task 1.4 (first-party depot shape) <--+
    |
    v
Task 2.1 (precompile rule) <-- Task 2.2 (worker script)
    |                              |
    v                              v
Task 2.3 (wire into dep graph) Task 2.4 (CPU target flag)
    |                              |
    v                              v
Task 2.5 (fragment merge) <--------+
    |
    v
Task 2.6 (first-party precompile)
    |
    v
Task 3.1 (runtime wrapper) <-- Task 3.4 (cpu_target substitution)
    |
    v
Task 3.2 (entrypoint simplification)
    |
    v
Task 3.3 (wire into binary impl)
    |
    v
Task 4.1-4.4 (cleanup, docs, tests)
```

**Parallel fetch (Task 1.2b)** can be done at any point after Task 1.2, independently of everything else.
