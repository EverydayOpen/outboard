# Motion spec: Outboard (website and app)

**Why:** the family requirement (2026-09-28): a modern UI with 3D motion that stays lightweight, on the website and
in the app. Outboard's version of it is "Alongside" (`docs/DESIGN.md` §1): one crossing, one leave, one return, then
stillness.
**Authority:** this file is authoritative for motion. `docs/DESIGN.md` is authoritative for tokens, surfaces and
compositions and wins where the two conflict. BUILD_PLAN §8 already fixes the rules this file obeys: one signature
animation (the crate crossing on the site, the tether drawing in the app, at most 3.2 s on the web and 1 s in the app),
everything else a plain fade, all of it off under Reduce Motion (the end state with at most a 150 ms fade), nothing
moving at idle, no percentage estimate or rate on any progress bar.
**Shared system:** §1 is the EverydayOpen motion language, copied verbatim from the Aftertaste repo's `docs/MOTION.md`
(identical there, in Overstay's, Tirekick's and Whydunit's); change all five together. Where §1 says "Tirekick (macOS
13)", read Outboard: the deployment target is the same. Two Outboard-specific differences to §1.7: there is no webfont,
and `site/static/motion.js` is **Aftertaste's file byte for byte** (the shared script plus the appended sweep job, §2.4,
whose status strings come from attributes), so its cap is 6 KB, not 5.
**Status:** nothing in this file has been built or run. The CSS and JS in §2 follow the same mechanics as the
siblings' prototype-tested code but have not themselves been opened in a browser. The Swift in §3 is written, not
compiled; anything unconfirmed is marked VERIFY.

## 1. The EverydayOpen motion language (shared, identical in all four repos)

### 1.0 What makes 3D feel premium and still light (research, 2026-09-28)

- **Only the object moves.** Apple's product pages keep headlines, prices and buttons still. The product and the
  depth around it do the moving, and the hero plays once and then stops.
- **One camera, a few planes.** Linear and Raycast get depth from 2 to 4 flat layers at different Z, turned a few
  degrees in one perspective. They never build a full 3D model. Flat layers are cheap and keep text sharp.
- **Physical, damped, quick.** Things and Arc use short springs with a little overshoot for small objects and none
  for big surfaces. Nothing floats for more than about a second.
- **Light follows the pointer.** macOS Tahoe's Liquid Glass puts specular highlights where you move, and Reduce Motion
  turns that parallax off. Here that becomes glare under the pointer plus shadows that don't move.
- **The platform does the heavy lifting.** CSS 3D transforms and scroll-driven animations run on the compositor.
  Safari 26 shipped scroll-driven animations, and Safari 26.4 moved them to the compositor thread. Firefox stable
  still hides them behind a flag (mid-2026), so it gets a small IntersectionObserver fallback. In SwiftUI,
  `rotation3DEffect`, springs and transitions cover everything here without SceneKit or Metal.
- **Trust tools animate facts calmly.** Motion never makes a verdict look scarier or more cheerful than it is.

### 1.1 Principles (rules, not taste)

1. **Text never waits.** Hero headlines, taglines, verdicts, numbers and buttons render still, at once. Below the
   fold, a block can rise in as it enters the viewport, and it is done by the time 75% of it is visible.
2. **One hero moment per surface, then stillness.** Every sequence ends: at most 3.2 s on the web and 1 s in the
   apps. The only loops are a progress indicator that runs while real work runs (a scan, the checks).
3. **Motion never encodes severity.** A red "Walk away" arrives exactly like a green "Clean". Nothing shakes, flashes
   or pulses to alarm.
4. **Depth follows light.** A surface turns to face the pointer: the edge under the pointer recedes. The glare sits
   under the pointer. Shadows are fixed per layer and move only with their surface.
5. **Physical and quick.** Surfaces use springs with bounce ≤ 0.25. Small glyphs use ≤ 0.4. Nothing lasts longer
   than 1.1 s except the one-time hero sequence.
6. **Reduce Motion means no movement.** The end state is the same, reached by at most a 150–200 ms fade. No tilt, no
   parallax, no flip: a flip becomes a crossfade or an instant swap.
7. **Compositor only.** The web animates `transform`, `translate`, `rotate`, `scale` and `opacity`. The apps animate
   geometry effects and opacity, never frames or padding, during 3D motion.

### 1.2 Tokens

**Depth.** The web shares one real perspective per scene. SwiftUI has no shared 3D space, so each view gets its own
`perspective:` (1 is the default; lower is flatter). The table's mapping is approximate: VERIFY on a Mac and tune by
eye.

| Token | CSS | SwiftUI `perspective:` | Use |
|---|---|---|---|
| scene | `--persp-scene: 1600px` | 0.4–0.5 | hero scenes, grids, the report card, the laptop |
| card | `--persp-card: 900px` | 0.6 | cards, tiles, rows, FAQ answers |
| glyph | `perspective(400px)` inline | 1.0 (default) | icons, step numbers, keys |

| Z layer | CSS `translateZ` | SwiftUI stand-in | Shadow |
|---|---|---|---|
| back | −140 to −160px | smaller, behind in a ZStack | none |
| surface | 0 | the view itself | `--shadow` (z3) if it floats, none on a band |
| hug | +40 to +60px | offset ×1 of the tilt | `--z1`/`--z2` |
| float | +90px (max +140) | offset ×2 of the tilt | `--shadow` |

Use at most 4 layers in one scene.

**Easing and springs.**

| Token | CSS | SwiftUI (Whydunit, macOS 15) | SwiftUI (Tirekick, macOS 13) | Use |
|---|---|---|---|---|
| out | `--ease-out: cubic-bezier(.16, 1, .3, 1)` | `Motion.spring(_:)` = `.spring(duration: 0.45, bounce: 0.22)` | `.spring(response: 0.45, dampingFraction: 0.78)` | entrances, settling, tilt return, flips |
| hero | `--ease-out` over `--t-hero` | `Motion.hero` = `.spring(duration: 0.9, bounce: 0.2)` | `.spring(response: 0.9, dampingFraction: 0.8)` | one-time entrances (icon, lid) |
| spring | `--ease-spring: cubic-bezier(.34, 1.56, .64, 1)` | `Motion.pop` = `.spring(duration: 0.32, bounce: 0.38)` | `.spring(response: 0.32, dampingFraction: 0.62)` | chips, symbols, keys |
| follow | `var(--t-fast)` with `--ease-out` | `Motion.follow` = `.interactiveSpring(response: 0.25, dampingFraction: 0.86)` | same (macOS 10.15 API) | following the pointer |
| in-out | `--ease-in-out: cubic-bezier(.65, 0, .35, 1)` | `.easeInOut(duration:)` | same | beams, rising files |
| standard | none | `Motion.standard(_:)` (existing) | `Motion.standard(_:)` (existing) | plain state changes |

`.spring(duration:bounce:)` is macOS 14. With bounce ≥ 0 its damping fraction is 1 − bounce, so the Tirekick column
is the same curve.

