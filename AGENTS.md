# Outboard: notes for coding agents

Outboard is a free, open-source (MIT), offline macOS app (Swift/SwiftUI, macOS 13+, Swift 5 language mode, not sandboxed, no
network, no helper, no root). It is a Storage Planner for people with an external SSD: it measures the big folders apps keep on the
Mac, moves the ones with a known method (a verified copy, the original kept until the user confirms, every step in a log), guides
the rest, and runs a Drive Guard that announces a missing drive and parks a note where the folder was. It does **not** auto-configure
new installs (there is no install hook) and it makes no claim about speed or about making an external drive behave like internal storage.

Read [docs/BUILD_PLAN.md](docs/BUILD_PLAN.md) first. It is the contract: model and Core API (§4), Mac API (§5), safety rules and CI
greps (§3), UI rules and copy (§8), demo mode (§9), file ownership (§10). Product background and evidence: the Whydunit repo's
`docs/next/APP6.md`, `IDEA3.md` and `app6-research-*.md`. Going live: [docs/GO_LIVE.md](docs/GO_LIVE.md), [docs/RELEASING.md](docs/RELEASING.md).
What real Macs have tried: [docs/VERIFY_LOG.md](docs/VERIFY_LOG.md).

## Be honest about what has run

- Only `OutboardCore` is compiled and tested locally (Linux, in Docker). `OutboardMac`, `App/` and the workflows have never been compiled
  or run until a CI run on macOS says so. **Never claim Mac or App code builds or works unless a CI run shows it.** Say "written, not
  compiled". Nothing has run on a real Mac: never claim runtime behaviour (renames and links across volumes, `diskutil` keys, TCC, login
  items, what Photos/Ollama/Xcode do with a parked note, unplug behaviour, anything about performance) until a tester has tried it.
  The README and the site say "Not yet tried on a real Mac." until `docs/VERIFY_LOG.md` closes the recipe's items.
- Don't invent APIs, flags or behaviour. Check Apple's docs and headers; mark anything you couldn't verify with `VERIFY`. If you're unsure an
  API exists on macOS 13, don't use it, or put it in `App/DesignSystem/Compat.swift` behind `if #available`.
- macOS 13 means `ObservableObject`, `@Published` and `@StateObject`; never `@Observable` or `@Bindable`.
- CI must build **Debug as well as Release** (the Release build skips `#if DEBUG`, where the demo code and the `Faults` hooks live).

## Test

```sh
bash tools/test_core_docker.sh             # Core build + tests in Docker (Windows Git Bash too); must pass with no warnings
SAFETY_FAST=1 bash tools/safety_greps.sh   # the safety rules as greps + their self-tests, without the slow mutation runs (about 35 s on Windows)
bash tools/safety_greps.sh                 # the same with every mutation run (about 13 minutes on Windows, about a minute on Linux); CI runs this
bash tools/repo_checks.sh                  # home paths, empty Buttons, Edit menu, commit identity and credit lines (infra)
swift test                                 # on a Mac: Core and Mac tests
OUTBOARD_DISK_TESTS=1 swift test           # on a Mac: plus the real-volume, unplug and crash-recovery tests (APFS disk images); they skip themselves without the variable
bash tools/check_test_log.sh --self-test  # the checker CI runs on the swift test log (skipped or missing invariant tests fail the job)
python tools/check_recipes.py              # the recipe validator on the exported catalogue (python tools/check_recipes.py --self-test tests the validator)
python tools/changelog.py --self-test      # changelog parser and markdown renderer
python tools/build_site.py --check         # website build and checks (CSP, links, contrast, banned phrases, the not-tried line)
bash tools/doctor.sh                       # what's configured and what's left before go-live (--ci: only consistency errors)
python tools/make_icon.py                  # regenerates App/Assets.xcassets/AppIcon.appiconset (about a minute); make_og.py the site images (about 2 minutes)
```

Windows tip: Git Bash heredocs and `sed` mangle backslashes, and `python` text-mode writes CRLF. Write regexes and Swift with an editor tool,
and keep files LF (`.gitattributes` enforces it on commit).

## Safety rules (BUILD_PLAN §3; `tools/safety_greps.sh` enforces the mechanical ones)

This app renames, copies and links other apps' data and points the apps at the copy. A wrong deletion is the failure that kills the product.
In short:

- **Nothing is deleted.** No `removeItem`, `unlink`, `rmdir`, `rm`, `replaceItem`, `renamex_np`, `copyfile`, `clonefile`, `ditto`, `rsync`, `truncate`
  anywhere in `Sources/` or `App/`. The original is renamed `<name>.before-move`; only after the user confirms does `FileManager.trashItem` move it to the Trash.
- **One site per verb:** `moveItem(` only in `Renamer.swift` (it takes a closed `RenameOp`), `copyItem(` only in `Copier.swift`, `createSymbolicLink(` only in
  `Linker.swift`, `trashItem(` only in `Trasher.swift`, the one `defaults write` in `DefaultsRedirect.swift` through `ProcessRunner`. Each verb's file writes its
  own journal `intent` (appended and `fsync`ed) **before** acting and refuses to act if that fails, then a `result` line. The pinned line orders are in §3.4.
- `Process` only in `ProcessRunner.swift`, a closed command set: `/usr/sbin/diskutil` (`info -plist`, `list -plist`, `apfs list -plist`), `/usr/bin/tmutil destinationinfo -X`,
  `/usr/bin/defaults read|write` for catalogue keys only (`Catalogue.allowsDefaults`). No shell, no `launchctl`, no `ditto`, no signals, no `sudo`, no helper. `hdiutil` only
  in `Tests/.../DiskImageLab.swift` and CI.
