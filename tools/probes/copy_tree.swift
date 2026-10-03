// Probe E6, T6 and the Removable Volumes question (BUILD_PLAN section 6.4): copy a tree with FileManager.copyItem, as the app's Copier
// will, and print the outcome. The caller compares the two trees (links, xattrs, ACLs, resource forks, compression, modes, sparse
// files) with stat, ls and xattr. Writing from a compiled binary also shows whether the first write to an external volume triggers
// a privacy prompt or a log entry. Usage: copy_tree SRC DST. Run by tools/probes/volumes.sh; never part of the app.
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: copy_tree SRC DST")
    exit(2)
}
let fm = FileManager.default
do {
    try fm.createDirectory(atPath: (args[2] as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try fm.copyItem(atPath: args[1], toPath: args[2])
    print("copyItem: ok")
} catch {
    print("copyItem: error \(error)")
    exit(1)
}
