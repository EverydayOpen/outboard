# Going live: from zero to the first public release

Outboard is free and open source: there are no payments, licences, accounts or updater to set up. Do the steps in order;
each one unblocks the next. `bash tools/doctor.sh` shows what's configured and what's still open. Signing and
notarization details live in [RELEASING.md](RELEASING.md); this file covers everything around them. Anything marked
**VERIFY** wasn't confirmed against the provider's docs, so check it there when you get to it.

The product decision, kill tests and launch plan are in the Whydunit repo's `docs/next/APP6.md` (sections 4.14, 5 and 6) and the
`docs/next/app6-research-*.md` files; the build contract is [BUILD_PLAN.md](BUILD_PLAN.md). Nothing about runtime behaviour on a
real Mac has been verified yet (AGENTS.md): the first tester beta is where that starts, and it starts with moves that are hidden
unless the tester turns them on.

## 1. Name check (before anything goes public)

On 2026-10-03 the research (APP6 section 2) found 97 GitHub repositories matching "outboard" in the name (no macOS repo, no Swift
repo), no Mac App Store or iOS exact match, no Homebrew cask or formula, and `EverydayOpen/outboard` and
`everydayopen.github.io/outboard` free. **Not searched:** trademark registers, and domains beyond RDAP. Re-run the repository, App Store
and Homebrew searches the day the repo is created, and run a knockout search before any paid promotion. A knockout search is a quick
screen for obvious conflicts, not a legal clearance.

- Search "Outboard" and close variants for software in Nice classes **9** (downloadable software) and **42** (software
  services):
  - USPTO: https://tmsearch.uspto.gov/
  - EUIPO: https://euipo.europa.eu/eSearch/ (**VERIFY** the address)
  - WIPO Global Brand Database: https://branddb.wipo.int/
  - India, IP India public search: https://tmrsearch.ipindia.gov.in/tmrpublicsearch/ (**VERIFY** the address)
  - The Mac App Store and a web search for "Outboard app" and "Outboard Mac".
