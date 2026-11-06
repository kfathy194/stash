#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_root="$(mktemp -d /private/tmp/stash-editor-smoke.XXXXXX)"
printf 'Disposable editor fixture: %s\n' "$fixture_root"
mkdir -p "$fixture_root/home" "$fixture_root/sources" "$fixture_root/StashEditorSmoke.app/Contents/MacOS"
printf 'generated-editor-fixture\n' > "$fixture_root/fixture-marker"
for source in StashMac/*.swift; do
    [ "$source" = StashMac/StashApp.swift ] && continue
    sed '/^import StashCore$/d' "$source" > "$fixture_root/sources/$(basename "$source")"
done
cat > "$fixture_root/StashEditorSmoke.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>StashEditorSmoke</string>
<key>CFBundleIdentifier</key><string>com.kfathy.stash.editor-smoke</string>
<key>CFBundleName</key><string>Stash Editor Smoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation nonisolated \
    -Xcc -fmodule-map-file="$PWD/StashCore/Sources/CSQLite/module.modulemap" \
    StashCore/Sources/StashCore/*.swift "$fixture_root"/sources/*.swift Scripts/EditorSmoke.swift \
    -lsqlite3 -o "$fixture_root/StashEditorSmoke.app/Contents/MacOS/StashEditorSmoke"
CFFIXED_USER_HOME="$fixture_root/home" \
    "$fixture_root/StashEditorSmoke.app/Contents/MacOS/StashEditorSmoke" "$fixture_root"
