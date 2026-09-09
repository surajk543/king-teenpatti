import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../widgets/playing_card.dart';
import '../widgets/buy_chips.dart';
import '../widgets/drifting_chips.dart';
import '../widgets/fireworks.dart';
import '../widgets/poker_chip.dart';
import '../widgets/premium_surface.dart';
import '../widgets/rules_sheet.dart';
import '../widgets/seat_pod.dart';

/// The game room: an oval table with the players around it, the pot in the
/// middle, the viewer's own hand at the bottom, and one bar of controls.
///
/// The viewer always sits at the bottom and the table turns around them.
/// Which of the two panels the left drawer is showing.
enum _LeftPanel { menu, chat }

class TableScreen extends StatefulWidget {
  const TableScreen({super.key});

  @override
  State<TableScreen> createState() => _TableScreenState();
}

class _TableScreenState extends State<TableScreen> {
  /// The menu and the chat share one drawer rather than being a drawer and a
  /// sheet: both are "the panel behind the left edge", and a Scaffold has only
  /// one of those. Which one is showing is decided before it opens.
  _LeftPanel _panel = _LeftPanel.menu;

  /// Opening is driven from the rail, which sits inside this Scaffold, so the
  /// state is reached by key rather than by looking up an ancestor. The key
  /// lives on the game state so the back gesture can close the drawer too.
  GlobalKey<ScaffoldState> get _scaffold =>
      context.read<GameState>().tableScaffold;

  void _open(_LeftPanel panel) {
    if (panel == _LeftPanel.chat) context.read<GameState>().markChatRead();
    setState(() => _panel = panel);
    _scaffold.currentState?.openDrawer();
  }

  @override
  Widget build(BuildContext context) {
    // This widget subscribes to nothing itself: the game state ticks once a
    // second for the reward countdown, and rebuilding the Scaffold tears an
    // open drawer down with it. Everything inside subscribes for itself.
    return Scaffold(
      key: _scaffold,
      drawer: _panel == _LeftPanel.menu
          ? const _TableDrawer()
          : const _ChatDrawer(),
      body: SafeArea(
        child: Stack(
          children: [
            // The same slow drift of chips the lobby has, behind the felt, so
            // a room and the lobby feel like one place — but carried at more
            // than twice the lobby's opacity. The felt covers most of the
            // screen here, so only the margin around the oval shows a chip at
            // all, and at the lobby's strength that margin looked empty.
            const Positioned.fill(
              child: IgnorePointer(child: DriftingChips(strength: 2.4)),
            ),
            Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      _SideRail(onOpen: _open),
                      const Expanded(child: _Felt()),
                    ],
                  ),
                ),
                const _MissedTurnsStrip(),
                const _ActionBar(),
              ],
            ),
            // Top right, which is the one corner of the felt nothing else
            // uses: the menu and chat are down the left edge, the seats sit
            // around the rim, and the category tag is centred above the pot.
            const Positioned(
              top: 6,
              right: 12,
              child: BuyChipsButton(compact: true),
            ),
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
  const _SideRail({required this.onOpen});