- If a live mark or a shipping app uses the same or a confusingly similar name for software, switch to the fallback **Stowage**
  (clean on Mac in the research; it collides with a 193-star C# SDK). The name appears in `project.yml`, `Package.swift`, `App/`,
  `Sources/`, `site/site.json`, the workflows' `APP`, the README and the site pages.
- Titles and the first line always read "Outboard for Mac" plus what it does.

## 2. GitHub: repo, Pages and the first CI runs

1. **Public repo, claimed on day 1.** On GitHub's free plan the repo must be public for the `release` environment, its secrets and
   its `v*` rule, for required reviewers, and for CodeQL. A public repo also runs standard GitHub-hosted runners, macOS included,
   for free (**VERIFY** current Actions pricing if you ever go private). Claim `https://everydayopen.github.io/outboard` early,
   and keep the repo public well before launch day (r/macapps removes posts from repos under 30 days old).
2. **Push.** From this folder, with `gh` logged in as EverydayOpen:
   `git init -b main`, confirm `git config user.email` is
   `36332199+EverydayOpen@users.noreply.github.com` (`bash tools/doctor.sh` checks), then
   `git add -A && git status --ignored`. Every file staged becomes public, so check that no key material or secrets are
   among them. Commit messages carry no `Co-Authored-By` trailer and name no AI tool or product (ci.yml's `checks` job
   fails the push otherwise). Then `gh repo create EverydayOpen/outboard --public --source . --push`. Keep `-b main`:
   `site.yml` deploys only from `main`, and `ci.yml` runs on pushes to `main`, on pull requests and weekly.
3. **First CI run is the first compile.** Nothing in `OutboardMac`, `OutboardFixture`, `OutboardCrashHelper` or `App/` has ever been
   compiled. Expect the `macos` job to fail on the first push; fix the compile errors from its log, in small commits, until it is
   green. The job builds the app **twice, Release and Debug**: the Release build skips `#if DEBUG` code, and the demo code and the
   crash-injection hooks live there. Until both are green, every Mac and App file is "written, not compiled" (AGENTS.md). Two things to
   watch on that first run: that SwiftPM builds `OutboardFixture` and `OutboardCrashHelper` (path `Tests/OutboardCrashHelper`) where the
   Mac tests look for them, and that `swift test` can create and attach an APFS disk image on the runner (the `volumes` job shows the
   mechanics on their own).
4. **Pages.** The first push runs `site.yml`, which creates the `gh-pages` branch. Then open Settings › Pages › Build and
   deployment › Source: **Deploy from a branch**, branch `gh-pages`, folder `/ (root)`, and **Save**. The site is
   served at `https://everydayopen.github.io/outboard/`, which is `site/site.json`'s `baseURL`, `Names.website` in Core and
   `Links.website` in `App/Links.swift`; `bash tools/doctor.sh` checks that they agree. Leave **Issues** on: the site and the app's Help
   menu send people there. Create the labels `move-problem` and `tester-report` for the issue forms.
5. **Repository settings** listed in RELEASING.md step 4 (branch ruleset, tag ruleset, immutable releases, private vulnerability
   reporting). **Leave the CodeQL default setup off**: `codeql.yml` is the setup. Its Swift build mode has never run
   (**VERIFY** the first run traces the build; the file's header says what to check).
6. **Screens.** Run Actions › **screens** once the Debug build is green and open the PNG artifacts: every frame must be a real
   window capture (the workflow checks size and non-blank, but look at them). The README hero and the site screenshots are picked
   from those frames and stay labelled "Sample data".
7. **The probe workflow (day 1).** Open Actions › **fixtures** › Run workflow. It runs a set of experiments and the whole test suite on
   the arm64 and Intel runners and uploads `probe-*` artifacts. Read, in this order:
   - `e1-summary.txt`: the effective build directory under each Xcode key and mode, where a build lands and where an archive lands.
     This decides whether the first automated move (B1) stays Xcode build data or becomes the Hugging Face cache (BUILD_PLAN section 6.4).
   - `ghost-state.txt` and `e2-*`, `e3-*`, `e4-*`: does a tool create a "ghost" `/Volumes/<name>` folder on the boot volume when its
     data folder points at a drive that is not there?
   - `e5-*`: `diskutil info`, `list` and `apfs list` of an image volume, its whole disk and its physical store, and `tmutil
     destinationinfo -X` with no Time Machine. They become parser fixtures under `Tests/OutboardCoreTests/Fixtures/commands/`.
   - `t1-uuid.txt`: whether the volume UUID is equal across `URLResourceValues` and `diskutil`.
   - `t5.stdout`: the errors an open file gives after `detach -force`.
   - `t6-summary.txt` and `t6-compare.txt`: what `copyItem` keeps and loses (hard links, extended attributes, ACLs, resource forks,
     compression, modes, sparse blocks) and whether the relative links of a Hugging Face-shaped tree survive.
   - `events.stdout`, `tcc-log.txt`, `trash-on-volume.stdout`, `volumes-writable.*`: which workspace notifications arrive headless,
     whether the first write to an image trips the removable-volumes check, what `trashItem` does on the image, and whether
     `/Volumes` is writable for this user.
   - `swift-test.log`: the whole suite, skips included.
   Then update BUILD_PLAN section 12 and `docs/VERIFY_LOG.md` ("Results from CI runners"). The runners are fresh virtual machines (no
   external hardware, no Time Machine, no FileVault, no iCloud), so they cannot answer the questions BUILD_PLAN section 6.4 lists under
   "What CI cannot show": that is the testers' job (section 3).

## 3. Kill tests and testers (APP6 section 5.3)

The owner runs the gates, not an agent. Outboard is being built before K1 and K2 are answered (owner decision); the rollout order is
the safeguard: the first beta (B0) measures, explains and guides, and every automated move stays hidden until a tester has tried it.

- **K0 Shelf check.** Re-read Storage Studio's pages and a week of r/macmini and r/LocalLLaMA for a new *free* mover with a guard.
  If one exists with releases and over 100 stars, reconsider.
- **K1 Demand probe.** One non-promotional r/macmini question ("Which folders would you move to an SSD, and what went wrong when
  you tried?") posted by the owner. Fewer than about 25 real replies in 7 days: demand is quiet; ship B0 only and stop.
- **K2 The guard can exist.** One tester with a real Mac runs the three items that could end Drive Guard before any mover ships: what
  Photos does with a missing library on macOS 15 and 26; whether a read-only note makes Xcode, Ollama (the app and the command line)
  and Finder fail visibly instead of recreating their folder; and whether external volumes mount before or after a login item starts.
  If the note makes any of the three recreate silently and `revertSetting` cannot cover it, that recipe is dropped; if all three
  recreate, the product is B0 plus guided cards and the movers stay hidden.
- **Rollout (BUILD_PLAN section 2).** B0 measure, explain, guide. B1 `xcode-deriveddata`. B2 the symlink caches. B3 iPhone backups. B4
  Xcode archives. A step ships as a normal entry only after the previous one has an entry in `docs/VERIFY_LOG.md` from a named tester.
  `tools/check_recipes.py` enforces the order.
- **Any report of a loss or an alteration** (a file missing or changed after a move, a safety copy altered, a failed roll back): stop the
  beta, add the case to the tests and the never-list if it belongs there, and publish the fix before anything else. A reproduced loss
  blocks that recipe and every code path it shares; a failed roll back on a real Mac blocks all automated recipes. One confirmed report
  of Outboard changing something the user did not ask for, not fixed within 48 hours: pull the release and say so.

## 4. Optional: a custom domain

Skip this unless you want your own domain; `everydayopen.github.io/outboard` works as is.

1. Verify the domain for the EverydayOpen organization first (organization Settings › Pages › **Add a domain**; GitHub
   shows a TXT record to add). This stops anyone else from taking the domain over on GitHub Pages.
2. Add these records at your DNS host:

   | Type | Name | Value |
   |---|---|---|
   | A | `@` | `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153` (four records) |
   | AAAA | `@` | `2606:50c0:8000::153`, `2606:50c0:8001::153`, `2606:50c0:8002::153`, `2606:50c0:8003::153` |
   | CNAME | `www` | `everydayopen.github.io` |

3. In the repo, open Settings › Pages › Custom domain, enter the domain and save. GitHub commits a `CNAME` file to
   `gh-pages`, which `site.yml` never overwrites. Tick **Enforce HTTPS** when it becomes available.
4. Change `site/site.json` `baseURL`, `Names.website` (and `Names.websiteShort`) in Core and `Links.website` to `https://<domain>`
   (no path) and run `bash tools/doctor.sh`. The app has no update feed, so older copies only lose their Help link's address; GitHub
   redirects the old one.

## 5. Apple Developer Program and signing

Public betas can ship unsigned (`beta.yml`, with the Gatekeeper steps in the release notes and a SHA-256). A first
**public** launch is much better signed and notarized: follow RELEASING.md steps 1 to 4 (enrollment, the Developer ID
Application certificate, the App Store Connect Team API key, and the `release` environment with its seven secrets). With
`gh` logged in, `bash tools/doctor.sh` lists any secret that's still missing. Outboard renames and links other apps' data, so the trust
cost of an unsigned build is real: decide before launch week, not on it. If Gatekeeper or privacy-prompt trouble is more than 30% of the
first 20 issues, signing is the blocker; ship no further unsigned betas. Unsigned casks cannot enter the main Homebrew tap, so until a
Developer ID exists the download is direct only.

## 6. Website and privacy review

1. `site/site.json` names the owner (EverydayOpen), shown in the site footer. Run
   `python tools/build_site.py --check` and push `main`: `site.yml` publishes the site. `/download/` shows the
   no-release-yet status line and the Releases button until `CHANGELOG.md` on `main` has a released section (step 9).
2. **Privacy review.** The site has no separate terms or privacy pages; the privacy text is the README "Privacy" section and the
   home page. Have a lawyer check it against: free, open-source software under the MIT License, provided as is; an app that
   **renames, copies and links folders that other apps wrote** and changes their settings (the confirm dialog's wording, "findings,
   not guarantees"); what the app actually does (no network, no telemetry, no account, one local activity log of home-relative paths,
   sizes and step names, manifests of file names and hashes on the user's own drive and Mac, one preferences blob; it reads file
   contents only to hash them); GitHub as host of the site and the downloads (it sees visitors' IP addresses; **VERIFY** what it logs
   for Pages and release downloads); and the contact route for privacy requests.
3. **Honest-copy review.** Read the site, the README, the app's strings and a screenshot of every screen against the list in
   `tools/banned_phrases.txt` and against APP6 section 5.1 and BUILD_PLAN section 8 ("findings, not guarantees"; never "safe to
   unplug"; no speed claim). The CI check only catches the phrases it knows; look for the meaning, not just the words (BUILD_PLAN
   section 12, last item).
4. The site and README use real tester numbers once they exist, with permission. Until then every number is labelled
   "Sample data", and "Not yet tried on a real Mac." stays until `docs/VERIFY_LOG.md` closes the catalogue's items.

## 7. Go / no-go

Publish only when all of these hold:

- CI is green on the exact commit being tagged, both Release and Debug builds, including the real-volume tests on arm64 (and the
  `fixtures` run on Intel has been read).
- K2 passed (a real Mac, by a named tester) and K1 did not fail; the recovery tests (S1 to S20 and the crash-injection runs) passed in CI.
- The first-run cards, the consent sheet ("Move {what} to {drive}?"), the confirm dialog and the result sheet were read by a person on
  a real Mac, and a roll back and a Return to Mac were each used at least once on a real Mac, on data that rebuilds itself.
- The release notes state what was tried ("tried by N testers on macOS X"), nothing more, and carry "Not yet tried on a real Mac." for
  every entry without a verify-log entry.
- `bash tools/doctor.sh` has no `ERROR` and no `todo` you have not decided to accept; `tools/safety_greps.sh`,
  `tools/repo_checks.sh` and `tools/check_recipes.py` are green.

## 8. Before the first public release

**Rehearse** as RELEASING.md describes under "Before the first public release".

## 9. First release

1. On release day, rename `## Unreleased` in `CHANGELOG.md` to `## 1.0.0 — <that day>` and commit it, then tag and push
   only `v1.0.0`. Push `main` once the release is published (RELEASING.md "Cutting a release"): that push deploys the
   site, and `/download/` stops showing the no-release-yet status line.
2. **Homebrew** (optional, **VERIFY**): an own tap `EverydayOpen/homebrew-tap` with a cask pointing at
   `releases/download/v1.0.0/Outboard-1.0.0.dmg` and its SHA-256. Homebrew's stance on casks in its official tap is
   unverified; an own tap avoids the question.

## 10. Launch and after

APP6 section 5.2 has the order. **Trust first:** the canonical URL everywhere, SHA-256 checksums in each release, `SECURITY.md`, a
"never paste a Terminal command to install this" line, and the banned-phrase CI check visible in the README (the honesty is the
pitch). The repo is public from day 1 so it is over 30 days old by launch. The owner writes the posts, not an agent, and posts
nothing automatically.

- **Launch day L** (after the buffer week): the GitHub release (unsigned beta, with checksums); the site; a post that leads with a
  real tester's Storage Plan card and a measured number ("of 38 GB in System Data, 21 GB is movable; here is what Outboard will not touch
  and why"), not with the tool. Channels in order: r/macmini (the 256 GB buyer), r/LocalLLaMA (model folders), r/iOSProgramming
  (DerivedData, Archives, device backups), then r/macapps; Show HN only with the measurement angle (tool posts score low there). Post
  Tuesday to Thursday, about 8 to 10 am US Eastern, and avoid Black Friday week.
- **Weeks 2 to 4:** collect tester results into `docs/VERIFY_LOG.md` (per macOS version and drive, sample size stated); answer every
  issue within 48 hours; a second post only when there is new measured data.

Post-release checks:

- The stable link downloads the new DMG
  (`https://github.com/EverydayOpen/outboard/releases/latest/download/Outboard.dmg`; `<baseURL>/download/` does not use it
  yet, so check the page's own link too). It opens and the app launches without a Gatekeeper warning. The release workflow
  already launched it on Apple silicon and Intel.
- `/changelog/` and `/feed.xml` show the release.
- In the app, the Help menu opens the website and the issue forms, and everything works with Wi-Fi off.
- Watch Issues (every "move went wrong" becomes a test, and possibly a change to the recipe or the rules) and the Actions runs. The
  weekly **ci** and **fixtures** runs show whether the current macOS image still behaves as the tests assume.
- Kill criteria (APP6 section 5.3): by day 14, under 150 stars and under 500 downloads: stop feature work and keep the site; 150 to
  500: maintenance only; over 500: continue. **Safety-signal exception:** if the bar is missed but at least three testers have posted
  real-Mac results from the verify list, keep the recipes and the guard correct and stop only *new* recipes, because those results are
  the thing no CI can buy. By day 60, under 400 stars and fewer than 5 external issues or pull requests (recipe PRs count): archive
  with a clear README. At any time: a free, open mover with a verified copy and a guard reaches 1,000 stars, or Gatekeeper or privacy-prompt
  trouble is over 30% of the first 20 issues: re-run the comparison, or stop shipping unsigned betas. "Download" is defined before
  launch: release asset counts include bots and are an upper bound.
