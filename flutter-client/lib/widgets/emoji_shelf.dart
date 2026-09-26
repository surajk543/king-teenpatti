/// The emojis (owner, 26 Sep 2026: "user can buy emoji which will be
/// animation … this emoji can buy from store also, IN UI add a button of
/// emoji in gameplay table, when user click that emoji then that emoji
/// message will send to all players just like chat messages").
///
/// Two places show the catalogue, and both live here so they can never
/// disagree about what a locked emoji is or what tapping one does:
/// * the store's Emojis shelf ([emojiShelf]) — the Animated shelf's tile, the
///   emoji playing, its badge (Owned, or the padlock and the price), its name
///   and its term; a locked tile asks first ([unlockEmoji]);
/// * the table's emoji page ([EmojiDrawer]) — a page of the table's left
///   drawer, never a route: the player's own emojis playing, one tap to send
///   one to everyone at the table; the rest dimmed with their price, a tap
///   away from the store.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../settings/feedback_settings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import 'chip_store.dart';
import 'edge_fade.dart';
import 'emoji_art.dart';
import 'glass_components.dart';
import 'glass_panels.dart';
import 'picture_shelf.dart';
import 'table_chrome.dart';

/// The order the emojis stand in, on the shelf and on the table's page:
/// free first, then chips, hammers and diamonds — the wallets in the order
/// the picture shelves keep — each cheapest first, and the catalogue's own
/// order among equals (Dart's sort is not stable, hence the index).
List<EmojiItem> emojiShelfOrder(List<EmojiItem> emojis) {
  int group(EmojiItem e) => e.free
      ? 0
      : switch (e.currency) {
          PictureCurrency.hammer => 2,
          PictureCurrency.diamond => 3,
          _ => 1,
        };
  final order = [for (var i = 0; i < emojis.length; i++) i]
    ..sort((i, k) {
      final a = emojis[i], b = emojis[k];
      final byGroup = group(a).compareTo(group(b));
      if (byGroup != 0) return byGroup;
      final byCost = a.cost.compareTo(b.cost);
      return byCost != 0 ? byCost : i.compareTo(k);
    });
  return [for (final i in order) emojis[i]];
}

/// Whether [emoji] may be bought where the player is: anywhere, except a
/// chip-priced one at a table — a seated player's chips move only at the
/// table's checkpoints, so the server sells them only what hammers or
/// diamonds pay for (`seated`). Only an exact 'COIN' is held back here; a
/// currency this build does not know is left for the server to answer.
bool emojiSellsHere(EmojiItem emoji, {required bool atTable}) =>
    !atTable || emoji.currency != PictureCurrency.coin;

/// Whether [user] holds enough for [emoji], as far as this phone knows —
/// the hammer and diamond wallets only, which the store's shelves refill.
bool canAffordEmoji(EmojiItem emoji, User? user) => switch (emoji.currency) {
  PictureCurrency.hammer => (user?.hammer ?? 0) >= emoji.cost,
  PictureCurrency.diamond => (user?.diamond ?? 0) >= emoji.cost,
  _ => true,
};

/// The unlock question's sentence for an emoji: the price in its wallet's
/// word ([Strings.priceIn]) and, for a rental, the term.
String unlockEmojiBody(Strings t, EmojiItem emoji) {
  final cost = emoji.pricedInHammers
      ? '${emoji.cost}'
      : formatChips(emoji.cost);
  final price = t.priceIn(emoji.currency, cost);
  return emoji.rented
      ? t.unlockEmojiRentBody(
          emoji.name,
          price,
          t.rentalTerm(emoji.durationDays, emoji.durationHours),
        )
      : t.unlockEmojiBody(emoji.name, price);
}

