#!/bin/bash
set -euo pipefail

echo "[ci_post_clone] Running post-clone setup..."

repo_root="${CI_PRIMARY_REPOSITORY_PATH:-${CI_WORKSPACE:-$PWD}}"
min_ruby_version="3.2.0"
preferred_ruby_version="3.2.6"
bundler_version="4.0.7"

ruby_meets_minimum() {
  if ! command -v ruby &>/dev/null; then
    return 1
  fi

  ruby -e '
    required = Gem::Version.new(ARGV[0])
    current = Gem::Version.new(RUBY_VERSION)
    exit(current >= required ? 0 : 1)
  ' "$min_ruby_version"
}

ensure_ruby_runtime() {
  if ruby_meets_minimum; then
    echo "[ci_post_clone] Using Ruby $(ruby -e 'print RUBY_VERSION')"
    return 0
  fi

  if command -v rbenv &>/dev/null; then
    echo "[ci_post_clone] Ruby < $min_ruby_version detected. Installing Ruby $preferred_ruby_version via rbenv..."
    export RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
    eval "$(rbenv init - bash)"
    rbenv install -s "$preferred_ruby_version"
    rbenv global "$preferred_ruby_version"
  elif command -v mise &>/dev/null; then
    echo "[ci_post_clone] Ruby < $min_ruby_version detected. Installing Ruby $preferred_ruby_version via mise..."
    eval "$(mise activate bash)"
    mise install "ruby@$preferred_ruby_version"
    mise use -g "ruby@$preferred_ruby_version"
  else
    echo "[ci_post_clone] ERROR: Ruby $min_ruby_version+ is required for Bundler $bundler_version."
    echo "[ci_post_clone] ERROR: Install/setup Ruby (for example via rbenv or mise) before running this script."
    exit 1
  fi

  if ! ruby_meets_minimum; then
    echo "[ci_post_clone] ERROR: Failed to activate Ruby $min_ruby_version+."
    exit 1
  fi

  echo "[ci_post_clone] Using Ruby $(ruby -e 'print RUBY_VERSION')"
}

setup_bundler() {
  if [[ ! -f "$repo_root/Gemfile" ]]; then
    return 0
  fi

  ensure_ruby_runtime

  echo "[ci_post_clone] Installing Bundler $bundler_version..."
  gem install bundler -v "$bundler_version" --no-document

  echo "[ci_post_clone] Installing Ruby gems via Bundler..."
  (
    cd "$repo_root"
    bundle "_${bundler_version}_" install
  )
}

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
  setup_bundler

  echo "[ci_post_clone] Installing CocoaPods dependencies..."
  if command -v bundle &>/dev/null && [[ -f "$repo_root/Gemfile" ]]; then
    (
      cd "$repo_root"
      bundle "_${bundler_version}_" exec pod install --repo-update
    )
  elif command -v pod &>/dev/null; then
    (
      cd "$repo_root"
      pod install --repo-update
    )
  else
    echo "[ci_post_clone] ERROR: CocoaPods is required but neither 'bundle' nor 'pod' is available."
    exit 1
  fi
fi

if [[ ! -d "$repo_root/Delta.xcworkspace" ]]; then
  echo "[ci_post_clone] ERROR: Expected workspace not found at $repo_root/Delta.xcworkspace"
  exit 1
fi

echo "[ci_post_clone] Done."
