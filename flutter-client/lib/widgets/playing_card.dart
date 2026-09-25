import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_theme.dart';

/// A playing card, face up or face down.
///
/// Cards keep one aspect ratio everywhere — the player's own hand and every
/// opponent's — so a card means the same thing wherever it appears. Turning one
/// over animates: the card lifts, rotates on its long axis and the face appears
/// at the halfway point, which is what a real card does and what makes "see"
/// feel like an action rather than a repaint.
///
/// **The face is printed stock** (premium-card brief, 25 Sep 2026: "a physical
/// premium playing card", not "Flutter UI with card widgets"). Warm ivory,
/// lighter where the table's lamp falls and a shade deeper in the far corner;
/// a thin cut edge in a restrained warm gold ([AppTheme.cardRim]) that faces
/// and backs share; the faintest highlight along the top edge; two soft
/// shadows, one tight under the card and one wider, so it lies a little above
/// the cloth. All of it is one painter ([CardFaceMetrics] holds the layout),
/// under the card's own repaint boundary, so a face costs one picture however
/// much is printed on it.
///
/// **The rank leads, the suit follows** (the brief: "RANK > SUIT > secondary
/// card details"). The rank is set in the app's own face, Inter, at its
/// heaviest weight, and fitted to a cap height — never by its line box — so a
/// 5 and a Q stand exactly as tall; a 10 is condensed rather than shrunk, as a
/// printed deck's is. The suit under it and in the middle is PAINTED
/// ([CardPips]): Inter has no suit glyphs and a phone would draw them from its
/// colour emoji font, which ignores the ink. Red is hearts and diamonds, black
/// spades and clubs, and nothing else.
///
/// **Small faces drop detail, never the rank.** Below [compactBelow] (a rim
/// seat's cards) the face is COMPACT: a larger share of its height goes to the
/// rank and the corner pip, and the court frame, the highlight and the pip's
/// shading are left out.
class PlayingCard extends StatefulWidget {
  const PlayingCard({
    super.key,
    this.code,
    this.height = 96,
    this.dimmed = false,
    this.tint,
    this.indexOnRight = false,
    this.flipDelay = Duration.zero,
  });

  /// A server card code such as "As" or "Td". Null means face down.
  final String? code;
  final double height;

  /// Packed players' cards are dimmed rather than removed, so the seat still
  /// reads as "was in this hand".
  final bool dimmed;

  /// Recolours the BACK, leaving the artwork's own light and shade alone.
  ///
  /// [BlendMode.color] takes the hue and saturation from this and the
  /// luminosity from the printed back, so the crown and the bevel survive the
  /// change — a flat fill would paint over both. A face is never tinted: a
  /// card that is showing has already answered the question this asks. The
  /// stock's gold edge is not printing and is not tinted either.
  final Color? tint;

  /// Prints the index in the top-RIGHT corner instead of the top-left —
  /// the corner a left-hander's deck prints it in, for a card whose left side
  /// is covered. The viewer's own fan has its middle card on top, so a card
  /// to the right of it shows only its right-hand side; with its index in the
  /// top-left its rank would be under the middle card (premium-card brief,
  /// 25 Sep 2026: "Do not hide rank/suit information"). One index a card,
  /// never two: a second would peek out in pieces from under its neighbour.
  final bool indexOnRight;

  /// How long the card waits before it turns over once told to — how a hand
  /// is turned one card after another rather than all at once.
  final Duration flipDelay;

  /// The card-back artwork's own ratio, which is the standard poker 5:7
  /// (2.5 x 3.5 in): wide enough for a rank, its pip and the centre pip.
  static const double aspect = 240 / 336;

  /// The stock's corner radius, as a share of the card's height: a real
  /// card's rounded corner, not a button's.
  static const double cornerShare = 0.058;

  /// Faces shorter than this are drawn COMPACT (see the class doc): a rim
  /// seat's cards, 38 to 46dp on the phones the table is laid out for, and the
  /// rules sheet's examples.
  static const double compactBelow = 56;