**Durations.** `--t-fast .16s` (hover, press), `--t-base .32s` (state change, FAQ), `--t-slow .7s` (reveal, tilt
settle), `--t-hero 1.1s` (hero plane). **Stagger:** 90 ms between cards and 80 ms between report rows on the web.
In the apps, Whydunit rows use `Motion.stagger = 0.045` and Tirekick check rows keep their existing 70 ms. The
stagger index is capped (6 on the web, 8 in the apps), so a long list never trickles.

### 1.3 Hover tilt, glare and sheen

| Surface | Max tilt | Lift | Glare |
|---|---|---|---|
| Hero scene (window, laptop and card together) | 5° | none (it already floats) | only the report card |
| Cards and tiles | 7° | `scale 1.02` (web), press `0.97` | web yes, app no |
| App icon (Whydunit Welcome) | 12° | none | yes, masked to the icon |
| Laptop drawing (Tirekick Welcome) | 8° | none | no |
| Reading surface with long text (report card in the app) | 4° | none | yes |
| Tables, forms, lists, sidebars, buttons, navigation, keys | 0° | press depth only | no |

- **Direction.** `px` and `py` run from −1 to 1, measured from the center. CSS uses
  `rotateX(py × −max) rotateY(px × max)`, which was checked in Chromium: the edge under the pointer recedes. SwiftUI
  starts from the same formula; VERIFY the signs on a Mac.
- **Follow fast, settle slow.** Follow the pointer over 160 ms. Return over 700 ms (web) or with `Motion.spring`
  (app).
- **Fine pointers only.** Tilt needs `(hover: hover) and (pointer: fine)`; a Mac always qualifies. Phones get
  scroll-driven depth instead (§1.7).
- **Hit areas never move.** The web reads the pointer on the element and caches the box when the pointer enters. The
  app gets `onContinuousHover` coordinates in the untransformed layout frame.
- **Glare** is a soft radial spot under the pointer, about 60% of the surface wide, fading in over 160 ms. White
  can't shine on white, so light mode uses a faint accent spotlight (`rgb(0 102 204 / .07)`). Dark mode uses white
  at .10, and the app uses white at .28. On the web it is a 200% layer moved with `transform` and clipped by the
  card, drawn between the card's fill and its text, so it never repaints and never lowers text contrast.
- **Sheen** is a single linear highlight sweep. It is used only for the Tirekick scan beam, once.

### 1.4 Shadows that sell depth

- `--z1: 0 1px 2px rgb(0 0 0 / .06), 0 4px 12px rgb(0 0 0 / .05)`: hug layers and guide boxes.
- `--z2: 0 2px 6px rgb(0 0 0 / .06), 0 12px 32px rgb(0 0 0 / .1)`: small floating badges.
- `--shadow` (existing, z3): floating surfaces and chips.
- **Dark mode:** black backgrounds swallow shadows, so each shadow is darker and carries a 1px light rim
  (`0 0 0 1px rgb(255 255 255 / .06–.12)`) that draws the edge.
- **Never animate `box-shadow` or `filter`.** A shadow belongs to its layer. Depth changes come from moving the
  surface, and the shadow moves with it.
- **App:** use `.compositingGroup().shadow(...)` on anything that contains text, so glyphs don't get shadows of
  their own.

### 1.5 Reduce Motion

| Effect | With Reduce Motion |
|---|---|
| Hero sequence (web) | Nothing plays. The page shows the final state: lid open, files uploaded, rows filled, chips gone. |
| Pointer tilt, glare, parallax | Off (flat). |
| Scroll reveal, steps coin, phone scroll lean | Off: content is simply there. |
| FAQ unfold, button press scale | Off. `<details>` opens instantly. |
| Report card flip (web) | Instant swap by `visibility`. The button still works. |
| App entrances (icon, lid, card deal-in) | Shown at rest immediately, or a `Motion.standard(true)` fade. |
| Row flip-ins, split-flap verdict, sheet card swaps | `.opacity` transitions. |
| Scan loops (cloud glyph, laptop beam) | Not drawn. The system `ProgressView` stays. |
| Symbol effects | Removed (`.symbolEffectsRemoved(reduceMotion)` in Whydunit; Tirekick never triggers them). |

The web puts every movement inside `@media (prefers-reduced-motion: no-preference)`, so Reduce Motion needs no
override rules except the flip. The apps read `@Environment(\.accessibilityReduceMotion)` in every view that moves,
or go through `Motion.*(reduceMotion)`. VoiceOver labels, traits and element grouping never change.

### 1.6 Performance rules

**Web**

- Animate `transform`, `translate`, `rotate`, `scale` and `opacity`, plus the custom properties `--px` and `--py`
  that feed them. Never animate `box-shadow`, `filter`, `background-position`, size or position.
- **Grouping properties flatten 3D.** Never put `opacity < 1`, a non-visible `overflow`, `filter`, `clip-path`,
  `mask`, `mix-blend-mode`, `isolation` or `contain: paint` on an element that has
  `transform-style: preserve-3d`. Fade its children or its parent instead. The prototype follows this.
- No `backdrop-filter` inside a 3D scene (Safari draws it flat), and no permanent `will-change`: it wastes GPU memory
  and blurs text in Safari.
- Use `translate`/`rotate`/`scale` (the individual properties) for reveals and `transform` for tilt, so both can
  run on one card without fighting.
- At most one `requestAnimationFrame` per frame. `pointermove` listeners are passive. The box is read once per
  element entered.
- No infinite animations on the web.
- **CSS stays in `styles.css`.** `motion.js` is byte-identical in both repos (2.7 KB; hard cap 5 KB) and loads with
  `defer` from `layout.html`.
- **Two `:root` blocks only.** `tools/build_site.py` `contrast()` unpacks exactly two `:root { }` blocks, light then
  dark; a third one crashes `--check`. New tokens go into the existing two blocks. Any other override uses `html`
  or a class.
- `data-theme` and `localStorage` fail `--check`. Dark and light come from `prefers-color-scheme` only.

**Apps**

- **Zero CPU when idle.** Springs settle and stop. `repeatForever`, a `phaseAnimator` without a trigger, and
  `TimelineView` appear only inside views that exist only while work runs: Whydunit's first-scan view and Tirekick's
  "Checking this Mac…" view.
- Use only `.animation(_:value:)`, never unscoped `.animation`. Call `withAnimation` only in event handlers and
  `onAppear`.
- **3D on content only.** Never add 3D to a `Table` or `List` row container: AppKit owns the cell, its clipping and
  its selection.
- `ImageRenderer` paths get no effects inside the rendered view. Tirekick's `ReportCardView` is the PNG.
- No `drawingGroup()` over text: it rasterizes, and the text blurs at 3D angles.
- Hover state lives in the modifier (`@State`), never in `AppStore` or `AppModel`. Keep at most 8 `HoverTilt`
  views on screen at once; plain `onHover` rows are cheap and don't count.
- Written, not compiled: none of the Swift in this file has been built. Mark every API you can't confirm with
  `VERIFY`.

### 1.7 Shared web code (prototype-tested in Chromium on Windows, 2026-09-28)

**Tokens.** Append these to the **existing** light `:root` block:

```css
  /* Motion and depth (docs/MOTION.md §1). Only these two :root blocks: build_site.py contrast() reads exactly two. */
  --ease-out: cubic-bezier(.16, 1, .3, 1);
  --ease-spring: cubic-bezier(.34, 1.56, .64, 1);
  --ease-in-out: cubic-bezier(.65, 0, .35, 1);
  --t-fast: .16s;
  --t-base: .32s;
  --t-slow: .7s;
  --t-hero: 1.1s;
  --persp-scene: 1600px;
  --persp-card: 900px;
  --z1: 0 1px 2px rgb(0 0 0 / .06), 0 4px 12px rgb(0 0 0 / .05);
  --z2: 0 2px 6px rgb(0 0 0 / .06), 0 12px 32px rgb(0 0 0 / .1);
  --glare: rgb(0 102 204 / .07);   /* white can't shine on white: a faint accent spotlight instead */
```

Then append these to the existing dark `:root` block:

```css
    --z1: 0 0 0 1px rgb(255 255 255 / .06), 0 4px 12px rgb(0 0 0 / .5);
    --z2: 0 0 0 1px rgb(255 255 255 / .08), 0 12px 32px rgb(0 0 0 / .6);
    --glare: rgb(255 255 255 / .1);
```

**Shared rules.** Append these to `styles.css`, and delete the old
`@media (prefers-reduced-motion: no-preference) { .button { transition: background-color .2s; } }` line, which the
button rule below replaces. The block adds about 3 KB.

```css
/* Motion (docs/MOTION.md). Everything above is the finished, still page; movement only under no-preference.
   Animate transform, translate, rotate, scale and opacity only. Never opacity, overflow, filter or clip-path on a
   transform-style: preserve-3d element: they flatten its 3D. */
[data-tilt] { --px: 0; --py: 0; }
.stage { --tilt: 5deg; perspective: var(--persp-scene); }
.scene { position: relative; transform-style: preserve-3d; }
.grid { perspective: var(--persp-scene); }
.card[data-tilt] { --tilt: 7deg; position: relative; isolation: isolate; overflow: hidden; }
/* Glare: a 200% spotlight moved by transform (no repaint), between the card's fill and its text. */
.card[data-tilt]::after {
  content: ""; position: absolute; z-index: -1; inset: -50%; pointer-events: none; opacity: 0;
  background: radial-gradient(circle, var(--glare), transparent 30%);
  transform: translate(calc(var(--px) * 25%), calc(var(--py) * 25%));
}
@media (prefers-reduced-motion: no-preference) and (hover: hover) and (pointer: fine) {
  .scene, .card[data-tilt] {
    transform: rotateX(calc(var(--py) * var(--tilt) * -1)) rotateY(calc(var(--px) * var(--tilt)));
    transition: transform var(--t-slow) var(--ease-out), scale var(--t-base) var(--ease-out);
  }
  .tilting .scene, .card.tilting { transition-duration: var(--t-fast), var(--t-base); }   /* follow fast, settle slow */
  .card.tilting { scale: 1.02; }
  .card[data-tilt]::after { transition: opacity var(--t-base), transform var(--t-fast) linear; }
  .card.tilting::after { opacity: 1; }
}
/* Phones: no pointer, so the hero leans back and straightens as it scrolls into place. */
@media (prefers-reduced-motion: no-preference) and (hover: none) {
  @supports (animation-timeline: view()) {
    .scene { animation: settle linear both; animation-timeline: view(); animation-range: cover 0% cover 45%; }
  }
}
/* Reveal: scroll-driven where supported; motion.js adds .reveal-io and .in elsewhere. */
@media (prefers-reduced-motion: no-preference) {
  @supports (animation-timeline: view()) {
    .reveal { animation: rise linear both; animation-timeline: view(); animation-range: entry 0% entry 75%; }
  }
  .reveal-io .reveal:not(.in) { opacity: 0; }
  .reveal-io .reveal.in { animation: rise var(--t-slow) var(--ease-out) calc(var(--i, 0) * 90ms) backwards; }
  details[open] > p { animation: unfold var(--t-base) var(--ease-out); }
  summary::after { transition: rotate var(--t-base) var(--ease-out); }
  details[open] summary::after { rotate: 180deg; }
  .button { transition: background-color .2s, scale var(--t-fast) var(--ease-out); }
  .button:active { scale: .97; }
}
details { perspective: var(--persp-card); }
@keyframes settle { from { transform: rotateX(12deg) scale(.96); } }
@keyframes rise { from { opacity: 0; translate: 0 32px; rotate: x 10deg; } }
@keyframes unfold { from { opacity: 0; translate: 0 -6px; rotate: x -12deg; } }
@keyframes fade { from { opacity: 0; } }
@keyframes pop { from { opacity: 0; transform: translateZ(0) scale(.8); } }
```

**`site/static/motion.js`** is byte-identical in both repos and loads from `layout.html` right after the stylesheet
link: `<script src="/motion.js" defer></script>`. The build prefixes `src="/`, and `--check` confirms the file
exists. It has three jobs:

1. **Tilt.** Write `--px`/`--py` on the hovered `[data-tilt]` element and toggle `.tilting`. This happens only for
   a mouse, without Reduce Motion, throttled to one rAF per frame. It resets on scroll and when the pointer leaves
   the window.
2. **Reveal fallback.** Where `animation-timeline: view()` is unsupported (Firefox stable), add `.reveal-io` to
   `<html>` and give `.in` to each `.reveal` as it enters, staggered within each batch. Anything already on screen at
   load gets `.in` before the class goes on, so it never flashes.
3. **Flip.** Unhide each `[data-flip]` button and make it toggle `.flipped` on its `aria-controls` target, keeping
   `aria-pressed` in sync.

With no JS, the pages are complete and still. Hero sequences are pure CSS and need no JS.

```js
// Motion for the EverydayOpen sites (docs/MOTION.md). Every page is complete and static without it.
(() => {
  const root = document.documentElement;
  const calm = matchMedia('(prefers-reduced-motion: reduce)');
  const fine = matchMedia('(hover: hover) and (pointer: fine)');

  // Tilt: --px/--py (-1..1 from the center) on the hovered [data-tilt]; CSS turns them into rotation and glare.
  // The box is read once per element entered, so the tilt never feeds back into it.
  let el = null, box, x = 0, y = 0, frame = 0;
  const enter = (t) => {
    if (el) {
      el.classList.remove('tilting');
      el.style.removeProperty('--px');
      el.style.removeProperty('--py');
    }
    el = t;
    if (el) {
      el.classList.add('tilting');
      box = el.getBoundingClientRect();
    }
  };
  const unit = (v, start, size) => Math.max(-1, Math.min(1, (v - start) / size * 2 - 1)).toFixed(3);
  const draw = () => {
    frame = 0;
    if (!el) return;
    el.style.setProperty('--px', unit(x, box.left, box.width));
    el.style.setProperty('--py', unit(y, box.top, box.height));
  };
  addEventListener('pointermove', (e) => {
    if (e.pointerType !== 'mouse' || calm.matches || !fine.matches) return;
    const t = e.target.closest ? e.target.closest('[data-tilt]') : null;
    if (t !== el) enter(t);
    x = e.clientX;
    y = e.clientY;
    if (el && !frame) frame = requestAnimationFrame(draw);
  }, { passive: true });
  addEventListener('scroll', () => el && enter(null), { passive: true });
  root.addEventListener('pointerleave', () => enter(null));

  // Reveal, where CSS scroll-driven animations don't exist yet (Firefox): .in when it enters, staggered per batch.
  const items = document.querySelectorAll('.reveal');
  if (items.length && !calm.matches && !CSS.supports('animation-timeline: view()') && 'IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => {
      entries.filter((e) => e.isIntersecting).forEach((e, n) => {
        e.target.style.setProperty('--i', Math.min(n, 6));
        e.target.classList.add('in');
        io.unobserve(e.target);
      });
    }, { rootMargin: '0px 0px -8% 0px' });
    items.forEach((e) => (e.getBoundingClientRect().top < innerHeight ? e.classList.add('in') : io.observe(e)));
    root.classList.add('reveal-io');
  }

  // Flip: a [data-flip] button turns the card named by aria-controls over and back.
  document.querySelectorAll('[data-flip]').forEach((b) => {
    const card = document.getElementById(b.getAttribute('aria-controls'));
    if (!card) return;
    b.hidden = false;
    b.addEventListener('click', () => b.setAttribute('aria-pressed', card.classList.toggle('flipped')));
  });
})();
```

