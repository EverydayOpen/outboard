import AppKit
import OutboardCore
import OutboardMac
import SwiftUI

/// The single source of truth (BUILD_PLAN §7). Core makes the plan, the cards and the text; the backend reads and moves; the
/// views read this from the environment. Every state and count shown comes from `StoragePlan`, `RelocationRecord` (folded from
/// the journal by Core) and the derived `GuardSnapshot` (invariant I10). The only file with UserDefaults and the Finder and
/// System Settings bridge, with `OutboardApp` and `Links` (safety_greps G8, G9). Written, not compiled.
@MainActor final class AppModel: ObservableObject {
    enum Screen: Hashable { case plan, drives, activity, about }

    enum Phase: Equatable {
        case idle
        /// "Measuring the big folders": by folder, never a percentage.
        case measuring
        /// The consent sheet.
        case consenting(recipeID: RecipeID, volumeID: String)
        /// Copying, comparing or switching (or returning, or checking after an unclean removal): bytes and elapsed time, no estimate.
        case running(MoveProgress)
        /// "The move is ready. Open Xcode and check your data."
        case tryAndConfirm(moveID: String)
        /// The outcome of the last action, until the person dismisses it.
        case result(MoveOutcome)
    }

    /// `LiveBackend.make(...)`, or the scenario's backend in a DEBUG demo launch (App/Demo.swift).
    let backend: Backend
    /// Always `Policy.release`: a demo launch shows unverified moves with the preference on, so its sheets carry the note.
    let policy: Policy
    let macOS: MinOS
    /// "/Users/jane" in sample data, else the real home. Expands `~` in the journal's paths and in Finder requests.
    let homePath: String
    let appVersion: String

    @Published var screen: Screen = .plan { didSet { screenChanged(from: oldValue) } }
    /// nil until the first measurement.
    @Published private(set) var plan: StoragePlan?
    @Published private(set) var volumes: [DriveFacts] = []
    @Published private(set) var relocations: [RelocationRecord] = [] { didSet { keepRunningChanged() } }
    @Published private(set) var leftovers: [Leftover] = []
    /// The journal rendered by Core `ActivityText`, oldest first (the journal's own order; the Activity screen shows it newest
    /// first). Views filter (`tone == .problem`); nothing here is edited.
    @Published private(set) var log: [ActivityEntry] = []
    /// Assigned ONLY when it changed (Equatable, no timestamps), so a timer tick that finds nothing new re-renders nothing.
    @Published private(set) var guardSnapshot = GuardSnapshot.empty
    @Published private(set) var phase: Phase = .idle { didSet { busyChanged() } }
    /// Which action `phase` (running or result) belongs to, so a sheet can say "Copying", "Returning" or "Checking".
    @Published private(set) var activeAction: MoveActionKind = .move
    /// A quick action (confirm, roll back, forget, trash a leftover, use a drive) is in flight: one mutation at a time (I5).
    @Published private(set) var actionInFlight = false { didSet { busyChanged() } }
    @Published private(set) var loginItem: LoginItemState = .notRegistered
    @Published private(set) var fullDiskAccess: Tri = .unknown
    /// False until `start()` has read the journal and made the guard's first pass; RootView covers the window until then.
    @Published private(set) var isReady = false
    /// Bumped when an app launches or quits, so every view that shows `blockers(for:)` is drawn again and reads them fresh. No polling.
    @Published private(set) var blockersEpoch = 0
    /// Persisted as one JSON blob (never in demo mode). The MenuBarExtra never binds to it directly.
    @Published var prefs: Preferences { didSet { prefsChanged(from: oldValue) } }

    // Sheets and flags the views and App/Demo.swift set. RootView presents them, one at a time.
    @Published var showPreferences = false
    /// The Export sheet (Markdown or JSON through a save panel).
    @Published var showReport = false
    /// First-run cards reopened from Help; the first run itself is `!prefs.hasSeenFirstRun`.
    @Published var showFirstRun = false
    /// The Confirm dialog on the Try-it-and-confirm sheet.
    @Published var showConfirmDialog = false
    /// The guided card sheet.
    @Published var guideRecipeID: RecipeID?
    /// A one-line message in a pill over the window ("Diagnostics copied."). Clears itself.
    @Published var notice: String?

