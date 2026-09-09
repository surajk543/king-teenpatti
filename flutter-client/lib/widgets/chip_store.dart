import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:provider/provider.dart';

import '../settings/feedback_settings.dart';

import '../l10n/strings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'poker_chip.dart';
import 'premium_surface.dart';

/// Where a pack sits in the range. Drives the ribbon across its top edge, and
/// nothing else — the price and the chips are the offer, this is the signpost.
enum ShelfMark { none, starter, popular, bestValue, premium }

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
    required this.productId,
    required this.rupees,
    required this.chips,
    this.bonusPercent = 0,
    this.mark = ShelfMark.none,
  });

  final String id;

  /// The Play Console product id. It must match internal/purchase/catalogue.go
  /// exactly — that file, not this one, decides how many chips it is worth.
  final String productId;
  final int rupees;
  final int chips;

  /// 0 on the starter pack, which is the baseline the rest are sold against.
  final int bonusPercent;
  final ShelfMark mark;

  bool get featured => mark == ShelfMark.bestValue || mark == ShelfMark.premium;
}

/// The shelf, in the owner's order. Cheapest first, so scrolling right is
/// always "more".
const chipPacks = <ChipPack>[
  ChipPack(id: 'A', productId: 'chips_a_99', rupees: 99, chips: 19200000, mark: ShelfMark.starter),
  ChipPack(id: 'B', productId: 'chips_b_199', rupees: 199, chips: 52800000, bonusPercent: 20),
  ChipPack(id: 'C', productId: 'chips_c_399', rupees: 399, chips: 120000000, bonusPercent: 30),
  ChipPack(
    id: 'D', productId: 'chips_d_999',
    rupees: 999,
    chips: 352000000,
    bonusPercent: 40,
    mark: ShelfMark.popular,
  ),
  ChipPack(id: 'E', productId: 'chips_e_1499', rupees: 1499, chips: 600000000, bonusPercent: 50),
  ChipPack(
    id: 'F', productId: 'chips_f_2999',
    rupees: 2999,
    chips: 1500000000,
    bonusPercent: 55,
    mark: ShelfMark.bestValue,
  ),
  ChipPack(
    id: 'G', productId: 'chips_g_4999',
    rupees: 4999,
    chips: 2750000000,
    bonusPercent: 60,
    mark: ShelfMark.popular,
  ),
  ChipPack(
    id: 'H', productId: 'chips_h_6900',
    rupees: 6900,
    chips: 4000000000,
    bonusPercent: 65,
    mark: ShelfMark.premium,
  ),
  ChipPack(
    id: 'I', productId: 'chips_i_7900',
    rupees: 7900,
    chips: 5000000000,
    bonusPercent: 70,
    mark: ShelfMark.bestValue,
  ),
];

/// The tallest pile any card carries, from the same expression the cards use.
/// It is what the shelf height is measured against, so every card is the same
/// height whatever its own pile does.
final int _tallestPile =
    chipPacks.map((p) => _pileFor(p)).reduce((a, b) => a > b ? a : b);

/// How many discs a pack's pile is. Unchanged: `colours.length` is layout in
/// [LivelyChipStack], so this expression is the card's geometry, not a palette.
int _pileFor(ChipPack p) => 3 + chipPacks.indexOf(p) ~/ 4;

