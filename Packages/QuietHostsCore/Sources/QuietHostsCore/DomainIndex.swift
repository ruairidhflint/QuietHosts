import Foundation

/// The union of every imported source, de-duplicated, with a bitmask per
/// hostname recording which sources contain it.
///
/// The index is immutable and only rebuilt when a source's data changes
/// (import, refresh, removal). Turning a source on or off, adding rules and
/// searching never rebuild it: enabled state is applied as a mask at query time.
public final class DomainIndex: Sendable {
    public let list: DomainList
    public let masks: [UInt64]

    public static let empty = DomainIndex(list: .empty, masks: [])

    init(list: DomainList, masks: [UInt64]) {
        self.list = list
        self.masks = masks
    }

    public var count: Int { list.count }

    /// Merges per-source lists. `bit` must be in 0..<64 and unique.
    public convenience init(sources: [(bit: Int, list: DomainList)]) {
        let sources = sources.filter { !$0.list.isEmpty }
        if sources.isEmpty { self.init(list: .empty, masks: []); return }
        if sources.count == 1 {
            let only = sources[0]
            self.init(list: only.list, masks: Array(repeating: UInt64(1) << UInt64(only.bit), count: only.list.count))
            return
        }

        let totalBytes = sources.reduce(0) { $0 + $1.list.bytes.count }
        let totalCount = sources.reduce(0) { $0 + $1.list.count }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(totalBytes)
        var starts: [Int32] = []
        starts.reserveCapacity(totalCount + 1)
        var masks: [UInt64] = []
        masks.reserveCapacity(totalCount)

        var cursors = Array(repeating: 0, count: sources.count)
        // k is tiny (a handful of sources), so a linear scan of the heads is
        // simpler and faster than a heap.
        while true {
            var best = -1
            var bestMask: UInt64 = 0
            for k in sources.indices where cursors[k] < sources[k].list.count {
                if best < 0 {
                    best = k
                    bestMask = UInt64(1) << UInt64(sources[k].bit)
                    continue
                }
                let c = Self.compare(sources[k].list, cursors[k], sources[best].list, cursors[best])
                if c < 0 {
                    best = k
                    bestMask = UInt64(1) << UInt64(sources[k].bit)
                } else if c == 0 {
                    bestMask |= UInt64(1) << UInt64(sources[k].bit)
                }
            }
            if best < 0 { break }
            let winner = sources[best].list
            let i = cursors[best]
            starts.append(Int32(bytes.count))
            bytes.append(contentsOf: winner.bytes[Int(winner.starts[i])..<Int(winner.starts[i + 1])])
            masks.append(bestMask)
            // Advance every source whose head equals the winner.
            for k in sources.indices where cursors[k] < sources[k].list.count {
                if k == best || Self.compare(sources[k].list, cursors[k], winner, i) == 0 { cursors[k] += 1 }
            }
        }
        starts.append(Int32(bytes.count))
        self.init(list: DomainList(uncheckedBytes: bytes, starts: starts), masks: masks)
    }

    /// Compares record `i` of `a` with record `j` of `b`, terminators included.
    @inline(__always)
    static func compare(_ a: DomainList, _ i: Int, _ b: DomainList, _ j: Int) -> Int32 {
        let aStart = Int(a.starts[i]), aLen = Int(a.starts[i + 1]) - aStart
        let bStart = Int(b.starts[j]), bLen = Int(b.starts[j + 1]) - bStart
        return a.bytes.withUnsafeBufferPointer { ab in
            b.bytes.withUnsafeBufferPointer { bb in
                memcmp(ab.baseAddress! + aStart, bb.baseAddress! + bStart, min(aLen, bLen))
            }
        }
    }

    public func index(of domain: String) -> Int? { list.index(of: domain) }

    public func mask(of domain: String) -> UInt64 {
        guard let i = list.index(of: domain) else { return 0 }
        return masks[i]
    }

    /// Number of hostnames contained in at least one source in `enabledMask`.
    public func count(matching enabledMask: UInt64) -> Int {
        var n = 0
        for m in masks where m & enabledMask != 0 { n += 1 }
        return n
    }

    // MARK: Search

    public enum MatchRank: Int, Sendable, Comparable {
        case exact = 0
        /// The hostname starts with the query.
        case prefix = 1
        /// A label inside the hostname starts with the query (`www.rand…`, `m.rand…`).
        case labelPrefix = 2
        case substring = 3

        public static func < (a: MatchRank, b: MatchRank) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Matches: Sendable {
        /// Indices into `list`, best first, at most `limit` long.
        public var top: [(index: Int, rank: MatchRank)]
        /// Total number of matching hostnames.
        public var total: Int
    }

