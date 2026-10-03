#!/usr/bin/env bash
# Disk-image helper for CI on macOS runners (BUILD_PLAN section 6.3 and 6.4). Never part of the app: the app does not run hdiutil.
#   bash tools/disk_image.sh smoke OUTDIR   create a 2 GB sparse APFS image named Outboard-TEST, attach it (not browsable), record what
#                                           diskutil says about it into OUTDIR, write and read a file, detach it. Exits 1 if any step fails.
#   bash tools/disk_image.sh cleanup        force-detach every volume named Outboard-TEST* (or OB-TEST*, the ExFAT test's 11-character label) that
#                                           is still mounted. Never fails. Every test volume name starts with one of the two (safety_greps.sh checks).
# Every workflow that attaches an image ends with a `cleanup` step that has `if: always()` (tools/safety_greps.sh checks that).
# Hosted runners answer "Resource busy" to hdiutil now and then, so create, attach and detach retry with a growing pause.
# Plain bash 3.2 syntax: the macOS runners' /bin/bash is 3.2.
set -u
NAME=Outboard-TEST
SHORT=OB-TEST   # ExFAT and FAT labels hold 11 characters
HDIUTIL=/usr/bin/hdiutil
DISKUTIL=/usr/sbin/diskutil

retry() {   # retry COMMAND...: up to 5 attempts, 5 s then 10 s ... between them
  local i
  for i in 1 2 3 4 5; do
    "$@" && return 0
    echo "attempt $i of 5 failed: $*" >&2
    sleep $((i * 5))
  done
  return 1
}

cleanup() {
  local v
  for v in /Volumes/"$NAME"* /Volumes/"$SHORT"*; do
    [ -d "$v" ] || continue
    echo "detaching $v"
    "$HDIUTIL" detach "$v" > /dev/null 2>&1 || "$HDIUTIL" detach -force "$v" > /dev/null 2>&1 || echo "could not detach $v" >&2
  done
  return 0
}

smoke() {
  local out=$1 tmp img mp i
  mkdir -p "$out"
  tmp=$(mktemp -d)
  img="$tmp/smoke"   # hdiutil appends .sparseimage for -type SPARSE
  { sw_vers; uname -m; echo "runner image: ${ImageOS:-unknown} ${ImageVersion:-unknown}"; } > "$out/about.txt"

  # The option spelling of `diskutil image` (macOS 15 and later, if present) is VERIFY item 17: record its usage text, never use it here.
  "$DISKUTIL" image > "$out/diskutil-image-usage.txt" 2>&1 || true

  retry "$HDIUTIL" create -size 2g -type SPARSE -fs APFS -volname "$NAME" "$img" > "$out/create.txt" 2>&1 || { cat "$out/create.txt"; echo "create failed" >&2; return 1; }
  [ -f "$img.sparseimage" ] || { echo "no $img.sparseimage after create" >&2; ls -la "$tmp" >&2; return 1; }

  retry "$HDIUTIL" attach -plist -nobrowse -noverify -noautofsck "$img.sparseimage" > "$out/attach.plist" 2> "$out/attach.stderr" || { cat "$out/attach.stderr" >&2; echo "attach failed" >&2; return 1; }

  mp=
  for i in 0 1 2 3 4 5 6 7; do
    mp=$(/usr/libexec/PlistBuddy -c "Print :system-entities:$i:mount-point" "$out/attach.plist" 2> /dev/null) && [ -n "$mp" ] && break
    mp=
  done
  [ -n "$mp" ] || { echo "attach.plist names no mount point" >&2; cat "$out/attach.plist" >&2; return 1; }
  echo "mounted at $mp" | tee "$out/mount-point.txt"

  "$DISKUTIL" info -plist "$mp" > "$out/diskutil-info.plist" 2> "$out/diskutil-info.stderr" || echo "diskutil info failed (data, not a failure)" >&2
  "$DISKUTIL" apfs list -plist > "$out/apfs-list.plist" 2> "$out/apfs-list.stderr" || echo "diskutil apfs list failed (data, not a failure)" >&2
  mount > "$out/mount.txt" 2>&1 || true

  # An ordinary write and read, as the Mac tests do, so a runner that mounts the image read-only shows up here.
  if printf 'outboard smoke\n' > "$mp/smoke.txt" && [ "$(cat "$mp/smoke.txt")" = "outboard smoke" ]; then
    echo "write and read on the image: ok" | tee "$out/write-read.txt"
  else
    echo "write or read on the image failed" | tee "$out/write-read.txt" >&2
    retry "$HDIUTIL" detach -force "$mp" > /dev/null 2>&1 || true
    return 1
  fi

  retry "$HDIUTIL" detach "$mp" > "$out/detach.txt" 2>&1 || { "$HDIUTIL" detach -force "$mp" >> "$out/detach.txt" 2>&1 || { cat "$out/detach.txt" >&2; echo "detach failed" >&2; return 1; }; }
  if [ -d "$mp" ] && mount | grep -qF "$mp"; then echo "$mp is still mounted after detach" >&2; return 1; fi
  echo "smoke: ok"
}

case "${1:-}" in
  smoke) smoke "${2:-out}" ;;
  cleanup) cleanup ;;
  *) echo "usage: bash tools/disk_image.sh smoke OUTDIR | cleanup" >&2; exit 2 ;;
esac
