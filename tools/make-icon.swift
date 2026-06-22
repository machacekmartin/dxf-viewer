#!/usr/bin/env swift
// Render a placeholder AppIcon for DXF Viewer.
// Usage: swift tools/make-icon.swift
// Output: Resources/AppIcon.icns (and a transient AppIcon.iconset alongside).

import AppKit
import Foundation

// ponytail: simple line-based blueprint motif over a dark glass gradient.
// Replace with proper artwork before 1.0 ships if you want something fancier.

func draw(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }

    // Background: continuous-rounded rect with vertical gradient (slate → near-black).
    let inset: CGFloat = size * 0.06
    let rect = CGRect(x: inset, y: inset, width: size - 2*inset, height: size - 2*inset)
    let radius = size * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        CGColor(red: 0.16, green: 0.22, blue: 0.30, alpha: 1.0),
        CGColor(red: 0.06, green: 0.09, blue: 0.13, alpha: 1.0)
    ]
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray,
                          locations: [0.0, 1.0])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
    ctx.restoreGState()

    // Subtle grid: cyan hairlines, every ~8% of side.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.setStrokeColor(CGColor(red: 0.45, green: 0.75, blue: 0.95, alpha: 0.18))
    ctx.setLineWidth(max(1, size / 512))
    let step = size * 0.08
    var x = rect.minX
    while x < rect.maxX { ctx.move(to: CGPoint(x: x, y: rect.minY)); ctx.addLine(to: CGPoint(x: x, y: rect.maxY)); x += step }
    var y = rect.minY
    while y < rect.maxY { ctx.move(to: CGPoint(x: rect.minX, y: y)); ctx.addLine(to: CGPoint(x: rect.maxX, y: y)); y += step }
    ctx.strokePath()
    ctx.restoreGState()

    // Stylised floor-plan: two rooms + a doorway arc + a diagonal.
    ctx.saveGState()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let stroke = size * 0.028
    ctx.setLineWidth(stroke)

    let cx = size / 2
    let cy = size / 2
    let w = size * 0.52
    let h = size * 0.40

    // Outer rectangle.
    let outer = CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h)
    ctx.stroke(outer)

    // Interior wall.
    let wallX = outer.minX + outer.width * 0.55
    ctx.move(to: CGPoint(x: wallX, y: outer.minY))
    ctx.addLine(to: CGPoint(x: wallX, y: outer.maxY - outer.height * 0.35))
    ctx.strokePath()

    // Doorway arc.
    let doorR = outer.height * 0.28
    let doorOrigin = CGPoint(x: wallX, y: outer.maxY - outer.height * 0.35)
    ctx.addArc(center: doorOrigin, radius: doorR, startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
    ctx.strokePath()

    // Diagonal dimension line (DXF feel).
    ctx.setStrokeColor(CGColor(red: 0.50, green: 0.85, blue: 1.0, alpha: 0.95))
    ctx.setLineWidth(stroke * 0.75)
    ctx.move(to: CGPoint(x: outer.minX - size * 0.04, y: outer.maxY + size * 0.05))
    ctx.addLine(to: CGPoint(x: outer.maxX + size * 0.04, y: outer.maxY + size * 0.05))
    ctx.strokePath()
    // Tick marks.
    [outer.minX - size * 0.04, outer.maxX + size * 0.04].forEach { tx in
        ctx.move(to: CGPoint(x: tx, y: outer.maxY + size * 0.05 - size * 0.02))
        ctx.addLine(to: CGPoint(x: tx, y: outer.maxY + size * 0.05 + size * 0.02))
        ctx.strokePath()
    }
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func pngData(_ image: NSImage, pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                  pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

struct Variant { let name: String; let pixels: Int }
let variants: [Variant] = [
    .init(name: "icon_16x16.png",       pixels: 16),
    .init(name: "icon_16x16@2x.png",    pixels: 32),
    .init(name: "icon_32x32.png",       pixels: 32),
    .init(name: "icon_32x32@2x.png",    pixels: 64),
    .init(name: "icon_128x128.png",     pixels: 128),
    .init(name: "icon_128x128@2x.png",  pixels: 256),
    .init(name: "icon_256x256.png",     pixels: 256),
    .init(name: "icon_256x256@2x.png",  pixels: 512),
    .init(name: "icon_512x512.png",     pixels: 512),
    .init(name: "icon_512x512@2x.png",  pixels: 1024),
]

let master = draw(1024)
for v in variants {
    let data = pngData(master, pixels: v.pixels)
    try data.write(to: iconset.appendingPathComponent(v.name))
}

// Use iconutil to roll an .icns. Falls back to leaving the iconset on disk.
let icnsPath = root.appendingPathComponent("Resources/AppIcon.icns").path
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset.path, "-o", icnsPath]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(icnsPath)")

// ponytail self-check: file exists and is non-trivial in size.
let attrs = try FileManager.default.attributesOfItem(atPath: icnsPath)
let size = (attrs[.size] as? Int) ?? 0
assert(size > 5_000, "AppIcon.icns suspiciously small: \(size) bytes")
