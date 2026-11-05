import Foundation

public struct SearchHit: Sendable, Identifiable, Equatable, Hashable {
    public var domain: String
    /// Sources (bit positions) whose data contains the domain.
    public var sourceMask: UInt64
    public var rank: DomainIndex.MatchRank
    /// Byte range of the first match, for highlighting.
    public var matchRange: Range<Int>?

    public var id: String { domain }
}

public struct SearchOutcome: Sendable, Equatable {
    public var query: String
    public var hits: [SearchHit]
    /// Total matching hostnames (may exceed `hits.count`).
    public var total: Int
    /// The query as a valid hostname, when it is one.
    public var hostnameQuery: String?
    public var exactMatchFound: Bool

    public static let empty = SearchOutcome(query: "", hits: [], total: 0, hostnameQuery: nil, exactMatchFound: false)
}

/// Searches imported lists and the user's own rules together.
///
/// The index is searched in place; rules are a few hundred entries at most and
/// are scanned directly, so user-added names that appear in no list are still
/// found.
public enum SearchEngine {
    public static func search(_ raw: String, index: DomainIndex, rules: RuleSet, limit: Int = 300) -> SearchOutcome {
        guard let q = Hostname.normalize(searchQuery: raw) else { return .empty }

        var queries = [q]
        if q.hasPrefix("www."), q.count > 4 { queries.append(String(q.dropFirst(4))) }

        var byDomain: [String: SearchHit] = [:]
        var total = 0
        for (n, query) in queries.enumerated() {
            let matches = index.search(query, limit: limit)
            if n == 0 { total = matches.total }
            for m in matches.top {
                let domain = index.list.domain(at: m.index)
                if byDomain[domain] == nil {
                    // Results for the www-stripped query rank after the original.
                    let rank = n == 0 ? m.rank : max(m.rank, .labelPrefix)
                    byDomain[domain] = SearchHit(domain: domain, sourceMask: index.masks[m.index], rank: rank,
                                                 matchRange: matchRange(of: query, in: domain))
                } else if n > 0 {
                    continue
                }
                if n > 0 { total += 1 }
            }
        }

        // Rule entries that are not in any list.
        for domain in Set(rules.blocked.keys).union(rules.allowed.keys) where byDomain[domain] == nil {
            guard index.index(of: domain) == nil else { continue }
            for query in queries {
                guard let r = matchRange(of: query, in: domain) else { continue }
                byDomain[domain] = SearchHit(domain: domain, sourceMask: 0, rank: rank(of: r, query: query, in: domain), matchRange: r)
                total += 1
                break
            }
        }

        var hits = Array(byDomain.values)
        hits.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.domain.utf8.count != b.domain.utf8.count { return a.domain.utf8.count < b.domain.utf8.count }
            return a.domain < b.domain
        }
        if hits.count > limit { hits.removeLast(hits.count - limit) }

        let asHostname = Hostname.isValid(q, allowUnderscore: false) ? q : nil
        return SearchOutcome(query: q, hits: hits, total: max(total, hits.count), hostnameQuery: asHostname,
                             exactMatchFound: hits.contains { $0.domain == q })
    }

    static func matchRange(of query: String, in domain: String) -> Range<Int>? {
        let d = Array(domain.utf8), q = Array(query.utf8)
        guard q.count <= d.count, !q.isEmpty else { return nil }
        var best: Range<Int>?
        for start in 0...(d.count - q.count) where d[start..<start + q.count].elementsEqual(q) {
            let r = start..<start + q.count
            if start == 0 || d[start - 1] == 0x2E { return r }
            if best == nil { best = r }
        }
        return best
    }

    static func rank(of range: Range<Int>, query: String, in domain: String) -> DomainIndex.MatchRank {
        if range.lowerBound == 0 { return range.count == domain.utf8.count ? .exact : .prefix }
        return Array(domain.utf8)[range.lowerBound - 1] == 0x2E ? .labelPrefix : .substring
    }
}
