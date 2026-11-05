import AppKit
import SwiftUI

/// QuietHosts' mark: a ring with a horizontal bar, a softened "no entry".
/// Drawn in code; Apple's SF Symbols may not be used in logos or app icons.
/// `scripts/make-icon.swift` draws the same geometry for the app icon.
enum BrandMark {
    static let teal = Color(red: 0.09, green: 0.60, blue: 0.52)

    /// Draws the mark centred in `rect`, using the context's current fill and stroke colours.
    static func draw(in rect: CGRect, badge: Bool = false, ctx: CGContext) {
        let s = min(rect.width, rect.height)
        let r = CGRect(x: rect.midX - s / 2, y: rect.midY - s / 2, width: s, height: s)
        let lineWidth = s * 0.11
        ctx.setLineWidth(lineWidth)
        ctx.strokeEllipse(in: r.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        let bar = CGRect(x: r.minX + s * 0.25, y: r.midY - s * 0.075, width: s * 0.5, height: s * 0.15)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: s * 0.075, cornerHeight: s * 0.075, transform: nil))
        ctx.fillPath()
        if badge {
            // A notch in the ring with a small dot: "needs attention".
            let centre = CGPoint(x: r.maxX - s * 0.15, y: r.maxY - s * 0.15)
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.fillEllipse(in: CGRect(x: centre.x - s * 0.22, y: centre.y - s * 0.22, width: s * 0.44, height: s * 0.44))
            ctx.restoreGState()
            ctx.fillEllipse(in: CGRect(x: centre.x - s * 0.13, y: centre.y - s * 0.13, width: s * 0.26, height: s * 0.26))
        }
    }

    /// A template image of the mark, for the menu bar and the popover header.
    static func image(size: CGFloat, badge: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setStrokeColor(NSColor.black.cgColor)
            draw(in: rect.insetBy(dx: size * 0.06, dy: size * 0.06), badge: badge, ctx: ctx)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "QuietHosts"
        return image
    }
}
