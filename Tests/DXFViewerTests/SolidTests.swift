import Foundation
import CoreGraphics
import DXFViewerCore

// SOLID / TRACE / 3DFACE — filled polygon entity. DXF stores corners in Z-order
// (TL, TR, BL, BR); parser reorders to a CCW outline. If only 3 corners given
// (or 4th == 3rd), it's a triangle.

@MainActor
func registerSolidTests() {
    tests.append(("solid/triangle-3corners", {
        // 10/20=A, 11/21=B, 12/22=C, no 13/23 → triangle.
        let dxf = entitiesSection("""
        0
        SOLID
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
        12
        50
        22
        100
        """)
        let doc = try parseInlineDXF(dxf)
        guard case .solid(let pts) = doc.entities[0].kind else {
            throw TestFailure.expectation("expected solid, got \(doc.entities[0].kind)")
        }
        try expectEqual(pts.count, 3)
        try expectClose(pts[0].x, 0); try expectClose(pts[0].y, 0)
        try expectClose(pts[1].x, 100); try expectClose(pts[1].y, 0)
        try expectClose(pts[2].x, 50); try expectClose(pts[2].y, 100)
    }))

    tests.append(("solid/quad-reorders-Z-style-to-CCW-outline", {
        // SOLID's wire order: 10=TL, 11=TR, 12=BL, 13=BR. Outline must walk TL→TR→BR→BL.
        let dxf = entitiesSection("""
        0
        SOLID
        8
        0
        10
        0
        20
        100
        11
        100
        21
        100
        12
        0
        22
        0
        13
        100
        23
        0
        """)
        let doc = try parseInlineDXF(dxf)
        guard case .solid(let pts) = doc.entities[0].kind else {
            throw TestFailure.expectation("expected solid, got \(doc.entities[0].kind)")
        }
        try expectEqual(pts.count, 4)
        // TL → TR → BR → BL.
        try expectClose(pts[0].x, 0); try expectClose(pts[0].y, 100)
        try expectClose(pts[1].x, 100); try expectClose(pts[1].y, 100)
        try expectClose(pts[2].x, 100); try expectClose(pts[2].y, 0)
        try expectClose(pts[3].x, 0); try expectClose(pts[3].y, 0)
    }))

    tests.append(("solid/quad-with-13==12-is-triangle", {
        let dxf = entitiesSection("""
        0
        SOLID
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
        12
        50
        22
        100
        13
        50
        23
        100
        """)
        let doc = try parseInlineDXF(dxf)
        guard case .solid(let pts) = doc.entities[0].kind else {
            throw TestFailure.expectation("expected solid"); return
        }
        try expectEqual(pts.count, 3)
    }))

    tests.append(("solid/routes-to-fill-bucket", {
        let dxf = entitiesSection("""
        0
        SOLID
        8
        0
        62
        1
        10
        0
        20
        0
        11
        100
        21
        0
        12
        50
        22
        100
        """)
        let doc = try parseInlineDXF(dxf)
        let rm = DXFRenderModel.build(from: doc)
        try expect(rm.bulkFill.count == 1, "SOLID must produce exactly one fill bucket, got \(rm.bulkFill.count)")
    }))
}
