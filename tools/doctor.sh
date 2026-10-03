#!/usr/bin/env bash
# What's configured and what's next before go-live (docs/GO_LIVE.md). Runs in Git Bash on Windows and on macOS.
#   bash tools/doctor.sh        ok/todo lines; also checks the live site and GitHub secrets when it can. Exits 0.
#   bash tools/doctor.sh --ci   offline; exits 1 only on a consistency error (base URLs or bundle ids that disagree).
# Placeholders (REPLACE_..., OWNER) are todos, not errors: they are expected until go-live.
cd "$(dirname "$0")/.." || exit 1
CI_MODE=; [ "${1:-}" = --ci ] && CI_MODE=1
errors=0 todos=0 BASE=
ok()   { printf 'ok     %s\n' "$*"; }
todo() { printf 'todo   %s\n' "$*"; todos=$((todos + 1)); }
err()  { printf 'ERROR  %s\n' "$*"; errors=$((errors + 1)); }
placeholder() { case "$1" in "" | *REPLACE* | *OWNER*) return 0 ;; *) return 1 ;; esac; }
json() { [ -f site/site.json ] && sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" site/site.json | head -1; }

# 1. One base URL everywhere: site/site.json baseURL == Names.website (Core) == Links.website (the app's Help menu). The first real one
#    found is the reference. The app files are written by other owners in parallel; until App/OutboardApp.swift exists a missing
#    App/Links.swift is a todo, afterwards it is an error in --ci mode.
base() {  # file, what, URL without the trailing slash, [required]
    if [ ! -f "$1" ]; then
        if [ -n "$CI_MODE" ] && [ "${4:-}" = required ]; then err "$1: missing"; else todo "$1: missing"; fi
    elif [ -z "$3" ]; then todo "$1: couldn't read $2; expected https://everydayopen.github.io/outboard or https://<domain>"
    elif placeholder "$3"; then todo "$1: $2 $3 is a placeholder (docs/GO_LIVE.md step 2)"
    elif [ -z "$BASE" ] || [ "$3" = "$BASE" ]; then BASE=$3; ok "$1: $2 $3"
    else err "$1: $2 is $3 but the other files say $BASE (one base URL everywhere)"
    fi
}
NAMES=Sources/OutboardCore/Model/Names.swift
WEB=$(grep -m1 'let website' App/Links.swift 2>/dev/null | grep -o 'https://[^"]*')
NWEB=$(grep -m1 'static let website' "$NAMES" 2>/dev/null | grep -o 'https://[^"]*')
APPREQ=; [ -f App/OutboardApp.swift ] && APPREQ=required
base site/site.json baseURL "$(json baseURL)" required
base "$NAMES" Names.website "${NWEB%/}" required
base App/Links.swift Links.website "${WEB%/}" "$APPREQ"

# 1b. The repository: site.json releasesRepo == Names.repo (what the site's Source and Download links point at).
REPO=$(grep -m1 'static let repo' "$NAMES" 2>/dev/null | grep -o 'https://github.com/[^"]*')
RELREPO=$(json releasesRepo)
if [ -n "$REPO" ] && [ -n "$RELREPO" ]; then
    if [ "${REPO#https://github.com/}" = "$RELREPO" ]; then ok "releasesRepo $RELREPO == Names.repo"
    else err "site/site.json releasesRepo is $RELREPO but Names.repo is $REPO"; fi
fi

# 1c. The bundle id: project.yml == Names.bundleID.
BID=$(grep -m1 'static let bundleID' "$NAMES" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"')
PBID=$(sed -n 's/.*PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*\([^[:space:]]*\).*/\1/p' project.yml 2>/dev/null | head -1)
if [ -n "$BID" ] && [ -n "$PBID" ]; then
    if [ "$BID" = "$PBID" ]; then ok "bundle id $BID (Names.bundleID == project.yml)"
    else err "Names.bundleID is $BID but project.yml has $PBID"; fi
fi

# 1d. The manifest keys BUILD_PLAN section 3 asks for.
if [ -f App/Info.plist ]; then
    grep -q 'LSMultipleInstancesProhibited' App/Info.plist && ok "App/Info.plist: LSMultipleInstancesProhibited" || err "App/Info.plist: LSMultipleInstancesProhibited is missing"
    n=$(grep -c 'UsageDescription</key>' App/Info.plist)
    [ "$n" = 1 ] && grep -q 'NSRemovableVolumesUsageDescription' App/Info.plist && ok "App/Info.plist: exactly one usage string (NSRemovableVolumesUsageDescription)" \
        || err "App/Info.plist must carry exactly one usage string, NSRemovableVolumesUsageDescription (found $n)"
fi
if [ -f App/Outboard.entitlements ]; then
    grep -q '<key>' App/Outboard.entitlements && err "App/Outboard.entitlements must stay empty" || ok "App/Outboard.entitlements: empty"
fi

# 2. Placeholders.
while IFS= read -r hit; do
    case "$hit" in
        *'"owner"'*) next="the name shown in the site footer (docs/GO_LIVE.md step 6)" ;;
        *) next="see docs/GO_LIVE.md" ;;
    esac
    todo "${hit%%:*}: placeholder on line $(echo "$hit" | cut -d: -f2); set $next"
done < <(grep -rnIE 'REPLACE_|OWNER' App Sources site/site.json 2>/dev/null \
         | grep -vE '"baseURL"|let website|^[^:]+:[0-9]+:[[:space:]]*//')   # section 1 covers those

