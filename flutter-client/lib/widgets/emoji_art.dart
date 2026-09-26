/// An emoji as the app draws it everywhere (owner, 26 Sep 2026): the store's
/// Emojis shelf, the unlock question, the table's emoji page, a seat playing
/// one, and the chat log.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../net/picture_cache.dart';
import '../theme/app_theme.dart';
import 'table_picture_shelf.dart' show pictureRetryDelay;

/// One emoji's Lottie, [size] square, drawn from [PictureCache] — the file
/// is fetched once per URL and kept on the phone, as every picture is, so a
/// table full of players sending the same emoji costs one download.
///
/// Always FITTED whole ([BoxFit.contain]), never cropped: an emoji's canvas
/// is its drawing, and a crop would cut a face in half. Until the bytes are
/// in hand — and if they never come — a quiet smiley stands in its place, so
/// a seat, a tile or a chat line is never an empty box; a failed fetch is
/// tried again on [pictureRetryDelay]'s clock (a phone that was offline for a
/// moment, a Drive file not shared yet), as the table's picture is.
///
/// Its own repaint boundary: a playing emoji repaints every frame, and
/// nothing round it should.
class EmojiArt extends StatefulWidget {
  const EmojiArt({
    super.key,
    required this.url,
    required this.size,
    this.animate = true,
    this.semanticLabel,
  });

  /// Absolute — the caller has made a server-relative path loadable
  /// (`GameState.absoluteUrl`). Null or empty draws the stand-in.
  final String? url;

  /// The square the emoji is drawn in, in dp.
  final double size;

  /// Whether it plays; false rests it on its first frame.
  final bool animate;

  /// What a screen reader calls it — the emoji's name.
  final String? semanticLabel;

  @override
  State<EmojiArt> createState() => _EmojiArtState();
}

class _EmojiArtState extends State<EmojiArt> {
  Uint8List? _bytes;
  Timer? _retry;
  int _failures = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant EmojiArt old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _retry?.cancel();
      _failures = 0;
      _bytes = null;
      _resolve();
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  void _resolve() {
    final url = widget.url;
    if (url == null || url.isEmpty) return;
    final ready = PictureCache.peek(url);
    if (ready != null) {
      _bytes = ready;
      return;
    }
    PictureCache.load(url).then((bytes) {
      if (!mounted || url != widget.url) return;
      if (bytes == null) {
        _retry = Timer(pictureRetryDelay(_failures++), () {
          if (mounted && url == widget.url) _resolve();
        });
        return;
      }
      _failures = 0;
      setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final bytes = _bytes;
    final Widget stand = _StandIn(size: size);
    final Widget art = bytes == null
        ? stand
        : Lottie.memory(
            bytes,
            width: size,
            height: size,
            fit: BoxFit.contain,
            animate: widget.animate,
            repeat: widget.animate,
            frameBuilder: (_, child, composition) =>
                composition == null ? stand : child,
            errorBuilder: (_, _, _) => stand,
          );
    return Semantics(
      label: widget.semanticLabel,
      image: widget.semanticLabel != null,
      excludeSemantics: true,
      child: RepaintBoundary(
        child: SizedBox.square(dimension: size, child: art),
      ),
    );
  }
}

/// The emoji's place while it has nothing to show: a smiley in the quiet
/// ink, never a broken box.
class _StandIn extends StatelessWidget {
  const _StandIn({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Icon(
        Icons.emoji_emotions_outlined,
        size: size * 0.62,
        color: theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkLow),
      ),
    );
  }
}
