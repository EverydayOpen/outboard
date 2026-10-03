"""Build the product website: site/src + site/static + CHANGELOG.md + the Core catalogue export -> site/_dist.

Stdlib only. Pages are site/src/pages/**/*.html: a first line `<!--meta {json}-->` (title, description, optional
"noindex": true), then the body, which site/src/layout.html wraps.
{{key}} is replaced by site.json values and the computed values in values(); an unknown key fails the build.
Sources link root-relative (href="/download/"); the build prefixes those with baseURL's path, so the site works as a
GitHub Pages project site (https://everydayopen.github.io/outboard) and on a custom domain (https://example.com).
Canonicals, og:image, the sitemap, the feed, robots.txt and llms.txt use the full baseURL.

The catalogue numbers and tables on the site come from Tests/OutboardCoreTests/Fixtures/export/recipes.json (the file the Core tests
export from the Swift data, which tools/check_recipes.py also reads), or, until that file exists, from the Swift data itself, so the
site cannot say something the app does not.

  python tools/build_site.py           writes site/_dist
  python tools/build_site.py --check   builds into temp dirs for baseURL, its bare origin and a /<releases repo>
                                       project path, then checks internal links (inside the path prefix), anchors,
                                       assets, meta tags, headings, alt text, XML, sitemap/feed/llms.txt URLs,
                                       placeholders, text contrast, exactly two root-selector CSS blocks, theme
                                       switches, the CSP (no inline script, style or handler), rel=noopener on
                                       external links, the not-affiliated line on every page, "Not yet tried on a real Mac."
                                       on the home and download pages while any catalogue entry is unverified, no webfont,
                                       size budgets, every <img> sized, tools/banned_phrases.txt over everything built
                                       (a line marked no-claim-ok is exempt) and the word "safe" nowhere; exit 1 on any problem
"""
import datetime
import html
import json
import re
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET
from email.utils import format_datetime
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urljoin, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import changelog  # noqa: E402  tools/changelog.py: parse(path), to_html(md)
import check_recipes  # noqa: E402  tools/check_recipes.py: load(path), method_kind(r), method_body(r, kind)

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
PLACEHOLDER = re.compile("REPLACE_ME|OWNER")
# layout.html's Content-Security-Policy allows only same-origin files, so no page may use inline code.
CSP = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'"
# Bytes, for each built file matching the pattern.
BUDGET = {"styles.css": 40_000, "motion.js": 6_000, "index.html": 36_000, "shots/*": 110_000}
AFFILIATION = "not affiliated with or endorsed by any app it lists"
NOT_TRIED = "Not yet tried on a real Mac."
SAFE = re.compile(r"\bsafe(?:ly|r|st)?\b", re.I)


class Raw(str):
    """Already HTML: inserted without escaping."""


def banned():
    """tools/banned_phrases.txt as one case-insensitive regex (the same list tools/safety_greps.sh check G15 uses)."""
    f = ROOT / "tools" / "banned_phrases.txt"
    pats = [l.strip() for l in f.read_text(encoding="utf-8").splitlines() if l.strip() and not l.lstrip().startswith("#")] if f.exists() else []
    return re.compile("|".join(pats), re.I) if pats else None


def fill(template, values, where, esc=html.escape):
    def sub(m):
        if m.group(1) not in values:
            sys.exit(f"{where}: unknown {{{{{m.group(1)}}}}}")
        v = values[m.group(1)]
        return v if isinstance(v, Raw) else esc(str(v))
    return re.sub(r"\{\{(\w+)\}\}", sub, template)


def pretty(iso):
    d = datetime.date.fromisoformat(str(iso))
    return f"{d.day} {d:%B %Y}"


GLYPH = {"xcode-deriveddata": "k-build", "xcode-archives": "k-archive", "ollama-models": "k-model", "huggingface-hub-cache": "k-model",
         "llamacpp-cache": "k-model", "lmstudio-models": "k-model", "npm-cache": "k-cache", "ios-device-backups": "k-backup",
         "mas-large-apps": "k-archive", "photos-library": "k-photos", "music-media-folder": "k-music", "final-cut-library": "k-film",
         "logic-sound-library": "k-music", "steam-library": "k-game", "android-sdk": "k-sdk"}
