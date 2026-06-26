import Foundation
import DXFViewerCore

// Write a DXF body to a temp file and parse it. Body is concatenated between SECTION
// HEADER (with a $INSUNITS=4 for mm) and a final EOF marker.
func parseInlineDXF(_ body: String) throws -> DXFDocument {
    let header = """
    0
    SECTION
    2
    HEADER
    9
    $INSUNITS
    70
    4
    0
    ENDSEC
    """
    let footer = """
    0
    ENDSEC
    0
    EOF
    """
    let full = header + "\n" + body + "\n" + footer + "\n"
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test-\(UUID().uuidString).dxf")
    try full.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    return try parseDXF(url: url)
}

// Wraps a list of entity blocks into a SECTION ENTITIES.
func entitiesSection(_ entityBlocks: String) -> String {
    """
    0
    SECTION
    2
    ENTITIES
    \(entityBlocks)
    """
}

// LAYER table fragment with optional color (code 62) and lineweight (code 370).
func layerTable(_ layers: [(name: String, aci: Int?, lw: Int?)]) -> String {
    var out = """
    0
    SECTION
    2
    TABLES
    0
    TABLE
    2
    LAYER
    """
    for L in layers {
        out += "\n0\nLAYER\n2\n\(L.name)\n70\n0"
        if let aci = L.aci { out += "\n62\n\(aci)" }
        if let lw = L.lw { out += "\n370\n\(lw)" }
    }
    out += "\n0\nENDTAB\n0\nENDSEC"
    return out
}
