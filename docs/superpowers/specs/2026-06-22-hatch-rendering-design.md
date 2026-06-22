# HATCH Rendering — Multi-Boundary + Pattern Stripes

Date: 2026-06-22
Scope: B (boundaries + inline pattern lines). Solid fill bundled (≈5 LOC).
Out of scope: edge-defined boundaries (code 92 without polyline bit), `acad.pat` external pattern library, screen-space density culling.

## Problem

`examples/floorplan.dxf` HATCH #145 (layer `A-DIMS-1`, pattern `ANSI31`) renders as triangles instead of diagonal stripes.

Two root-cause bugs:

1. **Multi-path concatenation.** `DXFParser.swift:323-330` flips `hatchInBoundary=true` on the first code 92 and never resets between paths. All `10/20` from every boundary path are appended to a single `hatchVerts` array. The renderer (`DXFRenderModel.swift:156-163`) closes that as one polygon — connecting the last vertex of path 1 to the first of path 2 with a diagonal. The two diagonals plus closing line produce the triangle silhouette.
2. **Seed-point slurping.** Code 98 (seed point count) is followed by code-10/20 pairs. `hatchInBoundary` is still `true` → those seed points are appended as boundary vertices. Matches the user-reported "10 boundary points" (4 + 4 + 2).
3. **No pattern fill, by design.** `DXFParser.swift:84` comment: "HATCH outline only". Stripes are never drawn even when boundaries are correct.

## Data model

Replace `case hatch([CGPoint])` in `DXFEntity.Kind` with structured data:

```swift
struct HatchBoundary { var verts: [CGPoint]; var closed: Bool }
struct HatchPatternLine {
    var angleDeg: CGFloat        // pattern-line angle + entity angle (codes 53 + 52)
    var basePoint: CGPoint       // codes 43/44, scaled
    var offset: CGPoint          // codes 45/46, scaled (perpendicular delta between parallels)
    var dashes: [CGFloat]        // code 49 repeats (empty = solid line)
}
struct HatchData {
    var boundaries: [HatchBoundary]
    var isSolid: Bool            // code 70
    var pattern: [HatchPatternLine]   // empty → outline-only fallback
    var patternScale: CGFloat    // code 41
    var patternAngle: CGFloat    // code 52
}
case hatch(HatchData)
```

Bounds extension (`DXFParser.swift:704`) uses only boundary vertices.

## Parser changes (`DXFParser.swift`)

State variables (replace `hatchVerts`, `hatchLastVertex`, `hatchInBoundary`):

```swift
var hatchPaths: [HatchBoundary] = []
var hatchCurrent: [CGPoint] = []
var hatchVertsLeft: Int = 0          // remaining code-10/20 to read for current path (from code 93)
var hatchInSeed: Bool = false        // suppresses 10/20 collection after code 98
var hatchPattern: [HatchPatternLine] = []
var hatchPendingLine: HatchPatternLine? = nil
var hatchSolid: Bool = false
var hatchScale: CGFloat = 1
var hatchEntityAngle: CGFloat = 0
var hatchLastX: CGFloat? = nil       // for 43/44 and 45/46 pair tracking
```

Group-code dispatch inside `current == "HATCH"`:

| Code | Action |
|------|--------|
| 70   | `hatchSolid = (Int(value) ?? 0) != 0` |
| 52   | `hatchEntityAngle = CGFloat(Double(value) ?? 0)` |
| 41   | `hatchScale = CGFloat(Double(value) ?? 1)` |
| 91   | (optional sanity, unused — paths are detected by 92) |
| 92   | flush `hatchCurrent` into `hatchPaths` if non-empty; reset `hatchCurrent`, `hatchVertsLeft=0`, `hatchInSeed=false` |
| 93   | `hatchVertsLeft = Int(value) ?? 0` |
| 10   | if `hatchInSeed` → discard; else if `hatchVertsLeft > 0` → stash x; else if `hatchPendingLine != nil` → start 43/45-style x (see pattern table) |
| 20   | mirror of 10 for y; on complete pair within boundary path, append to `hatchCurrent` and decrement `hatchVertsLeft` |
| 97   | source-boundary-object count — ignore (skip subsequent 330 codes) |
| 78   | pattern line count (informational) |
| 53   | flush `hatchPendingLine` if set; start new line with angle = value + entity angle |
| 43/44 | base point x/y (pattern coords) into `hatchPendingLine` |
| 45/46 | offset x/y into `hatchPendingLine` |
| 79   | dash count for current pattern line |
| 49   | append dash length to `hatchPendingLine.dashes` |
| 98   | seed point count → `hatchInSeed = true` (suppresses 10/20 from here to entity end) |