  /// How far apart the cards of one hand turn over (see [flipDelay]): a hand
  /// of five has turned in 0.62 s, inside the pause before its best three are
  /// set out (table_screen's `_BestThreeStage.beforeAside`, 650 ms).
  static const Duration flipStagger = Duration(milliseconds: 50);

  /// How long a turn takes, from back to face.
  static const Duration flipFor = Motion.enter;

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

  /// Whether a rank is a court card, which the face frames.
  static bool isCourt(String rank) => rank == 'J' || rank == 'Q' || rank == 'K';

  /// The two soft shadows a card casts on the table, [lift] times further off
  /// it than at rest (a card turning over, or in the air). None for a dimmed
  /// card, which is out of the hand and lies flat.
  static List<BoxShadow> shadows(
    double height,
    Brightness brightness, {
    double lift = 1,
  }) {
    final dark = brightness == Brightness.dark;
    final ink = AppTheme.shadowFor(brightness);
    return <BoxShadow>[
      // Contact: small, tight and directly underneath.
      BoxShadow(
        color: ink.withValues(alpha: dark ? 0.46 : 0.24),
        blurRadius: height * 0.018 * lift,
        offset: Offset(0, height * 0.010 * lift),
      ),
      // Depth: wider and softer, so the card stands off the cloth.
      BoxShadow(
        color: ink.withValues(alpha: dark ? 0.26 : 0.14),
        blurRadius: height * 0.085 * lift,
        offset: Offset(0, height * 0.040 * lift),
      ),
    ];
  }
}

class _PlayingCardState extends State<PlayingCard>
    with SingleTickerProviderStateMixin {
  // Read by every build (the AnimatedBuilder below), so never first touched
  // in dispose() (CLAUDE.md §12.3).
  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: PlayingCard.flipFor,
    value: widget.code == null ? 0 : 1,
  );
  Timer? _wait;

  /// The last face shown, kept while the card turns back over so the face's
  /// half of the turn is not blank.
  String? _face;

  @override
  void initState() {
    super.initState();
    _face = widget.code;
  }

  @override
  void didUpdateWidget(covariant PlayingCard old) {
    super.didUpdateWidget(old);
    if (widget.code != null) _face = widget.code;
    final wasFaceUp = old.code != null;
    final isFaceUp = widget.code != null;
    if (wasFaceUp == isFaceUp) return;

    // Turned over, so play it rather than swapping the picture — after the
    // card's own beat in a hand being turned one card at a time.
    _wait?.cancel();
    void turn() => isFaceUp ? _flip.forward() : _flip.reverse();
    if (widget.flipDelay <= Duration.zero) {
      turn();
    } else {
      _wait = Timer(widget.flipDelay, () {
        if (mounted) turn();
      });
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _flip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    final w = h * PlayingCard.aspect;
    final brightness = Theme.of(context).brightness;
    final radius = BorderRadius.circular(h * PlayingCard.cornerShare);
    final faceCode = _face;

    // Both sides are built once per build of the card and handed to the
    // turn, which only moves them: nothing on either is laid out per frame.
    final face = faceCode == null
        ? null
        : RepaintBoundary(
            child: CustomPaint(
              size: Size(w, h),
              painter: CardFacePainter(
                code: faceCode,
                height: h,
                indexOnRight: widget.indexOnRight,
              ),
            ),
          );
    final back = _CardBack(height: h, tint: widget.tint);

    Widget card = AnimatedBuilder(
      animation: _flip,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_flip.value);
        final angle = t * math.pi;
        final showingFace = t > 0.5 && face != null;
        final rising = math.sin(angle);
        // Edge-on, the card has no width to draw; the light band peaks
        // exactly where the geometry vanishes so it never blinks out.
        final sheen = (1 - math.cos(angle).abs()) * 0.5;
        // It lifts off the felt on the way over rather than pivoting flat:
        // a little larger, a little higher, its shadow further below it.
        final lift = 1 + 0.9 * rising;

        final side = DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: widget.dimmed
                ? const <BoxShadow>[]
                : PlayingCard.shadows(h, brightness, lift: lift),
          ),
          child: Stack(
            children: <Widget>[
              showingFace
                  // The face would be mirrored halfway through the turn, so
                  // it is flipped back the other way.
                  ? Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()..rotateY(math.pi),
                      child: face,
                    )
                  : back,
              ?_sheen(sheen, radius),
            ],
          ),
        );

        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015) // a little perspective, so it has depth
            ..translateByDouble(0, -h * 0.05 * rising, 0, 1)
            ..scaleByDouble(1 + 0.05 * rising, 1 + 0.05 * rising, 1, 1)
            ..rotateY(angle),
          child: side,
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
      child: SizedBox(width: w, height: h, child: card),
    );
  }

  /// The band of light that crosses the card as it turns. Absent at rest, so
  /// a resting card is its stock and nothing more.
  Widget? _sheen(double alpha, BorderRadius radius) {
    if (alpha < 0.004) return null;
    return Positioned.fill(
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: <Color>[
                Colors.transparent,
                const Color(0xFFFFF6DC).withValues(alpha: alpha * 0.9),
                Colors.transparent,
              ],
              stops: const <double>[0.14, 0.5, 0.86],
            ),
          ),
        ),
      ),
    );
  }
}

