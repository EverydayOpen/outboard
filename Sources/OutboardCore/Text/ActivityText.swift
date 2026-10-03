import Foundation

/// The Activity screen, the export timeline and crash recovery render the same `JournalEntry` lines through this one file (invariant
/// I10). Every line says what was done or checked, never what it means: "Compared 48,211 files by size and SHA-256: 0 differences."
/// Lines name a folder by its last path component and a drive by its label; they never carry a full path, file contents or a command.
public enum ActivityText {
    /// One line of the journal as one row. `recipeNames` maps a recipe id to the name shown (a missing id falls back to the begin
    /// line's recorded name, then to the id).
    ///
    /// `driveLabels` (volume UUID to a stand-in such as "Drive 1") is for a report that hides drive names: the line then never says the
    /// drive's own name, and a drive it can't place becomes "the drive". `moveVolume` is the UUID the move's plan recorded, for lines that
    /// don't carry one.
    public static func entry(for line: JournalEntry, recipeNames: [String: String], driveLabels: [String: String]? = nil,
                             moveVolume: String? = nil) -> ActivityEntry {
        let name = recipeName(of: line, recipeNames)
        var standIn: String?
        if let driveLabels {
            standIn = (line.vol ?? line.plan?.volume.uuid ?? moveVolume).flatMap { driveLabels[$0.uppercased()] } ?? "the drive"
        }
        let rendered = render(line, name: name, drive: standIn)
        return ActivityEntry(id: line.lineID, timestamp: line.ts, moveID: line.id == "app" ? nil : line.id,
                             recipeName: line.recipe == nil || line.recipe == "" ? nil : name, text: rendered.text,
                             tone: rendered.problem ? .problem : .normal, step: line.step)
    }

    /// The rows of a log, oldest first. An intent line is left out when its result is there too (the result line says it), except
    /// `begin` and `copy`, whose intent lines carry the plan. Unknown steps are kept and shown raw.
    public static func rows(from log: [JournalEntry], problemsOnly: Bool, driveLabels: [String: String]? = nil) -> [ActivityEntry] {
        var names: [String: String] = [:]
        var volumeOfMove: [String: String] = [:]
        for c in Catalogue.all { names[c.id] = c.name }
        for l in log {
            if let p = l.plan {
                names[p.recipeID] = names[p.recipeID] ?? p.recipeName
                volumeOfMove[l.id] = volumeOfMove[l.id] ?? p.volume.uuid
            }
        }
        var resultKeys: Set<String> = []
        for l in log where l.phase == .result { resultKeys.insert(l.id + "|" + l.step) }
        var out: [ActivityEntry] = []
        var intents: [String: JournalEntry] = [:]
        for original in log {
            var l = original
            let key = l.id + "|" + l.step
            if l.phase == .intent {
                intents[key] = l
            } else if let intent = intents[key] {
                // A result line says what happened; the names it acted on were written on its intent line.
                l.src = l.src ?? intent.src
                l.to = l.to ?? intent.to
                l.volName = l.volName ?? intent.volName
                l.note = l.note ?? intent.note
            }
            if l.phase == .intent, l.moveStep != nil, l.moveStep != .begin, l.moveStep != .copy, resultKeys.contains(key) { continue }
            let e = entry(for: l, recipeNames: names, driveLabels: driveLabels, moveVolume: volumeOfMove[l.id])
            if problemsOnly && e.tone != .problem { continue }
            out.append(e)
        }
        return out
    }

    // MARK: - Rendering

    private static func recipeName(of line: JournalEntry, _ names: [String: String]) -> String {
        let id = line.recipe.map { String($0.split(separator: "@", omittingEmptySubsequences: true).first ?? "") } ?? ""
        if !id.isEmpty, let n = names[id] { return n }
        if let p = line.plan { return p.recipeName }
        return id.isEmpty ? "this folder" : id
    }

    private static func leaf(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let l = PathNorm.leaf(path)
        return l.isEmpty ? nil : l
    }

    private static func drive(_ line: JournalEntry) -> String {
        if let n = line.volName, !n.isEmpty { return RecipeNames.driveLabel(n) }
        if let p = line.plan { return p.volume.label }
        return "the drive"
    }

    private static func differences(_ n: Int) -> String { n == 1 ? "1 difference" : "\(Format.number(n)) differences" }