# The mono chip on a "never" row (DESIGN §3 block 6): what the reason is about, in a word the catalogue itself uses.
NEVER_CHIP = {"never-containers": "sandbox", "never-apple-data": "TCC", "never-homebrew": "/opt/homebrew", "never-caches-home": "~/Library/Caches",
              "never-icloud": "sync", "never-app-bundles": ".app", "never-simulator-runtimes": "disk images", "never-docker-orbstack": "disk image",
              "never-pnpm-uv": "links"}
ROLLOUT = {"B1": 1, "B2": 2, "B3": 3, "B4": 4}


def fmt_bytes(n):
    """Sizes as the app shows them (Format.bytes in Sources/OutboardCore/Text/Format.swift): decimal, one decimal below 100 from MB up."""
    if n < 1000: return f"{n} bytes"
    units, value, unit = ["KB", "MB", "GB", "TB"], n / 1000, 0
    while True:
        tenths = int(value * 10 + 0.5)
        one = unit > 0 and tenths < 1000
        if int(value + 0.5) >= 1000 and unit < len(units) - 1:
            value, unit = value / 1000, unit + 1
            continue
        if one and tenths % 10: return f"{tenths // 10}.{tenths % 10} {units[unit]}"
        return f"{tenths // 10 if one else int(value + 0.5)} {units[unit]}"


