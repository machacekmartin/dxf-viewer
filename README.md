![DXF Viewer](https://machacekmartin.github.io/dxf-viewer/hero.png)

# DXF Viewer

A native macOS reader for AutoCAD DXF drawings. Fast, free, and quiet.

[**Get it on Gumroad**](https://machacekmartin.gumroad.com/l/dxf-viewer-macos) · [Free on GitHub Releases](https://github.com/machacekmartin/dxf-viewer/releases/latest) · [Website](https://machacekmartin.github.io/dxf-viewer/)

![DXF Viewer showing floorplan.dxf with the layers sidebar](https://machacekmartin.github.io/dxf-viewer/preview.png)

## Features

- **Eleven DXF entities, decoded.** LINE, CIRCLE, ARC, POLYLINE, TEXT, ELLIPSE, SPLINE, HATCH, DIMENSION, LEADER, INSERT. Hatches keep their patterns; polygons keep their holes.
- **Layers in their place.** Toggle visibility, recolor, search by name.
- **Scale that means something.** Live scale bar in millimetres, centimetres, or metres. Pinch or `⌘`-scroll to zoom. Press `F` to fit.
- **Async parsing.** A 30-MB drawing parses on a background thread; the UI stays responsive.
- **Native, end to end.** SwiftUI and Liquid Glass on macOS 26. Finder double-click, drag-onto-Dock, Open Recent, VoiceOver.
- **Quiet auto-updates.** Sparkle, EdDSA-signed, no telemetry, no account.

## Requirements

- macOS 26 or later
- Universal binary (Apple Silicon + Intel)
- ~2.6 MB

## Install

**Gumroad** — pay what feels right, even nothing:
<https://machacekmartin.gumroad.com/l/dxf-viewer-macos>

**GitHub Releases** — the same DMG, no checkout:
<https://github.com/machacekmartin/dxf-viewer/releases/latest>

Both builds are ad-hoc signed. On first launch, right-click → Open to bypass Gatekeeper.

## Build from source

```sh
git clone https://github.com/machacekmartin/dxf-viewer.git
cd dxf-viewer
bash scripts/release.sh           # produces dist/DXFViewer-x.y.z.{dmg,zip}
# or
swift build -c release            # CLI binary at .build/release/DXFViewer
```

Requires Swift 6.2 and macOS 26 SDK.

## Releases

See [`CHANGELOG.md`](CHANGELOG.md) for version history. The Sparkle update feed lives at <https://machacekmartin.github.io/dxf-viewer/appcast.xml> and is consumed automatically by the running app.

Release runbook for maintainers: [`docs/RELEASE.md`](docs/RELEASE.md).

## License

[MIT](LICENSE) © 2026 [Martin Machacek](https://github.com/machacekmartin)
