#!/usr/bin/env bash
# The disk-image probes of BUILD_PLAN section 6.4 (E5, E6, T1, T5, T6 and the mount, TCC and Trash questions), run by fixtures.yml on
# macOS runners. Usage: bash tools/probes/volumes.sh OUTDIR. Everything it writes goes to OUTDIR; every command's outcome is data, so
# the script keeps going after a failure and exits 0. The workflow ends with `bash tools/disk_image.sh cleanup` under `if: always()`.
# Never part of the app: the app does not run hdiutil, ditto or any command beyond diskutil, tmutil and defaults.
set -u
cd "$(dirname "$0")/../.." || exit 1
OUT=${1:-out}
# shellcheck source=tools/probes/lib.sh
. tools/probes/lib.sh
HDIUTIL=/usr/bin/hdiutil
PB=/usr/libexec/PlistBuddy
P=$(mktemp -d)
mkdir -p "$P/bin"

# 0. Compile the Swift probes. A compile error is data too (an API that does not exist on this SDK).
for s in volume_facts force_detach copy_tree mount_events trash_on_volume; do
  rec "compile-$s" swiftc -O -swift-version 5 "tools/probes/$s.swift" -o "$P/bin/$s"
done

MP=
attach() {   # attach NAME  ->  sets MP to the mount point; the image file is $P/NAME.sparseimage
  local name=$1 i
  MP=
  retry "$HDIUTIL" create -size 2g -type SPARSE -fs APFS -volname "$name" "$P/$name" > "$OUT/create-$name.txt" 2>&1 || return 1
  retry "$HDIUTIL" attach -plist -nobrowse -noverify -noautofsck "$P/$name.sparseimage" > "$OUT/attach-$name.plist" 2> "$OUT/attach-$name.stderr" || return 1
  for i in 0 1 2 3 4 5 6 7; do
    MP=$("$PB" -c "Print :system-entities:$i:mount-point" "$OUT/attach-$name.plist" 2> /dev/null) && [ -n "$MP" ] && return 0
    MP=
  done
  return 1
}
detach() {   # detach MOUNTPOINT
  "$HDIUTIL" detach "$1" > /dev/null 2>&1 || "$HDIUTIL" detach -force "$1" > /dev/null 2>&1
}
detach_force() {   # detach_force MOUNTPOINT
  "$HDIUTIL" detach -force "$1" > /dev/null 2>&1
}

