// Pictures of Friends at the table (owner, 26 Sep 2026): the Teen Patti felt
// (and the poker felt) with a waiting request's badge on its sender's seat —
// a long name's too — and the friend mark on the seats of the viewer's
// friends (the two on one pod, as they never are, to show they stand apart),
// and the player drawer a pod opens — reading the profile, Add Friend,
// Request Sent, Accept and Reject under the badge, the Friends tag, a refusal
// said in the drawer, a profile that could not be read — and the poker felt's
// drawer, at the landscape sizes the app is checked on and a tablet, in both
// themes, at text x1.0 and x1.25, and in Hindi at the tightest size. Not part
// of `flutter test` (the name has no `_test`): run it by hand.
//
//   flutter test test/friends_table_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=answer_640   a substring of the names;
//              several, comma-separated, take any of them, and a '+' inside
//              one asks for all its parts (answer+_dark_x1.25)
//
// Every shot is the real table, the drawer opened by a tap on the real pod,
// with Inter, the Noto fonts and the Material icons loaded, and written to
// SHOTS_DIR as a PNG at twice the logical size. Anything that overflows or
// throws is written to SHOTS_DIR/problems.txt rather than failing the run.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/hammer_flight.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'friends_fixture.dart';
import 'script_fonts.dart';
import 'table_scenes.dart' show silentFeedback, tableApp;

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');

const _names = ['Priya', 'Ravi', 'Meera', 'Arjun', 'Vikramaditya'];

/// Profile pictures the repository carries, worn at the table.
const _pictures = ['owl', 'tiger', 'fox', 'lion', 'panda'];

enum _Scene {
  badge,
  longBadge,
  marks,
  both,
  loading,
  add,
  sent,
  answer,
  friends,
  refused,
  failed,
  pokerBadge,
  pokerMarks,
  poker,
}

/// The scenes laid on the poker felt.
const _pokerScenes = {_Scene.pokerBadge, _Scene.pokerMarks, _Scene.poker};

/// Whose pod each scene taps.
const _tapped = {
  _Scene.loading: 'u1',
  _Scene.add: 'u1',
  _Scene.sent: 'u2',
  _Scene.answer: 'u3',
  _Scene.friends: 'u4',
  _Scene.refused: 'u1',
  _Scene.failed: 'u1',
  _Scene.poker: 'u3',
};

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
  Size(915, 412),
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

Map<String, dynamic> _seat(int i, {required bool poker}) => {
  'seatIndex': i,
  'userId': 'u$i',
  'displayName': _names[i],
  'avatarUrl': '/profiles/${_pictures[i]}.svg',
  'chips': i == 0 || !poker ? 1820000 : null,
  'status': 'active',
  'isBlind': i.isOdd,
  'lastBet': poker ? 0 : 400,
  'lastAction': poker ? null : 'chaal',
  'contributed': poker ? 0 : 1400,
  'connected': true,
  'cardCount': poker ? 2 : 3,
};

RoomState _room({required bool poker}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return RoomState.fromJson({
    'roomId': poker ? 'p1' : 'r1',
    'code': 'ABCD2345',
    'category': poker ? 'texas_holdem' : 'seen',
    'game': poker ? 'poker' : null,
    'chipsHidden': poker,
    'state': 'betting',
    'handNo': 7,
    'dealerSeat': 3,
    'maxPlayers': 5,
    'minPlayers': 2,
    'bootAmount': poker ? 50000 : 200,
    'turnTimeoutMs': 25000,
    'pot': poker ? 75000 : 6800,
    'maxPot': poker ? 0 : 2000000,
    'stake': 400,
    'turn': {'seatIndex': 2, 'userId': 'u2', 'deadline': now + 20000},
    'you': {
      'seatIndex': 0,
      'chips': 1820000,
      'status': 'active',
      'isBlind': false,
      'blindMovesLeft': 0,
      'contributed': 1400,
      'missedTurns': 0,
      'maxMissedTurns': 3,
      'cards': poker ? const <String>[] : ['As', 'Kd', 'Qh'],
    },
    'seats': [for (var i = 0; i < 5; i++) _seat(i, poker: poker)],
    if (poker)
      'poker': {
        'variant': 'texas_holdem',
        'street': 'preflop',
        'community': const <String>[],
        'pots': const <Map<String, dynamic>>[],
        'smallBlind': 25000,
        'bigBlind': 50000,
        'ante': 0,
        'holeCards': 2,
        'maxDiscards': 0,
        'minBuyIn': 500000,
      },
  });
}

