import Foundation
import CoreGraphics

// Precomputed render bundle: every spline/ellipse already tessellated, every entity baked
// into a CGPath in WORLD coords. The canvas multiplies by a single CGAffineTransform per
// frame instead of re-tessellating + retransforming N entities on every pan/zoom.
//
// `bulkStroke` / `bulkFill` are one merged path per aci — the no-selection hot path
// strokes one CGPath per color and exits. `entries` keeps per-entity geometry for the
// selection-active path (dim / normal / selected bucketing).
// `@unchecked Sendable` invariant: CGPath instances stored inside an entry/bulk dict
// are constructed during `build(from:)` and never mutated afterwards. The struct
// itself is `let`-only. Safe to pass across actor boundaries after construction.
public struct DXFRenderModel: @unchecked Sendable {
    public struct Entry {
        public let index: Int      // index into DXFDocument.entities (or parent for DIM children)
        public let aci: Int
        public let layer: String
        public let kindName: String
        public let lineWeight: Int // hundredths of mm; resolved.
        public let geometry: Geometry
    }
    public enum Geometry {
        case stroke(CGPath)
        case fill(CGPath)
        // Wide stroke: centerline path + world-units width. Renderer strokes at
        // max(worldWidth × zoom, minPx) so the band stays visible at any zoom.
        case wideStroke(CGPath, CGFloat)
        // Text needs per-entity transform + measurement, so we keep it parameterized.
        case text(TextSpec)
    }
    public struct TextSpec {
        public let pos: CGPoint
        public let str: String
        public let height: CGFloat
        public let rotDeg: CGFloat
        public let hAlign: Int
        public let vAlign: Int
        public let wrapWidth: CGFloat
        public let lineSpacing: CGFloat
    }
    // Stroke bucket key: same color + same weight share one CGPath so a typical file
    // (≤3 weights × ≤8 colors) draws in O(colors × weights), not O(entities).
    public struct StrokeBucket: Hashable, Sendable {
        public let aci: Int
        public let lineWeight: Int
        public init(aci: Int, lineWeight: Int) { self.aci = aci; self.lineWeight = lineWeight }
    }

    // Bucket for constant-width LWPOLYLINEs. Key = (color, world-units width).
    // Rounded to 1e-3 mm so floating-point jitter doesn't fracture the bucket.
    public struct WideStrokeBucket: Hashable, Sendable {
        public let aci: Int
        public let worldWidth: CGFloat
        public init(aci: Int, worldWidth: CGFloat) {
            self.aci = aci
            self.worldWidth = (worldWidth * 1000).rounded() / 1000
        }
    }

    public let entries: [Entry]
    // Merged stroke paths in WORLD coords, keyed by (aci, weight). Drawn once per
    // bucket when the selection is empty. Fill has no width → keyed by aci alone.
    public let bulkStroke: [StrokeBucket: CGPath]
    public let bulkFill: [Int: CGPath]
    public let bulkWideStroke: [WideStrokeBucket: CGPath]
}

extension DXFRenderModel {
    public static func build(from doc: DXFDocument) -> DXFRenderModel {
        var entries: [Entry] = []
        entries.reserveCapacity(doc.entities.count)

        let strokeAcc = StrokePathDict()
        let fillAcc = FillPathDict()
        let wideStrokeAcc = WideStrokePathDict()

        for i in doc.entities.indices {
            let e = doc.entities[i]
            // DIMENSION wrappers: flatten so each child still draws, but selection routes
            // back to the wrapper's index — selecting the dim highlights all parts.
            if case .dimension(let children) = e.kind {
                for c in children {
                    let proxy = DXFEntity(kind: c.kind, aci: e.aci, layer: e.layer, lineWeight: e.lineWeight)
                    appendEntity(proxy, parentIndex: i, into: &entries,
                                 stroke: strokeAcc, fill: fillAcc, wideStroke: wideStrokeAcc)
                }
            } else {
                appendEntity(e, parentIndex: i, into: &entries,
                             stroke: strokeAcc, fill: fillAcc, wideStroke: wideStrokeAcc)
            }
        }

        return DXFRenderModel(
            entries: entries,
            bulkStroke: strokeAcc.frozen(),
            bulkFill: fillAcc.frozen(),
            bulkWideStroke: wideStrokeAcc.frozen())
    }

