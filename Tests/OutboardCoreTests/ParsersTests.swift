import Foundation
import XCTest
@testable import OutboardCore

final class ParsersTests: XCTestCase {
    private func plist(_ body: String) -> Data {
        Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict>\(body)</dict></plist>".utf8)
    }

    // The key names are VERIFY on macOS 15 and 26 (the probe workflow records real output); these are table tests of the parser.
    private let infoApfs = """
    <key>DeviceIdentifier</key><string>disk5s1</string><key>VolumeUUID</key><string>3e1c0b7a-0000-4000-8000-000000000001</string>
    <key>VolumeName</key><string>Outboard</string><key>MountPoint</key><string>/Volumes/Outboard</string><key>FilesystemType</key><string>apfs</string>
    <key>BusProtocol</key><string>USB</string><key>Internal</key><false/><key>SolidState</key><true/><key>WritableVolume</key><true/>
    <key>FileVault</key><true/><key>SMARTStatus</key><string>Not Supported</string><key>GlobalPermissionsEnabled</key><true/>
    <key>TotalSize</key><integer>500000000000</integer><key>ParentWholeDisk</key><string>disk5</string>
    <key>APFSContainerReference</key><string>disk5</string>
    <key>APFSPhysicalStores</key><array><dict><key>APFSPhysicalStore</key><string>disk4s2</string></dict></array>
    """

    func testDiskutilInfoReadsEveryKey() throws {
        let info = try XCTUnwrap(Parsers.diskutilInfo(plist(infoApfs)))
        XCTAssertEqual(info.deviceIdentifier, "disk5s1")
        XCTAssertEqual(info.volumeUUID, "3E1C0B7A-0000-4000-8000-000000000001", "UUIDs are upper case")
        XCTAssertEqual(info.volumeName, "Outboard")
        XCTAssertEqual(info.mountPoint, "/Volumes/Outboard")
        XCTAssertEqual(info.filesystemType, "apfs")
        XCTAssertEqual(info.busProtocol, "USB")
        XCTAssertEqual(info.isInternal, .no)
        XCTAssertEqual(info.isSolidState, .yes)
        XCTAssertEqual(info.isWritable, .yes)
        XCTAssertEqual(info.isEncrypted, .yes)
        XCTAssertEqual(info.isLocked, .unknown, "a key that isn't there is unknown, never no")
        XCTAssertEqual(info.smart, .notSupported)
        XCTAssertEqual(info.ownershipHonoured, .yes)
        XCTAssertEqual(info.totalSize, 500_000_000_000)
        XCTAssertEqual(info.parentWholeDisk, "disk5")
        XCTAssertEqual(info.apfsPhysicalStores, ["disk4s2"])
        XCTAssertEqual(info.apfsContainerReference, "disk5")
    }

    func testDiskutilInfoNeverTurnsAMissingOrMistypedKeyIntoYes() throws {
        let info = try XCTUnwrap(Parsers.diskutilInfo(plist("<key>DeviceIdentifier</key><string>disk9s1</string><key>Internal</key><string>No</string><key>SolidState</key><integer>1</integer>")))
        XCTAssertEqual(info.isInternal, .unknown, "a string is not a Boolean")
        XCTAssertEqual(info.isSolidState, .unknown)
        XCTAssertEqual(info.isWritable, .unknown)
        XCTAssertEqual(info.smart, .unknown)
        XCTAssertEqual(info.ownershipHonoured, .unknown)
        XCTAssertNil(info.filesystemType)
    }

    func testDiskutilInfoRejectsGarbage() {
        XCTAssertNil(Parsers.diskutilInfo(Data()))
        XCTAssertNil(Parsers.diskutilInfo(Data("not a plist".utf8)))
        XCTAssertNil(Parsers.diskutilInfo(plist("<key>Other</key><string>x</string>")), "nothing recognisable")
        XCTAssertNil(Parsers.diskutilInfo(Data(count: Parsers.maxPlistBytes + 1)))
        XCTAssertEqual(Parsers.diskutilInfo(plist("<key>SMARTStatus</key><string>Failing</string><key>DeviceIdentifier</key><string>d</string>"))?.smart, .failing)
        XCTAssertEqual(Parsers.diskutilInfo(plist("<key>SMARTStatus</key><string>Verified</string><key>DeviceIdentifier</key><string>d</string>"))?.smart, .verified)
        XCTAssertEqual(Parsers.diskutilInfo(plist("<key>Writable</key><false/><key>DeviceIdentifier</key><string>d</string>"))?.isWritable, .no, "falls back to Writable")
    }

