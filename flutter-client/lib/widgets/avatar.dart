import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// A player's picture (requirements 20 and 21).
///
/// The bundled set is SVG and a Google or Facebook picture is a bitmap, so both
/// paths are handled here. Anything that fails to load falls back to the
/// player's initial rather than a broken box — a missing picture should never
/// be the most eye-catching thing at the table.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.url,
    required this.fallback,
    this.radius = 20,
    this.background,
  });

  /// Absolute, or server-relative like "/profiles/ace.svg".
  final String? url;

  /// Shown when there is no picture: normally the display name.
  final String fallback;
  final double radius;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = background ?? theme.colorScheme.surfaceContainerHighest;

    final initial = Text(
      fallback.isEmpty ? '?' : fallback.characters.first.toUpperCase(),
      style: TextStyle(
        fontSize: radius * 0.9,
        fontWeight: FontWeight.w800,
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );

    final link = url;
    if (link == null || link.isEmpty) {
      return CircleAvatar(radius: radius, backgroundColor: bg, child: initial);
    }

    final Widget picture = link.toLowerCase().endsWith('.svg')
        ? SvgPicture.network(
            link,
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            placeholderBuilder: (_) => Center(child: initial),
          )
        : Image.network(
            link,
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Center(child: initial),
          );

    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      child: ClipOval(
        child: SizedBox(width: radius * 2, height: radius * 2, child: picture),
      ),
    );
  }
}
