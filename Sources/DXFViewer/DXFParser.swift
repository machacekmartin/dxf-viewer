import Foundation
import CoreGraphics

// Cox–de Boor evaluation of an open / clamped B-spline. Samples the curve at `samples+1`
// points across the valid parameter range [U_p, U_{n+1}]. If the DXF gave us no knot
// vector (or a malformed one), we synthesize a uniform clamped knot vector — that's
// the standard "open uniform" interpretation that matches AutoCAD.
func tessellateSpline(controlPoints: [CGPoint], knots: [Double], degree: Int, samples: Int = 100) -> [CGPoint] {
    guard controlPoints.count > degree, degree >= 1 else { return controlPoints }
    let n = controlPoints.count - 1
    let p = degree
    let expectedKnots = n + p + 2
    let kn: [Double]
    if knots.count == expectedKnots {
        kn = knots
    } else {
        var k = [Double](repeating: 0, count: expectedKnots)
        let interior = expectedKnots - 2 * (p + 1)
        for i in 0..<expectedKnots {
            if i <= p { k[i] = 0 }
            else if i >= n + 1 { k[i] = 1 }
            else {
                let idx = i - p
                k[i] = Double(idx) / Double(interior + 1)
            }
        }
        kn = k
    }
    let uStart = kn[p]
    let uEnd = kn[n + 1]
    guard uEnd > uStart else { return [controlPoints[0]] }

    func deBoor(_ u: Double) -> CGPoint {
        let uClamped = min(max(u, uStart), uEnd - 1e-12)
        var k = p
        for i in p...n {
            if uClamped < kn[i + 1] { k = i; break }
            k = i
        }
        var d = (0...p).map { controlPoints[k - p + $0] }
        for r in 1...p {
            for j in stride(from: p, through: r, by: -1) {
                let i = k - p + j
                let denom = kn[i + p - r + 1] - kn[i]
                let alpha = denom == 0 ? 0 : (uClamped - kn[i]) / denom
                d[j] = CGPoint(
                    x: CGFloat(1 - alpha) * d[j - 1].x + CGFloat(alpha) * d[j].x,
                    y: CGFloat(1 - alpha) * d[j - 1].y + CGFloat(alpha) * d[j].y)
            }
        }
        return d[p]
    }

    var pts: [CGPoint] = []
    pts.reserveCapacity(samples + 1)
    for s in 0...samples {
        let u = uStart + (uEnd - uStart) * Double(s) / Double(samples)
        pts.append(deBoor(u))
    }
    return pts
}

// Map the ANSI_NNNN value of $DWGCODEPAGE (R12 era) to a Foundation encoding.
// Latin1 is lossless, so we sniff it as the probe encoding first.
private func sniffDXFEncoding(_ data: Data) -> String.Encoding? {
    let probeLimit = min(data.count, 16384)
    guard let probe = String(data: data.prefix(probeLimit), encoding: .isoLatin1) else { return nil }
    guard let header = probe.range(of: "$DWGCODEPAGE") else { return nil }
    guard let ansi = probe.range(of: "ANSI_", range: header.upperBound..<probe.endIndex) else { return nil }
    let digits = probe[ansi.upperBound...].prefix(4)
    switch String(digits) {
    case "1250": return .windowsCP1250
    case "1251": return .windowsCP1251
    case "1252": return .windowsCP1252
    case "1253": return .windowsCP1253
    case "1254": return .windowsCP1254
    default: return nil
    }
}

