import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../models/friends.dart';
import '../state/friends_state.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import '../theme/theme_colors.dart';
import 'avatar.dart';
import 'edge_fade.dart';
import 'glass_components.dart';
import 'glass_panels.dart';
import 'player_profile.dart';
import 'table_chrome.dart';

// Friends at the table (owner, 26 Sep 2026: "in a gametable, if a player
// clicks other player pod then a drawer from right side will open, where he
// can send friend request and player by clicking his pod can accept the
// friend request, do this async"). The one Friends surface a table has: a tap
// on another player's pod opens this drawer on the right with what the two
// are to each other and that player's record; a seat whose player has asked
// wears a badge. Everything else of Friends — the page, its lists, the
// search, where a friend is — stays in the lobby, and nothing here is, or
// names, a wallet or a table.

/// [seat] when a tap on its pod opens the player drawer — another player,
/// sitting there now, on a server that has Friends — and null for the
/// viewer's own seat, an empty chair, or a server from before Friends.
Seat? playerDrawerSeat(GameState state, Seat? seat) {
  final userId = seat?.userId;
  if (seat == null || !seat.occupied) return null;
  if (userId == null || userId.isEmpty || userId == state.user?.id) {
    return null;
  }
  return state.friends.available ? seat : null;
}

/// Opens the player drawer for the player sitting in [seat] — never for the
/// viewer's own seat or an empty chair. Their name and picture show at once,
/// as the seat has them, and their profile is read as the drawer slides in.
/// Nothing waits on it: the game plays on under the drawer.
void openPlayerDrawer(BuildContext context, Seat seat) {
  final state = context.read<GameState>();
  if (playerDrawerSeat(state, seat) == null) return;
  final userId = seat.userId!;
  tapHaptic(context);
  unawaited(
    state.friends.openSeat(
      PlayerCard(
        userId: userId,
        displayName: seat.displayName,
        pictureUrl: seat.avatarUrl,
      ),
    ),
  );
  state.tableScaffold.currentState?.openEndDrawer();
}

/// The table's player drawer: the end drawer of both felts' Scaffold.
///
/// The player the seat named — their picture and name, at once — then, as
/// their profile arrives, the one move that fits what the two are to each
/// other: Add Friend; Request Sent (quiet, and dead); Accept or Reject a
/// request of theirs; or a ✓ Friends tag (nothing is ended from a table).
/// Under it, their record — the lobby profile's own tiles
/// ([PlayerStatsGrid]). A refusal is said here, in the drawer the move was
/// made from, and the profile is read again to offer what fits now.
///
/// It subscribes for itself ([FriendsState], the language): the table's
/// Scaffold watches nothing, since rebuilding it tears an open drawer down.
/// Its profile has a slot of its own ([FriendsState.seatPlayer]), and the
/// drawer drops it once it has slid away.
class PlayerDrawer extends StatefulWidget {
  const PlayerDrawer({super.key});

  @override
  State<PlayerDrawer> createState() => _PlayerDrawerState();
}

class _PlayerDrawerState extends State<PlayerDrawer> {
  late final FriendsState _friends;

  @override
  void initState() {
    super.initState();
    _friends = context.read<GameState>().friends;
  }

