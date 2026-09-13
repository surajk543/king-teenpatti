import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:provider/provider.dart';

import '../settings/feedback_settings.dart';

import '../l10n/strings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import 'avatar.dart';
import 'glass_components.dart';
import 'glass_orb.dart';
import 'picture_shelf.dart';
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

/// One purchasable diamond pack (owner, 13 Sep 2026).
///
/// Like [ChipPack], the count is only for display: `purchase.Catalogue` on the
/// server decides what a product id is worth, and a diamond pack credits
/// `users.diamond`, never chips.
class DiamondPack {
  const DiamondPack({
    required this.productId,
    required this.rupees,
    required this.diamonds,
    this.mark = ShelfMark.none,
  });

  /// The Play Console product id. It must match
  /// internal/purchase/catalogue.go exactly.
  final String productId;
  final int rupees;
  final int diamonds;
  final ShelfMark mark;
}

/// The diamond shelf, cheapest first. ⭐ marks the popular pack, 🔥 the best
/// value, as the owner set them.
const diamondPacks = <DiamondPack>[
  DiamondPack(productId: 'diamonds_1_49', rupees: 49, diamonds: 1),
  DiamondPack(
    productId: 'diamonds_5_199',
    rupees: 199,
    diamonds: 5,
    mark: ShelfMark.popular,
  ),
  DiamondPack(
    productId: 'diamonds_20_699',
    rupees: 699,
    diamonds: 20,
    mark: ShelfMark.bestValue,
  ),
  DiamondPack(productId: 'diamonds_100_2999', rupees: 2999, diamonds: 100),
];

/// One purchasable hammer pack (owner, 13 Sep 2026). A hammer pays for one
/// Force Sideshow at the table.
///
/// Like [DiamondPack], the count is only for display: `purchase.Catalogue` on
/// the server decides what a product id is worth, and a hammer pack credits
/// `users.hammer`, never chips or diamonds.
class HammerPack {
  const HammerPack({
    required this.productId,
    required this.rupees,
    required this.hammers,
    this.mark = ShelfMark.none,
  });

  /// The Play Console product id. It must match
  /// internal/purchase/catalogue.go exactly.
  final String productId;
  final int rupees;
  final int hammers;
  final ShelfMark mark;
}

/// The hammer shelf, cheapest first. ⭐ marks the popular pack and 🔥 the best
/// value, the same treatment as the diamond shelf, on the packs the owner
/// chose: 50 and 100.
const hammerPacks = <HammerPack>[
  HammerPack(productId: 'hammers_20_300', rupees: 300, hammers: 20),
  HammerPack(
    productId: 'hammers_50_699',
    rupees: 699,
    hammers: 50,
    mark: ShelfMark.popular,
  ),
  HammerPack(
    productId: 'hammers_100_1299',
    rupees: 1299,
    hammers: 100,
    mark: ShelfMark.bestValue,
  ),
  HammerPack(productId: 'hammers_250_2999', rupees: 2999, hammers: 250),
];

/// The shelf, in the owner's order. Cheapest first, so scrolling right is
/// always "more".
const chipPacks = <ChipPack>[
  ChipPack(
    id: 'A',
    productId: 'chips_a_99',
    rupees: 99,
    chips: 19200000,
    mark: ShelfMark.starter,
  ),
  ChipPack(
    id: 'B',
    productId: 'chips_b_199',
    rupees: 199,
    chips: 52800000,
    bonusPercent: 20,
  ),
  ChipPack(
    id: 'C',
    productId: 'chips_c_399',
    rupees: 399,
    chips: 120000000,
    bonusPercent: 30,
  ),
  ChipPack(
    id: 'D',
    productId: 'chips_d_999',
    rupees: 999,
    chips: 352000000,
    bonusPercent: 40,
    mark: ShelfMark.popular,
  ),
  ChipPack(
    id: 'E',
    productId: 'chips_e_1499',
    rupees: 1499,
    chips: 600000000,
    bonusPercent: 50,
  ),
  ChipPack(
    id: 'F',
    productId: 'chips_f_2999',
    rupees: 2999,
    chips: 1500000000,
    bonusPercent: 55,
    mark: ShelfMark.bestValue,
  ),
  ChipPack(
    id: 'G',
    productId: 'chips_g_4999',
    rupees: 4999,
    chips: 2750000000,
    bonusPercent: 60,
    mark: ShelfMark.popular,
  ),
  ChipPack(
    id: 'H',
    productId: 'chips_h_6900',
    rupees: 6900,
    chips: 4000000000,
    bonusPercent: 65,
    mark: ShelfMark.premium,
  ),
  ChipPack(
    id: 'I',
    productId: 'chips_i_7900',
    rupees: 7900,
    chips: 5000000000,
    bonusPercent: 70,
    mark: ShelfMark.bestValue,
  ),
];

