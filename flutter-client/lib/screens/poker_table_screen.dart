import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import '../widgets/buy_chips.dart';
import '../widgets/deal_flight.dart';
import '../widgets/drifting_chips.dart';
import '../widgets/playing_card.dart';
import '../widgets/poker_chip.dart';
import '../widgets/pot_flight.dart';
import '../widgets/rules_sheet.dart';
import '../widgets/seat_pod.dart';
import '../widgets/table_chrome.dart';
import '../widgets/variation_prompt.dart';

/// The poker room (go-server/internal/poker): Texas Hold'em, Omaha, 5-Card
/// Draw and 3-Card Poker on the same felt, in the same chrome, as the Teen
/// Patti table — the room's ground, the rail, the two drawers, the wallet and
/// the machined keys are the shared ones in `widgets/table_chrome.dart`. What
/// differs is on the cloth: a board of community cards (or the dealer's hand,
/// on 3-Card Poker) over the pot, side pots beside the main one, a street tag
/// where the category tag is, the viewer's hole cards fanned on the floor —
/// tappable on the draw street — and a poker console: Fold in the bottom-left
/// corner where Pack stands, for the same reason (a fold must never land
/// under a thumb reaching for a bet), and Check / Call, All-in and the bet
/// stepper in the bottom-right.
///
/// **Everything is drawn from the snapshot** (`room:state.poker`, `you`,
/// `seats`), never from a copy: a reconnect mid-hand rebuilds the deal, the
/// street, the turn, the keys and — through `poker.result`, which the server
/// keeps until the next deal — a finished hand and its winners. The
/// `poker:showdown` / `poker:handEnded` events only start the celebration a
/// moment sooner and say when the next deal is due (GameState).
///
/// [TableScreen] mounts this in place of its own body when the room is a
/// poker one; both use `GameState.tableScaffold`, and only one is ever
/// mounted.
class PokerTableScreen extends StatefulWidget {
  const PokerTableScreen({super.key});

  @override
  State<PokerTableScreen> createState() => _PokerTableScreenState();
}

class _PokerTableScreenState extends State<PokerTableScreen> {
  /// The menu and the chat share the one drawer, as on the Teen Patti table:
  /// which one is showing is decided as it opens, and it is the menu at rest.
  LeftPanel _panel = LeftPanel.menu;

  GlobalKey<ScaffoldState> get _scaffold =>
      context.read<GameState>().tableScaffold;

  void _open(LeftPanel panel) {
    if (panel == LeftPanel.chat) context.read<GameState>().markChatRead();
    setState(() => _panel = panel);
    _scaffold.currentState?.openDrawer();
  }

  /// The rulebook key in the rail (owner, 19 Sep 2026). It opens the sheet
  /// scoped to THIS room — only this game's rules and only its ranking, never
  /// the other three or Teen Patti's — by handing `showRules` the menu entry
  /// the room would have had ([LobbyTable.ofRoom]). Nothing happens at a table
  /// whose snapshot has not arrived yet.
  void _openRules() {
    final room = context.read<GameState>().room;
    final table = room == null ? null : LobbyTable.ofRoom(room);
    if (table == null) return;
    showRules(context, table: table);
  }

  /// Puts the menu back behind the edge once the drawer has finished closing
  /// (see the Teen Patti table's `_drawerGone`).
  void _drawerGone() {
    if (_panel == LeftPanel.menu) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _panel = LeftPanel.menu);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Watches nothing itself: GameState notifies once a second, and a Scaffold
    // rebuild tears an open drawer down. Everything inside subscribes for
    // itself.
    return Scaffold(
      key: _scaffold,
      resizeToAvoidBottomInset: false,
      // The room the Teen Patti felt stands in, dimmed the same way.
      drawerScrimColor: TableScrim.drawer,
      drawer: DrawerSlot(
        onGone: _drawerGone,
        child: switch (_panel) {
          LeftPanel.menu => const TableDrawer(),
          LeftPanel.chat => const ChatDrawer(),
        },
      ),
      body: Stack(
        children: [
          const Positioned.fill(child: RoomGround()),
          const TurnBuzzer(),
          const Positioned.fill(
            child: IgnorePointer(
              child: DriftingChips(strength: TableAmbient.roomChips),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      SideRail(onOpen: _open, onRules: _openRules),
                      const Expanded(child: _PokerFelt()),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // The room's two top corners, as the Teen Patti table keeps them.
          const TopCorner(left: true, child: ShopButton()),
          const TopCorner(left: false, child: TableWallet()),
          // Check / Call and All-in over the bet stepper, in the corner the
          // Teen Patti keys are pressed in, and exactly as wide: the viewer's
          // fanned hand — five cards, on 5-Card Draw — is laid out to clear
          // that width.
          const Positioned(
            right: 0,
            bottom: 0,
            child: SafeArea(child: WhileOnline(child: _PokerKeys())),
          ),
          // Fold, alone in the opposite corner, where Pack is: the one key
          // that must never sit under a thumb reaching for a bet.
          const Positioned(
            left: 0,
            bottom: 0,
            child: SafeArea(child: WhileOnline(child: _FoldKey())),
          ),
          const Positioned.fill(child: SafeArea(child: Reconnecting())),
        ],
      ),
    );
  }
}

/// The cloth: the five seats in the Teen Patti felt's places, the board or
/// the dealer's hand over the pot, the pots, the street tag, the status line
/// and the viewer's own hand.
class _PokerFelt extends StatelessWidget {
  const _PokerFelt();