def gigabytes_rounded(sizes):
    """Format.gigabytesRounded: whole GB per row, largest remainder, so the rows add up to the rounded total."""
    unit = 10 ** 9
    target = (sum(sizes) + unit // 2) // unit
    out = [s // unit for s in sizes]
    for i in sorted(range(len(sizes)), key=lambda i: (-(sizes[i] % unit), i)):
        if sum(out) < target: out[i] += 1
    return out


def read_swift(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def plan_sample():
    """The Storage Plan card of the `plan` demo scenario (DemoScenarios.base), worded as StoragePlanText does, so the hero cannot show
    sizes the app's demo never produces."""
    seeds = {i: int(b.replace("_", "")) for i, b in re.findall(r'DemoSeed\(recipeID: "([\w-]+)", bytes: ([\d_]+)', read_swift("Sources/OutboardCore/Demo/DemoScenarios.swift"))}
    ids = ("xcode-deriveddata", "ollama-models", "ios-device-backups")
    if any(i not in seeds for i in ids): sys.exit("build_site: DemoScenarios.swift no longer has DemoSeed(recipeID:, bytes:) rows for the three plan folders")
    sizes = [seeds[i] for i in ids]
    gb = gigabytes_rounded(sizes)
    photos = seeds.get("photos-library")
    if not photos: sys.exit("build_site: DemoScenarios.swift no longer seeds photos-library (the card's \"Also on this Mac\" line)")
    return {"planXcode": f"{gb[0]} GB", "planOllama": f"{gb[1]} GB", "planIos": f"{gb[2]} GB", "planTotal": f"{sum(gb)} GB", "planPhotos": fmt_bytes(photos),
            "planGrow": [round(100 * s / max(sizes)) for s in sizes]}


def swift_const(rel, pattern, what):
    m = re.search(pattern, read_swift(rel))
    if not m: sys.exit(f"build_site: {rel} no longer has {what}")
    return m[1]


def placeholder_text():
    """PlaceholderText.body for a drive named "Outboard" (the note a parked folder gets), read from Core so the site prints the app's words."""
    t = swift_const("Sources/OutboardCore/Text/GuidedText.swift", r'return "(Outboard moved this folder.*?)"\n', "the PlaceholderText.body sentence")
    t = t.replace('\\"\\(clean)\\"', '"Outboard"')
    if "\\" in t: sys.exit("build_site: PlaceholderText.body has a shape build_site.py does not read")
    return t


def education():
    d = json.loads((ROOT / "Tests/OutboardCoreTests/Fixtures/export/education.json").read_text(encoding="utf-8"))
    cards = {c["id"]: c for c in d["cards"]}
    s = re.split(r"(?<=\.) ", cards["how-a-move-works"]["body"])
    if len(s) != 4: sys.exit("build_site: Education card 4 is no longer four sentences; the home ledger splits it (DESIGN §3 block 5)")
    return {"eduS1": s[0], "eduS2": s[1], "eduS3": s[2], "eduS4": s[3], "eduLimit": cards["if-you-unplug"]["emphasis"],
            "guardOn": d["guardOn"], "guardQuit": d["guardQuit"], "eduFooter": d["footer"]}


def catalogue():
    export = ROOT / "Tests/OutboardCoreTests/Fixtures/export/recipes.json"
    rows = check_recipes.load(export)
    for r in rows:
        r["kind"] = check_recipes.method_kind(r)
    return rows


def tag(text, cls=""):
    return f'<em class="tag{" " + cls if cls else ""}">{html.escape(text)}</em>'


def catalogue_values():
    rows = catalogue()
    by = {r["id"]: r for r in rows}
    auto = [r for r in rows if r["kind"] in ("defaults", "symlink")]
    guided = [r for r in rows if r["kind"] == "guided"]
    never = [r for r in rows if r["kind"] == "never"]
    unverified = [r for r in auto if r.get("verifiedOnRealMac") is not True]
    e = html.escape
    first = lambda s: s.split(". ")[0].rstrip(".") + "."

    def crates(items, label=None):
        return Raw("".join(f'<li><svg aria-hidden="true"><use href="#{GLYPH.get(r["id"], "k-cache")}"/></svg><span><b>{e(r["name"])}</b>'
                           + (f'<code>{e(r["source"])}</code>' if r.get("source") else "") + f'</span>{tag(label or r["methodLabel"])}</li>' for r in items))

    def tried(r):
        return NOT_TRIED if r["kind"] in ("defaults", "symlink") and r.get("verifiedOnRealMac") is not True else ""

    def rows_html(items, lines, tags):
        return Raw("".join(
            f'<li class="ro"><span class="t"><b>{e(r["name"])}</b>' + (f'<code>{e(r["source"])}</code>' if r.get("source") else "") + "</span>"
            + "".join(tag(t) for t in tags(r)) + "".join(f"<p>{e(p)}</p>" for p in lines(r) if p) + "</li>" for r in items))

    step = lambda r: f"Rollout step {ROLLOUT[r['beta']]} of 4." if r.get("beta") in ROLLOUT else ""
    never_home = "".join(f'<li><svg aria-hidden="true"><use href="#k-never"/></svg><span><b>{e(r["name"])}</b>{e(first(r["neverReason"]))}</span>'
                         f'<code>{e(NEVER_CHIP[r["id"]])}</code></li>' for r in never)
    return {"autoCount": len(auto), "guidedCount": len(guided), "neverCount": len(never), "knownCount": len(auto) + len(guided),
            "unverifiedCount": len(unverified), "triedLine": NOT_TRIED if unverified else "",
            "cratesAuto": crates(auto), "cratesGuided": crates(guided, "Guided"), "neverHome": Raw(never_home),
            "autoRows": rows_html(auto, lambda r: [f"If the drive is away: {r['missingDriveEffect']}", f"Confidence in the method: {r['confidence']}. {step(r)} {tried(r)}".replace("  ", " ").strip()],
                                  lambda r: [r["methodLabel"], r["riskLabel"]]),
            "guidedRows": rows_html(guided, lambda r: [f"{len(r['steps'])} steps. The app does the moving; Outboard shows the steps and opens it.", f"If the drive is away: {r['missingDriveEffect']}"],
                                    lambda r: ["Guided", r["riskLabel"]]),
            "neverRows": rows_html(never, lambda r: [r["neverReason"]], lambda r: ["Not offered"]),
            "neverMono": "\n".join(f"{r['name']:<36}{NEVER_CHIP[r['id']]}" for r in never),
            "xcodeKnow": Raw("".join(f"<li>{e(t)}</li>" for t in by["xcode-deriveddata"]["consent"]["whatToKnow"])),
            "ollamaKnow": Raw("".join(f"<li>{e(t)}</li>" for t in by["ollama-models"]["consent"]["whatToKnow"])),
            "ollamaEnv": "'/Volumes/YourDrive".join(by["ollama-models"]["envLine"].split("{drive}")) + "'"}


def values(site):
    v = dict(site)
    base = site["baseURL"]
    v["year"] = datetime.date.today().year
    v["downloadURL"] = f"https://github.com/{site['releasesRepo']}/releases/latest/download/{site['dmgName']}"
    v["issuesURL"] = f"https://github.com/{site['releasesRepo']}/issues"
    v["moveProblemURL"] = v["issuesURL"] + "/new?template=move-went-wrong.yml"
    v["testerURL"] = v["issuesURL"] + "/new?template=recipe-result.yml"
    v["releasesURL"] = f"https://github.com/{site['releasesRepo']}/releases"
    v["repoURL"] = f"https://github.com/{site['releasesRepo']}"
    ld = {"@context": "https://schema.org", "@type": "SoftwareApplication", "name": site["name"],
          "operatingSystem": f"macOS {site['minMacOS']} or later", "applicationCategory": "UtilitiesApplication",
          "description": site["tagline"], "url": base + "/", "image": base + "/og.png",
          "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"}}
    v.update(catalogue_values())
    v.update(education())
    plan = plan_sample()
    v.update(plan)
    note = placeholder_text()
    v["placeholderText"] = note
    v["noteLead"] = note.split(". ")[0] + "."
    v["sampleFiles"] = swift_const("Sources/OutboardCore/Model/Names.swift", r"returnSampleFiles = (\d+)", "returnSampleFiles")
    v["parkSeconds"] = int(float(swift_const("Sources/OutboardCore/Model/Names.swift", r"parkDebounceSeconds = ([\d.]+)", "parkDebounceSeconds")))
    v["websiteShort"] = urlsplit(base).netloc + urlsplit(base).path
    # The Drive Guard is described in the future-ish tense until a real Mac has run it (docs/VERIFY_LOG.md; DESIGN §9 decision 5).
    v["guardVerb"] = "is designed to announce" if v["unverifiedCount"] else "announces"
    v["ogAlt"] = (f"Sample data: the Outboard Storage Plan card. Your Mac could free up to {plan['planTotal']}: Xcode build data {plan['planXcode']}, "
                  f"Ollama models {plan['planOllama']}, iPhone backups {plan['planIos']}. Measured on this Mac. Nothing was moved.")
    v["softwareJSON"] = Raw(json.dumps(ld, ensure_ascii=False).replace("</", "<\\/"))
    return v


def pages():
    """(output path, url, meta, body) for every page source."""
    src = SITE / "src" / "pages"
    for f in sorted(src.rglob("*.html"), key=lambda f: f.relative_to(src).as_posix().removesuffix("index.html")):
        rel = f.relative_to(src).as_posix()
        text = f.read_text(encoding="utf-8")
        m = re.match(r"<!--meta (\{.*?\})-->\n", text, re.S)
        if not m:
            sys.exit(f"{rel}: first line must be <!--meta {{...}}-->")
        yield rel, "/" + rel.removesuffix("index.html"), json.loads(m.group(1)), text[m.end():]


def changelog_html(entries, name):
    if not entries:
        return Raw(f'<p class="muted">No releases yet. {html.escape(name)} 1.0 is on its way.</p>')
    out = []
    for e in entries:
        ver = html.escape(e["version"])
        out.append(f'<section class="release" id="v{ver}"><h2>{ver} <time datetime="{e["date"]}">{pretty(e["date"])}</time></h2>'
                   f'{changelog.to_html(e["body_md"])}</section>')
    return Raw("\n".join(out))


def feed(v, entries):
    # Root-relative links in the notes get the full baseURL, like the pages' href/src rewrite in build().
    notes = lambda md: re.sub(r'\b(href|src)="/(?!/)', rf'\1="{v["baseURL"]}/', changelog.to_html(md))
    items = "".join(
        f"<item><title>{html.escape(v['name'])} {html.escape(e['version'])}</title>"
        f"<link>{v['baseURL']}/changelog/#v{html.escape(e['version'])}</link>"
        f"<guid isPermaLink=\"false\">{html.escape(v['name'])}-{html.escape(e['version'])}</guid>"
        f"<pubDate>{format_datetime(datetime.datetime.fromisoformat(str(e['date'])).replace(tzinfo=datetime.timezone.utc))}</pubDate>"
        f"<description>{html.escape(notes(e['body_md']))}</description></item>"
        for e in entries)
    return ('<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel>'
            f"<title>{html.escape(v['name'])} changelog</title><link>{v['baseURL']}/changelog/</link>"
            f'<atom:link href="{v["baseURL"]}/feed.xml" rel="self" type="application/rss+xml"/>'
            f"<description>New versions of {html.escape(v['name'])}</description><language>en</language>{items}"
            "</channel></rss>\n")


def minify(css):
    """Comments out, whitespace runs to one space, none around { } ; , and after a colon. Strings (fonts, content, url) are left alone; the
    spaces calc() needs around + and - stay because only runs are collapsed."""
    parts = re.split(r'("(?:[^"\\]|\\.)*")', re.sub(r"/\*.*?\*/", "", css, flags=re.S))
    return "".join(p if i % 2 else re.sub(r": ", ":", re.sub(r" ?([{};,]) ?", r"\1", re.sub(r"\s+", " ", p))) for i, p in enumerate(parts)).strip() + "\n"


def build(out, site):
    if out.name != "_dist": sys.exit(f"refusing to build into {out}: the output folder must be named _dist")   # rmtree below; not an assert, python -O strips those
    log = ROOT / "CHANGELOG.md"
    entries = changelog.parse(str(log)) if log.exists() else []
    v = values(site)
    v["changelog"] = changelog_html(entries, site["name"])
    v["version"] = f"Version {entries[0]['version']}" if entries else "1.0 coming soon"
    v["status"] = Raw(f'The latest release is {html.escape(entries[0]["version"])}.' if entries else
                      "There is no public release yet. A first tester beta comes after the code has compiled in CI on macOS and "
                      'real Macs have tried it. The <a href="/changelog/">changelog</a> and its <a href="/feed.xml">RSS feed</a> will say when it is out.')
    v["statusShort"] = f"Version {entries[0]['version']} is out." if entries else "In development. No public release yet."
    v["statusNote"] = ("The changelog says what testers have tried on real Macs." if entries else
                       "Nothing has run on a real Mac yet, so read everything described here as the design, not as proof that it works. The changelog will say what testers have tried.")
    v["statusTag"] = f"Version {entries[0]['version']}" if entries else "In development"
    layout = (SITE / "src" / "layout.html").read_text(encoding="utf-8")
    prefix = urlsplit(site["baseURL"]).path   # "/outboard" on a project site, "" on a custom domain

    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(SITE / "static", out)
    (out / ".nojekyll").write_text("")   # serve files as-is on GitHub Pages
    css = out / "styles.css"   # the shipped sheet carries no comments and no layout whitespace (they are for people, and count against the budget)
    css.write_text(minify(css.read_text(encoding="utf-8")), encoding="utf-8", newline="\n")
    listed = []
    for rel, url, meta, body in pages():
        meta = {k: fill(x, v, rel, str) if isinstance(x, str) else x for k, x in meta.items()}
        head = ['<meta name="robots" content="noindex">'] if meta.get("noindex") else []
        listed += [] if meta.get("noindex") else [(url, meta)]
        page = dict(v, title=meta["title"], description=meta["description"], canonical=v["baseURL"] + url,
                    head=Raw("\n".join(head)), body=Raw(fill(body, v, rel)))
        dest = out / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        text = re.sub(r'\b(href|src)="/(?!/)', rf'\1="{prefix}/', fill(layout, page, "layout.html"))
        text = re.sub(r'<a\b[^>]*?\bhref="(https?://[^"]+)"[^>]*>',   # an external link gets rel=noopener
                      lambda m: m[0] if urlsplit(m[1]).netloc == urlsplit(site["baseURL"]).netloc or " rel=" in m[0] else m[0][:-1] + ' rel="noopener">', text)
        # srcset="/a.jpg 1x, /b.jpg 2x": every candidate gets the prefix too.
        text = re.sub(r'\bsrcset="([^"]*)"',
                      lambda m: 'srcset="' + re.sub(r'(^|,\s*)/(?!/)', rf'\1{prefix}/', m[1]) + '"', text)
        dest.write_text(text, encoding="utf-8", newline="\n")

    (out / "feed.xml").write_text(feed(v, entries), encoding="utf-8", newline="\n")
    (out / "sitemap.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
        + "".join(f"<url><loc>{v['baseURL']}{u}</loc></url>\n" for u, _ in listed) + "</urlset>\n",
        encoding="utf-8", newline="\n")
    # Crawlers read robots.txt only at a host's root, so on a project site this file does nothing (harmless).
    (out / "robots.txt").write_text(f"User-agent: *\nAllow: /\n\nSitemap: {v['baseURL']}/sitemap.xml\n",
                                    encoding="utf-8", newline="\n")
    v["pageList"] = Raw("\n".join(f"- [{m['title']}]({v['baseURL']}{u}): {m['description']}" for u, m in listed))
    llms = fill((SITE / "src" / "llms.txt").read_text(encoding="utf-8"), v, "llms.txt", str)
    (out / "llms.txt").write_text(llms, encoding="utf-8", newline="\n")
    return v


class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links, self.ids, self.meta, self.title, self.h1, self.noalt, self.nosize = [], set(), {}, "", 0, 0, 0
        self._title, self.csp, self.inline, self.anchors, self.text = False, None, [], [], []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "meta" and (a.get("http-equiv") or "").lower() == "content-security-policy":
            self.csp = a.get("content")
        # What the CSP blocks: inline scripts (JSON-LD is data, not script), <style>, style="" and on* handlers.
        if tag == "script" and not a.get("src") and a.get("type") != "application/ld+json" or tag == "style":
            self.inline.append(f"inline <{tag}> (blocked by the CSP)")
        self.inline += [f"<{tag} {k}> (blocked by the CSP)" for k in a if k == "style" or k.startswith("on")]
        if a.get("target") == "_blank" and "noopener" not in (a.get("rel") or ""):   # a new tab gets no opener
            self.inline.append(f"<{tag} target=_blank> without rel=noopener")
        if tag == "a" and (a.get("href") or "").startswith(("http://", "https://")):
            self.anchors.append((a["href"], a.get("rel") or ""))
        if "id" in a:
            self.ids.add(a["id"])
        self.links += [a[k] for k in ("href", "src") if a.get(k)]
        self.links += [c.split()[0] for c in (a.get("srcset") or "").split(",") if c.strip()]
        if tag == "meta" and (a.get("name") or a.get("property")):
            self.meta[a.get("name") or a.get("property")] = a.get("content") or ""
        if tag == "link" and a.get("rel") == "canonical":
            self.meta["canonical"] = a.get("href") or ""
        self._title |= tag == "title"
        self.h1 += tag == "h1"
        self.noalt += tag == "img" and "alt" not in a
        self.nosize += tag == "img" and not (a.get("width") and a.get("height"))

    def handle_endtag(self, tag):
        self._title &= tag != "title"

    def handle_data(self, data):
        self.text.append(data)
        if self._title:
            self.title += data


def contrast(css):
    """WCAG AA (4.5:1) for the text colors on the page backgrounds, in the light block and in the dark one (which
    overrides the light tokens it names)."""
    # ponytail: only 6-digit hex tokens are measured (not rgb() ones like --header), and not illustrations with fixed
    # colours.
    # Add pairs here when a color lands on a new background.
    def lum(c):
        c = [int(c[i:i + 2], 16) / 255 for i in (1, 3, 5)]
        c = [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
        return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    blocks = re.findall(r":root\s*\{([^}]*)\}", css)   # light, then prefers-color-scheme: dark
    if len(blocks) != 2:
        return [f"styles.css: {len(blocks)} root-selector blocks, want exactly two (light, then dark)"]
    light, dark = (dict(re.findall(r"--([\w-]+):\s*(#[0-9a-fA-F]{6})\b", b)) for b in blocks)
    pairs = [(f, b) for f in ("text", "text-2", "accent") for b in ("bg", "bg-alt", "card")]
    on = "on-button" if "on-button" in light else "#ffffff"   # the .button and .skip label
    pairs += [(on, "button"), (on, "button-hover")]
    errors = []
    for scheme, t in (("light", light), ("dark", {**light, **dark})):
        for fg, bg in pairs:
            hi, lo = sorted((lum(t.get(fg, fg)), lum(t[bg])), reverse=True)
            if (hi + 0.05) / (lo + 0.05) < 4.5:
                errors.append(f"styles.css: {fg} on --{bg} is {(hi + 0.05) / (lo + 0.05):.2f}:1 in {scheme}, want 4.5:1")
    return errors


def check(out, site, v):
    errors = []
    base = v["baseURL"]
    host, prefix = urlsplit(base).netloc, urlsplit(base).path
    parsed = {}
    for f in sorted(out.rglob("*.html")):
        p = Page()
        p.feed(f.read_text(encoding="utf-8"))
        parsed[f] = p

    def resolve(rel, page, link):
        u = urlsplit(urljoin(page, link))
        if u.scheme not in ("http", "https") or u.netloc != host:
            return   # mailto:, external
        if not u.path.startswith(prefix + "/"):
            errors.append(f"{rel}: link {link} is outside {base}/")
            return
        target = out / u.path[len(prefix) + 1:]
        if u.path.endswith("/"):
            target /= "index.html"
        if not target.is_file():
            errors.append(f"{rel}: broken link {link}")
        elif u.fragment and target in parsed and u.fragment not in parsed[target].ids:
            errors.append(f"{rel}: missing anchor {link}")

    for f, p in parsed.items():
        rel = f.relative_to(out).as_posix()
        url = "/" + rel.removesuffix("index.html")
        for key in ("description", "canonical", "og:title", "og:description", "og:image", "og:url"):
            if not p.meta.get(key):
                errors.append(f"{rel}: missing {key}")
        if not p.title.strip():
            errors.append(f"{rel}: missing <title>")
        if p.meta.get("canonical") != base + url:
            errors.append(f"{rel}: canonical {p.meta.get('canonical')} != {base + url}")
        if p.h1 != 1:
            errors.append(f"{rel}: {p.h1} <h1> elements, want 1")
        if p.noalt:
            errors.append(f"{rel}: {p.noalt} <img> without alt")
        if p.nosize:
            errors.append(f"{rel}: {p.nosize} <img> without width and height (layout shift)")
        text = re.sub(r"\s+", " ", "".join(p.text))
        if AFFILIATION not in text:
            errors.append(f"{rel}: missing the line \"... {AFFILIATION}\"")
        if v["unverifiedCount"] and rel in ("index.html", "download/index.html") and NOT_TRIED not in text:
            errors.append(f"{rel}: must say \"{NOT_TRIED}\" while {v['unverifiedCount']} automated entries are unverified (BUILD_PLAN section 2)")
        errors += [f"{rel}: external link {h} without rel=noopener" for h, r in p.anchors if urlsplit(h).netloc != host and "noopener" not in r]
        if p.csp != CSP:
            errors.append(f"{rel}: Content-Security-Policy meta is {p.csp!r}, want {CSP!r}")
        errors += [f"{rel}: {what}" for what in p.inline]
        for link in p.links + [p.meta.get("og:image", "")]:
            resolve(rel, base + url, link)
    bp = banned()
    for f in sorted(out.rglob("*")):
        rel = f.relative_to(out).as_posix()
        if f.suffix in (".html", ".xml", ".txt", ".css", ".js"):
            for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
                if bp and (hit := bp.search(line)) and "no-claim-ok" not in line:
                    errors.append(f"{rel}:{n}: banned phrase {hit[0]!r} (tools/banned_phrases.txt); mark an intentional mention no-claim-ok")
        if f.suffix in (".html", ".txt") and (hit := SAFE.search(f.read_text(encoding="utf-8"))):
            errors.append(f"{rel}: the word {hit[0]!r} (say what happens instead)")
        if f.suffix in (".html", ".txt", ".xml") and re.search(r"\bOverflow\b", f.read_text(encoding="utf-8")):
            errors.append(f"{rel}: the word \"Overflow\" (the drive is \"your Outboard drive\", BUILD_PLAN section 1)")
        if f.suffix in (".html", ".xml", ".txt"):
            text = f.read_text(encoding="utf-8")
            if f.suffix != ".html":   # sitemap, feed, robots.txt, llms.txt
                for link in re.findall(re.escape(base) + r'[^\s"<>)&]*', text):
                    resolve(rel, base, link)
            for key in site.get("placeholders", []):
                text = text.replace(html.escape(str(site[key])), "").replace(str(site[key]), "")
            if PLACEHOLDER.search(text):
                errors.append(f"{rel}: {PLACEHOLDER.search(text)[0]} not from a site.json placeholder")
        if f.suffix in (".html", ".css") and re.search(r"data-theme|localStorage", f.read_text(encoding="utf-8")):
            errors.append(f"{rel}: data-theme/localStorage (use prefers-color-scheme only)")
        if f.suffix == ".xml":
            try:
                ET.parse(f)
            except ET.ParseError as e:
                errors.append(f"{f.name}: {e}")
    for key, val in site.items():
        if PLACEHOLDER.search(str(val)) and key not in site.get("placeholders", []):
            errors.append(f"site.json: {key} is a placeholder but not listed in \"placeholders\"")
    errors += [f"{f.relative_to(out).as_posix()}: a webfont (the family ships none)" for f in out.rglob("*") if f.suffix in (".woff", ".woff2", ".ttf", ".otf")]
    errors += contrast((out / "styles.css").read_text(encoding="utf-8"))
    css = (out / "styles.css").read_text(encoding="utf-8")
    # The Storage Plan card's bars are sized in CSS (CSP: no style attribute); they must follow the demo scenario's unrounded bytes.
    grow = [int(w) for _, w in sorted(re.findall(r"\.card-rows li:nth-child\((\d)\) \.rb\s*\{\s*width:\s*(\d+)%", css))]
    if grow != v["planGrow"]:
        errors.append(f"styles.css: .card-rows .rb widths {grow} must match the plan demo's {v['planGrow']} (share of the largest folder, in percent)")
    if re.search(r"url\(\s*['\"]?data:", css):
        errors.append("styles.css: a data: URL is blocked by the CSP's img-src 'self'; ship the image as a static file")
    for pattern, cap in BUDGET.items():
        for f in out.glob(pattern):
            if f.stat().st_size > cap:
                errors.append(f"{f.relative_to(out).as_posix()}: {f.stat().st_size} bytes, over its {cap} byte budget")
    return errors, len(parsed)


def main():
    site = json.loads((SITE / "site.json").read_text(encoding="utf-8"))
    site["baseURL"] = site["baseURL"].rstrip("/")
    if "--check" not in sys.argv[1:]:
        build(SITE / "_dist", site)
        print(f"built {SITE / '_dist'} for {site['baseURL']}")
        return
    # baseURL, plus the other shape it can take: a bare origin (custom domain) or a GitHub Pages project path.
    u = urlsplit(site["baseURL"])
    origin = f"{u.scheme}://{u.netloc}"
    failed = False
    for base in dict.fromkeys([site["baseURL"], origin, f"{origin}/{site['releasesRepo'].split('/')[-1]}"]):
        s = dict(site, baseURL=base)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "_dist"
            errors, n = check(out, s, build(out, s))
        for e in errors:
            print("error:", e)
        print(f"checked {n} pages for {base}: {len(errors)} errors")
        failed |= bool(errors)
    todo = [k for k in site.get("placeholders", []) if PLACEHOLDER.search(str(site[k]))]
    if todo: print("placeholders still to fill: " + ", ".join(todo))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