    private var scans: [SizeScan] = []
    private var measuredAt = Date()
    private var hasMeasured = false
    private var journal: [JournalEntry] = []
    private var startTask: Task<Void, Never>?
    private var moveTask: Task<MoveOutcome, Never>?
    private var cancelWatch: (@Sendable () -> Void)?
    private var watchers: [NSObjectProtocol] = []
    private var reconciling = false
    private var pendingTrigger: ReconcileTrigger?

    private static let prefsKey = "outboard.preferences"

    init() {
        #if DEBUG
        let demo = Demo.backend   // non-nil only for a demo launch (App/Demo.swift)
        #else
        let demo: Backend? = nil
        #endif
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let home = demo == nil ? FileManager.default.homeDirectoryForCurrentUser.path : DemoScenarios.home
        self.homePath = home
        self.appVersion = version
        self.macOS = demo == nil ? MinOS(system.majorVersion, system.minorVersion) : DemoScenarios.macOS
        self.policy = Policy.release
        self.backend = demo ?? LiveBackend.make(home: home, appVersion: version)
        self.prefs = demo == nil ? Self.storedPrefs() : Preferences()
        #if DEBUG
        Demo.start(self)
        #endif
    }

    // MARK: - Derived state

    var isDemo: Bool { backend.isDemo }

    /// Something is being changed or measured: buttons that start another thing are disabled, menus wait.
    var isBusy: Bool {
        if actionInFlight { return true }
        switch phase {
        case .measuring, .running: return true
        default: return false
        }
    }

    /// Any sheet is up; the menu's navigation items wait while one is open.
    var sheetOpen: Bool {
        if !prefs.hasSeenFirstRun || showFirstRun || showPreferences || showReport || guideRecipeID != nil { return true }
        switch phase {
        case .idle, .measuring: return false
        default: return true
        }
    }

    /// The folders the guard watches: the redirect is in place (swapped, confirmed, original trashed).
    var activeRelocations: [RelocationRecord] { relocations.filter { $0.isWatchedByGuard } }

    /// The menu bar item exists once any relocation does, and closing the window keeps Outboard running while it does and the
    /// preference is on.
    var hasRelocations: Bool { relocations.contains { $0.isWatchedByGuard } }

    /// Bytes moved to drives by the active relocations (`RelocationRecord.logicalBytes`).
    var movedBytes: UInt64 { activeRelocations.filter { $0.direction == .toDrive }.reduce(UInt64(0)) { $0 &+ $1.logicalBytes } }

    /// How many moved folders are not Healthy (the Drives row's badge). Zero when nothing is watched.
    var attentionCount: Int { guardSnapshot.relocations.filter { $0.health != .healthy }.count }

    /// The guard's health for one moved folder, or nil before the first pass has seen it.
    func health(of moveID: String) -> RelocationHealth? { guardSnapshot.relocations.first { $0.moveID == moveID } }

    /// The Storage Plan card, from the plan, the relocations and the preferences. nil before the first measurement.
    var planCard: StoragePlanCard? {
        plan.map { StoragePlanText.card(from: $0, relocations: relocations, prefs: prefs, isSample: isDemo) }
    }

    /// The lamp is lit while every moved folder is Healthy (and also with nothing to watch). Dimmed while anything is away or held.
    var guardLit: Bool { guardSnapshot.isAllHealthy }

    /// The words beside the lamp (DESIGN §6.5): "Guard on · nothing moved yet" / "Guard on · drive attached" / "Guard on ·
    /// drive away" / "Guard on · needs a look". Outboard's guard runs while the app does, so it is never "off" while this shows.
    var guardLabel: String {
        let rows = guardSnapshot.relocations
        if rows.isEmpty { return "Guard on \u{00B7} nothing moved yet" }
        if rows.allSatisfy({ $0.health == .healthy }) { return "Guard on \u{00B7} drive attached" }
        if rows.contains(where: { $0.health == .driveAway }) { return "Guard on \u{00B7} drive away" }
        return "Guard on \u{00B7} needs a look"
    }

    /// Under the lamp when closing the window would stop the guard: Education's quit sentence, said only when it applies.
    var guardNote: String? {
        prefs.keepGuardRunning || !hasRelocations ? nil : "Outboard quits when the window closes, so nothing would watch your drives."
    }

