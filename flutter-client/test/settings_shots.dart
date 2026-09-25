// Pictures of the lobby's Settings drawer (the settings polish, 26 Sep 2026):
// open at its top and scrolled to its end, in the dark, light and System
// themes, at the landscape sizes the app is checked on and a tablet, at text
// x1.0 and x1.25, in Hindi at the tightest size, with the number format
// collapsed and opened, and with the keyboard up under the name field — and,
// to prove the widgets the drawer shares, the Stats drawer, the table's menu
// drawer and the login screen once per theme. Not part of `flutter test` (the
// name has no `_test`): run it by hand.
//
//   flutter test test/settings_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=settings-top   a substring of the names;
//              several, comma-separated, take any of them, and a '+' inside
//              one asks for all its parts (settings-end+640x360)
//
// Every shot is laid out for real — the whole screen, Inter, the Noto fonts a
// phone falls back to and the Material icons loaded — and written to SHOTS_DIR
// as a PNG at twice the logical size. Anything that overflows or throws is
// written to SHOTS_DIR/problems.txt rather than failing the run.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/login_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

import 'script_fonts.dart';
import 'table_scenes.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');

/// Which theme a shot is in: the two the player can pick, and System, which
/// follows the phone — shown here on a phone in its light theme, so the
/// switcher's System segment is the one lit.
enum _Look { dark, light, system }

/// What the shot shows.
enum _View {
  /// The Settings drawer as it opens.
  top,

  /// The Settings drawer scrolled to its end.
  end,

  /// Scrolled to GAME EXPERIENCE: the number format's row, closed, and the
  /// two switches.
  middle,

  /// The number format opened in place.
  numbers,

  /// The keyboard up under the name field.
  keyboard,

  /// The Stats drawer.
  stats,

  /// The table's menu drawer, which shares the switches and the switcher.
  table,

  /// The table's menu drawer scrolled to its end, where they are.
  tableEnd,

  /// The login screen, which shares the switcher.
  login,
}

class _Shot {
  const _Shot(
    this.view,
    this.size,
    this.look,
    this.scale, {
    this.lang = AppLang.english,
  });
  final _View view;
  final Size size;
  final _Look look;
  final double scale;
  final AppLang lang;

  String get file =>
      '${switch (view) {
        _View.top => 'settings-top',
        _View.end => 'settings-end',
        _View.middle => 'settings-middle',
        _View.numbers => 'settings-numbers',
        _View.keyboard => 'settings-keyboard',
        _View.stats => 'stats',
        _View.table => 'table-menu',
        _View.tableEnd => 'table-menu-end',
        _View.login => 'login',
      }}_${size.width.toInt()}x${size.height.toInt()}_${look.name}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}.png';
}

const _sizes = [
  Size(640, 360),
  Size(891, 411),
  Size(592, 360),
  Size(915, 412),
  Size(1280, 800),
];

List<_Shot> _shots() => [
  for (final view in const [_View.top, _View.middle, _View.end])
    for (final size in _sizes)
      for (final look in _Look.values)
        for (final scale in [1.0, 1.25]) _Shot(view, size, look, scale),
  for (final view in const [_View.top, _View.middle, _View.end, _View.numbers])
    for (final look in const [_Look.dark, _Look.light])
      _Shot(view, const Size(640, 360), look, 1.25, lang: AppLang.hindi),
  for (final size in const [Size(640, 360), Size(891, 411)])
    for (final look in const [_Look.dark, _Look.light])
      for (final scale in [1.0, 1.25]) _Shot(_View.numbers, size, look, scale),
  for (final look in const [_Look.dark, _Look.light])
    for (final scale in [1.0, 1.25])
      _Shot(_View.keyboard, const Size(640, 360), look, scale),
  for (final view in const [
    _View.stats,
    _View.table,
    _View.tableEnd,
    _View.login,
  ])
    for (final look in const [_Look.dark, _Look.light])
      _Shot(view, const Size(640, 360), look, 1.0),
  _Shot(_View.stats, const Size(640, 360), _Look.dark, 1.25),
  _Shot(_View.tableEnd, const Size(640, 360), _Look.dark, 1.25),
  _Shot(_View.tableEnd, const Size(891, 411), _Look.light, 1.25),
  _Shot(_View.login, const Size(891, 411), _Look.light, 1.25),
];

Future<void> _loadFonts() async {
  await loadScriptFonts();
  final icons = File(const String.fromEnvironment('ICON_FONT'));
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
}

ThemeData _theme(Brightness b) => withScriptFallback(
  b == Brightness.dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false),
);

GameState _lobbyState(_Shot shot) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = shot.lang
    ..screen = shot.view == _View.login ? Screen.login : Screen.lobby
    ..themeMode = switch (shot.look) {
      _Look.dark => ThemeMode.dark,
      _Look.light => ThemeMode.light,
      _Look.system => ThemeMode.system,
    }
    ..appVersion = '1.2.3 (10)'
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
        {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
      ],
    })
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Guest0E00B',
      'chips': 3245000,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
      'handsPlayed': 128,
      'handsWon': 41,
      'handsLost': 79,
      'handsLeftMid': 8,
      'totalWinnings': 4520000,
      'biggestPot': 385000,
    });
}

