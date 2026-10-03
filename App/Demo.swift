#if DEBUG
import AppKit
import OutboardCore

/// Screenshots (.github/workflows/screens.yml), DEBUG builds only (BUILD_PLAN §9). A launch argument opens one screen on
/// synthetic data: the scenario's Mac and drives are built in Core (`DemoBackend`, real catalogue apps, fictional sizes, home
/// /Users/jane), so nothing is read from or moved on the real system, no drive is touched and no activity is logged to disk.
/// Outboard is a window app, so the main window is simply the app's own `Window` scene.
///
///     -demoScreen <screen>      or --demo-screen
///     -demoScenario <scenario>  or --demo-scenario, -demo, or OUTBOARD_DEMO=<scenario>; each screen has a default scenario
///     -demoAppearance light|dark
///     -demoCardOut <png path>   renders the Storage Plan card with Export after the first measurement and quits
///     -demoScroll <0...1>       scrolls the main window's widest scrollable area to that fraction (what is below the fold)
///
/// Names ignore case and hyphens. An unknown name stops the app, so a typo in the workflow fails its capture.
/// AppModel reads `Demo.backend` when it picks its backend and calls `Demo.start(self)` at the end of its init.
/// It uses AppModel's published surface (`screen`, `plan`, `prefs`, `phase`, `start()`, `rescan()`, `eligibility`, `beginConsent`,
/// `startMove`, `confirm`, `handle`, `showGuide`, and the flags `showPreferences`, `showReport`, `showConfirmDialog`) and never calls
/// `openGuide` or anything else that opens a real app or touches the system.
enum Demo {
    enum Screen: String, CaseIterable {
        /// Plan (the home): the Storage Plan card over the ranked list. Scenario `plan`: 87 GB.
        case plan
        /// Drives: the eligible drive and the refusals (exFAT, USB hard disk, Time Machine disk, two named Backup, a NAS, a card, a disk image).
        case drivePicker
        /// The consent sheet for the scenario's recipe (default: Xcode build data, with Xcode shown as running).
        case consent
        /// The progress sheet, frozen by the scenario (`copying` at 41%, or `verifying`).
        case moving
        /// A whole move on the sample Mac, then "The move is ready" with the verification done.
        case verified
        /// `verified`, then the Confirm dialog on top.
        case confirm
        /// `verified`, then confirmed: the result sheet.
        case result
        /// The guided card (Photos library) with the drive check.
        case guided
        /// Drives with the drive ejected: banner, "Drive away" pills, the notes parked where the folders were.
        case driveMissing
        /// Drives after it came back: "Checked 200 of 41,203 files: all matched."
        case restored
        /// Drives on an edge scenario (default `held`; also `conflict`, `recovered`, `needs-attention`, `forget`, ...).
        case edge
        /// Activity: the journal rendered (default scenario `after-moves`).
        case activity
        /// The export preview over Activity (scenario `report`).
        case report
        /// The Plan on `plan-guided`, for the card with its muted guided line; `-demoCardOut` writes the card itself.
        case card
        case about, preferences
        /// The five education cards over an empty Plan.
        case firstRun
        /// "No big folders from the apps Outboard knows."
        case quiet
        /// The README hero's run (screens.yml records it): the Plan, the consent sheet, a move whose progress takes about 4.5 s,
        /// "The move is ready", then confirmed. The sheets are the subject, so none is hidden.
        case hero
        /// The README hero's second run: Drives with the drive away, then the same Mac with the drive back.
        case heroGuard
    }

    /// nil on a normal launch.
    private static let setup: (screen: Screen, scenario: DemoScenario)? = {
        let name = argument("demoScreen")
        let given = argument("demoScenario") ?? argument("demo") ?? ProcessInfo.processInfo.environment["OUTBOARD_DEMO"]
        guard name != nil || given != nil else { return nil }
        let scenario: DemoScenario? = given.map { parse($0) }
        let screen: Screen = name.map { parse($0, alias: aliases) } ?? scenario.map(defaultScreen) ?? .plan
        return (screen, scenario ?? defaultScenario(screen))
    }()

    /// BUILD_PLAN §9's screen names and a few spellings the workflow may use.
    private static let aliases: [String: Screen] = [
        "drives": .drivePicker, "progress": .moving, "copying": .moving, "ready": .verified, "tryit": .verified,
        "away": .driveMissing, "back": .restored, "history": .activity, "welcome": .firstRun, "empty": .quiet,
    ]