// ASCII DXF parser. Handles: LINE, POINT, CIRCLE, ARC, ELLIPSE, LWPOLYLINE (with bulge),
// POLYLINE/VERTEX, TEXT (with 72/73 alignment + 50 rotation), MTEXT (formatting stripped),
// SPLINE (control points + knots), INSERT/BLOCK (expanded), DIMENSION (via its anonymous block),
// HATCH (outline only), LEADER. Skipped: SOLID/3DFACE, OCS extrusion (assumes +Z),
// linetype/lineweight (continuous + 1pt).
func parseDXF(url: URL) throws -> DXFDocument {
    let data = try Data(contentsOf: url)
    let text: String
    // $DWGCODEPAGE is authoritative when present. Many R12 exports declare ANSI_1250
    // (Central European) but their bytes ALSO decode under CP1252, just with the wrong
    // glyphs — so UTF-8-first ordering routes them to the wrong fallback.
    if let enc = sniffDXFEncoding(data), let s = String(data: data, encoding: enc) {
        text = s
    } else if let s = String(data: data, encoding: .utf8) { text = s }
    else if let s = String(data: data, encoding: .windowsCP1252) { text = s }
    else if let s = String(data: data, encoding: .windowsCP1250) { text = s }
    else if let s = String(data: data, encoding: .isoLatin1) { text = s }
    else { text = "" }

    // CRLF gets clustered into a single Character in Swift, so a predicate on '\n'/'\r'
    // misses every break. Normalize once, then split — produces [Substring], no String allocs.
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let lineSubs = normalized.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })

    // Fast first scan: $INSUNITS only. Avoids paying the cost of materializing every
    // (code, value) pair just to read the header.
    var insunits = 0
    for i in 0..<lineSubs.count - 1 {
        let l = lineSubs[i]
        if l.contains("$INSUNITS") {
            // Trim, confirm code 9, then read code 70 + value on the next two lines.
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed == "9" {
                // next is the var name "$INSUNITS"; +2 = code 70; +3 = value
                if i + 3 < lineSubs.count {
                    let codeLine = lineSubs[i + 2].trimmingCharacters(in: .whitespaces)
                    let valLine = lineSubs[i + 3].trimmingCharacters(in: .whitespaces)
                    if codeLine == "70" { insunits = Int(valLine) ?? 0 }
                }
                break
            }
        }
    }
    let mmPerUnit = mmPerInsunit(insunits)

    var state = ParserState()
    var idx = 0
    while idx + 1 < lineSubs.count {
        // Stream code/value pairs directly off the line buffer. No intermediate array.
        let codeStr = lineSubs[idx].trimmingCharacters(in: .whitespaces)
        guard let code = Int(codeStr) else { idx += 1; continue }
        let value = String(lineSubs[idx + 1]).trimmingCharacters(in: .whitespaces)
        idx += 2
        if state.step(code: code, value: value) { break }
    }
    state.finalize()

    let expanded = expandInserts(state.rawEntities, blocks: state.blocks, depth: 0)
    return DXFDocument(
        entities: expanded,
        bounds: computeBounds(expanded),
        layers: buildLayerInfo(expanded, layerColor: state.layerColor),
        mmPerUnit: mmPerUnit)
}

// MARK: - State machine
// One struct so the parse loop is a plain `state.step(code, value)` per pair.
// `step` returns true once it hits the EOF marker.
private struct ParserState {
    enum Section { case none, tables, blocks, entities }
    var section: Section = .none

    var layerColor: [String: Int] = [:]
    var frozenLayers: Set<String> = []

    var blocks: [String: (entities: [DXFEntity], base: CGPoint)] = [:]
    var inBlock = false
    var blockName = ""
    var blockBase = CGPoint.zero
    var blockEntities: [DXFEntity] = []
    var rawEntities: [DXFEntity] = []

    var inLayer = false
    var current: String? = nil
    var attrs: [Int: String] = [:]

    var inPoly = false
    var polyLayer = ""
    var polyAci = 256
    var polyVerts: [CGPoint] = []
    var polyClosed = false
    var pendingVertex: (x: CGFloat?, y: CGFloat?) = (nil, nil)

    var lwVerts: [(CGPoint, CGFloat)] = []
    var lwLastVertex: (x: CGFloat?, y: CGFloat?, bulge: CGFloat) = (nil, nil, 0)

    var splinePts: [CGPoint] = []
    var splineLastX: CGFloat? = nil
    var splineKnots: [Double] = []
    var splineDegree = 3
    var splineFlags = 0

    var hatchPaths: [HatchBoundary] = []
    var hatchCurrent: [CGPoint] = []
    var hatchPendingX: CGFloat? = nil       // 10 received, awaiting 20
    var hatchVertsLeft: Int = 0             // remaining 10/20 pairs in current path (set by code 93)
    var hatchPathIsPolyline = false
    var hatchInSeed = false                 // suppress 10/20 collection after code 98
    var hatchPattern: [HatchPatternLine] = []
    var hatchPendingLine: HatchPatternLine? = nil
    var hatchSolid = false
    var hatchScale: CGFloat = 1
    var hatchEntityAngle: CGFloat = 0

    func num(_ k: Int, _ d: Double = 0) -> CGFloat { CGFloat(Double(attrs[k] ?? "") ?? d) }
    func intVal(_ k: Int, _ d: Int = 0) -> Int { Int(attrs[k] ?? "") ?? d }

    func resolveAci(layer: String, entityAci: Int) -> Int {
        if entityAci == 0 || entityAci == 256 { return layerColor[layer] ?? 7 }
        return entityAci
    }

    mutating func appendEntity(_ e: DXFEntity) {
        if inBlock { blockEntities.append(e) } else { rawEntities.append(e) }
    }
    mutating func commitVertex() {
        if let x = pendingVertex.x, let y = pendingVertex.y {
            polyVerts.append(CGPoint(x: x, y: y))
        }
        pendingVertex = (nil, nil)
    }
    mutating func commitLWVertex() {
        if let x = lwLastVertex.x, let y = lwLastVertex.y {
            lwVerts.append((CGPoint(x: x, y: y), lwLastVertex.bulge))
        }
        lwLastVertex = (nil, nil, 0)
    }
    mutating func flushHatchPath() {
        if !hatchCurrent.isEmpty {
            hatchPaths.append(HatchBoundary(verts: hatchCurrent, closed: true))
        }
        hatchCurrent = []
        hatchPendingX = nil
        hatchVertsLeft = 0
        hatchPathIsPolyline = false
    }
    mutating func flushHatchPendingLine() {
        if let pl = hatchPendingLine {
            hatchPattern.append(pl)
            hatchPendingLine = nil
        }
    }
    mutating func reset() {
        current = nil; attrs = [:]
        polyVerts = []; polyClosed = false; polyLayer = ""; polyAci = 256
        pendingVertex = (nil, nil)
        lwVerts = []; lwLastVertex = (nil, nil, 0)
        splinePts = []; splineLastX = nil
        splineKnots = []; splineDegree = 3; splineFlags = 0
        hatchPaths = []; hatchCurrent = []; hatchPendingX = nil
        hatchVertsLeft = 0; hatchPathIsPolyline = false; hatchInSeed = false
        hatchPattern = []; hatchPendingLine = nil
        hatchSolid = false; hatchScale = 1; hatchEntityAngle = 0
    }

