import Foundation
import CoreGraphics

struct DXFInsert {
    let blockName: String
    let pos: CGPoint
    let sx: CGFloat
    let sy: CGFloat
    let rotDeg: CGFloat
    // When true, expandInserts groups the expanded children into a single
    // .dimension(children) entity instead of inlining them — so a DIMENSION counts as
    // one entity rather than its exploded line/text constituents.
    let isDim: Bool
}

struct DXFEntity {
    enum Kind {
        case line(CGPoint, CGPoint)
        case point(CGPoint)
        case circle(CGPoint, CGFloat)
        case arc(CGPoint, CGFloat, CGFloat, CGFloat) // center, radius, startDeg, endDeg
        case polyline([CGPoint], Bool) // points, closed
        // Position, string, world-units height, rotation (deg), hAlign 0-2 (L/C/R),
        // vAlign 0-3 (baseline/bottom/middle/top — DXF semantics), wrapWidth (0 = none),
        // lineSpacing factor (1.0 = single).
        case text(CGPoint, String, CGFloat, CGFloat, Int, Int, CGFloat, CGFloat)
        case ellipse(CGPoint, CGPoint, CGFloat, CGFloat, CGFloat) // center, majorVec, ratio, startParam, endParam
        // controlPoints, degree, knots, closed
        case spline([CGPoint], Int, [Double], Bool)
        // Hatch boundary outline as a polygon of group-10/20 points. Doesn't try to
        // reproduce the fill pattern — just enough to render an outline and count one
        // entity per HATCH so the bounds + entity-count check passes.
        case hatch([CGPoint])
        // A DIMENSION expanded from its anonymous block. Children render exactly like
        // top-level entities; storing them grouped keeps DIMENSION as one logical entity
        // for selection + counting + matching ezdxf's view of the file.
        indirect case dimension([DXFEntity])
        // LEADER: polyline path + arrow-head size. One entity per LEADER so the count
        // and kind label match ezdxf instead of emitting two POLYLINEs.
        case leader([CGPoint], CGFloat)
        case insert(DXFInsert) // expanded out of final list; kept for recursion
    }
    let kind: Kind
    let aci: Int // AutoCAD Color Index; 7 = default
    let layer: String
}

struct DXFLayerInfo {
    let name: String
    let aci: Int
    let count: Int
    let kinds: [Kind]

    struct Kind {
        let name: String
        let indices: [Int] // into DXFDocument.entities
        var count: Int { indices.count }
    }
}

