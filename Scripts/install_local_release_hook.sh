#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
configured="$(git config --get core.hooksPath || true)"
install_root="$HOME/Library/Application Support/Stash/LocalRelease"
hook_path="$install_root/hooks"
if [ -n "$configured" ] && [ "$configured" != "$hook_path" ]; then
  printf 'Refusing to replace existing core.hooksPath: %s\n' "$configured" >&2
  exit 1
fi
if [ -z "$configured" ]; then
  default_hooks="$(git rev-parse --git-path hooks)"
  case "$default_hooks" in
    /*) ;;
    *) default_hooks="$repo_root/$default_hooks" ;;
  esac
  for hook in "$default_hooks"/*; do
    [ -f "$hook" ] && [ -x "$hook" ] || continue
    case "$hook" in
      *.sample) continue ;;
    esac
    printf 'Refusing to suppress active default hook: %s\n' "$hook" >&2
    exit 1
  done
fi
if [ "$configured" = "$hook_path" ] && [ -e "$hook_path/pre-push" ] && \
    ! cmp -s .githooks/pre-push "$hook_path/pre-push"; then
  printf 'Refusing to replace existing active hook: %s/pre-push\n' "$hook_path" >&2
  exit 1
fi

mkdir -p "$install_root/Scripts" "$hook_path"
chmod 700 "$install_root" "$install_root/Scripts" "$hook_path"
for helper in local_release.py release_pipeline.py release_versions.py package_release.py release_metadata.py; do
  install -m 600 "Scripts/$helper" "$install_root/Scripts/$helper"
done
install -m 700 .githooks/pre-push "$hook_path/pre-push"
git config --local core.hooksPath "$hook_path"
printf 'Installed local release hook path: %s\n' "$hook_path"
