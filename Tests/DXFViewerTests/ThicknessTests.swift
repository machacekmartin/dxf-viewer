import Foundation
import DXFViewerCore

// Group code 39 — 3D extrusion height. Parser captures on every entity; the 2D plan-view
// renderer is no-op (top-down projection of +Z extrusion has no visible effect).

@MainActor
func registerThicknessTests() {
    tests.append(("thickness/line-captures-39", {
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
        39
        25.0
        """)
        let doc = try parseInlineDXF(dxf)
        try expectClose(doc.entities[0].thickness, 25.0)
    }))

    tests.append(("thickness/circle-captures-39", {
        let dxf = entitiesSection("""
        0
        CIRCLE
        8
        0
        10
        50
        20
        50
        40
        10
        39
        12.5
        """)
        let doc = try parseInlineDXF(dxf)
        if case .circle = doc.entities[0].kind {} else {
            throw TestFailure.expectation("expected circle, got \(doc.entities[0].kind)")
        }
        try expectClose(doc.entities[0].thickness, 12.5)
    }))

    tests.append(("thickness/missing-39-defaults-to-zero", {
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
        """)
        let doc = try parseInlineDXF(dxf)
        try expectClose(doc.entities[0].thickness, 0)
    }))
}
