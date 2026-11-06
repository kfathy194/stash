#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
stash_check_root="${STASH_CHECK_ROOT:-${TMPDIR:-/tmp}/stash-verification}"
mkdir -p "$stash_check_root"
export CLANG_MODULE_CACHE_PATH="$stash_check_root/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$stash_check_root/modules"
export CFFIXED_USER_HOME="$stash_check_root/home"
mkdir -p "$CFFIXED_USER_HOME"
python3 Scripts/generate_config.py
python3 Scripts/generate_project.py
python3 -m unittest discover -s Scripts/tests -v
swift test --disable-sandbox --package-path StashCore --scratch-path "$stash_check_root/package"
xcodebuild -project Stash.xcodeproj -scheme StashMac -configuration Release -derivedDataPath "$stash_check_root/mac" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO 'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -disable-sandbox' build
xcodebuild -project Stash.xcodeproj -scheme StashIOS -configuration Debug -derivedDataPath "$stash_check_root/ios" -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO 'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -disable-sandbox' build
