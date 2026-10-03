import Darwin
import Foundation
import OutboardCore

enum PreflightResult {
    case passed(PreflightReport)
    case failed(PreflightReport)

    var report: PreflightReport {
        switch self {
        case .passed(let r), .failed(let r): return r
        }
    }
}

/// P1 to P14 (safety-ux 2.3): every check that must hold before a byte is copied. Read-only (one walk of the source, `lstat` calls
/// and the running check); nothing is written. All checks are evaluated so the report lists every one, and the move starts only if
/// all of them pass. A check that cannot be answered fails and says which signal was missing (invariant I4).
enum Preflight {
    static func run(_ plan: MovePlan, recipe: Recipe, drive: DriveFacts, home: String, snapshot: RunningSnapshot, journalWritable: Bool,
                    policy: Policy, macOS: MinOS, mutationFree: Bool = true) -> PreflightResult {
        let top = Fs.info(plan.sourcePath)
        let isDirectory = top.err == 0 && Fs.kind(top.st) == .directory
        let walked = isDirectory ? SizeScanner.walk(plan.sourcePath) : nil
        let fp = walked?.fingerprint
        var checks: [PreflightCheck] = []
        func add(_ id: PreflightID, _ passed: Bool, _ detail: String = "") { checks.append(PreflightCheck(id, passed: passed, detail: passed ? "" : detail)) }

        // P1: the drive, as it is now, for this recipe and this folder.
        let needs = SourceNeeds(logicalBytes: max(plan.logicalBytes, fp?.logicalBytes ?? 0), isCaseSensitive: DriveInspector.caseSensitivity(ofPath: plan.sourcePath),
                                hasHardLinks: (fp?.hardLinkedFiles ?? 0) > 0, hasSymlinks: (fp?.symlinks ?? 0) > 0)
        let eligibility = Eligibility.evaluate(volume: drive, recipe: recipe, source: needs, policy: policy)
        let ticked = Set(plan.consent.ackIDs)
        let unticked = eligibility.acks.filter { !ticked.contains($0.ackID) }
        let changed = Eligibility.freshness(plannedUUID: plan.destination.volumeUUID, plannedMountPoint: plan.destination.mountPoint, now: drive)
        if let changed {
            add(.p1, false, changed.message)
        } else if !OutboardRoot.driveFolderIsSound(mountPoint: plan.destination.mountPoint, path: plan.destination.finalPath) {
            add(.p1, false, OutboardRoot.driveFolderText)
        } else if let first = eligibility.firstRefusal {
            add(.p1, false, first.message)
        } else if let first = unticked.first {
            add(.p1, false, first.message)
        } else {
            add(.p1, true)
        }

        // P2: this build offers the recipe, in the version the plan was made from.
        let osOK = recipe.minMacOS.map { macOS >= $0 } ?? true
        let verifiedOrAccepted = policy.treatsAllRecipesAsVerified || recipe.verifiedOnRealMac || plan.consent.sawUnverifiedNote
        add(.p2, recipe.isAutomated && recipe.version == plan.recipeVersion && osOK && verifiedOrAccepted,
            osOK ? "This move is not offered in this build." : "This move needs a newer macOS.")

        // P3: a real folder on this Mac's own data volume, not a link, not already pointed somewhere else.
        var redirectedAlready = false
        if case .defaults(_, _, let prior, _) = plan.redirect {
            redirectedAlready = DefaultsRedirect.isRedirected(recipe, home: home, read: { key in prior.first { $0.key == key.name }.map { $0.value } })
        }
        let onHomeVolume = isDirectory && Fs.device(of: home) == Int64(top.st.st_dev)
        let local = Fs.isLocalVolume(plan.sourcePath) == true
        add(.p3, isDirectory && onHomeVolume && local && !redirectedAlready,
            redirectedAlready ? "The app's setting already points to a custom folder." : "The folder is not a plain folder on this Mac's own storage.")

        // P4: not on the never-list, and neither is where the copy would go. The list is lexical, so the folders above both are
        // followed to where they really lead (a parent that is a link into iCloud Drive or a container passes no other check).
        let detour = Fs.ancestorProblem(plan.sourcePath, home: home) ?? Fs.ancestorProblem(plan.stagingPath, home: home)
        add(.p4, NeverList.reason(forPath: plan.sourcePath, home: home) == nil && NeverList.reason(forPath: plan.stagingPath, home: home) == nil && detour == nil,
            detour ?? "This location is one Outboard never touches.")

        // P5: fully local. A dataless file would download or fail to read.
        add(.p5, fp != nil && fp?.datalessFiles == 0, "The folder holds files that are stored in the cloud and not on this Mac.")

        // P6: no sockets, pipes, devices, mount points or sparse files.
        add(.p6, fp != nil && fp?.specialFiles == 0 && fp?.sparseFiles == 0,
            "The folder holds special or sparse files that a copy would not reproduce.")

        // P7: nothing left over from an earlier attempt.
        let remains = leftovers(plan, home: home)
        add(.p7, remains.isEmpty, remains.first ?? "")

        // P8: the app and its helpers are not running; the recipe's own checks are ticked.
        let state = RunningCheck.state(recipe: recipe, snapshot: snapshot)
        let required = recipe.consent?.checkboxes.map(\.id) ?? []
        let missing = required.filter { !plan.consent.tickedIDs.contains($0) }
        let blockers = RunningCheck.blockers(recipe: recipe, snapshot: snapshot).filter { !$0.isClear }.map(\.name)
        if state == .unknown {
            add(.p8, false, Say.unknownRunning)
        } else if state == .running {
            add(.p8, false, blockers.isEmpty ? "The app is running. Quit it and try again." : "Running: " + blockers.joined(separator: ", ") + ". Quit it and try again.")
        } else {
            add(.p8, missing.isEmpty, "A box on the sheet was not ticked.")
        }

        // P9: the journal takes lines.
        add(.p9, journalWritable, Say.journalBlocked)

        // P10: readable end to end. macOS-protected folders say EPERM here and nothing is changed.
        let blocked = walked.map { $0.firstErrno == EPERM || $0.firstErrno == EACCES } ?? (top.err == EPERM || top.err == EACCES)
        add(.p10, walked?.isComplete == true,
            blocked ? "macOS does not let Outboard read this folder. Full Disk Access is needed." : "The folder could not be read end to end.")

        // P11 and P12: case sensitivity and hard links, as Core's rules E10 and E11 judge them.
        add(.p11, !eligibility.refusals.contains { $0.rule == .e10 }, "The drive and the data treat upper and lower case differently.")
        add(.p12, !eligibility.refusals.contains { $0.rule == .e11 }, "The drive cannot hold the links this data needs.")

        // P13: every path fits on the drive, and the folder has few enough entries for its check list (manifest) to be written and read
        // back as one file. Refused here, before the copy, so a huge folder is not copied for hours and then rolled back.
        let pathsFit = fitsOnDrive(plan, walked)
        let manifestFits = walked.map { Limits.manifestFits(entryCount: $0.entries.count) } ?? false
        add(.p13, pathsFit && manifestFits,
            pathsFit ? "The folder has too many files and folders for Outboard to keep a check list of them." : "Some names or paths in the folder are too long for the drive.")

        // P14: nothing else is changing anything.
        add(.p14, mutationFree, Say.busy)

        let report = PreflightReport(checks: checks)
        return report.passed ? .passed(report) : .failed(report)
    }