/// The printed back — the King Teen Patti crown on its lattice — on the same
/// stock as the face: cut to the card's corner, with the stock's gold edge and
/// its top-edge light laid over it. [tint] recolours the printing only.
class _CardBack extends StatelessWidget {
  const _CardBack({required this.height, this.tint});

  final double height;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final h = height;
    final w = h * PlayingCard.aspect;
    return CustomPaint(
      foregroundPainter: CardStockPainter(height: h, face: false),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(h * PlayingCard.cornerShare),
        child: SvgPicture.asset(
          'assets/card_back.svg',
          fit: BoxFit.fill,
          width: w,
          height: h,
          colorFilter: tint == null
              ? null
              : ColorFilter.mode(tint!, BlendMode.color),
        ),
      ),
    );
  }
}

/// Where everything on a face goes, as a function of the card's height alone
/// — the one set of numbers the face painter draws by and the tests measure.
@immutable
class CardFaceMetrics {
  const CardFaceMetrics._({
    required this.height,
    required this.compact,
    required this.inset,
    required this.top,
    required this.rankCap,
    required this.indexWidth,
    required this.gap,
    required this.indexPip,
    required this.centrePip,
    required this.centreY,
    required this.acePip,
    required this.aceY,
  });

  factory CardFaceMetrics.of(double height) {
    final h = height;
    if (h < PlayingCard.compactBelow) {
      // Compact: a rim seat's card, 38dp tall on a 640x360 phone. A quarter of
      // the card is rank.
      return CardFaceMetrics._(
        height: h,
        compact: true,
        inset: h * 0.058,
        top: h * 0.07,
        rankCap: h * 0.25,
        indexWidth: h * 0.28,
        gap: h * 0.028,
        indexPip: h * 0.135,
        centrePip: h * 0.36,
        centreY: h * 0.70,
        acePip: h * 0.40,
        aceY: h * 0.695,
      );
    }
    return CardFaceMetrics._(
      height: h,
      compact: false,
      inset: h * 0.055,
      top: h * 0.06,
      rankCap: h * 0.21,
      indexWidth: h * 0.235,
      gap: h * 0.024,
      indexPip: h * 0.115,
      centrePip: h * 0.34,
      centreY: h * 0.665,
      acePip: h * 0.44,
      aceY: h * 0.645,
    );
  }

  final double height;
  double get width => height * PlayingCard.aspect;

  /// Whether the face is drawn compact (see [PlayingCard.compactBelow]).
  final bool compact;

  /// The index column's distance from the card's side, and the rank's cap
  /// from its top.
  final double inset;
  final double top;

  /// The rank's cap height: every rank, a 5 and a Q alike, stands this tall.
  final double rankCap;