    /// Case-insensitive substring search. `query` must already be normalised
    /// (see `Hostname.normalize(searchQuery:)`).
    ///
    /// Scans the contiguous byte buffer with `memmem`, so cost is roughly a
    /// single pass over ~20 bytes per domain regardless of how many sources
    /// are loaded.
    public func search(_ query: String, limit: Int) -> Matches {
        let q = Array(query.utf8)
        guard !q.isEmpty, !list.isEmpty, !q.contains(0x0A) else { return Matches(top: [], total: 0) }

        var buckets: [[Int32]] = [[], [], [], []]
        let starts = list.starts
        let count = list.count

        list.bytes.withUnsafeBufferPointer { hb in
            q.withUnsafeBufferPointer { qb in
                let base = hb.baseAddress!
                let needle = qb.baseAddress!
                let qLen = qb.count
                let total = hb.count
                var pos = 0
                var lo = 0 // matches arrive in order, so the record search only moves forward
                while pos < total {
                    guard let found = memmem(base + pos, total - pos, needle, qLen) else { break }
                    let p = UnsafeRawPointer(found).assumingMemoryBound(to: UInt8.self) - base
                    // Locate the record containing offset p.
                    var hi = count - 1
                    while lo < hi {
                        let mid = (lo + hi + 1) >> 1
                        if Int(starts[mid]) <= p { lo = mid } else { hi = mid - 1 }
                    }
                    let id = lo
                    let s = Int(starts[id])
                    let e = Int(starts[id + 1]) - 1 // offset of "\n"

                    var rank: MatchRank
                    if p == s {
                        rank = (e - s == qLen) ? .exact : .prefix
                    } else if base[p - 1] == 0x2E {
                        rank = .labelPrefix
                    } else {
                        rank = .substring
                        // A later occurrence inside the same hostname may start a label.
                        var next = p + 1
                        while next + qLen <= e,
                              let again = memmem(base + next, e - next, needle, qLen) {
                            let ap = UnsafeRawPointer(again).assumingMemoryBound(to: UInt8.self) - base
                            if base[ap - 1] == 0x2E { rank = .labelPrefix; break }
                            next = ap + 1
                        }
                    }
                    buckets[rank.rawValue].append(Int32(id))
                    pos = e + 1
                }
            }
        }

        let total = buckets.reduce(0) { $0 + $1.count }
        var top: [(index: Int, rank: MatchRank)] = []
        top.reserveCapacity(min(limit, total))
        for r in 0..<4 where top.count < limit {
            let chosen = shortestFirst(buckets[r], limit: limit - top.count)
            let rank = MatchRank(rawValue: r)!
            for id in chosen { top.append((Int(id), rank)) }
        }
        return Matches(top: top, total: total)
    }

    /// Orders ids (already alphabetical) by hostname length, keeping
    /// alphabetical order within a length, and returns at most `limit`.
    /// Uses a length histogram so huge buckets (one-letter queries) stay O(n).
    func shortestFirst(_ ids: [Int32], limit: Int) -> [Int32] {
        if ids.isEmpty || limit <= 0 { return [] }
        if ids.count <= 64 {
            let sorted = ids.enumerated().sorted { a, b in
                let la = list.length(at: Int(a.element)), lb = list.length(at: Int(b.element))
                return la != lb ? la < lb : a.offset < b.offset
            }
            return Array(sorted.prefix(limit).map(\.element))
        }
        var histogram = [Int](repeating: 0, count: Hostname.maxLength + 2)
        for id in ids { histogram[min(list.length(at: Int(id)), Hostname.maxLength + 1)] += 1 }
        var cutoff = 0, running = 0
        while cutoff < histogram.count && running + histogram[cutoff] < limit {
            running += histogram[cutoff]
            cutoff += 1
        }
        // Everything shorter than `cutoff`, plus enough of length `cutoff`.
        var byLength = [[Int32]](repeating: [], count: min(cutoff, histogram.count - 1) + 1)
        for id in ids {
            let len = min(list.length(at: Int(id)), Hostname.maxLength + 1)
            if len < byLength.count { byLength[len].append(id) }
        }
        var out: [Int32] = []
        out.reserveCapacity(limit)
        for group in byLength {
            for id in group {
                if out.count == limit { return out }
                out.append(id)
            }
        }
        return out
    }

    /// Indices of indexed hostnames that are subdomains of `domain`
    /// (end with `.domain`).
    public func subdomains(of domain: String) -> [Int] {
        var needle = Array(("." + domain).utf8)
        needle.append(0x0A)
        var result: [Int] = []
        let starts = list.starts
        list.bytes.withUnsafeBufferPointer { hb in
            needle.withUnsafeBufferPointer { nb in
                guard let base = hb.baseAddress else { return }
                var pos = 0
                while pos < hb.count,
                      let found = memmem(base + pos, hb.count - pos, nb.baseAddress!, nb.count) {
                    let p = UnsafeRawPointer(found).assumingMemoryBound(to: UInt8.self) - base
                    let end = p + nb.count // start of the next record
                    // Binary search for the record that ends at `end`.
                    var lo = 0, hi = list.count - 1
                    while lo < hi {
                        let mid = (lo + hi + 1) >> 1
                        if Int(starts[mid]) <= p { lo = mid } else { hi = mid - 1 }
                    }
                    if Int(starts[lo]) < p { result.append(lo) }
                    pos = end
                }
            }
        }
        return result
    }
}
