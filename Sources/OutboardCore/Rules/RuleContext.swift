import Foundation

/// Everything the four rule functions need to approve a path: built from a `MovePlan`, from a `RelocationRecord` (the guard,
/// recovery, rollback, the Trash) or from a record plus the drive's current mount point. Paths are absolute and normalised.
/// The Mac verbs take the context, never two free paths, so a call site cannot invent a rename (BUILD_PLAN §4.4).
public struct RuleContext: Sendable, Equatable {
    public var home: String
    public var moveID: String
    public var direction: MoveDirection
    /// `toDrive`: the folder on the Mac. `returnToMac`: the folder on the drive.
    public var sourcePath: String
    /// The folder on the Mac that is renamed, linked or redirected.
    public var macPath: String
    /// `<macPath>.before-move`
    public var beforeMovePath: String
    /// `<mount>/Outboard/<recipe>/.staging-<id>`; empty while the drive is away.
    public var stagingPath: String
    /// `<macPath>.returning-<id>` (the copy coming back to the Mac).
    public var returningPath: String
    /// `<mount>/Outboard/<recipe>/<leaf>`; empty while the drive is away.
    public var finalPath: String
    /// `<home>/Library/Application Support/Outboard/Parked/<id>`
    public var parkedFolder: String
    /// `<mount>/Outboard/<recipe>`; empty while the drive is away.
    public var recipeFolder: String
    /// `/Volumes/<name>`; empty while the drive is away.
    public var mountPoint: String
    /// The state of the record this context was built from (the Trash rule needs `confirmed`).
    public var recordState: MoveState?
    /// Absolute paths of staging or published folders the journal names as leftovers of an aborted or rolled-back move, or of the
    /// drive copy left by a return (see `leftoverPaths`). Set by the caller; empty by default.
    public var knownLeftovers: [String]

    public init(plan: MovePlan, home: String) {
        let h = PathNorm.normalize(home)
        self.home = h
        moveID = plan.id
        direction = plan.direction
        sourcePath = PathNorm.normalize(plan.sourcePath)
        macPath = PathNorm.normalize(plan.macPath)
        beforeMovePath = PathNorm.normalize(plan.beforeMovePath)
        stagingPath = PathNorm.normalize(plan.stagingPath)
        returningPath = PathNorm.normalize(plan.macPath) + Names.returningInfix + plan.id
        finalPath = PathNorm.normalize(plan.destination.finalPath)
        parkedFolder = RuleContext.parkedFolder(home: h, moveID: plan.id)
        recipeFolder = PathNorm.normalize(plan.destination.mountPoint + "/" + plan.destination.recipeFolder)
        mountPoint = PathNorm.normalize(plan.destination.mountPoint)
        recordState = nil
        knownLeftovers = []
    }

    /// `mountPoint` is where the recorded drive is mounted now (nil while it is away: every drive path is then empty and the rules
    /// refuse anything that needs the drive).
    public init(record: RelocationRecord, home: String, mountPoint: String?) {
        let h = PathNorm.normalize(home)
        self.home = h
        moveID = record.id
        direction = record.direction
        let mac = PathNorm.normalize(PathText.expandTilde(record.macPath, home: h))
        macPath = mac
        beforeMovePath = mac + Names.beforeMoveSuffix
        returningPath = mac + Names.returningInfix + record.id
        parkedFolder = RuleContext.parkedFolder(home: h, moveID: record.id)
        if let mountPoint, !mountPoint.isEmpty {
            let m = PathNorm.normalize(mountPoint)
            self.mountPoint = m
            let rel = PathNorm.normalize(record.relativePath)
            finalPath = m + "/" + rel
            let folder = PathNorm.parent(rel)
            recipeFolder = folder.isEmpty ? m : m + "/" + folder
            stagingPath = recipeFolder + "/" + Names.stagingPrefix + record.id
        } else {
            self.mountPoint = ""
            finalPath = ""
            recipeFolder = ""
            stagingPath = ""
        }
        sourcePath = record.direction == .toDrive ? mac : finalPath
        recordState = record.state
        knownLeftovers = []
    }

    static func parkedFolder(home: String, moveID: String) -> String {
        PathNorm.normalize(home) + "/Library/Application Support/" + Names.supportFolder + "/" + Names.parkedFolder + "/" + moveID
    }

    /// `/Volumes/<name>` and nothing else: the only mount shape Outboard accepts (E8, E14).
    static func isStandardMount(_ mount: String) -> Bool {
        let c = PathNorm.components(mount)
        return c.count == 2 && c[0] == "Volumes" && mount.hasPrefix("/Volumes/")
    }

    /// The absolute paths of the leftovers that live on the drive, for `knownLeftovers`. Mac-side items are not trashable by the app
    /// except `<name>.before-move` of a confirmed record, so they are left out.
    public static func leftoverPaths(_ leftovers: [Leftover], mountPoint: String?) -> [String] {
        guard let mountPoint, !mountPoint.isEmpty else { return [] }
        let m = PathNorm.normalize(mountPoint)
        return leftovers.compactMap { l in
            guard l.onDrive, l.kind == .incompleteCopy || l.kind == .rolledBackCopy || l.kind == .driveCopyAfterReturn else { return nil }
            return m + "/" + PathNorm.normalize(l.path)
        }
    }
}
