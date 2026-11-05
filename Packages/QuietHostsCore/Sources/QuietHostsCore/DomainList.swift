import Foundation

/// A sorted, de-duplicated list of hostnames stored contiguously.
///
/// Every hostname is followed by a `\n` byte, so `bytes` is also the exact
/// on-disk cache format and can be scanned with `memmem` for substring search
/// without allocating a `String` per domain. Ordering is plain byte order,
/// which for lower-case ASCII matches `String` ordering.
public struct DomainList: Sendable, Equatable {
    /// Concatenated `domain\n` records.
    public let bytes: [UInt8]
    /// Start offset of each record plus a trailing sentinel equal to `bytes.count`.
    public let starts: [Int32]

    public static let empty = DomainList(uncheckedBytes: [], starts: [0])

    init(uncheckedBytes bytes: [UInt8], starts: [Int32]) {
        self.bytes = bytes
        self.starts = starts
    }

    public var count: Int { starts.count - 1 }
    public var isEmpty: Bool { count == 0 }

    @inline(__always)
    public func length(at i: Int) -> Int { Int(starts[i + 1] - starts[i]) - 1 }

    public func domain(at i: Int) -> String {
        let s = Int(starts[i]), e = Int(starts[i + 1]) - 1
        return bytes.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[s..<e]), as: UTF8.self) }
    }

    public var allDomains: [String] { (0..<count).map(domain(at:)) }

    /// Binary search for an exact hostname.
    public func index(of domain: String) -> Int? {
        var key = Array(domain.utf8)
        key.append(0x0A)
        return key.withUnsafeBufferPointer { index(ofTerminatedKey: $0) }
    }

    public func contains(_ domain: String) -> Bool { index(of: domain) != nil }

    /// `key` must include the trailing `\n`.
    func index(ofTerminatedKey key: UnsafeBufferPointer<UInt8>) -> Int? {
        bytes.withUnsafeBufferPointer { hb -> Int? in
            guard let base = hb.baseAddress else { return nil }
            var lo = 0, hi = count - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let s = Int(starts[mid])
                let len = Int(starts[mid + 1]) - s // includes terminator
                let c = memcmp(base + s, key.baseAddress!, min(len, key.count))
                if c == 0 && len == key.count { return mid }
                if c < 0 || (c == 0 && len < key.count) { lo = mid + 1 } else { hi = mid - 1 }
            }
            return nil
        }
    }

    /// Writes the list in its cache format (one hostname per line).
    public var fileData: Data { Data(bytes) }

    /// Builds a list from arbitrary hostnames. Invalid entries are dropped.
    public init<S: Sequence>(domains: S) where S.Element == String {
        var builder = DomainListBuilder()
        for d in domains {
            var copy = d.lowercased()
            _ = copy.withUTF8 { builder.appendCandidate($0) }
        }
        self = builder.build()
    }
}

/// Accumulates candidate hostnames into an arena and produces a sorted,
/// de-duplicated `DomainList`.
struct DomainListBuilder {
    private(set) var arena: [UInt8] = []
    private var records: [(start: Int32, length: Int32)] = []

    init(capacityBytes: Int = 0) {
        arena.reserveCapacity(capacityBytes)
    }

    var candidateCount: Int { records.count }

    /// Appends an already lower-cased, already validated hostname.
    @inline(__always)
    mutating func appendValidated(_ p: UnsafeBufferPointer<UInt8>) {
        let start = Int32(arena.count)
        arena.append(contentsOf: p)
        records.append((start, Int32(p.count)))
    }

    /// Lower-cases and validates; returns the validation problem if rejected.
    @discardableResult
    mutating func appendCandidate(_ p: UnsafeBufferPointer<UInt8>) -> Hostname.Problem? {
        let start = arena.count
        arena.reserveCapacity(start + p.count)
        for c in p { arena.append((c >= 0x41 && c <= 0x5A) ? c | 0x20 : c) }
        var end = arena.count
        while end > start && arena[end - 1] == 0x2E { end -= 1 } // trailing dots
        let problem: Hostname.Problem? = arena.withUnsafeBufferPointer {
            Hostname.validateLowercased(UnsafeBufferPointer(rebasing: $0[start..<end]))
        }
        if problem != nil {
            arena.removeSubrange(start...)
            return problem
        }
        arena.removeSubrange(end...)
        records.append((Int32(start), Int32(end - start)))
        return nil
    }

    /// Discards the most recently appended record (used by callers that do
    /// extra filtering after validation).
    mutating func removeLast() {
        guard let last = records.popLast() else { return }
        arena.removeSubrange(Int(last.start)...)
    }

    func lastRecordEquals(_ s: StaticString) -> Bool {
        guard let last = records.last, Int(last.length) == s.utf8CodeUnitCount else { return false }
        return arena.withUnsafeBufferPointer { a in
            memcmp(a.baseAddress! + Int(last.start), s.utf8Start, Int(last.length)) == 0
        }
    }

    func build() -> DomainList {
        if records.isEmpty { return .empty }
        let arenaCopy = arena
        var order = records
        arenaCopy.withUnsafeBufferPointer { a in
            let base = a.baseAddress!
            @inline(__always) func less(_ x: (start: Int32, length: Int32), _ y: (start: Int32, length: Int32)) -> Bool {
                let c = memcmp(base + Int(x.start), base + Int(y.start), Int(min(x.length, y.length)))
                return c < 0 || (c == 0 && x.length < y.length)
            }
            var sorted = true
            for i in 1..<order.count where !less(order[i - 1], order[i]) {
                sorted = false
                break
            }
            if !sorted { order.sort(by: less) }
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(arena.count + order.count)
        var starts: [Int32] = []
        starts.reserveCapacity(order.count + 1)
        arenaCopy.withUnsafeBufferPointer { a in
            let base = a.baseAddress!
            var previous: (start: Int32, length: Int32)?
            for r in order {
                if let p = previous, p.length == r.length,
                   memcmp(base + Int(p.start), base + Int(r.start), Int(r.length)) == 0 {
                    continue
                }
                starts.append(Int32(bytes.count))
                bytes.append(contentsOf: UnsafeBufferPointer(rebasing: a[Int(r.start)..<Int(r.start + r.length)]))
                bytes.append(0x0A)
                previous = r
            }
        }
        starts.append(Int32(bytes.count))
        return DomainList(uncheckedBytes: bytes, starts: starts)
    }
}