    /// The menu bar item's status line and accessibility label: "Outboard: 1 drive away, 2 held". Derived, never stored.
    var menuStatus: String {
        let rows = guardSnapshot.relocations
        if rows.isEmpty { return "Outboard: nothing moved yet" }
        let away = Health.allCases.filter { $0 != .healthy }.compactMap { health -> String? in
            let n = rows.filter { $0.health == health }.count
            return n == 0 ? nil : "\(n) \(health.displayName.lowercased())"
        }
        return away.isEmpty ? "Outboard: \(Format.count(rows.count, "moved folder")), all Healthy" : "Outboard: " + away.joined(separator: ", ")
    }

    func recipe(_ id: RecipeID) -> Recipe? { Catalogue.recipe(id) }
    func planItem(_ id: RecipeID) -> PlanItem? { plan?.items.first { $0.recipeID == id } }
    func drive(_ volumeID: String) -> DriveFacts? { volumes.first { $0.id == volumeID } }
    func drive(for record: RelocationRecord) -> DriveFacts? { volumes.first { $0.uuid == record.volume.uuid } }

    /// One scan standing for the recipe's folders together (the consent sheet shows the sum). nil when none was found.
    func mergedScan(for id: RecipeID) -> SizeScan? {
        planItem(id).flatMap { SizeScan.merged($0.scans.filter { $0.state != .absent }) }
    }

    /// Not yet tried on a real Mac: the consent sheet then carries `Names.notTriedMarker` (flag-driven, never baked in).
    func isUnverified(_ recipe: Recipe) -> Bool { Catalogue.isUnverified(recipe, policy: policy) }

    private var clock: Date { isDemo ? DemoScenarios.referenceNow : Date() }

    // MARK: - Start

    /// Once per launch; a second caller waits for the first. Reads the journal, makes the guard's first pass (recovery runs
    /// there, before any window content is trusted) and, once the first-run cards have been passed, measures.
    func start() async {
        if let task = startTask {
            await task.value
            return
        }
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
    }

    private func performStart() async {
        watchApps()
        AppDelegate.onQuitBlocked = { [weak self] in self?.post("Outboard is finishing a step. Quit again in a moment.") }
        let backend = self.backend
        let snapshot = await backend.reconcile(.launch)
        await reloadRecords()
        await reloadVolumes()
        adopt(snapshot)
        loginItem = backend.loginItemState()
        startWatching()
        isReady = true
        if prefs.hasSeenFirstRun, plan == nil { await rescan() }
    }

    /// The volume watcher's triggers (mount, unmount, rename, wake, the 10 s timer while any relocation exists) arrive here.
    private func startWatching() {
        cancelWatch = backend.watch { [weak self] trigger in
            Task { @MainActor in await self?.handle(trigger) }
        }
    }

    // MARK: - Measuring

    /// ⌘R. Measure the catalogue's folders again (`lstat` only; never reads contents).
    func rescan() async {
        guard phase == .idle, !actionInFlight else { return }
        phase = .measuring
        announce("Measuring the big folders.")
        await measure()
        phase = .idle
    }

    private func measure() async {
        let backend = self.backend
        let ids = Catalogue.all.filter { $0.kind != .never }.map(\.id)
        scans = await backend.measure(ids)
        measuredAt = clock
        hasMeasured = true
        fullDiskAccess = backend.fullDiskAccess()
        rebuildPlan()
    }

    /// The plan from the scans in hand and the current preferences; a preference change rebuilds it without measuring again.
    private func rebuildPlan() {
        guard hasMeasured else { return }
        let built = StoragePlanBuilder.build(recipes: Catalogue.all, scans: scans, prefs: prefs, policy: policy, macOS: macOS, now: measuredAt)
        if built != plan { plan = built }
    }

    // MARK: - Drives

    func eligibility(volumeID: String, recipeID: RecipeID?) async -> EligibilityReport {
        await backend.eligibility(volumeID, recipeID)
    }

