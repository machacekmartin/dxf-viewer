# DXF Viewer

Native macOS DXF viewer. SwiftUI + SwiftPM. No dependencies.

## Build

```sh
swift build -c release
.build/release/DXFViewer
```

Or run directly:

```sh
swift run
```

Requires macOS 13+ and Xcode command line tools (`xcode-select --install`).

## Controls

- **Import .dxf** button — pick a file
- Drag — pan
- Pinch / ⌘-scroll — zoom
- Scroll — pan

## Supported entities

LINE, CIRCLE, ARC, LWPOLYLINE, POLYLINE. ASCII DXF only.
