// Pictures of the two picture shelves (the store polish, 26 Sep 2026): the
// store's Pictures shelf over the lobby, its Animated shelf at a table, the
// lobby's picture picker (the same shelf), and the Tables shelf — with every
// state a tile can be in: the picture being worn, owned for good, a rental
// with days or hours left, and locked at a price in chips, hammers and
// diamonds, with and without a term; the table shelf with a cloth in use, one
// owned and waiting, locked ones in each wallet, and the Flowing chips tile.
// At the landscape phone sizes the game is checked on and a tablet, in both
// themes, at text x1.0 and x1.25, and in Hindi at the tightest size. Not part
// of `flutter test` (the name has no `_test`): run it by hand.
//
//   flutter test test/picture_shelf_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=01-pictures   a substring of the names;
//              several, comma-separated, take any of them, and a '+' inside
//              one asks for all its parts (01-pictures+_dark_x1.25)
//
// The files the catalogues point at are the repo's own — the animal SVGs the
// browser client serves, the generated table SVGs and the app's own Lottie
// animations — primed into the picture cache, so nothing is fetched. Anything
// that overflows or throws is written to SHOTS_DIR/problems.txt rather than
// failing the run.
import 'dart:async';
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
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';
import 'table_scenes.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');

/// One thing to photograph: a shelf of the store or the lobby's picker, where
/// it was opened from, how far down it is scrolled, and whose picture is on.
class _Scene {
  const _Scene(
    this.name,
    this.tab, {
    this.atTable = false,
    this.picker = false,
    this.scroll = 0,
    this.wornFree = false,
    this.noTable = false,
  });

  final String name;
  final StoreTab tab;

  /// Opened at a table (its Animated shelf), rather than over the lobby.
  final bool atTable;

  /// The lobby's picture picker instead of the store.
  final bool picker;

  /// How far down the shelf is scrolled: 0 its top, 1 its foot.
  final double scroll;

  /// A free picture is being worn, rather than a premium rental.
  final bool wornFree;

  /// No table picture is laid: the Flowing chips are in use.
  final bool noTable;
}

const _scenes = [
  _Scene('01-pictures', StoreTab.pictures),
  _Scene('02-pictures-end', StoreTab.pictures, scroll: 1),
  _Scene('03-animated', StoreTab.pictures, atTable: true),
  _Scene('04-picker', StoreTab.pictures, picker: true),
  _Scene('05-picker-free', StoreTab.pictures, picker: true, wornFree: true),
  _Scene('06-tables', StoreTab.tables),
  _Scene('07-tables-mid', StoreTab.tables, scroll: 0.5),
  _Scene('07-tables-end', StoreTab.tables, scroll: 1),
  _Scene('08-tables-chips', StoreTab.tables, noTable: true),
];

class _Shot {
  const _Shot(
    this.scene,
    this.size,
    this.dark,
    this.scale, {
    this.lang = AppLang.english,
  });
  final _Scene scene;
  final Size size;
  final bool dark;
  final double scale;
  final AppLang lang;

  String get file =>
      '${scene.name}_${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x$scale'
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
  for (final scene in _scenes)
    for (final size in _sizes)
      for (final dark in [true, false])
        for (final scale in [1.0, 1.25]) _Shot(scene, size, dark, scale),
  for (final scene in _scenes)
    for (final dark in [true, false])
      _Shot(scene, const Size(640, 360), dark, 1.25, lang: AppLang.hindi),
];

const _repo = '../';
const _profiles = '${_repo}go-server/public/profiles';
const _tables = '${_repo}go-server/public/tables';
const _animations = 'assets/animations';

String _pic(String file) => 'https://pictures.test/$file';

Future<void> _primePictures() async {
  void prime(String url, String path) {
    final file = File(path);
    if (file.existsSync()) PictureCache.prime(url, file.readAsBytesSync());
  }

  for (final animal in const [
    'bear', 'cat', 'dog', 'fox', 'frog', 'horse', 'koala', 'lion', //
    'monkey', 'owl', 'panda', 'penguin', 'rabbit', 'tiger', 'wolf',
  ]) {
    prime(_pic('$animal.svg'), '$_profiles/$animal.svg');
  }
  for (final table in const [
    'royal-sapphire', 'emerald-lattice', 'midnight-gold', 'royal-purple', //
    'sunset-marble', 'carbon-weave', 'classic-baize', 'oxblood-club',
  ]) {
    prime(_pic('$table-day.svg'), '$_tables/$table-day.svg');
    prime(_pic('$table-night.svg'), '$_tables/$table-night.svg');
  }
  for (final (url, file) in const [
    ('hammer.json', 'Hammer.json'),
    ('missile.json', 'Missile.json'),
    ('message.json', 'Message.json'),
    ('chips.json', 'Poker Chip Shuffle.json'),
  ]) {
    prime(_pic(url), '$_animations/$file');
  }
}