  @override
  void dispose() {
    // A Scaffold builds its drawer only while it is at least partly open, so
    // this is the moment the slide-out ends: the player goes with it.
    _friends.closeSeat(notify: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    final t = Strings(lang);
    return GlassDrawerPanel(
      alignment: AlignmentDirectional.centerEnd,
      width: TableSpace.drawerW(MediaQuery.sizeOf(context).width),
      padding: EdgeInsets.zero,
      child: SizedBox.expand(
        child: ListenableBuilder(
          listenable: _friends,
          builder: (context, _) {
            final who = _friends.seatPlayer;
            if (who == null) return const SizedBox.shrink();
            return Column(
              key: ValueKey('player-drawer:${who.userId}'),
              children: [
                _Head(t: t, player: who),
                const MenuRule(),
                Expanded(
                  child: EdgeFade(
                    child: ListView(
                      key: const ValueKey('player-drawer-list'),
                      padding: const EdgeInsets.fromLTRB(
                        TableSpace.drawerInset,
                        Space.sm,
                        TableSpace.drawerInset,
                        Space.lg,
                      ),
                      children: _body(context, t, who),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context, Strings t, PlayerCard who) {
    final f = _friends;
    final profile = f.seatProfile;
    if (profile == null) {
      final error = f.seatError;
      if (error == null || f.seatLoading) {
        return const [_Waiting(key: ValueKey('seat-loading'))];
      }
      final gone = error == 'player_not_found';
      return [
        _Trouble(
          key: const ValueKey('seat-failed'),
          message: gone ? friendsRefusalText(t, error) : t.profileLoadFailed,
          retry: gone ? null : t.friendsRetry,
          onRetry: gone ? null : f.retrySeat,
        ),
      ];
    }
    final note = f.seatNote;
    return [
      _Relation(t: t, friends: f, player: who, profile: profile),
      if (note != null)
        _Note(
          key: const ValueKey('seat-note'),
          text: friendsRefusalText(t, note),
        ),
      const SizedBox(height: Space.lg),
      PlayerStatsGrid(t: t, stats: profile.stats, surface: RecordSurface.table),
    ];
  }
}

/// Who the drawer is about: their picture and their name, as the seat drew
/// them, and the key that closes it.
class _Head extends StatelessWidget {
  const _Head({required this.t, required this.player});

  final Strings t;
  final PlayerCard player;

  /// The picture's radius: the drawer's one portrait, a step over a chat
  /// line's and under a pod's.
  static const double pictureRadius = 22;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        TableSpace.drawerInset,
        Space.md,
        Space.xs,
        Space.xs,
      ),
      child: Row(
        children: [
          Avatar(
            key: const ValueKey('seat-player-picture'),
            url: context.read<GameState>().absoluteUrl(player.pictureUrl),
            fallback: player.displayName,
            radius: pictureRadius,
            animate: true,
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              player.displayName,
              key: const ValueKey('seat-player-name'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TableType.modalTitle(theme),
            ),
          ),
          PressScale(
            child: IconButton(
              key: const ValueKey('seat-close'),
              visualDensity: VisualDensity.compact,
              tooltip: t.close,
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// The move that fits what the two players are to each other, by the
/// profile's `friendStatus`: Add Friend, Request Sent, Accept and Reject, or
/// the ✓ Friends tag. Nothing for the player themselves, whose seat never
/// opens this drawer.
class _Relation extends StatelessWidget {
  const _Relation({
    required this.t,
    required this.friends,
    required this.player,
    required this.profile,
  });

  final Strings t;
  final FriendsState friends;
  final PlayerCard player;
  final PublicProfile profile;

  @override
  Widget build(BuildContext context) {
    final userId = player.userId;
    switch (profile.friendStatus) {
      case FriendStatus.none:
        final sending = friends.sendingTo == userId;
        return _DrawerKey(
          key: const ValueKey('seat-add-friend'),
          role: KeyRole.primary,
          icon: Icons.person_add_alt_1_rounded,
          label: t.addFriend,
          busy: sending,
          onPressed: friends.sendingTo != null
              ? null
              : () => unawaited(friends.sendRequest(userId)),
        );
      case FriendStatus.pendingSent:
        return _DrawerKey(
          key: const ValueKey('seat-request-sent'),
          role: KeyRole.secondary,
          icon: Icons.schedule_rounded,
          label: t.requestSent,
          onPressed: null,
        );
      case FriendStatus.pendingReceived:
        final id = profile.requestId ?? friends.requestFrom(userId)?.requestId;
        final busy = id != null && friends.busyRequests.contains(id);
        final theme = Theme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t.wantsToBeFriends,
              key: const ValueKey('seat-wants'),
              style: TableType.info(
                theme,
                colour: theme.colorScheme.onSurface.withValues(
                  alpha: AppTheme.inkMed,
                ),
              ),
            ),
            const SizedBox(height: Space.sm),
            _DrawerKey(
              key: const ValueKey('seat-accept'),
              role: KeyRole.primary,
              icon: Icons.check_rounded,
              label: t.friendAccept,
              busy: busy,
              onPressed: id == null || busy
                  ? null
                  : () => unawaited(friends.accept(id)),
            ),
            const SizedBox(height: Space.sm),
            _DrawerKey(
              key: const ValueKey('seat-reject'),
              role: KeyRole.secondary,
              icon: Icons.close_rounded,
              label: t.friendReject,
              onPressed: id == null || busy
                  ? null
                  : () => unawaited(friends.reject(id)),
            ),
          ],
        );
      case FriendStatus.friends:
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: _FriendsTag(key: const ValueKey('seat-friends'), t: t),
        );
      default:
        return const SizedBox.shrink(key: ValueKey('seat-self'));
    }
  }
}

/// One of the drawer's keys, as loud as what it does ([KeyRole]) — the
/// table's dialogs' own two: the PRIMARY move (Add Friend, Accept) in the one
/// solid gold, its name in the primary key's type; a SECONDARY one (Reject)
/// on the plaque's neutral ink with the live hairline; and a key that cannot
/// be pressed faded as every dead key at the table is ([deadKeyOpacity]),
/// words and all. Its name is set smaller rather than cut where a language's
/// words need more than the drawer's width.
class _DrawerKey extends StatelessWidget {
  const _DrawerKey({
    super.key,
    required this.role,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
  });

  final KeyRole role;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// The move is out: a spinner in place of the glyph, and no second press.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final primary = role == KeyRole.primary;
    final dead = onPressed == null && !busy;
    final ink = primary ? inkOnFill(AppTheme.gold) : scheme.onSurface;
    final glyph = busy
        ? SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: ink),
          )
        : Icon(icon, size: 18);
    final name = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(label, maxLines: 1),
    );
    final text = primary
        ? TableType.primaryAction(theme)
        : TableType.secondaryAction(theme);
    final key = primary
        ? GlassButton(
            style: GlassButtonStyle.primary,
            expand: true,
            minimumSize: const Size.fromHeight(Dim.minTouch),
            icon: glyph,
            buttonStyle: FilledButton.styleFrom(
              backgroundColor: AppTheme.gold,
              foregroundColor: ink,
              iconColor: ink,
              // A move that is out keeps its gold: it is being made, not
              // refused.
              disabledBackgroundColor: AppTheme.gold,
              disabledForegroundColor: ink,
              disabledIconColor: ink,
              textStyle: text,
            ),
            onPressed: busy ? null : onPressed,
            child: name,
          )
        : GlassButton(
            style: GlassButtonStyle.outline,
            expand: true,
            minimumSize: const Size.fromHeight(Dim.minTouch),
            icon: glyph,
            buttonStyle: OutlinedButton.styleFrom(
              // The console's plaque: a clear body let the key's own lift
              // show through it by day, a grey slab.
              backgroundColor: AppTheme.plaque(theme.brightness),
              disabledBackgroundColor: AppTheme.panelBase(theme.brightness),
              foregroundColor: ink,
              iconColor: ink,
              // The fade below is the one sign a key cannot be pressed.
              disabledForegroundColor: ink,
              disabledIconColor: ink,
              textStyle: text,
              side: BorderSide(
                color: AppTheme.hairlineColour(theme.brightness, live: true),
                width: Dim.hairline,
              ),
            ),
            onPressed: busy ? null : onPressed,
            child: name,
          );
    return Opacity(opacity: dead ? deadKeyOpacity : 1, child: key);
  }
}

/// ✓ Friends: what the two already are, in the green a friendship is marked
/// in — a tag, not a key, since nothing is ended from a table.
class _FriendsTag extends StatelessWidget {
  const _FriendsTag({super.key, required this.t});

  final Strings t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final green = friendsGreen(theme.brightness);
    return Container(
      constraints: const BoxConstraints(minHeight: Dim.minTouch),
      padding: const EdgeInsets.symmetric(horizontal: Space.lg),
      decoration: BoxDecoration(
        color: glass.wellFill,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(
          color: green.withValues(alpha: 0.55),
          width: Dim.hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, size: 18, color: green),
          const SizedBox(width: Space.sm),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                t.friends,
                maxLines: 1,
                style: TableType.secondaryAction(theme).copyWith(color: green),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What the last move was refused with, said where it was made.
class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkMed);
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(Icons.info_outline_rounded, size: 16, color: ink),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(text, style: TableType.info(theme, colour: ink)),
          ),
        ],
      ),
    );
  }
}

/// The profile is being read.
class _Waiting extends StatelessWidget {
  const _Waiting({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: Space.xl),
    child: Center(
      child: SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
  );
}

/// The profile could not be read: why, and — where trying again could help
/// — the key that does.
class _Trouble extends StatelessWidget {
  const _Trouble({super.key, required this.message, this.retry, this.onRetry});

  final String message;
  final String? retry;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkMed);
    final again = onRetry;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, size: 24, color: ink),
          const SizedBox(height: Space.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TableType.modalBody(theme).copyWith(color: ink),
          ),
          if (again != null && retry != null) ...[
            const SizedBox(height: Space.md),
            _DrawerKey(
              key: const ValueKey('seat-retry'),
              role: KeyRole.secondary,
              icon: Icons.refresh_rounded,
              label: retry!,
              onPressed: () => unawaited(again()),
            ),
          ],
        ],
      ),
    );
  }
}

