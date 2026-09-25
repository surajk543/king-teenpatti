import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../widgets/glass_components.dart';
import '../widgets/lucky_prizes.dart';
import '../widgets/lucky_reveal.dart';
import '../widgets/lucky_spin_key.dart';
import '../widgets/lucky_wheel.dart';
import '../widgets/premium_surface.dart';

// The Lucky Draw's parts, where the lobby's key and the tests have always
// found them.
export '../widgets/lucky_prizes.dart';
export '../widgets/lucky_reveal.dart';
export '../widgets/lucky_spin_key.dart';
export '../widgets/lucky_wheel.dart';

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

  /// The key has been pressed: the wheel gathers speed while the server is
  /// asked. Nothing about its turn yet depends on the prize.
  asking,

  /// The server has drawn the slot: the wheel runs on and down onto it.
  turning,

  /// The server refused, or never answered: the wheel runs down with no
  /// prize, and the key comes back once it rests.
  stopping,

  /// At rest on the prize: its wedge and its tile are lit, for
  /// [LuckyDrawScreen.revealAfter], before the prize is shown.
  landed,

  /// The prize is on show.
  shown,
}

/// The Lucky Draw (owner, 24 Sep 2026): the wheel, its six prizes, and the key
/// that spins it, as [showLuckyDraw] opens it.
///
/// The client draws nothing. A tap asks the server to spin
/// ([GameState.spinLuckyDraw]) and starts the wheel gathering speed at once
/// (the polish of 26 Sep 2026: "start wheel acceleration" at the tap); the
/// server draws the slot, grants its prize and records the spin, and only its
/// answer decides where the wheel comes to rest — [LuckySpinMotion] runs it
/// down onto that slot along [LuckySpinCurve], about [spinTime] from the tap.
/// A refusal, or no answer, runs it down to rest with no prize and gives the
/// key back. At rest, the winning wedge and its tile are lit for
/// [revealAfter], and then the prize is shown.
class LuckyDrawScreen extends StatefulWidget {
  const LuckyDrawScreen({super.key});

  /// How long a spin takes from the tap to rest when the server answers at
  /// once (owner, 24 Sep 2026: "at least run for 5-6 seconds").
  static const Duration spinTime = luckySpinTime;

  /// How long the winning wedge and tile are lit, with the wheel at rest,
  /// before the prize is shown over them (the polish: "highlight the winning
  /// segment, highlight the corresponding reward card, show reward
  /// celebration").
  static const Duration revealAfter = Duration(milliseconds: 900);

  /// How long the lighting of the win runs, from the stop: two beats on the
  /// wedge and one swell of the tile, then their resting glow.
  static const Duration litFor = Duration(milliseconds: 1100);

  /// The panel at its largest: on a tablet the page stands in the middle of
  /// the room at a size a phone's hand still takes in, rather than stretching
  /// six prize tiles across a whole screen.
  static const Size largest = Size(1040, 640);

  @override
  State<LuckyDrawScreen> createState() => _LuckyDrawScreenState();
}