/// The painted height of one line of the type ramp, after the OS text scale
/// (clamped app-wide to 0.9–1.25 in `main.dart`).
///
/// Rounded up, because a paragraph is laid out on whole pixels: the exact
/// product is a fraction short of what the text actually takes, and a Column
/// measured to the fraction overflows by tenths of a pixel.
double _line(TextScaler scaler, double size, double heightFactor) =>
    (scaler.scale(size) * heightFactor).ceilToDouble();

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
    transitionDuration: Motion.enter,
    pageBuilder: (_, a, b) => const _ChipStore(),
    transitionBuilder: (context, anim, _, child) {
      // Rises and settles: easeOutBack overshoots a touch on the way in, which
      // reads as the shelf being set down rather than fading up.
      final e = Motion.settle.transform(anim.value.clamp(0.0, 1.0));
      final fade = Motion.standard.transform(anim.value);
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

class _ChipStore extends StatefulWidget {
  const _ChipStore();

  @override
  State<_ChipStore> createState() => _ChipStoreState();
}

class _ChipStoreState extends State<_ChipStore> {
  /// Play's own prices, in the player's currency. Fetched when the store
  /// opens rather than held on the state: prices are Play's to change, and a
  /// figure cached across sessions could be wrong by the time it is shown.
  Map<String, ProductDetails> _prices = const {};

  @override
  void initState() {
    super.initState();
    _loadPrices();
  }

  Future<void> _loadPrices() async {
    final got = await context
        .read<GameState>()
        .purchases
        .priceList(chipPacks.map((p) => p.productId).toSet());
    if (mounted && got.isNotEmpty) setState(() => _prices = got);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.watch<GameState>().t;
    final prices = _prices;
    final size = MediaQuery.sizeOf(context);
    final scaler = MediaQuery.textScalerOf(context);

    // Every height here is measured from what it holds, and the shelf gets
    // whatever is left. Header: the title over the blurb, or the close
    // button's touch target, whichever is taller — 44dp at the normal text
    // scale, 48 at the 1.25 ceiling.
    final headerH = math.max(
      Dim.minTouch,
      _line(scaler, 17, 1.25) + _line(scaler, 12, 1.35),
    );
    final packH = _packHeight(scaler, size.height);
    // Shelf against the room, at the 1.25 text ceiling: 250dp free at h=360
    // for a 195.2dp card, 301 for 200.4 at h=411, 690 for 210.7 at h=800 — the
    // card fits at every size, so the min() is the guard rail, not the rule.
    final shelfH = math.min(
      packH,
      size.height -
          2 * Space.md -
          2 * Space.lg -
          headerH -
          Space.lg,
    );

    return Center(
      child: Padding(
        // The app is landscape and short, so the shelf is a horizontal rail
        // and the panel gives it nearly the full width.
        padding: const EdgeInsets.all(Space.md),
        child: PremiumGlassPanel(
          // A modal, and the only one of its kind on screen: it may take the
          // app's single blur if nothing louder has claimed it.
          mode: GlassMode.auto,
          sigma: 24,
          priority: 20,
          radius: Radii.lg,
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: headerH,
                child: Row(
                  children: [
                    const PokerChip(colour: AppTheme.gold, size: 22),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            t.storeTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.label(
                              theme.textTheme.titleMedium ?? const TextStyle(),
                            ),
                          ),
                          Text(
                            t.storeBlurb,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurface
                                  .withValues(alpha: AppTheme.inkLow),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: t.close,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded, size: 20),
                      // A Material icon button lays out at 48 whatever its
                      // icon does, which is 4dp more than the header is tall.
                      // The touch floor is Dim.minTouch, so say so.
                      style: IconButton.styleFrom(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        minimumSize: const Size.square(Dim.minTouch),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Space.lg),
              SizedBox(
                height: shelfH,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: Space.xxs),
                  itemCount: chipPacks.length,
                  separatorBuilder: (_, i) => const SizedBox(width: Space.md),
                  itemBuilder: (context, i) => _PackEntrance(
                    index: i,
                    child: _PackCard(
                      pack: chipPacks[i],
                      prices: prices,
                      width: Dim.packW(size.width),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A pack card's height, added up from what it holds rather than picked to
/// look right on one device: the ribbon lane, the bonus plate, the tallest
/// pile on the shelf, the figure, the price key, and the gaps between them.
///
/// 195.2dp at h=360, 200.4 at h=411, 210.7 at h=800 (all at the 1.25 text
/// scale ceiling; the pile is the only part that grows with the screen).
double _packHeight(TextScaler scaler, double screenH) {
  final chip = _pileChip(screenH);

  return _ribbonHeight(scaler) +
      Space.sm +
      _badgeHeight(scaler) +
      Space.sm +
      chip + chip * 0.22 * (_tallestPile - 1) +
      Space.sm +
      _line(scaler, 17, 1.25) +
      Space.md +
      Dim.minTouch +
      Space.md;
}

/// 19.3dp at h=360, 22 at h=411, 27.5 at h=800.
double _pileChip(double screenH) => 22 * Dim.vScale(screenH);

double _ribbonHeight(TextScaler scaler) =>
    _line(scaler, 10.5, 1.15) + 2 * Space.xs;

double _badgeHeight(TextScaler scaler) =>
    _line(scaler, 10.5, 1.15) + 2 * Space.xs + 2 * Dim.hairline;

/// Slides each pack up as the shelf is set out, one stagger apart.
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
    _c = AnimationController(vsync: this, duration: Motion.enter);
    Future<void>.delayed(Motion.stagger * widget.index, () {
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
        final e = Motion.standard.transform(_c.value);
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
  const _PackCard({
    required this.pack,
    required this.prices,
    required this.width,
  });

  final ChipPack pack;

  /// What Play says these cost, keyed by product id. Empty when Play is
  /// unavailable or has not answered yet, and then the card falls back to the
  /// list price — an approximate figure beats an empty shelf, and the real one
  /// is always shown on Play's own sheet before anyone is charged.
  final Map<String, ProductDetails> prices;

  /// 140dp at w=640, 169.3 at w=891, 200 (the ceiling) at w=1280.
  final double width;

  @override
  State<_PackCard> createState() => _PackCardState();
}

class _PackCardState extends State<_PackCard> {
  bool _down = false;

  String _markLabel(Strings t) => switch (widget.pack.mark) {
    ShelfMark.starter => t.posStarter,
    ShelfMark.popular => t.posPopular,
    ShelfMark.bestValue => t.posBestValue,
    ShelfMark.premium => t.posPremium,
    ShelfMark.none => '',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = context.watch<GameState>();
    final t = state.t;
    final p = widget.pack;
    final prices = widget.prices;
    final scaler = MediaQuery.textScalerOf(context);
    final screenH = MediaQuery.sizeOf(context).height;
    // Champagne reads on charcoal and vanishes on bone, so the light scheme
    // takes the deep end of the same gold.
    final champagne = theme.brightness == Brightness.dark
        ? AppTheme.goldBright
        : AppTheme.goldDeep;

    void buy() {
      // Play is the only thing that can take money, and it is not always
      // there: an emulator without Play Services, a side-loaded build, a
      // device signed out of Play. Say so plainly instead of failing at the
      // billing sheet.
      final details = prices[p.productId];
      if (!state.purchases.available || details == null) {
        state.notice = t.storeNotLive;
        Navigator.pop(context);
        return;
      }
      // From here the result arrives on the purchase stream, not from this
      // call — see net/purchases.dart. The store closes; a purchase that
      // completes minutes later is still credited and still celebrated.
      state.purchases.buy(details);
      Navigator.pop(context);
    }

    return AnimatedScale(
      scale: _down ? 0.955 : 1,
      duration: Motion.fast,
      curve: Motion.standard,
      child: SizedBox(
        width: widget.width,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            // The top of the range sits in a still pool of gold. It used to
            // breathe on a 2.4s loop in all nine cards at once, which is nine
            // repeating controllers and a shelf that flickers.
            boxShadow: p.featured
                ? [
                    BoxShadow(
                      color: AppTheme.gold.withValues(alpha: 0.14),
                      blurRadius: 22,
                      spreadRadius: -4,
                    ),
                  ]
                : null,
          ),
          child: PremiumGlassPanel(
            mode: GlassMode.tinted,
            radius: Radii.lg,
            live: p.featured,
            tint: p.featured ? AppTheme.gold : null,
            padding: EdgeInsets.zero,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
      // Material's own click, gated on the player's Sound switch —
      // otherwise a silenced game would still tick on every tap.
      enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
                onTap: buy,
                onTapDown: (_) => setState(() => _down = true),
                onTapCancel: () => setState(() => _down = false),
                onTapUp: (_) => setState(() => _down = false),
                splashColor: AppTheme.gold.withValues(alpha: 0.12),
                highlightColor: AppTheme.gold.withValues(alpha: 0.06),
                child: Column(
                  children: [
                    SizedBox(
                      // The lane is reserved on every card, marked or not, so
                      // nine cards line up on one grid.
                      height: _ribbonHeight(scaler),
                      width: double.infinity,
                      child: p.mark == ShelfMark.none
                          ? null
                          : _Ribbon(label: _markLabel(t)),
                    ),
                    const SizedBox(height: Space.sm),
                    SizedBox(
                      height: _badgeHeight(scaler),
                      child: _BonusBadge(pack: p),
                    ),
                    const SizedBox(height: Space.sm),
                    // A taller pile as the packs get bigger, so the picture
                    // agrees with the number. Flexible so a text scale the
                    // arithmetic did not foresee shortens the pile instead of
                    // overflowing the shelf.
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: LivelyChipStack(
                          colours: List.generate(
                            _pileFor(p),
                            (i) => i.isEven ? AppTheme.gold : scheme.primary,
                          ),
                          size: _pileChip(screenH),
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
                      child: FittedBox(
                        // The figure is the offer. It is the one string here
                        // whose length is not ours — "5 Billion" and
                        // "5,00,00,00,000" are the same card — so it shrinks
                        // rather than wraps or ellipsises.
                        fit: BoxFit.scaleDown,
                        child: Text(
                          formatChips(p.chips),
                          maxLines: 1,
                          style: AppTheme.money(
                            theme.textTheme.titleMedium ?? const TextStyle(),
                            colour: p.featured ? champagne : scheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.md),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Space.md,
                        0,
                        Space.md,
                        Space.md,
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: buy,
                          style: FilledButton.styleFrom(
                            // shrinkWrap, or Material's padded tap target
                            // silently makes this key 48 and the card 4dp
                            // taller than the shelf it was measured for.
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            minimumSize: const Size.fromHeight(Dim.minTouch),
                            padding: EdgeInsets.zero,
                          ),
                          child: Text(
                            prices[p.productId]?.price ??
                                '₹${_grouped(p.rupees)}',
                            maxLines: 1,
                            style: AppTheme.money(
                              theme.textTheme.titleSmall ?? const TextStyle(),
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

/// The tier marker: one material for all four tiers.
///
/// It used to be five different accent colours, which made the shelf read as
/// five unrelated offers. Gold is the house's one signal colour and the ribbon
/// is where the store spends it.
class _Ribbon extends StatelessWidget {
  const _Ribbon({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      // Flat foil, not the struck gradient the buy-chips key wears: a marker
      // and a control should not be the same material.
      decoration: const BoxDecoration(color: AppTheme.gold),
      child: Center(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          // label, not smallCaps: these four words are translated, and adding
          // tracking to Gujarati or Gurmukhi only pulls it apart.
          style: AppTheme.label(
            theme.textTheme.labelSmall ?? const TextStyle(),
            colour: AppTheme.inkOnLight,
            weight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// The bonus figure. The starter pack has nothing to claim and keeps the lane
/// with a dash, so the nine cards stay on one grid.
class _BonusBadge extends StatelessWidget {
  const _BonusBadge({required this.pack});

  final ChipPack pack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.watch<GameState>().t;
    final champagne = theme.brightness == Brightness.dark
        ? AppTheme.goldBright
        : AppTheme.goldDeep;

    if (pack.bonusPercent == 0) {
      return Center(
        child: Text(
          '—',
          style: AppTheme.label(
            theme.textTheme.labelSmall ?? const TextStyle(),
            colour: scheme.onSurface.withValues(alpha: AppTheme.inkLow),
          ),
        ),
      );
    }

    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.gold.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(
            color: AppTheme.hairlineColour(theme.brightness, live: true),
            width: Dim.hairline,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          child: Text(
            '${pack.bonusPercent}% ${t.storeBonus}',
            maxLines: 1,
            style: AppTheme.label(
              theme.textTheme.labelSmall ?? const TextStyle(),
              colour: champagne,
              weight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
