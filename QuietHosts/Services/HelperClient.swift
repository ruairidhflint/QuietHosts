import Foundation
import Observation
import QuietHostsCore
import ServiceManagement

/// Registration state of the privileged helper (SMAppService LaunchDaemon).
@MainActor
@Observable
final class HelperManager {
    enum Status: Equatable {
        case notRegistered
        case requiresApproval
        case enabled
        /// The daemon plist or binary is missing from the app bundle.
        case notFound
    }

    private(set) var status: Status = .notRegistered
    private(set) var lastError: String?
    /// Called when `status` changes (e.g. the user approves the helper).
    @ObservationIgnored var onStatusChange: (() -> Void)?
    private let service = SMAppService.daemon(plistName: HelperConstants.launchdPlistName)
    private var registrationFailedNotFound = false
    private var pollTask: Task<Void, Never>?

    var isReady: Bool { status == .enabled }

    func refresh() {
        // macOS reports `.notFound` for a daemon that has simply never been
        // registered, so that is treated as "not set up yet". `.notFound` is
        // only shown when registering fails because the plist is missing.
        let new: Status = switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: registrationFailedNotFound ? .notFound : .notRegistered
        }
        if new != status {
            status = new
            onStatusChange?()
        }
        if status == .requiresApproval { startPolling() } else if status == .enabled { stopPolling() }
    }

    /// Registers the daemon. macOS then asks the user to allow it in System
    /// Settings; we open the right pane and poll until it is approved.
    func install() {
        lastError = nil
        registrationFailedNotFound = false
        do {
            try service.register()
        } catch {
            // "Operation not permitted" is the normal response while approval is pending.
            let nsError = error as NSError
            switch nsError.code {
            case 1, kSMErrorLaunchDeniedByUser, kSMErrorAlreadyRegistered:
                break
            case kSMErrorJobPlistNotFound, kSMErrorInvalidPlist:
                registrationFailedNotFound = true
                lastError = "The helper is missing from the app (\(error.localizedDescription))."
            case kSMErrorInvalidSignature:
                lastError = "macOS rejected the helper’s signature (\(error.localizedDescription))."
            default:
                lastError = error.localizedDescription
            }
        }
        refresh()
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
        startPolling()
    }

    /// Unregisters and registers again; used to recover from a stale or
    /// broken registration.
    func reinstall() async {
        lastError = nil
        do { try await service.unregister() } catch { /* not registered is fine */ }
        try? await Task.sleep(for: .seconds(1))
        install()
    }

    /// Removes the helper registration (used when uninstalling).
    func uninstall() async throws {
        try await service.unregister()
        refresh()
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refresh()
                if self.status == .enabled || self.status == .notRegistered { break }
            }
            self?.pollTask = nil
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    #if DEBUG
    func setPreviewStatus(_ status: Status) { self.status = status }
    #endif
}

enum HelperCallError: LocalizedError {
    case unsigned
    case connection(String)
    case timeout
    case hosts(HostsFileError)

    var errorDescription: String? {
        switch self {
        case .unsigned: "QuietHosts isn’t signed with a developer identity, so the helper won’t accept it."
        case .connection(let detail): "Couldn’t reach the QuietHosts helper (\(detail))."
        case .timeout: "The QuietHosts helper didn’t respond in time."
        case .hosts(let error): error.localizedDescription
        }
    }
}

/// XPC client for the helper. Each call opens a short-lived connection that
/// verifies the helper's code signature before sending anything.
struct HelperClient: Sendable {
    func version() async throws -> Int {
        let data = try await invoke(timeout: 10) { proxy, done in
            proxy.helperVersion { v in done(withUnsafeBytes(of: v) { Data($0) }) }
        }
        return data.withUnsafeBytes { $0.load(as: Int.self) }
    }

    func applyBlocklist(_ domains: Data, overwriteExternalEdits: Bool) async throws -> HostsApplyReport {
        try decode(await invoke(timeout: 90) { proxy, done in
            proxy.applyBlocklist(domains, overwriteExternalEdits: overwriteExternalEdits, withReply: done)
        })
    }

    func removeManagedSection(overwriteExternalEdits: Bool) async throws -> HostsApplyReport {
        try decode(await invoke(timeout: 60) { proxy, done in
            proxy.removeManagedSection(overwriteExternalEdits: overwriteExternalEdits, withReply: done)
        })
    }

    private func decode(_ data: Data) throws -> HostsApplyReport {
        let reply = HelperReply.decode(data)
        if let error = reply.error { throw HelperCallError.hosts(error) }
        guard let report = reply.report else { throw HelperCallError.connection("empty reply") }
        return report
    }

    private func invoke(timeout: TimeInterval,
                        _ call: @escaping @Sendable (QuietHostsHelperProtocol, @escaping @Sendable (Data) -> Void) -> Void) async throws -> Data {
        guard let team = CodeSigningIdentity.currentTeamIdentifier() else { throw HelperCallError.unsigned }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: QuietHostsHelperProtocol.self)
        connection.setCodeSigningRequirement(
            CodeSigningIdentity.requirement(identifier: HelperConstants.helperBundleIdentifier, teamIdentifier: team)
        )
        connection.resume()
        let box = ConnectionBox(connection)
        defer { box.connection.invalidate() }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let once = ResumeOnce(continuation)
            let proxy = box.connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(throwing: HelperCallError.connection(error.localizedDescription))
            }
            guard let helper = proxy as? QuietHostsHelperProtocol else {
                once.resume(throwing: HelperCallError.connection("unexpected proxy"))
                return
            }
            call(helper) { data in once.resume(returning: data) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.resume(throwing: HelperCallError.timeout)
            }
        }
    }
}

/// NSXPCConnection is thread-safe but not annotated Sendable.
private final class ConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection
    init(_ connection: NSXPCConnection) { self.connection = connection }
}

/// Resumes a continuation exactly once, whichever of reply, error or timeout
/// happens first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

    func resume(returning data: Data) {
        take()?.resume(returning: data)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
}
