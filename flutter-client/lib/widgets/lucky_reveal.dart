import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'avatar.dart';
import 'fireworks.dart';
import 'glass_components.dart';
import 'lucky_prizes.dart';
import 'lucky_spin_key.dart';
import 'poker_chip.dart';
import 'premium_surface.dart';
import 'table_picture_shelf.dart';

/// The prize, once the wheel has stopped on it and the winning wedge and tile
/// have been lit: fireworks, the prize as its wallet or its picture over a
/// gold light, what it is — its figure first — and what it means; or, on the
/// empty slot, better luck next time, quietly. Built from the lobby's reward
/// celebration (a scrim, [Fireworks], [PremiumSurface]), so a prize won here
/// looks like every other the game hands out.
///
/// It arrives as a small celebration (26 Sep 2026, the Lucky Draw polish:
/// "fade in, scale from 0.9 → 1.0, small glow, reward icon emphasis"): the
/// card fades up from nine tenths of its size and settles, the light behind
/// the mark swells, and the mark pops in a beat after it. The empty slot's
/// card comes the same way with no overshoot, no light and no fireworks, its
/// face tilting once, as a shrug. A tap anywhere closes it.
class LuckyPrizeReveal extends StatelessWidget {
  const LuckyPrizeReveal({
    super.key,
    required this.spin,
    required this.onClose,
  });

  final LuckySpin spin;
  final VoidCallback onClose;

  /// How long the card takes to arrive, and its mark to pop in after it.
  static const Duration arrival = Motion.arrive;
  static const Duration pop = Duration(milliseconds: 820);

  @override
  Widget build(BuildContext context) {
    // Selected, not watched: the one-second tick changes nothing here.
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final wornPicture = context.select<GameState, int?>(
      (s) => s.user?.activePictureId,
    );
    final laidTable = context.select<GameState, int?>(
      (s) => s.user?.activeTablePictureId,
    );
    final state = context.read<GameState>();
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final dark = theme.brightness == Brightness.dark;
    final size = MediaQuery.sizeOf(context);
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkMed,
    );
    final prize = spin.prize;
    final nothing = prize.isNothing;
    final hero = (size.height * 0.16).clamp(40.0, 68.0);
    final padV = (size.height * 0.055).clamp(16.0, 28.0);
    final padH = (size.height * 0.085).clamp(24.0, 44.0);
    final ink = luckyPrizeInk(prize, theme);