    /// What each step is called when a generic sentence is needed.
    private static func phrase(_ step: MoveStep) -> String {
        switch step {
        case .begin: return "planning the move"
        case .preflight: return "the pre-move checks"
        case .copy: return "copying"
        case .verify: return "comparing the copy with the original"
        case .publish: return "publishing the checked copy"
        case .setAside: return "renaming the original"
        case .redirect: return "pointing the app at the drive"
        case .swapped: return "the final check"
        case .confirm: return "confirming the move"
        case .trash: return "moving the original to the Trash"
        case .rollback: return "rolling back"
        case .undoRedirect: return "undoing the redirect"
        case .undoSetAside: return "renaming the original back"
        case .setAsideForeign: return "setting aside a new item"
        case .returned: return "returning to your Mac"
        case .forget: return "forgetting the move"
        case .park: return "parking the link"
        case .unpark: return "reconnecting"
        case .retarget: return "updating the link"
        case .recreate: return "rebuilding the link"
        case .checkAndReconnect: return "Check and reconnect"
        case .recover: return "recovery"
        case .abort: return "stopping the move"
        case .guideViewed: return "showing the steps"
        case .useDrive: return "setting up the drive"
        case .startGuard: return "starting the Drive Guard"
        }
    }

    private static func abortReason(_ r: AbortReason) -> String {
        switch r {
        case .userCancelled: return "you cancelled"
        case .preflightFailed: return "a pre-move check failed"
        case .interrupted: return "the move was interrupted"
        case .destinationFull: return "the drive ran out of space"
        case .sourceChanged: return "the files changed while they were being copied"
        case .mismatch: return "a file on the drive differs from the original"
        case .appLaunched: return "the app was opened"
        case .journalUnwritable: return "the activity log can't be written"
        case .driveChanged: return "the drive changed"
        case .foreignFolderAppeared: return "something new appeared where the folder was"
        case .healthFailed: return "the link or setting didn't point at the drive"
        case .manifestUnreadable: return "the check list made at copy time couldn't be read back"
        case .needsPermission: return "macOS blocked access"
        case .copyFailed: return "the copy failed"
        case .sleepInterrupted: return "the Mac went to sleep"
        case .unknown: return "of an unknown error"
        }
    }

    private static func statusWords(_ s: StepStatus) -> String {
        switch s {
        case .ok: return "it finished"
        case .failed: return "it failed"
        case .refused: return "a rule refused it"
        case .mismatch: return "the files didn't match"
        case .interrupted: return "it was interrupted"
        }
    }

