import Darwin
import Foundation
import Testing
@testable import QuietHostsCore

/// A throwaway directory containing a fake hosts file and backup folder.
final class HostsFixture {
    let dir: URL
    let hostsPath: String
    let backupDir: String
    let flusher = RecordingFlusher()

    static let systemDefault = """
    ##
    # Host Database
    #
    # localhost is used to configure the loopback interface
    # when the system is booting.  Do not change this entry.
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1             localhost
    192.168.1.10 nas.home   # my NAS

    """

    init(contents: String = HostsFixture.systemDefault, mode: mode_t = 0o644) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("qh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        hostsPath = dir.appendingPathComponent("hosts").path
        backupDir = dir.appendingPathComponent("Backups").path
        try Data(contents.utf8).write(to: URL(fileURLWithPath: hostsPath))
        chmod(hostsPath, mode)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var writer: HostsFileWriter {
        HostsFileWriter(configuration: .init(hostsPath: hostsPath, backupDirectory: backupDir, enforceSystemOwnership: false),
                        flusher: flusher)
    }

    var contents: String { (try? String(contentsOfFile: hostsPath, encoding: .utf8)) ?? "" }
    var bytes: Data { FileManager.default.contents(atPath: hostsPath) ?? Data() }

    func block(_ domains: [String]) throws -> Data {
        let list = DomainList(domains: domains)
        let r = try ManagedSection.renderBody(fromDomainList: list.fileData)
        return ManagedSection.render(body: r.body, count: r.count)
    }

    @discardableResult
    func apply(_ domains: [String], overwrite: Bool = false) throws -> HostsApplyReport {
        try writer.apply(block: domains.isEmpty ? nil : try block(domains), entryCount: domains.count, overwriteExternalEdits: overwrite)
    }
}

final class RecordingFlusher: DNSCacheFlushing, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func flush() -> String? {
        lock.withLock { _count += 1 }
        return nil
    }
}

@Suite("Managed hosts section")
struct HostsFileTests {
    @Test("Adds a managed block while preserving every existing byte")
    func preservesUnrelatedContent() throws {
        let f = try HostsFixture()
        let original = f.bytes
        let report = try f.apply(["b.example.com", "a.example.com"])
        #expect(report.changed)
        #expect(report.entryCount == 2)
        #expect(f.flusher.count == 1)
        let now = f.bytes
        #expect(now.starts(with: original), "existing content must be untouched")
        let text = f.contents
        #expect(text.contains("0.0.0.0 a.example.com\n:: a.example.com\n0.0.0.0 b.example.com\n:: b.example.com\n"))
        #expect(text.contains("192.168.1.10 nas.home   # my NAS"))
        let doc = try HostsDocument(now)
        #expect(doc.section?.isIntact == true)
        #expect(doc.section?.declaredCount == 2)
        #expect(doc.unmanagedContent == original)
    }

    @Test("Rebuilds the block deterministically and only rewrites when needed")
    func rebuild() throws {
        let f = try HostsFixture()
        try f.apply(["a.example.com", "b.example.com"])
        let first = f.bytes
        try f.apply(["b.example.com", "a.example.com"])
        #expect(f.bytes == first)
        let unchanged = try f.apply(["a.example.com", "b.example.com"])
        #expect(!unchanged.changed)
        #expect(f.flusher.count == 1, "no write and no flush when nothing changed")
        try f.apply(["c.example.com"])
        #expect(!f.contents.contains("a.example.com"))
        #expect(f.contents.contains("0.0.0.0 c.example.com"))
        #expect(f.contents.components(separatedBy: ManagedSection.beginPrefix).count == 2)
    }

    @Test("Content added after the block by someone else is kept")
    func preservesTrailingEdits() throws {
        let f = try HostsFixture()
        try f.apply(["a.example.com"])
        let edited = f.contents + "10.0.0.5 printer.office\n"
        try Data(edited.utf8).write(to: URL(fileURLWithPath: f.hostsPath))
        try f.apply(["z.example.com"])
        #expect(f.contents.hasSuffix("10.0.0.5 printer.office\n"))
        try f.apply([])
        #expect(f.contents == HostsFixture.systemDefault + "10.0.0.5 printer.office\n")
    }

