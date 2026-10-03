import Foundation
import OutboardCore

/// Marks on journal lines that let the guard find "the link I wrote" and "the note I wrote" later, by stamp.
enum JournalNote {
    static let link = "link"
    static let placeholder = "placeholder"
    static func park(_ removal: RemovalKind) -> String { "park:" + removal.rawValue }
}

/// What the journal says about one move, for the Mac layer: the stamps recorded by the verbs (so the next verb can check it is
/// touching the same object) and the last link target. Pure reading of `JournalEntry` lines; nothing here touches the disk.
struct JournalFacts {
    let moveID: String
    let entries: [JournalEntry]
    let home: String

    init(moveID: String, all: [JournalEntry], home: String) {
        self.moveID = moveID
        self.entries = all.filter { $0.id == moveID }
        self.home = home
    }

    private func last(step: MoveStep, phase: JournalPhase, where extra: (JournalEntry) -> Bool = { _ in true }) -> JournalEntry? {
        entries.last { $0.step == step.rawValue && $0.phase == phase && extra($0) }
    }

    /// The stamp of the source folder when the copy began (the plan's `sourceStamp`).
    var sourceStamp: FileStamp? {
        last(step: .copy, phase: .intent) { $0.stamp != nil }?.stamp
    }

    /// The stamp of the original taken right before it was renamed to `<name>.before-move` (same object afterwards).
    var setAsideStamp: FileStamp? {
        last(step: .setAside, phase: .intent) { $0.stamp != nil }?.stamp
    }

    /// The staging folder as the copy left it. Whatever the copy's status: a copy that was cancelled, ran out of room or failed leaves
    /// a partial folder, and that folder is the one the user may move to the Trash.
    var stagingStamp: FileStamp? {
        last(step: .copy, phase: .result) { $0.stamp != nil }?.stamp
    }

    /// The published folder (the staging folder's object, renamed).
    var publishedStamp: FileStamp? {
        last(step: .publish, phase: .result) { $0.status == .ok && $0.stamp != nil }?.stamp
    }

    /// The last link Outboard created at the path: where it points and what `lstat` said right after.
    var lastLink: (target: String, stamp: FileStamp)? {
        guard let e = entries.last(where: { $0.phase == .result && $0.status == .ok && $0.note == JournalNote.link && $0.to != nil && $0.stamp != nil }),
              let to = e.to, let stamp = e.stamp else { return nil }
        return (PathText.expandTilde(to, home: home), stamp)
    }

    /// The last note file Outboard created at the path.
    var lastPlaceholder: FileStamp? {
        entries.last { $0.phase == .result && $0.status == .ok && ($0.note ?? "").hasPrefix(JournalNote.placeholder) && $0.stamp != nil }?.stamp
    }

    /// How the drive left the last time the guard parked this relocation, if it said (`park:<kind>` anywhere in the note). A park
    /// that a later successful unpark or return has answered is over, so it says nothing about a newer removal.
    var lastRemoval: RemovalKind? {
        for e in entries.reversed() where e.phase == .result {
            if e.status == .ok, e.step == MoveStep.unpark.rawValue || e.step == MoveStep.returned.rawValue { return nil }
            guard let note = e.note, let range = note.range(of: "park:") else { continue }
            let word = note[range.upperBound...].prefix { !$0.isWhitespace }
            if let kind = RemovalKind(rawValue: String(word)) { return kind }
        }
        return nil
    }

    /// Lines that mention a step, for tests and recovery messages.
    func count(step: MoveStep, phase: JournalPhase) -> Int {
        entries.filter { $0.step == step.rawValue && $0.phase == phase }.count
    }
}
