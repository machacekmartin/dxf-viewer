import Foundation
import DXFViewerCore

func usage() -> Never {
    print("Usage: DXFRender <input.dxf> <output.png> [--width N] [--height N] [-v]")
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var width = 1600
var height = 1200
var verbose = false

var positional: [String] = []
var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "--width":
        i += 1; guard i < args.count, let n = Int(args[i]) else { usage() }
        width = n
    case "--height":
        i += 1; guard i < args.count, let n = Int(args[i]) else { usage() }
        height = n
    case "-v", "--verbose":
        verbose = true
    default:
        positional.append(a)
    }
    i += 1
}

guard positional.count == 2 else { usage() }
let inURL = URL(fileURLWithPath: positional[0])
let outURL = URL(fileURLWithPath: positional[1])

do {
    let doc = try parseDXF(url: inURL)
    if verbose {
        print("Entities: \(doc.entities.count)  Bounds: \(doc.bounds)  mmPerUnit: \(doc.mmPerUnit)")
    }
    var config = HeadlessRenderConfig(width: width, height: height)
    config.verbose = verbose
    try renderHeadless(doc: doc, to: outURL, config: config)
    print("Wrote \(outURL.path)")
} catch {
    print("ERROR: \(error)")
    exit(1)
}
