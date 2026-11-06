# README gallery

The gallery renders Stash's production AppKit and SwiftUI views with fictional Northstar Studio records. It builds a separate bundle with the production asset catalog and uses an in-memory library for feature records and a separate disposable local library for the wizard. The fixture excludes the application entry point and never starts capture, paste, global shortcuts, login registration, permission requests, or MCP.

From the repository root on a Mac with Xcode selected, run:

```sh
bash Scripts/readme_gallery.sh
```

The command prints a disposable directory under `/private/tmp`. Inspect the six PNGs in its `images` directory and copy only the reviewed images into this directory. The bundle, generated data and fixture home stay in the disposable directory.

The renderer snapshots its own view hierarchy, so the images contain no desktop, other windows, or menu-bar contents. It uses a fixed light appearance and consistent width. The app window frames shown in the guide are cropped to their content.

## Verification

The fixture rendered the five feature views with Xcode 27.2. The onboarding update adds the production Welcome step in its own disposable local library, giving the gallery six views. The first Privacy render failed when the view tried to read an absent paste service. After guarding that access, Privacy rendered with the same inert model as the other views. The images were inspected for visible content, framing, and fictional records. GitHub Markdown rendering preserved the six feature descriptions, both tables, and the image paths. The repo's installation directions were checked against the available development release assets.

This verifies the rendered views. Installed-app permissions, destination-app paste, cloud sync, signed sharing, and physical-device operation remain acceptance checks. [Acceptance report](../ACCEPTANCE.md)
