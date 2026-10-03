import Darwin
import Foundation
import OutboardCore

enum PlaceholderResult {
    case created(FileStamp)
    /// Something is already at the path; nothing was changed.
    case refused(String)
    case failed(errno: Int32?, message: String)
    case notAttempted(String)

    var text: String {
        switch self {
        case .created: return "Done."
        case .refused(let why), .notAttempted(let why): return why
        case .failed(_, let message): return message
        }
    }
}

/// The note that stands where a folder was while its drive is away: a small regular file named like the folder, read-only (0444),
/// with the text from Core `PlaceholderText`. An app that tries to make the folder fails with "not a directory" instead of
/// starting fresh on the Mac. The mode is given at creation, so no permission call exists anywhere. It never overwrites.
enum Placeholder {
    static func create(at path: String, driveName: String, removal: RemovalKind, subject: JournalSubject, home: String) -> PlaceholderResult {
        let before = Fs.info(path)
        guard before.err == ENOENT else {
            return before.err == 0 ? .refused("Something is already at that path.")
                                   : .failed(errno: before.err, message: "The path could not be looked at (error \(before.err)).")
        }
        let note = JournalNote.placeholder + " " + JournalNote.park(removal)
        guard Journal.intent(.park, subject: subject, home: home, src: path, note: note) else {
            return .notAttempted(Say.journalBlocked)
        }
        let text = PlaceholderText.body(driveName: driveName)
        let made = FileManager.default.createFile(atPath: path, contents: Data(text.utf8),
                                                  attributes: [.posixPermissions: 0o444])
        let stamp = made ? Fs.stamp(of: path) : nil
        let confirmed = stamp != nil && (Fs.info(path).st.st_mode & 0o777) == 0o444
        Journal.result(.park, subject: subject, home: home, status: confirmed ? .ok : .failed, src: path, stamp: stamp, note: note)
        if let stamp, confirmed { return .created(stamp) }
        return .failed(errno: nil, message: "The note could not be created.")
    }
}
