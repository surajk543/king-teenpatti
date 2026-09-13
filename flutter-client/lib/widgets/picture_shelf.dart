/// The picture shelf: the catalogue's filter, its grid of tiles, the unlock
/// dialog and the diamond balance.
///
/// Shared by the two places a picture is chosen or bought — the picker behind
/// the lobby's avatar and the store's Pictures tab — so the two can never
/// disagree about what a locked tile looks like or what tapping one does.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../settings/feedback_settings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'avatar.dart';
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

/// The pictures on one shelf.
///
/// An empty shelf says so rather than showing nothing: a blank space under
/// the menu would read as a picker that failed to load.
Widget pictureShelf({
  required BuildContext context,
  required GameState state,
  required PictureFilter filter,
  required double radius,
}) {
  final pictures = state.pictures.where(filter.holds).toList();
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
      spacing: Space.md,
      runSpacing: Space.sm,
      children: [
        for (final p in pictures)
          PictureChoice(
            picture: p,
            radius: radius,
            selected: user?.activePictureId == p.id,
            busy: state.buyingPicture == p.id,
            onTap: () =>
                p.locked ? unlockPicture(context, p) : state.chooseAvatar(p.id),
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

/// Asks before spending chips on a premium picture, then buys and wears it.
///
/// A confirmation rather than a straight tap-to-buy: this is the only place in
/// the lobby where a tap costs real chips, and a picker is somewhere people
/// browse. Tapping a face should never be how a stack quietly goes down.
Future<void> unlockPicture(BuildContext context, ProfilePicture picture) async {
  final state = context.read<GameState>();
  final t = state.t;
  final theme = Theme.of(context);

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
            // the last place to say which this is before chips leave the
            // wallet. The currency names the wallet the cost leaves, so a
            // diamond row must not be caught saying "chips".
            picture.rented
                ? (picture.currency == 'DIAMOND'
                      ? t.unlockRentBodyDiamond(
                          picture.name,
                          formatChips(picture.cost),
                          picture.durationDays,
                        )
                      : t.unlockRentBody(
                          picture.name,
                          formatChips(picture.cost),
                          picture.durationDays,
                        ))
                : (picture.currency == 'DIAMOND'
                      ? t.unlockBodyDiamond(
                          picture.name,
                          formatChips(picture.cost),
                        )
                      : t.unlockBody(picture.name, formatChips(picture.cost))),
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

  // The server is the authority on whether it can be afforded and whether the
  // player is seated; a refusal comes back as a notice rather than being
  // guessed at here.
  if (confirmed == true) await state.buyPicture(picture.id);
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
    // The same green as the ring round an unlocked picture, so the badge and
    // the outline read as one statement rather than two.
    final green = theme.colorScheme.primary;
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

/// The player's diamonds, in the picture picker's header.
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

class _PriceTag extends StatelessWidget {
  const _PriceTag({required this.cost, this.currency = 'COIN', this.days});

  final int cost;

  /// Which wallet the cost leaves — 'COIN' or 'DIAMOND'. It decides the
  /// pill's glyph: the padlock-plus-price reads as chips, the gem as a
  /// diamond price.
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
              currency == 'DIAMOND'
                  ? const Icon(Icons.diamond, size: 11, color: _diamondInk)
                  : Icon(Icons.lock, size: 9, color: AppTheme.goldBright),
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