    private static func defaultScenario(_ screen: Screen) -> DemoScenario {
        switch screen {
        case .plan, .about, .preferences, .verified, .confirm, .result, .hero: return .plan
        case .drivePicker: return .drives
        case .consent: return .consentXcodeDerivedData
        case .moving: return .copying
        case .guided: return .guided
        case .driveMissing, .heroGuard: return .driveAway
        case .restored: return .driveBack
        case .edge: return .held
        case .activity: return .afterMoves
        case .report: return .report
        case .card: return .planGuided
        case .firstRun: return .firstRun
        case .quiet: return .nothingFound
        }
    }

    /// For a launch that names only a scenario.
    private static func defaultScreen(_ scenario: DemoScenario) -> Screen {
        switch scenario {
        case .fresh, .plan, .planGuided, .partlyMeasured, .small, .journalBlocked: return .plan
        case .nothingFound: return .quiet
        case .drives: return .drivePicker
        case .consentXcodeDerivedData, .consentXcodeArchives, .consentHuggingFace, .consentOllama, .consentLlamaCpp, .consentNpm,
             .consentIOSBackups: return .consent
        case .guided: return .guided
        case .copying, .verifying: return .moving
        case .driveAway: return .driveMissing
        case .driveBack: return .restored
        case .swapped, .confirmed, .rolledBack, .recovered, .needsAttention, .held, .conflict, .forget: return .edge
        case .afterMoves: return .activity
        case .report: return .report
        case .firstRun: return .firstRun
        }
    }

    /// Non-nil in demo mode: the scenario's backend. The hero's move is slowed so the bar and the phases can be seen; every
    /// other screen uses Core's default beat length. `heroGuard` swaps the drive-away Mac for the drive-back one on cue.
    static let backend: Backend? = setup.map { demo in
        let seconds = demo.screen == .hero ? 4.5 : 1.2
        let backend = DemoBackend.make(demo.scenario, seconds: seconds)
        guard demo.screen == .heroGuard else { return backend }
        return Demo.swapping(backend, for: DemoBackend.make(.driveBack, seconds: seconds), latch: driveBack)
    }

    private static var started = false

