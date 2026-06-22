# Changelog

All notable changes to DXF Viewer are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning follows
[SemVer](https://semver.org/).

## [Unreleased]

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
