import Foundation
import CoreGraphics
import DXFViewerCore

// Regression test for examples/statik-design.dxf (current revision).
// Inventory by `awk` on the raw file:
//   - 32 LINE entities (mostly KOTY/dimension layers)
//   - 12 SOLID entities (concrete fills on _BETON layers) ← parser MUST keep these
//   -  4 LWPOLYLINE entities (no width 43, just outlines)
//   -  7 MTEXT entities, plus block/inserts

@MainActor
func registerStatikFixtureTests() {
    tests.append(("statik/parses", {
        let url = try fixtureURL("statik-design.dxf")
        let doc = try parseDXF(url: url)
        try expect(doc.entities.count > 0)
    }))

    tests.append(("statik/SOLIDs-present-and-on-BETON-layers", {
        let url = try fixtureURL("statik-design.dxf")
        let doc = try parseDXF(url: url)
        let solids = doc.entities.compactMap { e -> (String, [CGPoint])? in
            if case .solid(let pts) = e.kind { return (e.layer, pts) } else { return nil }
        }
        // Block expansion multiplies SOLIDs (one block instance per column/truss).
        // We just verify they're present and exclusively on _BETON layers.
        try expect(solids.count > 0, "no SOLID entities parsed")
        let nonBeton = solids.filter { !$0.0.contains("BETON") }
        try expectEqual(nonBeton.count, 0)
    }))

    tests.append(("statik/SOLID-routed-to-bulkFill", {
        let url = try fixtureURL("statik-design.dxf")
        let doc = try parseDXF(url: url)
        let rm = DXFRenderModel.build(from: doc)
        // The 12 SOLIDs are all on aci=7 layers → bulkFill should have an entry
        // for at least that color. If SOLID rendering is skipped, bulkFill is empty.
        try expect(!rm.bulkFill.isEmpty, "SOLIDs missing from bulkFill — concrete will be invisible")
    }))
}

private func fixtureURL(_ name: String) throws -> URL {
    if let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
        return url
    }
    if let url = Bundle.module.url(forResource: name, withExtension: nil) {
        return url
    }
    throw TestFailure.expectation("missing fixture: \(name)")
}
