import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'glass_components.dart';
import 'lucky_wheel.dart';

/// "71:59:59" — the wait for the next spin as hours, minutes and seconds, the
/// hours running past 24 (a spin every three days waits up to 72 of them).
/// Rounded up, so it reads 00:00:00 only once the spin is due.
String formatSpinClock(Duration wait) {
  final ms = wait.inMilliseconds;
  final s = ms <= 0 ? 0 : (ms + 999) ~/ 1000;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(s ~/ 3600)}:${two(s % 3600 ~/ 60)}:${two(s % 60)}';
}

/// A key struck in gold (26 Sep 2026, the Lucky Draw polish: "premium
/// gold/yellow CTA … soft glow, strong readable typography, slight elevation,
/// good press animation"): the Shop key's and the table's Chaal face
/// ([AppTheme.goldFace]) with the lit top edge of struck metal, lifted on the
/// app's control shadow with a gold bloom under it, charcoal words, and the
/// press-down every key has ([PressScale]). The one gold key on its screen —
/// the Lucky Draw's Spin, or the prize's own action.
///
/// [onTap] is the caller's and is called as it is; the haptic is the
/// caller's too.
class LuckyGoldKey extends StatelessWidget {
  const LuckyGoldKey({
    super.key,
    required this.label,
    required this.onTap,
    this.glyph,
    this.height = Dim.minTouch,
    this.style,
    this.expand = false,
  });

  final String label;
  final VoidCallback onTap;

  /// A mark before the words, drawn in [AppTheme.inkOnLight].
  final Widget? glyph;
  final double height;

  /// The words' style; the theme's label size, bold, in charcoal by default.
  final TextStyle? style;

  /// Stretches the key to its parent's width.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(Radii.md);
    final words = AppTheme.label(
      style ?? theme.textTheme.labelLarge ?? const TextStyle(),
      colour: AppTheme.inkOnLight,
      weight: FontWeight.w700,
    );
    Widget key = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: AppTheme.controlShadow(
          theme.brightness,
          elevation: 4,
          bloom: AppTheme.gold,
        ),
      ),
      child: PressScale(
        haptic: false,
        scale: 0.96,
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: Ink(
            decoration: BoxDecoration(
              gradient: AppTheme.goldFace,
              borderRadius: radius,
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.55)),
              ),
            ),
            child: InkWell(
              enableFeedback: soundOn(context),
              onTap: onTap,
              splashColor: AppTheme.inkOnLight.withValues(alpha: 0.16),
              highlightColor: AppTheme.inkOnLight.withValues(alpha: 0.08),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: height),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.lg),
                  child: Row(
                    mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (glyph != null) ...[
                        glyph!,
                        const SizedBox(width: Space.sm),
                      ],
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: words,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (expand) key = SizedBox(width: double.infinity, child: key);
    // A button, named by its own words, as Material's keys are.
    return Semantics(container: true, button: true, enabled: true, child: key);
  }
}

/// The Lucky Draw's key (26 Sep 2026, the polish: "the strongest element on
/// the screen after the wheel"): SPIN NOW in struck gold while a spin is due;
/// SPINNING… from the tap until the prize is on show; NEXT FREE SPIN over the
/// time left while the wheel recharges. Only the first can be pressed, and
/// the server checks it again all the same.
///
/// The two keys that cannot be pressed are the plaque every idle key on the
/// table is, with a gold hairline, and their words still read in full: the
/// gold face, its bloom and its glyph are what say "press", and they go.
///
/// The wait is the server's: [GameState.luckyDraw]'s `nextSpinAt`, taken
/// from the draw, a spin or a refusal. This key watches the state, so the
/// one-second tick counts it down here and nowhere else on the screen.
class LuckySpinKey extends StatelessWidget {
  const LuckySpinKey({
    super.key,
    required this.spinning,
    required this.onSpin,
    required this.height,
  });

  /// A spin is under way, from the tap until its prize is on show.
  final bool spinning;
  final VoidCallback onSpin;
  final double height;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final gold = AppTheme.goldInk(b);
    final draw = state.luckyDraw;
    final now = DateTime.now();
    final due = draw != null && draw.readyAt(now);
    final short = Breaks.isShort(MediaQuery.sizeOf(context).height);

    if (!spinning && due) {
      return LuckyGoldKey(
        key: const ValueKey('lucky-spin'),
        label: t.luckySpinNow,
        onTap: onSpin,
        height: height,
        expand: true,
        style: text.titleMedium,
        glyph: const LuckyWheelGlyph(
          colour: AppTheme.inkOnLight,
          size: 22,
          turning: true,
        ),
      );
    }

    final Widget words;
    final String said;
    if (spinning) {
      said = t.luckySpinning;
      words = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: gold),
          ),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Text(
              t.luckySpinning,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.label(
                text.titleSmall!,
                colour: gold,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ],
      );
    } else {
      final clock = formatSpinClock(draw?.untilNext(now) ?? Duration.zero);
      said = '${t.luckyNextFreeSpin} $clock';
      words = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.hourglass_bottom_rounded,
            size: 18,
            color: theme.colorScheme.onSurface.withValues(
              alpha: AppTheme.inkMed,
            ),
          ),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.luckyNextFreeSpin,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.label(
                    text.labelMedium!,
                    colour: theme.colorScheme.onSurface.withValues(
                      alpha: AppTheme.inkMed,
                    ),
                  ),
                ),
                Text(
                  clock,
                  key: const ValueKey('lucky-next-spin'),
                  maxLines: 1,
                  style: AppTheme.money(
                    (short ? text.titleMedium : text.titleLarge)!,
                    colour: gold,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Semantics(
      key: const ValueKey('lucky-spin'),
      button: true,
      enabled: false,
      label: said,
      child: ExcludeSemantics(
        child: Container(
          constraints: BoxConstraints(minHeight: height),
          width: double.infinity,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          decoration: BoxDecoration(
            color: AppTheme.plaque(b),
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(
              color: AppTheme.hairlineColour(b, live: true),
              width: Dim.hairline,
            ),
          ),
          child: words,
        ),
      ),
    );
  }
}
