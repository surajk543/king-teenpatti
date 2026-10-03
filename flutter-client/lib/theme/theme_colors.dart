import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

/// The glass tokens, one set per brightness.
///
/// Two looks share one structure. "Obsidian" is the dark one: a near-black
/// ground, panels that are barely more than a blur with a whisper of white
/// over it, white type at three opacities. "Frosted ice" is the light one: a
/// cool off-white ground, panels of milky white over a strong blur, charcoal
/// type. Every glass surface in the app reads its fill, border, sheen and blur
/// from here through `GlassColors.of(context)`, so the two modes cannot drift
/// apart — a token missing from one side would fail to compile, not fail to
/// match.
///
/// Registered as a `ThemeExtension` so a widget asks `Theme.of(context)` and
/// gets the right set for the theme it is actually being painted in — a dialog
/// built off the root navigator included.
@immutable
class GlassColors extends ThemeExtension<GlassColors> {
  const GlassColors({
    required this.ground,
    required this.groundEdge,
    required this.fill,
    required this.fillStrong,
    required this.wellFill,
    required this.borderTop,
    required this.borderBottom,
    required this.highlight,
    required this.sigma,
    required this.textDisplay,
    required this.textBody,
    required this.textMuted,
    required this.thumb,
    required this.cardFill,
    required this.cardFillEnd,
    required this.cardBorder,
    required this.cardHighlight,
    required this.cardMuted,
    required this.cardShadow,
    required this.glowStrength,
    required this.glowReach,
  });

  /// The screen's ground, and the darker (or greyer) edge a vignette closes on.
  final Color ground;
  final Color groundEdge;

  /// A glass panel's body over a blur: the two stops of its gradient. [fill]
  /// is the lighter top-left, [fillStrong] the bottom-right and the fill a
  /// dialog or drawer uses outright.
  final Color fill;
  final Color fillStrong;

  /// A well sunk INTO a pane — an input, a key on a panel — rather than a
  /// pane floating over the ground.
  ///
  /// It cannot be [fill]: a pane's body is a wash of white that works because
  /// a softened backdrop shows through it, and on the frosted-ice side the
  /// pane itself is already milk-white, so more white on top of it is nothing
  /// at all. A well goes the other way — darker than its pane on ice, lighter
  /// on obsidian — which is what gives a text field and a glass key a body of
  /// their own in both modes.
  final Color wellFill;

  /// The one-pixel border, top to bottom. Lit above, fading below, so the
  /// panel reads as a pane catching light rather than a stroked rectangle.
  final Color borderTop;
  final Color borderBottom;

  /// The sheen along a panel's top edge.
  final Color highlight;

  /// The blur behind a panel, when it blurs at all.
  final double sigma;

  /// Type: display and titles, body, and the quiet third tier.
  final Color textDisplay;
  final Color textBody;
  final Color textMuted;

  /// The thumb of a segmented control: the one raised thing on a glass track.
  final Color thumb;

  /// A game card in the lobby (`GlassSurface.card`): the square cards on the
  /// rail and the chips at its corners (owner, 24 Sep 2026). Nearly opaque —
  /// it is the thing being read, not a pane over something — and lit the way
  /// its ground wants rather than one look inverted: by night a charcoal a
  /// step off the ground, a hairline of white and a deep shadow; by day a
  /// white card, a grey hairline and a shadow soft enough to be felt rather
  /// than seen. [cardFill] is the top of the body and [cardFillEnd] its foot.
  final Color cardFill;
  final Color cardFillEnd;

  /// The card's one-pixel edge, and the lit line just inside its top.
  final Color cardBorder;
  final Color cardHighlight;

  /// The quiet tier of type on a card — a caption, a chip's title. By day
  /// it is [textMuted]; by night a step up from white38, which is 3.5:1 on the
  /// card's charcoal, to white at 0.50 (4.9:1), so the smallest words on the
  /// card still clear AA.
  final Color cardMuted;

  /// What a card casts: stronger by night, where a shadow has to work harder
  /// to lift a charcoal card off a charcoal ground.
  final List<BoxShadow> cardShadow;

