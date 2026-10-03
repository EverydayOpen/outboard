import Foundation

/// Builds the plan of one move from a recipe, a measured folder, a drive and the ticked consent boxes (BUILD_PLAN §4.4). Pure: it
/// changes nothing on disk. Every refusal is a plain sentence, and a refusal means no plan exists, so nothing downstream can run.
public enum MovePlanner {
    /// `20261003T101500Z-3fa9c1`: the UTC time and six hex digits of `random`.
    public static func newMoveID(now: Date, random: UInt32) -> String {
        let p = Civil.parts(now)
        let hex = String(random & 0xFF_FFFF, radix: 16)
        let suffix = String(repeating: "0", count: 6 - hex.count) + hex
        return "\(Civil.pad(p.year, 4))\(Civil.pad(p.month))\(Civil.pad(p.day))T\(Civil.pad(p.hour))\(Civil.pad(p.minute))\(Civil.pad(p.second))Z-\(suffix)"
    }

    /// The consent boxes plus the eligibility acknowledgements that must be ticked before a plan exists.
    public static func requiredCheckboxIDs(recipe: Recipe, report: EligibilityReport) -> [String] {
        var ids = recipe.consent?.checkboxes.map(\.id) ?? []
        for ack in report.acks where !ids.contains(ack.ackID) { ids.append(ack.ackID) }
        return ids
    }

    /// The folder's name on the drive: the last component of the source without leading dots (`.npm` -> `npm`), so a hidden folder
    /// does not become a hidden folder on the drive.
    public static func leafName(forSource path: String) -> String {
        var name = PathNorm.leaf(path)
        while name.hasPrefix(".") { name.removeFirst() }
        return name.isEmpty ? "data" : name
    }

