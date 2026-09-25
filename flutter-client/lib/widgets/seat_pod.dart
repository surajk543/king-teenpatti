import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import 'avatar.dart';
import 'hammer_flight.dart';
import 'liquid_fill.dart';
import 'playing_card.dart';
import 'poker_chip.dart';
import 'glass_orb.dart';
import 'premium_surface.dart';
import 'seat_ring.dart';
import 'variation_prompt.dart';

/// Every proportion in the pod, named once.
///
/// A pod is the one thing in the app that has to work from 56dp to 148dp, so
/// each figure is a fraction of [SeatPod.width] rather than a dp. Its type is
/// not here: every size a seat writes in — the name, the status, the chips,
/// the bubble — is a role of the table's type scale ([SeatType]), a share of
/// the same width with a floor under it.
///
/// The plaque's height is the sum below plus its padding, never a number of its
/// own: 0.10 padding + name row + 0.04 + avatar + 0.04 + stack pill.
/// At podW 56 -> 60.2 | 90 (h=360) -> 86.7 | 105 (h=411) -> 100.4 |
/// 148 (tablet ceiling) -> 139.4, plus 1 + 0.02W for the winner's rule. Never
/// taller than it is wide above podW 70 (below that the type floors win, and
/// a readable name is worth 4dp), which is what keeps the rim seats
/// clear of each other on the narrowest felt.
const double _kRadius = 0.11;
const double _kPad = 0.05;
const double _kAvatar = 0.245;

/// The picture when no stack pill sits under it — a blind table's other
/// seats. It takes back most of what the pill was using, so the pod stays
/// about the height it was and the face gets the difference.
const double _kAvatarAlone = 0.315;

/// The viewer's own picture. Larger than anyone else's, which makes their pod
/// TALLER without making it wider — the column sizes to its contents, and
/// nothing else in it changed. Width is deliberately untouched: the pod sits
/// between the Pack key and a fanned hand with little room either side, so
/// growing sideways is what would collide, and growing downwards is free now
/// that the name has moved out above the plaque.
const double _kAvatarMine = 0.365;
const double _kDealer = 0.095;
const double _kGap = 0.04;

/// The corner every capsule on a seat is cut to — BLIND / SEEN on its cards,
/// a revealed hand's name, the bet badge and "In Pot" — so the four read as
/// one set of labels rather than four (owner's brief, 25 Sep 2026: "Improve
/// consistency between: player name, avatar, cards, BLIND/SEEN state, In Pot
/// amount"). They were cut at 0.08, 0.08, 0.10 and 0.07 of the pod.
const double _kCapsule = 0.08;

/// How far a seat fades once it is out of the hand — packed, lost, or waiting
/// for the next deal. Low enough to read as "not playing", high enough that
/// the name and the picture are still legible: a seat you cannot see is a
/// seat you forget is sitting there, and they are still at the table.
const double _kAsideOpacity = 0.45;

/// The same fade on the light theme's pale ground, where 0.45 took a packed
/// seat's "Pack" line to 2:1: charcoal loses far more against ice than bone
/// does against obsidian.
const double _kAsideOpacityLight = 0.62;

/// One player's place at the table: a portrait pod with the name across the
/// top, a picture in the middle and the stack on a pill underneath, with its
/// cards alongside and its bet between the pod and the pot.
///
/// The pod of whoever is to act carries a ring in the turn colour and fills
/// from the bottom. The ring starts green and bleeds to red as the clock
/// empties, so the colour alone says how long is left; a full pod means the
/// turn is over.
/// Where a seat's speech bubble opens relative to its pod.
enum BubbleSide { above, left, right }

/// Which corner of a seat pod its orb spills out of. The table picks per seat
/// so the colour always leaks towards open felt — never under the rail, over a
/// card fan or off the side of the screen.
///
/// [contained] keeps the colour inside the glass and draws no orb outside it:
/// the viewer's pod stands on the floor between the missed-turns plate and
/// their own cards, and on a 360dp phone there is no open felt on either side
/// for anything to spill into.
enum OrbCorner { topLeft, topRight, contained }

/// Where a pod's orb sits, as a square in the pod's own coordinates: most of it
/// behind the top of the pod, and a tenth of the pod's width reaching past the
/// chosen corner ([TableAmbient.orbSpill]; a sixth until the table polish of
/// 24 Sep 2026, when the orbs read as five coloured discs competing with the
/// seat on turn). No more than that — the table is crowded, and an orb
/// reaching further would lie under a neighbour's cards.
Rect _orbRect(double w, OrbCorner corner) {
  final d = w * TableAmbient.orbSize;
  final spill = w * TableAmbient.orbSpill;
  final cx = corner == OrbCorner.topRight ? w - d / 2 + spill : d / 2 - spill;
  return Rect.fromCenter(
    center: Offset(cx, d / 2 - spill),
    width: d,
    height: d,
  );
}

class SeatPod extends StatelessWidget {
  const SeatPod({
    super.key,
    required this.seat,
    required this.isMe,
    required this.isDealer,
    required this.onTurn,
    required this.progress,
    required this.deadlineMs,
    required this.totalMs,
    required this.chipsHidden,
    required this.handLive,
    required this.width,
    required this.avatarUrl,
    this.revealed,
    this.revealedHand,
    this.wild = const [],
    this.playsAs = const [],
    this.best = const [],
    this.saying,
    this.bubbleSide = BubbleSide.above,
    this.reversed = false,
    this.beside = false,
    this.orbCorner = OrbCorner.topLeft,
    this.podKey,
    this.impact,
    this.poker = false,
  });

  /// A seat at a poker table (go-server/internal/poker). Nothing about it is
  /// blind or seen: no BLIND / SEEN word rides on its cards and no back turns
  /// green, a fold reads as "Fold" rather than "Pack", its bet badge carries
  /// what it has put in on this street ([Seat.streetBet]), and a seat with its
  /// whole stack in wears an all-in ribbon. False on every Teen Patti table,
  /// where nothing here changes.
  final bool poker;

  /// Names the pod itself — the glass plaque, not the column of cards and bets
  /// under it — so the table can find where it stands on the felt: where a
  /// Force Sideshow's hammer is thrown from, and where it lands.
  final Key? podKey;

  /// The hammer's clock while this is the pod being hit, else null
  /// ([PodImpact]).
  final Animation<double>? impact;

  final Seat? seat;
  final bool isMe;
  final bool isDealer;
  final bool onTurn;

  /// This seat's cards, face up, at the showdown.
  ///
  /// Null for every other moment, and the pod draws backs. When it arrives the
  /// existing PlayingCard flip runs in place, so the hand is revealed at the
  /// seat that played it rather than in a panel over the middle of the table —
  /// which is where a real table shows you a hand.
  final List<String>? revealed;

  /// What the revealed hand is called — "Pair", "Colour", "Run". Shown under
  /// the cards at the showdown, because three cards read at pod scale from
  /// across a table are not a hand anyone can name at a glance.
  final String? revealedHand;

  /// Which of [revealed] played as wild cards — a variation table only, and
  /// empty everywhere else. They get a gold edge, which is what explains a
  /// ranking the three faces alone would not make.
  final List<String> wild;

