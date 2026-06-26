import Foundation
import DXFViewerCore

// Group code 370 — display lineweight in hundredths of mm.
// Resolution chain: entity → layer (if -1) → $LWDEFAULT (if -3) → ByBlock falls back to default.

@MainActor
func registerLineweightTests() {
    tests.append(("lineweight/entity-explicit-keeps-value", {
        let dxf = entitiesSection("""
        0
        LINE
        8
        0
        10
        0
        20
        0
        11
        100
        21
        0
        370
        50
        """)
        let doc = try parseInlineDXF(dxf)
        try expectEqual(doc.entities.count, 1)
        try expectEqual(doc.entities[0].lineWeight, 50)
    }))

    tests.append(("lineweight/by-layer-resolution", {
        let body = layerTable([("WALLS", 1, 30)]) + "\n" + entitiesSection("""
        0
        LINE
        8
        WALLS
        10
        0
        20
        0
        11
        100
        21
        0
        370
        -1
        """)
        let doc = try parseInlineDXF(body)
        try expectEqual(doc.entities[0].lineWeight, 30)
    }))

    tests.append(("lineweight/default-(-3)-resolves-to-LWDEFAULT", {
        let dxf = entitiesSection("""
        0
        LINE
        8
        0
        10
        0
        20
        0
        11
        100
        21
        0
        370
        -3
        """)
        let doc = try parseInlineDXF(dxf)
        try expectEqual(doc.entities[0].lineWeight, dxfDefaultLineWeight)
    }))

    tests.append(("lineweight/by-block-(-2)-falls-back-outside-block", {
        let dxf = entitiesSection("""
        0
        LINE
        8
        0
        10
        0
        20
        0
        11
        100
        21
        0
        370
        -2
        """)
        let doc = try parseInlineDXF(dxf)
        try expectEqual(doc.entities[0].lineWeight, dxfDefaultLineWeight)
    }))

    tests.append(("lineweight/missing-370-inherits-layer", {
        let body = layerTable([("ROOFS", 7, 70)]) + "\n" + entitiesSection("""
        0
        LINE
        8
        ROOFS
        10
        0
        20
        0
        11
        100
        21
        0
        """)
        let doc = try parseInlineDXF(body)
        try expectEqual(doc.entities[0].lineWeight, 70)
    }))

    tests.append(("lineweight/out-of-range-clamps-to-211", {
        let dxf = entitiesSection("""
        0
        LINE
        8
        0
        10
        0
        20
        0
        11
        100
        21
        0
        370
        999
        """)
        let doc = try parseInlineDXF(dxf)
        try expectEqual(doc.entities[0].lineWeight, 211)
    }))
}
