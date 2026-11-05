import Foundation
import Testing
@testable import QuietHostsCore

@Suite("Hostname validation and normalisation")
struct HostnameTests {
    @Test("Accepts ordinary hostnames", arguments: [
        "example.com", "www.reddit.com", "a.b.c.d.example.co.uk", "xn--bcher-kva.de", "1337x.to",
        "my-site.org", "a1.b2", "ad_server.example.com",
    ])
    func acceptsValid(_ host: String) {
        #expect(Hostname.validate(host) == nil)
    }

    @Test("Rejects invalid hostnames")
    func rejectsInvalid() {
        #expect(Hostname.validate("") == .empty)
        #expect(Hostname.validate("localhost") == .singleLabel)
        #expect(Hostname.validate("com") == .singleLabel)
        #expect(Hostname.validate("example..com") == .emptyLabel)
        #expect(Hostname.validate(".example.com") == .emptyLabel)
        #expect(Hostname.validate("-bad.example.com") == .hyphenAtLabelEdge)
        #expect(Hostname.validate("bad-.example.com") == .hyphenAtLabelEdge)
        #expect(Hostname.validate("exa mple.com") == .invalidCharacter)
        #expect(Hostname.validate("Example.com") == .invalidCharacter) // must be lower-cased first
        #expect(Hostname.validate("example.com#x") == .invalidCharacter)
        #expect(Hostname.validate("bücher.de") == .invalidCharacter)
        #expect(Hostname.validate("192.168.0.1") == .numericTopLevel)
        #expect(Hostname.validate("0.0.0.0") == .numericTopLevel)
        #expect(Hostname.validate("example.123") == .numericTopLevel)
        #expect(Hostname.validate("printer.local") == .reserved)
        #expect(Hostname.validate("localhost.localdomain") == .reserved)
        #expect(Hostname.validate("1.0.0.127.in-addr.arpa") == .reserved)
        #expect(Hostname.validate("foo.localhost") == .reserved)
        #expect(Hostname.validate("ad_server.example.com", allowUnderscore: false) == .invalidCharacter)
        #expect(Hostname.validate(String(repeating: "a", count: 64) + ".com") == .labelTooLong)
        let long = (0..<26).map { _ in "abcdefghi" }.joined(separator: ".") + ".com"
        #expect(Hostname.validate(long) == .tooLong)
    }

    @Test("Rejects hosts-file injection attempts")
    func rejectsInjection() {
        for evil in ["evil.com\n1.2.3.4 bank.com", "evil.com 1.2.3.4", "evil.com\tbank.com", "evil.com\0x", "evil.com\r"] {
            #expect(Hostname.validate(evil) != nil, "\(evil.debugDescription) must be rejected")
        }
    }

    @Test("Normalises typed and pasted input")
    func normalisesInput() throws {
        #expect(try Hostname.normalize(userInput: "x.com").get() == "x.com")
        #expect(try Hostname.normalize(userInput: "  www.Reddit.com  ").get() == "www.reddit.com")
        #expect(try Hostname.normalize(userInput: "https://instagram.com/some/path?q=1").get() == "instagram.com")
        #expect(try Hostname.normalize(userInput: "Example.COM:8080/path").get() == "example.com")
        #expect(try Hostname.normalize(userInput: "http://user:pw@host.example.org/").get() == "host.example.org")
        #expect(try Hostname.normalize(userInput: "example.com.").get() == "example.com")
        #expect(try Hostname.normalize(userInput: "bücher.de").get() == "xn--bcher-kva.de")
    }

    @Test("Explains rejected input")
    func rejectsInput() {
        #expect(Hostname.normalize(userInput: "   ") == .failure(.empty))
        #expect(Hostname.normalize(userInput: "192.168.1.1") == .failure(.ipAddress))
        #expect(Hostname.normalize(userInput: "http://[::1]/") == .failure(.ipAddress))
        #expect(Hostname.normalize(userInput: "*.example.com") == .failure(.wildcard))
        #expect(Hostname.normalize(userInput: "localhost") == .failure(.reserved))
        #expect(Hostname.normalize(userInput: "nas.local") == .failure(.reserved))
        #expect(Hostname.normalize(userInput: "exa mple.com") == .failure(.notAHostname))
        #expect(Hostname.normalize(userInput: "intranet") == .failure(.invalid(.singleLabel)))
        #expect(Hostname.normalize(userInput: "bad_name.example.com") == .failure(.invalid(.invalidCharacter)))
    }

