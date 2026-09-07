import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../widgets/playing_card.dart';
import '../widgets/fireworks.dart';
import '../widgets/poker_chip.dart';
import '../widgets/premium_surface.dart';
import '../widgets/rules_sheet.dart';
import '../widgets/seat_pod.dart';

/// The game room: an oval table with the players around it, the pot in the
/// middle, the viewer's own hand at the bottom, and one bar of controls.
///
/// The viewer always sits at the bottom and the table turns around them.
class TableScreen extends StatelessWidget {
  const TableScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const _TableDrawer(),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  const _SideRail(),
                  const Expanded(child: _Felt()),
                ],
              ),
            ),
            const _ActionBar(),
          ],
        ),
      ),
    );
  }
}

/// The only chrome in the game room: the menu, and the chat below it, stacked
/// down the left edge.
///
/// Everything else that used to sit across the top — the table code, the
/// category, the hand number — is in the drawer. None of it changed what a
/// player does next, and a rail costs width, which a landscape screen has, in
/// place of height, which it does not.
class _SideRail extends StatelessWidget {
  const _SideRail();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();

    return SizedBox(
      width: 46,
      child: Column(
        children: [
          IconButton(
            tooltip: state.t.tableMenu,
            visualDensity: VisualDensity.compact,
            onPressed: () => Scaffold.of(context).openDrawer(),
            icon: const Icon(Icons.menu),
          ),
          Badge(
            isLabelVisible: state.unreadChat > 0,
            label: Text('${state.unreadChat}'),
            child: IconButton(
              tooltip: state.t.tableChat,
              visualDensity: VisualDensity.compact,
              onPressed: () => _openChat(context, state),
              icon: const Icon(Icons.chat_bubble_outline),
            ),
          ),
        ],
      ),
    );
  }

  void _openChat(BuildContext context, GameState state) {
    state.markChatRead();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ChatSheet(),
    );
  }
}

/// The table menu. Leaving lives here rather than as a button on the bar,
/// where it sat one stray tap away from the action controls.
class _TableDrawer extends StatelessWidget {
  const _TableDrawer();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final t = state.t;

    final room = state.room;
    if (room == null) return const Drawer(child: SizedBox.shrink());
    final you = room.you;

    return Drawer(
      width: 320,
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Table ${room.code}',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        Text(
                          '${room.category.toUpperCase()}  ·  hand ${room.handNo}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, indent: 20, endIndent: 20),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.savings_outlined, size: 18),
              title: Text(t.yourChips),
              trailing: Text(
                formatChips(you?.chips ?? state.user?.chips ?? 0),
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.paid_outlined, size: 18),
              title: Text(t.boot),
              trailing: Text(
                formatChips(room.bootAmount),
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            if (room.maxPot > 0)
              ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                leading: const Icon(Icons.trending_up, size: 18),
                title: Text(t.maxPot),
                trailing: Text(
                  formatChips(room.maxPot),
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            const Divider(height: 1, indent: 20, endIndent: 20),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.menu_book_outlined, size: 18),
              title: Text(t.rules),
              onTap: () {
                Navigator.pop(context);
                showRules(context);
              },
            ),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: Icon(
                state.themeMode == ThemeMode.dark
                    ? Icons.light_mode_outlined
                    : Icons.dark_mode_outlined,
                size: 18,
              ),
              title: Text(
                state.themeMode == ThemeMode.dark ? t.dayMode : t.nightMode,
              ),
              onTap: state.toggleTheme,
            ),
            const Divider(height: 1, indent: 20, endIndent: 20),
            ListTile(
              leading: state.switching
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.swap_horiz),
              title: Text(t.switchTable),
              subtitle: Text(
                '${t.switchTable} · ${room.category}',
                maxLines: 2,
              ),
              onTap: state.switching
                  ? null
                  : () async {
                      Navigator.pop(context);
                      await _confirmSwitch(context, state, room);
                    },
            ),
            const Divider(height: 1, indent: 20, endIndent: 20),
            ListTile(
              leading: Icon(Icons.logout, color: theme.colorScheme.error),
              title: Text(
                t.leaveTable,
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(t.joinAnother),
              onTap: () async {
                // Close the menu first, so the dialog is not stacked on top of
                // a drawer that is still sliding.
                Navigator.pop(context);
                await _confirmLeave(context, state, room);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Switching is confirmed too. It gives up the seat at this table, and mid-hand
/// that costs the player their stake, so it is not something to do by accident.
Future<void> _confirmSwitch(
    BuildContext context, GameState state, RoomState room) async {
  final midHand =
      room.state == TableState.betting && room.you?.status == SeatState.active;

  final go = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.swap_horiz),
      title: Text(state.t.switchTableQ),
      content: Text(midHand ? state.t.switchMidHand : state.t.switchIdle),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(state.t.stay),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(state.t.switchAction),
        ),
      ],
    ),
  );

  if (go == true) await state.switchTable();
}

