# Changelog

All notable changes to DXF Viewer are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning follows
[SemVer](https://semver.org/).

## [Unreleased]

## [1.1.2] - 2026-06-25

### Fixed
- Arrow-key navigation in the layer panel now scrolls the panel so the
  focused row stays visible.

## [1.1.1] - 2026-06-25

### Fixed
- Layer panel sidebar can now be scrolled. The canvas's scroll-wheel
  monitor was capturing every scroll event in the app, so the panel's
  scroll view never received any. It now only fires while the cursor
  is over the canvas.
- Zoom no longer gets stuck after aggressive trackpad or momentum
  scrolls. Per-event zoom step is now capped so a single big delta
  can't slam the scale into its clamp in one frame.

## [1.1.0] - 2026-06-23

### Changed
- App bundle renamed from `DXFViewer.app` to `DXF Viewer.app`. The
  Dock icon, menu bar, About dialog, and Finder all already showed
  "DXF Viewer" (via `CFBundleDisplayName`); this release brings the
  on-disk bundle name, the `CFBundleExecutable`, and Activity Monitor's
  process name into line.
- Sparkle handles the upgrade automatically — the new bundle replaces
  the old one at its original install location. **If you pinned the
  app to the Dock you'll need to re-pin it after the update**; the
  Dock shortcut points at the old filename.
- Source layout, SwiftPM target name, sandbox container ID
  (`com.machacekmartin.dxfviewer`), and DMG/ZIP asset filenames are
  intentionally unchanged.

### Licence
- Project relicensed from MIT to GPL-3.0-or-later. Forks are still
  welcome; they just have to stay open-source and GPL too.

## [1.0.2] - 2026-06-22

### Changed
- New app icon: 3D glass + dark-charcoal interlocking glyph replaces the
  procedural slate/grid placeholder. Source PNG lives at
  `tools/icon-source.png`; `tools/make-icon.sh` regenerates the iconset and
  `.icns` from it using stock macOS tools (sips + iconutil).

### Removed
- `tools/make-icon.swift` (procedural placeholder generator, superseded by
  the artwork-driven pipeline above).

## [1.0.1] - 2026-06-22

### Fixed
- HATCH entities with multiple boundary paths (e.g. frames with inner holes)
  no longer render as triangles. The parser was concatenating every boundary
  path's vertices into one polygon, drawing diagonal seams between paths.
  Each path is now its own closed sub-path with even-odd hole handling.
- Code-98 seed points were being captured as boundary vertices, polluting
  hatch outlines with stray points (e.g. floorplan.dxf hatch #145 had 10
  reported verts instead of the actual 8).
- Edge-defined HATCH boundaries (line/arc/ellipse/spline edges, code 92
  without the polyline bit) no longer cause the entity to be dropped
  entirely.

### Added
- HATCH pattern rendering: striped patterns like ANSI31 now draw their
  inline pattern lines (codes 53/43/44/45/46/79/49) by scanline-clipping
  each parallel line against the boundary polygon. Solid hatches (code
  70 = 1) fill with the entity color.

## [1.0.0] - 2026-06-22

### Added
- Native macOS DXF viewer (SwiftUI + Liquid Glass).
- Parses ASCII DXF: LINE, CIRCLE, ARC, LWPOLYLINE, POLYLINE, TEXT/MTEXT,
  ELLIPSE, SPLINE, HATCH, DIMENSION, LEADER, INSERT.
- Layer panel with per-layer visibility, color, and search.
- Scale indicator with dynamic units (mm / cm / m).
- Pan, pinch/⌘-scroll zoom, fit-to-view.
- Async parsing with progress indicator.
- Open via Import button, Finder double-click, drag-onto-Dock, or `--parse` CLI.
- File → Open Recent menu.
- VoiceOver labels.
- Crash diagnostics via MetricKit.
- Auto-update via Sparkle.
