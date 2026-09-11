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
    );
  }
}
