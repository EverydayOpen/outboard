import Darwin
import Foundation
import OutboardCore

/// The real `Backend` (BUILD_PLAN §5.10): it composes the Mac files and nothing else. Every path derives from the one injected
/// `home`; nothing is read from or written to anywhere that home does not lead to, except the drives the user chose.
public enum LiveBackend {
    public static func make(home: String, appVersion: String, policy: Policy = .release) -> Backend {
        let state = LiveState(home: home, appVersion: appVersion, policy: policy)
        return Backend(
            measure: { ids in await state.measure(ids) },
            volumes: { await DriveInspector.volumes(policy: policy) },
            eligibility: { volumeID, recipeID in await state.eligibility(volumeID, recipeID) },
            blockers: { id in state.blockers(id) },
            fullDiskAccess: { state.fullDiskAccess() },
            relocations: { state.refreshRecords() },
            leftovers: { state.leftovers() },
            loadLog: { Journal.loadAll(home: home) },
            diagnostics: { await state.diagnostics() },
            useDrive: { id in await state.useDrive(id) },
            plan: { recipeID, volumeID, consent in await state.plan(recipeID, volumeID, consent) },
            move: { plan, progress in await state.move(plan, progress) },
            confirm: { id in await state.act(.confirm, id) { record in Confirm.run(record, home: home) } },
            rollback: { id in await state.act(.rollback, id) { record in Rollback.run(record, home: home) } },
            returnToMac: { id, progress in
                await state.act(.returnToMac, id) { record in await MoveEngine.returnToMac(record, home: home, policy: policy, progress: progress) }
            },
            forget: { id in await state.act(.forget, id) { record in Rollback.forget(record, home: home) } },
            checkAndReconnect: { id, progress in
                let outcome = await Reconcile.checkAndReconnect(id, home: home, progress: progress)
                _ = state.refreshRecords()
                return outcome
            },
            setAsideAndReconnect: { id in
                let outcome = await Reconcile.setAsideAndReconnect(id, home: home)
                _ = state.refreshRecords()
                return outcome
            },
            trashLeftover: { id in
                let outcome = Leftovers.trash(id, home: home)
                _ = state.refreshRecords()
                return outcome
            },
            recordGuideViewed: { recipeID in
                if Journal.intent(.guideViewed, subject: .app, home: home, note: recipeID) {
                    Journal.result(.guideViewed, subject: .app, home: home, status: .ok, note: recipeID)
                }
            },
            reconcile: { trigger in await state.reconcile(trigger) },
            watch: { onTrigger in VolumeWatcher.start(hasRelocations: { state.hasWatched() }, onTrigger) },
            loginItemState: { LoginItem.state },
            setLoginItem: { enabled in LoginItem.set(enabled) },
            isDemo: false)
    }
}

/// What the live backend remembers between calls: the last sizes (for "Copy diagnostics" and the drive checks) and the folded
/// journal. Nothing here is written anywhere.
final class LiveState: @unchecked Sendable {
    let home: String
    let appVersion: String
    let policy: Policy
    private let lock = NSLock()
    private var lastScans: [SizeScan] = []
    private var records: [RelocationRecord]?

    /// Locks around a synchronous body (an `NSLock` is not used directly in an async function).
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    init(home: String, appVersion: String, policy: Policy) {
        self.home = home
        self.appVersion = appVersion
        self.policy = policy
    }

    // MARK: - The journal as records

    @discardableResult
    func refreshRecords() -> [RelocationRecord] {
        let folded = RelocationFold.records(from: Journal.loadAll(home: home), home: home)
        locked { records = folded }
        return folded
    }

    func hasWatched() -> Bool {
        let cached = locked { records }
        return !GuardPolicy.watched(cached ?? refreshRecords()).isEmpty
    }

    func leftovers() -> [Leftover] {
        let entries = Journal.loadAll(home: home)
        return RelocationFold.leftovers(from: entries, records: RelocationFold.records(from: entries, home: home))
    }

    // MARK: - Measuring and judging drives

    func measure(_ ids: [RecipeID]) async -> [SizeScan] {
        let recipes = ids.isEmpty ? Catalogue.all : ids.compactMap { Catalogue.recipe($0) }
        let home = self.home
        let scans = await Task.detached(priority: .userInitiated) {
            SizeScanner.measure(recipes, home: home, now: Date(), redirected: { LiveState.redirectTarget(of: $0, home: home) })
        }.value
        locked {
            let kept = lastScans.filter { old in !scans.contains { $0.recipeID == old.recipeID && $0.path == old.path } }
            lastScans = kept + scans
        }
        return scans
    }

