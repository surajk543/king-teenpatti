// Pictures of the lobby's top bar with the player's level and XP bar under
// their name (owner, 27 Sep 2026: "In the Lobby on Top show current level of
// player and xp progress bar for next level"): Level 10 part-way at 640x360,
// 891x411 and 1280x800, both themes, text x1.0 and x1.25; Hindi at 640x360
// x1.25; the top of the ladder, the first level, and the ladder not yet read.
// Not part of `flutter test` (the name has no `_test`): run it by hand.
//
//   flutter test test/lobby_level_bar_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=L10_640   a substring of the names
//
// Each picture is the whole lobby at twice its size; anything that overflows
// or throws is written to SHOTS_DIR/problems.txt rather than failing the run.
import 'dart:io';
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

class _Shot {
  const _Shot(
    this.label,
    this.level,
    this.size,
    this.dark,
    this.scale, {
    this.lang = AppLang.english,
    this.ladder = true,
    this.name = 'Guest0E00B',
  });

  final String label;
  final Map<String, Object?> Function() level;
  final Size size;
  final bool dark;
  final double scale;
  final AppLang lang;
  final bool ladder;
  final String name;

  String get file =>
      '${label}_${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}';
}

Map<String, Object?> _l10() => levelAt(10, xp: 4180);

final _shots = [
  for (final size in const [Size(640, 360), Size(891, 411), Size(1280, 800)])
    for (final dark in [true, false])
      for (final scale in [1.0, 1.25]) _Shot('L10', _l10, size, dark, scale),
  const _Shot('L10', _l10, Size(640, 360), true, 1.25, lang: AppLang.hindi),
  _Shot(
    'L50',
    () => levelAt(50, xp: 2150000),
    const Size(640, 360),
    true,
    1.25,
  ),
  _Shot('L1', () => levelAt(1, xp: 23), const Size(891, 411), false, 1.0),
  _Shot(
    'L49',
    () => levelAt(49, xp: 1850000),
    const Size(592, 360),
    true,
    1.25,
    name: 'Vikramaditya Singh Ratho',
  ),
  _Shot(
    'L49',
    () => levelAt(49, xp: 1850000),
    const Size(732, 412),
    true,
    1.25,
    lang: AppLang.bengali,
  ),
  _Shot(
    'L49',
    () => levelAt(49, xp: 1850000),
    const Size(592, 360),
    false,
    1.25,
    lang: AppLang.hindi,
  ),
  const _Shot('noladder', _l10, Size(640, 360), true, 1.0, ladder: false),
];

void main() {
  setUpAll(() async {
    await loadLevelFonts(icons: const String.fromEnvironment('ICON_FONT'));
    primeBadges();
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
  final state = levelState(
    level: shot.level(),
    lang: shot.lang,
    withLadder: shot.ladder,
  );
  state.user = User.fromJson({
    'id': 'u0',
    'provider': 'guest',
    'displayName': shot.name,
    'chips': 324500,
    'diamond': 9,
    'hammer': 20,
    'missile': 1,
    'playerLevel': shot.level(),
    'badges': [regularBadge()],
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
