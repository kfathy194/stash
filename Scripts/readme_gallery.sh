#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

fixture_root="$(mktemp -d /private/tmp/stash-readme-gallery.XXXXXX)"
printf 'Disposable README gallery: %s\n' "$fixture_root"
bundle="$fixture_root/StashReadmeGallery.app/Contents"
mkdir -p "$fixture_root/home" "$fixture_root/sources" "$fixture_root/images" "$bundle/MacOS" "$bundle/Resources"
printf 'generated-readme-gallery\n' > "$fixture_root/fixture-marker"

for source in StashMac/*.swift; do
    [ "$source" = StashMac/StashApp.swift ] && continue
    sed '/^import StashCore$/d' "$source" > "$fixture_root/sources/$(basename "$source")"
done

cat > "$bundle/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>StashReadmeGallery</string>
<key>CFBundleIdentifier</key><string>com.kfathy.stash.readme-gallery</string>
<key>CFBundleName</key><string>Stash README Gallery</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>StashCloudKitEnabled</key><false/>
</dict></plist>
PLIST

xcrun actool StashMac/Assets.xcassets --compile "$bundle/Resources" \
    --platform macosx --minimum-deployment-target 14.0 --target-device mac
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation nonisolated \
    -Xcc -fmodule-map-file="$PWD/StashCore/Sources/CSQLite/module.modulemap" \
    StashCore/Sources/StashCore/*.swift "$fixture_root"/sources/*.swift Scripts/ReadmeGallery.swift \
    -lsqlite3 -o "$bundle/MacOS/StashReadmeGallery"
CFFIXED_USER_HOME="$fixture_root/home" "$bundle/MacOS/StashReadmeGallery" "$fixture_root"
printf 'Inspect generated screenshots in %s/images\n' "$fixture_root"
