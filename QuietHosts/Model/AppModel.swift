import AppKit
import Foundation
import Observation
import QuietHostsCore

/// Coordinates persistent state, list data, search, rule changes and applying
/// the resulting policy to the hosts file through the helper.
@MainActor
@Observable
final class AppModel {
    // MARK: Dependencies

    let store: QuietHostsStore
    let helper: HelperManager
    @ObservationIgnored private let client = HelperClient()
    @ObservationIgnored private let fetcher: ListFetching
    /// Read without privileges to verify what is actually in effect.
    @ObservationIgnored let hostsPath: String

    // MARK: Persistent state

    private(set) var settings: AppSettings
    private(set) var rules: RuleSet
    private(set) var rulesWereRecovered = false

    // MARK: List data

    private(set) var index: DomainIndex = .empty
    @ObservationIgnored private var lists: [String: DomainList] = [:]
    private(set) var isLoadingLists = true
    private(set) var refreshing: Set<String> = []
    private(set) var blockedCount = 0

    // MARK: Applying

    enum ApplyState: Equatable {
        case starting
        case applying
        case applied(Date)
        case needsHelper
        case externallyEdited
        case failed(String)
    }

    private(set) var applyState: ApplyState = .starting
    private(set) var lastReport: HostsApplyReport?
    /// Result of independently reading /etc/hosts and comparing checksums.
    private(set) var hostsVerified: Bool?
    @ObservationIgnored private var desiredGeneration = 0
    @ObservationIgnored private var appliedGeneration = -1
    private(set) var pendingDomains: [String: Int] = [:]
    @ObservationIgnored private var applyRequested = false
    @ObservationIgnored private var overwriteRequested = false
    @ObservationIgnored private var isApplying = false

    // MARK: Search

    var query = "" {
        didSet { if query != oldValue { runSearch() } }
    }
    private(set) var outcome: SearchOutcome = .empty
    var selection: Int?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    private(set) var resolverChecks: [String: ResolverCheck.Outcome?] = [:]

    // MARK: Environment

    private(set) var upstreamFilter: UpstreamFilterDetector.Finding?
    var addingWebsite = false
    @ObservationIgnored private var weeklyTask: Task<Void, Never>?

    init(store: QuietHostsStore = QuietHostsStore(root: QuietHostsStore.defaultRoot),
         helper: HelperManager = HelperManager(),
         fetcher: ListFetching = URLSessionListFetcher(),
         hostsPath: String = "/private/etc/hosts") {
        self.store = store
        self.helper = helper
        self.fetcher = fetcher
        self.hostsPath = hostsPath
        try? store.prepare()
        settings = store.loadSettings()
        let loaded = store.loadRules()
        rules = loaded.rules
        rulesWereRecovered = loaded.recovered
    }

    // MARK: Lifecycle

    func start() {
        helper.refresh()
        upstreamFilter = UpstreamFilterDetector.detect()
        Task {
            await loadLists()
            await verifyHostsFile(adoptIfInSync: true)
            // First run: fetch enabled lists that have never been downloaded.
            for source in settings.sources where source.enabled && lists[source.id] == nil && source.isRemote {
                await refresh(source.id)
            }
        }
        scheduleWeeklyUpdates()
    }

    /// Called whenever the popover or manage window is shown.
    func didBecomeVisible() {
        helper.refresh()
        upstreamFilter = UpstreamFilterDetector.detect()
        if !isApplying && !isLoadingLists {
            Task { await verifyHostsFile(adoptIfInSync: false) }
        }
    }

    func helperStatusChanged() {
        if helper.isReady, !isLoadingLists, hostsVerified != true || applyState == .needsHelper {
            requestApply()
        }
    }

    private func loadLists() async {
        let store = self.store
        let ids = settings.sources.map(\.id)
        let loaded = await Task.detached(priority: .userInitiated) {
            var out: [String: DomainList] = [:]
            for id in ids where store.hasList(id) {
                if let list = try? store.loadList(id) { out[id] = list }
            }
            return out
        }.value
        lists = loaded
        for i in settings.sources.indices {
            if let list = loaded[settings.sources[i].id] { settings.sources[i].domainCount = list.count }
        }
        await rebuildIndex()
        isLoadingLists = false
    }

