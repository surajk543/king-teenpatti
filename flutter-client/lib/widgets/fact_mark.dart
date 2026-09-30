import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Where a lobby card fact's Lottie mark sits in its file: the owner's lock
/// on the "Open to you" row ([OpenLock]), wallet on the "Entry" row
/// ([EntryWallet]) and piggy bank on the "Pot limit" row ([PotPiggy]), the
/// rules key's book ([RuleBook]), the info key's waves ([InfoWave]), the
/// coins at a card's top left ([CardCoins]) and the Shop key's shop
/// ([ShopMark]).
class FactMarkArt {
  const FactMarkArt({
    required this.asset,
    required this.canvas,
    required this.centre,
    required this.extent,
    required this.fallback,
    this.gradient,
    this.recolour,
    this.loopFrom,
  });

  /// The Lottie, under `assets/animations/`.
  final String asset;

  /// The file's square canvas, in its own units.
  final double canvas;

  /// The middle of the art at rest, in canvas units: drawn at the middle of
  /// the icon's box.
  final Offset centre;

  /// How much of the canvas, in its units, fills the icon's box: the art's
  /// widest side at rest.
  final double extent;

  /// Drawn instead, in the icon's colour, if the file cannot be read.
  final IconData fallback;

  /// The colours of the file's gradients, stop by stop — every gradient in it
  /// the same — or none where it has no gradient. A gradient cannot be tinted
  /// from what it was (the player hands its colour callback no colours), so
  /// it is given these, tinted.
  final List<Color>? gradient;

  /// What this art alone needs on a card of this brightness, over and above
  /// the card's colour — none where the file reads on that card as it is.
  /// Handed [tint], the card's colour as [FactMark] lays it on the file's
  /// colours, so what it sets is in the card's colour too. A top-level
  /// function, so the art stays a constant.
  final List<ValueDelegate<Object>> Function(
    Brightness brightness,
    Color Function(Color) tint,
  )?
  recolour;

  /// Where the loop starts, as a share of the file, for art that builds
  /// itself from nothing: played whole once, then from here to its end, over
  /// and over — it never goes back to the empty start. None loops it whole.
  final double? loopFrom;
}