/// Requirement 25: leaving is confirmed first, and the wording changes when a
/// hand is live — that is when walking away actually costs something.
Future<void> _confirmLeave(
    BuildContext context, GameState state, RoomState room) async {
  final midHand =
      room.state == TableState.betting && room.you?.status == SeatState.active;

  final leave = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.logout),
      title: Text(state.t.leaveTableQ),
      content: Text(midHand ? state.t.leaveMidHand : state.t.leaveAnytime),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(state.t.stay),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(state.t.leave),
        ),
      ],
    ),
  );

  if (leave == true) state.leaveTable();
}

class _Felt extends StatelessWidget {
  const _Felt();

  /// Where each seat sits on the felt, as a fraction of it, in view order:
  /// the viewer at the bottom, then clockwise from their left.
  /// A seat's column is pod, then cards, then its bet chip — about half the
  /// felt's height in all — so the top pair sit well clear of the rim or their
  /// names are clipped off by it.
  static const List<Offset> _places = [
    Offset(0.335, 0.00), // you — x only; the pair below sit on the floor
    Offset(0.090, 0.42), // left
    Offset(0.260, 0.28), // top left
    Offset(0.740, 0.28), // top right
    Offset(0.910, 0.42), // right
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);

    final room = state.room;
    if (room == null) return const Center(child: CircularProgressIndicator());

    final seats = state.seatsInViewOrder();
    final turnSeat = room.turn?.seatIndex;
    final progress = state.turnProgress;

    bool onTurn(Seat? s) =>
        s != null && room.state == TableState.betting && s.seatIndex == turnSeat;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final h = box.maxHeight;

          // Everything on the table is a multiple of the pod width, which is
          // itself taken from the felt. The screen this runs on is short and
          // wide in logical pixels, so nothing here may be a fixed size.
          final podW = (h * 0.30).clamp(64.0, 128.0);
          final handH = (h * 0.29).clamp(50.0, 116.0);

          Widget pod(int viewIndex) {
            final s = viewIndex < seats.length ? seats[viewIndex] : null;
            return SeatPod(
              seat: s,
              isMe: s?.userId != null && s!.userId == state.user?.id,
              isDealer: s?.seatIndex == room.dealerSeat,
              onTurn: onTurn(s),
              progress: onTurn(s) ? progress : null,
              deadlineMs: room.turn?.deadline ?? 0,
              totalMs: room.turnTimeoutMs,
              chipsHidden: room.chipsHidden,
              width: podW,
              avatarUrl: state.absoluteUrl(s?.avatarUrl),
              saying: s?.userId == null
                  ? null
                  : state.saidRecently[s!.userId]?.text,
              // The bottom seat stacks upwards, or its chip runs off the felt.
              reversed: viewIndex == 0,
            );
          }

          // Positioned by centre, so a seat stays put as its own column grows
          // and shrinks with the hand.
          Widget at(Offset place, Widget child, {double? width}) => Positioned(
                left: place.dx * w - (width ?? podW) / 2,
                top: place.dy * h,
                width: width ?? podW,
                child: FractionalTranslation(
                  translation: const Offset(0, -0.5),
                  child: child,
                ),
              );

          // The same surface the lobby cards are made of, at table size: one
          // gradient, one lit edge, one shadow. The table is a stadium rather
          // than a card only because it is a table.
          // The room takes its colour from the table you sat down at, so a
          // blind table and a seen one are told apart at a glance — and the
          // room matches the lobby card you tapped to get here. A bigger stake
          // tints deeper, so the two stakes differ as well.
          final blind = room.category == TableCategory.blind;
          final accent = blind ? theme.colorScheme.tertiary : AppTheme.gold;
          final deep = room.bootAmount >= 1000;
          final base = theme.brightness == Brightness.dark ? 0.26 : 0.18;

