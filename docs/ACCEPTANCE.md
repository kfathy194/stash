# Development status and limitations

Stash is a development application. Source availability and automated tests are
not claims of production or App Store readiness. Run `bash Scripts/verify.sh`
on the selected snapshot to verify its code with your local toolchain.

- Mac development downloads are ad-hoc signed and unnotarized. Recent packages
  use local storage; iCloud sync and sharing require separate signed provisioning.
- Real permissions, direct paste across destination apps, signed CloudKit and
  multi-device sharing, MCP interoperability, and StoreKit acceptance are separate.
- Older snapshots represent their historical feature state. Prefer the newest
  development release and read its version-specific notes before installation.
- iOS/iPadOS installation requires your own signing and device provisioning.

The gallery, when present, uses generated examples rather than private clipboard
content. See [usage](USAGE.md) and [development downloads](RELEASES.md).