/// [original] in [accent]'s hue and saturation at [original]'s own
/// luminance, its alpha kept; a white or a grey (no hue to speak of) as it
/// is.
///
/// Holding the luminance holds every contrast the file had — against the
/// card, and between its own parts — whatever the card's colour: a gold made
/// to the blue's luminance is a deep gold, never a yellow that vanishes on the
/// white card.
Color tintAt(Color original, Color accent) {
  final hsl = HSLColor.fromColor(original);
  if (hsl.saturation < 0.08) return original;
  final to = HSLColor.fromColor(accent);
  final target = original.withValues(alpha: 1).computeLuminance();
  // Luminance only grows with lightness at a fixed hue and saturation, from
  // black at 0 to white at 1, so every luminance is reached exactly once.
  var lo = 0.0, hi = 1.0;
  for (var i = 0; i < 24; i++) {
    final mid = (lo + hi) / 2;
    final y = HSLColor.fromAHSL(
      1,
      to.hue,
      to.saturation,
      mid,
    ).toColor().computeLuminance();
    if (y < target) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return HSLColor.fromAHSL(
    original.a,
    to.hue,
    to.saturation,
    (lo + hi) / 2,
  ).toColor();
}

/// The delegates a mark of [art] is drawn with on a card of [brightness] in
/// [accent] — made once for each and kept, so that cards of one colour share
/// a render cache (it keys on a callback's identity) and a card of another
/// colour, or the other theme, never replays their frames.
final _delegates =
    <(FactMarkArt, Brightness?, Color?), List<ValueDelegate<Object>>>{};

List<ValueDelegate<Object>> _delegatesFor(
  FactMarkArt art,
  Brightness? brightness,
  Color? accent,
) => _delegates.putIfAbsent((art, brightness, accent), () {
  final tinted = <Color, Color>{};
  Color tint(Color c) =>
      accent == null ? c : tinted.putIfAbsent(c, () => tintAt(c, accent));
  return [
    if (accent != null) ...[
      ValueDelegate.color(const ['**'], callback: (f) => tint(f.startValue!)),
      ValueDelegate.strokeColor(const [
        '**',
      ], callback: (f) => tint(f.startValue!)),
      if (art.gradient case final stops?)
        ValueDelegate.gradientColor(
          const ['**'],
          value: [for (final c in stops) tint(c)],
        ),
    ],
    // After the card's colour, so on what they both reach, these win.
    if (brightness != null) ...art.recolour!(brightness, tint),
  ];
});

/// A lobby card fact's mark played from [art] in the icon's box, [size]
/// square — the box the fact row's icon had.
///
/// The canvas is drawn large enough for the art to fill that box and is
/// placed so the art's middle is the box's; the canvas's empty margins hang
/// outside the box, unpainted, and whatever the art does in motion past the
/// box it does in the gaps the row leaves round the icon.
///
/// [tint] — the card's colour: gold on Seen, blue on Blind, violet on
/// Variation — lays its hue on every coloured part of the file at that
/// part's own luminance ([tintAt]; owner, 29 Sep 2026: "change the wallet
/// color and lock and piggy bank animation color acc to card, yellow, blue,
/// purple, but keep the animation"). None plays the file's own colours. Over
/// that, whatever [FactMarkArt.recolour] asks of the card's brightness.
///
/// [animate] false stands it still on its first frame — on its last, for art
/// that builds itself from nothing ([FactMarkArt.loopFrom]); [opacity] below
/// 1 fades it.
///
/// The lobby rebuilds every second, and none of it reaches the animation: the
/// subtree is built once per size, motion, strength, colour, fallback colour
/// and (for art recoloured by brightness) brightness and handed back
/// unchanged, so the Lottie's own controller is never touched by a tick
/// ([ChipShuffle]'s rule).
class FactMark extends StatefulWidget {
  const FactMark({
    super.key,
    required this.art,
    required this.size,
    required this.fallbackInk,
    required this.boxKey,
    this.tint,
    this.animate = true,
    this.opacity = 1,
  });

  final FactMarkArt art;

  /// The side of the square the mark takes in layout.
  final double size;

  /// The colour of [FactMarkArt.fallback].
  final Color fallbackInk;

  /// The key on the mark's box, by which the tests find it.
  final Key boxKey;

  /// The card's colour, or none for the file's own.
  final Color? tint;

  final bool animate;
  final double opacity;

  @override
  State<FactMark> createState() => _FactMarkState();
}

class _FactMarkState extends State<FactMark>
    with SingleTickerProviderStateMixin {
  (FactMarkArt, double, bool, double, Color, Key, Color?, Brightness?)?
  _builtFor;
  Widget? _built;

  /// Drives art that loops from part-way ([FactMarkArt.loopFrom]); made here,
  /// never lazily (CLAUDE.md §12.3), and only for such art.
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.art.loopFrom != null) {
      _controller = AnimationController(vsync: this);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// The file has loaded: once through, then from [FactMarkArt.loopFrom] to
  /// the end, at the file's own speed; or its last frame, standing still.
  void _loaded(LottieComposition composition) {
    final controller = _controller!;
    final from = widget.art.loopFrom!;
    controller.duration = composition.duration;
    if (!widget.animate) {
      controller.value = 1;
      return;
    }
    controller.forward(from: 0).then((_) {
      if (!mounted) return;
      controller.repeat(
        min: from,
        max: 1,
        period: composition.duration * (1 - from),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final brightness = widget.art.recolour == null
        ? null
        : Theme.of(context).brightness;
    final key = (
      widget.art,
      widget.size,
      widget.animate,
      widget.opacity,
      widget.fallbackInk,
      widget.boxKey,
      widget.tint,
      brightness,
    );
    if (key != _builtFor) {
      _builtFor = key;
      _built = _mark(_delegatesFor(widget.art, brightness, widget.tint));
    }
    return _built!;
  }

  Widget _mark(List<ValueDelegate<Object>> recolour) {
    final art = widget.art;
    final size = widget.size;
    final scale = size / art.extent;
    final canvas = art.canvas * scale;
    final half = art.canvas / 2;
    final ink = widget.fallbackInk;
    Widget lottie = Lottie.asset(
      art.asset,
      width: canvas,
      height: canvas,
      fit: BoxFit.contain,
      animate: widget.animate,
      controller: _controller,
      onLoaded: _controller == null ? null : _loaded,
      // The render cache keys on these, so a gold card's frames are never
      // replayed on a blue one, nor a day card's on the night card.
      delegates: recolour.isEmpty ? null : LottieDelegates(values: recolour),
      // A loop replayed for as long as the lobby is open, a card or more at
      // a time: kept as pictures after the first loop, not rebuilt from
      // their paths every frame (ChipShuffle's reasoning).
      renderCache: RenderCache.drawingCommands,
      errorBuilder: (context, error, stack) => Center(
        child: Icon(art.fallback, size: size, color: ink),
      ),
    );
    if (widget.opacity < 1) {
      lottie = Opacity(opacity: widget.opacity, child: lottie);
    }
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox.square(
          key: widget.boxKey,
          dimension: size,
          child: OverflowBox(
            minWidth: canvas,
            maxWidth: canvas,
            minHeight: canvas,
            maxHeight: canvas,
            child: Transform.translate(
              offset:
                  Offset(half - art.centre.dx, half - art.centre.dy) * scale,
              child: lottie,
            ),
          ),
        ),
      ),
    );
  }
}
