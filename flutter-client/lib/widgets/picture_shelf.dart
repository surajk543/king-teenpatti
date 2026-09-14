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
import 'avatar.dart';
import 'chip_store.dart';
import 'glass_components.dart';
import 'glass_panels.dart';

/// The shelves of the picture picker: everything, then the three ways in.
///
/// Premium is split by how a picture plays rather than by what it costs: a
/// picture that moves — a Lottie or a Rive file — is its own thing to shop
/// for. A free picture stays on the free shelf whatever its format.
enum PictureFilter {
  all,
  free,
  premium,
  animated;

  bool holds(ProfilePicture p) => switch (this) {
    PictureFilter.all => true,
    PictureFilter.free => p.free,
    PictureFilter.premium => !p.free && !p.animated,
    PictureFilter.animated => !p.free && p.animated,
  };
}

/// The order a shelf draws its pictures in: the catalogue's own, except that
/// the premium animated pictures run cheapest first (owner, 13 Sep 2026).
///
/// They are re-dealt into the slots they already hold, so on the All shelf the
/// animated group stays where the catalogue put it. Chip, hammer and diamond
/// prices are not comparable figures, so the currencies keep an order of their
/// own ([_currencyRank]) and only within one does the price decide; equal
/// prices keep the catalogue's order — Dart's sort is not stable, hence the
/// index as the last word.
List<ProfilePicture> shelfOrder(List<ProfilePicture> pictures) {
  final slots = [
    for (var i = 0; i < pictures.length; i++)
      if (!pictures[i].free && pictures[i].animated) i,
  ];
  final byCost = [...slots]
    ..sort((i, k) {
      final a = pictures[i], b = pictures[k];
      final rank = _currencyRank(
        a.currency,
      ).compareTo(_currencyRank(b.currency));
      if (rank != 0) return rank;
      final cost = a.cost.compareTo(b.cost);
      return cost != 0 ? cost : i.compareTo(k);
    });
  final ordered = [...pictures];
  for (var n = 0; n < slots.length; n++) {
    ordered[slots[n]] = pictures[byCost[n]];
  }
  return ordered;
}

/// Where a currency's pictures stand among the animated ones: chips first — a
/// currency this build does not know with them, since it is drawn as chips —
/// then hammers, then the diamonds that cost real money.
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
/// and the store is opened instead.
Widget pictureShelf({
  required BuildContext context,
  required GameState state,
  required PictureFilter filter,
  required double radius,
  ValueChanged<StoreTab>? openStore,
}) {
  final pictures = shelfOrder(state.pictures.where(filter.holds).toList());
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
    child: Wrap(
      // Centred in the sheet: flush left, a tablet's nine columns left about
      // 95dp empty on the right and 20 on the left (QA 14 Sep 2026).
      alignment: WrapAlignment.center,
      spacing: Space.md,
      runSpacing: Space.sm,
      children: [
        for (final p in pictures)
          PictureChoice(
            picture: p,
            radius: radius,
            selected: user?.activePictureId == p.id,
            busy: state.buyingPicture == p.id,
            // One answer per kind of tile. A locked picture asks to be bought.
            // A premium one already paid for stops to say so, and for how
            // long, before it is worn: the tile's "12d left" is all its owner
            // otherwise sees of the rental, and on the last day that pill
            // cannot tell twenty hours from twenty minutes. A free picture has
            // nothing to say, so a tap simply wears it.
            onTap: () => p.locked
                ? unlockPicture(context, p, openStore: openStore)
                : p.free
                ? state.chooseAvatar(p.id)
                : showOwnedPicture(context, p),
          ),
      ],
    ),
  );
}