    private static func appendEntity(
        _ e: DXFEntity,
        parentIndex: Int,
        into entries: inout [Entry],
        stroke: StrokePathDict,
        fill: FillPathDict,
        wideStroke: WideStrokePathDict
    ) {
        let name = e.kind.typeName
        let strokeKey = StrokeBucket(aci: e.aci, lineWeight: e.lineWeight)
        func makeEntry(_ g: Geometry) -> Entry {
            .init(index: parentIndex, aci: e.aci, layer: e.layer, kindName: name, lineWeight: e.lineWeight, geometry: g)
        }
        switch e.kind {
        case .line(let a, let b):
            let p = CGMutablePath()
            p.move(to: a); p.addLine(to: b)
            entries.append(makeEntry(.stroke(p)))
            stroke[strokeKey].addPath(p)

        case .point(let pt):
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: pt.x - 1.5, y: pt.y - 1.5, width: 3, height: 3))
            entries.append(makeEntry(.fill(p)))
            fill[e.aci].addPath(p)

        case .circle(let c, let r):
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            entries.append(makeEntry(.stroke(p)))
            stroke[strokeKey].addPath(p)

        case .arc(let c, let r, let start, let end):
            // DXF: angles CCW degrees, math convention. We render with Y flipped, so the
            // CGPath stays in world coords here and the transform handles the flip.
            let p = CGMutablePath()
            let startRad = Double(start) * .pi / 180
            let startPt = CGPoint(x: c.x + r * CGFloat(cos(startRad)), y: c.y + r * CGFloat(sin(startRad)))
            p.move(to: startPt)
            p.addArc(
                center: c,
                radius: r,
                startAngle: Double(start) * .pi / 180,
                endAngle: Double(end) * .pi / 180,
                clockwise: false)
            entries.append(makeEntry(.stroke(p)))
            stroke[strokeKey].addPath(p)

        case .polyline(let pts, let closed):
            guard let first = pts.first else { break }
            let p = CGMutablePath()
            p.move(to: first)
            for pt in pts.dropFirst() { p.addLine(to: pt) }
            if closed { p.addLine(to: first) }
            entries.append(makeEntry(.stroke(p)))
            stroke[strokeKey].addPath(p)

        case .solid(let pts):
            guard let first = pts.first else { break }
            let p = CGMutablePath()
            p.move(to: first)
            for pt in pts.dropFirst() { p.addLine(to: pt) }
            p.closeSubpath()
            entries.append(makeEntry(.fill(p)))
            fill[e.aci].addPath(p)

        case .widePolyline(let verts, let closed):
            // Constant-width: stroke the centerline at world width, clamped to a
            // visible-pixel minimum at render time. Joins / caps from CGContext.
            // Tapered: fall back to filled trapezoid band (current behavior).
            if let constantW = constantWidth(of: verts) {
                let center = centerlinePath(verts: verts, closed: closed)
                entries.append(makeEntry(.wideStroke(center, constantW)))
                let key = WideStrokeBucket(aci: e.aci, worldWidth: constantW)
                wideStroke[key].addPath(center)
            } else {
                let p = widePolylinePath(verts: verts, closed: closed)
                entries.append(makeEntry(.fill(p)))
                fill[e.aci].addPath(p)
            }

