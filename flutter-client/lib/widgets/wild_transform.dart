import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'playing_card.dart';

/// One card of the viewer's own hand on a variation table, which turns into
/// the card it PLAYED AS once the server has said what that was (owner, 18 Sep
/// 2026: "once the player sees his own cards, change the card according to the
/// AK47 variation, with animation and effect").
///
/// Under AK47 a hand of J-Q-4 is a Sequence, and nothing on three ordinary
/// faces says why. So the wild 4 charges with gold light, lifts off the fan,
/// turns over on its long axis and comes back as the king it stood for, under
/// a burst of sparks — and then stays that way, edged in gold, with a "Wild"
/// ribbon at its head and the card it really is on a tab at its foot, because
/// a player who has forgotten what they hold cannot play it.
///
/// **What the card stood for is never worked out here.** [standIn] comes from
/// `you.hand.playsAs`, which the server sends to this player alone once they
/// have looked AND the variation is chosen. Until it arrives the card is drawn
/// exactly as [PlayingCard] draws it; a card that is not wild always is.
///
/// **It plays once.** The turn starts when [standIn] first arrives — after the
/// card's own face-up flip if the two came in the same snapshot (a player who
/// looked once the variation was known), at once if they were already looking
/// when the choice landed. A widget that is BUILT with its stand-in already
/// there (a reconnect mid-hand, the table screen rebuilt) shows the finished
/// state and does not replay. The server drops `you.hand` the moment the hand
/// ends, while the cards are still on the felt for the showdown; the last
/// stand-in is kept, so the hand does not turn back at the very moment it is
/// being compared. A new hand is a new key in the fan, and so a new State.
///
/// Every effect is painted over or behind the card's own box and adds nothing
/// to it: the fan the cards stand in must not move when one of them turns.
class WildTransform extends StatefulWidget {
  const WildTransform({
    super.key,
    required this.height,
    required this.code,
    required this.index,
    required this.label,
    this.wild = false,
    this.standIn,
    this.dimmed = false,
  });

  final double height;

  /// The card as dealt, or null while it is face down.
  final String? code;

  /// The card [code] played as, or null: not wild, not yet known, or itself.
  final String? standIn;

  /// Whether the card played wild at all — a wild ace that stood for itself
  /// still earns the gold edge, as does a wild card named only by a showdown.
  final bool wild;

  /// Its place in the fan, which staggers the turns left to right.
  final int index;

  /// "Wild", in the player's language: the ribbon, and the screen reader's word.
  final String label;
  final bool dimmed;

  /// The whole performance, per card.
  static const Duration turnFor = Duration(milliseconds: 1150);

  /// How far apart the cards of one hand start.
  static const Duration stagger = Duration(milliseconds: 190);

  @override
  State<WildTransform> createState() => _WildTransformState();
}

