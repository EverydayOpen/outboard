import Foundation
import OutboardCore

enum RedirectResult {
    case applied
    /// Something is already at the path (a link or folder an app made in the gap); nothing was changed.
    case exists
    case refused(String)
    case failed(errno: Int32?, message: String)
    case notAttempted(String)

    var isApplied: Bool {
        if case .applied = self { return true }
        return false
    }

    var text: String {
        switch self {
        case .applied: return "Done."
        case .exists: return "Something is already at that path."
        case .refused(let why), .notAttempted(let why): return why
        case .failed(_, let message): return message
        }
    }
}

/// The one caller of `defaults write`: points an app's own setting at the copy (an official setting, Xcode's DerivedData location)
/// and puts it back. Catalogue keys only (`Catalogue.allowsDefaults`), never while the app runs (a running Xcode would write the
/// key again when it quits), journal intent first, the value read back after. A restore writes the prior or neutral value; there is
/// no delete. Writes go through `cfprefsd` via the `defaults` tool, never by editing a plist file.
enum DefaultsRedirect {
    static func apply(_ plan: MovePlan, recipe: Recipe, home: String) -> RedirectResult {
        guard case .defaults(let domain, let writes, _, _) = plan.redirect else { return .refused("This move does not change a setting.") }
        return redirectSetting(writes, domain: domain, step: .redirect, subject: JournalSubject(plan), recipe: recipe, home: home)
    }

    /// Writes the values that put the setting back (`revert` as resolved when the move was planned). A rollback journals it as
    /// `undoRedirect`; the guard, parking a setting because the drive is away, journals it as `park` (with how the drive left in
    /// `mark`), so recovery never reads the guard's write as a rollback.
    static func revert(domain: String, writes: [DefaultsWrite], subject: JournalSubject, recipe: Recipe, home: String,
                       step: MoveStep = .undoRedirect, mark: String? = nil) -> RedirectResult {
        redirectSetting(writes, domain: domain, step: step, mark: mark, subject: subject, recipe: recipe, home: home)
    }

    /// Writes the values again when the drive is back (the guard's unpark of a `defaults` relocation), or, as `retarget`, when it
    /// came back under another name or path and the setting still holds the old one.
    static func reapply(domain: String, writes: [DefaultsWrite], subject: JournalSubject, recipe: Recipe, home: String,
                        step: MoveStep = .unpark) -> RedirectResult {
        redirectSetting(writes, domain: domain, step: step, subject: subject, recipe: recipe, home: home)
    }

    /// The single place that writes. `apply` and `revert` differ only in the values and the journal step.
    private static func redirectSetting(_ writes: [DefaultsWrite], domain: String, step: MoveStep, mark: String? = nil, subject: JournalSubject,
                                        recipe: Recipe, home: String) -> RedirectResult {
        if writes.isEmpty { return .applied }
        // A value kept as `~/...` in the journal is written as the real path (expanding an expanded value changes nothing).
        let writes = writes.map { DefaultsWrite(key: $0.key, type: $0.type, value: PathText.expandTilde($0.value, home: home)) }
        for w in writes {
            guard Catalogue.allowsDefaults(domain, w.key) else { return .refused("This setting is not one Outboard changes.") }
        }
        switch RunningCheck.state(recipe: recipe, snapshot: RunningApps.snapshot(for: recipe, home: home)) {
        case .notRunning: break
        case .running: return .refused("\(recipe.name) is using it. Quit the app and try again.")
        case .unknown: return .refused(Say.unknownRunning)
        }
        let keys = writes.map(\.key).joined(separator: ", ")
        let note = "defaults " + domain + ": " + keys + (mark.map { " " + $0 } ?? "")
        guard Journal.intent(step, subject: subject, home: home, note: note) else {
            return .notAttempted(Say.journalBlocked)
        }
        var problem: String?
        for w in writes {
            let out = ProcessRunner.run(.defaultsWrite(domain: domain, key: w.key, type: w.type, value: w.value))
            if !out.ok {
                problem = out.timedOut ? "The setting did not answer in time." : "The setting could not be written."
                break
            }
        }
        if problem == nil {
            for w in writes {
                let back = ProcessRunner.run(.defaultsRead(domain: domain, key: w.key))
                if !back.ok || Parsers.defaultsRead(back.text, type: w.type) != w.value {
                    problem = "The setting did not read back as written."
                    break
                }
            }
        }
        Journal.result(step, subject: subject, home: home, status: problem == nil ? .ok : .failed, note: note)
        if let problem { return .failed(errno: nil, message: problem) }
        return .applied
    }

    /// What `defaults read` says now: `.some(nil)` = the key does not exist, `nil` = it could not be read (unknown), else the text.
    /// Read-only; catalogue keys only.
    static func currentValue(domain: String, key: String, type: DefaultsValueType) -> String?? {
        let out = ProcessRunner.run(.defaultsRead(domain: domain, key: key))
        if out.timedOut || !out.ran { return nil }
        if out.status == 0 { return .some(Parsers.defaultsRead(out.text, type: type)) }
        // `defaults read` exits 1 for a missing domain or key; stderr is not read (VERIFY the exit code on 13, 15, 26).
        return out.status == 1 ? .some(nil) : nil
    }

    /// Whether a `defaults` recipe's setting already sends the app somewhere else. A rollback or a guard revert puts the mode key (or,
    /// for a recipe with no mode key, the default path) back but leaves the path key set, so that key alone says nothing: it counts
    /// only when it differs from the recipe's own folder and no mode key reads as its neutral value (or is absent).
    /// `lookup` answers like `currentValue`: `.some(nil)` = the key does not exist, nil = it could not be read (then it counts as set).
    static func isRedirected(_ recipe: Recipe, home: String, read lookup: (DefaultsKeySpec) -> String??) -> Bool {
        guard case .defaults(_, let keys, _) = recipe.method, let pathKey = keys.first(where: { $0.value == .destinationPath }),
              case .some(.some(let path)) = lookup(pathKey), !path.isEmpty,
              PathText.tilde(path, home: home) != PathText.tilde(PathText.expandTilde(recipe.source, home: home), home: home) else { return false }
        for mode in keys where mode.value != .destinationPath {
            let neutral: String?
            switch mode.neutral {
            case .int(let n)?: neutral = String(n)
            case .string(let s)?: neutral = PathText.expandTilde(s, home: home)
            default: neutral = nil
            }
            guard let neutral, case .some(let seen) = lookup(mode) else { continue }
            if seen == nil || seen == neutral { return false }
        }
        return true
    }
}