    // Returns true if EOF reached.
    mutating func step(code: Int, value: String) -> Bool {
        if code == 0 {
            // Finalize the in-flight item before dispatching the new one.
            if inLayer {
                if let name = attrs[2] {
                    let aci = intVal(62, 7)
                    layerColor[name] = abs(aci)
                    if (intVal(70) & 1) != 0 || aci < 0 { frozenLayers.insert(name) }
                }
                inLayer = false; attrs = [:]
            } else if inPoly {
                if value == "VERTEX" {
                    commitVertex(); current = "POLYLINE_VERTEX"; return false
                } else {
                    commitVertex()
                    if !polyVerts.isEmpty && !frozenLayers.contains(polyLayer) {
                        let aci = resolveAci(layer: polyLayer, entityAci: polyAci)
                        appendEntity(DXFEntity(kind: .polyline(polyVerts, polyClosed), aci: aci, layer: polyLayer))
                    }
                    inPoly = false; reset()
                    if value == "SEQEND" { return false }
                    // else fall through
                }
            } else if let c = current {
                emit(c); reset()
            }

            if value == "SECTION" { return false }
            if value == "ENDBLK" {
                if inBlock {
                    blocks[blockName] = (blockEntities, blockBase)
                    blockEntities = []; blockName = ""; blockBase = .zero; inBlock = false
                }
                return false
            }
            if value == "ENDTAB" { return false }
            if value == "ENDSEC" { section = .none; return false }
            if value == "EOF" { return true }

            switch section {
            case .tables:
                if value == "LAYER" { inLayer = true }
            case .blocks:
                if value == "BLOCK" {
                    current = "BLOCK_HEADER"
                } else if value == "POLYLINE" {
                    inPoly = true; current = "POLYLINE_HEADER"
                } else {
                    current = value
                }
            case .entities:
                if value == "POLYLINE" {
                    inPoly = true; current = "POLYLINE_HEADER"
                } else {
                    current = value
                }
            case .none: break
            }
            return false
        }
        if code == 2 && (value == "ENTITIES" || value == "TABLES" || value == "BLOCKS") && !inLayer && !inBlock && current == nil {
            section = (value == "ENTITIES") ? .entities : (value == "BLOCKS") ? .blocks : .tables
            return false
        }
        if inLayer { attrs[code] = value; return false }
        if current == "BLOCK_HEADER" {
            attrs[code] = value
            if code == 2 { blockName = value; inBlock = true; blockEntities = [] }
            else if code == 10 { blockBase.x = CGFloat(Double(value) ?? 0) }
            else if code == 20 { blockBase.y = CGFloat(Double(value) ?? 0) }
            return false
        }
        if inPoly && current == "POLYLINE_HEADER" {
            if code == 70 { polyClosed = (Int(value) ?? 0) & 1 == 1 }
            else if code == 8 { polyLayer = value }
            else if code == 62 { polyAci = Int(value) ?? 256 }
            return false
        }
        if inPoly {
            if code == 10 { pendingVertex.x = CGFloat(Double(value) ?? 0) }
            else if code == 20 { pendingVertex.y = CGFloat(Double(value) ?? 0) }
            return false
        }
        if current == "LWPOLYLINE" {
            if code == 10 { commitLWVertex(); lwLastVertex.x = CGFloat(Double(value) ?? 0) }
            else if code == 20 { lwLastVertex.y = CGFloat(Double(value) ?? 0) }
            else if code == 42 { lwLastVertex.bulge = CGFloat(Double(value) ?? 0) }
            else { attrs[code] = value }
            return false
        }
        if current == "LEADER" {
            if code == 10 { commitLWVertex(); lwLastVertex.x = CGFloat(Double(value) ?? 0) }
            else if code == 20 { lwLastVertex.y = CGFloat(Double(value) ?? 0) }
            else { attrs[code] = value }
            return false
        }
        if current == "HATCH" {
            switch code {
            case 70:
                hatchSolid = (Int(value) ?? 0) != 0
            case 41:
                hatchScale = CGFloat(Double(value) ?? 1)
            case 52:
                hatchEntityAngle = CGFloat(Double(value) ?? 0)
            case 92:
                // New boundary path starts. Flush current path, capture polyline-flag (bit 2 = 2).
                flushHatchPath()
                let flags = Int(value) ?? 0
                hatchPathIsPolyline = (flags & 2) != 0
            case 93:
                // Vertex count for current path (polyline) OR edge count (non-polyline; skipped).
                hatchVertsLeft = hatchPathIsPolyline ? (Int(value) ?? 0) : 0
            case 10:
                if hatchInSeed { break }
                if hatchPathIsPolyline && hatchVertsLeft > 0 {
                    hatchPendingX = CGFloat(Double(value) ?? 0)
                } else if hatchPendingLine != nil {
                    // Codes 10/20 don't appear in the entity-level pattern table for predefined
                    // patterns, but guard anyway by ignoring outside boundary context.
                }
            case 20:
                if hatchInSeed { break }
                if hatchPathIsPolyline && hatchVertsLeft > 0, let x = hatchPendingX {
                    hatchCurrent.append(CGPoint(x: x, y: CGFloat(Double(value) ?? 0)))
                    hatchPendingX = nil
                    hatchVertsLeft -= 1
                }
            case 53:
                flushHatchPendingLine()
                let lineAngle = CGFloat(Double(value) ?? 0)
                hatchPendingLine = HatchPatternLine(
                    angleDeg: lineAngle + hatchEntityAngle,
                    basePoint: .zero, offset: .zero, dashes: [])
            case 43: if hatchPendingLine != nil { hatchPendingLine!.basePoint.x = CGFloat(Double(value) ?? 0) }
            case 44: if hatchPendingLine != nil { hatchPendingLine!.basePoint.y = CGFloat(Double(value) ?? 0) }
            case 45: if hatchPendingLine != nil { hatchPendingLine!.offset.x = CGFloat(Double(value) ?? 0) }
            case 46: if hatchPendingLine != nil { hatchPendingLine!.offset.y = CGFloat(Double(value) ?? 0) }
            case 49: if hatchPendingLine != nil { hatchPendingLine!.dashes.append(CGFloat(Double(value) ?? 0)) }
            case 98:
                // Seed-point count. Subsequent 10/20 pairs are seed points — must NOT be
                // collected as boundary vertices (root cause of the 2 stray points in #145).
                flushHatchPendingLine()
                hatchInSeed = true
            default:
                attrs[code] = value
            }
            return false
        }
        if current == "SPLINE" {
            if code == 10 { splineLastX = CGFloat(Double(value) ?? 0) }
            else if code == 20, let x = splineLastX {
                splinePts.append(CGPoint(x: x, y: CGFloat(Double(value) ?? 0)))
                splineLastX = nil
            } else if code == 40 {
                if let d = Double(value) { splineKnots.append(d) }
            } else if code == 70 { splineFlags = Int(value) ?? 0 }
            else if code == 71 { splineDegree = Int(value) ?? 3 }
            else { attrs[code] = value }
            return false
        }
        if current != nil { attrs[code] = value }
        return false
    }