    /// Called by AppModel.init, after the demo backend is in place.
    /// AppModel does not persist `prefs` while `backend.isDemo`, so replacing them here leaves the real settings alone.
    @MainActor static func start(_ model: AppModel) {
        guard let demo = setup, !started else { return }
        started = true
        if let look = argument("demoAppearance") {
            NSApplication.shared.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        // The scenario's preferences show the moves not yet tried on a real Mac (every automated recipe is one). The login-item
        // question is marked answered so no extra card sits in front of a move; the first-run cards come up only for `firstRun`.
        var prefs = DemoScenarios.preferences(for: demo.scenario)
        prefs.hasAnsweredLoginItem = true
        if demo.screen == .firstRun { prefs.hasSeenFirstRun = false }
        model.prefs = prefs
        Task {
            await run(demo, model)
            // `open` activates the app already; this covers a launch that lost focus while the screen was set up.
            activateApp()
        }
        if let fraction = argument("demoScroll").flatMap(Double.init) {
            // Three passes: a lazy List or ScrollView only knows its full height after the first rows have been measured.
            Task { for wait in [3.0, 1.0, 1.0] { await pause(wait); scroll(to: fraction) } }
        }
    }

    @MainActor private static func run(_ demo: (screen: Screen, scenario: DemoScenario), _ model: AppModel) async {
        await model.start()   // once per launch: a second caller waits for the first; it measures itself unless the first-run cards are up
        if model.plan == nil, model.prefs.hasSeenFirstRun { await model.rescan() }
        if let path = argument("demoCardOut") {
            if !writeCard(model, to: path) { fatalError("Could not write the card") }
            NSApp.terminate(nil)
            return
        }
        let focus = DemoScenarios.focus(for: demo.scenario)
        switch demo.screen {
        case .plan, .quiet, .card: model.screen = .plan
        case .about: model.screen = .about
        case .drivePicker, .driveMissing, .restored, .edge: model.screen = .drives
        case .activity: model.screen = .activity
        case .firstRun: break   // the first-run cards come up because `hasSeenFirstRun` is false
        case .preferences: model.showPreferences = true
        case .report:
            model.screen = .activity
            model.showReport = true
        case .guided:
            guard let recipeID = focus.recipeID else { fatalError("The demo scenario has no guided app") }
            model.showGuide(recipeID: recipeID)
        case .consent:
            let (recipeID, volumeID, _) = target(focus)
            model.beginConsent(recipeID: recipeID, volumeID: volumeID)
        case .moving:
            // The frozen scenarios never return from the move (only a cancelled task leaves), so it is not awaited.
            Task { await move(model, focus) }
        case .verified: await move(model, focus)
        case .confirm:
            await move(model, focus)
            model.showConfirmDialog = true
        case .result:
            await move(model, focus)
            await confirmMove(model)
        case .hero: await playHero(model, focus)
        case .heroGuard: await playGuard(model)
        }
    }

    // MARK: A move on the sample Mac

    /// The recipe, the drive and the recipe's data for the scenario's move. A scenario without one is a typo in the workflow.
    private static func target(_ focus: DemoFocus) -> (RecipeID, String, Recipe) {
        guard let recipeID = focus.recipeID, let volumeID = focus.volumeID, let recipe = Catalogue.recipe(recipeID) else {
            fatalError("The demo scenario has no move")
        }
        return (recipeID, volumeID, recipe)
    }

    /// What a person does on the consent sheet: every box ticked, then Move. Runs the whole demo move (Core's real state machine
    /// over an in-memory tree) and returns when AppModel has reached "The move is ready" (or the scenario freezes it).
    @MainActor private static func move(_ model: AppModel, _ focus: DemoFocus) async {
        let (recipeID, volumeID, recipe) = target(focus)
        if model.phase == .idle { model.beginConsent(recipeID: recipeID, volumeID: volumeID) }   // `startMove` needs the consent phase
        let report = await model.eligibility(volumeID: volumeID, recipeID: recipeID)
        await model.startMove(recipeID: recipeID, volumeID: volumeID, consent: DemoScenarios.tickedConsent(recipe: recipe, report: report))
    }

    /// "Confirm and move to Trash" for the move that is ready (the demo backend moves nothing real).
    @MainActor private static func confirmMove(_ model: AppModel) async {
        if case .tryAndConfirm(let moveID) = model.phase { await model.confirm(moveID: moveID) }
    }

    // MARK: The README hero

    /// The hero's frames are a burst of window captures while this plays (screens.yml), so every pause here is a stretch of
    /// frames. From the window appearing: 1.6 s for the first measurement and the entrance animations (screens.yml drops those
    /// frames), idle 1.2, a glide down to the rows 0.8, still 0.8, the consent sheet 1.6, the move (4.5 s plus the beats around
    /// it), "The move is ready" 2, confirmed and the result 2.2.
    @MainActor private static func playHero(_ model: AppModel, _ focus: DemoFocus) async {
        while !windowShown() { await pause(0.05) }   // the recording starts when the window is up
        activateApp()
        await pause(1.6)
        await pause(1.2)
        // Points from the top of the list; VERIFY by eye on the first CI frames (it depends on the card's height).
        await glide(to: 300, over: 0.8)
        await pause(0.8)
        let (recipeID, volumeID, _) = target(focus)
        model.beginConsent(recipeID: recipeID, volumeID: volumeID)
        await pause(1.6)
        await move(model, focus)
        await pause(2)
        await confirmMove(model)
        await pause(2.2)
    }

    /// The hero's second run: the drive is away (banner, "Drive away", the notes parked), then back on cue. `handle(.mount)` is one
    /// guard pass: it re-reads the drives, the records and the snapshot from the backend, which now answers as the drive-back Mac.
    @MainActor private static func playGuard(_ model: AppModel) async {
        model.screen = .drives
        while !windowShown() { await pause(0.05) }
        activateApp()
        await pause(1.6)
        await pause(3.2)
        driveBack.turnOn()
        await model.handle(.mount)
        await pause(3.6)
    }

    /// Swaps what the guard reads from the drive-away Mac to the drive-back one once `latch` is on. Only the five closures the
    /// drive's return changes are swapped; the rest keep serving the drive-away Mac.
    private static func swapping(_ away: Backend, for back: Backend, latch: Latch) -> Backend {
        let pick: @Sendable () -> Backend = { latch.isOn ? back : away }
        var merged = away
        merged.volumes = { await pick().volumes() }
        merged.relocations = { pick().relocations() }
        merged.leftovers = { pick().leftovers() }
        merged.loadLog = { pick().loadLog() }
        merged.reconcile = { trigger in await pick().reconcile(trigger) }
        return merged
    }

    private static let driveBack = Latch()

    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var isOn: Bool {
            lock.lock()
            defer { lock.unlock() }
            return on
        }
        func turnOn() {
            lock.lock()
            on = true
            lock.unlock()
        }
    }