/// The store's Emojis shelf: every emoji in the catalogue, in
/// [emojiShelfOrder]. An empty catalogue says so — the seed ships with no
/// emojis until the owner supplies the art — rather than leaving a blank
/// space that reads as a shelf that failed to load.
///
/// [side] is the square an emoji is drawn in; [openStore] moves the store to
/// the Hammers or Diamonds shelf when a wallet is short, as the picture
/// shelf's does.
Widget emojiShelf({
  required BuildContext context,
  required GameState state,
  required double side,
  ValueChanged<StoreTab>? openStore,
}) {
  final emojis = emojiShelfOrder(state.emojis);
  if (emojis.isEmpty) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xl),
      child: Center(
        child: Text(
          state.t.emojiShelfEmpty,
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
      tileWidth: EmojiChoice.widthFor(side),
      children: [
        for (final (i, e) in emojis.indexed)
          ShelfTileEntrance(
            key: ValueKey('emoji-${e.id}'),
            index: i,
            child: EmojiChoice(
              emoji: e,
              side: side,
              busy: state.buyingEmoji == e.id,
              // A locked emoji asks to be bought. One the player owns is sent
              // from the table's emoji key, not from here, and a tap says so.
              onTap: () => e.locked
                  ? unlockEmoji(context, e, openStore: openStore)
                  : state.say(state.t.emojiOwnedNote),
            ),
          ),
      ],
    ),
  );
}

/// One tile of the Emojis shelf, built as the picture shelf's is (the store
/// polish, 26 Sep 2026): the emoji playing in a rounded well, its one
/// [ShelfBadge] — Owned, or the padlock and the price — its name, and the
/// small print: a rental's term, or what is left of one ([ShelfDetail]). An
/// emoji is never worn, so there is no gold "in use" state; the well's line
/// is green round what the player can send and the hairline round the rest.
class EmojiChoice extends StatelessWidget {
  const EmojiChoice({
    super.key,
    required this.emoji,
    required this.side,
    required this.busy,
    required this.onTap,
  });

  final EmojiItem emoji;

  /// The well's side; the tile is a little wider, for the badge and the
  /// name ([widthFor]).
  final double side;

  /// This emoji is being bought right now.
  final bool busy;
  final VoidCallback onTap;

  /// How wide a tile with a well of [side] stands on the shelf.
  static double widthFor(double side) => side + Space.lg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<GameState>();
    final t = state.t;
    final locked = emoji.locked;
    final kind = locked ? ShelfBadgeKind.locked : ShelfBadgeKind.owned;
    final Widget badge = locked
        ? PriceTag(cost: emoji.cost, currency: emoji.currency)
        : ShelfBadge(kind: kind, label: t.pictureOwned);
    final String? detail = locked
        ? (emoji.rented
              ? t.rentalTerm(emoji.durationDays, emoji.durationHours)
              : null)
        : rentalTagLeft(t, emoji.expiresAt, DateTime.now());