  final void Function(_LeftPanel) onOpen;

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
            onPressed: () => onOpen(_LeftPanel.menu),
            icon: const Icon(Icons.menu),
          ),
          Badge(
            isLabelVisible: state.unreadChat > 0,
            label: Text('${state.unreadChat}'),
            child: IconButton(
              // While the cooldown runs the icon becomes the countdown, so
              // the player can see when they may speak again without opening
              // the chat to find out.
              tooltip: state.canChat
                  ? state.t.tableChat
                  : '${state.t.tableChat} ${state.chatCooldownLeft}s',
              visualDensity: VisualDensity.compact,
              onPressed: () => onOpen(_LeftPanel.chat),
              icon: state.canChat
                  ? const Icon(Icons.chat_bubble_outline)
                  : _ChatCountdown(
                      left: state.chatCooldownLeft,
                      total: GameState.chatCooldown.inSeconds,
                    ),
            ),
          ),
        ],
      ),
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
                        Text(
                          'Table ${room.code}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
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
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            ListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.paid_outlined, size: 18),
              title: Text(t.boot),
              trailing: Text(
                formatChips(room.bootAmount),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
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
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
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
  BuildContext context,
  GameState state,
  RoomState room,
) async {
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
  BuildContext context,
  GameState state,
  RoomState room,
) async {
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

  /// Where a seat sits on the felt, given its index as the server numbers it.
  ///
  /// The table is drawn from the viewer's chair, so a server index has to be
  /// rotated into view order first — the viewer is always view seat 0, at the
  /// bottom, and that one stands on the floor rather than being centred.
  static Offset _seatCentre(
    GameState state,
    int seatIndex,
    double w,
    double h,
    double podW,
  ) {
    final total = state.config.maxPlayers == 0 ? 5 : state.config.maxPlayers;
    final mine = state.room?.you?.seatIndex ?? 0;
    final view = (seatIndex - mine + total * 2) % total;

    if (view == 0) return Offset(_places[0].dx * w, h * 0.84);
    final place = _places[view % _places.length];
    return Offset(place.dx * w, place.dy * h);
  }

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
        s != null &&
        room.state == TableState.betting &&
        s.seatIndex == turnSeat;

    // Which seat took the pot, if they are still sitting there.
    int? winnerSeat;
    for (final seat in room.seats) {
      if (state.winnerId != null && seat.userId == state.winnerId) {
        winnerSeat = seat.seatIndex;
      }
    }

    // A hand is on the table until the celebration for it has finished, not
    // just until the server stops dealing — the seats keep their bets and
    // statuses through the winner's moment, and drop them with it.
    final handLive =
        room.state == TableState.betting ||
        room.state == TableState.showdown ||
        state.showdown.isNotEmpty ||
        state.showdownResult.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final h = box.maxHeight;

          // Everything on the table is a multiple of the pod width, which is
          // itself taken from the felt. The screen this runs on is short and
          // wide in logical pixels, so nothing here may be a fixed size.
          // Bounded by the felt's width as well as its height. The seats are
          // placed at fixed fractions across the felt, so on a narrower screen
          // a pod sized purely off the height grows until neighbours collide
          // and the outer ones hang over the rim.
          final podW = math
              .min(h * 0.30, w * 0.155)
              .clamp(56.0, 128.0)
              .toDouble();
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
              handLive: handLive,
              width: podW,
              avatarUrl: state.absoluteUrl(s?.avatarUrl),
              saying: s?.userId == null
                  ? null
                  : state.saidRecently[s!.userId]?.text,
              // A bubble opens towards the middle of the table: seats on the
              // left speak to the right, seats on the right to the left, and
              // the viewer's own words go up over their pod.
              bubbleSide: viewIndex == 0
                  ? BubbleSide.above
                  : viewIndex <= 2
                  ? BubbleSide.right
                  : BubbleSide.left,
              // The bottom seat stacks upwards, or its chip runs off the felt.
              reversed: viewIndex == 0,
            );
          }

          // Positioned by centre, so a seat stays put as its own column grows
          // and shrinks with the hand — but never past either edge, which is
          // what clipped the outermost seat on a narrow screen.
          Widget at(Offset place, Widget child, {double? width}) {
            final box = width ?? podW;
            final left = (place.dx * w - box / 2)
                .clamp(0.0, math.max(0.0, w - box))
                .toDouble();

            return Positioned(
              left: left,
              top: place.dy * h,
              width: box,
              child: FractionalTranslation(
                translation: const Offset(0, -0.5),
                child: child,
              ),
            );
          }

          // The same surface the lobby cards are made of, at table size: one
          // gradient, one lit edge, one shadow. The table is a stadium rather
          // than a card only because it is a table.
          // The room takes its colour from the table you sat down at, so a
          // blind table and a seen one are told apart at a glance — and the
          // room matches the lobby card you tapped to get here. A bigger stake
          // tints deeper, so the two stakes differ as well.
          final palette = AppTheme.paletteFor(
            theme.colorScheme,
            category: room.category,
            bootAmount: room.bootAmount,
          );
          final potCentre = Offset(0.5 * w, 0.30 * h);
          Offset seatCentre(int seatIndex) =>
              _seatCentre(state, seatIndex, w, h, podW);

          return PremiumSurface(
            accent: palette.accent,
            radius: h / 2,
            borderWidth: 3,
            tint: palette.tint,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Light in the table's own colour, breathing slowly behind the
                // pot, so the felt is never a flat wash.
                Positioned.fill(
                  child: IgnorePointer(
                    child: _AmbientGlow(
                      colour: palette.accent,
                      centre: const Alignment(0, -0.35),
                    ),
                  ),
                ),
                // Every bet is seen to travel: a chip leaves the seat that made
                // it and lands on the pot.
                Positioned.fill(
                  child: IgnorePointer(
                    child: _BetFlights(
                      seats: room.seats,
                      handNo: room.handNo,
                      centreOf: seatCentre,
                      pot: potCentre,
                      size: (podW * 0.22).clamp(14.0, 26.0),
                      colour: palette.accent,
                    ),
                  ),
                ),
                // The table's furniture first, the seats after it: a seat's
                // speech bubble or bet chip is a moment that matters more
                // than the tag or the pot label it might briefly cross, so
                // the seats paint on top.
                at(
                  const Offset(0.5, 0.075),
                  _CategoryTag(room: room),
                  width: w * 0.30,
                ),
                at(const Offset(0.5, 0.26), _Pot(room: room), width: w * 0.34),
                at(
                  const Offset(0.5, 0.44),
                  _Status(room: room),
                  width: w * 0.4,
                ),

                for (var i = 1; i < _places.length; i++) at(_places[i], pod(i)),

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

                // A sideshow in progress, drawn for everyone: a line pulsing
                // between the two seats, so the rest of the table can see who
                // asked whom without seeing a single card.
                if (state.sideshow != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _SideshowLink(
                        from: _seatCentre(
                          state,
                          state.sideshow!.fromSeat,
                          w,
                          h,
                          podW,
                        ),
                        to: _seatCentre(
                          state,
                          state.sideshow!.toSeat,
                          w,
                          h,
                          podW,
                        ),
                        accent: palette.accent,
                      ),
                    ),
                  ),

                // Only the player being asked gets the buttons.
                if (state.sideshowIsForMe)
                  Positioned.fill(child: _SideshowPrompt(state: state)),

                // And only the two of them ever see the hands. The winner's
                // banner wins any race between the two.
                if (state.sideshowReveal != null &&
                    state.showdown.isEmpty &&
                    state.showdownResult.isEmpty)
                  Positioned.fill(
                    child: _SideshowRevealPanel(reveal: state.sideshowReveal!),
                  ),

                if (state.showdown.isNotEmpty ||
                    state.showdownResult.isNotEmpty)
                  Positioned.fill(
                    child: _Showdown(
                      theme: theme,
                      // Fractions of the felt, so the bursts land over the
                      // player who won rather than across the whole room.
                      winnerAt: winnerSeat == null
                          ? null
                          : Offset(
                              _seatCentre(state, winnerSeat, w, h, podW).dx / w,
                              _seatCentre(state, winnerSeat, w, h, podW).dy / h,
                            ),
                      // The pot going where it was won.
                      potFlight: winnerSeat == null || state.winnerPot <= 0
                          ? null
                          : _PotToWinner(
                              key: ValueKey(
                                'pot-${room.handNo}-${state.winnerId}',
                              ),
                              from: Offset(0.5 * w, 0.26 * h),
                              to: _seatCentre(state, winnerSeat, w, h, podW),
                              size: podW * 0.28,
                            ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Which kind of table this is, said plainly on the felt.
///
/// The room already takes its colour from the category, but colour alone asks
/// a player to remember what it means. This says it — and on a blind table
/// that matters, because it is the reason they cannot see anyone's stack.
class _CategoryTag extends StatelessWidget {
  const _CategoryTag({required this.room});
  final RoomState room;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.watch<GameState>().t;
    final blind = room.category == TableCategory.blind;
    final palette = AppTheme.paletteFor(
      scheme,
      category: room.category,
      bootAmount: room.bootAmount,
    );

    return Center(
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 4, 12, 4),
        decoration: BoxDecoration(
          color: palette.container,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: palette.accent.withValues(alpha: 0.6)),
          boxShadow: AppTheme.controlShadow(theme.brightness, elevation: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(palette.icon, size: 14, color: palette.onContainer),
            const SizedBox(width: 6),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  // The category and the stake together: "BLIND · 5,000"
                  // names the table, and the colour behind it is the table's
                  // own. It shrinks on a small screen rather than losing its
                  // stake to an ellipsis.
                  '${blind ? t.blind : t.seen} · ${formatChips(room.bootAmount)}',
                  maxLines: 1,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.2,
                    color: palette.onContainer,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How many turns this player has let run out, and what happens if they let
/// one more go.
///
/// Missing a turn is not obviously a countable thing while it is happening —
/// the hand simply carries on without you — so the count is stated, and the
/// last one is stated loudly. It is shown to nobody else: the server sends the
/// figure only to the player it concerns.
/// Requirement 31, kept where the thumb already is: the count of turns
/// auto-packed in a row sits over the Pack button, bottom left, and stays put
/// at zero too, so the player can always see how the table is scoring them.
///
/// It takes no height of its own — it is drawn upward over the bottom-left
/// corner of the felt, which nothing else uses — so the buttons never shift
/// under a hand as the count changes.
class _MissedTurnsStrip extends StatelessWidget {
  const _MissedTurnsStrip();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final room = state.room;
    final you = room?.you;
    if (room == null || you == null) return const SizedBox.shrink();

    // Blind moves are only a live question while the player is still blind
    // and still in the hand; once they look, the pill goes and the missed
    // count settles back onto the bar.
    final showBlind =
        you.isBlind &&
        you.status == SeatState.active &&
        room.state == TableState.betting;
    final maxBlind =
        state.config.tables
            .where(
              (t) =>
                  t.category == room.category &&
                  t.bootAmount == room.bootAmount,
            )
            .map((t) => t.maxBlindMoves)
            .firstOrNull ??
        4;

    // The corner the pills live in is only as wide as the gap between the
    // Pack button's left edge and the viewer's pod. On a small phone that is
    // not much, so the pills tighten — one line, no explanation — and are
    // capped at about a quarter of the screen, so they never run under the pod.
    final size = MediaQuery.sizeOf(context);
    final inset = MediaQuery.paddingOf(context);
    final screenW = size.width;
    final compact = screenW < 760;
    // The cap is worked out from the same geometry the felt lays the viewer's
    // pod out with — rail 46, felt padding 12 each side, the pod centred at
    // 0.335 of the felt, pod width from the felt's height and width — so the
    // pills stop a little short of the pod on every screen, camera cutout and
    // all, rather than trusting a share of the screen width.
    final feltW = screenW - inset.horizontal - 46 - 24;
    final feltH = size.height - inset.vertical - 64;
    final podW = math.min(feltH * 0.30, feltW * 0.155).clamp(56.0, 128.0);
    final podLeft = 46 + 12 + 0.335 * feltW - podW / 2;
    // 20 dp of clear felt between the pill's edge and the pod, shadows included.
    final maxW = (podLeft - 16 - 20).clamp(120.0, 360.0);

    return SizedBox(
      height: 0,
      width: double.infinity,
      child: OverflowBox(
        alignment: Alignment.bottomLeft,
        minHeight: 0,
        maxHeight: 120,
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 4),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showBlind) ...[
                    _BlindMovesPill(
                      left: you.blindMovesLeft,
                      max: maxBlind,
                      compact: compact,
                    ),
                    SizedBox(height: compact ? 4 : 6),
                  ],
                  _MissedTurns(you: you, compact: compact),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How many bets this player may still make without looking at their cards.
/// The same figure sits under the "See cards" button; here it stays in the
/// corner the player already watches for their missed-turn count.
class _BlindMovesPill extends StatelessWidget {
  const _BlindMovesPill({
    required this.left,
    required this.max,
    this.compact = false,
  });

  final int left;
  final int max;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.watch<GameState>().t;
    // The last blind move is worth a warmer colour: the next bet after it
    // turns the cards face up whether the player looked or not.
    final lastOne = left <= 1;

    return Container(
      padding: compact
          ? const EdgeInsets.fromLTRB(8, 3, 10, 3)
          : const EdgeInsets.fromLTRB(10, 5, 12, 5),
      decoration: BoxDecoration(
        color: lastOne
            ? scheme.tertiaryContainer.withValues(alpha: 0.96)
            : scheme.surfaceContainerHigh.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: lastOne
              ? scheme.tertiary.withValues(alpha: 0.7)
              : scheme.outlineVariant,
        ),
        boxShadow: AppTheme.controlShadow(theme.brightness),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.visibility_off_outlined,
            size: 16,
            color: lastOne
                ? scheme.onTertiaryContainer
                : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 7),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${t.blindMovesLabel} $left/$max',
                maxLines: 1,
                style: (compact
                        ? theme.textTheme.labelMedium
                        : theme.textTheme.labelLarge)
                    ?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: lastOne
                      ? scheme.onTertiaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MissedTurns extends StatefulWidget {
  const _MissedTurns({required this.you, this.compact = false});
  final You you;

  /// One line only, for a screen with no room for the explanation.
  final bool compact;

  @override
  State<_MissedTurns> createState() => _MissedTurnsState();
}

class _MissedTurnsState extends State<_MissedTurns>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.watch<GameState>().t;

    final missed = widget.you.missedTurns;
    final limit = widget.you.maxMissedTurns;
    final last = widget.you.onLastWarning;
    // Anything above zero is a mark against the seat; the pill warms up with
    // the count and turns red for the final warning.
    final marked = missed > 0 && !last;

    final foreground = last
        ? scheme.onErrorContainer
        : marked
        ? scheme.onTertiaryContainer
        : scheme.onSurfaceVariant;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) => Opacity(
        // Only the final warning breathes. Below that it is information, and
        // information that pulses is just noise.
        opacity: last ? 0.72 + 0.28 * _pulse.value : 1,
        child: child,
      ),
      child: Container(
        padding: widget.compact
            ? const EdgeInsets.fromLTRB(8, 3, 10, 3)
            : EdgeInsets.fromLTRB(10, last ? 7 : 5, 12, last ? 7 : 5),
        decoration: BoxDecoration(
          color: last
              ? scheme.errorContainer
              : marked
              ? scheme.tertiaryContainer.withValues(alpha: 0.94)
              : scheme.surfaceContainerHigh.withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: last
                ? scheme.error
                : marked
                ? scheme.tertiary.withValues(alpha: 0.6)
                : scheme.outlineVariant,
            width: last ? 2 : 1,
          ),
          boxShadow: AppTheme.controlShadow(theme.brightness),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              last ? Icons.warning_amber_rounded : Icons.timer_off_outlined,
              size: last ? 20 : 16,
              color: foreground,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      // "Missed turns 1/3" — the count is the whole point, so
                      // it is always there, even at 0/3.
                      '${last ? t.lastWarning : t.missedTurnsLabel} $missed/$limit',
                      maxLines: 1,
                      style: (widget.compact
                              ? theme.textTheme.labelMedium
                              : theme.textTheme.labelLarge)
                          ?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: foreground,
                      ),
                    ),
                  ),
                  if (last && !widget.compact)
                    Text(
                      t.missOneMore,
                      // Two lines when the corner is narrow, rather than an
                      // explanation cut off mid-sentence.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: foreground,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The pot travelling to whoever won it.
///
/// A row of chips leaves the middle of the table and lands on the winner's
/// seat, one after another. It runs once — the pot moves once — and the arc
/// carries them wide of the straight line, so a handful of chips reads as a
/// pile being pushed across rather than a swarm.
class _PotToWinner extends StatefulWidget {
  const _PotToWinner({
    super.key,
    required this.from,
    required this.to,
    required this.size,
  });

  final Offset from;
  final Offset to;
  final double size;

  @override
  State<_PotToWinner> createState() => _PotToWinnerState();
}

class _PotToWinnerState extends State<_PotToWinner>
    with SingleTickerProviderStateMixin {
  static const int _chips = 9;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = [scheme.primary, AppTheme.gold, scheme.tertiary];

    // The bow in the flight path, at right angles to it.
    final line = widget.to - widget.from;
    final normal =
        Offset(-line.dy, line.dx) / (line.distance == 0 ? 1 : line.distance);

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(
          children: [
            for (var i = 0; i < _chips; i++) ..._chip(i, normal, palette),
          ],
        ),
      ),
    );
  }

  List<Widget> _chip(int i, Offset normal, List<Color> palette) {
    // Each chip leaves a moment after the one before it.
    final start = i / (_chips * 1.6);
    final local = ((_c.value - start) / (1 - start)).clamp(0.0, 1.0);
    if (local <= 0) return const [];

    final eased = Curves.easeInOutCubic.transform(local);
    // Alternating sides, so the chips fan out instead of following one another.
    final bow = (i.isEven ? 1 : -1) * widget.size * (1.4 + i * 0.25);
    // Zero at both ends, widest in the middle: the arc, not a drift.
    final arc = math.sin(eased * math.pi) * bow;

    final at = Offset.lerp(widget.from, widget.to, eased)! + normal * arc;

    return [
      Positioned(
        left: at.dx - widget.size / 2,
        top: at.dy - widget.size / 2,
        child: Opacity(
          // Fades out as it lands, so the chips are absorbed by the seat
          // rather than piling up on top of it.
          opacity: (1 - math.max(0.0, (eased - 0.82) / 0.18))
              .clamp(0.0, 1.0)
              .toDouble(),
          child: Transform.rotate(
            angle: eased * math.pi * (i.isEven ? 2 : -2),
            child: PokerChip(
              colour: palette[i % palette.length],
              size: widget.size,
            ),
          ),
        ),
      ),
    ];
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
        Text(
          state.t.pot,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 2,
          ),
        ),
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
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
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
      TableState.waiting => '${state.t.waitingForPlayers} (${room.minPlayers})',
      TableState.starting => state.t.startingGame,
      _ =>
        state.myTurn
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

    final packed =
        you.status == SeatState.packed || you.status == SeatState.lost;
    // A packed hand stays on the table, face down and struck out, so the player
    // can see what they folded rather than having it vanish.
    if (you.status != SeatState.active && !packed) {
      return const SizedBox.shrink();
    }

    final cards = you.cards;

    // Looking is allowed at any point, not only on your own turn: it costs
    // nothing and changes nothing for anyone else. Betting still waits for the
    // turn, which the action bar handles.
    final stillBlind = you.isBlind && !packed;

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
        position: Tween(
          begin: const Offset(-0.5, -0.9),
          end: Offset.zero,
        ).animate(curved),
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
  const _Showdown({required this.theme, this.winnerAt, this.potFlight});
  final ThemeData theme;

  /// Where the winner is sitting, as a fraction of the felt. Null when they
  /// have already left, in which case the fireworks go up over the table.
  final Offset? winnerAt;

  /// The chips crossing the table to them, drawn over the wash but under the
  /// headline — chips passing across the words would only make them harder to
  /// read, and the words are the point.
  final Widget? potFlight;

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
          child: Fireworks(
            seed: state.room?.handNo ?? 0,
            bursts: won ? 8 : 5,
            focus: winnerAt,
          ),
        ),
        if (potFlight != null) Positioned.fill(child: potFlight!),
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
              color: (won ? scheme.primary : Colors.black).withValues(
                alpha: won ? 0.45 : 0.25,
              ),
              blurRadius: 26,
              spreadRadius: 2,
            ),
          ],
        ),
        // Scaled as one piece: a pot in crores must never push the trophy or
        // the name out of the card, or the card off the felt.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (won) ...[
                Icon(
                  Icons.emoji_events,
                  color: scheme.onPrimaryContainer,
                  size: 26,
                ),
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