  /// The revealed hand as it was COUNTED, index for index with [revealed]: a
  /// wild card replaced by the card it stood for. When the server sends it
  /// (with [wild]) the fan shows THESE faces — the trail that won, not the
  /// pair it was dealt (owner, 24 Sep 2026: "on show or sideshow, show updated
  /// cards not the base cards") — and the wild marking stays on the stand-in,
  /// so the star says which card was the joker. Empty: the real cards.
  final List<String> playsAs;

  /// Which three of a FIVE-card [revealed] hand were counted (5-Card, a
  /// variation table) — the server's choice, sent with the reveal. The other
  /// two are drawn set back. Empty for every three-card hand.
  final List<String> best;

  /// How much of this player's turn has gone, 0 to 1, or null when unknown.
  /// Used for the colour; the fill level is worked out per frame from the
  /// deadline below, because this only updates about once a second.
  final double? progress;
  final int deadlineMs;
  final int totalMs;
  final bool chipsHidden;

  /// Whether a hand is still on the table — counting the moment after it ends,
  /// while the winner is being shown. A seat keeps its status until the next
  /// deal, so without this a finished hand's bets hang over a table that has
  /// gone back to waiting for players.
  final bool handLive;

  /// Drives every other size in the pod.
  final double width;

  /// This player's picture, already made absolute.
  final String? avatarUrl;

  /// What they just said, while it is still fresh.
  final String? saying;

  /// Which way the bubble opens, so it lands on the felt and not off it.
  final BubbleSide bubbleSide;

  /// Cards and the bet chip stack upwards instead of down. The seat at the
  /// bottom of the table needs this or its column runs off the felt.
  final bool reversed;

  /// The seat at the head of the table ([SeatSpot.head]): its cards and its
  /// bet stand BESIDE its pod, on its right, rather than under it, so the seat
  /// is no taller than its pod and the pot keeps the middle of the table. The
  /// seat is then [SeatRing.headUnitWidth] wide: two pods and the gap.
  final bool beside;

  /// Which corner of the pod its colour spills out of (see [OrbCorner]).
  final OrbCorner orbCorner;