### 1.8 Shared SwiftUI code (PROPOSAL, written, not compiled)

Both apps get the same pointer tilt, in `App/DesignSystem/Tokens.swift`. It uses only macOS 13 APIs:
`onContinuousHover` is macOS 13, and `rotation3DEffect`, `RadialGradient` and `mask` are older. **Whydunit** (macOS
15) replaces the `.background(GeometryReader …)` line with
`.onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }`, which avoids the one-argument `onChange`
that is deprecated from macOS 14.

```swift
/// Turns a surface to face the pointer (the edge under it recedes), at most `max` degrees, with an optional glare
/// masked to the content's own shape. Flat under Reduce Motion. The pointer is read in the layout frame, so the
/// tilt never moves hit areas.
struct HoverTilt: ViewModifier {
    var max = 7.0
    var glare = false
    @State private var size = CGSize.zero
    @State private var p = CGPoint.zero          // -1...1 from the center
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if glare && hovering {
                    RadialGradient(colors: [.white.opacity(0.28), .clear], center: .center,
                                   startRadius: 0, endRadius: size.width * 0.6)
                        .offset(x: p.x * size.width / 2, y: p.y * size.height / 2)
                        .mask { content }            // VERIFY: content drawn twice; fine for an icon and one card
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            // VERIFY on a Mac: the edge under the pointer should recede; negate both angles if it rises instead.
            .rotation3DEffect(.degrees(-p.y * max), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(p.x * max), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .background(GeometryReader { g in
                Color.clear.onAppear { size = g.size }.onChange(of: g.size) { size = $0 }
            })
            .onContinuousHover { phase in
                guard !reduceMotion, size.width > 0, size.height > 0 else { return }
                switch phase {
                case .active(let at):
                    withAnimation(Motion.follow) {
                        hovering = true
                        p = CGPoint(x: at.x / size.width * 2 - 1, y: at.y / size.height * 2 - 1)
                    }
                case .ended:
                    withAnimation(Motion.spring(false)) {
                        hovering = false
                        p = .zero
                    }
                }
            }
    }
}
```

The `Motion` additions (`spring`, `hero`, `pop`, `follow`) are in each app's section, spelled for its deployment
target.

**Sources:** WebKit, "WebKit Features in Safari 26.0" (webkit.org/blog/17333) and "WebKit Features for Safari
26.4" (webkit.org/blog/17862); Firefox's `layout.css.scroll-driven-animations.enabled` flag status (mid-2026
developer guides); Apple docs for `onContinuousHover(coordinateSpace:perform:)` (macOS 13) and
`rotation3DEffect(_:axis:anchor:anchorZ:perspective:)`; SF Symbols 6 effects `wiggle`, `breathe` and `rotate`
(macOS 15; WWDC24 "What's new in SwiftUI"). `keyframeAnimator` is deliberately unused. Nobody has checked whether a
one-shot run rests on the last keyframe or on `initialValue`, and plain `@State` plus a spring does the same job on
every macOS version without that question.


## 2. Outboard website

### 2.1 The story in 2.8 seconds, the leave, the return and the flip

The quay is dark. The lamp lights: a small aqua point on its post at the quay's edge, and its pool spreads on the water.
The quay settles into place, full to the brim; the boat slides in from the right and moors alongside, mostly empty; the
gangway extends between them. Then the crates cross, one by one: Xcode build data, Ollama models, iPhone backups lift
off the quay, travel the gangway and settle on the boat, each 160 ms after the last. As each one leaves, a painted
outline draws in where it stood and a thin tether runs from the outline across the gangway to the crate. The Storage
Plan card deals in at the front right. Then the page is still: the pointer tilts the scene up to 5°, which parallaxes
the crates against the boat and the card against the water.

Press **Unplug the drive**. The boat slides out to the right and back, taking the crates with it; the gangway folds to
the quay; the tethers slacken and fade; a small note card pins itself to each outline; the lamp dims to a parked glow.
The quay's bar does not change: the hatched "kept until you confirm" segment stays, because the originals are still on
the Mac. The button reads **Plug it back in** and reverses every step: the boat returns, the gangway extends, the notes
lift off, the tethers draw back, the lamp relights. Press **Turn the card over** and the card turns on its vertical axis
to show its back: the footnote and "Not counted". The headline, lede and both page buttons never move.

| t (s) | What happens | Element | Easing |
|---|---|---|---|
| 0.00–0.50 | The lamp lights (the core `scale 0 → 1`, the glow fades in) | `.lamp-core`, `.lamp-glow` | `--ease-out` |
| 0.10–0.80 | The water and its pool fade in (opacity on a flat plane) | `.water` | `--ease-out` |
| 0.30–1.00 | The quay settles (rises 16px into place and fades in) | `.quay` | `--ease-out` |
| 0.45–1.15 | The boat moors (slides in from `translate3d(120px, 0, -30px)` to rest, fades in) | `.hull` | `--ease-out` |
| 0.80–1.10 | The gangway extends (`scaleX 0 → 1` from the quay end) | `.gangway` | `--ease-spring` |
| 1.00–2.32 | The crates cross: each from over its outline on the quay (`translate3d(dx − 440px, dy + 40px, 0) scale(.96)`, opacity 0) to its stepped place on the boat, 160 ms apart, 1 s each | `.crates li` | `--ease-in-out` |
| 1.30–2.22 | As each crate leaves, its outline draws in (opacity 0 → .55) and its tether extends (`scaleX 0 → 1`), 160 ms apart | `.outline`, `.tether` | `--ease-out` |
| 2.10–2.80 | The card deals in (`translate3d(0,-14px,80px) scale(.98)` → rest), its face fades in | `.report-wrap`, `.report .face` | `--ease-out` |

**The leave** (1.0 s, on the button; reversible):

