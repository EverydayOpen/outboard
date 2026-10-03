import Foundation

/// The journal's line format: one JSON object per line, sorted keys, dates as ISO-8601 whole seconds in UTC (BUILD_PLAN §4.5).
/// A `JournalEntry` has no field for file contents, command lines or anything but what the screen shows, so no log line can carry them.
public enum ActivityLog {
    /// "journal-2026-10.jsonl" (UTC month): one file per month.
    public static func fileName(for date: Date) -> String {
        let p = Civil.parts(date)
        return Names.journalPrefix + "\(Civil.pad(p.year, 4))-\(Civil.pad(p.month))" + Names.journalSuffix
    }

    public static func isJournalFile(_ name: String) -> Bool {
        let u = Array(name.utf8)
        guard u.count == "journal-2026-10.jsonl".utf8.count, name.hasPrefix(Names.journalPrefix), name.hasSuffix(Names.journalSuffix) else { return false }
        let digits = Array(u[8..<15])
        return digits.enumerated().allSatisfy { $0.offset == 4 ? $0.element == 45 : ($0.element >= 48 && $0.element <= 57) }
    }

    /// One line, no trailing newline (the Mac layer appends the newline itself).
    public static func encode(_ e: JournalEntry) -> String {
        guard let data = try? ISO8601Lite.encoder().encode(e), let line = String(data: data, encoding: .utf8) else { return "" }
        return line
    }

    public static func decode(line: String) -> JournalEntry? {
        try? ISO8601Lite.decoder().decode(JournalEntry.self, from: Data(line.utf8))
    }

    /// Tolerant: blank lines are ignored; a torn or damaged line is counted in `skippedLines` and never stops the rest (a torn last
    /// line is how a crash during an append looks).
    public static func decodeAll(_ text: String) -> (entries: [JournalEntry], skippedLines: Int) {
        var entries: [JournalEntry] = []
        var skipped = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let e = decode(line: line) { entries.append(e) } else { skipped += 1 }
        }
        return (entries, skipped)
    }
}
