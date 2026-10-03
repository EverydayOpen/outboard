// Probe T5 (BUILD_PLAN section 6.4, VERIFY item 19): what an open file, a held directory and a path on a volume do after `detach -force`.
// Usage: force_detach FILE_ON_VOLUME TRIGGER_FILE. It opens the file and its folder, prints READY, waits until TRIGGER_FILE exists (the
// caller detaches the volume, then creates the trigger; the trigger must be outside the volume), then prints the errno of each call.
// Run by tools/probes/volumes.sh; never part of the app.
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: force_detach FILE_ON_VOLUME TRIGGER_FILE")
    exit(2)
}
let path = args[1]
let trigger = args[2]
let folder = (path as NSString).deletingLastPathComponent

let fd = open(path, O_RDWR)
guard fd >= 0 else {
    print("open failed, errno \(errno)")
    exit(1)
}
let dirFD = open(folder, O_RDONLY)
print("READY fd=\(fd) dirfd=\(dirFD)")
fflush(stdout)

var waited = 0
while !FileManager.default.fileExists(atPath: trigger) && waited < 600 {
    usleep(100_000)
    waited += 1
}

// The result of a call, with errno read before anything else can change it.
func report(_ what: String, _ result: Int) {
    let e = errno
    if result < 0 {
        print("\(what): -1, errno \(e) (\(String(cString: strerror(e))))")
    } else {
        print("\(what): \(result)")
    }
}

var buffer = [UInt8](repeating: 0, count: 16)
var info = stat()
report("read(fd)", read(fd, &buffer, buffer.count))
report("write(fd)", write(fd, "x", 1))
report("fsync(fd)", Int(fsync(fd)))
report("fstat(fd)", Int(fstat(fd, &info)))
report("fstat(dirfd)", Int(fstat(dirFD, &info)))
report("stat(path)", Int(stat(path, &info)))
report("stat(folder)", Int(stat(folder, &info)))
report("lseek(fd)", Int(lseek(fd, 0, SEEK_SET)))
let reopened = open(path, O_RDONLY)
report("open(path) again", Int(reopened))
let dir = opendir(folder)
print("opendir(folder): \(dir == nil ? "nil, errno \(errno)" : "ok")")
print("fileExists(folder): \(FileManager.default.fileExists(atPath: folder))")
report("close(fd)", Int(close(fd)))
report("close(dirfd)", Int(close(dirFD)))