          return PremiumSurface(
            accent: accent,
            radius: h / 2,
            borderWidth: 3,
            tint: deep ? base + 0.08 : base,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                for (var i = 1; i < _places.length; i++) at(_places[i], pod(i)),

                at(const Offset(0.5, 0.26), _Pot(room: room), width: w * 0.34),
                at(const Offset(0.5, 0.44), _Status(room: room), width: w * 0.4),

                // The viewer's pod and hand stand on the floor of the table
                // rather than being centred on a point: their columns are
                // different heights, so centring both left one hanging over the
                // rim and clipped by it. A shared bottom line keeps them inside
                // and flush with the edge.
                Positioned(
                  left: _places[0].dx * w - podW / 2,
                  bottom: h * 0.035,
                  width: podW,
                  child: pod(0),
                ),
                Positioned(
                  left: _places[0].dx * w + podW / 2 + 8,
                  bottom: h * 0.035,
                  child: _OwnHand(cardHeight: handH),
                ),

                if (state.showdown.isNotEmpty || state.showdownResult.isNotEmpty)
                  Positioned.fill(child: _Showdown(theme: theme)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Pot extends StatelessWidget {
  const _Pot({required this.room});
  final RoomState room;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<GameState>();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(state.t.pot,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 2,
            )),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // The pile grows as the pot does — a nudge upward each time chips
            // land, so the middle of the table is where the eye goes.
            _PotChips(pot: room.pot),
            const SizedBox(width: 10),
            Flexible(
              // Chips arriving in the pot is the thing players watch, so the
              // number travels to its new value instead of jumping.
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: room.pot.toDouble()),
                duration: const Duration(milliseconds: 550),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    formatChips(value.round()),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: AppTheme.gold,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '${state.t.stake} ${formatChips(room.stake)}   ·   ${state.t.boot} ${formatChips(room.bootAmount)}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

/// The pile in the middle. It lifts and settles whenever the pot changes, so
/// chips landing is something you see rather than only read.
class _PotChips extends StatefulWidget {
  const _PotChips({required this.pot});
  final int pot;

  @override
  State<_PotChips> createState() => _PotChipsState();
}

class _PotChipsState extends State<_PotChips>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void didUpdateWidget(covariant _PotChips old) {
    super.didUpdateWidget(old);
    if (widget.pot > old.pot) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        // Up and back down, with a touch of overshoot on the way.
        final lift = math.sin(_c.value * math.pi);
        return Transform.translate(
          offset: Offset(0, -6 * lift),
          child: Transform.scale(scale: 1 + 0.12 * lift, child: child),
        );
      },
      child: ChipStack(
        size: 26,
        colours: [scheme.secondary, scheme.tertiary, scheme.primary],
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.room});
  final RoomState room;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);

    final text = switch (room.state) {
      TableState.waiting =>
        '${state.t.waitingForPlayers} (${room.minPlayers})',
      TableState.starting => state.t.startingGame,
      _ => state.myTurn
          ? state.t.yourTurn
          : _nameOf(room, room.turn?.seatIndex) == null
              ? ''
              : '${_nameOf(room, room.turn?.seatIndex)} ${state.t.toAct}',
    };

    if (text.isEmpty) return const SizedBox.shrink();

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        text,
        style: theme.textTheme.titleMedium?.copyWith(
          color: AppTheme.gold,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  static String? _nameOf(RoomState room, int? seatIndex) {
    if (seatIndex == null) return null;
    for (final s in room.seats) {
      if (s.seatIndex == seatIndex && s.occupied) return s.displayName;
    }
    return null;
  }
}

/// The viewer's own three cards, with "See cards" laid over them: looking at
/// your hand is something you do to the cards, and once you have looked the
/// button has no reason to still be there.
class _OwnHand extends StatelessWidget {
  const _OwnHand({required this.cardHeight});
  final double cardHeight;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final you = state.room?.you;
    if (you == null) return const SizedBox.shrink();

