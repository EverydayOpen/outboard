# Design spec: Outboard (website and app)

**Why:** Outboard is EverydayOpen's fifth app and must read as a sibling of Whydunit ("Daylight", a desktop diorama),
Tirekick ("Night Bay", an inspection bay), Overstay ("Last Call", a room after the party) and Aftertaste ("The Morning
After", a desk at first light) while having its own world. The bar is the family's reference set (Maccy, Rectangle,
VoiceInk, Recordly, Mole, MaCursor): a real product object inside a small world with one light source, on a page that is
otherwise quiet.
**Authority:** this file is authoritative for visual design (tokens, surfaces, compositions, type, icon).
`docs/MOTION.md` is authoritative for motion and is referenced by section. `docs/BUILD_PLAN.md` (§7 screens, §8 UI rules
and copy, §9 demo, §10 ownership) is the contract; where this file wants a BUILD_PLAN or copy change it is listed in §9,
not made.
**Shared system:** §1.1 (the eight rules), §2.3–§2.7 (web foundation) and §6.1 (`surface`, `OnFloor`, `Horizon`,
`Metric`, `Tag`, `KeyCapStyle`, `HoverTilt`) are the same mechanics as the Aftertaste, Overstay, Tirekick and Whydunit
`docs/DESIGN.md`; copy fixes to all five. Everything else here is Outboard's.
**Status:** nothing in this file has been built. Every contrast figure was computed with `tools/build_site.py`'s
`contrast()` formula (`<scratchpad>/outboard_contrast.py`, 2026-10-03). The Swift is written, not compiled, and no Mac has
run it; anything unconfirmed is marked VERIFY. Copy in this file never uses a phrase from `tools/banned_phrases.txt`
except on a line that says the app never says it (marked `no-claim-ok`); the site and app owners keep it that way
(BUILD_PLAN §3.1 G15).

## 1. The verdict: "Alongside" (world: the quay at dusk, high water)

The theme is room to breathe. The world is **a stone quay at dusk with a boat moored alongside**. The quay is the Mac:
a flat slab with a capacity bar cut into its edge, full to the brim. The boat is the drive: a longer, roomier slab with
the same bar, mostly empty. Between them a short gangway, and across the gangway, one by one, go the crates: the big
folders (Xcode build data, Ollama models, iPhone backups). Where each crate stood on the quay a painted outline remains,
and from the outline a thin line (the tether, the link) runs across the gangway to the crate on the boat. On the quay
stands the lamp: the one light in the scene and the **Drive Guard**. It burns while the boat is moored. When the boat
leaves, the gangway folds, the tethers slacken and fade, a small note card is pinned to each outline (the parked
placeholder), and the lamp dims to a parked glow: the page shows the limit the app has. When the boat returns, the lamp
relights and the tethers draw back. That one picture gives every surface its colour (aqua = "the line to the drive", the
only accent; slate and cyan only in the sky and the water), its motion (the crossing, the leave, the return) and its
resolution (the quiet state is a lit lamp and a still boat, not a celebration).

