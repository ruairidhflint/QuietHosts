import Darwin
import Foundation

/// Result of a hosts-file update, returned to the app.
public struct HostsApplyReport: Codable, Sendable, Equatable {
    /// False when the file already had the requested content.
    public var changed: Bool
    public var entryCount: Int
    /// SHA-256 of the managed body, or nil when no managed block is present.
    public var sectionSHA256: String?
    public var fileBytes: Int
    public var backupFile: String?
    public var writeMilliseconds: Double
    public var flushMilliseconds: Double
    /// Set when the file was written but refreshing DNS caches failed.
    public var dnsWarning: String?
}

public protocol DNSCacheFlushing: Sendable {
    /// Flushes resolver caches. Returns a warning if anything failed.
    func flush() -> String?
}

public struct NoopDNSFlusher: DNSCacheFlushing {
    public init() {}
    public func flush() -> String? { nil }
}

/// Clears the macOS resolver caches using the two fixed system commands Apple
/// documents for this. Arguments are constant; nothing from a client is used.
public struct SystemDNSFlusher: DNSCacheFlushing {
    public init() {}

    public func flush() -> String? {
        var problems: [String] = []
        if let p = Self.run("/usr/bin/dscacheutil", ["-flushcache"]) { problems.append(p) }
        if let p = Self.run("/usr/bin/killall", ["-HUP", "mDNSResponder"]) { problems.append(p) }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    static func run(_ path: String, _ arguments: [String]) -> String? {
        let name = (path as NSString).lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return "\(name) couldn’t start" }
        if done.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            return "\(name) timed out"
        }
        return process.terminationStatus == 0 ? nil : "\(name) exited with status \(process.terminationStatus)"
    }
}

/// Reads and atomically rewrites the hosts file, touching only the managed block.
///
/// Safety properties:
/// - refuses symlinks, non-regular files, oversized files and (in system mode)
///   files or directories not owned by root;
/// - refuses unbalanced or duplicated markers and, unless explicitly told to
///   overwrite, a managed block whose contents no longer match its checksum;
/// - backs up the original file once, and every distinct version of the
///   unrelated content before changing it;
/// - writes a complete new file next to the original with the same owner and
///   mode, fsyncs it and `rename(2)`s it into place, so the hosts file is
///   always either entirely old or entirely new;
/// - aborts if the file changes between reading and replacing it;
/// - re-reads the result to verify it.
public struct HostsFileWriter: Sendable {
    public struct Configuration: Sendable {
        public var hostsPath: String
        public var backupDirectory: String
        /// Require root ownership of the hosts file, its directory and the
        /// backup directory. Disabled only for tests using temporary files.
        public var enforceSystemOwnership: Bool
        public var maxFileBytes: Int
        public var backupsToKeep: Int

        public init(hostsPath: String, backupDirectory: String, enforceSystemOwnership: Bool,
                    maxFileBytes: Int = 128 * 1024 * 1024, backupsToKeep: Int = 10) {
            self.hostsPath = hostsPath
            self.backupDirectory = backupDirectory
            self.enforceSystemOwnership = enforceSystemOwnership
            self.maxFileBytes = maxFileBytes
            self.backupsToKeep = backupsToKeep
        }

        public static let system = Configuration(
            hostsPath: "/private/etc/hosts",
            backupDirectory: "/Library/Application Support/QuietHosts/Backups",
            enforceSystemOwnership: true
        )
    }

    public static let originalBackupName = "hosts.original"

    public let configuration: Configuration
    public let flusher: DNSCacheFlushing

    public init(configuration: Configuration, flusher: DNSCacheFlushing) {
        self.configuration = configuration
        self.flusher = flusher
    }

    struct FileIdentity: Equatable {
        var device: dev_t
        var inode: ino_t
        var size: off_t
        var modified: timespec
        var mode: mode_t
        var owner: uid_t
        var group: gid_t

        init(_ st: stat) {
            device = st.st_dev
            inode = st.st_ino
            size = st.st_size
            modified = st.st_mtimespec
            mode = st.st_mode
            owner = st.st_uid
            group = st.st_gid
        }

