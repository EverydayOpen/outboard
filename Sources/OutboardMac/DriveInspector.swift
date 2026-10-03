import Foundation
import OutboardCore

/// Gathers the facts about mounted volumes that Core's eligibility table reads: `URLResourceValues`, read-only `diskutil` and
/// `tmutil` output parsed by Core `Parsers`, the Outboard marker, and a look at the volume root. It never caches across a move
/// (E18: every caller asks again) and it never turns a missing key into "eligible": the facts stay unknown and Core decides.
/// Every key name behind this file is VERIFY on macOS 15 and 26 with a real USB-C SSD and a Thunderbolt enclosure (BUILD_PLAN §12).
enum DriveInspector {
    private static let keys: [URLResourceKey] = [
        .volumeUUIDStringKey, .volumeNameKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeIsEjectableKey,
        .volumeIsRemovableKey, .volumeSupportsSymbolicLinksKey, .volumeSupportsHardLinksKey, .volumeSupportsCaseSensitiveNamesKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey, .volumeLocalizedFormatDescriptionKey,
    ]

    /// What the whole list shares: the APFS roles and the Time Machine destinations, read once.
    private struct Shared {
        var apfs: [ApfsVolumeInfo]
        var destinations: [TimeMachineDestination]?
        var nameCounts: [String: Int]
    }

    /// Every mounted, non-hidden volume (the startup volume, external drives, shares, disk images) with its facts.
    /// `policy` is not applied here: inspection reports what is there, and Core's `Eligibility` applies the policy.
    static func volumes(policy: Policy) async -> [DriveFacts] {
        let urls = mountedURLs()
        let shared = await loadShared(urls)
        return await withTaskGroup(of: (Int, DriveFacts).self, returning: [DriveFacts].self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { (index, await facts(for: url, shared: shared)) }
            }
            var out: [(Int, DriveFacts)] = []
            for await item in group { out.append(item) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// One volume, read again right now. `id` is `DriveFacts.id`: the UUID, or `mount:<path>` when the system gave none.
    static func facts(forVolumeID id: String) async -> DriveFacts? {
        let urls = mountedURLs()
        guard let url = urls.first(where: { identifier(of: $0).caseInsensitiveCompare(id) == .orderedSame }) else { return nil }
        return await facts(for: url, shared: await loadShared(urls))
    }

    /// Case sensitivity of the volume holding `path`, as a tri-state.
    static func caseSensitivity(ofPath path: String) -> Tri {
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return Tri(v?.volumeSupportsCaseSensitiveNames)
    }

    // MARK: -

    private static func mountedURLs() -> [URL] {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    }

    private static func identifier(of url: URL) -> String {
        let uuid = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        return uuid ?? "mount:" + Fs.normalized(url.path)
    }

    private static func loadShared(_ urls: [URL]) async -> Shared {
        async let apfsOut = ProcessRunner.runAsync(.diskutilApfsList)
        async let tmOut = ProcessRunner.runAsync(.tmutilDestinations)
        let (apfs, tm) = await (apfsOut, tmOut)
        var counts: [String: Int] = [:]
        for url in urls {
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
            counts[name, default: 0] += 1
        }
        return Shared(apfs: apfs.ok ? Parsers.apfsList(apfs.stdout) : [],
                      destinations: tm.ok ? Parsers.tmutilDestinations(tm.stdout) : nil,
                      nameCounts: counts)
    }

    private static func resourceFacts(_ url: URL) -> ResourceFacts {
        let v = try? url.resourceValues(forKeys: Set(keys))
        return ResourceFacts(uuid: v?.volumeUUIDString, name: v?.volumeName ?? url.lastPathComponent, mountPoint: Fs.normalized(url.path),
                             isLocal: v?.volumeIsLocal, isInternal: v?.volumeIsInternal, isReadOnly: v?.volumeIsReadOnly,
                             isEjectable: v?.volumeIsEjectable, isRemovable: v?.volumeIsRemovable,
                             supportsSymlinks: v?.volumeSupportsSymbolicLinks, supportsHardLinks: v?.volumeSupportsHardLinks,
                             isCaseSensitive: v?.volumeSupportsCaseSensitiveNames,
                             availableBytes: v?.volumeAvailableCapacityForImportantUsage.map { UInt64(max(0, $0)) },
                             totalBytes: v?.volumeTotalCapacity.map { UInt64(max(0, $0)) },
                             formatDescription: v?.volumeLocalizedFormatDescription)
    }

    private static func facts(for url: URL, shared: Shared) async -> DriveFacts {
        let resource = resourceFacts(url)
        // `diskutil info` for a share can be slow and says little; a failed or unreadable answer stays nil (unknown).
        var info: DiskutilInfo?
        if resource.isLocal != false {
            let out = await ProcessRunner.runAsync(.diskutilInfo(path: resource.mountPoint))
            if out.ok { info = Parsers.diskutilInfo(out.stdout) }
        }
        let apfs = shared.apfs.first { VolumeIdentity.same($0.volumeUUID, resource.uuid) }
        // Time Machine signal 3 and the Outboard marker are looks at the volume root; skip them for a volume that is not local.
        let backupAtRoot: Tri = resource.isLocal == false ? .unknown : Disks.backupFolderAtRoot(mountPoint: resource.mountPoint)
        let marker = resource.isLocal == false ? nil : OutboardRoot.readMarker(mountPoint: resource.mountPoint)
        let sibling = Disks.siblingTimeMachine(in: apfs?.containerReference ?? info?.apfsContainerReference, ownUUID: resource.uuid,
                                               volumes: shared.apfs)
        // The link speed is not read in v1.0, so the USB 2 refusal in E5 is inert and a drive on a slow link is accepted. Mapping a BSD
        // disk to its IOKit USB device ("Device Speed") cannot be checked without a real Mac (VERIFY); Core keeps the rule for then.
        return DriveFactsBuilder.build(resource: resource, info: info, apfs: apfs, tmDestinations: shared.destinations,
                                       backupFolderAtRoot: backupAtRoot, siblingTimeMachineInContainer: sibling, marker: marker,
                                       sameNameCount: shared.nameCounts[resource.name] ?? 1,
                                       isSyncedLocation: NeverList.isSyncedPath(resource.mountPoint), linkMegabitsPerSecond: nil)
    }
}
