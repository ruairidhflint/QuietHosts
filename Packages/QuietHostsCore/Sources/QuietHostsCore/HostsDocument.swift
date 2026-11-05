import CryptoKit
import Foundation

/// Errors from reading, validating or writing the hosts file. Codable so the
/// helper can return them over XPC unchanged.
public enum HostsFileError: Error, Equatable, Sendable, Codable, LocalizedError {
    case missing
    case notRegularFile
    case symlink
    case tooLarge(bytes: Int)
    case unsafeOwnership(String)
    case unreadable(String)
    case malformedSection(String)
    case externallyModified
    case changedDuringWrite
    case writeFailed(String)
    case verificationFailed
    case backupFailed(String)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .missing: "The hosts file doesn’t exist."
        case .notRegularFile: "The hosts file isn’t a regular file, so QuietHosts won’t modify it."
        case .symlink: "The hosts file is a symbolic link, so QuietHosts won’t modify it."
        case .tooLarge(let bytes): "The hosts file is unexpectedly large (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))."
        case .unsafeOwnership(let detail): "The hosts file has unexpected ownership or permissions (\(detail)), so QuietHosts won’t modify it."
        case .unreadable(let detail): "The hosts file couldn’t be read: \(detail)"
        case .malformedSection(let detail): "The QuietHosts section of the hosts file is damaged (\(detail)). Nothing was changed."
        case .externallyModified: "The QuietHosts section of the hosts file was edited outside the app."
        case .changedDuringWrite: "The hosts file changed while QuietHosts was updating it. Nothing was changed."
        case .writeFailed(let detail): "The hosts file couldn’t be written: \(detail)"
        case .verificationFailed: "The hosts file didn’t contain the expected content after writing."
        case .backupFailed(let detail): "A backup of the hosts file couldn’t be created, so nothing was changed: \(detail)"
        case .invalidRequest(let detail): "The update was rejected: \(detail)"
        }
    }
}

/// The QuietHosts-managed block inside the hosts file.
public enum ManagedSection {
    public static let beginPrefix = "# >>> QuietHosts BEGIN"
    public static let endPrefix = "# <<< QuietHosts END"
    /// Every blocked name gets an IPv4 and an IPv6 sinkhole entry. mDNSResponder
    /// only answers a query from a hosts entry of the same address family, so an
    /// IPv4-only entry would let AAAA lookups fall through to real DNS and the
    /// site would still load over IPv6.
    public static let sinkholeV4 = "0.0.0.0 "
    public static let sinkholeV6 = ":: "

    /// Hard limits the helper enforces on requests.
    public static let maxEntries = 1_000_000
    public static let maxRequestBytes = 64 * 1024 * 1024

    /// Renders the body (`0.0.0.0 host` and `:: host` lines) from a newline-separated list of
    /// hostnames, validating every entry. Entries must be sorted and unique so
    /// that output is deterministic.
    public static func renderBody(fromDomainList data: Data) throws(HostsFileError) -> (body: Data, count: Int) {
        if data.count > maxRequestBytes { throw .invalidRequest("too much data") }
        var body: [UInt8] = []
        body.reserveCapacity(data.count * 2 + (data.count / 12) * 11)
        var count = 0
        let v4 = Array(sinkholeV4.utf8)
        let v6 = Array(sinkholeV6.utf8)
        var failure: HostsFileError?
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var start = 0
            var previous: Range<Int>?
            while start < p.count {
                var end = start
                while end < p.count && p[end] != 0x0A { end += 1 }
                let line = UnsafeBufferPointer(rebasing: p[start..<end])
                if let problem = Hostname.validateLowercased(line) {
                    let shown = String(decoding: line.prefix(80), as: UTF8.self)
                    failure = .invalidRequest("“\(shown)” is not an acceptable hostname (\(problem.rawValue))")
                    return
                }
                if let prev = previous {
                    let a = UnsafeBufferPointer(rebasing: p[prev])
                    if !a.lexicographicallyPrecedes(line) {
                        failure = .invalidRequest("entries must be sorted and unique")
                        return
                    }
                }
                count += 1
                if count > maxEntries {
                    failure = .invalidRequest("more than \(maxEntries) entries")
                    return
                }
                body.append(contentsOf: v4)
                body.append(contentsOf: line)
                body.append(0x0A)
                body.append(contentsOf: v6)
                body.append(contentsOf: line)
                body.append(0x0A)
                previous = start..<end
                start = end + 1
            }
        }
        if let failure { throw failure }
        return (Data(body), count)
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func beginLine(count: Int, sha256: String) -> String {
        "\(beginPrefix) - managed by QuietHosts.app; edits here will be replaced (entries=\(count) sha256=\(sha256))"
    }

    public static func endLine() -> String { endPrefix }

