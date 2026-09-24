import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import '../widgets/avatar.dart';
import '../widgets/fireworks.dart';
import '../widgets/glass_components.dart';
import '../widgets/picture_shelf.dart';
import '../widgets/poker_chip.dart';
import '../widgets/premium_surface.dart';
import '../widgets/table_picture_shelf.dart';

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

  /// The part of the canvas drawn: the rim, the wheel and the stand, without
  /// the empty margin round them. The canvas is 300 square.
  static const Rect window = Rect.fromLTRB(25, 18, 275, 282);
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
/// [LuckyDrawScreen.spinTime] it takes a second and a half to reach full
/// speed — the first second covers a tenth of the turn — holds it for most
/// of a second, and runs down for three and a half, the last second
/// covering well under a hundredth.
///
/// It replaced a curve that left at full speed and slowed from the first
/// frame (the owner: "not smooth"): all but the first second was a crawl, and
/// that first second moved a wedge a frame, which on a wheel of six wedges
/// strobes. This one's full speed, five turns in six seconds, is under two
/// turns a second — a fifth of a wedge a frame at 60 fps.
class LuckySpinCurve extends Curve {
  const LuckySpinCurve({this.speedUp = 0.25, this.hold = 0.15});

  /// The shares of the run spent gathering speed, and at full speed; the
  /// rest is the run down.
  final double speedUp;
  final double hold;

  double get _runDown => 1 - speedUp - hold;

  /// The whole distance, in full-speed-by-time units: half the speed-up, all
  /// of the hold and two fifths of the run down.
  double get _whole => 0.5 * speedUp + hold + 0.4 * _runDown;

  /// The wheel's speed at [t], as a share of its full speed.
  double speedAt(double t) {
    if (t <= 0 || t >= 1) return 0;
    if (t < speedUp) {
      final x = t / speedUp;
      return x * x * (3 - 2 * x);
    }
    if (t <= speedUp + hold) return 1;
    final y = 1 - (t - speedUp - hold) / _runDown;
    return y * y * y * (4 - 3 * y);
  }

  @override
  double transformInternal(double t) {
    final double run;
    if (t <= speedUp) {
      final x = t / speedUp;
      // The integral of the smoothstep: x³ − x⁴/2.
      run = speedUp * (x * x * x - x * x * x * x / 2);
    } else if (t <= speedUp + hold) {
      run = 0.5 * speedUp + (t - speedUp);
    } else {
      final y = 1 - (t - speedUp - hold) / _runDown;
      // The integral of (1 − x)³(1 + 3x) from 0, with y = 1 − x.
      run =
          0.5 * speedUp +
          hold +
          _runDown * (0.4 - (y * y * y * y - 0.6 * y * y * y * y * y));
    }
    return run / _whole;
  }
}

/// "71:59:59" — the wait for the next spin as hours, minutes and seconds, the
/// hours running past 24 (a spin every three days waits up to 72 of them).
/// Rounded up, so it reads 00:00:00 only once the spin is due.
String formatSpinClock(Duration wait) {
  final ms = wait.inMilliseconds;
  final s = ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(s ~/ 3600)}:${two(s % 3600 ~/ 60)}:${two(s % 60)}';
}

/// What a prize is called: "10 Lakh chips", "5 diamonds", "4 hammers",
/// "2 missiles", a picture's name, "No prize".
String luckyPrizeLabel(Strings t, LuckyPrize prize) => switch (prize.type) {
  LuckyReward.chips => t.priceIn(
    PictureCurrency.coin,
    formatChips(prize.amount),
  ),
  LuckyReward.diamond => t.priceIn(
    PictureCurrency.diamond,
    formatChips(prize.amount),
  ),
  LuckyReward.hammer => t.priceIn(PictureCurrency.hammer, '${prize.amount}'),
  LuckyReward.missile => t.countMissiles(prize.amount),
  LuckyReward.profilePicture || LuckyReward.tablePicture => prize.pictureName,
  _ => t.luckyNoPrize,
};

