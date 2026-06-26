import Foundation
import CoreGraphics
import DXFViewerCore

// LWPOLYLINE width:  43 = constant; 40 = per-vertex start; 41 = per-vertex end.

@MainActor
func registerWidePolylineTests() {
    tests.append(("widePolyline/constant-43-becomes-widePolyline", {
        let dxf = entitiesSection("""
        0
        LWPOLYLINE
        8
        0
        90
        2
        70
        0
        43
        50.0
        10
        0
        20
        0
        10
        100
        20
        0
        """)
        let doc = try parseInlineDXF(dxf)
        guard case .widePolyline(let verts, let closed) = doc.entities[0].kind else {
            throw TestFailure.expectation("expected widePolyline, got \(doc.entities[0].kind)")
        }
        try expectEqual(closed, false)
        try expectEqual(verts.count, 2)
        try expectClose(verts[0].startWidth, 50)
        try expectClose(verts[0].endWidth, 50)
        try expectClose(verts[1].startWidth, 50)
        try expectClose(verts[1].endWidth, 50)
    }))

    tests.append(("widePolyline/zero-width-stays-thin", {
        let dxf = entitiesSection("""
        0
        LWPOLYLINE
        8
        0
        90
        2
        70
        0
        43
        0.0
        10
        0
        20
        0
        10
        100
        20
        0
        """)
        let doc = try parseInlineDXF(dxf)
        if case .polyline = doc.entities[0].kind {} else {
            throw TestFailure.expectation("expected polyline, got \(doc.entities[0].kind)")
        }
    }))

    tests.append(("widePolyline/per-vertex-40-41-tapered", {
        let dxf = entitiesSection("""
        0
        LWPOLYLINE
        8
        0
        90
        2
        70
        0
        10
        0
        20
        0
        40
        10.0
        41
        50.0
        10
        100
        20
        0
        40
        50.0
        41
        50.0
        """)
        let doc = try parseInlineDXF(dxf)
        guard case .widePolyline(let verts, _) = doc.entities[0].kind else {
            throw TestFailure.expectation("expected widePolyline, got \(doc.entities[0].kind)")
        }
        try expectClose(verts[0].startWidth, 10)
        try expectClose(verts[0].endWidth, 50)
        try expectClose(verts[1].startWidth, 50)
        try expectClose(verts[1].endWidth, 50)
    }))

    tests.append(("widePolyline/bulge-preserved", {
        let dxf = entitiesSection("""
        0
        LWPOLYLINE
        8
        0
        90
        2
        70
        0
        43
        20.0
        10
        0
        20
        0
        42
        1.0
        10
        100
        20
        0
        """)
        let doc = try parseInlineDXF(dxf)
        guard case .widePolyline(let verts, _) = doc.entities[0].kind else {
            throw TestFailure.expectation("expected widePolyline, got \(doc.entities[0].kind)")
        }
        try expectClose(verts[0].bulge, 1.0)
    }))

    // Geometry tests for trapezoid math (no DXF involved).

    tests.append(("widePolyline-geom/straight-uniform-bbox-matches-width", {
        let verts = [
            WidePolylineVertex(point: .init(x: 0, y: 0), bulge: 0, startWidth: 10, endWidth: 10),
            WidePolylineVertex(point: .init(x: 100, y: 0), bulge: 0, startWidth: 10, endWidth: 10),
        ]
        let path = widePolylinePath(verts: verts, closed: false)
        let bbox = path.boundingBox
        try expectClose(bbox.minX, 0)
        try expectClose(bbox.maxX, 100)
        try expectClose(bbox.minY, -5)
        try expectClose(bbox.maxY, 5)
    }))

    tests.append(("widePolyline-geom/tapered-bbox-grows-with-wider-end", {
        let verts = [
            WidePolylineVertex(point: .init(x: 0, y: 0), bulge: 0, startWidth: 10, endWidth: 50),
            WidePolylineVertex(point: .init(x: 100, y: 0), bulge: 0, startWidth: 50, endWidth: 50),
        ]
        let path = widePolylinePath(verts: verts, closed: false)
        let bbox = path.boundingBox
        try expectClose(bbox.minY, -25)
        try expectClose(bbox.maxY, 25)
    }))

    tests.append(("widePolyline-geom/diagonal-normal-projects-correctly", {
        let w: CGFloat = 2 * CGFloat(sqrt(2.0))
        let verts = [
            WidePolylineVertex(point: .init(x: 0, y: 0), bulge: 0, startWidth: w, endWidth: w),
            WidePolylineVertex(point: .init(x: 100, y: 100), bulge: 0, startWidth: w, endWidth: w),
        ]
        let path = widePolylinePath(verts: verts, closed: false)
        let bbox = path.boundingBox
        try expectClose(bbox.minX, -1, tolerance: 1e-6)
        try expectClose(bbox.maxY, 101, tolerance: 1e-6)
    }))

    tests.append(("widePolyline-geom/zero-length-segment-empty-path", {
        let verts = [
            WidePolylineVertex(point: .init(x: 5, y: 5), bulge: 0, startWidth: 10, endWidth: 10),
            WidePolylineVertex(point: .init(x: 5, y: 5), bulge: 0, startWidth: 10, endWidth: 10),
        ]
        let path = widePolylinePath(verts: verts, closed: false)
        try expect(path.isEmpty)
    }))

    // Constant-width classification + centerline generation. Renderer relies on
    // these to choose stroke-with-floor vs filled trapezoid.
    tests.append(("widePolyline/constantWidth-detects-uniform", {
        let verts = [
            WidePolylineVertex(point: .init(x: 0, y: 0), bulge: 0, startWidth: 50, endWidth: 50),
            WidePolylineVertex(point: .init(x: 100, y: 0), bulge: 0, startWidth: 50, endWidth: 50),
            WidePolylineVertex(point: .init(x: 100, y: 100), bulge: 0, startWidth: 50, endWidth: 50),
        ]
        try expectEqual(constantWidth(of: verts), 50)
    }))

    tests.append(("widePolyline/constantWidth-nil-for-tapered", {
        let verts = [
            WidePolylineVertex(point: .init(x: 0, y: 0), bulge: 0, startWidth: 10, endWidth: 50),
            WidePolylineVertex(point: .init(x: 100, y: 0), bulge: 0, startWidth: 50, endWidth: 50),
        ]
        try expect(constantWidth(of: verts) == nil)
    }))

    tests.append(("widePolyline/centerline-closed-rectangle-bbox-matches-verts", {
        let verts = [
            WidePolylineVertex(point: .init(x: 0, y: 0), bulge: 0, startWidth: 50, endWidth: 50),
            WidePolylineVertex(point: .init(x: 100, y: 0), bulge: 0, startWidth: 50, endWidth: 50),
            WidePolylineVertex(point: .init(x: 100, y: 100), bulge: 0, startWidth: 50, endWidth: 50),
            WidePolylineVertex(point: .init(x: 0, y: 100), bulge: 0, startWidth: 50, endWidth: 50),
        ]
        let path = centerlinePath(verts: verts, closed: true)
        let bbox = path.boundingBox
        // Centerline bbox = vertex extents (stroke width applied at render time).
        try expectClose(bbox.minX, 0)
        try expectClose(bbox.minY, 0)
        try expectClose(bbox.maxX, 100)
        try expectClose(bbox.maxY, 100)
    }))
}