        case .ellipse(let c, let mv, let ratio, let sa, let ea):
            let minorVec = CGPoint(x: -mv.y * ratio, y: mv.x * ratio)
            var sweep = ea - sa
            if sweep <= 0 { sweep += 2 * .pi }
            let steps = 64
            let p = CGMutablePath()
            for k in 0...steps {
                let t = sa + sweep * CGFloat(k) / CGFloat(steps)
                let pt = CGPoint(
                    x: c.x + mv.x * cos(t) + minorVec.x * sin(t),
                    y: c.y + mv.y * cos(t) + minorVec.y * sin(t))
                if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            entries.append(makeEntry(.stroke(p)))
            stroke[strokeKey].addPath(p)

        case .spline(let cps, let deg, let knots, let closed):
            // Pre-tessellate once at build time; the canvas no longer re-runs deBoor
            // every frame.
            let curve = tessellateSpline(controlPoints: cps, knots: knots, degree: deg)
            guard let first = curve.first else { break }
            let p = CGMutablePath()
            p.move(to: first)
            for pt in curve.dropFirst() { p.addLine(to: pt) }
            if closed { p.addLine(to: first) }
            entries.append(makeEntry(.stroke(p)))
            stroke[strokeKey].addPath(p)

        case .hatch(let h):
            // 1) Even-odd boundary path — one closed sub-path per HATCH boundary.
            //    Multiple sub-paths automatically punch holes when CG fills with even-odd.
            let bp = CGMutablePath()
            for b in h.boundaries where b.verts.count >= 2 {
                bp.move(to: b.verts[0])
                for v in b.verts.dropFirst() { bp.addLine(to: v) }
                bp.closeSubpath()
            }
            // No boundaries → emit a placeholder empty stroke entry so indexing stays aligned.
            guard !bp.isEmpty else {
                entries.append(makeEntry(.stroke(CGMutablePath())))
                break
            }

            // 2) Outline every boundary independently (the old code joined them — that's
            //    where the triangles came from). Always emit the outline so even pattern
            //    hatches show a visible silhouette.
            stroke[strokeKey].addPath(bp)

            // 3) Fill. Solid → flat ACI fill. Pattern → scanline-clip parallel lines.
            if h.isSolid {
                fill[e.aci].addPath(bp)
                entries.append(makeEntry(.fill(bp)))
            } else if !h.pattern.isEmpty {
                let stripes = tessellateHatchPattern(boundaries: h.boundaries, pattern: h.pattern)
                stroke[strokeKey].addPath(stripes)
                // Record the stripes as the per-entity geometry so selection/highlight hits them.
                entries.append(makeEntry(.stroke(stripes)))
            } else {
                // Outline-only fallback (pattern parse failed or genuinely no pattern data).
                entries.append(makeEntry(.stroke(bp)))
            }

        case .leader(let pts, let arrow):
            guard let first = pts.first else { break }
            let path = CGMutablePath()
            path.move(to: first)
            for pt in pts.dropFirst() { path.addLine(to: pt) }
            entries.append(makeEntry(.stroke(path)))
            stroke[strokeKey].addPath(path)
            if pts.count >= 2 {
                let a = pts[0], b = pts[1]
                let dx = b.x - a.x, dy = b.y - a.y
                let len = hypot(dx, dy)
                if len > 1e-6 {
                    let ux = dx / len, uy = dy / len
                    let nx = -uy, ny = ux
                    let backCenter = CGPoint(x: a.x + ux * arrow, y: a.y + uy * arrow)
                    let w = arrow * 0.4
                    let p1 = CGPoint(x: backCenter.x + nx * w, y: backCenter.y + ny * w)
                    let p2 = CGPoint(x: backCenter.x - nx * w, y: backCenter.y - ny * w)
                    let fp = CGMutablePath()
                    fp.move(to: a); fp.addLine(to: p1); fp.addLine(to: p2); fp.closeSubpath()
                    entries.append(makeEntry(.fill(fp)))
                    fill[e.aci].addPath(fp)
                }
            }

        case .text(let pt, let s, let h, let rot, let hAlign, let vAlign, let wrapW, let ls):
            let spec = TextSpec(pos: pt, str: s, height: h, rotDeg: rot,
                                hAlign: hAlign, vAlign: vAlign, wrapWidth: wrapW, lineSpacing: ls)
            entries.append(makeEntry(.text(spec)))

        case .dimension, .insert: break
        }
    }
}

// MARK: - Wide polyline classification + centerline

// Returns the uniform width if every vertex's start/end widths are equal and > 0.
// Otherwise nil → caller falls back to tapered trapezoid rendering.
public func constantWidth(of verts: [WidePolylineVertex]) -> CGFloat? {
    guard let first = verts.first else { return nil }
    let w = first.startWidth
    guard w > 0 else { return nil }
    let eps: CGFloat = 1e-6
    for v in verts {
        if abs(v.startWidth - w) > eps || abs(v.endWidth - w) > eps { return nil }
    }
    return w
}

// Build the centerline CGPath of a (constant-width) widePolyline. Bulges tessellate
// into chords. Closed polylines close the subpath so CGContext can mitre the join.
public func centerlinePath(verts: [WidePolylineVertex], closed: Bool) -> CGPath {
    let out = CGMutablePath()
    guard let first = verts.first else { return out }
    out.move(to: first.point)
    let segCount = closed ? verts.count : verts.count - 1
    for i in 0..<segCount {
        let a = verts[i]
        let b = verts[(i + 1) % verts.count]
        if abs(a.bulge) > 1e-9 {
            for mid in tessellateBulge(a.point, b.point, bulge: a.bulge, steps: 24) {
                out.addLine(to: mid)
            }
        }
        out.addLine(to: b.point)
    }
    if closed { out.closeSubpath() }
    return out
}