    return PressScale(
      enabled: !busy,
      child: InkWell(
        enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: SizedBox(
          width: widthFor(side),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _EmojiWell(
                url: state.absoluteUrl(emoji.url),
                name: emoji.name,
                side: side,
                line: locked
                    ? AppTheme.hairlineColour(theme.brightness)
                    : shelfOwnedLine(theme),
                busy: busy,
              ),
              const SizedBox(height: Space.xs),
              ShelfBadgeSwitcher(kind: kind, child: badge),
              const SizedBox(height: Space.xs),
              Text(
                emoji.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: shelfNameStyle(
                  theme,
                  theme.textTheme.labelSmall,
                  selected: false,
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

/// An emoji in its rounded well: a faint ground so a transparent Lottie
/// reads on either theme's glass, the line that says whether it is the
/// player's, and the emoji playing inside it.
class _EmojiWell extends StatelessWidget {
  const _EmojiWell({
    required this.url,
    required this.name,
    required this.side,
    required this.line,
    this.busy = false,
    this.dim = false,
    this.overlay,
  });

  final String? url;
  final String name;
  final double side;
  final Color line;
  final bool busy;

  /// Drawn at half strength: a locked emoji on the table's page, and every
  /// emoji there while the chat's cooldown runs.
  final bool dim;

  /// Laid over the middle of the well: the cooldown's dial.
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.md),
        color: dark
            ? Colors.white.withValues(alpha: 0.05)
            : AppTheme.ink900.withValues(alpha: 0.04),
        border: Border.all(color: line, width: 1.5),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Opacity(
            opacity: dim ? 0.45 : 1,
            child: EmojiArt(url: url, size: side * 0.78, semanticLabel: name),
          ),
          ?overlay,
          if (busy)
            SizedBox(
              width: side * 0.45,
              height: side * 0.45,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
        ],
      ),
    );
  }
}

/// An emoji as the unlock question and the "not enough" offer show it:
/// large, playing. Sized off the screen's height, the scarce axis in
/// landscape.
class _EmojiOnOffer extends StatelessWidget {
  const _EmojiOnOffer({required this.emoji});

  final EmojiItem emoji;

  @override
  Widget build(BuildContext context) => EmojiArt(
    url: context.read<GameState>().absoluteUrl(emoji.url),
    size: (MediaQuery.sizeOf(context).height * 0.3).clamp(80.0, 160.0),
    semanticLabel: emoji.name,
  );
}

/// Asks before spending on a premium emoji, then buys it — [unlockPicture]
/// for the emoji shelf, with the same two answers before the question: a
/// chip-priced emoji tapped at a table is refused on the spot
/// ([emojiSellsHere]), and one whose hammer or diamond wallet is short is
/// offered that wallet's shelf ([offerWalletShelf]), which is also what
/// follows the server's own shortage when this phone's count was out of date.
Future<void> unlockEmoji(
  BuildContext context,
  EmojiItem emoji, {
  ValueChanged<StoreTab>? openStore,
}) async {
  final state = context.read<GameState>();
  final t = state.t;
  final theme = Theme.of(context);

  if (!emojiSellsHere(emoji, atTable: state.screen == Screen.table)) {
    state.say(t.emojiChipsLobbyOnly);
    return;
  }
  if (!canAffordEmoji(emoji, state.user)) {
    await offerWalletShelf(
      context,
      name: emoji.name,
      cost: emoji.cost,
      currency: emoji.currency,
      preview: _EmojiOnOffer(emoji: emoji),
      openStore: openStore,
    );
    return;
  }
  final balance = walletBalanceFor(state, emoji.currency);

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
              t.unlockEmojiTitle,
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
          _EmojiOnOffer(emoji: emoji),
          const SizedBox(height: Space.lg),
          Text(
            unlockEmojiBody(t, emoji),
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
          label: t.unlock,
          onPressed: () => Navigator.pop(dialogContext, true),
        ),
      ],
    ),
  );

  if (confirmed != true) return;
  final result = await state.buyEmoji(emoji.id);
  if (result == PictureBuyResult.notEnough && context.mounted) {
    await offerWalletShelf(
      context,
      name: emoji.name,
      cost: emoji.cost,
      currency: emoji.currency,
      preview: _EmojiOnOffer(emoji: emoji),
      openStore: openStore,
    );
  }
}

/// The table's emoji page (owner, 26 Sep 2026: "IN UI add a button of emoji
/// in gameplay table, when user click that emoji then that emoji message will
/// send to all players just like chat messages"): a page of the table's
/// left drawer, opened by the rail's emoji key — never a route, as the chat
/// drawer's pages are not.
///
/// The player's own emojis first, each playing in its well: one tap sends it
/// to the whole table ([GameState.sendEmoji]) and the drawer goes, so what
/// the player sees next is their emoji over their own seat. An emoji is a
/// chat line — the server counts it against the chat's limiter — so the two
/// share one cooldown: while it runs every well is greyed with its dial, as
/// each quick message counts it down.
///
/// Under them, the ones the player does not own, dimmed with their price; a
/// tap opens the store on its Emojis shelf, over the drawer, so a player who
/// buys one comes back to it here, ready to send.
class EmojiDrawer extends StatelessWidget {
  const EmojiDrawer({super.key});

  /// A well's side on this page, and the tile round it.
  static const double wellSide = 64;
  static const double tileWidth = wellSide + Space.md;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final t = state.t;
    final ink = theme.colorScheme.onSurface;
    final all = emojiShelfOrder(state.emojis);
    final owned = [
      for (final e in all)
        if (!e.locked) e,
    ];
    final locked = [
      for (final e in all)
        if (e.locked) e,
    ];
    final canSend = state.canChat;
    final left = state.chatCooldownLeft;

