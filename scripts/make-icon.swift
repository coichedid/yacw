#!/usr/bin/env swift
// Generates the YACW app icon (original artwork, CoreGraphics only, no dependencies).
// Usage: swift scripts/make-icon.swift   -> Resources/AppIcon.icns + docs/images/icon.png
// The .icns is versioned, so building the app never needs to run this script.
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

    // macOS icon grid: the shape fills 80% of the canvas, corner radius ~22.5% of the shape.
    let side = s * 0.8
    let rect = CGRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side)
    let shape = CGPath(roundedRect: rect, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [rgb(0.13, 0.16, 0.21), rgb(0.04, 0.05, 0.08)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()

    let c = CGPoint(x: s / 2, y: s / 2)
    // Open gauge: dim track, then the filled arc; starts at 12 o'clock and runs clockwise (CG angles are counterclockwise).
    func ring(radius: CGFloat, width: CGFloat, fraction: CGFloat, color: CGColor) {
        ctx.setLineCap(.round)
        ctx.setLineWidth(width * side)
        let start = CGFloat.pi / 2
        ctx.setStrokeColor(rgb(1, 1, 1, 0.12))
        ctx.addArc(center: c, radius: radius * side, startAngle: start, endAngle: start - 2 * .pi * 0.999, clockwise: true)
        ctx.strokePath()
        ctx.setStrokeColor(color)
        ctx.addArc(center: c, radius: radius * side, startAngle: start, endAngle: start - 2 * .pi * fraction, clockwise: true)
        ctx.strokePath()
    }
    ring(radius: 0.37, width: 0.11, fraction: 0.70, color: rgb(0.17, 0.78, 0.72))   // weekly limit, teal
    ring(radius: 0.225, width: 0.085, fraction: 0.40, color: rgb(1.0, 0.70, 0.18))  // 5h limit, amber
    ctx.setFillColor(rgb(0.93, 0.96, 1.0))
    ctx.fillEllipse(in: CGRect(x: c.x - 0.075 * side, y: c.y - 0.075 * side, width: 0.15 * side, height: 0.15 * side))

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try fm.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: true)
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
try render(512).write(to: root.appendingPathComponent("docs/images/icon.png"))
try? fm.removeItem(at: iconset)
print("wrote \(icns.path) and docs/images/icon.png")
