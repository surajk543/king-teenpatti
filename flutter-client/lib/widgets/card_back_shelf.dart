/// The store's Cards shelf (owner, 3 Oct 2026: "Add a table cards_background
/// which users can buy just like user can buy profile_pictures … add one more
/// tab Cards in Store which user can buy … keep the price of all cards 5
/// Hammers validaity 10 days"): the card backs a player wears on their own
/// cards, which every player at their table sees.
///
/// The Tables shelf's shape for a card (`tablePictureShelf`): the bundled
/// Royal Fox first — everybody's for nothing and never a catalogue row, which
/// a tap puts back on ("Royal Fox · Default", as the Flowing chips tile
/// restores the room) — then the catalogue in its own order. Every tile is a
/// card in a frame that says in colour what its badge says in a glyph and a
/// word — In use, Owned, or the padlock and the price — over its name and its
/// small print. Everything a locked tile does — the price tag, the unlock
/// question's price, the offer of a wallet's shelf — is the picture shelf's,
/// shared rather than copied, so the shelves can never disagree.
///
/// One card back is bought at a time ([GameState.buyCardBackground]): while
/// one is with the server its card wears the game's ring and no tile takes a
/// tap until the answer comes back, as on the Emojis shelf.
///
/// A rental that runs out while the shelf is open (owner, 3 Oct 2026: "when
/// validity of premium card expires, it restores default card") turns back
/// to its padlock and price at that very moment, and the Royal Fox to "In
/// use" if it was the back on the player's cards: both are read on the
/// card-back clock ([CardBackground.locked], [User.activeCardBackgroundId]),
/// and GameState wakes the store then and reads the catalogue again.
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
import 'card_back_art.dart';
import 'chip_store.dart';
import 'game_loader.dart';
import 'glass_components.dart';
import 'glass_panels.dart';
import 'picture_shelf.dart';
import 'playing_card.dart';

/// What the shelf's first tile is called: the Royal Fox, the bundled default
/// back (`cards/Royal Fox.jpg` in the bucket, shipped in the app cut to the
/// card — [PlayingCard.backAsset]). A name, as every catalogue row's name is
/// the server's and is shown as it comes, so it is not translated; the small
/// print under it is ([Strings.cardBackDefaultHint]).
const royalFoxName = 'Royal Fox';

/// The key of the shelf's first tile, the Royal Fox.
const royalFoxTileKey = 'royal-fox';

/// The key of the shelf's tile for card back [id].
ValueKey<String> cardBackTileKey(int id) => ValueKey('card-back-$id');

/// The order the catalogue stands in after the Royal Fox: the owner's own
/// (`sort_order`, [CardBackground.sortOrder]), the server's order among
/// equals — Dart's sort is not stable, hence the index as the last word.
List<CardBackground> cardShelfOrder(List<CardBackground> cards) {
  final order = [for (var i = 0; i < cards.length; i++) i]
    ..sort((i, k) {
      final bySort = cards[i].sortOrder.compareTo(cards[k].sortOrder);
      return bySort != 0 ? bySort : i.compareTo(k);
    });
  return [for (final i in order) cards[i]];
}

/// Whether [card] may be bought where the player is: anywhere, except a
/// chip-priced one at a table — a seated player's chips move only at the
/// table's checkpoints, so the server sells them only what hammers or
/// diamonds pay for (`seated`). Only an exact 'COIN' is held back here; a
/// currency this build does not know is left for the server to answer.
bool cardBackSellsHere(CardBackground card, {required bool atTable}) =>
    !atTable || card.currency != PictureCurrency.coin;

/// Whether [user] holds enough for [card], as far as this phone knows — the
/// hammer and diamond wallets only, which the store's shelves refill. Chips,
/// and a currency this build does not know, are left to the server.
bool canAffordCardBack(CardBackground card, User? user) =>
    switch (card.currency) {
      PictureCurrency.hammer => (user?.hammer ?? 0) >= card.cost,
      PictureCurrency.diamond => (user?.diamond ?? 0) >= card.cost,
      _ => true,
    };