    /// "Use this drive": writes only the marker file (a UUID-mounted check first). Remembers the choice.
    func useDrive(_ volumeID: String) async {
        guard !isBusy else { return }
        actionInFlight = true
        let result = await backend.useDrive(volumeID)
        if result.ok, let uuid = drive(volumeID)?.uuid { prefs.preferredVolumeUUID = uuid }
        await reloadVolumes()
        actionInFlight = false
        post(result.message)
    }

    private func reloadVolumes() async {
        let found = await backend.volumes()
        if found != volumes { volumes = found }
    }

    // MARK: - Moving

    /// Opens the consent sheet for a recipe and the drive the person chose (the Plan's drive chooser calls this). The sheet reads
    /// `blockers(for:)`, `eligibility(volumeID:recipeID:)`, `mergedScan(for:)` and `isUnverified(_:)`.
    func beginConsent(recipeID: RecipeID, volumeID: String) {
        guard phase == .idle, !actionInFlight, let recipe = Catalogue.recipe(recipeID), recipe.isAutomated else { return }
        phase = .consenting(recipeID: recipeID, volumeID: volumeID)
        announce("Move \(recipe.name)?")
    }

    func cancelConsent() {
        guard case .consenting = phase, !actionInFlight else { return }
        phase = .idle
    }

    /// The "Before you start" rows, read fresh from the backend each time a view asks (an unreadable list is a row that blocks).
    /// Views that show them depend on `blockersEpoch`, which changes when an app launches or quits.
    func blockers(for recipeID: RecipeID) -> [Blocker] {
        _ = blockersEpoch
        return backend.blockers(recipeID)
    }

    /// backend.plan, then backend.move with polled progress, then "ready to confirm" or the outcome. One mutation in flight.
    /// Returns when the move has finished (a frozen demo scenario returns only if the move is stopped).
    func startMove(recipeID: RecipeID, volumeID: String, consent: ConsentRecord) async {
        guard case .consenting = phase, !actionInFlight else { return }
        actionInFlight = true
        activeAction = .move
        let backend = self.backend
        let result = await backend.plan(recipeID, volumeID, consent)
        guard let movePlan = result.plan else {
            actionInFlight = false
            phase = .result(MoveOutcome(action: .move, moveID: "", state: .aborted, ok: false, abort: .preflightFailed,
                                        message: result.refusal ?? "Outboard couldn't plan this move. Nothing was changed."))
            return
        }
        phase = .running(MoveProgress(moveID: movePlan.id, phase: .preflight))
        announce("Moving \(movePlan.recipeName).")
        let task = Task { await backend.move(movePlan) { [weak self] progress in Task { @MainActor in self?.noteProgress(progress) } } }
        moveTask = task
        let outcome = await task.value
        moveTask = nil
        await reloadAfterAction()
        actionInFlight = false
        if outcome.ok, outcome.state == .swapped {
            phase = .tryAndConfirm(moveID: outcome.moveID)
            announce("The move is ready. Open the app and check your data.")
        } else {
            phase = .result(outcome)
            announce(outcome.message)
        }
        Task { await self.measure() }
    }

    /// "Stop" while copying or comparing. Cancels the task that runs the move; the engine ends at its next check with nothing on
    /// the Mac changed (VERIFY that the live engine looks at `Task.isCancelled` between files).
    func stopMove() {
        guard case .running(let progress) = phase, progress.phase == .copying || progress.phase == .verifying || progress.phase == .preflight else { return }
        moveTask?.cancel()
    }

    /// "Done" on a result, and "Not yet" on the Try-it-and-confirm sheet: the move then stays Ready to confirm (the Drives row
    /// offers Confirm… and Roll back… later). Nothing else closes these two.
    func dismissResult() {
        switch phase {
        case .result, .tryAndConfirm:
            showConfirmDialog = false
            phase = .idle
        default: break
        }
    }

    /// A polled value, shown as it is. When the step changes (or the move is new to the list) the records are read again, so the
    /// sheet names the folder and the drive and the state word is the journal's.
    private func noteProgress(_ progress: MoveProgress) {
        guard case .running(let current) = phase, progress != current else { return }
        phase = .running(progress)
        if progress.phase != current.phase || !relocations.contains(where: { $0.id == progress.moveID }) { Task { await self.reloadRecords() } }
    }

    // MARK: - What the person decides