# 1. E5: the volume, its whole disk and its physical store, as diskutil describes them, the container list, Time Machine with none set up.
if attach Outboard-TEST; then
  echo "Outboard-TEST mounted at $MP" > "$OUT/mount-point.txt"
  rec e5-diskutil-info-volume /usr/sbin/diskutil info -plist "$MP"
  whole=$("$PB" -c 'Print :ParentWholeDisk' "$OUT/e5-diskutil-info-volume.stdout" 2> /dev/null || true)
  store=$("$PB" -c 'Print :APFSPhysicalStores:0:APFSPhysicalStore' "$OUT/e5-diskutil-info-volume.stdout" 2> /dev/null || true)
  note e5-ids "whole disk: ${whole:-unknown}; physical store: ${store:-unknown}"
  [ -n "$whole" ] && rec e5-diskutil-info-whole /usr/sbin/diskutil info -plist "/dev/$whole"
  [ -n "$store" ] && rec e5-diskutil-info-store /usr/sbin/diskutil info -plist "/dev/$store"
  rec e5-diskutil-list /usr/sbin/diskutil list -plist
  rec e5-apfs-list /usr/sbin/diskutil apfs list -plist
  rec e5-tmutil-destinationinfo /usr/bin/tmutil destinationinfo -X
  rec e5-mount mount
  rec e5-volumes-listing ls -le@ /Volumes

  # 2. T1: the UUID as the app reads it (URLResourceValues) next to the one diskutil prints.
  rec t1-volume-facts "$P/bin/volume_facts" "$MP"
  uuid_di=$("$PB" -c 'Print :VolumeUUID' "$OUT/e5-diskutil-info-volume.stdout" 2> /dev/null || true)
  uuid_url=$(sed -n 's/^NSURLVolumeUUIDStringKey = //p' "$OUT/t1-volume-facts.stdout" | head -1)
  note t1-uuid "diskutil VolumeUUID: ${uuid_di:-missing}"
  note t1-uuid "URLResourceValues volumeUUIDString: ${uuid_url:-missing}"
  if [ -n "$uuid_di" ] && [ "$uuid_di" = "$uuid_url" ]; then note t1-uuid "equal, byte for byte"; else note t1-uuid "NOT equal byte for byte (compare case and dashes)"; fi

  # 3. The fixture trees: a Hugging Face-shaped cache (E6) and the T6 fidelity cases.
  F="$P/fixture"
  mkdir -p "$F/hf/models--org--tiny/blobs" "$F/hf/models--org--tiny/snapshots/abc123" "$F/hf/models--org--tiny/refs" "$F/t6"
  printf 'blob-one\n' > "$F/hf/models--org--tiny/blobs/aaaa"
  ln -s ../../blobs/aaaa "$F/hf/models--org--tiny/snapshots/abc123/config.json"
  printf 'abc123' > "$F/hf/models--org--tiny/refs/main"
  printf 'one\n' > "$F/t6/linkA"
  ln "$F/t6/linkA" "$F/t6/linkB"
  ln -s linkA "$F/t6/relsym"
  printf 'x\n' > "$F/t6/xattr"
  xattr -w com.example.outboard probe "$F/t6/xattr" 2> "$OUT/t6-make-xattr.stderr" || true
  printf 'x\n' > "$F/t6/acl"
  chmod +a "everyone deny delete" "$F/t6/acl" 2> "$OUT/t6-make-acl.stderr" || true
  printf 'data\n' > "$F/t6/rsrc"
  printf 'resource fork bytes' 2> "$OUT/t6-make-rsrc.stderr" > "$F/t6/rsrc/..namedfork/rsrc" || true
  head -c 1048576 /dev/zero | tr '\0' 'a' > "$F/t6/plain"
  /usr/bin/ditto --hfsCompression "$F/t6/plain" "$F/t6/compressed" 2> "$OUT/t6-make-compressed.stderr" || true
  printf 'ro\n' > "$F/t6/mode400"
  chmod 400 "$F/t6/mode400"
  dd if=/dev/zero of="$F/t6/sparse" bs=1 count=0 seek=1073741824 2> /dev/null || true
  printf 'a' | dd of="$F/t6/sparse" conv=notrunc 2> /dev/null || true

  # 4. E6 and T6: copy to the volume with FileManager.copyItem (the app's copier), from a compiled binary (also the TCC question), then compare.
  rec t6-copy "$P/bin/copy_tree" "$F" "$MP/Outboard/fixture"
  bounded 60 /usr/bin/log show --last 3m --info --predicate 'subsystem == "com.apple.TCC"' > "$OUT/tcc-log.txt" 2>&1 || true
  D="$MP/Outboard/fixture"
  for p in hf/models--org--tiny/blobs/aaaa hf/models--org--tiny/snapshots/abc123/config.json t6/linkA t6/linkB t6/relsym t6/xattr t6/acl t6/rsrc t6/plain t6/compressed t6/mode400 t6/sparse; do
    {
      echo "== $p"
      echo "src: $(stat -f 'type=%HT mode=%Lp links=%l inode=%i size=%z blocks=%b target=%Y' "$F/$p" 2>&1)"
      echo "dst: $(stat -f 'type=%HT mode=%Lp links=%l inode=%i size=%z blocks=%b target=%Y' "$D/$p" 2>&1)"
      echo "src xattrs: $(xattr -l "$F/$p" 2>&1 | tr '\n' ' ')"
      echo "dst xattrs: $(xattr -l "$D/$p" 2>&1 | tr '\n' ' ')"
      echo "src ls -led: $(ls -led "$F/$p" 2>&1 | tr '\n' ' ')"
      echo "dst ls -led: $(ls -led "$D/$p" 2>&1 | tr '\n' ' ')"
      echo "src flags: $(ls -ldO "$F/$p" 2>&1)"
      echo "dst flags: $(ls -ldO "$D/$p" 2>&1)"
    } >> "$OUT/t6-compare.txt"
  done
  note t6-summary "hard-link pair in the copy shares an inode: $([ "$(stat -f %i "$D/t6/linkA" 2> /dev/null)" = "$(stat -f %i "$D/t6/linkB" 2> /dev/null)" ] && echo yes || echo no)"
  note t6-summary "relative symlink target in the copy: $(readlink "$D/hf/models--org--tiny/snapshots/abc123/config.json" 2>&1) (source: ../../blobs/aaaa)"
  note t6-summary "sparse file blocks, source / copy: $(stat -f %b "$F/t6/sparse") / $(stat -f %b "$D/t6/sparse" 2> /dev/null)"
  note t6-summary "regular files byte-equal (cmp): $(for p in hf/models--org--tiny/blobs/aaaa t6/plain t6/compressed t6/mode400; do cmp -s "$F/$p" "$D/$p" && echo "$p ok" || echo "$p DIFFERS"; done | tr '\n' ' ')"

  # 5. trashItem on the volume.
  rec trash-on-volume "$P/bin/trash_on_volume" "$MP"
  rec trash-listing ls -laeO "$MP/.Trashes"

  # 6. T5: an open file and a held folder, then detach -force, then each call's errno.
  mkdir -p "$MP/t5"
  printf 'held\n' > "$MP/t5/held.txt"
  TRIG="$P/t5-trigger"
  rm -f "$TRIG"
  "$P/bin/force_detach" "$MP/t5/held.txt" "$TRIG" > "$OUT/t5.stdout" 2> "$OUT/t5.stderr" &
  T5PID=$!
  for _ in $(seq 1 60); do grep -q READY "$OUT/t5.stdout" 2> /dev/null && break; sleep 1; done
  rec t5-detach-force "$HDIUTIL" detach -force "$MP"
  touch "$TRIG"
  for _ in $(seq 1 40); do kill -0 "$T5PID" 2> /dev/null || break; sleep 1; done
  kill -0 "$T5PID" 2> /dev/null && { note t5-notes "force_detach did not finish within 40 s after the trigger; it was left to the cleanup step"; kill "$T5PID" 2> /dev/null; }
  wait "$T5PID" 2> /dev/null
  rec t5-mount-after mount
