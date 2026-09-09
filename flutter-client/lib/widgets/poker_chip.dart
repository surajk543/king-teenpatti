import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The six inserts that make a disc read as a chip. [PokerChip.dashes] stays
/// public so a caller can tune one chip; the piles and the spin take it as it
/// stands.
const int _defaultDashes = 6;

/// A poker chip, drawn rather than iconified.
///
/// Material has nothing that reads as a casino chip — the coin and savings
/// glyphs both say "money" but not "table stakes" — and this is small enough
/// to be worth painting: a ring, a face, and the edge dashes that make a chip
/// recognisable at 20 pixels.
///
/// It is moulded clay, not glass: a body lit from the upper left, six edge
/// inserts, a recessed face, a specular crescent on the lit rim and contact
/// shading on the shaded one. A translucent chip is not money.
///
/// The art fills the box edge to edge with nothing painted outside it, because
/// `_BetFlights` and `_PotToWinner` position a chip by `size / 2` and would
/// land it off-centre otherwise. Everything is a fraction of [size], and the
/// smallest chip the app asks for is the seat's bet pill at `podW * 0.14` —
/// 360 -> 12.3 | 411 -> 14.3 | 800 -> 20.7 — so every hairline here carries a
/// floor that keeps it a line rather than a smear at 12dp.
class PokerChip extends StatelessWidget {
  const PokerChip({
    super.key,
    required this.colour,
    this.size = 22,
    this.dashes = _defaultDashes,
    this.grounded = false,
  });

  final Color colour;
  final double size;
  final int dashes;

  /// Whether the chip is *resting on* something.
  ///
  /// A grounded chip gives up the bottom tenth of its box to a contact shadow
  /// and shrinks to fit, so it reads as sitting on a surface instead of
  /// floating over one. Off by default: the flights and the pot centre a chip
  /// on the box, and moving the disc off centre would move where they land.
  final bool grounded;

  @override
  Widget build(BuildContext context) {
    // The raster is a pure function of the fields, so a chip carried by a
    // travelling or rotating parent — the bet flights, the drifting background
    // — is composited rather than re-shaded on every frame.
    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _ChipPainter(
            tones: _ChipTones.of(colour),
            dashes: dashes,
            grounded: grounded,
          ),
        ),
      ),
    );
  }
}

/// The tones one chip is built from.
///
/// Derived once per colour so the body gradient, the inserts, the face and the
/// moulded edge cannot drift apart, and so the single
/// [ThemeData.estimateBrightnessForColor] call — the auto-contrast contract the
/// old black-or-white rim was built on — is made in one place.
@immutable
class _ChipTones {
  const _ChipTones._({
    required this.top,
    required this.body,
    required this.base,
    required this.outline,
    required this.face,
    required this.edgeHigh,
    required this.edgeLow,
    required this.rim,
  });

  factory _ChipTones.of(Color colour) {
    // One threshold, and it is the framework's own: it flips at a relative
    // luminance of 0.337. A dark chip takes the bright champagne, a light one
    // the deep — the contrast contract survives while the theme-flipping
    // black-or-white rim goes.
    final rim = ThemeData.estimateBrightnessForColor(colour) == Brightness.dark
        ? AppTheme.goldBright
        : AppTheme.goldDeep;

    return _ChipTones._(
      top: _lighten(colour, 0.16),
      body: colour,
      base: _darken(colour, 0.22),
      outline: _darken(colour, 0.42),
      face: _darken(colour, 0.10),
      edgeHigh: _darken(colour, 0.35),
      edgeLow: _darken(colour, 0.55),
      rim: rim,
    );
  }

  final Color top;
  final Color body;
  final Color base;
  final Color outline;
  final Color face;
  final Color edgeHigh;
  final Color edgeLow;
  final Color rim;

  // Every other field is a pure function of [body], so one comparison covers
  // all eight.
  @override
  bool operator ==(Object other) => other is _ChipTones && other.body == body;

  @override
  int get hashCode => body.hashCode;
}

Color _lighten(Color c, double t) => Color.lerp(c, const Color(0xFFFFFFFF), t)!;
Color _darken(Color c, double t) => Color.lerp(c, const Color(0xFF000000), t)!;

/// Alpha applied as a multiplier rather than by a `saveLayer`: a chip in a
/// falling pile fades individually, and five layers to do it would be five
/// off-screen buffers.
Color _fade(Color c, double alpha) =>
    alpha >= 1 ? c : c.withValues(alpha: c.a * alpha);

