# Stash public source guidance

This repository contains reviewed source snapshots and development downloads.
The `public` branch is the distribution history; private development commits and
operational records are not imported. Do not merge private history into this repo.

Read README.md, docs/ACCEPTANCE.md, and CODING-STANDARDS.md before changing code.
Preserve Swift 6, macOS 14 and iOS 17 targets. Run Scripts/verify.sh for relevant
code changes and keep signed-device acceptance distinct from automated checks.
Never commit clipboard data, credentials, personal paths, screenshots of user
content, build caches, or private commit metadata. Use a GitHub no-reply email.

The maintainer release scripts are included for source completeness and tests.
Do not install their hooks or LaunchAgent from this public snapshot; they operate
the maintainer's separately controlled development workflow. Public publication
requires review of the selected files and source provenance.
