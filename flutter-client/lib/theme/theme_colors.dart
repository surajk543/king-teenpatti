import 'dart:ui' show lerpDouble;

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
    // an alpha a white card needs and no more.
    cardShadow: [
      BoxShadow(color: Color(0x0D0E1220), blurRadius: 3, offset: Offset(0, 1)),
      BoxShadow(color: Color(0x140E1220), blurRadius: 20, offset: Offset(0, 8)),
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

/// The casino table's colours, one set per brightness (owner's brief, 24 Sep
/// 2026: "a large oval/rounded casino table surface ... a modern luxury mobile
/// casino ... Do NOT use the old-fashioned red casino table aesthetic"), read
/// by the one painter that draws the table ([CasinoTableSurface]), the light
/// that moves on it ([TableAmbientEffects]) and the light behind the host
/// ([DealerHost]).
///
/// Two looks designed for their own grounds rather than one inverted: by day
/// a pearl rail lit from above round a pale emerald cloth, with a thin
/// champagne rim; by night a graphite rail round a deep emerald cloth that
/// falls to near black at its edge, a subtler gold rim and a controlled cyan
/// light around the table. Both cloths keep the table's type legible as it
/// always was — charcoal on the pale cloth, white on the dark one — so no word
/// on the felt changes colour for the table's sake.
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
    required this.feltCentre,
    required this.feltEdge,
    required this.feltLine,
    required this.lipShadow,
    required this.shadow,
    required this.shadowBlur,
    required this.glow,
    required this.lamp,
    required this.lampAlpha,
    required this.turnGlow,
    required this.hostHalo,
    required this.hostHaloOuter,
    required this.hostHaloTurn,
    required this.hostHaloWin,
    required this.sparkle,
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

  /// The playing surface: lit in the middle, falling towards its edge.
  final Color feltCentre;
  final Color feltEdge;

  /// The thin line printed on the cloth a step inside the rail.
  final Color feltLine;

  /// The shadow the rail's lip throws on the top of the cloth.
  final Color lipShadow;

  /// The one soft shadow the table casts on the floor, and its blur.
  final Color shadow;
  final double shadowBlur;

  /// Light round the table's outer edge: a controlled cyan by night, none by
  /// day, where a glow on a pale floor reads as a smudge.
  final Color glow;

  /// The overhead lamp's pool on the cloth, and its alpha at rest (it
  /// breathes a little over that).
  final Color lamp;
  final double lampAlpha;

  /// The warm light the near rail takes on the viewer's turn.
  final Color turnGlow;

  /// The light behind the host: at rest (its core and the colour it fades
  /// into), on the viewer's turn and at a win.
  final Color hostHalo;
  final Color hostHaloOuter;
  final Color hostHaloTurn;
  final Color hostHaloWin;

  /// The sparks round the host at a win.
  final Color sparkle;

  /// By night: graphite, deep emerald, a subtle gold rim, a controlled cyan
  /// glow.
  static const CasinoTableColors dark = CasinoTableColors(
    railTop: Color(0xFF2E3238),
    railBottom: Color(0xFF16181C),
    railSheen: Color(0x1FFFFFFF),
    rim: Color(0xC7E8C877),
    rimLow: Color(0xA38A6A18),
    seam: Color(0x99000000),
    feltCentre: Color(0xFF123F35),
    feltEdge: Color(0xFF05140F),
    feltLine: Color(0x4D3E9C85),
    lipShadow: Color(0x73000000),
    shadow: Color(0x99000000),
    shadowBlur: 22,
    glow: Color(0x2E3FD1C2),
    lamp: _lampWarm,
    lampAlpha: 0.075,
    turnGlow: Color(0xFFF1D27A),
    hostHalo: Color(0x29F1D27A),
    hostHaloOuter: Color(0x1F3FD1C2),
    hostHaloTurn: Color(0x47F1D27A),
    hostHaloWin: Color(0x61F1D27A),
    sparkle: Color(0xFFF7E3A6),
  );

  /// By day: a pearl rail, a pale emerald cloth, a champagne rim, and a soft
  /// shadow in the light theme's own slate.
  static const CasinoTableColors light = CasinoTableColors(
    railTop: Color(0xFFFCFAF5),
    railBottom: Color(0xFFE7DECB),
    railSheen: Color(0xCCFFFFFF),
    rim: Color(0xFFD9B458),
    rimLow: Color(0xFFA9822A),
    seam: Color(0x80A88A48),
    feltCentre: Color(0xFFE6F2ED),
    feltEdge: Color(0xFFC3DDD4),
    feltLine: Color(0x8C8DBDAE),
    lipShadow: Color(0x2E0E3A30),
    shadow: Color(0x330E1220),
    shadowBlur: 18,
    glow: Color(0x00000000),
    lamp: _lampWarm,
    lampAlpha: 0.30,
    turnGlow: Color(0xFFD4A514),
    hostHalo: Color(0x29E5C274),
    hostHaloOuter: Color(0x1476C8BA),
    hostHaloTurn: Color(0x42D4A514),
    hostHaloWin: Color(0x5CD4A514),
    sparkle: Color(0xFFD4A514),
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
    Color? feltCentre,
    Color? feltEdge,
    Color? feltLine,
    Color? lipShadow,
    Color? shadow,
    double? shadowBlur,
    Color? glow,
    Color? lamp,
    double? lampAlpha,
    Color? turnGlow,
    Color? hostHalo,
    Color? hostHaloOuter,
    Color? hostHaloTurn,
    Color? hostHaloWin,
    Color? sparkle,
  }) => CasinoTableColors(
    railTop: railTop ?? this.railTop,
    railBottom: railBottom ?? this.railBottom,
    railSheen: railSheen ?? this.railSheen,
    rim: rim ?? this.rim,
    rimLow: rimLow ?? this.rimLow,
    seam: seam ?? this.seam,
    feltCentre: feltCentre ?? this.feltCentre,
    feltEdge: feltEdge ?? this.feltEdge,
    feltLine: feltLine ?? this.feltLine,
    lipShadow: lipShadow ?? this.lipShadow,
    shadow: shadow ?? this.shadow,
    shadowBlur: shadowBlur ?? this.shadowBlur,
    glow: glow ?? this.glow,
    lamp: lamp ?? this.lamp,
    lampAlpha: lampAlpha ?? this.lampAlpha,
    turnGlow: turnGlow ?? this.turnGlow,
    hostHalo: hostHalo ?? this.hostHalo,
    hostHaloOuter: hostHaloOuter ?? this.hostHaloOuter,
    hostHaloTurn: hostHaloTurn ?? this.hostHaloTurn,
    hostHaloWin: hostHaloWin ?? this.hostHaloWin,
    sparkle: sparkle ?? this.sparkle,
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
      feltCentre: c(feltCentre, other.feltCentre),
      feltEdge: c(feltEdge, other.feltEdge),
      feltLine: c(feltLine, other.feltLine),
      lipShadow: c(lipShadow, other.lipShadow),
      shadow: c(shadow, other.shadow),
      shadowBlur: lerpDouble(shadowBlur, other.shadowBlur, t)!,
      glow: c(glow, other.glow),
      lamp: c(lamp, other.lamp),
      lampAlpha: lerpDouble(lampAlpha, other.lampAlpha, t)!,
      turnGlow: c(turnGlow, other.turnGlow),
      hostHalo: c(hostHalo, other.hostHalo),
      hostHaloOuter: c(hostHaloOuter, other.hostHaloOuter),
      hostHaloTurn: c(hostHaloTurn, other.hostHaloTurn),
      hostHaloWin: c(hostHaloWin, other.hostHaloWin),
      sparkle: c(sparkle, other.sparkle),
    );
  }
}
