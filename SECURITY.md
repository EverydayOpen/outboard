# Security

Please report vulnerabilities privately: this repository's **Security** tab › **Report a vulnerability**. Don't open a public issue.

- **Supported version:** the latest release, the one the website's download page links to.
- **Response:** an acknowledgement within 7 days, and a fix or a plan within 30 days after that.
- **In scope:** the Outboard app, the recipe catalogue, the website, and this repository's GitHub Actions workflows.
- **Especially welcome:** any way to make Outboard delete, overwrite, merge, replace or truncate a file or folder; any way to make
  a recovery or a roll back do so; any way to make it move something on the never-list (Mail, Safari, Messages and Notes data,
  anything in iCloud, sandboxed containers, the Homebrew folder, the home folder, the whole Caches folder, app bundles); a path
  that lets a catalogue entry, a journal line, a drive marker, a sentinel or a manifest read off a drive point outside the folder it
  is meant for (traversal, a symbolic link at the leaf or in a parent, a case or Unicode trick); a drive or folder that is mistaken
  for another (the same name, a `... 1` mount point, a restored or cloned volume); an item that changed between the check and the
  action; a way to make it act while the owning app is running; a way to run a command other than the closed set (`diskutil` info and
  list, `tmutil destinationinfo`, `defaults` for the catalogue's keys); a volume name or path that reaches a command line as anything
  but one argument; any path by which a file name, a path or a drive name could leave the Mac or reach a saved report or card when the
  setting that hides them is on.
- **Not a vulnerability:** an app that behaves badly when its folder is on another drive, a recipe that is too cautious or too eager,
  or a drive the rules refuse that you think they should accept. Use the "A move went wrong" issue form for the first and a normal
  issue for the others, and never paste file contents into either.

Outboard makes no network connections, needs no administrator password and installs no helper, so a report about it "phoning home",
asking for elevated rights or leaving a background process behind would itself be a bug worth reporting. The release workflow signs
nothing with a personal token: it uses the workflow's own token, and the Developer ID secrets live in a protected environment that needs
a reviewer's approval (docs/RELEASING.md).
