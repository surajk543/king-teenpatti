/// Chips crossing the table: every bet from the seat that made it into the
/// pot ([BetFlights]), and the pot to whoever won it ([PotFlight]).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../models/dtos.dart';
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
/// it lands; and the whole run is ONE painter repainting off its clock — no
/// widget rebuilt, nothing laid out and no layer made per frame.
///
/// The clock is the flight's own unless the table hands it one ([progress]):
/// the Teen Patti felt runs its whole celebration off one clock (26 Sep 2026),
/// so the pot's figure falls as the chips leave the pile ([leftAt]) and the
/// winner's stack rises as they land on it ([landedAt]).
class PotFlight extends StatefulWidget {
  const PotFlight({
    super.key,
    required this.from,
    required this.to,
    required this.size,
    this.progress,
  });

  /// The pot and the winner's seat, in the coordinates of the box this fills.
  final Offset from;
  final Offset to;

  /// One chip's diameter.
  final double size;

  /// The run, 0 to 1 over [total], when the table keeps the time: 0 until
  /// the chips set off, 1 once the last has landed. Null runs the flight on
  /// a clock of its own from the frame it first appears (the poker felt).
  final Animation<double>? progress;

  /// How many chips make the run.
  static const int chips = 9;

  /// One chip's trip from the pot to the seat.
  static const Duration flight = Duration(milliseconds: 900);

  /// How long after the chip before it each chip sets off.
  static const Duration stagger = Duration(milliseconds: 60);

  /// The whole run, from the first chip leaving to the last one landing.
  static const Duration total = Duration(milliseconds: 900 + 60 * (chips - 1));

  /// The share of its trip over which a chip rises off the pile, and over
  /// which it settles onto the seat — the same shares [potChipAt] fades it
  /// in and out over.
  static const double leaving = 0.15;
  static const double landing = 0.2;

  /// How much of the pot has left the pile [elapsed] after the run began, 0
  /// to 1: each chip takes its ninth as it rises off the pile. Falls to the
  /// last chip's leaving, 615 ms in; the plinth's figure follows it down, so
  /// the number drops as the chips go rather than before any has moved.
  static double leftAt(Duration elapsed) => _share(elapsed, 0, leaving);

  /// How much of the pot has landed on the seat [elapsed] after the run
  /// began, 0 to 1: each chip's ninth as it settles there, from 720 ms to
  /// the end of the run. The winner's stack follows it up.
  static double landedAt(Duration elapsed) =>
      _share(elapsed, 1 - landing, landing);

  /// Every chip's progress through the part of its trip that starts at
  /// [from] and lasts [length] (both shares of [flight]), averaged over the
  /// run.
  static double _share(Duration elapsed, double from, double length) {
    final ms = elapsed.inMicroseconds / Duration.microsecondsPerMillisecond;
    final trip = flight.inMilliseconds;
    var sum = 0.0;
    for (var i = 0; i < chips; i++) {
      final t = (ms - stagger.inMilliseconds * i) / trip;
      sum += Curves.easeOut.transform(((t - from) / length).clamp(0.0, 1.0));
    }
    return sum / chips;
  }

  @override
  State<PotFlight> createState() => _PotFlightState();
}

/// A figure that follows the chips — the pot draining off its pile, a
/// winner's stack filling — built again only when what it shows changes
/// ([figureAt] of [animation]'s value: the words, formatted), never on the
/// ticks between: on the felt every rebuild lays the felt out again.
class LiveFigure extends StatefulWidget {
  const LiveFigure({
    super.key,
    required this.animation,
    required this.figureAt,
    required this.builder,
  });

  final Animation<double> animation;
  final String Function(double value) figureAt;
  final Widget Function(BuildContext context, String figure) builder;

  @override
  State<LiveFigure> createState() => _LiveFigureState();
}

class _LiveFigureState extends State<LiveFigure> {
  late String _figure = widget.figureAt(widget.animation.value);

  @override
  void initState() {
    super.initState();
    widget.animation.addListener(_follow);
  }

