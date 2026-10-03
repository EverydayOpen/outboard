import Foundation

/// What the checks on return found. Built by the Mac layer from `ReturnCheck` and the hashes it read; judged by `Held.evaluate`.
public struct ReturnCheckResult: Codable, Hashable, Sendable {
    /// The quick check (listing against the manifest) passed.
    public var quickPassed: Bool
    /// Files hashed: the bounded sample on a clean return, every unchanged file after "Check and reconnect".
    public var hashed: Int
    /// Hashed files whose hash differs from the manifest.
    public var mismatches: Int
    /// This was "Check and reconnect": every unchanged file was hashed.
    public var fullCheck: Bool
    /// Files the manifest has that are no longer there.
    public var missing: Int
    /// Files on the drive now that are not in the manifest or have changed since: they were not compared.
    public var changedSince: Int
    /// How many files the sample was drawn from (unchanged files).
    public var sampleOf: Int

    public init(quickPassed: Bool, hashed: Int, mismatches: Int, fullCheck: Bool, missing: Int = 0, changedSince: Int = 0, sampleOf: Int = 0) {
        self.quickPassed = quickPassed
        self.hashed = hashed
        self.mismatches = mismatches
        self.fullCheck = fullCheck
        self.missing = missing
        self.changedSince = changedSince
        self.sampleOf = sampleOf
    }

    /// Nothing was found wrong.
    public var passed: Bool { quickPassed && mismatches == 0 }
}

/// What the banner "Drive is back" says. `GuardPolicy.snapshot` and `BannerText` carry it by move id.
public struct ReturnReport: Codable, Hashable, Sendable {
    public var sampled: Int
    public var sampleOf: Int
    public var mismatches: Int
    public var fullCheck: Bool
    public var comparedFiles: Int
    public var changedSince: Int
    /// The drive came back under another name and the link was updated.
    public var driveRenamed: Bool

    public init(sampled: Int = 0, sampleOf: Int = 0, mismatches: Int = 0, fullCheck: Bool = false, comparedFiles: Int = 0,
                changedSince: Int = 0, driveRenamed: Bool = false) {
        self.sampled = sampled
        self.sampleOf = sampleOf
        self.mismatches = mismatches
        self.fullCheck = fullCheck
        self.comparedFiles = comparedFiles
        self.changedSince = changedSince
        self.driveRenamed = driveRenamed
    }

    public init(_ check: ReturnCheckResult, driveRenamed: Bool = false) {
        self.init(sampled: check.hashed, sampleOf: check.sampleOf, mismatches: check.mismatches, fullCheck: check.fullCheck,
                  comparedFiles: check.hashed, changedSince: check.changedSince, driveRenamed: driveRenamed)
    }
}

/// "Verify on return" is identity plus a bounded sample, never "the hashes match" claimed for files that apps have written since
/// (BUILD_PLAN §4.4). The manifest is what was copied; the current listing is what the drive holds now.
public enum ReturnCheck {
    /// The listing against the manifest: no file of the manifest is missing, and no file whose modification time is unchanged has a
    /// different size or type. Files added or changed since are not a failure (apps write to this data).
    public static func quick(manifest: [TreeEntry], current: [TreeEntry]) -> Bool {
        missingFiles(manifest: manifest, current: current) == 0 && sizeMismatches(manifest: manifest, current: current) == 0
    }

    /// Files in the manifest that are gone from the listing.
    public static func missingFiles(manifest: [TreeEntry], current: [TreeEntry]) -> Int {
        let now = Set(current.map(\.path))
        return manifest.filter { $0.type != .directory && !now.contains($0.path) }.count
    }

    /// Files whose modification time is unchanged and whose size or type is different: they were not written by an app.
    public static func sizeMismatches(manifest: [TreeEntry], current: [TreeEntry]) -> Int {
        let now = Dictionary(current.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        var n = 0
        for m in manifest {
            guard let c = now[m.path] else { continue }
            if c.type != m.type { n += 1; continue }
            if m.type == .file, c.mtimeSeconds == m.mtimeSeconds, c.size != m.size { n += 1 }
        }
        return n
    }

    /// Files present in both with the same type, size and modification time: the ones worth hashing again, sorted.
    public static func unchanged(manifest: [TreeEntry], current: [TreeEntry]) -> [String] {
        let now = Dictionary(current.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        var out: [String] = []
        for m in manifest where m.type == .file {
            if let c = now[m.path], c.type == .file, c.size == m.size, c.mtimeSeconds == m.mtimeSeconds, m.sha256 != nil { out.append(m.path) }
        }
        return out.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// Regular files on the drive now that were not compared: new, or changed since the copy.
    public static func changedSince(manifest: [TreeEntry], current: [TreeEntry]) -> Int {
        let unchangedCount = unchanged(manifest: manifest, current: current).count
        let files = current.filter { $0.type == .file }.count
        return max(0, files - unchangedCount)
    }

    /// A deterministic bounded sample of the unchanged files: at most `limit` paths, the same for the same inputs and seed, sorted.
    public static func sample(manifest: [TreeEntry], current: [TreeEntry], limit: Int, seed: UInt64) -> [String] {
        var pool = unchanged(manifest: manifest, current: current)
        guard limit > 0 else { return [] }
        if pool.count <= limit { return pool }
        var rng = SplitMix64(seed: seed)
        // Partial Fisher-Yates: the first `limit` slots end up holding a uniform sample.
        for i in 0..<limit {
            let j = i + Int(rng.next() % UInt64(pool.count - i))
            if i != j { pool.swapAt(i, j) }
        }
        return pool[0..<limit].sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    /// Everything `Held.evaluate` needs from the listing, before any hashing: the Mac layer fills `hashed` and `hashMismatches` after it
    /// has read the sample (or, for "Check and reconnect", every unchanged file). A size that differs while the modification time is
    /// unchanged counts as a mismatch too.
    public static func listingResult(manifest: [TreeEntry], current: [TreeEntry], hashed: Int, hashMismatches: Int, fullCheck: Bool) -> ReturnCheckResult {
        let missing = missingFiles(manifest: manifest, current: current)
        let sizeBad = sizeMismatches(manifest: manifest, current: current)
        return ReturnCheckResult(quickPassed: missing == 0 && sizeBad == 0, hashed: hashed, mismatches: hashMismatches + sizeBad,
                                 fullCheck: fullCheck, missing: missing,
                                 changedSince: changedSince(manifest: manifest, current: current),
                                 sampleOf: unchanged(manifest: manifest, current: current).count)
    }
}

/// SplitMix64: a tiny deterministic generator (no platform differences) for the sample.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
