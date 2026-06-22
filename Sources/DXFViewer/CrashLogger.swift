import Foundation
#if canImport(MetricKit)
import MetricKit
#endif

/// MetricKit subscriber that drops crash + hang + cpu-exception diagnostics
/// into a local log directory. Nothing leaves the machine.
///
/// Path under the App Sandbox:
///   ~/Library/Containers/com.machacekmartin.dxfviewer/Data/Library/Logs/DXFViewer/
@MainActor
final class CrashLogger: NSObject {
    static let shared = CrashLogger()

    private let logDir: URL = {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = lib.appendingPathComponent("Logs/DXFViewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func install() {
        #if canImport(MetricKit)
        MXMetricManager.shared.add(self)
        #endif
    }

    private func filename(_ prefix: String) -> String {
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "\(prefix)-\(ts).json"
    }

    private func write(_ data: Data, prefix: String) {
        let url = logDir.appendingPathComponent(filename(prefix))
        try? data.write(to: url, options: .atomic)
    }
}

#if canImport(MetricKit)
extension CrashLogger: @preconcurrency MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads { write(p.jsonRepresentation(), prefix: "metric") }
    }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { write(p.jsonRepresentation(), prefix: "diagnostic") }
    }
}
#endif
