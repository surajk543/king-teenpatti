import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../models/dtos.dart';
import '../state/game_state.dart' show formatChips;
import '../theme/app_theme.dart';
import 'lucky_prizes.dart';

/// The Lucky Draw's wheel (owner, 24 Sep 2026): a six-wedge prize wheel on a
/// stand, the owner's own Lottie (5.10, 300x300, 30 fps), played as it is.
///
/// The file turns its wheel through seven and a half turns in its first five
/// seconds and always stops on the same wedge; then it flashes that wedge and
/// scatters sparkles. None of that can say where a spin landed — the SERVER
/// draws the slot — so the wheel's turn is taken over at runtime
/// ([LuckyWheel]) and only the rest of the file is played: the rim's lights,
/// looping.
const String luckySpinnerAsset = 'assets/animations/Lucky Draw Spinner.json';

/// How long a spin takes from the tap to rest (owner, 24 Sep 2026: "at least
/// run for 5-6 seconds") when the server answers at once — a slower answer
/// keeps the wheel at full speed for as long as it takes ([LuckySpinMotion]).
const Duration luckySpinTime = Duration(seconds: 6);

/// Where things are on [luckySpinnerAsset]'s canvas, in its own units.
///
/// The wheel is the file's layer 12 — a shape layer named `L`, turned about
/// (150, 127.99) — cut into six wedges of 60°, the first centred at the top
/// and the rest clockwise. The hub's needle points straight up, so the wedge
/// at the top is the one the wheel has stopped on. Slot n of the draw is
/// wedge n − 1: with the wheel turned θ degrees clockwise, its centre is at
/// 60(n − 1) + θ degrees from the top.
abstract final class LuckyWheelGeometry {
  /// The hub, which the wheel turns about.
  static const Offset centre = Offset(150, 127.99);

  /// One wedge, in degrees.
  static const double wedge = 60;

  /// A prize badge's centre, as a distance from the hub, and its diameter.
  /// The wedges reach 84 from the hub and the hub itself about 22, so a disc
  /// of 42 at 57 stands clear of the hub, the rim and both of its wedge's
  /// edges (57 · sin 30° = 28.5 ≥ 21).
  static const double badgeRadius = 57;
  static const double badgeSize = 42;

  /// The gold rim every wedge sits in (the file's layer 13, a disc of 100),
  /// and how far the wedges themselves reach.
  static const double rimRadius = 100;
  static const double wedgeRadius = 84;

  /// The hub's orange collar (the file's own, left as it is) and the gold cap
  /// laid over its middle ([LuckyWheel]'s hub).
  static const double collarRadius = 20;
  static const double capRadius = 14;

  /// How far above the hub the needle's point stands: where the file's own
  /// needle ended, just short of the top badge, which begins at
  /// [badgeRadius] − [badgeSize] / 2 = 36.
  static const double needleReach = 33.5;

  /// The foot of the stand: the lower edge of its base, and half its width.
  static const double footY = 272;
  static const double footHalfWidth = 56;

  /// The part of the canvas drawn: the rim (50..250 across, from 28 down),
  /// the stand (down to 272), and two units round them (26 Sep 2026). It was
  /// 25..275 across and 18..282 down — up to 25 units of empty canvas round
  /// the art, which kept the wheel a tenth smaller than the panel's height
  /// allowed. The light round the rim and the stand's shadow are drawn by
  /// [LuckyWheel] itself, outside this window.
  static const Rect window = Rect.fromLTRB(48, 26, 252, 274);
  static const double canvas = 300;

  /// The frames played: the file's first five seconds, over which its lights
  /// chase round the rim. Those after them flash the file's own first wedge,
  /// whatever the draw landed on, and are never played.
  static const double loopEnd = 150 / 240;
}

/// The wheel's angle, in degrees clockwise, with [slotNumber]'s wedge
/// centred under the needle.
double luckyRestAngle(int slotNumber) =>
    -LuckyWheelGeometry.wedge * (slotNumber - 1);

/// The slot under the needle when the wheel stands at [angle].
int luckySlotAt(double angle) =>
    ((-angle / LuckyWheelGeometry.wedge).round() % 6) + 1;

/// Where a spin landing on [slotNumber] stops: [turns] whole turns on from
/// [from], clockwise, and on to that slot's wedge, [nudge] degrees off its
/// centre — kept well inside the wedge's half-width of 30, so the needle
/// always stands in it.
double luckySpinTarget({
  required double from,
  required int slotNumber,
  int turns = 5,
  double nudge = 0,
}) {
  final rest = luckyRestAngle(slotNumber) + nudge.clamp(-18.0, 18.0);
  return from + turns * 360 + (rest - from) % 360;
}

/// Where in its wedge a spin comes to rest: a few degrees either side of the
/// middle, fixed by the spin's own key, so a wheel does not stop dead centre
/// every time. Looks only; the slot is the server's.
double luckyNudge(String actionId) => (actionId.hashCode % 21 - 10).toDouble();

