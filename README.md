# DXF Viewer

A fast, native macOS viewer for AutoCAD DXF drawings.

Written in SwiftUI on top of AppKit, with Liquid Glass UI. No external
dependencies at the parser layer — the DXF parser is hand-rolled.

— by [Martin Machacek](mailto:machacekmartin@icloud.com)

## Download

- **Gumroad** *(primary)* — <https://machacekmartin.gumroad.com/l/dxf-viewer-macos>
- **GitHub Releases** *(free)* — <https://github.com/machacekmartin/dxf-viewer/releases>

Built-in auto-update via Sparkle keeps you on the latest version once
installed.

### First launch (important)

This build is **not** notarised by Apple, so macOS Gatekeeper will refuse
to open it the first time. To bypass:

1. Drag **DXF Viewer.app** into `/Applications`.
2. In Finder, **right-click** the app → **Open**.
3. Hit **Open** in the follow-up dialog.

After this one-time dance, double-click opens it normally forever.

If macOS shows *"App is damaged and can't be opened"*, run once in
Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/DXFViewer.app
```

## System requirements

- macOS 26 (Tahoe) or later — required for the Liquid Glass UI.
- Apple Silicon Mac. (macOS 26 dropped Intel Mac support at the OS level.)

## Features

- Renders ASCII DXF: LINE, CIRCLE, ARC, LWPOLYLINE, POLYLINE, TEXT/MTEXT,
  ELLIPSE, SPLINE, HATCH, DIMENSION, LEADER, INSERT.
- Layer panel with per-layer visibility, search, and per-layer colour.
- Live scale indicator that adapts to drawing units (mm / cm / m).
- Pan, pinch and ⌘-scroll zoom; drag onto the Dock icon to open.
- Finder integration: register as a `.dxf` opener; Open Recent menu.
- Fully keyboard-driven (⌘O open, ⌘+ ⌘- ⌘0 zoom, ⌘W close, ⌘Q quit).
- VoiceOver labels for accessibility.

## Build from source

```sh
git clone https://github.com/machacekmartin/dxf-viewer
cd dxf-viewer
swift run
```

To produce a redistributable `.app`:

```sh
bash scripts/build-app.sh
open dist/DXFViewer.app
```

To produce a DMG + ZIP for release:

```sh
bash scripts/release.sh
# → dist/DXFViewer-1.0.0.dmg   (ad-hoc signed, ready for Gumroad)
# → dist/DXFViewer-1.0.0.zip   (ad-hoc signed, for Sparkle / GitHub Releases)
```

See [`docs/PUBLISHING.md`](docs/PUBLISHING.md) for the full release runbook
(Sparkle keys, Gumroad upload, GitHub Pages appcast).

## Project layout

```
Sources/DXFViewer/
    App.swift              # SwiftUI App + AppDelegate, menus, --parse CLI
    ContentView.swift      # Top-level UI
    DXFCanvas.swift        # Pan/zoom canvas, drawing pipeline
    DXFParser.swift        # ASCII DXF parser
    DXFRenderModel.swift   # Pre-computed CGPath bulks per layer
    DXFEntity.swift        # Entity enum
    LayerPanel.swift       # Layer sidebar
    ScaleIndicator.swift   # Bottom-right metric ruler
    GlassEffects.swift     # Reusable Liquid Glass modifiers
    OpenCoordinator.swift  # File-open intent funnel + recents
    CrashLogger.swift      # MetricKit diagnostic sink
    Updater.swift          # Sparkle facade
Resources/
    Info.plist             # Bundle metadata + Sparkle keys + UTI
    DXFViewer.entitlements # Sandbox + hardened runtime
    AppIcon.icns           # Built from tools/make-icon.swift
    Credits.rtf            # About-panel credits
scripts/
    build-app.sh           # Build .app bundle
    release.sh             # Build → sign → notarize → DMG
tools/
    make-icon.swift        # Re-generate placeholder app icon
    validate.py            # Cross-check parser against ezdxf
    ezdxf_ref.py
.github/workflows/
    ci.yml                 # PR / push CI
    release.yml            # Tag-driven release pipeline
appcast.xml                # Sparkle update feed
docs/PUBLISHING.md         # Release runbook
```

## License

MIT — see [LICENSE](LICENSE).

## Privacy

DXF Viewer is local-only. No telemetry, no analytics. See [PRIVACY.md](PRIVACY.md).

## Contact

Martin Machacek — <machacekmartin@icloud.com>