    func testApfsList() {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Containers</key><array>
        <dict><key>ContainerReference</key><string>disk5</string><key>Volumes</key><array>
          <dict><key>APFSVolumeUUID</key><string>aaaaaaaa-0000-4000-8000-000000000001</string><key>Roles</key><array><string>Backup</string></array>
                <key>FileVault</key><false/><key>Locked</key><false/><key>CapacityQuota</key><integer>0</integer></dict>
          <dict><key>APFSVolumeUUID</key><string>bbbbbbbb-0000-4000-8000-000000000002</string><key>Roles</key><array/>
                <key>FileVault</key><true/><key>CapacityQuota</key><integer>100000000000</integer><key>CapacityReserve</key><integer>5000000000</integer></dict>
        </array></dict></array></dict></plist>
        """.utf8)
        let volumes = Parsers.apfsList(data)
        XCTAssertEqual(volumes.count, 2)
        XCTAssertEqual(volumes[0].volumeUUID, "AAAAAAAA-0000-4000-8000-000000000001")
        XCTAssertTrue(volumes[0].isBackupRole)
        XCTAssertEqual(volumes[0].isEncrypted, .no)
        XCTAssertNil(volumes[0].quotaBytes, "a quota of 0 means none")
        XCTAssertEqual(volumes[0].containerReference, "disk5")
        XCTAssertFalse(volumes[1].isBackupRole)
        XCTAssertEqual(volumes[1].isEncrypted, .yes)
        XCTAssertEqual(volumes[1].isLocked, .unknown)
        XCTAssertEqual(volumes[1].quotaBytes, 100_000_000_000)
        XCTAssertEqual(volumes[1].reserveBytes, 5_000_000_000)
        XCTAssertEqual(Parsers.apfsList(Data("nope".utf8)), [])
    }

    func testTmutilDestinations() {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Destinations</key><array>
        <dict><key>Name</key><string>Backup</string><key>ID</key><string>cccccccc-0000-4000-8000-000000000003</string><key>MountPoint</key><string>/Volumes/Backup</string><key>Kind</key><string>Local</string></dict>
        </array></dict></plist>
        """.utf8)
        let d = Parsers.tmutilDestinations(data)
        XCTAssertEqual(d?.count, 1)
        XCTAssertEqual(d?.first?.name, "Backup")
        XCTAssertEqual(d?.first?.mountPoint, "/Volumes/Backup")
        XCTAssertEqual(d?.first?.volumeUUID, "CCCCCCCC-0000-4000-8000-000000000003")
        XCTAssertEqual(Parsers.tmutilDestinations(plist("<key>Other</key><string>x</string>")), [], "a plist without destinations: none configured")
        XCTAssertNil(Parsers.tmutilDestinations(Data("tmutil: No destinations configured.".utf8)), "plain text is unknown, not 'none'")
        XCTAssertNil(Parsers.tmutilDestinations(Data()))
    }

    func testDefaultsRead() {
        XCTAssertEqual(Parsers.defaultsRead("2\n", type: .int), "2")
        XCTAssertEqual(Parsers.defaultsRead("-1", type: .int), "-1")
        XCTAssertNil(Parsers.defaultsRead("two", type: .int))
        XCTAssertNil(Parsers.defaultsRead("1.5", type: .int))
        XCTAssertNil(Parsers.defaultsRead("", type: .int))
        XCTAssertNil(Parsers.defaultsRead("\nThe domain/default pair of (com.apple.dt.Xcode, IDECustomDerivedDataLocation) does not exist\n", type: .string))
        XCTAssertEqual(Parsers.defaultsRead("/Users/jane/Build\n", type: .string), "/Users/jane/Build")
        XCTAssertEqual(Parsers.defaultsRead("\"/Volumes/My Drive/DerivedData\"\n", type: .string), "/Volumes/My Drive/DerivedData")
        XCTAssertEqual(Parsers.defaultsRead("\"say \\\"hi\\\"\"", type: .string), "say \"hi\"")
        // non-ASCII drive names come back as \Uxxxx escapes (VERIFY on a Mac)
        XCTAssertEqual(Parsers.defaultsRead("\"/Volumes/Caf\\U00e9 Drive/DerivedData\"", type: .string), "/Volumes/Caf\u{e9} Drive/DerivedData")
        XCTAssertEqual(Parsers.defaultsRead("\"/Volumes/Fast \\Ud83d\\Ude80\"", type: .string), "/Volumes/Fast \u{1F680}", "a surrogate pair is one character")
        XCTAssertEqual(Parsers.defaultsRead("\"a\\\\b \\U00e9\"", type: .string), "a\\b \u{e9}", "an escaped backslash stays a backslash")
        XCTAssertEqual(Parsers.defaultsRead("\"x\\U12\"", type: .string), "xU12", "a short escape is not decoded")
        XCTAssertNil(Parsers.defaultsRead("(\n    a,\n    b\n)", type: .string), "an array is not a scalar")
        XCTAssertNil(Parsers.defaultsRead("{\n a = 1;\n}", type: .string))
    }

    func testMarkerAndSentinelRoundTripAndRefuseTheWrongSchema() throws {
        let marker = VolumeMarker(uuid: T.uuid, token: T.token, createdAt: T.t0, appVersion: "1.0.0")
        let data = try XCTUnwrap(Parsers.markerData(marker))
        XCTAssertEqual(Parsers.volumeMarker(data), marker)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertTrue(text.contains("\"createdAt\":\"2027-01-15T08:00:00Z\""))
        XCTAssertTrue(text.contains("\"token\":"))
        XCTAssertNil(Parsers.volumeMarker(Data(text.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":2").utf8)))
        XCTAssertNil(Parsers.volumeMarker(Data("{}".utf8)))
        XCTAssertNil(Parsers.volumeMarker(Data()))
        XCTAssertNil(Parsers.volumeMarker(Data(count: Parsers.maxSmallJSONBytes + 1)))

        let sentinel = Sentinel(moveID: "20270115T080000Z-3fa9c1", recipeID: "ollama-models", volumeToken: T.token, relativePath: "Outboard/ollama-models/models", createdAt: T.t0)
        let s = try XCTUnwrap(Parsers.sentinelData(sentinel))
        XCTAssertEqual(Parsers.sentinel(s), sentinel)
        XCTAssertTrue(Sentinel.matches(Parsers.sentinel(s), moveID: sentinel.moveID, recipeID: sentinel.recipeID, volumeToken: T.token, relativePath: sentinel.relativePath))
        XCTAssertFalse(Sentinel.matches(Parsers.sentinel(s), moveID: sentinel.moveID, recipeID: sentinel.recipeID, volumeToken: "other", relativePath: sentinel.relativePath))
    }

    func testManifestRoundTrip() throws {
        let entries = [TreeEntry(path: "a", type: .directory), TreeEntry(path: "a/b.bin", type: .file, size: 5, sha256: "ab")]
        let m = ManifestFile(moveID: "m", recipeID: "ollama-models", createdAt: T.t0, entries: entries, digest: "d")
        let data = try XCTUnwrap(Parsers.manifestData(m))
        XCTAssertEqual(Parsers.manifest(data), m)
        XCTAssertNil(Parsers.manifest(Data("[]".utf8)))
    }

    func testTheWriterAndTheReaderShareOneManifestLimit() throws {
        XCTAssertEqual(Parsers.maxManifestBytes, Limits.maxManifestBytes, "a manifest that was written can always be read back")
        let most = Limits.maxManifestBytes / Limits.manifestBytesPerEntryEstimate
        XCTAssertTrue(Limits.manifestFits(entryCount: 100_000))
        XCTAssertTrue(Limits.manifestFits(entryCount: most))
        XCTAssertFalse(Limits.manifestFits(entryCount: most + 1))
        XCTAssertFalse(Limits.manifestFits(entryCount: -1))
        // The per-entry estimate is above what an entry with a 180-character path really takes once it is written.
        let sha = String(repeating: "ab", count: 32)
        let entries = (0..<1_000).map { TreeEntry(path: String(repeating: "p", count: 180) + String($0), type: .file, size: 1_234_567, mtimeSeconds: 1_700_000_000, sha256: sha) }
        let m = ManifestFile(moveID: "m", recipeID: "ollama-models", createdAt: T.t0, entries: entries, digest: "d")
        let bytes = try XCTUnwrap(Parsers.manifestData(m)).count
        XCTAssertLessThan(bytes / entries.count, Limits.manifestBytesPerEntryEstimate)
        XCTAssertEqual(Parsers.manifest(try XCTUnwrap(Parsers.manifestData(m)))?.entries.count, entries.count)
    }

    // MARK: the builder

    private func resource(_ mutate: (inout ResourceFacts) -> Void = { _ in }) -> ResourceFacts {
        var r = ResourceFacts(uuid: T.uuid, name: "Outboard", mountPoint: "/Volumes/Outboard", isLocal: true, isInternal: false, isReadOnly: false,
                              isEjectable: true, isRemovable: false, supportsSymlinks: true, supportsHardLinks: true, isCaseSensitive: false,
                              availableBytes: 480_000_000_000, totalBytes: 500_000_000_000, formatDescription: "APFS")
        mutate(&r)
        return r
    }

    private func build(_ r: ResourceFacts, info: DiskutilInfo? = nil, apfs: ApfsVolumeInfo? = nil, tm: [TimeMachineDestination]? = [], marker: VolumeMarker? = nil,
                       root: Tri = .no, sameName: Int = 1) -> DriveFacts {
        DriveFactsBuilder.build(resource: r, info: info, apfs: apfs, tmDestinations: tm, backupFolderAtRoot: root, siblingTimeMachineInContainer: false,
                                marker: marker, sameNameCount: sameName, isSyncedLocation: false, linkMegabitsPerSecond: nil)
    }

    func testBuilderMergesTheSources() throws {
        let info = try XCTUnwrap(Parsers.diskutilInfo(plist(infoApfs)))
        let apfs = ApfsVolumeInfo(volumeUUID: T.uuid, roles: [], isEncrypted: .yes, quotaBytes: 100_000_000_000)
        let marker = VolumeMarker(uuid: T.uuid.lowercased(), token: T.token, createdAt: T.t0, appVersion: "1")
        let d = build(resource(), info: info, apfs: apfs, marker: marker)
        XCTAssertEqual(d.uuid, T.uuid)
        XCTAssertEqual(d.fileSystem, .apfs)
        XCTAssertEqual(d.bus, .usb)
        XCTAssertEqual(d.isInternal, .no)
        XCTAssertEqual(d.isWritable, .yes)
        XCTAssertEqual(d.isSolidState, .yes)
        XCTAssertEqual(d.isEncrypted, .yes)
        XCTAssertEqual(d.ownershipHonoured, .yes)
        XCTAssertEqual(d.quotaBytes, 100_000_000_000)
        XCTAssertEqual(d.capacityBytes, 500_000_000_000)
        XCTAssertTrue(d.isStandardMount)
        XCTAssertTrue(d.hasOutboardMarker)
        XCTAssertEqual(d.markerToken, T.token)
        XCTAssertEqual(d.timeMachine.apfsBackupRole, .no)
        XCTAssertEqual(d.timeMachine.listedByTmutil, .no)
        XCTAssertTrue(Eligibility.evaluate(volume: d, recipe: T.recipe("ollama-models"), source: SourceNeeds(logicalBytes: 1_000_000_000), policy: .release).isAllowed)
    }

    func testBuilderFailsClosedOnMissingKeys() {
        let d = build(resource { $0.isInternal = nil; $0.isReadOnly = nil; $0.isLocal = nil; $0.supportsSymlinks = nil; $0.isCaseSensitive = nil },
                      info: nil, apfs: nil, tm: nil)
        XCTAssertEqual(d.isInternal, .unknown)
        XCTAssertEqual(d.isWritable, .unknown)
        XCTAssertFalse(d.isLocal, "an unknown local flag is not 'local'")
        XCTAssertEqual(d.supportsSymlinks, .unknown)
        XCTAssertEqual(d.isCaseSensitive, .unknown)
        XCTAssertEqual(d.isSolidState, .unknown)
        XCTAssertEqual(d.isEncrypted, .unknown)
        XCTAssertEqual(d.smart, .unknown)
        XCTAssertEqual(d.timeMachine.apfsBackupRole, .unknown, "an APFS volume with no listing: the role is unknown")
        XCTAssertEqual(d.timeMachine.listedByTmutil, .unknown)
        XCTAssertFalse(Eligibility.evaluate(volume: d, recipe: T.recipe("ollama-models"), source: SourceNeeds(logicalBytes: 1), policy: .release).isAllowed)
    }

    func testBuilderTakesTheStricterAnswerWhenSourcesDisagree() throws {
        var info = try XCTUnwrap(Parsers.diskutilInfo(plist(infoApfs)))
        info.isInternal = .yes
        XCTAssertEqual(build(resource(), info: info).isInternal, .yes)
        info.isInternal = .no
        info.isWritable = .no
        XCTAssertEqual(build(resource(), info: info).isWritable, .no)
        XCTAssertEqual(build(resource { $0.isReadOnly = true }, info: nil).isWritable, .no)
    }

    func testBuilderTimeMachineSignals() {
        let apfsOnly = ApfsVolumeInfo(volumeUUID: T.uuid, roles: ["Backup"])
        XCTAssertEqual(build(resource(), apfs: apfsOnly).timeMachine.apfsBackupRole, .yes)
        let byUUID = [TimeMachineDestination(name: "x", mountPoint: nil, volumeUUID: T.uuid.lowercased())]
        XCTAssertEqual(build(resource(), tm: byUUID).timeMachine.listedByTmutil, .yes)
        let byMount = [TimeMachineDestination(name: "x", mountPoint: "/Volumes/Outboard/", volumeUUID: nil)]
        XCTAssertEqual(build(resource(), tm: byMount).timeMachine.listedByTmutil, .yes)
        XCTAssertEqual(build(resource(), tm: nil).timeMachine.listedByTmutil, .unknown)
        XCTAssertEqual(build(resource(), tm: []).timeMachine.listedByTmutil, .no)
        XCTAssertEqual(build(resource(), root: .yes).timeMachine.backupFolderAtRoot, .yes)
        XCTAssertTrue(build(resource(), apfs: apfsOnly).timeMachine.anyYes)
    }

    func testBuilderIdentityAndMarker() {
        // A stale /Volumes/Outboard makes the real drive mount as "Outboard 1": the name and the mount point no longer agree.
        XCTAssertFalse(build(resource { $0.mountPoint = "/Volumes/Outboard 1" }).isStandardMount)
        XCTAssertEqual(build(resource(), sameName: 2).sameNameCount, 2)
        // A marker that names another UUID is not this drive's.
        let other = VolumeMarker(uuid: "FFFFFFFF-0000-4000-8000-000000000009", token: "t", createdAt: T.t0, appVersion: "1")
        XCTAssertFalse(build(resource(), marker: other).hasOutboardMarker)
        XCTAssertNil(build(resource(), marker: other).markerToken)
        XCTAssertNil(build(resource { $0.uuid = nil }).uuid)
        XCTAssertEqual(build(resource { $0.uuid = nil }).id, "mount:/Volumes/Outboard")
        XCTAssertTrue(DriveFactsBuilder.build(resource: resource { $0.mountPoint = "/Users/jane/Library/CloudStorage/x" }, info: nil, apfs: nil, tmDestinations: [],
                                              backupFolderAtRoot: .no, siblingTimeMachineInContainer: false, marker: nil, sameNameCount: 1,
                                              isSyncedLocation: false, linkMegabitsPerSecond: nil).isSyncedLocation)
    }

    func testBuilderFormatsAndBuses() {
        for (raw, kind) in [("apfs", FileSystemKind.apfs), ("hfs", .hfsPlus), ("exfat", .exfat), ("msdos", .fat), ("ntfs", .ntfs), ("smbfs", .network), ("zfs", .other)] {
            let info = DiskutilInfo(deviceIdentifier: "d", filesystemType: raw)
            XCTAssertEqual(build(resource { $0.formatDescription = nil }, info: info).fileSystem, kind, raw)
        }
        XCTAssertEqual(build(resource { $0.formatDescription = "Mac OS Extended (Journaled)" }).fileSystem, .hfsPlus)
        for (raw, bus) in [("USB", BusKind.usb), ("Thunderbolt", .thunderbolt), ("PCI-Express", .nvme), ("SATA", .sata), ("Disk Image", .diskImage), ("Secure Digital", .sdCard), ("FireWire", .firewire)] {
            XCTAssertEqual(build(resource(), info: DiskutilInfo(deviceIdentifier: "d", busProtocol: raw)).bus, bus, raw)
        }
        XCTAssertEqual(build(resource(), info: nil).bus, .unknown)
    }
}
