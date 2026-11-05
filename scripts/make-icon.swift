// Generates QuietHosts' app icon PNGs: swift scripts/make-icon.swift <appiconset dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func renderIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 rounded square, centred, with a soft shadow.
    let inset = size * 100 / 1024
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.025,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(srgbRed: 0.04, green: 0.42, blue: 0.40, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(srgbRed: 0.13, green: 0.70, blue: 0.58, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.04, green: 0.42, blue: 0.40, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // The QuietHosts mark (same geometry as QuietHosts/Views/BrandMark.swift):
    // a ring with a rounded horizontal bar.
    let s = rect.width * 0.52
    let mark = CGRect(x: rect.midX - s / 2, y: rect.midY - s / 2, width: s, height: s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.006), blur: size * 0.012,
                  color: NSColor.black.withAlphaComponent(0.2).cgColor)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    let lineWidth = s * 0.11
    ctx.setLineWidth(lineWidth)
    ctx.strokeEllipse(in: mark.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
    let bar = CGRect(x: mark.minX + s * 0.25, y: mark.midY - s * 0.075, width: s * 0.5, height: s * 0.15)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: s * 0.075, cornerHeight: s * 0.075, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int, String)] = [
    ("16x16", 16, "1x"), ("16x16", 32, "2x"), ("32x32", 32, "1x"), ("32x32", 64, "2x"),
    ("128x128", 128, "1x"), ("128x128", 256, "2x"), ("256x256", 256, "1x"), ("256x256", 512, "2x"),
    ("512x512", 512, "1x"), ("512x512", 1024, "2x"),
]
var images: [String] = []
for (size, px, scale) in specs {
    let name = "icon_\(size)@\(scale).png"
    try! renderIcon(pixels: px).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    images.append("{\"filename\":\"\(name)\",\"idiom\":\"mac\",\"scale\":\"\(scale)\",\"size\":\"\(size)\"}")
}
let json = "{\"images\":[\(images.joined(separator: ","))],\"info\":{\"author\":\"xcode\",\"version\":1}}"
try! json.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Icon written to \(outDir)")
