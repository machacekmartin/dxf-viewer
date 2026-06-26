import SwiftUI
import Foundation
import AppKit
import DXFViewerCore

// MARK: - Notifications driven by menu commands

extension Notification.Name {
    static let dxfZoomIn  = Notification.Name("com.machacekmartin.dxfviewer.zoomIn")
    static let dxfZoomOut = Notification.Name("com.machacekmartin.dxfviewer.zoomOut")
    static let dxfFit     = Notification.Name("com.machacekmartin.dxfviewer.fit")
    static let dxfFocusBounds = Notification.Name("com.machacekmartin.dxfviewer.focusBounds")
}

// MARK: - CLI fingerprint helpers (used by tools/validate.py)

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

func entityBBox(_ e: DXFEntity) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    let r = computeBoundsForOne(e)
    return (r.minX, r.minY, r.maxX, r.maxY)
}

func dxfKindUppercase(_ k: DXFEntity.Kind) -> String {
    switch k {
    case .line: return "LINE"
    case .point: return "POINT"
    case .circle: return "CIRCLE"
    case .arc: return "ARC"
    case .polyline: return "POLYLINE"
    case .widePolyline: return "POLYLINE"
    case .solid: return "SOLID"
    case .text: return "TEXT"
    case .ellipse: return "ELLIPSE"
    case .spline: return "SPLINE"
    case .hatch: return "HATCH"
    case .dimension: return "DIMENSION"
    case .leader: return "LEADER"
    case .insert: return "INSERT"
    }
}

// MARK: - AppKit delegate (Finder open + drag-onto-Dock + crash logger)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashLogger.shared.install()
        Task { @MainActor in _ = UpdaterController.shared }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { OpenCoordinator.shared.open(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - App entry

@main
struct DXFViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = OpenCoordinator.shared
    @StateObject private var updater = UpdaterController.shared

    init() {
        // Raw binary launched from terminal doesn't auto-foreground; force it.
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
                        print("\(idx)\t\(dxfKindUppercase(e.kind))\tlayer=\(e.layer)\txmin=\(xmn)\tymin=\(ymn)\txmax=\(xmx)\tymax=\(ymx)\tdesc=\(entityDescription(e))")
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
                .environmentObject(coordinator)
                .ignoresSafeArea()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { coordinator.openPicker() }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    if coordinator.recents.isEmpty {
                        Text("No Recent Documents")
                    } else {
                        ForEach(coordinator.recents, id: \.self) { url in
                            Button(url.lastPathComponent) { coordinator.open(url) }
                        }
                        Divider()
                        Button("Clear Menu") { coordinator.clearRecents() }
                    }
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    NotificationCenter.default.post(name: .dxfZoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .dxfZoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button("Fit to Window") {
                    NotificationCenter.default.post(name: .dxfFit, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("DXF Viewer Help") {
                    if let url = URL(string: "https://github.com/machacekmartin/dxf-viewer#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
