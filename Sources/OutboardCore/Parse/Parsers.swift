import Foundation

/// The only place property lists are parsed (grep G7) and the only place the small JSON files Outboard writes on a drive are read.
/// Pure: the Mac layer reads the bytes (at most 1 MB per plist) and hands them over. **Every key name from a system tool is VERIFY on
/// macOS 15 and 26** (BUILD_PLAN §12 item 1); a missing or mistyped key is `unknown` or nil, never a reason to call a drive eligible.
public enum Parsers {
    static let maxPlistBytes = 1_048_576
    static let maxSmallJSONBytes = 65_536
    static let maxManifestBytes = Limits.maxManifestBytes

    private static func dictionary(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= maxPlistBytes else { return nil }
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return object as? [String: Any]
    }

    /// A real Boolean only. A string, an integer or a missing key is `unknown`.
    private static func tri(_ v: Any?) -> Tri {
        guard let v else { return .unknown }
        if let n = v as? NSNumber {
            let t = String(cString: n.objCType)
            return t == "c" || t == "B" ? Tri(n.boolValue) : .unknown
        }
        if let b = v as? Bool { return Tri(b) }
        return .unknown
    }

    private static func text(_ v: Any?) -> String? {
        guard let s = v as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func unsigned(_ v: Any?) -> UInt64? {
        if let n = v as? Int { return n >= 0 ? UInt64(n) : nil }
        if let n = v as? UInt64 { return n }
        if let n = v as? NSNumber, !(v is Bool) { let i = n.int64Value; return i >= 0 ? UInt64(i) : nil }
        return nil
    }

    // MARK: diskutil

    /// `diskutil info -plist <mount point>`. Keys (VERIFY): DeviceIdentifier, VolumeUUID, VolumeName, MountPoint, FilesystemType,
    /// BusProtocol, Internal, SolidState, WritableVolume (or Writable), FileVault, Locked, SMARTStatus, GlobalPermissionsEnabled,
    /// TotalSize (or Size), ParentWholeDisk, APFSPhysicalStores, APFSContainerReference. nil when nothing recognisable is there.
    public static func diskutilInfo(_ plist: Data) -> DiskutilInfo? {
        guard let d = dictionary(plist) else { return nil }
        let device = text(d["DeviceIdentifier"])
        let uuid = text(d["VolumeUUID"])?.uppercased()
        let fs = text(d["FilesystemType"])?.lowercased()
        let mount = text(d["MountPoint"])
        guard device != nil || uuid != nil || fs != nil || mount != nil else { return nil }
        let smart: SmartStatus
        switch text(d["SMARTStatus"])?.lowercased() {
        case "verified": smart = .verified
        case "failing": smart = .failing
        case "not supported": smart = .notSupported
        default: smart = .unknown
        }
        var stores: [String] = []
        if let list = d["APFSPhysicalStores"] as? [Any] {
            for item in list {
                if let s = item as? String, !s.isEmpty { stores.append(s) }
                if let dict = item as? [String: Any], let s = text(dict["APFSPhysicalStore"]) { stores.append(s) }
            }
        }
        let writable = d["WritableVolume"] != nil ? tri(d["WritableVolume"]) : tri(d["Writable"])
        return DiskutilInfo(deviceIdentifier: device, volumeUUID: uuid, volumeName: text(d["VolumeName"]), mountPoint: mount,
                            filesystemType: fs, busProtocol: text(d["BusProtocol"]), isInternal: tri(d["Internal"]),
                            isSolidState: tri(d["SolidState"]), isWritable: writable, isEncrypted: tri(d["FileVault"]),
                            isLocked: tri(d["Locked"]), smart: smart, ownershipHonoured: tri(d["GlobalPermissionsEnabled"]),
                            totalSize: unsigned(d["TotalSize"]) ?? unsigned(d["Size"]), parentWholeDisk: text(d["ParentWholeDisk"]),
                            apfsPhysicalStores: stores, apfsContainerReference: text(d["APFSContainerReference"]))
    }

    /// `diskutil apfs list -plist`: Containers, each with ContainerReference and Volumes (APFSVolumeUUID, Roles, FileVault, Locked,
    /// CapacityQuota, CapacityReserve). Key names VERIFY. A quota of 0 means none.
    public static func apfsList(_ plist: Data) -> [ApfsVolumeInfo] {
        guard let d = dictionary(plist), let containers = d["Containers"] as? [[String: Any]] else { return [] }
        var out: [ApfsVolumeInfo] = []
        for container in containers {
            let ref = text(container["ContainerReference"])
            for volume in (container["Volumes"] as? [[String: Any]]) ?? [] {
                let roles = (volume["Roles"] as? [Any])?.compactMap { text($0) } ?? []
                let encrypted = volume["FileVault"] != nil ? tri(volume["FileVault"]) : tri(volume["Encryption"])
                let quota = unsigned(volume["CapacityQuota"])
                let reserve = unsigned(volume["CapacityReserve"])
                out.append(ApfsVolumeInfo(volumeUUID: text(volume["APFSVolumeUUID"])?.uppercased(), containerReference: ref, roles: roles,
                                          isEncrypted: encrypted, isLocked: tri(volume["Locked"]),
                                          quotaBytes: (quota ?? 0) > 0 ? quota : nil, reserveBytes: (reserve ?? 0) > 0 ? reserve : nil))
            }
        }
        return out
    }

    /// `tmutil destinationinfo -X`: a dictionary with Destinations (Name, ID, MountPoint, Kind ...). nil when the output is not a
    /// property list (no destinations configured prints plain text, or the call failed): the caller then treats it as unknown.
    /// The destination ID is read as the volume UUID (VERIFY: it may be the destination's own ID).
    public static func tmutilDestinations(_ plist: Data) -> [TimeMachineDestination]? {
        guard let d = dictionary(plist) else { return nil }
        guard let list = d["Destinations"] as? [[String: Any]] else { return [] }
        return list.map { item in
            TimeMachineDestination(name: text(item["Name"]), mountPoint: text(item["MountPoint"]), volumeUUID: text(item["ID"])?.uppercased())
        }
    }

    // MARK: defaults

    /// The output of `defaults read <domain> <key>`. A missing key ("does not exist") and anything that is not a single scalar of the
    /// expected type is nil. A string may come back quoted (a path with a space is); the quotes and their escapes are removed.
    public static func defaultsRead(_ text: String, type: DefaultsValueType) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.lowercased().contains("does not exist") { return nil }
        if t.contains("\n") { return nil }
        switch type {
        case .int:
            guard !t.isEmpty, t.count <= 20, t.allSatisfy({ $0.isASCII && $0.isNumber || $0 == "-" }), Int64(t) != nil else { return nil }
            return String(Int64(t) ?? 0)
        case .string:
            if t.hasPrefix("(") || t.hasPrefix("{") { return nil }
            if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
                // `defaults read` prints non-ASCII as `\U00e9` (VERIFY on a Mac). Those escapes are gathered as UTF-16 units so that a
                // surrogate pair (an emoji) decodes to one character.
                let body = Array(t.dropFirst().dropLast())
                var out = ""
                var units: [UInt16] = []
                func flush() { out += String(decoding: units, as: UTF16.self); units = [] }
                var i = 0
                while i < body.count {
                    let c = body[i]
                    if c != "\\" { flush(); out.append(c); i += 1; continue }
                    guard i + 1 < body.count else { break }   // a lone trailing backslash is dropped
                    let n = body[i + 1]
                    if n == "U", i + 5 < body.count, body[(i + 2)...(i + 5)].allSatisfy({ $0.isASCII && $0.isHexDigit }),
                       let unit = UInt16(String(body[(i + 2)...(i + 5)]), radix: 16) {
                        units.append(unit)
                        i += 6
                        continue
                    }
                    flush()
                    switch n {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    default: out.append(n)
                    }
                    i += 2
                }
                flush()
                return out
            }
            return t
        }
    }

    // MARK: Outboard's own small files

    /// `Outboard/.outboard/volume.json`. nil unless the schema is ours and the uuid and token are there.
    public static func volumeMarker(_ data: Data) -> VolumeMarker? {
        guard !data.isEmpty, data.count <= maxSmallJSONBytes,
              let m = try? ISO8601Lite.decoder().decode(VolumeMarker.self, from: data),
              m.schema == Limits.markerSchema, !m.uuid.isEmpty, !m.token.isEmpty else { return nil }
        return m
    }

    /// `Outboard/<recipe-id>/.sentinel-<moveID>.json`.
    public static func sentinel(_ data: Data) -> Sentinel? {
        guard !data.isEmpty, data.count <= maxSmallJSONBytes,
              let s = try? ISO8601Lite.decoder().decode(Sentinel.self, from: data),
              s.schema == Limits.markerSchema, !s.moveID.isEmpty, !s.volumeToken.isEmpty else { return nil }
        return s
    }

    /// The per-file manifest (path, size, mtime, SHA-256). nil unless the schema is ours.
    public static func manifest(_ data: Data) -> ManifestFile? {
        guard !data.isEmpty, data.count <= maxManifestBytes,
              let m = try? ISO8601Lite.decoder().decode(ManifestFile.self, from: data), m.schema == Limits.manifestSchema else { return nil }
        return m
    }

    /// The bytes the Mac layer writes: sorted keys, ISO-8601 whole seconds, a trailing newline.
    public static func markerData(_ m: VolumeMarker) -> Data? { encoded(m) }
    public static func sentinelData(_ s: Sentinel) -> Data? { encoded(s) }
    /// nil when the manifest would be larger than `maxManifestBytes`: it could be written but never read back.
    public static func manifestData(_ m: ManifestFile) -> Data? { encoded(m).flatMap { $0.count <= maxManifestBytes ? $0 : nil } }

    private static func encoded<T: Encodable>(_ value: T) -> Data? {
        guard var data = try? ISO8601Lite.encoder().encode(value) else { return nil }
        data.append(10)
        return data
    }
}
