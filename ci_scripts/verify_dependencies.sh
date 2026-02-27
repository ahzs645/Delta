#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

missing=0

check_nonempty_dir() {
  local dir="$1"
  local hint="$2"

  if [[ ! -d "$dir" ]]; then
    echo "❌ Missing directory: $dir"
    echo "   $hint"
    missing=1
    return
  fi

  if [[ -z "$(find "$dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "❌ Directory is empty: $dir"
    echo "   $hint"
    missing=1
    return
  fi

  echo "✅ Found dependency contents: $dir"
}

check_nonempty_dir "External/Harmony" "Run: git submodule update --init --recursive"
check_nonempty_dir "External/Roxas" "Run: git submodule update --init --recursive"
check_nonempty_dir "External/CheatBase" "Run: git submodule update --init --recursive"
check_nonempty_dir "Cores/DeltaCore" "Run: git submodule update --init --recursive"

if [[ $missing -ne 0 ]]; then
  cat <<'MSG'

Dependency preflight failed.
These missing/empty submodules commonly cause errors such as:
- Cannot find type 'Syncable' in scope
- Cannot find 'DropboxService' in scope
- Type 'Expression<Any>' has no member ...

After submodules are initialized, re-run `pod install` and reopen Delta.xcworkspace.
MSG
  exit 1
fi

echo "All required submodules appear to be populated."
