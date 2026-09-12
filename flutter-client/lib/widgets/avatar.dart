import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_theme.dart';

/// A player's picture (requirements 20 and 21), set in a ring.
///
/// The catalogue set is SVG and a Google or Facebook picture is a bitmap, so
/// both paths are handled here.
///
/// There are two different fallbacks and the difference matters. A player with
/// NO picture gets their initial — it is something rather than nothing, and it
/// tells the table who the seat belongs to. A picture that was supposed to
/// load and did NOT — a retired file, a dead Google URL, a phone that lost the
/// network mid-fetch — gets [defaultAsset], a bundled image, because falling
/// back to a letter there would make a broken link look like a deliberate
/// choice. Either way, never a broken box: a missing picture should not be the
/// most eye-catching thing at the table.
///
/// The ring is what makes the portrait sit *in* the surface it is on rather
/// than on top of it: a champagne hairline, a contact shadow under it, and a
/// dark inner stroke painted over the picture's own edge so a pale avatar does
/// not bleed into a pale plaque. The seat pod passes the turn colour here, so a
/// player watching faces rather than borders still sees whose turn it is.
class Avatar extends StatelessWidget {
  /// Shipped with the app rather than fetched, because the whole point of it
  /// is to be there when a fetch has just failed.
  static const defaultAsset = 'assets/default_avatar.svg';

  const Avatar({
    super.key,
    required this.url,
    required this.fallback,
    this.radius = 20,
    this.background,
    this.ring,
    this.ringWidth = 1.5,
    this.ringGap = 0,
  });

  /// Absolute, or server-relative like "/profiles/ace.svg".
  final String? url;

  /// Shown when there is no picture: normally the display name.
  final String fallback;
  final double radius;
  final Color? background;

  /// The ring's colour. Defaults to the app's champagne hairline.
  final Color? ring;
  final double ringWidth;

  /// A band of ground between the ring and the picture, for a selected state
  /// that has to read as chosen rather than as an Android focus highlight.
  final double ringGap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final bg = background ?? theme.colorScheme.surfaceContainerHighest;
    // Brighter than [AppTheme.hairlineColour]'s resting alpha on purpose: this
    // one runs round a picture rather than along a panel edge, and a 0.16 ring
    // at radius 20 is not visible at all.
    final rim =
        ring ??
        (dark
            ? AppTheme.goldBright.withValues(alpha: 0.28)
            : AppTheme.goldDeep.withValues(alpha: 0.34));

    final initial = Text(
      fallback.isEmpty ? '?' : fallback.characters.first.toUpperCase(),
      style: TextStyle(
        fontSize: radius * 0.85,
        fontWeight: FontWeight.w600,
        color: dark
            ? AppTheme.goldBright.withValues(alpha: 0.75)
            : theme.colorScheme.onSurfaceVariant,
      ),
    );

    final fallbackImage = SvgPicture.asset(
      defaultAsset,
      width: radius * 2,
      height: radius * 2,
      fit: BoxFit.cover,
      // If even the bundled asset will not render there is nothing left to
      // try, so the initial is the floor.
      placeholderBuilder: (_) => Center(child: initial),
    );

    final link = url;
    final Widget? picture = link == null || link.isEmpty
        ? null
        // An SVG through Image.network renders nothing, so the two loaders are
        // routed on the extension and must stay that way.
        : link.toLowerCase().endsWith('.svg')
        ? SvgPicture.network(
            link,
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            placeholderBuilder: (_) => Center(child: initial),
            errorBuilder: (_, _, _) => fallbackImage,
          )
        : Image.network(
            link,
            width: radius * 2,
            height: radius * 2,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => fallbackImage,
          );

    Widget core = CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      child: picture == null
          ? initial
          : ClipOval(
              child: SizedBox(
                width: radius * 2,
                height: radius * 2,
                child: picture,
              ),
            ),
    );

    // Painted over the picture rather than around it, so the seat's arithmetic
    // stays (2 * radius) + the ring the caller asked for and nothing else.
    core = Stack(
      alignment: Alignment.center,
      children: [
        core,
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppTheme.ink900.withValues(alpha: dark ? 0.30 : 0.14),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    if (ringGap > 0) {
      core = Container(
        padding: EdgeInsets.all(ringGap),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: dark ? AppTheme.ink800 : AppTheme.bone100,
        ),
        child: core,
      );
    }

    // A bordered BoxDecoration insets its child by the border width, so the
    // ring grows outwards and the picture keeps the radius it was given.
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: rim, width: ringWidth),
        boxShadow: [
          BoxShadow(
            color: AppTheme.shadowFor(
              theme.brightness,
            ).withValues(alpha: dark ? 0.45 : 0.16),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: core,
    );
  }
}
