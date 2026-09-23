import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../theme/app_theme.dart';
import 'poker_chip.dart';

/// Twelve poker chips shuffled from two stacks into one and back, looping
/// every two seconds: the glyph beside the title of each of the lobby's engine
/// cards, Teen Patti and Poker (owner, 23 Sep 2026: "use this animation on
/// teenPatti and Poker card of UI and change coin colour accord to the card
/// coin u have, but animation should be same").
///
/// The file is played as it is — its motion and its timing are untouched —
/// and only its colours change, at runtime, through [chipShuffleColours].
const String chipShuffleAsset = 'assets/animations/Poker Chip Shuffle.json';

/// The file's chip, as it is built: one precomp (`RedChip`) drawn twelve
/// times, whose eleven shape layers hold one fill each. Five are the red of
/// the chip's body, listed lightest first with the file's own colour.
///
/// test/chip_shuffle_test.dart holds the file to these, so a replacement that
/// renamed a layer or moved a colour fails there rather than keeping its red.
const Map<String, Color> chipShuffleBodyLayers = {
  // The rim round the centre of the face.
  'Layer 8 Outlines': Color.from(alpha: 1, red: .969, green: .224, blue: .204),
  // The spots round the top and down the edge, laid in multiply (below).
  'Layer 10 Outlines': Color.from(alpha: 1, red: .965, green: .22, blue: .2),
  // The ring the dashes sit on.
  'Layer 4 Outlines': Color.from(alpha: 1, red: .918, green: .149, blue: .137),
  // The shadow under the near side of that ring.
  'Layer 5 Outlines': Color.from(alpha: 1, red: .776, green: .118, blue: .067),
  // The shadow on its far wall.
  'Layer 11 Outlines': Color.from(alpha: 1, red: .741, green: .11, blue: .055),
};

/// The other five fills that are recoloured: the chip's white inlay and the
/// greys it is shaded with, lightest first, with the file's own colour.
const Map<String, Color> chipShuffleInlayLayers = {
  // The centre of the face.
  'Layer 9 Outlines': Color.from(alpha: 1, red: .969, green: .969, blue: .969),
  // The top of the chip, which shows as the stripes between the spots.
  'Layer 1 Outlines': Color.from(alpha: 1, red: .969, green: .969, blue: .969),
  // The twelve dashes round the face.
  'Layer 7 Outlines': Color.from(alpha: 1, red: .933, green: .929, blue: .925),
  // The lip between the top and the edge.
  'Layer 3 Outlines': Color.from(alpha: 1, red: .808, green: .808, blue: .808),
  // The edge, which shows as its stripes.
  'Layer 2 Outlines': Color.from(alpha: 1, red: .699, green: .699, blue: .699),
};

/// The one fill left as the file has it: a neutral grey laid in multiply over
/// the body-coloured ring round the face. A neutral multiply only darkens, so
/// it already shades that ring in whatever colour the ring is; tinting it with
/// the inlay would stain the ring instead.
const String chipShuffleShadeLayer = 'Layer 6 Outlines';

/// The layer the file lays its spots with in multiply: what shows is its
/// colour times the inlay under it (the top of the chip, the lip, the edge),
/// not its colour.
const String _spots = 'Layer 10 Outlines';

/// The inlay's lightest grey in the file — the white its other greys are
/// fractions of, and the top of the chip the spots are laid over.
const double _inlayWhite = .969;

/// Every recoloured fill of [chipShuffleAsset], by layer name, for a chip whose
/// body is [body] — a lobby card's accent, the colour its old coin was.
///
/// The five body shades are the five a [PokerChip] of that colour is moulded
/// in ([chipBodyShades]: its lit top, the body, its face, the foot of its body
/// and its wall), given to the five red layers in the file's own light-to-dark
/// order. The inlay is champagne ([AppTheme.goldBright]), the colour every
/// chip's inserts take against a deep body (`_ChipTones.rim`) and the one the
/// card's coin showed on its top chip; the file's white takes it whole and each
/// grey takes it darkened by the grey's own share of that white, so the edge
/// and the lip stay shaded as the file shades them.
///
/// The spots are laid in multiply over the champagne top, so they are given
/// the body DIVIDED by the champagne, which multiplies back to the body
/// itself. Where the champagne is too dark in a channel to carry the body
/// (the dark theme's pale teal is bluer than it), the whole chip is taken
/// down to the lightest shade of the same hue that it can carry, instead of
/// letting one channel clip and turn the teal green.
Map<String, Color> chipShuffleColours(Color body) {
  const inlay = AppTheme.goldBright;
  // The share of [body] the champagne can carry in every channel.
  final carry = [
    (inlay.r, body.r),
    (inlay.g, body.g),
    (inlay.b, body.b),
  ].fold(1.0, (k, c) => c.$2 <= 0 ? k : math.min(k, c.$1 / c.$2));
  final chip = carry >= 1 ? body : Color.lerp(body, Colors.black, 1 - carry)!;
  final shades = chipBodyShades(chip);

  return {
    for (final (i, layer) in chipShuffleBodyLayers.keys.indexed)
      layer: layer == _spots ? _over(shades[i], inlay) : shades[i],
    for (final MapEntry(key: layer, value: grey)
        in chipShuffleInlayLayers.entries)
      layer: Color.lerp(
        inlay,
        Colors.black,
        (1 - _lightness(grey) / _inlayWhite).clamp(0.0, 1.0),
      )!,
  };
}