    /// "Confirm and move to Trash": records the decision, then trashes `<name>.before-move`. The space comes back when the
    /// Trash is emptied.
    func confirm(moveID: String) async {
        guard beginAction(.confirm) else { return }
        let outcome = await backend.confirm(moveID)
        await finish(outcome)
    }

    func rollback(moveID: String) async {
        guard beginAction(.rollback) else { return }
        let outcome = await backend.rollback(moveID)
        await finish(outcome)
    }

    func forget(moveID: String) async {
        guard beginAction(.forget) else { return }
        let outcome = await backend.forget(moveID)
        await finish(outcome)
    }

    func setAsideAndReconnect(moveID: String) async {
        guard beginAction(.setAsideAndReconnect) else { return }
        let outcome = await backend.setAsideAndReconnect(moveID)
        await finish(outcome)
    }

    func trashLeftover(_ id: String) async {
        guard beginAction(.trashLeftover) else { return }
        let outcome = await backend.trashLeftover(id)
        await finish(outcome)
    }

    /// Return to Mac: a verified copy back, the drive copy kept. Shows the progress sheet.
    func returnToMac(moveID: String) async {
        guard beginAction(.returnToMac) else { return }
        phase = .running(MoveProgress(moveID: moveID, phase: .preflight))
        let backend = self.backend
        let outcome = await backend.returnToMac(moveID) { [weak self] progress in Task { @MainActor in self?.noteProgress(progress) } }
        await finish(outcome)
    }

    /// After an unclean removal: hash every file that has not changed since it was copied, then reconnect.
    func checkAndReconnect(moveID: String) async {
        guard beginAction(.checkAndReconnect) else { return }
        phase = .running(MoveProgress(moveID: moveID, phase: .verifying))
        let backend = self.backend
        let outcome = await backend.checkAndReconnect(moveID) { [weak self] progress in Task { @MainActor in self?.noteProgress(progress) } }
        await finish(outcome)
    }

    private func beginAction(_ kind: MoveActionKind) -> Bool {
        guard !isBusy else { return false }
        actionInFlight = true
        activeAction = kind
        showConfirmDialog = false
        return true
    }

    private func finish(_ outcome: MoveOutcome) async {
        await reloadAfterAction()
        actionInFlight = false
        phase = .result(outcome)
        announce(outcome.message)
        Task { await self.measure() }
    }

    /// Records, leftovers, drives and the guard's snapshot after something changed, so the screens agree at once.
    private func reloadAfterAction() async {
        await reloadRecords()
        await reloadVolumes()
        adopt(await backend.reconcile(.manual))
    }

    // MARK: - The guard

    /// One trigger, one idempotent pass; a trigger that arrives during a pass is run right after it (a mount is never dropped,
    /// a timer tick may be). Triggers are advisory: a missed one costs seconds, not correctness.
    func handle(_ trigger: ReconcileTrigger) async {
        if reconciling {
            if trigger != .timer || pendingTrigger == nil { pendingTrigger = trigger }
            return
        }
        if trigger == .timer, actionInFlight { return }
        reconciling = true
        var next: ReconcileTrigger? = trigger
        while let current = next {
            pendingTrigger = nil
            let snapshot = await backend.reconcile(current)
            if current != .timer { await reloadVolumes() }
            await reloadRecords()
            adopt(snapshot)
            next = pendingTrigger
        }
        reconciling = false
    }

    /// Assigns the snapshot only when it changed, and tells VoiceOver about a banner that is new.
    private func adopt(_ snapshot: GuardSnapshot) {
        guard snapshot != guardSnapshot else { return }
        let known = Set(guardSnapshot.banners.map(\.id))
        guardSnapshot = snapshot
        if let fresh = snapshot.banners.first(where: { !known.contains($0.id) }) { announce(fresh.text) }
    }

    /// Records, leftovers and the rendered log from the backend, off the main thread, assigned only when they changed.
    private func reloadRecords() async {
        let backend = self.backend
        let read = await Task.detached { () -> ([RelocationRecord], [Leftover], [JournalEntry], [ActivityEntry]) in
            let entries = backend.loadLog()
            return (backend.relocations(), backend.leftovers(), entries, ActivityText.rows(from: entries, problemsOnly: false))
        }.value
        if read.0 != relocations { relocations = read.0 }
        if read.1 != leftovers { leftovers = read.1 }
        if read.2 != journal {
            journal = read.2
            log = read.3
        }
    }

