// Pictures of the Lucky Draw in every state its polish brief names (26 Sep
// 2026): ready to spin, the spin frame by frame — the wind-up while the
// server is asked, full speed, the run down and the creep —, the stop with
// the winning prize lit, each reveal (chips, hammers, a picture, no prize)
// and the wait for the next spin; at the landscape sizes the app is checked
// on and a tablet, in both themes, at text x1.0 and x1.25, and in Hindi at
// the tightest size. Not part of `flutter test` (the name has no `_test`):
// run it by hand.
//
//   flutter test test/lucky_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=spin_640   a substring of the names;
//              several, comma-separated, take any of them, and a '+' inside
//              one asks for all its parts (spin+_dark_x1.25)
//
// Every shot is the real screen, opened from the lobby's own Lucky Draw key
// over the real lobby, with Inter, the Noto fonts and the Material icons
// loaded, and written to SHOTS_DIR as a PNG at twice the logical size.
// Anything that overflows or throws is written to SHOTS_DIR/problems.txt
// rather than failing the run.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/lucky_draw_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');
const _server = 'http://127.0.0.1:9';
const _threeDays = 3 * 24 * 60 * 60 * 1000;

/// A picture prize is drawn from a profile SVG the repository carries.
const _picturePath = '/profiles/fox.svg';

/// The owner's beginner draw, as GET /api/lucky-draw sends it.
const List<Map<String, dynamic>> _beginner = [
  {'slotNumber': 1, 'rewardType': 'HAMMER', 'rewardValue': 1},
  {'slotNumber': 2, 'rewardType': 'HAMMER', 'rewardValue': 4},
  {'slotNumber': 3, 'rewardType': 'CHIPS', 'rewardValue': 1000000},
  {'slotNumber': 4, 'rewardType': 'CHIPS', 'rewardValue': 100000},
  {'slotNumber': 5, 'rewardType': 'NO_REWARD', 'rewardValue': 0},
  {'slotNumber': 6, 'rewardType': 'CHIPS', 'rewardValue': 500000},
];

const Map<String, dynamic> _fox = {
  'id': 7,
  'name': 'Fox',
  'url': _picturePath,
  'assetFormat': 'SVG',
  'currency': 'COIN',
  'type': 'PREMIUM',
  'cost': 250000,
  'durationDays': 7,
  'owned': false,
};

/// The same draw with a picture on slot 1, as an owner's UPDATE makes one.
final List<Map<String, dynamic>> _withPicture = [
  {
    'slotNumber': 1,
    'rewardType': 'PROFILE_PICTURE',
    'rewardValue': null,
    'rewardRefId': '7',
    'picture': _fox,
  },
  ..._beginner.skip(1),
];

/// One journey through the screen: which draw, which slot the server draws
/// and what it grants, and which moments are pictured.
class _Journey {
  const _Journey(
    this.name, {
    required this.slot,
    required this.reward,
    this.slots = _beginner,
    this.frames = false,
    this.cooldown = false,
    this.refused = false,
  });

  final String name;
  final int slot;
  final Map<String, dynamic> reward;
  final List<Map<String, dynamic>> slots;

  /// The spin frame by frame, and the moment it stops, as well as the reveal.
  final bool frames;

  /// Opened while the wheel recharges: the wait is all there is to see.
  final bool cooldown;

  /// The server refuses the spin: the wheel stops with no prize.
  final bool refused;
}

final _journeys = [
  const _Journey(
    'spin',
    slot: 3,
    reward: {'type': 'CHIPS', 'value': 1000000},
    frames: true,
  ),
  const _Journey('hammers', slot: 2, reward: {'type': 'HAMMER', 'value': 4}),
  _Journey(
    'picture',
    slot: 1,
    reward: const {
      'type': 'PROFILE_PICTURE',
      'value': null,
      'refId': '7',
      'picture': _fox,
    },
    slots: _withPicture,
  ),
  const _Journey('nothing', slot: 5, reward: {'type': 'NO_REWARD', 'value': 0}),
  const _Journey('cooldown', slot: 1, reward: {}, cooldown: true),
  const _Journey('refused', slot: 1, reward: {}, refused: true),
];

