import Darwin
import Foundation
import OutboardCore

/// Progress and cancellation of one copy, shared between the thread that copies and the one that reports.
final class CopyControl: @unchecked Sendable {
    private let lock = NSLock()
    private var startedBytes: UInt64 = 0
    private var startedFiles = 0
    private var stop = false

    func add(bytes: UInt64) {
        lock.lock()
        startedBytes += bytes
        startedFiles += 1
        lock.unlock()
    }

    /// Bytes of the files the copy has started so far (a file counts when it begins, not when it ends: no estimate, no rate).
    var bytes: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return startedBytes
    }

    var files: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedFiles
    }

    func cancel() {
        lock.lock()
        stop = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stop
    }
}

struct CopyDone {
    /// Manifest A: the source as it was right before the copy began.
    var startManifest: [TreeEntry]
    var fingerprint: TreeFingerprint
    var stagingStamp: FileStamp?
    var destination: String
}

enum CopyResult {
    case copied(CopyDone)
    /// A rule said no; nothing was written.
    case refused(String)
    /// The source is not what the plan describes; nothing was written.
    case changed(String)
    /// The journal would not take the intent; nothing was written.
    case notAttempted(String)
    /// The copy stopped part way; a partial folder may be on the drive (it is labelled and offered for the Trash).
    case failed(errno: Int32?, message: String)
    case cancelled
}

/// The only `copyItem`. Copies the plan's source into a new folder (`.staging-<id>` on the drive; `<name>.returning-<id>` for a
/// return to the Mac), after the Core rules approve the pair, the source is the object that was planned, and the journal has the
/// intent. A real copy across volumes, not a clone; symbolic links are copied as links. It never merges into an existing folder
/// (`copyItem` fails when the destination exists) and never reads a file's contents itself.
enum Copier {
    static func destinationPath(_ plan: MovePlan) -> String {
        plan.direction == .toDrive ? plan.stagingPath : plan.macPath + Names.returningInfix + plan.id
    }

    static func copy(_ plan: MovePlan, home: String, control: CopyControl) -> CopyResult {
        let destination = destinationPath(plan)
        switch CopyRules.check(source: plan.sourcePath, destination: destination, ctx: RuleContext(plan: plan, home: home)) {
        case .allowed: break
        case .refused(let why): return .refused(why)
        }
        switch Guard.verifyStamp(path: plan.sourcePath, expected: plan.sourceStamp) {
        case .unchanged: break
        case .missing: return .changed("The folder is gone.")
        case .changed(let why): return .changed(why)
        case .unreadable(let e): return .failed(errno: e, message: "The folder could not be looked at (error \(e)).")
        }
        // Neither end is reached through a link in a parent folder (the never-list and the sync check read the text of the path).
        if let why = Fs.ancestorProblem(plan.sourcePath, home: home) ?? Fs.ancestorProblem(destination, home: home) { return .refused(why) }
        // The folder the copy goes into must already be there (made by `OutboardRoot` after the drive's UUID was confirmed): a copy never
        // creates its own parents, least of all under /Volumes.
        guard Fs.isPlainDirectory(Fs.parent(of: destination)) else { return .refused("The folder for the copy is not on the drive.") }
        // And it is the drive's own: `Outboard` and the recipe folder are real folders on the recorded volume, looked at again right
        // before the first byte goes (a link planted since the preflight would send the copy somewhere else).
        let d = plan.destination
        let onTheDrive = plan.direction == .toDrive ? OutboardRoot.recipeFolderIsOnDrive(plan)
                                                    : OutboardRoot.driveFolderIsSound(mountPoint: d.mountPoint, path: plan.sourcePath)
        guard onTheDrive else { return .refused(OutboardRoot.driveFolderText) }
        // Manifest A, from a walk of the source (names, sizes and attributes; no contents).
        guard let start = SizeScanner.walk(plan.sourcePath), start.isComplete else {
            return .failed(errno: nil, message: "The folder could not be read end to end.")
        }
        let counts = JournalCounts(files: start.fingerprint.files, bytes: start.fingerprint.logicalBytes)
        guard Journal.intent(.copy, subject: JournalSubject(plan), home: home, src: plan.sourcePath, to: destination, stamp: plan.sourceStamp,
                             state: .copying, counts: counts) else {
            return .notAttempted(Say.journalBlocked)
        }
        let manager = FileManager()
        let watcher = Watcher(control: control)
        manager.delegate = watcher
        var failure: Error?
        do {
            try manager.copyItem(at: URL(fileURLWithPath: plan.sourcePath, isDirectory: true), to: URL(fileURLWithPath: destination, isDirectory: true))
        } catch {
            failure = error
        }
        let stagingStamp = Fs.stamp(of: destination)
        let code = failure.flatMap { Fs.posix($0) }
        let cancelled = control.isCancelled
        let status: StepStatus = failure == nil && !cancelled ? .ok : (cancelled ? .interrupted : .failed)
        Journal.result(.copy, subject: JournalSubject(plan), home: home, status: status, errno: code, src: plan.sourcePath, to: destination,
                       stamp: stagingStamp, counts: counts)
        if cancelled { return .cancelled }
        if let failure {
            let text = code == ENOSPC ? "The drive ran out of space." : "The copy stopped: \(failure.localizedDescription)"
            return .failed(errno: code, message: text)
        }
        return .copied(CopyDone(startManifest: start.entries, fingerprint: start.fingerprint, stagingStamp: stagingStamp, destination: destination))
    }

    /// Counts what the copy starts and lets a caller stop it: `copyItem` asks before each item (VERIFY that it does on every macOS
    /// we run on; if it does not, progress stays at zero and cancel waits for the copy to finish).
    private final class Watcher: NSObject, FileManagerDelegate {
        let control: CopyControl

        init(control: CopyControl) {
            self.control = control
        }

        func fileManager(_ fileManager: FileManager, shouldCopyItemAt srcURL: URL, to dstURL: URL) -> Bool {
            if control.isCancelled { return false }
            var st = stat()
            let size: UInt64 = lstat(srcURL.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG ? UInt64(max(0, st.st_size)) : 0
            control.add(bytes: size)
            return true
        }

        func fileManager(_ fileManager: FileManager, shouldProceedAfterError error: Error, copyingItemAt srcURL: URL, to dstURL: URL) -> Bool {
            false
        }
    }
}
