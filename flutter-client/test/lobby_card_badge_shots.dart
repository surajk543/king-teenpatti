// Pictures of the lobby's Seen, Blind and Variation cards with the badge that
// brings the player's winning tax lowest in their top-right corner (owner,
// 27 Sep 2026): Regular (20%) and a Royal badge (0%), at 592x360, 640x360,
// 891x411 and 1280x800, both themes, text x1.0 and x1.25, and Hindi.
// Not part of `flutter test` (the name has no `_test`): run it by hand.
//
//   flutter test test/lobby_card_badge_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf \
//     --dart-define=BADGES_DIR=/abs/dir/with/regular.json,king.json…   (optional: the owner's Lotties)
//   (optional) --dart-define=SHOTS_ONLY=regular_640   a substring of the names
//
// Each picture is the whole lobby at twice its size; anything that overflows
// or throws is written to SHOTS_DIR/problems.txt rather than failing the run.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';

import 'level_fixtures.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');
const _badges = String.fromEnvironment('BADGES_DIR');

Map<String, Uint8List> _realBadges() {
  if (_badges.isEmpty) return const {};
  const files = {'REGULAR': 'regular.json', 'ROYAL_KING': 'king.json'};
  return {
    for (final MapEntry(key: code, value: file) in files.entries)
      if (File('$_badges/$file').existsSync())
        code: File('$_badges/$file').readAsBytesSync(),
  };
}

class _Shot {
  const _Shot(
    this.label,
    this.size,
    this.dark,
    this.scale, {
    this.lang = AppLang.english,
  });

  final String label;
  final Size size;
  final bool dark;
  final double scale;
  final AppLang lang;

  String get file =>
      '${label}_${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}';
}

final _shots = [
  for (final size in const [
    Size(592, 360),
    Size(640, 360),
    Size(891, 411),
    Size(1280, 800),
  ])
    for (final dark in [true, false])
      for (final scale in [1.0, 1.25]) _Shot('regular', size, dark, scale),
  for (final dark in [true, false])
    _Shot('royal', const Size(640, 360), dark, 1.25),
  const _Shot('royal', Size(891, 411), true, 1.0),
  const _Shot('regular', Size(640, 360), true, 1.25, lang: AppLang.hindi),
  const _Shot('regular', Size(640, 360), false, 1.25, lang: AppLang.bengali),
];

void main() {
  setUpAll(() async {
    await loadLevelFonts(icons: const String.fromEnvironment('ICON_FONT'));
  });
  tearDownAll(PictureCache.clearMemory);
  final problems = <String>[];
  tearDownAll(() {
    if (_dir.isEmpty) return;
    File('$_dir/problems.txt').writeAsStringSync(
      problems.isEmpty ? 'none\n' : '${problems.join('\n')}\n',
    );
  });

  for (final shot in _shots) {
    if (_only.isNotEmpty &&
        !_only.split(',').any((term) => shot.file.contains(term))) {
      continue;
    }
    testWidgets(shot.file, (tester) async {
      debugDisableShadows = false;
      try {
        await _shoot(tester, shot, problems);
      } finally {
        debugDisableShadows = true;
      }
    });
  }
}

Future<void> _shoot(
  WidgetTester tester,
  _Shot shot,
  List<String> problems,
) async {
  primeBadges(_realBadges());
  final level = levelAt(10, xp: 4180);
  final state = levelState(level: level, lang: shot.lang);
  // The three games, Variation's the longest name.
  state.config = GameConfig.fromJson({
    'maxPlayers': 5,
    'minPlayers': 2,
    'bootAmount': 200,
    'turnTimeoutMs': 25000,
    'tables': [
      for (final (category, boot) in const [
        ('seen', 200),
        ('blind', 200),
        ('blind', 5000),
        ('variation', 50000),
      ])
        {
          'category': category,
          'bootAmount': boot,
          'winnerTax': true,
          'winnerTaxMinWinnings': 5000000,
        },
    ],
  });
  state.user = User.fromJson({
    'id': 'u0',
    'provider': 'guest',
    'displayName': 'Guest0E00B',
    'chips': 324500,
    'diamond': 9,
    'hammer': 20,
    'missile': 1,
    'playerLevel': level,
    'badges': [
      regularBadge(),
      if (shot.label == 'royal')
        royalBadge('ROYAL_KING', const Duration(days: 12)),
    ],
  });
  final boundary = GlobalKey();
  await pumpLevelLobby(
    tester,
    state,
    screen: shot.size,
    scale: shot.scale,
    dark: shot.dark,
    wrap: (child) => RepaintBoundary(key: boundary, child: child),
  );
  await tester.pump(const Duration(seconds: 1));
  final problem = tester.takeException();
  if (problem != null) problems.add('${shot.file}: $problem');
  if (_dir.isNotEmpty) {
    await tester.runAsync(() async {
      final box =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await box.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '$_dir/${shot.file}.png',
      ).writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }
  await unmountLevel(tester, state);
}