    mutating func finalize() {
        if inLayer, let name = attrs[2] {
            let aci = intVal(62, 7)
            layerColor[name] = abs(aci)
            if (intVal(70) & 1) != 0 || aci < 0 { frozenLayers.insert(name) }
        } else if let c = current { emit(c) }
    }

    mutating func emit(_ name: String) {
        let layer = attrs[8] ?? "0"
        // DEFPOINTS is a CAD convention for non-printing dim definition points;
        // ezdxf + AutoCAD exclude its contents from bbox + render, so we do too.
        if frozenLayers.contains(layer) || layer.caseInsensitiveCompare("defpoints") == .orderedSame {
            return
        }
        let aci = resolveAci(layer: layer, entityAci: intVal(62, 256))
        switch name {
        case "LINE":
            appendEntity(DXFEntity(kind: .line(CGPoint(x: num(10), y: num(20)), CGPoint(x: num(11), y: num(21))), aci: aci, layer: layer))
        case "POINT":
            appendEntity(DXFEntity(kind: .point(CGPoint(x: num(10), y: num(20))), aci: aci, layer: layer))
        case "CIRCLE":
            appendEntity(DXFEntity(kind: .circle(CGPoint(x: num(10), y: num(20)), num(40)), aci: aci, layer: layer))
        case "ARC":
            appendEntity(DXFEntity(kind: .arc(CGPoint(x: num(10), y: num(20)), num(40), num(50), num(51)), aci: aci, layer: layer))
        case "ELLIPSE":
            let c = CGPoint(x: num(10), y: num(20))
            let mv = CGPoint(x: num(11), y: num(21))
            appendEntity(DXFEntity(kind: .ellipse(c, mv, num(40, 1), num(41, 0), num(42, 2 * .pi)), aci: aci, layer: layer))
        case "LWPOLYLINE":
            commitLWVertex()
            guard !lwVerts.isEmpty else { return }
            let closed = (intVal(70) & 1) == 1
            var pts: [CGPoint] = [lwVerts[0].0]
            for i in 0..<lwVerts.count - 1 {
                let a = lwVerts[i]
                let b = lwVerts[i + 1]
                if abs(a.1) > 1e-9 { pts.append(contentsOf: tessellateBulge(a.0, b.0, bulge: a.1)) }
                pts.append(b.0)
            }
            if closed, let last = lwVerts.last, abs(last.1) > 1e-9 {
                pts.append(contentsOf: tessellateBulge(last.0, lwVerts[0].0, bulge: last.1))
            }
            appendEntity(DXFEntity(kind: .polyline(pts, closed), aci: aci, layer: layer))
        case "TEXT":
            guard let raw = attrs[1], !raw.isEmpty else { return }
            let s = stripDxfEscapes(raw)
            let h = num(40, 10)
            let g72 = intVal(72)
            let g73 = intVal(73)
            let useSecond = (g72 != 0) || (g73 != 0)
            let pos = useSecond ? CGPoint(x: num(11), y: num(21)) : CGPoint(x: num(10), y: num(20))
            let hAlign: Int = {
                switch g72 {
                case 1, 4: return 1
                case 2: return 2
                default: return 0
                }
            }()
            // g72=4 (Middle) means the alignment point is the geometric centre of the
            // glyph box — vertically as well as horizontally.
            let vAlign = (g72 == 4) ? 2 : g73
            appendEntity(DXFEntity(kind: .text(pos, s, h, num(50), hAlign, vAlign, 0, 1.0), aci: aci, layer: layer))
        case "MTEXT":
            guard let raw = attrs[1], !raw.isEmpty else { return }
            let s = stripMText(raw)
            let h = num(40, 10)
            let att = intVal(71, 1)
            let hAlign: Int = {
                switch att {
                case 1, 4, 7: return 0
                case 2, 5, 8: return 1
                case 3, 6, 9: return 2
                default: return 0
                }
            }()
            let vAlign: Int = {
                switch att {
                case 1, 2, 3: return 3
                case 4, 5, 6: return 2
                case 7, 8, 9: return 1
                default: return 3
                }
            }()
            let wrapW = num(41, 0)
            let lineSp = num(44, 1)
            var rot = num(50, 0)
            if abs(rot) < 1e-9 {
                let dx = num(11, 1)
                let dy = num(21, 0)
                if abs(dx - 1) > 1e-6 || abs(dy) > 1e-6 {
                    rot = atan2(dy, dx) * 180 / .pi
                }
            }
            appendEntity(DXFEntity(kind: .text(CGPoint(x: num(10), y: num(20)), s, h, rot, hAlign, vAlign, wrapW, lineSp), aci: aci, layer: layer))
        case "INSERT":
            let bn = attrs[2] ?? ""
            var px = num(10), py = num(20)
            var sx = num(41, 1), sy = num(42, 1)
            var rotDeg = num(50, 0)
            // OCS extrusion: 230 == -1 → X-flip. tx() in expandInserts applies mirror
            // first, then rotation, so equivalent composition needs the rotation negated.
            let extrZ = num(230, 1)
            if extrZ < 0 { px = -px; sx = -sx; rotDeg = -rotDeg }
            appendEntity(DXFEntity(kind: .insert(DXFInsert(blockName: bn, pos: CGPoint(x: px, y: py), sx: sx, sy: sy, rotDeg: rotDeg, isDim: false)), aci: aci, layer: layer))
        case "DIMENSION":
            let bn = attrs[2] ?? ""
            if !bn.isEmpty {
                appendEntity(DXFEntity(kind: .insert(DXFInsert(blockName: bn, pos: .zero, sx: 1, sy: 1, rotDeg: 0, isDim: true)), aci: aci, layer: layer))
            }
        case "SPLINE":
            if !splinePts.isEmpty {
                let closed = (splineFlags & 1) != 0
                appendEntity(DXFEntity(kind: .spline(splinePts, max(splineDegree, 1), splineKnots, closed), aci: aci, layer: layer))
            }
        case "HATCH":
            flushHatchPath()
            flushHatchPendingLine()
            // Apply entity-level scale + rotation to each pattern line's basePoint/offset.
            // The pattern-line angle already absorbs entity angle; the basePoint/offset still
            // live in pattern coords and must be rotated and scaled into world space.
            let cosA = cos(Double(hatchEntityAngle) * .pi / 180)
            let sinA = sin(Double(hatchEntityAngle) * .pi / 180)
            let scaled = hatchPattern.map { pl -> HatchPatternLine in
                func rot(_ p: CGPoint) -> CGPoint {
                    let x = Double(p.x) * cosA - Double(p.y) * sinA
                    let y = Double(p.x) * sinA + Double(p.y) * cosA
                    return CGPoint(x: CGFloat(x) * hatchScale, y: CGFloat(y) * hatchScale)
                }
                return HatchPatternLine(
                    angleDeg: pl.angleDeg,
                    basePoint: rot(pl.basePoint),
                    offset: rot(pl.offset),
                    dashes: pl.dashes.map { $0 * hatchScale })
            }
            guard !hatchPaths.isEmpty else { return }
            let data = HatchData(
                boundaries: hatchPaths,
                isSolid: hatchSolid,
                pattern: scaled,
                patternScale: hatchScale,
                patternAngle: hatchEntityAngle)
            appendEntity(DXFEntity(kind: .hatch(data), aci: aci, layer: layer))
        case "LEADER":
            commitLWVertex()
            guard !lwVerts.isEmpty else { return }
            let extrZ = num(230, 1)
            var pts = lwVerts.map { $0.0 }
            if extrZ < 0 { pts = pts.map { CGPoint(x: -$0.x, y: $0.y) } }
            let arrow: CGFloat = {
                if pts.count >= 2 {
                    let a = pts[0], b = pts[1]
                    let segLen = hypot(b.x - a.x, b.y - a.y)
                    return max(num(40, segLen * 0.05), 1)
                }
                return num(40, 1)
            }()
            appendEntity(DXFEntity(kind: .leader(pts, arrow), aci: aci, layer: layer))
        default: break
        }
    }
}

