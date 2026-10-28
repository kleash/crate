// Draws Crate's app icon (a taped cardboard box on a blue rounded square) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = CommandLine.arguments.dropFirst().first ?? "Resources/AppIcon.icns"

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func polygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

/// Draws the icon on a 1024×1024 canvas (y up).
func draw(_ cg: CGContext) {
    // Background: Apple's macOS icon grid, an 824-point rounded square with a soft drop shadow.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.35))
    cg.addPath(body)
    cg.setFillColor(color(44, 93, 216))
    cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(body)
    cg.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(92, 154, 255), color(40, 84, 208)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A soft glow behind the box, so it reads at a glance in the Dock.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(255, 255, 255, 0.28), color(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 600), startRadius: 0, endCenter: CGPoint(x: 512, y: 600), endRadius: 420, options: [])
    cg.restoreGState()
    // A thin light rim along the top edge of the rounded square.
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: CGRect(x: 102, y: 102, width: 820, height: 820), cornerWidth: 183, cornerHeight: 183, transform: nil))
    cg.setStrokeColor(color(255, 255, 255, 0.18))
    cg.setLineWidth(4)
    cg.strokePath()
    cg.restoreGState()

    // The box: an isometric cube. Top face corners: left, back, right, front; side faces hang `height` below.
    let cx: CGFloat = 512, cy: CGFloat = 652, half: CGFloat = 250, rise = half * tan(.pi / 6), height: CGFloat = 280
    let left = CGPoint(x: cx - half, y: cy), back = CGPoint(x: cx, y: cy + rise)
    let right = CGPoint(x: cx + half, y: cy), front = CGPoint(x: cx, y: cy - rise)
    func down(_ p: CGPoint, _ amount: CGFloat = height) -> CGPoint { CGPoint(x: p.x, y: p.y - amount) }
    /// A point on the top face: s runs left→back, t runs left→front.
    func top(_ s: CGFloat, _ t: CGFloat) -> CGPoint {
        CGPoint(x: left.x + s * (back.x - left.x) + t * (front.x - left.x), y: left.y + s * (back.y - left.y) + t * (front.y - left.y))
    }
    let faces: [(CGPath, CGColor)] = [
        (polygon([left, front, down(front), down(left)]), color(221, 176, 107)),
        (polygon([front, right, down(right), down(front)]), color(194, 140, 74)),
        (polygon([left, back, right, front]), color(244, 218, 166)),
    ]
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: color(10, 30, 90, 0.45))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    for (path, fill) in faces {
        cg.addPath(path)
        cg.setFillColor(fill)
        cg.fillPath()
    }
    cg.endTransparencyLayer()
    cg.restoreGState()
    // Shade the sides darker toward the bottom, as if lit from above.
    let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0, 0, 0, 0), color(60, 30, 0, 0.22)] as CFArray, locations: [0, 1])!
    for (path, _) in faces.prefix(2) {
        cg.saveGState()
        cg.addPath(path)
        cg.clip()
        cg.drawLinearGradient(shade, start: CGPoint(x: 512, y: front.y), end: CGPoint(x: 512, y: down(front).y), options: [])
        cg.restoreGState()
    }

    // Packing tape along the lid seam, running over the front-right edge and halfway down that side.
    let (a, b): (CGFloat, CGFloat) = (0.41, 0.59)
    cg.addPath(polygon([top(a, 0), top(b, 0), top(b, 1), top(a, 1)]))
    cg.setFillColor(color(226, 186, 118))
    cg.fillPath()
    cg.addPath(polygon([top(a, 1), top(b, 1), down(top(b, 1), height * 0.55), down(top(a, 1), height * 0.55)]))
    cg.setFillColor(color(170, 118, 58))
    cg.fillPath()
    // The seam between the two lid flaps, under the tape's centre line.
    cg.setStrokeColor(color(150, 100, 45, 0.55))
    cg.setLineWidth(3)
    cg.addLines(between: [top(0.5, 0), top(0.5, 1)])
    cg.strokePath()

    // Crisp edges: a light line where the lit top meets the sides.
    cg.setStrokeColor(color(255, 244, 222, 0.9))
    cg.setLineWidth(6)
    cg.setLineJoin(.round)
    cg.addLines(between: [left, front, right])
    cg.strokePath()
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let cg = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        draw(cg)
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let destination = CGImageDestinationCreateWithURL(iconset.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("can't write \(name)") }
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output)")
