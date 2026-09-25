/// The picture shelf: the catalogue's filter, its grid of tiles, the unlock
/// dialog and the store's offer when a wallet is short, the already-unlocked
/// popup, and the wallet balances.
///
/// Shared by every place a picture is chosen or bought — the picker behind
/// the lobby's avatar, the store's Pictures tab and its Animated tab at a
/// table — so they can never disagree about what a locked tile looks like or
/// what tapping one does.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../settings/feedback_settings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import 'avatar.dart';
import 'chip_store.dart';
import 'glass_components.dart';
import 'glass_panels.dart';
import 'poker_chip.dart';

/// The shelves of a picture list: everything, then the premium pictures by
/// the wallet they are bought from — chips, hammers, diamonds (owner, 14 Sep
/// 2026; the menu offered Free, Premium and Premium (Animated) before). A free
/// picture is on All alone. A currency this build does not know is shelved
/// with chips, as its price tag is drawn.
///
/// [animated] is not in the menu ([menu]): it is the shelf the store sells at
/// a table, where the moving pictures alone are on offer.
enum PictureFilter {
  all,
  chips,
  hammers,
  diamonds,
  animated;

  /// The shelves the menu offers, in its order.
  static const menu = [
    PictureFilter.all,
    PictureFilter.chips,
    PictureFilter.hammers,
    PictureFilter.diamonds,
  ];

  bool holds(ProfilePicture p) => switch (this) {
    PictureFilter.all => true,
    PictureFilter.chips =>
      !p.free &&
          p.currency != PictureCurrency.hammer &&
          p.currency != PictureCurrency.diamond,
    PictureFilter.hammers => !p.free && p.currency == PictureCurrency.hammer,
    PictureFilter.diamonds => !p.free && p.currency == PictureCurrency.diamond,
    PictureFilter.animated => !p.free && p.animated,
  };
}

/// The orders a shelf can be drawn in, picked from the menu on the right of
/// the shelf menu ([PictureSortMenu], owner 14 Sep 2026): by price, cheapest
/// first (the default) or dearest first.
enum PictureSort { lowToHigh, highToLow }

/// The order a shelf draws its pictures in: by price, [sort] deciding which
/// way (owner, 14 Sep 2026; until then the catalogue's own order, with only
/// the premium animated pictures re-dealt cheapest first).
///
/// Chip, hammer and diamond prices are not comparable figures, so on a shelf
/// holding more than one wallet each wallet's pictures are sorted among
/// themselves and the wallets keep an order of their own ([_currencyRank]):
/// chips, then hammers, then diamonds, whichever way the prices run. A free
/// picture is the cheapest of all — first low to high, last high to low.
/// Equal prices keep the catalogue's order: Dart's sort is not stable, hence
/// the index as the last word.
List<ProfilePicture> shelfOrder(
  List<ProfilePicture> pictures, [
  PictureSort sort = PictureSort.lowToHigh,
]) {
  final down = sort == PictureSort.highToLow;
  int group(ProfilePicture p) =>
      p.free ? (down ? 3 : -1) : _currencyRank(p.currency);
  final order = [for (var i = 0; i < pictures.length; i++) i]
    ..sort((i, k) {
      final a = pictures[i], b = pictures[k];
      final byGroup = group(a).compareTo(group(b));
      if (byGroup != 0) return byGroup;
      final byCost = down ? b.cost.compareTo(a.cost) : a.cost.compareTo(b.cost);
      return byCost != 0 ? byCost : i.compareTo(k);
    });
  return [for (final i in order) pictures[i]];
}

/// Where a currency's pictures stand on a shelf: chips first — a currency this
/// build does not know with them, since it is drawn as chips — then hammers,
/// then the diamonds that cost real money.
int _currencyRank(String currency) => switch (currency) {
  PictureCurrency.hammer => 1,
  PictureCurrency.diamond => 2,
  _ => 0,
};

/// The pictures on one shelf.
///
/// An empty shelf says so rather than showing nothing: a blank space under
/// the menu would read as a picker that failed to load. [openStore] is how a
/// shelf inside the store moves the store to the Hammers or Diamonds shelf
/// when a picture's wallet is short ([unlockPicture]); elsewhere it is null
/// and the store is opened instead. [sort] is the order menu's choice
/// ([shelfOrder]).
Widget pictureShelf({
  required BuildContext context,
  required GameState state,
  required PictureFilter filter,
  required double radius,
  PictureSort sort = PictureSort.lowToHigh,
  ValueChanged<StoreTab>? openStore,
}) {
  final pictures = shelfOrder(
    state.pictures.where(filter.holds).toList(),
    sort,
  );
  final user = state.user;

  if (pictures.isEmpty) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xl),
      child: Center(
        child: Text(
          state.t.pictureShelfEmpty,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(
              alpha: AppTheme.inkMed,
            ),
          ),
        ),
      ),
    );
  }

  return Padding(
    padding: const EdgeInsets.only(bottom: Space.md),
    child: ShelfGrid(
      tileWidth: PictureChoice.widthFor(radius),
      children: [
        for (final (i, p) in pictures.indexed)
          ShelfTileEntrance(
            // Keyed by the picture, so a tile keeps its state — its entrance
            // run once, its ring's switcher — when the shelf is sorted, a
            // purchase re-reads the catalogue, or the clock ticks.
            key: ValueKey(p.id),
            index: i,
            child: PictureChoice(
              picture: p,
              radius: radius,
              selected: user?.activePictureId == p.id,
              busy: state.buyingPicture == p.id,
              // One answer per kind of tile. A locked picture asks to be
              // bought. A premium one already paid for stops to say so, and
              // for how long, before it is worn: the tile's "12d left" is all
              // its owner otherwise sees of the rental, and on the last day
              // that line cannot tell twenty hours from twenty minutes. A free
              // picture has nothing to say, so a tap simply wears it.
              onTap: () => p.locked
                  ? unlockPicture(context, p, openStore: openStore)
                  : p.free
                  ? state.chooseAvatar(p.id)
                  : showOwnedPicture(context, p),
            ),
          ),
      ],
    ),
  );
}

/// A shelf's tiles in whole columns (the store polish, 26 Sep 2026: "Are
/// cards aligned?"). The block is centred in the width it is given — flush
/// left, a tablet's nine columns left about 95dp empty on the right and 20 on
/// the left (QA 14 Sep 2026) — but every row inside it, the last one too,
/// starts at the block's left edge: a centred Wrap set a short last row
/// between the columns above it. Every child is [tileWidth] wide, as both
/// shelves' tiles are.
class ShelfGrid extends StatelessWidget {
  const ShelfGrid({
    super.key,
    required this.tileWidth,
    required this.children,
    this.spacing = Space.md,
    this.runSpacing = Space.lg,
  });

  final double tileWidth;
  final List<Widget> children;

  /// Between two tiles of a row, and between two rows. A row ends on type
  /// — a name, a term — so rows stand further apart than tiles do.
  final double spacing;
  final double runSpacing;

  /// How many tiles stand in a row of [width].
  static int columnsFor(double width, double tileWidth, double spacing) =>
      math.max(1, ((width + spacing) / (tileWidth + spacing)).floor());

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final wrap = Wrap(
        spacing: spacing,
        runSpacing: runSpacing,
        children: children,
      );
      if (!box.hasBoundedWidth || children.isEmpty) return wrap;
      final across = math.min(
        columnsFor(box.maxWidth, tileWidth, spacing),
        children.length,
      );
      // Half a dp over the sum, so rounding can never push the last tile of
      // a full row onto a row of its own.
      final width = across * tileWidth + (across - 1) * spacing + 0.5;
      return Center(
        child: SizedBox(width: math.min(width, box.maxWidth), child: wrap),
      );
    },
  );
}

/// A tile arriving on a shelf: faded in and risen a few dp, a beat after the
/// tile before it (the store polish, 26 Sep 2026: "Product card: very subtle
/// entrance animation"). It runs once per tile — keyed by its picture, a tile
/// that stays on the shelf through a tick, a sort or a purchase never runs it
/// again, while one a new shelf brings does — and the beat is capped at
/// [maxBeats], so the last tile of a long shelf is not kept waiting behind
/// forty others. One controller a tile, idle once the tile has arrived.
class ShelfTileEntrance extends StatefulWidget {
  const ShelfTileEntrance({
    super.key,
    required this.index,
    required this.child,
  });

  /// The tile's place on the shelf, which decides its beat.
  final int index;
  final Widget child;