// MARK: - Wide polyline → trapezoid band (tapered fallback only)

// Build a single closed CGPath for a wide polyline. Every segment becomes ONE
// quadrilateral (a/b ± perpendicular × halfWidth). Bulge segments are tessellated
// into N small chords; widths interpolate linearly across the arc.
//
// Junctions: butt caps (each segment is an independent closed sub-path). For
// constant-width polylines, neighbouring quads overlap exactly at the shared vertex
// so the join is invisible. For tapered widths the misalignment is on the order of
// width-delta × small angle — acceptable for a viewer; AutoCAD's mitred join can
// be added later if needed.
//   // ponytail: butt caps now; mitre join only if a real file shows visible gaps.
public func widePolylinePath(verts: [WidePolylineVertex], closed: Bool) -> CGPath {
    let out = CGMutablePath()
    guard verts.count >= 2 else { return out }
    let segCount = closed ? verts.count : verts.count - 1
    for i in 0..<segCount {
        let a = verts[i]
        let b = verts[(i + 1) % verts.count]
        let endWidth = a.endWidth        // width at a looking → next
        let startWidth = b.startWidth    // width at next looking ← previous
        // Pick the larger end of each pair so a vertex shared by two segments uses
        // the same width (avoids gap when widths agree on both sides).
        let wa = max(a.startWidth, endWidth)
        let wb = max(startWidth, b.endWidth)
        if abs(a.bulge) > 1e-9 {
            // Tessellate the arc and stitch widths linearly across the tessellation.
            let mid = tessellateBulge(a.point, b.point, bulge: a.bulge, steps: 24)
            var chain: [CGPoint] = [a.point]
            chain.append(contentsOf: mid)
            chain.append(b.point)
            appendWideBand(into: out, chain: chain, startWidth: wa, endWidth: wb)
        } else {
            appendWideQuad(into: out, a: a.point, b: b.point, wa: wa, wb: wb)
        }
    }
    return out
}

private func appendWideQuad(into out: CGMutablePath, a: CGPoint, b: CGPoint, wa: CGFloat, wb: CGFloat) {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = hypot(dx, dy)
    guard len > 1e-9 else { return }
    let nx = -dy / len, ny = dx / len
    let hA = wa / 2, hB = wb / 2
    out.move(to: CGPoint(x: a.x + nx * hA, y: a.y + ny * hA))
    out.addLine(to: CGPoint(x: b.x + nx * hB, y: b.y + ny * hB))
    out.addLine(to: CGPoint(x: b.x - nx * hB, y: b.y - ny * hB))
    out.addLine(to: CGPoint(x: a.x - nx * hA, y: a.y - ny * hA))
    out.closeSubpath()
}

private func appendWideBand(into out: CGMutablePath, chain: [CGPoint], startWidth: CGFloat, endWidth: CGFloat) {
    guard chain.count >= 2 else { return }
    // Per-vertex offsets along the average normal of incident segments. Linear t
    // along chain length for width interpolation.
    var lengths: [CGFloat] = [0]
    var total: CGFloat = 0
    for i in 1..<chain.count {
        total += hypot(chain[i].x - chain[i - 1].x, chain[i].y - chain[i - 1].y)
        lengths.append(total)
    }
    guard total > 1e-9 else { return }
    var left: [CGPoint] = []
    var right: [CGPoint] = []
    for i in chain.indices {
        let t = lengths[i] / total
        let w = startWidth + (endWidth - startWidth) * t
        let h = w / 2
        // Average normal of incident segments (or single normal at endpoints).
        var nx: CGFloat = 0, ny: CGFloat = 0
        if i > 0 {
            let dx = chain[i].x - chain[i - 1].x, dy = chain[i].y - chain[i - 1].y
            let l = hypot(dx, dy)
            if l > 1e-9 { nx += -dy / l; ny += dx / l }
        }
        if i < chain.count - 1 {
            let dx = chain[i + 1].x - chain[i].x, dy = chain[i + 1].y - chain[i].y
            let l = hypot(dx, dy)
            if l > 1e-9 { nx += -dy / l; ny += dx / l }
        }
        let l = hypot(nx, ny)
        if l > 1e-9 { nx /= l; ny /= l }
        left.append(CGPoint(x: chain[i].x + nx * h, y: chain[i].y + ny * h))
        right.append(CGPoint(x: chain[i].x - nx * h, y: chain[i].y - ny * h))
    }
    out.move(to: left[0])
    for i in 1..<left.count { out.addLine(to: left[i]) }
    for i in stride(from: right.count - 1, through: 0, by: -1) { out.addLine(to: right[i]) }
    out.closeSubpath()
}