  @override
  Widget build(BuildContext context) {
    final s = seat;
    // An empty chair shows nothing: a row of blank pods reads as broken rather
    // than as free seats. Before the watch below, so a table with two players
    // does not rebuild three empty pods on every tick of GameState's clock.
    if (s == null || !s.occupied) return _emptySeat(context);

    final state = context.watch<GameState>();
    final t = state.t;
    final theme = Theme.of(context);
    final turn = (progress ?? 0).clamp(0.0, 1.0);
    // Champagne to red, squared — so it holds gold for most of the turn and
    // reddens sharply at the end rather than sitting muddy in the middle.
    //
    // Gold rather than the scheme's primary because the felt now carries the
    // table's own colour: a green ring on green cloth, or a purple one on
    // purple, is the signal competing with its own background. Champagne is
    // the one accent that reads on all three cloths, and whose turn it is has
    // to be answerable from across the table.
    final beat = Color.lerp(
      AppTheme.goldBright,
      theme.colorScheme.error,
      turn * turn,
    )!;
    // The ring's EDGE, and the ring round the picture: the beat itself by
    // night, where champagne on obsidian cannot be missed — and by day the
    // gold the app writes with on a light ground ([AppTheme.goldOnLight]),
    // reddening the same way. Champagne on the pale room, rail and cloths
    // measured 1.0 to 1.3:1: on a light table the seat on turn was the
    // hardest thing on it to find (final table polish, 26 Sep 2026: "the
    // active player should be immediately identifiable … light/dark theme
    // contrast"). The pod's wash and its rising clock keep the beat.
    final edge = theme.brightness == Brightness.dark
        ? beat
        : Color.lerp(
            AppTheme.goldOnLight,
            theme.colorScheme.error,
            turn * turn,
          )!;

    // Between the pod and the cards and badge hung under it: the table's own
    // spacing for a seat, one step for every gap in the column.
    final gap = TableSpace.seat(width);
    final status = _status(t, s);
    // Nothing in this column may change height as a hand is shown down. A seat
    // is placed by its column's MIDDLE (_Felt `at`), so a column that grows or
    // shrinks at the reveal moves the whole seat: with the hand's name added as
    // a line above the cards and a loser's bet badge dropping out below them,
    // every beaten player's cards jumped down the felt the moment a missile's
    // result came in (owner, 14 Sep 2026). The name rides on the cards instead
    // (_cards), and the badge stays while the finished hand is on show.
    final below = <Widget>[
      if (s.cardCount > 0 && !isMe) ...[
        SizedBox(height: gap),
        _cards(context, t, s),
      ],
      // The viewer's badge and total are not in their column: they are drawn
      // over their own cards instead (see _Felt). Their pod stands on the
      // floor beside a fanned hand, so a stack under it grows towards the
      // screen edge, while the space above the cards is empty and is where
      // their eye already is.
      if (_betShown(s) && !isMe) ...[
        SizedBox(height: gap),
        SeatBet(seat: s, width: width, withCategory: false, poker: poker),
      ] else if (status != null) ...[
        SizedBox(height: gap),
        _statusTag(context, s, status),
      ],
    ];

    final column = <Widget>[
      _pod(
        context,
        s,
        beat,
        edge,
        state.colourFor(s.userId ?? '', theme.colorScheme),
      ),
      ...below,
    ];

    // The bubble takes no room in the column — it hangs off one end of it in
    // a zero-height box — so a player speaking never nudges their own pod,
    // cards or chips. It is the last thing in the column, so it paints over
    // the cards and badge rather than under them, and it stays over the
    // player's own column: the seats round the rim open theirs over their
    // cards, growing towards the middle of the table, and the viewer's opens
    // upwards over their bets. Nothing ever reaches the pot, the tag, or the
    // edge of the felt.
    //
    // The OverflowBox and the bubble itself are handed the same ceiling, so
    // the two can no longer disagree about how wide a bubble may grow.
    final bubbleMax = width * (bubbleSide == BubbleSide.above ? 2.1 : 1.7);
    final bubble = saying == null
        ? null
        : SizedBox(
            height: 0,
            width: width,
            child: OverflowBox(
              alignment: switch (bubbleSide) {
                BubbleSide.above => Alignment.bottomCenter,
                BubbleSide.left => Alignment.bottomRight,
                BubbleSide.right => Alignment.bottomLeft,
              },
              minWidth: 0,
              // Narrower for the seats round the rim: their bubbles grow
              // towards the middle of the table, where the pot and the status
              // line are, and must stop short of them.
              maxWidth: bubbleMax,
              minHeight: 0,
              maxHeight: width * 1.3,
              child: Padding(
                padding: EdgeInsets.only(bottom: gap),
                child: _Bubble(
                  text: saying!,
                  width: width,
                  maxWidth: bubbleMax,
                  // The pointer says whose words these are: the rim seats'
                  // bubbles sit below their pod and point up at it; the
                  // viewer's sits above and points down.
                  tailUp: bubbleSide != BubbleSide.above,
                  tailFrom: switch (bubbleSide) {
                    BubbleSide.above => _TailFrom.centre,
                    BubbleSide.right => _TailFrom.left,
                    BubbleSide.left => _TailFrom.right,
                  },
                ),
              ),
            ),
          );

    // For the viewer the column is reversed, which puts the bubble at the top
    // — above everything, growing upwards. For everyone else it sits at the
    // foot of the column and grows up over it.
    final ordered = <Widget>[...column, ?bubble];

    // The head seat: the pod on the left with its bubble hanging from it, and
    // its cards and bet beside it, centred on the pod's height.
    final Widget body = beside
        ? Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [column.first, ?bubble],
                ),
              ),
              SizedBox(width: width * SeatRing.headGapShare),
              SizedBox(
                width: width,
                child: Column(mainAxisSize: MainAxisSize.min, children: below),
              ),
            ],
          )
        : SizedBox(
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [...(reversed ? ordered.reversed.toList() : ordered)],
            ),
          );

    // The pod is the app's most expensive repeated object — a gradient, three
    // shadows, a ring and a turn clock, five times over a felt whose lamp
    // breathes continuously. Without this boundary all five re-rasterise on
    // every frame of every ambient animation on the screen; with it, a seat
    // repaints when that seat's own data changes.
    // Somebody who has packed, or who is sitting out until the next deal, is
    // still at the table but not in the hand — and at full strength their pod
    // competes for attention with the players who are. Fading the whole column
    // rather than greying its parts keeps them legible (you can still see who
    // is there and what they hold) while putting them behind the live seats.
    //
    // Animated, because status flips mid-hand: a pack that snapped to half
    // opacity would read as a glitch rather than as somebody folding. The
    // winner is never faded — `won` outranks everything, including the `lost`
    // that every other seat is wearing at that moment.
    //
    // Never the viewer's own pod. The fade puts the OTHER players who are out
    // of the hand behind the ones still in it; the viewer's pod is where they
    // read their own balance, and faded it measured under 2:1 in the light
    // theme. Their hand already says they packed, under its plate.
    final aside =
        !isMe &&
        s.status != SeatState.won &&
        (s.status == SeatState.packed ||
            s.status == SeatState.waiting ||
            s.status == SeatState.lost);

    return RepaintBoundary(
      child: AnimatedOpacity(
        opacity: aside
            ? (theme.brightness == Brightness.light
                  ? _kAsideOpacityLight
                  : _kAsideOpacity)
            : 1,
        duration: Motion.base,
        curve: Curves.easeOut,
        child: body,
      ),
    );
  }

  Widget _pod(
    BuildContext context,
    Seat s,
    Color beat,
    Color edge,
    Color player,
  ) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final won = s.status == SeatState.won;

    // Null means withheld, never zero — a blind table sends no stack for
    // anyone but you (CLAUDE.md §6.1). Your own pod always knows its figure,
    // so the viewer keeps their pill while the rim seats lose theirs.
    final knownStack = s.chips != null;

    // A pod is a lobby card at pod size, so the two screens are built from the
    // same material rather than merely resembling each other.
    //
    // Won beats on-turn beats idle, in that order. The idle rim is nearly
    // invisible on purpose: five equally-lit pods is what made every seat look
    // active from across the table, and a bloom under a resting seat spends a
    // signal the app reserves for something the game just did.
    final accent = won
        ? theme.colorScheme.primary
        : onTurn
        ? beat
        : dark
        ? AppTheme.ink400
        : theme.colorScheme.outlineVariant;

    final type = TableType.seat(theme, width);

    // Glass, with the player's own colour behind it (owner's decision, 11 Sep
    // 2026: the lobby's cards, at pod size). What the plaque used to say with
    // its border, wash and bloom now rides on the glass — a gold hairline and a
    // wash of the turn or winner colour while the seat is live, plain frosted
    // white at rest.
    //
    // The colour is ambient light, not a disc (table polish, 24 Sep 2026: five
    // saturated circles at 0.95 were the loudest things on the felt, louder
    // than the seat on turn): softened inside the glass and out, at the
    // opacities [TableAmbient] keeps, so the seat's own ring and the cards
    // stay the brightest things round it.
    final colours = orbColours(player);
    final orb = _orbRect(width, orbCorner);
    // The viewer's own pod glows at three quarters of a rim seat's strength.
    final glow = isMe ? TableAmbient.mineGlow : 1.0;
    final panel = _TurnRing(
      active: onTurn,
      colour: beat,
      edge: edge,
      radius: width * _kRadius,
      glow: glow,
      child: PremiumGlassPanel(
        mode: GlassMode.tinted,
        padding: EdgeInsets.zero,
        radius: width * _kRadius,
        live: won || onTurn,
        tint: won || onTurn ? accent : Colors.white,
        behind: Stack(
          children: [
            Positioned.fromRect(
              rect: orb,
              child: GlassOrb(
                colours: colours,
                size: orb.width,
                soft: true,
                opacity: TableAmbient.orbInside(theme.brightness) * glow,
              ),
            ),
          ],
        ),
        child: Stack(
          children: [
            // The turn clock, drawn as liquid rising inside the pod. Full
            // means their time is up. Boundaried so the wave does not drag the
            // plaque's gradient, border and shadows into a per-frame repaint.
            if (onTurn && progress != null && deadlineMs > 0)
              Positioned.fill(
                child: RepaintBoundary(
                  child: LiquidFill(
                    deadlineMs: deadlineMs,
                    totalMs: totalMs,
                    colour: beat,
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.all(width * _kPad),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: SeatName(
                          isMe ? 'YOU' : s.displayName,
                          // 'YOU' is a fixed Latin string the code owns, so it
                          // can be tracked capitals. A display name never can:
                          // toUpperCase() does nothing to Devanagari or
                          // Bengali, and tracked RAVI beside untracked मीरा is
                          // worse than either alone.
                          style: isMe
                              ? type.you(
                                  colour: dark
                                      ? AppTheme.goldBright
                                      : AppTheme.goldDeep,
                                )
                              : type.name(),
                        ),
                      ),
                      if (isDealer) ...[
                        SizedBox(width: width * 0.035),
                        _DealerButton(size: width * _kDealer * 2),
                      ],
                    ],
                  ),
                  // A laurel rule under the winner's name. The border alone
                  // cannot carry the moment while the pod is also the brightest
                  // thing on a scrimmed table.
                  if (won) ...[
                    SizedBox(height: width * 0.02),
                    Container(
                      height: 1,
                      width: width * 0.5,
                      color: AppTheme.goldBright.withValues(alpha: 0.34),
                    ),
                  ],
                  SizedBox(height: width * _kGap),
                  Avatar(
                    url: avatarUrl,
                    fallback: s.displayName,
                    // Bigger when there is no stack pill under it. On a blind
                    // table another player's chips were never sent, so the
                    // pill under their picture said nothing but '•••' — a
                    // bordered, shaded plaque spending a fifth of the pod's
                    // height to report that it has nothing to report. Drop it
                    // and the picture takes the room instead, which is the one
                    // thing in a pod worth looking at.
                    radius:
                        width *
                        (isMe
                            ? _kAvatarMine
                            : knownStack
                            ? _kAvatar
                            : _kAvatarAlone),
                    // The second, quieter turn cue, for a player reading faces
                    // rather than borders — in the ring's own edge colour.
                    ring: onTurn ? edge : null,
                    ringWidth: onTurn ? 2 : 1.5,
                    // An animated picture plays at the table too: it is what
                    // the player paid for, and a still frame of it here read as
                    // broken. A still picture has no frames, so this costs a
                    // ticker only for the seats that wear one that moves.
                    animate: true,
                  ),
                  if (knownStack) ...[
                    SizedBox(height: width * _kGap),
                    _stackPill(context, s),
                  ],
                ],
              ),
            ),
            // A poker seat with its whole stack in: the ribbon lies over the
            // stack pill, which reads 0 for exactly that player. Only a poker
            // snapshot ever sets the flag.
            if (s.allIn && !won)
              Positioned(
                left: width * _kPad,
                right: width * _kPad,
                bottom: width * _kPad,
                child: IgnorePointer(child: _AllInRibbon(width: width)),
              ),
            // The result, on the winner rather than over the middle of the
            // table — and LAST in this stack, so it sits above the face and
            // the plaque. Placed before them it was painted over by the
            // avatar, which left "W…R" showing round the edges of a picture.
            if (won)
              Positioned.fill(
                child: IgnorePointer(
                  child: _WinnerFlash(width: width, hand: revealedHand),
                ),
              ),
          ],
        ),
      ),
    );

    return PodImpact(
      key: podKey,
      clock: impact,
      width: width,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // The orb behind the pod, where it reaches past the corner, and its
          // twin in the glass's `behind` slot at the same place. Softened out
          // here too since the table polish (24 Sep 2026): a hard edge is what
          // made the colour read as a disc rather than as light.
          if (orbCorner != OrbCorner.contained)
            Positioned.fromRect(
              rect: orb,
              child: IgnorePointer(
                child: GlassOrb(
                  colours: colours,
                  size: orb.width,
                  soft: true,
                  opacity: TableAmbient.orbOutside(theme.brightness),
                ),
              ),
            ),
          panel,
        ],
      ),
    );
  }

  /// The balance, recessed into the plaque rather than raised off it — it is
  /// reference, not the loudest thing on a resting seat.
  Widget _stackPill(BuildContext context, Seat s) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final known = s.chips != null;
    final type = TableType.seat(theme, width);

    return Container(
      width: double.infinity,
      // Slimmer than it was: only the viewer still carries a pill (the rim
      // seats' figures are withheld on a blind table and the pill went with
      // them), and one plaque at the bottom of the screen does not need the
      // weight it had when five of them ringed the table.
      padding: EdgeInsets.symmetric(
        vertical: width * 0.010,
        horizontal: width * 0.040,
      ),
      decoration: BoxDecoration(
        // Two stops rather than one: the darker top edge is what reads as a
        // well cut into the plaque, since Flutter has no inset shadow.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? [
                  AppTheme.ink900.withValues(alpha: 0.62),
                  AppTheme.ink900.withValues(alpha: 0.42),
                ]
              : [
                  AppTheme.bone300.withValues(alpha: 0.90),
                  AppTheme.bone300.withValues(alpha: 0.55),
                ],
        ),
        borderRadius: BorderRadius.circular(width * 0.075),
        border: Border.all(color: AppTheme.hairlineColour(theme.brightness)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          // On a blind table another player's stack was never sent, so show it
          // as withheld rather than as zero.
          known ? formatChips(s.chips!) : '•••',
          textAlign: TextAlign.center,
          style: known
              ? type.stack(
                  colour: dark ? AppTheme.goldBright : AppTheme.goldDeep,
                )
              : type
                    .stack(
                      colour: theme.colorScheme.onSurface.withValues(
                        alpha: AppTheme.inkLow,
                      ),
                    )
                    .copyWith(letterSpacing: width * 0.02),
        ),
      ),
    );
  }

  Widget _cards(BuildContext context, Strings t, Seat s) {
    final dim = s.status == SeatState.packed || s.status == SeatState.lost;
    final show = revealed;
    // At a showdown the pod draws the real hand and the card flips where it
    // sits. How many cards is the server's to say — `cardCount`, three on
    // every table but a 5-Card hand's five — and a reveal that carries more
    // than the seat was last said to hold is believed, so a five-card hand is
    // never shown as its first three. Never past five: that is all the fan has
    // room for, and all the server deals.
    final count = math.min(
      5,
      show != null && show.length > s.cardCount ? show.length : s.cardCount,
    );
    final cardH = width * 0.42;
    // The three that count, once there are more than three to choose from.
    final picking =
        show != null &&
        show.length > 3 &&
        best.isNotEmpty &&
        best.length < show.length;

    // The faces shown: the hand as it was counted when the server said how
    // (a wild card as the card it stood for), else the cards as dealt.
    final faces = show != null && playsAs.length == show.length
        ? playsAs
        : show;
    Widget card(int i) =>
        // A foreground edge on the card's own box, so a wild card takes no
        // more room than any other: the column must not move at the reveal.
        WildEdge(
          wild: show != null && i < show.length && wild.contains(show[i]),
          cardHeight: cardH,
          label: t.wildCard,
          child: PlayingCard(
            height: cardH,
            dimmed: dim,
            code: faces != null && i < faces.length ? faces[i] : null,
            // A hand turned over at a showdown or a sideshow turns one card
            // after another, left to right, as the viewer's own does.
            flipDelay: PlayingCard.flipStagger * i,
            // Green backs say this player has looked at their hand, which is
            // the one thing about an opponent that changes how you bet. Not
            // while they are out of it: a packed seat's cards are history.
            // Never at poker, where every hand is looked at.
            tint: !poker && !s.isBlind && _inHand(s)
                ? AppTheme.cardSeenBack
                : null,
          ),
        );

    final Widget fan;
    if (count <= 3) {
      fan = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [for (var i = 0; i < count; i++) card(i)],
      );
    } else {
      // Four or five cards in the width three take (owner, 18 Sep 2026): the
      // pod's column is as wide as the pod and three cards already fill nine
      // tenths of it, so a longer hand overlaps instead of spreading. Each
      // card after the first shows its left half — a step of 0.15 of the pod,
      // against an index 0.11 wide — which is the half its rank and suit are
      // printed in. The same height as the row of three, so the column is the
      // same height whatever the hand, face down and face up alike.
      final cardW = cardH * PlayingCard.aspect;
      final step = 2 * cardW / (count - 1);
      fan = SizedBox(
        width: 3 * cardW,
        height: cardH,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < count; i++)
              Positioned(
                left: i * step,
                top: 0,
                // The two that do not count step back where they stand; the
                // three that do are simply left as they are. Nothing rises:
                // there is a pod above this fan and a badge below it.
                child: SetBack(
                  setBack:
                      picking && i < show.length && !best.contains(show[i]),
                  cardHeight: cardH,
                  child: card(i),
                ),
              ),
          ],
        ),
      );
    }

    // BLIND / SEEN rides on the hand it describes, and only while there is a
    // hand to describe: face-up cards at a showdown or a sideshow peek are the
    // answer to the same question, and a capsule over them would be covering
    // the very thing the player leaned in to read.
    //
    // What the revealed hand is called rides on it too, across the foot of
    // the fan where it covers the least of each card — not as a line of its
    // own above the cards, which made the column taller at the reveal and
    // moved the seat (see `below` in build). Not on the winner: their ribbon
    // already carries the ranking, and the same words twice read as a glitch.
    if (show != null || !_inHand(s)) {
      final name = revealedHand;
      if (name == null || s.status == SeatState.won) return fan;
      return Stack(
        alignment: Alignment.bottomCenter,
        clipBehavior: Clip.none,
        children: [
          fan,
          Padding(
            padding: EdgeInsets.only(bottom: width * 0.03),
            child: _handName(context, name),
          ),
        ],
      );
    }

    // A poker hand is neither blind nor seen: the backs alone.
    if (poker) return fan;

    return Stack(
      alignment: Alignment.center,
      children: [fan, _category(context, t, s)],
    );
  }

  /// Whether this seat is playing blind, laid over their cards.
  ///
  /// It used to be the first word of the badge under the pod. Moved here it
  /// says the same thing about the same object while the badge is left to be
  /// what it always mostly was — a chip and a figure.
  Widget _category(BuildContext context, Strings t, Seat s) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = dark ? AppTheme.boneInk : AppTheme.inkOnLight;
    // SEEN is written in the same green their cards have turned, so the word
    // and the backs under it are one signal rather than two. BLIND keeps the
    // quiet ink: green here means exactly one thing, and saying it of both
    // would mean nothing.
    final seen = !s.isBlind;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.055,
        vertical: width * 0.018,
      ),
      decoration: BoxDecoration(
        // The badge's own capsule, at the badge's own size: the two carry one
        // seat's state between them and should not read as two materials.
        color: AppTheme.plaque(theme.brightness).withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(width * _kCapsule),
        border: Border.all(color: AppTheme.hairlineColour(theme.brightness)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          seen ? t.seen : t.blind,
          maxLines: 1,
          style: TableType.seat(theme, width).tag(
            colour: seen
                ? AppTheme.seenInk(theme.brightness)
                : ink.withValues(alpha: AppTheme.inkMed),
            strong: seen,
          ),
        ),
      ),
    );
  }

  /// The hand's name, on the foot of the revealed cards, at a showdown — or
  /// on the hand that won a sideshow (the loser's cards turn over with no
  /// name).
  ///
  /// In the BLIND / SEEN capsule's own plaque, because it now lies over white
  /// card faces rather than the cloth. Champagne on the dark plaque, deep gold
  /// on the pale one.
  Widget _handName(BuildContext context, String name) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.055,
        vertical: width * 0.018,
      ),
      decoration: BoxDecoration(
        color: AppTheme.plaque(theme.brightness).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(width * _kCapsule),
        border: Border.all(color: AppTheme.hairlineColour(theme.brightness)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          name,
          maxLines: 1,
          style: TableType.seat(
            theme,
            width,
          ).handName(colour: dark ? AppTheme.goldBright : AppTheme.goldDeep),
        ),
      ),
    );
  }

  /// What this player just put in. The chip makes it read as money from across
  /// the table, where a bare number does not.
  static Widget _lastBet(
    BuildContext context,
    Strings t,
    Seat s,
    double width, {
    required bool withCategory,
    bool poker = false,
  }) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final label = s.isBlind ? t.blind : t.seen;
    final type = TableType.seat(theme, width);
    final ink = dark ? AppTheme.boneInk : AppTheme.inkOnLight;
    // A poker badge carries this street's bet; a Teen Patti one the last
    // move's. Its chip is gold: there is no blind or seen to colour it by.
    final figure = poker ? s.streetBet : s.lastBet;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.07,
        vertical: width * 0.025,
      ),
      decoration: BoxDecoration(
        // The plaque's own material, so the seat and its bet read as one
        // object. It used to be `secondaryContainer` — a muddy olive capsule,
        // and the most frequently visible thing on a rim seat during a hand.
        color: AppTheme.plaque(theme.brightness),
        borderRadius: BorderRadius.circular(width * _kCapsule),
        border: Border.all(color: AppTheme.hairlineColour(theme.brightness)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PokerChip(
            colour: poker
                ? AppTheme.gold
                : s.isBlind
                ? theme.colorScheme.tertiary
                : theme.colorScheme.secondary,
            size: width * 0.14,
          ),
          SizedBox(width: width * 0.05),
          // The figure slides up as it changes, so a raise is something the
          // table sees happen rather than a number that was always there.
          // It shrinks to the pod when the figure runs to lakhs or crores.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                transitionBuilder: (child, anim) => SlideTransition(
                  position: Tween(
                    begin: const Offset(0, 0.6),
                    end: Offset.zero,
                  ).animate(anim),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: Row(
                  key: ValueKey('$figure-${s.isBlind}'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Two styles rather than one string: the label is
                    // translated and stays in its natural case, the figure is
                    // money and gets tabular digits so it does not jitter as
                    // it counts.
                    if (withCategory)
                      Text(
                        label,
                        maxLines: 1,
                        style: type.bet(
                          colour: ink.withValues(alpha: AppTheme.inkMed),
                          figure: false,
                        ),
                      ),
                    if (figure > 0) ...[
                      if (withCategory) SizedBox(width: width * 0.04),
                      Text(
                        formatChips(figure),
                        maxLines: 1,
                        style: type.bet(colour: ink),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A seat nobody is in.
  ///
  /// It used to be nothing at all — a zero-height box — so a player leaving
  /// made the table silently rearrange itself around the hole, and the seat
  /// they had been in stopped existing. A chair that stays put says the table
  /// has five places and one of them is free, which is both true and what a
  /// player expects to see: the same shape comes back with a face in it when
  /// somebody sits down.
  ///
  /// No name, because there is nobody to name. Quiet enough that five empty
  /// chairs never compete with one occupied one.
  Widget _emptySeat(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: width,
      child: Container(
        height: width * 0.86,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.plaque(theme.brightness).withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(width * _kRadius),
          border: Border.all(
            color: AppTheme.hairlineColour(theme.brightness, live: false),
          ),
        ),
        child: Icon(
          Icons.chair_alt_outlined,
          size: width * 0.34,
          color: AppTheme.onTable(theme.colorScheme).withValues(alpha: 0.22),
        ),
      ),
    );
  }

  /// Everything they are in for this hand.
  static Widget _total(BuildContext context, Strings t, Seat s, double width) {
    final theme = Theme.of(context);
    final type = TableType.seat(theme, width);

    return TweenAnimationBuilder<double>(
      tween: Tween(end: s.contributed.toDouble()),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => FittedBox(
        fit: BoxFit.scaleDown,
        // A plaque of its own, quieter than the badge beneath it: the same
        // material, lighter, no border, tighter corners. Enough to read as a
        // chip of information rather than loose text on the ground, not
        // enough to argue with the badge for which of the two is the
        // headline — its words are the seat's quietest ([SeatType.inPot]).
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.055,
            vertical: width * 0.018,
          ),
          decoration: BoxDecoration(
            color: AppTheme.plaque(
              theme.brightness,
            ).withValues(alpha: SeatType.inPotPlate),
            borderRadius: BorderRadius.circular(width * _kCapsule),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.inPot, maxLines: 1, style: type.inPot()),
              SizedBox(width: width * 0.035),
              Text(
                formatChips(value.round()),
                maxLines: 1,
                style: type.inPot(figure: true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A dot and a word. The dot carries the state at pod scale, where six
  /// characters of Bengali do not.
  Widget _statusTag(BuildContext context, Seat s, String text) {
    final theme = Theme.of(context);
    final tone = !s.connected
        ? theme.colorScheme.error
        : switch (s.status) {
            SeatState.won => AppTheme.gold,
            SeatState.waiting => AppTheme.amber,
            // Also on the cloth, so also felt ink rather than surface ink. At
            // full strength: this is the line that says why the seat is
            // faded, and the fade already takes it down to the quiet tier.
            _ => AppTheme.onTable(theme.colorScheme, alpha: AppTheme.inkHigh),
          };

    return SizedBox(
      width: width,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(shape: BoxShape.circle, color: tone),
            ),
            SizedBox(width: width * 0.045),
            // Translated, so natural case: the tracked-capitals treatment is
            // for the fixed Latin strings only.
            Text(
              text,
              maxLines: 1,
              style: TableType.seat(theme, width).status(colour: tone),
            ),
          ],
        ),
      ),
    );
  }

  bool _inHand(Seat s) =>
      handLive && (s.status == SeatState.active || s.status == SeatState.won);

  /// Whether the bet badge hangs under this seat: while it is in the hand,
  /// and — unlike [_inHand] — still after it has lost a showdown, for as long
  /// as the finished hand is on show. Taking a beaten player's badge away at
  /// the reveal shortened their column and moved their seat.
  bool _betShown(Seat s) =>
      handLive &&
      (s.status == SeatState.active ||
          s.status == SeatState.won ||
          s.status == SeatState.lost);

  String? _status(Strings t, Seat s) {
    if (!s.connected) return t.offline;
    return switch (s.status) {
      // A poker player folds; a Teen Patti player packs.
      SeatState.packed => poker ? t.fold : t.pack,
      SeatState.won => t.winner,
      SeatState.waiting => t.waiting,
      _ => null,
    };
  }
}

/// ALL-IN across the foot of a poker seat whose whole stack is in the pot.
/// It lies over the stack pill, which reads 0 for exactly that player, in the
/// amber the app keeps for "committed, not yet decided".
class _AllInRibbon extends StatelessWidget {
  const _AllInRibbon({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.read<GameState>().t;
    return Container(
      padding: EdgeInsets.symmetric(
        vertical: width * 0.012,
        horizontal: width * 0.04,
      ),
      decoration: BoxDecoration(
        color: AppTheme.ink900.withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(width * 0.075),
        border: Border.all(color: AppTheme.amber.withValues(alpha: 0.75)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          t.allIn,
          maxLines: 1,
          // The stack pill's size, since it lies over the pill.
          style: TableType.seat(
            theme,
            width,
          ).stack(colour: AppTheme.amber).copyWith(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

/// The dealer's button, the one literal casino object on the pod.
class _DealerButton extends StatelessWidget {
  const _DealerButton({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          center: Alignment(-0.4, -0.4),
          colors: [Color(0xFFFFFBF0), Color(0xFFE6DCC4)],
        ),
        border: Border.all(color: AppTheme.goldDeep.withValues(alpha: 0.55)),
        boxShadow: [
          BoxShadow(
            color: AppTheme.ink900.withValues(alpha: 0.35),
            blurRadius: 1.5,
            offset: Offset(0, size * 0.06),
          ),
        ],
      ),
      child: Text('D', style: TableType.dealerMark(size)),
    );
  }
}

/// The pod of whoever is to act wears a ring of light.
///
/// It is a halo around the pod rather than only a change of border colour:
/// from across the table the glow is what carries, and every player needs to
/// see whose turn it is at a glance, not only the player whose turn it is.
///
/// Only the alpha breathes. The blur radii and spreads are frozen, because a
/// shadow's blur mask is cached by its geometry: the old version animated
/// `blurRadius 10->20` and `26->48` with a growing spread, which regenerated
/// two masks per pod per frame and was the single most expensive item on the
/// felt. Frozen geometry also makes the cue calmer — it pulses rather than
/// throbbing outwards.
class _TurnRing extends StatefulWidget {
  const _TurnRing({
    required this.active,
    required this.colour,
    required this.radius,
    required this.child,
    this.edge,
    this.glow = 1,
  });

  final bool active;

  /// The halo's colour — and the edge's, unless [edge] says otherwise.
  final Color colour;

  /// The ring's hard edge, where it must read against a pale ground that the
  /// halo's champagne does not (the light theme); null is [colour].
  final Color? edge;
  final double radius;
  final Widget child;

  /// How strong the halo round the ring is: 1 at a rim seat, less on the
  /// viewer's own pod ([TableAmbient.mineGlow]). The ring's edge is the same
  /// for everyone.
  final double glow;

  @override
  State<_TurnRing> createState() => _TurnRingState();
}

class _TurnRingState extends State<_TurnRing>
    with SingleTickerProviderStateMixin {
  /// Nullable, and deliberately not `late final`.
  ///
  /// Only the seat on turn blinks, so four of the five pods on a table never
  /// build a controller at all — `build` returns early and never reads this.
  /// That is the point of creating it on demand, and it is also the trap: with
  /// `late final AnimationController _c = AnimationController(…)`, the
  /// `_c.dispose()` in `dispose()` *runs the initialiser* for every pod that
  /// never blinked. Constructing an AnimationController needs a TickerMode
  /// lookup, that lookup is illegal on a deactivated element, and the throw
  /// lands in the middle of `_InactiveElements._unmount` — so the tree stops
  /// being finalised half-way and the failure surfaces later as a duplicate
  /// GlobalKey and an `_ElementLifecycle` assertion, nowhere near this widget.
  /// Every table teardown hit it. Keep the null check.
  AnimationController? _c;

  /// Turn timing, not chrome timing: it is read against a 25-second clock, so
  /// it stays out of [Motion]. 780ms until the table polish (24 Sep 2026),
  /// when it read as a flicker; one slower breath is still a pulse.
  AnimationController get _blink =>
      _c ??= AnimationController(vsync: this, duration: TableAmbient.turnBreath)
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;

    final blink = _blink;
    final floor = TableAmbient.turnEdgeFloor(Theme.of(context).brightness);
    return AnimatedBuilder(
      animation: blink,
      builder: (context, child) {
        final t = Motion.breathe.transform(blink.value);
        // Whose turn it is has to be answerable at a glance from across a
        // five-seat table, so this is the one ring the felt draws: a bright
        // edge OUTSIDE the plaque, brightening and dimming, over a halo that
        // breathes with it. The ring is what carries the signal — a glow alone
        // reads as decoration and gets lost against a lit pod, while a hard
        // edge that brightens is unmistakable.
        //
        // Its box is still (table polish, 24 Sep 2026): the gap round the
        // plaque used to grow and shrink with the breath, which re-laid the
        // seat's whole column every frame and nudged the pod up and down by a
        // pixel and a half. Only the edge's alpha and weight, and the halo's
        // alpha, move now — and less far, so the ring pulses rather than
        // throbs beside the key the player is about to press.
        return Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius + 4),
            border: Border.all(
              color: (widget.edge ?? widget.colour).withValues(
                alpha: floor + (1 - floor) * t,
              ),
              width: 2.0 + 0.5 * t,
            ),
            boxShadow: [
              BoxShadow(
                color: widget.colour.withValues(
                  alpha: (0.26 + 0.26 * t) * widget.glow,
                ),
                blurRadius: 14,
                spreadRadius: 1,
              ),
              BoxShadow(
                color: widget.colour.withValues(
                  alpha: (0.10 + 0.16 * t) * widget.glow,
                ),
                blurRadius: 30,
                spreadRadius: 4,
              ),
            ],
          ),
          child: child,
        );
      },
      // The plaque is rasterised once and composited under the breathing
      // shadows; without this it repaints with them.
      child: RepaintBoundary(child: widget.child),
    );
  }
}

/// A speech bubble over a seat, shown for a moment after that player speaks.
/// Which edge of a bubble its pointer is measured from — the pod it belongs
/// to is half a pod-width in from that edge.
enum _TailFrom { left, right, centre }

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.width,
    required this.maxWidth,
    required this.tailUp,
    required this.tailFrom,
  });

  final String text;

  /// The pod's width, which every measurement here is taken from — including
  /// where the tail points, since the pod is centred half its own width in
  /// from whichever edge the bubble is anchored by.
  final double width;

  /// The ceiling the OverflowBox above is using. Passed rather than recomputed,
  /// because the two used to disagree.
  final double maxWidth;

  /// Whether the pointer is on the top edge (aimed up at a pod above) or the
  /// bottom edge (aimed down at a pod below).
  final bool tailUp;
  final _TailFrom tailFrom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // Charcoal in both themes. The bubble hangs over emerald baize, which is a
    // physical surface and not scheme-derived, so a parchment bubble in light
    // mode would be the one element on the felt that is not lit like the rest.
    // It used to be `inverseSurface`: a near-white slab on green in dark mode.
    final fill = AppTheme.ink900.withValues(alpha: 0.82);
    final stroke = AppTheme.goldBright.withValues(alpha: 0.20);
    final reach = width * 0.08;

    return TweenAnimationBuilder<double>(
      // Keyed on the text, so a second line queued behind the first replays the
      // pop instead of swapping in silently.
      key: ValueKey(text),
      tween: Tween(begin: 0, end: 1),
      duration: Motion.base,
      curve: Motion.settle,
      builder: (context, v, child) => Transform.scale(
        scale: 0.6 + 0.4 * v,
        alignment: tailUp ? Alignment.topCenter : Alignment.bottomCenter,
        child: Opacity(opacity: v.clamp(0, 1), child: child),
      ),
      child: CustomPaint(
        // Body and tail are one path, filled once and stroked once. Drawn as
        // two overlapping shapes the translucent fills would double to a dark
        // wedge at the junction and the two hairlines would cross, ruling a
        // line through the bubble.
        painter: _BubbleSkin(
          fill: fill,
          stroke: stroke,
          shadow: AppTheme.ink900.withValues(alpha: dark ? 0.45 : 0.28),
          radius: width * 0.11,
          podWidth: width,
          tailBase: width * 0.17,
          reach: reach,
          tailUp: tailUp,
          tailFrom: tailFrom,
          blur: width * 0.10,
          dy: width * 0.035,
        ),
        child: Container(
          constraints: BoxConstraints(maxWidth: maxWidth),
          padding: EdgeInsets.only(
            top: (tailUp ? reach : 0) + width * 0.05,
            bottom: (tailUp ? 0 : reach) + width * 0.05,
            left: width * 0.09,
            right: width * 0.09,
          ),
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            // Chat is the one thing on the felt a player actually reads, as
            // opposed to glances at, so its role has a floor above the status
            // captions around it ([SeatType.speech]).
            style: TableType.seat(
              theme,
              width,
            ).speech(colour: AppTheme.boneInk.withValues(alpha: 0.94)),
          ),
        ),
      ),
    );
  }
}