// MARK: - Helpers

private func tessellateBulge(_ a: CGPoint, _ b: CGPoint, bulge: CGFloat, steps: Int = 12) -> [CGPoint] {
    let theta = 4 * atan(bulge)
    let chord = hypot(b.x - a.x, b.y - a.y)
    guard chord > 0, abs(theta) > 1e-9 else { return [] }
    let r = chord / (2 * sin(theta / 2))
    let midx = (a.x + b.x) / 2
    let midy = (a.y + b.y) / 2
    let nx = -(b.y - a.y) / chord
    let ny = (b.x - a.x) / chord
    let h = r * cos(theta / 2)
    let cx = midx + nx * h
    let cy = midy + ny * h
    let startAng = atan2(a.y - cy, a.x - cx)
    var pts: [CGPoint] = []
    for k in 1..<steps {
        let t = CGFloat(k) / CGFloat(steps)
        let ang = startAng + theta * t
        pts.append(CGPoint(x: cx + r * cos(ang), y: cy + r * sin(ang)))
    }
    return pts
}

// AutoCAD TEXT escape codes: %%u underline (drop), %%d/%%p/%%c special chars,
// %%nnn octal char code, %%% literal percent.
private func stripDxfEscapes(_ s: String) -> String {
    var r = s
    r = r.replacingOccurrences(of: "%%u", with: "", options: .caseInsensitive)
    r = r.replacingOccurrences(of: "%%o", with: "", options: .caseInsensitive)
    r = r.replacingOccurrences(of: "%%l", with: "", options: .caseInsensitive)
    r = r.replacingOccurrences(of: "%%k", with: "", options: .caseInsensitive)
    r = r.replacingOccurrences(of: "%%d", with: "°", options: .caseInsensitive)
    r = r.replacingOccurrences(of: "%%p", with: "±", options: .caseInsensitive)
    r = r.replacingOccurrences(of: "%%c", with: "⌀", options: .caseInsensitive)
    r = r.replacingOccurrences(of: "%%%", with: "%")
    if let regex = try? NSRegularExpression(pattern: "%%(\\d{3})") {
        let ns = r as NSString
        for m in regex.matches(in: r, range: NSRange(location: 0, length: ns.length)).reversed() {
            let codeStr = ns.substring(with: m.range(at: 1))
            if let code = Int(codeStr), let scalar = Unicode.Scalar(code) {
                r = (r as NSString).replacingCharacters(in: m.range, with: String(Character(scalar)))
            }
        }
    }
    return r
}

