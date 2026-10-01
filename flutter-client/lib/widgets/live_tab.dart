import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import 'player_profile.dart' show friendsGreen;

/// "Live" on a tab standing on the top edge of the lobby's Seen, Blind and
/// Variation cards, a small green dot blinking at its left (owner, 1 Oct 2026:
/// "Add a text word "Live" with a green small dot which blinks, this dot should
/// on the left side of text "Live" and this word should be on top of lobby
/// card(seen, blind, variation) only and this word should be in box which is
/// kept on top of lobby card and its top corners should be little round").
///
/// The box is the card's own surface ([GlassColors.cardFill]) outlined in the
/// card's lit edge ([edge]) along its top and sides, its top corners rounded a
/// little ([Radii.xs]) and its foot square, open and flush on the card's top
/// edge: a tab of the card, not a badge floating over it. It stands outside
/// the card's box, in the room the rail keeps above every card for it
/// ([heightOf]), so the card under it keeps its size wherever it is drawn.
///
/// The dot is the friends' "online" green ([friendsGreen]), the one green the
/// app already says "here now" in. It blinks on its own controller under a
/// repaint boundary: the lobby rebuilds every second and none of it restarts
/// the blink, and the blink repaints the dot alone. Where the platform asks
/// for less motion it stands lit.
class LiveTab extends StatelessWidget {
  const LiveTab({super.key, required this.label, required this.edge});

  /// "Live", in the player's language.
  final String label;

  /// The card's lit edge: its accent at the alpha its hairline's top has.
  final Color edge;

  /// The tab's padding round its line.
  static const double padX = 8;
  static const double padY = 3;

  /// The dot's side, and the gap between it and the word.
  static const double dot = 7;
  static const double gap = 5;

  /// Round the top corners, a little.
  static const double radius = Radii.xs;

  /// The word's style: the label ramp's medium step, bold.
  static TextStyle styleOf(BuildContext context) {
    final theme = Theme.of(context);
    return AppTheme.label(
      theme.textTheme.labelMedium!,
      colour: GlassColors.of(context).textDisplay,
      weight: FontWeight.w700,
    );
  }

  /// How tall the tab stands for [label] in this theme, language and text
  /// size — MEASURED, since a word in an Indic script stands taller than its
  /// font size says (CLAUDE.md §12.3). The rail keeps this much room above
  /// every card, and the tab is exactly this tall.
  static double heightOf(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: DefaultTextStyle.of(context).style.merge(styleOf(context)),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final line = painter.height;
    painter.dispose();
    return (line > dot ? line : dot) + 2 * padY;
  }

  @override
  Widget build(BuildContext context) {
    final glass = GlassColors.of(context);
    final b = Theme.of(context).brightness;
    return CustomPaint(
      key: const ValueKey('live-tab'),
      painter: _TabPainter(fill: glass.cardFill, edge: edge),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: padX, vertical: padY),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _LiveDot(colour: friendsGreen(b)),
            const SizedBox(width: gap),
            Text(label, maxLines: 1, softWrap: false, style: styleOf(context)),
          ],
        ),
      ),
    );
  }
}

/// The tab's box: [fill] with its top corners rounded, a hairline of [edge]
/// up one side, over the top and down the other, and no line along its foot,
/// which stands on the card's own top edge.
class _TabPainter extends CustomPainter {
  const _TabPainter({required this.fill, required this.edge});

  final Color fill;
  final Color edge;

  @override
  void paint(Canvas canvas, Size size) {
    final r = LiveTab.radius;
    final body = RRect.fromRectAndCorners(
      Offset.zero & size,
      topLeft: Radius.circular(r),
      topRight: Radius.circular(r),
    );
    canvas.drawRRect(body, Paint()..color = fill);
    // The hairline half a pixel in, so it is drawn whole inside the box.
    const h = 0.5;
    final outline = Path()
      ..moveTo(h, size.height)
      ..lineTo(h, r)
      ..arcToPoint(Offset(r, h), radius: Radius.circular(r - h))
      ..lineTo(size.width - r, h)
      ..arcToPoint(Offset(size.width - h, r), radius: Radius.circular(r - h))
      ..lineTo(size.width - h, size.height);
    canvas.drawPath(
      outline,
      Paint()
        ..color = edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_TabPainter old) => old.fill != fill || old.edge != edge;
}

/// The green dot, blinking: lit, then down to a fifth and back, about once a
/// second, with a soft glow of its own colour while it is lit.
class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.colour});

  final Color colour;

  /// Half a blink: lit to dim, or dim to lit.
  static const Duration half = Duration(milliseconds: 600);

  /// How far down the dot dims.
  static const double low = 0.2;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: _LiveDot.half,
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: 1,
    end: _LiveDot.low,
  ).animate(CurvedAnimation(parent: _blink, curve: Curves.easeInOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _blink
        ..stop()
        ..value = 0;
    } else if (!_blink.isAnimating) {
      _blink.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: FadeTransition(
      key: const ValueKey('live-dot'),
      opacity: _opacity,
      child: Container(
        width: LiveTab.dot,
        height: LiveTab.dot,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.colour,
          boxShadow: [
            BoxShadow(
              color: widget.colour.withValues(alpha: 0.6),
              blurRadius: 4,
            ),
          ],
        ),
      ),
    ),
  );
}