/// The shelf menu at the top of the picture picker.
///
/// A pill in the same dark ink as the price tags and the diamond balance, so
/// the sheet's controls read as one set — which is also why its type is a
/// fixed light ink rather than the theme's, which would vanish on it in the
/// light theme. Each entry carries its shelf's count: that is what tells a
/// player the animated shelf is worth opening.
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
    const ink = Color(0xE6FFFFFF);
    const quiet = Color(0x99FFFFFF);

    Widget entry(PictureFilter f) {
      final (IconData icon, Color colour, String label) = switch (f) {
        PictureFilter.all => (Icons.grid_view_rounded, ink, t.pictureAll),
        PictureFilter.free => (Icons.lock_open, ink, t.pictureFree),
        PictureFilter.premium => (
          Icons.lock,
          AppTheme.goldBright,
          t.picturePremium,
        ),
        PictureFilter.animated => (
          Icons.auto_awesome,
          AppTheme.goldBright,
          t.picturePremiumAnimated,
        ),
      };
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colour),
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
            '${counts[f] ?? 0}',
            style: theme.textTheme.labelSmall?.copyWith(color: quiet),
          ),
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.only(left: Space.md, right: Space.xs),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        color: AppTheme.ink900.withValues(alpha: 0.82),
        border: Border.all(color: AppTheme.goldBright.withValues(alpha: 0.45)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<PictureFilter>(
          value: value,
          isDense: true,
          padding: const EdgeInsets.symmetric(vertical: Space.sm),
          borderRadius: BorderRadius.circular(Radii.md),
          dropdownColor: AppTheme.ink900,
          iconEnabledColor: quiet,
          icon: const Icon(Icons.expand_more, size: 18),
          items: [
            for (final f in PictureFilter.values)
              DropdownMenuItem(value: f, child: entry(f)),
          ],
          onChanged: (f) {
            if (f != null) onChanged(f);
          },
        ),
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
  return switch (picture.currency) {
    PictureCurrency.hammer =>
      picture.rented
          ? t.unlockRentBodyHammers(picture.name, picture.cost, days)
          : t.unlockBodyHammers(picture.name, picture.cost),
    PictureCurrency.diamond =>
      picture.rented
          ? t.unlockRentBodyDiamond(picture.name, cost, days)
          : t.unlockBodyDiamond(picture.name, cost),
    _ =>
      picture.rented
          ? t.unlockRentBody(picture.name, cost, days)
          : t.unlockBody(picture.name, cost),
  };
}

/// What the player holds of the wallet [picture] is priced in, as its dialogs
/// show it, or null for chips.
Widget? _walletBalance(GameState state, ProfilePicture picture) =>
    switch (picture.currency) {
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
    await _offerWalletShelf(context, picture, openStore);
    return;
  }
  final balance = _walletBalance(state, picture);

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
          // The picture itself, large and at full colour, under the question.
          // On the shelf a locked face is a dimmed thumbnail; this is the one
          // place it is shown as what the chips actually buy — and an animated
          // one plays here. Sized off the screen's height, the scarce axis in
          // landscape; the dialog's body scrolls if it ever runs out.
          Avatar(
            url: state.absoluteUrl(picture.url),
            format: picture.assetFormat,
            fallback: picture.name,
            radius: (MediaQuery.sizeOf(dialogContext).height * 0.15).clamp(
              40.0,
              80.0,
            ),
            ring: AppTheme.goldBright,
            ringWidth: 2.5,
            ringGap: 3,
            animate: true,
          ),
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
    await _offerWalletShelf(context, picture, openStore);
  }
}