    private static func render(_ line: JournalEntry, name: String, drive standIn: String? = nil) -> (text: String, problem: Bool) {
        guard let step = line.moveStep else {
            let status = line.status.map { ", \($0.rawValue)" } ?? ""
            return ("Unknown step \"\(line.step)\" (\(line.phase.rawValue)\(status)).", true)
        }
        let d = standIn ?? drive(line)
        let note = line.note ?? ""
        let srcLeaf = leaf(line.src)
        let toLeaf = leaf(line.to)
        let ok = line.status == nil || line.status == .ok
        let isDefaultsNote = note.contains("defaults")

        // Intent lines: the ones that carry the plan have their own sentence; the rest are generic.
        if line.phase == .intent {
            switch step {
            case .begin:
                var sizes = ""
                if let p = line.plan {
                    sizes = " (\(Format.bytes(p.logicalBytes)), \(Format.count(p.fileCount, "file")))"
                }
                return ("Planned moving \(name) to \(d)\(sizes).", false)
            case .copy:
                var sizes = ""
                if let c = line.counts, let b = c.bytes, let f = c.files {
                    sizes = " (\(Format.bytes(b)), \(Format.count(f, "file")))"
                } else if let p = line.plan {
                    sizes = " (\(Format.bytes(p.logicalBytes)), \(Format.count(p.fileCount, "file")))"
                }
                return ("Started copying \(name) to \(d)\(sizes).", false)
            case .recover:
                return (line.note ?? "Started recovery.", false)
            default:
                return ("Started \(phrase(step)).", false)
            }
        }

        // Result lines that did not finish cleanly.
        if !ok, let status = line.status {
            switch step {
            case .verify:
                let n = line.verification?.differences ?? line.counts?.differences ?? 0
                let files = line.verification?.filesCompared ?? line.counts?.files
                let compared = files.map { "Compared \(Format.count($0, "file")) by size and SHA-256: " } ?? "Compared the copy with the original: "
                return ("\(compared)\(differences(n)) found. Nothing on your Mac was changed.", true)
            case .abort:
                break
            default:
                let code = line.errno.map { " (error \($0))" } ?? ""
                let sentence = RecipeNames.capitalized(phrase(step)) + " didn't finish: " + statusWords(status) + code + "."
                return (sentence, true)
            }
        }

        switch step {
        case .begin:
            return ("Planned moving \(name) to \(d).", false)
        case .preflight:
            let free = line.counts?.freeBytes.map { ", \(Format.bytes($0)) free" } ?? ""
            let fs = line.fsName.map { "\($0)" } ?? ""
            let detail = fs.isEmpty && free.isEmpty ? "" : " (\(fs)\(free))"
            let passed = line.counts?.checksPassed, total = line.counts?.checksTotal
            if let passed, let total {
                return ("Checked \(d)\(detail): \(passed) of \(total) checks passed.", false)
            }
            return ("Checked \(d)\(detail).", false)
        case .copy:
            return ("Finished copying.", false)
        case .verify:
            let n = line.verification?.differences ?? line.counts?.differences ?? 0
            let files = line.verification?.filesCompared ?? line.counts?.files ?? 0
            return ("Compared \(Format.count(files, "file")) by size and SHA-256: \(differences(n)).", n > 0)
        case .publish:
            return ("Moved the checked copy to its final place on \(d).", false)
        case .setAside:
            let a = srcLeaf ?? "the folder"
            return ("Renamed \(a) to \(toLeaf ?? a + Names.beforeMoveSuffix).", false)
        case .redirect:
            if isDefaultsNote { return ("Changed the \(name) setting to point at \(d).", false) }
            if note.contains("link"), let a = srcLeaf { return ("Put a link at \(a) pointing to \(d).", false) }
            return ("Pointed \(name) at \(d).", false)
        case .swapped:
            return ("The move is ready. Waiting for you to try \(RecipeNames.appName(recipeIDOf(line))) and confirm.", false)
        case .confirm:
            return ("You confirmed the move.", false)
        case .trash:
            let a = srcLeaf ?? "the original"
            if note.contains("result not recorded") { return ("\(a) is gone from its place; check the Trash.", true) }
            return ("You confirmed. Moved \(a) to the Trash.", false)
        case .rollback:
            return ("You rolled back \(name). Your original is back.", false)
        case .undoRedirect:
            return (isDefaultsNote ? "Put the \(name) setting back." : "Moved the link for \(name) aside.", false)
        case .undoSetAside:
            let a = toLeaf ?? srcLeaf ?? "the folder"
            return ("Renamed \(a)\(Names.beforeMoveSuffix) back to \(a).", false)
        case .setAsideForeign:
            let a = srcLeaf ?? "the folder"
            return ("Something new was at \(a). Renamed it to \(toLeaf ?? a + Names.createdWhileMovingSuffix) and left it alone.", false)
        case .returned:
            return ("Returned \(name) to your Mac. The copy on \(d) stays there until you move it to the Trash.", false)
        case .forget:
            return ("You forgot this move. Outboard can't get the data back without \(d).", false)
        case .park:
            // Only what Outboard saw is stated: a will-unmount is an eject, a lone did-unmount is a removal without ejecting, and a drive
            // that was already gone when Outboard looked is neither.
            let how: String
            switch RemovalKind.fromParkNote(note) {
            case .ejected: how = "\(d) was ejected."
            case .unclean: how = "\(d) was removed without ejecting."
            case .unknown: how = "\(d) was not connected when Outboard looked, and Outboard didn't see how it was removed."
            }
            let did = isDefaultsNote ? "Put the \(name) setting back to its default." : "Moved the link for \(name) aside and put a note where the folder was."
            return ("\(how) \(did)", false)
        case .unpark:
            return ("\(d) came back. " + (isDefaultsNote ? "Pointed the \(name) setting at it again." : "Put the link for \(name) back."), false)
        case .retarget:
            return ("\(d) was renamed or mounted somewhere else. " + (isDefaultsNote ? "Pointed the \(name) setting at its new place." : "Updated the link for \(name)."), false)
        case .recreate:
            return ("Rebuilt the link for \(name).", false)
        case .checkAndReconnect:
            if let c = line.counts, let files = c.files {
                return ("You chose Check and reconnect: \(Format.count(files, "file")) compared, \(differences(c.differences ?? 0)).", (c.differences ?? 0) > 0)
            }
            if let c = line.counts, let sampled = c.sampled, let of = c.sampleOf {
                return ("Checked \(Format.number(sampled)) of \(Format.number(of)) files: \(differences(c.differences ?? 0)).", (c.differences ?? 0) > 0)
            }
            return ("You chose Check and reconnect.", false)
        case .recover:
            return (line.note ?? "Recovered after an interruption.", false)
        case .abort:
            let reason = line.abort.map(abortReason) ?? "the move did not finish"
            let tail: String
            switch line.abort {
            case .some(.foreignFolderAppeared), .some(.healthFailed), .some(.manifestUnreadable), .some(.appLaunched):
                tail = "Your original is back where it was."
            default:
                tail = "Nothing on your Mac was changed."
            }
            return ("Stopped: \(reason). \(tail)", true)
        case .guideViewed:
            return ("Viewed the steps for \(name).", false)
        case .useDrive:
            return ("Chose \(d) as an Outboard drive.", false)
        case .startGuard:
            return ("Started watching your drives.", false)
        }
    }

    private static func recipeIDOf(_ line: JournalEntry) -> String {
        line.recipe.map { String($0.split(separator: "@", omittingEmptySubsequences: true).first ?? "") } ?? ""
    }
}