/// The rim's bulbs, lit and unlit (owner, 24 Sep 2026: "The wheel outer dots
/// should blink always").
///
/// The file does blink them — two rings of bulbs, half a second out of step,
/// each bulb turning between an ivory and a pale yellow every half second —
/// but two pale colours on a gold rim hardly read as a blink at all. Here the
/// yellow is lit, a bright lemon, and the ivory unlit, a dull rust, so the
/// two rings chase each other round the wheel like a fairground's bulbs; the
/// file's timing is untouched, and the lights run for as long as the wheel is
/// on screen, spinning or not.
const Color luckyBulbLit = Color(0xFFFFF59D);
const Color luckyBulbUnlit = Color(0xFF9C4A16);

/// What [luckySpinnerAsset]'s bulb fill [file] is drawn as: its yellow lit,
/// its ivory unlit, anything else — the orange ring round each bulb — as it
/// is. Told apart by channel: both bulb colours are full green, and only the
/// ivory is also nearly full blue.
Color luckyBulbColour(Color file) {
  if (file.g < 0.9) return file;
  return file.b > 0.8 ? luckyBulbUnlit : luckyBulbLit;
}

/// What the hub's fill [file] is drawn as (26 Sep 2026, the Lucky Draw polish:
/// "make the center hub feel more polished"): the file's pale-yellow needle
/// and cap — a flat cream that all but vanished on the white wedges — are
/// left out, and [LuckyWheel] draws them again in struck gold over the hub;
/// the orange collar, its dark ring, the gold pin and the collar's shadow are
/// the file's own. Told apart by channel: only the cream is nearly full green.
Color luckyHubColour(Color file) =>
    file.g > 0.85 ? const Color(0x00000000) : file;

/// How a spin runs: the share of its whole turn the wheel has made at each
/// share of its time (owner, 24 Sep 2026: "slowly increase its speed and the
/// end slowly reduce its speed").
///
/// Told as the wheel's SPEED, which the position is the integral of: from rest
/// it gathers speed along a smoothstep over the first [speedUp] of the run
/// (no jolt at the start, none as it reaches full speed), holds full speed for
/// [hold], and runs down over the rest along (1 − x)³(1 + 3x) — which leaves
/// full speed as gently as the smoothstep reached it, and comes to rest with
/// a long creep, as a wheel spun by hand does. Over the six seconds of
/// [luckySpinTime] it takes a second and a half to reach full speed — the
/// first second covers a tenth of the turn — holds it for most of a second,
/// and runs down for three and a half, the last second covering well under a
/// hundredth.
///
/// It replaced a curve that left at full speed and slowed from the first
/// frame (the owner: "not smooth"): all but the first second was a crawl, and
/// that first second moved a wedge a frame, which on a wheel of six wedges
/// strobes. This one's full speed, five turns in six seconds, is under two
/// turns a second — a fifth of a wedge a frame at 60 fps.
///
/// [LuckySpinMotion] runs a spin along these three parts, starting the moment
/// the key is pressed.
class LuckySpinCurve extends Curve {
  const LuckySpinCurve({this.speedUp = 0.25, this.hold = 0.15});

  /// The shares of the run spent gathering speed, and at full speed; the
  /// rest is the run down.
  final double speedUp;
  final double hold;

  /// The share of the run spent running down to rest.
  double get runDown => 1 - speedUp - hold;

  /// The whole distance, in full-speed-by-time units: half the speed-up, all
  /// of the hold and two fifths of the run down.
  double get whole => 0.5 * speedUp + hold + 0.4 * runDown;

  /// The wheel's speed at [t], as a share of its full speed.
  double speedAt(double t) {
    if (t <= 0 || t >= 1) return 0;
    if (t < speedUp) return luckySpeedUp(t / speedUp);
    if (t <= speedUp + hold) return 1;
    return luckyRunDown(1 - (t - speedUp - hold) / runDown);
  }

  @override
  double transformInternal(double t) {
    final double run;
    if (t <= speedUp) {
      run = speedUp * luckySpeedUpRun(t / speedUp);
    } else if (t <= speedUp + hold) {
      run = 0.5 * speedUp + (t - speedUp);
    } else {
      run =
          0.5 * speedUp +
          hold +
          runDown * luckyRunDownRun((t - speedUp - hold) / runDown);
    }
    return run / whole;
  }
}

/// The speed-up's speed at [x] of its way, as a share of full speed: a
/// smoothstep, at rest at both ends of its slope.
double luckySpeedUp(double x) => x * x * (3 - 2 * x);

/// How far the speed-up has carried the wheel at [x] of its way, in full
/// speed by its length: the integral of the smoothstep, x³ − x⁴/2.
double luckySpeedUpRun(double x) => x * x * x - x * x * x * x / 2;

/// The run-down's speed with [y] of it still to go: (1 − x)³(1 + 3x) with
/// y = 1 − x, which leaves full speed with no jolt and creeps to rest.
double luckyRunDown(double y) => y * y * y * (4 - 3 * y);

