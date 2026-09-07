import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../state/game_state.dart';
import 'avatar.dart';
import 'liquid_fill.dart';
import 'playing_card.dart';
import 'poker_chip.dart';
import 'premium_surface.dart';

/// One player's place at the table: a portrait pod with the name across the
/// top, a picture in the middle and the stack on a pill underneath, with its
/// cards alongside and its bet between the pod and the pot.
///
/// The pod of whoever is to act blinks and fills from the bottom. The blink
/// starts green and bleeds to red as the clock empties, so the colour alone
/// says how long is left; a full pod means the turn is over.
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
    this.saying,
    this.bubbleSide = BubbleSide.above,
    this.reversed = false,
  });

  final Seat? seat;
  final bool isMe;
  final bool isDealer;
  final bool onTurn;

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
    // than as free seats.
    if (s == null || !s.occupied) return SizedBox(width: width);

    final theme = Theme.of(context);
    final t = (progress ?? 0).clamp(0.0, 1.0);
    // Squared, so it holds green for most of the turn and reddens sharply at
    // the end rather than sitting muddy in the middle.
    final beat = Color.lerp(
      theme.colorScheme.primary,
      theme.colorScheme.error,
      t * t,
    )!;

    final gap = width * 0.05;
    final below = <Widget>[
      if (s.cardCount > 0 && !isMe) ...[SizedBox(height: gap), _cards(s)],
      if (_inHand(s)) ...[
        SizedBox(height: gap),
        _lastBet(context, s),
        if (s.contributed > 0) ...[
          SizedBox(height: gap * 0.5),
          _total(context, s),
        ],
      ] else if (_status(context, s) != null) ...[
        SizedBox(height: gap),
        Text(
          _status(context, s)!,
          style: theme.textTheme.labelSmall?.copyWith(
            color: s.connected
                ? theme.colorScheme.onSurfaceVariant
                : theme.colorScheme.error,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ];

    final column = <Widget>[_pod(context, s, beat, t), ...below];

    // The bubble takes no room in the column — it hangs off one end of it in
    // a zero-height box — so a player speaking never nudges their own pod,
    // cards or chips. It is the last thing in the column, so it paints over
    // the cards and badge rather than under them, and it stays over the
    // player's own column: the seats round the rim open theirs over their
    // cards, growing towards the middle of the table, and the viewer's opens
    // upwards over their bets. Nothing ever reaches the pot, the tag, or the
    // edge of the felt.
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
              maxWidth: width * (bubbleSide == BubbleSide.above ? 2.1 : 1.7),
              minHeight: 0,
              maxHeight: width * 1.3,
              child: Padding(
                padding: EdgeInsets.only(bottom: gap),
                child: _Bubble(
                  text: saying!,
                  width: width,
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

    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ...(reversed ? ordered.reversed.toList() : ordered),
        ],
      ),
    );
  }

  Widget _pod(BuildContext context, Seat s, Color beat, double t) {
    final theme = Theme.of(context);

    // A pod is a lobby card at pod size, so the two screens are built from the
    // same material rather than merely resembling each other.
    final accent = s.status == SeatState.won
        ? theme.colorScheme.primary
        : onTurn
        ? beat
        : theme.colorScheme.outlineVariant;

    return _Blink(
      active: onTurn,
      colour: beat,
      radius: width * 0.14,
      child: PremiumSurface(
        accent: accent,
        radius: width * 0.14,
        borderWidth: onTurn ? 2 : 1.2,
        child: Stack(
          children: [
            // The turn clock, drawn as liquid rising inside the pod. Full
            // means their time is up.
            if (onTurn && progress != null && deadlineMs > 0)
              Positioned.fill(
                child: LiquidFill(
                  deadlineMs: deadlineMs,
                  totalMs: totalMs,
                  colour: beat,
                ),
              ),
            Padding(
              padding: EdgeInsets.all(width * 0.05),
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
                          style: TextStyle(
                            fontSize: width * 0.135,
                            fontWeight: FontWeight.w800,
                            color: isMe ? theme.colorScheme.secondary : null,
                          ),
                        ),
                      ),
                      if (isDealer) ...[
                        const SizedBox(width: 4),
                        CircleAvatar(
                          radius: width * 0.09,
                          backgroundColor: theme.colorScheme.tertiaryContainer,
                          child: Text(
                            'D',
                            style: TextStyle(
                              fontSize: width * 0.1,
                              color: theme.colorScheme.onTertiaryContainer,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: width * 0.04),
                  Avatar(
                    url: avatarUrl,
                    fallback: s.displayName,
                    radius: width * 0.2,
                  ),
                  SizedBox(height: width * 0.05),
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(vertical: width * 0.025),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(width * 0.09),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        // On a blind table another player's stack was never
                        // sent, so show it as withheld rather than as zero.
                        s.chips == null ? '•••' : formatChips(s.chips!),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: width * 0.125,
                          color: theme.colorScheme.onSecondaryContainer,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
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

  Widget _cards(Seat s) {
    final dim = s.status == SeatState.packed || s.status == SeatState.lost;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < s.cardCount; i++)
          PlayingCard(height: width * 0.42, dimmed: dim),
      ],
    );
  }

  /// What this player just put in. The chip makes it read as money from across
  /// the table, where a bare number does not.
  Widget _lastBet(BuildContext context, Seat s) {
    final theme = Theme.of(context);
    final t = context.watch<GameState>().t;
    final label = s.isBlind ? t.blind : t.seen;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.07,
        vertical: width * 0.025,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(width * 0.1),
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
                child: Text(
                  s.lastBet > 0 ? '$label  ${formatChips(s.lastBet)}' : label,
                  key: ValueKey('${s.lastBet}-${s.isBlind}'),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: width * 0.115,
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Everything they are in for this hand.
  Widget _total(BuildContext context, Seat s) {
    final theme = Theme.of(context);

    return TweenAnimationBuilder<double>(
      tween: Tween(end: s.contributed.toDouble()),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          '${context.watch<GameState>().t.inPot} ${formatChips(value.round())}',
          maxLines: 1,
          style: TextStyle(
            fontSize: width * 0.1,
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  bool _inHand(Seat s) =>
      handLive && (s.status == SeatState.active || s.status == SeatState.won);

  String? _status(BuildContext context, Seat s) {
    final t = context.watch<GameState>().t;
    if (!s.connected) return t.offline;
    return switch (s.status) {
      SeatState.packed => t.pack,
      SeatState.won => t.winner,
      SeatState.waiting => t.waiting,
      _ => null,
    };
  }
}

/// The pod of whoever is to act pulses, brightly.
///
/// It is a ring of light around the pod rather than a change of border colour:
/// from across the table the glow is what carries, and every player needs to
/// see whose turn it is at a glance, not only the player whose turn it is.
class _Blink extends StatefulWidget {
  const _Blink({
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
  State<_Blink> createState() => _BlinkState();
}

class _BlinkState extends State<_Blink> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 780),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;

    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_c.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            boxShadow: [
              // A tight core and a wide halo, both breathing, so the seat reads
              // as lit rather than merely outlined.
              BoxShadow(
                color: widget.colour.withValues(alpha: 0.55 + 0.45 * t),
                blurRadius: 10 + 10 * t,
                spreadRadius: 1 + 2 * t,
              ),
              BoxShadow(
                color: widget.colour.withValues(alpha: 0.20 + 0.35 * t),
                blurRadius: 26 + 22 * t,
                spreadRadius: 3 + 6 * t,
              ),
            ],
          ),
          child: child,
        );
      },
      child: widget.child,
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
    required this.tailUp,
    required this.tailFrom,
  });

  final String text;
  final double width;

  /// Whether the pointer is on the top edge (aimed up at a pod above) or the
  /// bottom edge (aimed down at a pod below).
  final bool tailUp;
  final _TailFrom tailFrom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = theme.colorScheme.inverseSurface;
    // The pointer is a rotated square half-buried in the bubble's edge, so
    // what shows is a small triangle aimed at the speaker.
    final tail = width * 0.13;
    final reach = tail * 0.62;
    // Centred under the pod, which is half a pod-width in from the anchored
    // edge — or dead centre when the bubble is centred on the pod.
    final inset = width / 2 - tail / 2;

    final body = Container(
      constraints: BoxConstraints(maxWidth: width * 2.1),
      padding: EdgeInsets.symmetric(
        horizontal: width * 0.09,
        vertical: width * 0.05,
      ),
      decoration: BoxDecoration(
        color: colour,
        borderRadius: BorderRadius.circular(width * 0.13),
        boxShadow: const [
          BoxShadow(
            color: Color(0x40000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: width * 0.11,
          height: 1.25,
          color: theme.colorScheme.onInverseSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

    final pointer = Transform.rotate(
      angle: math.pi / 4,
      child: Container(
        width: tail,
        height: tail,
        decoration: BoxDecoration(
          color: colour,
          borderRadius: BorderRadius.circular(tail * 0.15),
        ),
      ),
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      builder: (context, v, child) => Transform.scale(
        scale: 0.6 + 0.4 * v,
        alignment: tailUp ? Alignment.topCenter : Alignment.bottomCenter,
        child: Opacity(opacity: v.clamp(0, 1), child: child),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: EdgeInsets.only(
              top: tailUp ? reach : 0,
              bottom: tailUp ? 0 : reach,
            ),
            child: body,
          ),
          Positioned(
            top: tailUp ? 0 : null,
            bottom: tailUp ? null : 0,
            left: switch (tailFrom) {
              _TailFrom.left => inset,
              _TailFrom.right => null,
              _TailFrom.centre => 0,
            },
            right: switch (tailFrom) {
              _TailFrom.left => null,
              _TailFrom.right => inset,
              _TailFrom.centre => 0,
            },
            child: tailFrom == _TailFrom.centre
                ? Center(child: pointer)
                : pointer,
          ),
        ],
      ),
    );
  }
}
