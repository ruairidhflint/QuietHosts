import AppKit
import Foundation
import QuietHostsCore

/// `QuietHosts --uninstall` (run by `./install.sh --uninstall`): removes every
/// QuietHosts entry from /etc/hosts through the helper, then unregisters the
/// helper. The app bundle and settings are removed by the script.
@MainActor
enum Uninstaller {
    static func run() {
        Task {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: HelperConstants.appBundleIdentifier)
            where app.processIdentifier != getpid() {
                app.terminate()
            }
            let helper = HelperManager()
            helper.refresh()
            var succeeded = true

            if hostsHasSection() {
                if helper.isReady {
                    do {
                        _ = try await HelperClient().removeManagedSection(overwriteExternalEdits: true)
                        say("✓ Removed QuietHosts entries from /etc/hosts (your own entries were kept)")
                    } catch {
                        say("✗ Couldn’t remove the entries: \(error.localizedDescription)")
                        succeeded = false
                    }
                } else {
                    say("✗ /etc/hosts still has QuietHosts entries, but the helper isn’t available to remove them.")
                    say("  Open QuietHosts, finish setup, turn protection off, then run the uninstaller again.")
                    succeeded = false
                }
            } else {
                say("✓ /etc/hosts has no QuietHosts entries")
            }

            if succeeded, helper.status != .notRegistered {
                do {
                    try await helper.uninstall()
                    say("✓ Removed the background helper")
                } catch {
                    say("! Couldn’t unregister the helper (\(error.localizedDescription)). Remove QuietHosts in System Settings › General › Login Items & Extensions.")
                }
            }
            exit(succeeded ? 0 : 1)
        }
    }

    private static func hostsHasSection() -> Bool {
        guard let data = FileManager.default.contents(atPath: "/private/etc/hosts") else { return false }
        // Unreadable markers count as present; the helper then explains the problem.
        guard let document = try? HostsDocument(data) else { return true }
        return document.section != nil
    }

    private static func say(_ s: String) {
        print(s)
        fflush(stdout)
    }
}
