// Pictures of the level screen (the lobby's level key's popup, polished
// 27 Sep 2026) for review: each tab — My level at levels 1, 25 and 50, the
// daily XP part-earned and complete, All levels at the viewer's rung and at
// the badges, a Royal badge held — at 891x411 and 640x360, both themes, text
// x1.0, and in Hindi at 640x360 x1.25; and the table's tax popup, which keeps
// its two panes, at 891x411. Not part of `flutter test` (the name has no
// `_test`): run it by hand.
//
//   flutter test test/level_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=BADGES_DIR=/abs/dir   the owner's badge Lotties
//              (regular.json, ace.json, king.json …); a gold disc without
//   (optional) --dart-define=SHOTS_ONLY=mine_L1    a substring of the names
//
// Anything that overflows or throws is written to SHOTS_DIR/problems.txt
// rather than failing the run.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_tax.dart';

import 'level_fixtures.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');
const _badges = String.fromEnvironment('BADGES_DIR');

/// One picture: who the player is, which tab, and what is done first.
class _Scene {
  const _Scene(
    this.name, {
    required this.level,
    this.badges,
    this.taxBps,
    this.tab = 'mine',
    this.jumpToBadges = false,
    this.table = false,
    this.missions = false,
    this.scrollTo,
  });

  final String name;
  final Map<String, Object?> Function() level;
  final List<Map<String, Object?>> Function()? badges;
  final int? taxBps;
  final String tab;
  final bool jumpToBadges;
  final bool table;

  /// The ladder of a server with the one-time missions (28 Sep 2026).
  final bool missions;

  /// A key to bring into view before the picture.
  final String? scrollTo;
}

/// Level 10 with some one-time missions done, some part-way, the rest
/// untouched.
Map<String, Object?> _someMissions() => levelAt(
  10,
  into: 180,
  claimed: ['PLAY_15_MIN', 'WIN_PAIR'],
  missions: [
    missionAt('FIRST_HAND', 1, 1, completed: true, xpAwarded: 5),
    missionAt('FIRST_WIN', 1, 1, completed: true, xpAwarded: 10),
    missionAt('GETTING_STARTED', 7, 10),
    missionAt('FIRST_5_WINS', 3, 5),
    missionAt('CARD_PLAYER', 12, 50),
    missionAt('GAME_EXPLORER', 2, 3),
  ],
);

final _scenes = [
  _Scene('mine_L1', level: () => levelAt(1, xp: 23)),
  _Scene(
    'mine_L25',
    level: () => levelAt(25, into: 6400, claimed: ['PLAY_15_MIN']),
    badges: () => [
      regularBadge(),
      royalBadge('ROYAL_KING', const Duration(days: 12, hours: 3)),
    ],
    taxBps: 0,
  ),
  _Scene(
    'mine_L50',
    level: () => levelAt(50, xp: 2150000),
    badges: () => [regularBadge()],
  ),
  _Scene(
    'royal',
    level: () => levelAt(10, into: 180),
    badges: () => [
      regularBadge(),
      royalBadge('ROYAL_ACE', const Duration(days: 5, hours: 2)),
      royalBadge('ROYAL_KING', const Duration(hours: 5, minutes: 10)),
    ],
    taxBps: 0,
  ),
  _Scene(
    'daily_partial',
    level: () => levelAt(
      10,
      into: 180,
      claimed: ['PLAY_15_MIN', 'PLAY_60_MIN', 'WIN_PAIR'],
    ),
    tab: 'daily',
  ),
  _Scene(
    'daily_complete',
    level: () => levelAt(10, into: 180, claimed: allSourceCodes),
    tab: 'daily',
  ),
  _Scene(
    'daily_idle',
    level: () => levelAt(3, into: 40, resetsIn: null),
    tab: 'daily',
  ),
  // The one-time missions (28 Sep 2026): some done, some part-way, the rest
  // untouched, on the One-Time XP tab beside Daily XP — its top, and its end.
  _Scene('one_time', level: _someMissions, tab: 'oneTime', missions: true),
  _Scene(
    'one_time_end',
    level: _someMissions,
    tab: 'oneTime',
    missions: true,
    scrollTo: 'xp-mission-GAME_EXPLORER',
  ),
  _Scene('ladder_you', level: () => levelAt(10, into: 180), tab: 'ladder'),
  _Scene(
    'ladder_badges',
    level: () => levelAt(10, into: 180),
    badges: () => [
      regularBadge(),
      royalBadge('ROYAL_ACE', const Duration(days: 5)),
    ],
    taxBps: 0,
    tab: 'ladder',
    jumpToBadges: true,
  ),
  _Scene('table', level: () => levelAt(10, into: 180), table: true),
];

