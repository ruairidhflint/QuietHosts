import Foundation

/// The user's own rules, stored separately from imported list data so that
/// refreshing or re-importing a list can never touch them.
public struct RuleSet: Codable, Sendable, Equatable {
    public struct Allow: Codable, Sendable, Equatable {
        public var added: Date
        public init(added: Date) { self.added = added }
    }

    public struct Block: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var added: Date
        public init(enabled: Bool, added: Date) {
            self.enabled = enabled
            self.added = added
        }
    }

    /// Explicit exceptions. These win over everything else.
    public var allowed: [String: Allow]
    /// Websites the user blocked themselves ("My blocked sites").
    public var blocked: [String: Block]

    public init(allowed: [String: Allow] = [:], blocked: [String: Block] = [:]) {
        self.allowed = allowed
        self.blocked = blocked
    }
}

/// What QuietHosts does with a hostname.
public enum DomainState: Sendable, Equatable {
    /// Written to the hosts file (when protection is on).
    case blocked
    /// An explicit exception overrides every list and rule.
    case allowed
    /// Known to a list or rule, but every source that contains it is turned off.
    case inactive
    /// Not mentioned by any list or rule.
    case unrestricted
}

/// Everything needed to evaluate the policy, as an immutable value that can be
/// handed to background work.
public struct PolicySnapshot: Sendable {
    public var index: DomainIndex
    public var enabledSources: UInt64
    public var rules: RuleSet

    public init(index: DomainIndex, enabledSources: UInt64, rules: RuleSet) {
        self.index = index
        self.enabledSources = enabledSources
        self.rules = rules
    }

    /// Precedence:
    /// 1. explicit allow exception,
    /// 2. explicit (enabled) user block,
    /// 3. enabled imported lists,
    /// 4. otherwise unrestricted.
    public func state(of domain: String, sourceMask: UInt64? = nil) -> DomainState {
        let mask = sourceMask ?? index.mask(of: domain)
        if rules.allowed[domain] != nil { return .allowed }
        if rules.blocked[domain]?.enabled == true { return .blocked }
        if mask & enabledSources != 0 { return .blocked }
        if mask != 0 || rules.blocked[domain] != nil { return .inactive }
        return .unrestricted
    }

    /// The hostname plus its `www.` twin when the twin is known to a list or rule.
    func site(for domain: String) -> [String] {
        guard let twin = Hostname.wwwTwin(of: domain) else { return [domain] }
        let known = index.index(of: twin) != nil || rules.blocked[twin] != nil || rules.allowed[twin] != nil
        return known ? [domain, twin] : [domain]
    }
}

/// Explicit rule changes that depend on list data. Each operation leaves
/// exactly one unambiguous outcome: the latest action wins.
public extension PolicySnapshot {
    /// Allows `domain` (and its known `www.` twin): disables any user block and,
    /// where an imported list contains the name, records an exception that
    /// survives list refreshes.
    mutating func allow(_ domain: String, includeTwin: Bool = true, now: Date = Date()) {
        let targets = includeTwin ? site(for: domain) : [domain]
        for host in targets { allowSingle(host, now: now) }
    }

    /// Allows `domain`, its twin and every known subdomain.
    mutating func allowIncludingSubdomains(_ domain: String, now: Date = Date()) {
        allow(domain, now: now)
        var bases = [domain]
        if let twin = Hostname.wwwTwin(of: domain), !domain.hasPrefix("www.") { bases.append(twin) }
        for base in bases {
            for i in index.subdomains(of: base) { allowSingle(index.list.domain(at: i), now: now) }
        }
        for host in rules.blocked.keys where host.hasSuffix("." + domain) { allowSingle(host, now: now) }
    }

    /// Number of known subdomains (excluding the `www.` twin) that are blocked.
    func blockedSubdomainCount(of domain: String) -> Int {
        let twin = Hostname.wwwTwin(of: domain)
        var names = Set(index.subdomains(of: domain).map { index.list.domain(at: $0) })
        names.formUnion(rules.blocked.keys.filter { $0.hasSuffix("." + domain) })
        if let twin { names.remove(twin) }
        return names.reduce(0) { state(of: $1) == .blocked ? $0 + 1 : $0 }
    }

    private mutating func allowSingle(_ host: String, now: Date) {
        if rules.blocked[host] != nil { rules.blocked[host]?.enabled = false }
        if index.index(of: host) != nil, rules.allowed[host] == nil {
            rules.allowed[host] = RuleSet.Allow(added: now)
        }
    }