/// How far the run-down has carried the wheel at [x] of its way, in its
/// starting speed by its length: 0 at the start, 0.4 at rest.
double luckyRunDownRun(double x) {
  final y = 1 - x;
  return 0.4 - (y * y * y * y - 0.6 * y * y * y * y * y);
}

/// A spin, from the tap to rest (26 Sep 2026, the Lucky Draw polish: "start
/// wheel acceleration" at the tap, "precisely stop at the server-selected
/// reward").
///
/// The wheel starts to turn the moment the key is pressed, along
/// [LuckySpinCurve]'s speed-up, and holds full speed until it is told where
/// to stop — nothing about the turn so far depends on the prize, so nothing
/// is drawn by the client. [landOn], with the slot the server drew, plans the
/// run-down: the one moment to leave full speed from which the curve's own
/// run-down comes to rest exactly on [luckySpinTarget] — five whole turns and
/// on to the slot, a turn more for every 360° of full speed the answer took
/// to come. The speed-up, the hold and the run-down meet at full speed with
/// no change of pace, so the answer arriving shows nowhere in the turn. An
/// answer that comes at once rests the wheel 5.7 to 6.3 seconds after the tap
/// ([luckySpinTime] on average); one that comes late keeps it at full speed
/// until it does, and then takes the same run-down. [stop], when there is no
/// prize — the spin was refused, or never answered —, runs the wheel down
/// from whatever speed it has, wherever that leaves it.
class LuckySpinMotion extends Simulation {
  LuckySpinMotion({
    required this.from,
    this.curve = const LuckySpinCurve(),
    this.time = luckySpinTime,
  });

  /// Where the wheel stood at the tap, in degrees clockwise.
  final double from;
  final LuckySpinCurve curve;
  final Duration time;

  double get _seconds => time.inMicroseconds / Duration.microsecondsPerSecond;

  /// How long the speed-up takes, in seconds: 1.5 of the six.
  double get speedUpFor => curve.speedUp * _seconds;

  /// How long the run-down takes from full speed, in seconds: 3.6 of the six.
  double get runDownFor => curve.runDown * _seconds;

  /// Full speed, in degrees a second: the speed at which [curve] carries a
  /// spin of five and a half turns — the middle of a spin's range — over
  /// [time]. 641°/s, under two turns a second.
  double get fullSpeed => 5.5 * 360 / (_seconds * curve.whole);

  // The run-down, once it is planned: when it starts (seconds from the tap),
  // where and at what speed, and how long it takes. Null until then.
  double? _downAt;
  double _downFrom = 0;
  double _downSpeed = 0;
  double _downFor = 0;

  /// Where the wheel comes to rest, once the run-down is planned.
  double? _rest;

  /// Whether the run-down has been planned — by [landOn] or [stop].
  bool get planned => _downAt != null;

  /// Seconds from the tap to rest, once planned; null until then.
  double? get restsAt => _downAt == null ? null : _downAt! + _downFor;

  /// Where the wheel will rest, once planned; null until then.
  double? get restAngle => _rest;

  /// The wind-up: the speed-up, then full speed for as long as it lasts.
  double _windUp(double t) {
    if (t <= 0) return from;
    final r = speedUpFor;
    if (t < r) return from + fullSpeed * r * luckySpeedUpRun(t / r);
    return from + fullSpeed * (r / 2 + (t - r));
  }

  double _windUpSpeed(double t) {
    if (t <= 0) return 0;
    final r = speedUpFor;
    return t < r ? fullSpeed * luckySpeedUp(t / r) : fullSpeed;
  }

  @override
  double x(double time) {
    final at = _downAt;
    if (at == null || time <= at) return _windUp(time);
    if (time >= at + _downFor) return _rest!;
    return _downFrom +
        _downSpeed * _downFor * luckyRunDownRun((time - at) / _downFor);
  }

  @override
  double dx(double time) {
    final at = _downAt;
    if (at == null || time <= at) return _windUpSpeed(time);
    if (time >= at + _downFor) return 0;
    return _downSpeed * luckyRunDown(1 - (time - at) / _downFor);
  }

  @override
  bool isDone(double time) {
    final at = _downAt;
    return at != null && time >= at + _downFor;
  }

  /// Plans the run-down onto [slotNumber], [nudge] degrees off its centre,
  /// with the answer in hand [now] seconds after the tap. Returns the seconds
  /// from the tap to rest. Called once; the turn it plans is the server's.
  double landOn({
    required int slotNumber,
    required double now,
    double nudge = 0,
  }) {
    assert(!planned, 'a spin lands once');
    final v = fullSpeed;
    final r = speedUpFor;
    final q = runDownFor;
    for (var turns = 5; ; turns++) {
      final target = luckySpinTarget(
        from: from,
        slotNumber: slotNumber,
        turns: turns,
        nudge: nudge,
      );
      // At full speed from the end of the speed-up, and 0.4 of the run-down's
      // length at full speed to rest: the one moment to leave full speed.
      final leave = r + (target - from - v * r / 2 - 0.4 * v * q) / v;
      if (leave >= math.max(now, r)) {
        _downAt = leave;
        _downFrom = _windUp(leave);
        _downSpeed = v;
        _downFor = q;
        _rest = target;
        return leave + q;
      }
    }
  }