On `case "HATCH":` emit:
- flush trailing `hatchCurrent` into `hatchPaths` if non-empty
- flush `hatchPendingLine`
- build `HatchData`, multiply pattern base/offset by `hatchScale` and rotate by `hatchEntityAngle`
- skip entity if `hatchPaths` empty

INSERT path expansion (`DXFParser.swift:625`): map each boundary's verts through `tx`, leave pattern data unchanged (already in world units post-scale).

## Render-model changes (`DXFRenderModel.swift`)

Inside `case .hatch(let h):`

1. **Build even-odd boundary path:**
   ```swift
   let bp = CGMutablePath()
   for b in h.boundaries where b.verts.count >= 2 {
       bp.move(to: b.verts[0])
       for v in b.verts.dropFirst() { bp.addLine(to: v) }
       bp.closeSubpath()
   }
   ```
2. **Outline strokes** — add `bp` to `stroke[e.aci]` (each sub-path strokes independently in CG).
3. **Solid fill** — if `h.isSolid`: add `bp` to a new `fill[aci]` per-color path (introduce a `fill` map alongside `stroke`).
4. **Pattern fill** — else if `!h.pattern.isEmpty`:
   - Compute boundary AABB.
   - For each `HatchPatternLine pl`:
     - `dir = (cos pl.angleDeg, sin pl.angleDeg)`
     - `perp = (-dir.y, dir.x)`
     - perpendicular spacing `s = |pl.offset · perp|`; skip if `s < 1e-6`
     - project each AABB corner onto `perp` to get index range `[i_min, i_max]`
     - for `i` in that range: line origin `o = pl.basePoint + i * pl.offset` (mod offset along dir is irrelevant), endpoints `o ± diag*dir` where `diag = AABB diagonal length`
     - scanline-clip against all boundary edges: collect intersection `t` values, sort, pair even-odd, emit each inside segment as a sub-path on `stroke[e.aci]`
     - if `pl.dashes` non-empty: subdivide each inside segment by dash lengths (positive = stroke, negative = gap, zero = dot)
   - Record one `RenderEntry` per hatch entity referencing `bp` (or empty `stroke`) so `LayerPanel` still selects/highlights correctly.

Pre-baked at build time — mirrors spline tessellation pattern at `DXFRenderModel.swift:144-154`. Canvas draws as today.

## Edge cases

- Boundary with <2 verts → skip path.
- Zero boundaries → skip entity entirely.
- Pattern parse failure (no 53/45/46) → keep boundaries, drop pattern (outline only).
- `isSolid && pattern.notEmpty` → solid wins (matches AutoCAD).
- Pattern spacing degenerate (parallel-line offset = 0) → drop that line.

## Test

`tools/test-hatch.swift` — standalone `swift run` script (no XCTest dependency). Embed HATCH #145 group codes as a fixture string, feed to a re-exported parse function, assert:

- `boundaries.count == 2`
- each boundary has 4 verts
- `pattern.count == 1`
- `abs(pattern[0].angleDeg - 135) < 1e-6`
- `patternScale == 3.0`
- `isSolid == false`

Run via `swift tools/test-hatch.swift`. One assert per claim. Fails loud on regression.

## Performance notes

- Pattern-line generation is O(boundary_edges × pattern_lines_in_range) per hatch, run **once** at parse time.
- Floorplan has 29 hatches; with scale 3 and typical AABB ~50×50 mm, ANSI31 produces ~150 stripes per hatch. Total ~4500 line segments. Negligible vs the rest of the document.
- Density culling at render-time: deferred. `// ponytail: world-space stripes only, add screen-density cull when shimmer reported.`

## Files touched

- `Sources/DXFViewer/DXFEntity.swift` — replace `hatch` enum case with structured data
- `Sources/DXFViewer/DXFParser.swift` — state machine for boundary + pattern parsing
- `Sources/DXFViewer/DXFRenderModel.swift` — boundary CGPath build, pattern line tessellation, optional solid fill map
- `Sources/DXFViewer/LayerPanel.swift` — update `.hatch` case (uses verts only; switch to `boundaries.flatMap`)
- `Sources/DXFViewer/App.swift` — no change beyond `kind` name match
- `tools/test-hatch.swift` — new self-check
