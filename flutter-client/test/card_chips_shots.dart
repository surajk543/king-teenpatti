// Pictures of the owner's casino chips at the top left of the lobby's cards
// (1 Oct 2026: "Use this animation on top left of lobby cards, change colour
// acc to card"): the front's category cards and each category's table cards,
// at 640x360, 891x411 and 1280x800, both themes, text x1.0 and x1.25, and
// Hindi at 640x360 x1.25 — each once with the stack standing and once part
// built. Not part of `flutter test` (the name has no `_test`): run it by hand.
//
//   flutter test test/card_chips_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=640x360   a substring of the names
//
// Each picture is the whole lobby at twice its size; anything that overflows
// or throws is written to SHOTS_DIR/problems.txt rather than failing the run.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/widgets/card_chips.dart';
import 'package:teenpatti/widgets/entry_wallet.dart';
import 'package:teenpatti/widgets/info_wave.dart';
import 'package:teenpatti/widgets/open_lock.dart';
import 'package:teenpatti/widgets/pot_piggy.dart';
import 'package:teenpatti/widgets/rule_book.dart';
import 'package:teenpatti/widgets/shop_mark.dart';

import 'level_fixtures.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');

/// Priya holds 60 Crore: some tables shut to her, some open.
final _menu = GameConfig.fromJson({
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'categories': ['seen', 'blind', 'variation'],
  'tables': [
    {'category': 'seen', 'bootAmount': 200},
    {'category': 'seen', 'bootAmount': 5000, 'maxChips': 50000000},
    {'category': 'blind', 'bootAmount': 200, 'maxChips': 2000000},
    {'category': 'blind', 'bootAmount': 50000, 'maxChips': 2000000000},
    {'category': 'blind', 'bootAmount': 2000000, 'minChips': 500000000},
    {'category': 'variation', 'bootAmount': 50000, 'maxChips': 2000000000},
    {'category': 'variation', 'bootAmount': 2000000, 'minChips': 500000000},
  ],
});

class _Shot {
  const _Shot(this.size, this.dark, this.scale, {this.lang = AppLang.english});

  final Size size;
  final bool dark;
  final double scale;
  final AppLang lang;

  String file(String level, String moment) =>
      '${level}_${moment}_${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}';
}

final _shots = [
  for (final size in const [Size(640, 360), Size(891, 411), Size(1280, 800)])
    for (final dark in [true, false])
      for (final scale in [1.0, 1.25]) _Shot(size, dark, scale),
  const _Shot(Size(640, 360), true, 1.25, lang: AppLang.hindi),
];

void main() {
  setUpAll(() async {
    await loadLevelFonts(icons: const String.fromEnvironment('ICON_FONT'));
    primeBadges();
    // Loaded where async is real, so every test finds the compositions
    // already made (CLAUDE.md §12.3).
    for (final asset in [
      cardChipsAsset,
      openLockAsset,
      entryWalletAsset,
      potPiggyAsset,
      ruleBookAsset,
      infoWaveAsset,
      shopMarkAsset,
    ]) {
      await AssetLottie(asset).load();
    }
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
    final name = shot.file('lobby', '');
    if (_only.isNotEmpty &&
        !_only.split(',').any((term) => name.contains(term))) {
      continue;
    }
    testWidgets(name, (tester) async {
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
  final state = levelState(level: levelAt(10, xp: 4180), lang: shot.lang)
    ..config = _menu;
  final boundary = GlobalKey();
  await pumpLevelLobby(
    tester,
    state,
    screen: shot.size,
    scale: shot.scale,
    dark: shot.dark,
    wrap: (child) => RepaintBoundary(key: boundary, child: child),
  );

  Future<void> grab(String level, String moment) async {
    final problem = tester.takeException();
    if (problem != null) problems.add('${shot.file(level, moment)}: $problem');
    if (_dir.isEmpty) return;
    await tester.runAsync(() async {
      final box =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await box.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '$_dir/${shot.file(level, moment)}.png',
      ).writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  // The lobby has stood two seconds: the stack is built and standing.
  await grab('front', 'standing');
  for (final category in const ['seen', 'blind', 'variation']) {
    state.openLobbyCategory(category);
    // Each level's rail is new, so its chips start their loop afresh: three
    // fifths of a second in, part built; two seconds in, standing.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await grab(category, 'building');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 700));
    await grab(category, 'standing');
  }
  await unmountLevel(tester, state);
}
