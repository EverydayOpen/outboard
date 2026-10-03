import Foundation

/// Plain text helpers: sizes, counts and dates that read the same on every platform and locale (BUILD_PLAN §4.5).
public enum Format {
    /// Finder-style decimal units (1000): "999 bytes", "412 KB", "1.3 GB", "340 GB". One decimal from MB up while the figure is below 100.
    public static func bytes(_ n: UInt64) -> String {
        if n < 1000 { return n == 1 ? "1 byte" : "\(n) bytes" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(n) / 1000
        var unit = 0
        while true {
            let tenths = Int((value * 10).rounded())
            let oneDecimal = unit > 0 && tenths < 1000
            let whole = Int(value.rounded())
            if whole >= 1000 && unit < units.count - 1 {
                value /= 1000
                unit += 1
                continue
            }
            if oneDecimal && tenths % 10 != 0 { return "\(tenths / 10).\(tenths % 10) \(units[unit])" }
            return "\(oneDecimal ? tenths / 10 : whole) \(units[unit])"
        }
    }

    /// "at least 3 GB": a walk that hit a budget only knows a floor.
    public static func atLeast(_ n: UInt64) -> String { "at least " + bytes(n) }

    /// The figure, or "at least" the figure when it is only a floor.
    public static func size(_ n: UInt64, atLeast floor: Bool) -> String { floor ? atLeast(n) : bytes(n) }

    /// "1 item", "14 items". Regular plurals only (file, folder, drive ...).
    public static func count(_ n: Int, _ noun: String) -> String { "\(number(n)) \(noun)\(n == 1 ? "" : "s")" }

    /// "48,211": thousands separated by commas, whatever the locale.
    public static func number(_ n: Int) -> String {
        let negative = n < 0
        let digits = Array(String(n.magnitude))
        var out: [Character] = []
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (negative ? "-" : "") + String(out)
    }

    /// "2026-10-03", UTC.
    public static func date(_ d: Date) -> String {
        let p = Civil.parts(d)
        return "\(Civil.pad(p.year, 4))-\(Civil.pad(p.month))-\(Civil.pad(p.day))"
    }

    /// "2026-10-03 14:02 UTC": the one date-and-time spelling of the Markdown report.
    public static func dateTime(_ d: Date) -> String {
        let p = Civil.parts(d)
        return "\(date(d)) \(Civil.pad(p.hour)):\(Civil.pad(p.minute)) UTC"
    }

    /// "3 Oct", UTC: the short date inside a sentence ("Roll back to your original from 3 Oct").
    public static func shortDate(_ d: Date) -> String {
        let p = Civil.parts(d)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(p.day) \(months[max(0, min(11, p.month - 1))])"
    }

    /// Whole gigabytes for a set of rows that must add up to the rounded total (largest-remainder method, ties to the earlier row).
    /// The total is the sum of the unrounded bytes rounded to a whole GB; every row gets its floor plus at most one.
    public static func gigabytesRounded(_ bytes: [UInt64]) -> [Int] {
        let unit: UInt64 = 1_000_000_000
        guard !bytes.isEmpty else { return [] }
        let total = bytes.reduce(UInt64(0)) { $0 &+ $1 }
        let target = Int((total &+ unit / 2) / unit)
        var floors = bytes.map { Int($0 / unit) }
        var remaining = target - floors.reduce(0, +)
        if remaining <= 0 { return floors }
        let order = bytes.enumerated().sorted { a, b in
            let ra = a.element % unit, rb = b.element % unit
            return ra != rb ? ra > rb : a.offset < b.offset
        }
        for item in order where remaining > 0 {
            floors[item.offset] += 1
            remaining -= 1
        }
        return floors
    }

    /// "41 GB" for a whole-gigabyte figure.
    public static func gigabytes(_ n: Int) -> String { "\(number(n)) GB" }
}

/// Path text helpers. Home is replaced by `~` in everything the journal and the export show.
public enum PathText {
    /// "/Users/jane/Library/x" -> "~/Library/x". Only whole path components match, so "/Users/janet" is not under "/Users/jane".
    public static func tilde(_ path: String, home: String) -> String {
        let p = PathNorm.normalize(path)
        let h = PathNorm.normalize(home)
        guard !h.isEmpty, h != "/" else { return p }
        if p == h { return "~" }
        if p.hasPrefix(h + "/") { return "~" + String(p.dropFirst(h.count)) }
        return p
    }

    /// `tilde` for the value of a setting: only a value that is the home folder or starts with it changes; any other text (a number, a
    /// word, a path elsewhere) is returned exactly as it is.
    public static func tildeValue(_ value: String, home: String) -> String {
        let h = PathNorm.normalize(home)
        guard !h.isEmpty, h != "/" else { return value }
        if value == h { return "~" }
        if value.hasPrefix(h + "/") { return "~" + String(value.dropFirst(h.count)) }
        return value
    }

