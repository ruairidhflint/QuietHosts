import AppKit
import Darwin
import Foundation
import QuietHostsCore

/// End-to-end check against the real helper and /etc/hosts:
///
///   /Applications/QuietHosts.app/Contents/MacOS/QuietHosts --self-test [domain]
///
/// Uses the same coordinator as the menu-bar UI. It applies the current
/// policy, allows one listed domain, blocks it again, and turns protection off
/// and on, confirming each step through the system resolver (IPv4 and IPv6)
/// and by reading /etc/hosts. Rules and protection are restored afterwards.
/// Requires the helper to be approved already; never changes DNS settings.
@MainActor
enum SelfTest {
    private static var failures = 0

    static func run(domain requested: String?) {
        Task {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: HelperConstants.appBundleIdentifier)
                .filter { $0.processIdentifier != getpid() }
            if !others.isEmpty {
                say("✗ Quit the QuietHosts menu-bar app first, so the test and the app don’t both change the hosts file.")
                exit(2)
            }
            let model = AppModel()
            say("QuietHosts self-test — \(Date().formatted(date: .abbreviated, time: .standard))")
            model.helper.refresh()
            guard model.helper.isReady else {
                say("✗ The helper isn’t approved yet. Open QuietHosts and finish setup first.")
                exit(2)
            }
            do {
                say("  Helper protocol version: \(try await HelperClient().version())")
            } catch {
                say("✗ Couldn’t reach the helper: \(error.localizedDescription)")
                exit(2)
            }

            let originalProtection = model.settings.protectionEnabled
            let originalRules = model.rules
            let mdnsBefore = mDNSResponderMB()

            model.start()
            _ = await wait(timeout: 60) { !model.isLoadingLists }
            if model.index.count == 0 {
                _ = await wait(timeout: 120) { model.index.count > 0 }
            }
            say("  Lists loaded: \(model.index.count.formatted()) domains in index")
            if !model.settings.protectionEnabled { model.setProtection(true) }
            let initial = await waitApplied(model, label: "Initial apply / verify")
            if let r = model.lastReport, initial {
                say("    helper: write \(fmt(r.writeMilliseconds)) · DNS flush \(fmt(r.flushMilliseconds)) · \(r.entryCount.formatted()) entries · \(ByteCountFormatter.string(fromByteCount: Int64(r.fileBytes), countStyle: .file))")
            }

            guard let domain = pickDomain(model, requested) else {
                say("✗ No suitable blocked domain to test with.")
                exit(1)
            }
            say("  Test domain: \(domain)  (sources: \(model.sourceNames(for: domain, mask: model.index.mask(of: domain)).joined(separator: ", ")))")
            await expectResolution(domain, blocked: true, step: "Blocked before test")

            // Allow it.
            var started = ContinuousClock.now
            model.allow(domain)
            if await waitApplied(model, label: "Allow → applied") {
                report(model, since: started)
                expectHostsFile(model, contains: domain, false)
                await expectResolution(domain, blocked: false, step: "Allowed takes effect", since: started)
            }

            // Block it again.
            started = ContinuousClock.now
            model.block(domain)
            if await waitApplied(model, label: "Block again → applied") {
                report(model, since: started)
                expectHostsFile(model, contains: domain, true)
                await expectResolution(domain, blocked: true, step: "Blocked again takes effect", since: started)
            }

            // Protection off and on.
            started = ContinuousClock.now
            model.setProtection(false)
            if await waitApplied(model, label: "Protection off → applied") {
                report(model, since: started)
                expectNoSection(model)
                await expectResolution(domain, blocked: false, step: "Off takes effect", since: started)
            }
            started = ContinuousClock.now
            model.setProtection(true)
            if await waitApplied(model, label: "Protection on → applied") {
                report(model, since: started)
                await expectResolution(domain, blocked: true, step: "On takes effect", since: started)
            }

            // Upstream filtering caveat (e.g. Cloudflare for Families).
            if let filter = UpstreamFilterDetector.detect() {
                let sample = ["pornhub.com", "xvideos.com"].first { model.index.index(of: $0) != nil }
                if let sample {
                    let answer = upstreamAnswer(sample)
                    say("  Note: DNS is \(filter.provider) (\(filter.servers.joined(separator: ", "))). Its own answer for \(sample): \(answer.isEmpty ? "no address" : answer)\(answer == "0.0.0.0" ? " — blocked upstream, so a QuietHosts exception can’t unblock it" : "")")
                }
            }

            // Restore the user's state.
            model.restoreRules(originalRules)
            model.setProtection(originalProtection)
            _ = await waitApplied(model, label: "Restore original state")
            let mdnsAfter = mDNSResponderMB()
            say("  mDNSResponder resident memory: \(fmt(mdnsBefore, "MB")) before → \(fmt(mdnsAfter, "MB")) after")
            say(failures == 0 ? "✓ All checks passed" : "✗ \(failures) check(s) failed")
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: Steps

    /// Picks a listed, currently blocked domain with no rules whose upstream DNS
    /// answer is not itself a sinkhole, so "allowed" can actually be observed.
    private static func pickDomain(_ model: AppModel, _ requested: String?) -> String? {
        if let requested, case .success(let host) = Hostname.normalize(userInput: requested) { return host }
        let list = model.index.list
        var tried = 0
        var i = 0
        while i < list.count && tried < 60 {
            let d = list.domain(at: i)
            i += max(1, list.count / 60)
            guard model.state(of: d) == .blocked, model.rules.allowed[d] == nil, model.rules.blocked[d] == nil else { continue }
            tried += 1
            let answer = upstreamAnswer(d)
            if answer != "0.0.0.0" {
                say("  Upstream DNS answer for \(d) (bypassing /etc/hosts): \(answer.isEmpty ? "no address" : answer)")
                return d
            }
        }
        return nil
    }

    /// Asks the configured DNS server directly (dig ignores /etc/hosts).
    static func upstreamAnswer(_ domain: String) -> String {
        let pipe = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        p.arguments = ["+short", "+time=2", "+tries=1", "A", domain]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "?" }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let addresses = out.split(separator: "\n").map(String.init).filter { $0.first?.isNumber == true }
        return addresses.first ?? ""
    }

