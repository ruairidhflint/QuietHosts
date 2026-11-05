import Foundation
import Security

/// Identifiers shared by the app and the privileged helper.
public enum HelperConstants {
    public static let appBundleIdentifier = "com.quiethosts.QuietHosts"
    public static let helperBundleIdentifier = "com.quiethosts.helper"
    public static let machServiceName = "com.quiethosts.helper"
    public static let launchdPlistName = "com.quiethosts.helper.plist"
    /// Bumped whenever the XPC contract changes.
    public static let protocolVersion = 1
}

/// The complete privileged interface. It deliberately exposes only two
/// hosts-file operations and a version check; there is no way to pass a path,
/// a command or arbitrary file content.
///
/// - `applyBlocklist` takes sorted, newline-separated hostnames. The helper
///   validates every one and renders `0.0.0.0 <host>` lines itself, so a
///   caller can only ever *block* names, never redirect them.
@objc public protocol QuietHostsHelperProtocol {
    func helperVersion(withReply reply: @escaping @Sendable (Int) -> Void)
    func applyBlocklist(_ domains: Data, overwriteExternalEdits: Bool, withReply reply: @escaping @Sendable (Data) -> Void)
    func removeManagedSection(overwriteExternalEdits: Bool, withReply reply: @escaping @Sendable (Data) -> Void)
}

/// JSON payload returned by the helper.
public struct HelperReply: Codable, Sendable {
    public var report: HostsApplyReport?
    public var error: HostsFileError?

    public init(report: HostsApplyReport) { self.report = report; self.error = nil }
    public init(error: HostsFileError) { self.report = nil; self.error = error }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data) -> HelperReply {
        (try? JSONDecoder().decode(HelperReply.self, from: data))
            ?? HelperReply(error: .invalidRequest("the helper returned an unreadable reply"))
    }
}

/// Code-signing identity checks used on both ends of the XPC connection.
public enum CodeSigningIdentity {
    /// The Team ID this process is signed with, or nil for ad-hoc/unsigned code.
    public static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              isPlausibleTeamIdentifier(team)
        else { return nil }
        return team
    }

    static func isPlausibleTeamIdentifier(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { ($0.isASCII && $0.isLetter && $0.isUppercase) || ($0.isASCII && $0.isNumber) }
    }

    /// Requirement matching code with `identifier` signed by `teamIdentifier`
    /// through an Apple-issued certificate (Apple Development or Developer ID).
    ///
    /// Code carrying `get-task-allow` (debug builds, which other processes can
    /// attach to) is rejected, so only a Release-signed app can drive the
    /// privileged helper.
    public static func requirement(identifier: String, teamIdentifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
            + " and !(entitlement[\"com.apple.security.get-task-allow\"] exists)"
    }
}
