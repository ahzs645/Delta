#!/bin/bash
set -euo pipefail

echo "[ci_post_clone] Running post-clone setup..."

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$PWD}}"

# Recursively initialize all submodules. Xcode Cloud initializes top-level
# submodules but may skip nested ones (e.g. melonDS inside MelonDSDeltaCore).
if command -v git &>/dev/null && [[ -d "$repo_root/.git" ]]; then
  echo "[ci_post_clone] Recursively initializing submodules..."
  git -C "$repo_root" submodule update --init --recursive
fi

echo "[ci_post_clone] Done."
