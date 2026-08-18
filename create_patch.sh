#!/usr/bin/env bash
set -euo pipefail

# --- Usage ---
# ./create_patch.sh <commit-range>
#
# Examples:
#   ./create_patch.sh HEAD~3..HEAD      # last 3 commits
#   ./create_patch.sh abc123..def456    # specific range
#   ./create_patch.sh main..feature     # branch comparison
#   ./create_patch.sh HEAD~1            # changes since parent commit (implicit ..HEAD)

cd "$(git rev-parse --show-toplevel)"

# --- Paths to exclude (files or directories, relative to repo root) ---
EXCLUDED_PATHS=(
    "julia/pkg/private/pkg_compiler_utils.jl"
    "julia/pkg/private/pkg_utils.bzl"
    "build_templates/"
    "rules_julia/julia/private/entrypoint_utils.jl"
    "rules_julia/julia/private/julia_common_utils.bzl"
)

PATCH_FILE="rules_julia.patch"
OVERLAY_DIR="overlays"
COMMIT_RANGE="${1:?Usage: $0 <commit-range>}"

# Parse the end ref from the commit range (e.g., "abc..def" → "def", or "abc" → "abc")
if [[ "${COMMIT_RANGE}" == *..* ]]; then
    END_REF="${COMMIT_RANGE##*..}"
else
    END_REF="${COMMIT_RANGE}"
fi

# --- 1. Generate patch (julia/ + tools/ minus excluded paths) ---
PATHSPECS=("julia/" "tools/")
for p in "${EXCLUDED_PATHS[@]}"; do
    PATHSPECS+=(":!${p}")
done

git diff "${COMMIT_RANGE}" -- "${PATHSPECS[@]}" > "${PATCH_FILE}"
echo "Patch written to ${PATCH_FILE}"

# --- 2. Copy excluded files from END_REF into overlays/ ---
rm -rf "${OVERLAY_DIR}"

for p in "${EXCLUDED_PATHS[@]}"; do
    # List all files matching this path at END_REF
    # (works for both individual files and directories)
    git ls-tree -r --name-only "${END_REF}" -- "${p}" | while read -r file; do
        mkdir -p "${OVERLAY_DIR}/$(dirname "${file}")"
        git show "${END_REF}:${file}" > "${OVERLAY_DIR}/${file}"
    done
done

if [[ -d "${OVERLAY_DIR}" ]]; then
    echo "Excluded file overlays written to ${OVERLAY_DIR}/"
else
    echo "No excluded paths to overlay."
fi