    /// The reverse of `tilde`: "~/Library/x" -> "/Users/jane/Library/x"; anything else is returned unchanged.
    public static func expandTilde(_ path: String, home: String) -> String {
        let h = PathNorm.normalize(home)
        if path == "~" { return h }
        if path.hasPrefix("~/") { return (h == "/" ? "" : h) + String(path.dropFirst(1)) }
        return path
    }
}

/// Lexical path arithmetic (no I/O, no symlink resolution: the Mac layer resolves, Core only compares text).
enum PathNorm {
    /// Collapses repeated slashes and drops a trailing slash (the root stays "/"). Does not resolve "." or "..".
    static func normalize(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        var out = ""
        var previousSlash = false
        for c in path {
            if c == "/" {
                if !previousSlash { out.append(c) }
                previousSlash = true
            } else {
                out.append(c)
                previousSlash = false
            }
        }
        if out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }

    static func components(_ path: String) -> [String] {
        normalize(path).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// True when a path component is ".." or "." (such a path is never approved).
    static func hasDotComponent(_ path: String) -> Bool {
        components(path).contains { $0 == ".." || $0 == "." }
    }

    static func leaf(_ path: String) -> String { components(path).last ?? "" }

    static func parent(_ path: String) -> String {
        let p = normalize(path)
        guard let slash = p.lastIndex(of: "/") else { return "" }
        if slash == p.startIndex { return "/" }
        return String(p[p.startIndex..<slash])
    }

    /// Equal to `root` or below it, by whole components.
    static func isUnder(_ path: String, _ root: String, caseInsensitive: Bool = false) -> Bool {
        var a = normalize(path)
        var b = normalize(root)
        if caseInsensitive { a = a.lowercased(); b = b.lowercased() }
        if a == b { return true }
        if b == "/" { return a.hasPrefix("/") }
        return a.hasPrefix(b + "/")
    }

    /// Strictly below `root` (not equal).
    static func isStrictlyUnder(_ path: String, _ root: String, caseInsensitive: Bool = false) -> Bool {
        isUnder(path, root, caseInsensitive: caseInsensitive) && normalize(path).count != normalize(root).count
    }

    static func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : normalize(base) + "/" + name
    }
}

/// UTC calendar arithmetic without Calendar or DateFormatter (identical on Linux and macOS, no locale).
enum Civil {
    struct Parts: Equatable {
        var year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    }

    static func pad(_ n: Int, _ width: Int = 2) -> String {
        let s = String(n)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// Days since 1970-01-01 -> civil date (Howard Hinnant's algorithm).
    static func parts(_ date: Date) -> Parts {
        let raw = date.timeIntervalSince1970
        let t = raw.isFinite ? Int64(max(-1e13, min(1e13, raw)).rounded(.down)) : 0
        var days = t / 86_400
        var rem = t % 86_400
        if rem < 0 { rem += 86_400; days -= 1 }
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return Parts(year: Int(m <= 2 ? y + 1 : y), month: Int(m), day: Int(d), hour: Int(rem / 3600), minute: Int(rem % 3600 / 60),
                     second: Int(rem % 60))
    }

    static func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        let y = Int64(month <= 2 ? year - 1 : year)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let m = Int64(month)
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + Int64(day) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        return Date(timeIntervalSince1970: Double(days * 86_400 + Int64(hour * 3600 + minute * 60 + second)))
    }
}

/// "2026-10-03T10:15:00Z": the only date spelling in the journal, the markers and the JSON report.
enum ISO8601Lite {
    static func string(_ d: Date) -> String {
        let p = Civil.parts(d)
        return "\(Civil.pad(p.year, 4))-\(Civil.pad(p.month))-\(Civil.pad(p.day))T\(Civil.pad(p.hour)):\(Civil.pad(p.minute)):\(Civil.pad(p.second))Z"
    }

    /// Accepts "YYYY-MM-DDTHH:MM:SS" with optional fractional seconds, then "Z". Nothing else.
    static func parse(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58 else { return nil }
        func num(_ a: Int, _ b: Int) -> Int? {
            var v = 0
            for i in a..<b {
                guard u[i] >= 48, u[i] <= 57 else { return nil }
                v = v * 10 + Int(u[i] - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 7), let d = num(8, 10), let h = num(11, 13), let mi = num(14, 16), let se = num(17, 19),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, se < 61 else { return nil }
        var i = 19
        var fraction = 0.0
        if u[i] == 46 {
            i += 1
            var scale = 0.1
            while i < u.count, u[i] >= 48, u[i] <= 57 {
                fraction += Double(u[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }
        guard i == u.count - 1, u[i] == 90 else { return nil }
        return Civil.date(year: y, month: mo, day: d, hour: h, minute: mi, second: se).addingTimeInterval(fraction)
    }

    static func encodeStrategy() -> JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(string(date))
        }
    }

    static func decodeStrategy() -> JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let d = parse(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO-8601 UTC date."))
            }
            return d
        }
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = encodeStrategy()
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = decodeStrategy()
        return d
    }
}