# 3. Go-live: the first release's changelog row (project.yml's version stays 1.0.0; release.yml's preflight checks every tag's row).
VER=$(sed -n 's/.*MARKETING_VERSION:[[:space:]]*"\([^"]*\)".*/\1/p' project.yml)
if grep -q "^## $VER — [0-9]" CHANGELOG.md 2>/dev/null; then ok "CHANGELOG.md: has a $VER section"
else todo "CHANGELOG.md: on release day rename '## Unreleased' to '## $VER — <that day>' (release.yml refuses the tag without it)"; fi

# 3b. "Not yet tried on a real Mac." and the VERIFY log: while the catalogue has unverified entries the README and the site carry the line.
if [ -f docs/VERIFY_LOG.md ]; then ok "docs/VERIFY_LOG.md exists"; else todo "docs/VERIFY_LOG.md is missing"; fi
if grep -qF 'Not yet tried on a real Mac.' README.md 2>/dev/null; then todo "README.md still says 'Not yet tried on a real Mac.' (true until docs/VERIFY_LOG.md closes the catalogue's items)"; fi

# 4. The repo's git identity (BUILD_PLAN section 1): commits by anyone else fail ci.yml's attribution check.
WANT="EverydayOpen <36332199+EverydayOpen@users.noreply.github.com>"
if [ -d .git ]; then
    HAVE="$(git config user.name) <$(git config user.email)>"
    if [ "$HAVE" = "$WANT" ]; then ok "git identity: $HAVE"
    else todo "git identity is '$HAVE'; run: git config user.name EverydayOpen && git config user.email 36332199+EverydayOpen@users.noreply.github.com"; fi
else
    todo "this folder is not a git repository yet: git init -b main (docs/GO_LIVE.md step 2)"
fi

# 5. Live checks: the site on GitHub Pages and the release secrets. Skipped in CI (no network or token needed there).
if [ -z "$CI_MODE" ]; then
    if [ -z "$BASE" ]; then todo "the live site can't be checked until the base URL is set (docs/GO_LIVE.md step 2)"
    elif curl -fsS --max-time 10 -o /dev/null "$BASE/" 2>/dev/null; then ok "$BASE/ is live"
    else todo "$BASE/ doesn't load: push main so site.yml creates gh-pages, then enable Pages (Settings › Pages › Deploy from a branch › gh-pages / root) (docs/GO_LIVE.md step 2)"; fi
    if gh repo view --json name > /dev/null 2>&1; then
        # Admin-only repo settings (docs/RELEASING.md step 4). on PATH JQ: the API's answer is exactly true.
        on() { [ "$(gh api "repos/{owner}/{repo}/$1" --jq "$2" 2>/dev/null)" = true ]; }
        on environments/release/deployment-branch-policies '[.branch_policies[] | .type + " " + .name] == ["tag v*"]' \
            && on environments/release 'any(.protection_rules[]; .type == "required_reviewers")' \
            && ok "GitHub env release: v* tags only, required reviewer" \
            || todo "GitHub env release: needs Selected tag v* and a required reviewer, before any secret goes in (docs/RELEASING.md step 4)"
        on rules/branches/main 'map(.type) | contains(["deletion", "non_fast_forward"])' && ok "GitHub: main can't be force-pushed or deleted" \
            || todo "GitHub: add a branch ruleset on main that blocks force pushes and deletion (docs/RELEASING.md step 4)"
        # Tag rulesets: the list endpoint's items carry target and enforcement (VERIFY the field names on the first live run).
        on rulesets 'any(.[]; .target == "tag" and .enforcement == "active")' && ok "GitHub: a tag ruleset restricts who can create v* tags" \
            || todo "GitHub: add a tag ruleset on v* so a collaborator cannot publish a beta unreviewed (docs/RELEASING.md step 4)"
        on immutable-releases .enabled && ok "GitHub: immutable releases on" \
            || todo "GitHub: turn on immutable releases (docs/RELEASING.md step 4)"
        on private-vulnerability-reporting .enabled && ok "GitHub: private vulnerability reporting on" \
            || todo "GitHub: turn on private vulnerability reporting, SECURITY.md sends reports there (docs/RELEASING.md step 4)"
        # CodeQL runs from .github/workflows/codeql.yml (advanced setup); the default setup would conflict with it.
        [ "$(gh api "repos/{owner}/{repo}/code-scanning/default-setup" --jq .state 2>/dev/null)" != configured ] \
            && ok "GitHub: CodeQL default setup is off (codeql.yml is the setup)" \
            || todo "GitHub: turn the CodeQL default setup off, codeql.yml replaces it (docs/RELEASING.md step 4)"
        # The issue forms apply these labels.
        LABELS=$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null)
        for l in move-problem tester-report; do
            echo "$LABELS" | grep -qx "$l" && ok "GitHub label $l" || todo "GitHub: create the issue label $l (the issue forms apply it) (docs/GO_LIVE.md step 2)"
        done
    fi
    if SECRETS=$(gh secret list --env release 2>/dev/null); then
        for s in DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD KEYCHAIN_PASSWORD DEVELOPMENT_TEAM ASC_KEY_P8_BASE64 \
                 ASC_KEY_ID ASC_ISSUER_ID; do
            echo "$SECRETS" | cut -f1 | grep -qx "$s" && ok "GitHub env release: secret $s" \
                || todo "GitHub env release: add secret $s (docs/RELEASING.md step 4)"
        done
    else
        todo "GitHub secrets not checked (needs gh, gh auth login, a GitHub remote and the release environment); see docs/RELEASING.md step 4"
    fi
fi

echo "$todos todo, $errors error(s)"
[ -n "$CI_MODE" ] && [ "$errors" -gt 0 ] && exit 1
exit 0
