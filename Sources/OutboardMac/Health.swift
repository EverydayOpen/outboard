import Foundation
import OutboardCore

enum HealthResult: Equatable {
    case healthy
    case failed(String)

    var isHealthy: Bool { self == .healthy }
}

/// "Does the redirect really lead to the drive we recorded?" (W4 and the check after an unpark.) Not "the path exists": the
/// resolved target's volume UUID must equal the recorded one, the sentinel must match, and (right after a swap) the listing must
/// have the manifest's entry count. This type shadows Core's `Health` word inside OutboardMac on purpose (the pinned call is
/// `Health.check(`); Core's value is only reached through `GuardPolicy` and `RelocationHealth`.
enum Health {
    /// The `failed` text for a manifest that could not be read (`MoveEngine` ends the move with `AbortReason.manifestUnreadable` for it).
    static let manifestUnreadable = "The check list made when the copy was taken could not be read."

    /// W4, right after the redirect.
    static func check(_ plan: MovePlan, home: String) -> HealthResult {
        let d = plan.destination
        var writes: [DefaultsWrite] = []
        var domain: String?
        if case .defaults(let dom, let w, _, _) = plan.redirect {
            domain = dom
            writes = w
        }
        return evaluate(method: plan.method, macPath: plan.macPath, volume: VolumeRef(uuid: d.volumeUUID, name: d.volumeName, token: d.volumeToken),
                        mountPoint: d.mountPoint, relativePath: d.relativePath, moveID: plan.id, recipeID: plan.recipeID, domain: domain,
                        writes: writes, compareListing: true, home: home)
    }

    /// After an unpark or a retarget: the same questions about a record, with the drive's mount point as it is now and the setting values
    /// as they were just written. The listing is not compared here (apps have written since); the return check does that.
    static func check(_ record: RelocationRecord, home: String, mountPoint: String, writes: [DefaultsWrite]? = nil) -> HealthResult {
        evaluate(method: record.method, macPath: Fs.expand(record.macPath, home: home), volume: record.volume, mountPoint: mountPoint,
                 relativePath: record.relativePath, moveID: record.id, recipeID: record.recipeID, domain: record.defaultsDomain,
                 writes: writes ?? recomputedWrites(record, mountPoint: mountPoint), compareListing: false, home: home)
    }

    /// The values a `defaults` relocation should read as when the drive is mounted at `mountPoint`: the recipe's path key points at
    /// `<mount>/<relative path>`, every other key keeps the value the move wrote. (The mount point can differ from the one at move time.)
    static func recomputedWrites(_ record: RelocationRecord, mountPoint: String) -> [DefaultsWrite] {
        guard let recipe = Catalogue.recipe(record.recipeID), case .defaults(_, let keys, _) = recipe.method else { return record.defaultsWrites }
        let path = mountPoint + "/" + record.relativePath
        return record.defaultsWrites.map { w in
            var out = w
            if let spec = keys.first(where: { $0.name == w.key }), spec.value == .destinationPath { out.value = path }
            return out
        }
    }

    private static func evaluate(method: MethodKind, macPath: String, volume: VolumeRef, mountPoint: String, relativePath: String, moveID: String,
                                 recipeID: RecipeID, domain: String?, writes: [DefaultsWrite], compareListing: Bool, home: String) -> HealthResult {
        guard VolumeIdentity.matches(volume, mountPoint: mountPoint) else { return .failed("The drive is not where it was.") }
        let folder = mountPoint + "/" + relativePath
        guard Fs.isPlainDirectory(folder) else { return .failed("The data folder is not on the drive.") }
        let sentinel = OutboardRoot.readSentinel(volume, relativePath: relativePath, moveID: moveID, mountPoint: mountPoint)
        guard Sentinel.matches(sentinel, moveID: moveID, recipeID: recipeID, volumeToken: volume.token, relativePath: relativePath) else {
            return .failed("The drive's check file is missing or different.")
        }
        if method == .defaults {
            guard let domain, !writes.isEmpty else { return .failed("The setting is not recorded.") }
            for w in writes {
                guard case .some(.some(let value)) = DefaultsRedirect.currentValue(domain: domain, key: w.key, type: w.type), value == w.value else {
                    return .failed("The setting does not point at the drive.")
                }
            }
        } else {
            guard Fs.kind(Fs.info(macPath).st) == .symlink, Fs.linkTarget(macPath) == folder else {
                return .failed("The link does not point where it was made to.")
            }
            guard VolumeIdentity.same(VolumeIdentity.volumeUUID(ofResolved: macPath), volume.uuid) else {
                return .failed("The link leads to a different volume than the drive.")
            }
            guard Fs.targetErrno(macPath) == 0 else { return .failed("The link cannot be followed.") }
        }
        if compareListing {
            guard let manifest = ManifestStore.load(moveID: moveID, home: home, driveFolder: Fs.parent(of: folder)) else {
                return .failed(manifestUnreadable)
            }
            guard let walked = SizeScanner.walk(folder, xattrs: false), walked.isComplete else {
                return .failed("The copy on the drive could not be listed.")
            }
            guard walked.entries.count == manifest.entries.count else { return .failed("The copy on the drive does not have the manifest's entries.") }
        }
        return .healthy
    }
}