int _in({int days = 0, int hours = 0, int minutes = 0}) => DateTime.now()
    .add(Duration(days: days, hours: hours, minutes: minutes))
    .millisecondsSinceEpoch;

ProfilePicture _picture(
  int id,
  String name,
  String file, {
  String format = 'SVG',
  String currency = PictureCurrency.coin,
  String type = 'PREMIUM',
  int cost = 0,
  int days = 0,
  int hours = 0,
  bool owned = false,
  int expiresAt = 0,
}) => ProfilePicture(
  id: id,
  name: name,
  url: _pic(file),
  assetFormat: format,
  currency: currency,
  type: type,
  cost: cost,
  durationDays: days,
  durationHours: hours,
  owned: owned,
  expiresAt: expiresAt,
);

/// Every state a picture tile can be in.
List<ProfilePicture> _catalogue() => [
  _picture(1, 'Bear', 'bear.svg', type: 'FREE', owned: true),
  _picture(2, 'Cat', 'cat.svg', type: 'FREE', owned: true),
  // Worn (unless the scene wears Bear): a rental with days left, cheap
  // enough to stand in the first row.
  _picture(
    3,
    'Lion',
    'lion.svg',
    cost: 20000,
    days: 10,
    owned: true,
    expiresAt: _in(days: 6, hours: 4),
  ),
  // Owned for good.
  _picture(4, 'Tiger', 'tiger.svg', cost: 500000, owned: true),
  // Owned, a rental in its last hour.
  _picture(
    5,
    'Love Sheep',
    'rabbit.svg',
    cost: 1000000,
    hours: 1,
    owned: true,
    expiresAt: _in(minutes: 42),
  ),
  _picture(6, 'Fox', 'fox.svg', cost: 25000),
  _picture(7, 'Wolf', 'wolf.svg', cost: 1000000, hours: 1),
  _picture(8, 'Love Birds', 'dog.svg', cost: 3000000, hours: 3),
  _picture(9, 'Bodybuilder', 'monkey.svg', cost: 500000000, days: 50),
  _picture(
    10,
    'Orange Ballerina',
    'horse.svg',
    currency: PictureCurrency.hammer,
    cost: 10,
    days: 100,
  ),
  _picture(
    11,
    'Panda',
    'panda.svg',
    currency: PictureCurrency.hammer,
    cost: 30,
    days: 30,
    owned: true,
    expiresAt: _in(days: 12),
  ),
  _picture(
    12,
    'Swirling Dots',
    'owl.svg',
    currency: PictureCurrency.hammer,
    cost: 300,
    days: 50,
  ),
  _picture(
    13,
    'Jolly King',
    'koala.svg',
    currency: PictureCurrency.diamond,
    cost: 5,
    days: 100,
  ),
  _picture(
    14,
    'Penguin',
    'penguin.svg',
    currency: PictureCurrency.diamond,
    cost: 1,
  ),
  _picture(
    15,
    'Hammer Time',
    'hammer.json',
    format: 'LOTTIE',
    currency: PictureCurrency.hammer,
    cost: 25,
    days: 10,
  ),
  _picture(
    16,
    'Missile Launch',
    'missile.json',
    format: 'LOTTIE',
    currency: PictureCurrency.hammer,
    cost: 30,
    days: 30,
    owned: true,
    expiresAt: _in(days: 20),
  ),
  _picture(
    17,
    'Chip Shuffle',
    'chips.json',
    format: 'LOTTIE',
    currency: PictureCurrency.diamond,
    cost: 4,
    days: 100,
  ),
  _picture(
    18,
    'Speech Bubble',
    'message.json',
    format: 'LOTTIE',
    currency: PictureCurrency.hammer,
    cost: 1,
    days: 100,
  ),
];

TablePicture _table(
  int id,
  String name,
  String slug, {
  String currency = PictureCurrency.coin,
  int cost = 100000,
  int days = 7,
  int hours = 0,
  bool owned = false,
  int expiresAt = 0,
}) => TablePicture(
  id: id,
  name: name,
  dayUrl: _pic('$slug-day.svg'),
  nightUrl: _pic('$slug-night.svg'),
  assetFormat: 'SVG',
  currency: currency,
  type: 'PREMIUM',
  cost: cost,
  durationDays: days,
  durationHours: hours,
  owned: owned,
  expiresAt: expiresAt,
);