/// The painted height of one line of the type ramp, after the OS text scale
/// (clamped app-wide to 0.9–1.25 in `main.dart`).
///
/// Rounded up, because a paragraph is laid out on whole pixels: the exact
/// product is a fraction short of what the text actually takes, and a Column
/// measured to the fraction overflows by tenths of a pixel.
double _line(TextScaler scaler, double size, double heightFactor) =>
    (scaler.scale(size) * heightFactor).ceilToDouble();

/// The store's shelves, in the order their keys sit in the header: chip packs,
/// diamond packs, hammer packs and the picture catalogue. Public so a caller
/// can open the store on the shelf it is sending the player to — the table's
/// Force Sideshow key sends a player with no hammers to [hammers].
enum StoreTab { chips, diamonds, hammers, pictures }

/// The switch between the store's shelves, in the header beside the close key.
///
/// Two keys rather than a Material TabBar: the header is one 44dp row in
/// landscape, and a TabBar is a row of its own taken straight out of the
/// shelf. The key that is on is washed in gold, the house's one signal colour;
/// the other is quiet ink on the glass.
class _StoreTabs extends StatelessWidget {
  const _StoreTabs({
    required this.value,
    required this.onChanged,
    this.animatedOnly = false,
    this.compact = false,
  });

  final StoreTab value;
  final ValueChanged<StoreTab> onChanged;

  /// Icons alone, without their words. On a 640dp phone three labelled keys
  /// left the header's blurb a few words ("The bigger the pack, the bigge…");
  /// the title over the blurb already names the shelf that is on.
  final bool compact;