/// The unlock question's sentence for a card back: the price in its wallet's
/// word ([Strings.priceIn]) and, for a rental, the term — "Royal Tiger costs
/// 5 hammers and is yours for 10 days. Unlock it and use it now?"
String unlockCardBody(Strings t, CardBackground card) {
  final cost = card.pricedInHammers ? '${card.cost}' : formatChips(card.cost);
  final price = t.priceIn(card.currency, cost);
  return card.rented
      ? t.unlockCardRentBody(
          card.name,
          price,
          t.rentalTerm(card.durationDays, card.durationHours),
        )
      : t.unlockCardBody(card.name, price);
}

/// The store's Cards shelf: the Royal Fox, then every card back in the
/// catalogue in [cardShelfOrder].
///
/// [height] is the room the shelf has — the store's body less its padding —
/// and sizes the cards ([CardBackChoice.cardHeightFor]). [openStore] moves the
/// store to the Hammers or Diamonds shelf when a back's wallet is short, as
/// the picture shelf's does.
Widget cardBackShelf({
  required BuildContext context,
  required GameState state,
  required double height,
  ValueChanged<StoreTab>? openStore,
}) {
  final cards = cardShelfOrder(state.cardBackgrounds);
  // The chosen back while it runs: none — the Royal Fox in use — from the
  // moment its rental runs out.
  final chosen = state.user?.activeCardBackgroundId;
  // One card back is bought at a time (GameState.buyCardBackground refuses a
  // second), so while one is with the server no tile takes a tap: not a
  // locked one, which would start another, and not one the player owns,
  // which would put a back on while the purchase is about to put on another.
  final purchasing = state.buyingCardBackground != null;
  final cardHeight = CardBackChoice.cardHeightFor(context, shelfHeight: height);
  final width = CardBackChoice.widthFor(cardHeight);
  return Padding(
    padding: const EdgeInsets.only(bottom: Space.md),
    child: ShelfGrid(
      tileWidth: width,
      children: [
        ShelfTileEntrance(
          key: const ValueKey(royalFoxTileKey),
          index: 0,
          child: CardBackChoice.royalFox(
            cardHeight: cardHeight,
            width: width,
            selected: chosen == null,
            // Takes a chosen back off; on the Royal Fox already, nothing.
            onTap: purchasing
                ? null
                : () {
                    if (chosen != null) unawaited(wearCardBack(state, null));
                  },
          ),
        ),
        for (final (i, c) in cards.indexed)
          ShelfTileEntrance(
            // Keyed by the back, so a tile keeps its state — its entrance
            // run once, its badge's switch — through a purchase's re-read of
            // the catalogue and the store's one-second rebuild.
            key: cardBackTileKey(c.id),
            index: i + 1,
            child: CardBackChoice(
              card: c,
              cardHeight: cardHeight,
              width: width,
              selected: chosen == c.id,
              busy: state.buyingCardBackground == c.id,
              // A locked back asks to be bought; an owned one is put on with
              // one tap — no "already unlocked" stop, as on the Tables shelf:
              // the tile carries the time left, and wearing costs nothing.
              onTap: purchasing
                  ? null
                  : c.locked
                  ? () => unlockCardBackground(context, c, openStore: openStore)
                  : () {
                      if (chosen != c.id) unawaited(wearCardBack(state, c.id));
                    },
            ),
          ),
      ],
    ),
  );
}

/// Puts card back [id] on the player's cards — null for the Royal Fox — and,
/// at a poker room, says where it will show: the poker felt keeps the
/// standard back ([Strings.cardsPokerNote]), as the table shelf says of a
/// cloth laid there.
Future<void> wearCardBack(GameState state, int? id) async {
  await state.chooseCardBackground(id);
  _sayPokerKeepsTheStandardBack(state, id);
}

/// At a poker room, once [id] is on, that its felt keeps the standard back.
void _sayPokerKeepsTheStandardBack(GameState state, int? id) {
  if (id == null || !(state.room?.isPoker ?? false)) return;
  if (state.user?.activeCardBackgroundId != id) return;
  state.say(state.t.cardsPokerNote);
}

/// Whether a card back is already being bought, and if so the player is told
/// to wait: [GameState.buyCardBackground] buys one at a time and refuses a
/// second without a word, so a question whose Unlock could only be refused
/// is never asked, nor its answer dropped — the Emojis shelf's rule.
bool _stillBuyingCardBack(GameState state) {
  if (state.buyingCardBackground == null) return false;
  state.say(state.t.pleaseWait);
  return true;
}

