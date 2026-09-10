import 'dart:math' as math;

import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:flutter/material.dart';

/// The one spacing ramp.
///
/// It is a ~1.4x ramp, not a 4-based grid — 6, 10, 14 and 28 are deliberate
/// steps, so nobody should "fix" them into multiples of four later.
class Space {
  const Space._();

  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 14;
  static const double xl = 20;
  static const double xxl = 28;
  static const double xxxl = 40;
}

/// Four corner radii and a capsule.
///
/// The old set was a stadium set (buttons 40, default 20, cards 24), which is
/// what made the game read as a friendly Material app rather than an expensive
/// one. Premium is squarer. Four steps are as many as stay distinguishable on
/// adjacent elements; anything finer is a range, not a system.
class Radii {
  const Radii._();

  /// Pips, micro-pills, code cells.
  static const double xs = 6;

  /// Plates, tags, badges.
  static const double sm = 10;

  /// Keys, inputs, the bet window, a panel's inner wells.
  static const double md = 14;

  /// Panels, cards, dialogs, drawers.
  static const double lg = 18;

  /// A capsule is still a capsule.
  static const double pill = 999;
}

/// Every duration and curve the chrome animates on.
///
/// Game timing is deliberately absent: the card flip, the deal stagger, the
/// liquid wave, the turn blink, the fireworks, the bet flights and the count-up
/// tweens are calibrated against a 25-second turn clock and a 4-second next-hand
/// delay. Retiming those is a gameplay change wearing a design costume.
class Motion {
  const Motion._();

  /// Press-down.
  static const Duration instant = Duration(milliseconds: 90);

  /// Key flash, hover, a figure swapping in place.
  static const Duration fast = Duration(milliseconds: 140);

  /// Switchers, selection, a state change.
  static const Duration base = Duration(milliseconds: 220);

  /// A screen transition, a panel entering.
  static const Duration slow = Duration(milliseconds: 300);

  /// A card entrance, a drawer row's stagger.
  static const Duration enter = Duration(milliseconds: 420);

  /// A winner banner, a reward panel: something arriving.
  static const Duration arrive = Duration(milliseconds: 520);

  /// The two ambient beats. Everything that breathes uses [breath] and
  /// everything that travels across a surface uses [sweep], so the screen stops
  /// looking like six unrelated things fidgeting.
  static const Duration breath = Duration(milliseconds: 3800);
  static const Duration sweep = Duration(milliseconds: 5200);

  static const Curve standard = Curves.easeOutCubic;

  /// Panels and screens arriving.
  static const Curve emphasized = Cubic(0.2, 0, 0, 1);

  /// Things landing: chips, banners.
  static const Curve settle = Curves.easeOutBack;

  /// Anything on `repeat(reverse: true)`.
  static const Curve breathe = Curves.easeInOut;

  /// Anything crossing the felt.
  static const Curve travel = Curves.easeInOutCubic;

  /// Per-item entrance delay in a list.
  static const Duration stagger = Duration(milliseconds: 55);
}

/// Device classes, in one place.
///
/// The app is landscape-locked, so width is the abundant axis and height is the
/// scarce one. Width thresholds decide how much a row may spread; the height
/// threshold decides whether a column has to give something up. Anything that
/// measures a sub-region (the top bar's content, a card in a rail) passes the
/// space it actually has, not the screen width.
class Breaks {
  const Breaks._();

  /// TP_Small (640x360) lives below this.
  static const double compact = 700;

  /// Pixel 6 / 7 Pro sit between [compact] and [wide].
  static const double wide = 900;

  /// Tablets.
  static const double expanded = 1200;

  /// A screen this short cannot afford a second line anywhere: 360 is compact,
  /// 411 and above is not.
  static const double shortHeight = 380;

  /// The lobby top bar folds its provider pill below this much *remaining*
  /// width — not below this much screen width. At the reward slot's own size
  /// that is 448dp on a 640 screen (fold) and 624dp on an 891 one (don't).
  static const double tightBar = 470;

  static bool isCompact(double w) => w < compact;
  static bool isWide(double w) => w >= wide;
  static bool isExpanded(double w) => w >= expanded;
  static bool isShort(double h) => h < shortHeight;
  static bool isTightBar(double contentW) => contentW < tightBar;
}