// --------------------------------------------------------------- sideshow

/// The line between the two seats in a sideshow, for everybody at the table.
///
/// This is the only part of a sideshow the rest of the room sees: who asked
/// whom, and that it is still open. No cards, no result, nothing that would
/// tell a bystander anything about either hand.
class _SideshowLink extends StatefulWidget {
  const _SideshowLink({
    required this.from,
    required this.to,
    required this.accent,
  });

  final Offset from;
  final Offset to;
  final Color accent;

  @override
  State<_SideshowLink> createState() => _SideshowLinkState();
}

class _SideshowLinkState extends State<_SideshowLink>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => CustomPaint(
        painter: _SideshowLinkPainter(
          from: widget.from,
          to: widget.to,
          accent: widget.accent,
          t: _pulse.value,
        ),
      ),
    );
  }
}

class _SideshowLinkPainter extends CustomPainter {
  _SideshowLinkPainter({
    required this.from,
    required this.to,
    required this.accent,
    required this.t,
  });

  final Offset from;
  final Offset to;
  final Color accent;

  /// 0 to 1, once per pulse.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    // A curve rather than a straight line: seats sit round a rim, and a chord
    // across the middle would cut through the pot.
    final mid = Offset((from.dx + to.dx) / 2, (from.dy + to.dy) / 2);
    final lift = (to - from).distance * 0.18;
    final control = Offset(mid.dx, mid.dy - lift);

    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(control.dx, control.dy, to.dx, to.dy);

