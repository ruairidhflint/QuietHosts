import Foundation

/// Validation and normalisation rules for hostnames that QuietHosts is willing
/// to place in `/etc/hosts`.
///
/// The same rules run in the app (user input, imported lists) and again in the
/// privileged helper, which never trusts what it is sent.
public enum Hostname {
    public static let maxLength = 253
    public static let maxLabelLength = 63

    /// Top-level labels that are never written to the hosts file because doing
    /// so could break loopback, Bonjour or reverse lookups.
    public static let reservedTopLevelLabels: Set<String> = ["localhost", "local", "localdomain", "arpa"]

    public enum Problem: String, Error, Sendable, Equatable, Codable {
        case empty
        case tooLong
        case invalidCharacter
        case emptyLabel
        case labelTooLong
        case hyphenAtLabelEdge
        case singleLabel
        case numericTopLevel
        case reserved
    }

    // MARK: Byte-level validation

    /// Validates an ASCII hostname that has already been lower-cased.
    ///
    /// Accepts letters, digits, hyphens and (optionally) underscores, which do
    /// appear in real-world blocklists. Rejects anything that could inject extra
    /// fields or comments into a hosts line (whitespace, `#`, control bytes,
    /// non-ASCII), IP addresses and single-label names.
    public static func validateLowercased(_ p: UnsafeBufferPointer<UInt8>, allowUnderscore: Bool = true) -> Problem? {
        let n = p.count
        if n == 0 { return .empty }
        if n > maxLength { return .tooLong }

        var labelStart = 0
        var labels = 0
        var labelHasLetter = false
        var i = 0
        while i <= n {
            let c: UInt8 = i < n ? p[i] : 0x2E
            if c == 0x2E { // "."
                let len = i - labelStart
                if len == 0 { return .emptyLabel }
                if len > maxLabelLength { return .labelTooLong }
                if p[labelStart] == 0x2D || p[i - 1] == 0x2D { return .hyphenAtLabelEdge }
                labels += 1
                if i < n {
                    labelStart = i + 1
                    labelHasLetter = false
                }
            } else if c >= 0x61 && c <= 0x7A { // a-z
                labelHasLetter = true
            } else if (c >= 0x30 && c <= 0x39) || c == 0x2D { // 0-9, "-"
                // allowed
            } else if c == 0x5F && allowUnderscore { // "_"
                // allowed
            } else {
                return .invalidCharacter
            }
            i += 1
        }
        if labels < 2 { return .singleLabel }
        // `labelHasLetter` now describes the top-level label. An all-numeric
        // TLD means this is an IPv4 address (or nonsense), never a domain.
        if !labelHasLetter { return .numericTopLevel }

        let tld = UnsafeBufferPointer(rebasing: p[labelStart..<n])
        for reserved in reservedTopLevelLabels where reserved.utf8.count == tld.count {
            if reserved.utf8.elementsEqual(tld) { return .reserved }
        }
        return nil
    }

    public static func validate(_ hostname: String, allowUnderscore: Bool = true) -> Problem? {
        var copy = hostname
        return copy.withUTF8 { validateLowercased($0, allowUnderscore: allowUnderscore) }
    }

    public static func isValid(_ hostname: String, allowUnderscore: Bool = true) -> Bool {
        validate(hostname, allowUnderscore: allowUnderscore) == nil
    }

    // MARK: Related names

    /// The bare/`www.` counterpart of a hostname, used so that blocking or
    /// allowing "a site" covers both forms people actually type.
    public static func wwwTwin(of hostname: String) -> String? {
        if hostname.hasPrefix("www.") {
            let rest = String(hostname.dropFirst(4))
            return isValid(rest) ? rest : nil
        }
        let twin = "www." + hostname
        return isValid(twin) ? twin : nil
    }

    // MARK: User input

    public enum InputError: Error, Equatable, Sendable, LocalizedError {
        case empty
        case notAHostname
        case ipAddress
        case wildcard
        case reserved
        case invalid(Problem)

        public var errorDescription: String? {
            switch self {
            case .empty: "Enter a website, such as example.com."
            case .notAHostname: "That doesn’t look like a website address."
            case .ipAddress: "IP addresses can’t be blocked with the hosts file. Enter a domain name."
            case .wildcard: "The hosts file can’t block wildcards. Enter a specific name such as example.com."
            case .reserved: "That name is reserved for your Mac or local network and can’t be blocked."
            case .invalid(let problem):
                switch problem {
                case .singleLabel: "Enter a full domain name, such as example.com."
                case .tooLong, .labelTooLong: "That domain name is too long."
                case .numericTopLevel: "IP addresses can’t be blocked with the hosts file. Enter a domain name."
                case .reserved: "That name is reserved for your Mac or local network and can’t be blocked."
                default: "That isn’t a valid domain name."
                }
            }
        }
    }

    /// Extracts and normalises a hostname from something a person typed or
    /// pasted: `x.com`, `www.reddit.com`, `https://instagram.com/some/path`,
    /// `Example.COM:8080`, or an internationalised name.
    public static func normalize(userInput raw: String) -> Result<String, InputError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        if trimmed.contains("*") { return .failure(.wildcard) }

        let candidate = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let components = URLComponents(string: candidate),
              let rawHost = components.encodedHost ?? components.host,
              !rawHost.isEmpty
        else { return .failure(.notAHostname) }

        var host = rawHost.lowercased()
        if host.hasPrefix("[") || host.contains(":") { return .failure(.ipAddress) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return .failure(.notAHostname) }
        if isIPv4Literal(host) { return .failure(.ipAddress) }
        if host.contains("%") { return .failure(.notAHostname) }

        if let problem = validate(host, allowUnderscore: false) {
            if problem == .reserved { return .failure(.reserved) }
            if problem == .singleLabel, ["localhost", "broadcasthost", "local"].contains(host) { return .failure(.reserved) }
            if problem == .numericTopLevel { return .failure(.ipAddress) }
            return .failure(.invalid(problem))
        }
        return .success(host)
    }

    static func isIPv4Literal(_ s: String) -> Bool {
        var addr = in_addr()
        return s.withCString { inet_pton(AF_INET, $0, &addr) } == 1
    }

    /// Normalises a search string: lower-cases it, strips a URL scheme, path,
    /// port and surrounding whitespace. Returns nil if nothing searchable is left
    /// or it contains characters that cannot occur in a hostname.
    public static func normalize(searchQuery raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<slash]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        guard !s.isEmpty, s.utf8.count <= maxLength else { return nil }
        for c in s.utf8 {
            let ok = (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2E || c == 0x5F
            if !ok { return nil }
        }
        return s
    }
}
