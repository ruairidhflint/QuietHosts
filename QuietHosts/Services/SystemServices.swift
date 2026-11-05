import Darwin
import Foundation
import ServiceManagement
import SystemConfiguration

/// Detects DNS resolvers that already filter adult content upstream. Hosts-file
/// exceptions can't override those, so we tell the user. Read-only and local:
/// it inspects the system's resolver configuration and never changes it.
enum UpstreamFilterDetector {
    struct Finding: Equatable {
        var provider: String
        var servers: [String]
    }

    static let filteringResolvers: [String: String] = [
        "1.1.1.3": "Cloudflare for Families", "1.0.0.3": "Cloudflare for Families",
        "2606:4700:4700::1113": "Cloudflare for Families", "2606:4700:4700::1003": "Cloudflare for Families",
        "208.67.222.123": "OpenDNS FamilyShield", "208.67.220.123": "OpenDNS FamilyShield",
        "185.228.168.10": "CleanBrowsing", "185.228.169.11": "CleanBrowsing",
        "185.228.168.168": "CleanBrowsing", "185.228.169.168": "CleanBrowsing",
        "94.140.14.15": "AdGuard Family", "94.140.15.16": "AdGuard Family",
    ]

    static func currentServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "QuietHosts" as CFString, nil, nil),
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dns["ServerAddresses"] as? [String]
        else { return [] }
        return servers
    }

    static func detect() -> Finding? {
        let servers = currentServers()
        let matches = servers.filter { filteringResolvers[$0] != nil }
        guard let first = matches.first, let provider = filteringResolvers[first] else { return nil }
        return Finding(provider: provider, servers: matches)
    }
}

/// Resolves a hostname through the normal system resolver (the same path
/// browsers use), to confirm whether the hosts file is in effect.
enum ResolverCheck {
    enum Outcome: Equatable {
        case blocked
        case resolves([String])
        case failed(String)

        var summary: String {
            switch self {
            case .blocked: "Blocked: resolves to 0.0.0.0"
            case .resolves(let addresses): "Reachable: resolves to \(addresses.prefix(2).joined(separator: ", "))"
            case .failed(let reason): "Doesn’t resolve (\(reason))"
            }
        }
    }

    static func check(_ host: String, family: Int32 = AF_UNSPEC) async -> Outcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: resolve(host, family: family))
            }
        }
    }

    private static func resolve(_ host: String, family: Int32) -> Outcome {
        var hints = addrinfo()
        hints.ai_family = family
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &result)
        guard rc == 0, let first = result else {
            return .failed(String(cString: gai_strerror(rc)))
        }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let ai = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !addresses.contains(s) { addresses.append(s) }
            }
            cursor = ai.pointee.ai_next
        }
        let sinkholes: Set<String> = ["0.0.0.0", "::", "127.0.0.1", "::1"]
        if !addresses.isEmpty && addresses.allSatisfy({ sinkholes.contains($0) }) { return .blocked }
        return addresses.isEmpty ? .failed("no addresses") : .resolves(addresses)
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
