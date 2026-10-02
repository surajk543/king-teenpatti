// Pictures of the level-up popup (owner, 2 Oct 2026: "Use this animation to
// COngrats Player once his level upgraded , show a pop in UI, and Tell in pop
// up that … now you will pay less tax and how much less tax u pay") for
// review: over the lobby and over a Teen Patti table, a level up that lowers
// the tax and one under a Royal badge, at 592x360, 640x360, 891x411 and
// 1280x800, both themes, text x1.0 and x1.25, and in Hindi and Bengali. Not
// part of `flutter test` (the name has no `_test`): run it by hand.
//
//   flutter test test/level_up_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=table    a substring of the names
//
// Anything that overflows or throws is written to SHOTS_DIR/problems.txt
// rather than failing the run.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/level_up_popup.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/xp_mission_bar.dart';

import 'level_fixtures.dart';
import 'table_scenes.dart' show seenTurnRoom, silentFeedback;

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');

final int _window = DateTime.now().millisecondsSinceEpoch + 20 * hourMs;

Map<String, Object?> _lv(int level, int xp, Map<String, int> claimed) {
  final (n, _, title, icon, taxBps) = ownersLevels[level - 1];
  final next = ownersLevels[level];
  return {
    'level': n,
    'title': title,
    'icon': icon,
    'xp': xp,
    'taxBps': taxBps,
    'assetUrl': levelArtUrl(level),
    'assetFormat': 'LOTTIE',
    'next': {
      'level': next.$1,
      'title': next.$3,
      'icon': next.$4,
      'minXp': next.$2,
      'taxBps': next.$5,
    },
    'daily': {'claimed': claimed, 'resetsAt': _window},
  };
}

/// Where the popup is shown and what it tells: a level up that lowers the
/// tax, over the lobby and over a table; one under a Royal badge, which
/// keeps the rate at 0%; and a long level name high up the ladder.
enum _Where { lobby, table, badge, longLevel }

class _Shot {
  const _Shot(this.where, this.size, this.dark, this.scale, this.lang);
  final _Where where;
  final Size size;
  final bool dark;
  final double scale;
  final AppLang lang;

  String get name =>
      '${where.name}_${size.width.toInt()}x${size.height.toInt()}'
      '_${dark ? 'dark' : 'light'}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}';
}

List<_Shot> _shots() => [
  for (final where in _Where.values)
    for (final size in const [Size(640, 360), Size(891, 411)])
      for (final dark in [true, false])
        _Shot(where, size, dark, 1.0, AppLang.english),
  for (final size in const [Size(592, 360), Size(1280, 800)])
    for (final dark in [true, false])
      _Shot(_Where.lobby, size, dark, 1.25, AppLang.english),
  for (final lang in [AppLang.hindi, AppLang.bengali])
    for (final where in [_Where.lobby, _Where.badge])
      _Shot(where, const Size(640, 360), true, 1.25, lang),
];

void main() {
  setUpAll(() async {
    await loadLevelFonts(icons: const String.fromEnvironment('ICON_FONT'));
  });
  final problems = <String>[];
  tearDownAll(() {
    if (_dir.isEmpty) return;
    File('$_dir/problems.txt').writeAsStringSync(
      problems.isEmpty ? 'none\n' : '${problems.join('\n')}\n',
    );
  });

  for (final shot in _shots()) {
    if (_only.isNotEmpty &&
        !_only.split(',').any((term) => shot.name.contains(term))) {
      continue;
    }
    testWidgets(shot.name, (tester) async {
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
  primeBadges();
  primeLevelArt();
  final royal = [
    regularBadge(),
    royalBadge('ROYAL_ACE', const Duration(days: 3)),
  ];
  final badged = shot.where == _Where.badge;
  final long = shot.where == _Where.longLevel;
  final state = levelState(
    level: long ? _lv(43, 809992, const {}) : _lv(1, 90, {'PLAY_15_MIN': 1}),
    lang: shot.lang,
    badges: badged ? royal : null,
    taxBps: badged ? 0 : null,
  );
  final table = shot.where == _Where.table;
  if (table) {
    state
      ..screen = Screen.table
      ..handleState(seenTurnRoom());
  }
  tester.view.physicalSize = shot.size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = shot.scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final boundary = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<GameState>.value(value: state),
          ChangeNotifierProvider.value(value: feedback),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: levelTheme(dark: shot.dark),
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            minScaleFactor: 0.9,
            maxScaleFactor: 1.25,
            child: GlassBudget(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Scaffold(
                    backgroundColor: Colors.transparent,
                    resizeToAvoidBottomInset: false,
                    body: child ?? const SizedBox.shrink(),
                  ),
                  const XpMissionHost(),
                  const LevelUpHost(),
                ],
              ),
            ),
          ),
          home: table ? const TableScreen() : const LobbyScreen(),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));

  final award = long
      ? _lv(44, 810000, {'WIN_PURE_SEQUENCE': 1})
      : _lv(2, 110, {'PLAY_15_MIN': 1, 'WIN_TRAIL': 1});
  state.handlePlayerLevel(
    Standing.maybe({
      'playerLevel': award,
      'badges': badged ? royal : [regularBadge()],
      'taxBps': badged ? 0 : award['taxBps'],
    })!,
  );
  await tester.pump();
  // At a table the popup waits for the hand's end to be seen first.
  await tester.pump(LevelUpHost.tableDelay);
  await tester.pump(LevelUpHost.enter + const Duration(milliseconds: 900));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );
  await tester.pump(const Duration(milliseconds: 16));

  final problem = tester.takeException();
  if (problem != null) problems.add('${shot.name}: $problem');
  if (_dir.isNotEmpty) {
    await tester.runAsync(() async {
      final box =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await box.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '$_dir/${shot.name}.png',
      ).writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 20));
  state.dispose();
}