    public static func plan(recipe: Recipe, folder: SizeScan, drive: DriveFacts, report: EligibilityReport, consent: ConsentRecord,
                            prior: [PriorValue], home: String, now: Date, moveID: String, groupID: String?,
                            policy: Policy = .release, prefs: Preferences = .default) -> MovePlanResult {
        func refuse(_ reason: String) -> MovePlanResult { MovePlanResult(plan: nil, eligibility: report, refusal: reason) }
        let homePath = PathNorm.normalize(home)

        // The recipe
        guard recipe.isAutomated, let sheet = recipe.consent else {
            return refuse("Outboard doesn't move \(recipe.name) itself. Use the steps on its card.")
        }
        guard Catalogue.isEnabled(recipe, prefs: prefs, policy: policy) else { return refuse("This move isn't turned on in this build.") }
        if Catalogue.isUnverified(recipe, policy: policy) && !consent.sawUnverifiedNote {
            return refuse("The sheet for this move must carry the line \"\(Names.notTriedMarker)\" first.")
        }
        guard consent.recipeVersion == recipe.version else { return refuse("This recipe changed after the sheet was shown. Open the sheet again.") }

        // The folder
        let known = ([recipe.source].compactMap { $0 } + recipe.companionSources)
        guard folder.recipeID == recipe.id, known.contains(folder.path) else { return refuse("That folder is not one of this recipe's folders.") }
        let source = PathNorm.normalize(PathText.expandTilde(folder.path, home: homePath))
        guard PathNorm.isStrictlyUnder(source, homePath) else { return refuse("The folder is not inside your home folder.") }
        if let never = NeverList.reason(forPath: source, home: homePath) { return refuse(never.text) }
        if NeverList.isOutboardOwn(source, home: homePath) { return refuse("That is Outboard's own folder.") }
        let leafOfSource = PathNorm.leaf(source)
        switch folder.state {
        case .absent: return refuse("\(leafOfSource) isn't on this Mac.")
        case .notMeasured:
            return refuse(folder.reason == .needsFullDiskAccess
                ? "\(leafOfSource) can't be measured until macOS allows access (Full Disk Access)."
                : "\(leafOfSource) hasn't been measured yet.")
        case .atLeast: return refuse("The size of \(leafOfSource) is only a lower bound. Measure it again.")
        case .measured: break
        }
        if folder.isLink { return refuse("\(leafOfSource) is already a link, so it was left alone.") }
        guard let stamp = folder.stamp, stamp.type == .directory else { return refuse("Outboard couldn't record what \(leafOfSource) is. Measure it again.") }
        let fp = folder.fingerprint
        if fp.specialFiles > 0 { return refuse("\(leafOfSource) holds special files (sockets or devices) that can't be copied.") }
        if fp.datalessFiles > 0 { return refuse("Some files in \(leafOfSource) are not stored on this Mac (iCloud placeholders).") }
        if fp.sparseFiles > 0 { return refuse("Some files in \(leafOfSource) are sparse files, which Outboard doesn't copy.") }

        // The drive
        if let rid = report.recipeID, rid != recipe.id { return refuse("That drive check was made for another recipe.") }
        guard report.volumeID == drive.id else { return refuse("That drive check was made for another drive.") }
        if let first = report.firstRefusal { return refuse(first.message) }
        guard let uuid = drive.uuid, !uuid.isEmpty else { return refuse("This drive has no volume ID, so Outboard couldn't recognise it again.") }
        let mount = PathNorm.normalize(drive.mountPoint)
        guard RuleContext.isStandardMount(mount) else { return refuse("This drive is mounted in an unusual place.") }
        guard drive.hasOutboardMarker, let token = drive.markerToken, !token.isEmpty else {
            return refuse("Choose Use this drive first, so Outboard can recognise it again.")
        }
        guard let available = Eligibility.effectiveAvailable(drive) else {
            return refuse("We couldn't tell how much space is free on \(Eligibility.driveLabel(drive)).")
        }
        let need = Eligibility.requiredFree(forBytes: fp.logicalBytes, capacity: drive.capacityBytes)
        if available < need {
            return refuse("Needs \(Format.bytes(need)) free on \(Eligibility.driveLabel(drive)); it has \(Format.bytes(available)).")
        }

        // The ticks
        let required = requiredCheckboxIDs(recipe: recipe, report: report)
        let consentBoxes = Set(sheet.checkboxes.map(\.id))
        let ticked = Set(consent.tickedIDs)
        let acked = Set(consent.ackIDs)
        for id in required {
            let done = consentBoxes.contains(id) ? ticked.contains(id) : acked.contains(id)
            if !done { return refuse("Tick every box on the sheet first.") }
        }

        // The destination and how the app is pointed at it
        let leaf = leafName(forSource: folder.path)
        let destination = PlanDestination(volumeUUID: uuid, volumeName: drive.name, mountPoint: mount, volumeToken: token,
                                          recipeFolder: Names.driveFolder + "/" + recipe.id, leaf: leaf)
        let redirect: RedirectPlan
        switch recipe.method {
        case .symlink:
            redirect = .symbolicLink(linkPath: source, target: destination.finalPath)
        case .defaults(let domain, let keys, let restore):
            for key in keys where !prior.contains(where: { $0.key == key.name }) {
                return refuse("Outboard couldn't read the current value of the \(key.name) setting, so it can't put it back.")
            }
            let writes = keys.compactMap { key in
                resolve(key.value, finalPath: destination.finalPath, home: homePath).map { DefaultsWrite(key: key.name, type: key.type, value: $0) }
            }
            let revert = keys.compactMap { key -> DefaultsWrite? in
                let before = prior.first { $0.key == key.name }
                switch restore {
                case .writePrior:
                    if let before, let value = before.value { return DefaultsWrite(key: key.name, type: before.type ?? key.type, value: value) }
                    fallthrough
                case .writeNeutral:
                    guard let neutral = key.neutral, let value = resolve(neutral, finalPath: nil, home: homePath) else { return nil }
                    return DefaultsWrite(key: key.name, type: key.type, value: value)
                }
            }
            redirect = .defaults(domain: domain, writes: writes, prior: prior, revert: revert)
        case .guided, .never:
            return refuse("Outboard doesn't move \(recipe.name) itself. Use the steps on its card.")
        }

        let plan = MovePlan(id: moveID, direction: .toDrive, recipeID: recipe.id, recipeVersion: recipe.version, recipeName: recipe.name,
                            method: recipe.kind, risk: recipe.riskClass, sourcePath: source, macPath: source, sourceStamp: stamp,
                            sourceFingerprint: fp, destination: destination, redirect: redirect, consent: consent, groupID: groupID,
                            createdAt: now)
        return MovePlanResult(plan: plan, eligibility: report, refusal: nil)
    }

    private static func resolve(_ v: DefaultsValueSource, finalPath: String?, home: String) -> String? {
        switch v {
        case .destinationPath: return finalPath
        case .int(let n): return String(n)
        case .string(let s): return PathText.expandTilde(s, home: home)
        }
    }