/// Asks before spending on a premium card back, then buys and wears it —
/// `unlockTablePicture` for the card, with the same two answers before the
/// question: a chip-priced back tapped at a table is refused on the spot
/// ([cardBackSellsHere]), and one whose hammer or diamond wallet is short is
/// offered that wallet's shelf ([offerWalletShelf]), which is also what
/// follows the server's own shortage when this phone's count was out of
/// date.
///
/// The tiles that lead here are dead while a card back is being bought;
/// should it be entered then all the same, the player is told to wait, both
/// before the question and after its Unlock ([_stillBuyingCardBack]).
Future<void> unlockCardBackground(
  BuildContext context,
  CardBackground card, {
  ValueChanged<StoreTab>? openStore,
}) async {
  final state = context.read<GameState>();
  final t = state.t;
  final theme = Theme.of(context);

  if (_stillBuyingCardBack(state)) return;
  if (!cardBackSellsHere(card, atTable: state.screen == Screen.table)) {
    state.say(t.cardChipsLobbyOnly);
    return;
  }
  if (!canAffordCardBack(card, state.user)) {
    await offerWalletShelf(
      context,
      name: card.name,
      cost: card.cost,
      currency: card.currency,
      preview: CardBackOnOffer(card: card),
      openStore: openStore,
    );
    return;
  }

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
              t.unlockCardTitle,
              style: AppTheme.label(
                theme.textTheme.titleMedium ?? const TextStyle(),
              ),
            ),
          ),
          // The price where it is always in view, as the other unlock
          // questions have it (28 Sep 2026): the body under the title
          // scrolls on a 360dp phone.
          const SizedBox(width: Space.md),
          PriceAndWallet(cost: card.cost, currency: card.currency),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CardBackOnOffer(card: card),
          const SizedBox(height: Space.lg),
          Text(
            unlockCardBody(t, card),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(
                alpha: AppTheme.inkMed,
              ),
            ),
          ),
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

  // The server is the authority on whether it can be afforded and whether
  // the player is seated: a refusal comes back as a notice — or, for a
  // wallet the store refills, as the offer of its shelf.
  if (confirmed != true || _stillBuyingCardBack(state)) return;
  final result = await state.buyCardBackground(card.id);
  if (result == PictureBuyResult.bought) {
    _sayPokerKeepsTheStandardBack(state, card.id);
  } else if (result == PictureBuyResult.notEnough && context.mounted) {
    await offerWalletShelf(
      context,
      name: card.name,
      cost: card.cost,
      currency: card.currency,
      preview: CardBackOnOffer(card: card),
      openStore: openStore,
    );
  }
}

/// The ring over the plain back a tile or a question shows while the back's
/// picture is still coming ([CardBackImage.loading]): the game's own, its
/// dark arc in the stock's gold, which reads on the card's black in either
/// theme.
Widget _comingRing(double cardHeight) => GameLoaderRing(
  size: cardHeight * PlayingCard.aspect * 0.5,
  ink: AppTheme.cardRim,
);

/// A card back as the unlock question and the "not enough" offer show it:
/// large, standing off the dialog on a card's own shadows. Sized off the
/// screen's height, the scarce axis in landscape — as tall as a picture and
/// an emoji stand in their questions, 30% of it — and a dialog's body
/// scrolls if it ever runs out, as theirs do at the 1.25 text ceiling on a
/// 360dp phone.
///
/// The back it sells or nothing: while its picture comes, the plain back
/// under the game's ring, never the Royal Fox over "costs 5 hammers"
/// (review, 3 Oct 2026; [CardBackImage.standIn]).
class CardBackOnOffer extends StatelessWidget {
  const CardBackOnOffer({super.key, required this.card});

  final CardBackground card;

  /// The card's height in a question on a screen [screenHeight] tall: 108dp
  /// on a 360dp phone, 123 on a 411dp one, 160 on a tablet.
  static double heightFor(double screenHeight) =>
      (screenHeight * 0.3).clamp(80.0, 160.0);

  @override
  Widget build(BuildContext context) {
    final height = heightFor(MediaQuery.sizeOf(context).height);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(height * PlayingCard.cornerShare),
        boxShadow: PlayingCard.shadows(height, Theme.of(context).brightness),
      ),
      child: CardBackImage(
        art: card.art,
        height: height,
        standIn: false,
        loading: _comingRing(height),
      ),
    );
  }
}