class _WildTransformState extends State<WildTransform>
    with SingleTickerProviderStateMixin {
  // Created in initState and read on every build: a `late final` first touched
  // in dispose() tears the tree (CLAUDE.md §12.3).
  late final AnimationController _turn;
  Timer? _cue;

  /// The last stand-in the server named this hand, kept after it stops naming
  /// one (the hand ending) so the card does not turn back under a showdown.
  String? _standIn;

  @override
  void initState() {
    super.initState();
    _standIn = widget.standIn;
    _turn = AnimationController(
      vsync: this,
      duration: WildTransform.turnFor,
      // Built already knowing: show it finished, do not replay it.
      value: _standIn == null ? 0 : 1,
    );
  }

  @override
  void didUpdateWidget(covariant WildTransform old) {
    super.didUpdateWidget(old);
    final next = widget.standIn;
    if (next == null || next == _standIn) return;
    final first = _standIn == null;
    _standIn = next;
    if (!first) return; // a changed answer swaps the face; it is not re-staged

    // After the card's own flip when they arrived together, else at once;
    // left to right along the fan either way.
    final flippingUp = old.code == null && widget.code != null;
    final wait =
        (flippingUp
            ? Motion.enter + const Duration(milliseconds: 220)
            : const Duration(milliseconds: 120)) +
        WildTransform.stagger * widget.index;
    _cue?.cancel();
    _cue = Timer(wait, () {
      if (mounted) _turn.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _cue?.cancel();
    _turn.dispose();
    super.dispose();
  }

  static double _span(double v, double from, double to) =>
      ((v - from) / (to - from)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final h = widget.height;
    final standIn = _standIn;
    final code = widget.code;

    // Nothing to turn into: the card as it always was, edged if it was wild.
    if (standIn == null || code == null) {
      final card = PlayingCard(height: h, code: code, dimmed: widget.dimmed);
      if (!widget.wild || code == null) return card;
      return Semantics(
        label: widget.label,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: _edge(h, 1),
          child: card,
        ),
      );
    }

    return Semantics(
      label:
          '${widget.label}: ${PlayingCard.rankOf(code)}'
          '${PlayingCard.suitSymbol(PlayingCard.suitOf(code))} → '
          '${PlayingCard.rankOf(standIn)}'
          '${PlayingCard.suitSymbol(PlayingCard.suitOf(standIn))}',
      child: AnimatedBuilder(
        animation: _turn,
        builder: (context, _) {
          final v = _turn.value;
          // Charge (light gathers, the card lifts) → turn (edge-on at the
          // middle, where the face is swapped) → burst and settle.
          final charge = Curves.easeOut.transform(_span(v, 0, 0.32));
          final flip = Motion.travel.transform(_span(v, 0.30, 0.64));
          final burst = Curves.easeOutCubic.transform(_span(v, 0.50, 1));
          final settle = Curves.easeOut.transform(_span(v, 0.66, 1));

          final turned = flip >= 0.5;
          // 0 → a quarter turn → 0: the card is never seen mirrored.
          final angle = (turned ? 1 - flip : flip) * math.pi;
          // Up off the fan for the turn, back down after it.
          final lift = math.sin(math.pi * _span(v, 0, 0.8));
          // Light: gathers, flares at the turn, rests as a quiet halo.
          final glow = math.max(charge * (1 - settle), 0.30 * settle) +
              0.55 * math.sin(math.pi * _span(v, 0.30, 0.70));

          return Stack(
            clipBehavior: Clip.none,
            children: [
              // The halo, behind the card and outside its box.
              Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(h * 0.055),
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.goldBright.withValues(
                            alpha: (0.75 * glow).clamp(0.0, 1.0),
                          ),
                          blurRadius: h * (0.10 + 0.28 * glow),
                          spreadRadius: h * 0.03 * glow,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0014) // a little perspective on the turn
                  ..translateByDouble(0, -h * 0.10 * lift, 0, 1)
                  ..scaleByDouble(1 + 0.08 * lift, 1 + 0.08 * lift, 1, 1)
                  ..rotateY(angle),
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: _edge(h, math.max(charge, settle)),
                  child: PlayingCard(
                    height: h,
                    code: turned ? standIn : code,
                    dimmed: widget.dimmed,
                  ),
                ),
              ),
              // Sparks thrown as the new face comes round.
              if (burst > 0 && burst < 1)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _BurstPainter(progress: burst, seed: widget.index),
                    ),
                  ),
                ),
              // What it is, and what it really is — once it has landed.
              if (settle > 0) ...[
                Positioned(
                  top: -h * 0.075,
                  left: 0,
                  right: 0,
                  child: Opacity(
                    opacity: settle,
                    child: Center(child: _Ribbon(text: widget.label, cardHeight: h)),
                  ),
                ),
                Positioned(
                  bottom: h * 0.03,
                  left: 0,
                  right: 0,
                  child: Opacity(
                    opacity: settle,
                    child: Center(child: _RealCardTab(code: code, cardHeight: h)),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  /// The gold edge of a wild card (PlayingCard's own corner radius).
  static BoxDecoration _edge(double h, double strength) => BoxDecoration(
    borderRadius: BorderRadius.circular(h * 0.055),
    border: Border.all(
      color: AppTheme.goldBright.withValues(alpha: strength.clamp(0.0, 1.0)),
      width: math.max(1.5, h * 0.035),
    ),
  );
}

/// "WILD", on a gold tab riding the head of the card.
class _Ribbon extends StatelessWidget {
  const _Ribbon({required this.text, required this.cardHeight});

  final String text;
  final double cardHeight;

  @override
  Widget build(BuildContext context) {
    final height = math.max(13.0, cardHeight * 0.15);
    return Container(
      height: height,
      // Never wider than the card it names, in any script.
      constraints: BoxConstraints(
        maxWidth: cardHeight * PlayingCard.aspect * 0.92,
      ),
      padding: EdgeInsets.symmetric(horizontal: height * 0.45),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(height),
        gradient: const LinearGradient(
          colors: [AppTheme.goldBright, AppTheme.gold],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        boxShadow: [
          BoxShadow(
            color: AppTheme.ink900.withValues(alpha: 0.45),
            blurRadius: height * 0.35,
            offset: Offset(0, height * 0.12),
          ),
        ],
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          text.toUpperCase(),
          maxLines: 1,
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontFamily: AppTheme.fontFamily,
            fontSize: height * 0.62,
            fontWeight: FontWeight.w800,
            letterSpacing: height * 0.06,
            height: 1,
            color: AppTheme.ink900,
          ),
        ),
      ),
    );
  }
}

/// The card the player really holds, on a small face-coloured tab at the foot
/// of what it turned into: "4♠" — the rank set in type and the suit PAINTED
/// ([CardPips]), as the card faces are, since 24 Sep 2026. It was one string
/// ending in a bare '♠', which Inter has no glyph for, so a phone drew it from
/// whatever it fell back to — on Android the colour emoji font, a chunkier
/// club than the "4" beside it, and a box on a phone without it. On this pale
/// tab the colour happened to come out right, which is why the owner's report
/// that day was about the tag over the pot and not this; it is drawn the same
/// way so that no suit anywhere depends on a font the app does not ship.
///
/// Keyed by its code (`wild-real-card:4s`), so a test can tell the tab under
/// one card from the tab under another.
class _RealCardTab extends StatelessWidget {
  const _RealCardTab({required this.code, required this.cardHeight});

  final String code;
  final double cardHeight;

  @override
  Widget build(BuildContext context) {
    final height = math.max(13.0, cardHeight * 0.16);
    final suit = PlayingCard.suitOf(code);
    final rank = PlayingCard.rankOf(code);
    final ink = PlayingCard.inkFor(suit);
    return Semantics(
      // Read out as the text was, "4♠".
      label: '$rank${PlayingCard.suitSymbol(suit)}',
      excludeSemantics: true,
      child: Container(
        key: ValueKey('wild-real-card:$code'),
        height: height,
        padding: EdgeInsets.symmetric(horizontal: height * 0.4),
        decoration: BoxDecoration(
          color: AppTheme.cardFace,
          borderRadius: BorderRadius.circular(height),
          border: Border.all(color: AppTheme.gold, width: 1),
          boxShadow: [
            BoxShadow(
              color: AppTheme.ink900.withValues(alpha: 0.35),
              blurRadius: height * 0.3,
            ),
          ],
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                rank,
                maxLines: 1,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontSize: height * 0.68,
                  fontWeight: FontWeight.w800,
                  height: 1,
                  color: ink,
                ),
              ),
              SizedBox(width: height * 0.07),
              // The pip a touch shorter than the rank's cap height, as a
              // card's own index sets it.
              CardPips(suit: suit, size: height * 0.58, colour: ink),
            ],
          ),
        ),
      ),
    );
  }
}