    private func rebuildIndex() async {
        let inputs = settings.sources.compactMap { s in lists[s.id].map { (bit: s.bit, list: $0) } }
        let built = await Task.detached(priority: .userInitiated) { DomainIndex(sources: inputs) }.value
        index = built
        recount()
        runSearch()
    }

    // MARK: Derived state

    var policy: PolicySnapshot {
        PolicySnapshot(index: index, enabledSources: settings.enabledMask, rules: rules)
    }

    private func recount() {
        blockedCount = HostsPlanner.count(policy)
    }

    func state(of hit: SearchHit) -> DomainState {
        policy.state(of: hit.domain, sourceMask: hit.sourceMask)
    }

    func state(of domain: String) -> DomainState {
        policy.state(of: domain)
    }

    enum Pending { case none, applying, notApplied }

    /// Whether a rule change for `domain` is still on its way to the hosts file.
    func pending(_ domain: String) -> Pending {
        guard let g = pendingDomains[domain], g > appliedGeneration else { return .none }
        return applyState == .applying ? .applying : .notApplied
    }

    func isPending(_ domain: String) -> Bool { pending(domain) != .none }

    var isUpToDate: Bool {
        if case .applied = applyState { return appliedGeneration == desiredGeneration }
        return false
    }

    /// Names of the sources containing a domain, plus "My blocked sites".
    func sourceNames(for domain: String, mask: UInt64) -> [String] {
        var names = settings.sources.filter { mask & $0.mask != 0 }.map(\.name)
        if rules.blocked[domain] != nil { names.append("My blocked sites") }
        if names.isEmpty && rules.allowed[domain] != nil { names.append("Your exception") }
        return names
    }

    func source(_ id: String) -> SourceDefinition? { settings.sources.first { $0.id == id } }

    /// Sources that contain `domain` but are currently turned off.
    func disabledSourceNames(for mask: UInt64) -> [String] {
        settings.sources.filter { mask & $0.mask != 0 && !$0.enabled }.map(\.name)
    }

    var customSites: [(domain: String, block: RuleSet.Block, alsoWWW: Bool)] {
        var out: [(String, RuleSet.Block, Bool)] = []
        for (domain, block) in rules.blocked {
            if domain.hasPrefix("www."), let bare = Hostname.wwwTwin(of: domain), rules.blocked[bare] != nil { continue }
            let twin = Hostname.wwwTwin(of: domain)
            out.append((domain, block, twin.map { rules.blocked[$0] != nil } ?? false))
        }
        return out.sorted { $0.0 < $1.0 }.map { (domain: $0.0, block: $0.1, alsoWWW: $0.2) }
    }

    var customSiteCount: Int { customSites.count }

    // MARK: Protection

    func setProtection(_ enabled: Bool) {
        guard settings.protectionEnabled != enabled else { return }
        settings.protectionEnabled = enabled
        policyDidChange()
    }

    /// Emergency action: remove every QuietHosts entry, even if the section was
    /// edited outside the app. Unrelated hosts entries are untouched.
    func removeAllEntries() {
        settings.protectionEnabled = false
        policyDidChange(overwrite: true)
    }

    func overwriteExternalEdits() {
        requestApply(overwrite: true)
    }

    // MARK: Rules

    func toggle(_ domain: String) {
        switch state(of: domain) {
        case .blocked: allow(domain)
        case .allowed, .inactive, .unrestricted: block(domain)
        }
    }

    func allow(_ domain: String, includingSubdomains: Bool = false) {
        var snapshot = policy
        let before = snapshot.rules
        if includingSubdomains { snapshot.allowIncludingSubdomains(domain) } else { snapshot.allow(domain) }
        rules = snapshot.rules
        policyDidChange(domains: changedDomains(before, rules))
    }

    func block(_ domain: String) {
        var snapshot = policy
        let before = snapshot.rules
        snapshot.block(domain)
        rules = snapshot.rules
        policyDidChange(domains: changedDomains(before, rules))
        if outcome.hits.contains(where: { $0.domain == domain }) == false { runSearch() }
    }

    func blockedSubdomainCount(of domain: String) -> Int {
        policy.blockedSubdomainCount(of: domain)
    }

