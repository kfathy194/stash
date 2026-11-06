# Stash identity

**Idea:** a small personal home for useful things. Two ivory cards and a flowing jade ribbon form a recognizable S. The app icon is sculpted; the companion glyph is flat and legible at menu-bar sizes.

**Voice:** calm, direct, useful. “A home for the things you copy.” No claims that the app has saved or synced something until the operation succeeds.

**Color:** midnight `#102F33`, jade `#22B6A5`, mint `#B8F2DF`, ivory `#F2FCF8`. Interactive tint is darker jade in light mode and lighter mint in dark mode for contrast. Use semantic system backgrounds and labels for app content.

**Type:** San Francisco for the interface; rounded semibold for the Stash wordmark. No custom font dependencies.

**Assets:** macOS master has transparent outer margins; iOS icon is opaque. All required icon sizes are generated from the masters by `Scripts/package_brand.swift`. `StashMac/AppIcon.icon` reuses the exact Mac master for current macOS icon appearances; its composition removes legacy outer padding. `Scripts/package_brand.swift` also refreshes its artwork copy. Xcode generates legacy bitmaps from the composition for previous systems; the existing Mac bitmap catalog and dedicated fallback are retained. `Stash.icns` is a dedicated macOS fallback for Finder, Login Items and privacy panes. `StashStatus` is a monochrome template and follows the menu bar's appearance.

**Naming:** release bundle is `Stash.app`, displayed name “Stash”. QA bundles must not be distributed or registered as login items. The local MCP bridge is a bundled helper, not a separate login item.

