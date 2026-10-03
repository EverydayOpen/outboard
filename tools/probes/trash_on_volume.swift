// Probe (BUILD_PLAN section 6.4): does FileManager.trashItem work for a file, a symbolic link and a folder that live on an external
// (disk image) volume, and where does the item go? The app's Trasher uses trashItem for the .before-move folder, which stays on the
// source volume, but a Return to Mac or a Forget can have items on the drive. Usage: trash_on_volume MOUNTPOINT.
// Run by tools/probes/volumes.sh; never part of the app. The probe cleans up only what it created, on a throwaway image.
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    print("usage: trash_on_volume MOUNTPOINT")
    exit(2)
}
let fm = FileManager.default
let dir = args[1] + "/trash-probe"
let file = dir + "/f.txt"
let target = dir + "/target.txt"
let link = dir + "/link"
let folder = dir + "/Folder"
try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
fm.createFile(atPath: file, contents: Data("x".utf8))
fm.createFile(atPath: target, contents: Data("t".utf8))
try? fm.createSymbolicLink(atPath: link, withDestinationPath: target)
fm.createFile(atPath: folder + "/inner.txt", contents: Data("i".utf8))

for (name, path) in [("file", file), ("symlink", link), ("folder", folder)] {
    var resulting: NSURL?
    do {
        try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
        print("trashItem \(name): ok; resultingItemURL: \((resulting as URL?)?.path ?? "nil")")
        print("  original still there: \(fm.fileExists(atPath: path)); symlink target still there: \(fm.fileExists(atPath: target))")
    } catch {
        print("trashItem \(name): error \(error)")
    }
}
