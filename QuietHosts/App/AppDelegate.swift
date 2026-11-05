import AppKit
import Observation
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static var shared: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var manageWindow: NSWindow?
    private let manageState = ManageState()
    private var focusToken = 0
    private var hosting: NSHostingController<MenuContentView>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--uninstall") {
            Uninstaller.run()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--self-test") {
            let domain = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : nil
            SelfTest.run(domain: domain)
            return
        }
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--render-snapshots"), i + 1 < CommandLine.arguments.count {
            SnapshotRenderer.run(outputDirectory: CommandLine.arguments[i + 1])
            return
        }
        #endif

        model = AppModel()
        model.helper.onStatusChange = { [weak self] in self?.model.helperStatusChanged() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let controller = NSHostingController(rootView: makeMenuView())
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        hosting = controller

        observeStatus()
        model.start()
    }

    private func makeMenuView() -> MenuContentView {
        MenuContentView(model: model, focusToken: focusToken, actions: MenuActions(
            openManage: { [weak self] tab in self?.openManage(tab) },
            close: { [weak self] in self?.popover.performClose(nil) },
            quit: { NSApp.terminate(nil) }
        ))
    }

    // MARK: Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        model.didBecomeVisible()
        focusToken += 1
        hosting?.rootView = makeMenuView()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        let protectionTitle = model.settings.protectionEnabled ? "Turn Protection Off" : "Turn Protection On"
        menu.addItem(withTitle: protectionTitle, action: #selector(toggleProtection), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Manage Lists…", action: #selector(openManageFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit QuietHosts", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.toolTip = "Blocking stays on after quitting."
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleProtection() { model.setProtection(!model.settings.protectionEnabled) }
    @objc private func openManageFromMenu() { openManage(.lists) }
    @objc private func openSettingsFromMenu() { openManage(.general) }

    /// Keeps the menu-bar icon in step with protection state.
    private func observeStatus() {
        withObservationTracking {
            updateStatusIcon()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStatus() }
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let description: String
        var badge = false
        var dimmed = false
        switch model.health {
        case .active, .applying, .loading:
            dimmed = !model.settings.protectionEnabled
            description = dimmed ? "QuietHosts: protection off" : "QuietHosts: protection on"
        case .off:
            dimmed = true
            description = "QuietHosts: protection off"
        case .needsSetup, .attention, .externallyEdited:
            badge = true
            description = "QuietHosts: needs attention"
        }
        let image = BrandMark.image(size: 17, badge: badge)
        image.accessibilityDescription = description
        button.image = image
        button.appearsDisabled = dimmed
        button.toolTip = description
    }

    // MARK: Popover

    func popoverDidClose(_ notification: Notification) {
        model.addingWebsite = false
        model.selection = nil
    }

    // MARK: Manage window

    private func openManage(_ tab: ManageTab) {
        popover.performClose(nil)
        manageState.tab = tab
        if manageWindow == nil {
            let controller = NSHostingController(rootView: ManageView(model: model, state: manageState))
            let window = NSWindow(contentViewController: controller)
            window.title = "QuietHosts"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 660, height: 540))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("QuietHostsManageWindow")
            manageWindow = window
        }
        model.didBecomeVisible()
        NSApp.activate()
        manageWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openManage(.lists)
        return false
    }
}