// MARK: - Hatch pattern tessellation
//
// Builds a CGPath of stripe segments for a HATCH entity. For every pattern line:
//   1. Project all boundary vertices onto the line's perpendicular axis to find the
//      range of parallel-line indices that could intersect the boundary.
//   2. For each index k, intersect the infinite line `base + k*offset + t*dir` with
//      every boundary edge, collect t-values, sort, and pair them via the even-odd
//      rule. Each pair is one inside segment.
//   3. Optionally subdivide each inside segment by the pattern's dash list.
//
// World-space: stripes are baked at DXF scale once at build time. Density culling on
// zoom is deferred (see spec).
//   // ponytail: world-space stripes only; add screen-density cull when shimmer reported.
public func tessellateHatchPattern(boundaries: [HatchBoundary], pattern: [HatchPatternLine]) -> CGPath {
    let out = CGMutablePath()
    // Pre-extract every boundary edge as (a, b) pairs.
    var edges: [(CGPoint, CGPoint)] = []
    edges.reserveCapacity(boundaries.reduce(0) { $0 + $1.verts.count })
    for b in boundaries where b.verts.count >= 2 {
        for i in 0..<b.verts.count - 1 {
            edges.append((b.verts[i], b.verts[i + 1]))
        }
        // Close polygon.
        edges.append((b.verts.last!, b.verts[0]))
    }
    guard !edges.isEmpty else { return out }

    for pl in pattern {
        let rad = Double(pl.angleDeg) * .pi / 180
        let dx = CGFloat(cos(rad)), dy = CGFloat(sin(rad))
        // Perpendicular axis (left-hand normal to dir).
        let nx = -dy, ny = dx

        // Perpendicular spacing between successive parallel lines = signed projection of
        // offset onto perp. Use absolute value for the iteration step.
        let sSigned = pl.offset.x * nx + pl.offset.y * ny
        let s = abs(sSigned)
        if s < 1e-9 { continue }

        // Boundary vertex perpendicular-coord range.
        var dMin = CGFloat.infinity, dMax = -CGFloat.infinity
        for b in boundaries {
            for v in b.verts {
                let d = v.x * nx + v.y * ny
                if d < dMin { dMin = d }
                if d > dMax { dMax = d }
            }
        }
        if !dMin.isFinite { continue }

        let d0 = pl.basePoint.x * nx + pl.basePoint.y * ny
        // Stripe k lies at perp coord d0 + k * sSigned. We want all stripes whose perp
        // coord falls in [dMin, dMax]. Iterate over absolute spacing s; sign of sSigned
        // just flips direction (same stripe family).
        let step = sSigned >= 0 ? sSigned : -sSigned
        // Convert k indices using abs(step). k_min = ceil((dMin - d0) / step) and likewise.
        let kMin = Int(((dMin - d0) / step).rounded(.down)) - 1
        let kMax = Int(((dMax - d0) / step).rounded(.up)) + 1

        // Total dash period for dashed lines (0 → solid line, no subdivision).
        var dashPeriod: CGFloat = 0
        for d in pl.dashes { dashPeriod += abs(d) }

        for k in kMin...kMax {
            // Origin point on line k.
            let perpOffset = CGFloat(k) * step
            let qx = pl.basePoint.x + nx * perpOffset
            let qy = pl.basePoint.y + ny * perpOffset

            // Intersect with every boundary edge.
            var ts: [CGFloat] = []
            ts.reserveCapacity(edges.count)
            for (a, b) in edges {
                let ex = b.x - a.x, ey = b.y - a.y
                let det = ex * dy - dx * ey
                if abs(det) < 1e-12 { continue }
                let rx = a.x - qx, ry = a.y - qy
                // t = (-ey * rx + ex * ry) / det ; u = (dx * ry - dy * rx) / det
                let t = (-ey * rx + ex * ry) / det
                let u = (dx * ry - dy * rx) / det
                // Half-open interval avoids double-counting at shared vertex (edge end
                // = next edge start). Otherwise even-odd pairing flips wrong.
                if u >= 0 && u < 1 { ts.append(t) }
            }
            if ts.count < 2 { continue }
            ts.sort()

            // Pair via even-odd. Each (ts[2i], ts[2i+1]) = inside segment.
            var i = 0
            while i + 1 < ts.count {
                let t0 = ts[i], t1 = ts[i + 1]
                if t1 - t0 > 1e-9 {
                    if dashPeriod > 1e-9 && !pl.dashes.isEmpty {
                        emitDashedSegment(into: out, qx: qx, qy: qy, dx: dx, dy: dy,
                                          t0: t0, t1: t1, dashes: pl.dashes, period: dashPeriod)
                    } else {
                        out.move(to: CGPoint(x: qx + dx * t0, y: qy + dy * t0))
                        out.addLine(to: CGPoint(x: qx + dx * t1, y: qy + dy * t1))
                    }
                }
                i += 2
            }
        }
    }
    return out
}

