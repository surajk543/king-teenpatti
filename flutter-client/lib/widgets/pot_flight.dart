/// The pot travelling to whoever won it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'poker_chip.dart';

/// A run of chips that leaves the pot and lands on the winner's seat, one after
/// another. It runs once — the pot moves once.
///
/// Rebuilt for smoothness (owner, 14 Sep 2026: the winner's coins did not move
/// smoothly). The flight it replaces had three faults:
/// - every chip flew for what was left of one shared clock after it set off,
///   so the first took 1.7 s and the last half that, and late chips overtook
///   early ones in mid-air;
/// - every chip dragged a faint copy of itself a step behind, which on screen
///   read as a double image strobing along the path;
/// - the eighteen were widgets, each with an opacity layer and a rotated
///   raster of its own, laid out and painted every frame while the fireworks,
///   the cards turning over and the winner's ribbon were all animating too.
///
/// Now every chip makes the same trip ([flight]) on the same curve, a
/// [stagger] behind the chip before it, so none can pass another; it fades and
/// grows in at the pot instead of popping into being, and shrinks and fades as
/// it lands; and the whole run is ONE painter repainting off its controller —
/// no widget rebuilt, nothing laid out and no layer made per frame.
class PotFlight extends StatefulWidget {
  const PotFlight({
    super.key,
    required this.from,
    required this.to,
    required this.size,
  });

  /// The pot and the winner's seat, in the coordinates of the box this fills.
  final Offset from;
  final Offset to;

  /// One chip's diameter.
  final double size;

  /// How many chips make the run.
  static const int chips = 9;

  /// One chip's trip from the pot to the seat.
  static const Duration flight = Duration(milliseconds: 900);

  /// How long after the chip before it each chip sets off.
  static const Duration stagger = Duration(milliseconds: 60);

  /// The whole run, from the first chip leaving to the last one landing.
  static const Duration total = Duration(milliseconds: 900 + 60 * (chips - 1));

  @override
  State<PotFlight> createState() => _PotFlightState();
}

/// One chip of a [PotFlight] at one moment.
@immutable
class PotChip {
  const PotChip({
    required this.t,
    required this.along,
    required this.bow,
    required this.alpha,
    required this.scale,
    required this.turn,
  });

  /// How far through its own trip the chip is, 0 to 1 in time.
  final double t;

  /// How far along the path from the pot to the seat, 0 to 1: [t] eased, so
  /// the chip leaves gently and settles gently.
  final double along;

  /// How far the path bows out to one side, in chip diameters. Zero at both
  /// ends, so a chip leaves from the pot and lands on the seat exactly.
  final double bow;

  /// The chip's opacity, and its size as a fraction of a full chip.
  final double alpha;
  final double scale;

  /// How far it has turned, in revolutions.
  final double turn;
}

/// Chip [index] of a run, [elapsed] after the run began; null before that chip
/// has set off and once it has landed.
PotChip? potChipAt(int index, Duration elapsed) {
  final ms =
      elapsed.inMicroseconds / Duration.microsecondsPerMillisecond -
      PotFlight.stagger.inMilliseconds * index;
  if (ms <= 0) return null;
  final t = ms / PotFlight.flight.inMilliseconds;
  if (t >= 1) return null;

  final along = Curves.easeInOutCubic.transform(t);
  // It arrives over the first 15% of its trip and lands over the last 20%.
  final arriving = Curves.easeOut.transform(math.min(t / 0.15, 1.0));
  final landing = Curves.easeOut.transform(math.min((1 - t) / 0.2, 1.0));

  return PotChip(
    t: t,
    along: along,
    // Alternate sides, a little wider chip by chip, so the run fans out like a
    // pile being pushed across the cloth rather than queueing on one line.
    bow:
        (index.isEven ? 1 : -1) *
        (0.45 + 0.1 * index) *
        math.sin(along * math.pi),
    alpha: math.min(arriving, landing),
    scale: (0.7 + 0.3 * arriving) * (0.7 + 0.3 * landing),
    // One calm turn over the trip, alternate chips the other way.
    turn: along * (index.isEven ? 1 : -1),
  );
}

class _PotFlightState extends State<PotFlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: PotFlight.total,
  )..forward();

  final PokerChipBrush _brush = PokerChipBrush(AppTheme.gold);

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _PotFlightPainter(
            clock: _clock,
            from: widget.from,
            to: widget.to,
            size: widget.size,
            brush: _brush,
          ),
        ),
      ),
    ),
  );
}

class _PotFlightPainter extends CustomPainter {
  _PotFlightPainter({
    required this.clock,
    required this.from,
    required this.to,
    required this.size,
    required this.brush,
  }) : super(repaint: clock);

  final Animation<double> clock;
  final Offset from;
  final Offset to;
  final double size;
  final PokerChipBrush brush;

  @override
  void paint(Canvas canvas, Size box) {
    final elapsed = PotFlight.total * clock.value;
    final line = to - from;
    final length = line.distance;
    final side = length == 0 ? Offset.zero : Offset(-line.dy, line.dx) / length;

    // The last chip to leave is drawn first, so the one leading the run is on
    // top of the chips following it.
    for (var i = PotFlight.chips - 1; i >= 0; i--) {
      final chip = potChipAt(i, elapsed);
      if (chip == null) continue;
      final centre =
          Offset.lerp(from, to, chip.along)! + side * (chip.bow * size);
      canvas
        ..save()
        ..translate(centre.dx, centre.dy)
        ..rotate(chip.turn * 2 * math.pi);
      brush.paint(
        canvas,
        Offset.zero,
        size / 2 * chip.scale,
        alpha: chip.alpha,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_PotFlightPainter old) =>
      old.clock != clock ||
      old.from != from ||
      old.to != to ||
      old.size != size ||
      old.brush != brush;
}
