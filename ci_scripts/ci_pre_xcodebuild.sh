#!/bin/bash
set -euo pipefail

echo "[ci_pre_xcodebuild] Applying Xcode Cloud dependency workarounds..."
bundler_version="4.0.7"

prepend_path() {
  local dir="$1"

  if [[ -z "$dir" || ! -d "$dir" ]]; then
    return 0
  fi

  case ":$PATH:" in
    *":$dir:"*) ;;
    *) export PATH="$dir:$PATH" ;;
  esac
}

activate_current_ruby_binpaths() {
  if ! command -v ruby &>/dev/null; then
    return 1
  fi

  local gem_bindir
  gem_bindir="$(ruby -e 'print Gem.bindir' 2>/dev/null || true)"
  prepend_path "$gem_bindir"
  hash -r
}

activate_existing_ruby_toolchain() {
  if command -v rbenv &>/dev/null; then
    export RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
    eval "$(rbenv init - bash)"
  fi

  if command -v mise &>/dev/null; then
    eval "$(mise activate bash)"
  fi

  if command -v brew &>/dev/null; then
    local brew_ruby_prefix
    brew_ruby_prefix="$(brew --prefix ruby 2>/dev/null || true)"
    prepend_path "$brew_ruby_prefix/bin"
  fi

  activate_current_ruby_binpaths || true
}

# Xcode 16+ explicit Swift modules can incorrectly resolve CocoaPods Clang modules
# (e.g. Harmony/SQLite) without their Swift APIs in CI archive builds.
export SWIFT_ENABLE_EXPLICIT_MODULES=NO

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

run_dependency_preflight() {
  local verify_script="$repo_root/ci_scripts/verify_dependencies.sh"

  if [[ ! -f "$verify_script" ]]; then
    echo "[ci_pre_xcodebuild] WARNING: dependency preflight script not found at $verify_script"
    return 0
  fi

  echo "[ci_pre_xcodebuild] Verifying required dependency checkouts..."

  if [[ -x "$verify_script" ]]; then
    "$verify_script"
  else
    bash "$verify_script"
  fi
}

ensure_pods_installed() {
  if [[ ! -f "$repo_root/Podfile" ]]; then
    return 0
  fi

  activate_existing_ruby_toolchain

  local podfile_lock="$repo_root/Podfile.lock"
  local manifest_lock="$repo_root/Pods/Manifest.lock"
  if [[ -f "$podfile_lock" && -f "$manifest_lock" ]] && cmp -s "$podfile_lock" "$manifest_lock"; then
    echo "[ci_pre_xcodebuild] CocoaPods already up to date. Skipping pod install."
    return 0
  fi

  local is_ci=0
  if [[ -n "${CI:-}" || -n "${CI_WORKSPACE:-}" || -n "${CI_XCODE_CLOUD:-}" ]]; then
    is_ci=1
  fi

  local use_bundle_exec=0
  if command -v bundle &>/dev/null && [[ -f "$repo_root/Gemfile" ]]; then
    use_bundle_exec=1
  fi

  if [[ $use_bundle_exec -eq 0 ]] && ! command -v pod &>/dev/null; then
    if [[ $is_ci -eq 1 ]]; then
      echo "[ci_pre_xcodebuild] ERROR: CocoaPods is required but neither 'bundle' nor 'pod' is available."
      echo "[ci_pre_xcodebuild] ERROR: Missing pod install can cause Harmony/SQLite symbol resolution failures."
      exit 1
    fi

    echo "[ci_pre_xcodebuild] WARNING: Neither 'bundle' nor 'pod' is available; skipping pod install for local build."
    echo "[ci_pre_xcodebuild] WARNING: If build fails with missing pods, run pod install manually."
    return 0
  fi

  echo "[ci_pre_xcodebuild] Installing/updating CocoaPods dependencies..."
  local pod_install_status=0
  if [[ $use_bundle_exec -eq 1 ]]; then
    (
      cd "$repo_root"
      bundle "_${bundler_version}_" exec pod install
    ) || pod_install_status=$?
  else
    (
      cd "$repo_root"
      # Avoid inheriting Bundler-specific environment when running under Xcode.
      # Some local Ruby setups only have a different Bundler version than Gemfile.lock.
      env -u BUNDLE_GEMFILE -u BUNDLE_PATH -u BUNDLE_BIN_PATH -u BUNDLE_WITHOUT -u RUBYGEMS_GEMDEPS -u RUBYOPT pod install
    ) || pod_install_status=$?
  fi

  if [[ $pod_install_status -ne 0 ]]; then
    if [[ $is_ci -eq 1 ]]; then
      echo "[ci_pre_xcodebuild] ERROR: pod install failed in CI environment."
      exit 1
    fi

    if [[ -d "$repo_root/Pods" && -f "$manifest_lock" ]]; then
      echo "[ci_pre_xcodebuild] WARNING: pod install failed, but existing Pods checkout was detected."
      echo "[ci_pre_xcodebuild] WARNING: Continuing local build. Fix CocoaPods/Bundler locally to silence this."
      return 0
    fi

    echo "[ci_pre_xcodebuild] ERROR: pod install failed and no usable Pods checkout was found."
    exit 1
  fi
}