    @Test("Normalises search queries")
    func searchQueries() {
        #expect(Hostname.normalize(searchQuery: "Rand") == "rand")
        #expect(Hostname.normalize(searchQuery: "https://www.RandomSite.org/page") == "www.randomsite.org")
        #expect(Hostname.normalize(searchQuery: "  site.com:443 ") == "site.com")
        #expect(Hostname.normalize(searchQuery: "") == nil)
        #expect(Hostname.normalize(searchQuery: "a b") == nil)
    }

    @Test("www twin")
    func twins() {
        #expect(Hostname.wwwTwin(of: "example.com") == "www.example.com")
        #expect(Hostname.wwwTwin(of: "www.example.com") == "example.com")
        #expect(Hostname.wwwTwin(of: "www.com") == nil)
    }
}

@Suite("Blocklist parsing")
struct ParserTests {
    func parse(_ text: String) -> ParseResult { BlocklistParser.parse(Data(text.utf8)) }

    @Test("Parses hosts format, including StevenBlack-style headers")
    func hostsFormat() {
        let r = parse("""
        # Title: StevenBlack/hosts
        127.0.0.1 localhost
        127.0.0.1 localhost.localdomain
        255.255.255.255 broadcasthost
        ::1 localhost
        fe80::1%lo0 localhost
        0.0.0.0 0.0.0.0
        0.0.0.0 Ads.Example.com   # trailing comment
        0.0.0.0\ttracker.example.net
        127.0.0.1 one.example.org two.example.org
        :: six.example.com
        0 zero.example.com
        """)
        #expect(r.domains.allDomains == ["ads.example.com", "one.example.org", "six.example.com",
                                         "tracker.example.net", "two.example.org", "zero.example.com"])
        #expect(r.stats.nonBlocking == 2) // broadcasthost and fe80 lines
        #expect(r.stats.local >= 2)
    }

    @Test("Parses domain-only format with CRLF, BOM, wildcards and trailing dots")
    func domainOnly() {
        let r = BlocklistParser.parse(Data([0xEF, 0xBB, 0xBF]) + Data("example.com\r\n# c\r\n\r\n*.wild.example.org\r\nFQDN.example.net.\r\nexample.com\r\n".utf8))
        #expect(r.domains.allDomains == ["example.com", "fqdn.example.net", "wild.example.org"])
        #expect(r.stats.accepted == 4)
        #expect(r.stats.unique == 3)
        #expect(r.stats.wildcardsReduced == 1)
    }

    @Test("Skips Adblock Plus rules instead of guessing")
    func adblockSkipped() {
        let r = parse("""
        [Adblock Plus 2.0]
        ! comment
        ||ads.example.com^
        @@||allowed.example.com^
        /banner/*/ad.js
        example.org##.ad
        plain.example.com
        """)
        #expect(r.domains.allDomains == ["plain.example.com"])
        #expect(r.stats.unsupported == 5)
    }

    @Test("Never turns a redirect entry into a mapping")
    func redirectsIgnored() {
        let r = parse("1.2.3.4 bank.example.com\n8.8.8.8 dns.example.com\n0.0.0.0 blocked.example.com")
        #expect(r.domains.allDomains == ["blocked.example.com"])
        #expect(r.stats.nonBlocking == 2)
    }

    @Test("Rejects malicious and malformed entries")
    func malicious() {
        let long = String(repeating: "a", count: 300) + ".com"
        let r = parse("""
        0.0.0.0 evil.com;rm -rf
        0.0.0.0 $(whoami).example.com
        0.0.0.0 ünïcode.example.com
        0.0.0.0 \(long)
        0.0.0.0 -leading.example.com
        0.0.0.0 ok.example.com
        0.0.0.0 192.168.1.1
        multi word line
        """)
        #expect(r.domains.allDomains == ["ok.example.com"])
        #expect(r.stats.invalid + r.stats.unsupported + r.stats.local >= 6)
    }

    @Test("Detects HTML pages and binary data")
    func htmlAndBinary() {
        #expect(parse("  <!DOCTYPE html><html><body>404</body></html>").stats.looksLikeHTML)
        #expect(BlocklistParser.parse(Data([0x00, 0x01, 0x02, 0x41])).stats.isBinary)
        #expect(throws: ImportError.looksLikeHTML) { try ListImporter.validate(Data("<html>".utf8), previousCount: nil) }
    }

    @Test("Ignores absurdly long lines")
    func longLines() {
        let r = parse(String(repeating: "x", count: 10_000) + "\nok.example.com")
        #expect(r.domains.allDomains == ["ok.example.com"])
    }
}

