"""CHANGELOG.md is the single source for release notes.

Consumers: the GitHub release body (md, release.yml), the site's /changelog/ and /feed.xml (html, build_site.py).

    python tools/changelog.py notes 1.0.0 --format md|html   # exit 1 if 1.0.0 has no row
    python tools/changelog.py --self-test

Sections look like `## 1.0.0 — 2027-01-25` (em dash, ISO date), newest first. `## Unreleased` is never
published. Any other `## ` heading is an error, so a typo fails the release instead of dropping notes.
Stdlib only.
"""
import argparse
import datetime
import html
import re
import sys
from pathlib import Path

DEFAULT = Path(__file__).resolve().parent.parent / "CHANGELOG.md"
HEADING = re.compile(r"(\d+\.\d+\.\d+) — (\d{4}-\d{2}-\d{2})")
INLINE = re.compile(r"`([^`]+)`|\*\*(.+?)\*\*|\[([^\]]+)\]\(([^)\s]+)\)")


def parse(path=DEFAULT):
    """[{version, date, body_md}], newest first, without Unreleased."""
    rows, body = [], None
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.startswith("## "):
            title = line[3:].strip()
            if title == "Unreleased":
                body = None
                continue
            m = HEADING.fullmatch(title)
            if not m:
                raise ValueError(f"{path}: bad heading {line!r}, want '## 1.2.3 — 2027-01-25'")
            try:
                datetime.date.fromisoformat(m[2])
            except ValueError:
                raise ValueError(f"{path}: bad date in {line!r}") from None
            body = []
            rows.append({"version": m[1], "date": m[2], "body_md": body})
        elif body is not None:
            body.append(line)
    for r in rows:
        r["body_md"] = "\n".join(r["body_md"]).strip()
    versions = [r["version"] for r in rows]
    if len(set(versions)) != len(versions):
        raise ValueError(f"{path}: duplicate version")
    return sorted(rows, key=lambda r: tuple(map(int, r["version"].split("."))), reverse=True)


def _safe_url(url):
    # Browsers drop control characters and spaces inside URLs, so "\x01javascript:" would run.
    if re.search(r"[\x00-\x20\x7f]", url):
        return False
    scheme = re.match(r"([A-Za-z][A-Za-z0-9+.-]*):", url)
    return not scheme or scheme[1].lower() in ("http", "https", "mailto")


def _inline(text):
    out, pos = [], 0
    for m in INLINE.finditer(text):
        out.append(html.escape(text[pos:m.start()]))
        code, bold, label, url = m.groups()
        if code is not None:
            out.append(f"<code>{html.escape(code)}</code>")
        elif bold is not None:
            out.append(f"<strong>{_inline(bold)}</strong>")
        elif _safe_url(url):
            out.append(f'<a href="{html.escape(url)}">{_inline(label)}</a>')
        else:
            out.append(html.escape(m[0]))
        pos = m.end()
    out.append(html.escape(text[pos:]))
    return "".join(out)


def to_html(md):
    """Paragraphs, `- ` lists (indented lines continue an item), **bold**, `code`, [text](url). Everything
    else, raw HTML included, is escaped."""
    blocks, para, items = [], [], []

    def flush():
        if para:
            blocks.append(f"<p>{_inline(' '.join(para))}</p>")
        if items:
            blocks.append("<ul>\n" + "\n".join(f"<li>{_inline(i)}</li>" for i in items) + "\n</ul>")
        para.clear(), items.clear()

    for raw in md.splitlines():
        line = raw.strip()
        if not line:
            flush()
        elif line.startswith("- "):
            if para:
                flush()
            items.append(line[2:].strip())
        elif items and raw[:1] in (" ", "\t"):
            items[-1] += " " + line
        else:
            if items:
                flush()
            para.append(line)
    flush()
    return "\n".join(blocks)


def _self_test():
    import tempfile
    md = ("# Changelog\nintro\n\n## Unreleased\n- secret\n\n"
          "## 1.0.0 — 2027-01-25\n\nFirst.\n\n- **Bold** and `a<b>`\n  continued\n- [site](https://x.app/?a=1&b=2)\n\n"
          "## 1.2.0 — 2027-03-01\n- newer\n")
    with tempfile.TemporaryDirectory() as d:
        p = Path(d, "CHANGELOG.md")
        p.write_text(md, encoding="utf-8")
        rows = parse(p)
        assert [r["version"] for r in rows] == ["1.2.0", "1.0.0"], rows
        assert rows[1]["date"] == "2027-01-25" and rows[1]["body_md"].startswith("First.")
        assert "secret" not in str(rows)
        for bad in ("## 1.0.0 - 2027-01-25", "## 1.0.0 — 2027-02-30"):
            p.write_text(bad + "\n", encoding="utf-8")
            try:
                parse(p)
                raise AssertionError(f"accepted {bad!r}")
            except ValueError:
                pass
    h = to_html(rows[1]["body_md"])
    assert h == ("<p>First.</p>\n<ul>\n<li><strong>Bold</strong> and <code>a&lt;b&gt;</code> continued</li>\n"
                 '<li><a href="https://x.app/?a=1&amp;b=2">site</a></li>\n</ul>'), h
    assert to_html("<script>x</script>") == "<p>&lt;script&gt;x&lt;/script&gt;</p>"
    for bad in ("javascript:alert(1)", "JavaScript:x", "data:text/html,x", "\x01javascript:x", "vbscript:x"):
        assert "<a " not in to_html(f"[x]({bad})"), bad
    for good in ("mailto:a@b.c", "/support/#backups", "../x", "http://a.b"):
        assert f'href="{good}"' in to_html(f"[x]({good})"), good
    assert to_html('[x](https://a.b/"onmouseover=1)') == '<p><a href="https://a.b/&quot;onmouseover=1">x</a></p>'
    assert to_html("a\nb\n\nc") == "<p>a b</p>\n<p>c</p>"


def main(argv):
    for stream in (sys.stdout, sys.stderr):
        stream.reconfigure(encoding="utf-8")
    if argv == ["--self-test"]:
        _self_test()
        print("changelog self-test ok")
        return 0
    ap = argparse.ArgumentParser(description="Print one version's release notes from CHANGELOG.md.")
    ap.add_argument("command", choices=["notes"])
    ap.add_argument("version", help="1.2.3 (a leading v is ignored)")
    ap.add_argument("--format", choices=["md", "html"], default="md")
    ap.add_argument("--file", default=DEFAULT)
    a = ap.parse_args(argv)
    version = a.version.removeprefix("v")
    row = next((r for r in parse(a.file) if r["version"] == version), None)
    if not row or not row["body_md"]:
        print(f"CHANGELOG.md has no '## {version} — YYYY-MM-DD' section with notes", file=sys.stderr)
        return 1
    print(row["body_md"] if a.format == "md" else to_html(row["body_md"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