        static func == (a: FileIdentity, b: FileIdentity) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }
    }

    // MARK: Reading

    /// Reads and parses the hosts file without changing anything.
    public func readDocument() throws(HostsFileError) -> HostsDocument {
        try read().document
    }

    func read() throws(HostsFileError) -> (document: HostsDocument, identity: FileIdentity) {
        let path = configuration.hostsPath
        var st = stat()
        if lstat(path, &st) != 0 {
            if errno == ENOENT { throw .missing }
            throw .unreadable(String(cString: strerror(errno)))
        }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw .symlink }
        if (st.st_mode & S_IFMT) != S_IFREG { throw .notRegularFile }
        if Int(st.st_size) > configuration.maxFileBytes { throw .tooLarge(bytes: Int(st.st_size)) }
        if configuration.enforceSystemOwnership && st.st_uid != 0 {
            throw .unsafeOwnership("owned by user id \(st.st_uid)")
        }

        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { throw .unreadable(String(cString: strerror(errno))) }
        defer { close(fd) }
        var fst = stat()
        guard fstat(fd, &fst) == 0 else { throw .unreadable(String(cString: strerror(errno))) }
        guard fst.st_dev == st.st_dev, fst.st_ino == st.st_ino, (fst.st_mode & S_IFMT) == S_IFREG else {
            throw .changedDuringWrite
        }
        let data = try readAll(fd: fd, expected: Int(fst.st_size))
        return (try HostsDocument(data), FileIdentity(fst))
    }

    private func readAll(fd: Int32, expected: Int) throws(HostsFileError) -> Data {
        var buffer = [UInt8](repeating: 0, count: max(expected, 0) + 1)
        var total = 0
        while true {
            if total == buffer.count {
                if buffer.count > configuration.maxFileBytes { throw .tooLarge(bytes: buffer.count) }
                buffer.append(contentsOf: [UInt8](repeating: 0, count: buffer.count))
            }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + total, $0.count - total) }
            if n < 0 {
                if errno == EINTR { continue }
                throw .unreadable(String(cString: strerror(errno)))
            }
            if n == 0 { break }
            total += n
        }
        return Data(buffer[0..<total])
    }

    // MARK: Writing

    /// Replaces the managed block with `block` (from `ManagedSection.render`),
    /// or removes it when `block` is nil.
    public func apply(block: Data?, entryCount: Int, overwriteExternalEdits: Bool) throws(HostsFileError) -> HostsApplyReport {
        do {
            return try applyOnce(block: block, entryCount: entryCount, overwriteExternalEdits: overwriteExternalEdits)
        } catch .changedDuringWrite {
            // Another process wrote the file between our read and rename. Re-read once.
            return try applyOnce(block: block, entryCount: entryCount, overwriteExternalEdits: overwriteExternalEdits)
        }
    }

    private func applyOnce(block: Data?, entryCount: Int, overwriteExternalEdits: Bool) throws(HostsFileError) -> HostsApplyReport {
        let clock = ContinuousClock()
        let started = clock.now
        try checkDirectory((configuration.hostsPath as NSString).deletingLastPathComponent)

        let (document, identity) = try read()
        if let section = document.section, !section.isIntact, !overwriteExternalEdits {
            throw .externallyModified
        }
        let newData = document.replacingSection(with: block)
        if newData == document.data {
            return HostsApplyReport(changed: false, entryCount: block == nil ? 0 : entryCount,
                                    sectionSHA256: document.section?.actualSHA256,
                                    fileBytes: newData.count, backupFile: nil,
                                    writeMilliseconds: Self.ms(clock.now - started), flushMilliseconds: 0, dnsWarning: nil)
        }

        let backupName = try backUp(document)
        try replaceFile(with: newData, matching: identity)

        // Verify what is now on disk.
        let verified = try read().document
        guard verified.data == newData else { throw .verificationFailed }
        let writeDone = clock.now

        let warning = flusher.flush()
        let finished = clock.now
        return HostsApplyReport(changed: true, entryCount: block == nil ? 0 : entryCount,
                                sectionSHA256: verified.section?.actualSHA256,
                                fileBytes: newData.count, backupFile: backupName,
                                writeMilliseconds: Self.ms(writeDone - started),
                                flushMilliseconds: Self.ms(finished - writeDone), dnsWarning: warning)
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func checkDirectory(_ dir: String) throws(HostsFileError) {
        var st = stat()
        guard lstat(dir, &st) == 0 else { throw .unreadable("can’t inspect \(dir)") }
        if (st.st_mode & S_IFMT) == S_IFLNK { throw .symlink }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw .notRegularFile }
        if configuration.enforceSystemOwnership {
            if st.st_uid != 0 { throw .unsafeOwnership("\(dir) owned by user id \(st.st_uid)") }
            if st.st_mode & (S_IWGRP | S_IWOTH) != 0 { throw .unsafeOwnership("\(dir) is writable by other users") }
        }
    }

    /// Writes `data` to a new file in the same directory and renames it over
    /// the hosts file, preserving owner and permissions.
    private func replaceFile(with data: Data, matching identity: FileIdentity) throws(HostsFileError) {
        let path = configuration.hostsPath
        let dir = (path as NSString).deletingLastPathComponent
        var template = Array("\(dir)/.hosts.quiethosts.XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        if fd < 0 { throw .writeFailed("couldn’t create a temporary file: \(String(cString: strerror(errno)))") }
        let tempPath = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(tempPath) }
        }

        try writeAll(fd: fd, data: data)
        if fchmod(fd, identity.mode & 0o7777) != 0 {
            throw .writeFailed("couldn’t set permissions: \(String(cString: strerror(errno)))")
        }
        if geteuid() == 0 || identity.owner == geteuid() {
            if fchown(fd, identity.owner, identity.group) != 0 && geteuid() == 0 {
                throw .writeFailed("couldn’t set ownership: \(String(cString: strerror(errno)))")
            }
        }
        if fsync(fd) != 0 { throw .writeFailed("fsync failed: \(String(cString: strerror(errno)))") }

        // Optimistic concurrency check: abort if anyone touched the file.
        var now = stat()
        guard lstat(path, &now) == 0, (now.st_mode & S_IFMT) == S_IFREG, FileIdentity(now) == identity else {
            throw .changedDuringWrite
        }
        if rename(tempPath, path) != 0 {
            throw .writeFailed("couldn’t replace the hosts file: \(String(cString: strerror(errno)))")
        }
        renamed = true
        let dfd = open(dir, O_RDONLY | O_CLOEXEC)
        if dfd >= 0 {
            fsync(dfd)
            close(dfd)
        }
    }

    private func writeAll(fd: Int32, data: Data) throws(HostsFileError) {
        var failure: HostsFileError?
        data.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, p, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = .writeFailed(String(cString: strerror(errno)))
                    return
                }
                p += n
                remaining -= n
            }
        }
        if let failure { throw failure }
    }

    // MARK: Backups

    /// Keeps `hosts.original` (the file as it was before QuietHosts first
    /// touched it) and timestamped copies of every distinct version of the
    /// content outside the managed block. Returns the backup file name, if one
    /// was written.
    func backUp(_ document: HostsDocument) throws(HostsFileError) -> String? {
        let dir = configuration.backupDirectory
        do {
            if !FileManager.default.fileExists(atPath: dir) {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o755])
            }
        } catch {
            throw .backupFailed(error.localizedDescription)
        }
        do {
            try checkDirectory(dir)
        } catch {
            throw .backupFailed(error.localizedDescription)
        }

        let original = (dir as NSString).appendingPathComponent(Self.originalBackupName)
        if document.section == nil && !FileManager.default.fileExists(atPath: original) {
            try writeBackup(document.data, to: original)
        }

        let existing = backupFiles()
        if let newest = existing.last,
           let data = FileManager.default.contents(atPath: (dir as NSString).appendingPathComponent(newest)),
           let previous = try? HostsDocument(data),
           previous.unmanagedContent == document.unmanagedContent {
            return nil // The unrelated content is already preserved.
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = "hosts-\(formatter.string(from: Date())).bak"
        try writeBackup(document.data, to: (dir as NSString).appendingPathComponent(name))

        let all = backupFiles()
        if all.count > configuration.backupsToKeep {
            for old in all.prefix(all.count - configuration.backupsToKeep) {
                unlink((dir as NSString).appendingPathComponent(old))
            }
        }
        return name
    }

    /// Timestamped backups, oldest first.
    public func backupFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: configuration.backupDirectory)) ?? []
        return names.filter { $0.hasPrefix("hosts-") && $0.hasSuffix(".bak") }.sorted()
    }

    private func writeBackup(_ data: Data, to path: String) throws(HostsFileError) {
        let dir = (path as NSString).deletingLastPathComponent
        var template = Array("\(dir)/.backup.XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        if fd < 0 { throw .backupFailed(String(cString: strerror(errno))) }
        let tempPath = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var ok = false
        defer {
            close(fd)
            if !ok { unlink(tempPath) }
        }
        do {
            try writeAll(fd: fd, data: data)
        } catch {
            throw .backupFailed(error.localizedDescription)
        }
        fchmod(fd, 0o644)
        guard fsync(fd) == 0, rename(tempPath, path) == 0 else {
            throw .backupFailed(String(cString: strerror(errno)))
        }
        ok = true
    }
}