  /// The column the rank and its pip are centred in; a rank wider than it (a
  /// 10) is condensed to it.
  final double indexWidth;

  /// Between the rank's baseline and the pip under it, and that pip's size.
  final double gap;
  final double indexPip;

  /// The pip in the middle of a number card or a court card's frame, and the
  /// larger one an ace carries, each with the height its centre stands at.
  final double centrePip;
  final double centreY;
  final double acePip;
  final double aceY;

  /// The index column: rank over pip, in the top-left corner, or mirrored
  /// into the top-right ([PlayingCard.indexOnRight]).
  Rect index({bool right = false}) {
    final h = rankCap + gap + indexPip;
    return Rect.fromLTWH(
      right ? width - inset - indexWidth : inset,
      top,
      indexWidth,
      h,
    );
  }

  /// A court card's frame: the window its centre pip stands in, below the
  /// indices on either side. Full faces only.
  Rect get courtFrame => Rect.fromLTRB(
    width * 0.15,
    height * 0.45,
    width * 0.85,
    height * 0.93,
  );

  /// How thick the stock's gold edge is drawn.
  double get rimWidth => (height * 0.010).clamp(0.7, 1.1).toDouble();
}

/// Inter's cap height, as a share of its size. The rank is fitted to a cap
/// height, not to a line box, so that its top is where the metrics say.
const double _interCapShare = 0.727;

/// The heaviest a rank is ever condensed across before it is made smaller.
const double _rankMinCondense = 0.8;

/// How a rank is set: the size, how far it is condensed across and how wide
/// it then stands, for a face [height] tall — the painter's own sums, public
/// so that a test can hold a 10 to its column.
({double fontSize, double condense, double width, double shrink}) cardRankFit(
  String rank,
  double height,
) {
  final m = CardFaceMetrics.of(height);
  final painter = _rankPainter(rank, m.rankCap / _interCapShare, AppTheme.pipBlack);
  final natural = painter.width;
  painter.dispose();
  var condense = natural <= m.indexWidth ? 1.0 : m.indexWidth / natural;
  var shrink = 1.0;
  if (condense < _rankMinCondense) {
    shrink = condense / _rankMinCondense;
    condense = _rankMinCondense;
  }
  return (
    fontSize: m.rankCap / _interCapShare * shrink,
    condense: condense,
    width: natural * condense * shrink,
    shrink: shrink,
  );
}