class _LuckyDrawScreenState extends State<LuckyDrawScreen>
    with TickerProviderStateMixin {
  /// The wheel's angle, in degrees clockwise: unbounded, driven through a
  /// spin by [LuckySpinMotion], and left where it rests.
  late final AnimationController _turn;

  /// The lighting of the win, from the stop ([LuckyDrawScreen.litFor]).
  late final AnimationController _lit;

  _Phase _phase = _Phase.idle;

  /// The spin being turned to or shown, and the slot it landed on, which
  /// stays lit until the next spin.
  LuckySpin? _spin;
  int? _won;

  /// Holds the prize back while the win is lit.
  Timer? _reveal;

  @override
  void initState() {
    super.initState();
    // Both made here, never lazily: a controller first read in dispose()
    // takes the teardown with it (CLAUDE.md §12.3).
    _turn = AnimationController.unbounded(vsync: this);
    _lit = AnimationController(vsync: this, duration: LuckyDrawScreen.litFor);
  }

  @override
  void dispose() {
    _reveal?.cancel();
    _turn.dispose();
    _lit.dispose();
    super.dispose();
  }

  double get _angle => _turn.value;

  /// Seconds since the spin began, as of the wheel's last frame.
  double get _elapsed =>
      (_turn.lastElapsedDuration?.inMicroseconds ?? 0) /
      Duration.microsecondsPerSecond;

  /// A spin is out: from the tap until its prize is shown (or the wheel is
  /// back at rest without one). The page stays open meanwhile.
  bool get _busy => switch (_phase) {
    _Phase.asking || _Phase.turning || _Phase.stopping || _Phase.landed => true,
    _Phase.idle || _Phase.shown => false,
  };

  Future<void> _spinNow() async {
    if (_phase != _Phase.idle) return;
    final state = context.read<GameState>();
    tapHaptic(context);
    _reveal?.cancel();
    _lit.value = 0;
    final motion = LuckySpinMotion(from: _angle % 360);
    setState(() {
      _phase = _Phase.asking;
      _won = null;
      _spin = null;
    });
    final turned = _turn.animateWith(motion);
    final spin = await state.spinLuckyDraw();
    if (!mounted) return;
    if (spin == null) {
      // Refused or never answered: the player has been told why, and the
      // wheel runs down from wherever it has got to, with no prize.
      motion.stop(now: _elapsed);
      setState(() => _phase = _Phase.stopping);
      await turned;
      if (!mounted) return;
      setState(() => _phase = _Phase.idle);
      return;
    }
    motion.landOn(
      slotNumber: spin.slotNumber,
      nudge: luckyNudge(spin.actionId),
      now: _elapsed,
    );
    setState(() {
      _spin = spin;
      _phase = _Phase.turning;
    });
    await turned;
    if (!mounted) return;
    setState(() {
      _won = spin.slotNumber;
      _phase = _Phase.landed;
    });
    unawaited(_lit.forward(from: 0));
    _reveal = Timer(LuckyDrawScreen.revealAfter, () {
      if (mounted && _phase == _Phase.landed) {
        setState(() => _phase = _Phase.shown);
      }
    });
  }

  void _closePrize() {
    if (_phase != _Phase.shown) return;
    // The wheel stays where it stopped, its slot lit until the next spin.
    setState(() => _phase = _Phase.idle);
  }

  LuckyWheelLight _light(bool due) => switch (_phase) {
    _Phase.asking ||
    _Phase.turning ||
    _Phase.stopping => LuckyWheelLight.spinning,
    _Phase.idle when due => LuckyWheelLight.ready,
    _ => LuckyWheelLight.resting,
  };

  @override
  Widget build(BuildContext context) {
    // Selected, never watched: the one-second tick would rebuild the whole
    // page. The wait counts down in the key alone ([LuckySpinKey]).
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    final draw = context.select<GameState, LuckyDrawState?>((s) => s.luckyDraw);
    final loading = context.select<GameState, bool>((s) => s.luckyDrawLoading);
    final failed = context.select<GameState, bool>((s) => s.luckyDrawFailed);
    final due = context.select<GameState, bool>(
      (s) => s.luckyDraw?.readyAt(DateTime.now()) ?? false,
    );
    final t = Strings(lang);
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final screen = MediaQuery.sizeOf(context);
    final short = Breaks.isShort(screen.height);
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkLowOn(b),
    );

    final days = (draw?.cooldownMs ?? 0) ~/ Duration.millisecondsPerDay;
    final hours =
        (draw?.cooldownMs ?? 0) %
        Duration.millisecondsPerDay ~/
        Duration.millisecondsPerHour;
    final every = days > 0 || hours > 0
        ? t.luckyEvery(t.rentalTerm(days, hours))
        : null;
    final free = due && _phase == _Phase.idle;

    final Widget body;
    if (draw == null) {
      body = _Absent(
        loading: loading,
        failed: failed,
        onRetry: context.read<GameState>().loadLuckyDraw,
      );
    } else {
      body = LayoutBuilder(
        builder: (context, box) {
          // The wheel takes the whole height, less what the prizes and the
          // key need beside it on a narrow phone.
          const columnFloor = 250.0;
          final roomForWheel = math.max(
            0.0,
            box.maxWidth - Space.xl - columnFloor,
          );
          final wheelH = math.min(
            box.maxHeight,
            LuckyWheel.heightFor(roomForWheel),
          );
          final keyH = (box.maxHeight * 0.19).clamp(
            Dim.minTouch + Space.xs,
            58.0,
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
                  lit: _lit,
                  light: _light(due),
                ),
              ),
              const SizedBox(width: Space.xl),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        t.luckyPrizes,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.label(
                          text.labelMedium!,
                          colour: theme.colorScheme.onSurface.withValues(
                            alpha: AppTheme.inkMed,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    Expanded(
                      child: LuckyPrizeGrid(
                        slots: draw.slots,
                        t: t,
                        won: _won,
                        lit: _lit,
                        showingWin:
                            _phase == _Phase.landed || _phase == _Phase.shown,
                      ),
                    ),
                    const SizedBox(height: Space.md),
                    LuckySpinKey(
                      spinning: _busy,
                      onSpin: _spinNow,
                      height: keyH,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      );
    }

    final titleStyle = AppTheme.label(
      (short ? text.titleMedium : text.titleLarge)!,
      weight: FontWeight.w700,
    );
    final header = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Dim.minTouch),
      child: Row(
        children: [
          LuckyWheelGlyph(colour: AppTheme.goldInk(b), size: 24, turning: free),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        t.luckyDrawTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: titleStyle,
                      ),
                    ),
                    if (free && draw != null) ...[
                      const SizedBox(width: Space.sm),
                      _FreeSpinTag(label: t.luckyFreeSpin),
                    ],
                  ],
                ),
                if (every != null)
                  Text(
                    every,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: quiet),
                  ),
              ],
            ),
          ),
          const SizedBox(width: Space.sm),
          PressScale(
            enabled: !_busy,
            child: IconButton(
              tooltip: t.close,
              onPressed: _busy ? null : () => Navigator.maybePop(context),
              icon: const Icon(Icons.close_rounded, size: 20),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size.square(Dim.minTouch),
              ),
            ),
          ),
        ],
      ),
    );

    return PopScope(
      // Not while the wheel turns: the prize is already the player's, and
      // closing now would only hide where it landed.
      canPop: !_busy,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints.loose(LuckyDrawScreen.largest),
              child: Stack(
                children: [
                  Positioned.fill(
                    // By day the card is laid on white of its own: the lobby
                    // must not show through a page that is being read.
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: dark ? null : AppTheme.panelBase(b),
                        borderRadius: BorderRadius.circular(Radii.lg),
                      ),
                      child: PremiumGlassPanel(
                        mode: GlassMode.auto,
                        priority: 20,
                        radius: Radii.lg,
                        // Obsidian glass over the dimmed lobby by night; by
                        // day the lobby's own card, warmed to a cream, since
                        // frosted milk over a dark scrim reads as grey, and
                        // the white prize tiles stand off the cream. A gold
                        // edge across the top either way, as a lobby card is
                        // lit along its top in its mode's colour.
                        surface: dark ? GlassSurface.pane : GlassSurface.card,
                        tint: dark ? null : AppTheme.gold,
                        edge: AppTheme.gold.withValues(
                          alpha: dark ? 0.42 : 0.6,
                        ),
                        padding: const EdgeInsets.fromLTRB(
                          Space.lg,
                          Space.md,
                          Space.lg,
                          Space.md,
                        ),
                        child: Column(
                          children: [
                            header,
                            const SizedBox(height: Space.sm),
                            Expanded(child: body),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_phase == _Phase.shown && _spin != null)
                    LuckyPrizeReveal(spin: _spin!, onClose: _closePrize),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "FREE SPIN" beside the title while a spin is due (26 Sep 2026, the Lucky
/// Draw polish: "Open this screen and immediately understand that I have a
/// free reward spin"): a small gold-edged tag, gone the moment the spin is
/// used, when the key starts counting down to the next.
class _FreeSpinTag extends StatelessWidget {
  const _FreeSpinTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gold = AppTheme.goldInk(theme.brightness);
    return Container(
      key: const ValueKey('lucky-free-spin'),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xxs,
      ),
      decoration: BoxDecoration(
        color: AppTheme.gold.withValues(
          alpha: theme.brightness == Brightness.dark ? 0.16 : 0.12,
        ),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: gold.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_rounded, size: 12, color: gold),
          const SizedBox(width: Space.xs),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.label(
                theme.textTheme.labelSmall!,
                colour: gold,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ],
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
