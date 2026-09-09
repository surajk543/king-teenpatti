# Critique 1

## Verdict

The **table** clears the bar. The **lobby does not** — it becomes a stack of near-identical charcoal rectangles with the same 1dp gold hairline, which is the 2024 "premium dark UI" template. And two of the three loudest "this is a Flutter app" tells — **Roboto and Material Rounded icons** — are left completely untouched by a document that otherwise specifies alpha values to two decimals.

Below, only things I can point at.

---

## 1. It still reads as a generic Flutter app here

**Typography — the fatal one.** "No font package and no font asset" is a self-imposed constraint the design cannot survive. `_textTheme` is Roboto at w400–w700 with tracking tweaks. `smallCaps()` is not small caps — it is `toUpperCase()` at 0.94× with `letterSpacing: 1.6`. And it is applied to: POT, BOOT, the status line, the category plate, seat status tags, SIDESHOW, VS, drawer section captions, tap-to-sit, PACKED, the pod name row, YOU, the winner headline, the splash studio line, the login provider line, the rules numerals, the toast. That is tracked-uppercase-Roboto on nearly every non-numeric string in the app, which is the single most recognisable "premium template" signature there is.

Worse, it is *broken across languages*: `toUpperCase()` on Devanagari, Bengali, Gujarati and Gurmukhi is a no-op. In a five-language app, `SeatPlaque`'s name row shows **RAVI** and **मीरा** side by side on adjacent pods with matched 1.6 tracking. Same for the status tags via `Strings`. Fix: (a) ship one display face for rank/money/labels — Roboto has no true `smcp`, so this is unavoidable; (b) restrict `smallCaps()` to strings you control (POT, BOOT, VS, SIDESHOW) and never apply it to `Seat.displayName` or to any `Strings` getter.

**Playing card ranks.** You drew `CardPips` as four hand-built Paths — correct, highest-value call in the document — and then left the rank as `Roboto w700, letterSpacing -0.5`. The rank is at `h*0.26` and `h*0.40` for the centre pip; the rank glyph is bigger, higher-contrast, and looked at more than the pip. A card face with hand-drawn pips and a UI sans-serif index is exactly a card app that got 80% of the way. Either draw the 13 rank glyphs as paths beside the pips, or accept a font asset.

**Icons — never mentioned once.** `Icons.menu_rounded`, `Icons.forum_rounded`, `Icons.emoji_events_outlined` (winner banner *and* milestone chip), `Icons.lock_outline_rounded` (capped card), `Icons.visibility_off_rounded` (category plate), `Icons.hourglass_top`, `Icons.block`, `Icons.delete_forever_outlined`, the 18dp outline set in all four drawers. Thirty components, zero say "replace the Material glyph." Material Rounded at 18–22dp is the second tell after Roboto, and `CategoryPlate` explicitly preserves `palette.icon` as an information channel — so the most semantically loaded glyph on the felt stays stock Material.

**Unstyled Material leaking through.** `DropdownButtonFormField` in the settings drawer is not in the component list, and the UI map already flags it ("the default dropdown menu is white/greyscale and will fight a charcoal drawer"). Its menu is a Material popup with its own elevation, radius and surface — it will open as a light rectangle on a sigma-22 charcoal drawer. Same for the `Tooltip`s `ActionConsole` newly introduces ("cost lines fold into tooltips") — stock grey rounded rects on the one screen where nothing else is grey.

**The seat's bet pill is orphaned.** `SeatPod._lastBet` (`seat_pod.dart:305`) is `colorScheme.secondaryContainer` with `onSecondaryContainer` text and a `tertiary`/`secondary` PokerChip. It is not in your component list. Under the new dark scheme that is `#3A2E12` — a muddy olive-brown capsule, and it is the **most frequently visible element on a rim seat during a live hand**, sitting directly under a `SeatPlaque` you have just made `ink600` with a champagne hairline and a `ink900@0.55` recessed StackPill. Same for `_total` ("IN POT n"), which your typography section assigns `smallCaps` but which no component owns. Add both to `SeatPlaque`'s spec or the pod ships half-redesigned.

**Stats drawer numbers.** You restyle it to a two-column figure grid, but the six values still run through `formatChips` — so "Hands played" reads **1.2 Lakh**. The map flags it; the design inherits it silently. A grid makes it more legible, not less wrong.

---

## 2. It reads as a glass showcase here

**The lobby has no solid object left.** LobbyTopRail (glass), LobbyTableCard ×3 (glass), PrivateTableCard (glass), `_CornerChip` ×2 (glass), RewardCelebration (glass), PicturePickerSheet (glass), both drawers (glass), NoticeToast (glass), RulesSheet (glass). The only non-glass element on the entire screen is BuyChipsButton. Your own stated rule — "glass is for what the interface puts *on top of* the game" — is coherent on the table and abandoned in the lobby, where there is no game underneath, so *everything* is chrome and therefore everything is glass. Result: six-plus charcoal translucent rectangles, all `ink700@0.82→ink800@0.90`, all with a 1.0dp `goldBright@0.16` hairline, in one horizontal rail. Nothing in that rail is a different *material* from anything else in it.

**"Exactly one gold hairline weight at exactly two alphas" is over-disciplined into flatness.** 0.16 resting / 0.34 live, one weight, on: every panel, every card, the console, the rail, the bet window, the stack pill, the chat bubble, the pot plinth, the corner chips, the machined key, the code cells, the instrument cluster. Restraint stops being restraint when it is the only edge treatment in the app — you have replaced "five Material container colours" with "one hairline repeated forty times." Give at least three classes a genuinely different edge: the felt rail already has `rimHigh/rimLow` (good), the cards have `cardEdge`, and the chips have their own rim — extend that logic so **containers** differ too (e.g. lobby cards get a two-tone rim like the felt; drawers get no rim at all and separate by shadow).

