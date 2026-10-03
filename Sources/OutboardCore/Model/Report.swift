import Foundation

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case markdown, json
    /// The Storage Plan card as an image (1200x630) or its one-line text.
    case cardPNG, cardText
}

/// What the export sheet chose. Nothing is written without a save panel; nothing is uploaded.
public struct ReportOptions: Codable, Hashable, Sendable {
    /// "Hide folder and drive names": paths become recipe names, drives become "Drive 1", "Drive 2", and no volume identifier is written.
    public var hidePaths: Bool
    public var appVersion: String
    public var macOSVersion: String
    /// "Mac14,12". Optional so it can be left out.
    public var macModel: String?
    public var now: Date
    /// Demo mode: the report carries the "Sample data" watermark.
    public var isSample: Bool

    public init(hidePaths: Bool = false, appVersion: String, macOSVersion: String, macModel: String? = nil, now: Date, isSample: Bool = false) {
        self.hidePaths = hidePaths
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.macModel = macModel
        self.now = now
        self.isSample = isSample
    }
}

public struct ReportDrive: Codable, Hashable, Sendable {
    public var name: String
    /// First 8 characters of the volume UUID; empty when the report hides drive names.
    public var uuidPrefix: String
    public var format: String
    public var encrypted: Tri
    public var firstUsed: Date?

    public init(name: String, uuidPrefix: String, format: String, encrypted: Tri, firstUsed: Date? = nil) {
        self.name = name
        self.uuidPrefix = uuidPrefix
        self.format = format
        self.encrypted = encrypted
        self.firstUsed = firstUsed
    }
}

public struct ReportRelocation: Codable, Hashable, Sendable {
    public var recipeID: RecipeID
    public var recipeName: String
    public var methodLabel: String
    /// `~`-relative, or the recipe name when paths are hidden.
    public var source: String
    public var destination: String
    public var logicalBytes: UInt64
    public var fileCount: Int
    public var state: MoveState
    /// The health word, when the relocation is active ("Healthy", "Drive away").
    public var health: String?
    public var safetyCopy: SafetyCopyState
    public var verification: VerificationSummary?
    public var unresolved: [String]
    public var timeline: [ActivityEntry]

    public init(recipeID: RecipeID, recipeName: String, methodLabel: String, source: String, destination: String, logicalBytes: UInt64,
                fileCount: Int, state: MoveState, health: String? = nil, safetyCopy: SafetyCopyState, verification: VerificationSummary? = nil,
                unresolved: [String] = [], timeline: [ActivityEntry] = []) {
        self.recipeID = recipeID
        self.recipeName = recipeName
        self.methodLabel = methodLabel
        self.source = source
        self.destination = destination
        self.logicalBytes = logicalBytes
        self.fileCount = fileCount
        self.state = state
        self.health = health
        self.safetyCopy = safetyCopy
        self.verification = verification
        self.unresolved = unresolved
        self.timeline = timeline
    }
}

/// The export report as data (JSON `schema: 1`). Core `ReportText` builds it from the journal and the records and renders both
/// the Markdown and the JSON, golden-file tested. The footer is fixed text and is never widened.
public struct ReportDocument: Codable, Hashable, Sendable {
    public var schema: Int
    public var appVersion: String
    public var macOSVersion: String
    public var macModel: String?
    public var generatedAt: Date
    /// "Generated on this Mac. Not uploaded."
    public var provenance: String
    public var isSample: Bool
    public var drives: [ReportDrive]
    public var relocations: [ReportRelocation]
    /// Every abort, rollback, held and conflict with its reason.
    public var problems: [String]
    public var footer: String

    public init(schema: Int = 1, appVersion: String, macOSVersion: String, macModel: String? = nil, generatedAt: Date, provenance: String,
                isSample: Bool = false, drives: [ReportDrive], relocations: [ReportRelocation], problems: [String], footer: String) {
        self.schema = schema
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.macModel = macModel
        self.generatedAt = generatedAt
        self.provenance = provenance
        self.isSample = isSample
        self.drives = drives
        self.relocations = relocations
        self.problems = problems
        self.footer = footer
    }
}
