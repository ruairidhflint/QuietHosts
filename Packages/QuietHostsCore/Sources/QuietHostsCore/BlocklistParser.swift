import Foundation

/// Statistics describing what a parse accepted and rejected.
public struct ParseStats: Sendable, Equatable, Codable {
    public var lines = 0
    /// Hostname entries accepted (before de-duplication).
    public var accepted = 0
    /// Unique hostnames in the result.
    public var unique = 0
    /// Entries that looked like hostnames but failed validation.
    public var invalid = 0
    /// Lines in formats we deliberately do not interpret (Adblock Plus rules,
    /// regexes, multi-column lines without an address).
    public var unsupported = 0
    /// Loopback/broadcast/local names found in hosts headers.
    public var local = 0
    /// Hosts lines that map a name to a real address (a redirect, not a block).
    public var nonBlocking = 0
    /// `*.example.com` entries reduced to `example.com`.
    public var wildcardsReduced = 0
    public var looksLikeHTML = false
    public var isBinary = false

    public init() {}
}

public struct ParseResult: Sendable {
    public var domains: DomainList
    public var stats: ParseStats
}

/// Parses hosts-format (`0.0.0.0 example.com`) and domain-only
/// (`example.com`) blocklists.
///
/// Only sinkhole addresses (0.0.0.0, 127.x, ::, ::1, 0) are treated as blocks;
/// a hosts line that maps a name to any other address is skipped rather than
/// turned into a block. Adblock Plus syntax is recognised and skipped, never
/// guessed at.
public enum BlocklistParser {
    public static let maxLineLength = 4096

    public static func parse(_ data: Data) -> ParseResult {
        data.withUnsafeBytes { raw in
            parse(raw.bindMemory(to: UInt8.self))
        }
    }

    public static func parse(_ input: UnsafeBufferPointer<UInt8>) -> ParseResult {
        var stats = ParseStats()
        var p = input
        // UTF-8 byte order mark.
        if p.count >= 3, p[0] == 0xEF, p[1] == 0xBB, p[2] == 0xBF {
            p = UnsafeBufferPointer(rebasing: p[3...])
        }
        // Reject obvious non-lists: HTML error pages and binary files.
        if let first = p.firstIndex(where: { !isSpace($0) && $0 != 0x0A }), p[first] == 0x3C { // "<"
            stats.looksLikeHTML = true
            return ParseResult(domains: .empty, stats: stats)
        }
        if p.prefix(8192).contains(0) {
            stats.isBinary = true
            return ParseResult(domains: .empty, stats: stats)
        }

        var builder = DomainListBuilder(capacityBytes: p.count / 2)
        var tokens: [Range<Int>] = []
        tokens.reserveCapacity(8)

        var lineStart = 0
        let n = p.count
        while lineStart < n {
            var lineEnd = lineStart
            while lineEnd < n && p[lineEnd] != 0x0A { lineEnd += 1 }
            defer { lineStart = lineEnd + 1 }
            stats.lines += 1
            if lineEnd - lineStart > maxLineLength {
                stats.invalid += 1
                continue
            }

            // Strip comments and tokenise.
            var contentEnd = lineStart
            while contentEnd < lineEnd && p[contentEnd] != 0x23 { contentEnd += 1 } // "#"
            // `example.org##.ad`, `example.org#@#.ad`, `#?#`, `#$#`: Adblock
            // cosmetic filters, not a hostname followed by a comment.
            if contentEnd > lineStart, contentEnd + 1 < lineEnd, !isSpace(p[contentEnd - 1]) {
                let next = p[contentEnd + 1]
                if next == 0x23 || next == 0x40 || next == 0x3F || next == 0x24 || next == 0x25 {
                    stats.unsupported += 1
                    continue
                }
            }
            tokens.removeAll(keepingCapacity: true)
            var i = lineStart
            while i < contentEnd {
                while i < contentEnd && isSpace(p[i]) { i += 1 }
                let tokenStart = i
                while i < contentEnd && !isSpace(p[i]) { i += 1 }
                if i > tokenStart { tokens.append(tokenStart..<i) }
            }
            guard let firstToken = tokens.first else { continue }

            let leading = p[firstToken.lowerBound]
            if leading == 0x21 { continue } // "!" Adblock comment
            if leading == 0x5B { stats.unsupported += 1; continue } // "[Adblock Plus 2.0]"

            let first = UnsafeBufferPointer(rebasing: p[firstToken])
            switch addressKind(first) {
            case .sinkhole:
                for t in tokens.dropFirst() { accept(UnsafeBufferPointer(rebasing: p[t]), into: &builder, stats: &stats) }
            case .other:
                stats.nonBlocking += max(0, tokens.count - 1)
            case .notAnAddress:
                if tokens.count == 1 {
                    accept(first, into: &builder, stats: &stats)
                } else {
                    stats.unsupported += 1
                }
            }
        }

        let list = builder.build()
        stats.unique = list.count
        return ParseResult(domains: list, stats: stats)
    }

    @inline(__always)
    static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0B || c == 0x0C
    }

    private static func accept(_ token: UnsafeBufferPointer<UInt8>, into builder: inout DomainListBuilder, stats: inout ParseStats) {
        var t = token
        if t.count > 2, t[0] == 0x2A, t[1] == 0x2E { // "*."
            t = UnsafeBufferPointer(rebasing: t[2...])
            stats.wildcardsReduced += 1
        }
        // Characters that only occur in filter syntax (||, ^, $, /, *, @, =, …).
        for c in t {
            let plain = (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39)
                || c == 0x2D || c == 0x2E || c == 0x5F
            if !plain {
                if c >= 0x80 || c < 0x20 { stats.invalid += 1 } else { stats.unsupported += 1 }
                return
            }
        }
        if let problem = builder.appendCandidate(t) {
            switch problem {
            case .singleLabel, .reserved: stats.local += 1
            default: stats.invalid += 1
            }
        } else {
            stats.accepted += 1
        }
    }

    enum AddressKind { case sinkhole, other, notAnAddress }

    static func addressKind(_ t: UnsafeBufferPointer<UInt8>) -> AddressKind {
        var hasColon = false, onlyDigitsAndDots = true
        for c in t {
            if c == 0x3A { hasColon = true } else if !((c >= 0x30 && c <= 0x39) || c == 0x2E) { onlyDigitsAndDots = false }
        }
        if !hasColon && !onlyDigitsAndDots { return .notAnAddress } // fast path for ordinary hostnames
        let s = String(decoding: t, as: UTF8.self)
        if hasColon {
            // Any IPv6-looking token (including scoped ones like fe80::1%lo0).
            let sinkholes: Set<String> = ["::", "::0", "::1", "0:0:0:0:0:0:0:0", "0:0:0:0:0:0:0:1"]
            return sinkholes.contains(s) ? .sinkhole : .other
        }
        if s == "0" { return .sinkhole }
        guard t.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E }), Hostname.isIPv4Literal(s) else {
            return .notAnAddress
        }
        return (s == "0.0.0.0" || s.hasPrefix("127.")) ? .sinkhole : .other
    }
}
