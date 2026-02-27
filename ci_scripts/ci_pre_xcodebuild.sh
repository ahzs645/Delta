#!/bin/bash
set -euo pipefail

echo "[ci_pre_xcodebuild] Applying Xcode Cloud dependency workarounds..."

patch_rcheevos_package() {
  local package_file="$1"

  if [[ ! -f "$package_file" ]]; then
    return 0
  fi

  if ! grep -q 'module.modulemap' "$package_file"; then
    return 0
  fi

  echo "[ci_pre_xcodebuild] Patching rcheevos Package.swift at: $package_file"

  python3 - <<'PY' "$package_file"
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
updated = text

updated = re.sub(r',\s*"include/module\.modulemap"', '', updated)
updated = re.sub(r'"include/module\.modulemap"\s*,\s*', '', updated)

if updated != text:
    path.write_text(updated)
PY
}

create_libslirp_version_header() {
  local include_dir="$1"
  local header="$include_dir/libslirp-version.h"

  if [[ -f "$header" ]]; then
    return 0
  fi

  if [[ ! -f "$include_dir/libslirp.h" ]]; then
    return 0
  fi

  echo "[ci_pre_xcodebuild] Creating missing libslirp-version.h at: $header"

  cat > "$header" <<'HDR'
#ifndef LIBSLIRP_VERSION_H
#define LIBSLIRP_VERSION_H

#define SLIRP_VERSION_STRING "4.8.0"
#define SLIRP_MAJOR_VERSION 4
#define SLIRP_MINOR_VERSION 8
#define SLIRP_MICRO_VERSION 0

#endif /* LIBSLIRP_VERSION_H */
HDR
}

# Use CI_PRIMARY_REPOSITORY_PATH (the actual repo root in Xcode Cloud),
# falling back to CI_WORKSPACE and PWD for local usage.
repo_root="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$PWD}}"

echo "[ci_pre_xcodebuild] Using repo root: $repo_root"

# Ensure nested submodules are fully initialized (melonDS is a submodule
# inside the MelonDSDeltaCore submodule and may not be auto-initialized).
if command -v git &>/dev/null && [[ -d "$repo_root/.git" ]]; then
  echo "[ci_pre_xcodebuild] Initializing nested submodules..."
  git -C "$repo_root" submodule update --init --recursive || true
fi

# --- CocoaPods module-map fix ---
# Xcode's dependency scanner needs module maps before any target is built.
# The xcconfig files have been updated to reference the source copies in
# Pods/Target Support Files/, but as a safety net we also rewrite any
# remaining PODS_CONFIGURATION_BUILD_DIR references in the committed
# xcconfig files (in case pod install was run without the Podfile hook).
echo "[ci_pre_xcodebuild] Fixing CocoaPods module-map paths in xcconfigs..."
pods_dir="$repo_root/Pods"
if [[ -d "$pods_dir/Target Support Files" ]]; then
  while IFS= read -r -d '' xcconfig; do
    if grep -q 'PODS_CONFIGURATION_BUILD_DIR.*\.modulemap' "$xcconfig" 2>/dev/null; then
      # For each build-dir modulemap ref, find the matching source modulemap.
      python3 - "$xcconfig" "$pods_dir" <<'PYFIX'
import pathlib, re, sys, glob

xcconfig = pathlib.Path(sys.argv[1])
pods_dir = pathlib.Path(sys.argv[2])
text = xcconfig.read_text()

def replace_modulemap(m):
    pod_dir = m.group(1)
    source_dir = pods_dir / "Target Support Files" / pod_dir
    maps = list(source_dir.glob("*.modulemap"))
    if maps:
        return f'${{PODS_ROOT}}/Target Support Files/{pod_dir}/{maps[0].name}'
    return m.group(0)

updated = re.sub(
    r'\$\{PODS_CONFIGURATION_BUILD_DIR\}/([^/]+)/[^"]+\.modulemap',
    replace_modulemap,
    text,
)

# Add source-dir entries to SWIFT_INCLUDE_PATHS if not already present.
swift_match = re.search(r'^(SWIFT_INCLUDE_PATHS\s*=\s*.*)$', updated, re.M)
if swift_match:
    line = swift_match.group(1)
    build_dirs = re.findall(r'"\$\{PODS_CONFIGURATION_BUILD_DIR\}/([^"/]+)"', line)
    for d in dict.fromkeys(build_dirs):
        entry = f'"${{PODS_ROOT}}/Target Support Files/{d}"'
        if entry not in line:
            line += " " + entry
    updated = updated[:swift_match.start()] + line + updated[swift_match.end():]

if updated != text:
    xcconfig.write_text(updated)
    print(f"  Patched: {xcconfig.name}")
PYFIX
    fi
  done < <(find "$pods_dir/Target Support Files" -name '*.xcconfig' -print0 2>/dev/null)
fi

# --- rcheevos modulemap fix ---
# Search the repo tree and DerivedData for the rcheevos Package.swift.
search_roots=("$repo_root")
if [[ -n "${CI_DERIVED_DATA_PATH:-}" ]]; then
  search_roots+=("$CI_DERIVED_DATA_PATH")
fi

for search_root in "${search_roots[@]}"; do
  while IFS= read -r -d '' package_file; do
    patch_rcheevos_package "$package_file"
  done < <(find "$search_root" -type f -path '*/SourcePackages/checkouts/rcheevos/Package.swift' -print0 2>/dev/null)
done

# --- libslirp-version.h fix ---
# 1. Try the known path first (most reliable).
known_libslirp_src="$repo_root/Cores/MelonDSDeltaCore/melonDS/src/net/libslirp/src"
if [[ -d "$known_libslirp_src" ]]; then
  create_libslirp_version_header "$known_libslirp_src"
fi

# 2. Fallback: search the whole tree for any other libslirp.h copies.
for search_root in "${search_roots[@]}"; do
  while IFS= read -r -d '' libslirp_header; do
    create_libslirp_version_header "$(dirname "$libslirp_header")"
  done < <(find "$search_root" -type f -name libslirp.h -path '*/libslirp*/*' -print0 2>/dev/null)
done

echo "[ci_pre_xcodebuild] Done."