/// One tile of the Cards shelf, built as the Tables shelf's is (the store
/// polish, 26 Sep 2026): the card standing in a frame that says its state in
/// colour — gold round the back on the player's cards, green round every one
/// they can put on now, the hairline round the rest — then the shelf's one
/// badge ("In use", "Owned", or the padlock and the price), the name, and the
/// small print: a rental's term, the time left on one the player holds, or
/// what the Royal Fox is.
class CardBackChoice extends StatelessWidget {
  const CardBackChoice({
    super.key,
    required CardBackground this.card,
    required this.cardHeight,
    required this.width,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  /// The tile for the bundled default, the Royal Fox.
  const CardBackChoice.royalFox({
    super.key,
    required this.cardHeight,
    required this.width,
    required this.selected,
    required this.onTap,
  }) : card = null,
       busy = false;

  /// Null for the Royal Fox's tile.
  final CardBackground? card;

  /// The card's height; it is [PlayingCard.aspect] as wide.
  final double cardHeight;

  /// The tile's width ([widthFor]), one for every tile on the shelf.
  final double width;

  /// The back on the player's cards.
  final bool selected;

  /// This back is being bought right now: its card wears the game's ring.
  final bool busy;

  /// Null while a card back is being bought, this one or another: no tile
  /// takes a tap until that purchase is answered.
  final VoidCallback? onTap;

  /// Between the card and its frame's line.
  static const double frameGap = 2;

  /// The frame's heaviest line, round the back in use. The frame's box is
  /// always this heavy, so the card never moves when a tile changes state.
  static const double frameLine = 2.5;

  /// The frame's line round every other card.
  static const double frameLineThin = 1.5;

  /// How far the frame stands out from the card, each side.
  static const double frameOutset = frameGap + frameLine;

  /// The least a card stands: below it the art is a smudge, and a shelf too
  /// short for it gives up its glimpse of the next row instead.
  static const double minCardHeight = 56;

  /// The most a card stands, on a tablet.
  static const double maxCardHeight = 160;

  /// How much of the next row a row of tiles leaves in view: what says the
  /// shelf goes on. The picture and Tables shelves leave 12-23dp at the
  /// 1.25 text ceiling on a 360dp phone.
  static const double nextRowShows = Space.lg;

  /// The narrowest tile: the badge's longest word ("उपयोग में" at the 1.25
  /// text ceiling) whole, and a name on two lines at most.
  static const double minWidth = 96;

  /// How wide a tile with a card [cardHeight] tall stands on the shelf: the
  /// card and room either side for the badge and the name.
  static double widthFor(double cardHeight) => math.max(
    minWidth,
    (cardHeight * PlayingCard.aspect + 2 * Space.xl).floorToDouble(),
  );

  /// How tall a tile's words stand under its card at this text size in this
  /// language — the badge, a name on two lines, the small print, and the
  /// steps between them — measured in the fonts the phone draws them in
  /// (CLAUDE.md §12.3), so the card can be given whatever the shelf has left.
  static double wordsHeight(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.read<GameState>().t;
    final painter = TextPainter(
      text: TextSpan(
        text: 'Royal\nFox',
        style: shelfNameStyle(
          theme,
          theme.textTheme.labelSmall,
          selected: true,
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 2,
    )..layout();
    final name = painter.height;
    painter.dispose();
    final detail = ShelfDetail.heightFor(context, [
      t.cardBackDefaultHint,
      t.rentalTerm(10, 0),
      t.daysLeft(10),
      t.hoursLeft(10),
      t.minutesLeft(10),
    ]);
    return Space.sm +
        ShelfBadge.heightFor(context) +
        Space.xs +
        name +
        Space.xxs +
        detail;
  }

  /// The card's height on a shelf [shelfHeight] tall: as tall as the shelf
  /// can make it while a row of tiles — names on two lines — still leaves
  /// [nextRowShows] of the next row in view, never taller than 28% of the
  /// screen (100dp on a 360dp phone, 115 on a 411dp one), never shorter
  /// than [minCardHeight] nor taller than [maxCardHeight]. Measured, so the
  /// cards give way where the words grow — the 1.25 text ceiling, an Indic
  /// script — and the first row is never cut by the sheet's foot.
  static double cardHeightFor(
    BuildContext context, {
    required double shelfHeight,
  }) {
    final preferred = MediaQuery.sizeOf(context).height * 0.28;
    // Under a row: the grid's run spacing (ShelfGrid's Space.lg), then the
    // glimpse of the next row.
    final room =
        shelfHeight -
        Space.lg -
        nextRowShows -
        2 * frameOutset -
        wordsHeight(context);
    return math
        .min(preferred, room)
        .clamp(minCardHeight, maxCardHeight)
        .floorToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final t = context.read<GameState>().t;
    final c = card;
    final locked = c?.locked ?? false;
    final gold = shelfGoldOn(brightness);
    final cardWidth = cardHeight * PlayingCard.aspect;
    final corner = cardHeight * PlayingCard.cornerShare;

    // The frame says what the badge says, in colour: gold round the back on
    // the player's cards, green round every one they can put on now — the
    // Royal Fox, and one bought and still running — and the hairline round
    // the rest. A back still chosen but no longer owned (a rental that lapsed
    // a moment ago) shows its price: a tap asks to buy it again.
    final kind = locked
        ? ShelfBadgeKind.locked
        : selected
        ? ShelfBadgeKind.equipped
        : ShelfBadgeKind.owned;
    final (Color line, double lineWidth) = switch (kind) {
      ShelfBadgeKind.equipped => (gold, frameLine),
      ShelfBadgeKind.owned => (shelfOwnedLine(theme), frameLineThin),
      ShelfBadgeKind.locked => (
        AppTheme.hairlineColour(brightness),
        frameLineThin,
      ),
    };
    final Widget badge = c != null && locked
        ? PriceTag(cost: c.cost, currency: c.currency)
        : ShelfBadge(
            kind: kind,
            label: kind == ShelfBadgeKind.equipped ? t.cardInUse : t.cardOwned,
          );
    // The small print: what the Royal Fox is; a rental's term — "10 days" —
    // or what is left of the one the player holds.
    final String? detail = c == null
        ? t.cardBackDefaultHint
        : locked
        ? (c.rented ? t.rentalTerm(c.durationDays, c.durationHours) : null)
        : rentalTagLeft(t, c.expiresAt, cardBackClock());
    final live = !busy && onTap != null;

    return PressScale(
      enabled: live,
      child: InkWell(
        // Material's own click, gated on the player's Sound switch.
        enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
        onTap: live ? onTap : null,
        borderRadius: BorderRadius.circular(Radii.md),
        child: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // One box whatever the state: the line's weight changes, the
              // padding inside it gives back what the line does not take, so
              // the card stands still when a tile turns from its price to In
              // use.
              AnimatedContainer(
                duration: Motion.base,
                curve: Motion.standard,
                width: cardWidth + 2 * frameOutset,
                height: cardHeight + 2 * frameOutset,
                padding: EdgeInsets.all(frameOutset - lineWidth),
                decoration: BoxDecoration(
                  // Parallel to the card's own corner.
                  borderRadius: BorderRadius.circular(corner + frameOutset),
                  border: Border.all(color: line, width: lineWidth),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.shadowFor(brightness).withValues(
                        alpha: brightness == Brightness.dark ? 0.45 : 0.16,
                      ),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                    // The back in use stands in a soft gold light: a still
                    // one, as on the other shelves.
                    if (kind == ShelfBadgeKind.equipped)
                      ...shelfGlow(gold, brightness),
                  ],
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CardBackImage(
                      art: c?.art,
                      height: cardHeight,
                      // On sale a back shows as itself or not at all: the
                      // plain back while its picture comes, never the Royal
                      // Fox — the first tile — over its name and price.
                      standIn: false,
                      // While it is being bought the purchase's ring stands
                      // over it instead: one ring on a card.
                      loading: busy ? null : _comingRing(cardHeight),
                    ),
                    if (busy)
                      Center(child: GameLoaderRing(size: cardWidth * 0.6)),
                  ],
                ),
              ),
              const SizedBox(height: Space.sm),
              ShelfBadgeSwitcher(kind: kind, child: badge),
              const SizedBox(height: Space.xs),
              // Two lines, as on the picture shelf: "Royal Owl with Fox" is
              // longer than a narrow tile.
              Text(
                c?.name ?? royalFoxName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: shelfNameStyle(
                  theme,
                  theme.textTheme.labelSmall,
                  selected: kind == ShelfBadgeKind.equipped,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: Space.xxs),
                ShelfDetail(text: detail, time: c != null),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
