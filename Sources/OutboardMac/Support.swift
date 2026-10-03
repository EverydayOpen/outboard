import Foundation
import OutboardCore

/// One mutation in flight in the whole app (invariant I5): a move, a rollback, a park, a trash. The first caller wins; the
/// others are told to wait and nothing is queued behind their back.
enum MutationGate {
    private static let lock = NSLock()
    private static var busy = false

    static func tryEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    static func leave() {
        lock.lock()
        busy = false
        lock.unlock()
    }

    static var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return busy
    }
}

extension MoveStep {
    /// The rollback's closing line is journaled as `rollback` with the state `rolledBack`; the pinned call reads `.rolledBack`.
    static var rolledBack: MoveStep { .rollback }
}

/// The plain sentences the Mac layer returns. Findings, not guarantees.
enum Say {
    static let journalBlocked = "I can't write the activity log, so nothing was changed."
    static let busy = "Another change is in progress. Try again when it finishes."
    static let driveGone = "The drive isn't connected anymore. Nothing was changed."
    static let unknownRunning = "We couldn't tell whether the app is running, so nothing was changed."

    static func running(_ appName: String) -> String { "\(appName) is running. Quit it and try again." }
}

/// A thread-safe flag, for cancellation and for "this finished".
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Keeps the Mac from idle sleep while a long copy or hash runs (ProcessInfo assertion), ended by `end()`.
final class Awake {
    private let token: NSObjectProtocol

    init(reason: String) {
        token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
    }

    func end() { ProcessInfo.processInfo.endActivity(token) }
}

extension Date {
    /// Whole seconds, so a date written as ISO-8601 reads back equal.
    var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
