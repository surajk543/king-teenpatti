// Pictures of Friends V1 (owner, 26 Sep 2026) in every state the contract
// names: the lobby with its Friends key and the count of requests waiting;
// the page with requests and friends — playing, online, offline —; the empty
// page; the page that could not load; Add Friend waiting, with a player found
// and with nobody found; a playing friend's profile, and the question before
// Remove Friend — at the landscape sizes the app is checked on and a tablet,
// in both themes, at text x1.0 and x1.25, and in Hindi at the tightest size.
// Not part of `flutter test` (the name has no `_test`): run it by hand.
//
//   flutter test test/friends_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=list_640   a substring of the names;
//              several, comma-separated, take any of them, and a '+' inside
//              one asks for all its parts (list+_dark_x1.25)
//
// Every shot is the real page, opened from the lobby's own Friends key over
// the real lobby, with Inter, the Noto fonts and the Material icons loaded,
// and written to SHOTS_DIR as a PNG at twice the logical size. Anything that
// overflows or throws is written to SHOTS_DIR/problems.txt rather than
// failing the run.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'friends_fixture.dart';
import 'script_fonts.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');

/// Profile pictures the repository carries, worn by the fixture's players.
const _pictures = {
  'u-ravi': 'tiger',
  'u-meera': 'fox',
  'u-arjun': 'lion',
  'u-kavya': 'owl',
  'u-isha': 'panda',
  'u-asha': 'rabbit',
};

enum _Scene { lobby, list, empty, failed, add, found, nobody, profile, remove }

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

  String get name =>
      '${scene.name}_${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}';
}

const _sizes = [
  Size(640, 360),
  Size(891, 411),
  Size(592, 360),
  Size(1280, 800),
];

List<_Shot> _shots() => [
  for (final scene in _Scene.values)
    for (final size in _sizes)
      for (final dark in [true, false])
        for (final scale in [1.0, 1.25]) _Shot(scene, size, dark, scale),
  for (final scene in _Scene.values)
    for (final dark in [true, false])
      _Shot(scene, const Size(640, 360), dark, 1.25, lang: AppLang.hindi),
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

/// The fixture's graph, every player wearing a picture.
FakeFriendsServer _server(_Scene scene) {
  if (scene == _Scene.empty) return FakeFriendsServer();
  final server = populatedServer()..failLists = scene == _Scene.failed;
  String? url(String id) {
    final p = _pictures[id];
    return p == null ? null : '/profiles/$p.svg';
  }

  void dress(Map<String, dynamic> card) {
    card['profilePicture'] = {'id': 1, 'url': url(card['userId'] as String)};
  }

  for (final f in server.friends) {
    dress(f);
  }
  for (final r in server.incoming) {
    dress(r['player'] as Map<String, dynamic>);
  }
  for (final p in server.profiles.values) {
    dress(p);
  }
  server.players['u-asha'] = {
    'player': {
      ...cardJson('u-asha', 'Asha'),
      'profilePicture': {'id': 1, 'url': url('u-asha')},
    },
    'friendStatus': 'NONE',
  };
  return server;
}

void main() {
  final pictures = <String, Uint8List>{};
  setUpAll(() async {
    await _loadFonts();
    for (final p in _pictures.values) {
      pictures['$friendsServer/profiles/$p.svg'] = File(
        '../go-server/public/profiles/$p.svg',
      ).readAsBytesSync();
    }
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
    if (!wanted(shot.name)) continue;
    testWidgets(shot.name, (tester) async {
      for (final MapEntry(key: url, value: bytes) in pictures.entries) {
        PictureCache.prime(url, bytes);
      }
      // The test binding draws every shadow as a solid block unless told not
      // to; a picture wants them soft.
      debugDisableShadows = false;
      try {
        final server = _server(shot.scene);
        await http.runWithClient(
          () => _shoot(tester, shot, problems),
          () => server.client,
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

  final state = signedInState(lang: shot.lang)
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
        {'category': 'blind', 'bootAmount': 200},
      ],
    });

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
          theme: withScriptFallback(
            shot.dark
                ? AppTheme.dark(sound: false)
                : AppTheme.light(sound: false),
          ),
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

  Future<void> real([int ms = 60]) =>
      tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
  Future<void> settle([int ms = 700]) async {
    await tester.pump(const Duration(milliseconds: 16));
    await real();
    await tester.pump(Duration(milliseconds: ms));
    await real();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> snap() async {
    await real(30);
    await tester.pump(const Duration(milliseconds: 1));
    final problem = tester.takeException();
    if (problem != null) problems.add('${shot.name}: $problem');
    if (_dir.isEmpty) return;
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '$_dir/${shot.name}.png',
      ).writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> tapShown(Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await settle();
  }

  await settle(1200);
  if (shot.scene == _Scene.lobby) {
    await snap();
  } else {
    await tester.tap(find.byTooltip(Strings(shot.lang).friends));
    await settle();
    switch (shot.scene) {
      case _Scene.add || _Scene.found || _Scene.nobody:
        await tester.tap(find.byKey(const ValueKey('friends-add')));
        await settle();
        if (shot.scene != _Scene.add) {
          await tester.enterText(
            find.byKey(const ValueKey('friends-id-field')),
            shot.scene == _Scene.found ? 'u-asha' : 'nobody-at-all',
          );
          await tester.tap(find.byKey(const ValueKey('friends-search')));
          await settle();
        }
      case _Scene.profile || _Scene.remove:
        await tapShown(find.byKey(const ValueKey('friend-u-meera')));
        if (shot.scene == _Scene.remove) {
          await tapShown(find.byKey(const ValueKey('friend-remove')));
        }
      default:
        break;
    }
    await snap();
  }

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}