private func emitDashedSegment(
    into path: CGMutablePath,
    qx: CGFloat, qy: CGFloat,
    dx: CGFloat, dy: CGFloat,
    t0: CGFloat, t1: CGFloat,
    dashes: [CGFloat], period: CGFloat
) {
    // DXF dash list: positive = dash (drawn), negative = gap, zero = dot (drawn 0.1*period).
    // Phase t0 inside the pattern so each stripe family is consistent across stripes.
    var t = t0
    // Step t forward to align with the dash pattern phase relative to origin.
    let phase = t0.truncatingRemainder(dividingBy: period)
    var skip = phase < 0 ? phase + period : phase
    var idx = 0
    while skip > 0 && idx < dashes.count {
        let dlen = dashes[idx] == 0 ? period * 0.1 : abs(dashes[idx])
        if skip < dlen {
            let drawSeg = dashes[idx] > 0 || dashes[idx] == 0
            let seg = min(dlen - skip, t1 - t)
            if drawSeg && seg > 1e-9 {
                path.move(to: CGPoint(x: qx + dx * t, y: qy + dy * t))
                path.addLine(to: CGPoint(x: qx + dx * (t + seg), y: qy + dy * (t + seg)))
            }
            t += seg
            skip = 0
            idx = (idx + 1) % dashes.count
        } else {
            skip -= dlen
            idx = (idx + 1) % dashes.count
        }
    }
    while t < t1 {
        let raw = dashes[idx]
        let dlen = raw == 0 ? period * 0.1 : abs(raw)
        let seg = min(dlen, t1 - t)
        if raw >= 0 && seg > 1e-9 {
            path.move(to: CGPoint(x: qx + dx * t, y: qy + dy * t))
            path.addLine(to: CGPoint(x: qx + dx * (t + seg), y: qy + dy * (t + seg)))
        }
        t += seg
        idx = (idx + 1) % dashes.count
    }
}

// Reference wrappers so loops can `addPath` into the same instance without COW surprises.
private final class StrokePathDict {
    private var paths: [DXFRenderModel.StrokeBucket: CGMutablePath] = [:]
    subscript(key: DXFRenderModel.StrokeBucket) -> CGMutablePath {
        if let p = paths[key] { return p }
        let p = CGMutablePath()
        paths[key] = p
        return p
    }
    func frozen() -> [DXFRenderModel.StrokeBucket: CGPath] {
        paths.mapValues { $0.copy() ?? CGMutablePath() }
    }
}

private final class FillPathDict {
    private var paths: [Int: CGMutablePath] = [:]
    subscript(aci: Int) -> CGMutablePath {
        if let p = paths[aci] { return p }
        let p = CGMutablePath()
        paths[aci] = p
        return p
    }
    func frozen() -> [Int: CGPath] {
        paths.mapValues { $0.copy() ?? CGMutablePath() }
    }
}

private final class WideStrokePathDict {
    private var paths: [DXFRenderModel.WideStrokeBucket: CGMutablePath] = [:]
    subscript(key: DXFRenderModel.WideStrokeBucket) -> CGMutablePath {
        if let p = paths[key] { return p }
        let p = CGMutablePath()
        paths[key] = p
        return p
    }
    func frozen() -> [DXFRenderModel.WideStrokeBucket: CGPath] {
        paths.mapValues { $0.copy() ?? CGMutablePath() }
    }
}
