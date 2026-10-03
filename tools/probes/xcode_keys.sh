#!/usr/bin/env bash
# Probe E1 (BUILD_PLAN section 6.4, VERIFY item 5): what the Xcode defaults keys do. It writes IDECustomDerivedDataLocation and
# IDEDerivedDataPathMode (absent, 0, 1, 2) and reads the effective build directory with `xcodebuild -showBuildSettings`, runs one real
# build to see where DerivedData lands, then tries IDECustomDistributionArchivesLocation with `xcodebuild archive`. The answer decides
# whether the first automated move is Xcode build data (B1) or the Hugging Face cache. Usage: bash tools/probes/xcode_keys.sh OUTDIR
# [XCODEGEN_BINARY]. The archive part needs XcodeGen to make a tiny app project; without it that part is skipped and says so.
# Runs on a throwaway runner, so it writes the keys with `defaults write` and removes them again with `defaults delete`; the app does
# neither of those against keys it did not write. Never part of the app. Every outcome is data, so the script exits 0.
set -u
cd "$(dirname "$0")/../.." || exit 1
OUT=${1:-out}
XCODEGEN_BIN=${2:-}
# shellcheck source=tools/probes/lib.sh
. tools/probes/lib.sh
D=com.apple.dt.Xcode
W=$(mktemp -d)
CUSTOM="$W/custom-dd"
mkdir -p "$CUSTOM"

rec e1-xcodebuild-version xcodebuild -version
rec e1-defaults-before defaults read "$D"

# A tiny Swift package: enough for xcodebuild to name a scheme, show settings and build.
mkdir -p "$W/Tiny/Sources/Tiny"
cat > "$W/Tiny/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Tiny", targets: [.executableTarget(name: "Tiny")])
SWIFT
printf 'print("tiny")\n' > "$W/Tiny/Sources/Tiny/main.swift"

clear_keys() {
  defaults delete "$D" IDECustomDerivedDataLocation 2> /dev/null || true
  defaults delete "$D" IDEDerivedDataPathMode 2> /dev/null || true
  defaults delete "$D" IDECustomDistributionArchivesLocation 2> /dev/null || true
}

settings() {   # settings LABEL: the effective build directories under the keys that are set right now
  local label=$1
  ( cd "$W/Tiny" && rec "e1-settings-$label" bounded 300 xcodebuild -scheme Tiny -destination 'generic/platform=macOS' -showBuildSettings )
  {
    echo "== $label"
    echo "defaults: $(defaults read "$D" 2>&1 | tr '\n' ' ')"
    grep -E '^ +(BUILD_DIR|OBJROOT|SYMROOT|BUILD_ROOT) = ' "$OUT/e1-settings-$label.stdout" 2> /dev/null
    echo "exit: $(cat "$OUT/e1-settings-$label.exit" 2> /dev/null)"
  } >> "$OUT/e1-summary.txt"
}

clear_keys
settings baseline

defaults write "$D" IDECustomDerivedDataLocation -string "$CUSTOM"
settings location-only
for mode in 0 1 2; do
  defaults write "$D" IDEDerivedDataPathMode -int "$mode"
  settings "location-mode-$mode"
done

# A relative string with mode 1, the form the blog posts describe (research source S14).
defaults write "$D" IDECustomDerivedDataLocation -string "relative-dd"
defaults write "$D" IDEDerivedDataPathMode -int 1
settings relative-mode-1

# One real build with the absolute path and each mode: where does DerivedData for the package appear?
for mode in 1 2; do
  clear_keys
  defaults write "$D" IDECustomDerivedDataLocation -string "$CUSTOM"
  defaults write "$D" IDEDerivedDataPathMode -int "$mode"
  ( cd "$W/Tiny" && rec "e1-build-mode-$mode" bounded 600 xcodebuild -scheme Tiny -destination 'generic/platform=macOS' build )
  {
    echo "== build with mode $mode, exit $(cat "$OUT/e1-build-mode-$mode.exit" 2> /dev/null)"
    echo "custom folder now holds: $(ls "$CUSTOM" 2>&1 | tr '\n' ' ')"
    echo "default DerivedData holds: $(ls "$HOME/Library/Developer/Xcode/DerivedData" 2>&1 | tr '\n' ' ')"
  } >> "$OUT/e1-summary.txt"
  rm -rf "$CUSTOM"
  mkdir -p "$CUSTOM"
done
clear_keys

# Archives: IDECustomDistributionArchivesLocation. Needs an app project, so XcodeGen makes one.
if [ -n "$XCODEGEN_BIN" ] && [ -x "$XCODEGEN_BIN" ]; then
  mkdir -p "$W/TinyApp/Sources" "$W/archives-custom"
  cat > "$W/TinyApp/project.yml" <<'YAML'
name: TinyApp
options:
  deploymentTarget:
    macOS: "13.0"
targets:
  TinyApp:
    type: application
    platform: macOS
    sources: [Sources]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: example.tinyapp
        GENERATE_INFOPLIST_FILE: "YES"
        CODE_SIGNING_ALLOWED: "NO"
        SKIP_INSTALL: "NO"
schemes:
  TinyApp:
    build:
      targets:
        TinyApp: all
YAML
  printf 'import AppKit\nlet app = NSApplication.shared\nprint(app.activationPolicy().rawValue)\n' > "$W/TinyApp/Sources/main.swift"
  ( cd "$W/TinyApp" && "$XCODEGEN_BIN" generate > "$OUT/e1-xcodegen.txt" 2>&1 )
  ARCH_DEFAULT="$HOME/Library/Developer/Xcode/Archives"
  defaults write "$D" IDECustomDistributionArchivesLocation -string "$W/archives-custom"
  # Without -archivePath: does xcodebuild archive into the custom location, the default one, or refuse?
  ( cd "$W/TinyApp" && rec e1-archive-no-path bounded 600 xcodebuild archive -scheme TinyApp -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO )
  {
    echo "== archive without -archivePath, exit $(cat "$OUT/e1-archive-no-path.exit" 2> /dev/null)"
    echo "custom archives folder: $(find "$W/archives-custom" -maxdepth 3 2>&1 | tr '\n' ' ')"
    echo "default archives folder: $(find "$ARCH_DEFAULT" -maxdepth 3 2>&1 | tr '\n' ' ')"
  } >> "$OUT/e1-summary.txt"
  ( cd "$W/TinyApp" && rec e1-archive-with-path bounded 600 xcodebuild archive -scheme TinyApp -destination 'generic/platform=macOS' -archivePath "$W/explicit.xcarchive" CODE_SIGNING_ALLOWED=NO )
  {
    echo "== archive with -archivePath, exit $(cat "$OUT/e1-archive-with-path.exit" 2> /dev/null); explicit archive exists: $([ -d "$W/explicit.xcarchive" ] && echo yes || echo no)"
    echo "custom archives folder: $(find "$W/archives-custom" -maxdepth 3 2>&1 | tr '\n' ' ')"
  } >> "$OUT/e1-summary.txt"
  clear_keys
else
  note e1-summary "== archives: skipped (no XcodeGen binary given)"
fi

rec e1-defaults-after defaults read "$D"
cat "$OUT/e1-summary.txt" 2> /dev/null
exit 0