stage_pod_module_artifacts() {
  local products_config_dir="$1"
  local public_headers_root="$repo_root/Pods/Headers/Public"

  if [[ ! -d "$public_headers_root" ]]; then
    return 0
  fi

  echo "[ci_pre_xcodebuild] Pre-staging pod module maps and public headers..."

  while IFS= read -r -d '' modulemap_path; do
    local source_dir
    local module_name
    local target_dir
    local companion_dir

    source_dir="$(dirname "$modulemap_path")"
    module_name="$(basename "$modulemap_path" .modulemap)"
    target_dir="$products_config_dir/$module_name"

    mkdir -p "$target_dir"

    # Copy the concrete files behind CocoaPods' symlinked public headers so
    # archive builds can resolve module maps before the producing pod target's
    # own copy phases have run.
    cp -RL "$source_dir"/. "$target_dir"/

    companion_dir="$public_headers_root/$module_name"
    if [[ -d "$companion_dir" && "$companion_dir" != "$source_dir" ]]; then
      cp -RL "$companion_dir"/. "$target_dir"/
    fi

    echo "[ci_pre_xcodebuild]   staged $module_name into $target_dir"
  done < <(find "$public_headers_root" -mindepth 2 -maxdepth 2 -name '*.modulemap' -print0 2>/dev/null)
}