/// Every fixed dp in the chrome, derived from the box it lives in.
///
/// Two rules hold this together, and both were learned the hard way. First, a
/// container's height is derived FROM its content plus its padding, never the
/// other way round — [consoleH] is [keyH] plus two [consolePad], so it cannot
/// be too small for the keys it holds. Second, the padding is always an
/// argument at the call site: an inherited default is what made four separate
/// panels ask for more room than they had.
///
/// Every formula below carries its value at h=360 (TP_Small), h=411 (Pixel 7
/// Pro) and h=800 (tablet) — with the matching widths 640, 891 and 1280.
class Dim {
  const Dim._();

  /// Nothing the player taps is ever smaller than this.
  static const double minTouch = 44;

  /// One hairline weight in the whole app.
  static const double hairline = 1;

  /// Vertical padding scales on the axis that is actually scarce.
  /// 360 -> 0.88 | 411 -> 1.00 | 800 -> 1.25
  static double vScale(double h) => (h / 411).clamp(0.82, 1.25);

  /// The table's left rail. The floor is a legal touch target, not 44 exactly,
  /// because the rail is also the column its buttons sit in.
  /// 640 -> 48.0 | 891 -> 54.0 | 1280 -> 54.0
  static double railW(double w) => (w * 0.072).clamp(48.0, 54.0);

  /// Explicit, because [railW]'s floor leaves 48 - 2*4 = 40dp for a 22dp glyph.
  static const double railPad = 4;

  /// A rail button's height. 360 -> 46.8 | 411 -> 53.4 | 800 -> 56.0
  static double railButtonH(double h) => (h * 0.13).clamp(minTouch, 56.0);

  /// An action key. 360 -> 44.0 | 411 -> 47.7 | 800 -> 52.0
  ///
  /// Brought down on 10 Sep 2026 to give the felt its height back. The console
  /// is the only thing competing with the cloth for vertical space, and at
  /// h*0.135 it was taking about a sixth of a landscape screen to show six
  /// controls that are mostly empty padding. The floor stays at [minTouch] —
  /// these are the keys the whole game is played with, and a key too small to
  /// hit reliably is a worse table than a slightly shorter one.
  static double keyH(double h) => (h * 0.116).clamp(minTouch, 52.0);

  /// The console's own padding, above and below its keys.
  /// 360 -> 4.3 | 411 -> 4.9 | 800 -> 7.0
  static double consolePad(double h) => (h * 0.012).clamp(4.0, 7.0);

  /// Derived from the keys it holds, so it can never be too short for them.
  /// 360 -> 52.6 | 411 -> 57.5 | 800 -> 66.0 (was 61.6 | 70.3 | 78.0)
  static double consoleH(double h) => keyH(h) + 2 * consolePad(h);

  /// 640 -> 96.0 | 891 -> 129.2 | 1280 -> 168.0
  static double keyW(double w) => (w * 0.145).clamp(96.0, 168.0);

  /// The bet window between the two steppers.
  /// 640 -> 128.0 | 891 -> 164.8 | 1280 -> 190.0
  static double betW(double w) => (w * 0.185).clamp(128.0, 190.0);

  /// The gap between controls in a row.
  /// 640 -> 6 | 891 -> 10 | 1280 -> 10
  static double gap(double w) => Breaks.isCompact(w) ? Space.sm : Space.md;
  static double railButtonW(double w) => railW(w) - 2 * railPad;

  /// The action row fits without scaling anything down. Three keys, the bet
  /// window, two [minTouch] steppers and five gaps, inside `w - 2*Space.xl`:
  /// 640 -> 534.0 of 600 | 891 -> 690.4 of 851 | 1280 -> 832.0 of 1240.
  static double actionRowW(double w) =>
      3 * keyW(w) + betW(w) + 2 * minTouch + 5 * gap(w);

  /// The lobby's avatar. 360 -> 37.8 | 411 -> 43.2 | 800 -> 48.0
  static double avatarD(double h) => (h * 0.105).clamp(36.0, 48.0);

  /// The edit pip hangs off the avatar's corner and has to be paid for.
  static const double avatarPip = 4;

  /// 360 -> 6.1 | 411 -> 7.0 | 800 -> 10.0
  static double topRailPad(double h) => (h * 0.017).clamp(5.0, 10.0);

  /// Derived from the avatar it carries, pip included.
  /// 360 -> 54.0 | 411 -> 61.1 | 800 -> 72.0
  static double topRailH(double h) =>
      avatarD(h) + avatarPip + 2 * topRailPad(h);

  /// The reward chip's slot in the top bar.
  /// 640 -> 192.0 | 891 -> 267.3 | 1280 -> 300.0
  static double bonusSlotW(double w) => (w * 0.30).clamp(180.0, 300.0);

