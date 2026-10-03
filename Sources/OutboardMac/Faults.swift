#if DEBUG
import Darwin
import Foundation
import OutboardCore

/// Where a test may stop the process or interfere: right after an `intent` line was written (before the act) or right after
/// the act (before its `result` line). Debug builds only (grep G14: CI builds Debug and Release); a Release build contains
/// neither this file's type nor a single call to it.
enum FaultPoint: Hashable {
    case afterIntent(MoveStep)
    case afterAct(MoveStep)
}

enum Faults {
    private static let lock = NSLock()
    private static var armed: (point: FaultPoint, occurrence: Int)?
    private static var seen: [FaultPoint: Int] = [:]
    /// A test sets this to change the world at a point (flip a byte in staging, create a folder, detach a disk image).
    static var onHit: ((FaultPoint) -> Void)?

    /// `_exit(9)` at the `occurrence`-th time `point` is reached (the crash helper arms this from its command line).
    static func arm(_ point: FaultPoint, occurrence: Int = 1) {
        lock.lock()
        armed = (point, max(1, occurrence))
        seen = [:]
        lock.unlock()
    }

    static func disarm() {
        lock.lock()
        armed = nil
        seen = [:]
        onHit = nil
        lock.unlock()
    }

    static func hit(_ point: FaultPoint) {
        onHit?(point)
        lock.lock()
        let n = (seen[point] ?? 0) + 1
        seen[point] = n
        let crash = armed.map { $0.point == point && $0.occurrence == n } ?? false
        lock.unlock()
        if crash { _exit(9) }
    }
}
#endif