@Suite("Domain index, de-duplication and search")
struct IndexTests {
    let adult = DomainList(domains: ["randomsite.org", "www.randomsite.org", "shared.example.com", "randombooks.com", "zzz.example"])
    let hagezi = DomainList(domains: ["shared.example.com", "other.example.net", "brand.example.org"])
    let social = DomainList(domains: ["randomexample.net", "a.example.com"])

    var index: DomainIndex { DomainIndex(sources: [(0, adult), (2, hagezi), (1, social)]) }

    @Test("Merges sources, de-duplicating while keeping attribution")
    func merge() {
        let idx = index
        #expect(idx.count == 9)
        #expect(idx.list.allDomains == idx.list.allDomains.sorted())
        #expect(idx.mask(of: "shared.example.com") == 0b101)
        #expect(idx.mask(of: "randomexample.net") == 0b010)
        #expect(idx.mask(of: "missing.example.com") == 0)
        #expect(idx.count(matching: 0b001) == 5)
        #expect(idx.count(matching: 0b111) == 9)
    }

    @Test("Search is case-insensitive, partial and ranked")
    func search() throws {
        let idx = index
        let q = try #require(Hostname.normalize(searchQuery: "RAND"))
        let m = idx.search(q, limit: 50)
        let names = m.top.map { idx.list.domain(at: $0.index) }
        // Prefix matches first (shortest first), then label prefix, then substring.
        #expect(names == ["randomsite.org", "randombooks.com", "randomexample.net", "www.randomsite.org", "brand.example.org"])
        #expect(m.top.map(\.rank) == [.prefix, .prefix, .prefix, .labelPrefix, .substring])
        #expect(m.total == 5)
    }

    @Test("Exact matches rank first")
    func exact() {
        let idx = DomainIndex(sources: [(0, DomainList(domains: ["x.com", "x.com.au", "box.com", "www.x.com"]))])
        let m = idx.search("x.com", limit: 10)
        #expect(m.top.first.map { idx.list.domain(at: $0.index) } == "x.com")
        #expect(m.top.first?.rank == .exact)
        #expect(m.total == 4)
    }

    @Test("Prefers label-start occurrences later in a hostname")
    func laterLabelMatch() {
        let idx = DomainIndex(sources: [(0, DomainList(domains: ["foran.random.com"]))])
        #expect(idx.search("ran", limit: 5).top.first?.rank == .labelPrefix)
    }

    @Test("Respects the result limit but reports the total")
    func limit() {
        let list = DomainList(domains: (0..<5000).map { "site\($0).example.com" })
        let idx = DomainIndex(sources: [(0, list)])
        let m = idx.search("site", limit: 100)
        #expect(m.top.count == 100)
        #expect(m.total == 5000)
        let lengths = m.top.map { idx.list.length(at: $0.index) }
        #expect(lengths == lengths.sorted())
    }

    @Test("Finds known subdomains")
    func subdomains() {
        let idx = DomainIndex(sources: [(0, DomainList(domains: ["example.com", "www.example.com", "cdn.example.com", "notexample.com", "example.com.evil.net"]))])
        let subs = Set(idx.subdomains(of: "example.com").map { idx.list.domain(at: $0) })
        #expect(subs == ["www.example.com", "cdn.example.com"])
    }

    @Test("Lookup and empty cases")
    func lookup() {
        let idx = index
        #expect(idx.index(of: "zzz.example") != nil)
        #expect(idx.index(of: "aaa.example") == nil)
        #expect(DomainIndex.empty.search("a", limit: 10).total == 0)
        #expect(idx.search("", limit: 10).total == 0)
    }
}

@Suite("Rule precedence")
struct PolicyTests {
    let adult = DomainList(domains: ["randomsite.org", "www.randomsite.org", "shared.example.com", "m.randomsite.org"])
    let hagezi = DomainList(domains: ["shared.example.com", "other.example.net"])

    func snapshot(enabled: UInt64 = 0b11, rules: RuleSet = RuleSet()) -> PolicySnapshot {
        PolicySnapshot(index: DomainIndex(sources: [(0, adult), (1, hagezi)]), enabledSources: enabled, rules: rules)
    }