  /// The light behind a card, in its mode's colour: the peak alpha of that
  /// light, and how far it reaches as a fraction of the card's side. Ambient
  /// light rather than a coloured disc, and turned down in the owner's final
  /// pass (24 Sep 2026: "keep the hues, reduce the tint") — about 5% by day,
  /// where the card stays white with a warmth in one corner, and about 18% by
  /// night, where a charcoal card needs more to show any colour at all (it was
  /// 12% and 22%) — so the card's content always stays the brightest thing
  /// on it.
  final double glowStrength;
  final double glowReach;

  /// Obsidian glass.
  static const GlassColors dark = GlassColors(
    ground: Color(0xFF0D0E12),
    groundEdge: Color(0xFF08080A),
    fill: Color(0x0AFFFFFF), // white at 0.04
    fillStrong: Color(0x14FFFFFF), // white at 0.08
    wellFill: Color(0x14FFFFFF), // white at 0.08, over the panel's own body
    borderTop: Color(0x1FFFFFFF), // white at 0.12
    borderBottom: Color(0x0AFFFFFF), // white at 0.04
    highlight: Color(0x1AFFFFFF),
    sigma: 16,
    textDisplay: Colors.white,
    textBody: Colors.white70,
    textMuted: Colors.white38,
    thumb: Color(0x24FFFFFF),
    // rgb(35,38,42) at 0.92 over rgb(28,30,33) at 0.88: the brief's card
    // (rgba(30,32,35,0.88–0.92)), lit a shade from above.
    cardFill: Color(0xEA23262A),
    cardFillEnd: Color(0xE11C1E21),
    cardBorder: Color(0x1AFFFFFF), // white at 0.10
    cardHighlight: Color(0x14FFFFFF), // white at 0.08
    cardMuted: Color(0x80FFFFFF), // white at 0.50
    cardShadow: [
      BoxShadow(color: Color(0x66000000), blurRadius: 6, offset: Offset(0, 2)),
      BoxShadow(
        color: Color(0x73000000),
        blurRadius: 30,
        offset: Offset(0, 14),
      ),
    ],
    glowStrength: 0.18,
    glowReach: 0.72,
  );

  /// Frosted ice glass.
  static const GlassColors light = GlassColors(
    ground: Color(0xFFF4F5F7),
    groundEdge: Color(0xFFDFE2E7),
    fill: Color(0x9EFFFFFF), // white at 0.62
    fillStrong: Color(0xB3FFFFFF), // white at 0.70
    wellFill: Color(0xFFE7E9EE), // slate, sunk into a white pane
    borderTop: Color(0xE6FFFFFF), // a white highlight
    borderBottom: Color(0x0F000000), // black at 0.06
    highlight: Color(0xB3FFFFFF),
    sigma: 20,
    // #6B6F78 on the ice ground is 5.2:1; the spec's own #8A8D94 is 3.05:1,
    // which fails AA for the quiet tier that the rules sheet sets its card
    // notes in. The three tiers still read as three tiers.
    textDisplay: Color(0xFF121316),
    textBody: Color(0xFF4A4D55),
    textMuted: Color(0xFF6B6F78),
    thumb: Color(0xF2FFFFFF),
    // White at 0.97 over white at 0.94, and the brief's #E2E4E7 hairline.
    cardFill: Color(0xF7FFFFFF),
    cardFillEnd: Color(0xF0FFFFFF),
    cardBorder: Color(0xFFE2E4E7),
    cardHighlight: Color(0xFFFFFFFF),
    cardMuted: Color(0xFF6B6F78),
    // The slate-blue shadow the light theme casts everywhere (shadowFor), at
    // an alpha a white card needs and no more: a tight contact shadow and a
    // soft ambient one pooled beneath it — the depth pass (28 Sep 2026) let
    // the ambient reach a little further (0x14 over 20dp, 8 down, before), so
    // a white card stands off the pale room rather than lying on it.
    cardShadow: [
      BoxShadow(color: Color(0x0F0E1220), blurRadius: 3, offset: Offset(0, 1)),
      BoxShadow(
        color: Color(0x1A0E1220),
        blurRadius: 26,
        spreadRadius: -3,
        offset: Offset(0, 11),
      ),
    ],
    glowStrength: 0.05,
    glowReach: 0.56,
  );

  /// The set for the theme in scope. Falls back by brightness if a theme was
  /// built without the extension, so nothing paints wrong for want of a
  /// registration.
  static GlassColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<GlassColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  static final double _nightGround = dark.ground.computeLuminance();
  static final double _dayGround = light.ground.computeLuminance();

