// Benchmarks for QuietHosts' core engine.
//
//   swift run -c release qh-bench                 # synthetic 100k and 200k datasets
//   swift run -c release qh-bench path/to/hosts   # also benchmark a real list
//
// Writes only to a temporary directory; never touches /etc/hosts.

import Darwin
import Foundation
import QuietHostsCore

// MARK: Synthetic data

/// Deterministic generator so runs are comparable.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let words = """
random site cam live hot free tube video star club girl box media stream web net online porn sex adult xxx chat date love
mega best top new real wild bang shop store deal tech play game world news blog link page host cloud data fast smart
red blue black gold silver pink dark night city park lake river sun moon sky fire ice rock wave pixel byte code dev app
""".split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
let tlds = ["com", "com", "com", "com", "net", "org", "xyz", "info", "io", "co", "ru", "de", "co.uk", "tv", "me", "live", "site", "online"]
let subdomains = ["www", "m", "cdn", "img", "static", "api", "media", "go", "track", "ads", "en", "de"]

func syntheticDomains(_ n: Int, seed: UInt64) -> [String] {
    var rng = SplitMix(state: seed)
    var out = Set<String>()
    out.reserveCapacity(n)
    let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    while out.count < n {
        var name: String
        switch Int.random(in: 0..<10, using: &rng) {
        case 0..<5: name = words.randomElement(using: &rng)! + words.randomElement(using: &rng)!
        case 5..<7: name = words.randomElement(using: &rng)! + "-" + words.randomElement(using: &rng)! + String(Int.random(in: 1..<999, using: &rng))
        default: name = String((0..<Int.random(in: 5...14, using: &rng)).map { _ in letters.randomElement(using: &rng)! })
        }
        var host = name + "." + tlds.randomElement(using: &rng)!
        if Int.random(in: 0..<10, using: &rng) < 3 { host = subdomains.randomElement(using: &rng)! + "." + host }
        out.insert(host)
    }
    return Array(out)
}

func hostsText(_ domains: [String]) -> Data {
    var s = "# Synthetic list\n127.0.0.1 localhost\n::1 localhost\n0.0.0.0 0.0.0.0\n"
    s.reserveCapacity(domains.count * 30)
    for d in domains { s += "0.0.0.0 \(d)\n" }
    return Data(s.utf8)
}

// MARK: Timing helpers

let clock = ContinuousClock()
func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

@discardableResult
func time<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = clock.now
    let r = try body()
    return (r, ms(clock.now - start))
}

func stats(_ samples: [Double]) -> (median: Double, p95: Double, max: Double) {
    let s = samples.sorted()
    return (s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.95))], s.last!)
}

func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

func row(_ label: String, _ value: String) {
    print("  " + label.padding(toLength: 46, withPad: " ", startingAt: 0) + value)
}

func f(_ x: Double) -> String { String(format: "%.2f ms", x) }

// MARK: Benchmark

func benchmark(name: String, primary: Data, secondary: Data, tertiary: Data, probe: String) throws {
    print("\n== \(name) ==")
    let rssBefore = residentMB()

    let (p1, tParse) = time { BlocklistParser.parse(primary) }
    let p2 = BlocklistParser.parse(secondary)
    let p3 = BlocklistParser.parse(tertiary)
    row("Parse primary list (\(p1.domains.count.formatted()) domains)", f(tParse) + "  (\(ByteCountFormatter.string(fromByteCount: Int64(primary.count), countStyle: .file)))")

    let (index, tMerge) = time { DomainIndex(sources: [(0, p1.domains), (1, p2.domains), (2, p3.domains)]) }
    row("Merge + de-duplicate 3 sources → \(index.count.formatted())", f(tMerge))

    let cacheData = p1.domains.fileData
    let (_, tCache) = time { BlocklistParser.parse(cacheData) }
    row("Reload primary from cache file", f(tCache))

    // Search latency.
    let queries = ["a", "ra", "ran", "rand", "random", "cam", "xyz", "co.uk", "www.", "q7z", probe, "notpresentanywhere"]
    print("  Search (limit 300), 30 runs each:")
    for q in queries {
        var samples: [Double] = []
        var total = 0
        for _ in 0..<30 {
            let (m, t) = time { index.search(q, limit: 300) }
            samples.append(t)
            total = m.total
        }
        let s = stats(samples)
        row("    \"\(q)\" (\(total.formatted()) matches)", String(format: "median %.2f ms  p95 %.2f ms", s.median, s.p95))
    }

    // Typing simulation: each keystroke triggers a fresh search.
    let typed = Array(probe)
    var perKey: [Double] = []
    for _ in 0..<20 {
        for i in 1...typed.count {
            let (_, t) = time { index.search(String(typed[0..<i]), limit: 300) }
            perKey.append(t)
        }
    }
    let k = stats(perKey)
    row("Search-as-you-type \"\(probe)\" (per keystroke)", String(format: "median %.2f ms  p95 %.2f ms  max %.2f ms", k.median, k.p95, k.max))

    // Policy: one exception, then regenerate the plan.
    var snapshot = PolicySnapshot(index: index, enabledSources: 0b001, rules: RuleSet())
    let (plan0, tPlan) = time { HostsPlanner.plan(snapshot) }
    row("Plan hosts entries (\(plan0.count.formatted()) blocked)", f(tPlan))
    let (_, tAllow) = time { snapshot.allow(probe) }
    let (plan1, tPlan1) = time { HostsPlanner.plan(snapshot) }
    row("Allow one domain (rule change)", f(tAllow))
    row("Re-plan after exception (\(plan1.count.formatted()))", f(tPlan1))

    var all = snapshot
    all.enabledSources = 0b111
    let planAll = HostsPlanner.plan(all)
    let (rendered, tRender) = try time { try ManagedSection.renderBody(fromDomainList: planAll.domains) }
    let (block, tBlock) = time { ManagedSection.render(body: rendered.body, count: rendered.count) }
    row("Validate + render \(rendered.count.formatted()) entries (helper side)", f(tRender))
    row("Checksum + assemble managed block", f(tBlock) + "  (\(ByteCountFormatter.string(fromByteCount: Int64(block.count), countStyle: .file)))")

    // Write to a temporary hosts file.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qh-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let hostsPath = dir.appendingPathComponent("hosts").path
    try Data("127.0.0.1 localhost\n::1 localhost\n".utf8).write(to: URL(fileURLWithPath: hostsPath))
    let writer = HostsFileWriter(configuration: .init(hostsPath: hostsPath, backupDirectory: dir.appendingPathComponent("b").path,
                                                      enforceSystemOwnership: false), flusher: NoopDNSFlusher())
    let (r1, tWrite1) = try time { try writer.apply(block: block, entryCount: rendered.count, overwriteExternalEdits: false) }
    row("First write incl. original backup + verify", f(tWrite1) + "  (\(ByteCountFormatter.string(fromByteCount: Int64(r1.fileBytes), countStyle: .file)))")
    var single = all
    single.allow(probe)
    let p = HostsPlanner.plan(single)
    let rb = try ManagedSection.renderBody(fromDomainList: p.domains)
    let b2 = ManagedSection.render(body: rb.body, count: rb.count)
    let (_, tWrite2) = try time { try writer.apply(block: b2, entryCount: rb.count, overwriteExternalEdits: false) }
    row("Rewrite after one exception (+ verify)", f(tWrite2))

    // End-to-end for one toggle, excluding XPC and the DNS flush.
    let (_, tE2E) = try time { () throws -> Void in
        var s = single
        s.block(probe)
        let p = HostsPlanner.plan(s)
        let rb = try ManagedSection.renderBody(fromDomainList: p.domains)
        _ = try writer.apply(block: ManagedSection.render(body: rb.body, count: rb.count), entryCount: rb.count, overwriteExternalEdits: false)
    }
    row("One toggle end-to-end (plan → render → write)", f(tE2E))

    let indexBytes = index.list.bytes.count + index.list.starts.count * 4 + index.masks.count * 8
    row("Index memory (bytes + offsets + masks)", ByteCountFormatter.string(fromByteCount: Int64(indexBytes), countStyle: .memory))
    row("Process RSS growth during this run", String(format: "%.1f MB (now %.1f MB)", residentMB() - rssBefore, residentMB()))
}

print("QuietHosts core benchmark — \(ProcessInfo.processInfo.processorCount) cores, \(ProcessInfo.processInfo.operatingSystemVersionString)")

for (n, label) in [(100_000, "100,000 domains"), (200_000, "200,000 domains")] {
    let primary = syntheticDomains(n, seed: 1)
    // Secondary/tertiary lists overlap the primary by ~30% to exercise de-duplication.
    let secondary = Array(primary.prefix(n * 3 / 10)) + syntheticDomains(n / 5, seed: 2)
    let tertiary = syntheticDomains(n / 20, seed: 3)
    let probe = primary.first { $0.hasPrefix("random") && !$0.hasPrefix("www.") } ?? primary[0]
    try benchmark(name: label, primary: hostsText(primary), secondary: hostsText(secondary), tertiary: hostsText(tertiary), probe: probe)
}

for path in CommandLine.arguments.dropFirst() {
    guard let data = FileManager.default.contents(atPath: path) else { print("Can’t read \(path)"); continue }
    let parsed = BlocklistParser.parse(data)
    let s = parsed.stats
    print("\n== Real list: \((path as NSString).lastPathComponent) ==")
    row("Lines / accepted / unique", "\(s.lines.formatted()) / \(s.accepted.formatted()) / \(s.unique.formatted())")
    row("Invalid / unsupported / local / redirects", "\(s.invalid) / \(s.unsupported) / \(s.local) / \(s.nonBlocking)")
    let probe = parsed.domains.domain(at: parsed.domains.count / 2)
    try benchmark(name: "Real list (\(parsed.domains.count.formatted()))", primary: data, secondary: Data(), tertiary: Data(), probe: probe)
}