  /// What the top bar's row actually has left — the number to hand
  /// [Breaks.isTightBar], never the raw screen width.
  /// 640 -> 448.0 | 891 -> 623.7 | 1280 -> 980.0
  static double topBarContentW(double w) => w - bonusSlotW(w);

  /// 640 -> 260.0 | 891 -> 356.4 | 1280 -> 380.0
  static double drawerW(double w) => (w * 0.40).clamp(260.0, 380.0);

  /// The margin the felt keeps from the rail and the screen edge.
  /// 640 -> 11.5 | 891 -> 16.0 | 1280 -> 23.0
  static double feltPad(double w) => (w * 0.018).clamp(10.0, 28.0);

  /// A seat pod, measured against the felt's own box rather than the screen's.
  ///
  /// Nudged up on 10 Sep 2026, but only a little, and the picture inside the
  /// pod was enlarged much more (_kAvatar in seat_pod.dart). That split is
  /// deliberate: the complaint was that the player's picture was the smallest
  /// thing on a table full of cards and chips, and growing the whole pod to
  /// fix it is the expensive way. A pod's column is taller than it is wide, so
  /// width buys height faster than it buys picture — at feltH * 0.345 the top
  /// seat's pod ran off the top of the screen and the rim seat crossed the
  /// cloth's edge. The horizontal clamp in _Felt.at() stops a pod leaving the
  /// felt sideways; nothing stops it leaving upwards, so the height fraction
  /// is the real ceiling here.
  static double podW(double feltW, double feltH) =>
      math.min(feltH * 0.270, feltW * 0.150).clamp(60.0, 140.0);

  /// The viewer's own fanned hand, again against the felt's box.
  ///
  /// Brought down on 10 Sep 2026. Three cards at 0.29 of the felt's height
  /// were the largest object on the screen once the cloth went, and the hand
  /// is the one thing a player already knows the contents of.
  static double handH(double feltH) => (feltH * 0.235).clamp(46.0, 108.0);

  /// A card in the sideshow reveal. Sized so it never grows on the tightest
  /// screen: 360 -> 61.2 | 411 -> 69.9 | 800 -> 104.0
  static double revealCardH(double h) => (h * 0.17).clamp(52.0, 104.0);

  /// A rule row in the rules sheet. 360 -> 41.4 | 411 -> 47.3 | 800 -> 66.0
  static double ruleCardH(double h) => (h * 0.115).clamp(40.0, 66.0);

  /// The avatar strip in the picture picker. The sheet does not scroll, so this
  /// shrinks on a short screen instead of growing.
  /// 360 -> 79.2 | 411 -> 90.4 | 800 -> 108.0
  static double pickerH(double h) => (h * 0.22).clamp(68.0, 108.0);

  /// A chip-store pack card. 640 -> 140.0 | 891 -> 169.3 | 1280 -> 200.0
  static double packW(double w) => (w * 0.19).clamp(140.0, 200.0);

  /// A floating notice. 640 -> 332.8 | 891 -> 463.3 | 1280 -> 520.0
  static double toastW(double w) => (w * 0.52).clamp(300.0, 520.0);

  /// A dialog. 640 -> 396.8 | 891 -> 520.0 | 1280 -> 520.0
  static double dialogW(double w) => (w * 0.62).clamp(320.0, 520.0);

  /// What a dialog may occupy vertically before its body has to scroll.
  /// 360 -> 332.0 | 411 -> 383.0 | 800 -> 772.0
  static double dialogMaxH(double h) => h - 2 * Space.lg;

  /// The sideshow prompt. Wide enough at 640 for two [minTouch]-tall keys of
  /// 132dp plus their gap and the panel's own padding (314 into 332.8).
  /// 640 -> 332.8 | 891 -> 460.0 | 1280 -> 460.0
  static double sideshowPanelW(double w) => (w * 0.52).clamp(300.0, 460.0);

  /// A lobby table card is square and height-driven — the one place in the app
  /// where the scarce axis sets both dimensions.
  /// 360 -> 259.2 | 411 -> 295.9 | 800 -> 400.0
  static double lobbyCardSide(double h) => (h * 0.72).clamp(210.0, 400.0);
}

/// The colours one table is told apart by.
///
/// Three tables, three identities: the seen table is gold, the small blind
/// table is sapphire, the high-stakes blind table is royal purple. The lobby
/// card, the felt, the tag over the pot and the badges all draw from the same
/// palette, so the room a player sits down in matches the card they tapped.
class TablePalette {
  const TablePalette({
    required this.accent,
    required this.container,
    required this.onContainer,
    required this.icon,
    required this.tint,
  });