class _BubbleSkin extends CustomPainter {
  const _BubbleSkin({
    required this.fill,
    required this.stroke,
    required this.shadow,
    required this.radius,
    required this.podWidth,
    required this.tailBase,
    required this.reach,
    required this.tailUp,
    required this.tailFrom,
    required this.blur,
    required this.dy,
  });

  final Color fill;
  final Color stroke;
  final Color shadow;
  final double radius;
  final double podWidth;
  final double tailBase;
  final double reach;
  final bool tailUp;
  final _TailFrom tailFrom;
  final double blur;
  final double dy;

  @override
  void paint(Canvas canvas, Size size) {
    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        0,
        tailUp ? reach : 0,
        size.width,
        math.max(0, size.height - reach),
      ),
      Radius.circular(radius),
    );

    // The pod sits half its own width in from whichever edge anchors the
    // bubble, so that is where the pointer aims.
    final centre = switch (tailFrom) {
      _TailFrom.centre => size.width / 2,
      _TailFrom.left => podWidth / 2,
      _TailFrom.right => size.width - podWidth / 2,
    };
    final half = tailBase / 2;
    final base = tailUp ? reach : size.height - reach;
    final tip = tailUp ? 0.0 : size.height;

    final path = Path.combine(
      PathOperation.union,
      Path()..addRRect(body),
      Path()..addPolygon([
        Offset(centre - half, base),
        Offset(centre, tip),
        Offset(centre + half, base),
      ], true),
    );

    canvas.drawPath(
      path.shift(Offset(0, dy)),
      Paint()
        ..color = shadow
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
    );
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = Dim.hairline
        ..color = stroke,
    );
  }

  @override
  bool shouldRepaint(_BubbleSkin old) =>
      old.fill != fill ||
      old.stroke != stroke ||
      old.shadow != shadow ||
      old.radius != radius ||
      old.podWidth != podWidth ||
      old.tailBase != tailBase ||
      old.reach != reach ||
      old.tailUp != tailUp ||
      old.tailFrom != tailFrom ||
      old.blur != blur ||
      old.dy != dy;
}

