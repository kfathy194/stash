# Development downloads and source provenance

Download published prereleases from [GitHub Releases](https://github.com/kfathy194/stash/releases).
Keep the supplied `SHA256SUMS` and `metadata.json` with the download. Verify the
checksum before installing; a checksum is not notarization or a safety guarantee.

Public Git tags identify clean source snapshots. `PUBLIC-SOURCE.json` records the
original build-source revision and export file hashes. The original binary receipt
retains its original build-source SHA: the binaries were not rebuilt from the new
public Git commit. Public release notes map the two identities explicitly.

Private Git history, operational discussions, and build logs are not imported.
Snapshots are prepared locally, reviewed for privacy, and published separately
from private builds. No hosted runner or automatic private-history mirror is used.
The private development hook/LaunchAgent is not installed from this public repo.