  /// The table's signature colour: borders, glows, the chip stack.
  final Color accent;

  /// A filled surface in the table's colour, for badges and tags.
  final Color container;
  final Color onContainer;

  /// The mark the table carries: an eye, a crossed eye, or a crown.
  final IconData icon;

  /// How deeply the felt and the card are washed in the accent.
  final double tint;

  /// The two ends of the table's rim. A rim lit from above and shaded below is
  /// what makes the felt read as a physical edge rather than a stroked oval.
  Color get rimHigh => Color.lerp(accent, const Color(0xFFFFFFFF), 0.18)!;
  Color get rimLow => Color.lerp(accent, const Color(0xFF000000), 0.34)!;
}

class AppTheme {
  const AppTheme._();

  /// A deep casino green, used as the seed for both schemes.
  static const Color _seed = Color(0xFF0F5236);
  static const Color _gold = Color(0xFFC9A227);

  /// The rim around the table, and the accent on chips and stakes.
  ///
  /// This value must not move. `ThemeData.estimateBrightnessForColor` flips at
  /// a relative luminance of 0.337 and this colour sits at 0.384 — a margin of
  /// 0.047 — and that call is a live switch for the label on a chip in
  /// `poker_chip.dart` and `chip_store.dart`. A deeper champagne would flip one
  /// of those two and not the other.
  static const Color gold = _gold;

  /// Champagne as a *line*: hairlines, small-caps type, a meniscus, a specular
  /// edge. Gold as a *fill* is [gold], and there is only ever one solid gold
  /// fill on screen at a time.
  static const Color goldBright = Color(0xFFF2DFA8);

  /// The underside of a gold gradient, an engraved shadow, gold ink on a light
  /// ground.
  static const Color goldDeep = Color(0xFF8A6A18);

  /// The two hairline alphas — resting and live. There is no third.
  static const double hairlineResting = 0.16;
  static const double hairlineLive = 0.34;
  static const double hairlineRestingLight = 0.28;
  static const double hairlineLiveLight = 0.48;

  /// The charcoal ground the whole dark scheme is built on.
  static const Color ink900 = Color(0xFF06080A);
  static const Color ink800 = Color(0xFF0B0E11);
  static const Color ink700 = Color(0xFF121619);
  static const Color ink600 = Color(0xFF1A2024);
  static const Color ink500 = Color(0xFF232B31);
  static const Color ink400 = Color(0xFF39434A);

  /// Its light-mode counterpart: warm parchment, never white. The dark scheme
  /// is the design's home, but every token below has a light value beside it —
  /// a saved `darkMode` preference and a toggle in the drawer both still work,
  /// and a light mode of charcoal cards on parchment would be incoherent.
  static const Color bone100 = Color(0xFFF3F1EA);
  static const Color bone200 = Color(0xFFE9E5DA);
  static const Color bone300 = Color(0xFFD8D2C3);

  /// The cloth. Solid emerald, lit from the middle and darkened at the rim —
  /// a physical surface, so it is never glass and never scheme-derived.
  // Oxblood, not green. Green is what every free card app uses, and the owner
  // asked for the private-club end of the register instead. Lit a little above
  // the middle where the lamp hangs and falling to near-black at the rim, so
  // it reads as wool under low light rather than as a red rectangle.
  static const Color feltCore = Color(0xFF412028);
  static const Color feltMid = Color(0xFF2F181E);
  static const Color feltRim = Color(0xFF190D11);
  static const Color feltCoreLight = Color(0xFF542A34);
  static const Color feltMidLight = Color(0xFF412129);
  static const Color feltRimLight = Color(0xFF241318);

  /// The pool an overhead lamp throws on the cloth, used at a low alpha and
  /// always in plain `srcOver` — a blend mode here would force an offscreen
  /// across the largest region on screen, every frame.
  static const Color lampWarm = Color(0xFFFFF3DC);

  /// Type ink, and the three opacities the whole app writes at.
  static const Color boneInk = Color(0xFFF4F1E9);
  static const Color inkOnLight = Color(0xFF14181B);
  static const double inkHigh = 1;
  static const double inkMed = 0.72;
  static const double inkLow = 0.46;

  /// The middle tier of an escalation — a missed turn that has been marked but
  /// is not yet a kick. The ends of that scale are `scheme.primary` and
  /// `scheme.error`, which stay far apart in both hue and luminance.
  static const Color amber = Color(0xFFE8A33C);