    // MARK: - Running apps

    /// An app starting or quitting changes the "Before you start" rows. No polling: the workspace tells us (BUILD_PLAN §7).
    private func watchApps() {
        guard !isDemo, watchers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            watchers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.blockersEpoch &+= 1 }
            })
        }
    }

    // MARK: - Guided cards

    /// "Show steps": opens the guided card. Moves nothing and writes nothing.
    func showGuide(recipeID: RecipeID) { guideRecipeID = recipeID }

    /// The card's "Open <App>": the journal records that the guide was viewed (its one line), then the vendor's own app opens.
    /// Moves nothing.
    func openGuide(recipeID: RecipeID) {
        let backend = self.backend
        Task.detached { backend.recordGuideViewed(recipeID) }
        guard let bundleID = Catalogue.recipe(recipeID)?.launchBundleID else { return }
        openApp(bundleID: bundleID)
    }

    // MARK: - Finder, System Settings, links, the pasteboard

    /// Opens an app by bundle identifier, only on a click.
    func openApp(bundleID: String) {
        guard !isDemo else {
            post("This is sample data, so no app is opened.")
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            post("That app isn't installed on this Mac.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    /// Shows a folder in Finder. `path` is `~`-relative (a record's `macPath`) or absolute (a folder on a drive).
    func reveal(_ path: String) {
        guard !isDemo else {
            post("This is sample data, so there is nothing to show in Finder.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: PathText.expandTilde(path, home: homePath))])
    }

    /// "Show on drive" for a moved folder; says so when the drive is not connected.
    func revealOnDrive(_ record: RelocationRecord) {
        guard let mount = drive(for: record)?.mountPoint else {
            post("\(record.volume.label) isn't connected.")
            return
        }
        reveal(mount + "/" + record.relativePath)
    }

    /// Shows the newest journal file in Finder (its folder if there is none yet).
    func revealLog() {
        guard !isDemo else {
            post("The sample activity log lives in memory.")
            return
        }
        let folder = URL(fileURLWithPath: homePath + "/Library/Application Support/" + Names.supportFolder, isDirectory: true)
        let file = folder.appendingPathComponent(ActivityLog.fileName(for: Date()))
        if !NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: folder.path), !NSWorkspace.shared.open(folder) {
            NSSound.beep()
        }
    }

    func openFullDiskAccessSettings() { openSettingsPane(Links.fullDiskAccess) }
    /// For a drive macOS will not let Outboard read: the Privacy & Security pane (VERIFY the Removable Volumes route; text steps
    /// always sit beside the button).
    func openPrivacySettings() { openSettingsPane(Links.fullDiskAccess) }
    func openLoginItemsSettings() { openSettingsPane(Links.loginItems) }
    func openDiskUtility() { openApp(bundleID: "com.apple.DiskUtility") }   // VERIFY the bundle identifier

    private func openSettingsPane(_ link: String) {
        guard !isDemo else {
            post("This is sample data, so System Settings stays closed.")
            return
        }
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    /// Opens a link in the browser, only on a click (the app makes no connections of its own).
    func openLink(_ url: URL) { NSWorkspace.shared.open(url) }
    func openWebsite() { openLink(Links.website) }
    func openReleases() { openLink(Links.releases) }
    func openIssues() { openLink(Links.issues) }
    func openDiskUtilityGuide() { openLink(Links.diskUtilityGuide) }

    func copyPath(_ path: String) { copyToPasteboard(PathText.expandTilde(path, home: homePath)) }

    /// "Copy as Text": the card's one-line text.
    func copyCardText() {
        guard let card = planCard else { return }
        Export.run(.cardText, card: card)
        post("Card text copied.")
    }

    /// "Copy as Image": the card as PNG and TIFF; the text version if it could not be drawn.
    func copyCardImage() {
        guard let card = planCard else { return }
        post(Export.copyImage(card) ? "Card copied as an image." : "The card couldn't be drawn, so its text was copied.")
    }

    /// "Save PNG…": a save panel for the 1200 px card.
    func saveCardPNG() {
        guard let card = planCard else { return }
        Export.run(.cardPNG, card: card)
    }

    /// Everything in the report, from the records and the journal as the screens show them. `hidePaths` swaps folder paths for
    /// recipe names. Nothing is written until a save panel says where.
    func reportDocument(hidePaths: Bool) -> ReportDocument {
        let options = ReportOptions(hidePaths: hidePaths, appVersion: appVersion, macOSVersion: osVersionText, macModel: nil, now: clock, isSample: isDemo)
        let words = Dictionary(guardSnapshot.relocations.map { ($0.moveID, $0.health) }, uniquingKeysWith: { first, _ in first })
        return ReportText.document(records: relocations, log: journal, drives: volumes, options: options, health: words)
    }

    /// The report as Markdown or JSON through a save panel (`hideFolderPathsInExports` decides about paths), or the card as a PNG.
    func exportReport(format: ExportFormat) {
        switch format {
        case .markdown, .json:
            Export.run(format, report: reportDocument(hidePaths: prefs.hideFolderPathsInExports))
        case .cardPNG, .cardText:
            guard let card = planCard else {
                NSSound.beep()
                return
            }
            Export.run(format, card: card)
        }
    }

    /// For testers (Help > Copy Diagnostics): the eligibility signals per drive and the errno matrix per measured folder. No file names.
    func copyDiagnostics() async {
        let text = await backend.diagnostics()
        copyToPasteboard(text)
        post("Diagnostics copied.")
    }

    private var osVersionText: String {
        if isDemo { return DemoScenarios.osVersion }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: - Login item and first run

    /// The answer to "Start Outboard at login" (offered on the first move): `SMAppService.mainApp` only, state reported plainly.
    func setLoginItem(_ on: Bool) {
        loginItem = backend.setLoginItem(on)
        prefs.startAtLogin = on
        prefs.hasAnsweredLoginItem = true
    }

    /// Done on the last first-run card (and on the cards reopened from Help).
    func finishFirstRun() {
        showFirstRun = false
        if !prefs.hasSeenFirstRun { prefs.hasSeenFirstRun = true }
    }

    // MARK: - Notices and VoiceOver

    /// A one-line message that clears itself after a few seconds.
    func post(_ text: String) {
        notice = text
        announce(text)
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if notice == text { notice = nil }
        }
    }

    /// The spinner and the sheets have no text of their own, so VoiceOver hears the outcome.
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Observers

    private func screenChanged(from old: Screen) {
        guard screen != old, isReady else { return }
        switch screen {
        case .drives: Task { await self.reloadVolumes() }
        case .activity: Task { await self.reloadRecords() }
        default: break
        }
    }

    private static func storedPrefs() -> Preferences {
        guard let data = UserDefaults.standard.data(forKey: prefsKey),
              let stored = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return stored
    }

    private func prefsChanged(from old: Preferences) {
        if !backend.isDemo, let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data, forKey: Self.prefsKey) }
        keepRunningChanged()
        if old.showUnverifiedMoves != prefs.showUnverifiedMoves { rebuildPlan() }
        // Nothing is measured before the first-run cards have been passed ("it looks first"); passing them measures once.
        if !old.hasSeenFirstRun, prefs.hasSeenFirstRun, isReady, plan == nil { Task { await self.rescan() } }
    }

    /// Closing the window keeps Outboard running while a moved folder is watched and the preference is on.
    private func keepRunningChanged() {
        let keep = hasRelocations && prefs.keepGuardRunning
        if AppDelegate.keepRunning != keep { AppDelegate.keepRunning = keep }
    }

    /// Quitting waits only for a step that must not be cut in two (the switch itself, a confirm, a roll back, a forget): the
    /// journal makes a quit during preflight, copying or comparing recoverable (the original is untouched until the switch).
    private func busyChanged() {
        var critical = actionInFlight
        if case .running(let progress) = phase, progress.phase == .preflight || progress.phase == .copying || progress.phase == .verifying { critical = false }
        if AppDelegate.busy != critical { AppDelegate.busy = critical }
        if actionInFlight != quitGuarded {
            quitGuarded = actionInFlight
            if actionInFlight { ProcessInfo.processInfo.disableSuddenTermination() } else { ProcessInfo.processInfo.enableSuddenTermination() }
        }
    }

    private var quitGuarded = false
}
