// Renders the Read Aloud app icon: a violet tile with a white waveform and a
// loose red hand-drawn loop around it ("point at it, hear about it").
// Usage: swift tools/make-icon.swift Resources/AppIcon.icns
import AppKit

func render(_ px: Int) -> CGImage {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = s / 1024
    // macOS icon grid: 824pt tile centred in 1024, continuous-ish corners.
    let tile = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let path = CGPath(roundedRect: tile, cornerWidth: 186 * k, cornerHeight: 186 * k, transform: nil)

    // Soft drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()

    // Gradient tile
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(srgbRed: 0.47, green: 0.40, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0.24, green: 0.17, blue: 0.62, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // Top sheen
    let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.midY), options: [])
    ctx.restoreGState()

    // Waveform: seven rounded bars
    let heights: [CGFloat] = [120, 230, 340, 420, 300, 200, 110]
    let barW = 52 * k, gap = 30 * k
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = 512 * k - total / 2
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    for h in heights {
        let r = CGRect(x: x, y: 512 * k - h * k / 2, width: barW, height: h * k)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        ctx.fillPath()
        x += barW + gap
    }

    // Loose red loop: an ellipse drawn a bit more than once, slightly wobbly.
    ctx.saveGState()
    ctx.translateBy(x: 512 * k, y: 505 * k)
    ctx.rotate(by: -0.18)
    let loop = CGMutablePath()
    let steps = 220
    for i in 0...steps {
        let t = Double(i) / Double(steps) * (2 * .pi * 1.12) + 0.9
        let wobble = 1 + 0.035 * sin(t * 3.0)
        let rx = 330.0 * wobble * Double(k), ry = 262.0 * wobble * Double(k) * (1 + 0.04 * (t / 7))
        let p = CGPoint(x: rx * cos(t), y: ry * sin(t))
        i == 0 ? loop.move(to: p) : loop.addLine(to: p)
    }
    ctx.addPath(loop)
    ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 0.30, blue: 0.27, alpha: 1))
    ctx.setLineWidth(34 * k); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setShadow(offset: .zero, blur: 10 * k, color: CGColor(srgbRed: 0.4, green: 0, blue: 0, alpha: 0.35))
    ctx.strokePath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: render(base * scale))
        try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
try! NSBitmapImageRep(cgImage: render(1024)).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: (out as NSString).deletingPathExtension + "-1024.png"))
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", out]; try! p.run(); p.waitUntilExit()
print("wrote \(out)")