  /// Runs the wheel down to rest from where it is [now] seconds after the
  /// tap, with no prize to stop on: as long a run-down as its speed asks for,
  /// and never shorter than half a second.
  void stop({required double now}) {
    assert(!planned, 'a spin stops once');
    final v = _windUpSpeed(now);
    _downAt = now;
    _downFrom = _windUp(now);
    _downSpeed = v;
    _downFor = math.max(0.5, runDownFor * v / fullSpeed);
    _rest = _downFrom + v * _downFor * 0.4;
  }
}

/// How brightly the winning wedge is lit [v] of the way through the moment
/// the wheel stops on it: up at once, down, up again a little less, and then
/// held at a glow that stays until the next spin — two beats, then rest.
double luckyWedgeLight(double v) {
  double ease(double a, double b, double from, double to) {
    final x = ((v - a) / (b - a)).clamp(0.0, 1.0);
    return from + (to - from) * Motion.breathe.transform(x);
  }

  if (v <= 0) return 0;
  if (v < 0.18) return ease(0, 0.18, 0, 1);
  if (v < 0.40) return ease(0.18, 0.40, 1, 0.45);
  if (v < 0.58) return ease(0.40, 0.58, 0.45, 0.85);
  return ease(0.58, 1, 0.85, 0.35);
}

/// How the light round the wheel is set: breathing while a free spin waits,
/// bright while the wheel turns, low while it recharges.
enum LuckyWheelLight {
  /// A spin is due and the wheel is still: the light breathes, slowly.
  ready,

  /// The wheel is turning: the light is up, and still.
  spinning,

  /// The wheel is recharging: the light is down, and still.
  resting,
}

/// The wheel: [luckySpinnerAsset] with its turn taken over, a badge on each
/// wedge naming the prize it holds, and round it the stage it stands on — a
/// soft light round the rim, the stand's shadow on the floor, and a gold hub.
///
/// [angle] is the wheel's turn in degrees clockwise, 0 with slot 1 at the top;
/// the Lottie and the badges are drawn from the same figure, so the wedge the
/// needle points at and the prize written on it can never disagree. The
/// file's own spin is its layer 12, the one layer named `L` whose rotation is
/// keyframed (721° → 2526°); its other `L` layers stand at 0° or 20°, so a
/// rotation it reports of a turn or more is the wheel's, and is replaced by
/// [angle]. The layers named `S` — a currency glyph printed on the first
/// wedge, and the sparkles of the frames never played — are hidden.
///
/// The light and the shadow are drawn outside the wheel's own box, into the
/// panel round it: nothing is laid out for them.
class LuckyWheel extends StatefulWidget {
  const LuckyWheel({
    super.key,
    required this.slots,
    required this.angle,
    required this.height,
    this.won,
    this.lit,
    this.light = LuckyWheelLight.resting,
  });

  final List<LuckySlot> slots;
  final double angle;
  final double height;

  /// The slot just won, ringed in gold, its wedge lit; null while none is.
  final int? won;

  /// How far the moment of the win has run, from the stop (0) to its end (1):
  /// what lights the winning wedge ([luckyWedgeLight]). Null leaves the wedge
  /// at its resting glow.
  final Animation<double>? lit;

  /// How the light round the wheel is set.
  final LuckyWheelLight light;

  /// The wheel's width at [height], and its height at [width]: the window of
  /// the canvas it draws is a little taller than wide.
  static double widthFor(double height) =>
      height *
      LuckyWheelGeometry.window.width /
      LuckyWheelGeometry.window.height;
  static double heightFor(double width) =>
      width *
      LuckyWheelGeometry.window.height /
      LuckyWheelGeometry.window.width;

  /// Where slot [slotNumber]'s badge is centred, in the wheel's own box, with
  /// the wheel at [angle] and [height] tall.
  static Offset badgeCentre(int slotNumber, double angle, double height) {
    final k = height / LuckyWheelGeometry.window.height;
    final hub =
        (LuckyWheelGeometry.centre - LuckyWheelGeometry.window.topLeft) * k;
    final phi =
        (LuckyWheelGeometry.wedge * (slotNumber - 1) + angle) * math.pi / 180;
    final r = LuckyWheelGeometry.badgeRadius * k;
    return hub + Offset(r * math.sin(phi), -r * math.cos(phi));
  }

  /// The hub, in the wheel's own box.
  static Offset hubCentre(double height) =>
      (LuckyWheelGeometry.centre - LuckyWheelGeometry.window.topLeft) *
      (height / LuckyWheelGeometry.window.height);

  /// The rim's diameter at [height]: what the eye reads as the wheel's size.
  static double rimDiameter(double height) =>
      2 *
      LuckyWheelGeometry.rimRadius *
      height /
      LuckyWheelGeometry.window.height;

  @override
  State<LuckyWheel> createState() => _LuckyWheelState();
}