  /// The most beats ([Motion.stagger] each) a tile waits: the whole shelf is
  /// in place within [Motion.stagger] × 6 + [Motion.enter].
  static const int maxBeats = 6;

  @override
  State<ShelfTileEntrance> createState() => _ShelfTileEntranceState();
}

class _ShelfTileEntranceState extends State<ShelfTileEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _arrive;
  late final CurvedAnimation _eased;
  late final Animation<Offset> _rise;

  @override
  void initState() {
    super.initState();
    // The beat is the head of the tile's own run rather than a timer before
    // it: every tile starts on the shelf's first frame and simply holds still
    // for its beat, so nothing is left pending when a shelf closes within it.
    final wait =
        Motion.stagger * math.min(widget.index, ShelfTileEntrance.maxBeats);
    final run = wait + Motion.enter;
    _arrive = AnimationController(vsync: this, duration: run)..forward();
    _eased = CurvedAnimation(
      parent: _arrive,
      curve: Interval(
        wait.inMicroseconds / run.inMicroseconds,
        1,
        curve: Motion.standard,
      ),
    );
    _rise = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(_eased);
  }

  @override
  void dispose() {
    _eased.dispose();
    _arrive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _eased,
    child: SlideTransition(position: _rise, child: widget.child),
  );
}

/// The shelf menu at the top of the picture picker.
///
/// A pill in the theme's own colours (owner, 14 Sep 2026; it was the price
/// tags' dark ink in both themes, so the day sheet carried a night pill):
/// charcoal with light type at night, a slate well with charcoal type by day,
/// gold-rimmed in both. The wallet glyphs take each theme's ink for their
/// currency, as the balances do. Each entry carries its shelf's count: that is
/// what tells a player a shelf is worth opening.
class PictureFilterMenu extends StatelessWidget {
  const PictureFilterMenu({
    super.key,
    required this.value,
    required this.counts,
    required this.onChanged,
  });

  final PictureFilter value;
  final Map<PictureFilter, int> counts;
  final ValueChanged<PictureFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.read<GameState>().t;
    final brightness = theme.brightness;
    final night = brightness == Brightness.dark;
    final glass = GlassColors.of(context);
    final ink = night ? const Color(0xE6FFFFFF) : glass.textDisplay;
    final quiet = night ? const Color(0x99FFFFFF) : glass.textMuted;
    // The gold that reads on the pill: pale on charcoal, deep on slate.
    final gold = night ? AppTheme.goldBright : AppTheme.goldDeep;

    Widget entry(PictureFilter f) {
      // Each premium shelf wears its wallet's own glyph, as the price tags and
      // the balances do: a chip, the hammer, the gem. All three say
      // "Premium", so a screen reader is told the wallet as well.
      final (
        Widget glyph,
        Color colour,
        String label,
        String? wallet,
      ) = switch (f) {
        PictureFilter.all => (
          Icon(Icons.grid_view_rounded, size: 14, color: ink),
          ink,
          t.pictureAll,
          null,
        ),
        PictureFilter.chips => (
          const PokerChip(colour: AppTheme.gold, size: 14),
          gold,
          t.picturePremium,
          t.storeTabChips,
        ),
        PictureFilter.hammers => (
          Icon(Icons.hardware, size: 14, color: hammerInkOn(brightness)),
          gold,
          t.picturePremium,
          t.storeTabHammers,
        ),
        PictureFilter.diamonds => (
          Icon(Icons.diamond, size: 14, color: diamondInkOn(brightness)),
          gold,
          t.picturePremium,
          t.storeTabDiamonds,
        ),
        PictureFilter.animated => (
          Icon(Icons.auto_awesome, size: 14, color: gold),
          gold,
          t.picturePremiumAnimated,
          null,
        ),
      };
      final count = counts[f] ?? 0;
      return Semantics(
        label: wallet == null ? '$label, $count' : '$label ($wallet), $count',
        excludeSemantics: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            glyph,
            const SizedBox(width: Space.sm),
            Text(
              label,
              style: AppTheme.label(
                theme.textTheme.labelMedium ?? const TextStyle(),
                colour: colour,
              ),
            ),
            const SizedBox(width: Space.sm),
            Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(color: quiet),
            ),
          ],
        ),
      );
    }

    return _ShelfPill(
      child: DropdownButton<PictureFilter>(
        value: value,
        isDense: true,
        padding: const EdgeInsets.symmetric(vertical: Space.sm),
        borderRadius: BorderRadius.circular(Radii.md),
        dropdownColor: night ? AppTheme.ink900 : Colors.white,
        iconEnabledColor: quiet,
        icon: const Icon(Icons.expand_more, size: 18),
        items: [
          for (final f in PictureFilter.menu)
            DropdownMenuItem(value: f, child: entry(f)),
        ],
        onChanged: (f) {
          if (f != null) onChanged(f);
        },
      ),
    );
  }
}

/// The pill the shelf's menus sit in: charcoal at night, a slate well by day,
/// gold-rimmed in both ([PictureFilterMenu], [PictureSortMenu]).
class _ShelfPill extends StatelessWidget {
  const _ShelfPill({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final night = Theme.of(context).brightness == Brightness.dark;
    final glass = GlassColors.of(context);
    final gold = night ? AppTheme.goldBright : AppTheme.goldDeep;
    return Container(
      padding: const EdgeInsets.only(left: Space.md, right: Space.xs),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        color: night ? AppTheme.ink900.withValues(alpha: 0.82) : glass.wellFill,
        border: Border.all(color: gold.withValues(alpha: night ? 0.45 : 0.55)),
      ),
      child: DropdownButtonHideUnderline(child: child),
    );
  }
}

/// The order menu on the right of the shelf menu (owner, 14 Sep 2026): price
/// low to high, or high to low, on whichever shelf is showing ([shelfOrder]).
/// The same pill as [PictureFilterMenu], so the two read as one row of
/// controls; the arrow says which way the prices run.
class PictureSortMenu extends StatelessWidget {
  const PictureSortMenu({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final PictureSort value;
  final ValueChanged<PictureSort> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.read<GameState>().t;
    final night = theme.brightness == Brightness.dark;
    final glass = GlassColors.of(context);
    final ink = night ? const Color(0xE6FFFFFF) : glass.textDisplay;
    final quiet = night ? const Color(0x99FFFFFF) : glass.textMuted;
    final gold = night ? AppTheme.goldBright : AppTheme.goldDeep;

    Widget entry(PictureSort s) {
      final (icon, label) = switch (s) {
        PictureSort.lowToHigh => (Icons.arrow_upward_rounded, t.priceLowToHigh),
        PictureSort.highToLow => (
          Icons.arrow_downward_rounded,
          t.priceHighToLow,
        ),
      };
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: gold),
          const SizedBox(width: Space.sm),
          Text(
            label,
            style: AppTheme.label(
              theme.textTheme.labelMedium ?? const TextStyle(),
              colour: ink,
            ),
          ),
        ],
      );
    }

    return _ShelfPill(
      child: DropdownButton<PictureSort>(
        value: value,
        isDense: true,
        padding: const EdgeInsets.symmetric(vertical: Space.sm),
        borderRadius: BorderRadius.circular(Radii.md),
        dropdownColor: night ? AppTheme.ink900 : Colors.white,
        iconEnabledColor: quiet,
        icon: const Icon(Icons.expand_more, size: 18),
        items: [
          for (final s in PictureSort.values)
            DropdownMenuItem(value: s, child: entry(s)),
        ],
        onChanged: (s) {
          if (s != null) onChanged(s);
        },
      ),
    );
  }
}

/// Whether [picture] may be bought where the player is: anywhere, except a
/// chip-priced one at a table (owner, 14 Sep 2026). A seated player's chips
/// move only at the table's checkpoints, so the server sells them only the
/// pictures priced in hammers or diamonds. Only an exact 'COIN' is held back
/// here — a currency this build does not know is left for the server to
/// answer.
bool pictureSellsHere(ProfilePicture picture, {required bool atTable}) =>
    !atTable || picture.currency != PictureCurrency.coin;

/// Whether [user] holds enough for [picture], as far as this phone knows.
///
/// Only the hammer and diamond wallets are counted: they are what the store's
/// shelves refill, so a shortage is worth offering one before the question is
/// asked. Chips — and a currency this build does not know — are left to the
/// server, as they always were.
bool canAffordPicture(ProfilePicture picture, User? user) =>
    switch (picture.currency) {
      PictureCurrency.hammer => (user?.hammer ?? 0) >= picture.cost,
      PictureCurrency.diamond => (user?.diamond ?? 0) >= picture.cost,
      _ => true,
    };