    canvas.drawPath(
      path,
      Paint()
        ..color = accent.withValues(alpha: 0.30)
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke,
    );

    // A bead running from the player who asked to the player being asked, so
    // the direction of the request is readable at a glance.
    final metric = path.computeMetrics().first;
    final head = metric.getTangentForOffset(metric.length * t)?.position;
    if (head != null) {
      canvas.drawCircle(
        head,
        7,
        Paint()..color = accent.withValues(alpha: 0.95),
      );
      canvas.drawCircle(
        head,
        13,
        Paint()..color = accent.withValues(alpha: 0.22 * (1 - t)),
      );
    }

    // A ring opening out of the seat being asked, which is where the answer
    // has to come from.
    canvas.drawCircle(
      to,
      18 + 22 * t,
      Paint()
        ..color = accent.withValues(alpha: 0.35 * (1 - t))
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_SideshowLinkPainter old) =>
      old.t != t || old.from != from || old.to != to || old.accent != accent;
}

/// The accept-or-decline prompt, shown only to the player who was asked.
///
/// The six seconds are the server's: it drops the request on its own clock
/// whatever this does, so the bar here is a readout and the buttons simply
/// beat it to the answer.
class _SideshowPrompt extends StatelessWidget {
  const _SideshowPrompt({required this.state});
  final GameState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = state.sideshow;
    if (pending == null) return const SizedBox.shrink();