/// The colour that, laid in multiply over [ground], shows as [shown].
Color _over(Color shown, Color ground) => Color.from(
  alpha: 1,
  red: (shown.r / ground.r).clamp(0.0, 1.0),
  green: (shown.g / ground.g).clamp(0.0, 1.0),
  blue: (shown.b / ground.b).clamp(0.0, 1.0),
);

/// A grey's lightness: the mean of its channels (the dashes are a warm grey).
double _lightness(Color c) => (c.r + c.g + c.b) / 3;

/// [chipShuffleColours] as the value delegates that paint them, each reaching
/// through both precomps to its layer in all twelve chips.
List<ValueDelegate<Object>> chipShuffleDelegates(Color body) => [
  for (final MapEntry(key: layer, value: colour) in chipShuffleColours(
    body,
  ).entries)
    ValueDelegate.color(['**', layer, '**'], value: colour),
];

/// The chip shuffle, in a [size]-square slot.
///
/// The file's canvas is mostly empty: across the whole loop its chips reach
/// over a box about seven tenths of its side, resting at the foot of it and
/// tossed to its top. The canvas is drawn large enough for that reach to fill
/// the slot, and its empty margins are left to hang outside it, unpainted.
///
/// It loops for as long as it is on screen, as the file does. Nothing in the
/// app honours the platform's reduce-motion setting yet, so neither does this.
///
/// The lobby rebuilds every second (its cards watch `GameState`), and none of
/// that reaches the animation: the composition is decoded once for the app
/// (the lottie package's cache, keyed by the asset), and the subtree under
/// this widget — the delegates included, since a new [LottieDelegates] never
/// compares equal to the last and would re-resolve every key path — is built
/// once per colour and size and handed back unchanged on every other build,
/// so the animation's own controller is never so much as touched by a tick.
class ChipShuffle extends StatefulWidget {
  const ChipShuffle({
    super.key,
    required this.colour,
    required this.size,
    this.fallback,
  });

  /// The colour of the chips' body; see [chipShuffleColours].
  final Color colour;

  /// The side of the square the shuffle takes in layout.
  final double size;

  /// Drawn instead if the file cannot be read.
  final Widget? fallback;

  /// The box the chips reach over across the loop, as a share of the canvas
  /// (x 168–916, y 128–892 of 1080), and its centre's offset from the
  /// canvas's, as the same share.
  static const double _reach = 764 / 1080;
  static const Offset _reachShift = Offset(
    (542 - 540) / 1080,
    (510 - 540) / 1080,
  );

  /// The side a slot needs for each of the twelve chips to be [chipWidth]
  /// wide: a chip is 370 of the 764 the loop reaches over.
  static double sizeForChip(double chipWidth) => chipWidth * 764 / 370;

  @override
  State<ChipShuffle> createState() => _ChipShuffleState();
}

class _ChipShuffleState extends State<ChipShuffle> {
  (Color, double)? _builtFor;
  Widget? _built;

  @override
  Widget build(BuildContext context) {
    final key = (widget.colour, widget.size);
    if (key != _builtFor) {
      _builtFor = key;
      _built = _shuffle();
    }
    return _built!;
  }

  Widget _shuffle() {
    final delegates = LottieDelegates(
      values: chipShuffleDelegates(widget.colour),
    );
    final fallback = widget.fallback;
    final art = widget.size / ChipShuffle._reach;
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: OverflowBox(
          minWidth: art,
          maxWidth: art,
          minHeight: art,
          maxHeight: art,
          child: Transform.translate(
            offset: -ChipShuffle._reachShift * art,
            child: Lottie.asset(
              chipShuffleAsset,
              delegates: delegates,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stack) =>
                  Center(child: fallback ?? const SizedBox.shrink()),
            ),
          ),
        ),
      ),
    );
  }
}