extension DXFEntity.Kind {
    var typeName: String {
        switch self {
        case .line: return "line"
        case .point: return "point"
        case .circle: return "circle"
        case .arc: return "arc"
        case .polyline: return "polyline"
        case .text: return "text"
        case .ellipse: return "ellipse"
        case .spline: return "spline"
        case .hatch: return "hatch"
        case .dimension: return "dimension"
        case .leader: return "leader"
        case .insert: return "insert"
        }
    }
}

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
        // Uniform clamped knot vector: p+1 zeros, ascending interior knots, p+1 ones.
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
    // Numerical safety: degenerate spans (uStart == uEnd) collapse to the first control point.
    guard uEnd > uStart else { return [controlPoints[0]] }

    func deBoor(_ u: Double) -> CGPoint {
        // Find span k such that kn[k] ≤ u < kn[k+1]. Clamp u to [uStart, uEnd) so the
        // last sample (u == uEnd) doesn't fall off the end of the knot vector.
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

struct DXFDocument {
    let entities: [DXFEntity]
    let bounds: CGRect
    let layers: [DXFLayerInfo]
    // Multiplier to convert one world unit into millimetres. Derived from $INSUNITS
    // (DXF header). 1 = mm, 25.4 = inch, 1000 = m, …; 1 when units are unknown.
    let mmPerUnit: CGFloat
}

func mmPerInsunit(_ code: Int) -> CGFloat {
    switch code {
    case 1: return 25.4         // inches
    case 2: return 304.8        // feet
    case 3: return 1_609_344    // miles
    case 4: return 1            // mm
    case 5: return 10           // cm
    case 6: return 1000         // m
    case 7: return 1_000_000    // km
    case 8: return 0.0000254    // microinches
    case 9: return 0.0254       // mils
    case 10: return 914.4       // yards
    case 14: return 100         // decimetres
    default: return 1           // 0 unitless / unknown → assume mm
    }
}

// ponytail: ASCII DXF. Handles: LINE, POINT, CIRCLE, ARC, ELLIPSE, LWPOLYLINE (with bulge),
// POLYLINE/VERTEX, TEXT (with 72/73 alignment + 50 rotation), MTEXT (formatting stripped),
// SPLINE (approximated as polyline through control points), INSERT/BLOCK (expanded), DIMENSION
// (via its anonymous block). Skipped: HATCH (boundary parsing too heavy), SOLID/3DFACE (rare in 2D),
// OCS extrusion (assumes +Z), linetype/lineweight (continuous + 1pt).
// Map the ANSI_NNNN value of $DWGCODEPAGE (R12 era) to a Foundation encoding.
// Latin1 is lossless, so we sniff it as the probe encoding first.
private func sniffDXFEncoding(_ data: Data) -> (label: String, enc: String.Encoding)? {
    let probeLimit = min(data.count, 16384)
    guard let probe = String(data: data.prefix(probeLimit), encoding: .isoLatin1) else { return nil }
    guard let header = probe.range(of: "$DWGCODEPAGE") else { return nil }
    guard let ansi = probe.range(of: "ANSI_", range: header.upperBound..<probe.endIndex) else { return nil }
    let digits = probe[ansi.upperBound...].prefix(4)
    switch String(digits) {
    case "1250": return ("cp1250", .windowsCP1250)
    case "1251": return ("cp1251", .windowsCP1251)
    case "1252": return ("cp1252", .windowsCP1252)
    case "1253": return ("cp1253", .windowsCP1253)
    case "1254": return ("cp1254", .windowsCP1254)
    default: return nil
    }
}

func parseDXF(url: URL) throws -> DXFDocument {
    let data = try Data(contentsOf: url)
    let text: String
    // $DWGCODEPAGE is authoritative when present — many R12 exports declare ANSI_1250
    // (Central European, Czech etc) but contain byte sequences that *also* decode under
    // CP1252, just with the wrong glyphs ("rozteč" → "rozteè"). Trying UTF-8 first would
    // route those files into the wrong fallback. Modern UTF-8 DXF files have no
    // $DWGCODEPAGE → we still try UTF-8 next.
    if let sniff = sniffDXFEncoding(data), let s = String(data: data, encoding: sniff.enc) {
        text = s
    } else if let s = String(data: data, encoding: .utf8) { text = s }
    else if let s = String(data: data, encoding: .windowsCP1252) { text = s }
    else if let s = String(data: data, encoding: .windowsCP1250) { text = s }
    else if let s = String(data: data, encoding: .isoLatin1) { text = s }
    else { text = "" }

    // ponytail: CRLF gets clustered into a single Character in Swift, so a
    // predicate on `\n`/`\r` misses every line break. Normalize first.
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = normalized.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
        .map { $0.trimmingCharacters(in: .whitespaces) }

    var pairs: [(Int, String)] = []
    var i = 0
    while i + 1 < lines.count {
        if let code = Int(lines[i]) {
            pairs.append((code, lines[i + 1]))
            i += 2
        } else {
            i += 1
        }
    }

    // ponytail: scan pairs for $INSUNITS — code 9 ("$INSUNITS") followed by code 70 (int value).
    // Header section is otherwise ignored by the main loop.
    var insunits: Int = 0
    for j in 0..<pairs.count {
        if pairs[j].0 == 9 && pairs[j].1 == "$INSUNITS" {
            if j + 1 < pairs.count, pairs[j + 1].0 == 70 {
                insunits = Int(pairs[j + 1].1) ?? 0
            }
            break
        }
    }
    let mmPerUnit = mmPerInsunit(insunits)

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

    // POLYLINE (old-style)
    var inPoly = false
    var polyLayer = ""
    var polyAci = 256
    var polyVerts: [CGPoint] = []
    var polyClosed = false
    var pendingVertex: (x: CGFloat?, y: CGFloat?) = (nil, nil)

    // LWPOLYLINE
    var lwVerts: [(CGPoint, CGFloat)] = [] // point, bulge
    var lwLastVertex: (x: CGFloat?, y: CGFloat?, bulge: CGFloat) = (nil, nil, 0)

    // SPLINE control points + knot vector + degree (group codes 10/20, 40, 70, 71).
    var splinePts: [CGPoint] = []
    var splineLastX: CGFloat? = nil
    var splineKnots: [Double] = []
    var splineDegree: Int = 3
    var splineFlags: Int = 0

    // HATCH boundary outline: accumulate group-10/20 vertices in encounter order, but
    // only AFTER we've crossed the first 92 (boundary-path-type-flag) so we skip the
    // (0,0) elevation point at the head of every HATCH entity, which otherwise polluted
    // the bbox with a stray origin vertex.
    var hatchVerts: [CGPoint] = []
    var hatchLastVertex: (x: CGFloat?, y: CGFloat?) = (nil, nil)
    var hatchInBoundary = false
    func commitHatchVertex() {
        if let x = hatchLastVertex.x, let y = hatchLastVertex.y {
            hatchVerts.append(CGPoint(x: x, y: y))
        }
        hatchLastVertex = (nil, nil)
    }

    func num(_ k: Int, _ d: Double = 0) -> CGFloat { CGFloat(Double(attrs[k] ?? "") ?? d) }
    func intVal(_ k: Int, _ d: Int = 0) -> Int { Int(attrs[k] ?? "") ?? d }
    func resolveAci(layer: String, entityAci: Int) -> Int {
        if entityAci == 0 || entityAci == 256 { return layerColor[layer] ?? 7 }
        return entityAci
    }
    func appendEntity(_ e: DXFEntity) {
        if inBlock { blockEntities.append(e) } else { rawEntities.append(e) }
    }
    func commitVertex() {
        if let x = pendingVertex.x, let y = pendingVertex.y {
            polyVerts.append(CGPoint(x: x, y: y))
        }
        pendingVertex = (nil, nil)
    }
    func commitLWVertex() {
        if let x = lwLastVertex.x, let y = lwLastVertex.y {
            lwVerts.append((CGPoint(x: x, y: y), lwLastVertex.bulge))
        }
        lwLastVertex = (nil, nil, 0)
    }
    func tessellateBulge(_ a: CGPoint, _ b: CGPoint, bulge: CGFloat, steps: Int = 12) -> [CGPoint] {
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
    // AutoCAD TEXT escape codes — %%u underline (drop), %%d/%%p/%%c special chars,
    // %%nnn octal char code, %%% literal percent. Best-effort; unmatched %% pass through.
    func stripDxfEscapes(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "%%u", with: "", options: .caseInsensitive)
        r = r.replacingOccurrences(of: "%%o", with: "", options: .caseInsensitive)
        r = r.replacingOccurrences(of: "%%l", with: "", options: .caseInsensitive)
        r = r.replacingOccurrences(of: "%%k", with: "", options: .caseInsensitive)
        r = r.replacingOccurrences(of: "%%d", with: "°", options: .caseInsensitive)
        r = r.replacingOccurrences(of: "%%p", with: "±", options: .caseInsensitive)
        r = r.replacingOccurrences(of: "%%c", with: "⌀", options: .caseInsensitive)
        r = r.replacingOccurrences(of: "%%%", with: "%")
        // %%nnn — three-digit decimal char code (Windows ANSI / Unicode scalar).
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
    func stripMText(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "\\P", with: "\n")
        r = r.replacingOccurrences(of: "\\~", with: " ")
        // ponytail: best-effort regex; handles \X..., \X...;, color/height/font escapes.
        if let regex = try? NSRegularExpression(pattern: "\\\\[A-Za-z][^;\\\\]*;?") {
            let ns = r as NSString
            r = regex.stringByReplacingMatches(in: r, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        }
        r = r.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return stripDxfEscapes(r)
    }
    func emit(_ name: String) {
        let layer = attrs[8] ?? "0"
        // DEFPOINTS is a CAD convention for non-printing dimension definition points.
        // ezdxf and AutoCAD exclude its contents from bbox + render, so we do too.
        if frozenLayers.contains(layer) || layer.caseInsensitiveCompare("defpoints") == .orderedSame {
            return
        }
        let aci = resolveAci(layer: layer, entityAci: intVal(62, 256))
        func add(_ kind: DXFEntity.Kind) {
            appendEntity(DXFEntity(kind: kind, aci: aci, layer: layer))
        }
        switch name {
        case "LINE":
            add(.line(CGPoint(x: num(10), y: num(20)), CGPoint(x: num(11), y: num(21))))
        case "POINT":
            add(.point(CGPoint(x: num(10), y: num(20))))
        case "CIRCLE":
            add(.circle(CGPoint(x: num(10), y: num(20)), num(40)))
        case "ARC":
            add(.arc(CGPoint(x: num(10), y: num(20)), num(40), num(50), num(51)))
        case "ELLIPSE":
            let c = CGPoint(x: num(10), y: num(20))
            let mv = CGPoint(x: num(11), y: num(21))
            let ratio = num(40, 1)
            let sa = num(41, 0)
            let ea = num(42, 2 * .pi)
            add(.ellipse(c, mv, ratio, sa, ea))
        case "LWPOLYLINE":
            commitLWVertex()
            guard !lwVerts.isEmpty else { break }
            let closed = (intVal(70) & 1) == 1
            var pts: [CGPoint] = [lwVerts[0].0]
            for i in 0..<lwVerts.count - 1 {
                let a = lwVerts[i]
                let b = lwVerts[i + 1]
                if abs(a.1) > 1e-9 {
                    pts.append(contentsOf: tessellateBulge(a.0, b.0, bulge: a.1))
                }
                pts.append(b.0)
            }
            if closed, let last = lwVerts.last, abs(last.1) > 1e-9 {
                pts.append(contentsOf: tessellateBulge(last.0, lwVerts[0].0, bulge: last.1))
            }
            add(.polyline(pts, closed))
        case "TEXT":
            guard let raw = attrs[1], !raw.isEmpty else { break }
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
            // glyph box — vertically as well as horizontally. Without this override the
            // text rendered with baseline at the point, so dim numbers sat half a height
            // above the dim line and the line crossed through the digits.
            let vAlign = (g72 == 4) ? 2 : g73
            add(.text(pos, s, h, num(50), hAlign, vAlign, 0, 1.0))
        case "MTEXT":
            guard let raw = attrs[1], !raw.isEmpty else { break }
            let s = stripMText(raw)
            let h = num(40, 10)
            let att = intVal(71, 1) // attachment point 1..9; default 1 (TL)
            // Map attachment → hAlign 0/1/2 and vAlign 1/2/3 (DXF v-codes).
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
                case 1, 2, 3: return 3 // top
                case 4, 5, 6: return 2 // middle
                case 7, 8, 9: return 1 // bottom
                default: return 3
                }
            }()
            let wrapW = num(41, 0)
            let lineSp = num(44, 1)
            // Rotation: prefer explicit code 50; otherwise derive from the X-axis direction vector (11/21).
            var rot = num(50, 0)
            if abs(rot) < 1e-9 {
                let dx = num(11, 1)
                let dy = num(21, 0)
                if abs(dx - 1) > 1e-6 || abs(dy) > 1e-6 {
                    rot = atan2(dy, dx) * 180 / .pi
                }
            }
            add(.text(CGPoint(x: num(10), y: num(20)), s, h, rot, hAlign, vAlign, wrapW, lineSp))
        case "INSERT":
            let bn = attrs[2] ?? ""
            var px = num(10), py = num(20)
            var sx = num(41, 1), sy = num(42, 1)
            var rotDeg = num(50, 0)
            // OCS extrusion (210/220/230). For the common floorplan-xref case 230 = -1,
            // OCS→WCS is X-flip — but X-flip is applied AFTER any in-OCS rotation. Our
            // tx() applies mirror first, then rotation, so equivalent composition needs
            // the rotation negated. Verified: R(-θ)·MirrorX == MirrorX·R(θ).
            let extrZ = num(230, 1)
            if extrZ < 0 {
                px = -px
                sx = -sx
                rotDeg = -rotDeg
            }
            let ins = DXFInsert(
                blockName: bn,
                pos: CGPoint(x: px, y: py),
                sx: sx, sy: sy,
                rotDeg: rotDeg,
                isDim: false)
            add(.insert(ins))
        case "DIMENSION":
            let bn = attrs[2] ?? ""
            if !bn.isEmpty {
                let ins = DXFInsert(blockName: bn, pos: .zero, sx: 1, sy: 1, rotDeg: 0, isDim: true)
                add(.insert(ins))
            }
        case "SPLINE":
            if !splinePts.isEmpty {
                let closed = (splineFlags & 1) != 0
                add(.spline(splinePts, max(splineDegree, 1), splineKnots, closed))
            }
        case "HATCH":
            commitHatchVertex()
            // Empty boundary still gets recorded so the entity count matches ezdxf.
            add(.hatch(hatchVerts))
        case "LEADER":
            commitLWVertex()
            guard !lwVerts.isEmpty else { break }
            let extrZ = num(230, 1)
            var pts = lwVerts.map { $0.0 }
            if extrZ < 0 { pts = pts.map { CGPoint(x: -$0.x, y: $0.y) } }
            // One leader = one .leader entity (polyline path + arrow-head size). The
            // renderer expands it into the path + a tiny triangle at the tip.
            let arrow: CGFloat = {
                if pts.count >= 2 {
                    let a = pts[0], b = pts[1]
                    let segLen = hypot(b.x - a.x, b.y - a.y)
                    return max(num(40, segLen * 0.05), 1)
                }
                return num(40, 1)
            }()
            add(.leader(pts, arrow))
        default:
            break
        }
    }
    func reset() {
        current = nil; attrs = [:]
        polyVerts = []; polyClosed = false; polyLayer = ""; polyAci = 256
        pendingVertex = (nil, nil)
        lwVerts = []; lwLastVertex = (nil, nil, 0)
        splinePts = []; splineLastX = nil
        splineKnots = []; splineDegree = 3; splineFlags = 0
        hatchVerts = []; hatchLastVertex = (nil, nil); hatchInBoundary = false
    }

    for (code, value) in pairs {
        if code == 0 {
            // 1) Finalize the in-flight item
            if inLayer {
                if let name = attrs[2] {
                    let aci = intVal(62, 7)
                    layerColor[name] = abs(aci)
                    if (intVal(70) & 1) != 0 || aci < 0 { frozenLayers.insert(name) }
                }
                inLayer = false; attrs = [:]
            } else if inPoly {
                if value == "VERTEX" {
                    commitVertex(); current = "POLYLINE_VERTEX"; continue
                } else if value == "SEQEND" || value != "VERTEX" {
                    commitVertex()
                    if !polyVerts.isEmpty && !frozenLayers.contains(polyLayer) {
                        let aci = resolveAci(layer: polyLayer, entityAci: polyAci)
                        appendEntity(DXFEntity(kind: .polyline(polyVerts, polyClosed), aci: aci, layer: polyLayer))
                    }
                    inPoly = false; reset()
                    if value == "SEQEND" { continue }
                    // else fall through
                }
            } else if let c = current {
                emit(c); reset()
            }

            // 2) Section / block markers
            if value == "SECTION" { continue }
            if value == "ENDBLK" {
                if inBlock {
                    blocks[blockName] = (blockEntities, blockBase)
                    blockEntities = []; blockName = ""; blockBase = .zero; inBlock = false
                }
                continue
            }
            if value == "ENDTAB" { continue }
            if value == "ENDSEC" { section = .none; continue }
            if value == "EOF" { break }

            // 3) Dispatch on new entity name
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
        } else if code == 2 && (value == "ENTITIES" || value == "TABLES" || value == "BLOCKS") && !inLayer && !inBlock && current == nil {
            section = (value == "ENTITIES") ? .entities : (value == "BLOCKS") ? .blocks : .tables
        } else if inLayer {
            attrs[code] = value
        } else if current == "BLOCK_HEADER" {
            attrs[code] = value
            if code == 2 { blockName = value; inBlock = true; blockEntities = [] }
            else if code == 10 { blockBase.x = CGFloat(Double(value) ?? 0) }
            else if code == 20 { blockBase.y = CGFloat(Double(value) ?? 0) }
        } else if inPoly && current == "POLYLINE_HEADER" {
            if code == 70 { polyClosed = (Int(value) ?? 0) & 1 == 1 }
            else if code == 8 { polyLayer = value }
            else if code == 62 { polyAci = Int(value) ?? 256 }
        } else if inPoly {
            if code == 10 { pendingVertex.x = CGFloat(Double(value) ?? 0) }
            else if code == 20 { pendingVertex.y = CGFloat(Double(value) ?? 0) }
        } else if current == "LWPOLYLINE" {
            if code == 10 { commitLWVertex(); lwLastVertex.x = CGFloat(Double(value) ?? 0) }
            else if code == 20 { lwLastVertex.y = CGFloat(Double(value) ?? 0) }
            else if code == 42 { lwLastVertex.bulge = CGFloat(Double(value) ?? 0) }
            else { attrs[code] = value }
        } else if current == "LEADER" {
            if code == 10 { commitLWVertex(); lwLastVertex.x = CGFloat(Double(value) ?? 0) }
            else if code == 20 { lwLastVertex.y = CGFloat(Double(value) ?? 0) }
            else { attrs[code] = value }
        } else if current == "HATCH" {
            if code == 92 { hatchInBoundary = true; attrs[code] = value }
            else if hatchInBoundary && code == 10 {
                commitHatchVertex(); hatchLastVertex.x = CGFloat(Double(value) ?? 0)
            } else if hatchInBoundary && code == 20 {
                hatchLastVertex.y = CGFloat(Double(value) ?? 0)
            } else { attrs[code] = value }
        } else if current == "SPLINE" {
            if code == 10 { splineLastX = CGFloat(Double(value) ?? 0) }
            else if code == 20, let x = splineLastX {
                splinePts.append(CGPoint(x: x, y: CGFloat(Double(value) ?? 0)))
                splineLastX = nil
            } else if code == 40 {
                if let d = Double(value) { splineKnots.append(d) }
            } else if code == 70 {
                splineFlags = Int(value) ?? 0
            } else if code == 71 {
                splineDegree = Int(value) ?? 3
            } else { attrs[code] = value }
        } else if current != nil {
            attrs[code] = value
        }
    }
    if inLayer, let name = attrs[2] {
        let aci = intVal(62, 7)
        layerColor[name] = abs(aci)
        if (intVal(70) & 1) != 0 || aci < 0 { frozenLayers.insert(name) }
    } else if let c = current { emit(c) }

    let expanded = expandInserts(rawEntities, blocks: blocks, depth: 0)
    return DXFDocument(
        entities: expanded,
        bounds: computeBounds(expanded),
        layers: buildLayerInfo(expanded, layerColor: layerColor),
        mmPerUnit: mmPerUnit)
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
        // For DIMENSION inserts, accumulate children into a buffer and append a single
        // .dimension(children) at the end so the entity count matches ezdxf.
        var dimChildren: [DXFEntity] = []
        func emit(_ child: DXFEntity) {
            if ins.isDim { dimChildren.append(child) } else { out.append(child) }
        }
        for be in inner {
            let aci = be.aci
            // ponytail: standard DXF rule — entities on layer "0" inside a block adopt the insert's layer.
            let layer = (be.layer == "0") ? e.layer : be.layer
            if layer.caseInsensitiveCompare("defpoints") == .orderedSame { continue }
            switch be.kind {
            case .line(let a, let b):
                emit(DXFEntity(kind: .line(tx(a), tx(b)), aci: aci, layer: layer))
            case .point(let p):
                emit(DXFEntity(kind: .point(tx(p)), aci: aci, layer: layer))
            case .circle(let c, let r):
                // Uniform scale → circle keeps its identity. Non-uniform sx/sy turns it
                // into a rotated ellipse: major axis follows the larger scale direction.
                // ezdxf does the same when exploding INSERTs with anisotropic scale.
                if abs(abs(ins.sx) - abs(ins.sy)) < 1e-9 {
                    emit(DXFEntity(kind: .circle(tx(c), r * scaleAbs), aci: aci, layer: layer))
                } else {
                    let asx = abs(ins.sx), asy = abs(ins.sy)
                    let rMajor = r * max(asx, asy)
                    let ratio = min(asx, asy) / max(asx, asy)
                    // Major axis direction depends on which scale is larger (X vs Y).
                    let majorWorld: CGPoint = (asx >= asy)
                        ? CGPoint(x: rMajor * cosR, y: rMajor * sinR)
                        : CGPoint(x: -rMajor * sinR, y: rMajor * cosR)
                    emit(DXFEntity(
                        kind: .ellipse(tx(c), majorWorld, ratio, 0, 2 * .pi),
                        aci: aci, layer: layer))
                }
            case .arc(let c, let r, let sa, let ea):
                // DXF arcs are CCW. A single-axis mirror reverses direction → swap start/end
                // and reflect about the mirror axis so the renderer traces the same physical arc.
                let mx = ins.sx < 0, my = ins.sy < 0
                var nsa: CGFloat = sa, nea: CGFloat = ea
                if mx && my {
                    nsa = sa + 180; nea = ea + 180
                } else if mx {
                    nsa = 180 - ea; nea = 180 - sa
                } else if my {
                    nsa = -ea; nea = -sa
                }
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
            case .hatch(let pts):
                emit(DXFEntity(kind: .hatch(pts.map(tx)), aci: aci, layer: layer))
            case .dimension(let children):
                // Nested dim (rare) — pass through grouped.
                emit(DXFEntity(kind: .dimension(children), aci: aci, layer: layer))
            case .leader(let pts, let arrow):
                emit(DXFEntity(kind: .leader(pts.map(tx), arrow * scaleAbs), aci: aci, layer: layer))
            case .insert: break
            }
        }
        if ins.isDim {
            // Use the originating INSERT's layer for the dim wrapper.
            out.append(DXFEntity(kind: .dimension(dimChildren), aci: e.aci, layer: e.layer))
        }
    }
    return out
}