/// Opens the Lucky Draw over the lobby, the way the store opens: a page of its
/// own, risen from the foot of the screen, which the back gesture closes.
Future<void> showLuckyDraw(BuildContext context) {
  // Read again as it opens: the wait, and which pictures are already the
  // player's, may have changed since sign-in.
  unawaited(context.read<GameState>().loadLuckyDraw());
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: AppTheme.ink900.withValues(alpha: 0.72),
    transitionDuration: Motion.enter,
    pageBuilder: (_, a, b) => const LuckyDrawScreen(),
    transitionBuilder: (context, anim, _, child) {
      final fade = Motion.standard.transform(anim.value);
      return Opacity(
        opacity: fade,
        child: Transform.translate(
          offset: Offset(0, 40 * (1 - fade)),
          child: child,
        ),
      );
    },
  );
}

enum _Phase {
  /// Nothing under way: the key spins when the wheel is due.
  idle,

  /// The spin is with the server. The wheel has not moved: it turns only once
  /// the server has said where to.
  asking,

  /// The wheel is turning to the slot the server drew.
  turning,

  /// It has stopped, and the prize is on show.
  shown,
}

/// The Lucky Draw (owner, 24 Sep 2026): the wheel, its six prizes, and the key
/// that spins it, as [showLuckyDraw] opens it.
///
/// The client draws nothing. A tap asks the server to spin
/// ([GameState.spinLuckyDraw]); the server draws the slot, grants the prize and
/// records the spin, and only then does the wheel turn — [spinTime], five
/// turns and on to the slot it answered, along [LuckySpinCurve] — and the
/// prize is shown.
class LuckyDrawScreen extends StatefulWidget {
  const LuckyDrawScreen({super.key});

  /// How long the wheel turns once the server has answered (owner, 24 Sep
  /// 2026: "at least run for 5-6 seconds").
  static const Duration spinTime = Duration(seconds: 6);

  @override
  State<LuckyDrawScreen> createState() => _LuckyDrawScreenState();
}

