// Pictures of a player's record game by game (player stats v2, owner,
// 27 Sep 2026): the Friends page's profile and the table's player drawer
// (another player's — the lobby's Stats drawer has its own presentation since
// the owner's brief of 27 Sep 2026, pictured by stats_drawer_shots.dart), each in
// its four views — All, Teen Patti, Variation, Poker — and Variation again
// scrolled to its end, where the variations played are; in both themes, at
// text x1.0 and x1.25, on the tightest phone the app is checked on, a larger
// one and a tablet, and in Hindi. Not part of `flutter test` (the name has no
// `_test`): run it by hand.
//
//   flutter test test/player_stats_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=stats-variation   a substring of the
//              names; several, comma-separated, take any of them, and a '+'
//              inside one asks for all its parts (drawer+hi)
//
// Every shot is laid out for real — Inter, the Noto fonts a phone falls back
// to and the Material icons loaded — and written to SHOTS_DIR as a PNG at
// twice the logical size. Anything that overflows or throws is written to
// SHOTS_DIR/problems.txt rather than failing the run.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/player_stats.dart';
import 'package:teenpatti/screens/friends_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/hammer_flight.dart';
import 'package:teenpatti/widgets/player_drawer.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'friends_fixture.dart';
import 'player_stats_fixture.dart';
import 'script_fonts.dart';
import 'table_scenes.dart' show silentFeedback, tableApp;

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');

/// Where the record is shown.
enum _Place {
  /// The lobby's Friends page, on a friend's profile.
  profile,

  /// A table's player drawer, on another player's seat.
  drawer,
}

/// How far down the record the shot is taken.
enum _Scroll {
  /// As it opens: the switch and the figures.
  top,

  /// The hands held in the middle of the view.
  hands,

  /// Its end, where the variations played are.
  end,
}

class _Shot {
  const _Shot(
    this.place,
    this.view,
    this.size,
    this.brightness,
    this.scale, {
    this.scroll = _Scroll.top,
    this.lang = AppLang.english,
  });

  final _Place place;
  final StatsCategory view;
  final Size size;
  final Brightness brightness;
  final double scale;
  final _Scroll scroll;
  final AppLang lang;

  String get file =>
      '${place.name}-${view.name}'
      '${scroll == _Scroll.top ? '' : '-${scroll.name}'}'
      '_${size.width.toInt()}x${size.height.toInt()}_${brightness.name}'
      '_x$scale${lang == AppLang.english ? '' : '_${lang.code}'}.png';
}

List<_Shot> _shots() => [
  for (final place in _Place.values)
    for (final brightness in Brightness.values) ...[
      for (final view in StatsCategory.values)
        _Shot(place, view, const Size(640, 360), brightness, 1.25),
      for (final scroll in const [_Scroll.hands, _Scroll.end])
        _Shot(
          place,
          StatsCategory.variation,
          const Size(640, 360),
          brightness,
          1.25,
          scroll: scroll,
        ),
      _Shot(
        place,
        StatsCategory.teenPatti,
        const Size(891, 411),
        brightness,
        1.0,
      ),
    ],
  for (final place in _Place.values) ...[
    _Shot(
      place,
      StatsCategory.variation,
      const Size(640, 360),
      Brightness.dark,
      1.25,
      lang: AppLang.hindi,
    ),
    for (final scroll in const [_Scroll.hands, _Scroll.end])
      _Shot(
        place,
        StatsCategory.variation,
        const Size(640, 360),
        Brightness.light,
        1.25,
        scroll: scroll,
        lang: AppLang.bengali,
      ),
  ],
  _Shot(
    _Place.profile,
    StatsCategory.variation,
    const Size(1280, 800),
    Brightness.dark,
    1.0,
  ),
  _Shot(
    _Place.drawer,
    StatsCategory.variation,
    const Size(1280, 800),
    Brightness.light,
    1.0,
  ),
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

void main() {
  setUpAll(_loadFonts);
  setUp(() => SharedPreferences.setMockInitialValues({'soundOn': false}));
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

  final key = GlobalKey();
  final server = switch (shot.place) {
    _Place.profile => statsProfileServer(),
    _Place.drawer => statsTableServer(),
  };
  await http.runWithClient(() async {
    late final GameState state;
    switch (shot.place) {
      case _Place.profile:
        state = signedInState(lang: shot.lang);
        final feedback = FeedbackSettings();
        addTearDown(feedback.dispose);
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: statsApp(
              state,
              feedback,
              Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () => showFriends(context),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
              brightness: shot.brightness,
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await _settle(tester, 800);
        final meera = find.byKey(const ValueKey('friend-u-meera'));
        await tester.ensureVisible(meera);
        await _settle(tester, 100);
        await tester.tap(meera);
        await _settle(tester, 800);
      case _Place.drawer:
        state = statsTableState(lang: shot.lang);
        final feedback = await silentFeedback();
        addTearDown(feedback.dispose);
        state.handleState(statsTableRoom());
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: tableApp(
              state: state,
              feedback: feedback,
              theme: statsTheme(shot.brightness),
            ),
          ),
        );
        await _settle(tester, 900);
        await _settle(tester, 900);
        await tester.tap(
          find.descendant(
            of: find.byWidgetPredicate(
              (w) => w is SeatPod && w.seat?.userId == 'u1',
            ),
            matching: find.byType(PodImpact),
          ),
        );
        await _settle(tester, 500);
    }

    final segment = find.byKey(ValueKey('stats-category-${shot.view.name}'));
    await tester.ensureVisible(segment);
    await _settle(tester, 100);
    await tester.tap(segment);
    await _settle(tester, 500);
    final root = switch (shot.place) {
      _Place.profile => find.byType(FriendsScreen),
      _Place.drawer => find.byType(PlayerDrawer),
    };
    final list = find.descendant(of: root, matching: find.byType(Scrollable));
    final position = tester.state<ScrollableState>(list.first).position;
    switch (shot.scroll) {
      case _Scroll.top:
        position.jumpTo(0);
      case _Scroll.hands:
        // The hands held in the middle of what shows.
        await tester.ensureVisible(find.byKey(const ValueKey('stats-hands')));
        await _settle(tester, 100);
        position.jumpTo(
          (position.pixels - position.viewportDimension * 0.2).clamp(
            0,
            position.maxScrollExtent,
          ),
        );
      case _Scroll.end:
        position.jumpTo(position.maxScrollExtent);
    }
    await _settle(tester, 400);
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
  }, () => server.client);
}

Future<void> _settle(WidgetTester tester, int ms) async {
  await tester.pump(const Duration(milliseconds: 16));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 120)),
  );
  await tester.pump(Duration(milliseconds: ms));
}
