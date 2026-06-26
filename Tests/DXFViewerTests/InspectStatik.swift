import Foundation
import CoreGraphics
import DXFViewerCore

// Diagnostic dump (not a test). Called from main.swift via registerInspectStatik().

@MainActor
func registerInspectStatik() {
    tests.append(("inspect/statik-dump", {
        let url = try fixtureURLForInspect("statik-design.dxf")
        let doc = try parseDXF(url: url)
        print("    bounds = \(doc.bounds)")
        print("    drawing size = \(doc.bounds.width) × \(doc.bounds.height) world units")
        print("    mmPerUnit = \(doc.mmPerUnit)  → \(doc.bounds.width * doc.mmPerUnit / 1000) × \(doc.bounds.height * doc.mmPerUnit / 1000) m")
        print("    entity count = \(doc.entities.count)")
        var byKind: [String: Int] = [:]
        for e in doc.entities {
            byKind[e.kind.typeName, default: 0] += 1
        }
        print("    by kind: \(byKind)")

        // Lineweight distribution by layer (covers the 370-driven path).
        var lwByLayer: [String: Set<Int>] = [:]
        for e in doc.entities {
            lwByLayer[e.layer, default: []].insert(e.lineWeight)
        }
        print("    layers + lineweights:")
        for (layer, weights) in lwByLayer.sorted(by: { $0.key < $1.key }) {
            print("      \(layer)  weights=\(Array(weights).sorted())")
        }

        // Wide polyline detail.
        var shown = 0
        for e in doc.entities {
            guard case .widePolyline(let verts, let closed) = e.kind else { continue }
            shown += 1
            if shown > 5 { break }
            let maxW = verts.map { max($0.startWidth, $0.endWidth) }.max() ?? 0
            let bbox = computeBoundsForOne(e)
            print("    wide[\(shown)] layer=\(e.layer) verts=\(verts.count) closed=\(closed) width=\(maxW)  bbox=\(bbox)")
        }
    }))
}

private func fixtureURLForInspect(_ name: String) throws -> URL {
    if let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") {
        return url
    }
    throw TestFailure.expectation("missing fixture: \(name)")
}
