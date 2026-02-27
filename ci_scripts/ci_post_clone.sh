#!/bin/bash
set -euo pipefail

echo "[ci_post_clone] Running post-clone setup..."

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$PWD}}"

# Rewrite any SSH submodule URLs to HTTPS so Xcode Cloud can clone them
# without SSH key authentication. The .gitmodules file should already use
# HTTPS, but git may have cached older SSH URLs in .git/config.
if command -v git &>/dev/null && [[ -d "$repo_root/.git" ]]; then
  echo "[ci_post_clone] Ensuring all submodule URLs use HTTPS..."
  git -C "$repo_root" submodule foreach --quiet \
    'url=$(git -C "$toplevel" config submodule."$name".url 2>/dev/null || true)
     if [ -n "$url" ]; then
       new_url=$(echo "$url" | sed "s|git@github\.com:|https://github.com/|")
       if [ "$url" != "$new_url" ]; then
         echo "  Rewriting $name: $url -> $new_url"
         git -C "$toplevel" config submodule."$name".url "$new_url"
       fi
     fi' 2>/dev/null || true
  git -C "$repo_root" submodule sync --recursive 2>/dev/null || true

  echo "[ci_post_clone] Recursively initializing submodules..."
  git -C "$repo_root" submodule update --init --recursive
fi

# Install CocoaPods dependencies. The Pods directory is committed, but local
# pods (Roxas, Harmony) reference submodule paths that must exist first.
# Running pod install ensures the Pods project is consistent after submodule
# initialization.
if command -v pod &>/dev/null && [[ -f "$repo_root/Podfile" ]]; then
  echo "[ci_post_clone] Installing CocoaPods dependencies..."
  cd "$repo_root"
  pod install --repo-update
fi

echo "[ci_post_clone] Done."