private func stripMText(_ s: String) -> String {
    var r = s.replacingOccurrences(of: "\\P", with: "\n")
    r = r.replacingOccurrences(of: "\\~", with: " ")
    if let regex = try? NSRegularExpression(pattern: "\\\\[A-Za-z][^;\\\\]*;?") {
        let ns = r as NSString
        r = regex.stringByReplacingMatches(in: r, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }
    r = r.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    return stripDxfEscapes(r)
}

private func buildLayerInfo(_ entities: [DXFEntity], layerColor: [String: Int]) -> [DXFLayerInfo] {
    var counts: [String: Int] = [:]
    var acis: [String: Int] = [:]
    var kindIndices: [String: [String: [Int]]] = [:]
    for (i, e) in entities.enumerated() {
        counts[e.layer, default: 0] += 1
        if acis[e.layer] == nil { acis[e.layer] = e.aci }
        kindIndices[e.layer, default: [:]][e.kind.typeName, default: []].append(i)
    }
    return counts.keys.sorted().map { name in
        let kinds = (kindIndices[name] ?? [:])
            .map { DXFLayerInfo.Kind(name: $0.key, indices: $0.value) }
            .sorted { ($0.count, $0.name) > ($1.count, $1.name) }
        return DXFLayerInfo(
            name: name,
            aci: layerColor[name] ?? acis[name] ?? 7,
            count: counts[name] ?? 0,
            kinds: kinds)
    }
}

private func expandInserts(_ entities: [DXFEntity], blocks: [String: (entities: [DXFEntity], base: CGPoint)], depth: Int) -> [DXFEntity] {
    if depth > 8 { return entities.filter { if case .insert = $0.kind { return false } else { return true } } }
    var out: [DXFEntity] = []
    for e in entities {
        guard case .insert(let ins) = e.kind else { out.append(e); continue }
        guard let block = blocks[ins.blockName] else { continue }
        let rot = Double(ins.rotDeg) * .pi / 180
        let cosR = CGFloat(cos(rot)), sinR = CGFloat(sin(rot))
        func tx(_ p: CGPoint) -> CGPoint {
            let lx = (p.x - block.base.x) * ins.sx
            let ly = (p.y - block.base.y) * ins.sy
            return CGPoint(x: lx * cosR - ly * sinR + ins.pos.x,
                           y: lx * sinR + ly * cosR + ins.pos.y)
        }
        let scaleAbs = abs(ins.sx)
        let inner = expandInserts(block.entities, blocks: blocks, depth: depth + 1)
        var dimChildren: [DXFEntity] = []
        func emit(_ child: DXFEntity) {
            if ins.isDim { dimChildren.append(child) } else { out.append(child) }
        }
        for be in inner {
            let aci = be.aci
            // Standard DXF rule: entities on layer "0" inside a block adopt the insert's layer.
            let layer = (be.layer == "0") ? e.layer : be.layer
            if layer.caseInsensitiveCompare("defpoints") == .orderedSame { continue }
            switch be.kind {
            case .line(let a, let b):
                emit(DXFEntity(kind: .line(tx(a), tx(b)), aci: aci, layer: layer))
            case .point(let p):
                emit(DXFEntity(kind: .point(tx(p)), aci: aci, layer: layer))
            case .circle(let c, let r):
                if abs(abs(ins.sx) - abs(ins.sy)) < 1e-9 {
                    emit(DXFEntity(kind: .circle(tx(c), r * scaleAbs), aci: aci, layer: layer))
                } else {
                    let asx = abs(ins.sx), asy = abs(ins.sy)
                    let rMajor = r * max(asx, asy)
                    let ratio = min(asx, asy) / max(asx, asy)
                    let majorWorld: CGPoint = (asx >= asy)
                        ? CGPoint(x: rMajor * cosR, y: rMajor * sinR)
                        : CGPoint(x: -rMajor * sinR, y: rMajor * cosR)
                    emit(DXFEntity(kind: .ellipse(tx(c), majorWorld, ratio, 0, 2 * .pi), aci: aci, layer: layer))
                }
            case .arc(let c, let r, let sa, let ea):
                let mx = ins.sx < 0, my = ins.sy < 0
                var nsa = sa, nea = ea
                if mx && my { nsa = sa + 180; nea = ea + 180 }
                else if mx { nsa = 180 - ea; nea = 180 - sa }
                else if my { nsa = -ea; nea = -sa }
                emit(DXFEntity(kind: .arc(tx(c), r * scaleAbs, nsa + ins.rotDeg, nea + ins.rotDeg), aci: aci, layer: layer))
            case .polyline(let pts, let closed):
                emit(DXFEntity(kind: .polyline(pts.map(tx), closed), aci: aci, layer: layer))
            case .text(let p, let s, let h, let r, let ha, let va, let w, let ls):
                emit(DXFEntity(kind: .text(tx(p), s, h * scaleAbs, r + ins.rotDeg, ha, va, w * scaleAbs, ls), aci: aci, layer: layer))
            case .ellipse(let c, let mv, let ratio, let sa, let ea):
                let cw = tx(c)
                let endpoint = tx(CGPoint(x: c.x + mv.x, y: c.y + mv.y))
                emit(DXFEntity(kind: .ellipse(cw, CGPoint(x: endpoint.x - cw.x, y: endpoint.y - cw.y), ratio, sa, ea), aci: aci, layer: layer))
            case .spline(let cps, let deg, let knots, let closed):
                emit(DXFEntity(kind: .spline(cps.map(tx), deg, knots, closed), aci: aci, layer: layer))
            case .hatch(let h):
                var hh = h
                hh.boundaries = h.boundaries.map {
                    HatchBoundary(verts: $0.verts.map(tx), closed: $0.closed)
                }
                // Pattern base/offset are in world units already; apply INSERT scale + rotation.
                // tx() maps a world point through translate + scale + rotate; we want just the
                // linear part (scale + rotate) for vectors. Recover by subtracting tx(.zero).
                let origin = tx(.zero)
                func txVec(_ v: CGPoint) -> CGPoint {
                    let p = tx(v)
                    return CGPoint(x: p.x - origin.x, y: p.y - origin.y)
                }
                hh.pattern = h.pattern.map {
                    HatchPatternLine(
                        angleDeg: $0.angleDeg + ins.rotDeg,
                        basePoint: tx($0.basePoint),
                        offset: txVec($0.offset),
                        dashes: $0.dashes.map { $0 * scaleAbs })
                }
                emit(DXFEntity(kind: .hatch(hh), aci: aci, layer: layer))
            case .dimension(let children):
                emit(DXFEntity(kind: .dimension(children), aci: aci, layer: layer))
            case .leader(let pts, let arrow):
                emit(DXFEntity(kind: .leader(pts.map(tx), arrow * scaleAbs), aci: aci, layer: layer))
            case .insert: break
            }
        }
        if ins.isDim {
            out.append(DXFEntity(kind: .dimension(dimChildren), aci: e.aci, layer: e.layer))
        }
    }
    return out
}

// MARK: - Bounds

func computeBoundsForOne(_ e: DXFEntity) -> CGRect { computeBounds([e]) }

func computeBounds(_ entities: [DXFEntity]) -> CGRect {
    var minX = CGFloat.infinity, minY = CGFloat.infinity
    var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
    func extend(_ p: CGPoint) {
        minX = min(minX, p.x); minY = min(minY, p.y)
        maxX = max(maxX, p.x); maxY = max(maxY, p.y)
    }
    for e in entities {
        switch e.kind {
        case .line(let a, let b): extend(a); extend(b)
        case .point(let p): extend(p)
        case .circle(let c, let r):
            extend(CGPoint(x: c.x - r, y: c.y - r)); extend(CGPoint(x: c.x + r, y: c.y + r))
        case .arc(let c, let r, let startDeg, let endDeg):
            // True arc bbox: endpoints + any axis-aligned extrema (0/90/180/270°) inside
            // the CCW sweep. Earlier code used the full-circle bbox and overshot.
            let start = Double(startDeg) * .pi / 180
            let end = Double(endDeg) * .pi / 180
            var sweep = end - start
            while sweep < 0 { sweep += 2 * .pi }
            extend(CGPoint(x: c.x + r * CGFloat(cos(start)), y: c.y + r * CGFloat(sin(start))))
            extend(CGPoint(x: c.x + r * CGFloat(cos(start + sweep)), y: c.y + r * CGFloat(sin(start + sweep))))
            for (angle, dx, dy) in [(0.0, 1.0, 0.0), (.pi/2, 0.0, 1.0), (.pi, -1.0, 0.0), (3 * .pi/2, 0.0, -1.0)] {
                var rel = angle - start
                while rel < 0 { rel += 2 * .pi }
                if rel <= sweep {
                    extend(CGPoint(x: c.x + r * CGFloat(dx), y: c.y + r * CGFloat(dy)))
                }
            }
        case .polyline(let pts, _): pts.forEach(extend)
        case .text(let p, let s, let h, let rotDeg, let hAlign, let vAlign, let wrapW, let lineSp):
            // Match the renderer's alignment math so fit-to-window doesn't crop text.
            let lines = max(1, s.components(separatedBy: "\n").count)
            let glyphW = wrapW > 0 ? wrapW : max(1, CGFloat(s.count)) * h * 0.7
            // ezdxf's MTEXT bbox uses ~2.95 × char height; single-line TEXT uses ~1.3 × h.
            let isMText = wrapW > 0
            let lineH = h * max(lineSp, 1) * (isMText ? 2.95 : 1.3)
            let glyphH = CGFloat(lines) * lineH
            let dx: CGFloat = hAlign == 1 ? -glyphW / 2 : (hAlign == 2 ? -glyphW : 0)
            let dy: CGFloat = vAlign == 3 ? -glyphH : (vAlign == 2 ? -glyphH / 2 : (vAlign == 1 ? 0 : -0.25 * h))
            let cosR = CGFloat(cos(Double(rotDeg) * .pi / 180))
            let sinR = CGFloat(sin(Double(rotDeg) * .pi / 180))
            for (cx, cy) in [(dx, dy), (dx + glyphW, dy), (dx, dy + glyphH), (dx + glyphW, dy + glyphH)] {
                extend(CGPoint(x: cosR * cx - sinR * cy + p.x,
                               y: sinR * cx + cosR * cy + p.y))
            }
        case .ellipse(let c, let mv, let ratio, let sa, let ea):
            let minorVec = CGPoint(x: -mv.y * ratio, y: mv.x * ratio)
            var sweep = ea - sa
            if sweep <= 0 { sweep += 2 * .pi }
            let steps = 64
            for k in 0...steps {
                let t = sa + sweep * CGFloat(k) / CGFloat(steps)
                extend(CGPoint(
                    x: c.x + mv.x * cos(t) + minorVec.x * sin(t),
                    y: c.y + mv.y * cos(t) + minorVec.y * sin(t)))
            }
        case .spline(let cps, let deg, let knots, _):
            tessellateSpline(controlPoints: cps, knots: knots, degree: deg).forEach(extend)
        case .hatch(let h): h.boundaries.forEach { $0.verts.forEach(extend) }
        case .dimension(let children):
            let sub = computeBounds(children)
            if sub.width > 0 || sub.height > 0 {
                extend(CGPoint(x: sub.minX, y: sub.minY))
                extend(CGPoint(x: sub.maxX, y: sub.maxY))
            }
        case .leader(let pts, _): pts.forEach(extend)
        case .insert: break
        }
    }
    if !minX.isFinite { return CGRect(x: 0, y: 0, width: 1, height: 1) }
    return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
}