/// The store shelf that refills the wallet [picture] is priced in: Hammers or
/// Diamonds, or null for a chip-priced picture, which no offer is made for.
StoreTab? pictureWalletShelf(ProfilePicture picture) =>
    switch (picture.currency) {
      PictureCurrency.hammer => StoreTab.hammers,
      PictureCurrency.diamond => StoreTab.diamonds,
      _ => null,
    };

/// The unlock dialog's sentence for [picture]: what it costs, in the wallet
/// that pays, and for how long when it is a rental. Chip and diamond prices
/// are written out by [formatChips]; a hammer price is a bare count, and one
/// hammer is said in the singular in every language.
String unlockPictureBody(Strings t, ProfilePicture picture) {
  final cost = formatChips(picture.cost);
  final days = picture.durationDays;
  final hours = picture.durationHours;
  return switch (picture.currency) {
    PictureCurrency.hammer =>
      picture.rented
          ? t.unlockRentBodyHammers(
              picture.name,
              picture.cost,
              days,
              hours: hours,
            )
          : t.unlockBodyHammers(picture.name, picture.cost),
    PictureCurrency.diamond =>
      picture.rented
          ? t.unlockRentBodyDiamond(picture.name, cost, days, hours: hours)
          : t.unlockBodyDiamond(picture.name, cost),
    _ =>
      picture.rented
          ? t.unlockRentBody(picture.name, cost, days, hours: hours)
          : t.unlockBody(picture.name, cost),
  };
}

/// What the player holds of the wallet [currency] names, as the picture
/// dialogs show it, or null for chips. Shared with the table shelf.
Widget? walletBalanceFor(GameState state, String currency) =>
    switch (currency) {
      PictureCurrency.hammer => HammerBalance(count: state.user?.hammer ?? 0),
      PictureCurrency.diamond => DiamondBalance(
        count: state.user?.diamond ?? 0,
      ),
      _ => null,
    };

/// Asks before spending on a premium picture, then buys and wears it.
///
/// A confirmation rather than a straight tap-to-buy: this is the only place in
/// the lobby where a tap costs real chips, and a picker is somewhere people
/// browse. Tapping a face should never be how a stack quietly goes down.
///
/// Two answers can come before the question (owner, 14 Sep 2026). A
/// chip-priced picture tapped at a table is refused on the spot
/// ([pictureSellsHere]). One priced in hammers or diamonds the player has too
/// few of is not offered for sale: the store's shelf for that wallet is
/// ([canAffordPicture]), which is also what follows the server's own shortage
/// when this phone's count was out of date. [openStore] moves an open store
/// to that shelf; without it the store is opened on it.
Future<void> unlockPicture(
  BuildContext context,
  ProfilePicture picture, {
  ValueChanged<StoreTab>? openStore,
}) async {
  final state = context.read<GameState>();
  final t = state.t;
  final theme = Theme.of(context);

  if (!pictureSellsHere(picture, atTable: state.screen == Screen.table)) {
    state.say(t.pictureChipsLobbyOnly);
    return;
  }
  if (!canAffordPicture(picture, state.user)) {
    await offerWalletShelf(
      context,
      name: picture.name,
      cost: picture.cost,
      currency: picture.currency,
      preview: _PictureOnOffer(picture: picture),
      openStore: openStore,
    );
    return;
  }
  final balance = walletBalanceFor(state, picture.currency);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: Row(
        children: [
          Icon(Icons.lock_open, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              t.unlockTitle,
              style: AppTheme.label(
                theme.textTheme.titleMedium ?? const TextStyle(),
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PictureOnOffer(picture: picture),
          const SizedBox(height: Space.lg),
          Text(
            // A rental and a purchase are different offers, and the dialog is
            // the last place to say which this is before anything leaves the
            // wallet. The currency names the wallet the cost leaves, so a
            // hammer or diamond row must not be caught saying "chips".
            unlockPictureBody(t, picture),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(
                alpha: AppTheme.inkMed,
              ),
            ),
          ),
          // What the player holds of that wallet, under the price, so the sum
          // is done before Unlock rather than after a refusal.
          if (balance != null) ...[const SizedBox(height: Space.md), balance],
        ],
      ),
      actions: [
        GlassButton(
          style: GlassButtonStyle.text,
          label: t.cancel,
          onPressed: () => Navigator.pop(dialogContext, false),
        ),
        GlassButton(
          style: GlassButtonStyle.primary,
          label: t.unlock,
          onPressed: () => Navigator.pop(dialogContext, true),
        ),
      ],
    ),
  );

  // The server is the authority on whether it can be afforded and whether the
  // player is seated. A refusal comes back as a notice — or, for a wallet the
  // store refills, as the offer of its shelf — rather than being guessed at
  // here.
  if (confirmed != true) return;
  final result = await state.buyPicture(picture.id);
  if (result == PictureBuyResult.notEnough && context.mounted) {
    await offerWalletShelf(
      context,
      name: picture.name,
      cost: picture.cost,
      currency: picture.currency,
      preview: _PictureOnOffer(picture: picture),
      openStore: openStore,
    );
  }
}

/// A premium picture as its dialogs show it: large, at full colour, and
/// playing when animated.
///
/// On the shelf a locked face is a dimmed thumbnail; the unlock question and
/// the "not enough" offer are where it is shown as what the wallet buys. Sized
/// off the screen's height, the scarce axis in landscape; a dialog's body
/// scrolls if it ever runs out.
class _PictureOnOffer extends StatelessWidget {
  const _PictureOnOffer({required this.picture});

  final ProfilePicture picture;

  @override
  Widget build(BuildContext context) => Avatar(
    url: context.read<GameState>().absoluteUrl(picture.url),
    format: picture.assetFormat,
    fallback: picture.name,
    radius: (MediaQuery.sizeOf(context).height * 0.15).clamp(40.0, 80.0),
    // The shelf's gold, which holds its contrast on the day dialog too.
    ring: shelfGoldOn(Theme.of(context).brightness),
    ringWidth: 2.5,
    ringGap: 3,
    animate: true,
  );
}

/// The store's shelf for the wallet [currency] names, offered to a player who
/// cannot pay [cost] for [name]: "Not enough hammers", the [preview] of what
/// they were after, what it costs, what they hold, and a key to the Hammers
/// shelf — or the same for diamonds. Nothing is offered for chips.
///
/// Shared by the picture shelf and the table shelf (owner, 15 Sep 2026), so
/// the two cannot word a shortage differently. [openStore] moves a store that
/// is already open to that shelf, rather than opening a second store over it;
/// without one the store opens on it.
Future<void> offerWalletShelf(
  BuildContext context, {
  required String name,
  required int cost,
  required String currency,
  required Widget preview,
  ValueChanged<StoreTab>? openStore,
}) async {
  final shelf = switch (currency) {
    PictureCurrency.hammer => StoreTab.hammers,
    PictureCurrency.diamond => StoreTab.diamonds,
    _ => null,
  };
  if (shelf == null) return;
  final state = context.read<GameState>();
  final t = state.t;
  final hammers = shelf == StoreTab.hammers;
  final balance = walletBalanceFor(state, currency);

  final go = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return GlassDialog(
        padding: const EdgeInsets.all(Space.xl),
        title: Row(
          children: [
            Icon(
              hammers ? Icons.hardware : Icons.diamond_rounded,
              size: 20,
              color: hammers
                  ? hammerInkOn(theme.brightness)
                  : diamondInkOn(theme.brightness),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                hammers ? t.notEnoughHammersTitle : t.notEnoughDiamondsTitle,
                style: AppTheme.label(
                  theme.textTheme.titleMedium ?? const TextStyle(),
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The picture they were after, as the unlock question shows it
            // (owner, 14 Sep 2026): the offer is of hammers or diamonds, but
            // what the player wants is this face — or this table.
            preview,
            const SizedBox(height: Space.lg),
            Text(
              hammers
                  ? t.notEnoughHammersBody(name, cost)
                  : t.notEnoughDiamondsPictureBody(name, formatChips(cost)),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(
                  alpha: AppTheme.inkMed,
                ),
              ),
            ),
            if (balance != null) ...[const SizedBox(height: Space.md), balance],
          ],
        ),
        actions: [
          GlassButton(
            style: GlassButtonStyle.text,
            label: t.cancel,
            onPressed: () => Navigator.pop(dialogContext, false),
          ),
          GlassButton(
            style: GlassButtonStyle.primary,
            label: hammers ? t.getHammers : t.getDiamonds,
            onPressed: () => Navigator.pop(dialogContext, true),
          ),
        ],
      );
    },
  );
  if (go != true || !context.mounted) return;
  if (openStore != null) {
    openStore(shelf);
  } else {
    await showChipStore(context, opensOn: shelf);
  }
}