/// One chip, of radius [r], centred on [centre].
///
/// Shared by the single chip, both piles and the spin, so a chip in a stack is
/// the same object as a chip on its own.
void _paintChip(
  Canvas canvas,
  Offset centre,
  double r,
  _ChipTones tones,
  int dashes, {
  double alpha = 1,
}) {
  final disc = Rect.fromCircle(center: centre, radius: r);

  // The body: clay under a lamp up and to the left.
  canvas.drawCircle(
    centre,
    r,
    Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.35, -0.4),
        radius: 0.95,
        colors: [
          _fade(tones.top, alpha),
          _fade(tones.body, alpha),
          _fade(tones.base, alpha),
        ],
        stops: const [0, 0.55, 1],
      ).createShader(disc),
  );

  // The edge inserts, drawn as a thick stroked circle broken up by wedges
  // rather than as separate shapes.
  final insert = Paint()
    ..color = _fade(tones.rim.withValues(alpha: 0.85), alpha)
    ..style = PaintingStyle.stroke
    ..strokeWidth = r * 0.3;

  final insertRect = Rect.fromCircle(center: centre, radius: r * 0.85);
  final sweep = (2 * math.pi / dashes) * 0.45;
  for (var i = 0; i < dashes; i++) {
    final start = (2 * math.pi / dashes) * i - sweep / 2;
    canvas.drawArc(insertRect, start, sweep, false, insert);
  }

  // The moulded outer wall, kept inside the box so the chip still fills its
  // SizedBox exactly.
  final wall = (r * 0.09).clamp(0.5, 1.4);
  canvas.drawCircle(
    centre,
    r - wall / 2,
    Paint()
      ..color = _fade(tones.outline, alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = wall,
  );

  // The recessed face, and the ring that cuts it in.
  canvas.drawCircle(centre, r * 0.62, Paint()..color = _fade(tones.face, alpha));
  canvas.drawCircle(
    centre,
    r * 0.62,
    Paint()
      ..color = _fade(tones.rim.withValues(alpha: 0.45), alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(r * 0.1, 0.6),
  );

  // Specular on the lit rim, occlusion on the shaded one. The pair is what
  // makes a flat disc read as a moulded object; either alone reads as a sticker.
  final gloss = math.max(r * 0.1, 0.6);
  canvas.drawArc(
    Rect.fromCircle(center: centre, radius: r - gloss),
    math.pi * 1.02,
    math.pi * 0.46,
    false,
    Paint()
      ..color = _fade(const Color(0x38FFFFFF), alpha)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = gloss,
  );
  canvas.drawArc(
    Rect.fromCircle(center: centre, radius: r - gloss),
    -math.pi * 0.04,
    math.pi * 0.58,
    false,
    Paint()
      ..color = _fade(AppTheme.ink900.withValues(alpha: 0.22), alpha)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = gloss,
  );
}

class _ChipPainter extends CustomPainter {
  const _ChipPainter({
    required this.tones,
    required this.dashes,
    required this.grounded,
  });

  final _ChipTones tones;
  final int dashes;
  final bool grounded;

  @override
  void paint(Canvas canvas, Size size) {
    final d = size.shortestSide;
    final r = grounded ? d * 0.45 : d / 2;
    final centre = grounded
        ? Offset(size.width / 2, size.height * 0.9 - r)
        : size.center(Offset.zero);

    if (grounded) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(size.width / 2, size.height * 0.945),
          width: r * 1.72,
          height: size.height * 0.11,
        ),
        Paint()
          ..color = AppTheme.ink900.withValues(alpha: 0.34)
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            math.max(d * 0.05, 0.8),
          ),
      );
    }

    _paintChip(canvas, centre, r, tones, dashes);
  }

  @override
  bool shouldRepaint(_ChipPainter old) =>
      old.tones != tones || old.dashes != dashes || old.grounded != grounded;
}

/// Chips stacked, for a stake rather than a single coin.
class ChipStack extends StatelessWidget {
  const ChipStack({super.key, required this.colours, this.size = 22});

  /// Bottom of the pile first: `colours.first` is the chip everything else is
  /// set down on. The length is layout — it sets the box's height — so callers
  /// can size around it.
  final List<Color> colours;
  final double size;

