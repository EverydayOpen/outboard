import Foundation
import OutboardCore
#if DEBUG
@testable import OutboardMac

// Runs one move to the drive and dies (`_exit(9)`) at the journal record named on the command line, so the Mac tests can run recovery
// on the same disk afterwards and check the recovery theorem on real files (BUILD_PLAN §6.3). Debug builds only: the hooks it arms
// do not exist in a Release build, and a Release build of this helper does nothing.
//
//   OutboardCrashHelper --home <fake home> --volume <volume id> --recipe <recipe id> --arm <intent|act>:<step>:<occurrence>
//
// Use a recipe that does not write to the real user's preferences (a link recipe such as npm-cache).

var home: String?
var volume: String?
var recipe: String?
var arm: String?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let flag = arguments.next() {
    switch flag {
    case "--home": home = arguments.next()
    case "--volume": volume = arguments.next()
    case "--recipe": recipe = arguments.next()
    case "--arm": arm = arguments.next()
    default: exit(64)
    }
}
guard let home, let volume, let recipe, let arm else { exit(64) }

let parts = arm.split(separator: ":").map(String.init)
guard parts.count == 3, let step = MoveStep(rawValue: parts[1]), let occurrence = Int(parts[2]), parts[0] == "intent" || parts[0] == "act" else { exit(64) }
guard let chosen = Catalogue.recipe(recipe), chosen.method.kind == .symlink else { exit(65) }

let backend = LiveBackend.make(home: home, appVersion: "crash-helper", policy: .testing)
let report = await backend.eligibility(volume, recipe)
guard report.isAllowed else { exit(66) }
let consent = ConsentRecord(recipeVersion: chosen.version, tickedIDs: chosen.consent?.checkboxes.map(\.id) ?? [], ackIDs: report.acks.map(\.ackID),
                            sawUnverifiedNote: true)
let planned = await backend.plan(recipe, volume, consent)
guard let plan = planned.plan else { exit(67) }

Faults.arm(parts[0] == "intent" ? .afterIntent(step) : .afterAct(step), occurrence: occurrence)
_ = await backend.move(plan, { _ in })
// Reaching this line means the armed point was never hit.
exit(0)
#else
exit(0)
#endif