/// How long a premium picture this player owns has left, as the
/// already-unlocked popup words it.
///
/// Two units at most, narrowing as the end nears — days and hours, then hours
/// and minutes, then minutes — because "100 days" says nothing useful on the
/// last afternoon and "2,399 hours" nothing useful on the first. The count is
/// rounded UP to the minute, as [ProfilePicture.daysLeft] rounds up to the
/// day, so a rental with seconds to go reads "1 minute left" rather than a
/// "0 minutes" that is neither over nor running.
///
/// [expiresAt] is epoch ms, 0 for a picture that never runs out. [now] is
/// passed in rather than read, so the wording can be tested without a clock.
String rentalTimeLeft(Strings t, int expiresAt, DateTime now) {
  if (expiresAt <= 0) return t.pictureKeeps;
  final left = expiresAt - now.millisecondsSinceEpoch;
  if (left <= 0) return t.rentalLapsed;
  final total = (left / Duration.millisecondsPerMinute).ceil();
  final days = total ~/ Duration.minutesPerDay;
  final hours = total % Duration.minutesPerDay ~/ Duration.minutesPerHour;
  final minutes = total % Duration.minutesPerHour;
  return t.timeLeft(switch ((days, hours)) {
    (> 0, _) => '${t.timeDays(days)} ${t.timeHours(hours)}',
    (_, > 0) => '${t.timeHours(hours)} ${t.timeMinutes(minutes)}',
    _ => t.timeMinutes(minutes),
  });
}

/// The short time left on an owned rental's tag, or null for a picture that
/// never runs out: whole days while more than a day is left, then hours while
/// more than 59 minutes are, then minutes (owner, 14 Sep 2026: pictures rented
/// by the hour, whose tag read "1d left" for all of their hour). Each rounds
/// UP, as [rentalTimeLeft] does, so a running rental never reads 0 and an hour
/// just bought reads "1h left" rather than "60m left".
String? rentalTagLeft(Strings t, int expiresAt, DateTime now) {
  if (expiresAt <= 0) return null;
  final left = expiresAt - now.millisecondsSinceEpoch;
  if (left > Duration.millisecondsPerDay) {
    return t.daysLeft((left / Duration.millisecondsPerDay).ceil());
  }
  if (left > 59 * Duration.millisecondsPerMinute) {
    return t.hoursLeft((left / Duration.millisecondsPerHour).ceil());
  }
  return t.minutesLeft(
    left <= 0 ? 0 : (left / Duration.millisecondsPerMinute).ceil(),
  );
}

/// The moment a rental ends, as the popup writes it: `dd/MM/yyyy HH:mm` on the
/// phone's own clock.
///
/// Numbers only, so no month name has to be translated five times, and a
/// 24-hour clock so there is no AM/PM word either. Day first, because that is
/// how the players this game is written for write a date.
String rentalEndDate(DateTime end) {
  String two(int n) => n.toString().padLeft(2, '0');
  final at = end.toLocal();
  return '${two(at.day)}/${two(at.month)}/${at.year} '
      '${two(at.hour)}:${two(at.minute)}';
}

/// Shows a premium picture this player has already paid for: that it is
/// theirs, how long for, and a key to wear it.
Future<void> showOwnedPicture(BuildContext context, ProfilePicture picture) =>
    showDialog<void>(
      context: context,
      builder: (_) => _OwnedPictureDialog(picture: picture),
    );

class _OwnedPictureDialog extends StatelessWidget {
  const _OwnedPictureDialog({required this.picture});

  /// The picture as it was when tapped. Kept, rather than only looked up,
  /// because the catalogue can be re-read under the open dialog and a rental
  /// that has lapsed comes back unowned with no expiry at all — without the
  /// deadline it was tapped with there would be no end date left to show.
  final ProfilePicture picture;

  @override
  Widget build(BuildContext context) {
    // Watched, not read: GameState notifies once a second, and that tick is
    // the whole of what keeps the countdown live while the dialog is open.
    final state = context.watch<GameState>();
    final t = state.t;
    final theme = Theme.of(context);
    final now = DateTime.now();

    var live = picture;
    for (final p in state.pictures) {
      if (p.id == picture.id) {
        live = p;
        break;
      }
    }
    // Two ways a rental ends under the dialog: the clock passes the deadline,
    // or a re-read catalogue (the lobby's rental watch) has already taken the
    // picture back. The second is the server's word, so it wins even when this
    // phone's clock disagrees.
    final expiresAt = live.owned ? live.expiresAt : picture.expiresAt;
    final lapsed =
        !live.owned ||
        (expiresAt > 0 && expiresAt <= now.millisecondsSinceEpoch);
    final keeps = expiresAt <= 0 && !lapsed;
    final worn = state.user?.activePictureId == picture.id;
    final colour = lapsed ? theme.colorScheme.error : theme.colorScheme.primary;
    const figures = [FontFeature.tabularFigures()];

    return GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: Row(
        children: [
          Icon(Icons.lock_open, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              t.pictureOwnedTitle,
              style: AppTheme.label(
                theme.textTheme.titleMedium ?? const TextStyle(),
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Sized exactly as in the unlock dialog, so buying a picture and
          // coming back to it later show the same face at the same size. The
          // ring is the shelf's: gold on the picture being worn, green on one
          // that is paid for and waiting, and the plain hairline once a rental
          // has run out — a green ring beside "your rental has run out" would
          // say two opposite things at once.
          Avatar(
            url: state.absoluteUrl(picture.url),
            format: picture.assetFormat,
            fallback: picture.name,
            radius: (MediaQuery.sizeOf(context).height * 0.15).clamp(
              40.0,
              80.0,
            ),
            ring: worn
                ? shelfGoldOn(theme.brightness)
                : lapsed
                ? null
                : shelfOwnedLine(theme),
            ringWidth: 2.5,
            ringGap: 3,
            animate: true,
          ),
          const SizedBox(height: Space.md),
          Text(
            picture.name,
            textAlign: TextAlign.center,
            style: AppTheme.label(
              theme.textTheme.titleSmall ?? const TextStyle(),
            ),
          ),
          const SizedBox(height: Space.xs),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                lapsed
                    ? Icons.timer_off_outlined
                    : keeps
                    ? Icons.all_inclusive
                    : Icons.schedule,
                size: 16,
                color: colour,
              ),
              const SizedBox(width: Space.xs),
              Flexible(
                child: Text(
                  lapsed ? t.rentalLapsed : rentalTimeLeft(t, expiresAt, now),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colour,
                    fontWeight: FontWeight.w600,
                    fontFeatures: figures,
                  ),
                ),
              ),
            ],
          ),
          if (expiresAt > 0) ...[
            const SizedBox(height: Space.xxs),
            Text(
              lapsed
                  ? t.rentalEnded(rentalEndDate(_at(expiresAt)))
                  : t.rentalEnds(rentalEndDate(_at(expiresAt))),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(
                  alpha: AppTheme.inkMed,
                ),
                fontFeatures: figures,
              ),
            ),
          ],
        ],
      ),
      actions: [
        GlassButton(
          style: GlassButtonStyle.text,
          label: t.close,
          onPressed: () => Navigator.pop(context),
        ),
        // Off rather than hidden in both cases, so the dialog keeps its shape
        // and the key itself says why: it is already on, or it can no longer
        // be put on without buying it again.
        GlassButton(
          style: GlassButtonStyle.primary,
          icon: worn ? const Icon(Icons.check, size: 18) : null,
          label: worn ? t.wearing : t.wear,
          onPressed: worn || lapsed
              ? null
              : () {
                  // Not awaited: the dialog closes on the tap, and a refusal
                  // (a rental the server has just taken back) arrives as a
                  // notice, which is painted over whatever is open.
                  unawaited(state.chooseAvatar(picture.id));
                  Navigator.pop(context);
                },
        ),
      ],
    );
  }

  static DateTime _at(int epochMs) =>
      DateTime.fromMillisecondsSinceEpoch(epochMs);
}