/// A seat's BLIND/SEEN badge and what it has put in this hand.
///
/// Lives outside [SeatPod] because the viewer's copy is not in their pod: it
/// is drawn over their own cards, where there is room and where they are
/// already looking. Everyone else's sits under their pod as before, and both
/// go through here so the two can never drift apart.
/// A player's name across the head of their pod, whole wherever it can be
/// (owner's brief, 25 Sep 2026: "Never allow: player names to clip"). A name
/// a little wider than its pod is set a little smaller — down to [minScale]
/// of its size — rather than cut: "Vikramaditya" read "Vikramad…" at 640x360
/// with text at x1.25, and is whole now at every phone size. Only a name that
/// would need smaller still (a 24-letter one) ends in an ellipsis, at that
/// size.
class SeatName extends StatelessWidget {
  const SeatName(this.name, {super.key, required this.style});

  final String name;
  final TextStyle style;

  /// The smallest a name is set before it is cut instead.
  static const double minScale = 0.78;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final painter = TextPainter(
          text: TextSpan(text: name, style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final natural = painter.width;
        painter.dispose();
        final room = box.maxWidth;
        final scale = !room.isFinite || natural <= room
            ? 1.0
            : math.max(minScale, room / natural * 0.98);
        return Text(
          name,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(fontSize: (style.fontSize ?? 14) * scale),
        );
      },
    );
  }
}