  @override
  Widget build(BuildContext context) {
    final lift = size * 0.22;

    return RepaintBoundary(
      child: SizedBox(
        width: size,
        height: size + lift * (colours.length - 1),
        child: CustomPaint(
          painter: _PilePainter(
            tones: [for (final c in colours) _ChipTones.of(c)],
            diameter: size,
            lift: lift,
          ),
        ),
      ),
    );
  }
}

/// A pile, painted in one pass.
///
/// One painter rather than a chip per widget, because the shadow each chip
/// casts on the one below it has to be laid down *between* them — that contact
/// is the whole difference between a pile and a column of overlapping discs.
class _PilePainter extends CustomPainter {
  const _PilePainter({
    required this.tones,
    required this.diameter,
    required this.lift,
    this.drop,
    this.alphas,
  });

  final List<_ChipTones> tones;
  final double diameter;
  final double lift;

  /// Per-chip state while the pile is still landing; null once it has.
  final List<double>? drop;
  final List<double>? alphas;

  @override
  void paint(Canvas canvas, Size size) {
    final r = diameter / 2;
    final x = size.width / 2;
    final floor = size.height - r;

    for (var k = 0; k < tones.length; k++) {
      final alpha = alphas == null ? 1.0 : alphas![k].clamp(0.0, 1.0);
      if (alpha <= 0) continue;

      final centre = Offset(x, floor - lift * k + (drop == null ? 0 : drop![k]));

      // Cast onto the chip below before that chip is covered: what stays
      // visible is the crescent under this one's lower edge.
      if (k > 0) {
        canvas.drawOval(
          Rect.fromCenter(
            center: centre.translate(0, lift * 0.7),
            width: r * 1.84,
            height: r * 1.1,
          ),
          Paint()
            ..color = _fade(AppTheme.ink900.withValues(alpha: 0.34), alpha)
            ..maskFilter = MaskFilter.blur(
              BlurStyle.normal,
              math.max(r * 0.14, 0.6),
            ),
        );
      }

      _paintChip(canvas, centre, r, tones[k], _defaultDashes, alpha: alpha);
    }
  }

  @override
  bool shouldRepaint(_PilePainter old) =>
      old.diameter != diameter ||
      old.lift != lift ||
      !listEquals(old.tones, tones) ||
      !listEquals(old.drop, drop) ||
      !listEquals(old.alphas, alphas);
}

/// A chip that turns over now and then.
///
/// It spins rather than spinning continuously: a chip revolving forever in the
/// corner of a lobby card is movement the eye has to keep dismissing. One turn,
/// then a few seconds of stillness, reads as a flourish instead.
class SpinningChip extends StatefulWidget {
  const SpinningChip({
    super.key,
    required this.colour,
    this.size = 22,
    this.turn = const Duration(milliseconds: 1100),
    this.rest = const Duration(milliseconds: 3400),
    this.delay = Duration.zero,
  });

  final Color colour;
  final double size;

  /// How long one revolution takes, and how long the chip sits still between
  /// revolutions.
  final Duration turn;
  final Duration rest;

  /// Staggers this chip against its neighbours, so a row of them does not turn
  /// in lockstep.
  final Duration delay;

  @override
  State<SpinningChip> createState() => _SpinningChipState();
}

class _SpinningChipState extends State<SpinningChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.turn + widget.rest,
  );

  /// Where in the cycle the turn ends and the rest begins.
  late final double _spinsUntil =
      widget.turn.inMilliseconds / (widget.turn + widget.rest).inMilliseconds;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(widget.delay, () {
      if (mounted) _c.repeat();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tones = _ChipTones.of(widget.colour);

    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            // Eased through the turn so it starts and stops softly, then flat
            // through the rest.
            final angle = t >= _spinsUntil
                ? 0.0
                : Curves.easeInOutCubic.transform(t / _spinsUntil) * math.pi * 2;

            return CustomPaint(
              painter: _SpinPainter(tones: tones, angle: angle),
            );
          },
        ),
      ),
    );
  }
}

/// The chip mid-revolution: a foreshortened face plus the edge it is milled
/// from.
///
/// Drawn rather than transformed, because a widget has no thickness: a
/// `rotateY` alone narrows to a line at ninety degrees, which the eye reads as
/// a chip being squashed rather than turned. The band is what makes it a
/// physical object, and it is why the old perspective entry is gone — that was
/// there to hide the same collapse.
class _SpinPainter extends CustomPainter {
  const _SpinPainter({required this.tones, required this.angle});