**`tinted` is not glass and calling it glass inflates the whole vocabulary.** `GlassMode.tinted` = gradient fill + border + 2dp sheen + shadow, no filter — i.e. structurally what `PremiumSurface` already is. LobbyTableCard, PrivateTableCard, the nine store packs, corner chips, PotPlinth, InstrumentCluster and ChatBubble are all `tinted`. So the majority of "glass" components in this system contain no blur at all. That is fine as engineering and misleading as design language: it lets the document claim a glass system while shipping gradient panels, and it hides the fact that the blur budget is being spent in the wrong places (next section).

---

## 3. Load-bearing things that don't work as specified

**`GlassBudget` cannot do what you claim.** You state: *"the winner banner … affordable because GlassBudget has flipped the rail and console to tinted for its lifetime."* It cannot. `_Showdown` is `Positioned.fill` inside the **felt's** Stack; `_SideRail` and `_ActionBar` are siblings of `_Felt` in the outer `Column`/`Row` (`table_screen.dart:71–84`). An `InheritedWidget` re-provided *beneath* the banner reaches only the banner's own subtree. To actually flip the rail and console you need budget state hoisted to `_Root` and *mutated* — which rebuilds `_TableScreenState`, and that build "deliberately subscribes to nothing" precisely because a rebuild tears down an open drawer mid-gesture. The entire "at most 3 blurred, at most 2 persistent" cap rests on this mechanism. Fix: make the budget a `ValueNotifier<int>` owned by `_Root`, consumed by each panel via its **own** `ValueListenableBuilder` (so only the panels rebuild, not the Scaffold), and have overlays push/pop on it in `initState`/`dispose`.

**The two persistent blurs are the two that buy nothing.** `DriftingChips` is `Positioned.fill` as the *first* child of the table Stack — behind the rail and the action bar as well as the felt. So `GlassRail` and `ActionConsole` sit over an animating layer and will re-run their offscreen blur **every frame, for the entire session**. And what they are blurring is a static `TableGround` gradient plus a slow chip: a sigma-12 blur of a smooth gradient produces the same smooth gradient. You are paying two permanent full-region offscreen passes for zero visual information, while the things over genuinely high-frequency backdrops — PotPlinth over flying chips, ChatBubbles over the felt — are forced to `tinted`. The policy is inverted. Fix: rail and console → `tinted` (they lose nothing), and either scope `DriftingChips` to the felt's own bounds or give the rail/console an opaque `ink800` bank.

**`AmbientLamp` with `BlendMode.plus` reintroduces exactly the cost rule 3 forbids.** Your rule: "No BackdropFilter inside the felt's Stack — that Stack repaints every frame." A widget-level non-`srcOver` blend over `Positioned.fill` forces a `saveLayer` across the felt — the largest region on screen — on every one of those same frames. Same class of cost, different name. Fix: fold the lamp into `feltPaint`'s own radial stops (a lighter `lampWarm` stop achieves the read without a composite), or paint it inside the felt's `CustomPainter` where the canvas layer already exists.

**The woven felt cannot be built as written.** "Two `LinearGradient`s with `TileMode.repeated` at ±45°, stops every 3.0 logical px," inside a `const` `BoxDecoration`. `LinearGradient.begin/end` are `Alignment`s normalised to the paint box — you cannot express a 3dp pitch without the box size, and your own performance rule requires every token to stay `const` and deterministic. As specified, the weave pitch scales with the felt: coarse burlap on a tablet, sub-pixel moiré on TP_Small, and it will shimmer against the per-frame repaint. This is the signature texture of the whole redesign. Fix: record a small tile once into a `ui.Image` at device DPR and use `ImageShader` with `TileMode.repeated` — which the document explicitly bans ("no `ImageShader`"). Lift that ban; it is the only correct implementation.

**The translucent chat bubble tail.** `_Bubble` becomes `PremiumGlassPanel(tinted)` at `ink900@0.72` with a 1dp hairline, and the tail is still a separately-positioned `Transform.rotate(π/4)` square told to "inherit the same fill and hairline." It won't work: two 0.72 fills overlap to ~0.92 (a visibly darker wedge at the junction) and the two 1dp borders cross where the tail meets the body, drawing a hairline *through* the bubble. The current design gets away with it only because the fill is opaque. Fix: bubble + tail as a **single `Path`**, filled once and stroked once.

**Contradictory chip-rim spec.** `PokerChip` says dashes are `goldBright@0.85` "when the chip's own luminance is below 0.55, `goldDeep` above — computed from the same `estimateBrightnessForColor` call that already exists." Those are two different thresholds. `estimateBrightnessForColor` flips at luminance **0.337**, not 0.55 (`(L+0.05)² > 0.15`). Pick one. Relatedly, your `gold` rationale states the risk is "near the 0.5 threshold" — I computed it: `#C9A227` = **0.384**, flip point **0.337**, margin **0.047**. Your instinct to freeze `gold` is right; the stated number is wrong, which matters because someone will later "verify" it against 0.5 and conclude they have 0.12 of headroom.

**Light mode is deleted but the toggle is kept.** `SurfaceKind.plaque` is "solid `ink600` to `ink700`" — a constant, not a theme lookup. So are `StackPill` (`ink900@0.55`), `ChatBubble` (`ink900@0.72`), `PotPlinth` (`ink900@0.34`), `BetWindow` (`[ink900, ink700]`), `MachinedKey` (`[ink500, ink600]`), `CategoryPlate` (`ink900@0.42`), `GlassCapsule` ("`ink900@0.42` in BOTH states"), and `LobbyTableCard` (`[ink700@0.82, ink800@0.90]`, no light branch). With `surface: bone200 / scaffoldBackground: bone100`, light mode ships **dark charcoal cards on a parchment lobby with a parchment top rail** — incoherent, not merely unpolished. Meanwhile `rimLight(light)` is `white@0.35` on bone (invisible) and `glassShadow(light)` is 0.18/0.10 (invisible). Either spec a light value beside every `ink*` usage, or make the decision the map warns about — removing a persisted `darkMode` pref plus `dayMode`/`nightMode` strings in five languages across three screens — deliberately.