  /// The middle of the pot, as a fraction of the felt's height — the Teen
  /// Patti felt's own figure, so the pot is where players expect it.
  static const double _potDy = 0.46;

  /// The board (or the dealer's hand) sits between the two top seats, where
  /// the waiting line stands when no hand is running.
  static const double _boardDy = 0.29;

  /// The waiting / starting line when the felt is empty: between the two top
  /// seats, where the board would be.
  static const double _statusDy = 0.28;

  /// The same line while a hand is on the table — "Choose up to 3 cards to
  /// exchange", "Play or fold?", "Starting game…" over a finished hand — in
  /// the one pocket of open felt a live hand leaves: right of the pot, under
  /// the top-right seat's column and above the key cluster, short of the
  /// right seat's column. It used to sit under the pot in the middle, which
  /// is where the viewer's own hand name and bet stand (Pixel 6, 19 Sep
  /// 2026). Two lines at most, scaled to the pocket (`_promptW`) — measured
  /// at `_promptWrap` times that width first, so "Choose up to 3 cards to
  /// exchange" breaks in two and is brought down once instead of being
  /// squashed onto a single line a pocket wide.
  static const double _promptDx = 0.74;
  static const double _promptDy = 0.615;
  static const double _promptW = 0.195;
  static const double _promptWrap = 1.9;

  /// Where the dealer's hand (3-Card Poker) ends: its FOOT, above the pot's
  /// plinth. Anchored there rather than by its middle because the reveal adds
  /// a line under its cards, and a column anchored by its middle grew down
  /// across the plinth's top edge (Pixel 6, 19 Sep 2026).
  static const double _dealerFootDy = 0.375;

  /// The street tag's line, the category tag's on the Teen Patti felt.
  static const double _tagDy = 0.075;

