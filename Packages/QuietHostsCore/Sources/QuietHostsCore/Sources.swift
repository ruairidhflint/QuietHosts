import Foundation

/// A blocklist the user can turn on or off. Its domains live in a separate
/// cache file; this record only holds configuration and status.
public struct SourceDefinition: Codable, Identifiable, Sendable, Equatable {
    public enum Origin: Codable, Sendable, Equatable {
        case remote(URL)
        case file(path: String)
    }

    public var id: String
    public var name: String
    public var detail: String
    public var origin: Origin
    public var builtIn: Bool
    /// Bit position used in `DomainIndex` masks. Stable for the life of the source.
    public var bit: Int
    public var enabled: Bool
    public var domainCount: Int?
    public var lastUpdated: Date?
    public var lastError: String?

    public init(id: String, name: String, detail: String, origin: Origin, builtIn: Bool, bit: Int, enabled: Bool,
                domainCount: Int? = nil, lastUpdated: Date? = nil, lastError: String? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.origin = origin
        self.builtIn = builtIn
        self.bit = bit
        self.enabled = enabled
        self.domainCount = domainCount
        self.lastUpdated = lastUpdated
        self.lastError = lastError
    }

    public var mask: UInt64 { UInt64(1) << UInt64(bit) }
    public var isRemote: Bool { if case .remote = origin { true } else { false } }
    public var hasData: Bool { lastUpdated != nil }

    public var originDescription: String {
        switch origin {
        case .remote(let url): url.host() ?? url.absoluteString
        case .file(let path): (path as NSString).lastPathComponent
        }
    }
}

public enum BuiltInSources {
    public static let adultID = "stevenblack-porn"
    public static let socialID = "stevenblack-social"
    public static let hageziID = "hagezi-nsfw"

    public static let all: [SourceDefinition] = [
        SourceDefinition(
            id: adultID, name: "Adult content",
            detail: "StevenBlack’s adult-only hosts list. Recommended.",
            origin: .remote(URL(string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/porn-only/hosts")!),
            builtIn: true, bit: 0, enabled: true),
        SourceDefinition(
            id: socialID, name: "Social media",
            detail: "StevenBlack’s social-only list: Facebook, Instagram, TikTok, X and similar.",
            origin: .remote(URL(string: "https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/social-only/hosts")!),
            builtIn: true, bit: 1, enabled: false),
        SourceDefinition(
            id: hageziID, name: "Adult content (HaGeZi)",
            detail: "HaGeZi’s NSFW domain list, an alternative adult source. Using it alongside Adult content blocks more sites but can increase false positives.",
            origin: .remote(URL(string: "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/nsfw-onlydomains.txt")!),
            builtIn: true, bit: 2, enabled: false),
    ]
}

/// Persistent app settings (`settings.json`).
public struct AppSettings: Codable, Sendable, Equatable {
    public var protectionEnabled: Bool
    public var weeklyUpdates: Bool
    public var sources: [SourceDefinition]

    public init(protectionEnabled: Bool = true, weeklyUpdates: Bool = true, sources: [SourceDefinition] = BuiltInSources.all) {
        self.protectionEnabled = protectionEnabled
        self.weeklyUpdates = weeklyUpdates
        self.sources = sources
    }

    public var enabledMask: UInt64 {
        sources.reduce(0) { $1.enabled ? $0 | $1.mask : $0 }
    }

    /// Adds built-in sources introduced by newer versions.
    public mutating func addMissingBuiltIns() {
        for builtIn in BuiltInSources.all where !sources.contains(where: { $0.id == builtIn.id }) {
            var s = builtIn
            if sources.contains(where: { $0.bit == s.bit }), let bit = nextFreeBit() { s.bit = bit }
            sources.append(s)
        }
    }

    public func nextFreeBit() -> Int? {
        let used = Set(sources.map(\.bit))
        return (0..<64).first { !used.contains($0) }
    }
}

public enum ImportError: Error, Equatable, Sendable, LocalizedError {
    case insecureURL
    case httpStatus(Int)
    case tooLarge
    case looksLikeHTML
    case binary
    case noDomains(invalidLines: Int)
    case tooManyDomains(Int)
    case shrank(from: Int, to: Int)
    case network(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .insecureURL: "Only https:// addresses can be used for blocklists."
        case .httpStatus(let code): "The server responded with an error (HTTP \(code))."
        case .tooLarge: "The list is larger than 50 MB."
        case .looksLikeHTML: "The address returned a web page, not a blocklist."
        case .binary: "The file isn’t a text blocklist."
        case .noDomains(let invalid):
            invalid > 0 ? "No usable domains were found (\(invalid) lines weren’t valid hosts or domain entries)."
                : "No usable domains were found."
        case .tooManyDomains(let n): "The list has \(n.formatted()) domains, more than the 1,000,000 QuietHosts supports."
        case .shrank(let old, let new): "The new version has only \(new.formatted()) domains (was \(old.formatted())), which looks broken. The previous version was kept."
        case .network(let detail): detail
        case .unreadable(let detail): "The file couldn’t be read: \(detail)"
        }
    }
}

/// Fetches remote lists. Abstracted so tests never touch the network.
public protocol ListFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

public struct URLSessionListFetcher: ListFetching {
    public static let maxBytes = 50 * 1024 * 1024

