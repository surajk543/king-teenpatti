import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'drifting_chips.dart';
import 'poker_chip.dart';
import 'premium_surface.dart';

/// Where a pack sits in the range. Drives the ribbon across its corner, and
/// nothing else — the price and the chips are the offer, this is the signpost.
enum ShelfMark { none, starter, popular, bestValue, premium }

/// A flourish beside the bonus figure on the packs that carry one, because by
/// the top of the range every card says "BONUS" and the percentage alone stops
/// standing out.
enum Flair { none, fire, crown }

/// One purchasable pack.
///
/// Chips are stored as an integer and rendered through [formatChips], never as
/// a baked-in "1.92 Cr" string: a player who has switched to international
/// numbering should read Million and Billion here exactly as they do at the
/// table. In Indian numbering the nine packs come out as the owner specified
/// them — 1.92, 5.28, 12, 35.2, 60, 150, 275, 400 and 500 Crore.
class ChipPack {
  const ChipPack({
    required this.id,
    required this.rupees,
    required this.chips,
    this.bonusPercent = 0,
    this.mark = ShelfMark.none,
    this.flair = Flair.none,
  });

  final String id;
  final int rupees;
  final int chips;

  /// 0 on the starter pack, which is the baseline the rest are sold against.
  final int bonusPercent;
  final ShelfMark mark;
  final Flair flair;

  bool get featured => mark == ShelfMark.bestValue || mark == ShelfMark.premium;
}

/// The shelf, in the owner's order. Cheapest first, so scrolling right is
/// always "more".
const chipPacks = <ChipPack>[
  ChipPack(id: 'A', rupees: 99, chips: 19200000, mark: ShelfMark.starter),
  ChipPack(id: 'B', rupees: 199, chips: 52800000, bonusPercent: 20),
  ChipPack(id: 'C', rupees: 399, chips: 120000000, bonusPercent: 30),
  ChipPack(
    id: 'D',
    rupees: 999,
    chips: 352000000,
    bonusPercent: 40,
    mark: ShelfMark.popular,
  ),
  ChipPack(id: 'E', rupees: 1499, chips: 600000000, bonusPercent: 50),
  ChipPack(
    id: 'F',
    rupees: 2999,
    chips: 1500000000,
    bonusPercent: 55,
    mark: ShelfMark.bestValue,
    flair: Flair.fire,
  ),
  ChipPack(
    id: 'G',
    rupees: 4999,
    chips: 2750000000,
    bonusPercent: 60,
    mark: ShelfMark.popular,
    flair: Flair.fire,
  ),
  ChipPack(
    id: 'H',
    rupees: 6900,
    chips: 4000000000,
    bonusPercent: 65,
    mark: ShelfMark.premium,
    flair: Flair.crown,
  ),
  ChipPack(
    id: 'I',
    rupees: 7900,
    chips: 5000000000,
    bonusPercent: 70,
    mark: ShelfMark.bestValue,
    flair: Flair.crown,
  ),
];

/// Opens the store over whatever is behind it.
///
/// `showGeneralDialog` rather than `showDialog` so the scrim and the entrance
/// are ours: the packs arrive in sequence, which reads as a shelf being set
/// out rather than a panel appearing.
Future<void> showChipStore(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black.withValues(alpha: 0.72),
    transitionDuration: const Duration(milliseconds: 420),
    pageBuilder: (_, a, b) => const _ChipStore(),
    transitionBuilder: (context, anim, _, child) {
      // Rises and settles: easeOutBack overshoots a touch on the way in, which
      // reads as the shelf being set down rather than fading up.
      final e = Curves.easeOutBack.transform(anim.value.clamp(0.0, 1.0));
      final fade = Curves.easeOut.transform(anim.value);
      return Opacity(
        opacity: fade,
        child: Transform.translate(
          offset: Offset(0, 26 * (1 - fade)),
          child: Transform.scale(scale: 0.90 + 0.10 * e, child: child),
        ),
      );
    },
  );
}

class _ChipStore extends StatelessWidget {
  const _ChipStore();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.watch<GameState>().t;