| | Whydunit | Tirekick | Overstay | Aftertaste | **Outboard** |
|---|---|---|---|---|---|
| Direction | Daylight (light-first) | Night Bay (dark everywhere) | Last Call (dark-first, follows the system) | The Morning After (dark-first, true light mode) | **Alongside** (dark-first, follows the system; a true light mode, "high water at noon") |
| World | a macOS desktop diorama | an inspection bay | a desk at night by a lit door | a desk at first light | **a quay at dusk, high water**: the quay slab (the Mac), the boat slab (the drive), the gangway, the crates, the outlines with their tethers, the lamp, the pinned note, the Storage Plan card |
| Key light | the dawn glow | one lime laser | the door light | the horizon line | **the quay lamp**: a small aqua point on a post at the quay's edge, with a pool on the water below it; it is the guard indicator (lit = drive attached, dimmed = parked) |
| Accent | sky blue | hi-vis lime | amber | dusk violet | **mooring aqua** `#4FE3D8` with near-black text; as text `#0B6F73` (light) / `#7EECE4` (dark); green only for "all matched", Healthy and a moved row's check; red only on a failed row's symbol |
| Type voice | Inter Display, centered | Inter Display, mono readouts | system display face, rounded numerals | system display face, rounded numerals | **system display face, no webfont** (§2.2); left-aligned hero; **rounded numerals** for sizes and counts; mono for paths, keys and UUID prefixes |
| Signature object | the window on the wallpaper | the paper report card | the weight bar of slabs | the outline and the residue bar | **the capacity bar** (one proportional bar per drive, segments per folder) and **the tethered outline** (the folder's painted outline on the Mac with its line to the drive) in the app; **the two slabs and the gangway** and the **Storage Plan card** on the site |
| Signature motion | the notification lands | the beam sweeps | the sweep to the door | the peel and the fade | **the crossing**: crates cross the gangway one by one; **the leave**: the boat slides out, the tethers slacken, the notes pin, the lamp dims; **the return** reverses it |
| Radii | 8/12/18/28, pills | 6/10/14/20 | 7/11/16/24 | 8/12/18/26 | **8/12/18/26**, 12px buttons (Aftertaste's set: the two apps share rows and cards) |

**Decided, in this brand:**

1. **No webfont** (the family decision, kept): the site budget is CSS ≤ 40 KB, JS ≤ 6 KB, no font file. Headlines use
   the system display face at 600 with tight tracking (§2.2).
2. **The site follows the system scheme** and the dark palette is designed first: it is the one on every screenshot,
   the OG image and the card. Light mode is the same quay at noon (cool paper, a pale sky, bright water), not a grey page.
3. **Aqua is the one accent and it means "the line to the drive".** It is on the primary button, the lamp, the tether,
   the lit edge of a segment that has been moved, and the Healthy pill's dot. Slate and cyan appear only inside the
   sky and water gradients (world, never UI). Green is a status (all matched, Healthy, a moved row's check). Red appears
   only on a failed row's symbol. **Health, method and risk are never conveyed by colour alone** (BUILD_PLAN §8): the
   pill carries the word; a "Community method" row is set exactly like an "Official setting" row apart from the chip word;
   a "Can't be replaced" row differs only by its chip word and by Cancel being the default button.
4. **Honest objects.** The slabs are drawn like the app's own Drives rows (name, format, free space, a capacity bar).
   The crates carry the app's own Plan rows (name, rounded size, method chip). The Storage Plan card on the site is the
   app's card verbatim, sample data, with the footnote on its back. The quay bar's moved segments turn to **outlines, not
   empty space**: the originals are kept as `.before-move` until the user confirms, and the picture says so.
5. **Two buttons, two shared JS jobs.** The hero's "Unplug the drive" is a real `<button>` driving the leave
   (`data-sweep`, MOTION §2.4; the same button reads "Plug it back in" and reverses it); "Turn the card over" is a
   `data-flip` button (the shared flip job). Both are keyboard-, tap- and click-reachable, hidden without JS, and swap
   states without movement under Reduce Motion. `motion.js` is Aftertaste's file byte for byte (the shared script plus
   the attribute-driven sweep job), under 6 KB.
6. **Glass only on the controls layer** (`barSurface()`, §6.2): the consent sheet's action bar, the progress sheet's bar
   and the banner strip. Content sits on porcelain surfaces; slabs, crates and cards are opaque.
7. **Real app names, no vendor marks.** The site and the demo name the apps the catalogue knows (Xcode, Ollama, iPhone
   backups, Photos) with the fixed line "Outboard is not affiliated with or endorsed by any app it lists."
   (`Names.affiliation`); icons are neutral SF Symbols in the app and inline stroke glyphs on the site (§4.3). No app
   icon, logo or wordmark of a third party ships.
8. **The word "safe" appears nowhere** on the site or in the app chrome (BUILD_PLAN §8, G15). The pages say "compared
   file by file", "the original is kept until you confirm", "a note where the folder was".
9. **"Not yet tried on a real Mac."** (`Names.notTriedMarker`) is a fixed line on the home page, the download page,
   About and every consent sheet of an unverified recipe, set as plain text in `--text-2`, never as a warning triangle
   and never in red. It is a fact, not an alarm.

**Not doing:** a CDN, a tracker, any font file, a star count, autoplay video, mesh blobs, gradient text, emoji icons,
glass on content, a nav CTA that hides itself, `style=""` attributes, `data-theme`, a lamp that pulses, a wave that
loops, a boat that rocks at idle, a percentage estimate or a rate on any progress bar (bytes and elapsed time only), a
"space freed" number before the Trash is emptied, a red anything that is not a failed row's symbol, the word "Overflow",
any of the banned phrases.

### 1.1 The eight rules (shared with the siblings)

1. **One world per product, and it appears only behind objects:** the hero scene, the "What it moves" media well, the
   finale and the download page's icon. Every other section is paper (light) or graphite (dark), paced by whitespace.
2. **One key light per scene.** Outboard's is the lamp. Nothing else glows, and a glow is never health- or risk-coloured
   (MOTION §1.1 rule 3): a Held relocation's row is lit exactly like a Healthy one; the lamp dims, it never turns red.
3. **Light, not lines.** Every raised surface has a lit top edge (`inset 0 1px 0`), a 0.5px hairline (a 1px light rim in
   dark, because black swallows shadows) and a shadow tinted with the brand's ink (slate-black), never neutral grey, never
   animated (MOTION §1.4).
4. **One accent.** Aqua means "the line to the drive" and is the only accent. Green and red mean a status and appear only
   in 6px dots, symbols and tag fills behind primary text. A method, a risk or a health never gets a coloured panel.
5. **Objects, not illustrations.** Every product visual is a faithful Mac object: a Finder-style row, a capacity bar, a
   window, a sheet, a printed card, a note file. The quay, the boat and the crates are drawn as slabs with the app's own
   rows on them. No water droplets, waves, anchors, ropes or seagulls.
6. **Everything you can press is a key-cap:** a gradient lighter at the top, a lit rim, a hairline, a shallow side wall,
   and a press that sinks 1–2px with the shadow swapped at once (never transitioned).
7. **Concentric radii:** outer radius = inner radius + padding. Outboard 8/12/18/26 and 12px buttons. Grain (≤ 6%,
   inline SVG) only on the sky and water gradients, never under body text.
8. **The apps stay native.** `NavigationSplitView`, `List`, sheets, the toolbar are system parts. Premium comes from
   the dusk wash, porcelain surfaces, one lifted object per screen, the aqua, the pills, the key-caps and the precision
   of the type. Nothing moves at idle.

## 2. Web foundation

### 2.1 The contract with `tools/build_site.py`

- `contrast()` reads exactly two `:root { }` blocks and only 6-digit hex tokens: light first, then
  `@media (prefers-color-scheme: dark)`. It measures `--text`, `--text-2`, `--accent` on `--bg`, `--bg-alt`,
  `--card`, and `--on-button` on `--button` and `--button-hover`. Every other override sits on `html[lang]` (§2.7),
  never on a third `:root`.
- Hero copy sits on `--bg` (the world is behind objects only), so no new pairs are needed. The slabs, the crates, the
  lamp and the card are `aria-hidden` or `role="img"` pictures with fixed colours, not measured.
- `data-theme` and `localStorage` must not appear anywhere, including comments. No `style=""` (stagger indices, crate
  positions and slab depths use `:nth-child`).
- The CSP is the siblings' exact string, unchanged, in `layout.html` and the `CSP` constant:
  `default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'`.
- `BUDGET` in `build_site.py` (infra): `styles.css` 40 000, `motion.js` 6 000, `index.html` 36 000, `shots/*`
  110 000; a font file appearing under `site/static/` is itself a `--check` error.
- `--check` also greps the built pages for `tools/banned_phrases.txt` (BUILD_PLAN §3.1 G15 covers `site/`); a line
  that must quote one (a guide saying what the app never claims) carries `no-claim-ok` in an HTML comment on that line
  and says why. `--check` fails while `Names.notTriedMarker` is missing from the home and download pages and any
  `Recipe(id:` lacks `verifiedOnRealMac: true` (G15's marker rule).
- The site reads the Core goldens `Tests/OutboardCoreTests/Fixtures/export/{recipes,education}.json` for the catalogue
  tables and the five education cards, so the app, the validator and the site cannot disagree (BUILD_PLAN §1).

### 2.2 Type: the system display face, no webfont

```css
--font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI Variable Text", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
--font-display: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI Variable Display", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
--font-num: ui-rounded, "SF Pro Rounded", var(--font);
--font-mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, "Cascadia Mono", Consolas, monospace;
```

**Type ladder.** Put this comment at the top of `styles.css`; no size outside it.

```css
/* Type ladder (docs/DESIGN.md §2.2). Display = var(--font-display) 600; numerals = var(--font-num) 600 tabular;
   everything else = var(--font). No webfont: the ladder is tuned so SF Pro Display and Segoe UI Variable both hold it.
   h1       display  clamp(2.75rem, 1.5rem + 4.6vw, 5rem)     / 1.02, -.034em, text-wrap: balance
   h2       display  clamp(2rem, 1.35rem + 2.4vw, 3.125rem)   / 1.06, -.028em, balance
   feature  display  clamp(1.5rem, 1.2rem + 1vw, 2rem)        / 1.12, -.022em
   card h3  system   17px / 1.3, -.015em, 600
   lede     system   clamp(1.125rem, 1rem + .45vw, 1.3125rem) / 1.45, -.012em, --text-2
   body     17px / 1.55, -.011em        small 15px / 1.5        meta 13px / 1.4, 500
   numerals num, tabular-nums: 40px (proof strip), 44px (card headline on the site), 64–88px (finale)
   readouts mono 12–13px 500: paths, defaults keys, UUID prefixes, "48,211 files · 41.2 GB" in rows
   labels   13px 600 with font-variant-caps: all-small-caps and .04em tracking (styling, not ALL CAPS copy)
   eyebrow  12px 500 mono "01 · Storage planner", the index in --accent */
h1, h2, .display, .feature h3, .brand { font-family: var(--font-display); font-weight: 600; }
.num, .proof dd, .card-h b, .bar b { font-family: var(--font-num); font-weight: 600; font-variant-numeric: tabular-nums; }
```

Weight 600, never 700. The h1 keeps the family's `<mark>` highlighter on one phrase, in aqua (§4.1).

### 2.3 Space, widths and radii

- Widths: `.wrap` 1080px (content), `.wide` 1240px (stages), `.read` 720px (prose, FAQ, guides, what-it-does).
  Gutter 20px, 16px under 480.
- `main > section { padding-block: clamp(72px, 10vw, 136px) }`. Gaps are 12, 16, 24, 32, 48 or 64px.
  `scroll-padding-top: 84px`.
- Radii: `--r-s: 8px; --r-m: 12px; --r-l: 18px; --r-xl: 26px; --r-btn: 12px`.

### 2.4 Light and depth

Every shadow and hairline is the brand's ink at an alpha. `--ink` is slate-black (`10 26 40`) in light; in dark every
shadow is black at .5–.8 and the hairline becomes a 1px light rim. Never animate `box-shadow` or `filter`.

| Token | Role | Light recipe |
|---|---|---|
| `--hi` | lit top edge on raised surfaces | `rgb(255 255 255 / .9)`; dark `/ .07` |
| `--z1` | hairline plus contact: rows, pills, the header | `0 0 0 .5px ink/.12, 0 1px 2px ink/.05` |
| `--z2` | porcelain card | `inset 0 1px 0 var(--hi), 0 0 0 .5px ink/.12, 0 2px 4px ink/.04, 0 12px 28px -12px ink/.16` |
| `--shadow` | a floating object (the Storage Plan card, a window shot) | `0 0 0 .5px ink/.22, 0 2px 4px ink/.06, 0 24px 48px -16px ink/.30, 0 64px 128px -32px ink/.34` |
| `--cap` | key-caps (buttons, the crates, the note) | `inset 0 1px 0 var(--hi), 0 0 0 .5px ink/.18, 0 1px 2px ink/.08, 0 2px 0 var(--cap-side), 0 6px 14px -6px ink/.14` |
| `--slab` | the quay and the boat: lit top, a long aqua-tinted shadow on the water | `inset 0 1px 0 var(--hi), 0 0 0 .5px ink/.16, 0 18px 36px -14px rgb(var(--aqua-ink) / .28)` |

### 2.5 Tokens (the two `:root` blocks, ready to paste)

```css
:root {
  color-scheme: light dark;
  /* contrast(), light, worst of bg / bg-alt / card: text 15.06:1, text-2 5.26:1, accent 5.07:1;
     on-button on button 10.39:1, on hover 9.12:1. (Checked with build_site.py's formula, 2026-10-03.) */
  --bg: #f3f7f9; --bg-alt: #e7eef2; --card: #ffffff;                   /* cool paper: the quay at noon */
  --text: #0f1a20; --text-2: #52646e; --accent: #0b6f73;               /* aqua as text needs this depth on paper */
  --button: #4fe3d8; --button-hover: #3fd6ca; --on-button: #052421;     /* the mooring key-cap, near-black label */
  --line: #d6e0e6; --header: rgb(247 250 252 / .74); --hi: rgb(255 255 255 / .9);
  --ink: 10 26 40;                                                      /* slate-black: every shadow and hairline */
  --ok: #1a7f37; --bad: #d93025;                                        /* dots and symbols only, never measured text */
  /* The world: the quay by day. Slate above, cyan at the water line; the lamp is the key light. */
  --sky-top: #dfe8f3; --sky-low: #cdeef0; --water: #e2eff3; --water-ink: 10 26 40;
  --lamp: #2fd1c4; --lamp-core: #effffd; --glow: rgb(47 209 196 / .24); --pool: rgb(47 209 196 / .12);
  --aqua: #4fe3d8; --aqua-ink: 11 111 115; --mark: rgb(79 227 216 / .45);
  --grain: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='160' height='160'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3' stitchTiles='stitch'/%3E%3CfeColorMatrix values='.33 .33 .33 0 0 .33 .33 .33 0 0 .33 .33 .33 0 0 0 0 0 0 .04'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
  /* Key-caps, slabs and crates. */
  --cap-top: #ffffff; --cap-bot: #eef3f6; --cap-side: #c9d6de;
  --cap: inset 0 1px 0 var(--hi), 0 0 0 .5px rgb(var(--ink) / .18), 0 1px 2px rgb(var(--ink) / .08), 0 2px 0 var(--cap-side), 0 6px 14px -6px rgb(var(--ink) / .14);
  --cap-down: inset 0 1px 0 var(--hi), 0 0 0 .5px rgb(var(--ink) / .18), 0 1px 0 var(--cap-side);
  --slab-top: #fbfdfe; --slab-bot: #e9f0f4;
  --slab: inset 0 1px 0 var(--hi), 0 0 0 .5px rgb(var(--ink) / .16), 0 18px 36px -14px rgb(var(--aqua-ink) / .28);
  --z1: 0 0 0 .5px rgb(var(--ink) / .12), 0 1px 2px rgb(var(--ink) / .05);
  --z2: inset 0 1px 0 var(--hi), 0 0 0 .5px rgb(var(--ink) / .12), 0 2px 4px rgb(var(--ink) / .04), 0 12px 28px -12px rgb(var(--ink) / .16);
  --shadow: 0 0 0 .5px rgb(var(--ink) / .22), 0 2px 4px rgb(var(--ink) / .06), 0 24px 48px -16px rgb(var(--ink) / .30), 0 64px 128px -32px rgb(var(--ink) / .34);
  --glare: rgb(11 111 115 / .07);                                       /* white can't shine on white: an aqua spot */
  /* The Storage Plan card is an object with fixed colours in both schemes (role="img", not measured). */
  --card-top: #0b1620; --card-bot: #0f1b24; --card-text: #eaf2f5; --card-2: #9db0ba; --card-accent: #7eece4;
  --font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI Variable Text", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --font-display: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI Variable Display", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --font-num: ui-rounded, "SF Pro Rounded", var(--font);
  --font-mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, "Cascadia Mono", Consolas, monospace;
  --r-s: 8px; --r-m: 12px; --r-l: 18px; --r-xl: 26px; --r-btn: 12px;
  /* Motion and depth (docs/MOTION.md §1.2, §1.7). */
  --ease-out: cubic-bezier(.16, 1, .3, 1); --ease-spring: cubic-bezier(.34, 1.56, .64, 1); --ease-in-out: cubic-bezier(.65, 0, .35, 1);
  --t-fast: .16s; --t-base: .32s; --t-slow: .7s; --t-hero: 1.1s;
  --persp-scene: 1600px; --persp-card: 900px;
}
@media (prefers-color-scheme: dark) {
  :root {
    /* worst: text 14.24:1, text-2 7.19:1, accent 11.54:1; on-button on button 10.39:1, hover 9.12:1 */
    --bg: #0b1217; --bg-alt: #111a21; --card: #17222b;                 /* cool near-black, never #000: the quay at dusk */
    --text: #eaf2f5; --text-2: #9db0ba; --accent: #7eece4;
    --line: #22313a; --header: rgb(12 18 24 / .76); --hi: rgb(255 255 255 / .07); --ink: 0 0 0;
    --ok: #34d26b; --bad: #ff5a4f;
    --sky-top: #101c2c; --sky-low: #0e3740; --water: #0a1d25; --water-ink: 0 0 0;
    --lamp: #5fe8dc; --lamp-core: #f2fffd; --glow: rgb(79 227 216 / .28); --pool: rgb(79 227 216 / .10);
    --aqua: #4fe3d8; --aqua-ink: 79 227 216; --mark: rgb(79 227 216 / .30);
    --grain: /* the same SVG with the last matrix value .06 */;
    --cap-top: #22303a; --cap-bot: #17222b; --cap-side: #05090c;
    --cap: inset 0 1px 0 rgb(255 255 255 / .12), 0 0 0 1px rgb(255 255 255 / .08), 0 2px 0 var(--cap-side), 0 10px 20px -10px rgb(0 0 0 / .8);
    --cap-down: inset 0 1px 0 rgb(255 255 255 / .12), 0 0 0 1px rgb(255 255 255 / .08), 0 1px 0 var(--cap-side);
    --slab-top: #26343f; --slab-bot: #1a2630;
    --slab: inset 0 1px 0 rgb(255 255 255 / .10), 0 0 0 1px rgb(255 255 255 / .08), 0 18px 36px -14px rgb(0 0 0 / .8), 0 12px 28px -16px rgb(var(--aqua-ink) / .35);
    --z1: inset 0 1px 0 var(--hi), 0 0 0 1px rgb(255 255 255 / .07), 0 1px 2px rgb(0 0 0 / .6);
    --z2: inset 0 1px 0 var(--hi), 0 0 0 1px rgb(255 255 255 / .08), 0 14px 36px -12px rgb(0 0 0 / .8);
    --shadow: 0 0 0 1px rgb(255 255 255 / .1), 0 24px 48px -16px rgb(0 0 0 / .8), 0 64px 128px -32px rgb(0 0 0 / .9);
    --glare: rgb(255 255 255 / .09);
  }
}
```

`layout.html`: `<meta name="color-scheme" content="light dark">`, `theme-color` `#f3f7f9` and `#0b1217` (two metas
with `media`), no font preload. The card's fixed colours were checked too: `#EAF2F5` on `#0F1B24` 15.4:1, `#7EECE4`
12.5:1, `#9DB0BA` 7.8:1. The status colours on the page backgrounds: `--ok` 4.7:1 light / 9.5:1 dark, `--bad` 4.4:1
light (a symbol beside a word, never measured text) / 6.1:1 dark.

### 2.6 Shared components (the same CSS as the siblings; Outboard's tokens)

```css
/* Header pill: 48px, the only backdrop-filter on the page. */
.nav { height: 48px; max-width: 980px; padding: 0 6px 0 14px; border-radius: 999px; background: var(--header);
  -webkit-backdrop-filter: saturate(180%) blur(20px); backdrop-filter: saturate(180%) blur(20px);
  box-shadow: inset 0 1px 0 var(--hi), var(--z1); }
.brand { font-size: 17px; letter-spacing: -.02em; }

/* Section head: editorial, left-aligned; heading left, lede right on wide screens. */
.sec-head { display: grid; gap: 16px 64px; align-items: end; margin-bottom: clamp(40px, 5vw, 64px); }
@media (min-width: 900px) { .sec-head { grid-template-columns: 7fr 5fr; } }
.sec-head h2, .sec-head .lede { margin: 0; }

/* Primary button: a mooring key-cap. The fill darkens downward only, so the label keeps its measured contrast. */
.button { border-radius: var(--r-btn); min-height: 48px; padding: 0 22px; font: 600 16px/1 var(--font); color: var(--on-button);
  background: linear-gradient(var(--button), color-mix(in srgb, var(--button) 88%, #000));
  box-shadow: inset 0 1px 0 rgb(255 255 255 / .35), inset 0 -1px 0 rgb(0 0 0 / .18), var(--cap); }
.button.secondary { color: var(--text); background: linear-gradient(var(--cap-top), var(--cap-bot)); box-shadow: var(--cap); }
.button:active { translate: 0 1px; box-shadow: inset 0 1px 0 rgb(255 255 255 / .3), var(--cap-down); }

/* Porcelain card. */
.card { border-radius: var(--r-l); background: var(--card); box-shadow: var(--z2); }

/* Proof strip: hairlines only, no box; rounded numerals. */
.proof { display: grid; grid-template-columns: repeat(4, 1fr); gap: 0; border-block: 1px solid var(--line); }
.proof div { padding: 24px 28px 24px 0; } .proof div + div { border-left: 1px solid var(--line); padding-left: 28px; }
.proof dd { font: 600 clamp(28px, 3.2vw, 44px)/1 var(--font-num); letter-spacing: -.02em; font-variant-numeric: tabular-nums; }
@media (max-width: 720px) { .proof { grid-template-columns: 1fr 1fr; } .proof div:nth-child(odd) { border-left: 0; padding-left: 0; } }

/* Ledger: rules as a spec sheet, with a trailing mono chip. */
.rules { margin: 0; padding: 0; list-style: none; border-top: 1px solid var(--line); }
.rules li { display: grid; grid-template-columns: 1fr auto; gap: 4px 24px; padding: 20px 0; border-bottom: 1px solid var(--line); }
.rules h3 { margin: 0; font: 600 17px/1.3 var(--font); letter-spacing: -.015em; }
.rules p { margin: 0; color: var(--text-2); font-size: 15px; }
.rules code { grid-column: 2; grid-row: 1 / span 2; align-self: center; }

/* FAQ: one grouped panel with hairline rows. "+" turns into "×", no JS. */
.faq-list { border-radius: var(--r-l); background: var(--card); box-shadow: var(--z2); }
.faq-list details { padding-inline: 20px; } .faq-list details + details { border-top: 1px solid var(--line); }
.faq-list summary::after { content: "+"; transition: rotate var(--t-base) var(--ease-spring); }
.faq-list details[open] summary::after { rotate: 45deg; }

/* Real screens: a scroll-snap filmstrip (§2.8). */
.film { display: grid; grid-auto-flow: column; grid-auto-columns: min(560px, 84vw); gap: 24px; overflow-x: auto;
  scroll-snap-type: x mandatory; overscroll-behavior-x: contain; padding: 8px 20px 36px; scrollbar-width: thin; }
.film figure { margin: 0; scroll-snap-align: center; }
.film img { display: block; width: 100%; height: auto; border-radius: 10px; background: var(--bg-alt); box-shadow: var(--shadow); }
.film figcaption { margin-top: 12px; font-size: 13px; color: var(--text-2); }

/* Finale: the app icon standing on the quay by the lamp. */
.finale .icon { width: 128px; height: 128px; -webkit-box-reflect: below 6px linear-gradient(transparent 62%, rgb(0 0 0 / .22)); }   /* VERIFY inside a 3D parent in Safari */

/* Small-caps labels; chips (the word carries the meaning, the dot carries the colour). */
.label { font: 600 13px/1.3 var(--font); font-variant-caps: all-small-caps; letter-spacing: .04em; color: var(--text-2); }
.tag { display: inline-flex; gap: 6px; align-items: center; padding: 2px 9px; border-radius: 999px; font: 600 12px/1.4 var(--font); color: var(--text);
  background: color-mix(in srgb, var(--tag, var(--text-2)) 14%, transparent); box-shadow: 0 0 0 .5px color-mix(in srgb, var(--tag, var(--text-2)) 35%, transparent); }
.tag::before { content: ""; width: 6px; height: 6px; border-radius: 50%; background: var(--tag, var(--text-2)); }
.tag.aqua { --tag: var(--aqua); } .tag.ok { --tag: var(--ok); } .tag.bad { --tag: var(--bad); }

/* Health pill: the word first, the dot second; only Healthy gets the green dot. */
.pill { composes: none; } /* .pill is .tag with these words: "Healthy" .ok, "Drive away" .tag, "Held" .tag, "Conflict" .tag, "Needs attention" .tag */
```

Chips on the site: `.tag.aqua` "Official setting" and "Community method" are **not** coloured differently: both are
`.tag` (grey dot); `.tag.aqua` is reserved for "Moved" (a crate that has crossed) and "Your Outboard drive" (E17).
Risk chips "Rebuilds itself", "Large to download again", "Can't be replaced": all `.tag`, the word does the work.
Health pills: "Healthy" `.tag.ok`; "Drive away", "Held", "Conflict", "Needs attention" `.tag`. Nothing is ever `.tag.bad`
except the chip beside a failed row's symbol.

### 2.7 Accessibility media

```css
@media (prefers-contrast: more) { html[lang] { --grain: none; --glare: transparent; --glow: transparent; --pool: transparent; }
  .card, details, .nav, .button, .tag, .proof, .faq-list, .note, .slab, .crate, .report, .bar { box-shadow: 0 0 0 2px var(--text); } .finale .icon { -webkit-box-reflect: unset; } }
@media (prefers-reduced-transparency: reduce) { .nav { -webkit-backdrop-filter: none; backdrop-filter: none; background: var(--card); } }
@media (forced-colors: active) { .button, .card, details, .tag, .proof div, .nav, .note, .slab, .crate, .report, .outline, .bar i { border: 1px solid CanvasText; } }
@media print { html[lang] { color-scheme: light; --bg: #fff; --bg-alt: #fff; --card: #fff; --text: #000; --text-2: #333; --grain: none; }
  .site-header, .site-footer, .skip, .stage, .finale, .film { display: none; } }
```

`html[lang]` (0,1,1) beats `:root` (0,1,0) and does not match the checker's `:root\s*\{` regex. Also: visible 3px
aqua focus rings (`outline: 3px solid var(--accent)`, which is the text-depth aqua, so it is visible on paper), 44px hit
areas, content visible without JS, every image with `width`/`height`, no `style=""`.

### 2.8 Imagery

- **Hero:** an HTML scene (0 image bytes, sharp at any DPI, follows the scheme). Its copy is the `plan` demo scenario
  (BUILD_PLAN §9): "Your Mac could free up to 87 GB", crates "Xcode build data · 41 GB", "Ollama models · 30 GB",
  "iPhone backups · 16 GB". The quay bar reads "Macintosh HD · 245 GB · 9 GB free" and the boat bar "Outboard · 1 TB ·
  913 GB free" (fictional, decimal, consistent with the scenario; the demo owner may replace them with the scenario's
  own numbers, which win). Caption: "Illustration with sample data." and, as on every page, the not-affiliated line.
- **Real screens** below the fold at half their pixel width: Plan with the card, Drives with verdicts, the consent
  sheet, Progress, the Drive-away banner with the Health pills; `<picture>` with a dark `<source>`, `loading="lazy"`,
  `decoding="async"`, real `alt`. Ship the section only once `screens.yml` captures are committed to
  `site/static/shots/`, watermarked "Sample data".
- The README hero is the Plan capture over a strip of the sky gradient, composited by CI (BUILD_PLAN §9), and the README
  says so.

## 3. Home page, section by section (13 blocks)

1. **Header pill** (§2.6): 22px icon and wordmark; "How it works", "What it moves", "Guides", "Download" at 14px/500
   `--text-2`; a secondary key-cap "Source" and a 36px mooring "Download".
2. **Hero: the quay** (§4). Left copy, right scene, full-bleed band, no box.
3. **Proof strip** in rounded numerals: "0 · network calls", "0 · deletes: Trash only, after you confirm",
   "SHA-256 · every file compared before the switch", "1 · log, written before each step". The last gets a 6px `--ok`
   dot, the one LED. (Copy owner confirms wording against BUILD_PLAN §8.)
4. **"Where the space went."** (the problem, in users' words). `.sec-head` with the lede "A 256 GB Mac fills up with
   things you never chose to keep there." Then three `.card`s in a row, each a paraphrased forum question as the title
   (no quotation, no usernames, source and date in the meta line): "System Data is 381 GB. What is it?" (r/mac,
   2026-08-31, 912 points), "A 256 GB Mac mini plus a 1 TB SSD: smart or stupid?" (r/macmini, 2026), "Where do my
   Ollama models go, and why is my disk full again?" (the local-LLM question; competitors §3). Each card ends with one
   sentence of the honest answer: "Some of System Data is movable. Most of it is not." / "It works for some apps, with
   known methods. Outboard lists them." / "`~/.ollama/models`. Outboard measures it and can move it." A 1px aqua line
   under the row leads to block 5. Facts from `docs/next/app6-research-competitors-names.md` §3 in the Whydunit repo.
5. **"How a move works."** (the three claims, APP6 §0, safety-ux §10.1 C1 to C4). `.sec-head`, then a 4-item `.rules`
   ledger with mono chips: "It copies the folder to your drive, then compares every file with the original by size and
   SHA-256." `copy · compare`; "Only if every file matches does it switch the app over." `switch`; "Your original stays
   on your Mac, renamed, until you have tried the app and said it works." `.before-move`; "Each step is written to a
   log before it happens, so an interruption leaves your original where it was or puts it back." `journal`. Under it one
   line: "After you confirm, the original goes to the Trash. Space comes back when you empty it." A link to the
   how-it-works page. These four sentences are Education card 4 (BUILD_PLAN §8.1) split into a ledger; the copy owner
   keeps them identical to `Education.cards`.
6. **"What it moves. What it never moves."** Two objects: left, the crates as a site object (§4.4 `.crate`): the 7
   automated recipes as a depth-stacked column (name, source path in mono, method chip), the 8 guided as a second, muted
   column ("Photos moves it itself; Outboard shows the steps"); right, overlapping by −30px, a `.card` (`--shadow`,
   `data-tilt` 7°) titled "Never" with the 9 never cards as rows: "Mail, Safari, Messages, Notes" `TCC`; "Sandboxed
   containers" `containermanagerd`; "Anything in iCloud Drive" `sync`; "Homebrew" `/opt/homebrew`; "Your home folder";
   "Your whole Caches folder"; "`.app` bundles"; "Xcode simulator runtimes" `disk images`; "Docker and OrbStack data";
   "pnpm and uv stores". Each with its one-line reason from the catalogue (`Recipe.method = .never(reason:)`), read from
   `recipes.json`. The line under both: "Outboard knows 15 apps. More are added in updates; the list is data, and anyone
   can propose one."
7. **"The Drive Guard, explained."** `.sec-head` with the lede "While Outboard is running, a missing drive is announced
   and a note is put where the moved folder was." (C9: until a real-Mac run the site says "is designed to announce",
   no-claim-ok applies to nothing here; the copy owner picks the tense from `docs/VERIFY_LOG.md`.) Then the leave as a
   static site object: the quay slab with three outlines, each with its pinned note, the lamp dimmed, and beside it the
   note's text verbatim in a `.note` (§4.4): "Outboard moved this folder's contents to the drive "Outboard". The drive
   isn't connected, so this note is here instead. Nothing was deleted. When the drive is back, Outboard puts things back.
   If you see this by mistake, open Outboard and look at the Drives tab." (`PlaceholderText.body`, exact.) Under it the
   three-row `.rules` ledger: "Ejected in Finder" → "a note is parked; when the drive is back, a quick check and a 200-file
   sample, then the link is put back" `park · unpark`; "Pulled out without ejecting" → "you are asked to check your files
   first; every unchanged file is compared" `Check and reconnect`; "Something new appeared where the folder was" →
   "nothing is touched; you choose" `Conflict`.
8. **"Honest limits."** A plain `.read` block, no card, with a 6-item list in body text: "Outboard can't stop you
   unplugging a drive or make that harmless." (Education card 5, bold in the app) · "The link points at nothing from the
   moment the drive disappears until the guard parks it: seconds while Outboard runs, and until the next launch when it
   doesn't." · "Apps that kept a file open on the drive need to be restarted after it returns." · "Time Machine won't back
   up the drive unless you add it." · "Outboard says nothing about speed; it doesn't measure it." · "Not yet tried on a
   real Mac." (`Names.notTriedMarker`, kept until a `docs/VERIFY_LOG.md` entry exists; the marker rule, G15). Facts:
   guard-tech §0 items 7 and 12, §5.3, §5.6; IDEA3 §4 item 5.
9. **Real screens.** The `.film` strip (§2.8). Caption: "Real screens, captured by CI from the app with sample data."
10. **FAQ.** Sticky head left (5), the grouped `.faq-list` right (7): "Does this make my drive work like internal
    storage?" (No. It moves the folders Outboard knows to the drive and points the app at them. The app still runs from
    your Mac.) · "What happens if I unplug the drive?" (links the guide G3) · "Why isn't Photos moved by Outboard?" (Photos
    moves its own library; Outboard shows Apple's steps and checks the drive) · "Why does it refuse my drive?" (spinning
    disk, exFAT, a network share, the Time Machine disk, a disk image: each with the reason) · "Is it really free?" ·
    "Why is the app unsigned?" · "What does "Not yet tried on a real Mac" mean?" (every automated move is hidden until a
    named tester has run it; the log is public).
11. **Download band:** the quay again (the lamp at the left, its pool on the water), the icon at 176px standing on the
    quay with its reflection, "Room to breathe. It's free." in display, the mooring key-cap "Download free", the
    requirements line "macOS 13 or later · Apple silicon and Intel · 6 MB", the SHA-256 line in mono, and the trust line.
12. **Source:** a `.card` row with the repository link as a secondary key-cap "View source", the licence, "Recipes are
    data: propose one with a pull request", and the CI line "Every push runs the safety checks and the banned-phrase
    check." (links the workflow file, not a badge).
13. **Footer:** the `--bg-alt` slab, a 0.5px ink hairline on top, mono column titles, the version tag, the official
    sources line, and the fixed line "Outboard is not affiliated with or endorsed by any app it lists."

(Blocks 4, 7 and 8 are Outboard's additions to the siblings' pattern; the proof strip, the ledger and the FAQ are the
shared shapes.)

## 4. Hero: the quay (the 3D product scene)

### 4.1 Copy, left, 5 of 12 columns (nothing here moves)

Eyebrow `<b>01</b> · Storage planner · macOS 13 or later` in 12px mono, the index in `--accent`; h1
`Big folders, <mark>moved alongside.</mark>`; the lede "Outboard finds the big folders apps keep on your Mac and, for
the apps where the method is known, moves them to an external SSD: copied, compared file by file, the original kept
until you say so, every step logged." (BUILD_PLAN §2 pitch, first sentence); then "When the drive is unplugged it tells
you and parks a note where the folder was."; the mooring key-cap "Download free" and the secondary "View source"; the
mono trust line "Free · Open source · No network · Nothing deleted without you"; under it, in 13px `--text-2`, the fixed
line "Not yet tried on a real Mac." while the marker rule holds.

```css
.hero h1 mark { color: inherit; padding: 0 .06em; background: linear-gradient(transparent 56%, var(--mark) 56% 90%, transparent 90%);
  -webkit-box-decoration-break: clone; box-decoration-break: clone; }
```

### 4.2 The scene, right, 7 of 12 columns, no box

The `.hero` section itself is the band: full-bleed, no radius, no border; its background is the dusk (slate at the top,
cyan at the water line, the water below). Back to front: the lamp (the key light) on its post at the far left of the quay,
the water plane, the quay slab at the left with its capacity bar and three outlines, the gangway running right and
slightly back, the boat slab at the right with its bar, the three crates on the boat (at rest they have crossed), the
tethers from each outline across the gangway to its crate, and the Storage Plan card in front at the right.

```html
<section class="hero dusk" aria-labelledby="hero-h">
  <div class="wide hero-grid">
    <div class="hero-copy">…§4.1…</div>
    <div class="stage" data-tilt>
      <div class="scene" id="hero-scene">
        <i class="water" aria-hidden="true"></i>                                   <!-- the plane everything stands on -->
        <div class="lamp" aria-hidden="true"><i class="lamp-glow"></i><i class="lamp-core"></i><i class="lamp-post"></i></div>   <!-- Z -200: the key light, the guard -->
        <div class="dock" aria-hidden="true">                                      <!-- Z 0: the quay, the gangway, the boat -->
          <div class="slab quay">
            <p class="bar-h"><span>Macintosh HD</span><b>9 GB free</b></p>
            <div class="bar"><i class="seg used"></i><i class="seg moved"></i><i class="seg free"></i></div>   <!-- used 158 · moved 87 (outlined) · free 9, of 245 -->
            <ul class="outlines">
              <li><i class="outline"></i><i class="tether"></i><em class="note"><span class="label">Note</span>Outboard moved this folder to "Outboard".</em></li>
              <li><i class="outline"></i><i class="tether"></i><em class="note"><span class="label">Note</span>Outboard moved this folder to "Outboard".</em></li>
              <li><i class="outline"></i><i class="tether"></i><em class="note"><span class="label">Note</span>Outboard moved this folder to "Outboard".</em></li>
            </ul>
          </div>
          <i class="gangway"></i>
          <div class="slab hull">
            <p class="bar-h"><span>Outboard</span><b>913 GB free</b></p>
            <div class="bar"><i class="seg moved"></i><i class="seg free"></i></div>                            <!-- 87 of 1,000 -->
          </div>
        </div>
        <ul class="crates" aria-hidden="true">                                     <!-- Z +40: the folders, on the boat at rest -->
          <li><span>Xcode build data</span><b>41 GB</b><em class="tag">Official setting</em></li>
          <li><span>Ollama models</span><b>30 GB</b><em class="tag">Community method</em></li>
          <li><span>iPhone backups</span><b>16 GB</b><em class="tag">Community method</em></li>
        </ul>
        <div class="report-wrap">                                                  <!-- Z +80 -->
          <figure class="report" id="hero-card" role="img" aria-label="Illustration with sample data: the Outboard Storage Plan card. Your Mac could free up to 87 GB: Xcode build data 41 GB, Ollama models 30 GB, iPhone backups 16 GB. Measured on this Mac. Nothing was moved. On the back: sizes are what these folders take on disk; space comes back when the originals are trashed and the Trash is emptied.">
            <div class="face front">
              <p class="card-brand"><svg aria-hidden="true"><use href="#i-mark"/></svg>Outboard<span class="tag aqua">Sample data</span></p>
              <p class="card-h">Your Mac could free up to <b>87 GB</b></p>
              <ul class="card-rows">
                <li><span>Xcode build data</span><b>41 GB</b><i class="rb"></i></li>
                <li><span>Ollama models</span><b>30 GB</b><i class="rb"></i></li>
                <li><span>iPhone backups</span><b>16 GB</b><i class="rb"></i></li>
              </ul>
              <p class="card-cov">Measured on this Mac. Nothing was moved.</p>
              <p class="card-prov"><span>everydayopen.github.io/outboard</span></p>
            </div>
            <div class="face back">
              <p class="card-foot">Sizes are what these folders take on disk. Space comes back when the originals are trashed and the Trash is emptied.</p>
              <p class="card-nc"><span class="label">Not counted</span>Photos library 212 GB: Photos moves it itself; Outboard shows the steps.</p>
            </div>
          </figure>
          <button class="button secondary report-flip" type="button" data-flip aria-controls="hero-card" aria-pressed="false" hidden>Turn the card over</button>
        </div>
        <button class="button dock-leave" type="button" data-sweep="Plug it back in" data-sweep-said="Sample: the drive left. 3 notes parked where the folders were; the lamp is dimmed." data-sweep-reset="Sample: the drive is back. The links are back; the lamp is lit." aria-controls="hero-scene" aria-pressed="false" hidden>Unplug the drive</button>
        <p class="sr-only" role="status" aria-live="polite" data-sweep-status></p>
      </div>
    </div>
  </div>
  <p class="caption">Illustration with sample data. Outboard is not affiliated with or endorsed by any app it lists.</p>
</section>
```

Both buttons are hidden until `motion.js` runs; without JS the picture is complete and still in the moored state. The
leave button sits under the dock (not over a drawn key-cap: nothing in this scene pretends to be a control), the flip
button under the card. The figure's `aria-label` describes both faces, so the flip changes nothing for assistive tech
beyond the button's `aria-pressed`; the leave announces through the live region. The notes' text is a shortened sample
of `PlaceholderText.body` (the full note is in block 7); it is `aria-hidden` here.

```css
.dusk { background: var(--grain), linear-gradient(var(--sky-top), var(--sky-low) 44%, var(--water) 44.5%); }
.hero-grid { display: grid; gap: 40px; align-items: center; }
@media (min-width: 900px) { .hero-grid { grid-template-columns: 5fr 7fr; } }
.stage { position: relative; min-height: 580px; perspective: var(--persp-scene); perspective-origin: 50% 36%; }
.scene { position: absolute; inset: 0; transform-style: preserve-3d; }
/* The water: a flat plane with the lamp's pool on it. The mask sits on this flat plane, never on the preserve-3d scene (MOTION §1.6). */
.water { position: absolute; left: -30%; right: -30%; bottom: -6%; height: 62%; transform-origin: 50% 0; transform: rotateX(78deg);
  background: radial-gradient(34% 40% at 16% 0, var(--pool), transparent 70%), repeating-linear-gradient(90deg, rgb(var(--water-ink) / .05) 0 1px, transparent 1px 96px);
  -webkit-mask-image: radial-gradient(70% 90% at 50% 0, #000 10%, transparent 72%); mask-image: radial-gradient(70% 90% at 50% 0, #000 10%, transparent 72%); }
/* The lamp: a point on a post at the quay's edge, far back. The only light. The glow is its own flat element so it can fade (opacity), never a box-shadow transition. */
.lamp { position: absolute; left: 7%; top: 18%; width: 24px; height: 160px; transform: translateZ(-200px); }
.lamp-post { position: absolute; left: 11px; top: 14px; width: 2px; bottom: 0; background: linear-gradient(rgb(var(--ink) / .5), transparent); }
.lamp-core { position: absolute; left: 6px; top: 6px; width: 12px; height: 12px; border-radius: 50%; background: radial-gradient(circle, var(--lamp-core) 0 30%, var(--lamp) 70%); }
.lamp-glow { position: absolute; left: -68px; top: -68px; width: 160px; height: 160px; border-radius: 50%; background: radial-gradient(circle, var(--glow) 0 18%, transparent 70%); }
/* The dock: the quay slab, the gangway and the boat slab on one plane; the boat is a longer slab set back a little. */
.dock { position: absolute; left: 4%; top: 30%; width: 92%; height: 300px; transform-style: preserve-3d; }
.slab { position: absolute; padding: 12px 14px 14px; border-radius: var(--r-l); background: linear-gradient(var(--slab-top), var(--slab-bot)); box-shadow: var(--slab); color: var(--text); font: 500 13px/1.2 var(--font); }
.slab::before { content: ""; position: absolute; inset: 0 var(--r-l) auto; height: 2px; border-radius: 1px; background: var(--hi); }   /* the lit top edge */
.quay { left: 0; top: 0; width: 44%; height: 220px; transform: translateZ(0); }
.hull { right: 0; top: 24px; width: 46%; height: 150px; transform: translate3d(0, 0, -30px); }
.gangway { position: absolute; left: 44%; top: 86px; width: 10%; height: 36px; border-radius: 6px; background: linear-gradient(90deg, var(--slab-bot), var(--slab-top)); box-shadow: var(--z1);
  transform-origin: 0 50%; transform: translateZ(-15px) rotateY(-8deg); }
.bar-h { display: flex; justify-content: space-between; margin: 0 0 8px; } .bar-h b { font-family: var(--font-num); font-variant-numeric: tabular-nums; }
/* The capacity bar: segments by bytes with a floor width; a moved segment is an outline, not empty space (the originals are kept). */
.bar { display: flex; gap: 3px; height: 14px; }
.bar .seg { border-radius: 5px; min-width: 24px; background: linear-gradient(var(--cap-top), var(--cap-bot)); box-shadow: 0 0 0 .5px rgb(var(--ink) / .14); }
.bar .seg.used { flex: 158; } .bar .seg.free { flex: 9; background: transparent; box-shadow: 0 0 0 .5px rgb(var(--ink) / .14) inset; }
.bar .seg.moved { flex: 87; background: repeating-linear-gradient(135deg, transparent 0 4px, rgb(var(--aqua-ink) / .25) 4px 6px); box-shadow: 0 0 0 1px var(--aqua) inset; }
.hull .bar .seg.moved { flex: 87; background: linear-gradient(var(--cap-top), var(--cap-bot)); box-shadow: 0 0 0 .5px rgb(var(--ink) / .14), inset 0 2px 0 var(--aqua); }
.hull .bar .seg.free { flex: 913; }
/* The outlines on the quay: where each crate stood; the tether runs from it to the crate; the note is pinned on the leave. */
.outlines { position: absolute; left: 14px; top: 64px; margin: 0; padding: 0; list-style: none; width: calc(100% - 28px); }
.outlines li { position: relative; height: 44px; margin-bottom: 10px; }
.outline { position: absolute; left: 0; top: 0; width: 100%; height: 36px; border-radius: var(--r-m); border: 2px dashed var(--accent); opacity: .55; }
.tether { position: absolute; left: 100%; top: 17px; width: var(--tl); height: 2px; border-radius: 1px; background: var(--aqua); transform-origin: 0 50%; transform: rotate(var(--ta)) scaleX(1); opacity: .9; }
.outlines li:nth-child(1) { --tl: 330px; --ta: -8deg; } .outlines li:nth-child(2) { --tl: 318px; --ta: 1deg; } .outlines li:nth-child(3) { --tl: 306px; --ta: 10deg; }
.note { position: absolute; left: 6px; top: 4px; padding: 4px 8px; border-radius: var(--r-s); background: linear-gradient(var(--cap-top), var(--cap-bot)); box-shadow: var(--cap); font: 500 11px/1.3 var(--font); color: var(--text-2); opacity: 0; }
.note .label { display: block; font-size: 10px; }
/* The crates: the folders on the boat, raised above the dock, depth-stepped. */
.crates { position: absolute; left: 50%; top: 23%; margin: 0; padding: 0; list-style: none; width: 44%; transform-style: preserve-3d; }
.crates li { position: absolute; left: 0; display: grid; grid-template-columns: 1fr auto auto; gap: 10px; align-items: center; width: 100%; padding: 10px 12px; border-radius: var(--r-m);
  background: linear-gradient(var(--cap-top), var(--cap-bot)); color: var(--text); font: 500 13px/1.2 var(--font); box-shadow: var(--cap);
  transform: translate3d(var(--dx), var(--dy), var(--dz)) scale(1); }
.crates li::before { content: ""; position: absolute; inset: 0 var(--r-m) auto; height: 2px; border-radius: 1px; background: var(--aqua); opacity: .9; }   /* the lit edge: aqua on every crate that crossed */
.crates b { font-family: var(--font-num); font-variant-numeric: tabular-nums; }
.crates li:nth-child(1) { --dx: 0px;   --dy: 0px;   --dz: 40px; }
.crates li:nth-child(2) { --dx: -8px;  --dy: 54px;  --dz: 28px; }
.crates li:nth-child(3) { --dx: -16px; --dy: 108px; --dz: 16px; }
/* The card: the front-most object, 300×158 (1200×630), fixed night colours in both schemes. */
.report-wrap { position: absolute; right: 2%; top: 4%; width: 300px; transform: translateZ(80px); perspective: var(--persp-card); }
.report { position: relative; margin: 0; aspect-ratio: 1200 / 630; transform-style: preserve-3d; border-radius: 12px; }
.report .face { position: absolute; inset: 0; padding: 14px 16px; border-radius: 12px; overflow: hidden; backface-visibility: hidden; -webkit-backface-visibility: hidden;
  background: linear-gradient(var(--card-top), var(--card-bot)); color: var(--card-text); font: 11px/1.35 var(--font); box-shadow: inset 0 1px 0 rgb(255 255 255 / .08), var(--shadow); }
.report .face::after { content: ""; position: absolute; left: 16px; width: 6px; height: 6px; bottom: 14px; border-radius: 50%; background: var(--card-accent); opacity: .9; }   /* the lamp printed on the card */
.report .back { transform: rotateY(180deg); }
.report.flipped { transform: rotateY(180deg); }
.card-brand { display: flex; gap: 6px; align-items: center; margin: 0 0 8px; font: 600 10px/1 var(--font); font-variant-caps: all-small-caps; letter-spacing: .06em; color: var(--card-2); }
.card-brand svg { width: 12px; height: 12px; color: var(--card-accent); } .card-brand .tag { margin-left: auto; color: var(--card-text); }
.card-h { margin: 0 0 8px; font: 600 16px/1.1 var(--font-display); letter-spacing: -.02em; } .card-h b { color: var(--card-accent); font-family: var(--font-num); }
.card-rows { margin: 0 0 8px; padding: 0; list-style: none; display: grid; gap: 4px; }
.card-rows li { display: grid; grid-template-columns: 110px 44px 1fr; gap: 8px; align-items: center; font-size: 11px; }
.card-rows b { font-family: var(--font-num); font-variant-numeric: tabular-nums; text-align: right; }
.card-rows .rb { height: 6px; border-radius: 3px; background: var(--card-accent); }
.card-rows li:nth-child(1) .rb { width: 100%; } .card-rows li:nth-child(2) .rb { width: 73%; } .card-rows li:nth-child(3) .rb { width: 39%; }   /* proportional to unrounded bytes */
.card-cov, .card-nc { margin: 0; color: var(--card-2); }
.card-prov { position: absolute; left: 30px; right: 16px; bottom: 10px; margin: 0; font: 500 9px/1.3 var(--font-mono); color: var(--card-2); }
.card-foot { margin: 0 0 10px; font: 600 12px/1.35 var(--font); }
.report-flip { position: absolute; left: 0; top: calc(100% + 12px); min-height: 0; padding: 8px 14px; font-size: 13px; }
.dock-leave { position: absolute; left: 4%; bottom: 8%; min-height: 0; padding: 10px 16px; font-size: 14px; transform: translateZ(2px); }
.report-flip[hidden], .dock-leave[hidden] { display: none; }
@media (max-width: 900px) { .report-wrap, .lamp-glow { display: none; } .dock { position: static; width: min(560px, 100%); height: auto; margin: 24px auto 0; } .crates { position: static; width: 100%; margin-top: 12px; }
  .crates li { position: static; transform: none; margin-bottom: 8px; } .dock-leave { position: static; margin-top: 12px; } .stage { min-height: 0; } }
```

**Planes** (4, within MOTION §1.2's cap): the lamp −200, the dock at 0 (the boat steps back to −30 and the gangway to
−15 inside it), the crates +40 (stepping down to +16), the card +80. The pointer tilts the whole scene up to 5°, which
parallaxes the crates against the boat and the card against the water: the depth cue a flat frame can't give.

**Sequence** (2.8 s once, then still), **the leave** (1.0 s on the button, reversible as **the return**) and **the
flip** (0.6 s on the card button) are specified in MOTION §2. Reduce Motion, print and no-JS show the moored state; the
buttons swap states without movement under Reduce Motion.

### 4.3 Inline glyphs (the page's sprite; neutral, no vendor marks)

`#i-mark` (the app mark: a rounded square with a shorter rounded bar beside it, joined by a short line, and a dot above
the square's near corner for the lamp, §7), `#i-ok` (the check in a circle), `#i-down` (download), and the class glyphs
`#k-build` (a hammer), `#k-model` (a cube), `#k-backup` (a phone), `#k-cache` (a stack of three lines), `#k-archive`
(a box with a lid), `#k-photos` (a picture frame), `#k-music` (a note), `#k-film` (a clapper), `#k-game` (a controller),
`#k-sdk` (a chevron bracket), `#k-never` (a hand), each a 24-viewBox stroke icon drawn to match the SF Symbols the app
uses (§6.1), so the replica and the CI captures agree.

### 4.4 Section recipes

- **Crates (`.crate`, the "What it moves" section):** the hero's `.crates` rules reused as a static column (`--dz` 0,
  `--dx` 0, 8px gaps), one per automated recipe, with the source path in mono `--text-2` on a second line and the
  method chip; the guided column uses `opacity: .72` and the chip "Guided"; `data-tilt` 5° on each column, not per
  crate. Under Reduce Motion, static.
- **Capacity bar (`.bar`, the hero slabs, the Drives replica and the how-it-works page):** one bar per drive, segments
  per folder with `flex` their bytes and `min-width: 24px` (lesson f), 5px radius, a 2px aqua lit edge on segments that
  were moved, the hatched outline for `.before-move` originals, `var(--cap-top)` fill otherwise; **labels never live
  inside segments**: a legend row below (`.bar-key`, 13px, "Used 158 GB · Kept until you confirm 87 GB · Free 9 GB"), so
  nothing truncates.
- **Readout rows** (the Plan replica, the never card's rows): title 15px 600, the `~` path in mono `--text-2`, the
  rounded size right-aligned, then `.tag`s for method and risk. A 3px aqua tick on the leading edge of a row that has
  been moved (`::before`, 10px inset), none on the others. Hairlines between rows, never cards.
- **Note (`.note`, the guard section):** the placeholder as an object: a `--bg-alt` sheet, 8px radius, a small-caps
  "Note" label, 13px body in `--text-2`, a 0.5px hairline, no shadow (it is a file, not a card); the full text verbatim.
- **Receipt** (the move copy): `--bg-alt`, 12px radius, 13px mono, `--text-2`, dots between clauses: "Re-checked right
  before the switch · the app not running · copied, then compared file by file · renamed, never deleted · every step in
  the journal · roll back until you confirm".
- **Download band:** `.finale .icon` from §2.6 standing on a `.water` copy's pool with the `.lamp` copy at the band's
  left.

## 5. Sub-pages

- **Download:** a 240px dusk band with the icon standing by the lamp, the h1, the mooring key-cap, the requirements
  line, three key-cap steps (Open the zip · Drag to Applications · Right-click, Open the first time: the Gatekeeper step,
  with the SHA-256 line), "Not yet tried on a real Mac." as plain text, and the official-sources line.
- **How it works (the safety ledger page):** the reading layout; the block-5 ledger in full, then the invariants from
  BUILD_PLAN §3 as a numbered `.rules` list with mono chips (`trashItem`, `fsync`, `lstat`, `SHA-256`, `0444`,
  `UUID`, `3 commands`), the "What it reads" / "What it never does" two-column ledger (reads: folder names and sizes in
  your Library and home dotfolders, mounted volumes and three read-only system commands, file contents only to hash them
  during a copy; never: no network, no deleting, no formatting, mounting or ejecting, no `launchctl`, no helper or root,
  nothing inside iCloud, no edit of your shell files: an environment line is shown as text to copy), and the never-list
  as a mono block. Prints clean.
- **What it moves:** the reading layout; the catalogue table from `recipes.json` (name, folder, method chip, risk chip,
  the missing-drive sentence, the confidence word, the beta step, "Not yet tried on a real Mac." per unverified recipe),
  the guided table with the vendor step counts, the never cards; "Propose a recipe" as a mooring key-cap linking the
  issue template; the line "Outboard knows 15 apps."
- **Guides** (`/guides/`, index plus three; the `<!--meta {…}-->` first line, `article.read.prose.guide`, an eyebrow
  `G1 · Guide · Checked <date> · macOS`, a `.summary` box "The short answer" with three numbered sentences, `h2`s with
  ids, a sources list at the end, the not-affiliated line). Facts come from `docs/next/app6-research-recipes.md`,
  `app6-research-guard-tech.md`, `app6-research-safety-ux.md` and `IDEA3.md` in the Whydunit repo; every number and
  quote names its source and date; anything a real Mac has not confirmed says so. The copy owner fills the prose; the
  outlines are fixed here:
  - **G1 "How to move Xcode DerivedData to an external drive."** Short answer: Xcode has its own setting for it
    (Settings › Locations › Derived Data › Custom); DerivedData rebuilds itself, so the cost of losing it is build time;
    two breakages are documented on external drives, so try it and keep the original until you are sure. Sections: *What
    DerivedData is* (build products and indexes under `~/Library/Developer/Xcode/DerivedData`; sizes of 5 to 100 GB are
    common in community reports; it is regenerable); *The official way* (the Locations pane; the same setting as the
    `com.apple.dt.Xcode` defaults key `IDECustomDerivedDataLocation`; the companion key `IDEDerivedDataPathMode`, whose
    value for an absolute path is **not documented anywhere the research could read**: the site must not print a value;
    the per-run alternative `xcodebuild -derivedDataPath`); *Quit first* (Xcode, Simulator, Instruments and any
    `xcodebuild`); *Known breakages* (framework tests on "My Mac" fail with exit code 9 when DerivedData is on an
    external drive and Xcode gives no warning: Apple Developer Forums thread 812321; SwiftPM build plugins fail with
    "Operation not permitted" with a custom external DerivedData path: Xcode 15 / Swift 5.9 report; the workaround in
    both is `xcodebuild` from Terminal or the default location); *What Outboard does* (copies, compares every file by
    size and SHA-256, writes the same setting, keeps `DerivedData.before-move` until you confirm; when the drive is away
    and Xcode is closed it writes the setting back (`revertSetting`); it is a B1 recipe: hidden until a tester's
    `docs/VERIFY_LOG.md` entry, and the sheet says "Not yet tried on a real Mac."); *Archives are different* (`Archives`
    hold shipped builds and dSYMs and can't be replaced; the key is `IDECustomDistributionArchivesLocation`, read by
    fastlane; Outboard treats it as "Can't be replaced" and ships it last, B4); *What can't move* (simulator runtimes
    are managed disk images; Apple's offload is `xcodebuild -exportPlatform`, cold storage). Ends with the capacity bar
    for the sample Mac.
  - **G2 "Can I run Ollama models from an external SSD?"** Short answer: yes, three ways, and the catch is the unplug:
    the Ollama app starts with an empty internal store when the path it was given is missing, so the models look gone
    and the next pull fills the internal disk. Sections: *Where the models live* (`~/.ollama/models`: blobs and
    manifests; never move `~/.ollama` itself, which holds keys, history and logs); *The app's own setting* (Ollama's
    Settings has a "Model location" field; the value lives in the app's own database, so Outboard never writes it: a
    guided card); *The environment variable* (`OLLAMA_MODELS`, documented in Ollama's FAQ; for the Mac app it must be set
    with `launchctl setenv` and the app restarted, and that value does not survive a reboot unless something re-applies
    it: user-level source; Outboard never edits shell or login files and shows the line as text to copy); *The link*
    (replacing `~/.ollama/models` with a link to the copy: the community method Outboard automates, "Large to download
    again"); *What happens when the drive is away* (from the app's source at v0.35.1, 2026-09-29: the server exports
    `OLLAMA_MODELS` only if the path can be read; otherwise it logs "models path not accessible, using default" and
    starts with the default store; with Outboard running a read-only note is parked at the path so the app reports an
    error instead of starting fresh: **whether Ollama does that with a note in the path is VERIFY**, and the guide says
    so); *Quit first* (the app, including its menu bar item, and any `ollama` command; the app may relaunch itself);
    *Hugging Face, llama.cpp and LM Studio aside* (`HF_HUB_CACHE`, not `HF_HOME`, which holds the token; relative links
    inside the cache; LM Studio's models directory is a guided card). No sentence about speed. Ends with the consent
    sheet's "What to know" bullets verbatim from the catalogue.
  - **G3 "What happens if I unplug an external drive that holds app data?"** Short answer: every way of putting app
    data on a drive fails open when the drive is missing; the app does its first-launch thing on the internal disk; the
    drive goes missing more often than people expect, and no app can make that harmless (`no-claim-ok` on the line that
    says Outboard never claims it). Sections: *What apps do* (Photos "creates a new empty library" in Apple's words;
    Ollama starts an empty store; Docker will not start; a dangling link fails closed for opening but not for apps that
    delete and recreate); *How drives go missing* (sleep: forum-grade evidence across macOS versions, Apple's note 101847
    is about Mac Pro (2023) internal SATA drives and not evidence about external ones; not mounted yet at login; a laptop
    unplugged on purpose, which is normal use; renamed, reformatted or replaced, and a second drive with the same name
    mounting as "Name 1" when a stale `/Volumes/Name` folder exists; the drive dies, and Time Machine excludes external
    drives by default); *What Outboard does while it runs* (after a 5 s debounce the link is moved into its own folder
    and a read-only note is put where the folder was, the note's text verbatim; for Xcode build data the setting is
    written back when Xcode is closed; on a clean eject and return: the drive's UUID and sentinel are checked, a quick
    check against the manifest, a 200-file hash sample, then the link is put back; after an unplug without ejecting:
    "Check and reconnect" compares every file that has not changed since it was copied); *What it cannot do* (the window
    between unplug and park is seconds while Outboard runs and unbounded when it isn't; it cannot veto an eject; apps that
    kept a file open on the drive need a restart, since their descriptors point at the old mount: by reasoning, not from
    a fetched source; macOS may block an app's access to a removable volume (TCC "Removable Volumes"), which Outboard
    shows as "macOS blocked access to the drive", never as "drive missing"); *What to do* (eject in Finder before
    unplugging; a direct cable rather than a hub; the display-off sleep setting; Outboard doesn't change power settings;
    add the drive to Time Machine if it holds anything you can't replace; prefer an encrypted APFS volume for backups).
    Lines that quote a banned phrase to say the app never uses it carry `no-claim-ok`.
- **Changelog:** release `.card`s with a 2px aqua rail on the left and the version in a mono tag.
- **404:** the dusk band with the lamp and an outline with no tether: "Nothing moored here." (copy owner to confirm).
- **`llms.txt`:** plain text, the pitch, the trust box, the "will never say" list marked `no-claim-ok`, the
  not-affiliated line, "Not yet tried on a real Mac." while the marker rule holds.

## 6. The app (macOS 13; macOS 14+ and 26 only in `Compat.swift`). Written, not compiled.

**Material hierarchy, in order:** the system window (sidebar and toolbar stay system; on macOS 26 the SDK makes them
glass by itself) → `Dusk` (a static wash: the sky along the top edge of stage screens, the lamp's pool at the top left)
→ porcelain surfaces for content groups → controls (glass only on `barSurface()`). One accent; method, risk and health
only as a pill word plus dot; status only as symbol tint. One lifted object per screen. Nothing moves at idle.

### 6.1 `App/DesignSystem/Tokens.swift`

Copy Aftertaste's `Space`, `Radius` (`plate = 18, tile = 14, row = 12, chip = 8, card = 12`), `Motion` (with `stagger`
and `delay(_:_:)`), `surface`, `OnFloor`, `Horizon`, `Metric`, `Tag`, `KeyCapStyle`, `HoverTilt`, `flip`, `FlipFaces`,
`CopyButton`, `copyToPasteboard`, `well`, `lifted`, `terminal`, `sidebarSurface`, `FlowLayout`, `SheetHeader` verbatim
(the Aftertaste `Tier`/`ResidueKind`/`TrashStatus` extensions are not copied), then change only these:

```swift
/// docs/DESIGN.md §1, §6. Aqua is the one accent ("the line to the drive"); green only for all matched, Healthy and a
/// moved row's check; red only on a failed row's symbol. Slate and cyan exist only inside `Dusk` and the card: they are
/// sky and water, not UI.
enum Brand {
    /// Slate-black: the soft shadow under porcelain surfaces is tinted with it, never neutral grey (rule 3).
    static let ink = Color(red: 0.039, green: 0.102, blue: 0.157)                                     // #0A1A28
    /// The mooring key-cap fill and every aqua fill. Near-black text on it (10.4:1).
    static let aqua = Color(red: 0.310, green: 0.890, blue: 0.847)                                    // #4FE3D8
    static let onAqua = Color(red: 0.020, green: 0.141, blue: 0.129)                                  // #052421
    /// Aqua as text, a symbol, the tether or the outline: readable on paper and on the dusk quay (5.1:1 / 11.5:1).
    static let aquaInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.494, green: 0.925, blue: 0.894, alpha: 1)                            // #7EECE4
            : NSColor(srgbRed: 0.043, green: 0.435, blue: 0.451, alpha: 1)                            // #0B6F73
    })
    /// The lamp. Never on a control, a chip or text.
    static let lamp = Color(red: 0.373, green: 0.910, blue: 0.863)                                    // #5FE8DC
    static let skyTop = Color(red: 0.063, green: 0.110, blue: 0.173)                                  // #101C2C
    static let skyLow = Color(red: 0.055, green: 0.216, blue: 0.251)                                  // #0E3740
}

/// The dusk behind stage screens (Plan, Drives, the consent and result sheets, first run, About): the plain window plus
/// the sky along the top edge and the lamp's pool at the top left, as a static wash. Increase Contrast gets the plain
/// window. Drawn once per size. (Aftertaste's `Dawn` with the horizon replaced by the lamp.)
struct Dusk: View {
    var strength = 1.0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = scheme == .dark
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
            if contrast != .increased {
                VStack(spacing: 0) {
                    // Slate to cyan, fading into the window: the sky at dusk, or by day at a quarter strength.
                    LinearGradient(colors: [Brand.skyTop.opacity((dark ? 0.9 : 0.12) * strength), Brand.skyLow.opacity((dark ? 0.7 : 0.14) * strength), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 220)
                    Spacer(minLength: 0)
                }
                // The lamp's pool: one key light per scene (rule 2). A soft radial at the top left; the lamp itself is `GuardLamp`
                // on the Drives screen, never drawn in the wash.
                RadialGradient(colors: [Brand.lamp.opacity((dark ? 0.22 : 0.14) * strength), .clear], center: .center, startRadius: 0, endRadius: 260)
                    .frame(width: 520, height: 520)
                    .offset(x: -120, y: -200)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The one prominent button per screen (Move 41 GB, Confirm and move to Trash, Check and reconnect, Continue): a mooring
/// key-cap with near-black text, a lit top edge and a slate lip; a press sinks 1pt. No glow: the light comes from the
/// lamp, not the button. `.keyboardShortcut(.defaultAction)` still works where BUILD_PLAN §8 allows it (never for an
/// irreplaceable recipe's primary button). Replaces .borderedProminent there.
struct MooringButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Plate(configuration: configuration) }

    private struct Plate: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            let down = configuration.isPressed && !reduceMotion
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(Brand.onAqua)
                .padding(.horizontal, 18)
                .frame(minHeight: 30)
                .background(shape.fill(Brand.aqua).overlay(shape.fill(LinearGradient(colors: [.clear, Color.black.opacity(0.12)], startPoint: .top, endPoint: .bottom))))
                .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.5), Color.black.opacity(0.22)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .background(shape.fill(Color(red: 0.11, green: 0.42, blue: 0.40)).offset(y: down ? 0.5 : 1.5))   // the lip; its bottom stays put
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.4)
                .offset(y: down ? 1 : 0)
                .animation(Motion.pop, value: configuration.isPressed)
        }
    }
}

extension Health {
    /// The pill word is `displayName` (Model). Health is carried by the word, never by colour alone (§1.1 rule 4):
    /// only Healthy gets the green dot; every other state gets the neutral dot. Never red: a problem is a fact to read.
    var tint: Color { self == .healthy ? .green : .secondary }
}

extension MethodKind {
    /// Neutral SF Symbols, never vendor logos (BUILD_PLAN §8). VERIFY each in the SF Symbols app: availability macOS 13 or earlier.
    var symbol: String {
        switch self {
        case .defaults: return "slider.horizontal.3"       // Official setting
        case .symlink: return "link"                      // Community method (a symbol name; not a function: G1 flags `link(` with a parenthesis only)
        case .guided: return "list.number"                // Guided
        case .never: return "hand.raised"                 // Not offered
        }
    }
}

extension RecipeID {
    /// One neutral symbol per catalogue entry; unknown ids get a folder. VERIFY each on macOS 13.
    var symbol: String {
        switch self {
        case "xcode-deriveddata": return "hammer"
        case "xcode-archives": return "archivebox"
        case "ollama-models", "huggingface-hub-cache", "llamacpp-cache", "lmstudio-models": return "cube"
        case "npm-cache": return "shippingbox"
        case "ios-device-backups": return "iphone"
        case "mas-large-apps": return "bag"
        case "photos-library": return "photo.on.rectangle"
        case "music-media-folder": return "music.note"
        case "final-cut-library": return "film"
        case "logic-sound-library": return "pianokeys"
        case "steam-library": return "gamecontroller"
        case "android-sdk": return "chevron.left.forwardslash.chevron.right"
        default: return hasPrefix("never-") ? "hand.raised" : "folder"
        }
    }
}

extension StepStatus {
    /// Activity rows and the result sheet: a symbol in a status colour, the word beside it. Red only here, only on failed.
    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .refused: return "hand.raised"
        case .mismatch: return "arrow.left.arrow.right.circle"
        case .interrupted: return "pause.circle"
        case .failed: return "xmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .ok: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}

extension BannerKind {
    /// A banner's leading symbol: neutral, secondary tint, never red (MOTION §1.1 rule 3). The text says what happened.
    var symbol: String {
        switch self {
        case .ejected, .locked: return "externaldrive.badge.minus"
        case .removedUnclean: return "externaldrive.badge.exclamationmark"
        case .backClean, .backChecked, .driveRenamed: return "externaldrive.badge.checkmark"
        case .appRunning, .revertPending: return "app.badge"
        case .sampleMismatch, .conflict, .foreignLink, .suspect, .differentDriveSameName, .driveChanged: return "questionmark.folder"
        case .needsPermission: return "lock"
        case .journalNotWritable: return "doc.badge.ellipsis"
        }
    }
}
```

`Tag(text, tint:)` is unchanged; `Tag(health.displayName, tint: health.tint)` is the Health pill;
`Tag(recipe.kind.displayName)` and `Tag(recipe.riskClass.displayName)` are the method and risk chips (neutral tint; the
word carries the meaning). The `Metric` default design is `.rounded` (sizes and counts are rounded; mono is for paths,
defaults keys and UUID prefixes only).

**Type in the app:** SF only. The Plan total `.system(size: 40, weight: .semibold, design: .rounded)` with
`.monospacedDigit()` and `.contentTransition(.numericText())` (macOS 13); stage headlines `.system(size: 28, weight:
.semibold)` `tracking(-0.5)`; plate titles 22pt semibold; rows 13pt with a 12pt secondary line; paths, keys and UUID
prefixes `.system(.caption, design: .monospaced)`; small-caps labels only on metric labels and section headers. Radii 18
(plates), 14 (tiles, crates), 12 (rows, inner groups), 8 (chips), 12 for the mooring button.

### 6.2 `App/DesignSystem/Compat.swift` (the only file with `#available`)

Aftertaste's `barSurface()`, `capsuleBorder()`, `bounce(on:)` and `activateApp()` verbatim:

```swift
extension View {
    /// Glass on the controls layer only (the consent sheet's action bar, the progress bar, the banner strip). macOS 26 glass; below it the system thin material.
    func barSurface() -> some View { /* Tirekick's: if #available(macOS 26, *) glassEffect else .background(.thinMaterial) */ }
    /// A capsule border on the secondary toolbar buttons ("Rescan"); macOS 14's buttonBorderShape, nothing below.
    func capsuleBorder() -> some View { /* if #available(macOS 14, *) buttonBorderShape(.capsule) */ }
    /// One bounce of a symbol on macOS 14+ (the Healthy check when a relocation becomes Healthy, the all-matched check); nothing on 13 and under Reduce Motion.
    func bounce(on value: Int, reduceMotion: Bool) -> some View { /* if #available(macOS 14, *), !reduceMotion { symbolEffect(.bounce, value: value) } */ }
    /// Brings the app forward (the menu bar item's "Open Outboard"). `NSApp.activate()` is macOS 14.
    func activateApp() { if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) } }
}
```

The macOS 13 path is the full design. macOS 14 adds the symbol bounce on the Healthy check and the capsule border on
"Rescan"; macOS 26 adds glass on the three bars. Nothing else is gated.

### 6.3 `CapacityBar.swift`, `GuardLamp.swift`, `Tether.swift`, `Moored.swift`: the signature objects

```swift
/// One proportional bar per drive (or per Plan): a segment per folder, width by bytes with a floor so small folders
/// stay legible, an aqua lit edge on segments that have been moved, a hatched outline for originals kept as
/// `.before-move`. Labels never live inside segments (lesson f): the legend row under the bar carries name and size.
/// Pure fills and strokes that `ImageRenderer` can draw: `PlanCardView` draws the card's rows with the same segment code.
struct CapacityBar: View {
    enum Fill { case used, moved, kept, free }
    struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: UInt64
        let fill: Fill
    }
    let segments: [Segment]
    var height: CGFloat = 14
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let total = max(1, segments.reduce(0) { $0 + $1.bytes })
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: Space.xs) {
            GeometryReader { g in
                let gap: CGFloat = 3, minW: CGFloat = 24
                let free = max(0, g.size.width - gap * CGFloat(max(0, segments.count - 1)) - minW * CGFloat(segments.count))
                HStack(spacing: gap) {
                    ForEach(segments) { s in
                        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
                        ZStack {
                            switch s.fill {
                            case .free:
                                shape.strokeBorder(Color.primary.opacity(dark ? 0.14 : 0.14), lineWidth: 0.5)
                            case .kept:
                                // The original, renamed and kept until the user confirms: an outline, not empty space (§1 decided 4).
                                Hatch().stroke(Brand.aquaInk.opacity(0.35), lineWidth: 1.5).clipShape(shape)
                                shape.strokeBorder(Brand.aquaInk.opacity(0.8), lineWidth: 1)
                            case .used, .moved:
                                shape.fill(contrast == .increased ? AnyShapeStyle(.quaternary)
                                           : AnyShapeStyle(LinearGradient(colors: dark ? [Color(red: 0.133, green: 0.188, blue: 0.227), Color(red: 0.090, green: 0.133, blue: 0.169)]
                                                                                        : [Color(red: 1, green: 1, blue: 1), Color(red: 0.933, green: 0.953, blue: 0.965)],
                                                                          startPoint: .top, endPoint: .bottom)))
                                    .overlay(alignment: .top) { Capsule().fill(s.fill == .moved ? Brand.aqua : Color.white.opacity(dark ? 0.12 : 0.9)).frame(height: 2).padding(.horizontal, 4).padding(.top, 1) }
                                    .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 1 : dark ? 0.10 : 0.08), lineWidth: contrast == .increased ? 1 : 0.5))
                            }
                        }
                        .frame(width: minW + free * CGFloat(s.bytes) / CGFloat(total))
                    }
                }
            }
            .frame(height: height)
            // The legend: every segment named, so no segment needs a label it cannot fit.
            Text(segments.map { "\($0.label) \(Format.bytes($0.bytes))" }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Capacity: " + segments.map { "\($0.label) \(Format.bytes($0.bytes))" }.joined(separator: ", "))
    }

    /// 45° hatching for a kept original. A `Shape`, so it draws in `ImageRenderer` too.
    private struct Hatch: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            var x = r.minX - r.height
            while x < r.maxX {
                p.move(to: CGPoint(x: x, y: r.maxY))
                p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                x += 6
            }
            return p
        }
    }
}

/// The lamp: the guard indicator on the Drives screen and in the first-run card 5. Lit while every relocation on the
/// drive is Healthy, dimmed ("parked") otherwise; the word beside it carries the state (VoiceOver reads it). A colour and
/// opacity swap under `Motion.pop`, shown under Reduce Motion too (it is a state, not movement). It never pulses.
struct GuardLamp: View {
    var lit: Bool
    var label: String                                        // "Guard on · drive attached" / "Guard on · drive away" / "Guard off"
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: Space.xs) {
            ZStack {
                if contrast != .increased {
                    Circle().fill(RadialGradient(colors: [Brand.lamp.opacity(lit ? 0.45 : 0.10), .clear], center: .center, startRadius: 0, endRadius: 18))
                        .frame(width: 36, height: 36)
                }
                Circle().fill(lit ? Brand.lamp : Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
            }
            .frame(width: 36, height: 36)
            .animation(Motion.pop, value: lit)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// The tether: the line from a folder's outline on the Mac to its copy on the drive, drawn once when a move reaches
/// Swapped (MOTION §3.2) and fading when the drive is away. One animatable `progress` (0 = not drawn, 1 = drawn).
struct Tether: Shape {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + r.width * progress, y: r.midY))
        return p
    }
}

/// A relocation row's leading object: the dashed outline (Aftertaste's `DashedOutline`, aqua) with a short tether to
/// the right. `drawn` is 1 when the relocation is Healthy, 0 when the drive is away (the tether fades with it).
struct TetheredOutline: View {
    var drawn: Double
    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Brand.aquaInk)
                .frame(width: 22, height: 16)
            Tether(progress: drawn).stroke(Brand.aquaInk, style: StrokeStyle(lineWidth: 1.5, lineCap: .round)).frame(width: 14, height: 16)
        }
        .opacity(0.9)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Layered depth for a recipe card: two faint rims offset under the surface, so a crate reads as a short stack of
    /// slabs (the quay and the boat). Static, pure strokes, no shadow on the layers themselves. (Aftertaste's `layered()`.)
    func moored() -> some View { modifier(Moored()) }
}

private struct Moored: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.plate, style: .continuous)
        let dark = scheme == .dark
        return content.background {
            if contrast != .increased {
                ZStack {
                    shape.fill(dark ? Color.white.opacity(0.03) : Color.white.opacity(0.6)).overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.08 : 0.06), lineWidth: 0.5)).padding(.horizontal, 12).offset(y: 6)
                    shape.fill(dark ? Color.white.opacity(0.04) : Color.white.opacity(0.8)).overlay(shape.strokeBorder(Color.primary.opacity(dark ? 0.09 : 0.07), lineWidth: 0.5)).padding(.horizontal, 6).offset(y: 3)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// The parked note as an object (the Drives screen's Drive-away row, first-run card 5, the edge states): a small sheet
/// with a small-caps "Note" label and the note's first sentence, `--bg-alt` fill, a hairline, no shadow (it is a file).
struct NoteCard: View {
    var text: String                                          // PlaceholderText.body(driveName:) or its first sentence
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Note").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.s)
        .background(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}
```

`Motion.stagger = 0.045` is Aftertaste's value. A list of relocation rows therefore settles within 0.36 s of stagger
plus a 0.45 s spring: under 1 s for the whole list (BUILD_PLAN §8).

### 6.4 `MenuBarIcon.swift` (the item exists once any relocation exists; BUILD_PLAN §1)

- **The glyph** (template): the mark at 16×16 (§7): a rounded square (the Mac, 1.5pt stroke, 3pt radius) and a shorter
  rounded bar to its right (the drive), joined by a 2pt line at mid height (the tether), with a 2pt solid dot above the
  square's top-left corner (the lamp). Drawn with `Canvas` into an `ImageRenderer` once at launch, `isTemplate = true`,
  so it follows the menu bar's appearance.
- **The dot** (`GuardSnapshot.showsAttentionDot`): when any relocation is Drive away or Held, a second template image
  with the tether gap open (the line stops short of the bar) and the lamp dot hollow. No number, no colour: the
  accessibility label carries the state ("Outboard: 1 drive away"), and the menu's first row says it in words.

```swift
enum MenuBarIcon {
    static let moored = glyph(attention: false)
    static let attention = glyph(attention: true)

    private static func glyph(attention: Bool) -> NSImage {
        let r = ImageRenderer(content: Mark(attention: attention))
        r.scale = 2
        let image = r.nsImage ?? NSImage(size: NSSize(width: 16, height: 16))
        image.isTemplate = true
        return image
    }

    private struct Mark: View {
        var attention: Bool
        var body: some View {
            Canvas { ctx, _ in
                var mac = Path()
                mac.addRoundedRect(in: CGRect(x: 0.75, y: 4.75, width: 6.5, height: 9), cornerSize: CGSize(width: 2, height: 2))
                ctx.stroke(mac, with: .color(.black), lineWidth: 1.5)                                            // the Mac
                var drive = Path()
                drive.addRoundedRect(in: CGRect(x: 11.25, y: 6.25, width: 4, height: 6), cornerSize: CGSize(width: 1.5, height: 1.5))
                ctx.stroke(drive, with: .color(.black), lineWidth: 1.5)                                          // the drive
                var line = Path()
                line.move(to: CGPoint(x: 7.25, y: 9.25))
                line.addLine(to: CGPoint(x: attention ? 9 : 11.25, y: 9.25))
                ctx.stroke(line, with: .color(.black), lineWidth: 1.5)                                           // the tether (open when attention)
                let lamp = Path(ellipseIn: CGRect(x: 1, y: 1, width: 3, height: 3))
                if attention { ctx.stroke(lamp, with: .color(.black), lineWidth: 1) } else { ctx.fill(lamp, with: .color(.black)) }   // the lamp
            }
            .frame(width: 16, height: 16)
        }
    }
}
```

### 6.5 Screens (BUILD_PLAN §7.1; each reachable in demo mode)

**Plan** (`PlanView`, app-shell; the window's home, 820×600 min). `NavigationSplitView` with the sidebar rows Plan,
Drives, Activity (system `List`, SF Symbols `square.grid.2x2`, `externaldrive`, `list.bullet.rectangle`). The detail's
top is a stage over `Dusk(strength: 0.8)`: the **Storage Plan card preview** (`PlanCardView` at 480×252pt, `lifted()`,
`HoverTilt(max: 4, glare: true)`: the one lifted object) beside a `Metric` column (`Metric("Could free", "87", unit:
"GB")` in 40pt rounded with `numericText`, `Metric("Measured", "4", unit: "folders")`, and the measured-at line in 13pt
secondary); under the card the bar "Copy as text", "Copy as image", "Save PNG…" as `KeyCapStyle`, and "Rescan" (⌘R,
`.bordered`, `capsuleBorder()`). Then the **ranked list** as one `.surface(18)` + `.moored()` per group, in
`StoragePlan.items` order: a *Movable* group (rows: the recipe symbol in a 20pt neutral `well`, the name 13pt semibold,
the `~` path in `.caption.monospaced` secondary `truncationMode(.middle)`, the size rounded `monospacedDigit` right
("41 GB", "at least 3 GB", "not measured"), the method `Tag` and the risk `Tag`, a 12pt secondary line with
`missingDriveEffect`, and a trailing `.bordered` "Move…"; an unverified row adds "Not yet tried on a real Mac." in 12pt
secondary, no symbol), a *Guided* group (the same row with "Show steps" and the muted line "Photos moves it itself;
Outboard shows the steps."), a *Not measured* group ("not measured (needs Full Disk Access)" with the text steps behind a
disclosure and a `.bordered` "Open System Settings", never nagged), and the *Never* group as compact rows (the hand
symbol, the name, the reason in 12pt secondary, no button). Between the movable group and the rest the fixed line "Some
of System Data is not movable by any app." in 13pt secondary. Keyboard: Full Keyboard Access reaches every row and
button; VoiceOver label per row "Name, size, method, risk" (BUILD_PLAN §8). A "Sample data" `Tag` top-trailing in demo
mode.

**Drives** (`DrivesView`, app-shell). Over `Dusk(strength: 0.6)`: the **`GuardLamp`** at the top left with its label
("Guard on · drive attached" / "Guard on · drive away" / "Guard off: Outboard quits when the window closes"), then the
stage's `Metric` row (`Metric("Drives", "3")`, `Metric("Moved", "87", unit: "GB")`). Then one `.surface(18)` per
mounted volume: header (`externaldrive` symbol in a 32pt `well`, the name 17pt semibold, `Eligibility.summary` in 13pt
mono secondary: "USB · APFS · encrypted: unknown · Time Machine: no · 38 GB free"), the **`CapacityBar`** (used, moved,
free), the verdict line (the first refusal in 13pt, or "Your Outboard drive." with `Tag("Your Outboard drive", tint:
Brand.aqua)` for E17, or the acks and warnings as plain rows), "All checks" as a disclosure listing every verdict with
its rule id in mono, and the trailing `MooringButtonStyle` "Use this drive" (only on the one allowed drive without a
marker; `.bordered` elsewhere). A refused drive's card is set exactly like an allowed one; only the words differ. Under
the volumes, **Relocations** as rows in one `.surface(16)`: `TetheredOutline(drawn:)`, the recipe symbol, the name,
"41 GB · 48,211 files" rounded, the Health `Tag` (word plus dot), the state word (`MoveState.displayName`), and on hover
"Show on drive", "Roll back", "Confirm…", "Return to Mac…", "Forget…" as borderless buttons (`.help` on each, only the
ones `canRollBack`/`canConfirm`/`canReturn` allow). A Drive-away row shows a `NoteCard` with the note's first sentence
under it. **Leftovers** as a final group ("Incomplete copy from 3 Oct, 38 GB" with "Move to Trash…"). E19 appears once
as a plain 12pt line under the first drive card ("Sleep can disconnect drives, hubs more often. …"). The onboarding
steps (`Education.driveSteps`) are a sheet from "Set up a drive…" (`KeyCapStyle`), numbered rows, "Open Disk Utility"
and "Apple's guide" as `.bordered`; the exFAT case shows its sentence above the steps.

**Consent sheet** (`ConsentSheet`, app-content; sized to content, never a fixed height). `SheetHeader`: the title
"Move Xcode's build data to Outboard drive?" 22pt, the subtitle "41 GB · Official setting · Rebuilds itself" 13pt
secondary, and, for an unverified recipe, "Not yet tried on a real Mac." as a third 13pt secondary line. A
`.surface(16)` "What changes" (the two or three sentences); a `.surface(16)` "What to know" (bullets as plain rows with
a 6px neutral dot); "Before you start" as a `.surface(16)` with the live **blocker rows** (`Blocker.name`, the state
word "Running" / "Not running" / "Can't tell", and "Quit Xcode to continue" in 12pt secondary; nothing clickable kills
anything; a `Can't tell` row blocks), then the required `Toggle`s (consent checkboxes and eligibility acks, each the
exact text, `.toggleStyle(.checkbox)`); the **space ledger** as three `LabeledContent` rows in 13pt with rounded
numerals (`ConsentSheetText.ledger`); for `envLine` recipes a `terminal()` block with the line and a `CopyButton`
("Outboard won't edit your shell or login settings; here is the line to copy."); the footer `Link`-style button "What
happens if I unplug the drive?" (opens Education card 5 in a sheet). The action bar on `barSurface()`: Cancel
(`role: .cancel`; **the default button when `recipe.riskClass == .irreplaceable`**) and `MooringButtonStyle` "Move 41 GB"
(disabled until every box is ticked and every blocker clear; `.keyboardShortcut(.defaultAction)` only when the risk is
not irreplaceable). No aqua panel, no red, no type-to-confirm.

**Progress** (`ProgressView` sheet, app-content; phase `.running`). The sheet stays; "Copying Xcode's build data" 22pt;
a **`CapacityBar`** with two segments (done, remaining) by bytes, the legend "12.4 GB of 41.2 GB · 3 min 10 s elapsed"
(bytes and elapsed time, never an estimate or a rate); while verifying, the same bar by files ("18,004 of 48,211 files
compared"); the system `ProgressView` (indeterminate) beside the phase word during preflight and swapping; the note
line ("Xcode opened. If it changes the data, the move will start over.") in 13pt secondary when present. The only loop
is the system spinner; the bar moves only when `MoveProgress` changes (polled every 500 ms by the backend). Demo freezes
at 41 % (BUILD_PLAN §9). No Cancel while swapping; "Stop" (`.bordered`) while copying or verifying, which aborts with
nothing on the Mac changed.

**Try it and confirm** (`.tryAndConfirm` sheet). Over `Dusk()`: "The move is ready. Open Xcode and check your data."
22pt; the `TetheredOutline(drawn: 1)` beside the relocation row (name, size, the Health `Tag` "Healthy"); the ledger's
three lines; "Open Xcode" (`.bordered`), "Not yet" (`role: .cancel`), and `MooringButtonStyle` "Confirm and move to
Trash…" which opens the **Confirm dialog** (`ConfirmDialog`): "Use the move for good?" with the exact body from
BUILD_PLAN §8.1, the checkbox "I opened Xcode and my data is there." and the two buttons; the primary is never the
default for irreplaceable recipes.

**Result** (`.result` sheet over `Dusk()`). "Moved 41 GB to Outboard drive." 22pt with the number rounded, then
`MoveOutcome.message` in 13pt secondary; a `.surface(16)` with the verification line ("Compared 48,211 files by size and
SHA-256: 0 differences.") with a green `checkmark.circle.fill` (`.bounce(on:)` once on macOS 14+), or an aborted move's
first differences as rows (`Difference.kind` word, the relative path in mono; never red except a failed row's
`xmark.circle.fill`) and the fixed line "Nothing on your Mac was changed."; the action bar on `barSurface()`: "Open
Activity", "Show on drive", "Done".

**Activity** (`ActivityView`, app-content). A plain `List` of `ActivityEntry` rows newest first: the `StepStatus`
symbol in its tint (a problem row's symbol secondary, failed red), the text 13pt (`ActivityText`, one line, never what
it means), the recipe name and time in 12pt secondary; filters in the toolbar (by relocation, by day, "Problems only");
"Export…" (⌘E) opens the `Export` sheet (`Form` + `.formStyle(.grouped)`: Markdown / JSON, "Hide folder paths", the
`NSSavePanel`). Under the list in 12pt secondary: "The log can't be edited or cleared from Outboard." Toolbar: "Reveal
log in Finder".

**Guided card** (`GuidedCardView`, app-content; a sheet). Over `Dusk(strength: 0.5)`: the recipe symbol in a 44pt
`well`, "Photos library" 22pt, "212 GB · Guided" 13pt secondary; the numbered steps as rows in a `.surface(16)`; the
chosen drive's verdict as one row with the Health-style `Tag` ("Allowed" neutral / the first refusal); the vendor's
missing-drive sentence in a `NoteCard`-shaped sheet labelled "If the drive is away"; the closing line "Outboard can't see
inside Photos. When you're done, open Photos and check that it works." 13pt secondary; the bar: "Open Photos"
(`MooringButtonStyle`), "Done". Nothing is written; the journal records "guide viewed".

**Preferences sheet** (`PreferencesSheet`). `Form` + `.formStyle(.grouped)`, stock: "Start Outboard at login" (with the
`LoginItemState` word beside it and the `requiresApproval` sentence plus "Open Login Items" when needed), "Keep the guard
running when the window closes", "Show moves not yet tried on a real Mac", "Hide folder paths in exports", "Show app
names on the card", "Check for updates" (opens Releases). No custom surfaces here.

**About** (`AboutView`). The icon on `OnFloor(height: 96)` with `HoverTilt(max: 8, glare: true)`, "Outboard 0.1.0"
rounded, the honesty statement ("Outboard copies, compares and renames. It never deletes; after you confirm, the
original goes to the Trash."), `Names.affiliation` and `Names.notTriedMarker` in 13pt secondary, links as `.link`
buttons, "Copy diagnostics" (`CopyButton`).

**First run** (`FirstRunView`, app-shell; a sheet sized to content over the empty Plan). The five `Education.cards`
as a paged `.surface(16)` with a page dot row (plain circles, the current one `Brand.aquaInk`): title 22pt, body 15pt,
card 5's last sentence `.bold()`; card 5 also carries the `GuardLamp(lit: true, label: "Guard on while Outboard is
running")`, the `Toggle("Keep Outboard running at login")` (default on) with its sub-line, and the `NoteCard` with the
note's text; the icon on `OnFloor(height: 112)` on card 1 with MOTION §3.4's arrival and `HoverTilt(max: 8, glare:
true)`; "Continue" / "Done" as the one `MooringButtonStyle`. Always reachable from Help › First-run Cards.

**Banner** (`BannerView`, app-content). One strip at the top of every tab while `GuardSnapshot.banners` is not empty,
on `barSurface()`: the `BannerKind.symbol` in secondary, the text 13pt (`Banner.text`, exact), the actions as
`.bordered` buttons in `BannerAction` order ("Check and reconnect" is `MooringButtonStyle` when present; "Forget" is
never the default and opens the two-step Forget sheet). Several banners stack; none dismisses itself. No colour: the
strip is the same for "is back" and "was removed".

**Edge states** (`EdgeStates`). All plain: a secondary sentence over `Dusk(strength: 0.5)` or a plain row. Journal not
writable: "I can't write the activity log, so nothing was changed." with "Reveal folder". Drive changed: "The drive
changed while we were getting ready. Nothing was changed." Needs attention: the `RecoveryFacts` as `LabeledContent`
rows ("Drive present: yes", "At the path: a link", "Safety copy: present"), the fixed line "Outboard stopped and
touched nothing.", "Copy diagnostics". Held: the reason word and the one button it needs. Conflict: the banner text and
its three actions. Forget: two steps ("Outboard cannot get this data back without the drive." then the confirm), never
default focus. Needs permission: "macOS blocked access to the drive." with the Privacy settings steps and "Open System
Settings".

**Dark mode.** The dusk wash; surfaces white .055 with a white .10 rim; aqua text uses `Brand.aquaInk`. Increase
Contrast gives the plain window, 1pt primary strokes, bar segments with a 1pt stroke and no aqua edge, the lamp without
its glow.

### 6.6 Storage Plan card (`PlanCardView`, app-report; the PNG; no materials, blur or shadows inside)

1200×630 at 2× from a 600×315pt view. The night quay in every scheme (the card is an object): `#0B1620` → `#0F1B24`
top to bottom; the lamp as a 6pt aqua dot (`Brand.lamp` at .9) at the bottom left with a faint pool around it; the mark
and "OUTBOARD" (small caps, `#9DB0BA`) top-left; `StoragePlanCard.headline` at 44pt display semibold `#EAF2F5` with the
number in `#7EECE4` rounded; the rows (`CardRow`) as label 17pt `#EAF2F5`, the rounded size tabular right-aligned, and
a `CapacityBar`-style single segment of `fraction` width in `#7EECE4` (6pt tall, 3pt radius); `moreLine` and
`guidedLines` at 15pt `#9DB0BA`; `measuredLine` at 17pt `#9DB0BA`; `footnote` at 13pt `#9DB0BA`; the website at 13pt
mono bottom-right; the "Sample data" `Tag` top-right when `isSample`. Rows become "3 folders" when `showsAppNames` is
false. Labels never truncate: the card grows taller (the PNG stays 1200 wide; height follows). `ImageRenderer` on macOS
13: VERIFY the 1200×630 output (BUILD_PLAN §12). The back of the card (the footnote and "Not counted") exists only on
the site; the PNG is the front.

## 7. Icon and social image (infra: `tools/make_icon.py`, `tools/make_og.py`, stdlib SDF renderers)

- **App icon:** a slate squircle (`#101C2C` → `#0E3740`, a faint top highlight) with the water: a cyan band across the
  lower third (`#0E3740` lightening to `#17505A` at the water line) and a lamp pool; the **mark** in aqua (`#7EECE4`):
  a rounded square (the Mac, stroke 1/14 of its width) left of centre and a shorter rounded bar (the drive) right of
  centre, joined at mid height by a line of the same stroke (the tether), with a solid dot above the square's top-left
  corner (the lamp, `#F2FFFD` core). Reads at 16px as "dark tile, two shapes, a line between them, a dot". No text, no
  vendor marks. Later, on a Mac: an Icon Composer `.icon` with three layers (sky and water, the mark, the lamp) and
  specular on the lamp.
- **Menu bar:** the mark alone, template (§6.4), with the open-tether variant for attention.
- **OG image (1200×630):** the quay edge to edge (sky at the top, the water line, the lamp at the left with its pool),
  the icon at 280px standing on the quay with its reflection, the wordmark under it. No sentence in the image;
  `og:title` carries "Outboard for Mac: move big app folders to an external SSD, compared file by file".

## 8. Acceptance and budgets

**Looks premium (a judge checks light and dark captures at 1440 and 390px, base and `prefers-contrast: more`,
against `refs/`):**

- [ ] The hero has no container edge: light comes only from the lamp; the water reads as water; the quay and the boat
      read as two slabs with a gangway between them; the three crates stand on the boat with their tethers back to the
      outlines on the quay; the card is in front and the brightest object; everything is still after 2.8 s; pressing
      "Unplug the drive" slides the boat out, folds the gangway, slackens and fades the tethers, pins a note to each
      outline and dims the lamp; the status says what happened; "Plug it back in" reverses all of it; "Turn the card
      over" shows the footnote and "Not counted".
- [ ] Exactly one accent is visible (aqua); slate and cyan appear only in the sky and water; green only in dots, the
      all-matched check and the Healthy pill; red only on a failed row's symbol; no method, risk or health gets a
      coloured panel; a Held row is set exactly like a Healthy row apart from the pill word and the dot; the lamp dims
      and never turns red.
- [ ] Every raised surface shows a lit top edge, a 0.5px hairline (1px rim in dark) and an ink-tinted shadow; the
      slabs cast a long aqua-tinted shadow on the water; buttons have a lip and no glow; key-caps sink on press.
- [ ] Headlines are the system display face at 600 with tight tracking; numerals are rounded and tabular; paths and
      keys are mono; labels are small caps; nothing is ALL CAPS copy; no font file is requested (Network panel).
- [ ] Light mode is the same quay at noon (cool paper, a pale sky, bright water), not a grey page; dark is cool
      near-black, never #000.
- [ ] Capacity bars, crate labels and card rows never truncate: segments have a floor width and the legend carries the
      words; sheets are sized to their content; nothing clips at the largest text size; a moved segment is an outline on
      the Mac's bar, never empty space, until the move is confirmed.
- [ ] Real screens appear only at ≤ 50% of their pixel width; no horizontal page scroll at 360px.
- [ ] Reduce Motion, no-JS and print show the moored state; print is dark text on white; both hero buttons swap states
      without movement under Reduce Motion and are hidden without JS.
- [ ] Every page carries "Outboard is not affiliated with or endorsed by any app it lists." and "Not yet tried on a real
      Mac." while the marker rule holds; no page, README or changelog line contains a banned phrase
      (`tools/safety_greps.sh` G15 is green); the word "Overflow" appears nowhere.
- [ ] `python tools/build_site.py --check` passes with exactly two `:root` blocks, no `style=""`, the CSP exact.
- [ ] App, from CI captures: the Plan shows the card as the one lifted object on the dusk wash with no grey-on-grey,
      the ranked groups with method and risk chips carrying words, the never group with reasons, "Some of System Data
      is not movable by any app."; Drives shows the lamp with its label, one capacity bar per volume with a legend,
      verdict words, and relocation rows with Health pills; the consent sheet holds the blocker rows, the checkboxes,
      the three-line ledger and "Move 41 GB", with Cancel as the default for "Can't be replaced"; Progress shows bytes
      and elapsed time and no estimate; the Drive-away banner is the same strip as the is-back banner; the card has no
      app names when hidden and shows the watermark in demo mode; VoiceOver labels read "Name, size, method, risk".

**Budgets:**

| Item | Cap |
|---|---|
| `site/static/styles.css` | 40 KB (`BUDGET` in `build_site.py`) |
| `site/static/motion.js` | 6 KB: Aftertaste's file byte for byte (the shared 2.7 KB plus the sweep job, under 1 KB) |
| Webfonts | 0 files, 0 bytes |
| Home HTML (built) | ≤ 36 KB |
| First load (HTML + CSS + JS + icon + favicon) | ≤ 110 KB |
| Lazy screenshots | ≤ 110 KB each, 5 per scheme, only the active scheme loads |
| Third-party requests, CDNs, trackers, network calls from the app | 0 |
| Hero sequence | ≤ 2.8 s, once; the leave ≤ 1.0 s on the button; the return ≤ 1.0 s; the flip ≤ 0.6 s; ≤ 4 planes |
| CLS / LCP | 0 / the h1 text |
| App | CPU 0% within 2 s of any entrance; the tether draw ≤ 1 s; `HoverTilt` ≤ 2 on screen; new assets or dependencies: none |
| CSP | the siblings' exact string; no inline script, style or handler |

**Security.** Nothing here touches the safety rules, the verbs, `Journal.swift`, the entitlements or the data flow.
The card path stays effect-free. Materials and glass are system APIs. The site makes no request beyond its own files.
The design never shows a path the report would scrub (the `~` form only), never a UUID beyond its first 8 characters,
never a drive name on the card before a move.

## 9. Changes for other owners, decisions for the lead, VERIFY list

**By owner (proposed, not made):**

- **site (`site/**`):** §2–§5 and MOTION §2; the inline glyph sprite (§4.3); the `html[lang]` media rules; the
  `color-scheme` and two `theme-color` metas; `motion.js` = Aftertaste's file unchanged (the sweep job reads
  `data-sweep-said` / `data-sweep-reset`); the three guides' outlines (§5) with sources; the catalogue tables read from
  `recipes.json` and the cards from `education.json`.
- **infra (`tools/build_site.py`, `make_icon.py`, `make_og.py`):** `BUDGET` with `motion.js` 6 000 and no `fonts/*`
  entry; fail `--check` if any `fonts/` file exists; the banned-phrase grep over `site/_dist`; the marker rule; the icon
  and OG per §7.
- **app-shell (`PlanView`, `DrivesView`, `AboutView`, `FirstRunView`, `RootView`, `Menu/**`):** §6.5's Plan, Drives,
  About and first run; `MenuBarIcon.moored` / `.attention` for the item (read from `guardSnapshot.showsAttentionDot`,
  never written back); `activateApp()` from Compat; `GuardLamp` fed from `guardSnapshot.isAllHealthy` and
  `prefs.keepGuardRunning`.
- **app-content:** §6.5's consent, progress, confirm, result, activity, guided card, preferences, banner, edge states;
  `CapacityBar` fed from `MoveProgress` (bytes while copying, files while verifying) and from each volume's
  `DriveFacts` (used = capacity − available, moved = the sum of that volume's active relocations' `logicalBytes`, free
  = available); `TetheredOutline(drawn:)` on relocation rows from `RelocationHealth.health == .healthy`.
- **app-report (`PlanCardView`):** §6.6, using `Brand` and the card's fixed colours; the row bars with the
  `CapacityBar` segment code; nothing with a shadow inside the rendered view.
- **core (`Text`):** nothing new; `Format.bytes`, `Eligibility.summary`, `ConsentSheetText`, `BannerText`,
  `PlaceholderText.body` and `StoragePlanText` are what the surfaces print. One request: a `Format.elapsed(_ seconds:
  Double) -> String` ("3 min 10 s") for the progress legend, if it does not already exist.
- **copy / lead (BUILD_PLAN §8):** the proof-strip numerals (§3 item 3); the FAQ questions; the 404 line; the hero h1
  "Big folders, moved alongside."; the download band "Room to breathe. It's free."; the three forum paraphrases in block
  4; `GuardLamp` labels ("Guard on · drive attached" / "Guard on · drive away" / "Guard off"); the Progress "Stop"
  button and the result sheet's "Nothing on your Mac was changed." if BUILD_PLAN wants them fixed.
- **BUILD_PLAN §8 (architect):** record the accent as **mooring aqua** `#4FE3D8` (button), `#0B6F73` / `#7EECE4` (as
  text) in place of "a mooring cobalt": the owner's design brief asked for a slate-to-cyan world with a bright aqua
  accent, and cobalt would sit too close to Whydunit's sky blue; slate and cyan are world-only. Add "the site follows
  the system scheme; the dark palette is the designed-first one and the one on the OG image".

**Decisions for the lead:** (1) confirm the accent (mooring aqua, not cobalt) and that slate and cyan never appear on
a control; (2) confirm the two hero buttons (the leave/return on the sweep job, the flip on the shared job); (3)
confirm that method and risk chips are neutral (word only) and only Healthy gets a green dot; (4) confirm the hero's
sample numbers (a 245 GB Mac with 9 GB free, a 1 TB drive with 913 GB free) or hand the demo owner's `plan` scenario
numbers to the site; (5) confirm the C9 tense on the site ("is designed to announce" until a `VERIFY_LOG.md` entry
exists).

**VERIFY (on a Mac or in Safari):** every SF Symbol in §6.1, §6.4, §6.5 on macOS 13 (`slider.horizontal.3`, `link`,
`list.number`, `hand.raised`, `hammer`, `archivebox`, `cube`, `shippingbox`, `iphone`, `bag`, `photo.on.rectangle`,
`music.note`, `film`, `pianokeys`, `gamecontroller`, `chevron.left.forwardslash.chevron.right`, `externaldrive`,
`externaldrive.badge.minus`, `externaldrive.badge.exclamationmark`, `externaldrive.badge.checkmark`, `app.badge`,
`questionmark.folder`, `doc.badge.ellipsis`, `arrow.left.arrow.right.circle`, `pause.circle`, `square.grid.2x2`,
`list.bullet.rectangle`); `Canvas` in `ImageRenderer` for the menu bar glyph; `OnFloor`'s shadow offset; `HoverTilt`
signs; `.contentTransition(.numericText())` while `MoveProgress` changes every 500 ms; the `Hatch` shape under
`ImageRenderer`; `-webkit-box-reflect` inside a 3D parent; `color-mix()` in the `.tag` rules on Safari 16.2+;
`backface-visibility` on the card's faces inside a `preserve-3d` parent in Safari; the per-function transform
interpolation on the leave (MOTION §2.3); the JPEG corner radius at half scale; `screencapture -o -l` for the window;
the app-icon mark's legibility at 16px (two shapes and a line) against the siblings' marks in a Dock row.
