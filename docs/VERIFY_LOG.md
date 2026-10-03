# Verify log

A catalogue entry says **Not yet tried on a real Mac.** until it has an entry here. The rule is mechanical: `tools/check_recipes.py`
fails a recipe with `verifiedOnRealMac: true` that has no entry below with a `Tester` and a `Closed` line, whose version matches the
recipe's, or that is verified while an earlier rollout stage (B1 before B2 before B3 before B4, BUILD_PLAN section 2) is not, or while one
of its `defaults` keys still has `valueVerified: false`. The README and the website carry the sentence until every automated entry has an entry
here, and only the owner changes `verifiedOnRealMac`.

This file is for results from real Macs. Results from CI runners (the `fixtures` workflow) are evidence too, but they come from virtual
machines with no external hardware, no Time Machine, no iCloud and no FileVault, so they close only the items BUILD_PLAN section 6.4 says
they can; say which run you mean ("fixtures run <number>, macos-26") and attach nothing from a run you did not read.

## How to add an entry

A tester opens the "Tried a move on a real Mac" issue form. The owner copies the result here, with the tester's handle if they agreed
and "anonymous" if not. One entry per entry-and-version, newest at the top of "Entries". Say what happened including when nothing went
wrong, and which VERIFY items (BUILD_PLAN section 12, items 1 to 22) it closes, by number. Never paste file contents.

```
### <recipe-id>@<version> — YYYY-MM-DD
- Tester: @handle (or anonymous)
- Mac: Apple silicon or Intel, macOS version
- Drive: model or kind, how it is connected, format, encrypted or not
- Closed: 5, 6 (the VERIFY item numbers this closes; write "none" for a partial report)
- Result: what happened, in the tester's words and the activity log's lines
- Open: what is still not known
```

## Entries

No entries yet. Nothing in the catalogue has been tried on a real Mac.

## Results from CI runners

None yet. The first run of the `fixtures` workflow answers E1 (the Xcode keys), E2 to E4 (what Ollama, Hugging Face, npm, pip and cargo
do with a missing drive), E5 (the `diskutil` and `tmutil` output the parsers read), E6 and T6 (what `copyItem` keeps), T1 (volume UUID
equality) and T5 (errors after a forced detach). Write the date, the run and the answer here, then update BUILD_PLAN section 12.

## Open items that only a real Mac can close

The list is BUILD_PLAN section 12. The ones that gate a first public beta are APP6's kill tests (K2): what Photos does with a missing
library, whether a read-only note makes Xcode, Ollama (the app and the command line) and Finder fail visibly instead of recreating
their folder, and whether an external volume mounts before or after a login item starts.