  final _ChipTones tones;
  final double angle;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final cos = math.cos(angle);
    final sin = math.sin(angle);

    // The face keeps |cos| of its width; the thickness shows at |sin|, so the
    // two hand off to each other across a revolution.
    final squash = math.max(cos.abs(), 0.02);
    final band = size.shortestSide * 0.055 * sin.abs();

    if (band > 0.4) {
      // The edge swaps sides as the chip passes edge-on, which is what a
      // turning coin does.
      final side = sin * cos >= 0 ? -1.0 : 1.0;
      final face = Rect.fromCenter(
        center: centre,
        width: 2 * r * squash,
        height: 2 * r,
      );
      final start = side > 0 ? -math.pi / 2 : math.pi / 2;
      final wall = Path()
        ..addArc(face, start, math.pi)
        ..arcTo(face.translate(side * band, 0), start + math.pi, -math.pi, false)
        ..close();

      canvas.drawPath(
        wall,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [tones.edgeHigh, tones.edgeLow],
          ).createShader(wall.getBounds()),
      );
    }

    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(squash, 1);
    canvas.translate(-centre.dx, -centre.dy);
    _paintChip(canvas, centre, r, tones, _defaultDashes);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpinPainter old) =>
      old.angle != angle || old.tones != tones;
}

/// A stack of chips that drops into place on first paint and then settles.
///
/// The chips land one after another from the bottom of the pile up, which is
/// the order they would be set down in, and the float they land into damps
/// away — a pile that breathes for ever is a pile nobody has put down.
class LivelyChipStack extends StatefulWidget {
  const LivelyChipStack({super.key, required this.colours, this.size = 22});

  final List<Color> colours;
  final double size;

  @override
  State<LivelyChipStack> createState() => _LivelyChipStackState();
}

class _LivelyChipStackState extends State<LivelyChipStack>
    with TickerProviderStateMixin {
  /// The lower a chip is in the pile, the sooner it lands.
  static const _fallMs = 420;
  static const _stackedMs = 130;

  /// Four float cycles past the last landing is where the damping has run out
  /// of anything to say (exp(-4) = 0.018).
  static const _cycleMs = 3200;
  static const _settleMs = 4 * _cycleMs;

  late final int _landMs =
      _fallMs + math.max(0, widget.colours.length - 1) * _stackedMs + _settleMs;

  /// The idle float, once everything has landed. Slow and small: this is the
  /// pile settling, not bouncing.
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _cycleMs),
  )..repeat();

  /// The drop, and the damping that follows it. One clock for both, so the
  /// pile cannot start breathing before it has been set down.
  late final AnimationController _land = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: _landMs),
  )..forward();

  @override
  void dispose() {
    _float.dispose();
    _land.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lift = widget.size * 0.22;
    final count = widget.colours.length;
    final tones = [for (final c in widget.colours) _ChipTones.of(c)];

    // The pile listens to the drop alone and sits behind its own boundary, so
    // the float below only moves a finished layer around.
    final pile = RepaintBoundary(
      child: AnimatedBuilder(
        animation: _land,
        builder: (context, _) {
          final elapsed = _land.value * _landMs;
          final drop = <double>[];
          final alphas = <double>[];
          for (var k = 0; k < count; k++) {
            final landed = Curves.easeOutBack.transform(
              (elapsed / (_fallMs + k * _stackedMs)).clamp(0.0, 1.0),
            );
            // easeOutBack overshoots past 1, so the chip dips a little under
            // its resting place on arrival. The opacity is clamped; the offset
            // is not, and nothing clips it.
            drop.add(-widget.size * (1 - landed));
            alphas.add(landed.clamp(0.0, 1.0));
          }

          return SizedBox(
            width: widget.size,
            height: widget.size + lift * (count - 1),
            child: CustomPaint(
              painter: _PilePainter(
                tones: tones,
                diameter: widget.size,
                lift: lift,
                drop: drop,
                alphas: alphas,
              ),
            ),
          );
        },
      ),
    );

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _float,
        child: pile,
        builder: (context, child) {
          final since = math.max(0.0, _land.value * _landMs - _settleMs);
          final damp = 0.35 + 0.65 * math.exp(-since / _cycleMs);
          return Transform.translate(
            offset: Offset(
              0,
              math.sin(_float.value * math.pi * 2) * widget.size * 0.055 * damp,
            ),
            child: child,
          );
        },
      ),
    );
  }
}
