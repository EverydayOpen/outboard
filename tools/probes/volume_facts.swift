// Probe T1 and E5 (BUILD_PLAN section 6.4): what URLResourceValues and statfs say about the volume at MOUNTPOINT. The workflow compares the
// UUID with diskutil's VolumeUUID. Read-only. Run by tools/probes/volumes.sh; never part of the app.
import Foundation
#if canImport(Darwin)
import Darwin
#endif

let args = CommandLine.arguments
guard args.count > 1 else {
    print("usage: volume_facts MOUNTPOINT")
    exit(2)
}
let url = URL(fileURLWithPath: args[1])

// The encrypted and the two "available capacity for ..." keys are looked up by raw name so one missing symbol cannot stop the probe (VERIFY item 9).
let keys: [URLResourceKey] = [
    .volumeNameKey, .volumeLocalizedNameKey, .volumeUUIDStringKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey,
    .volumeIsEjectableKey, .volumeIsReadOnlyKey, .volumeIsBrowsableKey, URLResourceKey(rawValue: "NSURLVolumeIsEncryptedKey"), .volumeSupportsCaseSensitiveNamesKey,
    .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    URLResourceKey(rawValue: "NSURLVolumeAvailableCapacityForImportantUsageKey"), URLResourceKey(rawValue: "NSURLVolumeAvailableCapacityForOpportunisticUsageKey"),
]

for key in keys {
    do {
        let values = try url.resourceValues(forKeys: [key])
        print("\(key.rawValue) = \(String(describing: values.allValues[key] ?? "nil"))")
    } catch {
        print("\(key.rawValue) = error: \(error)")
    }
}

#if canImport(Darwin)
var fs = statfs()
if statfs(args[1], &fs) == 0 {
    let type = withUnsafePointer(to: &fs.f_fstypename) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
    }
    let from = withUnsafePointer(to: &fs.f_mntfromname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    print("statfs f_fstypename = \(type)")
    print("statfs f_mntfromname = \(from)")
    print("statfs f_flags = 0x\(String(fs.f_flags, radix: 16)) (MNT_RDONLY set: \(fs.f_flags & UInt32(MNT_RDONLY) != 0))")
} else {
    print("statfs failed, errno \(errno)")
}
#endif

let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
print("mountedVolumeURLs:")
for m in mounted {
    let uuid = (try? m.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? "nil"
    print("  \(m.path)  uuid=\(uuid)")
}