    @discardableResult
    func addWebsite(_ input: String) -> Result<String, Hostname.InputError> {
        let result = Hostname.normalize(userInput: input)
        if case .success(let domain) = result {
            let before = rules
            rules.addWebsite(domain)
            policyDidChange(domains: changedDomains(before, rules))
            runSearch()
        }
        return result
    }

    func setWebsite(_ domain: String, enabled: Bool) {
        let before = rules
        rules.setWebsite(domain, enabled: enabled)
        policyDidChange(domains: changedDomains(before, rules))
    }

    func removeWebsite(_ domain: String) {
        let before = rules
        rules.removeWebsite(domain)
        policyDidChange(domains: changedDomains(before, rules))
        runSearch()
    }

    func removeException(_ domain: String) {
        let before = rules
        rules.removeException(domain)
        policyDidChange(domains: changedDomains(before, rules))
    }

    private func changedDomains(_ a: RuleSet, _ b: RuleSet) -> [String] {
        var changed = Set<String>()
        for key in Set(a.allowed.keys).symmetricDifference(b.allowed.keys) { changed.insert(key) }
        for key in Set(a.blocked.keys).union(b.blocked.keys) where a.blocked[key]?.enabled != b.blocked[key]?.enabled {
            changed.insert(key)
        }
        return Array(changed)
    }

    // MARK: Sources

    func setSource(_ id: String, enabled: Bool) {
        guard let i = settings.sources.firstIndex(where: { $0.id == id }) else { return }
        settings.sources[i].enabled = enabled
        policyDidChange()
        if enabled && lists[id] == nil {
            Task { await refresh(id) }
        }
    }

    func refreshAll() async {
        for source in settings.sources where source.enabled || lists[source.id] != nil {
            await refresh(source.id)
        }
    }

    /// Downloads (or re-reads) a source into a temporary buffer, validates it,
    /// and only then replaces the cached copy. Failures keep the last good list.
    func refresh(_ id: String) async {
        guard !refreshing.contains(id), let source = source(id) else { return }
        refreshing.insert(id)
        defer { refreshing.remove(id) }
        let previous = lists[id]?.count
        do {
            let parsed = try await Self.fetchAndValidate(source.origin, previousCount: previous, fetcher: fetcher)
            try store.saveList(parsed.domains, id: id)
            lists[id] = parsed.domains
            update(id) {
                $0.domainCount = parsed.domains.count
                $0.lastUpdated = Date()
                $0.lastError = nil
            }
            await rebuildIndex()
            if self.source(id)?.enabled == true { policyDidChange() } else { persist() }
        } catch {
            update(id) { $0.lastError = error.localizedDescription }
            persist()
        }
    }

    nonisolated private static func fetchAndValidate(_ origin: SourceDefinition.Origin, previousCount: Int?,
                                                     fetcher: ListFetching) async throws -> ParseResult {
        let data: Data
        switch origin {
        case .remote(let url):
            data = try await fetcher.fetch(url)
        case .file(let path):
            guard let contents = FileManager.default.contents(atPath: path) else {
                throw ImportError.unreadable("\((path as NSString).lastPathComponent) is no longer available")
            }
            data = contents
        }
        return try await Task.detached(priority: .userInitiated) {
            try ListImporter.validate(data, previousCount: previousCount)
        }.value
    }

    /// Imports a new custom source. Nothing is added unless the list is valid.
    func addSource(origin: SourceDefinition.Origin, name: String?) async throws {
        guard let bit = settings.nextFreeBit() else {
            throw ImportError.network("You’ve reached the limit of 64 lists.")
        }
        if case .remote(let url) = origin, url.scheme?.lowercased() != "https" { throw ImportError.insecureURL }
        let parsed = try await Self.fetchAndValidate(origin, previousCount: nil, fetcher: fetcher)
        let id = "custom-" + UUID().uuidString.lowercased()
        let fallbackName: String = switch origin {
        case .remote(let url): url.host() ?? "Custom list"
        case .file(let path): ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = SourceDefinition(
            id: id, name: trimmed.isEmpty ? fallbackName : trimmed,
            detail: "",
            origin: origin, builtIn: false, bit: bit, enabled: true,
            domainCount: parsed.domains.count, lastUpdated: Date())
        try store.saveList(parsed.domains, id: id)
        lists[id] = parsed.domains
        settings.sources.append(source)
        await rebuildIndex()
        policyDidChange()
    }

    func removeSource(_ id: String) {
        guard let source = source(id), !source.builtIn else { return }
        settings.sources.removeAll { $0.id == id }
        lists[id] = nil
        store.removeList(id)
        Task {
            await rebuildIndex()
            policyDidChange()
        }
    }

    func renameSource(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.name = trimmed }
        persist()
    }