    /// What an earlier attempt left behind, in plain English. Empty = clean.
    static func leftovers(_ plan: MovePlan, home: String) -> [String] {
        var out: [String] = []
        if Fs.exists(plan.beforeMovePath) { out.append("An earlier safety copy is still next to the folder (" + Fs.leaf(of: plan.beforeMovePath) + ").") }
        if Fs.exists(Park.parkedFolder(moveID: plan.id, home: home)) { out.append("A parked item from an earlier attempt is still there.") }
        if Fs.exists(plan.stagingPath) { out.append("An incomplete copy from an earlier attempt is on the drive.") }
        if Fs.exists(plan.destination.finalPath) { out.append("A copy from an earlier attempt is already on the drive. Move it to the Trash first.") }
        let recipeFolder = plan.destination.mountPoint + "/" + plan.destination.recipeFolder
        if Fs.names(in: recipeFolder).names.contains(where: { $0.hasPrefix(Names.stagingPrefix) }) {
            out.append("An incomplete copy from an earlier attempt is on the drive. Move it to the Trash first.")
        }
        return out
    }

    private static func fitsOnDrive(_ plan: MovePlan, _ walked: SizeScanner.WalkResult?) -> Bool {
        guard let walked else { return false }
        let base = plan.stagingPath.utf8.count
        for e in walked.entries {
            if base + 1 + e.path.utf8.count >= Fs.pathLimit - 1 { return false }
            for part in e.path.split(separator: "/") where part.utf8.count > Fs.nameLimit { return false }
        }
        return plan.destination.finalPath.utf8.count < Fs.pathLimit - 1
    }