class _LuckyDrawScreenState extends State<LuckyDrawScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn;

  static const _spinCurve = LuckySpinCurve();

  _Phase _phase = _Phase.idle;

  /// The wheel's turn is [_from] to [_to], in degrees clockwise, along
  /// [_spinCurve]; at rest the two are equal.
  double _from = 0;
  double _to = 0;

  /// The spin being turned to or shown, and the slot it landed on, which
  /// stays ringed until the next spin.
  LuckySpin? _spin;
  int? _won;

  @override
  void initState() {
    super.initState();
    _turn = AnimationController(
      vsync: this,
      duration: LuckyDrawScreen.spinTime,
    );
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  double get _angle =>
      _from + (_to - _from) * _spinCurve.transform(_turn.value);

  bool get _busy => _phase == _Phase.asking || _phase == _Phase.turning;

  Future<void> _spinNow(GameState state) async {
    if (_phase != _Phase.idle) return;
    tapHaptic(context);
    setState(() => _phase = _Phase.asking);
    final spin = await state.spinLuckyDraw();
    if (!mounted) return;
    if (spin == null) {
      // Refused or never answered: the player has been told, and the wheel
      // has not moved.
      setState(() => _phase = _Phase.idle);
      return;
    }
    final from = _angle % 360;
    setState(() {
      _spin = spin;
      _won = null;
      _from = from;
      _to = luckySpinTarget(
        from: from,
        slotNumber: spin.slotNumber,
        nudge: luckyNudge(spin.actionId),
      );
      _phase = _Phase.turning;
    });
    await _turn.forward(from: 0);
    if (!mounted) return;
    setState(() {
      _won = spin.slotNumber;
      _phase = _Phase.shown;
    });
  }

  void _closePrize() {
    if (_phase != _Phase.shown) return;
    setState(() {
      // The wheel stays where it stopped.
      _from = _to = _to % 360;
      _turn.value = 0;
      _phase = _Phase.idle;
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkLow,
    );
    final draw = state.luckyDraw;
    final now = DateTime.now();
    final due = draw != null && draw.readyAt(now);

    final days = (draw?.cooldownMs ?? 0) ~/ Duration.millisecondsPerDay;
    final hours =
        (draw?.cooldownMs ?? 0) %
        Duration.millisecondsPerDay ~/
        Duration.millisecondsPerHour;
    final every = days > 0 || hours > 0
        ? t.luckyEvery(t.rentalTerm(days, hours))
        : null;

    final Widget body;
    if (draw == null) {
      body = _Absent(
        loading: state.luckyDrawLoading,
        failed: state.luckyDrawFailed,
        onRetry: state.loadLuckyDraw,
      );
    } else {
      body = LayoutBuilder(
        builder: (context, box) {
          // The wheel takes the whole height, less what the prizes and the
          // key need beside it on a narrow phone.
          const columnFloor = 250.0;
          final roomForWheel = math.max(
            0.0,
            box.maxWidth - Space.lg - columnFloor,
          );
          final wheelH = math.min(
            box.maxHeight,
            LuckyWheel.heightFor(roomForWheel),
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AnimatedBuilder(
                animation: _turn,
                builder: (context, _) => LuckyWheel(
                  slots: draw.slots,
                  angle: _angle,
                  height: wheelH,
                  won: _won,
                ),
              ),
              const SizedBox(width: Space.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      t.luckyPrizes,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.label(text.labelSmall!, colour: quiet),
                    ),
                    const SizedBox(height: Space.sm),
                    Expanded(
                      child: _SlotGrid(slots: draw.slots, won: _won),
                    ),
                    const SizedBox(height: Space.md),
                    _SpinKey(
                      phase: _phase,
                      due: due,
                      wait: draw.untilNext(now),
                      onSpin: () => _spinNow(state),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      );
    }

    final titleStyle = AppTheme.label(text.titleMedium ?? const TextStyle());
    return PopScope(
      // Not while the wheel turns: the prize is already the player's, and
      // closing now would only hide where it landed.
      canPop: !_busy,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Stack(
            children: [
              Positioned.fill(
                child: PremiumGlassPanel(
                  mode: GlassMode.auto,
                  priority: 20,
                  radius: Radii.lg,
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    Space.md,
                    Space.lg,
                    Space.lg,
                  ),
                  child: Column(
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          minHeight: Dim.minTouch,
                        ),
                        child: Row(
                          children: [
                            LuckyWheelGlyph(
                              colour: AppTheme.goldBright,
                              size: 22,
                              turning: due && !_busy,
                            ),
                            const SizedBox(width: Space.md),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    t.luckyDrawTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: titleStyle,
                                  ),
                                  if (every != null)
                                    Text(
                                      every,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: text.bodySmall?.copyWith(
                                        color: quiet,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: Space.sm),
                            PressScale(
                              enabled: !_busy,
                              child: IconButton(
                                tooltip: t.close,
                                onPressed: _busy
                                    ? null
                                    : () => Navigator.maybePop(context),
                                icon: const Icon(Icons.close_rounded, size: 20),
                                style: IconButton.styleFrom(
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  minimumSize: const Size.square(Dim.minTouch),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: Space.md),
                      Expanded(child: body),
                    ],
                  ),
                ),
              ),
              if (_phase == _Phase.shown && _spin != null)
                _LuckyPrizeCard(spin: _spin!, onClose: _closePrize),
            ],
          ),
        ),
      ),
    );
  }
}

/// No wheel to show: still being read, not read, or no draw open.
class _Absent extends StatelessWidget {
  const _Absent({
    required this.loading,
    required this.failed,
    required this.onRetry,
  });

  final bool loading;
  final bool failed;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.read<GameState>().t;
    final theme = Theme.of(context);
    if (loading) {
      return const Center(child: CircularProgressIndicator.adaptive());
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            failed ? t.luckyLoadFailed : t.luckyClosed,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(
                alpha: AppTheme.inkMed,
              ),
            ),
          ),
          if (failed) ...[
            const SizedBox(height: Space.md),
            GlassButton(
              style: GlassButtonStyle.glass,
              label: t.luckyRetry,
              onPressed: onRetry,
            ),
          ],
        ],
      ),
    );
  }
}