/// The store's shelf for the wallet [picture] is priced in, offered to a
/// player who cannot pay for it: "Not enough hammers", what it costs, what
/// they hold, and a key to the Hammers shelf — or the same for diamonds.
///
/// [openStore] moves a store that is already open to that shelf, rather than
/// opening a second store over it; without one the store opens on it.
Future<void> _offerWalletShelf(
  BuildContext context,
  ProfilePicture picture,
  ValueChanged<StoreTab>? openStore,
) async {
  final shelf = pictureWalletShelf(picture);
  if (shelf == null) return;
  final state = context.read<GameState>();
  final t = state.t;
  final hammers = shelf == StoreTab.hammers;
  final balance = _walletBalance(state, picture);

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
            Text(
              hammers
                  ? t.notEnoughHammersBody(picture.name, picture.cost)
                  : t.notEnoughDiamondsPictureBody(
                      picture.name,
                      formatChips(picture.cost),
                    ),
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
                ? AppTheme.goldBright
                : lapsed
                ? null
                : theme.colorScheme.primary,
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

  /// The circle's radius. The tile is wider than 2r so the name underneath has
  /// room, and every tile is the same width so the grid stays on its columns
  /// whatever the names are.
  final double radius;
  final bool selected;

  /// This picture is being bought right now.
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final url = context.read<GameState>().absoluteUrl(picture.url);
    final locked = picture.locked;

    // Three rings, and each says something different. Gold is the one being
    // worn. Green is premium already paid for — the padlock is off, and at a
    // glance down the shelf that is the line between what this player can use
    // and what they would have to buy. Everything else keeps the champagne
    // hairline every portrait in the app wears.
    final unlockedRing = !picture.free && !locked;
    Widget face = AnimatedSwitcher(
      duration: Motion.base,
      child: selected
          ? Avatar(
              key: const ValueKey(true),
              url: url,
              format: picture.assetFormat,
              fallback: picture.name,
              radius: radius - 3,
              ring: AppTheme.goldBright,
              ringWidth: 2.5,
              ringGap: 2,
              animate: true,
            )
          : Avatar(
              key: ValueKey(unlockedRing),
              url: url,
              format: picture.assetFormat,
              fallback: picture.name,
              radius: radius,
              ring: unlockedRing ? theme.colorScheme.primary : null,
              ringWidth: unlockedRing ? 2 : 1.5,
              animate: true,
            ),
    );

    // A locked picture is shown, not hidden: knowing what is behind the
    // padlock is the whole reason anybody buys one. It is just held back —
    // dimmed, with the price on it — so it cannot be mistaken for a choice
    // that is one tap away.
    if (locked) {
      face = Opacity(opacity: 0.55, child: face);
    }

    return PressScale(
      child: InkWell(
        // Material's own click, gated on the player's Sound switch —
        // otherwise a silenced game would still tick on every tap.
        enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: SizedBox(
          width: radius * 2 + Space.lg,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The picture, with nothing written on it. The price and the
              // term used to sit over the bottom of the portrait, which put
              // type on exactly the part of a face people look at; they are a
              // line of their own underneath now.
              SizedBox(
                height: radius * 2 + 6,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
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
              const SizedBox(height: Space.xxs),
              if (!busy && locked)
                _PriceTag(
                  cost: picture.cost,
                  currency: picture.currency,
                  days: picture.rented ? picture.durationDays : null,
                ),
              // A premium picture that HAS been paid for. Without this an
              // unlocked one is indistinguishable from a free one, and the
              // chips somebody spent stop showing anywhere. A rental says how
              // long is left instead, because that is the thing its owner
              // actually needs to know.
              if (!busy && !locked && !picture.free)
                _UnlockedTag(daysLeft: picture.daysLeft(DateTime.now())),
              if (!busy && (locked || !picture.free))
                const SizedBox(height: Space.xxs),
              // The catalogue gives every picture a name; showing it is what
              // turns a row of circles into a list somebody can talk about.
              // Two lines, not one: the tile is only as wide as the portrait,
              // and on a 640dp phone one line cut "Orange Ballerina" down to
              // "Orange Baller…". The Wrap top-aligns its tiles, so a longer
              // name only hangs lower — the faces stay in their row.
              Text(
                picture.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  height: 1.1,
                  color: theme.colorScheme.onSurface.withValues(
                    alpha: selected ? AppTheme.inkHigh : AppTheme.inkMed,
                  ),
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The mark on a premium picture this player owns: an open padlock, in the
/// same spot and the same shape as the price it replaces, so the eye reads the
/// swap rather than a new kind of badge.
class _UnlockedTag extends StatelessWidget {
  const _UnlockedTag({this.daysLeft});

  /// Days left on the rental, or null when it never runs out.
  final int? daysLeft;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Mint in both themes. The pill is ink whatever the theme, and the light
    // scheme's primary — the dark seed green the ring round an unlocked
    // picture wears — all but vanished on it (1.5:1).
    const green = AppTheme.mintOnInk;
    final left = daysLeft;
    final label = left == null
        ? context.read<GameState>().t.pictureUnlocked
        : context.read<GameState>().t.daysLeft(left);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.xs,
        vertical: Space.xxs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        color: AppTheme.ink900.withValues(alpha: 0.82),
        border: Border.all(color: green.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            left == null ? Icons.lock_open : Icons.schedule,
            size: 9,
            color: green,
          ),
          const SizedBox(width: 2),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: green,
              fontWeight: FontWeight.w700,
              fontSize: 9,
              height: 1.1,
            ),
          ),
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

/// The player's diamonds: in the header of the store's Diamonds and Missiles
/// shelves, and in a diamond-priced picture's dialogs.
class DiamondBalance extends StatelessWidget {
  const DiamondBalance({super.key, required this.count});

  final int count;

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
        border: Border.all(color: _diamondInk.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.diamond, size: 14, color: _diamondInk),
          const SizedBox(width: Space.xs),
          Text(
            '$count',
            style: theme.textTheme.labelMedium?.copyWith(
              color: _diamondInk,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
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
/// hammer-priced picture's dialogs — the hammer twin of [DiamondBalance].
class HammerBalance extends StatelessWidget {
  const HammerBalance({super.key, required this.count});

  final int count;

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
        border: Border.all(color: _hammerInk.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.hardware, size: 14, color: _hammerInk),
          const SizedBox(width: Space.xs),
          Text(
            '$count',
            style: theme.textTheme.labelMedium?.copyWith(
              color: _hammerInk,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// The two wallets a premium picture is paid from besides chips — diamonds,
/// then hammers — in one dark pill, for the picture sheet's header and the
/// store's Pictures shelf (owner, 14 Sep 2026: the animated pictures were
/// re-priced in hammers, so the hammer count joined the diamond one there).
///
/// One pill rather than a [DiamondBalance] beside a [HammerBalance]: on a
/// 640dp phone a second pill took the store header's blurb down to a few
/// words. Where even one row is too wide the counts stand one over the other
/// ([stacked]), no wider than a single balance, as the table's [WalletPill]
/// does with its three.
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

  static const double _icon = 14;

  static TextStyle? _figure(ThemeData theme) =>
      theme.textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  /// How wide the pill is at this text scale, in a row or [stacked].
  ///
  /// Each count is measured as at least three figures — tabular, so any three
  /// are one width — because the store header's sums must not change when a
  /// purchase takes 100 hammers down to 70: its tabs would slide under the
  /// finger that bought the picture.
  static double width(
    BuildContext context, {
    required int diamonds,
    required int hammers,
    required bool stacked,
  }) {
    final style = _figure(Theme.of(context));
    double count(int value) {
      final painter = TextPainter(
        text: TextSpan(text: '$value'.padLeft(3, '0'), style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final w = _icon + Space.xs + painter.width;
      painter.dispose();
      return w;
    }

    final gems = count(diamonds);
    final tools = count(hammers);
    final content = stacked ? math.max(gems, tools) : gems + Space.md + tools;
    return (2 * _sidePad(stacked) + 2 * Dim.hairline + content).ceilToDouble();
  }

  /// The pill's padding either side. Narrower when stacked, so two lines are
  /// no wider than the one balance the store header counts on every shelf:
  /// at the full padding they took 3dp more from the Pictures blurb on a
  /// 640dp phone.
  static double _sidePad(bool stacked) => stacked ? Space.sm : Space.md;

  @override
  Widget build(BuildContext context) {
    final figure = _figure(Theme.of(context));

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
              children: [gems, tools],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                gems,
                const SizedBox(width: Space.md),
                tools,
              ],
            ),
    );
  }
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

class _PriceTag extends StatelessWidget {
  const _PriceTag({required this.cost, this.currency = 'COIN', this.days});

  final int cost;

  /// Which wallet the cost leaves — [PictureCurrency.coin], `diamond` or
  /// `hammer`. It decides the pill's glyph: the padlock-plus-price reads as
  /// chips, the gem as a diamond price, and the hammer — the wallet pill's
  /// and the Hammers shelf's glyph — as a hammer price. A currency this build
  /// does not know keeps the padlock.
  final String currency;

  /// The rental term, or null when buying it keeps it for good. Shown under
  /// the price rather than beside it: the price is the decision, the term is
  /// the small print, and on a 60dp tile they cannot share a line.
  final int? days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.xs,
        vertical: Space.xxs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        color: AppTheme.ink900.withValues(alpha: 0.82),
        border: Border.all(color: AppTheme.goldBright.withValues(alpha: 0.45)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              switch (currency) {
                PictureCurrency.diamond => const Icon(
                  Icons.diamond,
                  size: 11,
                  color: _diamondInk,
                ),
                PictureCurrency.hammer => const Icon(
                  Icons.hardware,
                  size: 11,
                  color: _hammerInk,
                ),
                _ => Icon(Icons.lock, size: 9, color: AppTheme.goldBright),
              },
              const SizedBox(width: 2),
              Text(
                formatChips(cost),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppTheme.goldBright,
                  fontWeight: FontWeight.w700,
                  fontSize: 9,
                  height: 1.1,
                ),
              ),
            ],
          ),
          if (days != null)
            Text(
              context.read<GameState>().t.rentForDays(days!),
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppTheme.goldBright.withValues(alpha: 0.75),
                fontWeight: FontWeight.w600,
                fontSize: 8,
                height: 1.15,
              ),
            ),
        ],
      ),
    );
  }
}
