import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../models/friends.dart';
import '../state/game_state.dart';
import 'emoji_art.dart';

/// A level's mark as the app draws it (owner, 29 Sep 2026: "Instead of using
/// icons use lottie animations json for showing player Level … if there is no
/// url, you show empty icon"): the owner's Lottie, [size] square, fitted
/// whole, wherever the app drew the level's emoji — the hero's medal, each
/// rung of the ladder, the lobby's level line and key, the table's tax pill,
/// a player's level in the drawer, the Stats drawer's head, a level up on the
/// mission bar.
///
/// A level the owner has not sent art for yet draws an EMPTY square of the
/// same size, so a row of rungs keeps its column and nothing moves when the
/// art arrives; the emoji is never drawn. Nor is anything drawn while the
/// file loads ([EmojiArt.standIn] off): a smiley would say something the
/// level does not. The file is fetched once per URL and kept on the phone
/// ([EmojiArt] through PictureCache), and a server-relative path — Level 1's,
/// served by the game server — is made absolute first.
///
/// Many of the places it stands rebuild every second (the lobby's foot, the
/// table): it hands back the SAME subtree while what it draws is unchanged,
/// so that tick never rebuilds the Lottie under it (`level_screen_test`'s
/// "rebuilds nothing", with the lobby behind the level screen).
class LevelArt extends StatefulWidget {
  const LevelArt({
    super.key,
    required this.size,
    this.assetUrl = '',
    this.assetFormat = '',
    this.label,
    this.animate = true,
  });

  LevelArt.of(
    PlayerLevel level, {
    Key? key,
    required double size,
    bool animate = true,
  }) : this(
         key: key,
         size: size,
         assetUrl: level.assetUrl,
         assetFormat: level.assetFormat,
         label: level.title,
         animate: animate,
       );

  LevelArt.step(
    LevelStep level, {
    Key? key,
    required double size,
    bool animate = true,
  }) : this(
         key: key,
         size: size,
         assetUrl: level.assetUrl,
         assetFormat: level.assetFormat,
         label: level.title,
         animate: animate,
       );

  LevelArt.rung(
    LadderLevel level, {
    Key? key,
    required double size,
    bool animate = true,
  }) : this(
         key: key,
         size: size,
         assetUrl: level.assetUrl,
         assetFormat: level.assetFormat,
         label: level.title,
         animate: animate,
       );

  LevelArt.profile(
    ProfileLevel level, {
    Key? key,
    required double size,
    bool animate = true,
  }) : this(
         key: key,
         size: size,
         assetUrl: level.assetUrl,
         assetFormat: level.assetFormat,
         label: level.title,
         animate: animate,
       );

  final double size;
  final String assetUrl;
  final String assetFormat;

  /// What a screen reader calls it: the level's title. Most places that draw
  /// it say the level in words beside it and exclude it.
  final String? label;

  /// Whether it plays; false rests it on its first frame.
  final bool animate;

  /// Whether [url] in [format] is art the app draws: a Lottie.
  static bool drawable(String url, String format) =>
      url.isNotEmpty && format.toUpperCase() == 'LOTTIE';

  @override
  State<LevelArt> createState() => _LevelArtState();
}

class _LevelArtState extends State<LevelArt> {
  /// What [_built] was built from.
  (String, String, double, String?, bool)? _inputs;
  Widget? _built;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final inputs = (w.assetUrl, w.assetFormat, w.size, w.label, w.animate);
    if (_inputs != inputs || _built == null) {
      _inputs = inputs;
      _built = _compose(context);
    }
    return _built!;
  }

  Widget _compose(BuildContext context) {
    final w = widget;
    if (!LevelArt.drawable(w.assetUrl, w.assetFormat)) {
      return SizedBox.square(
        key: const ValueKey('level-art-empty'),
        dimension: w.size,
      );
    }
    final url = w.assetUrl.startsWith('/')
        ? context.read<GameState>().absoluteUrl(w.assetUrl)
        : w.assetUrl;
    return EmojiArt(
      key: const ValueKey('level-art'),
      url: url,
      size: w.size,
      animate: w.animate,
      semanticLabel: w.label,
      standIn: false,
    );
  }
}