    String askerName = '';
    for (final seat in state.room?.seats ?? const <Seat>[]) {
      if (seat.userId == pending.fromUserId) askerName = seat.displayName;
    }
    return Center(
      child: PremiumSurface(
        accent: theme.colorScheme.secondary,
        radius: 22,
        borderWidth: 2,
        tint: 0.34,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                state.t.sideshowRunning.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 2,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '$askerName ${state.t.sideshowAsksYou}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              _SideshowCountdown(
                expiresAt: pending.expiresAt,
                totalMs: state.config.sideshowTimeoutMs,
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.tonal(
                    onPressed: () => state.answerSideshow(false),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(118, 44),
                      backgroundColor: theme.colorScheme.errorContainer,
                      foregroundColor: theme.colorScheme.onErrorContainer,
                    ),
                    child: Text(state.t.decline),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: () => state.answerSideshow(true),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(118, 44),
                    ),
                    child: Text(state.t.accept),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bar draining under a sideshow request.
///
/// It reads the wall clock once per frame rather than taking a level from the
/// game state, which only republishes about once a second — a bar stepping in
/// whole seconds is what makes a countdown look like it is stuttering. There
/// is no number over it: six seconds is short enough that a shortening bar
/// says everything a digit would, and reads faster.
class _SideshowCountdown extends StatefulWidget {
  const _SideshowCountdown({required this.expiresAt, required this.totalMs});

  /// When the server drops the request, in epoch milliseconds, and the window
  /// it allowed. The expiry is the server's; this only draws it.
  final int expiresAt;
  final int totalMs;

  @override
  State<_SideshowCountdown> createState() => _SideshowCountdownState();
}

class _SideshowCountdownState extends State<_SideshowCountdown>
    with SingleTickerProviderStateMixin {
  /// Repeats rather than runs once, so the bar keeps redrawing whatever the
  /// deadline is; the fraction below is what actually ends it.
  late final AnimationController _frames = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  /// How much of the window is left, right now.
  double _remaining() {
    if (widget.totalMs <= 0) return 0;

    final left = widget.expiresAt - DateTime.now().millisecondsSinceEpoch;
    return (left / widget.totalMs).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _frames.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _frames,
        builder: (context, _) {
          final left = _remaining();

          // The colour carries the urgency the missing number used to: it
          // slides from the table's own accent towards the error red as the
          // last third runs out.
          final colour = Color.lerp(
            theme.colorScheme.error,
            theme.colorScheme.secondary,
            (left * 3).clamp(0.0, 1.0),
          )!;

          return SizedBox(
            width: 260,
            height: 8,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.18,
                      ),
                    ),
                  ),
                  // heightFactor as well as widthFactor: the bar has no
                  // child to give it a height, so without it the fill
                  // collapses to nothing and only the track shows. Aligned
                  // left, or it would drain towards its own middle.
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: left,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [colour.withValues(alpha: 0.75), colour],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The two compared hands. The server sends these to the two players in the
/// sideshow and to nobody else, so this widget is only ever built for them.
class _SideshowRevealPanel extends StatelessWidget {
  const _SideshowRevealPanel({required this.reveal});
  final SideshowReveal reveal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<GameState>();
    final me = state.user?.id;

    final iPacked = reveal.packedUserId != null && reveal.packedUserId == me;

    return IgnorePointer(
      child: ColoredBox(
        color: theme.colorScheme.scrim.withValues(alpha: 0.45),
        child: Center(
          child: PremiumSurface(
            accent: theme.colorScheme.secondary,
            radius: 22,
            borderWidth: 2,
            tint: 0.34,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    state.t.sideshowRunning.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(
                      letterSpacing: 2,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final hand in reveal.hands) ...[
                        _SideshowHandCard(
                          hand: hand,
                          packed: hand.userId == reveal.packedUserId,
                          isMe: hand.userId == me,
                        ),
                        if (hand != reveal.hands.last)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Text(
                              'v',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    iPacked ? state.t.sideshowYouLost : state.t.sideshowYouWon,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: iPacked
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
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

class _SideshowHandCard extends StatelessWidget {
  const _SideshowHandCard({
    required this.hand,
    required this.packed,
    required this.isMe,
  });

  final SideshowHand hand;
  final bool packed;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(16),
        border: packed
            ? null
            : Border.all(color: theme.colorScheme.primary, width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isMe ? '${hand.displayName} *' : hand.displayName,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: packed ? theme.colorScheme.onSurfaceVariant : null,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in hand.cards)
                PlayingCard(height: 62, code: c, dimmed: packed),
            ],
          ),
          const SizedBox(height: 3),
          Text(hand.handName, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// The lift on an icon button that has a background of its own.
///
/// The button themes cover the labelled buttons; icon buttons are left out of
/// those on purpose, because most of the ones here — the menu, the chat, the
/// close on a sheet — are transparent, and a shadow under nothing visible is
/// just a smudge. This is applied to the three that are filled.
ButtonStyle _stepperStyle(ThemeData theme) =>
    AppTheme.raisedIcon(theme.brightness);

/// Pack on the left, the stake stepper in the middle, then Chaal and one more
/// button on the right.
///
/// The bar is always there and simply goes dead between turns: one that
/// disappears and comes back moves the buttons under the player's thumb, which
/// is how misclicks happen.
///
/// That last slot is Sideshow, and becomes Show once only two players are left
/// in the hand — the two can never be offered at once, because a sideshow
/// needs a third player and a show needs there not to be one.
/// One control in the action bar: an icon, what it does, and what it costs.
///
/// They share a shape so the bar reads as one set of keys rather than four
/// buttons that happen to sit together — and the icon is what a player finds
/// under their thumb without reading, which matters on a clock.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.width,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.amount,
    this.filled = false,
    this.background,
    this.foreground,
  });

  final double width;
  final IconData icon;
  final String label;

  /// The second line: what the move costs, or who it is aimed at. Omitted
  /// leaves the label centred on its own.
  final String? amount;
  final VoidCallback? onPressed;

  /// The primary action of the bar, in the scheme's own colour.
  final bool filled;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final style = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(46),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      backgroundColor: background,
      foregroundColor: foreground,
      disabledBackgroundColor: theme.colorScheme.surfaceContainerHighest,
      disabledForegroundColor: theme.colorScheme.onSurfaceVariant.withValues(
        alpha: 0.5,
      ),
    );

    final content = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 7),
        Flexible(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (amount != null)
                // A crore-sized bet is a long word; it shrinks to fit rather
                // than losing its tail to an ellipsis.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    amount!,
                    maxLines: 1,
                    style: const TextStyle(fontSize: 12, height: 1.15),
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    return SizedBox(
      width: width,
      child: filled
          ? FilledButton(onPressed: onPressed, style: style, child: content)
          : FilledButton.tonal(
              onPressed: onPressed,
              style: style,
              child: content,
            ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final live = state.myTurn;
    final options = state.options;
    final showCost = options?.show;
    final theme = Theme.of(context);

    final canSideshow = live && (options?.canSideshow ?? false);
    // Heads-up: a show is on offer, and a sideshow cannot be.
    final headsUp = live && showCost != null && showCost > 0;

    // The bar has a natural width; on a narrow screen the whole row is scaled
    // down rather than any one button being dropped or overflowing.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: LayoutBuilder(
        builder: (context, box) => FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: math.max(box.maxWidth, 760),
            child: Row(
              children: [
                _ActionButton(
                  width: 128,
                  icon: Icons.close_rounded,
                  label: state.t.pack,
                  onPressed: live && (options?.canPack ?? false)
                      ? state.pack
                      : null,
                  background: theme.colorScheme.errorContainer,
                  foreground: theme.colorScheme.onErrorContainer,
                ),
                const Spacer(),
                IconButton.filledTonal(
                  onPressed: state.canStepDown ? () => state.stepBet(-1) : null,
                  iconSize: 26,
                  style: _stepperStyle(theme),
                  icon: const Icon(Icons.remove),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 148,
                  height: 46,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    // A shade of depth across the pill, so it reads as a machined
                    // window between the two keys rather than a flat patch.
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        theme.colorScheme.surfaceContainerHighest,
                        theme.colorScheme.surfaceContainerHigh,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(23),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.55,
                      ),
                    ),
                    boxShadow: AppTheme.controlShadow(theme.brightness),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // A real chip rather than an icon of one: it is the same
                      // artwork the pot and the seats are counted in.
                      PokerChip(
                        colour: live
                            ? theme.colorScheme.secondary
                            : theme.colorScheme.outline,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
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
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                IconButton.filledTonal(
                  onPressed: state.canStepUp ? () => state.stepBet(1) : null,
                  iconSize: 26,
                  style: _stepperStyle(theme),
                  icon: const Icon(Icons.add),
                ),
                const Spacer(),
                _ActionButton(
                  width: 136,
                  icon: Icons.arrow_forward_rounded,
                  label: state.t.chaal,
                  amount: formatChips(state.betAmount),
                  onPressed: live ? state.bet : null,
                  filled: true,
                ),
                const SizedBox(width: 10),
                // One slot, two jobs. A show is only possible with two players left
                // and a sideshow only with three or more, so the button turns into
                // Show at exactly the point Sideshow stops being askable — and the
                // two are never on screen together.
                headsUp
                    ? _ActionButton(
                        width: 132,
                        icon: Icons.visibility_rounded,
                        label: state.t.show,
                        amount: formatChips(showCost),
                        onPressed: () => state.show(showCost),
                        background: theme.colorScheme.tertiaryContainer,
                        foreground: theme.colorScheme.onTertiaryContainer,
                      )
                    // Dead by default: it wakes up only on your turn, with three
                    // players in the hand and both you and the player on your right
                    // holding seen cards. All of that is the server's judgement,
                    // arriving as canSideshow.
                    : _ActionButton(
                        width: 132,
                        icon: Icons.compare_arrows_rounded,
                        label: state.t.sideshow,
                        amount: canSideshow ? options?.sideshowWith : null,
                        onPressed: canSideshow ? state.askSideshow : null,
                        background: theme.colorScheme.secondaryContainer,
                        foreground: theme.colorScheme.onSecondaryContainer,
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Requirement 8: room chat. It lives only in memory on the server and goes
/// when the room does.
class _ChatDrawer extends StatefulWidget {
  const _ChatDrawer();

  @override
  State<_ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<_ChatDrawer> {
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

    return Drawer(
      width: 340,
      child: SafeArea(
        child: Padding(
          // The composer sits at the bottom of a full-height panel, so it has
          // to ride above the keyboard rather than behind it.
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        state.t.tableChat,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
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
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
                      tooltip: state.canChat
                          ? null
                          : '${state.chatCooldownLeft}s',
                      onPressed: state.canChat ? () => _send(state) : null,
                      style: _stepperStyle(Theme.of(context)),
                      icon: state.canChat
                          ? const Icon(Icons.send)
                          : _ChatCountdown(
                              left: state.chatCooldownLeft,
                              total: GameState.chatCooldown.inSeconds,
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _send(GameState state) {
    if (!state.sendChat(_input.text)) return;
    _input.clear();
    // Said: the keyboard and the drawer go together, and what the player sees
    // next is the table with their words over their own seat.
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop();
  }
}

/// The seconds until the next message may be sent, drawn as a number inside a
/// ring that empties as the wait runs down.
class _ChatCountdown extends StatelessWidget {
  const _ChatCountdown({required this.left, required this.total});

  final int left;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 24,
      height: 24,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: total == 0 ? 0 : (left / total).clamp(0.0, 1.0),
            strokeWidth: 2.4,
            color: scheme.primary,
            backgroundColor: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
          Text(
            '$left',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// A soft pool of the table's colour, brightening and dimming on a slow cycle.
class _AmbientGlow extends StatefulWidget {
  const _AmbientGlow({required this.colour, required this.centre});

  final Color colour;
  final Alignment centre;

  @override
  State<_AmbientGlow> createState() => _AmbientGlowState();
}

class _AmbientGlowState extends State<_AmbientGlow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _breath,
      builder: (context, _) {
        final v = Curves.easeInOut.transform(_breath.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: widget.centre,
              radius: 0.55 + 0.08 * v,
              colors: [
                widget.colour.withValues(
                  alpha: (dark ? 0.16 : 0.12) + 0.08 * v,
                ),
                widget.colour.withValues(alpha: 0),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Chips in flight from a seat to the pot, one for every bet as it happens.
///
/// Watches each seat's running total; when it rises, a chip sets off from that
/// seat and lands on the pot. A new hand resets the totals, so the boot
/// everyone posts at the deal flies in too. Nothing is sent for the snapshot a
/// player arrives to — those bets were made before they sat down.
class _BetFlights extends StatefulWidget {
  const _BetFlights({
    required this.seats,
    required this.handNo,
    required this.centreOf,
    required this.pot,
    required this.size,
    required this.colour,
  });

  final List<Seat> seats;
  final int handNo;
  final Offset Function(int seatIndex) centreOf;
  final Offset pot;
  final double size;
  final Color colour;

  @override
  State<_BetFlights> createState() => _BetFlightsState();
}

class _Flight {
  _Flight({required this.from, required this.startedAt, required this.delay});
  final Offset from;
  final Duration startedAt;
  final Duration delay;
}

class _BetFlightsState extends State<_BetFlights>
    with SingleTickerProviderStateMixin {
  static const _travel = Duration(milliseconds: 620);

  late final Ticker _ticker;
  Duration _now = Duration.zero;
  final Map<int, int> _seen = {};
  int _handNo = -1;
  final List<_Flight> _flights = [];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _now = elapsed;
      _flights.removeWhere((f) => elapsed - f.startedAt - f.delay > _travel);
      if (_flights.isEmpty) _ticker.stop();
      setState(() {});
    });
    // The state we arrive to is the baseline, not a set of bets to animate.
    _handNo = widget.handNo;
    for (final seat in widget.seats) {
      _seen[seat.seatIndex] = seat.contributed;
    }
  }

  @override
  void didUpdateWidget(covariant _BetFlights old) {
    super.didUpdateWidget(old);
    final newHand = widget.handNo != _handNo;
    if (newHand) {
      _handNo = widget.handNo;
      _seen.clear();
    }
    var launched = 0;
    for (final seat in widget.seats) {
      final before = _seen[seat.seatIndex] ?? 0;
      if (seat.occupied && seat.contributed > before) {
        _flights.add(
          _Flight(
            from: widget.centreOf(seat.seatIndex),
            startedAt: _now,
            // At the deal every seat posts at once; a short stagger keeps the
            // chips from arriving as one lump.
            delay: Duration(milliseconds: 70 * launched),
          ),
        );
        launched += 1;
      }
      _seen[seat.seatIndex] = seat.contributed;
    }
    if (_flights.isNotEmpty && !_ticker.isActive) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_flights.isEmpty) return const SizedBox.expand();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final f in _flights)
          () {
            final elapsed = _now - f.startedAt - f.delay;
            if (elapsed.isNegative) return const SizedBox.shrink();
            final t = (elapsed.inMicroseconds / _travel.inMicroseconds).clamp(
              0.0,
              1.0,
            );
            final eased = Curves.easeInOutCubic.transform(t);
            // A shallow arc, so the chip is tossed rather than slid.
            final lift = math.sin(t * math.pi) * widget.size * 1.6;
            final pos =
                Offset.lerp(f.from, widget.pot, eased)! - Offset(0, lift);
            final fade = t > 0.82 ? (1 - t) / 0.18 : 1.0;
            return Positioned(
              left: pos.dx - widget.size / 2,
              top: pos.dy - widget.size / 2,
              child: Opacity(
                opacity: fade.clamp(0.0, 1.0),
                child: Transform.rotate(
                  angle: t * math.pi * 1.5,
                  child: PokerChip(colour: widget.colour, size: widget.size),
                ),
              ),
            );
          }(),
      ],
    );
  }
}