    /// Blocks `domain` (and its known `www.` twin): removes exceptions and, if no
    /// enabled list already covers the name, enables or creates a user block.
    mutating func block(_ domain: String, includeTwin: Bool = true, now: Date = Date()) {
        let targets = includeTwin ? site(for: domain) : [domain]
        for host in targets {
            rules.allowed[host] = nil
            if index.mask(of: host) & enabledSources != 0 { continue }
            if rules.blocked[host] != nil {
                rules.blocked[host]?.enabled = true
            } else {
                rules.blocked[host] = RuleSet.Block(enabled: true, added: now)
            }
        }
    }
}

public extension RuleSet {
    /// Adds a website from the "Add website" field: the bare and `www.` forms.
    mutating func addWebsite(_ domain: String, now: Date = Date()) {
        var hosts = [domain]
        if let twin = Hostname.wwwTwin(of: domain) { hosts.append(twin) }
        for host in hosts {
            allowed[host] = nil
            if blocked[host] != nil { blocked[host]?.enabled = true } else { blocked[host] = Block(enabled: true, added: now) }
        }
    }

    /// Turns a user block on or off (with its `www.` twin).
    mutating func setWebsite(_ domain: String, enabled: Bool) {
        var hosts = [domain]
        if let twin = Hostname.wwwTwin(of: domain) { hosts.append(twin) }
        for host in hosts where blocked[host] != nil {
            blocked[host]?.enabled = enabled
            if enabled { allowed[host] = nil }
        }
    }

    /// Removes a user block for the site (bare + `www.`). Imported lists are unaffected.
    mutating func removeWebsite(_ domain: String) {
        blocked[domain] = nil
        if let twin = Hostname.wwwTwin(of: domain) { blocked[twin] = nil }
    }

    /// Deletes an exception, so lists apply again.
    mutating func removeException(_ domain: String) {
        allowed[domain] = nil
    }
}

/// Computes the exact set of hostnames that belong in the hosts file.
public enum HostsPlanner {
    public struct Plan: Sendable, Equatable {
        /// Sorted, unique hostnames separated by `\n` (each followed by `\n`).
        public var domains: Data
        public var count: Int
    }

    /// Number of hostnames `plan` would produce, without building it.
    public static func count(_ snapshot: PolicySnapshot) -> Int {
        let index = snapshot.index
        let enabled = snapshot.enabledSources
        var n = index.count(matching: enabled)
        for host in snapshot.rules.allowed.keys {
            if let i = index.index(of: host), index.masks[i] & enabled != 0 { n -= 1 }
        }
        for (host, block) in snapshot.rules.blocked where block.enabled && snapshot.rules.allowed[host] == nil {
            if let i = index.index(of: host), index.masks[i] & enabled != 0 { continue }
            n += 1
        }
        return n
    }

    public static func plan(_ snapshot: PolicySnapshot) -> Plan {
        let index = snapshot.index
        let list = index.list
        let enabled = snapshot.enabledSources
        let rules = snapshot.rules

        // Exceptions that refer to indexed names, as a bitmap for O(1) checks.
        var excluded = [Bool](repeating: false, count: list.count)
        for host in rules.allowed.keys {
            if let i = index.index(of: host) { excluded[i] = true }
        }
        // Enabled user blocks that no enabled list already covers.
        var extras: [String] = []
        for (host, block) in rules.blocked where block.enabled && rules.allowed[host] == nil {
            if let i = index.index(of: host), index.masks[i] & enabled != 0 { continue }
            if Hostname.isValid(host) { extras.append(host) }
        }
        extras.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let extraBytes = extras.map { Array($0.utf8) }

        var out: [UInt8] = []
        out.reserveCapacity(list.bytes.count + extraBytes.reduce(0) { $0 + $1.count + 1 })
        var count = 0
        var e = 0
        list.bytes.withUnsafeBufferPointer { lb in
            let base = lb.baseAddress
            for i in 0..<list.count where index.masks[i] & enabled != 0 && !excluded[i] {
                let s = Int(list.starts[i]), end = Int(list.starts[i + 1]) // includes "\n"
                // Merge in any extras that sort before this record.
                while e < extraBytes.count {
                    let x = extraBytes[e]
                    let c = x.withUnsafeBufferPointer { memcmp($0.baseAddress!, base! + s, min(x.count, end - s - 1)) }
                    if c < 0 || (c == 0 && x.count < end - s - 1) {
                        out.append(contentsOf: x); out.append(0x0A); count += 1; e += 1
                    } else { break }
                }
                out.append(contentsOf: UnsafeBufferPointer(rebasing: lb[s..<end]))
                count += 1
            }
        }
        while e < extraBytes.count {
            out.append(contentsOf: extraBytes[e]); out.append(0x0A); count += 1; e += 1
        }
        return Plan(domains: Data(out), count: count)
    }
}