  /// How far these tokens have come from obsidian (0) to frosted ice (1),
  /// read off the ground colour, which lerps with the rest of the theme. For
  /// a surface that designs its own colours per theme and must cross-fade
  /// them with the theme's 420ms change rather than snap them at its middle,
  /// where the theme's brightness flips (the lobby drawers' body, the Stats
  /// drawer's record).
  double get dayShare =>
      ((ground.computeLuminance() - _nightGround) / (_dayGround - _nightGround))
          .clamp(0.0, 1.0);

  @override
  GlassColors copyWith({
    Color? ground,
    Color? groundEdge,
    Color? fill,
    Color? fillStrong,
    Color? wellFill,
    Color? borderTop,
    Color? borderBottom,
    Color? highlight,
    double? sigma,
    Color? textDisplay,
    Color? textBody,
    Color? textMuted,
    Color? thumb,
    Color? cardFill,
    Color? cardFillEnd,
    Color? cardBorder,
    Color? cardHighlight,
    Color? cardMuted,
    List<BoxShadow>? cardShadow,
    double? glowStrength,
    double? glowReach,
  }) => GlassColors(
    ground: ground ?? this.ground,
    groundEdge: groundEdge ?? this.groundEdge,
    fill: fill ?? this.fill,
    fillStrong: fillStrong ?? this.fillStrong,
    wellFill: wellFill ?? this.wellFill,
    borderTop: borderTop ?? this.borderTop,
    borderBottom: borderBottom ?? this.borderBottom,
    highlight: highlight ?? this.highlight,
    sigma: sigma ?? this.sigma,
    textDisplay: textDisplay ?? this.textDisplay,
    textBody: textBody ?? this.textBody,
    textMuted: textMuted ?? this.textMuted,
    thumb: thumb ?? this.thumb,
    cardFill: cardFill ?? this.cardFill,
    cardFillEnd: cardFillEnd ?? this.cardFillEnd,
    cardBorder: cardBorder ?? this.cardBorder,
    cardHighlight: cardHighlight ?? this.cardHighlight,
    cardMuted: cardMuted ?? this.cardMuted,
    cardShadow: cardShadow ?? this.cardShadow,
    glowStrength: glowStrength ?? this.glowStrength,
    glowReach: glowReach ?? this.glowReach,
  );

  /// What makes the theme toggle a cross-fade of every pane at once rather
  /// than a snap: `MaterialApp.themeAnimationDuration` lerps the extension
  /// along with the rest of the theme.
  @override
  GlassColors lerp(ThemeExtension<GlassColors>? other, double t) {
    if (other is! GlassColors) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return GlassColors(
      ground: c(ground, other.ground),
      groundEdge: c(groundEdge, other.groundEdge),
      fill: c(fill, other.fill),
      fillStrong: c(fillStrong, other.fillStrong),
      wellFill: c(wellFill, other.wellFill),
      borderTop: c(borderTop, other.borderTop),
      borderBottom: c(borderBottom, other.borderBottom),
      highlight: c(highlight, other.highlight),
      // Stepped, never interpolated. A blur radius is not a colour: every
      // distinct sigma allocates an ImageFilter that PremiumGlassPanel caches
      // for the life of the process, so lerping this would mint a filter per
      // frame of the 420 ms theme cross-fade and pin every one of them.
      sigma: t < 0.5 ? sigma : other.sigma,
      textDisplay: c(textDisplay, other.textDisplay),
      textBody: c(textBody, other.textBody),
      textMuted: c(textMuted, other.textMuted),
      thumb: c(thumb, other.thumb),
      cardFill: c(cardFill, other.cardFill),
      cardFillEnd: c(cardFillEnd, other.cardFillEnd),
      cardBorder: c(cardBorder, other.cardBorder),
      cardHighlight: c(cardHighlight, other.cardHighlight),
      cardMuted: c(cardMuted, other.cardMuted),
      cardShadow:
          BoxShadow.lerpList(cardShadow, other.cardShadow, t) ?? cardShadow,
      glowStrength: lerpDouble(glowStrength, other.glowStrength, t)!,
      glowReach: lerpDouble(glowReach, other.glowReach, t)!,
    );
  }
}

/// The overhead lamp's warm white, as `AppTheme.lampWarm` keeps it (this file
/// is imported by app_theme.dart, so it cannot import it back).
const Color _lampWarm = Color(0xFFFFF3DC);