  /// Where a seat sits on the felt, given its index as the server numbers it,
  /// rotated into view order round the viewer at the bottom.
  static Offset _seatCentre(
    GameState state,
    int seatIndex,
    double w,
    double h,
  ) {
    final total = state.config.maxPlayers == 0 ? 5 : state.config.maxPlayers;
    final mine = state.room?.you?.seatIndex ?? 0;
    final view = (seatIndex - mine + total * 2) % total;
    if (view == 0) return Offset(seatPlaces[0].dx * w, h * 0.84);
    final place = seatPlaces[view % seatPlaces.length];
    return Offset(place.dx * w, place.dy * h);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final room = state.room;
    final poker = room?.poker;
    if (room == null || poker == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final t = state.t;
    final seats = state.seatsInViewOrder();
    // The finished hand, until the next deal takes its place. The SNAPSHOT is
    // what says a hand is over — the server keeps `poker.result` from the
    // settle until the next `startHand` clears it (internal/poker/hand.go
    // `t.lastResult`), and after the settle it is the ONLY record of the
    // reveals and of 3-Card Poker's dealer. The celebration's own clock runs
    // to the deal the server *scheduled*, so keying the reveals on it took
    // every turned-over hand off the felt a beat early. [GameState.pokerResult]
    // prefers the event's copy, which arrives a moment sooner.
    final result = state.pokerResult;
    final turnSeat = room.turn?.seatIndex;
    final progress = state.turnProgress;
    final pad = Dim.feltPad(MediaQuery.sizeOf(context).width);

    bool onTurn(Seat? s) =>
        s != null &&
        room.state == TableState.betting &&
        s.seatIndex == turnSeat;

    // A hand is on the table until the next deal replaces it: the seats keep
    // their bets and their cards through the winner's moment and for as long
    // as the finished hand is on show.
    final handLive =
        room.state == TableState.betting ||
        room.state == TableState.showdown ||
        result != null;
    final board = result != null && result.community.isNotEmpty
        ? result.community
        : poker.community;
    final dealer = PokerDealer.shown(
      live: poker.dealer,
      finished: result?.dealer,
    );
    final threeCard = poker.variant == PokerVariant.threeCardPoker;

    return Padding(
      padding: EdgeInsets.fromLTRB(pad, Space.xxs, pad, 0),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final h = box.maxHeight;
          final podW = Dim.podW(w, h);
          final handH = Dim.handH(h);

          Widget pod(int viewIndex) {
            final s = viewIndex < seats.length ? seats[viewIndex] : null;
            final reveal = s == null ? null : result?.revealOf(s.userId);
            final outcome = t.pokerOutcome(reveal?.outcome);
            return SeatPod(
              poker: true,
              revealed: reveal?.cards,
              best: reveal?.best ?? const [],
              // What the hand made — and, against the dealer, how it fared.
              revealedHand: reveal == null
                  ? null
                  : outcome.isEmpty
                  ? reveal.handName
                  : '${reveal.handName} · $outcome',
              seat: s,
              orbCorner: viewIndex == 0
                  ? OrbCorner.contained
                  : viewIndex.isOdd
                  ? OrbCorner.topRight
                  : OrbCorner.topLeft,
              isMe: s?.userId != null && s!.userId == state.user?.id,
              // The button travels: the snapshot marks the seat that holds
              // it, and names it on the room too.
              isDealer:
                  s != null && (s.dealer || s.seatIndex == room.dealerSeat),
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
              bubbleSide: viewIndex == 0
                  ? BubbleSide.above
                  : viewIndex <= 2
                  ? BubbleSide.right
                  : BubbleSide.left,
              reversed: viewIndex == 0,
            );
          }

          // Positioned by centre, and never past either edge (the Teen Patti
          // felt's `at`).
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

          final potCentre = Offset(0.5 * w, _potDy * h);
          Offset seatCentre(int seatIndex) =>
              _seatCentre(state, seatIndex, w, h);

          // The board's cards: five across the gap between the top seats, so
          // each is as tall as that gap allows and never taller than the
          // viewer's own cards would dwarf.
          final boardW = w * 0.30;
          final boardCardH = math.min(
            handH * 0.62,
            ((boardW - 4 * Space.xxs) / 5) / PlayingCard.aspect,
          );

          // Which seats took a pot, for the fireworks and the chips.
          final winners = result?.winners ?? const <PokerPotWinner>[];
          final winnerSeats = [
            for (final winner in winners)
              for (final seat in room.seats)
                if (seat.userId == winner.userId) seat.seatIndex,
          ];

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // The deal: a back flies from the deck to every seat in the
              // hand, as many as the game deals each, before the cards are
              // shown. The Teen Patti felt's own layer, with the count from
              // the poker block.
              Positioned.fill(
                child: RepaintBoundary(
                  child: IgnorePointer(
                    child: DealFlights(
                      seats: room.seats,
                      roomId: room.roomId,
                      handNo: room.handNo,
                      centreOf: seatCentre,
                      deck: Offset(w / 2, h * 0.42),
                      cardHeight: (podW * 0.42).clamp(18.0, 46.0),
                      cards: poker.holeCards > 0 ? poker.holeCards : 3,
                    ),
                  ),
                ),
              ),
              at(
                const Offset(0.5, _tagDy),
                _StreetTag(room: room, poker: poker),
                width: w * 0.30,
              ),
              // The board, or the dealer's hand on 3-Card Poker; nothing on
              // 5-Card Draw, which has neither.
              if (poker.hasBoard)
                at(
                  const Offset(0.5, _boardDy),
                  _Board(cards: board, cardHeight: boardCardH),
                  width: boardW,
                )
              else if (threeCard && dealer != null)
                Positioned(
                  left: (0.5 * w - boardW / 2)
                      .clamp(0.0, math.max(0.0, w - boardW))
                      .toDouble(),
                  width: boardW,
                  bottom: h * (1 - _dealerFootDy),
                  child: _DealerHand(
                    dealer: dealer,
                    // Face up exactly when the cards are in hand, so the
                    // verdict is never written under three backs.
                    revealed: dealer.cards.isNotEmpty,
                    cardHeight: boardCardH,
                  ),
                ),
              at(
                const Offset(0.5, _potDy),
                _Pots(
                  room: room,
                  pots: result != null && result.pots.isNotEmpty
                      ? result.pots
                      : poker.pots,
                  // A dealer game's pots are one per player against the
                  // house, not a main pot and side pots: no capsules.
                  dealerGame: threeCard || poker.dealer != null,
                  chipSize: (podW * 0.17).clamp(12.0, 20.0),
                ),
                width: w * 0.24,
              ),
              if (handLive)
                at(
                  const Offset(_promptDx, _promptDy),
                  _PokerStatus(
                    room: room,
                    pocket: true,
                    wrapAt: w * _promptW * _promptWrap,
                  ),
                  width: w * _promptW,
                )
              else
                at(
                  const Offset(0.5, _statusDy),
                  _PokerStatus(room: room, pocket: false),
                  width: w * 0.28,
                ),

              for (var i = 1; i < seatPlaces.length; i++)
                at(seatPlaces[i], pod(i)),

              Positioned(
                left: seatPlaces[0].dx * w - podW / 2,
                bottom: h * 0.012,
                width: podW,
                child: pod(0),
              ),
              Positioned(
                left: seatPlaces[0].dx * w + podW / 2 + Space.md,
                bottom: h * 0.012,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _OwnHandLine(result: result),
                    if (seats.isNotEmpty && seats[0] != null && handLive) ...[
                      SeatBet(
                        seat: seats[0]!,
                        width: podW * 1.22,
                        totalFirst: true,
                        poker: true,
                      ),
                      const SizedBox(height: Space.xs),
                    ],
                    _PokerHand(cardHeight: handH, result: result),
                  ],
                ),
              ),

              // The celebration: fireworks over the winner and the chips
              // crossing the table to every seat that took a pot.
              if (state.pokerShowing)
                Positioned.fill(
                  child: _PokerCelebration(
                    hand: room.handNo,
                    winnerAt: winnerSeats.isEmpty
                        ? null
                        : Offset(
                            seatCentre(winnerSeats.first).dx / w,
                            seatCentre(winnerSeats.first).dy / h,
                          ),
                    big: state.iWon,
                    flights: [
                      for (final seatIndex in winnerSeats)
                        PotFlight(
                          key: ValueKey('poker-pot-${room.handNo}-$seatIndex'),
                          from: potCentre,
                          to: seatCentre(seatIndex),
                          size: podW * 0.28,
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Which game this is and where the hand stands, on the felt where the Teen
/// Patti table names its category: "Texas Hold'em · Flop". Between hands the
/// stake takes the street's place, as it does on the category tag.
class _StreetTag extends StatelessWidget {
  const _StreetTag({required this.room, required this.poker});

  final RoomState room;
  final PokerState poker;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<GameState>();
    final t = state.t;
    final palette = AppTheme.paletteFor(
      theme.colorScheme,
      category: room.category,
      bootAmount: room.bootAmount,
    );
    final street = poker.street.isNotEmpty
        ? poker.street
        : state.pokerShowing
        ? PokerStreet.showdown
        : PokerStreet.none;

    return Center(
      child: Plate(
        accent: palette.accent.withValues(alpha: 0.45),
        padding: const EdgeInsets.fromLTRB(
          Space.md,
          Space.xs,
          Space.lg,
          Space.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(palette.icon, size: 14, color: palette.accent),
            const SizedBox(width: Space.sm),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${t.pokerVariantName(poker.variant)} · '
                  '${street.isEmpty ? formatChips(room.bootAmount) : t.pokerStreetName(street)}',
                  maxLines: 1,
                  style: AppTheme.label(
                    theme.textTheme.labelMedium ?? const TextStyle(),
                    colour: AppTheme.goldBright.withValues(alpha: 0.92),
                    weight: FontWeight.w700,
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

/// The community cards, five places across: the cards dealt so far, and a
/// faint outline for each still to come, so the shape of the hand — flop,
/// turn, river — is readable before a card has landed.
class _Board extends StatelessWidget {
  const _Board({required this.cards, required this.cardHeight});

  final List<String> cards;
  final double cardHeight;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < 5; i++)
          Padding(
            padding: EdgeInsets.only(left: i == 0 ? 0 : Space.xxs),
            child: i < cards.length
                ? _Arrive(
                    key: ValueKey('board-${cards[i]}'),
                    child: PlayingCard(height: cardHeight, code: cards[i]),
                  )
                : _EmptySlot(height: cardHeight),
          ),
      ],
    );
  }
}

/// A place on the board with no card in it yet.
class _EmptySlot extends StatelessWidget {
  const _EmptySlot({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: height * PlayingCard.aspect,
    height: height,
    child: DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(height * 0.055),
        border: Border.all(
          color: AppTheme.goldBright.withValues(alpha: 0.22),
          width: Dim.hairline,
        ),
        color: AppTheme.ink900.withValues(alpha: 0.18),
      ),
    ),
  );
}

/// A card landing where it lies — on the board, or in the viewer's hand: it
/// grows and fades in, once, keyed on the card so a redraw never replays it.
/// [delay] holds it invisible first, so a hand's cards arrive one after
/// another rather than all at once.
class _Arrive extends StatelessWidget {
  const _Arrive({super.key, required this.child, this.delay = Duration.zero});

  final Widget child;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final total = delay + Motion.enter;
    final from = delay.inMicroseconds / total.inMicroseconds;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: total,
      curve: Interval(from, 1, curve: Motion.settle),
      child: child,
      builder: (context, v, child) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.7 + 0.3 * v, child: child),
      ),
    );
  }
}

/// 3-Card Poker's house hand, at the top of the felt: three backs while the
/// hand is played, its cards and its name at the reveal, and whether it
/// qualified — the one fact the whole result turns on.
class _DealerHand extends StatelessWidget {
  const _DealerHand({
    required this.dealer,
    required this.revealed,
    required this.cardHeight,
  });

  final PokerDealer dealer;
  final bool revealed;
  final double cardHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.watch<GameState>().t;
    final cards = dealer.cards;
    final count = math.max(cards.length, dealer.cardCount);
    if (count == 0) return const SizedBox.shrink();
    final qualified = dealer.qualified;
    final ink = AppTheme.goldBright.withValues(alpha: 0.9);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          t.dealerLabel,
          maxLines: 1,
          style: AppTheme.smallCaps(
            theme.textTheme.labelSmall ?? const TextStyle(),
            colour: ink,
          ),
        ),
        const SizedBox(height: Space.xxs),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < math.min(count, 3); i++)
              Padding(
                padding: EdgeInsets.only(left: i == 0 ? 0 : Space.xxs),
                child: PlayingCard(
                  height: cardHeight,
                  code: i < cards.length ? cards[i] : null,
                ),
              ),
          ],
        ),
        if (revealed && (dealer.handName.isNotEmpty || qualified != null)) ...[
          const SizedBox(height: Space.xxs),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              [
                if (dealer.handName.isNotEmpty) dealer.handName,
                if (qualified != null)
                  qualified ? t.dealerQualifies : t.dealerNotQualified,
              ].join(' · '),
              maxLines: 1,
              style: AppTheme.label(
                theme.textTheme.labelSmall ?? const TextStyle(),
                colour: qualified == false ? AppTheme.amber : ink,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The pot on its plinth — everything on the table this hand — and, when a
/// short stack has split it, each pot as a capsule beneath: the main pot
/// first, then the side pots.
class _Pots extends StatelessWidget {
  const _Pots({
    required this.room,
    required this.pots,
    required this.chipSize,
    this.dealerGame = false,
  });

  final RoomState room;
  final List<PokerPot> pots;
  final double chipSize;

  /// A game against the house (3-Card Poker): every player's stake is a pot
  /// of its own, so the plinth alone says what is on the table and no
  /// "side pot" capsules are drawn.
  final bool dealerGame;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.watch<GameState>().t;
    final total = math.max(room.pot, pots.fold(0, (s, p) => s + p.amount));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Plate(
          radius: Radii.lg,
          opacity: 0.52,
          elevation: 3,
          accent: AppTheme.goldBright.withValues(alpha: 0.22),
          padding: const EdgeInsets.symmetric(
            horizontal: Space.sm,
            vertical: Space.xs,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ChipStack(
                size: chipSize,
                colours: const [
                  AppTheme.goldDeep,
                  AppTheme.ink500,
                  AppTheme.gold,
                  AppTheme.goldBright,
                ],
              ),
              const SizedBox(width: Space.sm),
              Flexible(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: total.toDouble()),
                  duration: const Duration(milliseconds: 550),
                  curve: Motion.standard,
                  builder: (context, value, _) => FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      formatChips(value.round()),
                      style: AppTheme.money(
                        theme.textTheme.titleLarge ?? const TextStyle(),
                        colour: AppTheme.goldBright,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (pots.length > 1 && !dealerGame) ...[
          const SizedBox(height: Space.xxs),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: Space.xxs,
            runSpacing: Space.xxs,
            children: [
              for (final (i, pot) in pots.indexed)
                _PotCapsule(
                  label: i == 0 ? t.potLabel : t.sidePotLabel,
                  amount: pot.amount,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// One pot of several, named and counted.
class _PotCapsule extends StatelessWidget {
  const _PotCapsule({required this.label, required this.amount});

  final String label;
  final int amount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Plate(
      radius: Radii.pill,
      opacity: 0.6,
      elevation: 1,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xxs,
      ),
      child: Text(
        '$label ${formatChips(amount)}',
        maxLines: 1,
        style: AppTheme.money(
          theme.textTheme.labelSmall ?? const TextStyle(),
          colour: AppTheme.boneInk.withValues(alpha: 0.86),
          weight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The one line in the middle of the table: why nothing is happening
/// (waiting, starting), or what the viewer is being asked (the draw, the
/// decision against the dealer), or that their seat is being held for a chip
/// purchase.
class _PokerStatus extends StatelessWidget {
  const _PokerStatus({
    required this.room,
    required this.pocket,
    this.wrapAt = 0,
  });

  final RoomState room;

  /// Drawn in the pocket right of the pot (a hand on the table) rather than
  /// across the top of the felt: the line takes two lines there, and the pair
  /// is scaled to the pocket's width.
  final bool pocket;

  /// The width the pocket's line is measured at before it is scaled down to
  /// fit — wider than the pocket itself, so a sentence breaks into two and is
  /// brought down once rather than being squashed onto one line. Ignored
  /// unless [pocket].
  final double wrapAt;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final t = state.t;
    final graceLeft = state.unfundedGraceLeft(DateTime.now());
    // The clock folded this player's hand: said here for the rest of the
    // hand, where a toast is one glance long.
    final timedOut =
        state.pokerTimedOutHand == room.handNo &&
        room.you?.status == SeatState.packed;

    final String line;
    if (graceLeft != null) {
      line = t.buyChipsToStay(graceLeft);
    } else if (state.canDraw) {
      line = t.exchangeUpTo(state.maxDiscards);
    } else if (state.canPlay) {
      line = t.playOrFold;
    } else if (timedOut && room.state == TableState.betting) {
      line = t.pokerTimedOut;
    } else {
      line = switch (room.state) {
        TableState.waiting => '${t.waitingForPlayers} (${room.minPlayers})',
        TableState.starting => t.startingGame,
        _ => '',
      };
    }
    if (line.isEmpty) return const SizedBox.shrink();

    final mine = state.myPokerTurn && room.state == TableState.betting;
    final base = theme.textTheme.titleSmall ?? const TextStyle();

    return AnimatedSwitcher(
      duration: Motion.base,
      switchInCurve: Motion.emphasized,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.14),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      // Scaled down to whatever room the place has, never cut. In the pocket
      // the line is WRAPPED first and scaled after: a sentence squeezed onto
      // one line of a 100dp pocket is a third the size of the same sentence
      // across two, and [wrapAt] is the width it is measured at before the
      // whole block is brought down to the slot.
      child: FittedBox(
        key: ValueKey(graceLeft != null ? 'unfunded-grace' : line),
        fit: BoxFit.scaleDown,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: pocket && wrapAt > 0 ? wrapAt : double.infinity,
          ),
          child: Text(
            line,
            maxLines: pocket ? 2 : 1,
            textAlign: TextAlign.center,
            style:
                AppTheme.label(
                  base,
                  colour: graceLeft != null
                      ? AppTheme.amber
                      : mine
                      ? AppTheme.goldBright
                      : theme.brightness == Brightness.dark
                      ? AppTheme.boneInk.withValues(alpha: 0.82)
                      : AppTheme.inkOnLight.withValues(alpha: 0.78),
                  weight: FontWeight.w700,
                ).copyWith(
                  shadows: mine
                      ? [
                          Shadow(
                            color: AppTheme.goldBright.withValues(alpha: 0.22),
                            blurRadius: 6,
                          ),
                        ]
                      : null,
                ),
          ),
        ),
      ),
    );
  }
}

/// The viewer's own hand name over their cards — what their cards make right
/// now (`you.hand`), or what they made at the reveal, with the outcome against
/// the dealer where there is one.
class _OwnHandLine extends StatelessWidget {
  const _OwnHandLine({required this.result});

  final PokerResult? result;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final t = state.t;
    final myReveal = result?.revealOf(state.user?.id);
    final live = state.room?.you?.hand?.handName ?? '';
    final outcome = t.pokerOutcome(myReveal?.outcome);
    final name = myReveal != null
        ? (outcome.isEmpty
              ? myReveal.handName
              : '${myReveal.handName} · $outcome')
        : live;
    if (name.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xxs),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.sm,
          vertical: Space.xxs,
        ),
        decoration: BoxDecoration(
          color: AppTheme.plaque(theme.brightness).withValues(alpha: 0.86),
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: AppTheme.hairlineColour(theme.brightness)),
        ),
        child: Text(
          name,
          maxLines: 1,
          style: AppTheme.smallCaps(
            theme.textTheme.labelMedium ?? const TextStyle(),
            tracking: 0.8,
            colour: theme.brightness == Brightness.dark
                ? AppTheme.goldBright
                : AppTheme.goldDeep,
          ),
        ),
      ),
    );
  }
}

/// The viewer's hole cards, fanned on the floor of the table: two on
/// Hold'em, four on Omaha, five on 5-Card Draw, three on 3-Card Poker. Face
/// up the moment they are dealt (`you.cards`; a poker hand is never blind),
/// backs only when the server has not sent them.
///
/// **On the draw street each card is a key**: a tap marks it to be exchanged
/// (`GameState.toggleDiscard`), and a marked card lifts and takes a gold
/// edge. **Once the hand is decided** — the river, the second betting round of
/// Draw, the showdown — the cards that do not count are set back behind the
/// ones `you.hand.best` names, as a 5-Card Teen Patti hand's are.
///
/// Five cards stand in the box three do: the fan's run is the Teen Patti
/// fan's, and a longer hand is fanned tighter rather than wider, so the keys
/// in the bottom-right corner are never under a card.
class _PokerHand extends StatelessWidget {
  const _PokerHand({required this.cardHeight, required this.result});

  final double cardHeight;
  final PokerResult? result;

  /// How far the outer cards lean, in radians; the cards between lean in
  /// proportion.
  static const double _fan = 0.078;

  /// How far a marked card lifts, and a card that counts stands proud.
  static const double _picked = 0.10;
  static const double _proud = 0.05;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final room = state.room;
    final you = room?.you;
    final poker = room?.poker;
    if (room == null || you == null || poker == null) {
      return const SizedBox.shrink();
    }
    final t = state.t;
    final packed = you.status == SeatState.packed;
    final beaten = you.status == SeatState.lost;
    final inHand =
        you.status == SeatState.active || you.status == SeatState.won;
    if (!inHand && !packed && !beaten) return const SizedBox.shrink();

    final myReveal = result?.revealOf(state.user?.id);
    final cards = you.cards.isNotEmpty
        ? you.cards
        : (myReveal?.cards ?? const <String>[]);
    // How many to draw: what the server sent, else what the seat is said to
    // hold, else the game's deal. Never more than the fan has room for.
    final seatCards =
        room.seats
            .where((s) => s.seatIndex == you.seatIndex)
            .firstOrNull
            ?.cardCount ??
        0;
    final count = math.min(
      5,
      cards.isNotEmpty
          ? cards.length
          : seatCards > 0
          ? seatCards
          : poker.holeCards,
    );
    if (count <= 0) return const SizedBox.shrink();

    // The cards that count, once the hand is decided.
    final street = poker.street;
    final decided =
        result != null ||
        street == PokerStreet.river ||
        street == PokerStreet.postdraw ||
        street == PokerStreet.showdown;
    final counted = decided
        ? (myReveal?.best.isNotEmpty ?? false)
              ? myReveal!.best
              : (you.hand?.best ?? const <String>[])
        : const <String>[];
    final settingBack =
        counted.isNotEmpty && cards.isNotEmpty && cards.any(counted.contains);
    final choosing = state.canDraw;
    final marked = state.discardSelection;

    final cardW = cardHeight * PlayingCard.aspect;
    // Three cards or fewer keep the Teen Patti overlap; more share the run
    // three would take.
    final step = count <= 3 ? cardW * 0.82 : 2 * cardW * 0.82 / (count - 1);
    final run = step * (count - 1);
    final lean = cardHeight * 0.09;
    final width = cardW + run + 2 * lean;
    final mid = (count - 1) / 2;

    return SizedBox(
      width: width,
      height: cardHeight * 1.12,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedPositioned(
              key: ValueKey('poker-card-${room.handNo}-$i'),
              duration: Motion.base,
              curve: Motion.standard,
              left: lean + i * step,
              bottom: i < cards.length && marked.contains(cards[i])
                  ? cardHeight * _picked
                  : settingBack &&
                        i < cards.length &&
                        counted.contains(cards[i])
                  ? cardHeight * _proud
                  : 0,
              child: Transform.rotate(
                angle: mid == 0 ? 0 : (i - mid) * (_fan / mid),
                alignment: Alignment.bottomCenter,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: choosing && i < cards.length
                      ? () => state.toggleDiscard(cards[i])
                      : null,
                  child: SetBack(
                    setBack:
                        settingBack &&
                        i < cards.length &&
                        !counted.contains(cards[i]),
                    cardHeight: cardHeight,
                    child: WildEdge(
                      wild: i < cards.length && marked.contains(cards[i]),
                      cardHeight: cardHeight,
                      label: t.draw,
                      // Each card arrives a beat after the one before it,
                      // once per card: keyed on the card itself, so a hand
                      // re-dealt after a draw brings only its new cards in.
                      child: _Arrive(
                        key: ValueKey(
                          'own-${room.handNo}-$i-'
                          '${i < cards.length ? cards[i] : 'back'}',
                        ),
                        delay: DealFlights.stagger * i,
                        child: PlayingCard(
                          height: cardHeight,
                          code: i < cards.length ? cards[i] : null,
                          dimmed: packed,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The winner's fireworks and the chips leaving the pot, drawn over the felt
/// for the length of the celebration.
class _PokerCelebration extends StatelessWidget {
  const _PokerCelebration({
    required this.hand,
    required this.winnerAt,
    required this.big,
    required this.flights,
  });

  final int hand;
  final Offset? winnerAt;
  final bool big;
  final List<Widget> flights;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: _Fireworks(hand: hand, focus: winnerAt, big: big),
      ),
      for (final flight in flights) Positioned.fill(child: flight),
    ],
  );
}

/// `assets/animations/Fireworks.json`, once per win, over the seat that won
/// (the Teen Patti table's burst, drawn the same way).
class _Fireworks extends StatefulWidget {
  const _Fireworks({required this.hand, this.focus, this.big = false});

  final int hand;
  final Offset? focus;
  final bool big;

  @override
  State<_Fireworks> createState() => _FireworksState();
}

class _FireworksState extends State<_Fireworks>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  @override
  void didUpdateWidget(covariant _Fireworks old) {
    super.didUpdateWidget(old);
    if (old.hand != widget.hand && _controller.duration != null) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) {
          final side =
              math.min(box.maxWidth, box.maxHeight) *
              (widget.big ? 1.25 : 0.95);
          final centre = widget.focus == null
              ? Offset(box.maxWidth / 2, box.maxHeight / 2)
              : Offset(
                  widget.focus!.dx * box.maxWidth,
                  widget.focus!.dy * box.maxHeight,
                );
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: centre.dx - side / 2,
                top: centre.dy - side / 2,
                width: side,
                height: side,
                child: RepaintBoundary(
                  child: Lottie.asset(
                    'assets/animations/Fireworks.json',
                    controller: _controller,
                    fit: BoxFit.contain,
                    onLoaded: (composition) {
                      _controller.duration = composition.duration;
                      _controller.forward(from: 0);
                    },
                    errorBuilder: (context, error, stack) =>
                        const SizedBox.shrink(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The poker console, bottom-right: Check or Call and All-in on the top row,
/// the bet stepper on the bottom — or, in its place, the one key the street
/// is about: Draw on 5-Card Draw's draw street, Play on 3-Card Poker's
/// decision. Every key is lit only while the server offers the move, and off
/// turn each still reads the figure it would place.
class _PokerKeys extends StatelessWidget {
  const _PokerKeys();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    final size = MediaQuery.sizeOf(context);
    final keyH = Dim.keyH(size.height);
    final keyW = Dim.keyW(size.width);
    final gap = Dim.gap(size.width);
    // As wide as the Teen Patti console: two steppers, the bet key and the
    // gaps between them. The top row splits the same width in two.
    final rowW = 2 * Dim.minTouch + keyW + 2 * gap;
    final halfW = (rowW - gap) / 2;

    final street = state.pokerStreet;
    final live = state.myPokerTurn;
    final drawStreet = state.canDraw || (!live && street == PokerStreet.draw);
    final decision = state.canPlay || (!live && street == PokerStreet.decision);
    // Check when nothing is owed, Call for what is.
    final callAmount = state.pokerCallAmount;
    final checking = state.canCheck || (!live && callAmount <= 0);
    final canMatch = state.canCheck || state.canCall;
    // The one gold key: the everyday move — Check / Call — unless the street
    // is about one thing, and then that thing.
    final bottomPrimary = drawStreet || decision;
    final marked = state.discardSelection.length;

    return Padding(
      padding: EdgeInsets.fromLTRB(gap, gap, Dim.feltPad(size.width), gap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // On the draw and decision streets there is nothing to check, call
          // or shove: the row stands empty rather than dark ("Call 0",
          // "All-in 0" over the Draw key, Pixel 6, 19 Sep 2026), and keeps
          // its height so the cluster — and the felt above it — do not jump.
          if (bottomPrimary)
            SizedBox(width: rowW, height: keyH)
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                MachinedKey(
                  width: halfW,
                  height: keyH,
                  icon: checking
                      ? Icons.check_rounded
                      : Icons.arrow_forward_rounded,
                  label: checking ? t.check : t.call,
                  amount: checking ? null : formatChips(callAmount),
                  alive: canMatch,
                  primary: true,
                  onPressed: state.canCheck
                      ? state.pokerCheck
                      : state.canCall
                      ? state.pokerCall
                      : null,
                ),
              ],
            ),
          SizedBox(height: gap),
          if (drawStreet)
            MachinedKey(
              width: rowW,
              height: keyH,
              icon: Icons.swap_horiz_rounded,
              // "Draw 2", or "Stand pat" with nothing marked.
              label: marked == 0 ? t.standPat : '${t.draw} $marked',
              alive: state.canDraw,
              primary: true,
              onPressed: state.canDraw ? state.pokerDrawSelected : null,
            )
          else if (decision)
            MachinedKey(
              width: rowW,
              height: keyH,
              icon: Icons.play_arrow_rounded,
              label: t.play,
              amount: formatChips(state.pokerPlayAmount),
              alive: state.canPlay,
              primary: true,
              onPressed: state.canPlay ? state.pokerPlay : null,
            )
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StepperKey(
                  icon: Icons.remove_rounded,
                  height: keyH,
                  onPressed: state.canPokerStepDown
                      ? () => state.pokerStepBet(-1)
                      : null,
                ),
                SizedBox(width: gap),
                MachinedKey(
                  width: keyW,
                  height: keyH,
                  icon: Icons.trending_up_rounded,
                  label: state.pokerBetIsRaise ? t.raise : t.bet,
                  amount: formatChips(state.pokerBetAmount),
                  alive: state.canPokerBetOrRaise,
                  onPressed: state.canPokerBetOrRaise
                      ? state.pokerBetOrRaise
                      : null,
                ),
                SizedBox(width: gap),
                StepperKey(
                  icon: Icons.add_rounded,
                  height: keyH,
                  onPressed: state.canPokerStepUp
                      ? () => state.pokerStepBet(1)
                      : null,
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Fold, alone in the bottom-left corner, where the Teen Patti table keeps
/// Pack — and for its reason: the one irreversible key, kept away from the
/// keys pressed every turn.
class _FoldKey extends StatelessWidget {
  const _FoldKey();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final size = MediaQuery.sizeOf(context);
    final gap = Dim.gap(size.width);

    return Padding(
      padding: EdgeInsets.fromLTRB(Dim.feltPad(size.width), gap, gap, gap),
      // The destructive key, as Pack is at a Teen Patti table (KeyRole).
      child: MachinedKey(
        width: Dim.keyW(size.width),
        height: Dim.keyH(size.height),
        icon: Icons.close_rounded,
        label: state.t.fold,
        role: KeyRole.destructive,
        alive: state.canFold,
        onPressed: state.canFold ? state.pokerFold : null,
      ),
    );
  }
}
