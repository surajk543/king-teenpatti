// Pictures of the lobby's Stats drawer (the owner's brief, 27 Sep 2026: one
// continuous player profile, a small scope menu, no Poker): each of the three
// scopes, the menu open, the Variations scope scrolled to its list and an
// account with no record yet — by night and by day, at the landscape sizes the
// app is checked on — and in Hindi at the tightest size and the largest text.
// Not part of `flutter test` (the name has no `_test`): run it by hand.
//
//   flutter test test/stats_drawer_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=menu   a substring of the names;
//              several, comma-separated, take any of them, and a '+' inside
//              one asks for all its parts (menu+640x360)
//
// Every shot is laid out for real — the whole lobby, Inter, the Noto fonts a
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
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';
import 'stats_drawer_fixture.dart';
import 'table_scenes.dart' show silentFeedback;

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');

/// What the shot shows.
enum _View {
  /// All Games, as the drawer opens.
  all,

  /// Teen Patti chosen.
  teenPatti,

  /// Variations chosen.
  variations,

  /// The scope menu open over the record.
  menu,

  /// Variations chosen and the drawer scrolled to its end.
  variationsEnd,

  /// A new account: nothing played yet, in the Variations scope.
  empty,

  /// A new account in All Games.
  emptyAll,

  /// A player of years ([bigCountsJson]): Variations chosen and scrolled to
  /// its hand results, in four to six figures.
  bigCounts,
}

class _Shot {
  const _Shot(
    this.view,
    this.size,
    this.brightness,
    this.scale, {
    this.lang = AppLang.english,
  });
  final _View view;
  final Size size;
  final Brightness brightness;
  final double scale;
  final AppLang lang;

  String get file =>
      'stats-${view.name}_${size.width.toInt()}x${size.height.toInt()}_'
      '${brightness.name}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}.png';
}

List<_Shot> _shots() => [
  for (final view in _View.values.where((v) => v != _View.bigCounts))
    for (final size in const [Size(891, 411), Size(640, 360)])
      for (final b in Brightness.values) _Shot(view, size, b, 1.0),
  for (final view in const [_View.all, _View.variations, _View.menu])
    for (final b in Brightness.values)
      _Shot(view, const Size(640, 360), b, 1.25, lang: AppLang.hindi),
  for (final view in const [_View.all, _View.variationsEnd])
    for (final b in Brightness.values) ...[
      _Shot(view, const Size(592, 360), b, 1.25),
      _Shot(view, const Size(1280, 800), b, 1.0),
    ],
  _Shot(_View.menu, const Size(640, 360), Brightness.dark, 1.25),
  for (final size in const [Size(592, 360), Size(640, 360)])
    for (final b in Brightness.values) _Shot(_View.bigCounts, size, b, 1.25),
  _Shot(_View.all, const Size(640, 360), Brightness.light, 1.25),
];

Future<void> _loadFonts() async {
  await loadScriptFonts();
  final icons = File(const String.fromEnvironment('ICON_FONT'));
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
  // The level's mark and the badges' are colour emoji, as a phone draws them.
  final emoji = File('/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf');
  if (emoji.existsSync()) {
    final loader = FontLoader('Noto Color Emoji')
      ..addFont(Future.value(ByteData.sublistView(emoji.readAsBytesSync())));
    await loader.load();
  }
}

ThemeData _theme(Brightness b) {
  final base = withScriptFallback(
    b == Brightness.dark
        ? AppTheme.dark(sound: false)
        : AppTheme.light(sound: false),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamilyFallback: [...scriptFonts.keys, 'Noto Color Emoji'],
    ),
  );
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
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final empty = shot.view == _View.empty || shot.view == _View.emptyAll;
  final state = statsDrawerState(
    lang: shot.lang,
    me: empty
        ? newAccountJson()
        : shot.view == _View.bigCounts
        ? bigCountsJson()
        : guestWithStatsJson(),
  );

  final key = GlobalKey();
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
          themeMode: shot.brightness == Brightness.dark
              ? ThemeMode.dark
              : ThemeMode.light,
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
          home: const LobbyScreen(),
        ),
      ),
    ),
  );
  await _settle(tester, 900);
  await _settle(tester, 900);
  await tester.tap(find.byIcon(Icons.insights_outlined).first);
  await _settle(tester, 700);
  await _settle(tester, 500);

  Future<void> choose(String scope) async {
    await tester.tap(find.byKey(const ValueKey('stats-scope')));
    await _settle(tester, 300);
    await tester.tap(find.byKey(ValueKey('stats-scope-option-$scope')));
    await _settle(tester, 400);
  }

  switch (shot.view) {
    case _View.all || _View.emptyAll:
      break;
    case _View.teenPatti:
      await choose('teenPatti');
    case _View.variations || _View.empty:
      await choose('variations');
    case _View.bigCounts:
      await choose('variations');
      await tester.ensureVisible(find.byKey(const ValueKey('stats-hands')));
      await _settle(tester, 400);
    case _View.menu:
      await tester.tap(find.byKey(const ValueKey('stats-scope')));
      await _settle(tester, 300);
    case _View.variationsEnd:
      await choose('variations');
      final list = find.descendant(
        of: find.byType(Drawer),
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(list.first).position;
      position.jumpTo(position.maxScrollExtent);
      await _settle(tester, 400);
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