    final packed = you.status == SeatState.packed || you.status == SeatState.lost;
    // A packed hand stays on the table, face down and struck out, so the player
    // can see what they folded rather than having it vanish.
    if (you.status != SeatState.active && !packed) return const SizedBox.shrink();

    final cards = you.cards;

    // Looking is allowed at any point, not only on your own turn: it costs
    // nothing and changes nothing for anyone else. Betting still waits for the
    // turn, which the action bar handles.
    final stillBlind = you.isBlind && !packed;
    final blindLeft = you.blindMovesLeft;

    return Container(
      padding: EdgeInsets.all(cardHeight * 0.05),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(cardHeight * 0.14),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < 3; i++)
                _Dealt(
                  key: ValueKey('${state.room?.handNo}-$i'),
                  index: i,
                  child: PlayingCard(
                    height: cardHeight,
                    code: i < cards.length ? cards[i] : null,
                    dimmed: packed,
                  ),
                ),
            ],
          ),
          if (packed)
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: cardHeight * 0.22,
                vertical: cardHeight * 0.08,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.94),
                borderRadius: BorderRadius.circular(cardHeight * 0.1),
              ),
              child: Text(
                state.t.packed,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
            )
          else if (stillBlind)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: state.see,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                  ),
                  child: Text(state.t.seeCards),
                ),
                if (blindLeft > 0) ...[
                  const SizedBox(height: 4),
                  // Says why the cards will turn over on their own, so the
                  // automatic reveal is never a surprise.
                  Text(
                    blindLeft == 1
                        ? state.t.lastBlindMove
                        : '$blindLeft ${state.t.blindMovesLeft}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimary,
                      backgroundColor:
                          theme.colorScheme.scrim.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

/// Slides a card in from the middle of the table, staggered, so a hand looks
/// dealt rather than switched on.
class _Dealt extends StatefulWidget {
  const _Dealt({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_Dealt> createState() => _DealtState();
}

class _DealtState extends State<_Dealt> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration(milliseconds: widget.index * 110), () {
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
    final curved = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);

    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        // From up and to the left: the middle of the table, where the pot is.
        position: Tween(begin: const Offset(-0.5, -0.9), end: Offset.zero)
            .animate(curved),
        child: ScaleTransition(
          scale: Tween(begin: 0.85, end: 1.0).animate(curved),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Requirement 14: every revealed hand, plus who won and for how much.
///
/// It sits over the table rather than replacing it. Covering the felt with a
/// near-opaque sheet reads as the game having stopped; the players, the pot and
/// the chips should all still be there while the hand is being settled.
class _Showdown extends StatelessWidget {
  const _Showdown({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final scheme = theme.colorScheme;

    final won = state.iWon;
    final headline = won
        ? state.t.youAreWinner
        : state.winnerName.isNotEmpty
            ? '${state.winnerName} ${state.t.isTheWinner}'
            : state.showdownResult;

    return Stack(
      children: [
        // Just enough of a wash to lift the banner off the table.
        Positioned.fill(
          child: ColoredBox(color: scheme.scrim.withValues(alpha: 0.22)),
        ),
        Positioned.fill(
          child: Fireworks(seed: state.room?.handNo ?? 0, bursts: won ? 8 : 5),
        ),
        Positioned.fill(
          child: Center(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Banner(headline: headline, won: won, pot: state.winnerPot),
                  if (state.showdown.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final r in state.showdown)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: _RevealedHand(reveal: r),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The announcement itself, which lands rather than appears.
class _Banner extends StatelessWidget {
  const _Banner({required this.headline, required this.won, required this.pot});

  final String headline;
  final bool won;
  final int pot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutBack,
      builder: (context, v, child) => Transform.scale(
        scale: 0.7 + 0.3 * v,
        child: Opacity(opacity: v.clamp(0, 1), child: child),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
        decoration: BoxDecoration(
          color: won ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(
            color: won ? scheme.primary : scheme.outlineVariant,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: (won ? scheme.primary : Colors.black)
                  .withValues(alpha: won ? 0.45 : 0.25),
              blurRadius: 26,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (won) ...[
              Icon(Icons.emoji_events, color: scheme.onPrimaryContainer, size: 26),
              const SizedBox(width: 10),
            ],
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  headline,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: won ? scheme.onPrimaryContainer : scheme.onSurface,
                  ),
                ),
                if (pot > 0)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PokerChip(colour: scheme.secondary, size: 16),
                      const SizedBox(width: 6),
                      Text(
                        formatChips(pot),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: won
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One player's revealed hand.
class _RevealedHand extends StatelessWidget {
  const _RevealedHand({required this.reveal});
  final Reveal reveal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(16),
        border: reveal.won
            ? Border.all(color: theme.colorScheme.primary, width: 2)
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            reveal.displayName,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: reveal.won ? theme.colorScheme.primary : null,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in reveal.cards) PlayingCard(height: 68, code: c),
            ],
          ),
          const SizedBox(height: 3),
          Text(reveal.handName, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Pack on the left, the stake stepper in the middle, Chaal on the right.
///
/// The bar is always there and simply goes dead between turns: one that
/// disappears and comes back moves the buttons under the player's thumb, which
/// is how misclicks happen.
class _ActionBar extends StatelessWidget {
  const _ActionBar();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final live = state.myTurn;
    final options = state.options;
    final showCost = options?.show;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Row(
        children: [
          SizedBox(
            width: 128,
            child: FilledButton.tonal(
              onPressed: live && (options?.canPack ?? false) ? state.pack : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
                backgroundColor: theme.colorScheme.errorContainer,
                foregroundColor: theme.colorScheme.onErrorContainer,
              ),
              child: Text(state.t.pack),
            ),
          ),
          const Spacer(),
          IconButton.filledTonal(
            onPressed: state.canStepDown ? () => state.stepBet(-1) : null,
            iconSize: 26,
            icon: const Icon(Icons.remove),
          ),
          const SizedBox(width: 10),
          Container(
            width: 132,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(23),
            ),
            child: Text(
              formatChips(state.betAmount),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: live
                    ? theme.colorScheme.secondary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 10),
          IconButton.filledTonal(
            onPressed: state.canStepUp ? () => state.stepBet(1) : null,
            iconSize: 26,
            icon: const Icon(Icons.add),
          ),
          const Spacer(),
          // Show is only offered heads-up, so it is the one control that does
          // come and go.
          if (live && showCost != null && showCost > 0) ...[
            SizedBox(
              width: 120,
              child: FilledButton.tonal(
                onPressed: () => state.show(showCost),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  backgroundColor: theme.colorScheme.tertiaryContainer,
                  foregroundColor: theme.colorScheme.onTertiaryContainer,
                ),
                child: Text('${state.t.show}\n${formatChips(showCost)}',
                    textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: 10),
          ],
          SizedBox(
            width: 128,
            child: FilledButton(
              onPressed: live ? state.bet : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
              ),
              child: Text('${state.t.chaal}\n${formatChips(state.betAmount)}',
                  textAlign: TextAlign.center),
            ),
          ),
        ],
      ),
    );
  }
}

/// Requirement 8: room chat. It lives only in memory on the server and goes
/// when the room does.
class _ChatSheet extends StatefulWidget {
  const _ChatSheet();

  @override
  State<_ChatSheet> createState() => _ChatSheetState();
}

class _ChatSheetState extends State<_ChatSheet> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: 320,
        child: Column(
          children: [
            ListTile(
              title: Text(state.t.tableChat),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Expanded(
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: state.chat.length,
                itemBuilder: (context, i) {
                  final m = state.chat[state.chat.length - 1 - i];
                  final mine = m.userId == state.user?.id;
                  // Everyone gets their own colour, kept from their id so a
                  // player looks the same every time they speak.
                  final colour = state.colourFor(m.userId, theme.colorScheme);

                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 4,
                          height: 18,
                          margin: const EdgeInsets.only(right: 8, top: 2),
                          decoration: BoxDecoration(
                            color: colour,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Expanded(
                          child: RichText(
                            text: TextSpan(
                              style: theme.textTheme.bodyMedium,
                              children: [
                                TextSpan(
                                  text: '${mine ? 'You' : m.displayName}: ',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: colour,
                                  ),
                                ),
                                TextSpan(text: m.text),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      maxLength: 200,
                      decoration: InputDecoration(
                        hintText: state.t.saySomething,
                        counterText: '',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(state),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: () => _send(state),
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _send(GameState state) {
    state.sendChat(_input.text);
    _input.clear();
  }
}
