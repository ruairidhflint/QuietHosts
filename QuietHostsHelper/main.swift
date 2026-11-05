// QuietHostsHelper — the privileged LaunchDaemon that edits /etc/hosts.
//
// Registered by the app with SMAppService and started on demand by launchd
// when the app connects to its Mach service. It:
// - only accepts XPC connections from code signed as the QuietHosts app by
//   the same team (enforced by the kernel-backed code-signing requirement);
// - exposes exactly two hosts operations (see QuietHostsHelperProtocol) with
//   a fixed file path, validated hostnames and helper-rendered lines;
// - never runs shell commands; the DNS flush executes two fixed binaries
//   with constant arguments;
// - exits after a short idle period. launchd restarts it on the next request.

import Foundation
import os
import QuietHostsCore

let log = Logger(subsystem: HelperConstants.helperBundleIdentifier, category: "helper")

final class HelperService: NSObject, QuietHostsHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    /// Serialises all hosts-file work and the idle bookkeeping below.
    private let queue = DispatchQueue(label: "com.quiethosts.helper.hosts")
    private let writer = HostsFileWriter(configuration: .system, flusher: SystemDNSFlusher())
    private var lastActivity = Date()
    private var inFlight = 0
    private static let idleSeconds: TimeInterval = 120

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The listener's code-signing requirement has already rejected any
        // client that is not the QuietHosts app from our team.
        connection.exportedInterface = NSXPCInterface(with: QuietHostsHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        touch()
        return true
    }

    func helperVersion(withReply reply: @escaping @Sendable (Int) -> Void) {
        touch()
        reply(HelperConstants.protocolVersion)
    }

    func applyBlocklist(_ domains: Data, overwriteExternalEdits: Bool, withReply reply: @escaping @Sendable (Data) -> Void) {
        perform(reply) { writer in
            let rendered = try ManagedSection.renderBody(fromDomainList: domains)
            let block = rendered.count == 0 ? nil : ManagedSection.render(body: rendered.body, count: rendered.count)
            log.info("Applying \(rendered.count, privacy: .public) entries")
            return try writer.apply(block: block, entryCount: rendered.count, overwriteExternalEdits: overwriteExternalEdits)
        }
    }

    func removeManagedSection(overwriteExternalEdits: Bool, withReply reply: @escaping @Sendable (Data) -> Void) {
        perform(reply) { writer in
            log.info("Removing managed section")
            return try writer.apply(block: nil, entryCount: 0, overwriteExternalEdits: overwriteExternalEdits)
        }
    }

    private func perform(_ reply: @escaping @Sendable (Data) -> Void,
                         _ work: @escaping @Sendable (HostsFileWriter) throws -> HostsApplyReport) {
        queue.async { [self] in
            inFlight += 1
            defer { inFlight -= 1; lastActivity = Date() }
            let response: HelperReply
            do {
                let report = try work(writer)
                log.info("Done: changed=\(report.changed, privacy: .public) write=\(report.writeMilliseconds, privacy: .public)ms flush=\(report.flushMilliseconds, privacy: .public)ms")
                response = HelperReply(report: report)
            } catch {
                let failure = (error as? HostsFileError) ?? .writeFailed(error.localizedDescription)
                log.error("Refused or failed: \(failure.localizedDescription, privacy: .public)")
                response = HelperReply(error: failure)
            }
            reply(response.encoded())
        }
    }

    private func touch() {
        queue.async { [self] in lastActivity = Date() }
    }

    func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [self] in
            if inFlight == 0 && Date().timeIntervalSince(lastActivity) > Self.idleSeconds {
                log.info("Idle; exiting")
                exit(0)
            }
        }
        timer.resume()
        idleTimer = timer
    }

    private var idleTimer: DispatchSourceTimer?
}

guard getuid() == 0 else {
    log.error("Must run as root via launchd")
    exit(1)
}
guard let team = CodeSigningIdentity.currentTeamIdentifier() else {
    log.error("Helper is not signed with a team identity; refusing to run")
    exit(1)
}

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.setConnectionCodeSigningRequirement(
    CodeSigningIdentity.requirement(identifier: HelperConstants.appBundleIdentifier, teamIdentifier: team)
)
let service = HelperService()
listener.delegate = service
listener.resume()
service.startIdleTimer()
log.info("Started (protocol \(HelperConstants.protocolVersion, privacy: .public))")
dispatchMain()
