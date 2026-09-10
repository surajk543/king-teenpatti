import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'avatar.dart';
import 'liquid_fill.dart';
import 'playing_card.dart';
import 'poker_chip.dart';
import 'premium_surface.dart';

/// Every proportion in the pod, named once.
///
/// A pod is the one thing in the app that has to work from 56dp to 148dp, so
/// each figure is a fraction of [SeatPod.width] rather than a dp — but the type
/// sizes carry a floor, because a fraction that stays legible at 90 is 5px at
/// 56 and unreadable in any of the five languages.
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
const double _kName = 0.125;
const double _kNameFloor = 10.0;
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
const double _kStack = 0.125;

/// The BLIND / SEEN badge, which used to share [_kStack] with the chips pill.
/// They are not the same job: the pill is the viewer's own balance, glanced at
/// occasionally, while the badge is how everyone reads what the other players
/// are doing all hand long. Shrinking one should not shrink the other, and
/// before this constant existed it did.
const double _kBadge = 0.105;
const double _kBadgeFloor = 10.0;

/// What a seat has put in this hand. Deliberately a step smaller than
/// [_kBadge]: the badge carries the decision (blind or seen, and for how
/// much), the total is context for it, and when the two sit together the
/// headline should be obvious without reading either.
const double _kInPot = 0.086;
const double _kInPotFloor = 9.0;
const double _kStackFloor = 11.5;
const double _kStatus = 0.095;
const double _kStatusFloor = 9.0;

/// Chat is read rather than glanced at, so it gets a larger floor than the
/// captions do.
const double _kBubbleFloor = 12.0;

