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
import 'friend_presence.dart';
import 'glass_components.dart';
import 'paged_scroll.dart';
import 'own_record.dart';
import 'player_profile.dart' show friendsGreen;
import 'table_chrome.dart' show MenuRule;

// The viewer's own pod at a table (owner, 27 Sep 2026: "In game table, player
// can click his own pod and it will his own stats which you show when you
// click in lobby and also shows his friend list with status who all are
// online and other info"). The table's player drawer, in its own mode
// ([FriendsState.ownOpen]): the lobby Stats drawer's head and record, and the
// player's friends with where each one is — online or not, playing and at
// which game — as the lobby's Friends page lists them. Nothing here names a
// table or a wallet of anybody else's.

/// Which half of the viewer's own drawer is on show.
enum OwnDrawerTab { record, friends }

/// What the table's player drawer holds while it shows the viewer themselves:
/// their picture, name, level and badges ([PlayerStatsHeader], with its
/// close key), then two tabs — **Your record** ([OwnRecord], the lobby Stats
/// drawer's own) and **Friends** (every friend, PLAYING, ONLINE, OFFLINE, each
/// with [FriendPresenceLines]). The friend list is read when the drawer opens
/// ([FriendsState.openOwn]) and again every [FriendsState.pollEvery] while it
/// is on screen — its own lifetime decides, so a drawer taken down any way at
/// all stops the clock.
class OwnSeatBody extends StatefulWidget {
  const OwnSeatBody({super.key});

  /// The drawer's width in this mode: the lobby Stats drawer's (46% of the
  /// screen held to 300..420dp), wider than the table's other drawers, since
  /// the record stands three cards across.
  static double widthFor(double w) => (w * 0.46).clamp(300.0, 420.0);

  @override
  State<OwnSeatBody> createState() => _OwnSeatBodyState();
}

class _OwnSeatBodyState extends State<OwnSeatBody> {
  OwnDrawerTab _tab = OwnDrawerTab.record;
  late final FriendsState _friends;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _friends = context.read<GameState>().friends;
    _poll = Timer.periodic(FriendsState.pollEvery, (_) {
      if (mounted) unawaited(_friends.refresh());
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (user, lang) = context.select<GameState, (User?, AppLang)>(
      (s) => (s.user, s.lang),
    );
    final t = Strings(lang);
    return Column(
      key: const ValueKey('own-drawer'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PlayerStatsHeader(
          t: t,
          name: user?.displayName ?? '',
          avatarUrl: context.read<GameState>().avatarUrl,
          level: user?.playerLevel,
          badges: user?.badges ?? const [],
        ),
        ListenableBuilder(
          listenable: _friends,
          builder: (context, _) => OwnDrawerTabs(
            t: t,
            tab: _tab,
            online: _friends.available
                ? _friends.friends.where((f) => f.presence.isOnline).length
                : null,
            onChanged: (tab) => setState(() => _tab = tab),
          ),
        ),
        const MenuRule(),
        Expanded(
          child: AnimatedSwitcher(
            duration: Motion.fast,
            child: switch (_tab) {
              OwnDrawerTab.record => EdgeFade(
                key: const ValueKey('own-record-tab'),
                child: ListView(
                  key: const ValueKey('own-record-list'),
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    Space.md,
                    Space.lg,
                    Space.lg,
                  ),
                  children: [
                    OwnRecord(
                      key: const ValueKey('own-record'),
                      t: t,
                      user: user,
                    ),
                    const SizedBox(height: Space.lg),
                    StatsFootnote(t.playedNote),
                  ],
                ),
              ),
              OwnDrawerTab.friends => _FriendsTab(
                key: const ValueKey('own-friends-tab'),
                t: t,
                friends: _friends,
              ),
            },
          ),
        ),
      ],
    );
  }
}

/// The own drawer's two tabs, a word each on one line, the one on show in
/// gold over a gold underline; the Friends tab says how many friends are
/// online beside its word, once the list has been read.
class OwnDrawerTabs extends StatelessWidget {
  const OwnDrawerTabs({
    super.key,
    required this.t,
    required this.tab,
    required this.onChanged,
    this.online,
  });

  final Strings t;
  final OwnDrawerTab tab;
  final ValueChanged<OwnDrawerTab> onChanged;