    /// Where a `defaults` recipe's setting already points, if it points anywhere (then the default folder is not offered).
    static func redirectTarget(of recipe: Recipe, home: String) -> String? {
        guard case .defaults(let domain, let keys, _) = recipe.method,
              let key = keys.first(where: { $0.value == .destinationPath }) else { return nil }
        guard case .some(.some(let value)) = DefaultsRedirect.currentValue(domain: domain, key: key.name, type: key.type), !value.isEmpty,
              DefaultsRedirect.isRedirected(recipe, home: home, read: { DefaultsRedirect.currentValue(domain: domain, key: $0.name, type: $0.type) }) else { return nil }
        return value
    }

    /// What the folder needs from a destination, from its measured scans (all parts of the recipe together).
    func sourceNeeds(_ scans: [SizeScan]) -> SourceNeeds? {
        let measured = scans.filter { $0.state == .measured }
        guard !measured.isEmpty else { return nil }
        let bytes = measured.reduce(UInt64(0)) { $0 + $1.fingerprint.logicalBytes }
        return SourceNeeds(logicalBytes: bytes, isCaseSensitive: DriveInspector.caseSensitivity(ofPath: home),
                           hasHardLinks: measured.contains { $0.fingerprint.hardLinkedFiles > 0 },
                           hasSymlinks: measured.contains { $0.fingerprint.symlinks > 0 })
    }

    func eligibility(_ volumeID: String, _ recipeID: RecipeID?) async -> EligibilityReport {
        guard let facts = await DriveInspector.facts(forVolumeID: volumeID) else {
            return EligibilityReport(volumeID: volumeID, recipeID: recipeID,
                                     verdicts: [EligibilityVerdict(rule: .e18, outcome: .refuse, message: Say.driveGone)])
        }
        let recipe = recipeID.flatMap { Catalogue.recipe($0) }
        var needs: SourceNeeds?
        if let recipe, recipe.isAutomated {
            needs = sourceNeeds(await measure([recipe.id]))
        }
        return Eligibility.evaluate(volume: facts, recipe: recipe, source: needs, policy: policy)
    }

    func blockers(_ id: RecipeID) -> [Blocker] {
        guard let recipe = Catalogue.recipe(id) else { return [] }
        return RunningCheck.blockers(recipe: recipe, snapshot: RunningApps.snapshot(for: recipe, home: home, includeHandles: false))
    }

    /// Full Disk Access as far as one `opendir` on a folder macOS protects can tell. Nothing is listed or read.
    func fullDiskAccess() -> Tri {
        switch Fs.openDirectoryErrno(home + "/Library/Safari") {
        case 0: return .yes
        case EPERM, EACCES: return .no
        default: return .unknown
        }
    }

    func diagnostics() async -> String {
        let volumes = await DriveInspector.volumes(policy: policy)
        let scans = locked { lastScans }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        return DiagnosticsText.text(volumes: volumes, scans: scans, osVersion: os, appVersion: appVersion)
    }

    // MARK: - Writes

    func useDrive(_ volumeID: String) async -> UseDriveResult {
        guard let facts = await DriveInspector.facts(forVolumeID: volumeID) else { return UseDriveResult(ok: false, message: Say.driveGone) }
        let report = Eligibility.evaluate(volume: facts, recipe: nil, source: nil, policy: policy)
        guard report.isAllowed else {
            return UseDriveResult(ok: false, message: report.firstRefusal?.message ?? "This drive can't be used.", facts: facts)
        }
        guard MutationGate.tryEnter() else { return UseDriveResult(ok: false, message: Say.busy, facts: facts) }
        defer { MutationGate.leave() }
        guard Journal.intent(.useDrive, subject: .app, home: home, vol: facts.uuid, volName: facts.name, fsName: facts.fileSystem.displayName) else {
            return UseDriveResult(ok: false, message: Say.journalBlocked, facts: facts)
        }
        let result = OutboardRoot.useDrive(facts, appVersion: appVersion, now: Date())
        Journal.result(.useDrive, subject: .app, home: home, status: result.ok ? .ok : .failed, vol: facts.uuid, volName: facts.name,
                       fsName: facts.fileSystem.displayName)
        let fresh = result.ok ? await DriveInspector.facts(forVolumeID: volumeID) : facts
        return UseDriveResult(ok: result.ok, message: result.message, facts: fresh ?? facts)
    }

    /// The current value of each key of a `defaults` recipe, read-only. nil = a key could not be read (the plan then refuses).
    private func priorValues(_ recipe: Recipe) -> [PriorValue]? {
        guard case .defaults(let domain, let keys, _) = recipe.method else { return [] }
        var out: [PriorValue] = []
        for key in keys {
            guard let value = DefaultsRedirect.currentValue(domain: domain, key: key.name, type: key.type) else { return nil }
            out.append(PriorValue(key: key.name, type: key.type, value: value))
        }
        return out
    }