class SeatBet extends StatelessWidget {
  const SeatBet({
    super.key,
    required this.seat,
    required this.width,
    this.totalFirst = false,
    this.withCategory = true,
    this.poker = false,
  });

  final Seat seat;

  /// A poker seat's badge: this street's bet on a gold chip, and never the
  /// word BLIND or SEEN (see [SeatPod.poker]).
  final bool poker;

  /// Whether "In Pot" sits above the badge rather than below it.
  ///
  /// True only for the viewer, whose copy hangs over their own cards: there
  /// the badge is the line they act on, so it wants to be nearest the hand.
  /// A rim seat's copy hangs under their pod, where the reverse is true —
  /// the badge belongs against the pod it describes.
  final bool totalFirst;

  /// The pod width the figures are scaled against, so the viewer's badge is
  /// the same size as everybody else's rather than sized to its new home.
  final double width;

  /// Whether the badge still opens with the word BLIND or SEEN.
  ///
  /// True for the viewer only. A rim seat wears that word over its cards
  /// instead (owner's decision, 11 Sep 2026), which leaves the badge under the
  /// pod as a chip and a figure — the two things a player is counting when
  /// they look across the table.
  final bool withCategory;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<GameState>().t;

    final gap = SizedBox(height: width * _kPad * 0.5);
    final total = seat.contributed > 0
        ? SeatPod._total(context, t, seat, width)
        : null;
    // Without the word, a seat that has not bet yet would leave a capsule
    // holding one chip and nothing else — an empty box rather than a fact.
    // The word was carrying it; now the figure has to, and until there is one
    // the badge stands down and `In Pot` speaks for the seat.
    final figure = poker ? seat.streetBet : seat.lastBet;
    final badge = (withCategory && !poker) || figure > 0
        ? SeatPod._lastBet(
            context,
            t,
            seat,
            width,
            withCategory: withCategory && !poker,
            poker: poker,
          )
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: totalFirst
          ? [
              if (total != null) ...[total, if (badge != null) gap],
              ?badge,
            ]
          : [
              if (badge != null) ...[badge, if (total != null) gap],
              ?total,
            ],
    );
  }
}

