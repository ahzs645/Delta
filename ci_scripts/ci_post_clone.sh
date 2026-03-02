#!/bin/bash
set -euo pipefail

echo "[ci_post_clone] Running post-clone setup..."

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$PWD}}"

rewrite_ssh_urls() {
  local dir="$1"
  # Rewrite any SSH submodule URLs cached in .git/config to HTTPS.
  git -C "$dir" config --local --get-regexp 'submodule\..*\.url' 2>/dev/null | while read -r key url; do
    new_url=$(echo "$url" | sed 's|git@github\.com:|https://github.com/|')
    if [ "$url" != "$new_url" ]; then
      echo "  Rewriting $key: $url -> $new_url"
      git -C "$dir" config "$key" "$new_url"
    fi
  done || true
}

if command -v git &>/dev/null && [[ -d "$repo_root/.git" ]]; then
  # 1. Register submodules and sync URLs from .gitmodules (which uses HTTPS).
  echo "[ci_post_clone] Registering submodules..."
  git -C "$repo_root" submodule init

  # 2. Sync URLs from .gitmodules → .git/config and force any stale SSH
  #    entries to HTTPS.
  echo "[ci_post_clone] Syncing submodule URLs..."
  git -C "$repo_root" submodule sync --recursive
  rewrite_ssh_urls "$repo_root"

  # 3. Clone first-level submodules.
  echo "[ci_post_clone] Updating first-level submodules..."
  git -C "$repo_root" submodule update --init

  # 4. Handle nested submodules (e.g. melonDS inside MelonDSDeltaCore).
  #    Their .gitmodules may contain SSH URLs that need rewriting before the
  #    recursive update can succeed.
  echo "[ci_post_clone] Initialising nested submodules..."
  git -C "$repo_root" submodule foreach --recursive \
    'git submodule init 2>/dev/null || true
     git submodule sync 2>/dev/null || true' 2>/dev/null || true

  # Rewrite any SSH URLs introduced by nested .gitmodules.
  git -C "$repo_root" submodule foreach --recursive \
    'git config --local --get-regexp "submodule\..*\.url" 2>/dev/null | while read -r key url; do
       new_url=$(echo "$url" | sed "s|git@github\.com:|https://github.com/|")
       if [ "$url" != "$new_url" ]; then
         echo "  Rewriting nested $key: $url -> $new_url"
         git config "$key" "$new_url"
       fi
     done || true' 2>/dev/null || true

  echo "[ci_post_clone] Updating recursive submodules..."
  git -C "$repo_root" submodule update --init --recursive
fi

verify_script="$repo_root/ci_scripts/verify_dependencies.sh"
if [[ -f "$verify_script" ]]; then
  echo "[ci_post_clone] Running dependency preflight..."
  if [[ -x "$verify_script" ]]; then
    "$verify_script"
  else
    bash "$verify_script"
  fi
fi

# Install CocoaPods dependencies.
if [[ -f "$repo_root/Podfile" ]]; then
  if ! command -v pod &>/dev/null; then
    echo "[ci_post_clone] ERROR: CocoaPods is required but 'pod' is unavailable in PATH."
    echo "[ci_post_clone] ERROR: Run 'pod install' before archiving Delta.xcworkspace."
    exit 1
  fi

  echo "[ci_post_clone] Installing CocoaPods dependencies..."
  (
    cd "$repo_root"
    pod install --repo-update
  )
fi

if [[ ! -d "$repo_root/Delta.xcworkspace" ]]; then
  echo "[ci_post_clone] ERROR: Expected workspace not found at $repo_root/Delta.xcworkspace"
  exit 1
fi

echo "[ci_post_clone] Done."