else
  note attach-failed "could not create or attach Outboard-TEST; see create-Outboard-TEST.txt and attach-Outboard-TEST.stderr"
fi

# 7. NSWorkspace notifications in this session: attach, rename (best effort), detach and a forced detach, with the observer running.
"$P/bin/mount_events" 120 > "$OUT/events.stdout" 2> "$OUT/events.stderr" &
EVPID=$!
for _ in $(seq 1 30); do grep -q READY "$OUT/events.stdout" 2> /dev/null && break; sleep 1; done
if attach Outboard-TEST2; then
  sleep 3
  rec events-rename /usr/sbin/diskutil rename "$MP" Outboard-TEST2-renamed
  sleep 3
  MP2=$(ls -d /Volumes/Outboard-TEST2* 2> /dev/null | head -1)
  detach "${MP2:-$MP}"
  sleep 5
  if attach Outboard-TEST3; then
    sleep 3
    detach_force "$MP"
    sleep 5
  fi
fi
kill "$EVPID" 2> /dev/null
wait "$EVPID" 2> /dev/null
note events-notes "events.stdout holds one line per NSWorkspace notification that reached this process; an empty list means a headless session delivers none"

# 8. Writable /Volumes (VERIFY item 12): may this user's process create a folder directly under /Volumes? Cleaned up at once.
rec volumes-writable mkdir /Volumes/outboard-probe-dir
rmdir /Volumes/outboard-probe-dir 2> /dev/null || true

exit 0