class _LuckyWheelState extends State<LuckyWheel> with TickerProviderStateMixin {
  /// The rim's lights, chasing for as long as the wheel is on screen: the
  /// file's own first five seconds, looped, whatever the wheel is doing.
  late final AnimationController _lights;
  late final Animation<double> _progress;

  /// The light round the rim breathing while a free spin waits: one slow
  /// swell every [Motion.breath], stopped whenever there is nothing to wait
  /// for — the wheel turning, or recharging — and with the widget.
  late final AnimationController _breath;

  /// Built once: a new [LottieDelegates] never compares equal to the last,
  /// and would have every key path resolved again on each build.
  late final LottieDelegates _delegates;

  @override
  void initState() {
    super.initState();
    _lights = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat();
    _progress = Tween<double>(
      begin: 0,
      end: LuckyWheelGeometry.loopEnd,
    ).animate(_lights);
    _breath = AnimationController(vsync: this, duration: Motion.breath);
    _breathe();
    _delegates = LottieDelegates(
      values: [
        ValueDelegate.transformRotation(
          const ['L'],
          callback: (info) {
            final own = info.startValue ?? 0;
            return own >= 360 ? widget.angle : own;
          },
        ),
        ValueDelegate.transformOpacity(const ['S'], value: 0),
        // The bulbs: the two precomps named `L` (layers 8 and 9), their one
        // layer `L`, its groups `G`, their fills `F`. The wheel's own shape
        // layers are named `L` too, but hold no layer `L`, so nothing of the
        // wedges' ivory is reached.
        ValueDelegate.color(
          const ['L', 'L', 'G', 'F'],
          callback: (info) =>
              luckyBulbColour(info.startValue ?? luckyBulbUnlit),
        ),
        // The hub: the precomp named `A` (layer 7), its one layer `L`, its
        // groups `G`, their fills `F`. The cream needle and cap are left out
        // and drawn again over the hub, in gold ([_HubPainter]).
        ValueDelegate.color(
          const ['A', 'L', 'G', 'F'],
          callback: (info) =>
              luckyHubColour(info.startValue ?? const Color(0x00000000)),
        ),
      ],
    );
  }

  @override
  void didUpdateWidget(LuckyWheel old) {
    super.didUpdateWidget(old);
    if (old.light != widget.light) _breathe();
  }

  void _breathe() {
    if (widget.light == LuckyWheelLight.ready) {
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
      _breath.stop();
    }
  }

  @override
  void dispose() {
    _lights.dispose();
    _breath.dispose();
    super.dispose();
  }

  /// The Lottie and the six badges, built once and handed back unchanged on
  /// every frame of a spin, so a frame only moves the badges — each behind a
  /// repaint boundary, so moving one is a new offset, not a new picture —
  /// and repaints the Lottie, whose turn it reads for itself.
  Widget? _art;
  double? _artFor;
  List<Widget>? _badges;
  (List<LuckySlot>, int?, double)? _badgesFor;

  Widget _artAt(double h) {
    if (_artFor == h && _art != null) return _art!;
    final k = h / LuckyWheelGeometry.window.height;
    final canvas = LuckyWheelGeometry.canvas * k;
    _artFor = h;
    return _art = Positioned(
      left: -LuckyWheelGeometry.window.left * k,
      top: -LuckyWheelGeometry.window.top * k,
      width: canvas,
      height: canvas,
      child: RepaintBoundary(
        child: Lottie.asset(
          luckySpinnerAsset,
          controller: _progress,
          delegates: _delegates,
          fit: BoxFit.fill,
          // Every frame, not the file's thirty: the turn is ours and runs at
          // the screen's rate. The wheel's own keyframes change on every one
          // of those frames, which is what repaints it — and each repaint
          // reads [LuckyWheel.angle] afresh.
          frameRate: FrameRate.max,
          errorBuilder: (context, error, stack) => const SizedBox.shrink(),
        ),
      ),
    );
  }

  List<Widget> _badgesAt(double badge) {
    final key = (widget.slots, widget.won, badge);
    if (_badgesFor == key && _badges != null) return _badges!;
    _badgesFor = key;
    return _badges = [
      for (final slot in widget.slots)
        RepaintBoundary(
          key: ValueKey('lucky-badge-${slot.slotNumber}'),
          child: _PrizeBadge(
            prize: slot.prize,
            // The empty slot is never ringed in gold: it won nothing.
            won: widget.won == slot.slotNumber && !slot.prize.isNothing,
          ),
        ),
    ];
  }

  /// Whether the slot the wheel stopped on is the empty one.
  bool get _wonNothing {
    for (final slot in widget.slots) {
      if (slot.slotNumber == widget.won) return slot.prize.isNothing;
    }
    return false;
  }