TextPainter _rankPainter(String rank, double fontSize, Color ink) =>
    TextPainter(
      text: TextSpan(
        text: rank,
        style: TextStyle(
          fontFamily: AppTheme.fontFamily,
          fontWeight: FontWeight.w700,
          fontSize: fontSize,
          // Two figures sit close, as a printed 10's do.
          letterSpacing: rank.length > 1 ? -0.05 * fontSize : 0,
          color: ink,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();

/// The printed face of [code], [height] tall (see [PlayingCard]).
class CardFacePainter extends CustomPainter {
  const CardFacePainter({
    required this.code,
    required this.height,
    this.indexOnRight = false,
  });

  final String code;
  final double height;
  final bool indexOnRight;

  @override
  void paint(Canvas canvas, Size size) {
    final m = CardFaceMetrics.of(height);
    final rect = Offset.zero & size;
    final card = RRect.fromRectAndRadius(
      rect,
      Radius.circular(height * PlayingCard.cornerShare),
    );
    final suit = PlayingCard.suitOf(code);
    final rank = PlayingCard.rankOf(code);
    final ink = PlayingCard.inkFor(suit);

    // The stock: warm ivory, lit from its upper-left corner.
    canvas.drawRRect(
      card,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[AppTheme.cardFaceHigh, AppTheme.cardFaceLow],
        ).createShader(rect),
    );

    canvas
      ..save()
      ..clipRRect(card);

    // A court card's window, below the indices, as a printed court card has:
    // a thin gold rule and a fainter one just inside it. Full faces only.
    final court = PlayingCard.isCourt(rank) && !m.compact;
    if (court) {
      final rule = math.max(0.7, height * 0.008);
      final frame = RRect.fromRectAndRadius(
        m.courtFrame,
        Radius.circular(height * 0.025),
      );
      canvas
        ..drawRRect(
          frame,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = rule
            ..color = AppTheme.cardRim.withValues(alpha: 0.85),
        )
        ..drawRRect(
          frame.deflate(height * 0.018),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = rule * 0.7
            ..color = AppTheme.cardRim.withValues(alpha: 0.38),
        );
    }

    // The index, in the corner that shows.
    _paintIndex(canvas, m, m.index(right: indexOnRight), rank, suit, ink);

    // The centre pip: larger on an ace, inside the frame on a court card.
    final ace = rank == 'A';
    final pipSize = court
        ? m.courtFrame.height * 0.6
        : ace
        ? m.acePip
        : m.centrePip;
    final pipCentre = Offset(
      size.width / 2,
      court
          ? m.courtFrame.center.dy
          : ace
          ? m.aceY
          : m.centreY,
    );
    paintPip(
      canvas,
      suit,
      Rect.fromCenter(center: pipCentre, width: pipSize, height: pipSize),
      ink,
      shaded: !m.compact,
    );

    // The light along the top edge, where the stock catches the lamp.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, height * 0.2),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.white.withValues(alpha: m.compact ? 0.35 : 0.55),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(0, 0, size.width, height * 0.2)),
    );
    canvas.restore();

    CardStockPainter.paintEdge(canvas, card, height, face: true);
  }

  static void _paintIndex(
    Canvas canvas,
    CardFaceMetrics m,
    Rect column,
    String rank,
    String suit,
    Color ink,
  ) {
    final fit = cardRankFit(rank, m.height);
    final painter = _rankPainter(rank, fit.fontSize, ink);
    final baseline = painter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    // The cap top on the column's top, or — a rank that had to be made
    // smaller — its cap centred in the rank's own band.
    final cap = m.rankCap * fit.shrink;
    final capTop = column.top + (m.rankCap - cap) / 2;
    canvas
      ..save()
      ..translate(column.center.dx, capTop + cap - baseline)
      ..scale(fit.condense, 1);
    painter.paint(canvas, Offset(-painter.width / 2, 0));
    canvas.restore();
    painter.dispose();

    paintPip(
      canvas,
      suit,
      Rect.fromCenter(
        center: Offset(
          column.center.dx,
          column.top + m.rankCap + m.gap + m.indexPip / 2,
        ),
        width: m.indexPip,
        height: m.indexPip,
      ),
      ink,
    );
  }

  @override
  bool shouldRepaint(CardFacePainter old) =>
      old.code != code ||
      old.height != height ||
      old.indexOnRight != indexOnRight;
}

/// The stock's own finish, laid over a back (and drawn by the face painter
/// for a face): the gold cut edge, and on a back a faint light along its top.
class CardStockPainter extends CustomPainter {
  const CardStockPainter({required this.height, required this.face});

  final double height;
  final bool face;

  /// The cut edge round [card], and inside it on a full-size card the thin
  /// highlight a printed card's lacquer catches along its top.
  static void paintEdge(
    Canvas canvas,
    RRect card,
    double height, {
    required bool face,
  }) {
    final m = CardFaceMetrics.of(height);
    final rim = m.rimWidth;
    canvas.drawRRect(
      card.deflate(rim / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = rim
        ..color = face
            ? AppTheme.cardRim
            : AppTheme.cardRim.withValues(alpha: 0.85),
    );
    if (m.compact) return;
    final inner = card.deflate(rim + 0.6);
    canvas.drawRRect(
      inner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.white.withValues(alpha: face ? 0.9 : 0.22),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const <double>[0, 0.45],
        ).createShader(inner.outerRect),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final card = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(height * PlayingCard.cornerShare),
    );
    if (!face) {
      // The lacquer on a back: a faint light across its top.
      canvas
        ..save()
        ..clipRRect(card)
        ..drawRect(
          Rect.fromLTWH(0, 0, size.width, height * 0.22),
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.white.withValues(alpha: 0.12),
                Colors.white.withValues(alpha: 0),
              ],
            ).createShader(Rect.fromLTWH(0, 0, size.width, height * 0.22)),
        )
        ..restore();
    }
    paintEdge(canvas, card, height, face: face);
  }

  @override
  bool shouldRepaint(CardStockPainter old) =>
      old.height != height || old.face != face;
}