    func plan(_ recipeID: RecipeID, _ volumeID: String, _ consent: ConsentRecord) async -> MovePlanResult {
        func refuse(_ why: String, _ report: EligibilityReport? = nil) -> MovePlanResult { MovePlanResult(plan: nil, eligibility: report, refusal: why) }
        guard let recipe = Catalogue.recipe(recipeID), recipe.isAutomated else { return refuse("Outboard doesn't move this itself. Use the steps on its card.") }
        guard let drive = await DriveInspector.facts(forVolumeID: volumeID) else { return refuse(Say.driveGone) }
        let scans = await measure([recipeID])
        guard let primary = scans.first(where: { $0.path == recipe.source }) else { return refuse("This folder isn't on this Mac.") }
        let report = Eligibility.evaluate(volume: drive, recipe: recipe, source: sourceNeeds(scans), policy: policy)
        guard let prior = priorValues(recipe) else {
            return refuse("Outboard couldn't read the current value of the app's setting, so it can't put it back.", report)
        }
        var prefs = Preferences()
        prefs.showUnverifiedMoves = consent.sawUnverifiedNote
        let id = MovePlanner.newMoveID(now: Date(), random: UInt32.random(in: 0...0xFF_FFFF))
        return MovePlanner.plan(recipe: recipe, folder: primary, drive: drive, report: report, consent: consent, prior: prior, home: home, now: Date(),
                                moveID: id, groupID: recipe.companionSources.isEmpty ? nil : id, policy: policy, prefs: prefs)
    }

    /// The move, and for a recipe with a companion folder (Hugging Face's `xet`) a move of each companion that is on this Mac, in turn,
    /// under the same consent. A companion that cannot be moved leaves the first move as it is and says so.
    func move(_ plan: MovePlan, _ progress: @escaping @Sendable (MoveProgress) -> Void) async -> MoveOutcome {
        var outcome = await MoveEngine.run(plan, home: home, policy: policy, progress: progress)
        refreshRecords()
        guard outcome.ok, plan.groupID == plan.id, let recipe = Catalogue.recipe(plan.recipeID), !recipe.companionSources.isEmpty,
              let prior = priorValues(recipe) else { return outcome }
        let scans = await measure([recipe.id])
        for rel in recipe.companionSources {
            guard let scan = scans.first(where: { $0.path == rel }), scan.state == .measured, !scan.isLink else { continue }
            guard let drive = await DriveInspector.facts(forVolumeID: plan.destination.volumeUUID) else { break }
            let report = Eligibility.evaluate(volume: drive, recipe: recipe, source: sourceNeeds([scan]), policy: policy)
            var prefs = Preferences()
            prefs.showUnverifiedMoves = plan.consent.sawUnverifiedNote
            let id = MovePlanner.newMoveID(now: Date(), random: UInt32.random(in: 0...0xFF_FFFF))
            let planned = MovePlanner.plan(recipe: recipe, folder: scan, drive: drive, report: report, consent: plan.consent, prior: prior, home: home,
                                           now: Date(), moveID: id, groupID: plan.groupID, policy: policy, prefs: prefs)
            guard let next = planned.plan else {
                outcome.message += " The companion folder \(Fs.leaf(of: rel)) was not moved: " + (planned.refusal ?? "a rule said no.")
                break
            }
            let more = await MoveEngine.run(next, home: home, policy: policy, progress: progress)
            refreshRecords()
            if !more.ok {
                outcome.ok = false
                outcome.message += " The companion folder \(Fs.leaf(of: rel)) was not moved: " + more.message
                break
            }
        }
        return outcome
    }

    /// Runs a user action on a record, then on the other records of its group (the companions of one recipe) that are in the same
    /// state. A failure in a sibling is added to the message; the requested record's outcome is the one returned.
    func act(_ kind: MoveActionKind, _ moveID: String, _ action: (RelocationRecord) async -> MoveOutcome) async -> MoveOutcome {
        let all = refreshRecords()
        guard let record = all.first(where: { $0.id == moveID }) else {
            return MoveOutcome(action: kind, moveID: moveID, state: .aborted, ok: false, message: "Outboard has no record of that move.")
        }
        var outcome = await action(record)
        if let group = record.groupID {
            for sibling in all where sibling.groupID == group && sibling.id != record.id && sibling.state == record.state {
                let more = await action(sibling)
                if !more.ok {
                    outcome.ok = false
                    outcome.message += " " + sibling.recipeName + " (" + Fs.leaf(of: sibling.macPath) + "): " + more.message
                }
            }
        }
        refreshRecords()
        return outcome
    }

    // MARK: - The guard

    func reconcile(_ trigger: ReconcileTrigger) async -> GuardSnapshot {
        let home = self.home
        if trigger == .launch || trigger == .mount {
            // Before any window shows anything: finish or label what a crash left half done.
            _ = await Task.detached(priority: .userInitiated) { Recover.run(home: home) }.value
        }
        let snapshot = await Reconcile.run(trigger, home: home)
        refreshRecords()
        return snapshot
    }
}
