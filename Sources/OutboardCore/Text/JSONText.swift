import Foundation

/// A tiny JSON value with a deterministic renderer (sorted keys, two-space indent, no platform differences), used for the golden
/// files and the JSON report. `JSONEncoder`'s pretty printing is not byte-identical on every Foundation, and a golden file must be.
indirect enum JSONValue {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    static func unum(_ n: UInt64) -> JSONValue { .int(Int64(clamping: n)) }
    static func num(_ n: Int) -> JSONValue { .int(Int64(n)) }
    static func optional(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
    static func strings(_ a: [String]) -> JSONValue { .array(a.map(JSONValue.string)) }

    /// Pretty (default) or compact. Object keys are always sorted by their UTF-8 bytes.
    func render(pretty: Bool = true) -> String {
        var out = ""
        emit(into: &out, indent: 0, pretty: pretty)
        return out
    }

    private func emit(into out: inout String, indent: Int, pretty: Bool) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let n): out += String(n)
        case .string(let s): out += JSONValue.quote(s)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: " ", count: (indent + 1) * 2) }
                item.emit(into: &out, indent: indent + 1, pretty: pretty)
            }
            if pretty { out += "\n" + String(repeating: " ", count: indent * 2) }
            out += "]"
        case .object(let dict):
            if dict.isEmpty { out += "{}"; return }
            out += "{"
            let keys = dict.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for (i, key) in keys.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: " ", count: (indent + 1) * 2) }
                out += JSONValue.quote(key) + (pretty ? ": " : ":")
                dict[key]?.emit(into: &out, indent: indent + 1, pretty: pretty)
            }
            if pretty { out += "\n" + String(repeating: " ", count: indent * 2) }
            out += "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
