import Foundation
import CoreGraphics

public struct DXFInsert: Sendable {
    public let blockName: String
    public let pos: CGPoint
    public let sx: CGFloat
    public let sy: CGFloat
    public let rotDeg: CGFloat
    // True → expandInserts groups the children under a single .dimension(children) entity
    // so a DIMENSION counts as one entity instead of its exploded line/text constituents.
    public let isDim: Bool

    public init(blockName: String, pos: CGPoint, sx: CGFloat, sy: CGFloat, rotDeg: CGFloat, isDim: Bool) {
        self.blockName = blockName; self.pos = pos; self.sx = sx; self.sy = sy
        self.rotDeg = rotDeg; self.isDim = isDim
    }
}

public struct HatchBoundary: Sendable {
    public var verts: [CGPoint]
    public var closed: Bool
    public init(verts: [CGPoint], closed: Bool) { self.verts = verts; self.closed = closed }
}

public struct HatchPatternLine: Sendable {
    public var angleDeg: CGFloat        // final stripe angle (entity 52 + pattern-line 53)
    public var basePoint: CGPoint       // codes 43/44 (already scaled + rotated by entity angle)
    public var offset: CGPoint          // codes 45/46 (scaled + rotated). Perpendicular delta between parallels.
    public var dashes: [CGFloat]        // code 49 entries. Empty → solid line. Positive = dash, negative = gap.

    public init(angleDeg: CGFloat, basePoint: CGPoint, offset: CGPoint, dashes: [CGFloat]) {
        self.angleDeg = angleDeg; self.basePoint = basePoint; self.offset = offset; self.dashes = dashes
    }
}

public struct HatchData: Sendable {
    public var boundaries: [HatchBoundary]
    public var isSolid: Bool            // code 70
    public var pattern: [HatchPatternLine]
    public var patternScale: CGFloat    // code 41 (kept for diagnostics)
    public var patternAngle: CGFloat    // code 52 (kept for diagnostics)

    public init(boundaries: [HatchBoundary], isSolid: Bool, pattern: [HatchPatternLine], patternScale: CGFloat, patternAngle: CGFloat) {
        self.boundaries = boundaries; self.isSolid = isSolid; self.pattern = pattern
        self.patternScale = patternScale; self.patternAngle = patternAngle
    }
}

// One vertex of a wide polyline. Widths are world units; AutoCAD interpolates linearly
// across the segment from this vertex's endWidth to the next vertex's startWidth.
public struct WidePolylineVertex: Sendable {
    public var point: CGPoint
    public var bulge: CGFloat       // segment arc bulge; 0 = straight
    public var startWidth: CGFloat  // width at this vertex looking INTO the next segment
    public var endWidth: CGFloat    // width at the next vertex looking INTO this segment

    public init(point: CGPoint, bulge: CGFloat, startWidth: CGFloat, endWidth: CGFloat) {
        self.point = point; self.bulge = bulge; self.startWidth = startWidth; self.endWidth = endWidth
    }
}

public struct DXFEntity: Sendable {
    public enum Kind: Sendable {
        case line(CGPoint, CGPoint)
        case point(CGPoint)
        case circle(CGPoint, CGFloat)
        case arc(CGPoint, CGFloat, CGFloat, CGFloat) // center, radius, startDeg, endDeg
        case polyline([CGPoint], Bool)
        // Wide polyline (LWPOLYLINE code 43 / per-vertex 40+41, POLYLINE header 40/41).
        // Drawn as filled trapezoid band per segment, world-scaled.
        case widePolyline([WidePolylineVertex], Bool)
        // SOLID / TRACE / 3DFACE: filled polygon with 3 or 4 corners. DXF code 10/20,
        // 11/21, 12/22, 13/23. AutoCAD's vertex order for SOLID is "Z-style" (TL, TR,
        // BL, BR) — parser must reorder to a sane CCW polygon before storing.
        case solid([CGPoint])
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
    public let kind: Kind
    public let aci: Int // AutoCAD Color Index; 7 = default
    public let layer: String
    // DXF group code 370 resolved: hundredths of mm (0…211). 25 = 0.25mm (AutoCAD default).
    public let lineWeight: Int
    // DXF group code 39: 3D extrusion height along the entity's extrusion direction (default +Z).
    // In a 2D plan view this projects to a no-op for +Z extrusion. Stored so 3D-aware code
    // (export, future side views) can use it.
    // ponytail: parsed + carried but not rendered; add an isometric/side view if needed.
    public let thickness: CGFloat

    public init(kind: Kind, aci: Int, layer: String, lineWeight: Int = 25, thickness: CGFloat = 0) {
        self.kind = kind
        self.aci = aci
        self.layer = layer
        self.lineWeight = lineWeight
        self.thickness = thickness
    }
}

// AutoCAD's $LWDEFAULT fallback when an entity / layer reports -3 (default) or has no 370.
public let dxfDefaultLineWeight = 25

extension DXFEntity.Kind {
    public var typeName: String {
        switch self {
        case .line: return "line"
        case .point: return "point"
        case .circle: return "circle"
        case .arc: return "arc"
        case .polyline: return "polyline"
        case .widePolyline: return "polyline"
        case .solid: return "solid"
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

public struct DXFLayerInfo: Sendable {
    public let name: String
    public let aci: Int
    public let count: Int
    public let kinds: [Kind]

    public struct Kind: Sendable {
        public let name: String
        public let indices: [Int]
        public var count: Int { indices.count }
        public init(name: String, indices: [Int]) { self.name = name; self.indices = indices }
    }

    public init(name: String, aci: Int, count: Int, kinds: [Kind]) {
        self.name = name; self.aci = aci; self.count = count; self.kinds = kinds
    }
}

public struct DXFDocument: Sendable {
    public let entities: [DXFEntity]
    public let bounds: CGRect
    public let layers: [DXFLayerInfo]
    // Multiplier from $INSUNITS to convert one world unit into millimetres.
    public let mmPerUnit: CGFloat

    public init(entities: [DXFEntity], bounds: CGRect, layers: [DXFLayerInfo], mmPerUnit: CGFloat) {
        self.entities = entities; self.bounds = bounds; self.layers = layers; self.mmPerUnit = mmPerUnit
    }
}

// $INSUNITS code → mm-per-world-unit. 1 mm when units are unknown.
public func mmPerInsunit(_ code: Int) -> CGFloat {
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