/// One tile of the picture shelf (the store polish, 26 Sep 2026): the
/// picture, one [ShelfBadge] saying what it is to this player, its name, and
/// the small print — a rental's term or the time left on one ([ShelfDetail]).
/// The table shelf's tiles are built the same way round a preview, so the
/// two shelves read as one store.
class PictureChoice extends StatelessWidget {
  const PictureChoice({
    super.key,
    required this.picture,
    required this.radius,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  final ProfilePicture picture;

  /// The circle's radius. The tile is wider than 2r so the badge and the name
  /// underneath have room, and every tile is the same width so the grid stays
  /// on its columns whatever the names are ([widthFor]).
  final double radius;

  /// The picture being worn.
  final bool selected;

  /// This picture is being bought right now.
  final bool busy;
  final VoidCallback onTap;

  /// How wide a tile with a picture of [radius] stands on the shelf.
  static double widthFor(double radius) => radius * 2 + Space.lg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<GameState>();
    final t = state.t;
    final url = state.absoluteUrl(picture.url);
    final locked = picture.locked;
    final gold = shelfGoldOn(theme.brightness);

    // The ring says what the badge says, in colour, for the eye running down
    // the shelf: gold round the picture being worn, green round every one the
    // player can put on now — free or bought, which is the line between what
    // they can use and what they would have to buy — and the champagne
    // hairline every portrait in the app wears round the rest. Never colour
    // alone: the badge under it says the same in a glyph and a word.
    final Widget face = AnimatedSwitcher(
      duration: Motion.base,
      child: selected
          ? Avatar(
              key: const ValueKey(ShelfBadgeKind.equipped),
              url: url,
              format: picture.assetFormat,
              fallback: picture.name,
              radius: radius - 3,
              ring: gold,
              ringWidth: 2.5,
              ringGap: 2,
              animate: true,
            )
          : Avatar(
              key: ValueKey(locked),
              url: url,
              format: picture.assetFormat,
              fallback: picture.name,
              radius: radius,
              ring: locked ? null : shelfOwnedLine(theme),
              animate: true,
            ),
    );

    // A locked picture is shown, not hidden, and at full colour (owner,
    // 14 Sep 2026; it was dimmed to 0.55): knowing what is behind the padlock
    // is the whole reason anybody buys one. The badge under it is what says
    // it is not one tap away. A picture being worn but no longer owned (a
    // rental that lapsed a moment ago) shows its price: a tap asks to buy it.
    final kind = locked
        ? ShelfBadgeKind.locked
        : selected
        ? ShelfBadgeKind.equipped
        : ShelfBadgeKind.owned;
    final Widget badge = locked
        ? PriceTag(cost: picture.cost, currency: picture.currency)
        : ShelfBadge(kind: kind, label: selected ? t.wearing : t.pictureOwned);
    // The small print: what a rental would give — "1 day", where the old
    // tag's short form said "1 days" — or what is left of one.
    final String? detail = locked
        ? (picture.rented
              ? t.rentalTerm(picture.durationDays, picture.durationHours)
              : null)
        : rentalTagLeft(t, picture.expiresAt, DateTime.now());

    return PressScale(
      enabled: !busy,
      child: InkWell(
        // Material's own click, gated on the player's Sound switch —
        // otherwise a silenced game would still tick on every tap.
        enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: SizedBox(
          width: widthFor(radius),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The picture, with nothing written on it. The price and the
              // term used to sit over the bottom of the portrait, which put
              // type on exactly the part of a face people look at; they are
              // lines of their own underneath.
              SizedBox(
                height: radius * 2 + 6,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (selected)
                      // The one being worn stands in a soft gold light — a
                      // still one: nothing on the shelf moves but the
                      // pictures themselves.
                      DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: shelfGlow(gold, theme.brightness),
                        ),
                        child: SizedBox.square(dimension: radius * 2),
                      ),
                    Center(child: face),
                    if (busy)
                      SizedBox(
                        width: radius,
                        height: radius,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Space.xs),
              ShelfBadgeSwitcher(kind: kind, child: badge),
              const SizedBox(height: Space.xs),
              // The catalogue gives every picture a name; showing it is what
              // turns a row of circles into a list somebody can talk about.
              // Two lines, not one: the tile is only as wide as the portrait,
              // and on a 640dp phone one line cut "Orange Ballerina" down to
              // "Orange Baller…". Every tile carries a badge, so the names of
              // a row start on one line; a longer one only hangs lower.
              Text(
                picture.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: shelfNameStyle(
                  theme,
                  theme.textTheme.labelSmall,
                  selected: selected,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: Space.xxs),
                ShelfDetail(text: detail),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The gold of the picture being worn and the table being laid — the ring
/// round it, the glow behind it — in each theme's money gold: the lobby's
/// balance gold by night, and by day the deeper gold that still holds its
/// contrast on the frosted sheet, where the champagne ring all but vanished.
Color shelfGoldOn(Brightness brightness) => AppTheme.goldInk(brightness);

/// The line round a picture the player can put on now: the scheme's green,
/// turned down so a shelf of owned pictures is not a wall of green rings —
/// the badge under each says "Owned" in a word.
Color shelfOwnedLine(ThemeData theme) =>
    theme.colorScheme.primary.withValues(alpha: 0.7);

/// The still, soft light behind the one tile a shelf has on (the store
/// polish, 26 Sep 2026: "Selected item: soft glow" — never a pulse here):
/// wide and faint, so it lifts the picture without competing with it.
List<BoxShadow> shelfGlow(Color gold, Brightness brightness) => [
  BoxShadow(
    color: gold.withValues(alpha: brightness == Brightness.dark ? 0.30 : 0.26),
    blurRadius: 14,
  ),
];

/// A tile's name: the label ramp's natural case and tracking (the old 10dp
/// size and the ramp's 0.8 tracking set a name out like a caption), in the
/// body ink — the full ink and a step heavier on the one tile a shelf has on.
TextStyle shelfNameStyle(
  ThemeData theme,
  TextStyle? base, {
  required bool selected,
}) => AppTheme.label(
  (base ?? const TextStyle()).copyWith(height: 1.15),
  colour: theme.colorScheme.onSurface.withValues(
    alpha: selected ? AppTheme.inkHigh : AppTheme.inkMed,
  ),
  weight: selected ? FontWeight.w700 : FontWeight.w600,
);

/// What a shelf's tile is to this player (the store polish, 26 Sep 2026).
enum ShelfBadgeKind {
  /// The picture being worn, or the table picture being laid.
  equipped,

  /// One the player can put on now: free, or bought and still running.
  owned,

  /// One with a price.
  locked,
}

/// The one badge every tile of the two picture shelves carries (the store
/// polish, 26 Sep 2026: "EQUIPPED … OWNED … LOCKED / PURCHASABLE", never by
/// colour alone): a glyph and a word — a tick and "Wearing", "In use" or
/// "Owned" — or a padlock, the wallet's glyph and the price. Drawn in the
/// store's own vocabulary, so a tile and the store round it read as one:
/// * [ShelfBadgeKind.equipped] — the store head's "Wearing" tag: solid gold
///   under ink900 with a champagne rim and [Radii.xs] corners, the one solid
///   gold on the shelf, on the one picture worn or table picture laid;
/// * [ShelfBadgeKind.owned] — a quiet tag of the same shape in the scheme's
///   green (mint by night, the seed green by day), on a breath of it;
/// * [ShelfBadgeKind.locked] — the price as the store's purchase keys draw
///   one ([PriceTag]): a raised pill washed and rimmed in the wallet's ink
///   (the money gold, [diamondInkOn], [hammerInkOn]), the padlock and the
///   wallet's glyph in that ink, the figure in the full ink. It is the tile's
///   call to buy, so it is the one badge that is a pill.
///
/// One height for all three — the padding, the type (the label ramp's
/// smallest step, w700) and ONE measured line ([lineHeightFor]) — so the
/// badges of a row stand level whatever each says; the glyphs are the store
/// head's 12dp. A line too wide for the narrowest tile at the 1.25 text
/// ceiling is scaled into it whole rather than cut, and keeps that height.
class ShelfBadge extends StatelessWidget {
  const ShelfBadge({
    super.key,
    required this.kind,
    required this.label,
    this.wallet,
    this.walletInk,
    this.semanticsLabel,
  });

  final ShelfBadgeKind kind;

  /// The word, or the price as [formatChips] writes it.
  final String label;

  /// The glyph of the wallet a price is paid from, beside the padlock: the
  /// hammer or the gem. None for chips, whose price reads as chips.
  final IconData? wallet;

  /// A price's ink: its rim, its wash, the padlock and the wallet's glyph.
  /// The money gold ([AppTheme.goldInk]) when null.
  final Color? walletInk;

  /// What a screen reader says for the badge, when it is more than [label].
  final String? semanticsLabel;

  /// The glyphs' size: the store head's "Wearing" tag's.
  static const double glyph = 12;

  /// The height of one line of badge type at this text size in this language:
  /// the language's own badge words and the figures on ONE line, measured,
  /// because a phone draws Hindi, Bengali, Gujarati and Punjabi from its Noto
  /// fonts beside Inter's figures, and such a line is taller than either
  /// font's own (§12.3; a price and "आपकी" stood 3dp apart). Every badge
  /// stands on it, so a price and a word are one height in every language.
  /// Measured once per language, size and style, not on every tick.
  static double lineHeightFor(BuildContext context, TextStyle style) {
    final t = context.read<GameState>().t;
    final probe = '${t.wearing} ${t.pictureOwned} ${t.tableInUse} 0123456789';
    final scaler = MediaQuery.textScalerOf(context);
    final key =
        '$probe|${scaler.scale(100)}|${style.fontSize}|${style.height}|'
        '${style.fontFamily}|${style.fontFamilyFallback}|${style.fontWeight}';
    return _lines[key] ??= () {
      final painter = TextPainter(
        text: TextSpan(text: probe, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }();
  }

  static final Map<String, double> _lines = {};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final base = theme.textTheme.labelSmall ?? const TextStyle(fontSize: 10.5);
    final green = theme.colorScheme.primary;
    final money = walletInk ?? AppTheme.goldInk(theme.brightness);
    final (
      Color ink,
      Color mark,
      IconData glyphIcon,
      BoxDecoration look,
    ) = switch (kind) {
      ShelfBadgeKind.equipped => (
        AppTheme.ink900,
        AppTheme.ink900,
        Icons.check_rounded,
        BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.xs),
          color: AppTheme.gold,
          border: Border.all(
            color: AppTheme.goldBright.withValues(alpha: 0.9),
            width: Dim.hairline,
          ),
        ),
      ),
      ShelfBadgeKind.owned => (
        green,
        green,
        Icons.check_rounded,
        BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.xs),
          color: green.withValues(alpha: dark ? 0.12 : 0.08),
          border: Border.all(
            color: green.withValues(alpha: 0.55),
            width: Dim.hairline,
          ),
        ),
      ),
      ShelfBadgeKind.locked => (
        GlassColors.of(context).textDisplay,
        money,
        Icons.lock_rounded,
        BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.pill),
          // The purchase key's surface: a step off the sheet, lit from
          // above, with a breath of the wallet's ink in it.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark
                ? [
                    Color.alphaBlend(
                      money.withValues(alpha: 0.08),
                      const Color(0xFF3B4047),
                    ),
                    Color.alphaBlend(
                      money.withValues(alpha: 0.06),
                      const Color(0xFF272B30),
                    ),
                  ]
                : [
                    Color.alphaBlend(
                      money.withValues(alpha: 0.036),
                      Colors.white,
                    ),
                    Color.alphaBlend(
                      money.withValues(alpha: 0.06),
                      AppTheme.bone100,
                    ),
                  ],
          ),
          border: Border.all(
            color: money.withValues(alpha: 0.55),
            width: Dim.hairline,
          ),
          boxShadow: [
            BoxShadow(
              color: AppTheme.shadowFor(
                theme.brightness,
              ).withValues(alpha: dark ? 0.42 : 0.14),
              offset: const Offset(0, 1.5),
              blurRadius: 6,
              spreadRadius: -2,
            ),
          ],
        ),
      ),
    };
    // The store head's tag type: w700, a little tracking, tabular figures.
    final words = base.copyWith(
      color: ink,
      fontWeight: FontWeight.w700,
      height: 1.15,
      letterSpacing: 0.3,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final style = kind == ShelfBadgeKind.locked
        ? AppTheme.money(base.copyWith(height: 1.15), colour: ink)
        : words;

    return Semantics(
      label: semanticsLabel ?? label,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.sm,
          vertical: Space.xxs,
        ),
        decoration: look,
        // One measured line for every badge; a line too wide for the
        // narrowest tile is scaled into it whole, and keeps that height.
        child: SizedBox(
          height: math.max(glyph, lineHeightFor(context, words)),
          child: Align(
            widthFactor: 1,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(glyphIcon, size: glyph, color: mark),
                  if (wallet != null) ...[
                    const SizedBox(width: Space.xxs),
                    Icon(wallet, size: glyph, color: mark),
                  ],
                  const SizedBox(width: Space.xs),
                  Text(label, maxLines: 1, softWrap: false, style: style),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A tile's badge, changing kind with the store's own switch — a fade and a
/// small scale over [Motion.base] (its `_fadeScale`) — the store polish's
/// "purchase success: subtle success feedback": a picture just bought turns
/// from its price into "Wearing" where the player is looking. Nothing moves
/// while the kind stays.
class ShelfBadgeSwitcher extends StatelessWidget {
  const ShelfBadgeSwitcher({
    super.key,
    required this.kind,
    required this.child,
  });

  /// What [child] says, which is what the switch is keyed on.
  final ShelfBadgeKind kind;

  /// A [ShelfBadge] or a [PriceTag].
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: Motion.base,
    switchInCurve: Motion.standard,
    switchOutCurve: Curves.easeIn,
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.985, end: 1).animate(animation),
        child: child,
      ),
    ),
    child: KeyedSubtree(key: ValueKey(kind), child: child),
  );
}

/// The small print under a tile's name: how long a rental runs ("100 days"),
/// how long is left of one the player holds ("6d left"), or — on the default
/// table tile — what it is. The quiet ink, one line, a clock beside a time;
/// at the 1.25 text ceiling on the narrowest tile it is scaled to fit rather
/// than cut (the Hindi "42 मिनट बाकी" ran off its tile before, 26 Sep 2026).
class ShelfDetail extends StatelessWidget {
  const ShelfDetail({super.key, required this.text, this.time = true});