    /// The `begin` line's payload. Paths use `~` for the home folder; without `home` the folder under `/Users/<name>` is recognised.
    public static func journalPlan(_ plan: MovePlan, onDriveMissing: OnDriveMissing, volume: VolumeRef, fileCount: Int, home: String? = nil) -> JournalPlan {
        let h = home.map(PathNorm.normalize) ?? inferredHome(plan.macPath)
        var domain: String?
        var writes: [DefaultsWrite] = []
        var prior: [PriorValue] = []
        var revert: [DefaultsWrite] = []
        if case .defaults(let d, let w, let p, let r) = plan.redirect {
            // A value under the home folder is journaled as `~/...`; the readers (`RelocationFold`, `Recover.settingFact`) expand it again.
            func encoded(_ x: DefaultsWrite) -> DefaultsWrite { DefaultsWrite(key: x.key, type: x.type, value: PathText.tildeValue(x.value, home: h)) }
            domain = d
            writes = w.map(encoded)
            prior = p.map { PriorValue(key: $0.key, type: $0.type, value: $0.value.map { PathText.tildeValue($0, home: h) }) }
            revert = r.map(encoded)
        }
        return JournalPlan(direction: plan.direction, recipeID: plan.recipeID, recipeVersion: plan.recipeVersion, recipeName: plan.recipeName,
                           method: plan.method, risk: plan.risk, onDriveMissing: onDriveMissing,
                           macPath: h.isEmpty ? plan.macPath : PathText.tilde(plan.macPath, home: h), volume: volume,
                           relativePath: plan.destination.relativePath, defaultsDomain: domain, defaultsWrites: writes, defaultsPrior: prior,
                           defaultsRevert: revert, logicalBytes: plan.logicalBytes, fileCount: fileCount, groupID: plan.groupID,
                           consent: plan.consent)
    }

    private static func inferredHome(_ path: String) -> String {
        let c = PathNorm.components(path)
        if c.count >= 2, c[0] == "Users" { return "/Users/" + c[1] }
        return ""
    }

    /// Return to Mac: a new move in the other direction, from the copy on the drive to `<name>.returning-<id>` beside the original
    /// path, then swapped in. Only a confirmed move can return, and only from the drive it was moved to. The Mac layer fills
    /// `sourceStamp` and `sourceFingerprint` from a fresh walk of the drive copy before it journals the plan; `redirect` is the
    /// redirect being undone.
    public static func returnPlan(for record: RelocationRecord, drive: DriveFacts, home: String, now: Date, moveID: String) -> MovePlanResult {
        func refuse(_ reason: String) -> MovePlanResult { MovePlanResult(plan: nil, eligibility: nil, refusal: reason) }
        let homePath = PathNorm.normalize(home)
        guard record.canReturn else { return refuse("Only a confirmed move can come back to your Mac.") }
        guard let uuid = drive.uuid, uuid.uppercased() == record.volume.uuid.uppercased() else {
            return refuse("This isn't the drive the data was moved to.")
        }
        guard let token = drive.markerToken, token == record.volume.token, drive.hasOutboardMarker else {
            return refuse("This drive doesn't carry the mark Outboard left on it when it moved the data.")
        }
        guard !drive.isLocked else { return refuse("\(Eligibility.driveLabel(drive)) is locked.") }
        let mount = PathNorm.normalize(drive.mountPoint)
        guard RuleContext.isStandardMount(mount) else { return refuse("This drive is mounted in an unusual place.") }
        let macPath = PathNorm.normalize(PathText.expandTilde(record.macPath, home: homePath))
        guard PathNorm.isStrictlyUnder(macPath, homePath), NeverList.reason(forPath: macPath, home: homePath) == nil else {
            return refuse("The original location is not one Outboard works in.")
        }
        let relative = PathNorm.normalize(record.relativePath)
        let destination = PlanDestination(volumeUUID: record.volume.uuid, volumeName: drive.name, mountPoint: mount, volumeToken: record.volume.token,
                                          recipeFolder: PathNorm.parent(relative), leaf: PathNorm.leaf(relative))
        let redirect: RedirectPlan
        if let domain = record.defaultsDomain {
            redirect = .defaults(domain: domain, writes: record.defaultsWrites, prior: [], revert: record.defaultsRevert)
        } else {
            redirect = .symbolicLink(linkPath: macPath, target: destination.finalPath)
        }
        let plan = MovePlan(id: moveID, direction: .returnToMac, recipeID: record.recipeID, recipeVersion: record.recipeVersion,
                            recipeName: record.recipeName, method: record.method, risk: record.risk, sourcePath: destination.finalPath,
                            macPath: macPath, sourceStamp: FileStamp(device: 0, inode: 0, type: .directory),
                            sourceFingerprint: TreeFingerprint(files: record.fileCount, logicalBytes: record.logicalBytes),
                            destination: destination, redirect: redirect,
                            consent: ConsentRecord(recipeVersion: record.recipeVersion, tickedIDs: []), groupID: record.groupID, createdAt: now)
        return MovePlanResult(plan: plan, eligibility: nil, refusal: nil)
    }
}