/// How far a seat fades once it is out of the hand — packed, lost, or waiting
/// for the next deal. Low enough to read as "not playing", high enough that
/// the name and the picture are still legible: a seat you cannot see is a
/// seat you forget is sitting there, and they are still at the table.
const double _kAsideOpacity = 0.45;

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
    this.saying,
    this.bubbleSide = BubbleSide.above,
    this.reversed = false,
  });

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

    final gap = width * _kPad;
    final status = _status(t, s);
    final below = <Widget>[
      if (s.cardCount > 0 && !isMe) ...[
        SizedBox(height: gap),
        // Above the cards, not under them. At a showdown the eye lands on the
        // hand first and reads the label second, and a label underneath sat
        // between one seat's cards and the next seat's pod — which is the one
        // place on a crowded table it could be mistaken for either.
        if (revealedHand != null) _handName(context, revealedHand!),
        _cards(s),
      ],
      // The viewer's badge and total are not in their column: they are drawn
      // over their own cards instead (see _Felt). Their pod stands on the
      // floor beside a fanned hand, so a stack under it grows towards the
      // screen edge, while the space above the cards is empty and is where
      // their eye already is.
      if (_inHand(s) && !isMe) ...[
        SizedBox(height: gap),
        SeatBet(seat: s, width: width),
      ] else if (status != null) ...[
        SizedBox(height: gap),
        _statusTag(context, s, status),
      ],
    ];

    final column = <Widget>[_pod(context, s, beat), ...below];

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
    final aside =
        s.status != SeatState.won &&
        (s.status == SeatState.packed ||
            s.status == SeatState.waiting ||
            s.status == SeatState.lost);

    return RepaintBoundary(
      child: AnimatedOpacity(
        opacity: aside ? _kAsideOpacity : 1,
        duration: Motion.base,
        curve: Curves.easeOut,
        child: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [...(reversed ? ordered.reversed.toList() : ordered)],
          ),
        ),
      ),
    );
  }

  Widget _pod(BuildContext context, Seat s, Color beat) {
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

    final nameSize = math.max(_kNameFloor, width * _kName);

    return _TurnRing(
      active: onTurn,
      colour: beat,
      radius: width * _kRadius,
      child: PremiumSurface(
        accent: accent,
        radius: width * _kRadius,
        borderWidth: won
            ? 2.4
            : onTurn
            ? 2.0
            : 1.0,
        tint: won
            ? 0.20
            : onTurn
            ? 0.16
            : 0.06,
        bloom: won
            ? 0.28
            : onTurn
            ? 0.10
            : 0,
        bevel: 2,
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
                        child: Text(
                          isMe ? 'YOU' : s.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          // 'YOU' is a fixed Latin string the code owns, so it
                          // can be tracked capitals. A display name never can:
                          // toUpperCase() does nothing to Devanagari or
                          // Bengali, and tracked RAVI beside untracked मीरा is
                          // worse than either alone.
                          style: isMe
                              ? AppTheme.smallCaps(
                                  theme.textTheme.labelLarge!,
                                  fontSize: nameSize,
                                  tracking: 1.2,
                                  colour: dark
                                      ? AppTheme.goldBright
                                      : AppTheme.goldDeep,
                                )
                              : AppTheme.label(
                                  theme.textTheme.labelLarge!,
                                  fontSize: nameSize,
                                ),
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
                    // rather than borders.
                    ring: onTurn ? beat : null,
                    ringWidth: onTurn ? 2 : 1.5,
                  ),
                  if (knownStack) ...[
                    SizedBox(height: width * _kGap),
                    _stackPill(context, s),
                  ],
                ],
              ),
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
  }

  /// The balance, recessed into the plaque rather than raised off it — it is
  /// reference, not the loudest thing on a resting seat.
  Widget _stackPill(BuildContext context, Seat s) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final known = s.chips != null;

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
              ? AppTheme.money(
                  theme.textTheme.labelMedium!,
                  fontSize: math.max(_kStackFloor, width * _kStack),
                  colour: dark ? AppTheme.goldBright : AppTheme.goldDeep,
                )
              : theme.textTheme.labelMedium!.copyWith(
                  fontSize: math.max(_kStackFloor, width * _kStack),
                  letterSpacing: width * 0.02,
                  color: theme.colorScheme.onSurface.withValues(
                    alpha: AppTheme.inkLow,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _cards(Seat s) {
    final dim = s.status == SeatState.packed || s.status == SeatState.lost;
    final show = revealed;
    // At a showdown the pod draws the real hand and the card flips where it
    // sits. Guarded on length: cardCount is what the server says this seat
    // holds, and a reveal that disagrees is not something to index past.
    final count = show != null && show.length >= s.cardCount
        ? s.cardCount
        : s.cardCount;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          PlayingCard(
            height: width * 0.42,
            dimmed: dim,
            code: show != null && i < show.length ? show[i] : null,
          ),
      ],
    );
  }

  /// The hand's name, under the cards, at a showdown.
  Widget _handName(BuildContext context, String name) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: width * 0.04),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          name,
          maxLines: 1,
          style: AppTheme.smallCaps(
            theme.textTheme.labelSmall!,
            fontSize: math.max(_kStatusFloor, width * 0.095),
            colour: AppTheme.goldBright,
            weight: FontWeight.w800,
          ),
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
    double width,
  ) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final label = s.isBlind ? t.blind : t.seen;
    final size = math.max(_kBadgeFloor, width * _kBadge);
    final ink = dark ? AppTheme.boneInk : AppTheme.inkOnLight;

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
        borderRadius: BorderRadius.circular(width * 0.1),
        border: Border.all(color: AppTheme.hairlineColour(theme.brightness)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PokerChip(
            colour: s.isBlind
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
                  key: ValueKey('${s.lastBet}-${s.isBlind}'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Two styles rather than one string: the label is
                    // translated and stays in its natural case, the figure is
                    // money and gets tabular digits so it does not jitter as
                    // it counts.
                    Text(
                      label,
                      maxLines: 1,
                      style: AppTheme.label(
                        theme.textTheme.labelMedium!,
                        fontSize: size,
                        colour: ink.withValues(alpha: AppTheme.inkMed),
                      ),
                    ),
                    if (s.lastBet > 0) ...[
                      SizedBox(width: width * 0.04),
                      Text(
                        formatChips(s.lastBet),
                        maxLines: 1,
                        style: AppTheme.money(
                          theme.textTheme.labelMedium!,
                          fontSize: size,
                          colour: ink,
                        ),
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
    final size = math.max(_kInPotFloor, width * _kInPot);

    return TweenAnimationBuilder<double>(
      tween: Tween(end: s.contributed.toDouble()),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => FittedBox(
        fit: BoxFit.scaleDown,
        // A plaque of its own, a step quieter than the badge beneath it: same
        // material, no border, tighter corners. Enough to read as a chip of
        // information rather than loose text on the ground, not enough to
        // argue with the badge for which of the two is the headline.
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: width * 0.055,
            vertical: width * 0.018,
          ),
          decoration: BoxDecoration(
            color: AppTheme.plaque(theme.brightness).withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(width * 0.07),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                t.inPot,
                maxLines: 1,
                style: AppTheme.label(
                  theme.textTheme.labelSmall!,
                  fontSize: size,
                  colour: AppTheme.onTable(
                    theme.colorScheme,
                    alpha: AppTheme.inkLow,
                  ),
                ),
              ),
              SizedBox(width: width * 0.035),
              Text(
                formatChips(value.round()),
                maxLines: 1,
                style: AppTheme.money(
                  theme.textTheme.labelSmall!,
                  fontSize: size,
                  colour: AppTheme.onTable(theme.colorScheme),
                  weight: FontWeight.w600,
                ),
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
            // Also on the cloth, so also felt ink rather than surface ink.
            _ => AppTheme.onTable(theme.colorScheme),
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
              style: AppTheme.label(
                theme.textTheme.labelSmall!,
                fontSize: math.max(_kStatusFloor, width * _kStatus),
                colour: tone,
                weight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool _inHand(Seat s) =>
      handLive && (s.status == SeatState.active || s.status == SeatState.won);

  String? _status(Strings t, Seat s) {
    if (!s.connected) return t.offline;
    return switch (s.status) {
      SeatState.packed => t.pack,
      SeatState.won => t.winner,
      SeatState.waiting => t.waiting,
      _ => null,
    };
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
      child: Text(
        'D',
        style: TextStyle(
          fontSize: size * 0.52,
          height: 1,
          fontWeight: FontWeight.w700,
          color: const Color(0xFF6B5A33),
          // Debossed: the highlight sits half a pixel above the letter, which
          // is what makes it read as pressed into the disc.
          shadows: const [
            Shadow(color: Color(0x99FFFFFF), offset: Offset(0, -0.5)),
          ],
        ),
      ),
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
  });

  final bool active;
  final Color colour;
  final double radius;
  final Widget child;

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

  /// 780ms is turn timing, not chrome timing: it is read against a 25-second
  /// clock, so it stays out of [Motion].
  AnimationController get _blink => _c ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 780),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;

    final blink = _blink;
    return AnimatedBuilder(
      animation: blink,
      builder: (context, child) {
        final t = Motion.breathe.transform(blink.value);
        // Whose turn it is has to be answerable at a glance from across a
        // five-seat table, so this is the loudest thing the felt is allowed to
        // do: a bright ring drawn OUTSIDE the plaque, pulsing in width and
        // alpha, over a halo that breathes with it. The ring is what carries
        // the signal — a glow alone reads as decoration and gets lost against
        // a lit pod, while a hard edge that brightens is unmistakable.
        return Container(
          padding: EdgeInsets.all(2.5 + 1.5 * t),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius + 4),
            border: Border.all(
              color: widget.colour.withValues(alpha: 0.55 + 0.45 * t),
              width: 2.0 + 0.8 * t,
            ),
            boxShadow: [
              BoxShadow(
                color: widget.colour.withValues(alpha: 0.34 + 0.34 * t),
                blurRadius: 14,
                spreadRadius: 1,
              ),
              BoxShadow(
                color: widget.colour.withValues(alpha: 0.14 + 0.22 * t),
                blurRadius: 34,
                spreadRadius: 6,
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
            style: theme.textTheme.bodySmall!.copyWith(
              // Chat is the one thing on the felt a player actually reads, as
              // opposed to glances at, and it was set at the same size as the
              // status captions around it. Its own floor too: _kStatusFloor is
              // 9pt, which is fine for a word like "BLIND" and not fine for a
              // sentence somebody typed.
              fontSize: math.max(_kBubbleFloor, width * 0.135),
              height: 1.3,
              fontWeight: FontWeight.w500,
              color: AppTheme.boneInk.withValues(alpha: 0.94),
            ),
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
class SeatBet extends StatelessWidget {
  const SeatBet({
    super.key,
    required this.seat,
    required this.width,
    this.totalFirst = false,
  });

  final Seat seat;

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

  @override
  Widget build(BuildContext context) {
    final t = context.watch<GameState>().t;

    final gap = SizedBox(height: width * _kPad * 0.5);
    final total = seat.contributed > 0
        ? SeatPod._total(context, t, seat, width)
        : null;
    final badge = SeatPod._lastBet(context, t, seat, width);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: totalFirst
          ? [
              if (total != null) ...[total, gap],
              badge,
            ]
          : [
              badge,
              if (total != null) ...[gap, total],
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
  /// off whatever the pod is showing underneath.
  TextStyle _struck(
    BuildContext context,
    double w,
    double scale,
    FontWeight weight,
  ) =>
      AppTheme.smallCaps(
        Theme.of(context).textTheme.titleLarge ?? const TextStyle(),
        fontSize: math.max(9.0, w * scale),
        tracking: w * scale * 0.065,
        weight: weight,
        colour: Colors.white,
      ).copyWith(
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
                            Colors.white,
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
                          style: _struck(context, w, 0.175, FontWeight.w900),
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
                            0.092,
                            FontWeight.w700,
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
