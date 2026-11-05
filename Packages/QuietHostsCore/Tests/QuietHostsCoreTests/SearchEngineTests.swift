import Foundation
import Testing
@testable import QuietHostsCore

@Suite("Search engine")
struct SearchEngineTests {
    let index = DomainIndex(sources: [
        (0, DomainList(domains: ["randomsite.org", "www.randomsite.org", "randombooks.com", "brand.example.org"])),
        (1, DomainList(domains: ["randomexample.net"])),
    ])

    @Test("Finds list entries and user rules together")
    func listsAndRules() {
        var rules = RuleSet()
        rules.addWebsite("myrandom.example")
        rules.allowed["randomsite.org"] = .init(added: Date())
        let out = SearchEngine.search("rand", index: index, rules: rules)
        let names = out.hits.map(\.domain)
        #expect(names.contains("myrandom.example"))
        #expect(names.contains("www.myrandom.example"))
        #expect(names.first == "randomsite.org")
        #expect(out.total == names.count)
        #expect(out.hits.first { $0.domain == "randomexample.net" }?.sourceMask == 0b10)
        #expect(out.hits.first { $0.domain == "myrandom.example" }?.sourceMask == 0)
    }

    @Test("Reports exact matches and hostname queries")
    func hostnameQuery() {
        let found = SearchEngine.search("RandomSite.org", index: index, rules: RuleSet())
        #expect(found.exactMatchFound)
        #expect(found.hits.first?.rank == .exact)
        let missing = SearchEngine.search("https://notlisted.example.com/x", index: index, rules: RuleSet())
        #expect(missing.hostnameQuery == "notlisted.example.com")
        #expect(!missing.exactMatchFound)
        #expect(SearchEngine.search("rand", index: index, rules: RuleSet()).hostnameQuery == nil)
    }

    @Test("A www. query also finds the bare domain")
    func wwwQuery() {
        let out = SearchEngine.search("www.randombooks.com", index: index, rules: RuleSet())
        #expect(out.hits.map(\.domain) == ["randombooks.com"])
    }

    @Test("Highlights the best match")
    func highlight() {
        #expect(SearchEngine.matchRange(of: "ran", in: "foran.random.com") == 6..<9)
        #expect(SearchEngine.matchRange(of: "xyz", in: "abc.com") == nil)
    }

    @Test("Invalid queries return nothing")
    func invalid() {
        #expect(SearchEngine.search("a b", index: index, rules: RuleSet()) == .empty)
        #expect(SearchEngine.search("", index: index, rules: RuleSet()) == .empty)
    }
}