| t (s) | What happens | Element | Easing |
|---|---|---|---|
| 0.00–0.80 | The boat slides out and back (`translate3d(160px, 10px, -60px)` appended to its rest transform), opacity 1 → .45 over the last 0.6 s | `.swept .hull` | `--ease-in-out` |
| 0.00–0.80 | The crates go with it (the same shift appended), opacity → .45 | `.swept .crates li` | `--ease-in-out` |
| 0.00–0.40 | The gangway folds (`scaleX 1 → .1` from the quay end) | `.swept .gangway` | `--ease-in-out` |
| 0.10–0.70 | The tethers slacken (`scaleX 1 → .35`) and fade (opacity .9 → 0 over 0.4 s from 0.3 s) | `.swept .tether` | `--ease-in-out` |
| 0.50–0.90 | The notes pin (opacity 0 → 1, `translate 0 -4px → 0 0`) | `.swept .note` | `--ease-spring` |
| 0.30–0.90 | The lamp dims (the glow opacity 1 → .25, the core 1 → .45) | `.swept .lamp-glow`, `.swept .lamp-core` | `--ease-out` |
| — | The quay, its bar and its outlines move 0 px | `.quay`, `.bar`, `.outline` | none |

**The return** reverses every transition over the same durations (the same class toggled off): the boat moors, the
gangway extends, the tethers draw back, the notes lift, the lamp relights. The button reads "Plug it back in", not
"Undo" or "Reconnect", because the page must not pretend the demo did anything to a Mac.

**The flip** (0.6 s, on the card button; the shared `data-flip` job): `.report` rotates `0 → 180deg` on Y under
`--ease-out`; the faces are `backface-visibility: hidden`, so nothing is drawn twice. Reduce Motion swaps the faces
by `visibility` without animation (§1.5).

### 2.2 DOM