  double get _lightLevel => switch (widget.light) {
    LuckyWheelLight.ready => 1,
    LuckyWheelLight.spinning => 1.15,
    LuckyWheelLight.resting => 0.62,
  };

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    final k = h / LuckyWheelGeometry.window.height;
    final hub = LuckyWheel.hubCentre(h);
    final brightness = Theme.of(context).brightness;
    final badge = LuckyWheelGeometry.badgeSize * k;
    final badges = _badgesAt(badge);
    final won = widget.won;
    return SizedBox(
      key: const ValueKey('lucky-wheel'),
      width: LuckyWheel.widthFor(h),
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // The stage, under the wheel and outside its box: what it casts,
          // painted once, and the light round the rim in a layer of its own,
          // which repaints only while it breathes.
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _StageShadowPainter(
                    hub: hub,
                    k: k,
                    brightness: brightness,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey('lucky-wheel-light'),
                  painter: _StageLightPainter(
                    hub: hub,
                    k: k,
                    brightness: brightness,
                    level: _lightLevel,
                    breath: widget.light == LuckyWheelLight.ready
                        ? _breath
                        : null,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: ClipRect(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  _artAt(h),
                  if (won != null)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          key: const ValueKey('lucky-winning-wedge'),
                          painter: _WinningWedgePainter(
                            hub: hub,
                            k: k,
                            angle: widget.angle,
                            slot: won,
                            lit: widget.lit,
                            neutral: _wonNothing,
                          ),
                        ),
                      ),
                    ),
                  for (final (i, slot) in widget.slots.indexed)
                    _placed(
                      LuckyWheel.badgeCentre(slot.slotNumber, widget.angle, h),
                      badge,
                      badges[i],
                    ),
                ],
              ),
            ),
          ),
          // The hub, over everything that turns: it stands still.
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey('lucky-hub'),
                  painter: _HubPainter(hub: hub, k: k),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _placed(Offset centre, double size, Widget child) => Positioned(
    left: centre.dx - size / 2,
    top: centre.dy - size / 2,
    width: size,
    height: size,
    child: child,
  );
}

/// What the wheel casts: the stand's shadow on the floor under its foot and,
/// by day, the disc's own shadow — a pale panel has no dark to lose a gold
/// wheel in, and the shadow is what lifts it off. Still, so it is painted
/// once into a layer of its own.
class _StageShadowPainter extends CustomPainter {
  const _StageShadowPainter({
    required this.hub,
    required this.k,
    required this.brightness,
  });

  final Offset hub;

  /// Logical pixels to one unit of the file's canvas.
  final double k;
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    final dark = brightness == Brightness.dark;
    final shadow = AppTheme.shadowFor(brightness);
    final foot = Offset(
      hub.dx,
      hub.dy + (LuckyWheelGeometry.footY - LuckyWheelGeometry.centre.dy) * k,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: foot,
        width: LuckyWheelGeometry.footHalfWidth * 2.3 * k,
        height: 9 * k,
      ),
      Paint()
        ..color = shadow.withValues(alpha: dark ? 0.70 : 0.30)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 * k),
    );
    if (!dark) {
      canvas.drawCircle(
        hub + Offset(0, 5 * k),
        LuckyWheelGeometry.rimRadius * k,
        Paint()
          ..color = shadow.withValues(alpha: 0.20)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 9 * k),
      );
    }
  }

  @override
  bool shouldRepaint(_StageShadowPainter old) =>
      old.hub != hub || old.k != k || old.brightness != brightness;
}

/// The light round the rim, in the rim's own gold: brightest at the rim's
/// edge and gone a third of a rim further out (inside the rim it is under
/// the wheel). It breathes with [breath] while a free spin waits — a swell of
/// a sixth, no more — and is otherwise still, at [level].
class _StageLightPainter extends CustomPainter {
  _StageLightPainter({
    required this.hub,
    required this.k,
    required this.brightness,
    required this.level,
    this.breath,
  }) : super(repaint: breath);

  final Offset hub;
  final double k;
  final Brightness brightness;
  final double level;
  final Animation<double>? breath;

  /// The file's rim gold, #F5BA33: a shade deeper by day, warmer by night.
  static const _dayLight = Color(0xFFE9A92A);
  static const _nightLight = Color(0xFFF7C04A);

