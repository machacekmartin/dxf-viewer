import Foundation
import CoreGraphics

struct DXFInsert: Sendable {
    let blockName: String
    let pos: CGPoint
    let sx: CGFloat
    let sy: CGFloat
    let rotDeg: CGFloat
    // True → expandInserts groups the children under a single .dimension(children) entity
    // so a DIMENSION counts as one entity instead of its exploded line/text constituents.
    let isDim: Bool
}

struct HatchBoundary: Sendable {
    var verts: [CGPoint]
    var closed: Bool
}

struct HatchPatternLine: Sendable {
    var angleDeg: CGFloat        // final stripe angle (entity 52 + pattern-line 53)
    var basePoint: CGPoint       // codes 43/44 (already scaled + rotated by entity angle)
    var offset: CGPoint          // codes 45/46 (scaled + rotated). Perpendicular delta between parallels.
    var dashes: [CGFloat]        // code 49 entries. Empty → solid line. Positive = dash, negative = gap.
}

struct HatchData: Sendable {
    var boundaries: [HatchBoundary]
    var isSolid: Bool            // code 70
    var pattern: [HatchPatternLine]
    var patternScale: CGFloat    // code 41 (kept for diagnostics)
    var patternAngle: CGFloat    // code 52 (kept for diagnostics)
}

struct DXFEntity: Sendable {
    enum Kind: Sendable {
        case line(CGPoint, CGPoint)
        case point(CGPoint)
        case circle(CGPoint, CGFloat)
        case arc(CGPoint, CGFloat, CGFloat, CGFloat) // center, radius, startDeg, endDeg
        case polyline([CGPoint], Bool)
        // pos, str, world-units height, rotation, hAlign 0-2 (L/C/R),
        // vAlign 0-3 (baseline/bottom/middle/top), wrapWidth (0=none), lineSpacing.
        case text(CGPoint, String, CGFloat, CGFloat, Int, Int, CGFloat, CGFloat)
        case ellipse(CGPoint, CGPoint, CGFloat, CGFloat, CGFloat)
        case spline([CGPoint], Int, [Double], Bool)
        case hatch(HatchData)
        indirect case dimension([DXFEntity])
        case leader([CGPoint], CGFloat)
        case insert(DXFInsert)
    }
    let kind: Kind
    let aci: Int // AutoCAD Color Index; 7 = default
    let layer: String
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

struct DXFLayerInfo: Sendable {
    let name: String
    let aci: Int
    let count: Int
    let kinds: [Kind]

    struct Kind: Sendable {
        let name: String
        let indices: [Int]
        var count: Int { indices.count }
    }
}

struct DXFDocument: Sendable {
    let entities: [DXFEntity]
    let bounds: CGRect
    let layers: [DXFLayerInfo]
    // Multiplier from $INSUNITS to convert one world unit into millimetres.
    let mmPerUnit: CGFloat
}

// $INSUNITS code → mm-per-world-unit. 1 mm when units are unknown.
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
    default: return 1
    }
}