  final String text;

  /// Whether [text] is a time, which a clock marks.
  final bool time;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.labelSmall ?? const TextStyle(fontSize: 10.5);
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkLowOn(theme.brightness),
    );
    final style = AppTheme.label(
      base.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
      colour: quiet,
      weight: FontWeight.w500,
    );
    final glyph = MediaQuery.textScalerOf(context).scale(base.fontSize ?? 10.5);
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (time) ...[
            Icon(Icons.schedule_rounded, size: glyph, color: quiet),
            const SizedBox(width: Space.xxs),
          ],
          Text(text, maxLines: 1, softWrap: false, style: style),
        ],
      ),
    );
  }
}

/// The padlock and price sitting on a premium picture nobody has bought yet.
/// The ink every diamond figure is drawn in — the price tag's gem and the
/// balance in the picker header — on the dark pill both sit on, so it holds its
/// contrast in the light theme as well as the dark.
const _diamondInk = Color(0xFFBFE3FF);

/// The diamond ink for a surface that follows the theme — the top bar's glass —
/// rather than the dark pill [_diamondInk] was chosen for: that pale blue is
/// lost on frosted white, so the light theme gets a deeper one.
Color diamondInkOn(Brightness brightness) =>
    brightness == Brightness.dark ? _diamondInk : const Color(0xFF2F6FB3);

/// One soft wallet — its glyph in its ink and the count — on the dark pill
/// the store's single-wallet shelves head with, or bare, for [_WalletPanel],
/// which frames several at once. The ONE place the row is drawn, so the
/// missiles' figure on the Missiles shelf is the diamonds' beside it and the
/// hammers' on the Pictures shelf. Tabular figures, as every other balance
/// has (the chips, the panel, the table's [WalletPill]): a pack landing
/// changes the digits, never the pill's width under the finger.
class _WalletBalance extends StatelessWidget {
  const _WalletBalance({
    required this.icon,
    required this.ink,
    required this.count,
    required this.framed,
  });

  final IconData icon;
  final Color ink;
  final int count;

  /// On its own dark pill, or the bare glyph and figure for a panel that
  /// frames several wallets.
  final bool framed;

  /// The glyph's size, shared with [_WalletPanel.width].
  static const double iconSize = 14;