- The copy is **verified**: size and SHA-256 of every file, the destination read with the page cache bypassed; any mismatch aborts and nothing on the Mac changed. Free space
  at least 1.1x the source and 10 GB / 5% left over. Never operate while the target app is running (fresh check, no suspension point between the check and the act); the app never
  quits or signals anything. Never touch iCloud paths. A drive is identified by volume UUID + sentinel + root stamp, never by name or path.
- **Fail closed:** unknown signals refuse (irreplaceable recipes) or need a tick; `Tri.unknown` never becomes "yes"; an unwritable journal means nothing moves.
- Never read file contents except to hash them and for our own journal, manifests, marker and sentinel. No network, no telemetry, no Sparkle, no `print`/`NSLog`/`os_log`.
- Never move: sandbox containers, Mail/Safari/Messages/Notes, the Homebrew prefix, the home folder, `~/Library/Caches` as a whole, anything in iCloud, `.app` bundles.
- Honest wording: `tools/banned_phrases.txt` ("safe", "guarantee", "intact", "faster", "automatically moves", "tested on" ...). Copy says what happened and what was checked, never
  what it means. No speed claim. "Not yet tried on a real Mac." stays until a VERIFY log entry exists.
- No `Button` with an empty action (a dialog's `role: .cancel` is the exception).

## Repo rules

- **Naming and attribution (owner decision).** Never write Claude, Anthropic or any AI-tool credit in commit messages, author fields, trailers, PR text or "built with" lines.
  Docs, recipes and fixtures may name the apps Outboard knows (Xcode, Ollama, Hugging Face, Photos, Steam ...) with the README line "Outboard is not affiliated with or endorsed by
  any app it lists." Git identity: `EverydayOpen <36332199+EverydayOpen@users.noreply.github.com>`. No `Co-Authored-By` trailers, ever.
- No personal home paths in committed files (Windows user folders, or `/Users/` followed by a real name). CI fails on them. Use `~`, `<scratchpad>`, a repo-relative path, or the
  example user `jane`. `/Users/Shared` is allowed.
- Every release needs a `## X.Y.Z — YYYY-MM-DD` section in `CHANGELOG.md`, written for users. Upcoming notes go under `## Unreleased` (never published).
- One base URL, `https://everydayopen.github.io/outboard`: `site/site.json` `baseURL` == `App/Links.swift` `Links.website` == `Names.website`. `tools/doctor.sh --ci` fails when they disagree.
- GitHub push protection blocks key-shaped literals even in tests: build fake secrets/tokens from pieces at runtime.
- Python tools use the standard library only. Never commit key material (`.p12`, `.p8`) or real secrets.
- Recipes are data (`Sources/OutboardCore/Recipes/`): a community PR changes data, never code; the validator, CODEOWNERS and a `docs/VERIFY_LOG.md` entry per `verifiedOnRealMac: true` gate it.
- Code style is ponytail (BUILD_PLAN §1): the shortest correct code, no protocols with one implementation, no view model per screen, comments only where the why isn't obvious.
  Don't name functions `open`, `read`, `write`, `remove`, `rename`, `link`, `symlink`, `stat`, `truncate` or `kill` (the greps flag those tokens).

## Ownership

When several agents work in parallel, each edits only its own files (BUILD_PLAN §10). `Model/*`, `Package.swift` and `docs/BUILD_PLAN.md` are the architect's and frozen:
add extensions in your own files, and propose any other change in your report. Infra owns `.github/**`, `tools/**` (including `safety_greps.sh` and `banned_phrases.txt`; a change to a
regex or a pinned line goes in the same commit as the code that needs it), `project.yml`, `App/Info.plist`, the entitlements, the asset catalogue, this file, the README, the
changelog and the docs on releasing and going live.

## CI and the workflows

- Every workflow pins its actions by SHA (a `# vX.Y.Z` comment beside it) and XcodeGen by version and checksum; `dependabot.yml` bumps the actions weekly, the XcodeGen pin is bumped by hand
  in `ci.yml`, `beta.yml`, `release.yml`, `screens.yml`, `fixtures.yml` and `codeql.yml` together.
- `ci.yml`: Core on Linux (digest-pinned `swift:6.2`, warnings fail), `macos` (`swift test`, then the app built Release universal **and** Debug), `volumes` (the disk-image mechanics on
  arm64 and Intel, never blocking), `xcode-27` (non-blocking), `checks` (safety greps, repo checks, recipe validator, changelog, site, doctor).
- `fixtures.yml` is the probe workflow (BUILD_PLAN §6.4): run it by hand after a change to an assumption about macOS; its artifacts are the evidence for BUILD_PLAN §12.
- `hdiutil` exists only in `Tests/.../DiskImageLab.swift`, in `tools/disk_image.sh` and `tools/probes/`, and in the workflows. Every workflow that attaches an image ends with
  `bash tools/disk_image.sh cleanup` under `if: always()`; `tools/safety_greps.sh` checks that.
- `beta.yml` publishes unsigned pre-releases (`vX.Y.Z-beta.N`); `release.yml` publishes signed, notarized DMGs (`vX.Y.Z`) from a protected environment; `site.yml` deploys the site.
  `screens.yml` (demo captures) belongs to the demo-app owner.