class _Shot {
  const _Shot(
    this.journey,
    this.size,
    this.dark,
    this.scale, {
    this.lang = AppLang.english,
  });
  final _Journey journey;
  final Size size;
  final bool dark;
  final double scale;
  final AppLang lang;

  String get tag =>
      '${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}';

  String file(String moment) => '${journey.name}-${moment}_$tag.png';
}

const _sizes = [
  Size(640, 360),
  Size(891, 411),
  Size(592, 360),
  Size(915, 412),
  Size(1280, 800),
];

List<_Shot> _shots() => [
  for (final journey in _journeys)
    for (final size in _sizes)
      for (final dark in [true, false])
        for (final scale in [1.0, 1.25]) _Shot(journey, size, dark, scale),
  for (final journey in _journeys)
    for (final size in const [Size(640, 360), Size(592, 360)])
      for (final dark in [true, false])
        _Shot(journey, size, dark, 1.25, lang: AppLang.hindi),
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

Map<String, dynamic> _user() => {
  'id': 'u1',
  'provider': 'guest',
  'displayName': 'Priya',
  'chips': 1245000,
  'diamond': 9,
  'hammer': 20,
  'missile': 1,
  'rewards': {
    'milestoneAvailable': false,
    'milestoneReward': 25000,
    'handsToNextMilestone': 4,
    'bonusReward': 10000,
    'bonusReadyAt': DateTime.now()
        .add(const Duration(hours: 3))
        .millisecondsSinceEpoch,
    'bonusAvailable': false,
    'dailyReward': 100000,
    'dailyHammers': 1,
    'dailyReadyAt': DateTime.now()
        .add(const Duration(hours: 20))
        .millisecondsSinceEpoch,
    'dailyAvailable': false,
  },
};

Map<String, dynamic> _draw(_Journey journey) => {
  'draw': {
    'code': 'BEGINNER_LUCKY_DRAW',
    'name': 'Beginner Lucky Draw',
    'spinnerType': 'BEGINNER',
    'cooldownMs': _threeDays,
  },
  'slots': journey.slots,
  // The brief's own figure, 44:45:54.
  'nextSpinAt': journey.cooldown
      ? DateTime.now()
            .add(const Duration(hours: 44, minutes: 45, seconds: 54))
            .millisecondsSinceEpoch
      : 0,
};

/// The fake server: the draw, and the spin — held until [release] completes.
MockClient _client(_Journey journey, Completer<void> release) =>
    MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/lucky-draw') {
        return http.Response(jsonEncode(_draw(journey)), 200);
      }
      if (path == '/api/lucky-draw/spin') {
        await release.future;
        if (journey.refused) {
          return http.Response(
            jsonEncode({
              'error': 'lucky_draw_not_ready',
              'message': 'Your next Lucky Draw spin is not ready yet.',
              'readyAt': DateTime.now()
                  .add(const Duration(hours: 71, minutes: 58))
                  .millisecondsSinceEpoch,
            }),
            409,
          );
        }
        final user = _user();
        return http.Response(
          jsonEncode({
            'actionId': 'shot-${journey.name}',
            'slotNumber': journey.slot,
            'reward': journey.reward,
            'alreadyOwned': false,
            'replayed': false,
            'nextSpinAt': DateTime.now().millisecondsSinceEpoch + _threeDays,
            'user': user,
          }),
          200,
        );
      }
      return http.Response(jsonEncode({'error': 'not_found'}), 404);
    });

ThemeData _theme(bool dark) => withScriptFallback(
  dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
);

void main() {
  late Uint8List foxBytes;
  setUpAll(() async {
    await _loadFonts();
    // Loaded where async is real, so every test finds the composition
    // already made (CLAUDE.md §12.3).
    await AssetLottie(luckySpinnerAsset).load();
    foxBytes = File('../go-server/public$_picturePath').readAsBytesSync();
  });
  final problems = <String>[];
  tearDownAll(() {
    if (_dir.isEmpty) return;
    File('$_dir/problems.txt').writeAsStringSync(
      problems.isEmpty ? 'none\n' : '${problems.join('\n')}\n',
    );
  });

  bool wanted(String name) =>
      _only.isEmpty ||
      _only
          .split(',')
          .any((term) => term.split('+').every((part) => name.contains(part)));

  for (final shot in _shots()) {
    final name = '${shot.journey.name}_${shot.tag}';
    if (!wanted(name)) continue;
    testWidgets(name, (tester) async {
      PictureCache.prime('$_server$_picturePath', foxBytes);
      // The test binding draws every shadow as a solid block unless told not
      // to; a picture wants them soft.
      debugDisableShadows = false;
      try {
        final release = Completer<void>();
        await http.runWithClient(
          () => _shoot(tester, shot, release, problems),
          () => _client(shot.journey, release),
        );
      } finally {
        debugDisableShadows = true;
      }
    });
  }
}