  /// Friends online now; null where there is no list (a server from before
  /// Friends).
  final int? online;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gold = AppTheme.goldInk(theme.brightness);
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkMed,
    );

    Widget key(OwnDrawerTab which, String label, {String? detail}) {
      final on = tab == which;
      final style = TableType.item(theme).copyWith(
        color: on ? gold : quiet,
        fontWeight: on ? FontWeight.w700 : FontWeight.w600,
      );
      return Expanded(
        child: Semantics(
          button: true,
          selected: on,
          label: detail == null ? label : '$label, $detail',
          excludeSemantics: true,
          child: InkWell(
            key: ValueKey('own-tab-${which.name}'),
            onTap: on
                ? null
                : () {
                    tapHaptic(context);
                    onChanged(which);
                  },
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Dim.minTouch),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Space.xs),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: label),
                            if (detail != null)
                              TextSpan(
                                text: '  $detail',
                                style: TableType.metadata(theme, figures: true)
                                    .copyWith(
                                      color: friendsGreen(theme.brightness),
                                    ),
                              ),
                          ],
                        ),
                        maxLines: 1,
                        softWrap: false,
                        style: style,
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.xs),
                  AnimatedContainer(
                    duration: Motion.fast,
                    height: 2,
                    margin: const EdgeInsets.symmetric(horizontal: Space.lg),
                    decoration: BoxDecoration(
                      color: on ? gold : Colors.transparent,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      child: Row(
        children: [
          key(OwnDrawerTab.record, t.yourRecord),
          key(
            OwnDrawerTab.friends,
            t.friends,
            detail: online == null || online == 0
                ? null
                : t.friendsOnlineCount(online!),
          ),
        ],
      ),
    );
  }
}

/// The friends, as the lobby's Friends page lists them: PLAYING, then ONLINE,
/// then OFFLINE, each by name ([sortFriends], which the list is read in) —
/// a picture, a name and where they are. Read, not acted on: a friend is
/// looked up, asked or removed in the lobby.
class _FriendsTab extends StatelessWidget {
  const _FriendsTab({super.key, required this.t, required this.friends});

  final Strings t;
  final FriendsState friends;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: friends,
      builder: (context, _) {
        final theme = Theme.of(context);
        final glass = GlassColors.of(context);
        if (!friends.available || (friends.failed && !friends.loaded)) {
          return _Quiet(
            key: const ValueKey('own-friends-failed'),
            text: t.friendsLoadFailed,
            action: friends.available ? t.friendsRetry : null,
            onAction: friends.available ? friends.refresh : null,
          );
        }
        if (!friends.loaded) {
          return const Center(
            key: ValueKey('own-friends-loading'),
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final list = friends.friends;
        if (list.isEmpty) {
          return _Quiet(
            key: const ValueKey('own-friends-none'),
            title: t.noFriendsTitle,
            text: t.noFriendsBody,
          );
        }
        // The friends a page at a time, the next read as the list nears its
        // end (PagedScroll), a spinner at the end while it is.
        return PagedScroll(
          hasMore: friends.hasMoreFriends,
          loading: friends.loadingMoreFriends,
          onMore: () => unawaited(friends.loadMoreFriends()),
          builder: (context, controller) => EdgeFade(
            child: ListView.separated(
              key: const ValueKey('own-friends-list'),
              controller: controller,
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.sm,
                Space.lg,
                Space.lg,
              ),
              itemCount: list.length + (friends.loadingMoreFriends ? 1 : 0),
              separatorBuilder: (_, _) => Divider(
                height: Space.md,
                thickness: Dim.hairline,
                color: glass.cardBorder,
              ),
              itemBuilder: (context, i) {
                if (i == list.length) {
                  return const PagedFooter(key: ValueKey('own-friends-more'));
                }
                final friend = list[i];
                return Row(
                  key: ValueKey('own-friend:${friend.userId}'),
                  children: [
                    Avatar(
                      url: context.read<GameState>().absoluteUrl(
                        friend.player.pictureUrl,
                      ),
                      fallback: friend.displayName,
                      radius: 18,
                      animate: true,
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            friend.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.label(theme.textTheme.titleSmall!),
                          ),
                          const SizedBox(height: Space.xxs),
                          FriendPresenceLines(t: t, presence: friend.presence),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

/// A quiet message where the list would be, with an optional key under it.
class _Quiet extends StatelessWidget {
  const _Quiet({
    super.key,
    required this.text,
    this.title,
    this.action,
    this.onAction,
  });

  final String? title;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title case final head?)
              Text(
                head,
                textAlign: TextAlign.center,
                style: AppTheme.label(theme.textTheme.titleSmall!),
              ),
            if (title != null) const SizedBox(height: Space.xs),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: glass.cardMuted,
              ),
            ),
            if (action case final label?) ...[
              const SizedBox(height: Space.md),
              GlassButton(
                key: const ValueKey('own-friends-retry'),
                style: GlassButtonStyle.outline,
                onPressed: onAction,
                label: label,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
