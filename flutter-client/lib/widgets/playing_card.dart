import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_theme.dart';

/// A playing card, face up or face down.
///
/// Cards keep one aspect ratio everywhere — the player's own hand and every
/// opponent's — so a card means the same thing wherever it appears. Turning one
/// over animates: the card rotates on its long axis and the face appears at the
/// halfway point, which is what a real card does and what makes "see" feel like
/// an action rather than a repaint.
class PlayingCard extends StatefulWidget {
  const PlayingCard({
    super.key,
    this.code,
    this.height = 96,
    this.dimmed = false,
  });

  /// A server card code such as "As" or "Td". Null means face down.
  final String? code;
  final double height;

  /// Packed players' cards are dimmed rather than removed, so the seat still
  /// reads as "was in this hand".
  final bool dimmed;

  /// The card-back artwork's own ratio, which is the standard 5:7.
  static const double aspect = 240 / 336;

  @override
  State<PlayingCard> createState() => _PlayingCardState();
}

class _PlayingCardState extends State<PlayingCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flip = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
    value: widget.code == null ? 0 : 1,
  );

  @override
  void didUpdateWidget(covariant PlayingCard old) {
    super.didUpdateWidget(old);
    final wasFaceUp = old.code != null;
    final isFaceUp = widget.code != null;
    if (wasFaceUp == isFaceUp) return;

    // Turned over, so play it rather than swapping the picture.
    isFaceUp ? _flip.forward() : _flip.reverse();
  }

  @override
  void dispose() {
    _flip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.height * PlayingCard.aspect;

    final card = AnimatedBuilder(
      animation: _flip,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(_flip.value);
        final angle = t * math.pi;
        final showingFace = t > 0.5;

        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015) // a little perspective, so it has depth
            ..rotateY(angle),
          child: showingFace
              // The face would be mirrored halfway through the turn, so it is
              // flipped back the other way.
              ? Transform(
                  alignment: Alignment.center,
                  transform: Matrix4.identity()..rotateY(math.pi),
                  child: _face(context),
                )
              : _back(),
        );
      },
    );

    return SizedBox(
      width: width,
      height: widget.height,
      child: widget.dimmed ? Opacity(opacity: 0.35, child: card) : card,
    );
  }

  Widget _back() => ClipRRect(
        borderRadius: BorderRadius.circular(widget.height * 0.06),
        child: SvgPicture.asset(
          'assets/card_back.svg',
          fit: BoxFit.fill,
          width: widget.height * PlayingCard.aspect,
          height: widget.height,
        ),
      );

  Widget _face(BuildContext context) {
    final code = widget.code;
    if (code == null) return const SizedBox.shrink();

    final rank = rankOf(code);
    final suit = suitOf(code);
    final red = suit == 'h' || suit == 'd';
    final ink = red ? AppTheme.pipRed : AppTheme.pipBlack;
    final h = widget.height;

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.cardFace,
        borderRadius: BorderRadius.circular(h * 0.06),
        boxShadow: const [
          BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      padding: EdgeInsets.symmetric(horizontal: h * 0.05, vertical: h * 0.06),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              rank,
              style: TextStyle(
                color: ink,
                fontWeight: FontWeight.w800,
                fontSize: h * 0.34,
                height: 1,
              ),
            ),
          ),
          Text(
            suitSymbol(suit),
            style: TextStyle(color: ink, fontSize: h * 0.3, height: 1),
          ),
        ],
      ),
    );
  }

  static String rankOf(String code) {
    final r = code.substring(0, code.length - 1).toUpperCase();
    return r == 'T' ? '10' : r;
  }

  static String suitOf(String code) =>
      code.substring(code.length - 1).toLowerCase();

  static String suitSymbol(String suit) => switch (suit) {
        's' => '♠',
        'h' => '♥',
        'd' => '♦',
        'c' => '♣',
        _ => '?',
      };
}