/// Paints the [suit]'s silhouette filling [box] in [ink] — [shaded], a shade
/// lighter at its top than at its foot, as a pip printed in heavy ink reads
/// under a lamp. An unknown suit paints nothing: [CardPips] owns the '?'.
void paintPip(
  Canvas canvas,
  String suit,
  Rect box,
  Color ink, {
  bool shaded = false,
}) {
  final path = _pipPaths[suit];
  if (path == null) {
    final painter = TextPainter(
      text: TextSpan(
        text: PlayingCard.suitSymbol(suit),
        style: TextStyle(color: ink, fontSize: box.height * 0.9, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      box.center - Offset(painter.width / 2, painter.height / 2),
    );
    painter.dispose();
    return;
  }
  final paint = Paint()..color = ink;
  if (shaded) {
    final light = Color.lerp(ink, Colors.white, 0.16)!;
    final deep = Color.lerp(ink, Colors.black, 0.10)!;
    paint.shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: <Color>[light, deep],
    ).createShader(box);
  }
  canvas
    ..save()
    ..translate(box.left, box.top)
    ..scale(box.width / _glyphBox, box.height / _glyphBox)
    ..drawPath(path, paint)
    ..restore();
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
      painter: _PipPainter(suit: suit, colour: colour),
    );
  }
}

/// A suit on a miniature card face, for the places a suit is NAMED in a line
/// of text rather than printed on a card — the table's tag over the pot,
/// "Variation · Hukam · ♣".
///
/// Painted, never typed (owner, 24 Sep 2026: "in Variation Game play when
/// user selects Hukam, then the icon on top is not visible properly"). The tag
/// used to end in a bare '♣' set in the label's gold, and Inter has no such
/// glyph: Android drew it from the colour emoji font, which ignores the text
/// colour — a black club on the tag's dark pill, invisible, and a red emoji
/// heart for hearts. A pale rounded square with the [CardPips] silhouette in
/// the suit's own ink keeps the suit's colour — red hearts and diamonds, black
/// spades and clubs — on any ground in either theme, and reads as the card it
/// names.
class SuitMark extends StatelessWidget {
  const SuitMark({super.key, required this.suit, required this.size});

  /// A suit letter as [PlayingCard.suitOf] returns it.
  final String suit;

  /// The side of the square, which the pip fills [pipShare] of.
  final double size;

  /// How much of the face the pip takes: a card's own corner pip, with a
  /// margin of face around it, not a poster.
  static const double pipShare = 0.72;

  /// The face, a little short of opaque so the pill's edge still shows
  /// through where the two meet.
  static const double faceAlpha = 0.92;

  @override
  Widget build(BuildContext context) => Semantics(
    // What a screen reader said when this was a glyph.
    label: PlayingCard.suitSymbol(suit),
    child: Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.cardFace.withValues(alpha: faceAlpha),
        borderRadius: BorderRadius.circular(size * 0.22),
      ),
      child: CardPips(
        suit: suit,
        size: size * pipShare,
        colour: PlayingCard.inkFor(suit),
      ),
    ),
  );
}

class _PipPainter extends CustomPainter {
  const _PipPainter({required this.suit, required this.colour});

  final String suit;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) =>
      paintPip(canvas, suit, Offset.zero & size, colour);

  @override
  bool shouldRepaint(_PipPainter old) =>
      old.suit != suit || old.colour != colour;
}

/// Everything below is drawn on a 100-square grid and scaled at paint time.
const double _glyphBox = 100;

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
