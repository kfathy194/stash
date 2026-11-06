#!/bin/sh
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(git -C "$script_dir/.." rev-parse --show-toplevel)"
install_root="$HOME/Library/Application Support/Stash/LocalRelease/Publisher"
agent_dir="$HOME/Library/LaunchAgents"
log_root="$HOME/Library/Logs/Stash"
label="com.kfathy.stash-local-release-publisher"
agent_path="$agent_dir/$label.plist"
domain="gui/$(id -u)"
action="${1:-install}"

case "$action" in
  install)
    mkdir -p "$install_root" "$agent_dir" "$log_root"
    chmod 700 "$install_root" "$log_root"
    for helper in local_release_publisher.py local_release.py release_pipeline.py \
        release_versions.py package_release.py release_metadata.py; do
      install -m 600 "$script_dir/$helper" "$install_root/$helper"
    done
    /usr/bin/python3 - "$script_dir/launch_agents/$label.plist" "$agent_path" \
        "$install_root" "$repo_root" "$log_root" <<'PY'
import os
import plistlib
import sys

source, target, install_root, repo_root, log_root = sys.argv[1:]
with open(source, 'rb') as stream:
    value = plistlib.load(stream)
replacements = {
    '@@INSTALL_ROOT@@': install_root,
    '@@REPO_ROOT@@': repo_root,
    '@@LOG_ROOT@@': log_root,
}
def replace(item):
    if isinstance(item, str):
        for marker, replacement in replacements.items():
            item = item.replace(marker, replacement)
        return item
    if isinstance(item, list):
        return [replace(entry) for entry in item]
    if isinstance(item, dict):
        return {key: replace(entry) for key, entry in item.items()}
    return item
with open(target, 'wb') as stream:
    plistlib.dump(replace(value), stream, sort_keys=True)
os.chmod(target, 0o600)
PY
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      launchctl bootout "$domain/$label"
    fi
    launchctl enable "$domain/$label"
    launchctl bootstrap "$domain" "$agent_path"
    printf 'Installed %s; publisher runs at login and every five minutes.\n' "$label"
    ;;
  status)
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      printf 'LaunchAgent is loaded: %s\n' "$label"
    else
      printf 'LaunchAgent is not loaded: %s\n' "$label"
    fi
    if [ -f "$install_root/local_release_publisher.py" ]; then
      /usr/bin/python3 "$install_root/local_release_publisher.py" status --repo "$repo_root"
    else
      printf 'Publisher helpers are not installed.\n'
    fi
    ;;
  retry)
    exec /usr/bin/python3 "$install_root/local_release_publisher.py" retry --repo "$repo_root"
    ;;
  disable)
    launchctl disable "$domain/$label"
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      launchctl bootout "$domain/$label"
    fi
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      printf 'Failed to unload %s\n' "$label" >&2
      exit 1
    fi
    printf 'Disabled %s until reinstalled. Pending packages remain queued.\n' "$label"
    ;;
  *)
    printf 'Usage: %s [install|status|retry|disable]\n' "$0" >&2
    exit 2
    ;;
esac