class _Shot {
  const _Shot(this.scene, this.size, this.dark, this.scale, this.lang);
  final _Scene scene;
  final Size size;
  final bool dark;
  final double scale;
  final AppLang lang;

  String get name =>
      '${scene.name}_${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}';
}

List<_Shot> _shots() => [
  for (final scene in _scenes)
    if (scene.table)
      for (final dark in [true, false])
        _Shot(scene, const Size(891, 411), dark, 1.0, AppLang.english)
    else ...[
      for (final size in const [Size(891, 411), Size(640, 360)])
        for (final dark in [true, false])
          _Shot(scene, size, dark, 1.0, AppLang.english),
      _Shot(scene, const Size(640, 360), true, 1.25, AppLang.hindi),
    ],
];

Map<String, Uint8List> _realBadges() {
  if (_badges.isEmpty) return const {};
  final files = {
    'REGULAR': 'regular.json',
    'ROYAL_ACE': 'ace.json',
    'ROYAL_KING': 'king.json',
    'ROYAL_MASTER': 'master.json',
    'ROYAL_EMPEROR': 'emperor.json',
    'ROYAL_LEGEND': 'legend.json',
    'ROYAL_KING_OF_KINGS': 'kingofkings.json',
  };
  return {
    for (final MapEntry(key: code, value: file) in files.entries)
      if (File('$_badges/$file').existsSync())
        code: File('$_badges/$file').readAsBytesSync(),
  };
}

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
  primeBadges(_realBadges());
  final scene = shot.scene;
  final state = levelState(
    level: scene.level(),
    badges: scene.badges?.call(),
    taxBps: scene.taxBps,
    lang: shot.lang,
    ladderRead: ladder(withMissions: scene.missions),
  );
  final boundary = GlobalKey();
  Widget wrap(Widget child) => RepaintBoundary(key: boundary, child: child);

  if (scene.table) {
    tester.view.physicalSize = shot.size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = shot.scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final feedback = FeedbackSettings();
    addTearDown(feedback.dispose);
    await tester.pumpWidget(
      wrap(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GameState>.value(value: state),
            ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: levelTheme(dark: shot.dark),
            builder: (context, child) => GlassBudget(child: child!),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    key: const ValueKey('open'),
                    onPressed: () => showWinningTaxInfo(context),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 800));
  } else {
    await pumpLevelLobby(
      tester,
      state,
      screen: shot.size,
      scale: shot.scale,
      dark: shot.dark,
      wrap: wrap,
    );
    await openLevelScreen(tester);
    if (scene.tab != 'mine') await showLevelTab(tester, scene.tab);
    if (scene.jumpToBadges) {
      await tester.tap(find.byKey(const ValueKey('ladder-jump-badges')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    }
    if (scene.scrollTo case final key?) {
      await tester.ensureVisible(
        find.byKey(ValueKey(key), skipOffstage: false),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }
  }
  // Real async for a moment, so the badges' Lotties can be decoded.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );
  await tester.pump(const Duration(milliseconds: 300));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 60)),
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
  await unmountLevel(tester, state);
}
