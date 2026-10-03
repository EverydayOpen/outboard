import Foundation

/// Phrases Outboard never uses to describe itself (BUILD_PLAN I12, APP6 section 4.10). `patterns` equals the non-comment lines of
/// `tools/banned_phrases.txt`, the single source of truth the CI grep reads; a test compares the two so they cannot drift.
/// This file is exempt from the grep because it has to spell the phrases.
public enum BannedPhrases {
    public static let patterns: [String] = [
        "\\bsafe(ly|st)?\\b",
        "\\bsecure(ly)?\\b",
        "\\brisk-?free\\b",
        "\\b(zero|no|without) +risk\\b",
        "\\bguarantee",
        "\\bnever +lose\\b",
        "\\bcan(no|')t +lose\\b",
        "\\bwon't +lose\\b",
        "\\bno +data +loss\\b",
        "\\bprevents? +data +loss\\b",
        "\\bprotects? +(your|against)\\b",
        "\\bbulletproof\\b",
        "\\bfoolproof\\b",
        "\\bfail-?safe\\b",
        "\\bcrash-?proof\\b",
        "\\bcorruption-?proof\\b",
        "\\btamper-?proof\\b",
        "\\bintact\\b",
        "\\buncorrupted\\b",
        "\\bcorruption-?free\\b",
        "\\bfaster\\b",
        "\\bspeed(s|ed)? +up\\b",
        "\\bspeed-?up\\b",
        "\\bboost",
        "\\bturbo\\b",
        "\\bsnappier\\b",
        "\\bperformance +(boost|gain|improvement)",
        "\\bas +fast +as +internal\\b",
        "\\b(works?|feels?|acts?) +like +(your +)?internal\\b",
        "\\bexternal +(ssd|drive|disk) +as +(an +)?internal\\b",
        "\\bexpands? +your +(mac|storage|ssd)",
        "\\bautomatic(ally)? +(mov|relocat|configur|migrat|install)",
        "\\bauto-?(move|configure|install)\\b",
        "\\bfully +reversible\\b",
        "\\b(always|100%) +(be +)?(undone|reversible)\\b",
        "\\bundo +(everything|anything)\\b",
        "\\bworks? +with +(any|every|all) +apps?\\b",
        "\\bverified +(safe|intact|backup)",
        "\\bfully +verified\\b",
        "\\b(safe|automatic|verified) +backup",
        "\\bendorsed +by\\b",
        "\\bapproved +by +(Apple|Adobe|Docker|Valve|Steam|Ollama)\\b",
        "\\bApple-approved\\b",
        "\\bin +one +click\\b",
        "\\bone-?click\\b",
        "\\binstant(ly)?\\b",
        "\\bin +seconds\\b",
        "\\bproven\\b",
        "\\btested +on +(a +|an +)?(real +)?(mac|macos)",
        "\\bworks? +on +(a +)?real +mac",
        "\\bmilitary\\b",
        "\\bcompliant\\b",
        "\\bGDPR\\b",
        "\\bHIPAA\\b",
        "\\bclean +your +Mac\\b",
        "\\bjunk\\b",
    ]

    /// The marker a line carries when it names a phrase only to say Outboard does not make that claim.
    public static let marker = "no-claim-ok"

    private static let expressions: [NSRegularExpression] = patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// The offending text, in order, for every banned phrase found. A line that carries the marker is skipped.
    public static func hits(in text: String) -> [String] {
        var out: [String] = []
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let s = String(line)
            if s.contains(marker) { continue }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            for expression in expressions {
                for match in expression.matches(in: s, options: [], range: range) {
                    if let r = Range(match.range, in: s) { out.append(String(s[r])) }
                }
            }
        }
        return out
    }
}
