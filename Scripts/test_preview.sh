#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d /tmp/stash-preview-smoke.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/home" "$scratch/sources" "$scratch/PreviewSmoke.app/Contents/MacOS"
# Compile the real app types, but replace its startup with generated fixtures.
for source in StashMac/*.swift; do
    [ "$source" = StashMac/StashApp.swift ] && continue
    sed '/^import StashCore$/d' "$source" > "$scratch/sources/$(basename "$source")"
done
cat > "$scratch/PreviewSmoke.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.kfathy.stash.preview-smoke</string><key>CFBundleExecutable</key><string>PreviewSmoke</string><key>LSUIElement</key><true/></dict></plist>
PLIST
swiftc -swift-version 6 -default-isolation nonisolated \
    -Xcc -fmodule-map-file="$PWD/StashCore/Sources/CSQLite/module.modulemap" \
    StashCore/Sources/StashCore/*.swift "$scratch"/sources/*.swift Scripts/tests/PreviewSmoke.swift \
    -lsqlite3 -o "$scratch/PreviewSmoke.app/Contents/MacOS/PreviewSmoke"
CFFIXED_USER_HOME="$scratch/home" \
    python3 - "$scratch/PreviewSmoke.app/Contents/MacOS/PreviewSmoke" "$scratch" <<'PY'
import subprocess
import sys

try:
    subprocess.run(sys.argv[1:], check=True, timeout=30)
except subprocess.TimeoutExpired:
    sys.exit("FAIL: Preview did not finish within 30 seconds (a file reference may have blocked it)")
PY