The hero DOM is in DESIGN §4.2. The only motion-related attributes: `id="hero-scene"` on `.scene` (the leave button's
`aria-controls`), `data-sweep="Plug it back in"` with `data-sweep-said` and `data-sweep-reset` (the live-region
strings), `id="hero-card"` on `.report` (the flip button's `aria-controls`), and the `.sr-only[data-sweep-status]`
live region beside the leave button. The sweep job toggles the class `swept` on the scene; this file's CSS uses that
class name so `motion.js` stays byte-identical with Aftertaste's.

Every `.card` in the "Where the space went", "Never", FAQ, source and download-step sections: `class="card reveal"
data-tilt`. The crate columns in "What it moves": `class="crates reveal" data-tilt`. The ledgers, the proof strip, the
guard section's static leave, the honest-limits list, the FAQ panel and the filmstrip: `reveal` only, no tilt.
`layout.html`: `<script src="/motion.js" defer></script>` after the stylesheet link.

### 2.3 CSS (append after the shared block in §1.7; about 3.6 KB)

The rest state is written first (DESIGN §4.2); everything below is movement under `no-preference`, plus the leave's
and the flip's state rules, which apply with or without motion so the buttons still swap states.

```css
/* Hero (MOTION.md §2): the lamp lights, the water pools, the quay settles, the boat moors, the gangway extends, the
   crates cross, the outlines and tethers draw in, the card deals in. Opacity sits on flat elements only: .water,
   .lamp-core, .lamp-glow, .quay, .hull, .gangway, .crates li, .outline, .tether, .note, .report .face (never on .scene,
   .dock, .crates or .report-wrap, which are preserve-3d or hold a 3D child). */
@media (prefers-reduced-motion: no-preference) {
  .lamp-core { animation: lamp .5s var(--ease-out) backwards; }
  .lamp-glow { animation: fade .5s var(--ease-out) backwards; }
  .water { animation: fade .7s var(--ease-out) .1s backwards; }
  .quay { animation: settle-quay .7s var(--ease-out) .3s backwards; }
  .hull { animation: moor .7s var(--ease-out) .45s backwards; }
  .gangway { animation: extend .3s var(--ease-spring) .8s backwards; }
  .crates li { animation: cross 1s var(--ease-in-out) backwards; }
  .crates li:nth-child(1) { animation-delay: 1s; } .crates li:nth-child(2) { animation-delay: 1.16s; } .crates li:nth-child(3) { animation-delay: 1.32s; }
  .outline { animation: fade .4s var(--ease-out) backwards; }
  .tether { animation: draw .6s var(--ease-out) backwards; }
  .outlines li:nth-child(1) .outline, .outlines li:nth-child(1) .tether { animation-delay: 1.3s; }
  .outlines li:nth-child(2) .outline, .outlines li:nth-child(2) .tether { animation-delay: 1.46s; }
  .outlines li:nth-child(3) .outline, .outlines li:nth-child(3) .tether { animation-delay: 1.62s; }
  .report-wrap { animation: deal .7s var(--ease-out) 2.1s backwards; }
  .report .face { animation: fade .5s var(--ease-out) 2.1s backwards; }
  /* The leave's and the return's transitions (the same rules run both ways). */
  .hull, .crates li { transition: transform .8s var(--ease-in-out), opacity .6s var(--ease-out) .2s; }
  .gangway { transition: transform .4s var(--ease-in-out); }
  .tether { transition: transform .6s var(--ease-in-out) .1s, opacity .4s var(--ease-out) .3s; }
  .note { transition: opacity .4s var(--ease-spring) .5s, translate .4s var(--ease-spring) .5s; }
  .lamp-glow, .lamp-core { transition: opacity .6s var(--ease-out) .3s; }
  /* The flip. */
  .report { transition: transform .6s var(--ease-out); }
}
/* The swept state (rest state of the leave; applies with or without motion). Each transform keeps the rest function list
   in the same order and appends to it, so every engine interpolates per function (never a matrix decomposition). */
.swept .hull { transform: translate3d(0, 0, -30px) translate3d(160px, 10px, -60px); opacity: .45; }
.swept .crates li { transform: translate3d(var(--dx), var(--dy), var(--dz)) scale(1) translate3d(160px, 10px, -60px); opacity: .45; }
.swept .gangway { transform: translateZ(-15px) rotateY(-8deg) scaleX(.1); }
.swept .tether { transform: rotate(var(--ta)) scaleX(.35); opacity: 0; }
.note { translate: 0 -4px; }
.swept .note { opacity: 1; translate: 0 0; }
.swept .lamp-glow { opacity: .25; }
.swept .lamp-core { opacity: .45; }
/* The flipped state. */
.report.flipped { transform: rotateY(180deg); }
@keyframes lamp { from { transform: scale(0); } }
@keyframes settle-quay { from { opacity: 0; transform: translate3d(0, 16px, 0); } }
@keyframes moor { from { opacity: 0; transform: translate3d(120px, 0, -30px); } }
@keyframes extend { from { transform: translateZ(-15px) rotateY(-8deg) scaleX(0); } }
@keyframes cross { from { opacity: 0; transform: translate3d(calc(var(--dx) - 440px), calc(var(--dy) + 40px), 0) scale(.96); } }
@keyframes draw { from { transform: rotate(var(--ta)) scaleX(0); } }
@keyframes deal { from { transform: translate3d(0, -14px, 80px) scale(.98); } }
```

Notes:

- **The moored state is the rest state** (DESIGN §4.2), so Reduce Motion, print and no-JS show the crates on the boat,
  the outlines with their tethers and the lamp lit. The `cross` keyframe only supplies the `from`.
- **Custom properties inside keyframes.** `cross` and `draw` end at each element's own `--dx/--dy/--dz` and `--ta` rest
  transform (the `to` is the element's computed value), so one keyframe serves three crates and three tethers. `calc()`
  with `var()` inside a keyframe is VERIFY in Firefox (expected fine since Firefox 57) and Safari.
- **Per-function interpolation.** The rest transform `translate3d(var(--dx), var(--dy), var(--dz)) scale(1)` and the
  swept transform start with the same functions in the same order, so the browser interpolates each function rather
  than decomposing a matrix (which would spin the crate). Never reorder them. The appended `translate3d` interpolates
  from identity. The same holds for `.hull` (`translate3d(0,0,-30px)` first) and `.gangway` (`translateZ rotateY` first,
  `scaleX` appended, present in the rest rule as `scaleX(1)` is implied: write it explicitly if an engine jumps).
- **The lamp dims by opacity**, never by a `box-shadow` or `background` transition (§1.6): the glow and the core are
  separate flat elements under `.lamp`, which holds the `translateZ(-200px)` and is not `preserve-3d`.
- **`.report` rotates, `.report-wrap` does not:** the wrap holds the `translateZ(80px)` plane and the card's own
  `perspective`, so the flip never fights the scene tilt.
- **Reduce Motion:** every animation and transition is inside `no-preference`; the `.swept` and `.flipped` rules are
  outside it, so both buttons still swap states, at once and without movement.
- **At ≤ 900px** the card and the lamp's glow are hidden and the dock is static under the copy (DESIGN §4.2), so the
  leave is the boat's fade, the tethers, the notes and the lamp core only. There is no horizontal scroll.

### 2.4 `motion.js`: Aftertaste's file, unchanged

`site/static/motion.js` is the shared §1.7 script with Aftertaste's fourth job appended before the closing `})();`
(about 600 bytes; the file stays under 6 KB). The job toggles `swept` on the button's `aria-controls` target, swaps the
button's text with its `data-sweep` value and writes `data-sweep-said` / `data-sweep-reset` into the live region. It
carries no product copy, so Outboard's copy is byte-identical with Aftertaste's; `diff` against it must be empty.

```js
  // Sweep: the hero's leave button slides the boat out and parks the notes; the same button brings it back.
  document.querySelectorAll('[data-sweep]').forEach((b) => {
    const scene = document.getElementById(b.getAttribute('aria-controls'));
    if (!scene) return;
    const move = b.textContent, reset = b.getAttribute('data-sweep');
    const say = b.parentNode.querySelector('[data-sweep-status]');
    b.hidden = false;
    b.addEventListener('click', () => {
      const on = scene.classList.toggle('swept');
      b.setAttribute('aria-pressed', on);
      b.textContent = on ? reset : move;
      if (say) say.textContent = on ? b.getAttribute('data-sweep-said') : b.getAttribute('data-sweep-reset');
    });
  });
```

(The comment line may differ from Aftertaste's only if both repos adopt the same wording; the site owner keeps the two
files identical and the comment generic.) The button is a real `<button>` with `aria-pressed`, hidden until JS runs,
placed under the dock so showing it moves nothing. Hover never unplugs (people move the mouse over the crates to read
them).

### 2.5 Sections and sub-pages

| Section | Motion |
|---|---|
| Hero text, lede, both buttons, trust line, the "Not yet tried" line | none (LCP: the h1) |
| Hero scene | §2.1 once, then tilt 5° (fine pointers) or scroll lean (phones); the leave, the return and the flip on their buttons |
| Where the space went, Never card, FAQ, source, download steps | reveal plus 7° tilt, glare and scale 1.02 on the `.card`s |
| What it moves (the crate columns) | reveal; 5° tilt on each column; crates never move individually (the crossing belongs to the hero) |
| The Drive Guard, explained (the static leave, the note) | reveal only: the parked state is a fact, drawn still |
| Honest limits | reveal only: text stays still |
| Proof strip, ledgers, receipts, capacity bars, filmstrip | reveal only (text and data stay still) |
| FAQ | answer unfolds; "+" turns into "×" |
| Buttons | press sinks 1px, shadow swapped |
| Download band | the icon on the quay with its reflection; `data-tilt` 8° on the icon only |
| How it works, what it moves, guides, changelog, 404, llms.txt | no motion beyond reveal and the `--z1` shadow on `pre` and `.summary`; they print |

## 3. Outboard app (macOS 13 deployment, SwiftUI; written, not compiled)

BUILD_PLAN §8: one signature animation, everything else a plain fade, all off under Reduce Motion, nothing moving at
idle, progress by bytes and elapsed time with no estimate. This section says exactly where each of those lives. Every
API is macOS 13 unless it sits in `App/DesignSystem/Compat.swift` behind `if #available`.

### 3.1 Tokens (`App/DesignSystem/Tokens.swift`)

Aftertaste's `Motion` (`standard`, `spring`, `hero`, `pop`, `follow`, `stagger`, `delay(_:_:)`), `HoverTilt`,
`AnyTransition.flip` and `FlipFaces` verbatim (§1.8, Tirekick MOTION §5.1). No new constants.

### 3.2 The tether: the one signature animation

`TetheredOutline(drawn:)` (DESIGN §6.3) is the leading object of every relocation row and of the Try-it-and-confirm
sheet. `drawn` is 1 when the relocation is Healthy and 0 otherwise, derived from `GuardSnapshot` (assigned only when it
changed, so a timer tick that finds nothing new animates nothing):

```swift
/// The line from the outline on the Mac to the copy on the drive. It draws once when a move reaches Swapped (the sheet
/// appears with `drawn` 0 and sets it to 1 in `onAppear` after 0.1 s) and follows health on the Drives screen: drawn
/// while Healthy, withdrawn while the drive is away or the relocation is held. A state change, animated only when the
/// value changes. Under Reduce Motion the line is always full length and only its opacity fades (no movement).
struct TetheredOutline: View {
    var drawn: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Brand.aquaInk)
                .frame(width: 22, height: 16)
            Tether(progress: reduceMotion ? 1 : drawn)
                .stroke(Brand.aquaInk, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .opacity(reduceMotion ? drawn : 1)
                .frame(width: 14, height: 16)
        }
        .opacity(0.9)
        .animation(reduceMotion ? Motion.standard(true) : Motion.spring(false), value: drawn)
        .accessibilityHidden(true)
    }
}
```

On the Try-it-and-confirm sheet the draw is the only entrance (≤ 0.45 s). On the Drives screen a list of rows whose
health changes together (a drive returns) redraws with `Motion.delay(i, reduceMotion)` per row (cap 8): 0.36 s of
stagger plus a 0.45 s spring, under 1 s for the whole list (BUILD_PLAN §8). Rows that did not change do not move.

### 3.3 The lamp and the bar: state, not movement

- `GuardLamp(lit:label:)` (DESIGN §6.3) swaps its fill and glow with `Motion.pop` when `lit` changes; the swap is shown
  under Reduce Motion too (`Motion.standard(true)` there: a 150 ms fade). It never pulses, breathes or blinks. It is
  driven by `guardSnapshot.isAllHealthy` and `prefs.keepGuardRunning`.
- `CapacityBar` segments re-lay out with `Motion.spring(reduceMotion)` on `.animation(_:value:)` keyed to the segment
  bytes: after a rescan, after a move is confirmed, when a drive's free space changes. During Progress the done segment
  widens with `Motion.standard(reduceMotion)` keyed to `MoveProgress.bytesDone` (or `filesDone` while verifying): an
  0.28 s ease between two real values polled 500 ms apart, never an extrapolation. A moved segment's lit edge swaps to
  aqua with `Motion.pop` (a colour swap, shown under Reduce Motion too).
- The Plan total (`Metric("Could free", …)`) uses `.contentTransition(.numericText())` (macOS 13) under
  `.animation(Motion.standard(reduceMotion), value: plan.headlineBytes)`, so a rescan counts to the new number; it never
  counts during a move (the headline is measured, not promised).

### 3.4 Entrances (one per screen, then stillness)

| Screen | Entrance | Length |
|---|---|---|
| Plan | the Storage Plan card preview is dealt once per scan result (`FlipFaces(angle: dealt ? 0 : 180, back: CardBack())` under `Motion.spring`, `dealt` set in `onAppear` after 0.1 s, `.id(plan.measuredAt)`); then `HoverTilt(max: 4, glare: true)`; the group plates and rows are a system list and get no transition | ≤ 0.5 s |
| Drives | none; the lamp's state swap (§3.3) and the tethers (§3.2) when health changes | ≤ 0.45 s per change |
| First run | the icon rises 24pt and fades in on `OnFloor`, `Motion.hero` after 0.1 s; then `HoverTilt(max: 8, glare: true)`; page changes are a crossfade (`.transition(.opacity)`, `Motion.standard`) | ≤ 1 s |
| Consent sheet | the system sheet animation only; a blocker row's state word changes with `Motion.standard` (no colour, no shake) | system |
| Progress | none; the bar follows real progress (§3.3); the system `ProgressView` spins during preflight and swapping | while work runs |
| Try it and confirm | the tether draws once (§3.2) | ≤ 0.45 s |
| Result | the green check `.bounce(on:)` once on macOS 14+ (Compat) when the verification line appears; nothing on 13; an aborted move's difference rows appear with a plain fade | ≤ 0.5 s |
| Activity, guided card, preferences, About, banner, edge states | none (About's icon has `HoverTilt(max: 8, glare: true)` and no arrival) | 0 |

Under Reduce Motion every entrance is `Motion.standard(true)`: a 150 ms fade, no movement, no tilt, no flip, no
bounce.

### 3.5 Hover, press and selection

- `MooringButtonStyle` and `KeyCapStyle` sink 1–2pt on press with `Motion.pop`; shadows are constant per state and
  never animated (§1.4).
- Ticking a consent box toggles its checkbox with the system's animation; the "Move 41 GB" button enables with
  `Motion.standard` (opacity 0.4 → 1), no movement.
- `HoverTilt` is used on exactly three views in the whole app (the Plan card preview, the first-run icon, the About
  icon), never more than two on screen at once: never on list rows, drive plates, crates, bars, the lamp or banners.
- Hover state lives in the modifier's `@State`, never in `AppModel`.

### 3.6 What doesn't move, and why

- The menu bar glyph never animates; its attention variant is a different template image swapped by
  `guardSnapshot.showsAttentionDot` (the `MenuBarExtra` reads derived state and never writes back: the Aftertaste
  re-render lesson, BUILD_PLAN §8).
- The banner strip appears and disappears with `Motion.standard` (a fade), never a slide; "is back" arrives exactly
  like "was removed" (§1.1 rule 3). Nothing shakes on Held, Conflict or Needs attention.
- The lamp never pulses; the boat never rocks; there is no wave, no ripple, no tide at idle.
- The crossing belongs to the site. In the app no crate crosses a gangway: the only honest motion during a move is the
  bar following the bytes that have actually been copied and compared. No `matchedGeometryEffect` from a Plan row to a
  drive plate.
- The consent sheet is still. People read it before a 41 GB folder is renamed.
- The Needs-attention facts, the Activity list and the export never animate: they are lists of facts.
- Nothing in `PlanCardView` moves (`ImageRenderer` draws it); the deal and the tilt wrap it from outside.
- No loop anywhere except the system `ProgressView` while a move, a check or a rescan runs.
- **Not doing:** a percentage or time estimate on any bar (bytes and elapsed time, files while verifying); a
  `phaseAnimator` or `keyframeAnimator`; glass on content; symbol effects beyond the one bounce on macOS 14+; a shake
  or a red flash anywhere; an animated unplug warning.

## 4. Budgets, acceptance and how to verify without a Mac

### 4.1 Budgets

| Website item | Hard cap | Measure |
|---|---|---|
| `site/static/styles.css` | 40 KB | `wc -c`; `BUDGET` in `build_site.py` |
| `site/static/motion.js` | 6 KB (Aftertaste's file byte for byte) | `wc -c`; `diff` against Aftertaste's is empty |
| Webfonts, CDNs, third-party requests, trackers | 0 | the Network panel on a cold load |
| Home HTML (built) | 36 KB | `wc -c site/_dist/index.html` |
| Home first load, uncompressed (HTML + CSS + JS + icon + favicon) | 110 KB | sum of the above |
| Hero sequence | ≤ 2.8 s, once; ≤ 4 planes | §2.1 table |
| The leave / the return / the flip | ≤ 1.0 s / ≤ 1.0 s / ≤ 0.6 s per press; reversible | §2.1 tables |
| CLS / LCP | 0 / the h1 | the siblings' snippets |

| App item | Budget |
|---|---|
| CPU after any entrance settles (Plan, first run, try-and-confirm, result) | 0% in Activity Monitor within 2 s |
| Loops | only the system `ProgressView` while a move, a check or a rescan runs |
| The tether | ≤ 0.45 s per row; a list ≤ 1 s on a 45 ms stagger, cap 8 |
| Entrance lengths | first run ≤ 1 s; the card deal ≤ 0.5 s; the lamp swap ≤ 0.32 s |
| `HoverTilt` views on screen | ≤ 2 |
| macOS 13 | every API outside `Compat.swift` is macOS 13 |
| New files | `App/DesignSystem/{Tokens,Compat,Surfaces,Controls,Motion,CapacityBar,GuardLamp,Tether,Moored,NoteCard,MenuBarIcon}.swift`; no assets beyond the icon set, no dependencies |

### 4.2 Acceptance checklist

**Website, all pages**

- [ ] `python tools/build_site.py --check` passes: links (including `/motion.js`), one `<h1>`, alt text, contrast with
      exactly two `:root` blocks, no `data-theme`/`localStorage`, no inline style or script, the exact CSP, budgets,
      no banned phrase in the built pages, the "Not yet tried on a real Mac." marker while the rule holds.
- [ ] With Reduce Motion: the moored state is simply there (lamp lit, quay, boat, gangway, three crates with tethers,
      card); nothing lights, slides, crosses or tilts; pressing the leave button swaps to the swept state at once and
      "Plug it back in" swaps back; the card button swaps the faces at once.
- [ ] With JavaScript off: the page is complete and still in the moored state and both buttons stay hidden.
- [ ] Light and dark are right: a cool paper quay at noon, a cool near-black quay at dusk; the lamp is aqua in both;
      the card keeps its fixed night colours.
- [ ] At 360×740: no horizontal scroll; the card and the lamp's glow are hidden; the dock is static under the copy;
      the leave still fades the boat, slackens the tethers, pins the notes and dims the lamp core.
- [ ] Firefox shows the reveal fallback and the `cross` keyframe ending at per-element `--dx/--dy/--dz`. Print of the
      "How it works" page shows dark text on white, no shadows, no motion artifacts.
- [ ] Performance: no long task from `motion.js`, no layout or paint while tilting, leaving, returning or flipping
      (only compositor properties: `transform`, `translate`, `opacity`).

**Website, hero**

- [ ] The lamp lights, the water pools, the quay settles, the boat moors, the gangway extends, three crates cross one
      by one leaving outlines and tethers, the card deals in. The page is still after about 2.8 s.
- [ ] "Unplug the drive" slides the boat out with its crates, folds the gangway, slackens and fades the tethers, pins
      three notes, dims the lamp; the quay's bar does not change; the live region says "Sample: the drive left. 3 notes
      parked where the folders were; the lamp is dimmed."; the button reads "Plug it back in" with
      `aria-pressed="true"`; pressing it reverses everything and the live region says the return line. Keyboard (Tab,
      Space, Enter) and tap both work; hover never unplugs.
- [ ] "Turn the card over" shows the footnote and "Not counted"; `aria-pressed` follows.
- [ ] The headline, lede, both page buttons, the trust line and the "Not yet tried" line never move.

**App** (on a Mac, or in CI once it compiles)

- [ ] Plan: the card is dealt once per scan, then tilts up to 4° with glare; the total counts to a new number only on
      rescan; the key-caps sink on press.
- [ ] Drives: the lamp swaps state (no pulse) when health changes; tethers draw and withdraw with a spring, staggered,
      the last within 1 s; rows that did not change do not move; bars re-lay out with a spring after a rescan.
- [ ] Consent: still; the move button enables with a fade; a blocker's state word changes with a fade.
- [ ] Progress: the bar follows bytes, then files; no estimate, no rate; the spinner is the only loop.
- [ ] Try it and confirm: the tether draws once; Result: the check bounces once on macOS 14+ and not on 13.
- [ ] Banner: fades in and out, no slide, no colour, the same for every kind.
- [ ] macOS 13: everything works without the Compat touches. Reduce Motion: fades only; no tilt, no flip, no sink,
      no stagger, no tether draw (opacity only), no bounce. VoiceOver: each Plan row reads "Name, size, method, risk";
      each relocation row reads "Name, size, health"; the bar reads its legend; the lamp reads its label; the Progress
      value is announced only on phase changes (`.accessibilityValue` updates at phase boundaries, not every 500 ms).

### 4.3 How to verify without a Mac

```sh
python tools/build_site.py --check
wc -c site/static/styles.css site/static/motion.js
diff site/static/motion.js ../aftertaste/site/static/motion.js   # must be empty
python tools/build_site.py && python -m http.server 8769 --directory site/_dist   # open http://localhost:8769/outboard/ after copying under that prefix
```

- **Chromium:** DevTools Rendering › emulate `prefers-reduced-motion` and `prefers-color-scheme`; the 360px device
  toolbar; `document.getAnimations()` to step the hero; a `PerformanceObserver` for `layout-shift` and
  `largest-contentful-paint`; the Performance panel while pressing the leave button (no Layout or Paint entries).
- **Firefox on Windows** covers the reveal fallback and `var()`/`calc()` in keyframes. **Safari** needs the owner's Mac.
- **App, by review until CI compiles it:**

```sh
grep -rn "#available" App/ | grep -v DesignSystem/Compat.swift                                                     # nothing
grep -rn "symbolEffect\|phaseAnimator\|keyframeAnimator\|visualEffect\|\.smooth(\|spring(duration" App/ | grep -v Compat.swift   # nothing
grep -rn "repeatForever\|TimelineView" App/                                                                       # nothing (the only loop is the system ProgressView)
grep -n "rotation3DEffect\|HoverTilt\|FlipFaces\|shadow\|material" App/Report/PlanCardView.swift                  # nothing: the PNG stays clean
grep -rn "\.animation(" App/ | grep -v "value:"                                                                   # nothing
grep -rn "HoverTilt(" App/ | wc -l                                                                                # 3
grep -rn "matchedGeometryEffect\|estimated\|remaining\|per second\|MB/s" App/                                       # nothing: no estimate, no rate
```

- Then the macOS CI build is the first compile. Until it is green, call the app code "written, not compiled".

### 4.4 Proposals for other owners (not made here)

- **site (`site/**`):** §2.2–§2.5; `motion.js` = Aftertaste's file unchanged; the `#i-mark` and `#i-ok` sprite
  symbols; the `data-sweep-said` / `data-sweep-reset` strings from DESIGN §4.2.
- **infra (`tools/build_site.py`):** `BUDGET["motion.js"] = 6_000`; in CI run the §4.3 app greps as failures, and a
  `diff` of `motion.js` against the Aftertaste file if the sibling repo is checked out beside this one (otherwise a
  size check only).
- **app-shell (`PlanView`, `DrivesView`, `FirstRunView`, `AboutView`):** §3.4's entrances and the three tilts; the
  tethers and the lamp on Drives.
- **app-content (`ConsentSheet`, `ProgressView`, `ConfirmDialog`, `BannerView`):** §3.3's bar animations keyed to
  `MoveProgress`; §3.2's tether on the try-and-confirm sheet; the banner's fade; the result check's bounce through
  Compat.
- **app-report (`PlanCardView`):** nothing moves inside; the deal and tilt wrap it from outside.
- **architect (BUILD_PLAN §7, frozen):** add "Motion: docs/MOTION.md; design: docs/DESIGN.md" to §7; note that
  `MoveProgress` already carries everything the bar needs (bytes, files, elapsed; no estimate), and that the Drives
  screen needs `RelocationHealth` per row (present in `GuardSnapshot`) for the tether.

**VERIFY (on a Mac or in Safari):** the per-function transform interpolation on the leave in all three engines;
`calc(var())` in `@keyframes` in Firefox and Safari; `backface-visibility` inside a `preserve-3d` card in Safari;
`Tether`'s `animatableData` through `.animation(_:value:)` with per-row delays; `.contentTransition(.numericText())`
with the Plan total; `FlipFaces` and `HoverTilt` signs; the lamp's radial gradient swap under `Motion.pop` (whether
SwiftUI animates the gradient's colours or snaps: a snap is acceptable); `Motion.spring` delays on `.animation(_:value:)`
with per-row offsets.
