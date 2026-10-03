"""Validate the recipe catalogue (docs/BUILD_PLAN.md section 4.2, invariant I13: recipes are data).

The catalogue is Swift data in Sources/OutboardCore/Recipes; a Core test exports it to Tests/OutboardCoreTests/Fixtures/export/recipes.json
(Catalogue.exportJSON(), sorted keys), and this script reads that file, so the app, the validator and the site cannot disagree. The same rules
exist in Core as RecipeValidator.problems(in:); a change to one is a change to the other.

    python tools/check_recipes.py                  validate the exported catalogue (exit 1 on any problem)
    python tools/check_recipes.py --file PATH      validate another export
    python tools/check_recipes.py --self-test      the validator against good and adversarial recipes

Rules: ids are unique lowercase words and hyphens, and the frozen ids of BUILD_PLAN section 2 keep their kind; a source starts with `~/`,
has no `..`, is not a never-list root (or under one), and an automated recipe has one; the method is one of defaults, symlink, guided,
never; a defaults key is on the allowlist and its domain is Xcode's; `restore` is writePrior or writeNeutral (there is no delete);
onDriveMissing matches the method; an automated recipe has a consent text with at least one required checkbox, and an irreplaceable one
names Time Machine and says the original stays; every user-visible string passes tools/banned_phrases.txt and none carries the "Not yet tried
on a real Mac." line (the sheet adds it from the flag); at least one https source URL; verifiedOnRealMac: true only with a matching entry in
docs/VERIFY_LOG.md, never while a key's value is unverified, and never before every automated recipe of an earlier rollout stage is
verified; Sources/OutboardCore/Recipes has a CODEOWNERS entry. Stdlib only.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXPORT = ROOT / "Tests/OutboardCoreTests/Fixtures/export/recipes.json"
VERIFY_LOG = ROOT / "docs/VERIFY_LOG.md"
CODEOWNERS = ROOT / ".github/CODEOWNERS"
RECIPES_DIR = ROOT / "Sources/OutboardCore/Recipes"
BANNED = ROOT / "tools/banned_phrases.txt"

ID_RE = re.compile(r"^[a-z][a-z0-9]*(-[a-z0-9]+)*$")
# The `defaults` allowlist (BUILD_PLAN section 4.2): the (domain, key) pairs an automated recipe may write. A new key is a change to this
# table in the same pull request as the recipe, reviewed by the owner (CODEOWNERS). The mode key for Archives is added when a real Mac knows it.
ALLOWED_DEFAULTS = {("com.apple.dt.Xcode", k) for k in ("IDECustomDerivedDataLocation", "IDEDerivedDataPathMode", "IDECustomDistributionArchivesLocation")}
RESTORES = {"writePrior", "writeNeutral"}
METHODS = {"defaults", "symlink", "guided", "never"}
ON_MISSING = {"parkPlaceholder", "revertSetting", "leaveAlone", "none"}
RISKS = {"regenerable", "expensive", "irreplaceable"}
CONFIDENCE = {"high", "medium", "low"}
# Never-list roots (exact or below), compared case-insensitively because APFS is by default. `~/Library/Caches` is forbidden as a whole only.
NEVER_ROOTS = ["~/Library/Containers", "~/Library/Group Containers", "~/Library/Mail", "~/Library/Safari", "~/Library/Messages",
               "~/Library/Mobile Documents", "~/Library/CloudStorage", "~/Desktop", "~/Documents", "/opt/homebrew", "/usr/local"]
NEVER_EXACT = ["~", "~/", "~/Library", "~/Library/Caches"]
# The frozen ids (BUILD_PLAN section 2): journaled, so they never change. More ids may be added; these keep their kind.
FROZEN = {
    **{i: "automated" for i in ("xcode-deriveddata", "huggingface-hub-cache", "ollama-models", "llamacpp-cache", "npm-cache", "ios-device-backups", "xcode-archives")},
    **{i: "guided" for i in ("mas-large-apps", "photos-library", "music-media-folder", "final-cut-library", "logic-sound-library", "steam-library", "lmstudio-models", "android-sdk")},
    **{i: "never" for i in ("never-containers", "never-apple-data", "never-homebrew", "never-caches-home", "never-icloud", "never-app-bundles",
                            "never-simulator-runtimes", "never-docker-orbstack", "never-pnpm-uv")},
}
NOT_TRIED = "tried on a real mac"
# ConsentSheetText.whileRunningPhrase: the guard's note and setting change happen only while Outboard is running, and the consent text says so.
WHILE_RUNNING = "While Outboard is running"


def banned_regex():
    if not BANNED.exists():
        return None
    pats = [l.strip() for l in BANNED.read_text(encoding="utf-8").splitlines() if l.strip() and not l.lstrip().startswith("#")]
    return re.compile("|".join(pats), re.I) if pats else None


def method_kind(r):
    """The method of a recipe. The Core export is flat ("kind": "defaults", a "defaults" object, "steps", "neverReason"); a nested
    {"method": {"defaults": {...}}} (Swift's default enum encoding) and a bare string are read too."""
    if r.get("kind") in METHODS:
        return r["kind"]
    m = r.get("method")
    if isinstance(m, str):
        return m
    if isinstance(m, dict):
        if isinstance(m.get("kind"), str):
            return m["kind"]
        ks = [k for k in m if k in METHODS]
        return ks[0] if len(ks) == 1 else None
    return r.get("kind") if isinstance(r.get("kind"), str) else None


def method_body(r, kind):
    if r.get("kind") in METHODS:   # the flat export
        if kind == "defaults":
            return r.get("defaults") or {}
        return {"steps": r.get("steps")} if kind == "guided" else {"reason": r.get("neverReason")} if kind == "never" else {}
    m = r.get("method")
    if isinstance(m, dict):
        body = m.get(kind, m)
        return body if isinstance(body, dict) else {}
    return {}


def beta_rank(r):
    b = r.get("beta")
    if isinstance(b, int):
        return b
    if isinstance(b, str) and re.fullmatch(r"[bB]\d", b):
        return int(b[1:])
    return None


def texts(r, kind):
    """The strings a person reads: name, consent, steps, reason, missing-drive effect, env line."""
    out = [r.get("name"), r.get("missingDriveEffect"), r.get("envLine")]
    c = r.get("consent") or {}
    out += [c.get("what"), c.get("whatChanges"), *(c.get("whatToKnow") or []), *(cb.get("text") for cb in (c.get("checkboxes") or []) if isinstance(cb, dict))]
    body = method_body(r, kind)
    out += list(body.get("steps") or []) + [body.get("reason")]
    return [t for t in out if isinstance(t, str)]


def path_problems(label, p, rid, kind):
    if not isinstance(p, str) or not p:
        return [f"{rid}: {label} must be a non-empty string"]
    out = []
    if not (p.startswith("~/") or p == "~"):
        out.append(f"{rid}: {label} {p!r} must start with ~/")
    if any(part == ".." for part in p.split("/")) or "\\" in p or re.search(r"[\x00-\x1f]", p) or "//" in p:
        out.append(f"{rid}: {label} {p!r} has .., a backslash, a control character or an empty component")
    low = p.rstrip("/").lower() or p.lower()
    if p.endswith(".app") or ".app/" in p:
        out.append(f"{rid}: {label} {p!r} is inside an app bundle (bundles are never moved)")
    if kind != "never":
        if low in [e.lower() for e in NEVER_EXACT] or p in NEVER_EXACT:
            out.append(f"{rid}: {label} {p!r} is a never-list location")
        for root in NEVER_ROOTS:
            if low == root.lower() or low.startswith(root.lower() + "/"):
                out.append(f"{rid}: {label} {p!r} is under the never-list root {root}")
    return out


def problems(recipes, verify_log="", codeowners=None, banned=None):
    out, seen = [], set()
    kinds = {}
    for r in recipes:
        rid = r.get("id") if isinstance(r, dict) else None
        if not isinstance(rid, str) or not ID_RE.match(rid):
            out.append(f"{rid!r}: id must be lowercase words and hyphens")
            continue
        if rid in seen:
            out.append(f"{rid}: duplicate id")
        seen.add(rid)
        kind = method_kind(r)
        if kind not in METHODS:
            out.append(f"{rid}: method must be one of {sorted(METHODS)}, got {r.get('method')!r}")
            continue
        auto = kind in ("defaults", "symlink")
        kinds[rid] = "automated" if auto else kind
        for k in ("name", "riskClass", "onDriveMissing", "confidence") + (("missingDriveEffect",) if kind != "never" else ()):
            if not r.get(k):
                out.append(f"{rid}: missing {k}")
        if r.get("riskClass") and r["riskClass"] not in RISKS:
            out.append(f"{rid}: riskClass {r['riskClass']!r} is not one of {sorted(RISKS)}")
        if r.get("confidence") and r["confidence"] not in CONFIDENCE:
            out.append(f"{rid}: confidence {r['confidence']!r} is not one of {sorted(CONFIDENCE)}")
        odm = r.get("onDriveMissing")
        if odm and odm not in ON_MISSING:
            out.append(f"{rid}: onDriveMissing {odm!r} is not one of {sorted(ON_MISSING)}")
        elif odm:
            want = {"defaults": {"revertSetting", "leaveAlone"}, "symlink": {"parkPlaceholder"}}.get(kind, {"none"})
            if odm not in want:
                out.append(f"{rid}: a {kind} recipe must have onDriveMissing in {sorted(want)}, got {odm}")
        # sources of the data
        src = r.get("source")
        if auto and not src:
            out.append(f"{rid}: an automated recipe needs a source")
        if src is not None:
            out += path_problems("source", src, rid, kind)
        for c in r.get("companionSources") or []:
            out += path_problems("companion source", c, rid, kind)
        # the method
        body = method_body(r, kind)
        if kind == "defaults":
            if not body.get("domain"):
                out.append(f"{rid}: a defaults recipe needs a domain")
            keys = body.get("keys") or []
            if not keys:
                out.append(f"{rid}: a defaults recipe needs at least one key")
            for k in keys:
                name = k.get("name") if isinstance(k, dict) else None
                if (body.get("domain"), name) not in ALLOWED_DEFAULTS:
                    out.append(f"{rid}: defaults key {body.get('domain')} {name!r} is not on the allowlist (tools/check_recipes.py ALLOWED_DEFAULTS)")
            if body.get("restore") not in RESTORES:
                out.append(f"{rid}: restore must be one of {sorted(RESTORES)} (there is no delete), got {body.get('restore')!r}")
        elif kind == "guided":
            steps = body.get("steps") or []
            if not steps or not all(isinstance(s, str) and s.strip() for s in steps):
                out.append(f"{rid}: a guided card needs numbered steps (non-empty strings)")
        elif kind == "never":
            if not (isinstance(body.get("reason"), str) and body["reason"].strip()):
                out.append(f"{rid}: a never card needs a reason")
        # the consent text
        c = r.get("consent")
        if auto:
            if not isinstance(c, dict):
                out.append(f"{rid}: an automated recipe needs a consent text")
            else:
                for k in ("what", "whatChanges"):
                    if not c.get(k):
                        out.append(f"{rid}: consent.{k} is empty")
                if not c.get("whatToKnow"):
                    out.append(f"{rid}: consent.whatToKnow is empty")
                boxes = c.get("checkboxes") or []
                if not boxes:
                    out.append(f"{rid}: consent needs at least one required checkbox")
                ids = [b.get("id") for b in boxes if isinstance(b, dict)]
                if len(ids) != len(set(ids)) or not all(isinstance(i, str) and i for i in ids):
                    out.append(f"{rid}: consent checkbox ids must be unique non-empty strings")
                if r.get("onDriveMissing") in ("parkPlaceholder", "revertSetting") and not any(
                        WHILE_RUNNING in b for b in (c.get("whatToKnow") or []) if isinstance(b, str)):
                    out.append(f"{rid}: a consent bullet must say '{WHILE_RUNNING}, it ...': the note or the setting change happens only while Outboard runs")
                if r.get("riskClass") == "irreplaceable":
                    whole = " ".join(texts(r, kind)).lower()
                    if "time machine" not in whole:
                        out.append(f"{rid}: an irreplaceable recipe's consent must name Time Machine")
                    if not any("original" in b.lower() for b in (c.get("whatToKnow") or []) if isinstance(b, str)):
                        out.append(f"{rid}: an irreplaceable recipe's consent must say the original stays")
        elif c:
            out.append(f"{rid}: only automated recipes carry a consent text")
        env = r.get("envLine")
        if isinstance(env, str) and ("{drive}" not in env or '"' in env or "'" in env):
            out.append(f"{rid}: envLine must use {{drive}} and must not quote it (Outboard quotes the path)")
        # words
        for t in texts(r, kind):
            if NOT_TRIED in t.lower():
                out.append(f"{rid}: 'Not yet tried on a real Mac.' must not be baked into the recipe text (the sheet adds it from the flag): {t[:60]!r}")
            if banned and (m := banned.search(t)):
                out.append(f"{rid}: banned phrase {m[0]!r} in {t[:60]!r}")
        # sources and verification
        srcs = r.get("sources") or []
        if not srcs or not all(isinstance(s, str) and s.startswith("https://") for s in srcs):
            out.append(f"{rid}: needs at least one source URL, all https://")
    # frozen ids keep their kind
    for fid, fk in FROZEN.items():
        if fid not in kinds:
            out.append(f"{fid}: frozen id missing from the catalogue (BUILD_PLAN section 2)")
        elif kinds[fid] != fk:
            out.append(f"{fid}: frozen id must be {fk}, is {kinds[fid]}")
    # verification
    by_stage = {}
    for r in recipes:
        if isinstance(r, dict) and method_kind(r) in ("defaults", "symlink") and beta_rank(r) is not None:
            by_stage.setdefault(beta_rank(r), []).append(r)
    for r in recipes:
        if not isinstance(r, dict) or r.get("verifiedOnRealMac") is not True:
            continue
        rid, ver = r.get("id"), r.get("version", 1)
        if not re.search(rf"^### {re.escape(str(rid))}@{ver}\b.*\n(?:(?!^### |^## ).*\n)*?^- Tester: .+\n(?:(?!^### |^## ).*\n)*?^- Closed: .+", verify_log + "\n", re.M):
            out.append(f"{rid}: verifiedOnRealMac is true but docs/VERIFY_LOG.md has no '### {rid}@{ver}' entry with Tester and Closed lines")
        body = method_body(r, "defaults")
        if method_kind(r) == "defaults" and any(isinstance(k, dict) and k.get("valueVerified") is False for k in body.get("keys") or []):
            out.append(f"{rid}: verifiedOnRealMac is true while a key's value is still unverified")
        rank = beta_rank(r)
        if rank is not None and method_kind(r) in ("defaults", "symlink"):
            for lower, rs in by_stage.items():
                if lower < rank and any(x.get("verifiedOnRealMac") is not True for x in rs):
                    out.append(f"{rid}: verified before the earlier rollout stage B{lower} is fully verified (BUILD_PLAN section 2)")
                    break
    if codeowners is not None and not re.search(r"^/Sources/OutboardCore/Recipes/?\s+@\S+", codeowners, re.M):
        out.append(".github/CODEOWNERS has no entry for /Sources/OutboardCore/Recipes/")
    return out


def load(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(data, dict):
        data = data.get("recipes", data.get("catalogue", data.get("all")))
    if not isinstance(data, list):
        raise ValueError(f"{path}: expected a list of recipes (or an object with a 'recipes' list)")
    return data


def good(**over):
    r = {"id": "xcode-deriveddata", "version": 1, "name": "Xcode build data", "source": "~/Library/Developer/Xcode/DerivedData",
         "method": {"defaults": {"domain": "com.apple.dt.Xcode", "restore": "writePrior",
                                 "keys": [{"name": "IDECustomDerivedDataLocation", "type": "string", "value": {"destinationPath": {}}, "valueVerified": True},
                                          {"name": "IDEDerivedDataPathMode", "type": "int", "value": {"int": {"_0": 1}}, "valueVerified": False}]}},
         "riskClass": "regenerable", "onDriveMissing": "revertSetting", "confidence": "medium", "beta": 1, "verifiedOnRealMac": False,
         "consent": {"what": "Xcode's build data", "whatChanges": "Copies the folder to your drive and points Xcode at the copy.",
                     "whatToKnow": ["While Outboard is running, it puts the setting back if the drive is unplugged.", "Your original stays on this Mac until you confirm.", "Xcode rebuilds what it needs."],
                     "checkboxes": [{"id": "quit-xcode", "text": "I have quit Xcode."}]},
         "missingDriveEffect": "Xcode builds into its default folder until the drive is back.", "sources": ["https://example.com/doc"]}
    r.update(over)
    return r


def self_test():
    ban = re.compile(r"\bsafe(ly|st)?\b|\bguarantee|\bintact\b", re.I)
    base = [good()]
    # The flat export format of the Core tests reads the same as the nested one.
    def flat(r):
        m = r.get("method")
        out = {k: v for k, v in r.items() if k != "method"}
        k = check_recipes_kind(r)
        out.update({"kind": k, "defaults": m["defaults"] if isinstance(m, dict) and "defaults" in m else None, "steps": (m.get("guided") or {}).get("steps", []) if isinstance(m, dict) else [],
                    "neverReason": (m.get("never") or {}).get("reason") if isinstance(m, dict) else None})
        return out
    check_recipes_kind = method_kind
    # the frozen-id rule is exercised separately: silence it for the focused cases
    def run(rs, log="", co="/Sources/OutboardCore/Recipes/ @EverydayOpen\n"):
        return [p for p in problems(rs, log, co, ban) if "frozen id missing" not in p]
    assert run(base) == [], run(base)
    assert run([flat(good())]) == [], run([flat(good())])
    assert run([flat(good(source="~/Documents"))]) and run([flat(good(method={"defaults": {"domain": "com.apple.dt.Xcode", "restore": "delete", "keys": [{"name": "IDECustomDerivedDataLocation"}]}}))])
    never = flat(good(id="n", source=None, method={"never": {"reason": "Because."}}, onDriveMissing="none", consent=None, missingDriveEffect=""))
    assert run([never]) == [], run([never])   # a never card has no missing-drive effect
    ok_shape = good(method="defaults")  # a bare string method is read too (then the body is empty)
    assert any("domain" in p for p in run([ok_shape]))
    bad_cases = {
        "documents": good(source="~/Documents"),
        "documents child": good(source="~/Documents/stuff"),
        "traversal": good(source="~/Library/../.ssh"),
        "absolute": good(source="/Library/Developer"),
        "home": good(source="~"),
        "caches whole": good(source="~/Library/Caches"),
        "containers": good(source="~/Library/Containers/com.example.app/Data"),
        "icloud": good(source="~/Library/Mobile Documents/com~apple~CloudDocs"),
        "mail": good(source="~/Library/Mail"),
        "homebrew": good(source="/opt/homebrew"),
        "app bundle": good(source="~/Applications/Foo.app"),
        "case trick": good(source="~/LIBRARY/CONTAINERS/x"),
        "no source": good(source=None),
        "key off allowlist": good(method={"defaults": {"domain": "com.apple.dt.Xcode", "restore": "writePrior", "keys": [{"name": "IDEAnything", "type": "string"}]}}),
        "domain off allowlist": good(method={"defaults": {"domain": "com.apple.finder", "restore": "writePrior", "keys": [{"name": "IDECustomDerivedDataLocation"}]}}),
        "restore delete": good(method={"defaults": {"domain": "com.apple.dt.Xcode", "restore": "delete", "keys": [{"name": "IDECustomDerivedDataLocation"}]}}),
        "unknown method": good(method={"shell": {"script": "rm"}}),
        "no consent": good(consent=None),
        "no checkbox": good(consent={"what": "x", "whatChanges": "y", "whatToKnow": ["z"], "checkboxes": []}),
        "missing onDriveMissing": good(onDriveMissing=""),
        "wrong onDriveMissing": good(onDriveMissing="parkPlaceholder"),
        "unknown riskClass": good(riskClass="whatever"),
        "irreplaceable without Time Machine": good(riskClass="irreplaceable"),
        "unconditional unplug promise": good(consent={"what": "x", "whatChanges": "y", "whatToKnow": ["Your original stays on this Mac until you confirm.", "Outboard puts the setting back if the drive is unplugged."], "checkboxes": [{"id": "a", "text": "ok"}]}),
        "baked-in line": good(missingDriveEffect="Xcode stops. Not yet tried on a real Mac."),
        "banned phrase": good(name="Safe Xcode build data"),
        "http source": good(sources=["http://example.com"]),
        "no source url": good(sources=[]),
        "verified without log": good(verifiedOnRealMac=True),
        "bad id": good(id="Xcode_DerivedData"),
        "guided without steps": good(id="g", source=None, method={"guided": {"steps": []}}, onDriveMissing="none", consent=None),
        "never without reason": good(id="n", source=None, method={"never": {"reason": ""}}, onDriveMissing="none", consent=None),
    }
    for name, r in bad_cases.items():
        assert run([r]), f"accepted: {name}"
    # an irreplaceable recipe that names Time Machine and the original passes
    irr = good(riskClass="irreplaceable", consent={"what": "x", "whatChanges": "y", "whatToKnow": ["While Outboard is running, it puts the setting back if the drive is unplugged.", "Your original stays on this Mac until you confirm.", "Time Machine will not back up the moved copy unless the drive is added."], "checkboxes": [{"id": "a", "text": "ok"}]})
    assert run([irr]) == [], run([irr])
    # duplicates, verification and stage order
    assert any("duplicate" in p for p in run([good(), good()]))
    log = "## Entries\n\n### xcode-deriveddata@1 — 2026-11-02\n- Tester: @someone\n- Closed: V5\n"
    ok_v = good(verifiedOnRealMac=True, method={"defaults": {"domain": "com.apple.dt.Xcode", "restore": "writePrior", "keys": [{"name": "IDECustomDerivedDataLocation", "valueVerified": True}]}})
    assert run([ok_v], log) == [], run([ok_v], log)
    assert any("VERIFY_LOG" in p for p in run([ok_v], "### xcode-deriveddata@1 — 2026-11-02\n- Tester: x\n"))   # no Closed line
    assert any("unverified" in p for p in run([good(verifiedOnRealMac=True)], log))
    later = good(id="ollama-models", source="~/.ollama/models", method="symlink", onDriveMissing="parkPlaceholder", beta=2, verifiedOnRealMac=True)
    assert any("earlier rollout stage" in p for p in run([good(), later], log + "### ollama-models@1 — 2026-11-03\n- Tester: x\n- Closed: V6\n"))
    # CODEOWNERS and frozen ids
    assert any("CODEOWNERS" in p for p in problems(base, "", "/docs/ @x\n", ban))
    assert any("frozen id missing" in p for p in problems(base, "", None, ban))
    assert any("must be automated" in p for p in problems([good(id="xcode-archives", method="never", source=None, onDriveMissing="none", consent=None)], "", None, ban))
    # load() accepts a list or {"recipes": [...]}
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        for body in (json.dumps(base), json.dumps({"recipes": base})):
            p = Path(d, "r.json")
            p.write_text(body, encoding="utf-8")
            assert load(p) == base
    print("check_recipes self-test ok")


def main(argv):
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8")
    if argv == ["--self-test"]:
        self_test()
        return 0
    path = EXPORT
    if argv[:1] == ["--file"] and len(argv) == 2:
        path = Path(argv[1])
    elif argv:
        print(__doc__)
        return 2
    if not path.exists():
        if RECIPES_DIR.exists():
            shown = path.relative_to(ROOT).as_posix() if path.is_relative_to(ROOT) else str(path)
            print(f"error: {shown} is missing, but {RECIPES_DIR.relative_to(ROOT).as_posix()} exists: the Core tests export the catalogue there")
            return 1
        print("check_recipes: no catalogue yet (Sources/OutboardCore/Recipes is not written); nothing to validate")
        return 0
    recipes = load(path)
    log = VERIFY_LOG.read_text(encoding="utf-8") if VERIFY_LOG.exists() else ""
    co = CODEOWNERS.read_text(encoding="utf-8") if CODEOWNERS.exists() else ""
    found = problems(recipes, log, co, banned_regex())
    for p in found:
        print("error:", p)
    verified = sum(1 for r in recipes if r.get("verifiedOnRealMac") is True)
    print(f"checked {len(recipes)} recipes ({verified} verified on a real Mac): {len(found)} problems")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