    @Test("Removing protection restores the original file exactly")
    func removeRestores() throws {
        let f = try HostsFixture()
        let original = f.bytes
        try f.apply(["a.example.com"])
        let report = try f.apply([])
        #expect(report.changed)
        #expect(report.sectionSHA256 == nil)
        #expect(f.bytes == original)
    }

    @Test("Repeated enable/disable cycles are stable")
    func cycles() throws {
        let f = try HostsFixture()
        let original = f.bytes
        var enabledVersion: Data?
        for i in 0..<25 {
            try f.apply(["a.example.com", "b.example.com"])
            if let v = enabledVersion { #expect(f.bytes == v, "cycle \(i)") } else { enabledVersion = f.bytes }
            try f.apply([])
            #expect(f.bytes == original, "cycle \(i)")
        }
    }

    @Test("A file without a trailing newline gains one, then stays stable")
    func noTrailingNewline() throws {
        let f = try HostsFixture(contents: "127.0.0.1 localhost")
        try f.apply(["a.example.com"])
        #expect(f.contents.hasPrefix("127.0.0.1 localhost\n# >>> QuietHosts BEGIN"))
        try f.apply([])
        #expect(f.contents == "127.0.0.1 localhost\n")
    }

    @Test("Non-UTF-8 bytes outside the block survive")
    func binarySafe() throws {
        let f = try HostsFixture()
        var weird = Data("# caf".utf8); weird.append(0xE9); weird.append(contentsOf: Array(" latin-1 comment\n".utf8))
        try weird.write(to: URL(fileURLWithPath: f.hostsPath))
        try f.apply(["a.example.com"])
        try f.apply([])
        #expect(f.bytes == weird)
    }

    @Test("Preserves file permissions")
    func permissions() throws {
        let f = try HostsFixture(mode: 0o640)
        try f.apply(["a.example.com"])
        var st = stat()
        lstat(f.hostsPath, &st)
        #expect(st.st_mode & 0o7777 == 0o640)
        #expect(st.st_uid == getuid())
    }

    @Test("Refuses to follow a symlinked hosts file")
    func symlinkRefused() throws {
        let f = try HostsFixture()
        let target = f.dir.appendingPathComponent("real-hosts").path
        try FileManager.default.moveItem(atPath: f.hostsPath, toPath: target)
        try FileManager.default.createSymbolicLink(atPath: f.hostsPath, withDestinationPath: target)
        #expect(throws: HostsFileError.symlink) { try f.apply(["a.example.com"]) }
        #expect(try String(contentsOfFile: target, encoding: .utf8) == HostsFixture.systemDefault)
    }

    @Test("Refuses non-regular files and missing files")
    func notRegular() throws {
        let f = try HostsFixture()
        try FileManager.default.removeItem(atPath: f.hostsPath)
        #expect(throws: HostsFileError.missing) { try f.apply(["a.example.com"]) }
        try FileManager.default.createDirectory(atPath: f.hostsPath, withIntermediateDirectories: false)
        #expect(throws: HostsFileError.notRegularFile) { try f.apply(["a.example.com"]) }
    }

    @Test("Refuses unbalanced or duplicated markers without changing the file")
    func malformed() throws {
        let cases = [
            HostsFixture.systemDefault + "# >>> QuietHosts BEGIN (entries=1 sha256=x)\n0.0.0.0 a.example.com\n",
            HostsFixture.systemDefault + "0.0.0.0 a.example.com\n# <<< QuietHosts END\n",
            HostsFixture.systemDefault + "# <<< QuietHosts END\n# >>> QuietHosts BEGIN\n",
            HostsFixture.systemDefault + "# >>> QuietHosts BEGIN\n# <<< QuietHosts END\n# >>> QuietHosts BEGIN\n# <<< QuietHosts END\n",
            HostsFixture.systemDefault + "# >>> quiet QuietHosts damaged marker\n",
        ]
        for text in cases {
            let f = try HostsFixture(contents: text)
            #expect(throws: HostsFileError.self) { try f.apply(["a.example.com"]) }
            #expect(f.contents == text)
            #expect(f.flusher.count == 0)
        }
    }

    @Test("Detects edits inside the managed block and only overwrites when asked")
    func externalEdits() throws {
        let f = try HostsFixture()
        try f.apply(["a.example.com"])
        let tampered = f.contents.replacingOccurrences(of: "0.0.0.0 a.example.com", with: "0.0.0.0 a.example.com\n1.2.3.4 bank.example.com")
        try Data(tampered.utf8).write(to: URL(fileURLWithPath: f.hostsPath))
        #expect(throws: HostsFileError.externallyModified) { try f.apply(["b.example.com"]) }
        #expect(f.contents == tampered)
        try f.apply(["b.example.com"], overwrite: true)
        #expect(!f.contents.contains("bank.example.com"))
        #expect(try HostsDocument(f.bytes).section?.isIntact == true)
    }

    @Test("Backs up the original once and each distinct version of unrelated content")
    func backups() throws {
        let f = try HostsFixture()
        let original = f.bytes
        try f.apply(["a.example.com"])
        let originalBackup = (f.backupDir as NSString).appendingPathComponent(HostsFileWriter.originalBackupName)
        #expect(FileManager.default.contents(atPath: originalBackup) == original)
        #expect(f.writer.backupFiles().count == 1)

        // Toggling rules does not churn backups when unrelated content is unchanged.
        try f.apply(["b.example.com"])
        try f.apply(["c.example.com"])
        #expect(f.writer.backupFiles().count == 1)

        // A change to unrelated content produces a new backup before the next write.
        try Data((f.contents + "10.1.1.1 extra.lan\n").utf8).write(to: URL(fileURLWithPath: f.hostsPath))
        try f.apply(["d.example.com"])
        #expect(f.writer.backupFiles().count == 2)
        #expect(FileManager.default.contents(atPath: originalBackup) == original, "the original is never overwritten")

        // Restoring a backup and removing the block yields the original.
        let restoredDoc = try HostsDocument(FileManager.default.contents(atPath: originalBackup)!)
        #expect(restoredDoc.section == nil)
    }

    @Test("Prunes old backups")
    func prune() throws {
        let f = try HostsFixture()
        let w = HostsFileWriter(configuration: .init(hostsPath: f.hostsPath, backupDirectory: f.backupDir,
                                                     enforceSystemOwnership: false, backupsToKeep: 3), flusher: f.flusher)
        for i in 0..<6 {
            try Data((f.contents + "10.0.0.\(i) host\(i).lan\n").utf8).write(to: URL(fileURLWithPath: f.hostsPath))
            _ = try w.apply(block: try f.block(["x\(i).example.com"]), entryCount: 1, overwriteExternalEdits: false)
            usleep(2000)
        }
        #expect(w.backupFiles().count == 3)
    }

    @Test("System mode refuses files not owned by root")
    func ownership() throws {
        let f = try HostsFixture()
        let strict = HostsFileWriter(configuration: .init(hostsPath: f.hostsPath, backupDirectory: f.backupDir, enforceSystemOwnership: true),
                                     flusher: f.flusher)
        #expect(throws: HostsFileError.self) { _ = try strict.apply(block: try f.block(["a.example.com"]), entryCount: 1, overwriteExternalEdits: false) }
        #expect(f.contents == HostsFixture.systemDefault)
    }

    @Test("Leaves no temporary files behind")
    func noTempFiles() throws {
        let f = try HostsFixture()
        try f.apply(["a.example.com"])
        try f.apply([])
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.dir.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)
    }