/// The table shelf: one laid (id 2, unless the scene lays none), one owned
/// and waiting, and locked ones in each wallet, one with a long name. The
/// laid and the owned one are the cheapest, so they stand in the first row.
List<TablePicture> _tableCatalogue() => [
  _table(1, 'Lines Background', 'royal-sapphire', cost: 100000),
  _table(
    2,
    'Background Pattern',
    'emerald-lattice',
    cost: 50000,
    owned: true,
    expiresAt: _in(days: 5, hours: 3),
  ),
  _table(
    3,
    'Welcome',
    'midnight-gold',
    cost: 75000,
    owned: true,
    expiresAt: _in(hours: 7),
  ),
  _table(4, 'Circle Background Pattern', 'classic-baize', cost: 300000),
  _table(5, 'Thank You', 'oxblood-club', cost: 3000000),
  _table(
    6,
    'Royal Purple',
    'royal-purple',
    currency: PictureCurrency.hammer,
    cost: 30,
    days: 30,
  ),
  _table(
    7,
    'Sunset Marble',
    'sunset-marble',
    currency: PictureCurrency.diamond,
    cost: 5,
    days: 100,
  ),
  _table(8, 'Carbon Weave', 'carbon-weave', cost: 500000000, days: 0),
];

Map<String, dynamic> _userJson(_Scene scene) => {
  'id': 'u0',
  'provider': 'guest',
  'displayName': 'Priya',
  'chips': 20740000,
  'diamond': 9,
  'hammer': 45,
  'missile': 3,
  'avatarUrl': _pic(scene.wornFree ? 'bear.svg' : 'lion.svg'),
  'activePictureId': scene.wornFree ? 1 : 3,
  'tablePicture': scene.noTable
      ? null
      : {
          'id': 2,
          'dayUrl': _pic('emerald-lattice-day.svg'),
          'nightUrl': _pic('emerald-lattice-night.svg'),
          'assetFormat': 'SVG',
          'currency': 'COIN',
          'cost': 500000,
        },
  'rewards': {
    'milestoneAvailable': false,
    'milestoneReward': 25000,
    'handsToNextMilestone': 25,
    'bonusReward': 10000,
    'bonusReadyAt': DateTime.now()
        .add(const Duration(hours: 3, minutes: 12))
        .millisecondsSinceEpoch,
    'bonusAvailable': false,
    'dailyReward': 100000,
    'dailyHammers': 1,
    'dailyReadyAt': 0,
    'dailyAvailable': true,
  },
};

const _menu = <Map<String, Object>>[
  {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
  {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
  {'category': 'variation', 'bootAmount': 50000, 'maxChips': 1000000000},
  {'category': 'omaha', 'bootAmount': 50000, 'minChips': 500000},
];

GameState _lobbyState(_Scene scene, AppLang lang) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = Screen.lobby
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': _menu,
    })
    ..user = User.fromJson(_userJson(scene))
    ..pictures = _catalogue()
    ..tablePictures = _tableCatalogue();
}

GameState _tableState(_Scene scene, AppLang lang) {
  final state = sceneState(tableScenes.first, lang: lang);
  final seat = state.user;
  return state
    ..user = User.fromJson({..._userJson(scene), 'id': seat?.id ?? 'u0'})
    ..pictures = _catalogue()
    ..tablePictures = _tableCatalogue();
}

Future<void> _loadFonts() async {
  await loadScriptFonts();
  final icons = File(const String.fromEnvironment('ICON_FONT'));
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
}

ThemeData _theme(bool dark, AppLang lang) {
  final base = dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  return lang == AppLang.english ? base : withScriptFallback(base);
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    await _primePictures();
  });
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
  final scene = shot.scene;
  final state = scene.atTable
      ? _tableState(scene, shot.lang)
      : _lobbyState(scene, shot.lang);
  final theme = _theme(shot.dark, shot.lang);

  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: scene.atTable
          ? tableApp(state: state, feedback: feedback, theme: theme)
          : MultiProvider(
              providers: [
                ChangeNotifierProvider<GameState>.value(value: state),
                ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
              ],
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme,
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

  Future<void> settle(int ms) async {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump(Duration(milliseconds: ms));
  }

  await settle(900);
  final host = tester.element(
    find.byType(scene.atTable ? TableScreen : LobbyScreen),
  );
  if (scene.picker) {
    unawaited(openPicturePicker(host));
  } else {
    unawaited(showChipStore(host, opensOn: scene.tab));
  }
  await settle(900);
  await settle(900);
  if (scene.scroll > 0) {
    // The shelf's body: the one vertical scroll view with somewhere to go.
    for (final element in find.byType(Scrollable).evaluate()) {
      final scrollable = (element as StatefulElement).state as ScrollableState;
      final position = scrollable.position;
      if (scrollable.axisDirection == AxisDirection.down &&
          position.maxScrollExtent > 0) {
        position.jumpTo(position.maxScrollExtent * scene.scroll);
      }
    }
    await settle(900);
  }
  // SVG and Lottie pictures decode off the test's clock.
  await settle(300);
  await settle(300);
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