    /// The full managed block including markers, each line `\n`-terminated.
    public static func render(body: Data, count: Int) -> Data {
        var out = Data()
        out.reserveCapacity(body.count + 200)
        out.append(contentsOf: Array((beginLine(count: count, sha256: sha256Hex(body)) + "\n").utf8))
        out.append(body)
        out.append(contentsOf: Array((endLine() + "\n").utf8))
        return out
    }
}

/// A parsed hosts file: everything outside the managed block is kept as raw
/// bytes and reproduced exactly.
public struct HostsDocument: Sendable, Equatable {
    public struct Section: Sendable, Equatable {
        /// Byte range of the whole block, from the start of the begin line to
        /// just after the end line's newline (or end of file).
        public var range: Range<Int>
        public var declaredCount: Int?
        public var declaredSHA256: String?
        public var body: Data
        public var actualSHA256: String

        public var isIntact: Bool { declaredSHA256 == actualSHA256 }
        public var entryCount: Int { declaredCount ?? 0 }
    }

    public let data: Data
    public let section: Section?

    /// Parses `data`; throws if there is more than one managed block or the
    /// markers are unbalanced, rather than guessing where the block ends.
    public init(_ input: Data) throws(HostsFileError) {
        // Work on a zero-based copy so byte offsets and Data indices agree.
        let data = input.startIndex == 0 ? input : input.withUnsafeBytes { Data($0) }
        self.data = data
        var begins: [(lineStart: Int, lineEnd: Int)] = []
        var ends: [(lineStart: Int, lineEnd: Int)] = []
        let beginBytes = Array(ManagedSection.beginPrefix.utf8)
        let endBytes = Array(ManagedSection.endPrefix.utf8)
        let markerFragment = Array("QuietHosts".utf8)

        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var start = 0
            while start < p.count {
                var end = start
                while end < p.count && p[end] != 0x0A { end += 1 }
                var s = start
                while s < end && (p[s] == 0x20 || p[s] == 0x09) { s += 1 }
                let line = UnsafeBufferPointer(rebasing: p[s..<end])
                if line.count >= 6, line[0] == 0x23, line.starts(with: beginBytes) {
                    begins.append((start, end))
                } else if line.count >= 6, line[0] == 0x23, line.starts(with: endBytes) {
                    ends.append((start, end))
                } else if line.first == 0x23, line.count < 512,
                          (line.firstRange(of: markerFragment) != nil),
                          (line.firstRange(of: Array(">>>".utf8)) != nil || line.firstRange(of: Array("<<<".utf8)) != nil) {
                    // Something that looks like a damaged marker.
                    begins.append((start, end)); ends.append((start, end))
                }
                start = end + 1
            }
        }

        if begins.isEmpty && ends.isEmpty {
            section = nil
            return
        }
        guard begins.count == 1, ends.count == 1 else {
            throw .malformedSection("found \(begins.count) start and \(ends.count) end markers")
        }
        let begin = begins[0], end = ends[0]
        guard begin.lineEnd < end.lineStart else {
            throw .malformedSection("the end marker comes before the start marker")
        }
        let bodyRange = (begin.lineEnd + 1)..<end.lineStart
        let body = data.subdata(in: bodyRange)
        let header = String(decoding: data.subdata(in: begin.lineStart..<begin.lineEnd), as: UTF8.self)
        let rangeEnd = min(end.lineEnd + 1, data.count)
        section = Section(
            range: begin.lineStart..<rangeEnd,
            declaredCount: Self.field("entries", in: header).flatMap { Int($0) },
            declaredSHA256: Self.field("sha256", in: header),
            body: body,
            actualSHA256: ManagedSection.sha256Hex(body)
        )
    }

    private static func field(_ name: String, in header: String) -> String? {
        guard let r = header.range(of: name + "=") else { return nil }
        let rest = header[r.upperBound...]
        let value = rest.prefix { $0.isLetter || $0.isNumber }
        return value.isEmpty ? nil : String(value)
    }

    /// Content outside the managed block.
    public var unmanagedContent: Data {
        guard let section else { return data }
        var out = data.subdata(in: 0..<section.range.lowerBound)
        out.append(data.subdata(in: section.range.upperBound..<data.count))
        return out
    }

    /// Produces the new file contents with the managed block replaced by
    /// `block` (or removed when `block` is nil). Everything else is preserved
    /// byte for byte; a new block is appended at the end of the file.
    public func replacingSection(with block: Data?) -> Data {
        if let section {
            var out = data.subdata(in: 0..<section.range.lowerBound)
            if let block { out.append(block) }
            out.append(data.subdata(in: section.range.upperBound..<data.count))
            return out
        }
        guard let block else { return data }
        var out = data
        if let last = out.last, last != 0x0A { out.append(0x0A) }
        out.append(block)
        return out
    }
}