  static TextStyle? figure(ThemeData theme) =>
      theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: iconSize, color: ink),
        const SizedBox(width: Space.xs),
        Text('$count', style: figure(theme)?.copyWith(color: ink)),
      ],
    );
    if (!framed) return row;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.xs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        color: AppTheme.ink900.withValues(alpha: 0.82),
        border: Border.all(
          color: ink.withValues(alpha: 0.55),
          width: Dim.hairline,
        ),
      ),
      child: row,
    );
  }
}

/// The player's diamonds: in the header of the store's Diamonds shelf, in a
/// diamond-priced picture's dialogs, and — [framed] off — as one figure of the
/// panels that show two wallets at once, [PictureWalletBalances] and
/// [MissileWalletBalances].
class DiamondBalance extends StatelessWidget {
  const DiamondBalance({super.key, required this.count, this.framed = true});

  final int count;

  /// On its own dark pill, or bare, for a panel that frames several wallets.
  final bool framed;

  @override
  Widget build(BuildContext context) => _WalletBalance(
    icon: Icons.diamond,
    ink: _diamondInk,
    count: count,
    framed: framed,
  );
}

/// The ink every hammer figure is drawn in on a dark pill: a pale copper, the
/// colour of the tool's head in the lamp, and far enough from the chips' gold
/// and the diamonds' ice blue that the three wallets never read as one.
const _hammerInk = Color(0xFFFFC08A);

/// The hammer ink for a surface that follows the theme. The pale copper is
/// lost on frosted white, so the light theme gets a burnt one (4.5:1 there).
Color hammerInkOn(Brightness brightness) =>
    brightness == Brightness.dark ? _hammerInk : const Color(0xFFB0571F);

/// The player's hammers, in the store's header on the Hammers shelf and in a
/// hammer-priced picture's dialogs — the hammer twin of [DiamondBalance] —
/// and, [framed] off, one figure of the Pictures shelf's pair.
class HammerBalance extends StatelessWidget {
  const HammerBalance({super.key, required this.count, this.framed = true});

  final int count;

  /// On its own dark pill, or bare, for a panel that frames several wallets.
  final bool framed;

  @override
  Widget build(BuildContext context) => _WalletBalance(
    icon: Icons.hardware,
    ink: _hammerInk,
    count: count,
    framed: framed,
  );
}

/// The player's chips, in the store's header on the Chips shelf — the chips
/// twin of [HammerBalance] (owner, 24 Sep 2026: "In store when user click on
/// Coins tab, then it is not showing users current coin on top, just like we
/// show for hammer"; until then Chips was the one shelf with no balance over
/// its packs). The glyph is the lobby wallet's coin, the ink the champagne
/// every gold figure takes on charcoal, and the figure is [formatChips]' —
/// 2.07 Lakh, never the digits — so it reads exactly as the balance in the
/// lobby bar does.
class ChipBalance extends StatelessWidget {
  const ChipBalance({super.key, required this.chips});

  final int chips;

  static const double _coin = 14;

  static TextStyle? _figure(ThemeData theme) =>
      theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// A two-decimal lakh figure: as wide as any wallet this shelf is likely to
  /// be opened with, and wider than one a pack bought on it makes (3 Lakh to
  /// 13 Lakh at most), so the header's sums never change under the finger
  /// that bought the pack.
  static const int _floorChips = 8888000;

  /// How wide the pill is at this text scale, for the store header, which
  /// counts one balance on every shelf so its tabs never move from one shelf
  /// to the next. At least the width of [_floorChips] (88.88 Lakh, or its
  /// international twin), for the reason [PictureWalletBalances.width]
  /// measures three figures.
  static double width(BuildContext context, {required int chips}) {
    final style = _figure(Theme.of(context));
    double figure(int value) {
      final painter = TextPainter(
        text: TextSpan(text: formatChips(value), style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final w = painter.width;
      painter.dispose();
      return w;
    }

    final content =
        _coin + Space.xs + math.max(figure(chips), figure(_floorChips));
    return (2 * Space.md + 2 * Dim.hairline + content).ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.xs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        color: AppTheme.ink900.withValues(alpha: 0.82),
        border: Border.all(
          color: AppTheme.goldBright.withValues(alpha: 0.55),
          width: Dim.hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const PokerChip(colour: AppTheme.gold, size: _coin),
          const SizedBox(width: Space.xs),
          Text(
            formatChips(chips),
            style: _figure(theme)?.copyWith(color: AppTheme.goldBright),
          ),
        ],
      ),
    );
  }
}

/// Several soft wallets in one dark panel, for a store header with room for
/// one balance: the bare figures in a row, or — [stacked] — one over the
/// other, no wider than a single balance, as the table's [WalletPill] does
/// with its three. One panel rather than a pill each: on a 640dp phone a
/// second pill took the store header's blurb down to a few words, and two
/// pills one over the other stand taller than a one-line header at the 1.25
/// text ceiling, which two bare lines on the thinner padding just keep to.
/// [PictureWalletBalances] and [MissileWalletBalances] are the two faces of it.
class _WalletPanel extends StatelessWidget {
  const _WalletPanel({required this.wallets, required this.stacked});

  /// The bare balances ([DiamondBalance] and its twins with `framed: false`),
  /// in the order shown.
  final List<Widget> wallets;

  /// The figures on lines under one another rather than beside each other.
  final bool stacked;

  /// How wide the panel is at this text scale with these [counts], in a row
  /// or [stacked].
  ///
  /// Each count is measured as at least three figures — tabular, so any three
  /// are one width — because the store header's sums must not change when a
  /// purchase takes 100 hammers down to 70, or 100 diamonds to 27: its tabs
  /// would slide under the finger that bought the picture or the pack.
  static double width(
    BuildContext context, {
    required List<int> counts,
    required bool stacked,
  }) {
    final style = _WalletBalance.figure(Theme.of(context));
    double count(int value) {
      final painter = TextPainter(
        text: TextSpan(text: '$value'.padLeft(3, '0'), style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final w = _WalletBalance.iconSize + Space.xs + painter.width;
      painter.dispose();
      return w;
    }

    final widths = [for (final value in counts) count(value)];
    final content = stacked
        ? widths.reduce(math.max)
        : widths.reduce((a, b) => a + Space.md + b);
    return (2 * _sidePad(stacked) + 2 * Dim.hairline + content).ceilToDouble();
  }

  /// The panel's padding either side. Narrower when stacked, so two lines are
  /// no wider than the one balance the store header counts on every shelf:
  /// at the full padding they took 3dp more from the Pictures blurb on a
  /// 640dp phone.
  static double _sidePad(bool stacked) => stacked ? Space.sm : Space.md;

  @override
  Widget build(BuildContext context) {
    return Container(
      // Two lines keep to the header's height at the 1.25 text ceiling only
      // with the thinner padding.
      padding: EdgeInsets.symmetric(
        horizontal: _sidePad(stacked),
        vertical: stacked ? Space.xxs : Space.xs,
      ),
      decoration: BoxDecoration(
        // A rounded panel for two lines, as the table's wallet: a pill's
        // radius on a box twice as tall rounds its ends into a lozenge.
        borderRadius: BorderRadius.circular(stacked ? Radii.md : Radii.pill),
        color: AppTheme.ink900.withValues(alpha: 0.82),
        border: Border.all(
          color: AppTheme.goldBright.withValues(alpha: 0.28),
          width: Dim.hairline,
        ),
      ),
      child: stacked
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: wallets,
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, wallet) in wallets.indexed) ...[
                  if (i > 0) const SizedBox(width: Space.md),
                  wallet,
                ],
              ],
            ),
    );
  }
}

/// The two wallets a premium picture is paid from besides chips — diamonds,
/// then hammers — in one dark panel, for the picture sheet's header and the
/// store's Pictures and Tables shelves (owner, 14 Sep 2026: the animated
/// pictures were re-priced in hammers, so the hammer count joined the diamond
/// one there). A [_WalletPanel] of a bare [DiamondBalance] and
/// [HammerBalance].
class PictureWalletBalances extends StatelessWidget {
  const PictureWalletBalances({
    super.key,
    required this.diamonds,
    required this.hammers,
    this.stacked = false,
  });

  final int diamonds;
  final int hammers;

  /// Hammers on a line under the diamonds rather than beside them.
  final bool stacked;

  /// How wide the panel is at this text scale, in a row or [stacked]
  /// ([_WalletPanel.width]).
  static double width(
    BuildContext context, {
    required int diamonds,
    required int hammers,
    required bool stacked,
  }) => _WalletPanel.width(
    context,
    counts: [diamonds, hammers],
    stacked: stacked,
  );

