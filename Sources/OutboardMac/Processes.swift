import Darwin
import Foundation

/// Read-only process facts (libproc): names, and which processes hold files open under a folder. No argv, no environment, no
/// working directory, no signal. nil means the list itself could not be read; the running check then fails closed (I4).
/// Every libproc name below is VERIFY on a Mac, and which processes a normal user may inspect is VERIFY (BUILD_PLAN §12 item 15).
enum Processes {
    private static let pathBufferSize = 4096 // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN), spelled out

    /// System services that look at files all the time and are not "the app"; an open handle held by one of these does not block.
    static let ignoredHolders: Set<String> = ["mds", "mds_stores", "mdworker", "mdworker_shared", "fseventsd", "Finder", "cfprefsd",
                                              "backupd", "distnoted", "quicklookd", "QuickLookUIService", "sandboxd", "trustd"]

    private static func pids() -> [pid_t]? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        // Slack for processes that start between the two calls.
        var list = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&list, Int32(list.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }
        return Array(list.prefix(Int(count))).filter { $0 > 0 }
    }

    /// The short name and the executable's file name of every process whose facts macOS lets us read.
    static func names() -> Set<String>? {
        guard let all = pids() else { return nil }
        var out = Set<String>()
        var short = [CChar](repeating: 0, count: 256)
        var long = [CChar](repeating: 0, count: pathBufferSize)
        for pid in all {
            if proc_name(pid, &short, UInt32(short.count)) > 0 { out.insert(String(cString: short)) }
            // Other users' processes fail here; a name match from any user still counts through proc_name above.
            if proc_pidpath(pid, &long, UInt32(pathBufferSize)) > 0 { out.insert(Fs.leaf(of: String(cString: long))) }
        }
        return out
    }

    /// Names of the same user's processes that hold a file open under `path` (this process excluded). nil = not enumerable.
    static func openHandleHolders(under path: String) -> [String]? {
        guard let all = pids() else { return nil }
        let roots = Set([path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path].map(Fs.normalized))
        let me = getpid()
        var holders = Set<String>()
        var short = [CChar](repeating: 0, count: 256)
        for pid in all where pid != me {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            if bytes <= 0 { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.size + 8)
            let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            if got <= 0 { continue }
            for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
                let file = Fs.string(info.pvip.vip_path)
                guard roots.contains(where: { file == $0 || file.hasPrefix($0 + "/") }) else { continue }
                if proc_name(pid, &short, UInt32(short.count)) > 0 {
                    let name = String(cString: short)
                    if !ignoredHolders.contains(name) { holders.insert(name) }
                }
                break
            }
        }
        return holders.sorted()
    }
}