  /// Whether the picture key sells the animated shelf alone, and is named for
  /// it. True at a table (owner, 13 Sep 2026), where a seated player may buy
  /// and wear an animated picture. Chips and diamonds are always on sale.
  final bool animatedOnly;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.read<GameState>().t;
    final champagne = theme.brightness == Brightness.dark
        ? AppTheme.goldBright
        : AppTheme.goldDeep;
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkMed,
    );

    Widget key(StoreTab tab, IconData icon, String label) {
      final on = tab == value;
      final ink = on ? champagne : quiet;
      final body = PressScale(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(Radii.pill),
            enableFeedback: context.select<FeedbackSettings, bool>(
              (f) => f.sound,
            ),
            onTap: on
                ? null
                : () {
                    tapHaptic(context);
                    onChanged(tab);
                  },
            child: AnimatedContainer(
              duration: Motion.fast,
              alignment: Alignment.center,
              constraints: BoxConstraints(
                minHeight: Dim.minTouch,
                minWidth: compact ? Dim.minTouch : 0,
              ),
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.pill),
                color: on
                    ? AppTheme.gold.withValues(alpha: 0.16)
                    : Colors.transparent,
                border: Border.all(
                  color: on
                      ? AppTheme.goldBright.withValues(alpha: 0.55)
                      : AppTheme.hairlineColour(theme.brightness),
                  width: Dim.hairline,
                ),
              ),
              child: compact
                  ? Icon(icon, size: 18, color: ink)
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 18, color: ink),
                        const SizedBox(width: Space.xs),
                        Text(
                          label,
                          maxLines: 1,
                          style: AppTheme.label(
                            theme.textTheme.labelLarge ?? const TextStyle(),
                            colour: ink,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      );
      // An icon-only key still says what it is: in a tooltip on a long press,
      // and to a screen reader, which also hears which shelf is on.
      return compact
          ? Tooltip(
              message: label,
              child: Semantics(selected: on, child: body),
            )
          : body;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, shelf) in _shelves(t, animatedOnly).indexed) ...[
          if (i > 0) const SizedBox(width: Space.sm),
          key(shelf.tab, shelf.icon, shelf.label),
        ],
      ],
    );
  }

  /// The keys in header order, with what each one shows.
  static List<({StoreTab tab, IconData icon, String label})> _shelves(
    Strings t,
    bool animatedOnly,
  ) => [
    (tab: StoreTab.chips, icon: Icons.toll_rounded, label: t.storeTabChips),
    (
      tab: StoreTab.diamonds,
      icon: Icons.diamond_rounded,
      label: t.storeTabDiamonds,
    ),
    (tab: StoreTab.hammers, icon: Icons.hardware, label: t.storeTabHammers),
    animatedOnly
        ? (
            tab: StoreTab.pictures,
            icon: Icons.auto_awesome_rounded,
            label: t.storeTabAnimated,
          )
        : (
            tab: StoreTab.pictures,
            icon: Icons.face_rounded,
            label: t.storeTabPictures,
          ),
  ];

  /// How wide the keys are with their words, in this language at this text
  /// scale, so the header drops the words only when they do not fit.
  ///
  /// Measured rather than decided by screen width. With a fourth shelf the
  /// labelled keys fit a 891dp phone in English but not in every language at
  /// the 1.25 text ceiling, and any single width rule would either starve the
  /// title in one language or hide the words needlessly in another.
  static double labelledWidth(
    BuildContext context,
    Strings t, {
    required bool animatedOnly,
  }) {
    final theme = Theme.of(context);
    final style = AppTheme.label(
      theme.textTheme.labelLarge ?? const TextStyle(),
      weight: FontWeight.w700,
    );
    final shelves = _shelves(t, animatedOnly);
    var total = Space.sm * (shelves.length - 1);
    for (final shelf in shelves) {
      final painter = TextPainter(
        text: TextSpan(text: shelf.label, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      // The key's padding either side, its icon and the gap after it, and
      // the hairline round it.
      total += 2 * Space.md + 18 + Space.xs + painter.width + 2 * Dim.hairline;
      painter.dispose();
    }
    return total;
  }
}

/// Opens the store over whatever is behind it.
///
/// `showGeneralDialog` rather than `showDialog` so the scrim and the entrance
/// are ours: the packs arrive in sequence, which reads as a shelf being set
/// out rather than a panel appearing.
/// Opens the store.
///
/// A bottom sheet, laid out exactly like the picture picker: the same glass
/// panel, the same grab handle, the same header, and the same vertically
/// scrolling body under the same scrollbar. They are the two shelves in this
/// game — one sells pictures, one sells chips — and until now they arrived
/// differently, one rising from the floor and one unfolding in the middle of
/// the screen, which made them feel like two unrelated parts of the app.
///
/// A scrim is always dark, whatever the theme: the ground's own edge is a pale
/// slate in the light scheme, so dimming with it BRIGHTENED the lobby behind
/// the store instead of pushing it back.
///
/// [opensOn] is the shelf showing when it opens: Chips from the Shop key, and
/// Hammers when a Force Sideshow found the player's wallet empty.
Future<void> showChipStore(
  BuildContext context, {
  StoreTab opensOn = StoreTab.chips,
}) {
  // Where the store was opened decides what it sells, and that holds for as
  // long as it is open. Worked out again on every build, a kick while the
  // table's store was up turned it into the lobby's under the player's finger.
  final atTable = context.read<GameState>().screen == Screen.table;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: AppTheme.ink900.withValues(alpha: 0.72),
    transitionDuration: Motion.enter,
    pageBuilder: (_, a, b) => _ChipStore(atTable: atTable, opensOn: opensOn),
    transitionBuilder: (context, anim, _, child) {
      // Rises from the foot of the screen and settles, which is how the
      // picture picker arrives too — the two shelves should not open in two
      // different ways.
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

class _ChipStore extends StatefulWidget {
  const _ChipStore({required this.atTable, required this.opensOn});

  /// The shelf showing when the store opens.
  final StoreTab opensOn;

  /// Whether the store was opened at a table, where its picture key sells the
  /// animated shelf alone (owner, 13 Sep 2026). Fixed when it opens.
  final bool atTable;

  @override
  State<_ChipStore> createState() => _ChipStoreState();
}

class _ChipStoreState extends State<_ChipStore> {
  /// Play's own prices, in the player's currency. Fetched when the store
  /// opens rather than held on the state: prices are Play's to change, and a
  /// figure cached across sessions could be wrong by the time it is shown.
  Map<String, ProductDetails> _prices = const {};

  /// Built in initState, never lazily: a late controller first read in
  /// dispose() is the teardown trap CLAUDE.md §12.3 documents.
  final ScrollController _scroller = ScrollController();

  /// Which shelf is showing. Set from [_ChipStore.opensOn] in initState.
  StoreTab _tab = StoreTab.chips;

  /// The picture shelf's filter, as in the picker; it opens on All. At a table
  /// the shelf is the animated one whatever this says.
  PictureFilter _shelf = PictureFilter.all;

  /// Back to the top when the shelf under the scrollbar changes, so a switch
  /// never lands part-way down a list the player has not seen.
  void _toTop() {
    if (_scroller.hasClients) _scroller.jumpTo(0);
  }

  @override
  void initState() {
    super.initState();
    _tab = widget.opensOn;
    _loadPrices();
  }

  @override
  void dispose() {
    _scroller.dispose();
    super.dispose();
  }

  Future<void> _loadPrices() async {
    // One query for every shelf: Play answers per product id, and a player
    // flicking between the Chips, Diamonds and Hammers tabs should see prices
    // at once.
    final got = await context.read<GameState>().purchases.priceList({
      ...chipPacks.map((p) => p.productId),
      ...diamondPacks.map((p) => p.productId),
      ...hammerPacks.map((p) => p.productId),
    });
    if (mounted && got.isNotEmpty) setState(() => _prices = got);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final state = context.watch<GameState>();
    final t = state.t;
    final prices = _prices;
    // At a table the picture key sells the animated shelf alone, with no shelf
    // menu (owner, 13 Sep 2026); the lobby keeps every shelf.
    final atTable = widget.atTable;
    final shelf = atTable ? PictureFilter.animated : _shelf;
    final tab = _tab;
    final onPictures = tab == StoreTab.pictures;
    final onDiamonds = tab == StoreTab.diamonds;
    final onHammers = tab == StoreTab.hammers;
    // The picture being worn, when it is one of the catalogue's, for the
    // Pictures tab's header; null leaves the provider photo or the initial.
    final wornMatches = state.pictures.where(
      (p) => p.id == state.user?.activePictureId,
    );
    final worn = wornMatches.isEmpty ? null : wornMatches.first;
    final wornR = (MediaQuery.sizeOf(context).height * 0.10).clamp(28.0, 48.0);
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
    // The tabs keep their words while the title beside them keeps some room of
    // its own. The header row is the screen less the safe area, the sheet's
    // margin and its padding; its fixed parts are the shelf's glyph, a
    // balance, the close key and the gaps between them. A balance is counted
    // on every shelf, although Chips shows none, so the tabs never change size
    // — and move under a finger — on the way from one shelf to the next.
    final safe = MediaQuery.paddingOf(context);
    final headerW =
        size.width - safe.left - safe.right - 2 * Space.md - 2 * Space.lg;
    const balanceW = 72.0;
    const titleFloor = 96.0;
    final fixedW =
        22 +
        Space.md +
        Space.md +
        balanceW +
        Space.md +
        Space.sm +
        Dim.minTouch;
    final compactTabs =
        headerW - fixedW - titleFloor <
        _StoreTabs.labelledWidth(context, t, animatedOnly: atTable);

    // A shelf of packs: near-square cards, the lobby card's proportions, set
    // out one stagger apart. Keyed by shelf, so moving from one pack shelf to
    // another sets the new one out afresh instead of reusing the last one's
    // cards.
    Widget packShelf(StoreTab shelf, List<Widget> cards) => Wrap(
      spacing: Space.md,
      runSpacing: Space.md,
      children: [
        for (final (i, card) in cards.indexed)
          SizedBox(
            key: ValueKey('${shelf.name}-$i'),
            width: Dim.packW(size.width),
            height: Dim.packW(size.width) * 1.05,
            child: _PackEntrance(index: i, child: card),
          ),
      ],
    );
    // Sits at the foot of the screen like the picture picker's sheet, rather
    // than in the middle of it: the two shelves are the same kind of thing and
    // should arrive in the same place.
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
          // One height whatever the shelf holds, so the header and its tabs
          // stay put from Chips to Diamonds to Pictures. Sized to its content,
          // the sheet shrank under the four diamond packs, and a tap aimed at
          // the next tab landed on the scrim and closed the store. Only the
          // packs scroll.
          child: SizedBox(
            height: size.height * 0.88,
            child: PremiumGlassPanel(
              // A modal, and the only one of its kind on screen: it may take the
              // app's single blur if nothing louder has claimed it. The blur
              // radius is the theme's own (GlassColors.sigma).
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
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(Radii.pill),
                        color: AppTheme.hairlineColour(
                          theme.brightness,
                          live: true,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  SizedBox(
                    height: headerH,
                    child: Row(
                      children: [
                        onPictures
                            ? const Icon(
                                Icons.face_rounded,
                                size: 22,
                                color: AppTheme.goldBright,
                              )
                            : onDiamonds
                            ? Icon(
                                Icons.diamond_rounded,
                                size: 22,
                                color: diamondInkOn(theme.brightness),
                              )
                            : onHammers
                            ? Icon(
                                Icons.hardware,
                                size: 22,
                                color: hammerInkOn(theme.brightness),
                              )
                            : const PokerChip(colour: AppTheme.gold, size: 22),
                        const SizedBox(width: Space.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                onPictures
                                    ? (atTable
                                          ? t.picturePremiumAnimated
                                          : t.storeTabPictures)
                                    : onDiamonds
                                    ? t.storeDiamondsTitle
                                    : onHammers
                                    ? t.storeHammersTitle
                                    : t.storeTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTheme.label(
                                  theme.textTheme.titleMedium ??
                                      const TextStyle(),
                                ),
                              ),
                              Text(
                                onPictures
                                    ? (atTable
                                          ? t.storeAnimatedBlurb
                                          : t.storePicturesBlurb)
                                    : onDiamonds
                                    ? t.storeDiamondsBlurb
                                    : onHammers
                                    ? t.storeHammersBlurb
                                    : t.storeBlurb,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurface.withValues(
                                    alpha: AppTheme.inkLowOn(theme.brightness),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: Space.md),
                        // The diamond balance stands before the tabs, not after
                        // them. It shows on Diamonds and Pictures only, and
                        // between the tabs and the close key its coming and
                        // going slid the whole tab row sideways, so a tap on a
                        // tab where it had just been landed on the balance.
                        // Here the title gives up the room instead, and the
                        // tabs stay anchored to the close key on every shelf.
                        if (onPictures || onDiamonds) ...[
                          DiamondBalance(count: state.user?.diamond ?? 0),
                          const SizedBox(width: Space.md),
                        ],
                        if (onHammers) ...[
                          HammerBalance(count: state.user?.hammer ?? 0),
                          const SizedBox(width: Space.md),
                        ],
                        _StoreTabs(
                          value: tab,
                          animatedOnly: atTable,
                          compact: compactTabs,
                          onChanged: (next) => setState(() {
                            _tab = next;
                            _toTop();
                          }),
                        ),
                        const SizedBox(width: Space.sm),
                        PressScale(
                          child: IconButton(
                            tooltip: t.close,
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close_rounded, size: 20),
                            // A Material icon button lays out at 48 whatever its
                            // icon does, which is 4dp more than the header is
                            // tall. The touch floor is Dim.minTouch, so say so.
                            style: IconButton.styleFrom(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              minimumSize: const Size.square(Dim.minTouch),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  // The picture shelf's filter, pinned above its grid exactly as
                  // in the picker.
                  if (onPictures) ...[
                    // The picture being worn, large and centred at the top of the
                    // tab, with the shelf's filter on the left of the same row: the
                    // player shops with their current face in view, and the row costs
                    // the sheet no more height than it has to.
                    SizedBox(
                      height: wornR * 2 + 11 + Space.xs + 18,
                      child: Stack(
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: atTable
                                ? const SizedBox.shrink()
                                : PictureFilterMenu(
                                    value: _shelf,
                                    counts: {
                                      for (final f in PictureFilter.values)
                                        f: state.pictures.where(f.holds).length,
                                    },
                                    onChanged: (f) => setState(() {
                                      _shelf = f;
                                      _toTop();
                                    }),
                                  ),
                          ),
                          Align(
                            alignment: Alignment.center,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Avatar(
                                  url: state.avatarUrl,
                                  format: worn?.assetFormat,
                                  fallback: state.user?.displayName ?? '',
                                  radius: wornR,
                                  ring: AppTheme.goldBright,
                                  ringWidth: 2.5,
                                  ringGap: 3,
                                  animate: true,
                                ),
                                const SizedBox(height: Space.xs),
                                SizedBox(
                                  // Capped, so a long name can never run into the menu.
                                  width: wornR * 2 + 48,
                                  child: Text(
                                    worn?.name ?? t.yourPicture,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: AppTheme.label(
                                      theme.textTheme.labelMedium!,
                                      colour: scheme.onSurface.withValues(
                                        alpha: AppTheme.inkMed,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                  ],
                  // Expanded, so a short shelf sits at the top of the fixed
                  // body rather than letting the sheet shrink around it.
                  Expanded(
                    child: ScrollbarTheme(
                      data: ScrollbarThemeData(
                        thickness: const WidgetStatePropertyAll(4),
                        radius: const Radius.circular(Radii.pill),
                        thumbColor: WidgetStatePropertyAll(
                          AppTheme.hairlineColour(theme.brightness, live: true),
                        ),
                      ),
                      child: Scrollbar(
                        controller: _scroller,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: _scroller,
                          padding: const EdgeInsets.only(right: Space.md),
                          child: onPictures
                              ? SizedBox(
                                  // Full width, so the grid starts under its menu rather than
                                  // centring in the sheet the way the pack shelf does.
                                  width: double.infinity,
                                  child: pictureShelf(
                                    context: context,
                                    state: state,
                                    filter: shelf,
                                    // The picker's tile size, so a face is the same
                                    // size wherever it is on sale.
                                    radius: (size.height * 0.105).clamp(
                                      32.0,
                                      52.0,
                                    ),
                                  ),
                                )
                              : onDiamonds
                              ? packShelf(StoreTab.diamonds, [
                                  for (final (i, p) in diamondPacks.indexed)
                                    _CountPackCard.diamonds(
                                      p,
                                      index: i,
                                      prices: prices,
                                    ),
                                ])
                              : onHammers
                              ? packShelf(StoreTab.hammers, [
                                  for (final (i, p) in hammerPacks.indexed)
                                    _CountPackCard.hammers(
                                      p,
                                      index: i,
                                      prices: prices,
                                    ),
                                ])
                              : Wrap(
                                  spacing: Space.md,
                                  runSpacing: Space.md,
                                  children: [
                                    for (var i = 0; i < chipPacks.length; i++)
                                      SizedBox(
                                        // The lobby card's proportions: near square.
                                        width: Dim.packW(size.width),
                                        height: Dim.packW(size.width) * 1.05,
                                        child: _PackEntrance(
                                          index: i,
                                          child: _PackCard(
                                            pack: chipPacks[i],
                                            index: i,
                                            prices: prices,
                                          ),
                                        ),
                                      ),
                                  ],
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
    );
  }
}

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
    required this.index,
    required this.prices,
  });

  final ChipPack pack;

  /// Where the pack sits in the range, which decides its colour.
  final int index;

  /// What Play says these cost, keyed by product id. Empty when Play is
  /// unavailable or has not answered yet, and then the card falls back to the
  /// list price — an approximate figure beats an empty shelf, and the real one
  /// is always shown on Play's own sheet before anyone is charged.
  final Map<String, ProductDetails> prices;

  @override
  State<_PackCard> createState() => _PackCardState();
}

/// One pack, drawn as the same card as a lobby table.
///
/// The store's cards match the lobby's part for part: frosted white glass over
/// a baked colour orb, a plate in the card's colour at the head, the figure
/// large beside a chip stack, one line of small print, and a glass capsule
/// along the foot — carrying the price where a table carries "Tap to sit
/// down". Colour climbs the range the way it climbs the lobby rail: sapphire
/// for the first three packs, royal purple for the next three, gold for the
/// top three, so the shelf reads from modest to rich at a glance.
class _PackCardState extends State<_PackCard> {
  bool _down = false;

  /// A marked pack names its place in the range; an unmarked one leads with
  /// its bonus, which is the reason to pick it.
  String _plateLabel(Strings t) => switch (widget.pack.mark) {
    ShelfMark.starter => t.posStarter,
    ShelfMark.popular => t.posPopular,
    ShelfMark.bestValue => t.posBestValue,
    ShelfMark.premium => t.posPremium,
    ShelfMark.none => '${widget.pack.bonusPercent}% ${t.storeBonus}',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final dark = theme.brightness == Brightness.dark;
    final state = context.watch<GameState>();
    final t = state.t;
    final p = widget.pack;
    final prices = widget.prices;
    final palette = AppTheme.paletteFor(
      theme.colorScheme,
      category: widget.index >= 6 ? 'seen' : 'blind',
      bootAmount: widget.index >= 3 ? 5000 : 200,
    );
    final accent = palette.accent;
    final champagne = dark ? AppTheme.goldBright : AppTheme.goldDeep;

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
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final h = box.maxHeight;
          final s = math.min(w, h);
          final pad = (s * 0.075).clamp(8.0, 14.0);
          final plateH = (s * 0.15).clamp(20.0, 28.0);
          final figure = (s * 0.17).clamp(18.0, 30.0);
          final factH = (s * 0.11).clamp(15.0, 20.0);
          final ctaH = (s * 0.20).clamp(28.0, 36.0);

          // Up and to the right, and almost wholly inside the card: the shelf
          // scrolls, and a scroll view clips whatever spills past it.
          final colours = orbColours(accent);
          final orb = Rect.fromCenter(
            center: Offset(w * 0.80, h * 0.34),
            width: s * 0.62,
            height: s * 0.62,
          );

          final panel = PremiumGlassPanel(
            mode: GlassMode.tinted,
            radius: Radii.lg,
            live: p.featured,
            padding: EdgeInsets.zero,
            tint: Colors.white,
            behind: Stack(
              children: [
                Positioned.fromRect(
                  rect: orb,
                  child: GlassOrb(
                    colours: colours,
                    size: orb.width,
                    soft: true,
                    opacity: dark ? 0.62 : 0.46,
                  ),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                // Material's own click, gated on the player's Sound switch —
                // otherwise a silenced game would still tick on every tap.
                enableFeedback: context.select<FeedbackSettings, bool>(
                  (f) => f.sound,
                ),
                borderRadius: BorderRadius.circular(Radii.lg),
                onTap: () {
                  tapHaptic(context);
                  buy();
                },
                onTapDown: (_) => setState(() => _down = true),
                onTapCancel: () => setState(() => _down = false),
                onTapUp: (_) => setState(() => _down = false),
                splashColor: accent.withValues(alpha: 0.12),
                highlightColor: accent.withValues(alpha: 0.06),
                child: Padding(
                  padding: EdgeInsets.all(pad),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PackPlate(
                        label: _plateLabel(t),
                        palette: palette,
                        height: plateH,
                      ),
                      const Spacer(),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          LivelyChipStack(
                            size: figure * 0.62,
                            colours: [
                              accent,
                              Color.lerp(accent, AppTheme.ink900, 0.35)!,
                              accent,
                            ],
                          ),
                          const SizedBox(width: Space.sm),
                          Expanded(
                            child: RepaintBoundary(
                              child: TweenAnimationBuilder<double>(
                                tween: Tween(end: p.chips.toDouble()),
                                duration: const Duration(milliseconds: 700),
                                curve: Motion.standard,
                                builder: (context, value, _) => FittedBox(
                                  // "5 Billion" and "5,00,00,00,000" are the
                                  // same card, so the figure shrinks rather
                                  // than wraps or ellipsises.
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    formatChips(value.round()),
                                    maxLines: 1,
                                    style: AppTheme.money(
                                      text.displaySmall!,
                                      fontSize: figure,
                                      colour: champagne,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.sm),
                      _PackFact(
                        icon: Icons.redeem_rounded,
                        label: t.storeBonus,
                        value: p.bonusPercent == 0 ? '—' : '${p.bonusPercent}%',
                        accent: accent,
                        height: factH,
                        highlight: p.bonusPercent > 0,
                      ),
                      const Spacer(),
                      _PriceCapsule(
                        label:
                            prices[p.productId]?.price ??
                            '₹${_grouped(p.rupees)}',
                        height: ctaH,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // The sharp orb, behind the card. Its softened twin is in the
              // glass's `behind` slot at the same place.
              Positioned.fromRect(
                rect: orb,
                child: IgnorePointer(
                  child: GlassOrb(
                    colours: colours,
                    size: orb.width,
                    opacity: dark ? 1.0 : 0.9,
                  ),
                ),
              ),
              panel,
            ],
          );
        },
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

/// One diamond or hammer pack, drawn as the same lobby-style card as a chip
/// pack.
///
/// The plate names its place on the shelf (⭐ popular, 🔥 best value), the
/// figure is the count beside the wallet's own glyph in the wallet's own ink,
/// and the price rides the glass capsule along the foot. Colour climbs the
/// shelf the way it climbs the chip packs — sapphire, sapphire, purple, gold —
/// so the shelves read as one store. One card serves both shelves because the
/// two differ in nothing but the glyph, the ink and the word.
class _CountPackCard extends StatefulWidget {
  const _CountPackCard({
    required this.productId,
    required this.rupees,
    required this.count,
    required this.mark,
    required this.icon,
    required this.inkOn,
    required this.unit,
    required this.index,
    required this.prices,
  });

  _CountPackCard.diamonds(
    DiamondPack pack, {
    required int index,
    required Map<String, ProductDetails> prices,
  }) : this(
         productId: pack.productId,
         rupees: pack.rupees,
         count: pack.diamonds,
         mark: pack.mark,
         icon: Icons.diamond_rounded,
         inkOn: diamondInkOn,
         unit: _diamondsWord,
         index: index,
         prices: prices,
       );

  _CountPackCard.hammers(
    HammerPack pack, {
    required int index,
    required Map<String, ProductDetails> prices,
  }) : this(
         productId: pack.productId,
         rupees: pack.rupees,
         count: pack.hammers,
         mark: pack.mark,
         icon: Icons.hardware,
         inkOn: hammerInkOn,
         unit: _hammersWord,
         index: index,
         prices: prices,
       );

  /// The Play Console product id, which is also the key into [prices].
  final String productId;

  /// The list price, shown until Play answers with its own.
  final int rupees;
  final int count;
  final ShelfMark mark;

  /// The wallet's glyph beside the figure.
  final IconData icon;

  /// The wallet's ink on the store's glass, by brightness.
  final Color Function(Brightness) inkOn;

  /// The wallet's name in the player's language, under the figure.
  final String Function(Strings) unit;
  final int index;

  /// Play's prices by product id; empty until Play answers, when the card
  /// falls back to the list price.
  final Map<String, ProductDetails> prices;

  @override
  State<_CountPackCard> createState() => _CountPackCardState();
}

String _diamondsWord(Strings t) => t.storeTabDiamonds;
String _hammersWord(Strings t) => t.storeTabHammers;

class _CountPackCardState extends State<_CountPackCard> {
  bool _down = false;

  String _plateLabel(Strings t) => switch (widget.mark) {
    ShelfMark.popular => '⭐ ${t.posPopular}',
    ShelfMark.bestValue => '🔥 ${t.posBestValue}',
    ShelfMark.starter => t.posStarter,
    ShelfMark.premium => t.posPremium,
    ShelfMark.none => widget.unit(t).toUpperCase(),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final dark = theme.brightness == Brightness.dark;
    final state = context.watch<GameState>();
    final t = state.t;
    final prices = widget.prices;
    final palette = AppTheme.paletteFor(
      theme.colorScheme,
      category: widget.index >= 3 ? 'seen' : 'blind',
      bootAmount: widget.index >= 2 ? 5000 : 200,
    );
    final accent = palette.accent;
    final ink = widget.inkOn(theme.brightness);

    void buy() {
      // The same rule as a chip pack: Play is the only thing that takes money,
      // and it is not always there. Say so rather than fail at the sheet.
      final details = prices[widget.productId];
      if (!state.purchases.available || details == null) {
        state.notice = t.storeNotLive;
        Navigator.pop(context);
        return;
      }
      // The result arrives on the purchase stream; the server credits the
      // wallet the product names, and the balance updates from its answer.
      state.purchases.buy(details);
      Navigator.pop(context);
    }

    return AnimatedScale(
      scale: _down ? 0.955 : 1,
      duration: Motion.fast,
      curve: Motion.standard,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final h = box.maxHeight;
          final s = math.min(w, h);
          final pad = (s * 0.075).clamp(8.0, 14.0);
          final plateH = (s * 0.15).clamp(20.0, 28.0);
          final figure = (s * 0.19).clamp(20.0, 34.0);
          final ctaH = (s * 0.20).clamp(28.0, 36.0);

          final colours = orbColours(accent);
          final orb = Rect.fromCenter(
            center: Offset(w * 0.80, h * 0.34),
            width: s * 0.62,
            height: s * 0.62,
          );

          final panel = PremiumGlassPanel(
            mode: GlassMode.tinted,
            radius: Radii.lg,
            live: widget.mark == ShelfMark.bestValue,
            padding: EdgeInsets.zero,
            tint: Colors.white,
            behind: Stack(
              children: [
                Positioned.fromRect(
                  rect: orb,
                  child: GlassOrb(
                    colours: colours,
                    size: orb.width,
                    soft: true,
                    opacity: dark ? 0.62 : 0.46,
                  ),
                ),
              ],
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                enableFeedback: context.select<FeedbackSettings, bool>(
                  (f) => f.sound,
                ),
                borderRadius: BorderRadius.circular(Radii.lg),
                onTap: () {
                  tapHaptic(context);
                  buy();
                },
                onTapDown: (_) => setState(() => _down = true),
                onTapCancel: () => setState(() => _down = false),
                onTapUp: (_) => setState(() => _down = false),
                splashColor: accent.withValues(alpha: 0.12),
                highlightColor: accent.withValues(alpha: 0.06),
                child: Padding(
                  padding: EdgeInsets.all(pad),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PackPlate(
                        label: _plateLabel(t),
                        palette: palette,
                        height: plateH,
                      ),
                      const Spacer(),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Icon(widget.icon, size: figure, color: ink),
                          const SizedBox(width: Space.sm),
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '${widget.count}',
                                maxLines: 1,
                                style: AppTheme.money(
                                  text.displaySmall!,
                                  fontSize: figure,
                                  colour: ink,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        widget.unit(t),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(
                          color: GlassColors.of(context).textBody,
                        ),
                      ),
                      const Spacer(),
                      _PriceCapsule(
                        label:
                            prices[widget.productId]?.price ??
                            '₹${_grouped(widget.rupees)}',
                        height: ctaH,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fromRect(
                rect: orb,
                child: IgnorePointer(
                  child: GlassOrb(
                    colours: colours,
                    size: orb.width,
                    opacity: dark ? 1.0 : 0.9,
                  ),
                ),
              ),
              panel,
            ],
          );
        },
      ),
    );
  }
}

/// The plate at the head of a pack card: the lobby's category plate, still.
///
/// The lobby's plate breathes and turns its chip; nine of them doing so at once
/// is the flickering shelf the store's cards were rebuilt to get away from, so
/// this one keeps the plate's colour and shape and none of its motion.
class _PackPlate extends StatelessWidget {
  const _PackPlate({
    required this.label,
    required this.palette,
    required this.height,
  });

  final String label;
  final TablePalette palette;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final h = height;

    return Container(
      height: h,
      padding: EdgeInsets.symmetric(horizontal: h * 0.30),
      decoration: BoxDecoration(
        color: palette.container,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PokerChip(colour: palette.accent, size: h * 0.58),
          SizedBox(width: h * 0.24),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // label, not smallCaps: these words are translated, and tracking
              // pulls Gujarati or Gurmukhi apart.
              style: AppTheme.label(
                theme.textTheme.labelLarge!,
                fontSize: (h * 0.40).clamp(9.5, 13.0),
                colour: palette.onContainer,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One line of small print on a pack card, in the lobby card's layout: an
/// icon, what it is, and what it is set to.
class _PackFact extends StatelessWidget {
  const _PackFact({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
    required this.height,
    this.highlight = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  final double height;

  /// Draws the value in the card's colour, for the fact worth noticing.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final glass = GlassColors.of(context);
    final size = (height * 0.62).clamp(10.0, 13.0);

    return SizedBox(
      height: height,
      child: Row(
        children: [
          Icon(icon, size: height * 0.80, color: glass.textMuted),
          const SizedBox(width: Space.xs),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(
                fontSize: size,
                color: glass.textBody,
              ),
            ),
          ),
          const SizedBox(width: Space.xs),
          Text(
            value,
            maxLines: 1,
            style: AppTheme.money(
              text.labelLarge!,
              fontSize: size,
              colour: highlight ? accent : glass.textDisplay,
            ),
          ),
        ],
      ),
    );
  }
}

/// The price along a pack card's foot: the lobby card's glass capsule.
///
/// Not a button of its own — the whole card is the target, as a lobby card is
/// — so it carries no ink response.
class _PriceCapsule extends StatelessWidget {
  const _PriceCapsule({required this.label, required this.height});

  final String label;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = GlassColors.of(context).textDisplay;

    return Container(
      height: height,
      width: double.infinity,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.20),
            Colors.white.withValues(alpha: 0.07),
          ],
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.34),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.16),
            offset: const Offset(0, -0.5),
            spreadRadius: -0.5,
          ),
          BoxShadow(
            color: AppTheme.ink900.withValues(alpha: 0.30),
            offset: const Offset(0, 2),
            blurRadius: 8,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.money(
                theme.textTheme.titleSmall!,
                fontSize: (height * 0.42).clamp(12.0, 16.0),
                colour: ink,
              ),
            ),
          ),
          const SizedBox(width: Space.sm),
          Icon(Icons.arrow_forward_rounded, size: height * 0.44, color: ink),
        ],
      ),
    );
  }
}