/// One cloth for the casino table: its lit middle, its edge, the line printed
/// on it a step inside the rail, and the shadow the rail's lip throws on it.
@immutable
class TableCloth {
  const TableCloth({
    required this.centre,
    required this.edge,
    required this.line,
    required this.lip,
  });

  /// The cloth of a game whose own colour is [accent] — its lobby card's and
  /// its table tag's (`AppTheme.paletteFor`) — at a table of [brightness]
  /// (owner, 25 Sep 2026: "keep different table color for seen, blind,
  /// variation gameplay").
  ///
  /// The accent gives the HUE and nothing else: every game's cloth has the
  /// same lightness and the same restraint, so the three tables are one family
  /// told apart by colour alone, and the lobby card, the tag and the cloth of a
  /// game can never disagree. By day a pale tint — a soft champagne, a pale
  /// cyan, a soft lavender — deep enough to read as its colour beside the
  /// pearl rail, pale enough that charcoal type, the dark card backs and the
  /// pot's plate stand on it as they did on the pale emerald. By night a deep,
  /// quiet shade — olive-gold, deep sapphire, deep plum — falling to near
  /// black at its edge, as the deep emerald did.
  ///
  /// Never saturated (owner's brief, 25 Sep 2026: "soft cyan/teal felt
  /// surface ... Do NOT make it photorealistic"): 0.40 saturation at most by
  /// day and 0.42 by night, a tint of the game's colour rather than the colour
  /// itself.
  factory TableCloth.tinted(Color accent, Brightness brightness) {
    var hue = HSLColor.fromColor(accent).hue;
    // A yellow darkened goes olive, where gold itself darkens to amber, so by
    // night a hue among the yellows turns a few degrees towards orange (seen's
    // gold, 47°, to 42°); the blues and the violets keep theirs.
    if (brightness == Brightness.dark) {
      hue -= 8 * (1 - (hue - 55).abs() / 25).clamp(0.0, 1.0);
    }
    Color tone(double saturation, double lightness, [double alpha = 1]) =>
        HSLColor.fromAHSL(alpha, hue, saturation, lightness).toColor();
    return switch (brightness) {
      Brightness.light => TableCloth(
        centre: tone(0.40, 0.885),
        edge: tone(0.30, 0.79),
        line: tone(0.26, 0.55, 0.55),
        lip: tone(0.50, 0.14, 0.18),
      ),
      Brightness.dark => TableCloth(
        centre: tone(0.36, 0.16),
        edge: tone(0.42, 0.055),
        line: tone(0.34, 0.45, 0.30),
        lip: tone(0, 0, 0.45),
      ),
    };
  }

  /// The hue of the cloth a table with no game colour of its own lays: a
  /// soft teal, between the emerald the table was first drawn in and the
  /// cyan the brief names (owner's brief, 25 Sep 2026: "soft cyan/teal felt
  /// surface"; by night "deep teal/emerald table").
  static const double tealHue = 172;

  /// The playing surface: lit in the middle, falling towards its edge.
  final Color centre;
  final Color edge;

  /// The thin line printed on the cloth a step inside the rail.
  final Color line;

  /// The shadow the rail's lip throws on the top of the cloth.
  final Color lip;

