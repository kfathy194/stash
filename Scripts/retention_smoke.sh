#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

smoke_root="$(mktemp -d /private/tmp/stash-retention-smoke.XXXXXX)"
printf 'Disposable smoke root: %s\n' "$smoke_root"
printf 'generated-retention-fixture\n' > "$smoke_root/fixture-marker"
export STASH_RETENTION_SMOKE_ROOT="$smoke_root"
export CFFIXED_USER_HOME="$smoke_root/home"
export CLANG_MODULE_CACHE_PATH="$smoke_root/clang"
mkdir -p "$CFFIXED_USER_HOME"

xcodebuild -project Stash.xcodeproj -scheme StashCore -configuration Debug \
    -derivedDataPath "$smoke_root/build" -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO 'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -disable-sandbox' build > "$smoke_root/build.log" 2>&1

smoke_app="$smoke_root/StashRetentionSmoke.app"
mkdir -p "$smoke_app/Contents/MacOS"
cat > "$smoke_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>StashRetentionSmoke</string>
<key>CFBundleIdentifier</key><string>com.kfathy.stash.retention-smoke</string>
<key>CFBundleName</key><string>Stash Retention Smoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 6 \
    -F "$smoke_root/build/Build/Products/Debug" -framework StashCore \
    -I StashCore/Sources/CSQLite -lsqlite3 \
    StashMac/HistoryRetentionSettings.swift Scripts/RetentionSmoke.swift \
    -o "$smoke_app/Contents/MacOS/StashRetentionSmoke"
"$smoke_app/Contents/MacOS/StashRetentionSmoke"