/// The table's players as they stand to the viewer: Ravi nobody yet, Meera
/// asked by the viewer, Arjun asking the viewer, Vikramaditya a friend. The
/// marks scenes make Ravi a friend too; `both` makes Arjun a friend with his
/// request still waiting (the two never meet: this shows they stand apart);
/// `longBadge` has Vikramaditya asking instead, and nobody a friend.
FakeFriendsServer _server(_Scene scene) {
  Map<String, dynamic> card(int i) => {
    ...cardJson('u$i', _names[i]),
    'profilePicture': {'id': 1, 'url': '/profiles/${_pictures[i]}.svg'},
  };
  final friends = switch (scene) {
    _Scene.marks || _Scene.pokerMarks => [1, 4],
    _Scene.both => [3, 4],
    _Scene.longBadge => <int>[],
    _ => [4],
  };
  final asking = scene == _Scene.longBadge ? 4 : 3;
  final server = FakeFriendsServer(
    friends: [
      for (final i in friends)
        {
          ...friendJson(
            'u$i',
            _names[i],
            status: 'PLAYING',
            game: 'TEEN_PATTI',
            variant: 'SEEN',
          ),
          'profilePicture': {'id': 1, 'url': '/profiles/${_pictures[i]}.svg'},
        },
    ],
    incoming: [
      {'requestId': 41, 'player': card(asking), 'createdAt': 1790442915826},
    ],
    outgoing: [
      {'requestId': 43, 'player': card(2), 'createdAt': 1790442915000},
    ],
  );
  server.profiles['u1'] = {
    ...card(1),
    'friendStatus': 'NONE',
    'stats': statsJson(played: 88, won: 30, lost: 50, left: 8, winRate: 34.09),
  };
  server.profiles['u2'] = {
    ...card(2),
    'friendStatus': 'PENDING_SENT',
    'requestId': 43,
    'stats': statsJson(),
  };
  server.profiles['u3'] = {
    ...card(3),
    'friendStatus': 'PENDING_RECEIVED',
    'requestId': 41,
    'stats': statsJson(
      played: 412,
      won: 180,
      lost: 214,
      left: 18,
      winRate: 43.69,
    ),
  };
  server.profiles['u4'] = {
    ...card(4),
    'friendStatus': 'FRIENDS',
    'stats': statsJson(
      played: 1234567,
      won: 600000,
      lost: 600000,
      left: 34567,
      winRate: 48.6,
    ),
  };
  if (scene == _Scene.refused) {
    server.sendRefusal = refusal('rate_limited', 429);
  }
  if (scene == _Scene.loading) {
    server
      ..holdPath = '/api/players/u1/profile'
      ..hold = Completer<void>();
  }
  return server;
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

void main() {
  final pictures = <String, Uint8List>{};
  setUpAll(() async {
    await _loadFonts();
    for (final p in _pictures) {
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
      final server = _server(shot.scene);
      try {
        await http.runWithClient(
          () => _shoot(tester, shot, server, problems),
          () => server.client,
        );
      } finally {
        debugDisableShadows = true;
        final hold = server.hold;
        if (hold != null && !hold.isCompleted) hold.complete();
      }
    });
  }
}

Future<void> _shoot(
  WidgetTester tester,
  _Shot shot,
  FakeFriendsServer server,
  List<String> problems,
) async {
  tester.view.physicalSize = shot.size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = shot.scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);

  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: friendsServer);
  debugDefaultTargetPlatformOverride = null;
  state
    ..lang = shot.lang
    ..debugToken = 'tok'
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Priya',
      'chips': 1820000,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
    })
    ..screen = Screen.lobby
    ..handleState(_room(poker: _pokerScenes.contains(shot.scene)));

  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: tableApp(
        state: state,
        feedback: feedback,
        theme: withScriptFallback(
          shot.dark
              ? AppTheme.dark(sound: false)
              : AppTheme.light(sound: false),
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

  await settle(900);
  await settle(900);

  final tapped = _tapped[shot.scene];
  if (tapped != null) {
    if (shot.scene == _Scene.failed) server.unsupported = true;
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is SeatPod && w.seat?.userId == tapped,
        ),
        matching: find.byType(PodImpact),
      ),
    );
    await settle();
    if (shot.scene == _Scene.refused) {
      await tester.tap(find.byKey(const ValueKey('seat-add-friend')));
      await settle();
    }
  }

  await real(30);
  await tester.pump(const Duration(milliseconds: 1));
  final problem = tester.takeException();
  if (problem != null) problems.add('${shot.name}: $problem');
  if (_dir.isNotEmpty) {
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

  final hold = server.hold;
  if (hold != null && !hold.isCompleted) hold.complete();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  final late = tester.takeException();
  if (late != null) problems.add('${shot.name} (teardown): $late');
  state.dispose();
}
