import Foundation

public enum ActivityTone: String, Codable, Sendable {
    case normal
    /// An abort, a rollback, a mismatch, a held or conflicting relocation, an unknown step: shown under "problems only".
    case problem
}

/// One row of the Activity screen and the export timeline: a **rendering** of one `JournalEntry` by Core `ActivityText`, so the
/// screen, the export and crash recovery cannot disagree (invariant I10). The log cannot be edited or cleared from the app.
/// Every line says what was done or checked, never what it means: "Compared 48,211 files by size and SHA-256: 0 differences."
public struct ActivityEntry: Codable, Hashable, Sendable, Identifiable {
    /// `JournalEntry.lineID`.
    public var id: String
    public var timestamp: Date
    /// The move this line belongs to; nil for app-level lines.
    public var moveID: String?
    public var recipeName: String?
    public var text: String
    public var tone: ActivityTone
    /// The raw journal step name, so an unknown step can still be filtered and shown.
    public var step: String

    public init(id: String, timestamp: Date, moveID: String? = nil, recipeName: String? = nil, text: String, tone: ActivityTone = .normal, step: String) {
        self.id = id
        self.timestamp = timestamp
        self.moveID = moveID
        self.recipeName = recipeName
        self.text = text
        self.tone = tone
        self.step = step
    }
}