    public init() {}

    public func fetch(_ url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw ImportError.insecureURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["User-Agent": "QuietHosts/1.0"]
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (fileURL, response): (URL, URLResponse)
        do {
            (fileURL, response) = try await session.download(from: url)
        } catch let error as URLError {
            throw ImportError.network(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ImportError.httpStatus(http.statusCode)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size > Self.maxBytes { throw ImportError.tooLarge }
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }
    }
}

public enum ListImporter {
    public static let maxDomains = 1_000_000

    /// Parses and sanity-checks downloaded or imported data. Nothing is
    /// written; the caller replaces the cache only if this succeeds.
    public static func validate(_ data: Data, previousCount: Int?) throws(ImportError) -> ParseResult {
        if data.count > URLSessionListFetcher.maxBytes { throw .tooLarge }
        let result = BlocklistParser.parse(data)
        if result.stats.looksLikeHTML { throw .looksLikeHTML }
        if result.stats.isBinary { throw .binary }
        let count = result.domains.count
        if count == 0 { throw .noDomains(invalidLines: result.stats.invalid + result.stats.unsupported) }
        if count > maxDomains { throw .tooManyDomains(count) }
        if let previous = previousCount, previous >= 1000, count < previous / 4 {
            throw .shrank(from: previous, to: count)
        }
        return result
    }
}

/// Files under `~/Library/Application Support/QuietHosts/`:
/// - `settings.json` – sources and preferences
/// - `rules.json` – the user's exceptions and blocked sites
/// - `lists/<id>.txt` – last known good copy of each list, one domain per line
public struct QuietHostsStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuietHosts", isDirectory: true)
    }

    public var settingsURL: URL { root.appendingPathComponent("settings.json") }
    public var rulesURL: URL { root.appendingPathComponent("rules.json") }
    public var listsDirectory: URL { root.appendingPathComponent("lists", isDirectory: true) }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: listsDirectory, withIntermediateDirectories: true)
    }

    // MARK: JSON

    public func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL) else { return AppSettings() }
        guard var settings = try? Self.decoder.decode(AppSettings.self, from: data) else {
            quarantine(settingsURL)
            return AppSettings()
        }
        settings.addMissingBuiltIns()
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        try Self.encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }

    /// Loads rules. A damaged file is moved aside (never deleted) and
    /// reported via `recovered`.
    public func loadRules() -> (rules: RuleSet, recovered: Bool) {
        guard let data = try? Data(contentsOf: rulesURL) else { return (RuleSet(), false) }
        if let rules = try? Self.decoder.decode(RuleSet.self, from: data) { return (rules, false) }
        quarantine(rulesURL)
        return (RuleSet(), true)
    }

    public func save(_ rules: RuleSet) throws {
        try Self.encoder.encode(rules).write(to: rulesURL, options: .atomic)
    }

    private func quarantine(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("damaged-\(stamp)"))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: List cache

    func listURL(_ id: String) -> URL {
        let safe = String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" })
        return listsDirectory.appendingPathComponent("\(safe).txt")
    }

    public func hasList(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: listURL(id).path)
    }

    public func loadList(_ id: String) throws -> DomainList {
        let data = try Data(contentsOf: listURL(id))
        return BlocklistParser.parse(data).domains
    }

    /// Atomically replaces the cached list.
    public func saveList(_ list: DomainList, id: String) throws {
        try prepare()
        try list.fileData.write(to: listURL(id), options: .atomic)
    }

    public func removeList(_ id: String) {
        try? FileManager.default.removeItem(at: listURL(id))
    }
}
