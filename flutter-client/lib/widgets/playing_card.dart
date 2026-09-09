import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_theme.dart';

/// A playing card, face up or face down.
///
/// Cards keep one aspect ratio everywhere — the player's own hand and every
/// opponent's — so a card means the same thing wherever it appears. Turning one
/// over animates: the card rotates on its long axis and the face appears at the
/// halfway point, which is what a real card does and what makes "see" feel like
/// an action rather than a repaint.
///
/// The face is printed stock, never glass: solid ground, a cut edge, drawn
/// pips and a drawn rank index. Nothing on it is a system glyph, because a
/// Unicode pip and a UI sans-serif index are what make a card app look like an
/// app rather than a deck.
class PlayingCard extends StatefulWidget {
  const PlayingCard({
    super.key,
    this.code,
    this.height = 96,
    this.dimmed = false,
  });

  /// A server card code such as "As" or "Td". Null means face down.
  final String? code;
  final double height;

  /// Packed players' cards are dimmed rather than removed, so the seat still
  /// reads as "was in this hand".
  final bool dimmed;

  /// The card-back artwork's own ratio, which is the standard 5:7.
  static const double aspect = 240 / 336;

  // Every measurement below is a fraction of [height], so one set of numbers
  // covers every size the app asks for. The card heights that actually occur
  // are the rules sheet's 46, the viewer's own hand (Dim.handH, 50..134) and a
  // reveal card (Dim.revealCardH: 61.2 at screen h=360, 69.9 at h=411, 104.0 at
  // h=800). At those three reveal sizes: rank box 15.9 / 18.2 / 27.0, index pip
  // 7.3 / 8.4 / 12.5, centre pip 20.8 / 23.8 / 35.4.
  //
  // The index block ends at 0.45h (0.055 top + 0.26 rank + 0.015 gap + 0.12
  // pip) and the centre pip starts at 0.49h, so the two clear each other by
  // 0.04h — 1.8dp on the smallest face in the app (h=46) and 4.2dp at h=104,
  // before the margin the drawn glyphs carry inside their own boxes. Cards are
  // never tappable, so no touch target depends on any of this.
  static const double _radius = 0.055;
  static const double _indexLeft = 0.065;
  static const double _indexTop = 0.055;
  static const double _indexWidth = 0.20;
  static const double _rankHeight = 0.26;
  static const double _indexGap = 0.015;
  static const double _indexPip = 0.12;
  static const double _centrePipTop = 0.49;
  static const double _centrePip = 0.34;

  /// Out of play, not half-erased: the colour drains and the card sits back
  /// rather than fading toward the felt. One filter, so it costs one layer.
  static const ColorFilter _drained = ColorFilter.matrix(<double>[
    0.40975, 0.53625, 0.054, 0, 0, //
    0.15975, 0.78625, 0.054, 0, 0, //
    0.15975, 0.53625, 0.304, 0, 0, //
    0, 0, 0, 0.55, 0, //
  ]);

  @override
  State<PlayingCard> createState() => _PlayingCardState();

  static String rankOf(String code) {
    final r = code.substring(0, code.length - 1).toUpperCase();
    return r == 'T' ? '10' : r;
  }

  static String suitOf(String code) =>
      code.substring(code.length - 1).toLowerCase();

  static String suitSymbol(String suit) => switch (suit) {
        's' => '♠',
        'h' => '♥',
        'd' => '♦',
        'c' => '♣',
        _ => '?',
      };

  /// Red suits and black suits, from a suit letter.
  static Color inkFor(String suit) =>
      suit == 'h' || suit == 'd' ? AppTheme.pipRed : AppTheme.pipBlack;
}

