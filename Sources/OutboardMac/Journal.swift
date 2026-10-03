import Darwin
import Foundation
import OutboardCore

/// The write-ahead journal (BUILD_PLAN §3 I3, §5.3): JSONL, append-only, one file per month, 0600 in a 0700 folder under
/// `~/Library/Application Support/Outboard` (never inside iCloud). An `intent` line is written and fsync'd before every act, a
/// `result` line after. If a line cannot be written the caller must not act (fail closed). Paths are stored with `~`. It holds
/// no file contents. The only file with raw `write(2)` and `fsync`.
enum Journal {
    private static let lock = NSLock()
    private static var seqs: [String: Int] = [:]

    static func directory(home: String) -> String { home + "/Library/Application Support/" + Names.supportFolder }

    /// Creates the folder if needed (0700). An existing one must be a real directory of ours with mode 0700: never followed
    /// through a symlink, never chmod'ed back into shape (a wrong mode means false).
    static func prepare(home: String) -> Bool {
        let dir = directory(home: home)
        var st = stat()
        if lstat(dir, &st) != 0 {
            guard errno == ENOENT,
                  (try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])) != nil else { return false }
        }
        return isOurs(dir)
    }

    /// The journal can take a line right now (folder and this month's file are ours and 0600).
    static func isWritable(home: String) -> Bool {
        guard prepare(home: home) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let fd = openAppend(directory(home: home) + "/" + ActivityLog.fileName(for: Date())) else { return false }
        close(fd)
        return true
    }

    /// Opens a move: the `begin` line carries the whole plan. False = nothing may move.
    static func begin(_ plan: MovePlan, onDriveMissing: OnDriveMissing, volume: VolumeRef, home: String, at: Date) -> Bool {
        guard prepare(home: home) else { return false }
        let jp = MovePlanner.journalPlan(plan, onDriveMissing: onDriveMissing, volume: volume, fileCount: plan.sourceFingerprint.files, home: home)
        return append(home: home, id: plan.id, ts: at, phase: .intent, step: .begin, recipe: JournalSubject(plan).recipe, state: .planned,
                      vol: plan.destination.volumeUUID, volName: plan.destination.volumeName, plan: jp)
    }

    /// Opens an action on a move that already exists (a rollback, a confirm): one `intent` line, no plan.
    static func begin(_ step: MoveStep, subject: JournalSubject, home: String, state: MoveState? = nil, note: String? = nil,
                      at: Date = Date()) -> Bool {
        guard prepare(home: home) else { return false }
        return append(home: home, id: subject.moveID, ts: at, phase: .intent, step: step, recipe: subject.recipe, state: state, note: note)
    }

    static func intent(_ step: MoveStep, subject: JournalSubject, home: String, src: String? = nil, to: String? = nil, stamp: FileStamp? = nil,
                       state: MoveState? = nil, vol: String? = nil, volName: String? = nil, fsName: String? = nil, note: String? = nil,
                       counts: JournalCounts? = nil, at: Date = Date()) -> Bool {
        let ok = append(home: home, id: subject.moveID, ts: at, phase: .intent, step: step, recipe: subject.recipe, state: state,
                        src: src.map { PathText.tilde($0, home: home) }, to: to.map { PathText.tilde($0, home: home) }, stamp: stamp,
                        vol: vol, volName: volName, fsName: fsName, note: note, counts: counts)
        #if DEBUG
        if ok { Faults.hit(.afterIntent(step)) }
        #endif
        return ok
    }

    @discardableResult
    static func result(_ step: MoveStep, subject: JournalSubject, home: String, status: StepStatus, errno: Int32? = nil, abort: AbortReason? = nil,
                       state: MoveState? = nil, src: String? = nil, to: String? = nil, stamp: FileStamp? = nil, note: String? = nil,
                       counts: JournalCounts? = nil, verification: VerificationSummary? = nil, trashedPath: String? = nil,
                       vol: String? = nil, volName: String? = nil, fsName: String? = nil, at: Date = Date()) -> Bool {
        #if DEBUG
        Faults.hit(.afterAct(step))
        #endif
        return append(home: home, id: subject.moveID, ts: at, phase: .result, step: step, recipe: subject.recipe, state: state,
                      src: src.map { PathText.tilde($0, home: home) }, to: to.map { PathText.tilde($0, home: home) }, stamp: stamp,
                      vol: vol, volName: volName, fsName: fsName, status: status, errno: errno, abort: abort, note: note, counts: counts,
                      verification: verification, trashedPath: trashedPath.map { PathText.tilde($0, home: home) })
    }

    /// Every journal-*.jsonl, oldest first. Missing, foreign or unreadable = nothing. ponytail: whole files in memory; a file
    /// above 64 MB is skipped instead.
    static func loadAll(home: String) -> [JournalEntry] {
        let dir = directory(home: home)
        guard isOurs(dir), let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var out: [JournalEntry] = []
        for name in names.filter(ActivityLog.isJournalFile).sorted() {
            let path = dir + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), st.st_size < 64 << 20,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            out += ActivityLog.decodeAll(text).entries
        }
        return out
    }

    // MARK: -

    private static func isOurs(_ dir: String) -> Bool {
        var st = stat()
        return lstat(dir, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid() && (st.st_mode & 0o777) == 0o700
    }

    /// O_NOFOLLOW refuses a symlinked file, O_NONBLOCK makes a planted FIFO fail instead of hanging, and the opened file
    /// itself is checked (regular, ours, 0600).
    private static func openAppend(_ path: String) -> Int32? {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), (st.st_mode & 0o777) == 0o600 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// A torn last line (a crash in the middle of a write) has no newline; the next line must not be glued to it.
    private static func endsWithNewline(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > 0 else { return true }
        var last: UInt8 = 0
        return pread(fd, &last, 1, st.st_size - 1) == 1 ? last == 0x0A : true
    }

    private static func nextSeq(_ id: String, home: String) -> Int {
        let key = home + "|" + id
        if let known = seqs[key] {
            seqs[key] = known + 1
            return known + 1
        }
        let existing = loadAll(home: home).filter { $0.id == id }.map(\.seq).max() ?? 0
        seqs[key] = existing + 1
        return existing + 1
    }

    /// One line, one write(2) loop, then fsync. Opens and closes per line: a handful of lines per step, nothing stays open.
    private static func append(home: String, id: String, ts: Date, phase: JournalPhase, step: MoveStep, recipe: String, state: MoveState? = nil,
                               src: String? = nil, to: String? = nil, stamp: FileStamp? = nil, vol: String? = nil, volName: String? = nil,
                               fsName: String? = nil, status: StepStatus? = nil, errno: Int32? = nil, abort: AbortReason? = nil,
                               note: String? = nil, plan: JournalPlan? = nil, counts: JournalCounts? = nil,
                               verification: VerificationSummary? = nil, trashedPath: String? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // Lines that belong to no move (choosing a drive, viewing a guide) come before any `begin`, so the folder is made here too.
        guard prepare(home: home) else { return false }
        let dir = directory(home: home)
        let path = dir + "/" + ActivityLog.fileName(for: ts)
        let heal = !endsWithNewline(path)
        guard let fd = openAppend(path) else { return false }
        defer { close(fd) }
        let entry = JournalEntry(id: id, seq: nextSeq(id, home: home), ts: ts, phase: phase, step: step, recipe: recipe.isEmpty ? nil : recipe,
                                 state: state, src: src, to: to, stamp: stamp, vol: vol, volName: volName, fsName: fsName, status: status,
                                 errno: errno, abort: abort, note: note, plan: plan, counts: counts, verification: verification,
                                 trashedPath: trashedPath)
        let bytes = Array(((heal ? "\n" : "") + ActivityLog.encode(entry) + "\n").utf8)
        var done = 0
        while done < bytes.count {
            let n = bytes[done...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if Darwin.errno == EINTR { continue }
                return false
            }
            done += n
        }
        // fsync, not F_FULLFSYNC: the filesystem is the source of truth, a torn last line is ignored on read, and a crash of
        // this process cannot lose a line that fsync returned for.
        return fsync(fd) == 0
    }
}
