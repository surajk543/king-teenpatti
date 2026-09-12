import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lottie/lottie.dart';

import '../net/picture_cache.dart';
import '../theme/app_theme.dart';

/// A player's picture (requirements 20 and 21), set in a ring.
///
/// The catalogue set is SVG, a Google or Facebook picture is a bitmap, and a
/// catalogue row may point at a Lottie animation, so three loaders are handled
/// here. They are routed on the extension and must stay that way: an SVG
/// through Image.network renders nothing, and a dotLottie is a zip that neither
/// of the other two can read.
///
/// An animation only PLAYS where [animate] is set — the picker. Everywhere else
/// it is drawn stopped on its first frame, which is still the player's picture
/// and costs no ticker: five looping animations around a felt that already runs
/// per-frame turn clocks is a different question, and not one a profile picture
/// should answer on its own.
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
    this.animate = false,
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

  /// Whether a Lottie picture plays. Off everywhere but the picker; a stopped
  /// animation still draws its first frame. Does nothing for SVG or bitmap
  /// pictures, which have no frames to run.
  final bool animate;

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
    final extension = (link ?? '').toLowerCase();
    // A dotLottie (.lottie) is a zip of manifest + animation + images; a raw
    // Lottie is .json. LottieComposition.decodeZip is the default decoder and
    // sniffs the PK magic bytes, so one call reads either.
    final animated =
        extension.endsWith('.lottie') || extension.endsWith('.json');

    // Bytes first, network second: PictureCache keeps a picture on the phone
    // once it has been fetched, so the second launch — and every rebuild of
    // the five seat pods — paints from memory rather than the wire.
    final Widget? picture = link == null || link.isEmpty
        ? null
        : _CachedPicture(
            url: link,
            size: radius * 2,
            animated: animated,
            isSvg: extension.endsWith('.svg'),
            animate: animate,
            placeholder: Center(child: initial),
            fallback: fallbackImage,
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


/// One picture, drawn from [PictureCache].
///
/// Held apart from [Avatar] because it needs state and Avatar does not: the
/// bytes arrive after the first frame the first time, and never after that.
/// A picture already in memory is painted on the FIRST frame — no placeholder,
/// no flash — which is the whole point of the cache being synchronous to peek.
class _CachedPicture extends StatefulWidget {
  const _CachedPicture({
    required this.url,
    required this.size,
    required this.animated,
    required this.isSvg,
    required this.animate,
    required this.placeholder,
    required this.fallback,
  });

  final String url;
  final double size;

  /// Routed on the extension, as before: an SVG through Image renders nothing,
  /// and a dotLottie is a zip neither of the others can read.
  final bool animated;
  final bool isSvg;

  /// Whether an animation plays, as opposed to resting on its first frame.
  final bool animate;

  /// Held while the bytes are on their way — only ever on a first fetch.
  final Widget placeholder;

  /// Shown when they cannot be had, or will not decode.
  final Widget fallback;

  @override
  State<_CachedPicture> createState() => _CachedPictureState();
}

class _CachedPictureState extends State<_CachedPicture> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant _CachedPicture old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _bytes = null;
      _failed = false;
      _resolve();
    }
  }

  void _resolve() {
    final ready = PictureCache.peek(widget.url);
    if (ready != null) {
      _bytes = ready;
      return;
    }
    final wanted = widget.url;
    PictureCache.load(wanted).then((bytes) {
      // The picker changes the picture under this widget, so a slow answer
      // for the previous URL must not overwrite the current one.
      if (!mounted || wanted != widget.url) return;
      setState(() {
        _bytes = bytes;
        _failed = bytes == null;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    final bytes = _bytes;
    if (bytes == null) return widget.placeholder;

    if (widget.animated) {
      return Lottie.memory(
        bytes,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        animate: widget.animate,
        repeat: widget.animate,
        frameBuilder: (_, child, composition) =>
            composition == null ? widget.placeholder : child,
        errorBuilder: (_, _, _) => widget.fallback,
      );
    }
    if (widget.isSvg) {
      return SvgPicture.memory(
        bytes,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        placeholderBuilder: (_) => widget.placeholder,
        errorBuilder: (_, _, _) => widget.fallback,
      );
    }
    return Image.memory(
      bytes,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.cover,
      // Bytes that will not decode are the same problem as bytes that never
      // arrived, and get the same answer.
      errorBuilder: (_, _, _) => widget.fallback,
    );
  }
}