class _PlayingCardState extends State<PlayingCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: Motion.enter,
    value: widget.code == null ? 0 : 1,
  );

  @override
  void didUpdateWidget(covariant PlayingCard old) {
    super.didUpdateWidget(old);
    final wasFaceUp = old.code != null;
    final isFaceUp = widget.code != null;
    if (wasFaceUp == isFaceUp) return;

    // Turned over, so play it rather than swapping the picture.
    isFaceUp ? _flip.forward() : _flip.reverse();
  }

  @override
  void dispose() {
    _flip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;

    Widget card = AnimatedBuilder(
      animation: _flip,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_flip.value);
        final angle = t * math.pi;
        final showingFace = t > 0.5;
        // Edge-on, the card has no width to draw; the specular band peaks
        // exactly where the geometry vanishes so it never blinks out.
        final sheen = (1 - math.cos(angle).abs()) * 0.5;
        // And it lifts off the felt on the way over rather than pivoting flat.
        final lift = 1 + 0.6 * math.sin(angle);

        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015) // a little perspective, so it has depth
            ..rotateY(angle),
          child: showingFace
              // The face would be mirrored halfway through the turn, so it is
              // flipped back the other way.
              ? Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()..rotateY(math.pi),
                  child: _face(sheen, lift),
                )
              : _back(sheen, lift),
        );
      },
    );

    if (widget.dimmed) {
      card = Transform.scale(
        scale: 0.97,
        child: ColorFiltered(colorFilter: PlayingCard._drained, child: card),
      );
    }

    // The felt behind a card animates continuously; the card does not. One
    // boundary each keeps up to fifteen of them out of every ambient frame.
    return RepaintBoundary(
      child: SizedBox(
        width: h * PlayingCard.aspect,
        height: h,
        child: card,
      ),
    );
  }

  /// The card lies on the felt: one tight contact shadow and one soft one.
  /// A dimmed card drops both — it is out of the hand, so it stops casting.
  List<BoxShadow> _shadows(double h, double lift) {
    if (widget.dimmed) return const <BoxShadow>[];
    return <BoxShadow>[
      BoxShadow(
        color: AppTheme.ink900.withValues(alpha: 0.42),
        blurRadius: h * 0.045 * lift,
        offset: Offset(0, h * 0.020),
      ),
      BoxShadow(
        color: AppTheme.ink900.withValues(alpha: 0.18),
        blurRadius: h * 0.11 * lift,
        offset: Offset(0, h * 0.05),
      ),
    ];
  }

  /// The band that crosses the card as it turns. Absent at rest, so a resting
  /// card is a plain decoration and nothing more.
  Widget? _sheen(double alpha) {
    if (alpha < 0.004) return null;
    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: <Color>[
                Colors.transparent,
                AppTheme.goldBright.withValues(alpha: alpha),
                Colors.transparent,
              ],
              stops: const <double>[0.12, 0.5, 0.88],
            ),
          ),
        ),
      ),
    );
  }

  Widget _back(double sheen, double lift) {
    final h = widget.height;
    final radius = BorderRadius.circular(h * PlayingCard._radius);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: _shadows(h, lift),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: <Widget>[
            SvgPicture.asset(
              'assets/card_back.svg',
              fit: BoxFit.fill,
              width: h * PlayingCard.aspect,
              height: h,
            ),
            ?_sheen(sheen),
          ],
        ),
      ),
    );
  }

  Widget _face(double sheen, double lift) {
    final code = widget.code;
    if (code == null) return const SizedBox.shrink();

    final h = widget.height;
    final suit = PlayingCard.suitOf(code);
    final ink = PlayingCard.inkFor(suit);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardFace,
        borderRadius: BorderRadius.circular(h * PlayingCard._radius),
        // The cut edge of the stock, which is what stops a pale card from
        // dissolving into a pale seat pod behind it.
        border: Border.all(color: AppTheme.cardEdge, width: 0.5),
        boxShadow: _shadows(h, lift),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(h * PlayingCard._radius),
        child: Stack(
          children: <Widget>[
            Positioned(
              left: h * PlayingCard._indexLeft,
              top: h * PlayingCard._indexTop,
              width: h * PlayingCard._indexWidth,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  CardRankGlyph(
                    rank: PlayingCard.rankOf(code),
                    height: h * PlayingCard._rankHeight,
                    colour: ink,
                  ),
                  SizedBox(height: h * PlayingCard._indexGap),
                  CardPips(
                    suit: suit,
                    size: h * PlayingCard._indexPip,
                    colour: ink,
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: h * PlayingCard._centrePipTop,
              height: h * PlayingCard._centrePip,
              child: Center(
                child: CardPips(
                  suit: suit,
                  size: h * PlayingCard._centrePip,
                  colour: ink,
                ),
              ),
            ),
            ?_sheen(sheen),
          ],
        ),
      ),
    );
  }
}

/// One suit mark, drawn rather than typed.
///
/// The Unicode pips render differently on every device and go thin at pod size;
/// these are four fixed silhouettes with the same weight everywhere. An unknown
/// suit still falls back to [PlayingCard.suitSymbol]'s '?', because a protocol
/// break must never render as a plausible wrong card.
class CardPips extends StatelessWidget {
  const CardPips({
    super.key,
    required this.suit,
    required this.size,
    required this.colour,
  });

  /// A suit letter as [PlayingCard.suitOf] returns it.
  final String suit;
  final double size;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final path = _pipPaths[suit];
    if (path == null) {
      return SizedBox(
        width: size,
        height: size,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            PlayingCard.suitSymbol(suit),
            style: TextStyle(color: colour, height: 1),
          ),
        ),
      );
    }
    return CustomPaint(
      size: Size.square(size),
      painter: _PipPainter(path: path, colour: colour),
    );
  }
}