prebuild_pods_target() {
  local pods_project="$repo_root/Pods/Pods.xcodeproj"
  if [[ ! -d "$pods_project" ]]; then
    echo "[ci_pre_xcodebuild] WARNING: Pods project not found at $pods_project"
    return 0
  fi

  local scheme="${CI_XCODE_SCHEME:-}"
  if [[ -z "$scheme" ]]; then
    if [[ -f "$repo_root/Delta.xcworkspace/xcshareddata/xcschemes/Delta-Cloud.xcscheme" ]]; then
      scheme="Delta-Cloud"
    else
      scheme="Delta"
    fi
  fi
  local configuration="${CONFIGURATION:-Release}"
  local sdk="${SDKROOT:-${SDK_NAME:-iphoneos}}"
  if [[ "$sdk" == */* ]]; then
    sdk="${SDK_NAME:-iphoneos}"
  fi

  local archive_suffix="/Build/Intermediates.noindex/ArchiveIntermediates/$scheme"
  local derived_data_root
  local archive_root
  local build_dir
  local obj_root

  if [[ -n "${BUILD_DIR:-}" && "$BUILD_DIR" == *"${archive_suffix}/BuildProductsPath" ]]; then
    build_dir="${BUILD_DIR}"
    archive_root="${build_dir%/BuildProductsPath}"
    derived_data_root="${archive_root%$archive_suffix}"
    obj_root="${OBJROOT:-$archive_root/IntermediateBuildFilesPath}"
  else
    derived_data_root="${CI_DERIVED_DATA_PATH:-}"
    if [[ -z "$derived_data_root" ]]; then
      if [[ -d "/Volumes/workspace/DerivedData" ]]; then
        derived_data_root="/Volumes/workspace/DerivedData"
      elif [[ -n "${CI_WORKSPACE:-}" && -d "${CI_WORKSPACE}/DerivedData" ]]; then
        derived_data_root="${CI_WORKSPACE}/DerivedData"
      else
        derived_data_root="$repo_root/DerivedData"
      fi
    fi

    archive_root="$derived_data_root$archive_suffix"
    build_dir="$archive_root/BuildProductsPath"
    obj_root="$archive_root/IntermediateBuildFilesPath"
  fi
  local effective_platform="-iphoneos"
  case "$sdk" in
    *simulator*) effective_platform="-iphonesimulator" ;;
    appletvos*) effective_platform="-appletvos" ;;
    appletvsimulator*) effective_platform="-appletvsimulator" ;;
    watchos*) effective_platform="-watchos" ;;
    watchsimulator*) effective_platform="-watchsimulator" ;;
    macosx*) effective_platform="" ;;
  esac
  local products_config_dir="$build_dir/${configuration}${effective_platform}"

  local -a targets=()
  if [[ "$scheme" == "DeltaPreviews" ]]; then
    targets=("Roxas" "Pods-DeltaPreviews")
  else
    targets=("Harmony" "SQLite.swift" "Pods-Delta")
  fi

  echo "[ci_pre_xcodebuild] Prebuilding pod targets into archive build dir..."
  echo "[ci_pre_xcodebuild]   scheme=$scheme configuration=$configuration sdk=$sdk"
  echo "[ci_pre_xcodebuild]   CI_DERIVED_DATA_PATH=${CI_DERIVED_DATA_PATH:-<unset>}"
  echo "[ci_pre_xcodebuild]   CI_WORKSPACE=${CI_WORKSPACE:-<unset>}"
  echo "[ci_pre_xcodebuild]   derived_data_root=$derived_data_root"
  echo "[ci_pre_xcodebuild]   BUILD_DIR=$build_dir"

  stage_pod_module_artifacts "$products_config_dir"

  local target
  for target in "${targets[@]}"; do
    echo "[ci_pre_xcodebuild] Building pod target: $target"
    env \
      -u BUILD_DIR \
      -u BUILD_ROOT \
      -u BUILT_PRODUCTS_DIR \
      -u CONFIGURATION_BUILD_DIR \
      -u CONFIGURATION_TEMP_DIR \
      -u DERIVED_FILE_DIR \
      -u DERIVED_FILES_DIR \
      -u DERIVED_SOURCES_DIR \
      -u FRAMEWORK_SEARCH_PATHS \
      -u HEADER_SEARCH_PATHS \
      -u LIBRARY_SEARCH_PATHS \
      -u MODULEMAP_FILE \
      -u OBJROOT \
      -u OTHER_CFLAGS \
      -u OTHER_CPLUSPLUSFLAGS \
      -u OTHER_LDFLAGS \
      -u OTHER_MODULE_VERIFIER_FLAGS \
      -u OTHER_SWIFT_FLAGS \
      -u PODS_BUILD_DIR \
      -u PODS_CONFIGURATION_BUILD_DIR \
      -u PODS_PODFILE_DIR_PATH \
      -u PODS_ROOT \
      -u PODS_TARGET_SRCROOT \
      -u PODS_XCFRAMEWORKS_BUILD_DIR \
      -u SRCROOT \
      -u SWIFT_INCLUDE_PATHS \
      -u SYMROOT \
      -u TARGET_BUILD_DIR \
      -u XCODE_DEVELOPER_DIR_PATH \
      xcodebuild \
      -project "$pods_project" \
      -target "$target" \
      -configuration "$configuration" \
      -sdk "$sdk" \
      BUILD_DIR="$build_dir" \
      OBJROOT="$obj_root" \
      SYMROOT="$build_dir" \
      build || {
        echo "[ci_pre_xcodebuild] ERROR: Failed to build pod target '$target'."
        exit 1
      }
  done

  # Verify expected Swift pod modules were produced at the same build-products
  # location used by Archive.
  if [[ "$scheme" != "DeltaPreviews" ]]; then
    local harmony_dir="$products_config_dir/Harmony"
    local sqlite_dir="$products_config_dir/SQLite.swift"
    local harmony_module_dir="$harmony_dir/Harmony.swiftmodule"
    local sqlite_module_dir="$sqlite_dir/SQLite.swiftmodule"

    echo "[ci_pre_xcodebuild] Verifying pod module outputs..."
    echo "[ci_pre_xcodebuild]   products_config_dir=$products_config_dir"

    if [[ ! -d "$harmony_module_dir" || -z "$(find "$harmony_module_dir" -name '*.swiftmodule' -print -quit 2>/dev/null)" ]]; then
      echo "[ci_pre_xcodebuild] ERROR: Harmony Swift module output missing at $harmony_module_dir"
      ls -la "$harmony_dir" 2>/dev/null || true
      exit 1
    fi

    if [[ ! -d "$sqlite_module_dir" || -z "$(find "$sqlite_module_dir" -name '*.swiftmodule' -print -quit 2>/dev/null)" ]]; then
      echo "[ci_pre_xcodebuild] ERROR: SQLite.swift module output missing at $sqlite_module_dir"
      ls -la "$sqlite_dir" 2>/dev/null || true
      exit 1
    fi
  fi
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

run_dependency_preflight
ensure_pods_installed

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

prebuild_pods_target

echo "[ci_pre_xcodebuild] Done."