  @override
  void didUpdateWidget(covariant LiveFigure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeListener(_follow);
      widget.animation.addListener(_follow);
    }
    _figure = widget.figureAt(widget.animation.value);
  }

  @override
  void dispose() {
    widget.animation.removeListener(_follow);
    super.dispose();
  }

  void _follow() {
    final figure = widget.figureAt(widget.animation.value);
    if (figure != _figure) setState(() => _figure = figure);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _figure);
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
  final arriving = Curves.easeOut.transform(
    math.min(t / PotFlight.leaving, 1.0),
  );
  final landing = Curves.easeOut.transform(
    math.min((1 - t) / PotFlight.landing, 1.0),
  );

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
  /// The flight's own clock, when the table hands it none. Made in initState
  /// or didUpdateWidget, never first touched in dispose (CLAUDE.md §12.3).
  AnimationController? _own;

  final PokerChipBrush _brush = PokerChipBrush(AppTheme.gold);

  @override
  void initState() {
    super.initState();
    if (widget.progress == null) _startOwn();
  }

  @override
  void didUpdateWidget(covariant PotFlight old) {
    super.didUpdateWidget(old);
    if (widget.progress == null && _own == null) _startOwn();
  }

  void _startOwn() =>
      _own = AnimationController(vsync: this, duration: PotFlight.total)
        ..forward();

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _PotFlightPainter(
            clock: widget.progress ?? _own!,
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

/// Chips in flight from a seat to the pot, one for every bet as it happens.
///
/// Watches each seat's running total; when it rises, a chip sets off from that
/// seat and lands on the pot. A new hand resets the totals, so the boot
/// everyone posts at the deal flies in too. Nothing is sent for the snapshot a
/// player arrives to — those bets were made before they sat down — nor for
/// the table a switch lands them at.
///
/// Rebuilt on 26 Sep 2026 (owner: "check … coin flow, make it smooth"). Its
/// clock restarted from nought every time its ticker stopped, while each new
/// chip was stamped with the time the LAST run had ended: every bet after the
/// first at a table flashed at its seat for one frame, vanished, and left
/// that much later than the one before — 0.64 s, 1.28 s, 1.9 s … — until the
/// chips were crossing the cloth seconds after the bets, and the next hand's
/// boots with them. Its time is now one clock that only ever moves forward
/// ([_now]); a chip rises in at its seat instead of popping into being; and
/// the chips are one painter, as the pot's are, instead of a widget with an
/// opacity layer and a rotation each, rebuilt every frame.
class BetFlights extends StatefulWidget {
  const BetFlights({
    super.key,
    required this.seats,
    required this.roomId,
    required this.handNo,
    required this.centreOf,
    required this.pot,
    required this.size,
  });

  final List<Seat> seats;

  /// Which table this is: a switch lands on a hand whose bets were made
  /// before the player got there, so it flies nothing.
  final String roomId;
  final int handNo;
  final Offset Function(int seatIndex) centreOf;

  /// Where the chips land: the pile on the pot's plinth.
  final Offset pot;

  /// One chip's diameter.
  final double size;

  /// One chip's trip from its seat to the pot.
  static const Duration travel = Duration(milliseconds: 620);

  /// How far apart the chips of one snapshot set off: at the deal every seat
  /// posts at once, and a short stagger keeps them from arriving as one lump.
  static const Duration stagger = Duration(milliseconds: 70);

  /// How far into its trip a chip is over the pile — where it has come down
  /// and begins to fade into it. The pot answers the chip here (its flare and
  /// the pile's lift), not when the bet was made.
  static const Duration landsAt = Duration(milliseconds: 540);

  @override
  State<BetFlights> createState() => BetFlightsState();
}

/// One bet chip at one moment of its trip.
@immutable
class BetChip {
  const BetChip({
    required this.along,
    required this.lift,
    required this.turn,
    required this.alpha,
    required this.scale,
  });

  /// How far from the seat to the pot, 0 to 1, eased at both ends.
  final double along;

  /// How high it is tossed above the straight line, in chip diameters.
  final double lift;

  /// How far it has turned, in revolutions.
  final double turn;

  /// Its opacity, and its size as a fraction of a full chip.
  final double alpha;
  final double scale;
}

/// A bet chip [elapsed] after it set off; null before it has and once it has
/// landed.
BetChip? betChipAt(Duration elapsed) {
  final t = elapsed.inMicroseconds / BetFlights.travel.inMicroseconds;
  if (t < 0 || t >= 1) return null;
  // Up off the seat over the first tenth of the trip rather than popping into
  // being at full size, and into the pile over the last 18% — the fade the
  // chip always had.
  final rising = Curves.easeOut.transform(math.min(t / 0.10, 1.0));
  final settling = t > 0.82 ? (1 - t) / 0.18 : 1.0;
  return BetChip(
    along: Motion.travel.transform(t),
    // A shallow arc, so the chip is tossed rather than slid.
    lift: math.sin(t * math.pi) * 1.6,
    turn: t * 0.75,
    alpha: math.min(rising, settling).clamp(0.0, 1.0),
    scale: 0.8 + 0.2 * rising,
  );
}

class _BetFlight {
  _BetFlight({required this.from, required this.leavesAt});
  final Offset from;

  /// When it sets off, on [BetFlightsState._now]'s clock.
  final Duration leavesAt;
}

/// Tells the painter a frame of the flights has gone by.
class _Frames extends ChangeNotifier {
  void tick() => notifyListeners();
}

class BetFlightsState extends State<BetFlights>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  /// The flights' time, which only ever moves forward. A ticker's own
  /// elapsed time starts again from nought each time it is started, so the
  /// time it had reached when it last stopped is carried in [_base].
  Duration _base = Duration.zero;
  Duration _elapsed = Duration.zero;
  Duration get _now => _base + _elapsed;

  final Map<int, int> _seen = {};
  int _handNo = 0;
  String _roomId = '';
  final List<_BetFlight> _flights = [];

  /// Repaints the chips every frame they are in the air, and nothing else.
  final _frames = _Frames();

  final PokerChipBrush _brush = PokerChipBrush(AppTheme.gold);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _handNo = widget.handNo;
    _roomId = widget.roomId;
    // The state we arrive to is the baseline, not a set of bets to animate.
    _baseline();
  }

  void _baseline() {
    _seen
      ..clear()
      ..addEntries(
        widget.seats.map((seat) => MapEntry(seat.seatIndex, seat.contributed)),
      );
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    _flights.removeWhere((f) => _now - f.leavesAt >= BetFlights.travel);
    if (_flights.isEmpty) {
      _base = _now;
      _elapsed = Duration.zero;
      _ticker.stop();
    }
    _frames.tick();
  }

  @override
  void didUpdateWidget(covariant BetFlights oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.roomId != _roomId) {
      // Another table: its bets were made before the player sat down there.
      _roomId = widget.roomId;
      _handNo = widget.handNo;
      _baseline();
      return;
    }
    if (widget.handNo != _handNo) {
      _handNo = widget.handNo;
      _seen.clear();
    }
    var launched = 0;
    for (final seat in widget.seats) {
      final before = _seen[seat.seatIndex] ?? 0;
      if (seat.occupied && seat.contributed > before) {
        _flights.add(
          _BetFlight(
            from: widget.centreOf(seat.seatIndex),
            leavesAt: _now + BetFlights.stagger * launched,
          ),
        );
        launched += 1;
      }
      _seen[seat.seatIndex] = seat.contributed;
    }
    if (_flights.isNotEmpty && !_ticker.isActive) _ticker.start();
  }

  /// Where every chip in the air is right now, and how opaque — what the
  /// painter draws, for the tests.
  @visibleForTesting
  List<({Offset centre, double alpha, double scale})> get chipsInFlight => [
    for (final flight in _flights)
      if (betChipAt(_now - flight.leavesAt) case final chip?)
        (centre: _centre(flight, chip), alpha: chip.alpha, scale: chip.scale),
  ];

  Offset _centre(_BetFlight flight, BetChip chip) =>
      Offset.lerp(flight.from, widget.pot, chip.along)! -
      Offset(0, chip.lift * widget.size);

  @override
  void dispose() {
    _ticker.dispose();
    _frames.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: CustomPaint(
      painter: _BetFlightsPainter(
        state: this,
        pot: widget.pot,
        size: widget.size,
        repaint: _frames,
      ),
    ),
  );
}

class _BetFlightsPainter extends CustomPainter {
  _BetFlightsPainter({
    required this.state,
    required this.pot,
    required this.size,
    required Listenable repaint,
  }) : super(repaint: repaint);

  /// Where the chips are is read from the state at paint time; the state
  /// says when that has moved, every frame a chip is in the air.
  final BetFlightsState state;
  final Offset pot;
  final double size;

  @override
  void paint(Canvas canvas, Size box) {
    // In the order they set off, so a chip lands over the one before it.
    for (final flight in state._flights) {
      final chip = betChipAt(state._now - flight.leavesAt);
      if (chip == null) continue;
      final centre =
          Offset.lerp(flight.from, pot, chip.along)! -
          Offset(0, chip.lift * size);
      canvas
        ..save()
        ..translate(centre.dx, centre.dy)
        ..rotate(chip.turn * 2 * math.pi);
      state._brush.paint(
        canvas,
        Offset.zero,
        size / 2 * chip.scale,
        alpha: chip.alpha,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_BetFlightsPainter old) =>
      old.state != state || old.pot != pot || old.size != size;
}