  static TableCloth lerp(TableCloth a, TableCloth b, double t) {
    Color c(Color x, Color y) => Color.lerp(x, y, t) ?? x;
    return TableCloth(
      centre: c(a.centre, b.centre),
      edge: c(a.edge, b.edge),
      line: c(a.line, b.line),
      lip: c(a.lip, b.lip),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TableCloth &&
      other.centre == centre &&
      other.edge == edge &&
      other.line == line &&
      other.lip == lip;

  @override
  int get hashCode => Object.hash(centre, edge, line, lip);
}

/// The casino table's colours, one set per brightness, read by the one painter
/// that draws the table ([CasinoTableSurface]), the light that moves on it
/// ([TableAmbientEffects]) and the few words painted straight on its cloth
/// ([ink]).
///
/// **The VIP table** (owner's redesign brief, 3 Oct 2026: "Luxury daytime
/// casino / premium card lounge" by day, "Luxury VIP casino at night"; and,
/// asked, "One felt, like the reference"): ONE felt for every Teen Patti
/// table — a rich emerald by day, a deep wine-red by night — inside a dark
/// espresso leather rail with a thin metallic gold edge, in both themes, so
/// day and night are the same table under different light. Each game keeps
/// its colour on its tag and in the lobby, not on the cloth. The per-game
/// cloths of 25 Sep 2026 ([cloths], [TableCloth.tinted]) are still wired:
/// `AppTheme.perGameCloths` brings them back.
///
/// Both felts are deep, so the words on the cloth are light in both themes
/// ([ink]); every word that stands on a plate keeps its theme's ink.
///
/// A [ThemeExtension], as [GlassColors] is, so the theme's cross-fade carries
/// the table with it rather than snapping it.
@immutable
class CasinoTableColors extends ThemeExtension<CasinoTableColors> {
  const CasinoTableColors({
    required this.railTop,
    required this.railBottom,
    required this.railSheen,
    required this.rim,
    required this.rimLow,
    required this.seam,
    required this.cloth,
    this.cloths = const {},
    required this.shadow,
    required this.shadowBlur,
    required this.glow,
    required this.lamp,
    required this.lampAlpha,
    required this.turnGlow,
    required this.ink,
  });

  /// The rail — the "outer table" — lit from above: its top and its foot.
  final Color railTop;
  final Color railBottom;

  /// The light along the rail's upper half, which rounds it into a lip.
  final Color railSheen;

  /// The thin champagne line round the rail's outer edge, lit at the top and
  /// deeper at the foot.
  final Color rim;
  final Color rimLow;

  /// The seam where the rail meets the cloth.
  final Color seam;

  /// The felt: the VIP table's one cloth (3 Oct 2026) — emerald by day,
  /// wine-red by night — which every game lays while
  /// `AppTheme.perGameCloths` is off, and the cloth of any game with none of
  /// its own in [cloths] when it is on.
  final TableCloth cloth;

  /// Each game's own cloth, by its wire category (`seen`, `blind`,
  /// `variation`): filled from the games' accents (`AppTheme.tableColours`)
  /// only while `AppTheme.perGameCloths` is on; empty in the two sets below.
  final Map<String, TableCloth> cloths;

  /// The one soft shadow the table casts on the floor, and its blur.
  final Color shadow;
  final double shadowBlur;

  /// Light round the table's outer edge: a controlled warm gold by night,
  /// none by day, where a glow on the ivory floor reads as a smudge.
  final Color glow;

  /// The overhead lamp's pool on the cloth, and its alpha at rest (it
  /// breathes a little over that).
  final Color lamp;
  final double lampAlpha;

  /// The warm light the near rail takes on the viewer's turn.
  final Color turnGlow;

  /// The ink of a word painted straight on the cloth, with no plate under it
  /// — the waiting line, a seat's status line, the variation lines. Light on
  /// both felts, 4.5:1 or more on the felt and the rail.
  final Color ink;

  /// The cloth for a table of [category]: its game's own, or the felt.
  TableCloth clothFor(String? category) => cloths[category] ?? cloth;

  /// This set with [cloths] as each game's cloth.
  CasinoTableColors withCloths(Map<String, TableCloth> cloths) =>
      copyWith(cloths: cloths);

  /// By night (VIP casino): a dark espresso leather rail with a gold edge, a
  /// deep wine-red felt falling to near black at its rim, and a controlled
  /// warm-gold light round the table — no neon.
  static const CasinoTableColors dark = CasinoTableColors(
    railTop: Color(0xFF34251D),
    railBottom: Color(0xFF110B08),
    railSheen: Color(0x26FFE3C2),
    rim: Color(0xF2EAC671),
    rimLow: Color(0xCC8F6A1E),
    seam: Color(0xB3000000),
    cloth: TableCloth(
      centre: Color(0xFF6A1524),
      edge: Color(0xFF22060B),
      line: Color(0x3DE8C877),
      lip: Color(0x8C000000),
    ),
    shadow: Color(0xB3000000),
    shadowBlur: 26,
    glow: Color(0x33E8B04B),
    lamp: _lampWarm,
    lampAlpha: 0.07,
    turnGlow: Color(0xFFF1D27A),
    ink: Color(0xFFF6EEDD),
  );

  /// By day (premium card lounge): the same espresso leather rail and gold
  /// edge, a rich emerald felt deepening towards its rim, and a soft warm
  /// shadow on the ivory floor. No glow round the rail: on a pale floor a glow
  /// reads as a smudge.
  static const CasinoTableColors light = CasinoTableColors(
    railTop: Color(0xFF4A3527),
    railBottom: Color(0xFF22160E),
    railSheen: Color(0x38FFF1DC),
    rim: Color(0xFFE4C066),
    rimLow: Color(0xFFA67C22),
    seam: Color(0x99000000),
    cloth: TableCloth(
      // Deep enough under the lamp for the words painted on it ([ink]) to
      // read 4.5:1 or more, and the gold of a chosen variation as well.
      centre: Color(0xFF186B47),
      edge: Color(0xFF083826),
      line: Color(0x47F1D27A),
      lip: Color(0x6B000000),
    ),
    shadow: Color(0x5C2E1E12),
    shadowBlur: 24,
    glow: Color(0x00000000),
    lamp: _lampWarm,
    lampAlpha: 0.14,
    turnGlow: Color(0xFFD4A514),
    ink: Color(0xFFF8F2E4),
  );

  /// The set for the theme in scope, by brightness when a theme was built
  /// without the extension.
  static CasinoTableColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<CasinoTableColors>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  CasinoTableColors copyWith({
    Color? railTop,
    Color? railBottom,
    Color? railSheen,
    Color? rim,
    Color? rimLow,
    Color? seam,
    TableCloth? cloth,
    Map<String, TableCloth>? cloths,
    Color? shadow,
    double? shadowBlur,
    Color? glow,
    Color? lamp,
    double? lampAlpha,
    Color? turnGlow,
    Color? ink,
  }) => CasinoTableColors(
    railTop: railTop ?? this.railTop,
    railBottom: railBottom ?? this.railBottom,
    railSheen: railSheen ?? this.railSheen,
    rim: rim ?? this.rim,
    rimLow: rimLow ?? this.rimLow,
    seam: seam ?? this.seam,
    cloth: cloth ?? this.cloth,
    cloths: cloths ?? this.cloths,
    shadow: shadow ?? this.shadow,
    shadowBlur: shadowBlur ?? this.shadowBlur,
    glow: glow ?? this.glow,
    lamp: lamp ?? this.lamp,
    lampAlpha: lampAlpha ?? this.lampAlpha,
    turnGlow: turnGlow ?? this.turnGlow,
    ink: ink ?? this.ink,
  );

  @override
  CasinoTableColors lerp(ThemeExtension<CasinoTableColors>? other, double t) {
    if (other is! CasinoTableColors) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return CasinoTableColors(
      railTop: c(railTop, other.railTop),
      railBottom: c(railBottom, other.railBottom),
      railSheen: c(railSheen, other.railSheen),
      rim: c(rim, other.rim),
      rimLow: c(rimLow, other.rimLow),
      seam: c(seam, other.seam),
      cloth: TableCloth.lerp(cloth, other.cloth, t),
      // Each game's cloth crosses into its own cloth in the other theme.
      cloths: {
        for (final game in {...cloths.keys, ...other.cloths.keys})
          game: TableCloth.lerp(clothFor(game), other.clothFor(game), t),
      },
      shadow: c(shadow, other.shadow),
      shadowBlur: lerpDouble(shadowBlur, other.shadowBlur, t)!,
      glow: c(glow, other.glow),
      lamp: c(lamp, other.lamp),
      lampAlpha: lerpDouble(lampAlpha, other.lampAlpha, t)!,
      turnGlow: c(turnGlow, other.turnGlow),
      ink: c(ink, other.ink),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CasinoTableColors &&
      other.railTop == railTop &&
      other.railBottom == railBottom &&
      other.railSheen == railSheen &&
      other.rim == rim &&
      other.rimLow == rimLow &&
      other.seam == seam &&
      other.cloth == cloth &&
      mapEquals(other.cloths, cloths) &&
      other.shadow == shadow &&
      other.shadowBlur == shadowBlur &&
      other.glow == glow &&
      other.lamp == lamp &&
      other.lampAlpha == lampAlpha &&
      other.turnGlow == turnGlow &&
      other.ink == ink;

  @override
  int get hashCode => Object.hash(
    railTop,
    railBottom,
    railSheen,
    rim,
    rimLow,
    seam,
    cloth,
    Object.hashAllUnordered(
      cloths.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    shadow,
    shadowBlur,
    glow,
    lamp,
    lampAlpha,
    turnGlow,
    ink,
  );
}