/// The wheel: [luckySpinnerAsset] with its turn taken over, and a badge on
/// each wedge naming the prize it holds.
///
/// [angle] is the wheel's turn in degrees clockwise, 0 with slot 1 at the top;
/// the Lottie and the badges are drawn from the same figure, so the wedge the
/// needle points at and the prize written on it can never disagree. The
/// file's own spin is its layer 12, the one layer named `L` whose rotation is
/// keyframed (721° → 2526°); its other `L` layers stand at 0° or 20°, so a
/// rotation it reports of a turn or more is the wheel's, and is replaced by
/// [angle]. The layers named `S` — a currency glyph printed on the first
/// wedge, and the sparkles of the frames never played — are hidden.
class LuckyWheel extends StatefulWidget {
  const LuckyWheel({
    super.key,
    required this.slots,
    required this.angle,
    required this.height,
    this.won,
  });

  final List<LuckySlot> slots;
  final double angle;
  final double height;

  /// The slot just won, ringed in gold; null while none is.
  final int? won;

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

  @override
  State<LuckyWheel> createState() => _LuckyWheelState();
}

class _LuckyWheelState extends State<LuckyWheel>
    with SingleTickerProviderStateMixin {
  /// The rim's lights, chasing for as long as the wheel is on screen: the
  /// file's own first five seconds, looped, whatever the wheel is doing.
  late final AnimationController _lights;
  late final Animation<double> _progress;

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
      ],
    );
  }

  @override
  void dispose() {
    _lights.dispose();
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
            won: widget.won == slot.slotNumber,
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    final badge =
        LuckyWheelGeometry.badgeSize * (h / LuckyWheelGeometry.window.height);
    final badges = _badgesAt(badge);
    return SizedBox(
      key: const ValueKey('lucky-wheel'),
      width: LuckyWheel.widthFor(h),
      height: h,
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            _artAt(h),
            for (final (i, slot) in widget.slots.indexed)
              _placed(
                LuckyWheel.badgeCentre(slot.slotNumber, widget.angle, h),
                badge,
                badges[i],
              ),
          ],
        ),
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

/// A prize, written on its wedge: an ivory disc with a gold rim — the wheel's
/// wedges are red and white whatever the theme, so the disc is too — the
/// wallet's mark, and the figure under it.
class _PrizeBadge extends StatelessWidget {
  const _PrizeBadge({required this.prize, required this.won});

  final LuckyPrize prize;
  final bool won;

  static const _ivory = Color(0xFFFFF8E6);

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
                    ? AppTheme.goldBright.withValues(alpha: 0.85)
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

/// A prize's mark: the wallet it fills, drawn as the top bar and the store draw
/// that wallet, or the picture itself.
class LuckyPrizeGlyph extends StatelessWidget {
  const LuckyPrizeGlyph({
    super.key,
    required this.prize,
    required this.size,
    this.brightness,
    this.animate = false,
  });

  final LuckyPrize prize;
  final double size;

  /// The ground the mark sits on, when it is not the theme's (the wheel's
  /// ivory badges).
  final Brightness? brightness;

