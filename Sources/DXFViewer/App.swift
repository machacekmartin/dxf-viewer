import SwiftUI
import Foundation
import AppKit

// Build a structured fingerprint of the parse result for the cross-check harness
// (tools/validate.py). Schema is shared with tools/ezdxf_ref.py: { file, ok,
// entity_count, by_kind: {LINE: n, …}, by_layer: {name: n}, bounds: {xmin,…},
// mm_per_unit, sample_texts }.
func parseFingerprintJSON(doc: DXFDocument, fileName: String) -> String {
    var byKind: [String: Int] = [:]
    var byLayer: [String: Int] = [:]
    var sampleTexts: [String] = []
    for e in doc.entities {
        let kind = dxfKindUppercase(e.kind)
        byKind[kind, default: 0] += 1
        byLayer[e.layer, default: 0] += 1
        if case .text(_, let str, _, _, _, _, _, _) = e.kind, sampleTexts.count < 5 {
            sampleTexts.append(str)
        }
    }
    let payload: [String: Any] = [
        "file": fileName,
        "ok": true,
        "entity_count": doc.entities.count,
        "by_kind": byKind,
        "by_layer": byLayer,
        "bounds": [
            "xmin": Double(doc.bounds.minX),
            "ymin": Double(doc.bounds.minY),
            "xmax": Double(doc.bounds.maxX),
            "ymax": Double(doc.bounds.maxY)
        ],
        "mm_per_unit": Double(doc.mmPerUnit),
        "sample_texts": sampleTexts
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

// Single-entity bounds helper for --dump. Reuses the document-level computeBounds
// indirectly via a one-element list.
func entityBBox(_ e: DXFEntity) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    let r = computeBoundsForOne(e)
    return (r.minX, r.minY, r.maxX, r.maxY)
}

// Match ezdxf's `dxftype()` output so the validator can diff like-for-like.
// LWPOLYLINE collapses into POLYLINE on both sides; MTEXT collapses into TEXT.
func dxfKindUppercase(_ k: DXFEntity.Kind) -> String {
    switch k {
    case .line: return "LINE"
    case .point: return "POINT"
    case .circle: return "CIRCLE"
    case .arc: return "ARC"
    case .polyline: return "POLYLINE"
    case .text: return "TEXT"
    case .ellipse: return "ELLIPSE"
    case .spline: return "SPLINE"
    case .hatch: return "HATCH"
    case .dimension: return "DIMENSION"
    case .leader: return "LEADER"
    case .insert: return "INSERT"
    }
}

@main
struct DXFViewerApp: App {
    init() {
        // ponytail: raw binary launched from terminal doesn't auto-foreground; force it.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        // ponytail: argv self-check.
        //   DXFViewer --parse file.dxf          → "entities=N bounds=..."
        //   DXFViewer --parse file.dxf --json   → JSON fingerprint for the validator
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--parse"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            let jsonMode = args.contains("--json")
            let dumpMode = args.contains("--dump")
            do {
                let doc = try parseDXF(url: url)
                if dumpMode {
                    for (idx, e) in doc.entities.enumerated() {
                        let (xmn, ymn, xmx, ymx) = entityBBox(e)
                        print("\(idx)\t\(dxfKindUppercase(e.kind))\tlayer=\(e.layer)\txmin=\(xmn)\tymin=\(ymn)\txmax=\(xmx)\tymax=\(ymx)")
                    }
                } else if jsonMode {
                    print(parseFingerprintJSON(doc: doc, fileName: url.lastPathComponent))
                } else {
                    print("entities=\(doc.entities.count) bounds=\(doc.bounds)")
                }
                exit(0)
            } catch {
                if jsonMode {
                    let payload: [String: Any] = [
                        "file": url.lastPathComponent,
                        "ok": false,
                        "error": "\(error)"
                    ]
                    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
                    print(String(data: data, encoding: .utf8) ?? "{}")
                } else {
                    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                }
                exit(1)
            }
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    }
}
