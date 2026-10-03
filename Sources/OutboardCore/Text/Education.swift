import Foundation

/// One of the five first-run cards. Always reachable from Help; the same text feeds the site from the golden file, so the app and
/// the site cannot disagree.
public struct EducationCard: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var body: String
    /// A sentence the card shows in bold (the limit the app has).
    public var emphasis: String?
    public var buttonTitle: String?
    public var buttonNote: String?

    public init(id: String, title: String, body: String, emphasis: String? = nil, buttonTitle: String? = nil, buttonNote: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.emphasis = emphasis
        self.buttonTitle = buttonTitle
        self.buttonNote = buttonNote
    }
}

public enum Education {
    public static let cards: [EducationCard] = [
        EducationCard(id: "what-this-does", title: "What this does",
                      body: "Outboard finds the big folders that apps keep on your Mac. For apps where it's known to work, it moves them to an external drive you choose. It looks first, and changes nothing until you say so."),
        EducationCard(id: "what-can-move", title: "What can move",
                      body: "Xcode build data. iPhone and iPad backups. Ollama and Hugging Face models. For Photos, Music, Final Cut Pro and Steam it shows you the steps; those apps do the moving themselves."),
        EducationCard(id: "what-never-moves", title: "What never moves",
                      body: "Mail, Safari and Messages. Anything inside iCloud Drive. Apps' sandboxed data. Homebrew. Your home folder. Your whole Caches folder. These can break an app or lock you out, so Outboard won't touch them."),
        EducationCard(id: "how-a-move-works", title: "How a move works",
                      body: "It copies the folder to your drive, then checks every file against the original. Only if every file matches does it switch the app over. Your original stays on your Mac, renamed, until you've tried the app and said it works. Nothing is deleted without you."),
        EducationCard(id: "if-you-unplug", title: "If you unplug the drive",
                      body: "The apps that use it can't see their data until it's back. While Outboard is running it notices, puts a note where the data was so apps stop instead of starting fresh, and puts things back when the drive returns. If the drive is removed without ejecting, you'll be asked to check your files first.",
                      emphasis: "Outboard can't stop you unplugging a drive or make that harmless.",
                      buttonTitle: "Keep Outboard running at login",
                      buttonNote: "Without it, an unplugged drive leaves apps pointing at nothing until you open Outboard."),
    ]

    /// Disk Utility steps for a drive that holds other data. Menu names and format labels are VERIFY on macOS 15 and 26 before this copy ships.
    public static let driveSteps: [String] = [
        "Open Disk Utility. Select the drive's APFS volume in the sidebar.",
        "Click Add Volume in the toolbar. Name it Outboard.",
        "For the format, choose an APFS option. Choose the encrypted option if you'll move iPhone backups. macOS will ask you for a password and offer to remember it in your keychain; Outboard never sees it.",
        "Size options are optional: a quota stops Outboard from using all the drive's space; a reserve keeps room for it. Adding a volume doesn't erase the others; they share the drive's free space.",
        "Come back here and choose Outboard.",
    ]

    public static let driveStepsTitle = "We recommend a separate volume just for this."
    public static let useDriveNote = "Use this drive writes one small file on it, and nothing else."

    /// A drive in a bad format: Outboard never formats anything.
    public static func badFormat(_ format: String) -> String {
        "This drive is \(format). Apps need APFS. Changing the format erases everything on it, and Outboard can't do that for you."
    }

    public static let guardOn = "Guard is on while Outboard is running. It watches your drives and keeps a notice in the menu bar."
    public static let guardQuit = "If you quit, nothing watches your drives. If a drive is unplugged, apps that use it will see a missing folder until Outboard runs again."
    public static let loginItemNeedsApproval = "macOS needs your OK in System Settings > Login Items before Outboard can start at login."
    public static let somethingNotMovable = "Some of System Data is not movable by any app."
    public static let fullDiskAccessSteps = "To measure and move iPhone backups, allow Outboard in System Settings, Privacy & Security, Full Disk Access. Outboard changes nothing until you do."
    public static let sleepAndHubs = "Sleep can disconnect drives, hubs more often. If you can, plug the drive straight in. Outboard doesn't change your power settings."

    /// The golden file the site builder reads (`Tests/OutboardCoreTests/Fixtures/export/education.json`).
    public static func exportJSON() -> String {
        JSONValue.object([
            "schema": .num(1),
            "cards": .array(cards.map { card in
                .object([
                    "id": .string(card.id), "title": .string(card.title), "body": .string(card.body),
                    "emphasis": .optional(card.emphasis), "buttonTitle": .optional(card.buttonTitle), "buttonNote": .optional(card.buttonNote),
                ])
            }),
            "driveSteps": .strings(driveSteps),
            "driveStepsTitle": .string(driveStepsTitle),
            "guardOn": .string(guardOn),
            "guardQuit": .string(guardQuit),
            "footer": .string(ReportText.footer),
            "affiliation": .string(Names.affiliation),
        ]).render() + "\n"
    }
}
