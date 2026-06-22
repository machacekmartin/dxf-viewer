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
struct DXFRenderModel: @unchecked Sendable {
    struct Entry {
        let index: Int      // index into DXFDocument.entities (or parent for DIM children)
        let aci: Int
        let layer: String
        let kindName: String
        let geometry: Geometry
    }
    enum Geometry {
        case stroke(CGPath)
        case fill(CGPath)
        // Text needs per-entity transform + measurement, so we keep it parameterized.
        case text(TextSpec)
    }
    struct TextSpec {
        let pos: CGPoint
        let str: String
        let height: CGFloat
        let rotDeg: CGFloat
        let hAlign: Int
        let vAlign: Int
        let wrapWidth: CGFloat
        let lineSpacing: CGFloat
    }

    let entries: [Entry]
    // Merged stroke / fill paths in WORLD coords, keyed by aci. Drawn once per color
    // when the selection is empty.
    let bulkStroke: [Int: CGPath]
    let bulkFill: [Int: CGPath]
}

extension DXFRenderModel {
    static func build(from doc: DXFDocument) -> DXFRenderModel {
        var entries: [Entry] = []
        entries.reserveCapacity(doc.entities.count)

        let strokeAcc = MutablePathDict()
        let fillAcc = MutablePathDict()

        for i in doc.entities.indices {
            let e = doc.entities[i]
            // DIMENSION wrappers: flatten so each child still draws, but selection routes
            // back to the wrapper's index — selecting the dim highlights all parts.
            if case .dimension(let children) = e.kind {
                for c in children {
                    let proxy = DXFEntity(kind: c.kind, aci: e.aci, layer: e.layer)
                    appendEntity(proxy, parentIndex: i, into: &entries,
                                 stroke: strokeAcc, fill: fillAcc)
                }
            } else {
                appendEntity(e, parentIndex: i, into: &entries,
                             stroke: strokeAcc, fill: fillAcc)
            }
        }

        return DXFRenderModel(
            entries: entries,
            bulkStroke: strokeAcc.frozen(),
            bulkFill: fillAcc.frozen())
    }

    private static func appendEntity(
        _ e: DXFEntity,
        parentIndex: Int,
        into entries: inout [Entry],
        stroke: MutablePathDict,
        fill: MutablePathDict
    ) {
        let name = e.kind.typeName
        switch e.kind {
        case .line(let a, let b):
            let p = CGMutablePath()
            p.move(to: a); p.addLine(to: b)
            entries.append(.init(index: parentIndex, aci: e.aci, layer: e.layer, kindName: name, geometry: .stroke(p)))
            stroke[e.aci].addPath(p)

        case .point(let pt):
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: pt.x - 1.5, y: pt.y - 1.5, width: 3, height: 3))
            entries.append(.init(index: parentIndex, aci: e.aci, layer: e.layer, kindName: name, geometry: .fill(p)))
            fill[e.aci].addPath(p)

        case .circle(let c, let r):
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            entries.append(.init(index: parentIndex, aci: e.aci, layer: e.layer, kindName: name, geometry: .stroke(p)))
            stroke[e.aci].addPath(p)

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
            entries.append(.init(index: parentIndex, aci: e.aci, layer: e.layer, kindName: name, geometry: .stroke(p)))
            stroke[e.aci].addPath(p)

        case .polyline(let pts, let closed):
            guard let first = pts.first else { break }
            let p = CGMutablePath()
            p.move(to: first)
            for pt in pts.dropFirst() { p.addLine(to: pt) }
            if closed { p.addLine(to: first) }
            entries.append(.init(index: parentIndex, aci: e.aci, layer: e.layer, kindName: name, geometry: .stroke(p)))
            stroke[e.aci].addPath(p)

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
            entries.append(.init(index: parentIndex, aci: e.aci, layer: e.layer, kindName: name, geometry: .stroke(p)))
            stroke[e.aci].addPath(p)

        case .spline(let cps, let deg, let knots, let closed):
            // Pre-tessellate once at build time; the canvas no longer re-runs deBoor
            // every frame.
            let curve = tessellateSpline(controlPoints: cps, knots: knots, degree: deg)
            guard let first = curve.first else { break }
            let p = CGMutablePath()
            p.move(to: first)
            for pt in curve.dropFirst() { p.addLine(to: pt) }
            if closed { p.addLine(to: first) }
            entries.append(.init(index: parentIndex, aci: e.aci, layer: e.layer, kindName: name, geometry: .stroke(p)))
            stroke[e.aci].addPath(p)

        case .hatch(let pts):
            guard let first = pts.first else { break }
            let p = CGMutablePath()
            p.move(to: first)
            for pt in pts.dropFirst() { p.addLine(to: pt) }
            p.addLine(to: first)
            entries.append(.init(index: parentIndex, aci: e.aci, layer: e.layer, kindName: name, geometry: .stroke(p)))
            stroke[e.aci].addPath(p)

        case .leader(let pts, let arrow):
            guard let first = pts.first else { break }
            let path = CGMutablePath()
            path.move(to: first)
            for pt in pts.dropFirst() { path.addLine(to: pt) }
            entries.append(.init(index: parentIndex, aci: e.aci, layer: e.layer, kindName: name, geometry: .stroke(path)))
            stroke[e.aci].addPath(path)
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
                    entries.append(.init(index: parentIndex, aci: e.aci, layer: e.layer, kindName: name, geometry: .fill(fp)))
                    fill[e.aci].addPath(fp)
                }
            }

        case .text(let pt, let s, let h, let rot, let hAlign, let vAlign, let wrapW, let ls):
            let spec = TextSpec(pos: pt, str: s, height: h, rotDeg: rot,
                                hAlign: hAlign, vAlign: vAlign, wrapWidth: wrapW, lineSpacing: ls)
            entries.append(.init(index: parentIndex, aci: e.aci, layer: e.layer, kindName: name, geometry: .text(spec)))

        case .dimension, .insert: break
        }
    }
}

// Reference wrapper around CGMutablePath dictionaries so closures/loops can `addPath`
// into the same instance without copy-on-write surprises.
private final class MutablePathDict {
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