    final picture = prize.picture;
    final table = prize.tablePicture;
    final Widget mark = switch (prize.type) {
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
      // The empty slot's face, in a quiet disc of its own.
      _ when nothing => Container(
        width: hero * 1.3,
        height: hero * 1.3,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.colorScheme.onSurface.withValues(
            alpha: dark ? 0.07 : 0.05,
          ),
        ),
        child: LuckyPrizeGlyph(prize: prize, size: hero * 0.8),
      ),
      _ => LuckyPrizeGlyph(prize: prize, size: hero),
    };

    // A picture's term: the shop's own, counted from the spin — or, for one
    // they had, that nothing changed.
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
    final canWear = picture != null && wornPicture != picture.id;
    final canLay = table != null && laidTable != table.id;

    // The prize's own line: the figure leading, the wallet's word after it.
    final parts = luckyPrizeParts(t, prize);
    final prizeLine = Text.rich(
      key: const ValueKey('lucky-result-prize'),
      TextSpan(
        children: [
          TextSpan(
            text: parts.amount,
            style: prize.isPicture
                ? AppTheme.label(text.headlineSmall!, weight: FontWeight.w700)
                : AppTheme.money(text.headlineMedium!, colour: ink),
          ),
          if (parts.unit.isNotEmpty && !prize.isPicture)
            TextSpan(
              text: ' ${parts.unit}',
              style: AppTheme.label(text.titleMedium!, colour: quiet),
            ),
        ],
      ),
      textAlign: TextAlign.center,
    );

    final title = Text(
      nothing ? t.luckyNothingTitle : t.luckyCongrats,
      textAlign: TextAlign.center,
      style: AppTheme.label(text.titleMedium!, weight: FontWeight.w700),
    );

    final primary = canWear
        ? (
            t.luckyWearNow,
            () {
              onClose();
              state.chooseAvatar(picture.id);
            },
          )
        : canLay
        ? (
            t.luckyLayNow,
            () {
              onClose();
              state.chooseTablePicture(table.id);
            },
          )
        : (t.close, onClose);

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
                      duration: arrival,
                      builder: (context, v, child) => Opacity(
                        opacity: Curves.easeOut.transform(v),
                        child: Transform.scale(
                          scale:
                              0.9 +
                              0.1 *
                                  (nothing ? Motion.standard : Motion.settle)
                                      .transform(v),
                          child: child,
                        ),
                      ),
                      child: PremiumSurface(
                        key: const ValueKey('lucky-result'),
                        accent: nothing
                            ? theme.colorScheme.onSurface.withValues(alpha: 0.5)
                            : AppTheme.gold,
                        bloom: nothing ? 0 : null,
                        radius: Radii.lg,
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(padH, padV, padH, padV),
                          child: SingleChildScrollView(
                            // The card clips at its own rounded edge; a
                            // viewport clip here cut the gold key's shadow
                            // off square at the foot of the card.
                            clipBehavior: Clip.none,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _MarkArrival(
                                  key: ValueKey('lucky-mark-${spin.actionId}'),
                                  size: hero,
                                  glow: nothing ? null : AppTheme.gold,
                                  shrug: nothing,
                                  child: mark,
                                ),
                                const SizedBox(height: Space.md),
                                title,
                                const SizedBox(height: Space.xs),
                                if (nothing)
                                  Text(
                                    t.luckyNoPrize,
                                    textAlign: TextAlign.center,
                                    style: AppTheme.label(
                                      text.titleMedium!,
                                      colour: quiet,
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
                                  prizeLine,
                                  if (prize.isPicture)
                                    Text(
                                      parts.unit,
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
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: Space.md,
                                  runSpacing: Space.sm,
                                  children: [
                                    if (canWear || canLay)
                                      GlassButton(
                                        style: GlassButtonStyle.text,
                                        label: t.close,
                                        // The quiet key in neutral ink, not
                                        // the scheme's green, beside the gold.
                                        tone: quiet,
                                        onPressed: onClose,
                                      ),
                                    LuckyGoldKey(
                                      key: const ValueKey('lucky-result-go'),
                                      label: primary.$1,
                                      onTap: () {
                                        tapHaptic(context);
                                        primary.$2();
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

/// The prize's mark arriving: a beat after the card, it pops up from seven
/// tenths of its size over a light that swells behind it and settles to a
/// glow ([glow]); or, for the empty slot ([shrug]), it simply turns up and
/// tilts one way and back, the way a shrug does.
class _MarkArrival extends StatelessWidget {
  const _MarkArrival({
    super.key,
    required this.size,
    required this.child,
    this.glow,
    this.shrug = false,
  });

  final double size;
  final Widget child;
  final Color? glow;
  final bool shrug;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final light = glow;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: LuckyPrizeReveal.pop,
      builder: (context, v, mark) {
        // The mark waits a beat for the card, then arrives.
        final m = ((v - 0.18) / 0.62).clamp(0.0, 1.0);
        final swell = light == null
            ? 0.0
            : (v < 0.55
                  ? Motion.standard.transform(v / 0.55)
                  : 1 - 0.3 * Motion.standard.transform((v - 0.55) / 0.45));
        final Widget arrived = shrug
            ? Transform.rotate(
                angle: 0.14 * math.sin(math.pi * 2 * m) * (1 - m),
                child: Opacity(
                  opacity: Curves.easeOut.transform(m),
                  child: mark,
                ),
              )
            : Transform.scale(
                scale: 0.7 + 0.3 * Motion.settle.transform(m),
                child: Opacity(
                  opacity: Curves.easeOut.transform(m),
                  child: mark,
                ),
              );
        if (light == null) return arrived;
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            // The light behind the mark: laid out as big as the mark, and
            // drawn well past it.
            Positioned(
              left: -size * 0.6,
              right: -size * 0.6,
              top: -size * 0.6,
              bottom: -size * 0.6,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        light.withValues(alpha: (dark ? 0.42 : 0.30) * swell),
                        light.withValues(alpha: (dark ? 0.16 : 0.10) * swell),
                        light.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.45, 1],
                    ),
                  ),
                ),
              ),
            ),
            arrived,
          ],
        );
      },
      child: child,
    );
  }
}