    func planned(_ s: PolicySnapshot) -> [String] {
        String(decoding: HostsPlanner.plan(s).domains, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    @Test("An exception beats every source that lists the domain")
    func allowBeatsMultipleSources() {
        var s = snapshot()
        #expect(s.state(of: "shared.example.com") == .blocked)
        s.allow("shared.example.com")
        #expect(s.state(of: "shared.example.com") == .allowed)
        #expect(!planned(s).contains("shared.example.com"))
    }

    @Test("Exceptions survive the source data changing")
    func exceptionSurvivesRefresh() {
        var s = snapshot()
        s.allow("randomsite.org")
        // Simulate a refresh that re-imports the list.
        s.index = DomainIndex(sources: [(0, DomainList(domains: adult.allDomains + ["new.example.com"])), (1, hagezi)])
        #expect(s.state(of: "randomsite.org") == .allowed)
        #expect(!planned(s).contains("randomsite.org"))
        #expect(planned(s).contains("new.example.com"))
    }

    @Test("Allowing a site covers its www twin, not other subdomains")
    func allowTwin() {
        var s = snapshot()
        s.allow("randomsite.org")
        #expect(s.state(of: "www.randomsite.org") == .allowed)
        #expect(s.state(of: "m.randomsite.org") == .blocked)
        s.allowIncludingSubdomains("randomsite.org")
        #expect(s.state(of: "m.randomsite.org") == .allowed)
    }

    @Test("Custom blocks apply independently of list categories")
    func customBlocks() {
        var s = snapshot(enabled: 0)
        s.rules.addWebsite("x.com")
        #expect(s.state(of: "x.com") == .blocked)
        #expect(s.state(of: "www.x.com") == .blocked)
        #expect(planned(s) == ["www.x.com", "x.com"])
    }

    @Test("Latest action wins: block → allow → block")
    func latestActionWins() {
        var s = snapshot()
        s.rules.addWebsite("x.com")
        s.allow("x.com")
        #expect(s.state(of: "x.com") == .inactive) // user block disabled, no list covers it
        #expect(s.rules.blocked["x.com"]?.enabled == false)
        #expect(!planned(s).contains("x.com"))
        s.block("x.com")
        #expect(s.state(of: "x.com") == .blocked)
        #expect(planned(s).contains("x.com"))

        s.allow("randomsite.org")
        s.block("randomsite.org")
        #expect(s.state(of: "randomsite.org") == .blocked)
        #expect(s.rules.allowed["randomsite.org"] == nil)
        #expect(s.rules.blocked["randomsite.org"] == nil, "a list already covers it, so no redundant user block")
    }

    @Test("Adding a website removes a conflicting exception")
    func addRemovesException() {
        var s = snapshot()
        s.allow("randomsite.org")
        s.rules.addWebsite("randomsite.org")
        #expect(s.state(of: "randomsite.org") == .blocked)
    }

    @Test("Disabled sources are reported as inactive and can be blocked explicitly")
    func inactiveSource() {
        var s = snapshot(enabled: 0b10)
        #expect(s.state(of: "randomsite.org") == .inactive)
        #expect(!planned(s).contains("randomsite.org"))
        s.block("randomsite.org")
        #expect(s.state(of: "randomsite.org") == .blocked)
        #expect(planned(s).contains("randomsite.org"))
    }

    @Test("Explicit precedence: allow > user block > lists")
    func explicitPrecedence() {
        var rules = RuleSet()
        rules.blocked["shared.example.com"] = .init(enabled: true, added: Date())
        rules.allowed["shared.example.com"] = .init(added: Date())
        let s = snapshot(rules: rules)
        #expect(s.state(of: "shared.example.com") == .allowed)
        #expect(!planned(s).contains("shared.example.com"))
    }

    @Test("Plan is sorted, unique and merges user blocks")
    func planSortedUnique() {
        var s = snapshot()
        s.rules.addWebsite("aaa.example.com")
        s.rules.addWebsite("shared.example.com") // already listed
        let p = planned(s)
        #expect(p == p.sorted())
        #expect(Set(p).count == p.count)
        #expect(p.contains("aaa.example.com") && p.contains("www.aaa.example.com"))
        #expect(HostsPlanner.plan(s).count == p.count)
        #expect(HostsPlanner.count(s) == p.count)
        s.allow("randomsite.org")
        #expect(HostsPlanner.count(s) == HostsPlanner.plan(s).count)
    }

    @Test("Removing rules restores list behaviour")
    func removal() {
        var s = snapshot()
        s.allow("randomsite.org")
        s.rules.removeException("randomsite.org")
        #expect(s.state(of: "randomsite.org") == .blocked)
        s.rules.addWebsite("x.com")
        s.rules.removeWebsite("x.com")
        #expect(s.state(of: "x.com") == .unrestricted)
        #expect(s.rules.blocked.isEmpty)
    }
}