---

## 4. Smaller specifics

- **`ActionConsole` on TP_Small doesn't fit its own concept.** `consoleH(360) = 55.8`, `keyH = clamp(43.8) → 48`. That leaves **3.9dp total** of surround for a panel whose whole idea is "keys inset into it, not floating on it," plus a 2dp sheen and a 1dp hairline. `PremiumGlassPanel`'s default `EdgeInsets.all(Space.lg)` (14) would overflow it outright. Either raise the `consoleH` floor to ~64 or drop the well/inset conceit below `Breaks.compact`.
- **A fourth breakpoint is introduced while claiming to unify three.** `Breaks` has 700 and 1000; `ActionConsole` then uses a bare `w >= 860`. Put it in `Breaks`.
- **Seven radii is a range, not a system.** `lg 16` / `xl 18` / `xxl 20` are not distinguishable on adjacent elements, so every call site gets an ambiguous choice for no visual return. Collapse to three plus `pill`.
- **The spacing scale is not 4-based** (6, 10, 14, 28 aren't multiples of 4). It's fine as a ~1.4× ramp — just don't label it 4-based, or someone will "fix" it.
- **The bet-flight ripple has two owners.** `BetFlights` says "one 220ms `goldBright@0.22` ripple, `size*1.2 → 3.0`"; `PotPlinth` says "one `goldBright@0.18` ripple, `podW*0.3 → 0.9`." Different alpha, different geometry, different widget. `PotPlinth` already diffs pot-on-increase (`_PotChips`) — give it to the plinth alone and delete it from `BetFlights`, which you rightly want untouched.
- **"Two ambient beats" is not achieved.** `SpinningChip` (1100+3400 = 4500) and `LivelyChipStack`'s float (3200) are ambient, appear on the lobby cards, the reward panel, the resume veil and the store, and are unaddressed. On the lobby you still have 4500, 3200, 5200, 3800 and 28000 running simultaneously.
- **`MachinedKey`'s disabled state.** Spec says disabled loses the gold border and drops to `ink700` — but the "1dp `white@0.08` top-inside bevel on an inner DecoratedBox" is a child, not a `WidgetStateProperty`, so a disabled key keeps a lit top edge and still reads as raised. Since disabled is your only illegal-move signal, resolve the bevel through state too.

---

## 5. Genuinely good — don't let the above obscure it

`TableGround` + `feltPaint` + the two-tone `rimHigh/rimLow` rail is the right idea and the highest-leverage change here. Decoupling `bevel` from `radius` fixes a real bug (the felt's `h/2` radius currently paints a sheen over half the table). Keeping seat pods **solid** against five BackdropFilters is the correct engineering call and correctly argued. `FontFeature.tabularFigures()` across every count-up is cheap and right. "Disabled loses the gold rather than changing colour" is a genuinely good rule. `CardPips` as paths, the `DealerButton`, the radial showdown scrim centred on the winner, unifying the three disagreeing pot Y-positions into `_kPotDy`, fixing `_FireworksPainter.shouldRepaint`, and `withClampedTextScaling` at `_Root` are all correct. And the document's handling of the `doNotTouch` list — `_Blink`'s nullable controller, `_BetFlights`' element identity, `_Dealt`'s key, `Seat.chips == null`, `options.show`, the `raiseIndex` ladder, the `'bonus'`/`'milestone'` literals — is careful and accurate throughout; that discipline is rarer than the visual work.

**Shortest path to the bar:** ship a display face, replace the Material icon set, un-glass the lobby (make table cards solid lit objects — they are the products), fix the `GlassBudget` mechanism, make the rail and console `tinted`, and either spec light mode or delete it.

---

# Critique 2

## Verdict up front

**Table screen, as specified: 2 persistent BackdropFilters (GlassRail σ12, ActionConsole σ16) + 1 transient (drawer σ22 / winner banner σ20 / sideshow prompt σ22 / chip store σ24) = 3 concurrent blurs in the exact moments the frame is already worst.** The document's cap of "3 composited, 2 persistent" is honoured arithmetically and is still unaffordable, because the cost model behind it is wrong for this screen. **The correct number of persistent blurs on the table is zero, and at most one transient.**

The reason is not the 1-second ticker. It's this:

---

## 1. The table screen's backdrop is dirty on *every* frame, forever — so a "persistent" BackdropFilter is a 60fps blur, not a one-off pass

Three animating children of the felt `Stack` (`table_screen.dart:538-555`) have **no `RepaintBoundary`**:

- `_AmbientGlow` (`:2545`) — `AnimationController(3800ms)..repeat(reverse: true)`, returns a bare `AnimatedBuilder > DecoratedBox`. Ticks at 60fps from the moment the table mounts until it unmounts. Never idle.
- `_BetFlights` (`:2681`) — returns a bare `Stack`, raw `Ticker`.
- `DriftingChips(strength: 2.4)` (`:70`) — `Positioned.fill` at the **bottom of the screen Stack**, i.e. *under everything*. Its `build` reconstructs 7 `Positioned > Opacity > Transform.rotate > PokerChip` on every tick of a 28s `repeat()` controller. Seven `Opacity` saveLayers and seven `CustomPaint`s, re-created and re-painted 60 times a second, with **no `RepaintBoundary` anywhere in the file**.

The nearest `RepaintBoundary` ancestor of any of these is effectively the screen root. So today, at rest, in `WAITING` state, with nobody acting: the whole table screen — drifting chips, felt gradient + three shadows, five `PremiumSurface` pods with their gradients and shadow stacks, every card, the rail, the action bar — repaints every frame.

`BackdropFilter` does not cache. It re-reads and re-blurs its backdrop every frame the backdrop repaints. Your note that *"the rail's and console's glass shells are const-constructed with only their contents rebuilding inside, so the filter layer is retained across ticks"* is optimising the wrong axis: const-constructing saves **widget/element** work; it does nothing about **raster** work, which is what a blur is. The filter layer is not retained across a dirty backdrop.

So GlassRail and ActionConsole are not "2 blur passes". They are **2 full saveLayer + gaussian passes per frame, for the entire session**.

Area: rail ≈ 44×336dp, console ≈ 612×64dp → ~54,000 dp² of a 230,000 dp² screen = **23% of the screen blurred every frame**. On TP_Small (Nexus 5, 640×360dp at DPR 3.0) that's ~490,000 device pixels through σ12 and σ16 gaussians, in two separate offscreen buffers, 60×/sec. Against a stated 8ms raster budget that also has to hold the felt, five pods, bet flights and fireworks — no.

And the proposal *adds* to the dirty backdrop: **DriftingChips gains "one shared `ImageFiltered(blur sigma 1.6)`"**. That's a third blur pass, in the always-animating subtree, positioned *below* the other two, so its output is what they then re-read. The `RepaintBoundary` you put around it is inert — the subtree it wraps is dirty every frame by construction.

**Fixes, in order of value:**
1. **Delete `DriftingChips` from the table screen.** Seven chips visible only in the thin margin around an opaque oval, at 2.4× opacity to compensate for being invisible. `TableGround`'s vignette replaces what it was for. This single deletion removes a full-screen 60fps repaint that sits under everything else.
2. `RepaintBoundary` on `_AmbientGlow`/`AmbientLamp` and on `_BetFlights`. Both animate independently and neither has one.
3. `RepaintBoundary` per `SeatPod`, and around the felt body itself. Five pods currently re-rasterise their gradient + three-layer shadow + border every frame because a lamp is breathing three layers below them.
4. Only then consider whether any blur is affordable.

---

## 2. `GlassBudget` does not work as described

> "Any full-screen blurred overlay re-provides `blurAllowance: 0` **beneath itself**, which flips every `auto` panel underneath to `tinted` for its lifetime."

An `InheritedWidget` affects its **descendants**, not the widgets painted beneath it. `GlassRail` and `ActionConsole` are children of `_TableScreenState`'s `Scaffold.body` `Column`. The winner banner is inside `_Felt`'s Stack — a *sibling* subtree. The drawer is `Scaffold.drawer` — a sibling. Dialogs, `showModalBottomSheet` and `showGeneralDialog` (the chip store) push **Navigator routes**, which live in the Overlay, an entirely different subtree. None of them is an ancestor of the rail or the console. Providing `GlassBudget(0)` from any of them demotes nothing.

Consequence: the mechanism specifically designed to make the showdown cost one pass instead of four **demotes zero panels**, and the showdown costs rail(σ12) + console(σ16) + banner(σ20) — three concurrent blurs, over a felt that is simultaneously running `Fireworks` (2600ms repeat), `_PotToWinner` (9 chips, 1700ms) and the lamp.

If you want this, the budget has to be a mutable value hoisted **above** `_Root`'s screen switch — an `InheritedNotifier` over a `ValueNotifier<int>` that each overlay decrements on mount and restores on dispose. It must **not** live on `GameState`, or every change routes through the 1s-notifier path and rebuilds the lobby.

Also note the flip is not free either way: making every `auto` panel depend on the budget means a budget change rebuilds all of them. That's fine at twice per hand; it is not fine if anything ever derives the budget per-frame.

---

## 3. All four drawers violate the proposal's own rule 4

> "**No BackdropFilter inside an animating `Transform` or `Opacity`.**"

A `Scaffold` drawer *is* animated by a slide `Transform` (`DrawerController`, ~246ms). `GlassDrawerPanel(mode: blurred, sigma: 22)` is therefore a moving BackdropFilter over a live table — the pathological case, because the sampled backdrop region changes every frame and nothing whatsoever can be reused. Add the rail and console (§2: not demoted) and the doc's own acceptance test — *"again with the chat drawer open over a live turn"* — is precisely the case that will miss frames.

Same for `showModalBottomSheet` (picture picker, σ22) and `showGeneralDialog` (chip store, σ24, which also mounts its **own second** `DriftingChips(strength: 1.7)` on top of the table's).

Drawers and sheets should be `tinted`. They cover their backdrop almost entirely; there is nothing to see through.

---

## 4. `AmbientLamp`'s `BlendMode.plus` is an unforced full-felt saveLayer, every frame

> "drawn with `BlendMode.plus` so it lightens the cloth rather than washing it"

Any blend mode other than `srcOver` on a layer forces an offscreen. Today `_AmbientGlow` is a plain `DecoratedBox(RadialGradient)` with default `srcOver` — **no saveLayer at all**. The proposal turns the largest region on screen into a per-frame offscreen allocate + blend + composite, on a 3800ms `repeat(reverse:)` controller (i.e. permanently), directly under two BackdropFilters that must then re-read the composited result.

Warm light on dark cloth is achievable with a low-alpha `lampWarm` radial in plain `srcOver` — which is literally what the current widget does. Drop `plus`. This is pure cost for no visual delta on a #0F4230 ground.

---

## 5. The felt weave is under-specified and, as described, the most expensive per-pixel thing on screen

> "two `LinearGradient`s with `TileMode.repeated` at +45° and −45°, stops every 3.0 logical px"

You cannot express a 3px tile with `Alignment`-based `begin`/`end` on a `BoxDecoration` gradient — the alignments are fractions of the box, so `TileMode.repeated` will produce a handful of wide diagonal bands across a ~600×300dp felt, not a weave. To get 3px you need a `GradientTransform` scaling the gradient span, at which point you have two repeated-tile shaders evaluating ~1.6M device pixels — **on a subtree that repaints every frame** (§1), **under two BackdropFilters** that re-read it.

Either bake the weave once (a `ui.Picture`/`ui.Image` tile, drawn once and reused — you rejected `ImageShader` on "no new asset" grounds, but a runtime-generated tile is not an asset), or put the felt body behind its own `RepaintBoundary` so the shader runs once and the lamp/flights/pods composite over the cached raster. The second is one line and fixes far more than the weave.

Related: `SurfaceKind.felt`'s two-tone rail is a `SweepGradient` stroke around an `h/2` stadium. Sweep gradients are the most expensive gradient type. It depends on `palette.accent`/`rimHigh`/`rimLow`, so your "hoist `Paint`s to `static final` where they do not depend on inputs" rule doesn't cover it — build it in the painter's **constructor**, never in `paint()`, and make `shouldRepaint` compare all three colours.

---

## 6. Fireworks: 272 `MaskFilter.blur` draws per frame during the worst frame in the game

`fireworks.dart:140` uses `MaskFilter.blur(BlurStyle.normal, 1.2)` per particle. Each masked draw is effectively its own small blur. Today: 26 × 8 = 208. The proposal raises `_perBurst` to 34 → **272 blurred draws per frame**, *plus* a 2px streak line each, at 60fps, concurrently with three BackdropFilters (§2), the 9-chip pot flight, five pods and the lamp.

This is the frame that will visibly hitch, and the doc's proposed lever ("drop the winner banner from `blurred` to `tinted`") removes one of four problems.

**Correct fix:** drop `MaskFilter` entirely. Pre-render one soft 16px dot to a `ui.Image` in `initState` and use **`Canvas.drawAtlas`** — 272 particles collapse to a single draw call with per-particle colour and transform. That is a strictly better-looking result at roughly 1% of the cost, and it makes the higher particle count free rather than expensive.

Your correction to `_FireworksPainter.shouldRepaint` (it omits `bursts` and `palette`) is a genuine bug fix. Keep it.

---

## 7. Card shadows: right idea, wrong prerequisite

Giving the card **back** the face's two-layer shadow means up to 15 backs × 2 blurred rounded-rect shadows = 30 shadow draws, inside the felt Stack that repaints every frame (§1). Blur-radius masks are cached by radius, and your radii are `h*0.045` / `h*0.11` — derived from card height, so pods (podW-derived) and own-hand (handH-derived) generate different mask keys; fine, small set.

This is affordable **only after** each `SeatPod` gets a `RepaintBoundary`. Without one you have added 30 blurred draws to a per-frame repaint. With one, a seat's raster is reused until that seat's data changes, and the shadows cost nothing at rest. Add the boundary in the same change, not later.

Same argument covers `AvatarRing`'s new `BoxShadow(blur 6)` + inner stroke × 5, `SeatPlaque`'s `rimLight` inner stroke, and `StackPill`'s inner top shadow.

---

## 8. Animating `blurRadius` is the expensive axis, and you have two of them

- `_MissedTurns`' 1100ms pulse moves from `Opacity(0.72→1.0)` to a border glow `#FF6B5A@(0.30+0.35v)` **with `blur 4 + 6*v`**. Animating the blur radius regenerates the shadow mask every frame; animating the *alpha* at a fixed blur reuses one cached mask and looks the same at this size. Fix the alpha, freeze the blur.
- `_Blink` (`seat_pod.dart`) already animates two shadows with `blurRadius 10→20` and `26→48` plus `spreadRadius`, at 780ms `repeat(reverse:)`, and the proposal keeps it while adding the plaque's three-layer shadow, a `rimLight` stroke and a 2.4dp border to the same widget. A 48-radius shadow mask regenerated 60×/sec on a pod that has no `RepaintBoundary` is the single most expensive per-pod item today. Boundary it, or freeze the blur and animate alpha.

---

## 9. `_Root`'s AnimatedSwitcher doubles the live ticker count for 300ms

Keying the screen switch on `Screen` keeps the outgoing child mounted. Lobby→table means, concurrently: lobby `DriftingChips(1.0)`, `_CategoryBadge._sheen` ×3, `SpinningChip` ×3, `LivelyChipStack._float` ×3, `Glint` ×3, plus the table's `DriftingChips(2.4)`, `AmbientLamp`, `_BetFlights`, five pods and possibly `_ResumeVeil`'s full-screen σ18 blur — roughly 15 controllers and two full screens painting.

One line fixes it: wrap the **outgoing** child in `TickerMode(enabled: false)` inside your custom `layoutBuilder`. Also: do not apply the 0.985→1.0 scale to both children — a scaling child needs its own `Transform`/layer per side.

`_ResumeVeil` should be `tinted`, not σ18 blurred. It runs during `state.start()` — the network, JSON, `SharedPreferences` and `package_info_plus` moment — and it deliberately hides what's behind it, so the blur is paid for content nobody is meant to see.

---

## 10. Your verification plan will not detect any of this

> "`flutter run --profile` on TP_Small … watch the raster thread"

TP_Small is an **AVD launched with `-gpu host`** on a 12-core dev box (CLAUDE.md §3/§4). The emulator's raster thread runs on the desktop GPU. `BackdropFilter`, `saveLayer` and `MaskFilter` are precisely the operations where an emulator is least representative of an Adreno-class mobile GPU — you can be 5–10× off. `adb logcat | grep overflowed` catches layout, not raster.

If blur ships, it has to be measured on **physical hardware**, or the budget is fiction.

---

## What is genuinely fine — don't spend effort here

- **Every `GlassMode.tinted` call**: PotPlinth, InstrumentCluster, ChatBubble (×5), lobby table cards, private card, corner chips, the nine store pack cards, NoticeToast, the capped lock plate. These are gradient-filled containers with a stroke and a shadow — the same cost class as the existing `PremiumSurface`. Correct calls, and the reasoning ("a real blur over low-frequency cloth is invisible and costs four passes") is exactly right. **Apply that same reasoning to the rail and console and you have solved the whole problem** — a σ16 blur of smooth emerald baize produces smooth emerald baize.
- **Seat pods staying solid.** The most important "no" in the document. Five BackdropFilters over the felt would be unrecoverable.
- **Cards, chips, keys, dealer button, bet window, own-hand fan staying solid.** Correct.
- **`static final Map<double, ui.ImageFilter> _blurCache`.** Right instinct; necessary but not sufficient.
- **Tabular figures.** The cheapest win in the document and it *reduces* work — no text re-layout as digit advances change during the 550/650/700/450ms count-ups.
- **`AppTheme.money()`/`smallCaps()` returning `copyWith` per build.** Not a concern: `TextStyle` has value equality and `const [FontFeature.tabularFigures()]` is const, so a fresh-but-equal style does not re-layout the paragraph. Don't memoise these.
- **`MediaQuery.withClampedTextScaling` at `_Root`.** One inherited value that never changes. Free.
- **Keeping `LiquidFill` and the countdowns on per-frame `DateTime.now()`.** Correct and non-negotiable.
- **Keeping `_TableScreenState.build` subscribed to nothing.** Preserved throughout the proposal. Good.
- **`Dim.*` / `Breaks.*` called in build.** Arithmetic. Free.
- **`ChatCountdownDial`, `CountdownArc`, the segmented milestone track, the sweep dial.** Small `CustomPaint`s driven by existing controllers. Fine — just give each a `shouldRepaint` that compares every input, since `_FireworksPainter` proves that habit isn't universal here.

**One thing sold as a perf win that isn't:** harmonising `Glint` 4200→5200, `_CategoryBadge._sheen` 3800→5200, `_PackCard._pulse` 2400→3800 and the hourglass 3200→3800 onto "two shared beats" changes nothing about cost. Six controllers running at two periods still tick 60fps each and still drive six independent repaints. It's a visual-coherence argument; don't let anyone bank it as headroom.

---

## The change that actually buys the design its glass

Do these four before adding a single `BackdropFilter`:

1. Remove `DriftingChips` from the table screen.
2. `RepaintBoundary` on `AmbientLamp`, `_BetFlights`, each `SeatPod`, and the felt body.
3. Drop `BlendMode.plus`.
4. Replace `Fireworks`' `MaskFilter` particles with `drawAtlas`.

Those are cheap, uncontroversial, and they attack the per-frame repaint of the entire table — which is a bug the current app already has and which the design would otherwise inherit and amplify. Afterwards the backdrop is static at rest, and *then* one blurred `ActionConsole` becomes a genuinely cheap effect, because it only re-blurs when something below it actually moves.

Ship the rail and console as `tinted` regardless. They sit over an emerald gradient. Nobody will see the difference, and it is 23% of the screen.

---

# Critique 3

# Responsiveness review: 640×360dp → tablet

Basis: landscape lock, so the scarce axis is **always height**. TP_Small = 640w × 360h. Pixel 6 = 873 × 393. Pixel 7 Pro = 891 × 411. Tablet ≈ 1280 × 800. All numbers below are from the spec's own formulas plus the code I read (`table_screen.dart`, `lobby_screen.dart`, `main.dart`).

## Fatal — arithmetic that cannot be satisfied at any size

**1. `Dim.consoleH` and `Dim.keyH` contradict each other on every device.**
`consoleH(h) = (h*0.155).clamp(52,76)`; `keyH(h) = (consoleH(h)-12).clamp(48,60)`. ActionConsole is a `PremiumGlassPanel` and passes no `padding`, so it inherits the spec's own default `EdgeInsets.all(Space.lg)` = 14, i.e. it needs `keyH + 28`.
- h=360: console 55.8, key 48 → needs 76 → **20.2dp overflow**.
- h=800: console 76, key 60 → needs 88 → **12dp overflow**.
There is no height at which it fits. The `-12` covers neither the 28dp of inherited padding, the 1dp hairline, nor the "1dp `ink900@0.45` inner top-left shadow under each key well". This is the component that replaces the FittedBox everyone agrees is broken, and it is worse: a FittedBox shrinks, a Row overflows.

**2. GlassRail: a 22dp glyph in a 46dp column with 28dp of inherited padding.**
`railW(640) = 46.08`. Same missing `padding` argument → 18.08dp usable for a 22dp glyph. **~4dp overflow, permanently, on every phone.** Separately: `railW`'s floor is **44**, below the 48dp minimum the spec itself declares non-negotiable for MachinedKey. The rail's two controls are the second most-tapped things on the table screen (today they are `visualDensity: compact` IconButtons = 40dp targets inside `SizedBox(width: 46)`). The spec calls them "glyphs" and never mentions an IconButton or a target size, so at best it preserves a 40dp target and at worst drops to 22dp — while spending a paragraph on the action bar's 37dp keys.

**3. LobbyTopRail: `topRailH(360) = 57.6` cannot hold a 38dp avatar.**
Avatar radius 19 → 38dp, plus a 1.5dp ring each side and a frosted edit pip hanging off the corner ≈ 42, plus the same inherited 28dp of glass padding = **70 into 57.6**.

Three of the four full-bleed chrome panels (rail, console, top rail) inherit `EdgeInsets.all(Space.lg)` they cannot afford. Only `GlassDrawerPanel` remembers `padding: EdgeInsets.zero`. That is not four independent bugs; it is one unstated rule.

## Regressions the proposal introduces at 640×360

**4. SideshowPromptPanel: the buttons no longer fit their own panel.**
Buttons rise 118→132 with `minimumSize: Size(132,48)`, and the panel gains `maxWidth: (w*0.42).clamp(280,420)` it never had. Required = 132 + 132 + `Space.md` 10 + 2×`Space.xl` 20 = **314**. At w=640 the panel is 280 → 240 usable → **34dp overflow**. Works from ~772dp up, i.e. Pixel 6 and above. Today's panel is a `Center > PremiumSurface` sizing to its 288dp content with no cap, which is exactly why it survives TP_Small. Capping a min-content panel at 42% of width, then enlarging its content, breaks the one device the touch-target fix was for.

**5. PicturePickerSheet gets *taller* on the shortest screen.**
`pickerH(360) = 108` (was a fixed 88); avatar radius = `pickerH*0.36` = 38.9 → **78dp circles, up from 64**. Verified in `lobby_screen.dart:890`: the sheet is `SafeArea > Padding > Column(mainAxisSize.min)` — **not scrollable**, inside `isScrollControlled: true`. Today ≈ 254dp of 360. The spec adds the strip growth, `Space.xl` vertical panel padding the sheet never had, a felt band and a hand-drawn handle → ~310–320 against 360 minus landscape gesture insets. The map already flagged this sheet as at risk; the redesign spends its remaining margin. (`clamp(72,120)`'s floor of 72 is dead — 0.30 of any height ≥ 240 clears it.)

**6. `revealCardH(360) = 68.4` — the sideshow reveal card grows from 62 to 68 on the tightest device.** Same for `ruleCardH(360) = 46.8` vs today's 46. Both formulas are height fractions whose value at h=360 happens to land *above* the literal they replace. That is the opposite of the stated goal.

**7. LobbyTableCard loses its only responsive axis.**
The card is square and **height**-driven; its sole adaptation today is `box.maxHeight < 330`. `Breaks` is width-only (`isCompact(double w)`) and the spec routes all three legacy thresholds through it. At the new rail cap (`h*0.78` = 280.8, minus the ListView's 24dp vertical padding) the card is ~257 square → 229 usable after the panel's 14dp padding. Content at the spec's own tokens: plate at 1.25× ≈ 36, +10, boot `money(displaySmall 34 @1.05)` 35.7, 'BOOT' 11.4, +10, 2-line blurb 37.8, +10, two `_CardFact` rows ≈ 40 + rule, +10, new full-width 34dp CTA capsule = **~246 into 229**. The redesign enlarges the badge and adds a CTA that did not exist, then deletes the ladder that paid for them. Worse: on a short-and-wide device `isCompact(w)` is *false* exactly when the card is shortest.

**8. `bonusSlotW` + `Breaks.compact` permanently kills the provider pill.**
`bonusSlotW(640) = 192` — 30% of the bar, against the 240 (37.5%) it replaces; a 48dp saving, not a fix. Then `tight` moves to `Breaks.compact = 700` "measured on the space the row actually has": 640−192 = 448, 873−262 = 611, 1280−384 = 896. A 700 threshold calibrated on full screen width, applied to a width now 30% smaller, makes `tight` true on **every phone and every tablet under ~1430dp**. Change the basis or the constant, not both.

**9. `_BonusChip` moves from an unbounded `Positioned` into a hard 192dp slot with no shrink rule.** Today it sizes to content (a long Bengali subtitle grows under the bar — ugly). Inside `SizedBox(width: bonusSlotW)` it is a constraint. The `_CornerChip` spec lists a 20dp dial, `Space.sm`, `labelSmall` title and `money(titleSmall)` subtitle — no `FittedBox`, no `maxLines`, no ellipsis — into 192−28 = **164dp usable**. "Collect 10,000" localised will overflow. `_MilestoneChip`'s new **25-segment track** goes into the same 164dp minus the icon and label: ~6.5dp per segment, and the spec never says it is `Expanded`.

**10. `MediaQuery.withClampedTextScaling` at `_Root` reaches almost none of the fixed-height surfaces.**
Verified: `_Root` is `MaterialApp.home`. Every modal uses the default `useRootNavigator: true` — `showDialog` (`main.dart:222`, `table_screen.dart:322`/`354`, `lobby_screen.dart:1247`), `showModalBottomSheet` (`lobby_screen.dart:890`), `showGeneralDialog` (`chip_store.dart:111`) — and `NoticeToast` is a `ScaffoldMessenger` SnackBar. All are built from the MaterialApp's Navigator/Messenger, **above** `_Root`. So GlassDialog, RulesSheet, PicturePickerSheet, ChipStoreShelf and NoticeToast — precisely the `ruleCardH` / `pickerH` / `packW` surfaces — get the raw OS scale (Android reaches 2.0). The clamp belongs in `MaterialApp.builder`, or every call site needs `useRootNavigator: false`.

**11. GlassDialog silently drops AlertDialog's scrolling content.** `Dialog > PremiumGlassPanel > Column` has no scrollable; `AlertDialog` does. Available height on TP_Small = 360 − 2×`Space.lg` = 332. The requirement-25 mid-hand leave copy is the longest string in the app; at 3 Bengali lines the column is ~228 (fits), at the 1.5 scale item 10 lets through it is ~340 → **overflow on the one dialog that must stay readable**.

## Systemic

**12. Wrong axis, and the floors do all the work.** On 640×360 these `Dim` values sit on a clamp floor and are therefore still fixed dp, just spelled differently: `keyH` 48 (formula 43.8), `keyW` 96 (92.8), `betW` 132 (118.4), `packW` 150 (128), `drawerW` 260 (256). Meanwhile `keyW`, `betW`, `railW`, `drawerW`, `toastW`, `packW`, `bonusSlotW` and `scale` are all keyed off **width**, the abundant axis. `Dim.scale(w)`'s single use is scaling **RewardCelebration's vertical padding** — a height problem, scaled by a width factor that is pinned to its 0.85 floor on the very device with the problem. That panel at 360 tall: 25.5×2 padding + SpinningChip 57.6 + title 21 + amount 29.7 + 2-line blurb 37.8 + 48dp key + gaps ≈ **300 of 360**, no scroll, and a 3-line Punjabi blurb tips it.

**13. `Breaks` does not deliver "one place to retune device classes".** `Breaks.medium = 1000` is referenced by nothing. The components then introduce fresh magic numbers: ActionConsole's `w >= 860`; InstrumentCluster's `26% / 30%`; SideshowPromptPanel's `0.42 / 280 / 420`; LobbyTableCard's `1.25×`; PrivateTableCard's **`34 × 44` code cells** (new fixed dp in a system built to remove them); GlassDialog's 460; the login card's 620; the chat counter's 120 characters. That is four-plus width thresholds and several fixed boxes outside the token classes.

**14. InstrumentCluster: the percentage cap runs under the pod on a tablet.** The spec says two incompatible things in one paragraph — "reads `Dim.railW`, `Dim.feltPad`, `Dim.consoleH`" *and* "width cap stays proportional (26% compact / 30% wide)". Against real geometry at 1280×800: railW 64, feltPad 23, feltW 1170, podW at the new 148 ceiling → podLeft = 64+23+391.9−74 = 404.9 → allowed ≈ 369. **30% of 1280 = 384 → 15dp under the viewer's pod.** Today's code clamps the derived value at 360 and is safe. The raised podW ceiling makes the percentage version worse, not better. Keep the derivation; delete the percentage.

**15. Text scale is defeated by `FittedBox`, and the system adds width to every label.** The spec names four reflowing surfaces and leaves `FittedBox(scaleDown)` as the strategy for the pod name, StatusTag, CategoryPlate (slot `w*0.30`), StatusLine (`w*0.42`), boot amount, WinnerBanner and StackPill. At the *typical* TP_Small podW of 88.5 (min(300·0.30, 571·0.155); the 56 floor is not the common case), StatusTag is `width*0.095 × 0.94` = **7.9px** and the pod name 10.4px in a Flexible with 88.5 − 8.9 padding − 16.8 dealer disc − 3.1 gap ≈ 59.7dp — a 12-glyph Devanagari name lands near 5px. Simultaneously `smallCaps` adds 1.6–2.4 tracking to labels that had none and `money()` switches to tabular figures (wider in Roboto): StatusLine's "Waiting for players (2)" gains ~46dp of pure tracking in a 240dp slot, so the FittedBox shrinks it a further ~16%. Nothing in the system declares a minimum legible size. Replacing ellipsis-to-two-glyphs with sub-5px type is a different failure, not a fix.

**16. `AppTheme.smallCaps` is called with a signature it does not have.** Declared `smallCaps(TextStyle base, {double tracking, Color? colour})`, which multiplies an inherited base by 0.94. SeatPlaque and StatusTag call `AppTheme.smallCaps(fontSize: width*0.125, tracking: width*0.006)`. There is no `fontSize` parameter. The pod's entire width-derived sizing — the one thing in the app that already scales correctly from 56 to 148 — rests on a decorator that cannot express it.

## Genuinely fine — say so and move on

- **`drawerW = (w*0.40).clamp(260,380)`** — 260 on TP_Small (40.6% vs today's 320/340 = 50–53%), 380 on tablet. Correct axis, real fix.
- **Raising `podW` 128→148 and `handH` 116→134 while keeping the formulas.** On TP_Small podW = min(300·0.30, 571·0.155) = 88.5, nowhere near either ceiling, so this is a pure tablet change. At 1280×800 the fanned own hand (3 cards at 95.7 wide, 18% overlap, ±4.5°) ends at ~747 of a 1170dp felt, with the viewer's pod bottom-anchored beside it — no collision. `_seatCentre` already takes `podW` as a parameter, so the four dependent animations follow correctly.
- **`toastW = (w*0.52).clamp(300,520)`** → 332.8 vs today's fixed 420 on a 640 screen. Right direction. (`main.dart:268` confirmed.)
- **DriftingChips off `box.shortestSide` (k 0.030–0.072)** → 10.8–25.9dp on TP_Small, 24–57.6 on tablet, strength literals untouched. Correct.
- **`feltPad = (w*0.018).clamp(10,28)`** → 11.5 vs today's 12; 23 on tablet. Harmless.
- **Killing `_SideshowCountdown`'s `SizedBox(width: 260, height: 8)` for an arc on the panel's own edge** — right diagnosis, right shape. Undone only by item 4, which breaks the panel it now measures against.
- **ChatCountdownDial at a fixed 22dp** — an icon-sized instrument in an icon slot. Leave it.
- **`_MissedTurnsStrip` reading `Dim.railW`/`feltPad`/`consoleH` instead of re-typing 46/24/64/0.335 and the podW formula.** The single best structural idea in the document — provided item 14's percentage does not overrule it, and provided `consoleH` becomes a real number (item 1) rather than one the console itself violates.