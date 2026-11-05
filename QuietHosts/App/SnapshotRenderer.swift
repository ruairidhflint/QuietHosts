#if DEBUG
import AppKit
import QuietHostsCore
import SwiftUI

/// Debug-only: renders the main views with sample data to PNG files, in light
/// and dark mode, for design review and the README screenshots.
///
///   QuietHosts.app/Contents/MacOS/QuietHosts --render-snapshots <dir>
///
/// Sample data uses neutral, made-up domain names.
@MainActor
enum SnapshotRenderer {
    static func run(outputDirectory: String) {
        NSApp.activate()
        Task {
            let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let model = await makeModel()
            let appearances: [(String, NSAppearance)] = [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)]
            for (name, appearance) in appearances {
                model.helper.setPreviewStatus(.enabled)
                await model.prepareForPreview(applyState: .applied(Date()))
                model.query = ""
                model.addingWebsite = false
                await render(menu(model), appearance, nil, out.appendingPathComponent("popover-\(name).png"))

                model.query = "studio"
                try? await Task.sleep(for: .milliseconds(300))
                model.selection = 1
                await render(menu(model), appearance, nil, out.appendingPathComponent("search-\(name).png"))
                model.selection = nil

                model.query = "news.example"
                try? await Task.sleep(for: .milliseconds(300))
                await render(menu(model), appearance, nil, out.appendingPathComponent("search-add-\(name).png"))

                model.query = ""
                model.addingWebsite = true
                await render(menu(model), appearance, nil, out.appendingPathComponent("add-\(name).png"))
                model.addingWebsite = false

                model.helper.setPreviewStatus(.notRegistered)
                await model.prepareForPreview(applyState: .needsHelper)
                await render(menu(model), appearance, nil, out.appendingPathComponent("setup-\(name).png"))

                model.helper.setPreviewStatus(.enabled)
                await model.prepareForPreview(applyState: .applied(Date()))
                let state = ManageState()
                for (tab, tabName) in [(ManageTab.lists, "lists"), (.sites, "sites"), (.exceptions, "exceptions"), (.general, "general")] {
                    state.tab = tab
                    await render(ManageView(model: model, state: state), appearance, NSSize(width: 660, height: 540),
                                 out.appendingPathComponent("manage-\(tabName)-\(name).png"))
                }
            }
            renderMenuBarIcons(to: out.appendingPathComponent("menubar-icons.png"))
            print("Snapshots written to \(out.path)")
            exit(0)
        }
    }

    /// The status-item states (on, off/dimmed, attention) at real size, 4× scale, light and dark.
    private static func renderMenuBarIcons(to url: URL) {
        let scale: CGFloat = 4, cell: CGFloat = 30
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cell * 3 * scale), pixelsHigh: Int(cell * 2 * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: scale, y: scale)
        for (row, dark) in [true, false].enumerated() {
            ctx.setFillColor(NSColor(white: dark ? 0.15 : 0.9, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: CGFloat(row) * cell, width: cell * 3, height: cell))
            for (col, state) in [(false, 1.0), (false, 0.4), (true, 1.0)].enumerated() {
                let fg = NSColor(white: dark ? 1 : 0, alpha: state.1)
                ctx.setFillColor(fg.cgColor)
                ctx.setStrokeColor(fg.cgColor)
                let r = CGRect(x: CGFloat(col) * cell + 6.5, y: CGFloat(row) * cell + 6.5, width: 17, height: 17)
                BrandMark.draw(in: r.insetBy(dx: 1, dy: 1), badge: state.0, ctx: ctx)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func menu(_ model: AppModel) -> some View {
        MenuContentView(model: model, focusToken: -1, actions: MenuActions())
            .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Neutral sample data sized like the real StevenBlack adult list.
    private static func makeModel() async -> AppModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qh-snapshot-\(UUID().uuidString)")
        let store = QuietHostsStore(root: root)
        try? store.prepare()

        let first = ["acme", "apex", "aqua", "atlas", "aura", "bay", "blue", "bolt", "bright", "cedar", "cloud", "coral", "crest",
                     "delta", "echo", "ember", "fable", "fern", "flux", "frost", "glow", "grove", "halo", "harbor", "iris", "jade",
                     "juno", "kite", "lark", "lumen", "maple", "metro", "mint", "nova", "oak", "onyx", "orbit", "pine", "pixel",
                     "polar", "quartz", "rain", "ripple", "river", "sage", "sky", "solar", "spark", "stone", "terra", "tide",
                     "urban", "vale", "vivid", "wave", "willow", "zen", "zephyr", "nimbus", "summit"]
        let second = ["box", "cast", "club", "deals", "feed", "hub", "lab", "link", "media", "net", "now", "pages", "play",
                      "point", "post", "reel", "share", "spot", "stream", "studio", "tube", "view", "vision", "wire", "works", "zone"]
        let tlds = ["com", "net", "org", "xyz", "info", "site", "online", "live", "co", "io", "me", "tv", "top", "club", "fun",
                    "pro", "biz", "cc", "to", "ws", "vip", "app", "one", "world", "space", "store", "tech", "link", "click", "cam",
                    "life", "page", "today", "zone", "media", "icu", "work", "win", "lol", "wtf", "best", "plus", "run", "art",
                    "blog", "cloud", "email", "global", "group", "host", "news", "pub", "red"]
        var domains: [String] = []
        domains.reserveCapacity(80_000)
        outer: for tld in tlds { for a in first { for b in second {
            domains.append("\(a)\(b).\(tld)")
            if domains.count == 76_795 { break outer }
        } } }
        domains += ["studio-example.com", "www.studio-example.com", "m.studio-example.com", "studiotickets.org", "photostudio.example", "duostudio.net"]
        let social = (0..<3_808).map { "social\($0).example" }
        try? store.saveList(DomainList(domains: domains), id: BuiltInSources.adultID)
        try? store.saveList(DomainList(domains: social), id: BuiltInSources.socialID)

        var settings = AppSettings()
        settings.sources[0].lastUpdated = Date().addingTimeInterval(-2 * 86400)
        settings.sources[1].lastUpdated = Date().addingTimeInterval(-9 * 86400)
        try? store.save(settings)
        var rules = RuleSet()
        rules.addWebsite("example-social.com", now: Date().addingTimeInterval(-86400 * 3))
        rules.addWebsite("video-feed.example", now: Date().addingTimeInterval(-86400 * 10))
        rules.allowed["studiotickets.org"] = .init(added: Date().addingTimeInterval(-3600))
        try? store.save(rules)
        return AppModel(store: store, helper: HelperManager(), hostsPath: "/nonexistent")
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private static func render<V: View>(_ view: V, _ appearance: NSAppearance, _ size: NSSize?, _ url: URL) async {
        let hosting = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        hosting.appearance = appearance
        let fitting = size ?? hosting.fittingSize
        let window = KeyWindow(contentRect: NSRect(x: -6000, y: -6000, width: fitting.width, height: fitting.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: fitting)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(600))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        if let png = framed(rep, dark: appearance.name == .darkAqua) {
            try? png.write(to: url)
        }
    }

    /// Rounds the corners, adds a hairline border and a soft shadow on a
    /// transparent canvas, like a window on the desktop.
    private static func framed(_ rep: NSBitmapImageRep, dark: Bool) -> Data? {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let scale = CGFloat(w) / rep.size.width
        let pad = Int(36 * scale), radius = 12 * scale
        let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w + 2 * pad, pixelsHigh: h + 2 * pad,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let canvas, let image = rep.cgImage else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        let ctx = NSGraphicsContext.current!.cgContext
        let rect = CGRect(x: pad, y: pad, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 28 * scale,
                      color: NSColor.black.withAlphaComponent(dark ? 0.45 : 0.22).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(white: dark ? 1 : 0, alpha: dark ? 0.18 : 0.12).cgColor)
        ctx.setLineWidth(1 * scale)
        ctx.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }
}
#endif