func computeBoundsForOne(_ e: DXFEntity) -> CGRect { computeBounds([e]) }

private func computeBounds(_ entities: [DXFEntity]) -> CGRect {
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
            // True arc bbox: endpoints + any axis-aligned extrema (0/90/180/270°) that
            // fall within the CCW sweep. Previously we used the full-circle bbox, which
            // gave us xmax/ymax overshoots whenever an arc only swept part of the circle.
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
            // Estimate glyph bbox around the insertion point so fit-to-window doesn't
            // crop text. Match the renderer's alignment math: hAlign 0/1/2 = L/C/R,
            // vAlign 0/1/2/3 = baseline/bottom/middle/top. Width uses wrapW when given,
            // else len*h*0.7 (roughly the SF aspect ratio). Height includes descender +
            // line gap (×1.6 of h × line count), then rotated about the insertion point.
            let lines = max(1, s.components(separatedBy: "\n").count)
            let glyphW = wrapW > 0 ? wrapW : max(1, CGFloat(s.count)) * h * 0.7
            // ezdxf's MTEXT bbox uses font-metric line height ≈ 2.95 × char height.
            // For single-line TEXT (no wrap width) ezdxf reports a much tighter bbox —
            // roughly cap height + descender (~1.3 × h). Use wrapW as the cheap MTEXT
            // detector; it's only set when MTEXT has an explicit wrap width.
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
            // The ellipse can be rotated (major axis ≠ X) and partial (sa..ea). Cheapest
            // accurate bbox: tessellate the swept arc and extend by each sample. 64 steps
            // matches the renderer so the bbox lines up with what gets drawn.
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
        case .hatch(let pts): pts.forEach(extend)
        case .dimension(let children):
            // Recurse into the dim's exploded children so they extend the bbox.
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