  /// Whether an animated picture plays.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final b = brightness ?? Theme.of(context).brightness;
    final picture = prize.picture;
    return switch (prize.type) {
      LuckyReward.chips => PokerChip(colour: AppTheme.gold, size: size),
      LuckyReward.diamond => Icon(
        Icons.diamond_rounded,
        size: size,
        color: diamondInkOn(b),
      ),
      LuckyReward.hammer => Icon(
        Icons.hardware,
        size: size,
        color: hammerInkOn(b),
      ),
      LuckyReward.missile => Icon(
        missileIcon,
        size: size,
        color: missileInkOn(b),
      ),
      LuckyReward.profilePicture when picture != null => Avatar(
        url: context.read<GameState>().absoluteUrl(picture.url),
        format: picture.assetFormat,
        fallback: picture.name,
        radius: size / 2,
        animate: animate,
      ),
      LuckyReward.profilePicture => Icon(
        Icons.face_rounded,
        size: size,
        color: AppTheme.goldDeep,
      ),
      LuckyReward.tablePicture => Icon(
        Icons.table_bar_rounded,
        size: size,
        color: b == Brightness.dark ? AppTheme.goldBright : AppTheme.goldDeep,
      ),
      _ => Icon(
        Icons.sentiment_neutral_rounded,
        size: size,
        color: b == Brightness.dark ? Colors.white54 : Colors.black45,
      ),
    };
  }
}

/// The six prizes, two to a row in wheel order — slot 1 and 2, 3 and 4, 5 and
/// 6 — the slot just won ringed in gold.
class _SlotGrid extends StatelessWidget {
  const _SlotGrid({required this.slots, required this.won});

  final List<LuckySlot> slots;
  final int? won;