    private static func waitApplied(_ model: AppModel, label: String) async -> Bool {
        let started = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(20))
        let ok = await wait(timeout: 60) {
            if case .failed = model.applyState { return true }
            if model.applyState == .externallyEdited || model.applyState == .needsHelper { return true }
            return model.isUpToDate
        }
        let elapsed = ContinuousClock.now - started
        if ok && model.isUpToDate {
            say("✓ \(label): \(fmt(ms(elapsed)))")
            return true
        }
        failures += 1
        say("✗ \(label): \(String(describing: model.applyState))")
        return false
    }

    private static func report(_ model: AppModel, since start: ContinuousClock.Instant) {
        guard let r = model.lastReport else { return }
        say("    helper: write+verify \(fmt(r.writeMilliseconds)) · DNS flush \(fmt(r.flushMilliseconds)) · \(r.entryCount.formatted()) entries\(r.dnsWarning.map { " · warning: \($0)" } ?? "")")
    }

    private static func expectHostsFile(_ model: AppModel, contains domain: String, _ expected: Bool) {
        guard let data = FileManager.default.contents(atPath: model.hostsPath),
              let doc = try? HostsDocument(data), let section = doc.section else {
            failures += 1
            say("✗ /etc/hosts: managed section missing or unreadable")
            return
        }
        let body = String(decoding: section.body, as: UTF8.self)
        let present = body.contains("\n0.0.0.0 \(domain)\n") || body.hasPrefix("0.0.0.0 \(domain)\n")
        let v6 = body.contains("\n:: \(domain)\n")
        if present == expected && v6 == expected && section.isIntact {
            say("✓ /etc/hosts \(expected ? "contains" : "doesn’t contain") \(domain) (IPv4 and IPv6), checksum intact")
        } else {
            failures += 1
            say("✗ /etc/hosts: expected \(domain) \(expected ? "present" : "absent"); v4=\(present) v6=\(v6) intact=\(section.isIntact)")
        }
    }

    private static func expectNoSection(_ model: AppModel) {
        let data = FileManager.default.contents(atPath: model.hostsPath) ?? Data()
        if let doc = try? HostsDocument(data), doc.section == nil {
            say("✓ /etc/hosts has no QuietHosts entries")
        } else {
            failures += 1
            say("✗ /etc/hosts still has a QuietHosts section")
        }
    }

    /// Polls the system resolver until the expected outcome appears (or 5 s).
    private static func expectResolution(_ domain: String, blocked: Bool, step: String,
                                         since start: ContinuousClock.Instant? = nil) async {
        let pollStart = ContinuousClock.now
        var v4 = ResolverCheck.Outcome.failed("not checked"), v6 = v4
        while ContinuousClock.now - pollStart < .seconds(5) {
            v4 = await ResolverCheck.check(domain, family: AF_INET)
            v6 = await ResolverCheck.check(domain, family: AF_INET6)
            let ok = blocked ? (v4 == .blocked && v6 == .blocked) : (v4 != .blocked && v6 != .blocked)
            if ok {
                let suffix = start.map { " (\(fmt(ms(ContinuousClock.now - $0))) after the click)" } ?? ""
                say("✓ \(step): IPv4 \(short(v4)), IPv6 \(short(v6))\(suffix)")
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        failures += 1
        say("✗ \(step): IPv4 \(short(v4)), IPv6 \(short(v6))")
    }

    // MARK: Utilities

    private static func wait(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > .seconds(timeout) { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private static func short(_ o: ResolverCheck.Outcome) -> String {
        switch o {
        case .blocked: "→ sinkhole"
        case .resolves(let a): "→ \(a.first ?? "?")"
        case .failed(let r): "→ no address (\(r))"
        }
    }

    private static func mDNSResponderMB() -> Double? {
        let pipe = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "rss=,comm="]
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in out.split(separator: "\n") where line.hasSuffix("/mDNSResponder") {
            if let kb = Double(line.split(separator: " ").first ?? "") { return kb / 1024 }
        }
        return nil
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func fmt(_ v: Double) -> String { v >= 1000 ? String(format: "%.2f s", v / 1000) : String(format: "%.0f ms", v) }
    private static func fmt(_ v: Double?, _ unit: String) -> String { v.map { String(format: "%.0f %@", $0, unit) } ?? "?" }

    private static func say(_ s: String) {
        print(s)
        fflush(stdout)
    }
}
