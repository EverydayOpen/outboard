import AppKit
import OutboardCore

/// The only observer of mount, unmount, rename, sleep and wake notifications (grep G6), and the 10 second timer that runs while
/// any relocation exists. Triggers are advisory: `reconcile` is one idempotent pass over the recorded volume UUIDs and the `lstat`
/// state of each path, so a missed notification costs seconds, not correctness. What the notifications say about *how* a drive left
/// (ejected, or pulled) is kept here for the guard: a pulled cable gives only `didUnmount`, or nothing until the next volume event.
/// Which notifications fire for which kind of removal, and their `userInfo` keys, are VERIFY on a Mac (BUILD_PLAN §12 item 3).
enum VolumeWatcher {
    private static let lock = NSLock()
    private static var willSleepAt: Date?
    private static var uuidByPath: [String: String] = [:]
    /// How a drive left, and when that was noted (the mark of a drive that is mounted again is dropped after a few seconds).
    private static var removals: [String: (kind: RemovalKind, at: Date)] = [:]
    /// A will-unmount that no unmount has answered yet. Not a removal: an eject can fail (volume busy) and leave the drive mounted.
    private static var pendingEjects: [String: Date] = [:]
    /// A will-unmount counts for an unmount that follows within this long; after it, the drive was pulled, not ejected.
    static let ejectWindowSeconds: TimeInterval = 60
    private static let settleSeconds: TimeInterval = 5

    // MARK: - What the guard asks

    /// The Mac went to sleep at or after `date` (a copy that ran across a sleep is not trusted).
    static func didSleep(since date: Date) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return willSleepAt.map { $0 >= date } ?? false
    }

    /// How the drive with this UUID last left: `.ejected` if the unmount followed a will-unmount within a minute, `.unclean` if not.
    static func removal(of uuid: String) -> RemovalKind? {
        lock.lock()
        defer { lock.unlock() }
        return removals[uuid.uppercased()]?.kind
    }

    static func clearRemoval(of uuid: String) {
        lock.lock()
        removals[uuid.uppercased()] = nil
        pendingEjects[uuid.uppercased()] = nil
        lock.unlock()
    }

    /// The Mac is about to unmount this drive. Only remembered; the drive is marked ejected when it has really left.
    static func noteWillUnmount(_ uuid: String, at now: Date = Date()) {
        lock.lock()
        pendingEjects[uuid.uppercased()] = now
        lock.unlock()
    }

    /// The drive has left. A recent will-unmount makes it an eject, anything else a pull. A mark that is already there stays.
    static func noteDidUnmount(_ uuid: String, at now: Date = Date()) {
        let key = uuid.uppercased()
        lock.lock()
        defer { lock.unlock() }
        let asked = pendingEjects.removeValue(forKey: key)
        guard removals[key] == nil else { return }
        let ejected = asked.map { now >= $0 && now.timeIntervalSince($0) < ejectWindowSeconds } ?? false
        removals[key] = (kind: ejected ? RemovalKind.ejected : RemovalKind.unclean, at: now)
    }

    /// The guard saw these drives mounted just now. A refused eject leaves its will-unmount behind, and a mark from an earlier
    /// removal outlives its drive: neither may colour the next removal, so a mark older than its grace is dropped.
    static func noteStillMounted(_ uuids: [String], at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        for uuid in uuids.map({ $0.uppercased() }) {
            if let asked = pendingEjects[uuid], now.timeIntervalSince(asked) >= ejectWindowSeconds { pendingEjects[uuid] = nil }
            if let mark = removals[uuid], now.timeIntervalSince(mark.at) >= settleSeconds { removals[uuid] = nil }
        }
    }

    #if DEBUG
    /// Tests only: say how a drive left, as the notifications would have (a headless runner does not deliver them).
    static func setRemovalForTests(_ kind: RemovalKind?, uuid: String) {
        lock.lock()
        removals[uuid.uppercased()] = kind.map { (kind: $0, at: Date.distantPast) }
        lock.unlock()
    }
    #endif

    // MARK: - Watching

    /// Starts watching. `hasRelocations` gates the timer (nothing ticks when Outboard has nothing to guard). Returns the cancel closure.
    static func start(hasRelocations: @escaping @Sendable () -> Bool = { true },
                      _ onTrigger: @escaping @Sendable (ReconcileTrigger) -> Void) -> @Sendable () -> Void {
        rememberMounted()
        let center = NSWorkspace.shared.notificationCenter
        var tokens: [NSObjectProtocol] = []

        tokens.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { note in
            if let url = volumeURL(note), let uuid = volumeUUID(of: url) {
                remember(path: url.path, uuid: uuid)
                clearRemoval(of: uuid)   // how it left last time says nothing about how it leaves next time
            }
            onTrigger(.mount)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: nil) { note in
            if let url = volumeURL(note), let uuid = volumeUUID(of: url) ?? knownUUID(forPath: url.path) {
                remember(path: url.path, uuid: uuid)
                noteWillUnmount(uuid)
            }
            onTrigger(.willUnmount)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { note in
            if let url = volumeURL(note), let uuid = knownUUID(forPath: url.path) { noteDidUnmount(uuid) }
            onTrigger(.unmount)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: nil) { _ in
            rememberMounted()
            onTrigger(.rename)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
            lock.lock()
            willSleepAt = Date()
            lock.unlock()
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            onTrigger(.wake)
        })

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + Limits.reconcileIntervalSeconds, repeating: Limits.reconcileIntervalSeconds)
        timer.setEventHandler {
            if hasRelocations() { onTrigger(.timer) }
        }
        timer.resume()

        let held = Observers(tokens)
        return {
            for token in held.tokens { center.removeObserver(token) }
            timer.cancel()
        }
    }

    /// The observer tokens, so the cancel closure can be `@Sendable`.
    private final class Observers: @unchecked Sendable {
        let tokens: [NSObjectProtocol]

        init(_ tokens: [NSObjectProtocol]) {
            self.tokens = tokens
        }
    }

    // MARK: - Bookkeeping

    private static func volumeURL(_ note: Notification) -> URL? {
        note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
    }

    private static func volumeUUID(of url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    private static func knownUUID(forPath path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return uuidByPath[Fs.normalized(path)]
    }

    private static func remember(path: String, uuid: String) {
        lock.lock()
        uuidByPath[Fs.normalized(path)] = uuid.uppercased()
        lock.unlock()
    }

    /// A path to UUID map from the mount table, so an unmount (whose URL no longer resolves to a UUID) can still be attributed.
    private static func rememberMounted() {
        for mounted in VolumeIdentity.all() ?? [] {
            if let uuid = mounted.uuid { remember(path: mounted.mountPoint, uuid: uuid) }
        }
    }
}
