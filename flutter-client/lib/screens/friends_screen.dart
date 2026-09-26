import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../models/friends.dart';
import '../settings/feedback_settings.dart';
import '../state/friends_state.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import '../widgets/avatar.dart';
import '../widgets/edge_fade.dart';
import '../widgets/glass_components.dart';
import '../widgets/glass_panels.dart';
import '../widgets/player_profile.dart';
import '../widgets/premium_surface.dart';

// Friends V1 (owner's brief, 26 Sep 2026) — a LOBBY feature: the key in the
// lobby's foot that opens it, the Friends page, and the two pages inside it,
// Add Friend and a player's profile. Nothing here appears at a table, and
// nothing here shows a wallet: a friend is a name, a picture, where they are
// and how they play, never what they hold.

/// Opens the Friends page over the lobby, the way the store and the Lucky
/// Draw open: a page of its own risen from the foot of the screen, which Back
/// closes (from a page inside it, Back returns to the list first).
///
/// The page's lists are read as it appears and every
/// [FriendsState.pollEvery] for as long as it is on screen; when it goes, the
/// reading stops and the lobby key's count is read once more
/// ([FriendsState.pageClosed]) — the page's own lifetime decides, so a page
/// taken down any way at all stops its clock.
Future<void> showFriends(BuildContext context) {
  final friends = context.read<GameState>().friends;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: AppTheme.ink900.withValues(alpha: 0.72),
    transitionDuration: Motion.enter,
    pageBuilder: (_, a, b) => ChangeNotifierProvider<FriendsState>.value(
      value: friends,
      child: const FriendsScreen(),
    ),
    transitionBuilder: (context, anim, _, child) {
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

/// The lobby's name for a Teen Patti or poker game, as a name: the app's own
/// words, written in capitals on the lobby's badges ("TEEN PATTI", "SEEN"),
/// set in title case where the script has case ("Teen Patti", "Seen"). A
/// script without case — Devanagari, Bengali, Gujarati, Gurmukhi — and a name
/// already in mixed case ("Texas Hold'em") are left exactly as they are.
String friendlyName(String name) {
  if (name != name.toUpperCase() || name == name.toLowerCase()) return name;
  return name
      .split(' ')
      .map(
        (word) => word.isEmpty
            ? word
            : '${word.substring(0, 1)}${word.substring(1).toLowerCase()}',
      )
      .join(' ');
}

/// "Teen Patti • Seen", "Poker • Texas Hold'em": the game a playing friend is
/// at, in the app's own localized names for its engines and categories. A
/// game or variant this build has never heard of goes by the server's name for
/// it, where the table catalogue gives one ([engineName], [categoryName]),
/// and failing that by its code, tidied. Null while they are not playing.
String? presenceGameLine(
  Strings t,
  FriendPresence presence, {
  String? Function(String engine)? engineName,
  String? Function(String category)? categoryName,
}) {
  if (!presence.isPlaying) return null;
  final game = presence.game;
  final variant = presence.variant;
  final parts = <String>[
    if (game != null)
      switch (game) {
        PresenceGame.teenPatti => friendlyName(t.teenPatti),
        PresenceGame.poker => friendlyName(t.poker),
        _ => engineName?.call(game.toLowerCase()) ?? _tidy(game),
      },
    if (variant != null) _variantName(t, variant, categoryName),
  ];
  return parts.isEmpty ? null : parts.join(' • ');
}

String _variantName(
  Strings t,
  String variant,
  String? Function(String category)? categoryName,
) {
  final category = variant.toLowerCase();
  if (TableCategory.isPoker(category)) return t.pokerVariantName(category);
  return switch (category) {
    TableCategory.seen => friendlyName(t.seen),
    TableCategory.blind => friendlyName(t.blind),
    TableCategory.variation => friendlyName(t.variation),
    _ => categoryName?.call(category) ?? _tidy(variant),
  };
}

/// A code as words: `NEW_GAME` → "New Game".
String _tidy(String code) => friendlyName(code.replaceAll('_', ' ').trim());

// ----------------------------------------------------------------- the key

/// The lobby's way to Friends: a round key in the lobby's foot, beside the
/// milestone, with the people glyph and a gold count of the requests waiting.
///
/// In the foot rather than among the top bar's keys, which is where the brief
/// put it first: on a 640dp phone at text x1.25 a fourth key there takes its
/// width from the player's name, already cut to "Guest…" (the lobby tests
/// measured it). Round and wordless for the same reason — the foot has its
/// rewards on both sides — with its name in its tooltip and its semantics.
///
/// While it is on screen the lobby is, so it is also what tells [FriendsState]
/// the lobby shows: the count is read when it appears and every
/// [FriendsState.badgeEvery] until it goes. Absent before sign-in, and on a
/// server from before Friends.
class FriendsKey extends StatefulWidget {
  const FriendsKey({super.key});

  /// The key's side: a legal touch target.
  static const double side = Dim.minTouch;

  @override
  State<FriendsKey> createState() => _FriendsKeyState();
}

class _FriendsKeyState extends State<FriendsKey> {
  late final FriendsState _friends;

  @override
  void initState() {
    super.initState();
    _friends = context.read<GameState>().friends;
    _friends.lobbyShown();
  }

  @override
  void dispose() {
    _friends.lobbyHidden();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = context.select<GameState, bool>((s) => s.user != null);
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    return ListenableBuilder(
      listenable: _friends,
      builder: (context, _) {
        if (!signedIn || !_friends.available) return const SizedBox.shrink();
        final t = Strings(lang);
        final waiting = _friends.incomingCount;
        final theme = Theme.of(context);
        final brightness = theme.brightness;
        final glass = GlassColors.of(context);
        final dark = brightness == Brightness.dark;
        final lit = waiting > 0;
        final fg = lit ? AppTheme.goldInk(brightness) : glass.textBody;

        final key = GlassCapsule(
          surface: GlassSurface.card,
          live: lit,
          minHeight: FriendsKey.side,
          onTap: () => showFriends(context),
          padding: const EdgeInsets.all((FriendsKey.side - _Mark.size) / 2),
          child: _Mark(
            lit: lit,
            child: Icon(Icons.people_alt_rounded, size: 16, color: fg),
          ),
        );

        return Padding(
          padding: const EdgeInsets.only(right: Space.sm),
          // One node for a screen reader, its count spoken with its name,
          // and the tap the key's own ink would have carried.
          child: Semantics(
            button: true,
            label: lit
                ? '${t.friends}, ${t.friendRequestsWaiting(waiting)}'
                : t.friends,
            onTap: () => showFriends(context),
            excludeSemantics: true,
            child: Tooltip(
              message: t.friends,
              child: PressScale(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    // The corner chips' own glow while something waits.
                    boxShadow: lit
                        ? [
                            BoxShadow(
                              color: AppTheme.gold.withValues(
                                alpha: dark ? 0.18 : 0.14,
                              ),
                              blurRadius: 16,
                              spreadRadius: -2,
                            ),
                          ]
                        : null,
                  ),
                  child: Badge(
                    key: const ValueKey('friends-badge'),
                    isLabelVisible: lit,
                    backgroundColor: AppTheme.gold,
                    textColor: AppTheme.ink900,
                    offset: const Offset(2, -2),
                    label: Text(waiting > 9 ? '9+' : '$waiting'),
                    child: SizedBox.square(
                      dimension: FriendsKey.side,
                      child: key,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A glyph in a 28dp disc, as the lobby's corner chips carry theirs: gold-lit
/// while something waits for the player, a quiet well otherwise.
class _Mark extends StatelessWidget {
  const _Mark({required this.lit, required this.child});

  final bool lit;
  final Widget child;

  static const double size = 28;

  @override
  Widget build(BuildContext context) {
    final glass = GlassColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: lit
            ? AppTheme.gold.withValues(alpha: dark ? 0.16 : 0.12)
            : glass.wellFill,
        border: Border.all(
          color: lit
              ? AppTheme.gold.withValues(alpha: dark ? 0.45 : 0.50)
              : glass.cardBorder,
        ),
      ),
      child: child,
    );
  }
}

// ---------------------------------------------------------------- the page

enum _View { list, add, profile }

/// The Friends page (owner, 26 Sep 2026), as [showFriends] opens it: who the
/// player is to others (their Player ID, to copy), the requests waiting for
/// them, and their friends — playing first, then online, then offline. Two
/// pages open inside it and Back returns from them: Add Friend, a search by
/// Player ID; and a player's profile, their record and, for a friend, where
/// they are and the way to remove them.
///
/// It watches [FriendsState] and selects from [GameState] only the language,
/// the player's id and where the app is, so the app's one-second tick never
/// rebuilds it.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  /// The panel at its largest: on a tablet the page stands in the middle of
  /// the room rather than stretching a list across the whole screen.
  static const Size largest = Size(960, 640);

  /// How long "Copied" stands on the copy key.
  static const Duration copiedFor = Duration(seconds: 2);

  /// The room the panel needs, while the keyboard is up, to keep its header
  /// over the Player ID field. A landscape phone's keyboard leaves it 70–110dp,
  /// room for the field and its Search key and not for the header as well:
  /// with it, the field stood under the keyboard on a 640x360 phone
  /// (26 Sep 2026). There the header steps aside until the keyboard goes; a
  /// tablet, leaving 400dp, keeps it.
  static const double typingRoom = 160;

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  late final FriendsState _friends;

  _View _view = _View.list;

  /// Whose profile is open, drawn at once from what the list or the search
  /// already knew while the profile itself is read.
  PlayerCard? _profileSeed;

  /// Where Back from the profile goes: the list, or the search it came from.
  _View _profileFrom = _View.list;

  final _idField = TextEditingController();
  final _idFocus = FocusNode();

  /// True for [FriendsScreen.copiedFor] after the Player ID was copied.
  bool _copied = false;
  Timer? _copiedTimer;

  /// Set once the page has asked to close because the app left the lobby, so
  /// it asks once.
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _friends = context.read<FriendsState>();
    // Once the page is on screen: the read says it has begun at once, and
    // marking the lobby's key to rebuild while this page is being built is
    // not allowed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _friends.pageOpened();
    });
  }

  @override
  void dispose() {
    _friends.pageClosed();
    _copiedTimer?.cancel();
    _idField.dispose();
    _idFocus.dispose();
    super.dispose();
  }

  void _openAdd() {
    setState(() => _view = _View.add);
  }

  void _openProfile(PlayerCard who, {required _View from}) {
    _idFocus.unfocus();
    unawaited(_friends.openProfile(who.userId));
    setState(() {
      _profileSeed = who;
      _profileFrom = from;
      _view = _View.profile;
    });
  }

  /// Back: from a page inside, to the one it came from; from the list, out.
  void _back() {
    switch (_view) {
      case _View.profile:
        _friends.closeProfile();
        setState(() => _view = _profileFrom);
      case _View.add:
        _idFocus.unfocus();
        _idField.clear();
        _friends.clearSearch();
        setState(() => _view = _View.list);
      case _View.list:
        Navigator.of(context).pop();
    }
  }

  void _close() {
    _idFocus.unfocus();
    Navigator.of(context).pop();
  }

  Future<void> _copyId(String id) async {
    tapHaptic(context);
    await Clipboard.setData(ClipboardData(text: id));
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(FriendsScreen.copiedFor, () {
      if (mounted) setState(() => _copied = false);
    });
  }

  void _search() {
    _idFocus.unfocus();
    unawaited(_friends.search(_idField.text));
  }

  /// Removes [player] from the friends, once the player has said so.
  Future<void> _confirmRemove(PlayerCard player) async {
    final t = Strings(context.read<GameState>().lang);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => GlassDialog(
        key: const ValueKey('friend-remove-dialog'),
        padding: const EdgeInsets.all(Space.xl),
        title: Row(
          children: [
            Icon(Icons.person_remove_rounded, size: 20, color: scheme.error),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                t.removeFriendQ(player.displayName),
                style: AppTheme.label(
                  theme.textTheme.titleMedium ?? const TextStyle(),
                ),
              ),
            ),
          ],
        ),
        content: Text(
          t.removeFriendBody,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurface.withValues(alpha: AppTheme.inkMed),
          ),
        ),
        actions: [
          GlassButton(
            key: const ValueKey('friend-remove-cancel'),
            style: GlassButtonStyle.text,
            label: t.cancel,
            onPressed: () => Navigator.pop(dialogContext, false),
          ),
          GlassButton(
            key: const ValueKey('friend-remove-confirm'),
            style: GlassButtonStyle.primary,
            label: t.removeFriendConfirm,
            buttonStyle: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final removed = await _friends.remove(player.userId);
    // The friend has gone from the list: the profile of somebody who is no
    // longer a friend is not where the player meant to be.
    if (removed && mounted && _view == _View.profile) _back();
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    final myId = context.select<GameState, String>((s) => s.user?.id ?? '');
    final inLobby = context.select<GameState, bool>(
      (s) => s.screen == Screen.lobby && s.user != null,
    );
    // Nothing here belongs anywhere but the lobby: signed out, or sent to a
    // table, the page goes.
    if (!inLobby && !_leaving) {
      _leaving = true;
      // This page's own route, and anything opened over it (the question
      // before Remove Friend) — never whatever else is on top.
      final route = ModalRoute.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || route == null || !route.isActive) return;
        final navigator = Navigator.of(context);
        navigator.popUntil((r) => r == route);
        navigator.pop();
      });
    }
    final t = Strings(lang);
    final theme = Theme.of(context);
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom = MediaQuery.paddingOf(context).bottom;

    final body = AnimatedSwitcher(
      duration: Motion.base,
      switchInCurve: Motion.standard,
      switchOutCurve: Motion.standard,
      // Each page fills the body and starts at its top: the switcher's own
      // layout centres a page shorter than the body, which set Add Friend's
      // field adrift in the middle of the panel.
      layoutBuilder: (current, previous) =>
          Stack(fit: StackFit.expand, children: [...previous, ?current]),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.03, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: switch (_view) {
        _View.list => _FriendsList(
          key: const ValueKey('friends-view-list'),
          t: t,
          onAdd: _openAdd,
          onProfile: (who) => _openProfile(who, from: _View.list),
        ),
        _View.add => _AddFriendView(
          key: const ValueKey('friends-view-add'),
          t: t,
          field: _idField,
          focus: _idFocus,
          onSearch: _search,
          onProfile: (who) => _openProfile(who, from: _View.add),
        ),
        _View.profile => _ProfileView(
          key: ValueKey('friends-view-profile:${_profileSeed?.userId}'),
          t: t,
          seed: _profileSeed,
          onRemove: _confirmRemove,
        ),
      },
    );

    return PopScope(
      canPop: _view == _View.list,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: SafeArea(
        child: Padding(
          // The page stands above the keyboard rather than under it: the
          // Player ID field and its key are what is being used.
          padding: EdgeInsets.fromLTRB(
            Space.md,
            Space.md,
            Space.md,
            Space.md + math.max(0.0, keyboard - safeBottom),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints.loose(FriendsScreen.largest),
              child: DecoratedBox(
                // By day the card is laid on white of its own, as the Lucky
                // Draw's is: the lobby must not show through a page being read.
                decoration: BoxDecoration(
                  color: dark ? null : AppTheme.panelBase(b),
                  borderRadius: BorderRadius.circular(Radii.lg),
                ),
                child: PremiumGlassPanel(
                  mode: GlassMode.auto,
                  priority: 20,
                  radius: Radii.lg,
                  // Obsidian glass by night, the lobby's own card warmed by
                  // day, lit gold along its top edge — the Lucky Draw's page.
                  surface: dark ? GlassSurface.pane : GlassSurface.card,
                  tint: dark ? null : AppTheme.gold,
                  edge: AppTheme.gold.withValues(alpha: dark ? 0.42 : 0.6),
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    Space.md,
                    Space.lg,
                    Space.md,
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final bare =
                            keyboard > 0 &&
                            _view == _View.add &&
                            box.maxHeight < FriendsScreen.typingRoom;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (!bare) ...[
                              _header(t, typing: keyboard > 0),
                              if (_view == _View.list) ...[
                                const SizedBox(height: Space.sm),
                                _PlayerIdStrip(
                                  t: t,
                                  id: myId,
                                  copied: _copied,
                                  onCopy: () => _copyId(myId),
                                ),
                              ],
                              // Add Friend keeps this gap inside its own
                              // scroll view (_AddFriendView).
                              if (_view != _View.add)
                                const SizedBox(height: Space.md),
                            ],
                            // Keyed so the field keeps its focus as the header
                            // steps aside and comes back.
                            Expanded(
                              key: const ValueKey('friends-body'),
                              child: body,
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(Strings t, {required bool typing}) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final short = Breaks.isShort(MediaQuery.sizeOf(context).height);
    final glass = GlassColors.of(context);
    final (title, subtitle) = switch (_view) {
      _View.list => (t.friends, null),
      _View.add => (t.addFriend, typing ? null : t.addFriendHint),
      // The name stands beside the picture below, as large as a name on this
      // page gets; the header says what the page is.
      _View.profile => (t.playerProfile, null),
    };

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Dim.minTouch),
      child: Row(
        children: [
          if (_view == _View.list)
            const _Mark(
              lit: true,
              child: _MarkGlyph(icon: Icons.people_alt_rounded),
            )
          else
            _RoundKey(
              key: const ValueKey('friends-back'),
              icon: Icons.arrow_back_rounded,
              tooltip: t.back,
              onTap: _back,
            ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.label(
                    (short ? text.titleMedium : text.titleLarge)!,
                    weight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: glass.cardMuted),
                  ),
              ],
            ),
          ),
          if (_view == _View.list) ...[
            const SizedBox(width: Space.sm),
            GlassButton(
              key: const ValueKey('friends-add'),
              style: GlassButtonStyle.primary,
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: t.addFriend,
              onPressed: _openAdd,
            ),
          ],
          const SizedBox(width: Space.sm),
          _RoundKey(
            key: const ValueKey('friends-close'),
            icon: Icons.close_rounded,
            tooltip: t.close,
            onTap: _close,
          ),
        ],
      ),
    );
  }
}

/// The glyph in the page's own mark: gold, as the Settings drawer's is.
class _MarkGlyph extends StatelessWidget {
  const _MarkGlyph({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => Icon(
    icon,
    size: 16,
    color: AppTheme.goldInk(Theme.of(context).brightness),
  );
}

/// A round 44dp key with one glyph: Back and Close.
class _RoundKey extends StatelessWidget {
  const _RoundKey({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: Dim.minTouch,
    child: PressScale(
      child: IconButton(
        padding: EdgeInsets.zero,
        tooltip: tooltip,
        icon: Icon(icon, size: 20),
        onPressed: onTap,
      ),
    ),
  );
}

/// "Your Player ID", the id itself and the key that copies it — what a
/// player reads out or sends to a friend so the friend can add them. The id
/// is never cut: where it is wider than its room it is set smaller.
class _PlayerIdStrip extends StatelessWidget {
  const _PlayerIdStrip({
    required this.t,
    required this.id,
    required this.copied,
    required this.onCopy,
  });

  final Strings t;
  final String id;
  final bool copied;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final glass = GlassColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      key: const ValueKey('friends-player-id'),
      padding: const EdgeInsets.fromLTRB(
        Space.md,
        Space.xxs,
        Space.xxs,
        Space.xxs,
      ),
      decoration: BoxDecoration(
        color: glass.wellFill,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: dark ? glass.borderTop : glass.cardBorder,
          width: Dim.hairline,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.badge_outlined, size: 16, color: glass.cardMuted),
          const SizedBox(width: Space.sm),
          Text(
            t.yourPlayerId,
            maxLines: 1,
            style: AppTheme.label(text.labelMedium!, colour: glass.cardMuted),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                id,
                key: const ValueKey('friends-player-id-value'),
                maxLines: 1,
                style: AppTheme.money(
                  text.labelLarge!,
                  colour: glass.textDisplay,
                  weight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: Space.sm),
          GlassButton(
            key: const ValueKey('friends-copy-id'),
            style: GlassButtonStyle.text,
            icon: Icon(
              copied ? Icons.check_rounded : Icons.copy_rounded,
              size: 16,
            ),
            label: copied ? t.idCopied : t.copyId,
            onPressed: id.isEmpty ? null : onCopy,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- the list

/// The page's own list: the requests waiting for the player and their
/// friends, read again every [FriendsState.pollEvery] and on a pull.
///
/// Side by side wherever the page is wide enough for two columns — every
/// landscape phone: requests on the left, friends on the right, each
/// scrolling on its own, so a player sees who is asking and who is playing at
/// once. One above the other stood the requests over the whole of a 640dp
/// phone's list at text x1.25, and the friends started below the fold.
/// Narrower than that, one list: the requests, then the friends.
class _FriendsList extends StatelessWidget {
  const _FriendsList({
    super.key,
    required this.t,
    required this.onAdd,
    required this.onProfile,
  });

  final Strings t;
  final VoidCallback onAdd;
  final void Function(PlayerCard who) onProfile;

  /// The narrowest body that takes two columns: a 592dp phone's (544dp).
  static const double twoColumns = 520;

  /// The requests' share of a two-column body; the friends, whose rows say
  /// more, take the rest.
  static const double requestsShare = 0.44;

  @override
  Widget build(BuildContext context) {
    final f = context.watch<FriendsState>();
    if (!f.loaded) {
      if (f.failed && !f.loading) {
        return _Trouble(
          key: const ValueKey('friends-load-failed'),
          message: t.friendsLoadFailed,
          retry: t.friendsRetry,
          onRetry: f.refresh,
        );
      }
      return const _Waiting(key: ValueKey('friends-loading'));
    }

    final english = t.lang == AppLang.english;
    return LayoutBuilder(
      builder: (context, box) {
        final split = box.maxWidth >= twoColumns;
        final requests = <Widget>[
          _SectionHead(
            label: t.friendRequests,
            count: f.incoming.length,
            english: english,
          ),
          if (f.incoming.isEmpty)
            _Pane(
              child: _QuietLine(
                key: const ValueKey('friends-no-requests'),
                icon: Icons.inbox_outlined,
                text: t.noFriendRequests,
              ),
            )
          else
            _Pane(
              children: [
                for (final request in f.incoming)
                  _RequestRow(
                    key: ValueKey('friend-request-${request.requestId}'),
                    t: t,
                    request: request,
                    // In a column of its own a request's keys stand under
                    // its name, where both keep their words.
                    stacked: split,
                    onProfile: () => onProfile(request.player),
                  ),
              ],
            ),
        ];
        final friends = <Widget>[
          _SectionHead(
            label: t.friends,
            count: f.friends.length,
            english: english,
          ),
          if (f.friends.isEmpty)
            _NoFriends(t: t, onAdd: onAdd)
          else
            _Pane(
              children: [
                for (final friend in f.friends)
                  _FriendRow(
                    key: ValueKey('friend-${friend.userId}'),
                    t: t,
                    friend: friend,
                    onTap: () => onProfile(friend.player),
                  ),
              ],
            ),
        ];
        if (!split) {
          return _Scroll(
            listKey: const ValueKey('friends-list'),
            onRefresh: f.refresh,
            children: [
              ...requests,
              const SizedBox(height: Space.lg),
              ...friends,
            ],
          );
        }
        const gap = Space.lg;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: (box.maxWidth - gap) * requestsShare,
              child: _Scroll(
                listKey: const ValueKey('friends-requests'),
                onRefresh: f.refresh,
                children: requests,
              ),
            ),
            const SizedBox(width: gap),
            Expanded(
              child: _Scroll(
                listKey: const ValueKey('friends-list'),
                onRefresh: f.refresh,
                children: friends,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One scrolling column of the page: pulled down, it reads the lists again;
/// faded at an edge while there is more beyond it.
class _Scroll extends StatelessWidget {
  const _Scroll({
    required this.listKey,
    required this.onRefresh,
    required this.children,
  });

  final Key listKey;
  final Future<void> Function() onRefresh;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    child: EdgeFade(
      extent: Space.lg,
      child: ListView(
        key: listKey,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: Space.md),
        children: children,
      ),
    ),
  );
}

/// A section's name over its rows, with how many there are.
class _SectionHead extends StatelessWidget {
  const _SectionHead({
    required this.label,
    required this.count,
    required this.english,
  });

  final String label;
  final int count;

  /// Tracked capitals in English only: spread over Devanagari or Gurmukhi,
  /// tracking pulls the vowel signs off their letters.
  final bool english;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final glass = GlassColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.xs, Space.xs, 0, Space.sm),
      child: Row(
        children: [
          Flexible(
            child: Semantics(
              header: true,
              child: Text(
                english ? label.toUpperCase() : label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.label(
                  text.labelMedium!,
                  colour: theme.colorScheme.onSurface.withValues(
                    alpha: AppTheme.inkMed,
                  ),
                ).copyWith(letterSpacing: english ? 1.2 : 0),
              ),
            ),
          ),
          const SizedBox(width: Space.sm),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.sm,
              vertical: 1,
            ),
            decoration: BoxDecoration(
              color: glass.wellFill,
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Text(
              '$count',
              style: AppTheme.money(text.labelSmall!, colour: glass.cardMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// A group of rows on one card of the lobby's own surface, parted by inset
/// hairlines — one pane a section, never a card a row.
class _Pane extends StatelessWidget {
  const _Pane({this.children, this.child})
    : assert((children == null) != (child == null));

  final List<Widget>? children;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final rows = children;
    final divider = Container(
      margin: const EdgeInsets.only(left: Space.md + 36 + Space.md),
      height: Dim.hairline,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
    );
    return PremiumGlassPanel(
      surface: GlassSurface.card,
      radius: Radii.md,
      elevated: false,
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        // A pane's one child spans it, so a centred column stands in the
        // pane's middle: the panel hands its child loose constraints, and a
        // column only as wide as its words stood at the pane's left.
        child: rows == null
            ? SizedBox(width: double.infinity, child: child)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) divider,
                    rows[i],
                  ],
                ],
              ),
      ),
    );
  }
}

/// One quiet line in a pane: nothing to show here.
class _QuietLine extends StatelessWidget {
  const _QuietLine({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.md,
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: glass.cardMuted),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: glass.cardMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "No Friends Yet · Add friends using their Player ID. [Add Friend]".
class _NoFriends extends StatelessWidget {
  const _NoFriends({required this.t, required this.onAdd});

  final Strings t;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final glass = GlassColors.of(context);
    return _Pane(
      child: Padding(
        key: const ValueKey('friends-empty'),
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.group_add_outlined, size: 28, color: glass.cardMuted),
            const SizedBox(height: Space.sm),
            Text(
              t.noFriendsTitle,
              textAlign: TextAlign.center,
              style: AppTheme.label(text.titleSmall!, weight: FontWeight.w700),
            ),
            const SizedBox(height: Space.xxs),
            Text(
              t.noFriendsBody,
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: glass.cardMuted),
            ),
            const SizedBox(height: Space.md),
            GlassButton(
              key: const ValueKey('friends-empty-add'),
              style: GlassButtonStyle.primary,
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: t.addFriend,
              onPressed: onAdd,
            ),
          ],
        ),
      ),
    );
  }
}

/// A player's picture, from the URL the server resolved for them.
class _Portrait extends StatelessWidget {
  const _Portrait({required this.player, this.radius = 18});

  final PlayerCard player;
  final double radius;

  @override
  Widget build(BuildContext context) => Avatar(
    url: context.read<GameState>().absoluteUrl(player.pictureUrl),
    fallback: player.displayName,
    radius: radius,
    animate: true,
  );
}

/// Where a friend is: a dot and a word — green "Online", grey "Offline" —
/// and while they play, "Playing now" and the game under it. Never where
/// they sit, never what they hold.
class _PresenceLines extends StatelessWidget {
  const _PresenceLines({required this.t, required this.presence});

  final Strings t;
  final FriendPresence presence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final glass = GlassColors.of(context);
    final online = presence.isOnline;
    final state = context.read<GameState>();
    final game = presenceGameLine(
      t,
      presence,
      engineName: state.lobbyEngineServerName,
      categoryName: state.lobbyServerName,
    );
    final small = text.bodySmall!;
    // The dot stands on the first line, where "Online" is, when "Playing now"
    // takes a second one (Hindi at text x1.25 does).
    final firstLine =
        MediaQuery.textScalerOf(context).scale(small.fontSize ?? 12) *
        (small.height ?? 1.2);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(
                top: math.max(0.0, (firstLine - _Dot.size) / 2),
              ),
              child: _Dot(online: online),
            ),
            const SizedBox(width: Space.sm),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: online ? t.presenceOnline : t.presenceOffline,
                      style: small.copyWith(
                        color: online ? glass.textBody : glass.cardMuted,
                      ),
                    ),
                    if (presence.isPlaying) ...[
                      TextSpan(
                        text: '  ·  ',
                        style: small.copyWith(color: glass.cardMuted),
                      ),
                      TextSpan(
                        text: t.playingNow,
                        style: AppTheme.label(
                          small,
                          colour: AppTheme.goldInk(b),
                          weight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (game != null)
          Padding(
            padding: const EdgeInsets.only(left: _Dot.size + Space.sm),
            child: Text(
              game,
              key: const ValueKey('friend-game'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: small.copyWith(color: glass.cardMuted),
            ),
          ),
      ],
    );
  }
}

/// The presence dot: green online, grey offline.
class _Dot extends StatelessWidget {
  const _Dot({required this.online});

  final bool online;

  static const double size = 8;

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final glass = GlassColors.of(context);
    final colour = online ? friendsGreen(b) : glass.cardMuted;
    return Container(
      key: ValueKey(online ? 'presence-dot-online' : 'presence-dot-offline'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colour,
        boxShadow: online
            ? [BoxShadow(color: colour.withValues(alpha: 0.5), blurRadius: 4)]
            : null,
      ),
    );
  }
}

/// One friend: picture, name, where they are; a tap opens their profile.
class _FriendRow extends StatelessWidget {
  const _FriendRow({
    super.key,
    required this.t,
    required this.friend,
    required this.onTap,
  });

  final Strings t;
  final FriendItem friend;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    return InkWell(
      enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
      onTap: () {
        tapHaptic(context);
        onTap();
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.md,
            vertical: Space.sm,
          ),
          child: Row(
            children: [
              _Portrait(player: friend.player),
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
                    _PresenceLines(t: t, presence: friend.presence),
                  ],
                ),
              ),
              const SizedBox(width: Space.sm),
              Icon(Icons.chevron_right_rounded, color: glass.cardMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Keys at the end of a row, given at most [share] of the row's width and set
/// smaller rather than cut where a language's words need more than that.
class _RowKeys extends StatelessWidget {
  const _RowKeys({required this.children, this.share = 0.6});

  final List<Widget> children;
  final double share;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => ConstrainedBox(
      constraints: BoxConstraints(maxWidth: box.maxWidth * share),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    ),
  );
}

/// The size and padding of a row's own keys: a step more compact than a
/// page's keys, so two of them sit beside a name, and still a full touch
/// target (the tap area stays 48dp).
const ButtonStyle _rowKeyStyle = ButtonStyle(
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Space.lg)),
  visualDensity: VisualDensity.compact,
);

/// A request waiting for the player: who, and Accept / Reject. Inline in a
/// full-width list; [stacked] in a column of its own, the keys under the
/// name at the row's end, where both keep their words.
class _RequestRow extends StatelessWidget {
  const _RequestRow({
    super.key,
    required this.t,
    required this.request,
    required this.onProfile,
    this.stacked = false,
  });

  final Strings t;
  final FriendRequestItem request;
  final VoidCallback onProfile;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final f = context.watch<FriendsState>();
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final busy = f.busyRequests.contains(request.requestId);
    final id = request.requestId;

    final who = InkWell(
      borderRadius: BorderRadius.circular(Radii.sm),
      onTap: onProfile,
      child: Row(
        children: [
          _Portrait(player: request.player),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  request.player.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.label(theme.textTheme.titleSmall!),
                ),
                Text(
                  t.wantsToBeFriends,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: glass.cardMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final keys = <Widget>[
      GlassButton(
        key: ValueKey('friend-accept-$id'),
        style: GlassButtonStyle.primary,
        buttonStyle: _rowKeyStyle,
        icon: busy
            ? const _Spinner()
            : const Icon(Icons.check_rounded, size: 18),
        label: t.friendAccept,
        onPressed: busy ? null : () => f.accept(id),
      ),
      const SizedBox(width: Space.sm),
      // Quieter than Accept, never greyed like a key that cannot be pressed:
      // the well a key on a panel is made of.
      GlassButton(
        key: ValueKey('friend-reject-$id'),
        style: GlassButtonStyle.glass,
        buttonStyle: _rowKeyStyle,
        icon: const Icon(Icons.close_rounded, size: 18),
        label: t.friendReject,
        onPressed: busy ? null : () => f.reject(id),
      ),
    ];

    return LayoutBuilder(
      builder: (context, box) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.md,
            vertical: Space.sm,
          ),
          child: stacked
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    who,
                    const SizedBox(height: Space.sm),
                    Align(
                      alignment: Alignment.centerRight,
                      child: _RowKeys(share: 1, children: keys),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: who),
                    const SizedBox(width: Space.sm),
                    SizedBox(
                      width: box.maxWidth * 0.5,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _RowKeys(share: 1, children: keys),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// A key's glyph while its move is out.
class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

/// Still being read.
class _Waiting extends StatelessWidget {
  const _Waiting({super.key});

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator.adaptive());
}

/// Something could not be read: what, and — where trying again could help —
/// the key that does.
class _Trouble extends StatelessWidget {
  const _Trouble({super.key, required this.message, this.retry, this.onRetry});

  final String message;
  final String? retry;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final again = onRetry;
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_rounded, size: 28, color: glass.cardMuted),
            const SizedBox(height: Space.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(
                  alpha: AppTheme.inkMed,
                ),
              ),
            ),
            if (again != null && retry != null) ...[
              const SizedBox(height: Space.md),
              GlassButton(
                key: const ValueKey('friends-retry'),
                style: GlassButtonStyle.glass,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: retry,
                onPressed: () => again(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A line that says what just happened on this page — a search that found
/// nobody, a request refused — with a glyph for its kind.
class _Note extends StatelessWidget {
  const _Note({super.key, required this.text, this.icon = Icons.info_outline});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: glass.cardMuted),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: glass.textBody,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A state in place of a key: "Request Sent", "Friends".
class _Tag extends StatelessWidget {
  const _Tag({super.key, required this.icon, required this.label, this.ink});

  final IconData icon;
  final String label;
  final Color? ink;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final colour = ink ?? glass.textBody;
    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      decoration: BoxDecoration(
        color: glass.wellFill,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: glass.cardBorder, width: Dim.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: colour),
          const SizedBox(width: Space.sm),
          Text(
            label,
            maxLines: 1,
            style: AppTheme.label(theme.textTheme.labelLarge!, colour: colour),
          ),
        ],
      ),
    );
  }
}

/// What the player can do about [player], by what they are to each other:
/// Add Friend, Request Sent, Accept, Friends — and nothing for themselves.
/// On a profile a friend's is Remove Friend instead ([onRemove]).
class _RelationAction extends StatelessWidget {
  const _RelationAction({
    required this.t,
    required this.player,
    required this.status,
    required this.requestId,
    this.onRemove,
  });

  final Strings t;
  final PlayerCard player;
  final String status;
  final String? requestId;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final f = context.watch<FriendsState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final userId = player.userId;
    switch (status) {
      case FriendStatus.none:
        final sending = f.sendingTo == userId;
        return GlassButton(
          key: const ValueKey('friend-send'),
          style: GlassButtonStyle.primary,
          icon: sending
              ? const _Spinner()
              : const Icon(Icons.person_add_alt_1_rounded, size: 18),
          label: t.addFriend,
          onPressed: f.sendingTo != null ? null : () => f.sendRequest(userId),
        );
      case FriendStatus.pendingSent:
        return _Tag(
          key: const ValueKey('friend-request-sent'),
          icon: Icons.schedule_rounded,
          label: t.requestSent,
        );
      case FriendStatus.pendingReceived:
        final id = requestId;
        final busy = id != null && f.busyRequests.contains(id);
        return GlassButton(
          key: const ValueKey('friend-lookup-accept'),
          style: GlassButtonStyle.primary,
          icon: busy
              ? const _Spinner()
              : const Icon(Icons.check_rounded, size: 18),
          label: t.friendAccept,
          onPressed: id == null || busy ? null : () => f.accept(id),
        );
      case FriendStatus.friends:
        final remove = onRemove;
        if (remove != null) {
          final removing = f.removing.contains(userId);
          // The well a key on a panel is made of, in the error's ink:
          // plain to find, never louder than the page (an outline key drew
          // its own shadow through its clear body by day, a grey slab).
          return GlassButton(
            key: const ValueKey('friend-remove'),
            style: GlassButtonStyle.glass,
            tone: scheme.error,
            icon: removing
                ? const _Spinner()
                : const Icon(Icons.person_remove_rounded, size: 18),
            label: t.removeFriend,
            onPressed: removing ? null : remove,
          );
        }
        return _Tag(
          key: const ValueKey('friend-already'),
          icon: Icons.check_circle_rounded,
          label: t.friends,
          ink: friendsGreen(theme.brightness),
        );
      default:
        return const SizedBox.shrink(key: ValueKey('friend-self'));
    }
  }
}

// ---------------------------------------------------------- add a friend

/// Add Friend: a Player ID typed or pasted, the search, and the player found
/// with what can be done about them — or why nobody was found.
class _AddFriendView extends StatelessWidget {
  const _AddFriendView({
    super.key,
    required this.t,
    required this.field,
    required this.focus,
    required this.onSearch,
    required this.onProfile,
  });

  final Strings t;
  final TextEditingController field;
  final FocusNode focus;
  final VoidCallback onSearch;
  final void Function(PlayerCard who) onProfile;

  @override
  Widget build(BuildContext context) {
    final f = context.watch<FriendsState>();
    final found = f.lookup;
    final error = f.searchError;
    final note = f.lookupNote;

    return SingleChildScrollView(
      // The gap under the page's header, kept inside the scroll view: the
      // field's floating label stands half above the field's own box, and a
      // scroll view whose contents overflow — the keyboard up on a landscape
      // phone, the header gone — clips at its top edge, where it cut the
      // label in half.
      padding: const EdgeInsets.only(top: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: KeyboardFocusGuard(
                  child: GlassTextField(
                    key: const ValueKey('friends-id-field'),
                    controller: field,
                    focusNode: focus,
                    labelText: t.playerIdLabel,
                    prefixIcon: const Icon(
                      Icons.person_search_rounded,
                      size: 18,
                    ),
                    maxLength: 64,
                    counterText: '',
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(isDense: true),
                    onSubmitted: (_) => onSearch(),
                  ),
                ),
              ),
              const SizedBox(width: Space.sm),
              GlassButton(
                key: const ValueKey('friends-search'),
                style: GlassButtonStyle.primary,
                icon: f.searching
                    ? const _Spinner()
                    : const Icon(Icons.search_rounded, size: 18),
                label: t.searchPlayer,
                onPressed: f.searching ? null : onSearch,
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          if (found != null) ...[
            _PlayerResult(
              key: ValueKey('friend-result-${found.player.userId}'),
              t: t,
              found: found,
              onOpen: () => onProfile(found.player),
            ),
            if (note != null)
              _Note(
                key: const ValueKey('friend-note'),
                text: friendsRefusalText(t, note),
              ),
          ] else if (error != null)
            _Note(
              key: const ValueKey('friend-search-error'),
              icon: error == 'player_not_found'
                  ? Icons.person_off_outlined
                  : Icons.info_outline,
              text: friendsRefusalText(t, error),
            )
          else if (!f.searching)
            // Nothing asked yet: where the ID a friend gives comes from.
            _Note(
              key: const ValueKey('friend-search-how'),
              icon: Icons.badge_outlined,
              text: t.addFriendHowTo,
            ),
        ],
      ),
    );
  }
}

/// The player a search found: picture, name and the move that fits — and a
/// tap on the card opens their profile.
class _PlayerResult extends StatelessWidget {
  const _PlayerResult({
    super.key,
    required this.t,
    required this.found,
    required this.onOpen,
  });

  final Strings t;
  final PlayerLookup found;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final self = found.friendStatus == FriendStatus.self;
    return _Pane(
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: LayoutBuilder(
            builder: (context, box) => Row(
              children: [
                _Portrait(player: found.player, radius: 22),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        found.player.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.label(theme.textTheme.titleSmall!),
                      ),
                      if (self)
                        Text(
                          t.thatsYou,
                          key: const ValueKey('friend-thats-you'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: glass.cardMuted,
                          ),
                        ),
                    ],
                  ),
                ),
                if (!self) ...[
                  const SizedBox(width: Space.sm),
                  SizedBox(
                    width: box.maxWidth * 0.45,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: _RowKeys(
                        share: 1,
                        children: [
                          _RelationAction(
                            t: t,
                            player: found.player,
                            status: found.friendStatus,
                            requestId: found.requestId,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- profile

/// A player's profile: their picture and name, where they are (a friend's
/// only), their record, and the move that fits — Remove Friend for a friend.
class _ProfileView extends StatelessWidget {
  const _ProfileView({
    super.key,
    required this.t,
    required this.seed,
    required this.onRemove,
  });

  final Strings t;
  final PlayerCard? seed;
  final void Function(PlayerCard player) onRemove;

  @override
  Widget build(BuildContext context) {
    final f = context.watch<FriendsState>();
    final profile = f.profile;
    final error = f.profileError;
    if (profile == null && error != null) {
      final gone = error == 'player_not_found';
      final who = seed;
      return _Trouble(
        key: const ValueKey('friend-profile-failed'),
        message: gone ? friendsRefusalText(t, error) : t.profileLoadFailed,
        retry: gone ? null : t.friendsRetry,
        onRetry: gone || who == null ? null : () => f.openProfile(who.userId),
      );
    }
    // Who it is shows at once — the list or the search already knew — and
    // the rest fills in as the profile arrives.
    final player = profile?.player ?? seed;
    if (player == null) {
      return const _Waiting(key: ValueKey('friend-profile-loading'));
    }

    final theme = Theme.of(context);
    final text = theme.textTheme;
    // The friend list is read every fifteen seconds while the page is open;
    // the profile once. Where they are comes from the fresher of the two.
    final presence = profile == null
        ? null
        : profile.friendStatus == FriendStatus.friends
        ? f.presenceOf(profile.userId) ?? profile.presence
        : profile.presence;
    final note = f.profileNote;

    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _Portrait(player: player, radius: 30),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    player.displayName,
                    key: const ValueKey('friend-profile-name'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.label(
                      text.titleMedium!,
                      weight: FontWeight.w700,
                    ),
                  ),
                  if (presence != null) ...[
                    const SizedBox(height: Space.xxs),
                    _PresenceLines(t: t, presence: presence),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (profile != null) ...[
          const SizedBox(height: Space.md),
          Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: _RelationAction(
                t: t,
                player: profile.player,
                status: profile.friendStatus,
                requestId: profile.requestId,
                onRemove: () => onRemove(profile.player),
              ),
            ),
          ),
        ],
        if (note != null)
          _Note(
            key: const ValueKey('friend-profile-note'),
            text: friendsRefusalText(t, note),
          ),
      ],
    );

    final stats = profile == null
        ? const SizedBox(
            height: 120,
            child: _Waiting(key: ValueKey('friend-profile-loading')),
          )
        : PlayerStatsGrid(t: t, stats: profile.stats);

    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 520;
        return EdgeFade(
          extent: Space.lg,
          child: SingleChildScrollView(
            key: const ValueKey('friend-profile'),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: math.min(280.0, box.maxWidth * 0.42),
                        child: identity,
                      ),
                      const SizedBox(width: Space.xl),
                      Expanded(child: stats),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      identity,
                      const SizedBox(height: Space.lg),
                      stats,
                    ],
                  ),
          ),
        );
      },
    );
  }
}