/// WINNER, struck across the pod of whoever just took the pot.
///
/// This replaced a banner across the middle of the table. A banner had to name
/// the winner because it was nowhere near them; sitting on their pod says who
/// by position, which is faster to read and covers nothing a player wants to
/// look at.
///
/// It arrives rather than appears: a hard scale-down from oversized onto the
/// pod, the way a stamp lands, then a slow shine that keeps it alive for the
/// few seconds it is up. Both run once per hand — the widget is rebuilt with
/// the seat, so a new winner gets a new strike.
class _WinnerFlash extends StatefulWidget {
  const _WinnerFlash({required this.width, this.hand});

  final double width;

  /// What they won with — "Pair", "Colour", "Run". Null when the hand ended
  /// without a showdown because everyone else packed: there is no winning hand
  /// to name then, only a last player standing.
  final String? hand;

  @override
  State<_WinnerFlash> createState() => _WinnerFlashState();
}

class _WinnerFlashState extends State<_WinnerFlash>
    with TickerProviderStateMixin {
  late final AnimationController _strike = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  )..forward();

  late final AnimationController _shine = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  )..repeat();

  @override
  void dispose() {
    _strike.dispose();
    _shine.dispose();
    super.dispose();
  }

  /// Both lines of the strike share a treatment: the shader paints them, so
  /// the colour here only has to be opaque, and the shadow is what lifts them
  /// off whatever the pod is showing underneath. [AppTheme.boneInk] rather than
  /// a scheme ink: the ribbon is charcoal in both themes, so its type is the
  /// on-obsidian ink in both — the same reason the chat bubble's text is.
  TextStyle _struck(
    BuildContext context,
    double w, {
    required bool big,
    required FontWeight weight,
  }) => TableType.seat(Theme.of(context), w)
      .winner(big: big, weight: weight)
      .copyWith(
        shadows: [
          Shadow(
            color: AppTheme.ink900.withValues(alpha: 0.55),
            blurRadius: w * 0.06,
            offset: Offset(0, w * 0.012),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final w = widget.width;

    return AnimatedBuilder(
      animation: Listenable.merge([_strike, _shine]),
      builder: (context, _) {
        final t = Curves.easeOutBack.transform(_strike.value.clamp(0.0, 1.0));
        // From oversized down onto the pod, so it reads as landing rather than
        // as growing — but only just oversized. At 2.1x the strike was half a
        // pod tall before it settled, and on the top row that overshoot went
        // straight off the top of the screen: the word and the hand under it
        // were cut for the first third of a second, which is exactly the part
        // a player looks at.
        final scale = 1.32 - 0.32 * t;
        final fade = Curves.easeOut.transform(
          (_strike.value * 2.2).clamp(0.0, 1.0),
        );
        final shine = _shine.value;

        return Opacity(
          opacity: fade,
          child: Transform.scale(
            scale: scale,
            child: Center(
              child: Container(
                // A solid ribbon, not bare text. Gold letters sat directly on
                // the pod were gold on a pale plaque over a photograph, which
                // is three light things in a row — the word was there and
                // could not be read, and the ranking under it disappeared
                // altogether. Ink behind them is what makes both legible on
                // any avatar anybody ever picks.
                padding: EdgeInsets.symmetric(
                  horizontal: w * 0.09,
                  vertical: w * 0.045,
                ),
                margin: EdgeInsets.symmetric(horizontal: w * 0.04),
                decoration: BoxDecoration(
                  color: AppTheme.ink900.withValues(alpha: 0.88),
                  borderRadius: BorderRadius.circular(w * 0.06),
                  border: Border.all(
                    color: AppTheme.goldBright.withValues(alpha: 0.55),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.goldBright.withValues(alpha: 0.30 * fade),
                      blurRadius: w * 0.16,
                      spreadRadius: w * 0.01,
                    ),
                  ],
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ShaderMask(
                        blendMode: BlendMode.srcIn,
                        shaderCallback: (rect) => LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: const [
                            AppTheme.goldDeep,
                            AppTheme.boneInk,
                            AppTheme.goldBright,
                          ],
                          stops: [
                            (shine - 0.28).clamp(0.0, 1.0),
                            shine.clamp(0.0, 1.0),
                            (shine + 0.28).clamp(0.0, 1.0),
                          ],
                        ).createShader(rect),
                        child: Text(
                          'WINNER',
                          maxLines: 1,
                          style: _struck(
                            context,
                            w,
                            big: true,
                            weight: FontWeight.w900,
                          ),
                        ),
                      ),
                      // What they won with. On the ribbon rather than beside
                      // it, so it cannot end up over a face on its own.
                      if (widget.hand != null)
                        Text(
                          widget.hand!,
                          maxLines: 1,
                          style: _struck(
                            context,
                            w,
                            big: false,
                            weight: FontWeight.w700,
                          ).copyWith(color: AppTheme.bone100),
                        ),
                    ],
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