  @override
  Widget build(BuildContext context) {
    Widget cell(int i) => i < slots.length
        ? _SlotTile(
            key: ValueKey('lucky-slot-${slots[i].slotNumber}'),
            slot: slots[i],
            won: won == slots[i].slotNumber,
          )
        : const SizedBox.shrink();
    final rows = (slots.length / 2).ceil().clamp(1, 3);
    return Column(
      children: [
        for (var row = 0; row < rows; row++) ...[
          if (row > 0) const SizedBox(height: Space.sm),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: cell(2 * row)),
                const SizedBox(width: Space.sm),
                Expanded(child: cell(2 * row + 1)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _SlotTile extends StatelessWidget {
  const _SlotTile({super.key, required this.slot, required this.won});

  final LuckySlot slot;
  final bool won;

  @override
  Widget build(BuildContext context) {
    final state = context.read<GameState>();
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final glass = GlassColors.of(context);
    final gold = theme.brightness == Brightness.dark
        ? AppTheme.goldBright
        : AppTheme.goldDeep;
    return AnimatedContainer(
      duration: Motion.base,
      curve: Motion.standard,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.md),
        color: won ? gold.withValues(alpha: 0.16) : glass.fill,
        border: Border.all(
          color: won
              ? gold
              : AppTheme.hairlineColour(theme.brightness, live: false),
          width: won ? 2 : Dim.hairline,
        ),
      ),
      child: Row(
        children: [
          // The slot's number, as the wheel counts it from the top.
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: gold.withValues(alpha: won ? 0.9 : 0.22),
            ),
            child: Text(
              '${slot.slotNumber}',
              style: AppTheme.money(
                text.labelSmall!,
                fontSize: 10,
                colour: won
                    ? theme.colorScheme.surface
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: Space.sm),
          LuckyPrizeGlyph(prize: slot.prize, size: 22),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              luckyPrizeLabel(state.t, slot.prize),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.label(
                text.labelMedium!,
                colour: slot.prize.isNothing
                    ? theme.colorScheme.onSurface.withValues(
                        alpha: AppTheme.inkLow,
                      )
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// SPIN NOW while a spin is due; SPINNING… from the tap until the prize is
/// on show; NEXT SPIN and the time left while the wheel recharges. Only the
/// first can be pressed, and the server checks it again all the same.
class _SpinKey extends StatelessWidget {
  const _SpinKey({
    required this.phase,
    required this.due,
    required this.wait,
    required this.onSpin,
  });

  final _Phase phase;
  final bool due;
  final Duration wait;
  final VoidCallback onSpin;

  @override
  Widget build(BuildContext context) {
    final t = context.read<GameState>().t;
    final text = Theme.of(context).textTheme;
    final spinning = phase == _Phase.asking || phase == _Phase.turning;
    final canSpin = due && phase == _Phase.idle;
    final Widget label;
    if (spinning) {
      label = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Text(
              t.luckySpinning,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    } else if (due) {
      label = Text(
        t.luckySpinNow,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    } else {
      label = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            t.luckyNextSpin,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.label(
              TextStyle(fontSize: text.labelSmall?.fontSize ?? 11),
            ),
          ),
          Text(
            formatSpinClock(wait),
            key: const ValueKey('lucky-next-spin'),
            maxLines: 1,
            style: AppTheme.money(
              TextStyle(fontSize: text.titleMedium?.fontSize ?? 16),
            ),
          ),
        ],
      );
    }
    return GlassButton(
      key: const ValueKey('lucky-spin'),
      style: GlassButtonStyle.primary,
      expand: true,
      minimumSize: const Size.fromHeight(52),
      onPressed: canSpin ? onSpin : null,
      child: label,
    );
  }
}

/// The prize, once the wheel has stopped on it: fireworks, the prize as its
/// wallet or its picture, and what it means — or, on the empty slot, better
/// luck next time. Built from the lobby's reward celebration, so a prize won
/// here looks like every other the game hands out.
class _LuckyPrizeCard extends StatelessWidget {
  const _LuckyPrizeCard({required this.spin, required this.onClose});

  final LuckySpin spin;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final size = MediaQuery.sizeOf(context);
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkMed,
    );
    final prize = spin.prize;
    final nothing = prize.isNothing;
    final hero = (size.height * 0.16).clamp(40.0, 68.0);
    final padV = (size.height * 0.055).clamp(16.0, 28.0);
    final padH = (size.height * 0.085).clamp(24.0, 44.0);
    final gold = theme.brightness == Brightness.dark
        ? AppTheme.goldBright
        : AppTheme.goldDeep;
    final ink = switch (prize.type) {
      LuckyReward.diamond => diamondInkOn(theme.brightness),
      LuckyReward.hammer => hammerInkOn(theme.brightness),
      LuckyReward.missile => missileInkOn(theme.brightness),
      _ => gold,
    };

    final picture = prize.picture;
    final table = prize.tablePicture;
    final Widget heroMark = switch (prize.type) {
      LuckyReward.chips => SpinningChip(
        colour: AppTheme.gold,
        size: hero,
        turn: const Duration(milliseconds: 900),
        rest: const Duration(milliseconds: 260),
      ),
      LuckyReward.tablePicture when table != null => SizedBox(
        width: hero * 2.4,
        height: hero * 1.35,
        child: TablePicturePreview(
          dayUrl: state.absoluteUrl(table.dayUrl) ?? '',
          nightUrl: state.absoluteUrl(table.nightUrl) ?? '',
          format: table.assetFormat,
        ),
      ),
      LuckyReward.profilePicture when picture != null => Avatar(
        url: state.absoluteUrl(picture.url),
        format: picture.assetFormat,
        fallback: picture.name,
        radius: hero * 0.75,
        ring: AppTheme.goldBright,
        ringWidth: 2.5,
        ringGap: 3,
        animate: true,
      ),
      _ => LuckyPrizeGlyph(prize: prize, size: hero),
    };

    // A picture's term: the shop's own, from now — or, for one they had, that
    // nothing changed.
    // The picture's term, the shop's own, counted from the spin.
    final term = switch ((picture, table)) {
      (final p?, _) => (p.rented, p.durationDays, p.durationHours),
      (_, final p?) => (p.rented, p.durationDays, p.durationHours),
      _ => null,
    };
    final termLine = term == null
        ? null
        : spin.alreadyOwned
        ? t.luckyAlreadyOwned
        : term.$1
        ? t.luckyPictureFor(t.rentalTerm(term.$2, term.$3))
        : t.pictureKeeps;

    // Put on now, if it is not on already. Winning never puts it on.
    final canWear =
        picture != null && state.user?.activePictureId != picture.id;
    final canLay =
        table != null && state.user?.activeTablePictureId != table.id;

    return Positioned.fill(
      child: GestureDetector(
        onTap: onClose,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.lg),
          child: ColoredBox(
            color: theme.colorScheme.scrim.withValues(alpha: 0.70),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (!nothing)
                  Fireworks(seed: spin.actionId.hashCode, bursts: 7),
                Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: Dim.dialogW(size.width),
                    ),
                    child: TweenAnimationBuilder<double>(
                      key: ValueKey('lucky-result-${spin.actionId}'),
                      tween: Tween(begin: 0, end: 1),
                      duration: Motion.arrive,
                      builder: (context, v, child) => Opacity(
                        opacity: Curves.easeOut.transform(v),
                        child: Transform.scale(
                          scale: 0.82 + 0.18 * Motion.settle.transform(v),
                          child: child,
                        ),
                      ),
                      child: PremiumSurface(
                        key: const ValueKey('lucky-result'),
                        accent: AppTheme.gold,
                        radius: Radii.lg,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(padH, padV, padH, padV),
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                heroMark,
                                const SizedBox(height: Space.md),
                                Text(
                                  nothing
                                      ? t.luckyNothingTitle
                                      : t.luckyCongrats,
                                  textAlign: TextAlign.center,
                                  style: AppTheme.label(text.titleMedium!),
                                ),
                                const SizedBox(height: Space.xs),
                                if (nothing)
                                  Text(
                                    t.luckyNothingBody,
                                    textAlign: TextAlign.center,
                                    style: text.bodyMedium?.copyWith(
                                      color: quiet,
                                    ),
                                  )
                                else ...[
                                  Text(
                                    t.luckyYouWon,
                                    textAlign: TextAlign.center,
                                    style: AppTheme.label(
                                      text.labelMedium!,
                                      colour: quiet,
                                    ),
                                  ),
                                  const SizedBox(height: Space.xs),
                                  Text(
                                    luckyPrizeLabel(t, prize),
                                    key: const ValueKey('lucky-result-prize'),
                                    textAlign: TextAlign.center,
                                    style: AppTheme.money(
                                      text.headlineSmall!,
                                      colour: ink,
                                    ),
                                  ),
                                  if (prize.isPicture)
                                    Text(
                                      prize.type == LuckyReward.profilePicture
                                          ? t.luckyProfilePicture
                                          : t.luckyTablePicture,
                                      textAlign: TextAlign.center,
                                      style: AppTheme.label(
                                        text.labelMedium!,
                                        colour: quiet,
                                      ),
                                    ),
                                  if (termLine != null) ...[
                                    const SizedBox(height: Space.sm),
                                    Text(
                                      termLine,
                                      textAlign: TextAlign.center,
                                      style: text.bodyMedium?.copyWith(
                                        color: quiet,
                                      ),
                                    ),
                                  ],
                                ],
                                const SizedBox(height: Space.lg),
                                Wrap(
                                  alignment: WrapAlignment.center,
                                  spacing: Space.md,
                                  runSpacing: Space.sm,
                                  children: [
                                    GlassButton(
                                      style: canWear || canLay
                                          ? GlassButtonStyle.text
                                          : GlassButtonStyle.primary,
                                      label: t.close,
                                      onPressed: onClose,
                                    ),
                                    if (canWear)
                                      GlassButton(
                                        style: GlassButtonStyle.primary,
                                        label: t.luckyWearNow,
                                        onPressed: () {
                                          onClose();
                                          state.chooseAvatar(picture.id);
                                        },
                                      ),
                                    if (canLay)
                                      GlassButton(
                                        style: GlassButtonStyle.primary,
                                        label: t.luckyLayNow,
                                        onPressed: () {
                                          onClose();
                                          state.chooseTablePicture(table.id);
                                        },
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