    // MARK: The card

    /// The Storage Plan card exactly as the Plan screen's Save PNG would draw it (`planCard`, marked as sample data), written to
    /// `path` without a panel (`Export.writePNG`, DEBUG only).
    @MainActor private static func writeCard(_ model: AppModel, to path: String) -> Bool {
        guard let card = model.planCard else { return false }
        return Export.writePNG(card, to: URL(fileURLWithPath: path))
    }

    private static let windowTitle = "Outboard"

    private static func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    @MainActor private static func windowShown() -> Bool {
        NSApp.windows.contains { $0.title == windowTitle && $0.isVisible }
    }

    // MARK: Scrolling

    /// The main window's widest scrollable area (the sidebar is narrower).
    /// VERIFY on a Mac that SwiftUI's ScrollView and List are NSScrollViews in the main window.
    @MainActor private static func listScroller() -> NSScrollView? {
        guard let root = (NSApp.windows.first { $0.title == windowTitle } ?? NSApp.mainWindow)?.contentView else { return nil }
        var best: NSScrollView?
        func find(_ view: NSView) {
            if let scroller = view as? NSScrollView, let document = scroller.documentView,
               document.frame.height > scroller.contentView.bounds.height + 1,
               scroller.frame.width > (best?.frame.width ?? 0) { best = scroller }
            view.subviews.forEach(find)
        }
        find(root)
        return best
    }

    /// How far the list has travelled, in points from the top, and how far it can.
    @MainActor private static func position(of scroller: NSScrollView) -> (offset: CGFloat, travel: CGFloat) {
        guard let document = scroller.documentView else { return (0, 0) }
        let travel = max(document.frame.height - scroller.contentView.bounds.height, 0)
        let y = scroller.contentView.bounds.origin.y
        return (document.isFlipped ? y : travel - y, travel)
    }

    @MainActor private static func place(_ scroller: NSScrollView, offset: CGFloat) {
        guard let document = scroller.documentView else { return }
        let travel = position(of: scroller).travel
        let y = min(max(offset, 0), travel)
        scroller.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? y : travel - y))
        scroller.reflectScrolledClipView(scroller.contentView)
    }

    /// `fraction` of the list's travel from the top.
    @MainActor private static func scroll(to fraction: Double) {
        guard let scroller = listScroller() else { return }
        place(scroller, offset: position(of: scroller).travel * CGFloat(fraction))
    }

    /// To `offset` points from the top over `seconds`, eased, one step per frame, so the capture burst has frames of it.
    @MainActor private static func glide(to offset: CGFloat, over seconds: Double) async {
        guard let scroller = listScroller() else { return }
        let from = position(of: scroller).offset
        let steps = max(Int(seconds * 60), 1)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            place(scroller, offset: from + (offset - from) * (t * t * (3 - 2 * t)))
            await pause(1.0 / 60)
        }
    }

    // MARK: Arguments

    /// The value after `-name` or `--kebab-name` (`demoScreen` is also `--demo-screen`), never a stored setting.
    private static func argument(_ name: String) -> String? {
        let kebab = name.map { $0.isUppercase ? "-" + $0.lowercased() : String($0) }.joined()
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(where: { $0 == "-" + name || $0 == "--" + kebab }), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }

    private static func key(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "-", with: "") }

    private static func parse<T: CaseIterable & RawRepresentable>(_ name: String, alias: [String: T] = [:]) -> T
    where T.RawValue == String {
        guard let hit = alias[key(name)] ?? T.allCases.first(where: { key($0.rawValue) == key(name) }) else {
            fatalError("Unknown demo name")   // constant text: a crash report must not carry names
        }
        return hit
    }
}
#endif
