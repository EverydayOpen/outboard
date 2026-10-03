#!/usr/bin/env bash
# The safety rules of docs/BUILD_PLAN.md §3 as greps. CI runs this (ci.yml `checks` job); run it locally before pushing.
# GNU grep (Git Bash and Linux): the regexes use \b. Only Sources/ and App/ are searched (plus site/, .github/, README.md and
# CHANGELOG.md for the banned phrases), so tests and tools are exempt. Each check prints its hits and fails the script.
# Owner: architect until infra takes it over. Rule text lives in BUILD_PLAN §3; this file is exact and has mutation self-tests.
# Harness copied from Aftertaste's tools/safety_greps.sh (check, hits, selftest, cleantest, ordered, synth); the constants are Outboard's.
set -u
cd "$(dirname "$0")/.."
fail=0
check() { if [ -n "$2" ]; then echo "$2"; echo "::error::$1"; fail=1; fi; }
S='--include=*.swift'
# Whole-line // comments are exempt everywhere (a comment can't run); a trailing comment after code is not.
C='^[^:]+:[0-9]+:[[:space:]]*//'
# hits REGEX [EXEMPT] [DIRS]: matching lines "file:line:text", minus comment lines, minus lines matching EXEMPT
# (a grep -E pattern, normally a "file:" prefix such as '^Sources/OutboardMac/Renamer\.swift:').
hits() { grep -rnsE $S "$1" ${3:-Sources App} | grep -vE "$C" | grep -vE "${2:-^$}" || true; }
# Self-tests: a regex that does not trip on its own bad example proves nothing. The examples are collected per regex and
# checked with two greps in selfcheck (spawning a process per example is minutes on Windows Git Bash).
#   selftest NAME REGEX 'bad line'   must match            cleantest NAME REGEX 'good line'   must NOT match
STD=$(mktemp -d)
trap 'rm -rf "$STD"' EXIT
selftest() { printf '%s\n' "$3" >> "$STD/$1.bad"; printf '%s' "$2" > "$STD/$1.re"; }
cleantest() { printf '%s\n' "$3" >> "$STD/$1.ok"; printf '%s' "$2" > "$STD/$1.re"; }
selfcheck() {
  local f name re m
  for f in "$STD"/*.re; do
    name=$(basename "$f" .re); re=$(cat "$f")
    if [ -f "$STD/$name.bad" ]; then
      m=$(grep -vE "$re" "$STD/$name.bad" || true)
      [ -z "$m" ] || check "safety_greps self-test: $name missed: $m" "self-test failed"
    fi
    if [ -f "$STD/$name.ok" ]; then
      m=$(grep -E "$re" "$STD/$name.ok" || true)
      [ -z "$m" ] || check "safety_greps self-test: $name flagged innocent code: $m" "self-test failed"
    fi
  done
}

M=Sources/OutboardMac
CORE=Sources/OutboardCore

# G1. Nothing is deleted, truncated, replaced or exchanged. Deleting means FileManager.trashItem (G2) after the user confirmed.
R_DELETE='(^|[^[:alnum:]_.])(remove|unlink|unlinkat|rmdir|rename|renameat|renamex_np|renameatx_np|truncate|ftruncate|copyfile|fcopyfile|clonefile|clonefileat|fclonefileat|link|linkat|symlink|symlinkat|mkfifo|mknod|exchangedata|removefile|removefile_state_alloc)[[:space:]]*\(|\.(removeItem|removeItems|replaceItem|replaceItemAt|linkItem|setAttributes|recycle|setUbiquitous|removeFile|performFileOperation|evictUbiquitousItem|startDownloadingUbiquitousItem|truncate|truncateFile|synchronizeFile)[[:space:]]*\(|\bremoveItem\b|\bRENAME_SWAP\b|"/bin/(rm|mv|cp|ln)"|"/usr/bin/(ditto|rsync|cp|mv|rm|ln)"|\bemptyTrash|F_PUNCHHOLE|\b(recycleOperation|destroyOperation|NSWorkspaceRecycleOperation|NSWorkspaceDestroyOperation)\b|\b(Darwin|Glibc)\.(remove|removefile|unlink|unlinkat|rmdir|rename|renameat|truncate|ftruncate|copyfile|link|symlink)\b'
selftest delete "$R_DELETE" 'try FileManager.default.removeItem(at: u)'
selftest delete "$R_DELETE" 'unlink(path)'
selftest delete "$R_DELETE" 'Darwin.rmdir(path)'
selftest delete "$R_DELETE" '_ = remove(path)'
selftest delete "$R_DELETE" 'rename(a, b)'
selftest delete "$R_DELETE" 'renamex_np(a, b, RENAME_SWAP)'
selftest delete "$R_DELETE" 'copyfile(a, b, nil, 0)'
selftest delete "$R_DELETE" 'try FileManager.default.replaceItemAt(a, withItemAt: b)'
selftest delete "$R_DELETE" 'NSWorkspace.shared.recycle([u]) { _, _ in }'
selftest delete "$R_DELETE" 'let p = "/bin/rm"'
selftest delete "$R_DELETE" 'let p = "/usr/bin/ditto"'
selftest delete "$R_DELETE" 'let p = "/usr/bin/rsync"'
selftest delete "$R_DELETE" 'try FileManager.default.setAttributes([:], ofItemAtPath: p)'
selftest delete "$R_DELETE" 'ftruncate(fd, 0)'
selftest delete "$R_DELETE" 'try handle.truncate(atOffset: 0)'
selftest delete "$R_DELETE" 'try handle.truncateFile(atOffset: 0)'
selftest delete "$R_DELETE" 'handle.synchronizeFile()'
selftest delete "$R_DELETE" 'removefile(path, nil, removefile_flags_t(REMOVEFILE_RECURSIVE))'
selftest delete "$R_DELETE" 'Darwin.removefile(path, nil, 0)'
selftest delete "$R_DELETE" 'let st = removefile_state_alloc()'
selftest delete "$R_DELETE" 'clonefile(a, b, 0)'
selftest delete "$R_DELETE" '_ = NSWorkspace.shared.performFileOperation(.recycleOperation, source: s, destination: "", files: f, tag: nil)'
selftest delete "$R_DELETE" 'let op = NSWorkspace.OperationName.destroyOperation'
selftest delete "$R_DELETE" 'let op = NSWorkspaceRecycleOperation'
selftest delete "$R_DELETE" 'try FileManager.default.evictUbiquitousItem(at: u)'
selftest delete "$R_DELETE" 'try fm.startDownloadingUbiquitousItem(at: u)'
cleantest delete "$R_DELETE" 'NSWorkspace.shared.open(url)'
cleantest delete "$R_DELETE" 'UserDefaults.standard.synchronize(); let n = log.truncated; text.truncatingTail()'
cleantest delete "$R_DELETE" 'ticked.remove(id); items.remove(at: 0); dict.removeValue(forKey: k)'
cleantest delete "$R_DELETE" 'try fm.moveItem(at: a, to: b); try fm.copyItem(at: a, to: b); try fm.createSymbolicLink(atPath: p, withDestinationPath: d)'
cleantest delete "$R_DELETE" 'try fm.trashItem(at: url, resultingItemURL: &resulting)'
check "Never delete, rename, replace, exchange, clone, link, truncate, recycle or empty the Trash: deleting means FileManager.trashItem in Trasher.swift" "$(hits "$R_DELETE")"

# G2. One site per verb. Each verb's file writes its own journal intent before acting (pinned below).
R_MOVE='(^|[^[:alnum:]_])moveItem[[:space:]]*\('
R_COPY='(^|[^[:alnum:]_])copyItem[[:space:]]*\('
R_SYMLINK='createSymbolicLink[[:space:]]*\('
R_TRASH='trashItem[[:space:]]*\('
R_DEFAULTSW='\.defaultsWrite\b|defaultsWrite[[:space:]]*\('
selftest moveItem "$R_MOVE" 'try fm.moveItem(at: a, to: b)'
selftest moveItem "$R_MOVE" 'moveItem(at: a, to: b)'
cleantest moveItem "$R_MOVE" 'try fm.removeItem(at: u)'
selftest copyItem "$R_COPY" 'try fm.copyItem(at: a, to: b)'
selftest symlink "$R_SYMLINK" 'try fm.createSymbolicLink(atPath: p, withDestinationPath: d)'
selftest trashItem "$R_TRASH" 'try fm.trashItem(at: u, resultingItemURL: &r)'
selftest defaultsw "$R_DEFAULTSW" 'ProcessRunner.run(.defaultsWrite(domain, key, type, value))'
check "moveItem( appears only in $M/Renamer.swift" "$(hits "$R_MOVE" "^$M/Renamer\.swift:")"
check "copyItem( appears only in $M/Copier.swift" "$(hits "$R_COPY" "^$M/Copier\.swift:")"
check "createSymbolicLink( appears only in $M/Linker.swift" "$(hits "$R_SYMLINK" "^$M/Linker\.swift:")"
check "trashItem( appears only in $M/Trasher.swift" "$(hits "$R_TRASH" "^$M/Trasher\.swift:")"
check "defaultsWrite appears only in $M/ProcessRunner.swift (the command) and $M/DefaultsRedirect.swift (its one caller)" "$(hits "$R_DEFAULTSW" "^$M/(ProcessRunner|DefaultsRedirect)\.swift:")"

# G3. Who may create or write anything. Journal.swift appends; ManifestStore, OutboardRoot, Placeholder, Copier (the staging folder),
#     Park (the Parked folder) and App/Export.swift (a save panel) create what their names say. Nothing else writes a byte.
R_WRITE_SYS='\bO_(WRONLY|CREAT|APPEND)\b|(^|[^[:alnum:]_.])((Darwin|Glibc).)?(write|fsync|fdatasync|fopen|freopen|mkdir|mkdirat|mkdtemp|mkstemp|creat)[[:space:]]*\(|\b(Darwin|Glibc)\.(write|fsync|fdatasync|fopen|freopen|mkdir|mkdirat|mkdtemp|mkstemp|creat)\b'
selftest write-sys "$R_WRITE_SYS" 'let fd = open(p, O_WRONLY | O_APPEND | O_CREAT, 0o600)'
selftest write-sys "$R_WRITE_SYS" 'write(fd, ptr, n)'
selftest write-sys "$R_WRITE_SYS" 'Darwin.write(fd, ptr, n)'
selftest write-sys "$R_WRITE_SYS" 'fsync(fd)'
selftest write-sys "$R_WRITE_SYS" 'mkdir(path, 0o700)'
selftest write-sys "$R_WRITE_SYS" 'let r = Darwin.mkdtemp(&template)'
selftest write-sys "$R_WRITE_SYS" 'let fd = mkstemp(&template)'
selftest write-sys "$R_WRITE_SYS" 'let fd = creat(path, 0o600)'
selftest write-sys "$R_WRITE_SYS" 'mkdirat(dirfd, name, 0o700)'
selftest write-sys "$R_WRITE_SYS" 'let f = fopen(path, "w")'
selftest write-sys "$R_WRITE_SYS" 'freopen(path, "a", stdout)'
selftest write-sys "$R_WRITE_SYS" 'let f = Darwin.fopen(path, "a")'
cleantest write-sys "$R_WRITE_SYS" 'try fm.createDirectory(atPath: p, withIntermediateDirectories: true); store.mkdir(p); Placeholder.create(at: p)'
check "Raw write(2), fsync and O_WRONLY/O_CREAT/O_APPEND only in $M/Journal.swift" "$(hits "$R_WRITE_SYS" "^$M/Journal\.swift:")"
R_WRITE_FND='createFile[[:space:]]*\(|FileHandle[[:space:]]*\(forWriting|FileHandle[[:space:]]*\(forUpdating|createDirectory[[:space:]]*\(|\.write[[:space:]]*\((to|contentsOf):|write[[:space:]]*\(toFile:|OutputStream|\.seekToEnd|atomically:'
selftest write-fnd "$R_WRITE_FND" 'try data.write(to: url, options: .atomic)'
selftest write-fnd "$R_WRITE_FND" 'try fm.createDirectory(at: u, withIntermediateDirectories: true)'
selftest write-fnd "$R_WRITE_FND" 'fm.createFile(atPath: p, contents: nil)'
selftest write-fnd "$R_WRITE_FND" 'let h = try FileHandle(forWritingTo: u)'
check "File creation and writing only in $M/{Journal,ManifestStore,OutboardRoot,Placeholder,Copier,Park}.swift and App/Export.swift" \
  "$(hits "$R_WRITE_FND" "^($M/(Journal|ManifestStore|OutboardRoot|Placeholder|Copier|Park)|App/Export)\.swift:")"
R_NEVER_RW='\bO_(RDWR|TRUNC|EXCL)\b|pwrite|writev|F_FULLFSYNC|F_PUNCHHOLE'
selftest never-rw "$R_NEVER_RW" 'let fd = open(p, O_RDWR)'
selftest never-rw "$R_NEVER_RW" 'fcntl(fd, F_FULLFSYNC)'
check "No in-place rewriting (O_RDWR, O_TRUNC, O_EXCL, pwrite, writev, F_FULLFSYNC): the journal appends and fsyncs, nothing else is rewritten" "$(hits "$R_NEVER_RW")"
# Modes: no permission, ownership, flag, xattr, ACL, timestamp or umask change, ever. A placeholder's mode is given at creation.
R_PERM='(^|[^[:alnum:]_])(chmod|fchmod|lchmod|fchmodat|chown|fchown|lchown|fchownat|chflags|fchflags|lchflags|setxattr|fsetxattr|removexattr|fremovexattr|utimes|futimes|lutimes|utimensat|futimens|setattrlist|fsetattrlist|setattrlistat|acl_set_file|acl_set_fd|acl_delete_entry|umask|setResourceValues)[[:space:]]*\('
selftest perm "$R_PERM" 'chflags(path, 0)'
selftest perm "$R_PERM" 'fchmod(fd, 0o600)'
selftest perm "$R_PERM" 'setxattr(p, "a", nil, 0, 0, 0)'
selftest perm "$R_PERM" 'try url.setResourceValues(values)'
check "No chmod/chown/chflags/xattr/ACL/utimes/umask/setResourceValues calls: modes are set by open(2) and createFile/createDirectory(attributes:) at creation" "$(hits "$R_PERM")"
R_POSIXATTR='posixPermissions|\.immutable\b|\.ownerAccountID|\.groupOwnerAccountID'
selftest posixattr "$R_POSIXATTR" 'let a: [FileAttributeKey: Any] = [.posixPermissions: 0o700]'
check "posixPermissions only in $M/{Journal,ManifestStore,Placeholder,Park}.swift (their own 0700 folders and the 0444 note, set at creation)" \
  "$(hits "$R_POSIXATTR" "^$M/(Journal|ManifestStore|Placeholder|Park)\.swift:")"

# G4. Child processes: one runner, a closed command set. Process only in ProcessRunner.swift; hdiutil nowhere in the app (G5).
R_PROCESS='\bProcess\b'
selftest process "$R_PROCESS" 'let p = Process()'
selftest process "$R_PROCESS" 'let p = Foundation.Process()'
cleantest process "$R_PROCESS" 'let v = ProcessInfo.processInfo.operatingSystemVersion'
check "Process only in $M/ProcessRunner.swift (the allow-listed runner: diskutil info/list, defaults read/write for catalogue keys, tmutil destinationinfo)" "$(hits "$R_PROCESS" "^$M/ProcessRunner\.swift:")"
R_NOPROC='\bposix_spawn|\bexec[lv]p?e?[[:space:]]*\(|(^|[^.[:alnum:]_])(system|popen|fork|vfork)[[:space:]]*\(|"/bin/(ba|z)?sh"|"/usr/bin/env"|"-c"|NSAppleScript|NSUserAppleScriptTask|NSTask|osascript|\bsudo\b|launchctl|\bpkill\b|\bkillall\b|\blsof\b|"/(usr/)?bin/ps"|"/usr/bin/open"|"/usr/bin/(plutil|tccutil|sfltool|lsregister|pkgutil|mdfind|mdls|xattr|chflags|trash|ditto|hdiutil|rsync|cp|mv|rm|ln)"'
selftest noproc "$R_NOPROC" 'system("rm -rf /")'
selftest noproc "$R_NOPROC" 'p.arguments = ["-c", cmd]'
selftest noproc "$R_NOPROC" 'p.executableURL = URL(fileURLWithPath: "/bin/sh")'
selftest noproc "$R_NOPROC" 'let t = "launchctl bootout"'
selftest noproc "$R_NOPROC" 'run("/usr/bin/tccutil", ["reset", "All"])'
selftest noproc "$R_NOPROC" 'return "/usr/bin/ditto"'
selftest noproc "$R_NOPROC" 'return "/usr/bin/hdiutil"'
selftest noproc "$R_NOPROC" 'let kill = "pkill -x bird"'
check "No shell, osascript, sudo, launchctl, pkill, killall, lsof, ps, open, ditto, hdiutil, tccutil, xattr or any command beyond ProcessRunner's closed set" "$(hits "$R_NOPROC")"

# G5. hdiutil is a test and CI tool: nowhere in the app, the site or the build files; in Tests/ only DiskImageLab.swift, always as /usr/bin/hdiutil with an argument array.
check "hdiutil appears nowhere in Sources/, App/, site/, project.yml or Package.swift (it is a test and CI tool)" \
  "$(grep -rnsI 'hdiutil' Sources App site project.yml Package.swift 2>/dev/null | grep -vE "$C" || true)"
check "hdiutil in Tests/ only in DiskImageLab.swift" "$(grep -rnsI 'hdiutil' Tests 2>/dev/null | grep -vE '^Tests/[^:]*/DiskImageLab\.swift:' || true)"
check "DiskImageLab.swift never runs hdiutil through a shell" "$(grep -nE '/bin/(ba|z)?sh|"-c"' Tests/*/DiskImageLab.swift 2>/dev/null || true)"
# Every macOS job that can attach an image (it runs the tests, the disk-image script or a probe) has a step `if: always()` + `run: bash
# tools/disk_image.sh cleanup`. Keyed on the cause, not on the word hdiutil (which only the DMG build in release.yml contains), and per job:
# a cleanup in a neighbouring job does not detach what this runner's tests attached. `hdiutil create -srcfolder` (the DMG) attaches nothing.
wf_detach() {   # wf_detach FILE...
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    awk -v F="$f" '
      function flush() {
        if (job != "" && macos && trig && !clean) print F ": job " job " can attach a disk image but has no `if: always()` step running `bash tools/disk_image.sh cleanup`"
        macos = 0; trig = 0; clean = 0; armed = 0
      }
      /^jobs:/ { injobs = 1; next }
      injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { flush(); job = $1; sub(/:$/, "", job); next }
      injobs && /^[^[:space:]#]/ { flush(); job = ""; injobs = 0; next }
      job != "" {
        if ($0 ~ /^[[:space:]]*#/) next
        if ($0 ~ /runs-on:[[:space:]]*(macos|\$\{\{)/) macos = 1
        if ($0 ~ /hdiutil[[:space:]]+(attach|mount|convert)|disk_image\.sh|probes\/volumes\.sh|ghost_mount|swift test/) trig = 1
        if (armed && $0 ~ /^[[:space:]]*run:[[:space:]]*bash tools\/disk_image\.sh cleanup[[:space:]]*$/) clean = 1
        armed = ($0 ~ /^[[:space:]]*(-[[:space:]]+)?if:[[:space:]]*always\(\)[[:space:]]*$/)
      }
      END { flush() }
    ' "$f"
  done
}
check "macOS jobs that can attach disk images must have an 'if: always()' step running 'bash tools/disk_image.sh cleanup'" "$(wf_detach .github/workflows/*.yml)"
WFT=$(mktemp -d)
printf '%s\n' 'jobs:' '  t:' '    runs-on: macos-26' '    steps:' '      - run: swift test' > "$WFT/bad1.yml"
printf '%s\n' 'jobs:' '  t:' '    runs-on: macos-26' '    steps:' '      - run: swift test' '      - name: x' '        if: always()' '        run: echo cleanup' '      - run: bash tools/disk_image.sh cleanup' > "$WFT/bad2.yml"
printf '%s\n' 'jobs:' '  a:' '    runs-on: macos-26' '    steps:' '      - run: swift test' '  b:' '    runs-on: macos-26' '    steps:' '      - if: always()' '        run: bash tools/disk_image.sh cleanup' > "$WFT/bad3.yml"
printf '%s\n' 'jobs:' '  t:' '    runs-on: ${{ matrix.runner }}' '    steps:' '      - run: bash tools/probes/volumes.sh out' > "$WFT/bad4.yml"
printf '%s\n' 'jobs:' '  t:' '    runs-on: macos-26' '    steps:' '      - run: swift test' '      - name: Detach' '        if: always()' '        run: bash tools/disk_image.sh cleanup' > "$WFT/ok1.yml"
printf '%s\n' 'jobs:' '  l:' '    runs-on: ubuntu-latest' '    steps:' '      - run: swift test --filter OutboardCoreTests' '  d:' '    runs-on: macos-26' '    steps:' '      - run: hdiutil create -volname X -srcfolder d -ov x.dmg' > "$WFT/ok2.yml"
for x in bad1 bad2 bad3 bad4; do [ -n "$(wf_detach "$WFT/$x.yml")" ] || check "safety_greps self-test: the detach-step check missed $x" "self-test failed"; done
for x in ok1 ok2; do [ -z "$(wf_detach "$WFT/$x.yml")" ] || check "safety_greps self-test: the detach-step check flagged $x" "$(wf_detach "$WFT/$x.yml")"; done
rm -rf "$WFT"
# Every test volume name starts with Outboard-TEST (or OB-TEST for ExFAT's 11-character label), so `disk_image.sh cleanup` finds it.
check "Every attach(... volumeName: literal) in Tests/OutboardMacTests starts with Outboard-TEST or OB-TEST (tools/disk_image.sh cleanup detaches by that prefix)" \
  "$(grep -rnsE 'attach\(.*volumeName:[[:space:]]*"' Tests/OutboardMacTests | grep -vE 'volumeName:[[:space:]]*"(Outboard-TEST|OB-TEST)' || true)"

# G6. Never signal, quit, eject, mount or unmount. A running app blocks a move; Outboard does not stop it. The drive is the user's.
R_SIGNAL='(^|[^[:alnum:]_])(kill|killpg|pthread_kill|raise)[[:space:]]*\(|\bSIG[A-Z0-9]+\b|forceTerminate|\bproc_terminate|\btask_for_pid|\bdlsym|\bdlopen|@_silgen_name|@_cdecl'
selftest signal "$R_SIGNAL" 'kill(pid, SIGTERM)'
selftest signal "$R_SIGNAL" 'Darwin.kill(pid, 9)'
selftest signal "$R_SIGNAL" 'let s = SIGKILL'
selftest signal "$R_SIGNAL" 'app.forceTerminate()'
check "No kill, killpg, raise, SIG* names, forceTerminate, dlsym or private-symbol tricks anywhere" "$(hits "$R_SIGNAL")"
check "terminate() only as NSApp.terminate(nil) to quit Outboard itself" \
  "$(hits '\.terminate[[:space:]]*\(' '(NSApp|NSApplication\.shared)\.terminate[[:space:]]*\(')"
selftest terminate '\.terminate[[:space:]]*\(' 'process.terminate()'
R_EJECT='unmountAndEjectDevice|DADiskUnmount|DADiskEject|DADiskMount|DARegisterDiskUnmountApprovalCallback|DARegisterDiskMountApprovalCallback|DARegisterDiskEjectApprovalCallback|IOEjectMedia|NSRunningApplication[^;]*\.(terminate|forceTerminate)'
selftest eject "$R_EJECT" 'NSWorkspace.shared.unmountAndEjectDevice(atPath: p)'
selftest eject "$R_EJECT" 'DADiskUnmount(disk, 0, nil, nil)'
check "Outboard never ejects, mounts or unmounts a volume, and never vetoes an eject (no unmountAndEjectDevice, DADiskUnmount/Eject/Mount, approval callbacks)" "$(hits "$R_EJECT")"
R_DA='DiskArbitration|DADiskCreate|DADiskCopyDescription|DASessionCreate'
check "DiskArbitration only in $M/Disks.swift (unused in v1)" "$(hits "$R_DA" "^$M/Disks\.swift:")"
R_RUNAPP='NSRunningApplication|runningApplications'
selftest runapp "$R_RUNAPP" 'NSWorkspace.shared.runningApplications.map(\.bundleIdentifier)'
check "NSRunningApplication/runningApplications only in $M/RunningApps.swift" "$(hits "$R_RUNAPP" "^$M/RunningApps\.swift:")"
R_APPNOTIF='didTerminateApplicationNotification|didLaunchApplicationNotification'
check "Workspace launch/terminate notifications only in $M/RunningApps.swift and App/AppModel.swift (re-evaluate, never poll)" "$(hits "$R_APPNOTIF" "^($M/RunningApps|App/AppModel)\.swift:")"
R_LIBPROC='proc_(listallpids|listpids|pidpath|pidinfo|name|regionfilename|set)|libproc|PROC_PID'
selftest libproc "$R_LIBPROC" 'let n = proc_listallpids(nil, 0)'
selftest libproc "$R_LIBPROC" 'let n = proc_pidpath(pid, &buf, 4096)'
check "libproc (proc_listallpids, proc_pidpath, proc_pidinfo: read-only process facts) only in $M/Processes.swift" "$(hits "$R_LIBPROC" "^$M/Processes\.swift:")"
R_VOLNOTIF='didMountNotification|willUnmountNotification|didUnmountNotification|didRenameVolumeNotification|willSleepNotification|didWakeNotification'
selftest volnotif "$R_VOLNOTIF" 'center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { _ in }'
selftest volnotif "$R_VOLNOTIF" 'center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in }'
check "Volume, sleep and wake notifications only in $M/VolumeWatcher.swift" "$(hits "$R_VOLNOTIF" "^$M/VolumeWatcher\.swift:")"
check "No user notifications (no permission prompt, no overclaiming surface): the menu bar item and the window carry state" "$(hits 'UserNotifications|UNUserNotificationCenter|UNMutableNotificationContent|NSUserNotification')"

# G7. Never read file contents, except to hash them (Verifier) and for our own journal, manifests, marker and sentinel.
R_READ='(NS)?(Data|String)[[:space:]]*\(contentsOf(File)?:|NSData[[:space:]]*\(|NSString[[:space:]]*\(contentsOf|NS(Dictionary|Array)[[:space:]]*\(contentsOf|contentsOfFile|\.contents[[:space:]]*\(atPath|(^|[^[:alnum:]_.])(fopen|freopen|open|openat|read|pread)[[:space:]]*\(|\b(Darwin|Glibc)\.(open|openat|read|pread)\b|FileHandle[[:space:]]*\(forReading|InputStream[[:space:]]*\(|\bfread[[:space:]]*\(|\bmmap[[:space:]]*\(|NSImage[[:space:]]*\(contentsOf|FileHandle[[:space:]]*\(fileDescriptor|\.lines\b|CGImageSource|NSImage[[:space:]]*\(byReferencing(File|URL|:)'
selftest read "$R_READ" 'let d = try Data(contentsOf: url)'
selftest read "$R_READ" 'let s = try String(contentsOf: url, encoding: .utf8)'
selftest read "$R_READ" 'let fd = open(path, O_RDONLY)'
selftest read "$R_READ" 'let n = read(fd, &buf, 10)'
selftest read "$R_READ" 'let h = try FileHandle(forReadingFrom: u)'
selftest read "$R_READ" 'let d = fm.contents(atPath: p)'
selftest read "$R_READ" 'let m = mmap(nil, n, PROT_READ, MAP_PRIVATE, fd, 0)'
selftest read "$R_READ" 'let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)'
selftest read "$R_READ" 'for try await l in url.lines {}'
selftest read "$R_READ" 'let s = CGImageSourceCreateWithURL(u as CFURL, nil)'
selftest read "$R_READ" 'let i = NSImage(byReferencingFile: p)'
selftest read "$R_READ" 'let i = NSImage(byReferencing: u)'
cleantest read "$R_READ" 'let t = report.summaryLines.joined(separator: " "); let n = lines.count'
check "No reading of file contents outside $M/{Verifier,Journal,ManifestStore,OutboardRoot,Disks}.swift" \
  "$(hits "$R_READ" "^$M/(Verifier|Journal|ManifestStore|OutboardRoot|Disks)\.swift:")"
R_HASH='CryptoKit|CommonCrypto|SHA256|CC_SHA256|F_NOCACHE'
selftest hash "$R_HASH" 'import CryptoKit'
selftest hash "$R_HASH" 'let h = SHA256()'
selftest hash "$R_HASH" 'fcntl(fd, F_NOCACHE, 1)'
check "Hashing and cache bypass (CryptoKit, SHA256, F_NOCACHE) only in $M/Verifier.swift" "$(hits "$R_HASH" "^$M/Verifier\.swift:")"
R_PLIST='PropertyListSerialization|PropertyListDecoder|PropertyListEncoder|NSKeyedUnarchiver|NSKeyedArchiver|\bplutil\b'
selftest plist "$R_PLIST" 'let o = try PropertyListSerialization.propertyList(from: d, options: [], format: nil)'
check "Property lists (diskutil, tmutil, Time Machine) are parsed only in $CORE/Parse/Parsers.swift (pure, tested on Linux)" "$(hits "$R_PLIST" "^$CORE/Parse/Parsers\.swift:")"
R_BUNDLE='(^|[^[:alnum:]_])Bundle[[:space:]]*\((url|path)|NSBundle|CFBundleCreate|CFBundleCopy|CFBundleGetValueForInfoDictionaryKey'
selftest bundle "$R_BUNDLE" 'let b = Bundle(url: appURL)'
check "Never open another app through Bundle(url:)/Bundle(path:): the running check uses bundle identifiers only" "$(hits "$R_BUNDLE")"
check "infoDictionary (our own version string) only in App/AppModel.swift" "$(hits 'infoDictionary' '^App/AppModel\.swift:')"

# G8. Filesystem metadata and listing calls: the Mac layer only. Core takes snapshots, the app asks the backend.
R_META='fileExists[[:space:]]*\(|attributesOfItem[[:space:]]*\(|(^|[^[:alnum:]_])[lf]?stat[[:space:]]*\(|statfs|statvfs|getattrlist|contentsOfDirectory|subpathsOfDirectory|enumerator[[:space:]]*\(|opendir|readdir|realpath|[Rr]esourceValues|getxattr|listxattr|isReadableFile|isWritableFile|isDeletableFile|isExecutableFile|destinationOfSymbolicLink|FileManager|NSFileManager|NSHomeDirectory|homeDirectoryForCurrentUser|getpwuid'
selftest meta "$R_META" 'if FileManager.default.fileExists(atPath: p) {}'
selftest meta "$R_META" 'var st = stat(); lstat(p, &st)'
selftest meta "$R_META" 'let u = FileManager.default.homeDirectoryForCurrentUser'
selftest meta "$R_META" 'let r = realpath(p, nil)'
selftest meta "$R_META" 'let v = try u.resourceValues(forKeys: [.volumeNameKey])'
selftest meta "$R_META" 'var v = URLResourceValues(); try u.setResourceValues(v)'
check "Filesystem calls (FileManager, stat, directory listing, realpath, resourceValues, home lookup) only in Sources/OutboardMac, plus the composition root App/AppModel.swift" \
  "$(hits "$R_META" '^App/AppModel\.swift:' "$CORE App")"

# G9. Login item, privilege, privacy-database, keychain, accessibility and Apple-event tricks.
R_SM='SMAppService|ServiceManagement|SMLoginItemSetEnabled'
selftest sm "$R_SM" 'try SMAppService.mainApp.register()'
check "SMAppService and ServiceManagement only in $M/LoginItem.swift" "$(hits "$R_SM" "^$M/LoginItem\.swift:")"
R_ESC='SMJobBless|AuthorizationCreate|AuthorizationExecuteWithPrivileges|AuthorizationCopyRights|NSXPCConnection|NSXPCListener'
selftest escalate "$R_ESC" 'AuthorizationExecuteWithPrivileges(a, p, 0, nil, nil)'
check "No SMJobBless, Authorization* or XPC: no privileged helper, no root" "$(hits "$R_ESC")"
R_TCC='TCC\.db|\btccutil\b|kTCCService|AXIsProcessTrusted|AXUIElement|CGEvent|System Events|NSAppleEventDescriptor|\blsregister\b|\bsfltool\b|CGRequestScreenCaptureAccess|CGWindowListCreate|IOHIDRequestAccess'
selftest tcc "$R_TCC" 'let p = "~/Library/Application Support/com.apple.TCC/TCC.db"'
selftest tcc "$R_TCC" 'AXIsProcessTrusted()'
check "No TCC database, tccutil, Accessibility, Apple events, lsregister or sfltool" "$(hits "$R_TCC")"
R_KEYCHAIN='SecItem|SecKeychain|kSecClass|kSecAttr|kSecValue|kSecReturn|LAContext|LocalAuthentication'
selftest keychain "$R_KEYCHAIN" 'SecItemCopyMatching(q as CFDictionary, &r)'
check "No keychain access of any kind (no passphrase ever touches Outboard)" "$(hits "$R_KEYCHAIN")"
R_SEC='import Security|SecStaticCode|SecCode|SecRequirement'
check "Security.framework not used at all in v1" "$(hits "$R_SEC")"
R_OPEN='NSWorkspace|LSOpen|openURL|\bLink[[:space:]]*\(|activateFileViewerSelecting|x-apple\.systempreferences'
selftest open "$R_OPEN" 'NSWorkspace.shared.open(url)'
selftest open "$R_OPEN" 'NSWorkspace.shared.activateFileViewerSelecting([u])'
check "NSWorkspace, openURL, Link and Finder reveal only in App/{Links,AppModel,OutboardApp}.swift, $M/RunningApps.swift and $M/VolumeWatcher.swift (workspace notification center)" \
  "$(hits "$R_OPEN" "^(App/(Links|AppModel|OutboardApp)|$M/(RunningApps|VolumeWatcher))\.swift:")"
check "System Settings deep links (x-apple.systempreferences) only in App/Links.swift" "$(hits 'x-apple\.systempreferences' '^App/Links\.swift:')"
R_DEFAULTS='UserDefaults|@AppStorage|@SceneStorage|NSUbiquitousKeyValueStore'
selftest defaults "$R_DEFAULTS" 'UserDefaults.standard.set(1, forKey: "a")'
check "UserDefaults, @AppStorage, @SceneStorage and iCloud key-value storage only in App/AppModel.swift" "$(hits "$R_DEFAULTS" '^App/AppModel\.swift:')"
R_PASTE='NSPasteboard|\.setString[[:space:]]*\(|\.setData[[:space:]]*\('
check "Pasteboard only in App/AppModel.swift and App/Export.swift" "$(hits "$R_PASTE" '^App/(AppModel|Export)\.swift:')"
check "Share services (NSSharingService, NSSharingServicePicker, ShareLink) nowhere: the card is copied or saved, never uploaded" "$(hits 'NSSharingService|ShareLink')"
# Present when the files exist.
if [ -f App/Info.plist ]; then
  grep -q 'LSMultipleInstancesProhibited' App/Info.plist || check "App/Info.plist must set LSMultipleInstancesProhibited (one mutation in flight, one instance)" "App/Info.plist: missing key"
fi

# G10. No network, no telemetry, no updater framework, no logging (paths reveal which apps a person has).
R_NET='URLSession|NSURLSession|NWConnection|NWPathMonitor|NWBrowser|NWListener|import Network|CFNetwork|CFStream|CFSocket|NSURLConnection|URLProtocol|WKWebView|import WebKit|SFSafariView|AsyncImage|MultipeerConnectivity|NetService|CloudKit|(^|[^[:alnum:]_.])socket[[:space:]]*\(|\b(Darwin|Glibc)\.(socket|connect|bind|listen|accept|sendto|getaddrinfo)\b|getaddrinfo|gethostbyname'
selftest net "$R_NET" 'let (d, _) = try await URLSession.shared.data(from: u)'
selftest net "$R_NET" 'import Network'
selftest net "$R_NET" 'let s = socket(AF_INET, SOCK_STREAM, 0)'
check "No network: no URLSession, Network framework, CFNetwork, sockets, web views, AsyncImage or CloudKit. Recipes are bundled data, never fetched" "$(hits "$R_NET")"
check "No Sparkle and no other dependency in v1: the app never goes online by itself (Check for updates opens the Releases page)" \
  "$(grep -rnsE 'Sparkle|SUFeedURL|SUPublicEDKey|\.package[[:space:]]*\(' App Sources project.yml Package.swift 2>/dev/null | grep -vE "$C" || true)"
R_LOG='(^|[^[:alnum:]_.])(print|debugPrint|dump|NSLog)[[:space:]]*\(|\bos_log\b|\bLogger[[:space:]]*\(|OSLog'
selftest log "$R_LOG" 'print(path)'
selftest log "$R_LOG" 'NSLog("%@", p)'
selftest log "$R_LOG" 'os_log("x")'
check "No print, debugPrint, dump, NSLog, os_log, Logger or OSLog" "$(hits "$R_LOG")"
check "Our own environment is read only in App/Demo.swift (-demoScreen / OUTBOARD_DEMO)" \
  "$(hits 'ProcessInfo\.processInfo\.environment|getenv[[:space:]]*\(|\benviron\b|setenv[[:space:]]*\(' '^App/Demo\.swift:')"
check "No interpolation into fatalError, precondition or assert messages (a crash report must not carry names or paths)" \
  "$(hits '\b(fatalError|preconditionFailure|assertionFailure|precondition|assert)[[:space:]]*\(.*\\\(' '^App/Demo\.swift:')"

# G11. iCloud and sync folders are hands-off: their names appear in one place (the never-list), nowhere else.
R_ICLOUD='Mobile Documents|CloudStorage|CloudDocs|FileProvider|iCloud~|com~apple~CloudDocs'
selftest icloud "$R_ICLOUD" 'let p = home + "/Library/Mobile Documents"'
selftest icloud "$R_ICLOUD" 'let p = home + "/Library/CloudStorage/Dropbox"'
check "iCloud/CloudDocs/FileProvider/CloudStorage names only in $CORE/Rules/NeverList.swift" "$(hits "$R_ICLOUD" "^$CORE/Rules/NeverList\.swift:")"

# G12. Layering. Core is Foundation-only and pure; Darwin/IOKit/CryptoKit live in the Mac layer; SwiftUI and AppKit are the app's.
check "$CORE imports only Foundation" "$(hits '^[[:space:]]*(@testable )?import ' 'import Foundation[[:space:]]*$' "$CORE")"
R_SYSIMPORT='import (Darwin|Glibc|MachO|IOKit|Security|libproc)|getuid[[:space:]]*\(|geteuid[[:space:]]*\(|getpid[[:space:]]*\(|getppid[[:space:]]*\(|sysctl|rusage'
selftest sysimport "$R_SYSIMPORT" 'import Darwin'
check "Darwin, IOKit, sysctl and uid/pid calls only in Sources/OutboardMac (Core and App never touch them)" "$(hits "$R_SYSIMPORT" '' "$CORE App")"
check "SwiftUI/Combine never in Sources/ (UI is App/ only); AppKit/Cocoa only in $M/RunningApps.swift and $M/VolumeWatcher.swift" \
  "$(hits 'import (SwiftUI|Combine|AppKit|Cocoa|UIKit)' "^$M/(RunningApps|VolumeWatcher)\.swift:" Sources)"
check "macOS 14+ APIs only in App/DesignSystem/Compat.swift (macOS 13 deployment target)" \
  "$(hits 'ContentUnavailableView|\.onKeyPress|\.symbolEffect|Animation\.smooth|\.smooth[[:space:]]*\(|@Observable|@Bindable|\.inspector[[:space:]]*\(|\.contentMargins|Button[[:space:]]*\([^)]*systemImage:|initial:|AccessibilityNotification|backgroundProminence|SettingsLink|containerRelativeFrame|\.scrollPosition[[:space:]]*\(|\.phaseAnimator|\.keyframeAnimator|\.scrollTargetBehavior|\.sensoryFeedback|\.containerBackground|\.presentationBackground|\.focusEffectDisabled|\.defaultScrollAnchor|\.windowResizeBehavior|\.windowToolbarStyle|\.activate[[:space:]]*\(\)|buttonBorderShape[[:space:]]*\(\.capsule\)|onChange[[:space:]]*\(of:[^{]*\)[[:space:]]*\{[[:space:]]*[A-Za-z_]+[[:space:]]*,[[:space:]]*[A-Za-z_]+[[:space:]]+in|glassEffect|\.fileDropDestination' '^App/DesignSystem/Compat\.swift:')"

# G13. Calls that perform an act may not be silenced or ignored: the journal result gates the act.
R_TRYQ='try[?!][[:space:]]*(await[[:space:]]+)?(Renamer|Copier|Linker|Placeholder|Trasher|Redirect|DefaultsRedirect|Verifier|Journal|ProcessRunner)\.'
R_BAREJ='^[[:space:]]*Journal\.(begin|intent)[[:space:]]*\('
R_UNDERJ='_[[:space:]]*=[[:space:]]*(try[[:space:]]+)?Journal\.(begin|intent)'
selftest tryq "$R_TRYQ" 'try? Renamer.perform(.setAside, plan)'
selftest tryq "$R_TRYQ" 'try! await Copier.copy(plan)'
selftest tryq "$R_TRYQ" 'let ok = try? ProcessRunner.run(.defaultsWrite(d, k, t, v))'
selftest barej "$R_BAREJ" '    Journal.intent(.setAside, subject: s, home: home)'
selftest underj "$R_UNDERJ" '_ = Journal.intent(.setAside, subject: s, home: home)'
cleantest barej "$R_BAREJ" '    guard Journal.intent(.setAside, subject: s, home: home) else { return .notAttempted }'
cleantest underj "$R_UNDERJ" '    guard Journal.intent(.setAside, subject: s, home: home) else { return .notAttempted }'
check "No try?/try! on Renamer, Copier, Linker, Placeholder, Trasher, Redirect, DefaultsRedirect, Verifier, Journal or ProcessRunner" "$(hits "$R_TRYQ")"
check "Journal.begin/intent results are never ignored (the intent gates the act): guard it" "$(hits "$R_BAREJ")"
check "Journal.begin/intent results are never discarded with _ =" "$(hits "$R_UNDERJ")"

# G14/G16. Debug-only hooks never reach Release (CI builds Debug AND Release). Policy is built in one file; only Policy.release outside DEBUG.
debug_only_hits() {   # tokens that may appear only between #if DEBUG and #endif
  local f
  while IFS= read -r f; do
    awk -v F="$f" -v tok='Faults[.]|enum Faults|Policy[.]testing' '
      /^[[:space:]]*#if[[:space:]]+DEBUG[[:space:]]*$/ { depth++; dbg[depth] = 1; next }
      /^[[:space:]]*#if[[:space:]]/ { depth++; dbg[depth] = 0; next }
      /^[[:space:]]*#(else|elseif)/ { if (depth > 0) dbg[depth] = 0; next }
      /^[[:space:]]*#endif/ { if (depth > 0) depth--; next }
      { ind = 0; for (i = 1; i <= depth; i++) if (dbg[i]) ind = 1
        if (!ind && $0 !~ /^[[:space:]]*\/\// && $0 ~ tok) print F ":" NR ": " $0 }
    ' "$f"
  done < <(find Sources App -name '*.swift' 2>/dev/null)
}
dbg_selftest() {
  local T; T=$(mktemp -d)
  printf '%s\n' 'let a = Policy.release' '#if DEBUG' 'let b = Policy.testing' 'Faults.hit(.x)' '#endif' > "$T/ok.swift"
  printf '%s\n' '#if DEBUG' 'let b = Policy.testing' '#else' 'let c = Policy.testing' '#endif' > "$T/bad1.swift"
  printf '%s\n' 'Faults.hit(.afterIntent(.copy))' > "$T/bad2.swift"
  printf '%s\n' '#if os(macOS)' 'let c = Policy.testing' '#endif' > "$T/bad3.swift"
  local f
  for f in ok bad1 bad2 bad3; do
    local out
    out=$(awk -v F="$f" -v tok='Faults[.]|enum Faults|Policy[.]testing' '
      /^[[:space:]]*#if[[:space:]]+DEBUG[[:space:]]*$/ { depth++; dbg[depth] = 1; next }
      /^[[:space:]]*#if[[:space:]]/ { depth++; dbg[depth] = 0; next }
      /^[[:space:]]*#(else|elseif)/ { if (depth > 0) dbg[depth] = 0; next }
      /^[[:space:]]*#endif/ { if (depth > 0) depth--; next }
      { ind = 0; for (i = 1; i <= depth; i++) if (dbg[i]) ind = 1
        if (!ind && $0 !~ /^[[:space:]]*\/\// && $0 ~ tok) print F ":" NR ": " $0 }' "$T/$f.swift")
    if [ "$f" = ok ]; then [ -z "$out" ] || check "safety_greps self-test: the DEBUG scan flagged code inside #if DEBUG" "$out"
    else [ -n "$out" ] || check "safety_greps self-test: the DEBUG scan missed $f" "self-test failed"; fi
  done
  rm -rf "$T"
}
dbg_selftest
check "Faults.* and Policy.testing only inside #if DEBUG (CI builds Debug and Release)" "$(debug_only_hits)"
R_POLICYCTOR='(^|[^[:alnum:]_])Policy[[:space:]]*\('
selftest policyctor "$R_POLICYCTOR" 'let p = Policy(allowsDiskImages: true, treatsAllRecipesAsVerified: true)'
cleantest policyctor "$R_POLICYCTOR" 'let p = Policy.release; let g = GuardPolicy.check(x)'
check "Policy( is constructed only in $CORE/Model/Drive.swift; everyone else picks Policy.release (or Policy.testing under DEBUG)" "$(hits "$R_POLICYCTOR" "^$CORE/Model/Drive\.swift:")"

# G15. Honest copy: tools/banned_phrases.txt is matched against everything the user can read (App/, Sources/ strings, site/, .github/,
#      README.md, CHANGELOG.md). Whole-line // comments in Swift are exempt; any other line may carry the marker `no-claim-ok`
#      when it names a banned phrase only to say we do not make that claim.
BP=tools/banned_phrases.txt
BP_RE=$(grep -vE '^[[:space:]]*(#|$)' "$BP" 2>/dev/null | paste -sd'|' -)
bp_hits() {   # bp_hits FILE_OR_DIR...: banned phrase hits, minus marker lines and Swift comment lines
  grep -rnsIiE --exclude-dir=_dist --exclude='BannedPhrases.swift' "$BP_RE" "$@" | grep -vF 'no-claim-ok' | grep -vE '^[^:]+\.swift:[0-9]+:[[:space:]]*//' || true
}
if [ -f "$BP" ]; then
  T=$(mktemp -d)
  cat > "$T/p.txt" <<'PHRASES'
Safe to unplug
Safely eject your drive
100% safe
We guarantee it
no data loss
never lose a file
Your files stay intact
Runs faster from an SSD
Speeds up Xcode
works like internal storage
use an external SSD as internal
Automatically moves new apps
Auto-configure new installs
fully reversible
a verified backup of your data
Tested on macOS 26
Move in one click
This is risk-free
secure erase
a fully verified copy
Apple-approved
expands your storage
It will boost your builds
PHRASES
  want=$(grep -c . "$T/p.txt"); got=$(grep -ciE "$BP_RE" "$T/p.txt")
  [ "$got" -eq "$want" ] || check "safety_greps self-test: banned phrases missed ($got of $want matched)" "$(grep -viE "$BP_RE" "$T/p.txt")"
  sed 's/$/  no-claim-ok/' "$T/p.txt" > "$T/m.txt"
  [ -z "$(bp_hits "$T/m.txt")" ] || check "safety_greps self-test: the no-claim-ok marker did not exempt" "$(bp_hits "$T/m.txt")"
  cat > "$T/h.txt" <<'HONEST'
Your original is kept as DerivedData.before-move until you confirm.
Eject the drive in Finder first.
Compared 48,211 files by size and SHA-256: 0 differences.
Not yet tried on a real Mac.
Safety copies still on this Mac: 41 GB until you confirm.
macOS protects this folder.
Measured on this Mac. Nothing was moved.
Outboard drive was ejected. Plug it back in and we'll put things back.
Outboard can't make unplugging a drive harmless.
HONEST
  [ -z "$(bp_hits "$T/h.txt")" ] || check "safety_greps self-test: banned-phrase regex flagged honest copy" "$(bp_hits "$T/h.txt")"
  rm -rf "$T"
  check "Banned phrases (tools/banned_phrases.txt) in App/, Sources/, site/, .github/, README.md or CHANGELOG.md; mark an intentional mention 'no-claim-ok' and say why" \
    "$(bp_hits App Sources site README.md CHANGELOG.md .github)"
else
  check "tools/banned_phrases.txt is missing" "missing"
fi
# "Not yet tried on a real Mac." stays on the README and the site while any recipe is not verifiedOnRealMac: true. Recipes are Swift
# data (one `Recipe(` per entry in Sources/OutboardCore/Recipes); tools/check_recipes.py and a Core test validate the exported JSON.
recipe_marker() {
  [ -d "$CORE/Recipes" ] || return 0
  local n v
  n=$(grep -rhE --include=*.swift '^[[:space:]]*(static let [A-Za-z0-9_]+ *(: *Recipe)? *= *)?Recipe\(id:' "$CORE/Recipes" | wc -l)
  v=$(grep -rhE --include=*.swift 'verifiedOnRealMac:[[:space:]]*true' "$CORE/Recipes" | wc -l)
  [ "$n" -gt "$v" ] || return 0
  [ -f README.md ] && ! grep -qF 'Not yet tried on a real Mac.' README.md && echo "README.md: lost 'Not yet tried on a real Mac.' while $((n - v)) recipe(s) are not verified"
  if [ -d site ] && ! grep -rqF 'Not yet tried on a real Mac.' site; then echo "site/: lost 'Not yet tried on a real Mac.' while $((n - v)) recipe(s) are not verified"; fi
  return 0
}
check "README.md and site/ must say 'Not yet tried on a real Mac.' while any recipe has verifiedOnRealMac false (remove only with a docs/VERIFY_LOG.md entry)" "$(recipe_marker)"

# G18. Only Swift is compiled: a C/ObjC file or a build-phase script would escape every grep above.
check "Sources/ and App/ hold no non-Swift source files; project.yml has no build scripts; Package.swift no plugins" \
  "$(find Sources App -type f \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.m' -o -name '*.mm' -o -name '*.h' -o -name '*.hpp' -o -name '*.s' -o -name '*.S' -o -name '*.sh' -o -name '*.py' -o -name '*.js' -o -name '*.pl' -o -name '*.rb' \) 2>/dev/null; grep -nE 'preBuildScripts|postBuildScripts|postCompileScripts|buildToolPlugins|runOnlyWhenInstalling|^[[:space:]]*-?[[:space:]]*script:' project.yml 2>/dev/null || true; grep -nE '\.plugin\(|plugins:|unsafeFlags|linkerSettings|cSettings' Package.swift || true)"

# G20. Recipes are data: a Mac file cannot invent a restore verb or an on-drive-missing action, and nothing deletes a setting.
check "No deleting of settings (.deleteSetting, .removeSetting ...): a restore writes the prior or neutral value" "$(hits '\.(delete|remove)[A-Za-z]*Setting')"
selftest settingdel '\.(delete|remove)[A-Za-z]*Setting' 'case .deleteSetting: break'
check "OnDriveMissing, DefaultsRestore and DefaultsValueSource are declared only in Core (a Mac file cannot invent a verb)" \
  "$(hits '(enum|struct|class|extension)[[:space:]]+(OnDriveMissing|DefaultsRestore|DefaultsValueSource|DefaultsKeySpec)\b' '' "$M App")"

# --- Pinned-line checks (Overstay's Signal.swift pattern). The files that move things keep their guard order. ------------------
#     `ordered FILE LINES...` prints a problem per missing or out-of-order line; the self-tests build a synthetic file from the
#     required lines and mutate it (every pin lost, every adjacent pair swapped, every extra forbidden line appended).
ordered() {
  local f=$1; shift
  local c prev=0 n s
  c=$(grep -nvE '^[[:space:]]*//' "$f")
  for s in "$@"; do
    n=$(printf '%s\n' "$c" | grep -F -m1 -- "$s" | cut -d: -f1)
    if [ -z "$n" ]; then echo "$f: lost the line: $s"; continue; fi
    if [ "$n" -le "$prev" ]; then echo "$f: out of order (must come after the previous pinned line): $s"; fi
    prev=$n
  done
}
present() {   # present FILE LINES...: every pinned line is there (any order)
  local f=$1; shift
  local c s
  c=$(grep -vE '^[[:space:]]*//' "$f")
  for s in "$@"; do printf '%s\n' "$c" | grep -qF -- "$s" || echo "$f: lost the line: $s"; done
}
verbs_banned() {   # verbs_banned FILE [ALLOWED_REGEX]: the other verbs may not appear in this file
  local f=$1 allow=${2:-^$}
  grep -vE '^[[:space:]]*//' "$f" | grep -E '(^|[^[:alnum:]_])(moveItem|copyItem|trashItem|createSymbolicLink)[[:space:]]*\(|\.removeItem|\.replaceItem|NSWorkspace|(^|[^[:alnum:]_])Process[[:space:]]*\(' | grep -vE "$allow" | sed "s|^|$f: forbidden call: |" || true
}
count_is_one() {   # count_is_one FILE REGEX LABEL
  local n
  n=$(grep -vE '^[[:space:]]*//' "$1" | grep -cE "$2")
  [ "$n" -eq 1 ] || echo "$1: expected exactly one $3, found $n"
}
no_try_on() {   # no_try_on FILE REGEX: no try?/try! on the lines matching REGEX
  grep -vE '^[[:space:]]*//' "$1" | grep -E "$2" | grep -E 'try[?!]' | sed "s|^|$1: try?/try! on an act: |" || true
}
no_suspension_between() {   # no_suspension_between FILE FROM TO
  local f=$1 c a b
  c=$(grep -nvE '^[[:space:]]*//' "$f")
  a=$(printf '%s\n' "$c" | grep -F -m1 -- "$2" | cut -d: -f1)
  b=$(printf '%s\n' "$c" | grep -F -m1 -- "$3" | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then
    printf '%s\n' "$c" | awk -F: -v a="$a" -v b="$b" '$1>=a && $1<=b' | grep -E '\bawait\b|Task\.sleep|Task\.yield|DispatchQueue|withCheckedContinuation|withTaskGroup' | sed "s|^|$f: suspension point between $2 and $3: |" || true
  fi
}

# MoveEngine.swift: the copy-verify-swap sequence. Verdict cases are distinct names so one case cannot satisfy two pins. Exactly one
# call of each of the four acts; no suspension point between the fresh recheck and the redirect; the engine only calls the verbs.
ENGINE_PINS=('Journal.begin(' 'Preflight.run(' 'case .passed: break' 'Copier.copy(' 'Verifier.verify(' 'case .verified: break' 'Renamer.perform(.publish' 'Guard.recheck(' 'case .unchanged: break' 'RunningCheck.state(' 'case .notRunning: break' 'Renamer.perform(.setAside' 'Redirect.apply(' 'Health.check(' 'Journal.result(.swapped')
engineprobs() {
  local f=$1
  ordered "$f" "${ENGINE_PINS[@]}"
  count_is_one "$f" 'Copier\.copy\(' 'Copier.copy('
  count_is_one "$f" 'Renamer\.perform\(\.publish' 'Renamer.perform(.publish'
  count_is_one "$f" 'Renamer\.perform\(\.setAside' 'Renamer.perform(.setAside'
  count_is_one "$f" 'Redirect\.apply\(' 'Redirect.apply('
  no_try_on "$f" 'Copier\.|Renamer\.|Linker\.|Redirect\.|Verifier\.|Journal\.|Placeholder\.|Trasher\.'
  no_suspension_between "$f" 'Guard.recheck(' 'Redirect.apply('
  verbs_banned "$f"
}
# Copier.swift: rules, fresh stamp, write-ahead intent, the one copyItem, result.
COPY_PINS=('CopyRules.check(' 'Guard.verifyStamp(' 'Journal.intent(' 'copyItem(at:' 'Journal.result(')
copyprobs() {
  local f=$1
  ordered "$f" "${COPY_PINS[@]}"
  count_is_one "$f" '(^|[^[:alnum:]_])copyItem[[:space:]]*\(' 'copyItem('
  no_try_on "$f" 'copyItem'
  verbs_banned "$f" 'copyItem'
}
# Renamer.swift: takes a closed RenameOp; the rules approve the pair; fresh stamp; intent; the one moveItem; result.
RENAME_PINS=('RenameRules.check(' 'Guard.verifyStamp(' 'Journal.intent(' 'moveItem(at:' 'Journal.result(')
renameprobs() {
  local f=$1
  ordered "$f" "${RENAME_PINS[@]}"
  count_is_one "$f" '(^|[^[:alnum:]_])moveItem[[:space:]]*\(' 'moveItem('
  no_try_on "$f" 'moveItem'
  verbs_banned "$f" 'moveItem'
}
# Linker.swift: rules, the drive's identity, intent, the one createSymbolicLink, result.
LINK_PINS=('LinkRules.check(' 'VolumeIdentity.matches(' 'Journal.intent(' 'createSymbolicLink(atPath:' 'Journal.result(')
linkprobs() {
  local f=$1
  ordered "$f" "${LINK_PINS[@]}"
  count_is_one "$f" 'createSymbolicLink[[:space:]]*\(' 'createSymbolicLink('
  no_try_on "$f" 'createSymbolicLink'
  verbs_banned "$f" 'createSymbolicLink'
}
# Trasher.swift: only a leftover or a <name>.before-move the journal knows; fresh stamp; intent; the one trashItem with its resultingItemURL; result.
TRASH_PINS=('TrashRules.allows(' 'Guard.verifyStamp(' 'Journal.intent(' 'trashItem(at: url, resultingItemURL: &resulting)' 'Journal.result(')
trashprobs() {
  local f=$1
  ordered "$f" "${TRASH_PINS[@]}"
  count_is_one "$f" 'trashItem[[:space:]]*\(' 'trashItem('
  no_try_on "$f" 'trashItem'
  no_suspension_between "$f" 'Guard.verifyStamp(' 'trashItem('
  verbs_banned "$f" 'trashItem'
}
# DefaultsRedirect.swift: catalogue key, the app is not running, intent, the one defaults write, a read back, result.
DEFAULTS_PINS=('Catalogue.allowsDefaults(' 'RunningCheck.state(' 'case .notRunning: break' 'Journal.intent(' 'ProcessRunner.run(.defaultsWrite(' 'ProcessRunner.run(.defaultsRead(' 'Journal.result(')
defaultsprobs() {
  local f=$1
  ordered "$f" "${DEFAULTS_PINS[@]}"
  count_is_one "$f" '\.defaultsWrite\(' '.defaultsWrite( call'
  no_try_on "$f" 'ProcessRunner|Journal\.'
  verbs_banned "$f"
}
# Rollback.swift: the app is not running (asked in runningProblem, which the user's own rollback calls before its first journal line),
# journal, undo the redirect, rename the original back, result .rolledBack. (Forget lives here too.)
ROLLBACK_PINS=('RunningCheck.state(' 'case .notRunning: break' 'Journal.begin(' 'Redirect.revert(' 'Renamer.perform(.undoSetAside' 'Journal.result(.rolledBack')
rollbackprobs() {
  local f=$1
  ordered "$f" "${ROLLBACK_PINS[@]}"
  no_try_on "$f" 'Renamer\.|Redirect\.|Journal\.'
  verbs_banned "$f"
}
# Park.swift: the drive is gone (UUID, not path), our link is still there, the rules approve the pair before any line is written, intent, rename the link into Parked/, the note, result.
PARK_PINS=('VolumeIdentity.absent(' 'Guard.verifyStamp(' 'RenameRules.check(' 'Journal.intent(' 'Renamer.perform(.park' 'Placeholder.create(' 'Journal.result(')
parkprobs() {
  local f=$1
  ordered "$f" "${PARK_PINS[@]}"
  no_try_on "$f" 'Renamer\.|Placeholder\.|Journal\.'
  verbs_banned "$f"
}
# Unpark.swift: identity, sentinel, no hold, fresh stamp, intent, rename the note away, a fresh link to the current mount point, health, result.
UNPARK_PINS=('VolumeIdentity.matches(' 'Sentinel.matches(' 'Held.evaluate(' 'case .clear: break' 'Guard.verifyStamp(' 'Journal.intent(' 'Renamer.perform(.unpark' 'Linker.create(' 'Health.check(' 'Journal.result(')
unparkprobs() {
  local f=$1
  ordered "$f" "${UNPARK_PINS[@]}"
  no_try_on "$f" 'Renamer\.|Linker\.|Journal\.'
  verbs_banned "$f"
}
# Placeholder.swift: the 0444 note is created with its mode (no chmod anywhere), write-ahead intent, result; it never overwrites.
PLACEHOLDER_PINS=('Journal.intent(' 'createFile(atPath:' '0o444' 'Journal.result(')
placeholderprobs() {
  local f=$1
  ordered "$f" "${PLACEHOLDER_PINS[@]}"
  no_try_on "$f" 'Journal\.'
  count_is_one "$f" 'createFile[[:space:]]*\(' 'createFile('
  verbs_banned "$f"
}
# Verifier.swift: SHA-256 with the page cache bypassed on the destination, the walk guards, the difference check, and exactly one
# .verified, which is the last return of verify(). A second `return .verified(`, a dropped `noCache: true` on the destination hash, a
# dropped difference check, or any return after the verdict fails.
VERIFY_PINS=('import CryptoKit' 'F_NOCACHE' 'SHA256' 'static func verify(' 'return .mismatch(' 'noCache: true' 'if !differences.isEmpty {' 'return .verified(')
verifyprobs() {
  local f=$1
  ordered "$f" "${VERIFY_PINS[@]}"
  count_is_one "$f" 'return[[:space:]]+\.verified\(' 'return .verified('
  grep -vE '^[[:space:]]*//' "$f" | awk -v F="$f" '
    /static func verify\(/ { on = 1; next }
    on && /static func / { on = 0 }
    on && /^[[:space:]]*return[[:space:]]/ { last = $0 }
    END { if (last !~ /return[[:space:]]+\.verified\(/) print F ": the last return in verify() must be .verified(: " last }'
  verbs_banned "$f"
}
# OutboardRoot.swift: nothing is created under /Volumes before the volume's UUID is confirmed mounted.
ROOT_PINS=('VolumeIdentity.mounted(' 'createDirectory(')
rootprobs() {
  local f=$1
  ordered "$f" "${ROOT_PINS[@]}"
  verbs_banned "$f"
}
# Journal.swift: append-only, never follows a symlink, private file and folder, durable, fail closed.
JOURNAL_PINS=('O_APPEND' 'O_NOFOLLOW' 'O_NONBLOCK' '0o600' '0o700' 'fsync(' 'static func begin(' 'static func intent(' 'static func result(')
journalprobs() {
  local f=$1
  present "$f" "${JOURNAL_PINS[@]}"
  grep -vE '^[[:space:]]*//' "$f" | grep -E 'O_TRUNC|ftruncate|\.removeItem|F_FULLFSYNC' | sed "s|^|$f: forbidden: |" || true
}
# Guard.swift: the fresh checks every verb leans on: lstat (never followed), device, the same object, the volume.
GUARD_PINS=('static func verifyStamp(' 'static func recheck(' 'lstat(' 'st_dev' 'isSameObject(')
guardprobs() { present "$1" "${GUARD_PINS[@]}"; }
# LoginItem.swift: the main app only; never an agent, a daemon or a login item helper.
LOGIN_PINS=('import ServiceManagement' 'SMAppService.mainApp')
loginprobs() {
  local f=$1
  present "$f" "${LOGIN_PINS[@]}"
  grep -vE '^[[:space:]]*//' "$f" | grep -E 'SMAppService\.(agent|daemon|loginItem)|SMAppService\(' | sed "s|^|$f: only SMAppService.mainApp: |" || true
}
# ProcessRunner.swift: a closed enum of commands; the only absolute paths are theirs; the only dash-arguments are -plist and -X;
# a defaults read or write is always preceded by the catalogue allowlist; a timed-out command is abandoned, never signalled.
PROCESS_PINS=('return "/usr/sbin/diskutil"' 'return "/usr/bin/defaults"' 'return "/usr/bin/tmutil"' 'return ["info", "-plist", path]' 'return ["list", "-plist"]' 'return ["apfs", "list", "-plist"]' 'return ["destinationinfo", "-X"]' 'Catalogue.allowsDefaults(domain, key)' 'return ["read", domain, key]' 'return ["write", domain, key, type.flag, value]' 'process.executableURL = URL(fileURLWithPath: command.path)' 'process.arguments = command.arguments')
processprobs() {
  local f=$1 c n
  c=$(grep -vE '^[[:space:]]*//' "$f")
  present "$f" "${PROCESS_PINS[@]}"
  printf '%s\n' "$c" | grep -oE '"/(usr|bin|sbin|opt|System|Library|private)[^"]*"' | grep -vxE '"/usr/sbin/diskutil"|"/usr/bin/defaults"|"/usr/bin/tmutil"' | sed "s|^|$f: unexpected absolute path literal: |" || true
  printf '%s\n' "$c" | grep -oE '"-[A-Za-z-]*"' | grep -vxE '"-plist"|"-X"' | sed "s|^|$f: unexpected dash argument: |" || true
  printf '%s\n' "$c" | grep -v '^[[:space:]]*import ' | grep -E '\b(eraseVolume|eraseDisk|addVolume|deleteVolume|deleteContainer|resizeContainer|mount|unmount|eject|mountDisk|unmountDisk|repairVolume|enableOwnership|disableOwnership|secureErase|partitionDisk|changeVolumeRole|passphrase|delete|delete-all|import|export|rename|sudo|listlocalsnapshots|deletelocalsnapshots)\b' | sed "s|^|$f: forbidden word: |" || true
  n=$(printf '%s\n' "$c" | grep -cE '\.arguments[[:space:]]*=')
  [ "$n" -eq 1 ] || echo "$f: expected exactly one .arguments assignment, found $n"
  n=$(printf '%s\n' "$c" | grep -cE '\.executableURL[[:space:]]*=')
  [ "$n" -eq 1 ] || echo "$f: expected exactly one .executableURL assignment, found $n"
  printf '%s\n' "$c" | grep -E 'terminate\(|interrupt\(|kill|launchPath|\.launch\(\)' | sed "s|^|$f: a timed-out command is abandoned, never signalled: |" || true
  # every defaults read/write return is preceded (within 3 lines) by the allowlist
  printf '%s\n' "$c" | awk -v F="$f" '
    { line[NR] = $0 }
    /return \["(read|write)", domain, key/ { ok = 0; for (i = NR - 3; i < NR; i++) if (i > 0 && line[i] ~ /Catalogue\.allowsDefaults\(/) ok = 1
                                              if (!ok) print F ": defaults read/write without Catalogue.allowsDefaults( just before it: " $0 }'
}
# Materialization.swift: dataless files are never materialized, process-wide, from the first statement of the app (EDEADLK then means dataless).
matprobs() {
  local f=$1 s
  for s in 'typeMaterializeDatalessFiles: Int32 = 3' 'scopeProcess: Int32 = 0' 'materializeOff: Int32 = 1' \
           'setiopolicy_np(typeMaterializeDatalessFiles, scopeProcess, materializeOff) == 0'; do
    grep -qF -- "$s" "$f" || echo "$f: lost the line: $s"
  done
  grep -qE 'static func disableForProcess\(\)' "$f" || echo "$f: lost disableForProcess()"
  grep -E 'scopeThread|materializeOn|allowingOnThisThread' "$f" | grep -vE '^[[:space:]]*//' && echo "$f: Outboard never turns materialization back on"
}
MAT=$M/Materialization.swift
check "setiopolicy_np only in $MAT" "$(hits 'setiopolicy_np|getiopolicy_np|IOPOL_' "^$MAT:")"
if [ -f App/OutboardApp.swift ]; then
  grep -qF 'Materialization.disableForProcess()' App/OutboardApp.swift || check "App/OutboardApp.swift must call Materialization.disableForProcess() at launch" "App/OutboardApp.swift: missing call"
fi

selfcheck

# --- the real files, when they exist ----------------------------------------------------------------------------------------
probe_file() {   # probe_file FILE FN MESSAGE
  [ -f "$1" ] && check "$3" "$($2 "$1")"
  return 0
}
probe_file "$M/MoveEngine.swift" engineprobs "$M/MoveEngine.swift must keep journal, preflight, copy, verify, publish, recheck, running check, set-aside, redirect, health, result order; one call of each act; no await from recheck to redirect"
probe_file "$M/Copier.swift" copyprobs "$M/Copier.swift must keep rules, stamp, intent, one copyItem, result"
probe_file "$M/Renamer.swift" renameprobs "$M/Renamer.swift must keep rules, stamp, intent, one moveItem, result"
probe_file "$M/Linker.swift" linkprobs "$M/Linker.swift must keep rules, volume identity, intent, one createSymbolicLink, result"
probe_file "$M/Trasher.swift" trashprobs "$M/Trasher.swift must keep rules, stamp, intent, one trashItem with its resultingItemURL, result"
probe_file "$M/DefaultsRedirect.swift" defaultsprobs "$M/DefaultsRedirect.swift must keep allowlist, running check, intent, the one defaults write, read back, result"
probe_file "$M/Rollback.swift" rollbackprobs "$M/Rollback.swift must keep running check, redirect revert, rename back, result"
probe_file "$M/Park.swift" parkprobs "$M/Park.swift must keep absence by UUID, stamp, intent, rename into Parked/, note, result"
probe_file "$M/Unpark.swift" unparkprobs "$M/Unpark.swift must keep identity, sentinel, no hold, stamp, intent, rename, fresh link, health, result"
probe_file "$M/Placeholder.swift" placeholderprobs "$M/Placeholder.swift must create the note with mode 0444 after its intent, never overwrite"
probe_file "$M/Verifier.swift" verifyprobs "$M/Verifier.swift must hash with SHA-256, bypass the page cache and never return .verified early"
probe_file "$M/OutboardRoot.swift" rootprobs "$M/OutboardRoot.swift must confirm the volume UUID is mounted before any createDirectory"
probe_file "$M/Journal.swift" journalprobs "$M/Journal.swift must stay append-only, no-follow, 0600/0700, fsync'd"
probe_file "$M/Guard.swift" guardprobs "$M/Guard.swift must keep verifyStamp, recheck, lstat, st_dev and isSameObject"
probe_file "$M/LoginItem.swift" loginprobs "$M/LoginItem.swift must use SMAppService.mainApp only"
probe_file "$M/ProcessRunner.swift" processprobs "$M/ProcessRunner.swift must run exactly diskutil info/list/apfs list, defaults read/write for catalogue keys, tmutil destinationinfo"
probe_file "$MAT" matprobs "$MAT must disable dataless materialization process-wide and never re-enable it"

# --- self-tests of the probes: a synthetic file made of the pinned lines is clean; every lost pin, every swapped pair and every
#     forbidden extra line is flagged -------------------------------------------------------------------------------------------
# mutants NAME FN ORDERED(0|1) PINS...      then, per extra bad line:  bad_extra NAME FN 'line' PINS...
mutants() {
  local name=$1 fn=$2 ord=$3; shift 3
  local pins=("$@") T i j n=${#pins[@]} m tmp
  T=$(mktemp -d)
  printf '%s\n' "${pins[@]}" > "$T/clean.swift"
  [ -z "$($fn "$T/clean.swift")" ] || check "safety_greps self-test: $name flagged its own pinned lines" "$($fn "$T/clean.swift")"
  for ((i = 0; i < n; i++)); do
    m=(); for ((j = 0; j < n; j++)); do [ "$j" -ne "$i" ] && m+=("${pins[$j]}"); done
    printf '%s\n' "${m[@]}" > "$T/m.swift"
    [ -n "$($fn "$T/m.swift")" ] || check "safety_greps self-test: the $name check missed the lost pin: ${pins[$i]}" "self-test failed"
  done
  if [ "$ord" = 1 ]; then
    for ((i = 0; i < n - 1; i++)); do
      m=("${pins[@]}"); tmp=${m[$i]}; m[$i]=${m[$((i + 1))]}; m[$((i + 1))]=$tmp
      printf '%s\n' "${m[@]}" > "$T/m.swift"
      [ -n "$($fn "$T/m.swift")" ] || check "safety_greps self-test: the $name check missed the swap of ${pins[$i]} and ${pins[$((i + 1))]}" "self-test failed"
    done
  fi
  rm -rf "$T"
}
bad_extra() {   # bad_extra NAME FN 'extra line appended' PINS...
  local name=$1 fn=$2 extra=$3; shift 3
  local T; T=$(mktemp -d)
  { printf '%s\n' "$@"; printf '%s\n' "$extra"; } > "$T/m.swift"
  [ -n "$($fn "$T/m.swift")" ] || check "safety_greps self-test: the $name check missed the extra line: $extra" "self-test failed"
  rm -rf "$T"
}
bad_after() {   # bad_after NAME FN 'pin to follow' 'inserted line' PINS...
  local name=$1 fn=$2 pin=$3 ins=$4; shift 4
  local T s; T=$(mktemp -d)
  : > "$T/m.swift"
  for s in "$@"; do printf '%s\n' "$s" >> "$T/m.swift"; [ "$s" = "$pin" ] && printf '%s\n' "$ins" >> "$T/m.swift"; done
  [ -n "$($fn "$T/m.swift")" ] || check "safety_greps self-test: the $name check missed '$ins' after $pin" "self-test failed"
  rm -rf "$T"
}
if [ -z "${SAFETY_FAST:-}" ]; then   # SAFETY_FAST=1 skips the mutation runs (slow on Windows Git Bash); CI never sets it
  mutants engine engineprobs 1 "${ENGINE_PINS[@]}"
  for x in 'Copier.copy(plan)' 'Renamer.perform(.setAside, plan)' 'Renamer.perform(.publish, plan)' 'Redirect.apply(plan)' 'try? Copier.copy(plan)' 'try! Redirect.apply(plan)' \
           'try fm.removeItem(at: u)' 'try fm.moveItem(at: a, to: b)' 'NSWorkspace.shared.recycle([u]) { _, _ in }' 'let p = Process()'; do
    bad_extra engine engineprobs "$x" "${ENGINE_PINS[@]}"
  done
  bad_after engine engineprobs 'Guard.recheck(' 'await Task.yield()' "${ENGINE_PINS[@]}"
  bad_after engine engineprobs 'RunningCheck.state(' 'let x = await foo()' "${ENGINE_PINS[@]}"
  mutants copier copyprobs 1 "${COPY_PINS[@]}"
  for x in 'try? fm.copyItem(at: a, to: b)' 'try fm.copyItem(at: a, to: b)' 'try fm.moveItem(at: a, to: b)' 'try fm.trashItem(at: u, resultingItemURL: nil)'; do bad_extra copier copyprobs "$x" "${COPY_PINS[@]}"; done
  mutants renamer renameprobs 1 "${RENAME_PINS[@]}"
  for x in 'try? fm.moveItem(at: a, to: b)' 'try fm.moveItem(at: a, to: b)' 'try fm.copyItem(at: a, to: b)' 'try fm.replaceItem(at: a, withItemAt: b)'; do bad_extra renamer renameprobs "$x" "${RENAME_PINS[@]}"; done
  mutants linker linkprobs 1 "${LINK_PINS[@]}"
  for x in 'try? fm.createSymbolicLink(atPath: a, withDestinationPath: b)' 'try fm.createSymbolicLink(atPath: a, withDestinationPath: b)' 'try fm.moveItem(at: a, to: b)'; do bad_extra linker linkprobs "$x" "${LINK_PINS[@]}"; done
  mutants trasher trashprobs 1 "${TRASH_PINS[@]}"
  for x in 'try? fm.trashItem(at: url, resultingItemURL: &resulting)' 'try fm.trashItem(at: url, resultingItemURL: &resulting)' 'try fm.removeItem(at: url)' 'try fm.moveItem(at: a, to: b)' 'NSWorkspace.shared.recycle([u]) { _, _ in }'; do bad_extra trasher trashprobs "$x" "${TRASH_PINS[@]}"; done
  bad_after trasher trashprobs 'Guard.verifyStamp(' 'await Task.yield()' "${TRASH_PINS[@]}"
  mutants defaults defaultsprobs 1 "${DEFAULTS_PINS[@]}"
  for x in 'ProcessRunner.run(.defaultsWrite(d, k, t, v))' 'let q = try? ProcessRunner.run(.defaultsRead(d, k))' 'let p = Process()'; do bad_extra defaults defaultsprobs "$x" "${DEFAULTS_PINS[@]}"; done
  mutants rollback rollbackprobs 1 "${ROLLBACK_PINS[@]}"
  for x in 'try? Renamer.perform(.undoSetAside, plan)' 'try fm.removeItem(at: u)'; do bad_extra rollback rollbackprobs "$x" "${ROLLBACK_PINS[@]}"; done
  mutants park parkprobs 1 "${PARK_PINS[@]}"
  for x in 'try? Placeholder.create(at: p)' 'try fm.removeItem(at: u)'; do bad_extra park parkprobs "$x" "${PARK_PINS[@]}"; done
  mutants unpark unparkprobs 1 "${UNPARK_PINS[@]}"
  for x in 'try? Linker.create(at: p, target: t)' 'try fm.removeItem(at: u)'; do bad_extra unpark unparkprobs "$x" "${UNPARK_PINS[@]}"; done
  mutants placeholder placeholderprobs 1 "${PLACEHOLDER_PINS[@]}"
  for x in 'fm.createFile(atPath: p, contents: nil, attributes: nil)' 'try? Journal.result(.park, subject: s, home: h, status: .ok)'; do bad_extra placeholder placeholderprobs "$x" "${PLACEHOLDER_PINS[@]}"; done
  mutants verifier verifyprobs 1 "${VERIFY_PINS[@]}"
  for x in 'try fm.removeItem(at: u)' 'return .verified(report)' 'return nil' 'return .mismatch(failure)'; do bad_extra verifier verifyprobs "$x" "${VERIFY_PINS[@]}"; done
  bad_after verifier verifyprobs 'static func verify(' 'return .verified(early)' "${VERIFY_PINS[@]}"
  bad_after verifier verifyprobs 'if !differences.isEmpty {' 'return .verified(skip)' "${VERIFY_PINS[@]}"
  mutants root rootprobs 1 "${ROOT_PINS[@]}"
  mutants journal journalprobs 0 "${JOURNAL_PINS[@]}"
  for x in 'let f = O_TRUNC' 'try fm.removeItem(at: u)' 'fcntl(fd, F_FULLFSYNC)'; do bad_extra journal journalprobs "$x" "${JOURNAL_PINS[@]}"; done
  mutants guard guardprobs 0 "${GUARD_PINS[@]}"
  mutants login loginprobs 0 "${LOGIN_PINS[@]}"
  for x in 'try SMAppService.agent(plistName: "x").register()' 'SMAppService.daemon(plistName: "x")'; do bad_extra login loginprobs "$x" "${LOGIN_PINS[@]}"; done
  mutants process processprobs 0 "${PROCESS_PINS[@]}"
  for x in 'let a = "/usr/bin/hdiutil"' 'let a = "/usr/bin/ditto"' 'let a = ["apfs", "addVolume", "disk1s1", "APFS", "x"]' 'let a = ["-passphrase", "x"]' 'let a = ["eraseVolume", "APFS", "x", "disk2"]' \
           'process.arguments = ["x"]' 'process.executableURL = URL(fileURLWithPath: "/usr/bin/open")' 'process.terminate()' 'kill(pid, 9)' 'let s = ["unmount", "force", "disk2"]' 'let s = ["listlocalsnapshots", "/"]'; do
    bad_extra process processprobs "$x" "${PROCESS_PINS[@]}"
  done
  MATPINS=('typeMaterializeDatalessFiles: Int32 = 3' 'scopeProcess: Int32 = 0' 'materializeOff: Int32 = 1' 'setiopolicy_np(typeMaterializeDatalessFiles, scopeProcess, materializeOff) == 0' 'static func disableForProcess()')
  mutants materialization matprobs 0 "${MATPINS[@]}"
  for x in 'let t = scopeThread' 'let m = materializeOn'; do bad_extra materialization matprobs "$x" "${MATPINS[@]}"; done
fi

[ "$fail" -eq 0 ] && echo "safety greps: ok"
exit $fail