/// The badge a seat wears while its player's friend request waits for the
/// viewer — so the viewer knows whose seat to tap to answer it. A gold disc
/// with the person-add glyph, laid over the pod's corner by [SeatPod], which
/// neither the pod's size nor the ring's layout feels.
///
/// It subscribes for itself: the requests waiting are read once as the table
/// opens and kept by the pushes and the moves ([FriendsState]), and the badge
/// comes and goes with them — nothing at a table polls for it.
class SeatRequestBadge extends StatelessWidget {
  const SeatRequestBadge({super.key, required this.userId});

  /// The seated player whose request the badge stands for.
  final String userId;

  @override
  Widget build(BuildContext context) {
    final friends = context.read<GameState>().friends;
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    return ListenableBuilder(
      listenable: friends,
      builder: (context, _) {
        if (!friends.hasRequestFrom(userId)) return const SizedBox.shrink();
        return Semantics(
          label: Strings(lang).wantsToBeFriends,
          child: LayoutBuilder(
            builder: (context, box) {
              final side = box.biggest.shortestSide;
              return Container(
                key: const ValueKey('seat-friend-request'),
                width: side,
                height: side,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.gold,
                  border: Border.all(
                    color: AppTheme.ink900.withValues(alpha: 0.55),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.ink900.withValues(alpha: 0.35),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.person_add_alt_1_rounded,
                  size: side * 0.62,
                  color: AppTheme.ink900,
                ),
              );
            },
          ),
        );
      },
    );
  }
}
