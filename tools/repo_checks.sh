#!/usr/bin/env bash
# Repo hygiene checks of docs/BUILD_PLAN.md section 3.2 and 3.3 (the safety greps are tools/safety_greps.sh).
# CI runs this in the `checks` job; run it locally before pushing. GNU grep (Git Bash and Linux). Owner: infra.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
bad() { echo "::error::$1"; fail=1; }
PY=$(command -v python3 || command -v python)
FILES=$(git ls-files -co --exclude-standard)   # tracked plus not-yet-committed, never ignored files
[ -n "$FILES" ] || { bad "git ls-files returned no files: nothing was scanned"; echo "repo checks: FAILED"; exit 1; }

# 1. "Nothing shipped names your machine": no home paths, no zsh prompts but the example jane@Janes-MacBook.
#    /Users/Shared is macOS's; jane and you are the docs' and tests' example users ("njane" is jane after a \n).
hits=$(printf '%s\n' "$FILES" | tr '\n' '\0' | xargs -0 grep -noIE '/Users/[A-Za-z0-9._-]+|[A-Za-z]:[\/]+[Uu]sers[\/]+[A-Za-z0-9._-]|[A-Za-z0-9._-]+@[A-Za-z0-9._-]+ ~ %' \
  | grep -vE ':/Users/(Shared|you|jane[nrt]?)$|:n?jane@Janes-|:name@host ~ %$' || true)
[ -z "$hits" ] || { echo "$hits"; bad "Personal home paths or Terminal prompts above: use ~, <scratchpad>, a repo-relative path or jane"; }

# 2. "No button can do nothing." Every role: .cancel button is exempt (a dialog's Cancel dismisses itself).
"$PY" - <<'PYEOF' || bad "Button with an empty action in App/"
import pathlib, re, sys
bad = [f"{p}:{s.count(chr(10), 0, m.start()) + 1}: {m[0]}" for p in sorted(pathlib.Path("App").rglob("*.swift"))
       for s in [p.read_text(encoding="utf-8")] for m in re.finditer(r"\bButton\b[^{}\n]*\{\s*\}", s)
       if "role: .cancel" not in m[0]]
print("\n".join(bad))
sys.exit(1 if bad else 0)
PYEOF

# 3. Replacing these Edit menu groups kills the standard copy and paste shortcuts.
if grep -rnE 'replacing: *\.(pasteboard|textEditing)\b' App Sources 2>/dev/null; then
  bad "Keep the standard Edit menu: never replace .pasteboard or .textEditing"
fi

# 4. Attribution (BUILD_PLAN 3.3). Tool names may appear descriptively in docs, README, site and hazard data, but never
#    in who wrote a commit, in a commit message, or in a credit line. The git-log checks skip pull requests: an outside
#    contributor's commits have their own identity and may name an app the rules detect. GitHub's web squash-merge
#    records the PR author as author, GitHub as committer and adds Co-authored-by trailers, so the author is not checked
#    when GitHub is the committer; the message is, so the squash message must be cleaned of trailers and tool names.
ok='EverydayOpen <36332199\+EverydayOpen@users\.noreply\.github\.com>|GitHub <noreply@github\.com>|dependabot\[bot\] <[^>]*>'
if [ "${GITHUB_EVENT_NAME:-}" != pull_request ] && git rev-parse --verify -q HEAD > /dev/null; then
  re="^($ok)\$"
  who=$(git log --format=$'%h\t%an <%ae>\t%cn <%ce>' | while IFS=$'\t' read -r h a c; do
    [[ $c =~ $re ]] || echo "$h committer $c"
    [[ $a =~ $re || $c == 'GitHub <noreply@github.com>' ]] || echo "$h author $a"
  done)
  [ -z "$who" ] || { echo "$who"; bad "Commit author or committer must be EverydayOpen <36332199+EverydayOpen@users.noreply.github.com>"; }
  msg=$(git log --format='commit %h%n%B' | grep -inE 'co-authored-by|generated with|\b(claude|anthropic|openai|codex|windsurf|copilot)\b' || true)
  [ -z "$msg" ] || { echo "$msg"; bad "Commit messages must not carry trailers, credit lines or AI tool names"; }
fi
credit=$(printf '%s\n' "$FILES" | grep -vE '^(docs/BUILD_PLAN\.md|AGENTS\.md|tools/repo_checks\.sh)$' | tr '\n' '\0' \
  | xargs -0 grep -nIiE '(built|made|created|written|generated|powered) (with|by) .{0,40}(claude|anthropic|openai|codex|cursor|copilot)' || true)
[ -z "$credit" ] || { echo "$credit"; bad "No built-with / made-with credit lines naming an AI tool"; }

# 5. No key material in the tree (the .gitignore blocks these too; this catches a forced add).
keys=$(printf '%s\n' "$FILES" | grep -iE '\.(p12|p8|pem|key|cer|csr|mobileprovision|b64)$|private.*key' || true)
[ -z "$keys" ] || { echo "$keys"; bad "Key material must never be committed (docs/RELEASING.md)"; }
# Content scan: key-shaped literals in any file (private key blocks, GitHub/AWS/Slack/API tokens). Tests build fake ones
# from pieces at runtime (BUILD_PLAN lesson c), so a hit is real. This script holds the patterns, so it is skipped.
lits=$(printf '%s\n' "$FILES" | grep -v '^tools/repo_checks\.sh$' | tr '\n' '\0' | xargs -0 grep -lIE \
  -e '-----BEGIN [A-Z ]*PRIVATE KEY' -e 'gh[pousr]_[A-Za-z0-9]{36,}' -e 'github_pat_[A-Za-z0-9_]{22,}' \
  -e '(AKIA|ASIA)[0-9A-Z]{16}' -e 'xox[abprs]-[A-Za-z0-9-]{10,}' -e 'sk-[A-Za-z0-9_-]{32,}' 2>/dev/null || true)   # -l: file names only, so a real secret never reaches the CI log
[ -z "$lits" ] || { echo "$lits"; bad "Key-shaped literal in the tree: build fake secrets from pieces at runtime, never commit real ones"; }

[ "$fail" -eq 0 ] && echo "repo checks: ok"
exit $fail