/// The rank index, drawn on the same grid as the pips.
///
/// Ranks are ASCII the server owns ("A", "2".."9", "10", "J", "Q", "K"), so
/// drawing them is safe in a way that drawing a display name never would be.
/// Anything else falls through to text, for the same reason the '?' pip does.
class CardRankGlyph extends StatelessWidget {
  const CardRankGlyph({
    super.key,
    required this.rank,
    required this.height,
    required this.colour,
  });

  /// A rank as [PlayingCard.rankOf] returns it.
  final String rank;
  final double height;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    final glyph = _rankGlyph(rank);
    if (glyph == null) {
      return SizedBox(
        height: height,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            rank,
            style: TextStyle(
              color: colour,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ),
      );
    }
    return CustomPaint(
      size: Size(height * glyph.width / _glyphBox, height),
      painter: _RankPainter(glyph: glyph, colour: colour),
    );
  }
}

class _PipPainter extends CustomPainter {
  const _PipPainter({required this.path, required this.colour});

  final Path path;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / _glyphBox, size.height / _glyphBox);
    canvas.drawPath(path, Paint()..color = colour);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PipPainter old) =>
      old.path != path || old.colour != colour;
}

class _RankPainter extends CustomPainter {
  const _RankPainter({required this.glyph, required this.colour});

  final _Glyph glyph;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    // Fit by height, then by width, which is the '10' case and the only one
    // that is ever wider than its box.
    final scale = math.min(
      size.height / _glyphBox,
      size.width / glyph.width,
    );
    canvas.save();
    canvas.translate(
      (size.width - glyph.width * scale) / 2,
      (size.height - _glyphBox * scale) / 2,
    );
    canvas.scale(scale);
    canvas.drawPath(
      glyph.path,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = _glyphStroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RankPainter old) =>
      old.glyph != glyph || old.colour != colour;
}

/// A drawn glyph and the advance width it needs, on the [_glyphBox] grid.
class _Glyph {
  const _Glyph(this.path, this.width);
  final Path path;
  final double width;
}

/// Everything below is drawn on a 100-tall grid and scaled at paint time, so
/// the stroke weight stays in proportion at every card size.
const double _glyphBox = 100;
const double _glyphStroke = 17;

/// A monoline engraved index: the strokes are round-ended and the shapes carry
/// the deck's own quirks (a closed 4, a barred J, a crossed Q) so the rank
/// reads as printed on a card rather than set in the interface's typeface.
final Map<String, _Glyph> _rankGlyphs = <String, _Glyph>{
  'A': _Glyph(
    Path()
      ..moveTo(9, 91)
      ..lineTo(32, 9)
      ..lineTo(55, 91)
      ..moveTo(17, 64)
      ..lineTo(47, 64),
    64,
  ),
  '2': _Glyph(
    Path()
      ..moveTo(10, 28)
      ..cubicTo(10, 9, 49, 7, 49, 31)
      ..cubicTo(49, 47, 30, 60, 10, 91)
      ..lineTo(50, 91),
    58,
  ),
  '3': _Glyph(
    Path()
      ..moveTo(11, 22)
      ..cubicTo(23, 7, 48, 10, 48, 28)
      ..cubicTo(48, 41, 36, 47, 28, 47)
      ..cubicTo(39, 47, 50, 53, 50, 69)
      ..cubicTo(50, 89, 21, 96, 11, 84),
    58,
  ),
  '4': _Glyph(
    Path()
      ..moveTo(40, 9)
      ..lineTo(9, 66)
      ..lineTo(53, 66)
      ..moveTo(40, 9)
      ..lineTo(40, 91),
    62,
  ),
  '5': _Glyph(
    Path()
      ..moveTo(48, 10)
      ..lineTo(14, 10)
      ..lineTo(11, 45)
      ..cubicTo(25, 38, 48, 42, 48, 66)
      ..cubicTo(48, 88, 22, 95, 10, 85),
    57,
  ),
  '6': _Glyph(_six(), 61),
  '7': _Glyph(
    Path()
      ..moveTo(10, 11)
      ..lineTo(48, 11)
      ..lineTo(23, 91),
    56,
  ),
  '8': _Glyph(
    Path()
      ..addOval(const Rect.fromLTWH(14, 9, 30, 34))
      ..addOval(const Rect.fromLTWH(9, 45, 40, 46)),
    58,
  ),
  '9': _Glyph(_six().transform(_halfTurn(61 / 2, 50)), 61),
  '10': _ten(),
  'J': _Glyph(
    Path()
      ..moveTo(12, 12)
      ..lineTo(44, 12)
      ..moveTo(31, 12)
      ..lineTo(31, 72)
      ..cubicTo(31, 89, 21, 95, 12, 89),
    53,
  ),
  'Q': _Glyph(
    Path()
      ..addOval(const Rect.fromLTWH(9, 9, 46, 72))
      ..moveTo(40, 64)
      ..lineTo(56, 90),
    65,
  ),
  'K': _Glyph(
    Path()
      ..moveTo(11, 9)
      ..lineTo(11, 91)
      ..moveTo(51, 9)
      ..lineTo(18, 51)
      ..moveTo(25, 44)
      ..lineTo(52, 91),
    61,
  ),
};

