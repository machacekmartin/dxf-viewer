<img src="https://machacekmartin.github.io/dxf-viewer/hero.png" alt="DXF Viewer" width="100%">

## Features

- Eleven DXF entities — LINE, CIRCLE, ARC, POLYLINE, TEXT, ELLIPSE, SPLINE, HATCH, DIMENSION, LEADER, INSERT
- Per-layer visibility, recolor, and search
- Live scale bar in mm / cm / m
- Async parsing on a background thread
- Native SwiftUI on macOS 26 with Sparkle auto-updates

## Requirements

- macOS 26 or later
- Universal binary (Apple Silicon + Intel)

[**Get it on Gumroad**](https://machacekmartin.gumroad.com/l/dxf-viewer-macos) · [Free on GitHub Releases](https://github.com/machacekmartin/dxf-viewer/releases/latest) · [Website](https://machacekmartin.github.io/dxf-viewer/)

## First launch on macOS

On the first launch macOS Gatekeeper shows *"cannot be opened — unverified
developer"*. To allow it:

1. Open **System Settings → Privacy & Security**.
2. Scroll to the bottom and click **Open Anyway** next to *DXF Viewer*.
3. Confirm in the prompt that follows.

macOS remembers your choice — you only do this once per machine.

## Build

```sh
swift build -c release
```

Requires Swift 6.2.

## License

[GPL-3.0](LICENSE) © [Martin Machacek](https://github.com/machacekmartin)

Forks are welcome — they just have to stay open-source and GPL too.