void main() {
  setUpAll(_loadFonts);
  final problems = <String>[];
  tearDownAll(() {
    if (_dir.isEmpty) return;
    File('$_dir/problems.txt').writeAsStringSync(
      problems.isEmpty ? 'none\n' : '${problems.join('\n')}\n',
    );
  });

  bool wanted(String file) =>
      _only.isEmpty ||
      _only
          .split(',')
          .any((term) => term.split('+').every((part) => file.contains(part)));

  for (final shot in _shots()) {
    if (!wanted(shot.file)) continue;
    testWidgets(shot.file, (tester) async {
      // The test binding draws every shadow as a solid block unless told not
      // to; a picture wants them soft.
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
  tester.view.physicalSize = shot.size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = shot.scale;
  tester.platformDispatcher.platformBrightnessTestValue =
      shot.look == _Look.dark ? Brightness.dark : Brightness.light;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final brightness = shot.look == _Look.dark
      ? Brightness.dark
      : Brightness.light;

  final key = GlobalKey();
  late final GameState state;
  if (shot.view == _View.table || shot.view == _View.tableEnd) {
    final scene = tableScenes.firstWhere((s) => s.name == '10-menu-drawer');
    state = sceneState(scene, lang: shot.lang)
      ..themeMode = brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light;
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: tableApp(
          state: state,
          feedback: feedback,
          theme: _theme(brightness),
        ),
      ),
    );
    await _settle(tester, 900);
    await _settle(tester, 900);
    await scene.act!(tester, state);
    if (shot.view == _View.tableEnd) {
      final list = find.descendant(
        of: find.byType(TableDrawer),
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(list.first).position;
      position.jumpTo(position.maxScrollExtent);
      await _settle(tester, 400);
    }
  } else {
    state = _lobbyState(shot);
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MultiProvider(
          providers: [
            ChangeNotifierProvider<GameState>.value(value: state),
            ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(Brightness.light),
            darkTheme: _theme(Brightness.dark),
            themeMode: state.themeMode,
            // As the app mounts it (main.dart): the text scale clamped to the
            // app's ceiling, the one glass budget, and the root Scaffold the
            // toasts are painted on.
            builder: (context, child) => MediaQuery.withClampedTextScaling(
              minScaleFactor: 0.9,
              maxScaleFactor: 1.25,
              child: GlassBudget(
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  resizeToAvoidBottomInset: false,
                  body: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
            home: shot.view == _View.login
                ? const LoginScreen()
                : const LobbyScreen(),
          ),
        ),
      ),
    );
    await _settle(tester, 900);
    await _settle(tester, 900);
    switch (shot.view) {
      case _View.login || _View.table || _View.tableEnd:
        break;
      case _View.stats:
        await tester.tap(find.byIcon(Icons.insights_outlined).first);
        await _settle(tester, 700);
      case _View.top ||
          _View.middle ||
          _View.end ||
          _View.numbers ||
          _View.keyboard:
        await tester.tap(find.byIcon(Icons.tune_rounded).first);
        await _settle(tester, 700);
    }
    if (shot.view == _View.middle || shot.view == _View.numbers) {
      // GAME EXPERIENCE at the top of the list. Below the fold at first:
      // built, but offstage to a default finder.
      final t = state.t;
      final label = find.text(
        shot.lang == AppLang.english
            ? t.settingsGameExperience.toUpperCase()
            : t.settingsGameExperience,
        skipOffstage: false,
      );
      await tester.ensureVisible(label);
      await _settle(tester, 300);
      if (shot.view == _View.numbers) {
        await tester.tap(find.text(t.numberSystem));
        await _settle(tester, 600);
      }
    }
    if (shot.view == _View.end) {
      final list = find.descendant(
        of: find.byType(Drawer),
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(list.first).position;
      position.jumpTo(position.maxScrollExtent);
      await _settle(tester, 400);
    }
    if (shot.view == _View.keyboard) {
      // A landscape phone's keyboard: a little over half the screen's height.
      await tester.tap(
        find.descendant(
          of: find.byType(Drawer),
          matching: find.byType(TextField),
        ),
      );
      await _settle(tester, 100);
      tester.view.viewInsets = FakeViewPadding(
        bottom: (shot.size.height * 0.53).roundToDouble(),
      );
      await _settle(tester, 400);
      await _settle(tester, 400);
    }
  }
  await _settle(tester, 300);
  final problem = tester.takeException();
  if (problem != null) problems.add('${shot.file}: $problem');

  if (_dir.isNotEmpty) {
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_dir/${shot.file}').writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  final late = tester.takeException();
  if (late != null) problems.add('${shot.file} (teardown): $late');
  state.dispose();
}

Future<void> _settle(WidgetTester tester, int ms) async {
  await tester.pump(const Duration(milliseconds: 16));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );
  await tester.pump(Duration(milliseconds: ms));
}