  @override
  void paint(Canvas canvas, Size size) {
    final dark = brightness == Brightness.dark;
    final swell = breath == null
        ? 1.0
        : 0.84 + 0.16 * Motion.breathe.transform(breath!.value);
    final reach = LuckyWheelGeometry.rimRadius * 1.34 * k;
    final alpha = ((dark ? 0.34 : 0.30) * level * swell).clamp(0.0, 1.0);
    final light = dark ? _nightLight : _dayLight;
    canvas.drawCircle(
      hub,
      reach,
      Paint()
        ..shader = ui.Gradient.radial(
          hub,
          reach,
          [
            light.withValues(alpha: alpha),
            light.withValues(alpha: alpha * 0.55),
            light.withValues(alpha: 0),
          ],
          const [0.72, 0.82, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_StageLightPainter old) =>
      old.hub != hub ||
      old.k != k ||
      old.brightness != brightness ||
      old.level != level ||
      old.breath != breath;
}

/// The winning wedge, lit: a warm gold light across it, brightest at the rim
/// — gold, not white, which on a red wedge read as pink — and a gold line
/// round it, at the brightness [luckyWedgeLight] gives for how far the moment
/// of the win has run ([lit]; at rest, its resting glow). The empty slot
/// ([neutral]) is only outlined, in a pale line: it is where the wheel
/// stopped, not something won.
class _WinningWedgePainter extends CustomPainter {
  _WinningWedgePainter({
    required this.hub,
    required this.k,
    required this.angle,
    required this.slot,
    this.lit,
    this.neutral = false,
  }) : super(repaint: lit);

  final Offset hub;
  final double k;
  final double angle;
  final int slot;
  final Animation<double>? lit;
  final bool neutral;

  @override
  void paint(Canvas canvas, Size size) {
    final i = luckyWedgeLight(lit?.value ?? 1);
    if (i <= 0) return;
    // Clockwise from the top, as the wedges are counted; the canvas counts
    // from three o'clock.
    final centreAngle =
        (LuckyWheelGeometry.wedge * (slot - 1) + angle - 90) * math.pi / 180;
    const half = math.pi / 6;
    final outer = LuckyWheelGeometry.wedgeRadius * k;
    final inner = (LuckyWheelGeometry.collarRadius + 1) * k;
    final path = Path()
      ..arcTo(
        Rect.fromCircle(center: hub, radius: outer),
        centreAngle - half,
        2 * half,
        true,
      )
      ..arcTo(
        Rect.fromCircle(center: hub, radius: inner),
        centreAngle + half,
        -2 * half,
        false,
      )
      ..close();
    if (!neutral) {
      canvas.drawPath(
        path,
        Paint()
          ..shader = ui.Gradient.radial(
            hub,
            outer,
            [
              const Color(0x00FFE9A6),
              const Color(0xFFFFE9A6).withValues(alpha: 0.34 * i),
              const Color(0xFFFFD457).withValues(alpha: 0.62 * i),
            ],
            const [0.2, 0.7, 1],
          ),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 1.8 * k
        ..color = (neutral ? Colors.white : AppTheme.goldBright).withValues(
          alpha: neutral ? 0.25 + 0.55 * i : 0.35 + 0.65 * i,
        ),
    );
  }

  @override
  bool shouldRepaint(_WinningWedgePainter old) =>
      old.hub != hub ||
      old.k != k ||
      old.angle != angle ||
      old.slot != slot ||
      old.lit != lit ||
      old.neutral != neutral;
}

/// The hub, struck in gold (26 Sep 2026, the Lucky Draw polish): the needle
/// in its place and shape — a teardrop from the hub to just short of the top
/// badge — lit from its left edge and outlined, casting a small shadow on the
/// wedges; over its foot a domed cap, lit from above left, with a fine dark
/// ring and a glint. It stands still while the wheel turns under it, as the
/// file's own needle did; the file's orange collar round it is the file's.
class _HubPainter extends CustomPainter {
  const _HubPainter({required this.hub, required this.k});

  final Offset hub;
  final double k;

  static const _edge = Color(0xFF6B4A0C);

  @override
  void paint(Canvas canvas, Size size) {
    // The needle.
    final tip = hub.dy - LuckyWheelGeometry.needleReach * k;
    final foot = hub.dy - 4 * k;
    final half = 7.4 * k;
    final needle = Path()
      ..moveTo(hub.dx, tip)
      ..cubicTo(
        hub.dx + half * 0.28,
        tip + 5 * k,
        hub.dx + half,
        foot - 12 * k,
        hub.dx + half,
        foot,
      )
      ..lineTo(hub.dx - half, foot)
      ..cubicTo(
        hub.dx - half,
        foot - 12 * k,
        hub.dx - half * 0.28,
        tip + 5 * k,
        hub.dx,
        tip,
      )
      ..close();
    canvas.drawPath(
      needle.shift(Offset(0, 1.6 * k)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.32)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 1.4 * k),
    );
    canvas.drawPath(
      needle,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(hub.dx - half, 0),
          Offset(hub.dx + half, 0),
          const [Color(0xFFFFEFB8), Color(0xFFE8B93A), Color(0xFFA9790F)],
          const [0, 0.45, 1],
        ),
    );
    canvas.drawPath(
      needle,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = 0.9 * k
        ..color = _edge.withValues(alpha: 0.9),
    );

    // The cap, over the needle's foot.
    final r = LuckyWheelGeometry.capRadius * k;
    canvas.drawCircle(
      hub + Offset(0, 1.4 * k),
      r,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 1.6 * k),
    );
    final cap = Rect.fromCircle(center: hub, radius: r);
    canvas.drawCircle(
      hub,
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.35, -0.45),
          radius: 1.05,
          colors: [
            Color(0xFFFFF7DA),
            Color(0xFFF1D27A),
            Color(0xFFD4A514),
            Color(0xFF9A6F10),
          ],
          stops: [0, 0.3, 0.72, 1],
        ).createShader(cap),
    );
    canvas.drawCircle(
      hub,
      r - 0.45 * k,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9 * k
        ..color = _edge.withValues(alpha: 0.85),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: hub + Offset(-3.8 * k, -4.8 * k),
        width: 6.6 * k,
        height: 3.8 * k,
      ),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 0.8 * k),
    );
  }

  @override
  bool shouldRepaint(_HubPainter old) => old.hub != hub || old.k != k;
}

