#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

fixture_root="$(mktemp -d /private/tmp/stash-onboarding-smoke.XXXXXX)"
printf 'Disposable onboarding fixture: %s\n' "$fixture_root"
app_contents="$fixture_root/StashOnboardingSmoke.app/Contents"
mkdir -p "$fixture_root/home" "$fixture_root/sources" "$app_contents/MacOS" "$app_contents/Resources"
printf 'generated-onboarding-fixture\n' > "$fixture_root/fixture-marker"

for source in StashMac/*.swift; do
    [ "$source" = StashMac/StashApp.swift ] && continue
    sed '/^import StashCore$/d' "$source" > "$fixture_root/sources/$(basename "$source")"
done

cat > "$app_contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>StashOnboardingSmoke</string>
<key>CFBundleIdentifier</key><string>com.kfathy.stash.onboarding-smoke</string>
<key>CFBundleName</key><string>Stash Onboarding Smoke</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

xcrun actool --compile "$app_contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --target-device mac StashMac/Assets.xcassets

xcrun swiftc -parse-as-library -swift-version 6 -default-isolation nonisolated \
    -Xcc -fmodule-map-file="$PWD/StashCore/Sources/CSQLite/module.modulemap" \
    StashCore/Sources/StashCore/*.swift "$fixture_root"/sources/*.swift Scripts/OnboardingSmoke.swift \
    -lsqlite3 -o "$app_contents/MacOS/StashOnboardingSmoke"

CFFIXED_USER_HOME="$fixture_root/home" \
    "$app_contents/MacOS/StashOnboardingSmoke" "$fixture_root" "$@"
