// Pictures of the XP mission bar (owner, 27 Sep 2026: "whenever xp mission
// completed, show top notification bar for 5 seconds showing this is
// completed and xp increased") for review: a mission over the lobby, one with
// a level up, and one over the Teen Patti and the poker felts, at 592x360,
// 640x360 and 915x412, both themes, text x1.0 and x1.25, and in Hindi. Not
// part of `flutter test` (the name has no `_test`): run it by hand.
//
//   flutter test test/xp_mission_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=lobby    a substring of the names
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
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/xp_mission_bar.dart';

import 'level_fixtures.dart';
import 'table_scenes.dart' show pokerRoom, seenTurnRoom, silentFeedback;

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

/// Where the bar is shown and the award that raises it; [longLevel] is the
/// tallest bar, on the Teen Patti felt: the longest mission and a long level
/// up with the tax it changed.
enum _Where { lobby, levelUp, table, poker, longLevel }

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
    for (final size in const [Size(592, 360), Size(640, 360), Size(915, 412)])
      for (final dark in [true, false])
        for (final scale in const [1.0, 1.25])
          _Shot(where, size, dark, scale, AppLang.english),
  for (final where in _Where.values)
    _Shot(where, const Size(640, 360), true, 1.25, AppLang.hindi),
  for (final dark in [true, false])
    _Shot(_Where.longLevel, const Size(592, 360), dark, 1.25, AppLang.bengali),
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
  final table = shot.where != _Where.lobby && shot.where != _Where.levelUp;
  final state = levelState(
    level: shot.where == _Where.longLevel
        ? _lv(43, 809992, const {})
        : _lv(1, 90, {'PLAY_15_MIN': 1}),
    lang: shot.lang,
  );
  if (table) {
    state
      ..screen = Screen.table
      ..handleState(shot.where == _Where.poker ? pokerRoom() : seenTurnRoom());
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

  final award = switch (shot.where) {
    _Where.levelUp => _lv(2, 110, {'PLAY_15_MIN': 1, 'WIN_TRAIL': 1}),
    _Where.lobby => _lv(1, 91, {'PLAY_15_MIN': 1, 'WIN_PAIR': 1}),
    _Where.longLevel => _lv(44, 810000, {'WIN_PURE_SEQUENCE': 1}),
    _ => _lv(1, 92, {'PLAY_15_MIN': 1, 'WIN_COLOR': 1}),
  };
  state.handlePlayerLevel(
    Standing.maybe({
      'playerLevel': award,
      'badges': [regularBadge()],
      'taxBps': award['taxBps'],
    })!,
  );
  await tester.pump();
  // At a table the bar waits for the winner's cheer to pass before it comes.
  await tester.pump(XpMissionHost.tableDelay);
  await tester.pump(XpMissionHost.slideIn + const Duration(milliseconds: 600));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
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
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}
