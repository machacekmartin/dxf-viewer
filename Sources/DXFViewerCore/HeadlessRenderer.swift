import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Mirror of the live SwiftUI Canvas render path, but talking directly to a CGContext.
// Used by the headless `DXFRender` tool so we can diff what the renderer is actually
// producing against what the user sees on screen.
//
// The same bucketing → stroke/fill flow as DXFCanvas.drawEntities, minus selection.

public struct HeadlessRenderConfig {
    public var width: Int
    public var height: Int
    public var pad: CGFloat = 40
    public var background: CGColor = CGColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1)
    public var wideStrokeMinPx: CGFloat = 2.5      // matches DXFCanvas.wideStrokeScreenWidth
    public var pointsPerMM: CGFloat = 3.7795276    // 25.4mm/inch ÷ 96dpi, screen-independent
    public var verbose: Bool = false

    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

public func renderHeadless(doc: DXFDocument, to url: URL, config: HeadlessRenderConfig) throws {
    let rm = DXFRenderModel.build(from: doc)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: config.width, height: config.height,
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw HeadlessError.contextCreation
    }
    ctx.setFillColor(config.background)
    ctx.fill(CGRect(x: 0, y: 0, width: config.width, height: config.height))

    let size = CGSize(width: config.width, height: config.height)
    let b = doc.bounds
    let fit = min((size.width - config.pad) / b.width, (size.height - config.pad) / b.height)
    let s = fit
    let cx = size.width / 2
    let cy = size.height / 2

    // Match DXFCanvas world→screen: Y flipped (world Y up, screen Y down).
    let xform = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: cx - b.midX * s, ty: cy + b.midY * s)

    if config.verbose {
        print("doc.bounds = \(b), fit = \(s)")
        print("bulkStroke buckets = \(rm.bulkStroke.count)")
        print("bulkWideStroke buckets = \(rm.bulkWideStroke.count)  (this is the path concrete-element widePolylines must hit)")
        print("bulkFill buckets = \(rm.bulkFill.count)")
        for (key, _) in rm.bulkWideStroke {
            let pxAtFit = max(config.wideStrokeMinPx, key.worldWidth * s)
            print("  wideStroke aci=\(key.aci) worldWidth=\(key.worldWidth)  → \(pxAtFit) px at fit zoom")
        }
    }

    // 1) Thin strokes (regular geometry).
    for (bucket, cg) in rm.bulkStroke {
        var t = xform
        guard let transformed = cg.copy(using: &t) else { continue }
        let mm = CGFloat(bucket.lineWeight) / 100
        let width = max(1.0, mm * config.pointsPerMM)
        ctx.setStrokeColor(aciCG(bucket.aci))
        ctx.setLineWidth(width)
        ctx.addPath(transformed)
        ctx.strokePath()
    }

    // 2) Wide strokes (LWPOLYLINE constant width — the "thick concrete element" path).
    for (bucket, cg) in rm.bulkWideStroke {
        var t = xform
        guard let transformed = cg.copy(using: &t) else { continue }
        let width = max(config.wideStrokeMinPx, bucket.worldWidth * s)
        ctx.setStrokeColor(aciCG(bucket.aci))
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        ctx.setLineJoin(.miter)
        ctx.setMiterLimit(4)
        ctx.addPath(transformed)
        ctx.strokePath()
    }

    // 3) Fills.
    for (aci, cg) in rm.bulkFill {
        var t = xform
        guard let transformed = cg.copy(using: &t) else { continue }
        ctx.setFillColor(aciCG(aci))
        ctx.addPath(transformed)
        ctx.fillPath()
    }

    // Skip text — not needed for the visual-debug pass.

    guard let img = ctx.makeImage() else { throw HeadlessError.makeImage }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw HeadlessError.destination
    }
    CGImageDestinationAddImage(dest, img, nil)
    if !CGImageDestinationFinalize(dest) { throw HeadlessError.finalize }
}

public enum HeadlessError: Error {
    case contextCreation, makeImage, destination, finalize
}