    @Test("The helper renderer rejects anything that isn't a sorted list of valid hostnames")
    func rendererValidation() {
        let bad: [String] = [
            "a.example.com\nlocalhost\n",
            "a.example.com\n1.2.3.4 bank.com\n",
            "b.example.com\na.example.com\n",
            "a.example.com\na.example.com\n",
            "A.EXAMPLE.COM\n",
            "a.example.com\n\nb.example.com\n",
            "printer.local\n",
            "evil.com#comment\n",
        ]
        for text in bad {
            #expect(throws: HostsFileError.self, "\(text.debugDescription)") { _ = try ManagedSection.renderBody(fromDomainList: Data(text.utf8)) }
        }
        let ok = try? ManagedSection.renderBody(fromDomainList: Data("a.example.com\nb.example.com\n".utf8))
        #expect(ok?.count == 2)
    }
}

@Suite("List import and update")
struct ImportTests {
    struct FakeFetcher: ListFetching {
        let result: Result<Data, ImportError>
        func fetch(_ url: URL) async throws -> Data { try result.get() }
    }

    func tempStore() throws -> QuietHostsStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qh-store-\(UUID().uuidString)")
        let store = QuietHostsStore(root: root)
        try store.prepare()
        return store
    }

    @Test("Rejects empty, HTML and truncated updates, keeping the previous list")
    func failedUpdatesKeepCache() async throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let good = DomainList(domains: (0..<5000).map { "site\($0).example.com" })
        try store.saveList(good, id: "adult")

        let failures: [(Data, ImportError)] = [
            (Data("<!doctype html><title>Rate limited</title>".utf8), .looksLikeHTML),
            (Data("# nothing here\n\n".utf8), .noDomains(invalidLines: 0)),
            (Data((0..<100).map { "0.0.0.0 x\($0).example.com" }.joined(separator: "\n").utf8), .shrank(from: 5000, to: 100)),
        ]
        for (data, expected) in failures {
            let fetcher = FakeFetcher(result: .success(data))
            await #expect(throws: expected) {
                let fetched = try await fetcher.fetch(URL(string: "https://example.com/list")!)
                _ = try ListImporter.validate(fetched, previousCount: good.count)
            }
            #expect(try store.loadList("adult") == good)
        }
        await #expect(throws: ImportError.httpStatus(503)) {
            _ = try await FakeFetcher(result: .failure(.httpStatus(503))).fetch(URL(string: "https://example.com")!)
        }
        #expect(try store.loadList("adult") == good)
    }

    @Test("Rejects non-HTTPS URLs before any request")
    func httpsOnly() async {
        await #expect(throws: ImportError.insecureURL) {
            _ = try await URLSessionListFetcher().fetch(URL(string: "http://example.com/hosts")!)
        }
    }

    @Test("Successful updates replace the cache and round-trip exactly")
    func roundTrip() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let result = try ListImporter.validate(Data("0.0.0.0 b.example.com\n0.0.0.0 a.example.com\n".utf8), previousCount: nil)
        try store.saveList(result.domains, id: "custom-1")
        #expect(try store.loadList("custom-1").allDomains == ["a.example.com", "b.example.com"])
    }

    @Test("Settings and rules persist, and damaged rules are set aside, not deleted")
    func persistence() throws {
        let store = try tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        var settings = AppSettings()
        settings.sources[1].enabled = true
        try store.save(settings)
        #expect(store.loadSettings() == settings)

        var rules = RuleSet()
        rules.addWebsite("x.com", now: Date(timeIntervalSince1970: 1_700_000_000))
        rules.allowed["ok.example.com"] = .init(added: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(rules)
        #expect(store.loadRules().rules == rules)

        try Data("{ not json".utf8).write(to: store.rulesURL)
        let loaded = store.loadRules()
        #expect(loaded.recovered)
        #expect(loaded.rules == RuleSet())
        let files = try FileManager.default.contentsOfDirectory(atPath: store.root.path)
        #expect(files.contains { $0.hasPrefix("rules.json.damaged-") })
    }

    @Test("Built-in sources: adult list on by default, alternatives off")
    func defaults() {
        let s = AppSettings()
        #expect(s.sources.map(\.id) == [BuiltInSources.adultID, BuiltInSources.socialID, BuiltInSources.hageziID])
        #expect(s.sources.map(\.enabled) == [true, false, false])
        #expect(s.enabledMask == 0b1)
        #expect(Set(s.sources.map(\.bit)).count == 3)
        #expect(s.nextFreeBit() == 3)
    }
}