  /// Royal purple for the high-stakes blind table, one shade per brightness.
  static const Color _royal = Color(0xFF6D4BC4);
  static const Color _royalDark = Color(0xFFC9B3FF);

  /// The palette for a table of this category and stake. Blind tables at or
  /// above 1,000 boot are the high-stakes ones and wear the purple.
  ///
  /// The tints are far lower than they were: the cloth is emerald baize now and
  /// the table's identity is carried by its rim, not by washing the felt.
  static TablePalette paletteFor(
    ColorScheme scheme, {
    required String category,
    required int bootAmount,
  }) {
    final dark = scheme.brightness == Brightness.dark;
    if (category != 'blind') {
      return TablePalette(
        accent: _gold,
        container: scheme.secondaryContainer,
        onContainer: scheme.onSecondaryContainer,
        icon: Icons.visibility_rounded,
        tint: dark ? 0.10 : 0.09,
      );
    }
    if (bootAmount >= 1000) {
      return TablePalette(
        accent: dark ? _royalDark : _royal,
        container: dark ? const Color(0xFF2A1E4E) : const Color(0xFFE9DEFF),
        onContainer: dark ? const Color(0xFFEDE4FF) : const Color(0xFF261452),
        icon: Icons.workspace_premium_rounded,
        tint: dark ? 0.14 : 0.12,
      );
    }
    return TablePalette(
      accent: scheme.tertiary,
      container: scheme.tertiaryContainer,
      onContainer: scheme.onTertiaryContainer,
      icon: Icons.visibility_off_rounded,
      tint: dark ? 0.10 : 0.09,
    );
  }

  /// A playing card's face is warm ivory stock and its pips red or black,
  /// whatever the theme is doing.
  static const Color cardFace = Color(0xFFFBF7EE);
  static const Color pipRed = Color(0xFFB3202C);
  static const Color pipBlack = Color(0xFF14171B);

  /// The cut edge of that stock, drawn as a half-pixel inner rim.
  static const Color cardEdge = Color(0xFFE6DFCE);

  /// The colour a raised control casts.
  ///
  /// Not black in light mode: a neutral shadow under a warm gold-and-green
  /// palette reads as grubby. In the dark scheme it stays pure black, because a
  /// shadow lighter than the surface makes a button glow instead of lift.
  static Color shadowFor(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFF000000)
      : const Color(0xFF0B3524);

  /// The screen's ground, and the darker edge a vignette closes on.
  static Color ground(Brightness b) => b == Brightness.dark ? ink800 : bone100;
  static Color groundEdge(Brightness b) =>
      b == Brightness.dark ? ink900 : bone300;

  /// The body of a panel — glass or otherwise — before anything tints it.
  static Color panelBase(Brightness b) =>
      b == Brightness.dark ? ink700 : const Color(0xFFFBFAF6);

  /// A solid raised object: a seat pod, a machined key, a plaque. Never glass;
  /// five blurred pods over a felt that repaints every frame is the one change
  /// that would sink the frame budget.
  static Color plaque(Brightness b) => b == Brightness.dark ? ink600 : bone200;

  /// The app's one hairline, at its two alphas. Resting is a rim; live means
  /// focused, claimable, or the primary key in a row.
  static Color hairlineColour(Brightness b, {bool live = false}) =>
      b == Brightness.dark
      ? goldBright.withValues(alpha: live ? hairlineLive : hairlineResting)
      : goldDeep.withValues(
          alpha: live ? hairlineLiveLight : hairlineRestingLight,
        );

  /// The lit inner top edge that separates a charcoal object from a charcoal
  /// ground. In dark mode this does the work a shadow cannot.
  static Color rimLight(Brightness b) =>
      b == Brightness.dark ? const Color(0x12FFFFFF) : const Color(0x59FFFFFF);

  /// The three tones of the cloth, per brightness.
  static ({Color core, Color mid, Color rim}) feltColours(
    Brightness b, {
    Color? accent,
  }) {
    final base = b == Brightness.dark
        ? (core: feltCore, mid: feltMid, rim: feltRim)
        : (core: feltCoreLight, mid: feltMidLight, rim: feltRimLight);
    if (accent == null) return base;

    // The cloth carries the table's identity, so the room a player sits down
    // in matches the card they tapped in the lobby: gold at the seen table,
    // sapphire at the small blind, royal purple at the high-stakes one. Green
    // stays underneath as the thing that reads as baize — an entirely purple
    // cloth reads as a lighting effect, not a table.
    //
    // Weighted from the middle outwards: strongest where the light falls and
    // almost absent at the rim, because a real cloth takes its colour from
    // what is dyed into it and its shadow from its own depth.
    Color wash(Color under, double amount) =>
        Color.lerp(under, accent, amount) ?? under;
    return (
      core: wash(base.core, 0.30),
      mid: wash(base.mid, 0.20),
      rim: wash(base.rim, 0.09),
    );
  }