    return Center(
      child: Padding(
        // The app is landscape and short, so the shelf is a horizontal rail
        // and the dialog gives it nearly the full width.
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        child: PremiumSurface(
          accent: AppTheme.gold,
          radius: 28,
          // Clipped so the drift is contained by the panel's own corners, and
          // a Stack so it sits behind the shelf without affecting its layout:
          // the Padding is the only non-positioned child, so it alone decides
          // how big the panel is.
          child: ClipRRect(
            borderRadius: BorderRadius.circular(27),
            child: Stack(
              children: [
                const Positioned.fill(
                  child: IgnorePointer(child: DriftingChips(strength: 1.7)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          PokerChip(colour: AppTheme.gold, size: 26),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                t.storeTitle,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.2,
                                ),
                              ),
                              Text(
                                t.storeBlurb,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: t.close,
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        // Sized to what a card actually holds. A taller rail leaves
                        // dead space under the price button, because the card fills
                        // the rail's height while its content does not.
                        height: 206,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          itemCount: chipPacks.length,
                          separatorBuilder: (_, i) => const SizedBox(width: 12),
                          itemBuilder: (context, i) => _PackEntrance(
                            index: i,
                            child: _PackCard(pack: chipPacks[i]),
                          ),
                        ),
                      ),
                    ],
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

/// Slides each pack up as the shelf is set out, 55 ms apart.
class _PackEntrance extends StatefulWidget {
  const _PackEntrance({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_PackEntrance> createState() => _PackEntranceState();
}

class _PackEntranceState extends State<_PackEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    Future<void>.delayed(Duration(milliseconds: 55 * widget.index), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final e = Curves.easeOutCubic.transform(_c.value);
        return Opacity(
          opacity: _c.value,
          child: Transform.translate(
            offset: Offset(0, 26 * (1 - e)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _PackCard extends StatefulWidget {
  const _PackCard({required this.pack});

  final ChipPack pack;

  @override
  State<_PackCard> createState() => _PackCardState();
}

class _PackCardState extends State<_PackCard>
    with SingleTickerProviderStateMixin {
  /// Eager, not lazy: this build has no path that skips the controller today,
  /// but a `late final` initialised in a field would be constructed by
  /// `dispose()` if one were ever added, and that throws on a deactivated
  /// element (see the note in seat_pod.dart's `_Blink`).
  late final AnimationController _pulse;
  bool _down = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  String _markLabel(Strings t) => switch (widget.pack.mark) {
    ShelfMark.starter => t.posStarter,
    ShelfMark.popular => t.posPopular,
    ShelfMark.bestValue => t.posBestValue,
    ShelfMark.premium => t.posPremium,
    ShelfMark.none => '',
  };

  Color _markColour(ColorScheme scheme) => switch (widget.pack.mark) {
    ShelfMark.starter => scheme.tertiary,
    ShelfMark.popular => scheme.primary,
    ShelfMark.bestValue => AppTheme.gold,
    ShelfMark.premium => const Color(0xFF7C4DFF),
    // Not `outline`: grey reads as disabled, and every pack here is on
    // sale. An unmarked pack is an ordinary one, not a lesser one — the
    // ribbon is what distinguishes it, so the accent stays the house green.
    ShelfMark.none => scheme.primary,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final state = context.watch<GameState>();
    final t = state.t;
    final p = widget.pack;
    final accent = p.featured ? AppTheme.gold : _markColour(scheme);

    void buy() {
      // Deliberately does not pretend to sell anything. There is no payment
      // path wired up, and a button that looks like it charged money is worse
      // than one that says it did not.
      state.notice = t.storeNotLive;
      Navigator.pop(context);
    }

    return AnimatedScale(
      scale: _down ? 0.955 : 1,
      duration: const Duration(milliseconds: 130),
      curve: Curves.easeOut,
      child: SizedBox(
        width: 168,
        child: AnimatedBuilder(
          animation: _pulse,
          builder: (context, child) {
            // Featured packs sit in a slowly breathing pool of their own
            // accent. Everything else is flat, so the glow is the signal.
            final halo = p.featured
                ? 0.30 + 0.16 * math.sin(_pulse.value * 2 * math.pi)
                : 0.0;
            return DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  if (p.featured)
                    BoxShadow(
                      color: AppTheme.gold.withValues(alpha: halo),
                      blurRadius: 26,
                      spreadRadius: 1,
                    ),
                  ...AppTheme.controlShadow(theme.brightness, elevation: 4),
                ],
              ),
              child: child,
            );
          },
          child: Material(
            // Material 3 tonal elevation: the card is a raised surface in the
            // scheme's own tonal palette, not a white rectangle.
            color: p.featured
                ? Color.alphaBlend(
                    AppTheme.gold.withValues(alpha: dark ? 0.16 : 0.11),
                    scheme.surfaceContainerHigh,
                  )
                : scheme.surfaceContainerHigh,
            elevation: 0,
            borderRadius: BorderRadius.circular(22),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: buy,
              onTapDown: (_) => setState(() => _down = true),
              onTapCancel: () => setState(() => _down = false),
              onTapUp: (_) => setState(() => _down = false),
              splashColor: accent.withValues(alpha: 0.14),
              highlightColor: accent.withValues(alpha: 0.06),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: accent.withValues(alpha: p.featured ? 0.85 : 0.30),
                    width: p.featured ? 1.6 : 1,
                  ),
                  // A soft vertical wash so the card has a top-lit face rather
                  // than one flat fill.
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      accent.withValues(alpha: dark ? 0.13 : 0.09),
                      accent.withValues(alpha: 0.0),
                    ],
                    stops: const [0, 0.62],
                  ),
                ),
                child: Stack(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        12,
                        p.mark == ShelfMark.none ? 16 : 34,
                        12,
                        14,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _BonusBadge(pack: p, pulse: _pulse),
                          // A taller pile as the packs get bigger, so the
                          // picture agrees with the number.
                          LivelyChipStack(
                            colours: List.generate(
                              3 + (chipPacks.indexOf(p) ~/ 4),
                              (i) => i.isEven ? accent : AppTheme.gold,
                            ),
                            size: 24,
                          ),
                          Text(
                            formatChips(p.chips),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.2,
                              color: p.featured
                                  ? (dark
                                        ? AppTheme.gold
                                        : const Color(0xFF6B5200))
                                  : scheme.onSurface,
                            ),
                          ),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: buy,
                              style: FilledButton.styleFrom(
                                backgroundColor: p.featured
                                    ? AppTheme.gold
                                    : scheme.primary,
                                foregroundColor: p.featured
                                    ? Colors.black.withValues(alpha: 0.86)
                                    : scheme.onPrimary,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 11,
                                ),
                                shape: const StadiumBorder(),
                              ),
                              child: Text(
                                '₹${_grouped(p.rupees)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 15,
                                  letterSpacing: 0.2,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (p.mark != ShelfMark.none)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _Ribbon(
                          label: _markLabel(t),
                          colour: _markColour(scheme),
                          shimmer: p.featured ? _pulse : null,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "1,499" — the Indian grouping for a rupee figure, which is a price and so
/// never abbreviated the way a chip balance is.
String _grouped(int n) {
  final s = n.toString();
  if (s.length <= 3) return s;
  final head = s.substring(0, s.length - 3);
  final tail = s.substring(s.length - 3);
  final buf = StringBuffer();
  for (var i = 0; i < head.length; i++) {
    if (i > 0 && (head.length - i) % 2 == 0) buf.write(',');
    buf.write(head[i]);
  }
  return '$buf,$tail';
}

class _Ribbon extends StatelessWidget {
  const _Ribbon({required this.label, required this.colour, this.shimmer});

  final String label;
  final Color colour;

  /// When given, a highlight travels along the ribbon — reserved for the packs
  /// the owner marked as the ones to look at, so it stays a signal.
  final AnimationController? shimmer;

  @override
  Widget build(BuildContext context) {
    final onColour =
        ThemeData.estimateBrightnessForColor(colour) == Brightness.dark
        ? Colors.white
        : Colors.black87;

    final bar = Container(
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [colour.withValues(alpha: 0.86), colour],
        ),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.1,
          color: onColour,
        ),
      ),
    );

    if (shimmer == null) return bar;
    return AnimatedBuilder(
      animation: shimmer!,
      builder: (context, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (rect) {
          // A narrow band of light sweeping left to right, and off the end.
          final x = shimmer!.value * 2.4 - 0.7;
          return LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.transparent,
              Colors.white.withValues(alpha: 0.55),
              Colors.transparent,
            ],
            stops: [
              (x - 0.14).clamp(0.0, 1.0),
              x.clamp(0.0, 1.0),
              (x + 0.14).clamp(0.0, 1.0),
            ],
          ).createShader(rect);
        },
        child: child,
      ),
      child: bar,
    );
  }
}

/// The bonus figure, and a breath on the packs carrying a flourish so the eye
/// lands on the top of the range.
class _BonusBadge extends StatelessWidget {
  const _BonusBadge({required this.pack, required this.pulse});

  final ChipPack pack;
  final AnimationController pulse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.watch<GameState>().t;

    if (pack.bonusPercent == 0) {
      // The starter pack has nothing to claim, and an empty badge would leave
      // the cards misaligned — so it keeps the height with a dash.
      return Text(
        '—',
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w800,
        ),
      );
    }

    final flair = switch (pack.flair) {
      Flair.fire => '🔥 ',
      Flair.crown => '👑 ',
      Flair.none => '',
    };
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.gold.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.gold.withValues(alpha: 0.7)),
      ),
      child: Text(
        '$flair${pack.bonusPercent}% ${t.storeBonus}',
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w900,
          letterSpacing: 0.3,
        ),
      ),
    );

    if (pack.flair == Flair.none) return badge;
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final breath = 1 + 0.05 * math.sin(pulse.value * 2 * math.pi);
        return Transform.scale(scale: breath, child: child);
      },
      child: badge,
    );
  }
}