_Glyph? _rankGlyph(String rank) => _rankGlyphs[rank];

Path _six() => Path()
  ..moveTo(46, 12)
  ..cubicTo(28, 5, 11, 22, 11, 56)
  ..cubicTo(11, 82, 24, 92, 33, 92)
  ..cubicTo(46, 92, 52, 82, 52, 68)
  ..cubicTo(52, 54, 42, 46, 31, 46)
  ..cubicTo(21, 46, 14, 52, 11, 60);

/// A half turn about a point, which is all a 9 is. Written out rather than
/// built from a Matrix4 so nothing here depends on a deprecated translate.
Float64List _halfTurn(double cx, double cy) => Float64List.fromList(<double>[
      -1, 0, 0, 0, //
      0, -1, 0, 0, //
      0, 0, 1, 0, //
      2 * cx, 2 * cy, 0, 1, //
    ]);

/// Ten is the one two-glyph rank; the painter fits it by width instead of
/// height, which is what the old FittedBox(scaleDown) did for the '10' text.
_Glyph _ten() {
  const gap = 10.0;
  final one = Path()
    ..moveTo(10, 26)
    ..lineTo(21, 12)
    ..lineTo(21, 91);
  final zero = Path()..addOval(const Rect.fromLTWH(9, 9, 40, 82));
  final path = Path()
    ..addPath(one, Offset.zero)
    ..addPath(zero, const Offset(31 + gap, 0));
  return _Glyph(path, 31 + gap + 58);
}

/// Four silhouettes on the same 100-grid, each sized so its ink fills the box.
final Map<String, Path> _pipPaths = <String, Path>{
  's': Path()
    ..moveTo(50, 7)
    ..cubicTo(44, 24, 20, 38, 15, 54)
    ..cubicTo(10, 70, 21, 82, 34, 82)
    ..cubicTo(41, 82, 46, 78, 49, 73)
    ..cubicTo(48, 83, 44, 91, 35, 96)
    ..lineTo(65, 96)
    ..cubicTo(56, 91, 52, 83, 51, 73)
    ..cubicTo(54, 78, 59, 82, 66, 82)
    ..cubicTo(79, 82, 90, 70, 85, 54)
    ..cubicTo(80, 38, 56, 24, 50, 7)
    ..close(),
  'h': Path()
    ..moveTo(50, 93)
    ..cubicTo(27, 75, 9, 60, 9, 39)
    ..cubicTo(9, 23, 21, 13, 33, 13)
    ..cubicTo(42, 13, 48, 18, 50, 25)
    ..cubicTo(52, 18, 58, 13, 67, 13)
    ..cubicTo(79, 13, 91, 23, 91, 39)
    ..cubicTo(91, 60, 73, 75, 50, 93)
    ..close(),
  'd': Path()
    ..moveTo(50, 5)
    ..cubicTo(61, 23, 75, 38, 88, 50)
    ..cubicTo(75, 62, 61, 77, 50, 95)
    ..cubicTo(39, 77, 25, 62, 12, 50)
    ..cubicTo(25, 38, 39, 23, 50, 5)
    ..close(),
  'c': _club(),
};

/// The club is three lobes and a stem welded into one silhouette, so it paints
/// as a single filled shape with no seams where the lobes meet.
Path _club() {
  final stem = Path()
    ..moveTo(44, 58)
    ..cubicTo(45, 76, 41, 89, 32, 96)
    ..lineTo(68, 96)
    ..cubicTo(59, 89, 55, 76, 56, 58)
    ..close();
  var path = stem;
  for (final lobe in const <(double, double, double)>[
    (50, 30, 21),
    (26, 60, 20),
    (74, 60, 20),
  ]) {
    path = Path.combine(
      PathOperation.union,
      path,
      Path()
        ..addOval(
          Rect.fromCircle(center: Offset(lobe.$1, lobe.$2), radius: lobe.$3),
        ),
    );
  }
  return path;
}