  @override
  Widget build(BuildContext context) => _WalletPanel(
    stacked: stacked,
    wallets: [
      DiamondBalance(count: diamonds, framed: false),
      HammerBalance(count: hammers, framed: false),
    ],
  );
}

/// The ink every missile figure is drawn in on a dark pill: the coral of the
/// missile's own body (assets/animations/Missile.json), rosier than the
/// hammers' copper so the three soft wallets never read as one.
const _missileInk = Color(0xFFFF9A8E);

/// The missile ink for a surface that follows the theme. The pale coral is
/// lost on frosted white, so the light theme gets a brick red.
Color missileInkOn(Brightness brightness) =>
    brightness == Brightness.dark ? _missileInk : const Color(0xFFB53A2C);

/// The glyph a missile count is marked with wherever it is written small —
/// the table's wallet, the lobby's bar, the store's tab. The Lottie is the
/// key's; at 14dp its strokes would vanish, so a count wears the icon.
const IconData missileIcon = Icons.rocket_launch_rounded;

/// The player's missiles, in the store's header on the Missiles shelf — the
/// missiles twin of [DiamondBalance] and [HammerBalance] (owner, 24 Sep 2026:
/// "In store when user click on Missile tab, then it should also show the
/// user current missile count just like it is showing diamond count"; until
/// then the shelf headed with the diamonds alone, and how many missiles a
/// pack would add to was nowhere on it). The glyph and ink are the ones the
/// table's wallet and the lobby bar count missiles with, [missileIcon] and
/// the coral of the missile itself, on the dark pill. [framed] off, it is one
/// figure of [MissileWalletBalances].
class MissileBalance extends StatelessWidget {
  const MissileBalance({super.key, required this.count, this.framed = true});

  final int count;

  /// On its own dark pill, or bare, for a panel that frames several wallets.
  final bool framed;

  @override
  Widget build(BuildContext context) => _WalletBalance(
    icon: missileIcon,
    ink: _missileInk,
    count: count,
    framed: framed,
  );
}

/// The diamonds a missile pack is traded for and the missiles a player holds
/// — diamonds first, then missiles, the order every other place gives the two
/// (the table's [WalletPill], the trade dialog over this very shelf) — in one
/// dark panel, for the store's Missiles
/// shelf (owner, 24 Sep 2026: the shelf must show "user current missile count
/// just like it is showing diamond count", and the diamonds stay, since the
/// packs are paid in them). The same [_WalletPanel] as the Pictures shelf's
/// pair, in a row where the widest blurb still keeps its line beside it and
/// [stacked] otherwise, so the Missiles shelf costs the header nothing the
/// Pictures shelf did not already.
class MissileWalletBalances extends StatelessWidget {
  const MissileWalletBalances({
    super.key,
    required this.missiles,
    required this.diamonds,
    this.stacked = false,
  });

  final int missiles;
  final int diamonds;

  /// Missiles on a line under the diamonds rather than beside them.
  final bool stacked;

  /// How wide the panel is at this text scale, in a row or [stacked]
  /// ([_WalletPanel.width]).
  static double width(
    BuildContext context, {
    required int missiles,
    required int diamonds,
    required bool stacked,
  }) => _WalletPanel.width(
    context,
    counts: [diamonds, missiles],
    stacked: stacked,
  );

  @override
  Widget build(BuildContext context) => _WalletPanel(
    stacked: stacked,
    wallets: [
      DiamondBalance(count: diamonds, framed: false),
      MissileBalance(count: missiles, framed: false),
    ],
  );
}

/// The three soft wallets in one dark pill — diamonds, hammers, then missiles
/// — for the top right of the game table (owner, 13 and 14 Sep 2026).
///
/// A pill rather than two: at a table the corner has room for one small
/// object, and a player glancing up mid-hand wants "what can I still spend"
/// answered once. Dark with light ink in both brightnesses, like everything
/// else standing on the table, and display only — the store is the Shop key's
/// job, and a stray tap in a corner should never open a sheet mid-turn.
class WalletPill extends StatelessWidget {
  const WalletPill({
    super.key,
    required this.diamonds,
    required this.hammers,
    this.missiles = 0,
    this.stacked = false,
    required this.semanticsLabel,
  });

  final int diamonds;
  final int hammers;
  final int missiles;

  /// Missiles on a second line under the other two, for a corner too narrow
  /// for all three in a row at a size that still reads
  /// ([WalletPill.rowWidth]).
  final bool stacked;

  /// What a screen reader says instead of two bare numbers.
  final String semanticsLabel;

  static TextStyle? _figure(ThemeData theme) =>
      theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  static const double _icon = 14;

  /// How wide the pill is with all three counts on one line, at this text
  /// scale — so the table can put the missiles on a line of their own where
  /// one line would have to shrink past reading.
  static double rowWidth(
    BuildContext context, {
    required int diamonds,
    required int hammers,
    required int missiles,
  }) {
    final style = _figure(Theme.of(context));
    var width = 2 * Space.md + 2 * Dim.hairline + 2 * Space.md;
    for (final count in [diamonds, hammers, missiles]) {
      final painter = TextPainter(
        text: TextSpan(text: '$count', style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      width += _icon + Space.xs + painter.width;
      painter.dispose();
    }
    return width.ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final figure = _figure(theme);

    Widget count(IconData icon, Color ink, int value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: _icon, color: ink),
        const SizedBox(width: Space.xs),
        Text('$value', style: figure?.copyWith(color: ink)),
      ],
    );
    final gems = count(Icons.diamond, _diamondInk, diamonds);
    final tools = count(Icons.hardware, _hammerInk, hammers);
    final rockets = count(missileIcon, _missileInk, missiles);

    return Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.xs,
        ),
        decoration: BoxDecoration(
          // Two lines are a rounded panel rather than a capsule: a pill's
          // radius on a box twice as tall would round its ends into a lozenge.
          borderRadius: BorderRadius.circular(stacked ? Radii.md : Radii.pill),
          color: AppTheme.ink900.withValues(alpha: 0.82),
          border: Border.all(
            color: AppTheme.goldBright.withValues(alpha: 0.28),
            width: Dim.hairline,
          ),
        ),
        child: stacked
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      gems,
                      const SizedBox(width: Space.md),
                      tools,
                    ],
                  ),
                  rockets,
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  gems,
                  const SizedBox(width: Space.md),
                  tools,
                  const SizedBox(width: Space.md),
                  rockets,
                ],
              ),
      ),
    );
  }
}

/// The padlock and the price on a picture — or a table picture — nobody has
/// bought yet: the locked [ShelfBadge]. Public for the table shelf, whose
/// locked tiles carry the same badge.
///
/// A padlock on every price (the store polish, 26 Sep 2026: "LOCKED /
/// PURCHASABLE: 🔒 Price"), and beside it the glyph of the wallet the price
/// leaves when that is not chips — the hammer, the wallet pill's and the
/// Hammers shelf's glyph, or the gem — so "30" is never read as chips; the
/// pill wears that wallet's ink, as the store's purchase keys do. The rental
/// term is no longer a second line in the pill: every badge on a shelf is one
/// line, and the term is the tile's small print ([ShelfDetail]).
class PriceTag extends StatelessWidget {
  const PriceTag({super.key, required this.cost, this.currency = 'COIN'});

  final int cost;

  /// Which wallet the cost leaves — [PictureCurrency.coin], `diamond` or
  /// `hammer`. A currency this build does not know reads as chips.
  final String currency;

  @override
  Widget build(BuildContext context) {
    final t = context.read<GameState>().t;
    final price = formatChips(cost);
    final brightness = Theme.of(context).brightness;
    final (IconData? wallet, Color? ink) = switch (currency) {
      PictureCurrency.diamond => (Icons.diamond, diamondInkOn(brightness)),
      PictureCurrency.hammer => (Icons.hardware, hammerInkOn(brightness)),
      _ => (null, null),
    };
    return ShelfBadge(
      kind: ShelfBadgeKind.locked,
      label: price,
      wallet: wallet,
      walletInk: ink,
      // "Unlock, 30 hammers": the price in its wallet's word, since the
      // glyph beside the figure says nothing to a screen reader.
      semanticsLabel:
          '${t.unlock}, '
          '${t.priceIn(currency, currency == PictureCurrency.hammer ? '$cost' : price)}',
    );
  }
}