/// A prize, written on its wedge: an ivory disc with a gold rim — the wheel's
/// wedges are red and white whatever the theme, so the disc is too — the
/// wallet's mark, and the figure under it.
class _PrizeBadge extends StatelessWidget {
  const _PrizeBadge({required this.prize, required this.won});

  final LuckyPrize prize;
  final bool won;

  static const _ivory = Color(0xFFFFF8E6);

  /// The won badge's light: a warm white, not the rim's gold, which on a red
  /// wedge glowed pink.
  static const _wonLight = Color(0xFFFFF1C2);

  @override
  Widget build(BuildContext context) {
    final figure = switch (prize.type) {
      LuckyReward.chips => formatChips(prize.amount),
      LuckyReward.diamond ||
      LuckyReward.hammer ||
      LuckyReward.missile => '${prize.amount}',
      _ => null,
    };
    return LayoutBuilder(
      builder: (context, box) {
        final d = box.biggest.shortestSide;
        return DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _ivory,
            border: Border.all(
              color: won ? AppTheme.goldBright : AppTheme.gold,
              width: won ? 2.5 : 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: won
                    ? _wonLight.withValues(alpha: 0.9)
                    : Colors.black.withValues(alpha: 0.28),
                blurRadius: won ? 12 : 3,
                spreadRadius: won ? 2 : 0,
                offset: won ? Offset.zero : const Offset(0, 1),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(d * 0.12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox.square(
                  dimension: d * (figure == null ? 0.62 : 0.4),
                  child: FittedBox(
                    child: LuckyPrizeGlyph(
                      prize: prize,
                      size: 24,
                      brightness: Brightness.light,
                    ),
                  ),
                ),
                if (figure != null)
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        figure,
                        maxLines: 1,
                        style: AppTheme.money(
                          const TextStyle(fontSize: 11, height: 1.1),
                          colour: AppTheme.goldDeep,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A small prize wheel — six wedges, alternately the ink and a wash of it,
/// under a needle — for the Lucky Draw's lobby key and its title. While a spin
/// is due it turns a third of a wheel now and then, as the bonus's hourglass
/// breathes when its bonus is ready; the wedges repeat every third of a turn,
/// so each turn ends looking exactly as it began.
class LuckyWheelGlyph extends StatefulWidget {
  const LuckyWheelGlyph({
    super.key,
    required this.colour,
    this.size = 18,
    this.turning = false,
  });

  final Color colour;
  final double size;
  final bool turning;

  @override
  State<LuckyWheelGlyph> createState() => _LuckyWheelGlyphState();
}

class _LuckyWheelGlyphState extends State<LuckyWheelGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    if (widget.turning) _c.repeat();
  }

  @override
  void didUpdateWidget(LuckyWheelGlyph old) {
    super.didUpdateWidget(old);
    if (widget.turning == old.turning) return;
    if (widget.turning) {
      _c.repeat();
    } else {
      _c
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        // A third of a turn over the first quarter of the cycle, then rest.
        final turn = Motion.standard.transform((_c.value / 0.25).clamp(0, 1));
        return CustomPaint(
          size: Size.square(widget.size),
          painter: _WheelGlyphPainter(
            colour: widget.colour,
            turn: turn * 2 * math.pi / 3,
          ),
        );
      },
    ),
  );
}

class _WheelGlyphPainter extends CustomPainter {
  const _WheelGlyphPainter({required this.colour, required this.turn});

  final Color colour;

  /// The wheel's turn, in radians.
  final double turn;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final centre = Offset(s / 2, s * 0.56);
    final r = s * 0.42;
    final full = Paint()..color = colour;
    final wash = Paint()..color = colour.withValues(alpha: 0.35);
    final rect = Rect.fromCircle(center: centre, radius: r);
    for (var i = 0; i < 6; i++) {
      canvas.drawArc(
        rect,
        -math.pi / 2 - math.pi / 6 + turn + i * math.pi / 3,
        math.pi / 3,
        true,
        i.isEven ? full : wash,
      );
    }
    canvas.drawCircle(
      centre,
      r,
      Paint()
        ..color = colour
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.06,
    );
    canvas.drawCircle(centre, s * 0.09, full);
    // The needle, standing still at the top.
    final top = centre.dy - r;
    canvas.drawPath(
      Path()
        ..moveTo(centre.dx - s * 0.11, top - s * 0.1)
        ..lineTo(centre.dx + s * 0.11, top - s * 0.1)
        ..lineTo(centre.dx, top + s * 0.1)
        ..close(),
      full,
    );
  }

  @override
  bool shouldRepaint(_WheelGlyphPainter old) =>
      old.colour != colour || old.turn != turn;
}
