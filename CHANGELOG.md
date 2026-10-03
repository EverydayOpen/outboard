# Changelog

Newest first. `tools/changelog.py` turns each section into the GitHub release notes and the website changelog, so
write for users. Headings must be `## X.Y.Z — YYYY-MM-DD` (em dash); the release workflow refuses a tag without one.
Write upcoming notes under `## Unreleased`, which is never published (the website deploys on every push to main). On
release day, rename it to `## X.Y.Z — <that day>`, commit, push only the tag, and push main once the release is
published (docs/RELEASING.md "Cutting a release"). Links must be full `https://` URLs: the GitHub release can't
resolve site-relative ones. Say what the app does, never what it means: findings, not promises (the phrases to avoid are in tools/banned_phrases.txt).
A release's notes say what testers have tried on real Macs ("tried by N testers on macOS X"), nothing more.

## Unreleased

First release. Outboard measures the big folders that apps keep on your Mac, moves the ones with a known method to an external drive you
choose, and guides you through the rest. **Not yet tried on a real Mac.**

- **Measure first**: a Storage Plan card says how much the folders Outboard knows could free up, measured read-only on your Mac, before
  any drive is chosen. Folders it cannot measure without Full Disk Access are named, not guessed.
- **Moves with a check**: a move copies the folder to your drive, compares every file with the original by size and SHA-256, and stops
  with your Mac unchanged if one file differs. Then it renames your original to `<name>.before-move`, points the app's setting (or a
  link) at the copy, and keeps the original until you confirm. Until then you can roll back.
- **Every step is logged**: the line is written before the step happens. If Outboard cannot write its log, nothing moves.
- **Hidden until tried**: every move that changes anything stays hidden until you turn on "Show moves not yet tried on a real Mac" in
  Preferences. Seven moves are included (Xcode build data and archives, Hugging Face, Ollama, llama.cpp and npm caches, iPhone backups).
- **Guided cards**: for Photos, Music, Final Cut Pro, Logic Pro, Steam, LM Studio, the Android SDK and the App Store's large-apps
  switch, Outboard shows the steps and opens the app. It moves nothing there.
- **Says no, with the reason**: Mail, Safari, Messages and Notes data, iCloud Drive, sandboxed containers, Homebrew, your home folder, the
  whole Caches folder, app bundles, simulator runtimes and Docker's disk image are shown as cards, not offered. A drive that is a network
  volume, FAT or exFAT, a Time Machine destination or a disk image is refused.
- **Drive Guard**: while Outboard is running it notices a missing drive, puts a note where the folder was (or puts the app's setting
  back), and when the drive returns it puts things back and checks them. It can't stop you unplugging a drive. How each app reacts to
  the note has not been tried on a real Mac.
- Makes no network connections and installs no helper. Needs no administrator password. macOS asks once before an app uses a removable
  volume. Moving iPhone backups also needs you to turn on Full Disk Access for Outboard; nothing else does. Requires macOS 13 or later, on Apple silicon or Intel. Free and open source under the MIT License.
  Outboard is not affiliated with or endorsed by any app it lists. <!-- no-claim-ok: the sentence says we make no such claim -->
