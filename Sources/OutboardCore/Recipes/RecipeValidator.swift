import Foundation

/// The recipe rules of BUILD_PLAN §4.2, as code. `tools/check_recipes.py` applies the same rules to the exported golden file and
/// adds the repo-level checks (a `docs/VERIFY_LOG.md` entry per `verifiedOnRealMac: true`, a CODEOWNERS entry for `Recipes/`).
public enum RecipeValidator {
    /// The only `defaults` domain and keys any recipe may write or read. A new key is a change here and in a recipe, both reviewed.
    public static let permittedDefaults: [String: Set<String>] = [
        "com.apple.dt.Xcode": [
            "IDECustomDerivedDataLocation",
            "IDEDerivedDataPathMode",
            "IDECustomDistributionArchivesLocation",
        ],
    ]

    /// A home folder that is only used to expand `~/` for the never-list check.
    private static let probeHome = "/Users/jane"

    public static func problems(in recipes: [Recipe]) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for r in recipes {
            if !seen.insert(r.id).inserted { out.append("\(r.id): the id appears more than once.") }
            out += problems(in: r)
        }
        return out
    }

    public static func problems(in r: Recipe) -> [String] {
        var out: [String] = []
        func add(_ s: String) { out.append("\(r.id): \(s)") }

        if !isValidID(r.id) { add("the id must be lowercase words joined by hyphens.") }
        if r.version < 1 { add("the version must be 1 or more.") }
        if r.name.trimmingCharacters(in: .whitespaces).isEmpty { add("the name is empty.") }
        if r.sources.isEmpty { add("at least one source URL is required.") }
        for s in r.sources where !s.hasPrefix("https://") { add("source \(s) is not an https URL.") }
        if let min = r.minMacOS, min < MinOS(13) { add("minMacOS is below the deployment target (macOS 13).") }
        for b in r.bundleIDs where !isValidBundleID(b) { add("bundle id \(b) is not a plain reverse-DNS name.") }
        for n in r.processNames where n.isEmpty || n.contains(where: { "*?/[]".contains($0) }) { add("process name \(n) must be a plain name.") }

        // Sources: `~/`, no dot components, nothing the never-list or Outboard's own folder covers.
        for path in ([r.source].compactMap { $0 } + r.companionSources) {
            if !path.hasPrefix("~/") { add("source \(path) must start with ~/.") }
            if PathNorm.hasDotComponent(path) { add("source \(path) contains '..' or '.'.") }
            let expanded = PathText.expandTilde(path, home: probeHome)
            if let never = NeverList.reason(forPath: expanded, home: probeHome) { add("source \(path) is on the never-list (\(never.recipeID)).") }
            if NeverList.isOutboardOwn(expanded, home: probeHome) { add("source \(path) is Outboard's own folder.") }
        }

        var texts: [String] = [r.name, r.missingDriveEffect]
        if let e = r.envLine {
            texts.append(e)
            if !e.contains("{drive}") { add("the environment line must use {drive}.") }
            if e.contains("\"") || e.contains("'") { add("the environment line must not quote {drive}; Outboard quotes the path.") }
        }

        switch r.method {
        case .defaults(let domain, let keys, _):
            automated(r, add: add)
            if r.source == nil { add("an automated recipe needs a source.") }
            if !r.companionSources.isEmpty { add("only a link recipe may have companion folders.") }
            if r.onDriveMissing != .revertSetting && r.onDriveMissing != .leaveAlone { add("a defaults recipe must revert the setting or leave it alone when the drive is missing.") }
            if r.needsFDA { add("a defaults recipe does not need Full Disk Access.") }
            guard let permitted = permittedDefaults[domain] else {
                add("the defaults domain \(domain) is not on the allowlist.")
                break
            }
            if keys.isEmpty { add("a defaults recipe needs at least one key.") }
            var hasPath = false
            for key in keys {
                if !permitted.contains(key.name) { add("the defaults key \(key.name) is not on the allowlist.") }
                if case .destinationPath = key.value {
                    hasPath = true
                    if key.type != .string { add("\(key.name): a path value must be a string.") }
                }
                if case .int = key.value, key.type != .int { add("\(key.name): an int value needs the int type.") }
                if case .string = key.value, key.type != .string { add("\(key.name): a string value needs the string type.") }
                if let neutral = key.neutral {
                    if case .destinationPath = neutral { add("\(key.name): the neutral value cannot be the drive path.") }
                    if case .int = neutral, key.type != .int { add("\(key.name): the neutral value needs the int type.") }
                    if case .string = neutral, key.type != .string { add("\(key.name): the neutral value needs the string type.") }
                }
                if !key.valueVerified && r.verifiedOnRealMac { add("\(key.name): a recipe with an unverified value cannot be verifiedOnRealMac.") }
            }
            if !hasPath { add("no key receives the drive path.") }
        case .symlink:
            automated(r, add: add)
            if r.source == nil { add("an automated recipe needs a source.") }
            if r.onDriveMissing != .parkPlaceholder { add("a link recipe must park a placeholder when the drive is missing.") }
        case .guided(let steps):
            if steps.isEmpty { add("a guided card needs steps.") }
            texts += steps
            if let e = r.envLine, let token = e.range(of: "{drive}") {
                // The line Outboard prints points at <mount>/Outboard/<id><tail>: the steps must lead the person to that folder.
                let all = steps.joined(separator: " ")
                let tail = e[token.upperBound...].split(separator: "/").map(String.init)
                if !all.contains("\(Names.driveFolder) folder") || !all.contains(r.id) || !tail.allSatisfy({ all.contains($0) }) {
                    add("the steps must name the folder the environment line points at: \(Names.driveFolder)/\(r.id)\(e[token.upperBound...]).")
                }
            }
            if r.consent != nil { add("a guided card has no consent sheet.") }
            if r.onDriveMissing != .none { add("a guided card does nothing when the drive is missing.") }
            if r.needsFDA || r.sensitive { add("a guided card needs no Full Disk Access and has no encryption acknowledgement.") }
            if r.verifiedOnRealMac { add("a guided card is never marked verifiedOnRealMac (it moves nothing).") }
        case .never(let reason):
            texts.append(reason)
            if reason.trimmingCharacters(in: .whitespaces).isEmpty { add("a never card needs its reason.") }
            if r.source != nil || !r.companionSources.isEmpty { add("a never card names no folder.") }
            if r.onDriveMissing != .none { add("a never card does nothing when the drive is missing.") }
            if r.consent != nil { add("a never card has no consent sheet.") }
        }

        if let c = r.consent {
            texts += [c.what, c.whatChanges] + c.whatToKnow + c.checkboxes.map(\.text)
        }
        for text in texts {
            let hits = BannedPhrases.hits(in: text)
            if !hits.isEmpty { add("text contains a banned phrase (\(hits.joined(separator: ", "))): \(text.prefix(60))") }
        }
        return out
    }

    /// Rules that hold for both automated kinds.
    private static func automated(_ r: Recipe, add: (String) -> Void) {
        guard let c = r.consent else {
            add("an automated recipe needs its consent text.")
            return
        }
        if c.what.isEmpty || c.whatChanges.isEmpty { add("the consent text needs 'what' and 'whatChanges'.") }
        if c.checkboxes.isEmpty { add("the consent text needs at least one required checkbox.") }
        if Set(c.checkboxes.map(\.id)).count != c.checkboxes.count { add("consent checkbox ids must be unique.") }
        for box in c.checkboxes where box.id.isEmpty || box.id.hasPrefix("ack-") { add("consent checkbox id '\(box.id)' is empty or collides with an acknowledgement id.") }
        if !c.whatToKnow.contains(where: { $0.contains(Names.beforeMoveSuffix) }) {
            add("the consent bullets must say the original stays as <name>\(Names.beforeMoveSuffix).")
        }
        if (r.onDriveMissing == .parkPlaceholder || r.onDriveMissing == .revertSetting)
            && !c.whatToKnow.contains(where: { $0.contains(ConsentSheetText.whileRunningPhrase) }) {
            add("a bullet must say '\(ConsentSheetText.whileRunningPhrase), it ...': the note or the setting change happens only while Outboard runs.")
        }
        if r.riskClass == .irreplaceable && !c.whatToKnow.contains(where: { $0.contains("Time Machine") }) {
            add("an irreplaceable recipe must carry the Time Machine sentence.")
        }
        if r.missingDriveEffect.trimmingCharacters(in: .whitespaces).isEmpty { add("the missing-drive sentence is empty.") }
    }

    private static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, !id.hasPrefix("-"), !id.hasSuffix("-"), !id.contains("--") else { return false }
        return id.allSatisfy { ($0.isASCII && $0.isLowercase) || ($0.isASCII && $0.isNumber) || $0 == "-" }
    }

    /// At least two labels of letters, digits and hyphens; nothing that could turn a name match into a pattern.
    private static func isValidBundleID(_ s: String) -> Bool {
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, s.utf8.count <= 155 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-") && label.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        }
    }
}