/// A ring of gold light opening from the card, and a dozen sparks thrown with
/// it. Painted past the card's box on purpose: nothing above it clips.
class _BurstPainter extends CustomPainter {
  const _BurstPainter({required this.progress, required this.seed});

  /// 0 at the moment the new face comes round, 1 when the last spark is out.
  final double progress;

  /// Turns each card's sparks a little differently from its neighbour's.
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final reach = size.height;
    final fade = 1 - progress;

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.0, reach * 0.045 * fade)
      ..color = AppTheme.goldBright.withValues(alpha: 0.85 * fade);
    canvas.drawCircle(centre, reach * (0.28 + 0.62 * progress), ring);

    final spark = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = math.max(1.0, reach * 0.028 * fade)
      ..color = AppTheme.goldBright.withValues(alpha: fade);
    const count = 12;
    for (var i = 0; i < count; i++) {
      final angle = (i + 0.37 * seed) * 2 * math.pi / count;
      // Every other spark flies further, so the burst is a star, not a wheel.
      final far = i.isEven ? 1.0 : 0.72;
      final from = reach * (0.34 + 0.50 * progress) * far;
      final to = from + reach * 0.16 * fade;
      final direction = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(centre + direction * from, centre + direction * to, spark);
    }
  }

  @override
  bool shouldRepaint(covariant _BurstPainter old) =>
      old.progress != progress || old.seed != seed;
}
