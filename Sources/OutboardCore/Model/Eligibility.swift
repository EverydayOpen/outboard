import Foundation

/// The destination rules E1 to E19 (APP6 §4.3). The raw value is the id shown in the diagnostics and the journal.
public enum EligibilityRule: String, Codable, CaseIterable, Sendable {
    case e1 = "E1"      // local disk only (not smbfs, nfs, afpfs, webdav)
    case e2 = "E2"      // not a disk image
    case e3 = "E3"      // external (not internal)
    case e4 = "E4"      // APFS; Mac OS Extended warns; exFAT, FAT, NTFS, ext refuse
    case e5 = "E5"      // solid state (and a known USB 2 link refuses)
    case e6 = "E6"      // writable
    case e7 = "E7"      // not a Time Machine volume (three signals)
    case e8 = "E8"      // identity usable: UUID present, /Volumes/<name>, unique name
    case e9 = "E9"      // ownership honoured
    case e10 = "E10"    // case sensitivity compatible
    case e11 = "E11"    // symbolic links (and hard links when the source has them)
    case e12 = "E12"    // free space
    case e13 = "E13"    // not in iCloud or a sync folder
    case e14 = "E14"    // mounted under /Volumes
    case e15 = "E15"    // SMART not failing
    case e16 = "E16"    // encrypted, for sensitive recipes
    case e17 = "E17"    // carries our marker
    case e18 = "E18"    // fresh: unchanged between the plan and the swap
    case e19 = "E19"    // hubs and sleep (information, once)
}

/// Refuse: the drive cannot be picked for this recipe. Ack: needs a ticked box in the consent sheet. Warn: shown, no box.
/// Info: shown quietly. **Unknown signal: refuse for irreplaceable recipes, ack otherwise**, and the message names the signal.
public enum EligibilityOutcome: String, Codable, CaseIterable, Sendable {
    case refuse, ack, warn, info

    public var isBlocking: Bool { self == .refuse }
}

public struct EligibilityVerdict: Codable, Hashable, Sendable, Identifiable {
    public var rule: EligibilityRule
    public var outcome: EligibilityOutcome
    /// The exact user-facing copy from APP6 §4.3 (banned-phrase clean), with names and numbers filled in.
    public var message: String
    /// The signal that was unknown, when the verdict is the unknown-signal outcome ("Time Machine status").
    public var unknownSignal: String?

    public init(rule: EligibilityRule, outcome: EligibilityOutcome, message: String, unknownSignal: String? = nil) {
        self.rule = rule
        self.outcome = outcome
        self.message = message
        self.unknownSignal = unknownSignal
    }

    public var id: String { "\(rule.rawValue)|\(outcome.rawValue)" }
    /// The id a ticked acknowledgement is journaled under (`ack-e16`).
    public var ackID: String { "ack-\(rule.rawValue.lowercased())" }

    /// The message as the drive chooser shows it, where there is nothing to tick: an acknowledgement's "Tick to confirm it is." becomes
    /// "You'll be asked to confirm it is in the next step." The box itself (`message`, via `ConsentSheetText`) keeps the pinned wording.
    public var plateText: String {
        guard outcome == .ack, let tick = message.range(of: "Tick to confirm ") else { return message }
        var rest = String(message[tick.upperBound...])
        if rest.hasSuffix(".") { rest.removeLast() }
        return String(message[..<tick.lowerBound]) + "You'll be asked to confirm \(rest) in the next step."
    }
}

/// The verdicts for one drive and one recipe, with the derived answers the UI reads. One source for "can I pick this drive".
public struct EligibilityReport: Codable, Hashable, Sendable {
    public var volumeID: String
    public var recipeID: RecipeID?
    public var verdicts: [EligibilityVerdict]

    public init(volumeID: String, recipeID: RecipeID? = nil, verdicts: [EligibilityVerdict]) {
        self.volumeID = volumeID
        self.recipeID = recipeID
        self.verdicts = verdicts
    }

    public var refusals: [EligibilityVerdict] { verdicts.filter { $0.outcome == .refuse } }
    public var acks: [EligibilityVerdict] { verdicts.filter { $0.outcome == .ack } }
    public var warnings: [EligibilityVerdict] { verdicts.filter { $0.outcome == .warn } }
    public var infos: [EligibilityVerdict] { verdicts.filter { $0.outcome == .info } }
    /// Allowed to be picked (acks still need their ticks).
    public var isAllowed: Bool { refusals.isEmpty }
    /// The first refusal, in rule order, for the one-line reason in the drive list.
    public var firstRefusal: EligibilityVerdict? { refusals.first }
}

public extension Sequence where Element == EligibilityVerdict {
    var hasRefusal: Bool { contains { $0.outcome == .refuse } }
}