    // MARK: - The way back

    /// Nothing is at the path, or what is there is the link or the note Outboard made (same target and same object as the journal
    /// recorded), not just any link or any small read-only file.
    private static func isOurs(_ path: String, _ at: (st: stat, err: Int32), _ facts: JournalFacts) -> Bool {
        if at.err == ENOENT { return true }
        guard at.err == 0 else { return false }
        switch Fs.kind(at.st) {
        case .symlink:
            guard let link = facts.lastLink, Fs.linkTarget(path) == link.target, case .unchanged = Guard.verifyStamp(path: path, expected: link.stamp) else { return false }
            return true
        case .file where Redirect.isNote(at.st):
            guard let note = facts.lastPlaceholder, case .unchanged = Guard.verifyStamp(path: path, expected: note) else { return false }
            return true
        default:
            return false
        }
    }

    /// The checks for "Return to Mac": the drive copy is still the object that was recorded, the Mac has room, the path holds only
    /// what Outboard put there, and nothing is running. Same report type, the ones that do not apply are left out.
    /// `original` is what the journal says about the move being brought back: the link and the note it made, by stamp.
    static func runReturn(_ plan: MovePlan, recipe: Recipe, home: String, snapshot: RunningSnapshot, journalWritable: Bool,
                          original: JournalFacts) -> PreflightResult {
        var checks: [PreflightCheck] = []
        func add(_ id: PreflightID, _ passed: Bool, _ detail: String = "") { checks.append(PreflightCheck(id, passed: passed, detail: passed ? "" : detail)) }
        let ref = VolumeRef(uuid: plan.destination.volumeUUID, name: plan.destination.volumeName, token: plan.destination.volumeToken)
        let d = plan.destination
        let present = VolumeIdentity.matches(ref, mountPoint: d.mountPoint)
        add(.p1, present && Fs.isPlainDirectory(plan.sourcePath), "The drive or the copy on it is not there.")
        add(.p2, recipe.isAutomated, "This move is not offered in this build.")
        let walked = present ? SizeScanner.walk(plan.sourcePath) : nil
        let free = (try? URL(fileURLWithPath: home).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) }
        let needed = (walked?.fingerprint.logicalBytes ?? plan.logicalBytes) / Limits.freeSpaceDenominator * Limits.freeSpaceNumerator
        add(.p3, free.map { $0 >= needed } ?? false, "Your Mac does not have enough free space for the copy.")
        let detour = Fs.ancestorProblem(plan.macPath, home: home)
        add(.p4, NeverList.reason(forPath: plan.macPath, home: home) == nil && detour == nil, detour ?? "This location is one Outboard never touches.")
        add(.p5, walked != nil && walked?.fingerprint.datalessFiles == 0, "The copy holds files that are stored in the cloud.")
        add(.p6, walked != nil && walked?.fingerprint.specialFiles == 0 && walked?.fingerprint.sparseFiles == 0, "The copy holds special or sparse files.")
        let returning = Copier.destinationPath(plan)
        let pathKind = Fs.info(plan.macPath)
        add(.p7, !Fs.exists(returning) && isOurs(plan.macPath, pathKind, original), "Something that is not Outboard's is where the folder goes, or an earlier return left a copy.")
        let state = RunningCheck.state(recipe: recipe, snapshot: snapshot)
        add(.p8, state == .notRunning, state == .unknown ? Say.unknownRunning : "The app is running. Quit it and try again.")
        add(.p9, journalWritable, Say.journalBlocked)
        add(.p10, walked?.isComplete == true, "The copy on the drive could not be read end to end.")
        add(.p13, walked.map { w in w.entries.allSatisfy { returning.utf8.count + 1 + $0.path.utf8.count < Fs.pathLimit - 1 } } ?? false, "Some paths are too long.")
        add(.p14, true)
        let report = PreflightReport(checks: checks)
        return report.passed ? .passed(report) : .failed(report)
    }
}
