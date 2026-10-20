// Draws the app icon in code and writes Resources/AppIcon.icns: a dark rounded square with a
// light RAM stick (body, four chips, pin row with the key notch) and an arrow coming down into it.
//   swift scripts/make-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas = 1024
let light = CGColor(gray: 0.96, alpha: 1)

func render(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let s = CGFloat(size) / CGFloat(canvas)
    ctx.scaleBy(x: s, y: s)

    // The macOS icon grid: an 824 pt squircle centred on the 1024 canvas, dark with a quiet gradient.
    let square = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: square, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [CGColor(red: 0.19, green: 0.19, blue: 0.21, alpha: 1), CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.08))
    ctx.setLineWidth(6)
    ctx.strokePath()

    ctx.setFillColor(light)
    ctx.setStrokeColor(light)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // The stick.
    let stick = CGRect(x: 232, y: 232, width: 560, height: 232)
    ctx.setLineWidth(28)
    ctx.addPath(CGPath(roundedRect: stick, cornerWidth: 40, cornerHeight: 40, transform: nil))
    ctx.strokePath()

    // Four chips along the top of the stick, filled.
    let gap: CGFloat = 30
    let chipW = (stick.width - gap * 5) / 4
    let chipH: CGFloat = 92
    for i in 0..<4 {
        let chip = CGRect(x: stick.minX + gap + CGFloat(i) * (chipW + gap), y: stick.maxY - 42 - chipH, width: chipW, height: chipH)
        ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
    }

    // Pin row along the bottom edge with the key notch.
    let pinCount = 14
    let pinStep = (stick.width - gap * 2) / CGFloat(pinCount)
    for i in 0..<pinCount where i != 9 {
        let x = stick.minX + gap + CGFloat(i) * pinStep + pinStep * 0.22
        ctx.fill(CGRect(x: x, y: stick.minY + 40, width: pinStep * 0.56, height: 44))
    }

    // The arrow: RAM coming down into the stick.
    let cx: CGFloat = 512
    ctx.setLineWidth(46)
    ctx.move(to: CGPoint(x: cx, y: 800))
    ctx.addLine(to: CGPoint(x: cx, y: 548))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: cx - 96, y: 644))
    ctx.addLine(to: CGPoint(x: cx, y: 548))
    ctx.addLine(to: CGPoint(x: cx + 96, y: 644))
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let resources = root.appendingPathComponent("Resources", isDirectory: true)
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
let out = resources.appendingPathComponent("AppIcon.icns")
writePNG(render(1024), to: resources.appendingPathComponent("AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try? fm.removeItem(at: iconset)
guard p.terminationStatus == 0 else { print("iconutil failed (\(p.terminationStatus))"); exit(1) }
print("wrote", out.path)