Future<void> _shoot(
  WidgetTester tester,
  _Shot shot,
  Completer<void> release,
  List<String> problems,
) async {
  tester.view.physicalSize = shot.size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = shot.scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  SharedPreferences.setMockInitialValues({'soundOn': false});
  final feedback = FeedbackSettings();
  await feedback.load();
  addTearDown(feedback.dispose);

  final journey = shot.journey;
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: _server);
  debugDefaultTargetPlatformOverride = null;
  state
    ..lang = shot.lang
    ..screen = Screen.lobby
    ..debugToken = 'tok'
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
        {'category': 'blind', 'bootAmount': 200},
      ],
    })
    ..user = User.fromJson(_user())
    ..luckyDraw = LuckyDrawState.fromJson(_draw(journey));

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
          theme: _theme(shot.dark),
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

  // Real async for a moment, so what is loaded outside the fake clock — the
  // wheel's composition, a picture — can arrive.
  Future<void> real([int ms = 60]) =>
      tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  Future<void> settle(int ms) async {
    await tester.pump(const Duration(milliseconds: 16));
    await real();
    await tester.pump(Duration(milliseconds: ms));
  }

  Future<void> snap(String moment) async {
    await real(30);
    await tester.pump(const Duration(milliseconds: 1));
    final problem = tester.takeException();
    if (problem != null) problems.add('${shot.file(moment)}: $problem');
    if (_dir.isEmpty) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '$_dir/${shot.file(moment)}',
      ).writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  /// Time moves on the fake clock in frames, as a phone's would.
  Future<void> run(Duration d) async {
    final end = tester.binding.clock.now().add(d);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  await settle(900);
  await settle(900);
  await tester.tap(find.byKey(const ValueKey('lucky-draw-chip')));
  await settle(700);
  await settle(300);

  if (journey.cooldown) {
    await snap('wait');
  } else {
    await snap('ready');
    await tester.tap(find.byKey(const ValueKey('lucky-spin')));
    await tester.pump();
    // Out with the server for a moment: the wind-up.
    await run(const Duration(milliseconds: 450));
    if (journey.frames || journey.refused) await snap('a-asking');
    release.complete();
    await tester.pump();
    await real();
    await tester.pump();
    if (journey.refused) {
      await run(const Duration(milliseconds: 400));
      await snap('b-refused');
      await run(const Duration(seconds: 4));
      await snap('c-after');
    } else {
      if (journey.frames) {
        await run(const Duration(milliseconds: 650));
        await snap('b-speeding');
        await run(const Duration(milliseconds: 1400));
        await snap('c-full-speed');
        await run(const Duration(milliseconds: 1500));
        await snap('d-slowing');
        await run(const Duration(milliseconds: 1500));
        await snap('e-creep');
      }
      // Until the wheel has stopped on the server's slot.
      final wheel = find.byType(LuckyWheel);
      for (var i = 0; i < 700; i++) {
        if (tester.widget<LuckyWheel>(wheel).won != null) break;
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (journey.frames || journey.name == 'nothing') {
        await run(const Duration(milliseconds: 250));
        await snap('f-landed');
      }
      await run(const Duration(milliseconds: 1600));
      await real();
      await run(const Duration(milliseconds: 200));
      await snap('g-reveal');
      if (journey.frames) {
        final close = find.text(Strings(shot.lang).close);
        if (close.evaluate().isNotEmpty) {
          await tester.tap(close.last);
          await run(const Duration(milliseconds: 700));
          await snap('h-after');
        }
      }
    }
  }

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  final late = tester.takeException();
  if (late != null) {
    problems.add('${journey.name}_${shot.tag} (teardown): $late');
  }
  state.dispose();
}
