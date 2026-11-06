# Stash usage and developer notes

The [README](../README.md) introduces the app, installation, and common workflows. This guide covers detailed controls, provisioning, and local development.

## Build from source

Open `Stash.xcodeproj` with Xcode 26 or newer. Choose `StashMac` or `StashIOS`. Minimum deployment: macOS 14, iOS/iPadOS 17. Suggestions uses macOS 26 Foundation Models.

The Xcode project uses a native static `StashCore` framework target and the same sources are independently available as the local `StashCore` Swift package. No external package downloads are needed. `Scripts/generate_project.py` and `Scripts/generate_config.py` regenerate the project and configuration files.

```sh
swift test --package-path StashCore
xcodebuild -project Stash.xcodeproj -scheme StashMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Stash.xcodeproj -scheme StashIOS -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

`Scripts/verify.sh` provides a reproducible unsigned verification path with temporary caches for restricted build environments. Its `-disable-sandbox` compiler flag concerns compiler plug-ins, not Stash's runtime permissions.

## Development downloads

See [release information](RELEASES.md).

## Mac setup and recovery

The wizard opens automatically for new Mac libraries. Use Back and Continue to review the local draft. Outside a text field or shortcut recorder, press Command–Return to continue or finish. Close the window at any point. Reopen Stash or choose **Resume Setup** in the menu bar to return to the draft. **Discard changes** clears the draft. For first setup, it returns you to Welcome and keeps capture paused. Existing users can reopen the wizard from **Settings → General → Setup Wizard…** and keep using their current configuration until Finish succeeds.

Use Privacy to choose retention and exclude apps from future capture. Shortening retention for an existing library asks before deleting older History. Pinboards are kept. Decline the confirmation to keep your current settings and draft.

If a shortcut conflicts, choose another combination or explicitly continue without the affected shortcut. The menu bar remains available when either the Open Stash or Paste Stack shortcut is disabled or unavailable. Launch at login may require approval in **System Settings → General → Login Items & Extensions**. Use the available retry or manual-startup fallback if registration fails. Retry Finish after resolving any settings-save error.

Direct paste uses Accessibility. Grant access only if you want it. A grant in macOS takes effect immediately and survives discarding a setup draft. Continue without direct paste to copy selected clips and paste them yourself. Finish opens the Clipboard tab, skips pre-existing clipboard contents on first capture, and shows a dismissible guide for trying a copy or finding the advanced Settings pages.

## Use on Mac

Launch `Stash.app`, copy something, then press **⇧⌘V**. The panel opens on the display under the pointer. Click an item to paste it; Command/Shift-click selects without pasting. Return pastes; ⇧Return pastes plain text; ⌘1–9 pastes a numbered item; Space previews. Without Accessibility permission, Stash copies the item and explains manual paste. Enable Accessibility in System Settings only when you want direct pasting. Capture skips the pre-existing clipboard on launch, concealed/transient content and ignored apps by default.

Drag the panel's top handle to resize. Use the toolbar to search, filter or create pinboards. Right-click cards and board tabs for actions. Settings includes retention, backup, app exclusions, shortcut recording, iCloud and opt-in intelligence.

Inside a writable Pinboard, **Add item (+)** or **⌘N** opens the text editor and saves directly to that Pinboard, outside History. The destination stays fixed while you draft. The separate **New Pinboard** control creates a collection. The resizable editor includes an optional title, explicit Save/Cancel and a format selector for Plain Text, Rich Text and code languages. Code copies as literal source; selecting HTML does not render it. Formatting-loss and unsaved-change prompts protect drafts. iOS keeps its plain editor while preserving a Code item's selected language.

**⇧⌘C** starts an ordered Paste Stack. Subsequent copies enter the stack. With Accessibility allowed, ordinary ⌘V consumes the next item; Stash-generated paste events do not consume it. Stop the stack from the toolbar/menu when finished.

`Stash.app --demo --show-panel` uses an isolated in-memory sample library and disables clipboard polling. Demo content is not the user's history. This is solely a UI verification option.

For disposable retention Settings checks, run `bash Scripts/retention_smoke.sh`.
It builds a separate temporary `StashRetentionSmoke.app` containing the production
retention controls and generated History/Pinboard records. It uses an explicit
temporary library, isolated preferences home and no clipboard, shortcut,
permission, login-item or normal application services. The window shows the
stored policy and generated records; **Reopen disposable library** reloads the
store and applies the normal retention operation. Build logs and fixture data
remain in the printed temporary directory. This checks retention controls;
full Stash startup, OS permissions and actual destination-app pasting remain
separate checks. Ordinary `--demo` disables capture but does not isolate every
system integration or preference.

For disposable editor and Pinboard checks, run `bash Scripts/editor_smoke.sh`.
It compiles the production controls into a distinct **Stash Editor Smoke** app
with generated content and an explicit temporary library. It does not start
normal capture, paste, global shortcuts, MCP or permission services. Its local
⌘N route invokes the production new-item handler. Close generated editors before
using **Reopen generated library**. Build output and fixture data remain in the
printed temporary directory; these checks do not establish signed CloudKit or
live destination-app paste behavior.

## iPhone and iPad

Use the native Paste control to save clipboard content, or the iOS Share Sheet. iPad visible capture is explicitly enabled by the user and checks privacy markers/pause state. The Share extension can save straight into a pinboard. Enable the Stash keyboard through system Keyboard settings; Full Access is required to read the shared on-device App Group. The keyboard does not send data to a backend. It pages through history/pinboards; text is inserted directly, while images/files are copied for the destination app's Paste command.

## Apple signing and cloud setup

For physical devices and CloudKit, choose your Apple Developer team for all app/extension targets. Register `group.com.kfathy.stash` and `iCloud.com.kfathy.stash`, with the entitlements in `Config`. Change the identifiers consistently if those names are not yours. Enable CloudKit, App Groups and remote notifications in the corresponding developer records. Initialize/deploy the Core Data CloudKit schema in your development account, then test two devices and two sharing accounts before production deployment. No account, paid service, production schema or store listing has been created by this project.

The supplied Mac build is for direct distribution and is intentionally not App Sandboxed, because it uses global pasteboard capture and accessibility event injection. It is not a Mac App Store submission configuration. A local/ad-hoc signature is not Developer ID signing or notarization. Automated ad-hoc development downloads use a separate local-only entitlement profile and disable iCloud sync/sharing in that package. Saved sync preferences remain intact for a properly provisioned build. See [development release limitations](RELEASES.md).

## Data and privacy

Mac storage: `~/Library/Application Support/Stash`. iOS and both extensions: `Stash` inside the App Group. Core Data stores private history separately from the shared board graph. Shared boards reference only separate copies of selected items; private clipboard history is never related into that graph. Binary payloads use external storage, which Core Data mirrors through CloudKit assets. File copies imported through iOS providers are preserved before the provider's temporary URL disappears; Mac file captures retain bookmarks/references.

MCP, Suggestions and iCloud opt-in are device-local consents, not cloud-synced permissions. Screen context is ephemeral and Suggestions fails closed when the focused window/password state cannot be identified. Link previews contact the copied website. There is no custom application server, analytics SDK or third-party dependency.

Exports contain private clipboard data. Keep them private. Import currently merges content and pinboards while preserving existing device preferences/permissions. On Mac, Settings → General → Migrate from PasteBar… reads an official PasteBar backup ZIP and adds supported History text, links, code, images with available bytes, and external file references. History dates reset to import time. Re-import skips known source IDs and preserves Stash edits; masked/protected content is skipped. Saved static clips keep their creation dates and import onto one Pinboard per collection/tab. Nested folder names are retained in titles; protected tabs and ancestors are skipped. An item in several tabs becomes an independent placement on each Pinboard. Nested sibling order is flattened depth first, and PasteBar named tab colors map to representative palette colors. Menu-only and dynamic actions are skipped. The result reports skipped content and unresolved references. Backups above 512 MiB, individual entries above 500 MiB, expanded archives above 1 GiB, source row bytes, cached image bytes or migrated content/metadata above 500 MiB, nested paths deeper than 256 folders, derived names above 1 MiB, encrypted/ZIP64 archives, and unsupported schemas are rejected. Import prevalidates content and compensates newly committed migration records if a multi-store save fails. A private journal of record identities lets reopening Stash finish an interrupted rollback before loading content; persistent recovery errors are surfaced. Adding new clips to an already shared imported Pinboard is rejected for the entire migration; duplicate-only repeats remain skipped. No live PasteBar database or original file is changed. Real-backup/version compatibility remains unverified. An archive stores preferences for future migration but does not silently apply them. Mac file references do not constitute backups of original files. A removed shared board returns any surviving original private copy to ordinary history, avoiding invisible orphan data; local deliberate board deletion removes that board's items.

## MCP

Enable Settings → Intelligence → MCP & AI Tools. The bundled `Contents/Helpers/StashMCP` is a stdio bridge to an opt-in loopback HTTP JSON-RPC server at `127.0.0.1:47841`. Launch with `--client "Tool name"`. Stash prompts before issuing a per-client Keychain token. You independently grant history reads, pinboard reads and item writes. Revocation takes effect immediately. `--reset` clears that bridge client's old credential so it can request approval again. Tokens never appear on protocol stdout.

Available tools: `search_items`, `get_item`, `list_recent`, `create_item`, `list_pinboards`, `create_pinboard`, `add_to_pinboard`. Write-only clients can move items they created without reading unrelated history. Setup snippets for Claude Desktop/Code, Codex, Cursor, VS Code, Windsurf and custom clients are included in the app.

## Branding

The [branding guide](../Branding/README.md) identifies the masters and reusable mark. `Scripts/package_brand.swift` generates the size-specific icon/badge/template assets; `Scripts/package_icns.py` packages the native macOS ICNS resource. `CFBundleDisplayName` and the final bundle name are Stash, and the bundle includes both the asset catalog icon and an explicit native icon fallback. QA bundles are excluded from deliverables.

## Commerce

Off by default through `StashCommerceEnabled`. StoreKit product loading, verified purchases, restoration and entitlement inspection are implemented. Product setup, eligibility/trial configuration, entitlement enforcement and direct-sale/team licensing remain release work. Do not enable the flag and assume the app is ready to charge customers.