    func setWeeklyUpdates(_ on: Bool) {
        settings.weeklyUpdates = on
        persist()
        scheduleWeeklyUpdates()
    }

    private func update(_ id: String, _ change: (inout SourceDefinition) -> Void) {
        guard let i = settings.sources.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.sources[i])
    }

    /// Checks local timestamps every few hours; downloads only enabled remote
    /// lists older than a week. No polling of servers.
    private func scheduleWeeklyUpdates() {
        weeklyTask?.cancel()
        guard settings.weeklyUpdates else { return }
        weeklyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while !Task.isCancelled {
                guard let self else { return }
                let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
                for source in self.settings.sources where source.enabled && source.isRemote {
                    if let updated = source.lastUpdated, updated > weekAgo { continue }
                    await self.refresh(source.id)
                }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    // MARK: Applying

    private func persist() {
        do {
            try store.save(settings)
            try store.save(rules)
        } catch {
            applyState = .failed("Couldn’t save settings: \(error.localizedDescription)")
        }
    }

    private func policyDidChange(domains: [String] = [], overwrite: Bool = false) {
        desiredGeneration += 1
        for d in domains { pendingDomains[d] = desiredGeneration }
        persist()
        recount()
        requestApply(overwrite: overwrite)
    }

    /// Schedules a write. Rapid changes are coalesced: at most one write is in
    /// flight, and it always carries the latest policy.
    func requestApply(overwrite: Bool = false) {
        applyRequested = true
        if overwrite { overwriteRequested = true }
        if helper.isReady && !isLoadingLists { applyState = .applying }
        guard !isApplying else { return }
        isApplying = true
        Task { await runApplyLoop() }
    }

    private func runApplyLoop() async {
        defer { isApplying = false }
        try? await Task.sleep(for: .milliseconds(100))
        while applyRequested {
            applyRequested = false
            if isLoadingLists { return } // re-requested once lists finish loading
            guard helper.isReady else {
                applyState = .needsHelper
                return
            }
            let generation = desiredGeneration
            let overwrite = overwriteRequested
            overwriteRequested = false
            let snapshot = policy
            let protectionOn = settings.protectionEnabled
            let client = self.client
            applyState = .applying
            do {
                let report = try await Task.detached(priority: .userInitiated) { () async throws -> HostsApplyReport in
                    if protectionOn {
                        return try await client.applyBlocklist(HostsPlanner.plan(snapshot).domains, overwriteExternalEdits: overwrite)
                    }
                    return try await client.removeManagedSection(overwriteExternalEdits: overwrite)
                }.value
                lastReport = report
                appliedGeneration = generation
                pendingDomains = pendingDomains.filter { $0.value > generation }
                applyState = .applied(Date())
                if !applyRequested { await verifyHostsFile(adoptIfInSync: false) }
            } catch HelperCallError.hosts(.externallyModified) {
                applyState = .externallyEdited
                return
            } catch {
                applyState = .failed(error.localizedDescription)
                return
            }
        }
    }

    /// Reads /etc/hosts (no privileges needed) and checks that the managed
    /// block matches the current policy exactly, by checksum.
    func verifyHostsFile(adoptIfInSync: Bool) async {
        let generation = desiredGeneration
        let snapshot = policy
        let protectionOn = settings.protectionEnabled
        let path = hostsPath
        enum Verdict: Sendable { case inSync(Date?), outOfSync, externallyEdited, unreadable(String) }
        let verdict = await Task.detached(priority: .utility) { () -> Verdict in
            guard let data = FileManager.default.contents(atPath: path) else { return .unreadable("The hosts file couldn’t be read.") }
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let modified = attributes?[.modificationDate] as? Date
            let document: HostsDocument
            do { document = try HostsDocument(data) } catch { return .unreadable(error.localizedDescription) }
            if let section = document.section, !section.isIntact { return .externallyEdited }
            var expectedSHA: String?
            if protectionOn {
                let plan = HostsPlanner.plan(snapshot)
                if plan.count > 0, let body = try? ManagedSection.renderBody(fromDomainList: plan.domains).body {
                    expectedSHA = ManagedSection.sha256Hex(body)
                }
            }
            return document.section?.actualSHA256 == expectedSHA ? .inSync(modified) : .outOfSync
        }.value

        // The policy changed while we were reading; a newer apply will follow.
        guard generation == desiredGeneration else { return }
        switch verdict {
        case .inSync(let modified):
            hostsVerified = true
            if adoptIfInSync || !isUpToDate {
                appliedGeneration = desiredGeneration
                pendingDomains.removeAll()
                if case .applied = applyState {} else { applyState = .applied(modified ?? Date()) }
            }
        case .outOfSync:
            hostsVerified = false
            if !isApplying { requestApply() }
        case .externallyEdited:
            hostsVerified = false
            applyState = .externallyEdited
        case .unreadable(let message):
            hostsVerified = false
            applyState = .failed(message)
        }
    }

    // MARK: Search

    private func runSearch() {
        searchTask?.cancel()
        let q = query
        if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outcome = .empty
            selection = nil
            return
        }
        let index = self.index, rules = self.rules
        searchTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                SearchEngine.search(q, index: index, rules: rules)
            }.value
            guard !Task.isCancelled else { return }
            if result.query != outcome.query { selection = nil }
            outcome = result
            if let s = selection, s >= rows.count { selection = rows.isEmpty ? nil : rows.count - 1 }
        }
    }

    enum SearchRow: Identifiable, Equatable {
        case add(String)
        case hit(SearchHit)

        var id: String {
            switch self {
            case .add(let d): "add:" + d
            case .hit(let h): h.domain
            }
        }
    }

    var rows: [SearchRow] {
        var out: [SearchRow] = []
        if let host = outcome.hostnameQuery, !outcome.exactMatchFound { out.append(.add(host)) }
        out.append(contentsOf: outcome.hits.map(SearchRow.hit))
        return out
    }

    func moveSelection(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        if let s = selection {
            selection = max(0, min(count - 1, s + delta))
        } else {
            selection = delta > 0 ? 0 : count - 1
        }
    }

    /// Return/Space on the selected row. With nothing selected, Return selects
    /// the first row rather than acting, so a stray key never changes a rule.
    func activateSelection() {
        let rows = self.rows
        guard let s = selection, rows.indices.contains(s) else {
            if !rows.isEmpty { selection = 0 }
            return
        }
        switch rows[s] {
        case .add(let host): addWebsite(host)
        case .hit(let hit): toggle(hit.domain)
        }
    }

    func checkResolution(_ domain: String) {
        resolverChecks[domain] = .some(nil)
        Task {
            let outcome = await ResolverCheck.check(domain)
            resolverChecks[domain] = .some(outcome)
        }
    }

    /// Used by the self-test to put rules back exactly as they were.
    func restoreRules(_ saved: RuleSet) {
        guard saved != rules else { return }
        rules = saved
        policyDidChange()
    }

    #if DEBUG
    /// Loads cached lists and forces a presentation state, for snapshot rendering.
    func prepareForPreview(applyState: ApplyState) async {
        if isLoadingLists { await loadLists() }
        self.applyState = applyState
        appliedGeneration = desiredGeneration
        hostsVerified = true
    }

    func markPendingForPreview(_ domain: String) {
        pendingDomains[domain] = desiredGeneration + 1
    }
    #endif

    // MARK: Status presentation

    enum Health: Equatable {
        case loading
        case needsSetup
        case applying
        case active
        case off
        case attention(String)
        case externallyEdited
    }

    var health: Health {
        if isLoadingLists { return .loading }
        // Nothing can be written until the helper is approved.
        if !helper.isReady && (settings.protectionEnabled || applyState == .needsHelper) { return .needsSetup }
        switch applyState {
        case .needsHelper: return .needsSetup
        case .externallyEdited: return .externallyEdited
        case .failed(let message): return .attention(message)
        case .applying: return .applying
        case .starting: return helper.isReady ? .applying : .needsSetup
        case .applied:
            if !isUpToDate { return .applying }
            return settings.protectionEnabled ? .active : .off
        }
    }
}