  /// Ink for text painted directly ON the felt.
  ///
  /// Not a scheme colour. `onSurfaceVariant` is defined against a surface, and
  /// the felt is not one — in the light scheme it resolves to a dark warm grey
  /// that all but disappears on green cloth, which is exactly what happened to
  /// the "in pot" line. Cloth is dark in both schemes, so its ink is bone in
  /// both, and only the weight changes.
  static Color onFelt(Brightness b, {double alpha = inkMed}) =>
      (b == Brightness.dark ? bone200 : bone100).withValues(alpha: alpha);

  /// Ink for text on the TABLE, which since 10 Sep 2026 has no cloth under it.
  ///
  /// [onFelt] is bone in both schemes because cloth was dark in both. Remove
  /// the cloth and that assumption inverts: bone on the light scheme's pale
  /// ground is very nearly invisible, and the "in pot" line disappeared
  /// exactly as the comment above warned it would on green. The table now sits
  /// on the app's own surface, so its ink follows the surface like any other
  /// text does. [onFelt] stays for the lobby cards, which still wear baize.
  static Color onTable(ColorScheme scheme, {double alpha = inkMed}) =>
      scheme.onSurface.withValues(alpha: alpha);

  /// Elevation for a button, by state: lifted at rest, higher under a pointer,
  /// and pressed down flat under a finger, so it behaves like a physical key.
  ///
  /// A disabled button sits flush. Nothing about it can be pressed, and a
  /// shadow under something dead is the thing that makes a UI look cheap.
  static WidgetStateProperty<double> liftElevation(double rest) =>
      WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return 0;
        if (states.contains(WidgetState.pressed)) return rest / 3;
        if (states.contains(WidgetState.hovered)) return rest * 2;
        return rest;
      });

  /// Adds that lift to every button the app can raise.
  ///
  /// Text buttons are deliberately left flat: they are the quiet half of a
  /// dialog's pair, and a shadow under "Cancel" would fight the button it is
  /// meant to defer to.
  /// `sound` is the player's Sound switch.
  ///
  /// Material plays its own click on every button through Feedback.forTap, and
  /// that call knows nothing about a setting in a drawer — so a switch that did
  /// not reach here would silence the game's own sounds and leave every button
  /// still ticking. Threading it through the button themes is what makes the
  /// switch mean ALL sound rather than most of it.
  static ThemeData _raisedButtons(ThemeData theme, {required bool sound}) {
    final shadow = shadowFor(theme.brightness);

    ButtonStyle lift(double rest) => ButtonStyle(
      elevation: liftElevation(rest),
      shadowColor: WidgetStatePropertyAll(shadow),
      // M3 tints a raised surface by elevation as well as shadowing it.
      // The buttons here are already solidly coloured, so the tint only
      // muddies them.
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      enableFeedback: sound,
    );

    return theme.copyWith(
      filledButtonTheme: FilledButtonThemeData(style: lift(3)),
      elevatedButtonTheme: ElevatedButtonThemeData(style: lift(3)),
      outlinedButtonTheme: OutlinedButtonThemeData(style: lift(1)),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(enableFeedback: sound),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(enableFeedback: sound),
      ),
      // Switches and tiles carry it as a property rather than a style.
      switchTheme: theme.switchTheme,
      inputDecorationTheme: _inputs(theme),
    );
  }

  /// Text fields answer to the same hairline rule as every panel: one weight,
  /// resting until it is focused.
  static InputDecorationThemeData _inputs(ThemeData theme) {
    final b = theme.brightness;
    OutlineInputBorder border(Color c, double w) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.md),
      borderSide: BorderSide(color: c, width: w),
    );

    return theme.inputDecorationTheme.copyWith(
      filled: true,
      fillColor: panelBase(
        b,
      ).withValues(alpha: b == Brightness.dark ? 0.55 : 0.70),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      border: border(hairlineColour(b), Dim.hairline),
      enabledBorder: border(hairlineColour(b), Dim.hairline),
      focusedBorder: border(hairlineColour(b, live: true), Dim.hairline),
      errorBorder: border(theme.colorScheme.error, Dim.hairline),
      focusedErrorBorder: border(theme.colorScheme.error, Dim.hairline),
      disabledBorder: border(
        theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        Dim.hairline,
      ),
    );
  }

  /// The same lift, for a button the button themes do not reach — an icon
  /// button with a background of its own.
  static ButtonStyle raisedIcon(Brightness brightness, {double rest = 3}) =>
      ButtonStyle(
        elevation: liftElevation(rest),
        shadowColor: WidgetStatePropertyAll(shadowFor(brightness)),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      );

  /// The same lift for something drawn by hand rather than by a button — the
  /// bet stepper's amount, say — so a row of controls sits at one height.
  ///
  /// The alphas are much higher in dark mode than they were: a shadow at 0.22
  /// on a #0B0E11 ground is not visible at all. [bloom] is optional and is a
  /// reserved signal — see [PremiumSurface]; a control passes it only when the
  /// game has just done something.
  static List<BoxShadow> controlShadow(
    Brightness brightness, {
    double elevation = 3,
    Color? bloom,
  }) {
    final s = shadowFor(brightness);
    final dark = brightness == Brightness.dark;

    return [
      BoxShadow(
        color: s.withValues(alpha: dark ? 0.55 : 0.22),
        blurRadius: elevation * 2.5,
        offset: Offset(0, elevation * 0.8),
      ),
      BoxShadow(
        color: s.withValues(alpha: dark ? 0.26 : 0.10),
        blurRadius: elevation,
        offset: Offset(0, elevation * 0.25),
      ),
      if (bloom != null)
        BoxShadow(
          color: bloom.withValues(alpha: dark ? 0.16 : 0.12),
          blurRadius: elevation * 6,
          spreadRadius: -elevation * 1.5,
          offset: Offset(0, elevation),
        ),
    ];
  }

  /// What a glass panel casts. Two layers, and never a bloom: an accent bloom
  /// is reserved for the felt, the winner's pod and the buy-chips button, so
  /// that a bloom always means the game did something.
  static List<BoxShadow> glassShadow(Brightness brightness) {
    final s = shadowFor(brightness);
    final dark = brightness == Brightness.dark;

    return [
      BoxShadow(
        color: s.withValues(alpha: dark ? 0.55 : 0.18),
        blurRadius: 10,
        offset: const Offset(0, 4),
      ),
      BoxShadow(
        color: s.withValues(alpha: dark ? 0.30 : 0.10),
        blurRadius: 30,
        offset: const Offset(0, 14),
      ),
    ];
  }

  /// Every figure that represents chips, a count, a countdown or a code.
  ///
  /// Tabular figures are load-bearing rather than decorative: the pot, the
  /// balance, the boot, the in-pot total and the bet window all count up or
  /// step, and proportional digits change width mid-tween, so the figure
  /// jitters horizontally while it animates. This also *reduces* work, because
  /// the paragraph no longer relayouts as digit advances change.
  static TextStyle money(
    TextStyle base, {
    Color? colour,
    double? fontSize,
    FontWeight weight = FontWeight.w700,
  }) => base.copyWith(
    fontSize: fontSize ?? base.fontSize,
    fontWeight: weight,
    letterSpacing: 0,
    color: colour ?? base.color,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  /// Tracked capitals, for the handful of fixed Latin labels the code owns:
  /// POT, BOOT, VS, SIDESHOW, YOU.
  ///
  /// Never a player's name and never a `Strings` getter. This is uppercasing
  /// plus tracking, and `toUpperCase()` is a no-op on Devanagari, Bengali,
  /// Gujarati and Gurmukhi — two adjacent pods would read RAVI beside मीरा with
  /// matched tracking, which is worse than either alone. Names and translated
  /// strings render in their natural case through [label].
  static TextStyle smallCaps(
    TextStyle base, {
    double? fontSize,
    double tracking = 1.4,
    Color? colour,
    FontWeight weight = FontWeight.w600,
  }) => base.copyWith(
    fontSize: fontSize ?? (base.fontSize ?? 14) * 0.94,
    fontWeight: weight,
    letterSpacing: tracking,
    color: colour ?? base.color,
  );

  /// The same slot as [smallCaps] for anything the player wrote or the server
  /// translated: natural case, and only as much tracking as a label wants.
  static TextStyle label(
    TextStyle base, {
    double? fontSize,
    Color? colour,
    FontWeight weight = FontWeight.w600,
  }) => base.copyWith(
    fontSize: fontSize ?? base.fontSize,
    fontWeight: weight,
    letterSpacing: 0.2,
    color: colour ?? base.color,
  );

  /// One type ramp for the whole app.
  ///
  /// The ceiling is w700 and it is reserved for money and headlines; the app
  /// used to shout in w800 and w900 everywhere. Hierarchy comes from size,
  /// tracking and opacity instead.
  static TextTheme _textTheme(Brightness b) {
    final ink = b == Brightness.dark ? boneInk : inkOnLight;

    return TextTheme(
      displaySmall: TextStyle(
        fontSize: 34,
        height: 1.05,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
        color: ink,
      ),
      headlineMedium: TextStyle(
        fontSize: 27,
        height: 1.10,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        color: ink,
      ),
      headlineSmall: TextStyle(
        fontSize: 23,
        height: 1.15,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: ink,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        height: 1.20,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      titleMedium: TextStyle(
        fontSize: 17,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: ink,
      ),
      titleSmall: TextStyle(
        fontSize: 15,
        height: 1.30,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
        color: ink,
      ),
      bodyLarge: TextStyle(
        fontSize: 15,
        height: 1.40,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.1,
        color: ink,
      ),
      bodyMedium: TextStyle(
        fontSize: 13.5,
        height: 1.40,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.1,
        color: ink,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        height: 1.35,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.15,
        color: ink,
      ),
      labelLarge: TextStyle(
        fontSize: 13.5,
        height: 1.15,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: ink,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        height: 1.15,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
        color: ink,
      ),
      labelSmall: TextStyle(
        fontSize: 10.5,
        height: 1.15,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: ink,
      ),
    );
  }

  static ThemeData light({bool sound = true}) => _raisedButtons(
    sound: sound,
    FlexThemeData.light(
      colors: const FlexSchemeColor(
        primary: _seed,
        primaryContainer: Color(0xFFA8E9C6),
        secondary: Color(0xFF7A6412),
        secondaryContainer: Color(0xFFF6E4B0),
        tertiary: Color(0xFF15586F),
        tertiaryContainer: Color(0xFFC2E3F2),
        appBarColor: Color(0xFFF6E4B0),
        error: Color(0xFFC0271B),
      ),
      surface: bone200,
      scaffoldBackground: bone100,
      surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
      blendLevel: 4,
      useMaterial3: true,
      subThemesData: _subThemes,
      textTheme: _textTheme(Brightness.light),
      visualDensity: VisualDensity.standard,
    ),
  );

  static ThemeData dark({bool sound = true}) => _raisedButtons(
    sound: sound,
    FlexThemeData.dark(
      colors: const FlexSchemeColor(
        primary: Color(0xFF5FD3A0),
        primaryContainer: Color(0xFF0E3A2A),
        secondary: Color(0xFFE3C88B),
        secondaryContainer: Color(0xFF3A2E12),
        tertiary: Color(0xFF7FB6D6),
        tertiaryContainer: Color(0xFF17394B),
        appBarColor: Color(0xFF12161A),
        error: Color(0xFFFF6B5A),
      ),
      surface: ink700,
      scaffoldBackground: ink800,
      surfaceMode: FlexSurfaceMode.highScaffoldLowSurface,
      // A whisper of emerald in every container, so charcoal never goes blue.
      blendLevel: 6,
      useMaterial3: true,
      subThemesData: _subThemes,
      textTheme: _textTheme(Brightness.dark),
      visualDensity: VisualDensity.standard,
    ),
  );

  /// Shared component shaping, in [Radii]'s terms. Squarer than it was: the
  /// stadium buttons are what made the game read as a friendly Material app.
  static const FlexSubThemesData _subThemes = FlexSubThemesData(
    defaultRadius: Radii.md,
    filledButtonRadius: Radii.md,
    elevatedButtonRadius: Radii.md,
    outlinedButtonRadius: Radii.md,
    textButtonRadius: Radii.sm,
    cardRadius: Radii.lg,
    dialogRadius: Radii.lg,
    inputDecoratorRadius: Radii.md,
    inputDecoratorIsFilled: true,
    inputDecoratorBorderType: FlexInputBorderType.outline,
    chipRadius: Radii.sm,
    // Keeps palette.onContainer readable against palette.container.
    blendOnColors: false,
    interactionEffects: true,
    tintedDisabledControls: true,
  );
}