    return GlassDrawerPanel(
      width: TableSpace.drawerW(MediaQuery.sizeOf(context).width),
      padding: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.md,
                Space.xs,
                Space.xs,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.emoji_emotions_rounded,
                    size: 22,
                    color: goldInk(theme.brightness),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Text(
                      t.tableEmojis,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TableType.modalTitle(theme),
                    ),
                  ),
                  if (!canSend) ...[
                    ChatCountdown(
                      left: left,
                      total: GameState.chatCooldown.inSeconds,
                    ),
                    const SizedBox(width: Space.xs),
                  ],
                  PressScale(
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: t.close,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
            ),
            const MenuRule(),
            Expanded(
              child: EdgeFade(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    Space.xs,
                    Space.lg,
                    Space.md,
                  ),
                  children: [
                    if (all.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: Space.xl),
                        child: Text(
                          t.emojiShelfEmpty,
                          key: const ValueKey('emoji-page-empty'),
                          textAlign: TextAlign.center,
                          style: TableType.metadata(theme),
                        ),
                      )
                    else ...[
                      Text(
                        owned.isEmpty ? t.emojiNoneOwned : t.emojiSendHint,
                        style: TableType.metadata(theme),
                      ),
                      const SizedBox(height: Space.sm),
                      if (owned.isNotEmpty)
                        ShelfGrid(
                          tileWidth: tileWidth,
                          spacing: Space.sm,
                          runSpacing: Space.sm,
                          children: [
                            for (final e in owned)
                              _SendTile(
                                key: ValueKey('emoji-send-${e.id}'),
                                emoji: e,
                                secondsLeft: canSend ? null : left,
                                onTap: canSend
                                    ? () {
                                        if (state.sendEmoji(e.id)) {
                                          Navigator.of(context).pop();
                                        }
                                      }
                                    : null,
                              ),
                          ],
                        ),
                      if (locked.isNotEmpty) ...[
                        const SizedBox(height: Space.lg),
                        Text(
                          t.emojiUnlockMore,
                          style: TableType.label(
                            theme,
                            colour: ink.withValues(alpha: AppTheme.inkMed),
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                        ShelfGrid(
                          tileWidth: tileWidth,
                          spacing: Space.sm,
                          runSpacing: Space.sm,
                          children: [
                            for (final e in locked)
                              _LockedTile(
                                key: ValueKey('emoji-locked-${e.id}'),
                                emoji: e,
                                onTap: () => showChipStore(
                                  context,
                                  opensOn: StoreTab.emojis,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One of the player's own emojis on the table's page: it plays in its well,
/// its name under it; a tap sends it. [onTap] is null while the chat's
/// cooldown runs, when the well is greyed under the seconds left.
class _SendTile extends StatelessWidget {
  const _SendTile({
    super.key,
    required this.emoji,
    required this.secondsLeft,
    required this.onTap,
  });

  final EmojiItem emoji;

  /// The cooldown's seconds, or null when the emoji can go now.
  final int? secondsLeft;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<GameState>();
    final live = onTap != null;
    final left = secondsLeft;
    return Semantics(
      button: true,
      enabled: live,
      label: emoji.name,
      excludeSemantics: true,
      child: PressScale(
        enabled: live,
        child: InkWell(
          enableFeedback: context.select<FeedbackSettings, bool>(
            (f) => f.sound,
          ),
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.md),
          child: SizedBox(
            width: EmojiDrawer.tileWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _EmojiWell(
                  url: state.absoluteUrl(emoji.url),
                  name: emoji.name,
                  side: EmojiDrawer.wellSide,
                  line: live
                      ? shelfOwnedLine(theme)
                      : AppTheme.hairlineColour(theme.brightness),
                  dim: !live,
                  overlay: left == null
                      ? null
                      : ChatCountdown(
                          left: left,
                          total: GameState.chatCooldown.inSeconds,
                        ),
                ),
                const SizedBox(height: Space.xxs),
                Text(
                  emoji.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: shelfNameStyle(
                    theme,
                    theme.textTheme.labelSmall,
                    selected: false,
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

/// An emoji the player does not own, on the table's page: dimmed in its
/// well, with its price under it; a tap opens the store on its shelf.
class _LockedTile extends StatelessWidget {
  const _LockedTile({super.key, required this.emoji, required this.onTap});

  final EmojiItem emoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<GameState>();
    return Semantics(
      button: true,
      label: '${emoji.name}, ${state.t.unlock}',
      excludeSemantics: true,
      child: PressScale(
        child: InkWell(
          enableFeedback: context.select<FeedbackSettings, bool>(
            (f) => f.sound,
          ),
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.md),
          child: SizedBox(
            width: EmojiDrawer.tileWidth,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _EmojiWell(
                  url: state.absoluteUrl(emoji.url),
                  name: emoji.name,
                  side: EmojiDrawer.wellSide,
                  line: AppTheme.hairlineColour(theme.brightness),
                  dim: true,
                ),
                const SizedBox(height: Space.xs),
                PriceTag(cost: emoji.cost, currency: emoji.currency),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
