// Friends at the table (owner, 26 Sep 2026: "in a gametable, if a player
// clicks other player pod then a drawer from right side will open, where he
// can send friend request and player by clicking his pod can accept the
// friend request, do this async").
//
// Pressed for real, on the Teen Patti felt and the poker felt: a tap on
// another player's pod opens the player drawer from the right — never the
// viewer's own pod, never an empty chair, never a swipe in from the edge —
// with the player's name and picture at once and then the move their profile
// offers: Add Friend (sent, it turns to Request Sent), Request Sent, Accept
// and Reject (accepted, it turns to ✓ Friends and their seat's badge goes),
// or the Friends tag. A refusal is said in the drawer, which reads the
// profile again. The two pushes, friend:request and friend:accepted, reach
// their streams exactly as the server writes them, badge the sender's seat,
// update an open drawer and raise a toast in the player's language — none for
// a sender blocked at the table. Back closes the drawer before it asks about
// leaving, and the variation window opening closes it too. The drawer fits a
// 640x360 phone at text x1.25 in all five languages, by day and by night,
// and has no word of a wallet, no presence and no table in it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/main.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/models/friends.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/friends_state.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/table_theme.dart';
import 'package:teenpatti/widgets/glass_panels.dart';
import 'package:teenpatti/widgets/hammer_flight.dart';
import 'package:teenpatti/widgets/player_drawer.dart';
import 'package:teenpatti/widgets/player_profile.dart';
import 'package:teenpatti/widgets/poker_chip.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

import 'friends_fixture.dart';
import 'script_fonts.dart';
import 'table_scenes.dart' show silentFeedback, tableApp;

const _names = {
  'u0': 'Priya',
  'u1': 'Ravi',
  'u2': 'Meera',
  'u3': 'Arjun',
  'u4': 'Vikramaditya',
};

Map<String, dynamic> _seat(int i, {bool empty = false, bool poker = false}) =>
    empty
    ? {'seatIndex': i, 'status': 'empty', 'cardCount': 0}
    : {
        'seatIndex': i,
        'userId': 'u$i',
        'displayName': _names['u$i'],
        'avatarUrl': null,
        'chips': i == 0 || !poker ? 1820000 : null,
        'status': 'active',
        'isBlind': false,
        'lastBet': poker ? 0 : 400,
        'lastAction': poker ? null : 'chaal',
        'contributed': poker ? 0 : 1400,
        'connected': true,
        'cardCount': poker ? 2 : 3,
      };

int get _now => DateTime.now().millisecondsSinceEpoch;

/// A seen table, the viewer (Priya, u0) at seat 0, [empty] seats free. With
/// [choosing], a variation table whose window is open for the viewer.
RoomState _teenPatti({List<int> empty = const [], bool choosing = false}) =>
    RoomState.fromJson({
      'roomId': 'r1',
      'code': 'ABCD2345',
      'isPrivate': false,
      'category': choosing ? 'variation' : 'seen',
      'chipsHidden': choosing,
      'state': 'betting',
      'handNo': 7,
      'dealerSeat': 3,
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'startsAt': 0,
      'pot': 6800,
      'maxPot': choosing ? 0 : 2000000,
      'stake': 400,
      'turn': choosing
          ? {'seatIndex': -1, 'userId': null, 'deadline': 0}
          : {'seatIndex': 2, 'userId': 'u2', 'deadline': _now + 20000},
      'you': {
        'seatIndex': 0,
        'chips': 1820000,
        'status': 'active',
        'isBlind': false,
        'blindMovesLeft': 0,
        'contributed': 1400,
        'missedTurns': 0,
        'maxMissedTurns': 3,
        'cards': ['As', 'Kd', 'Qh'],
      },
      'seats': [for (var i = 0; i < 5; i++) _seat(i, empty: empty.contains(i))],
      if (choosing)
        'variation': {
          'selecting': true,
          'userId': 'u0',
          'displayName': 'Priya',
          'seatIndex': 0,
          'startedAt': _now - 1000,
          'deadline': _now + 9000,
          'timeoutMs': 10000,
          'options': ['MUFLIS', 'AK47', 'JOKER', 'HUKAM'],
        },
    });

/// A Texas Hold'em room, the viewer (u0) at seat 0.
RoomState _poker({List<int> empty = const []}) => RoomState.fromJson({
  'roomId': 'p1',
  'code': 'ABCD2345',
  'category': 'texas_holdem',
  'game': 'poker',
  'chipsHidden': true,
  'state': 'betting',
  'handNo': 3,
  'dealerSeat': 1,
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 50000,
  'turnTimeoutMs': 25000,
  'pot': 75000,
  'turn': {'seatIndex': 1, 'userId': 'u1', 'deadline': _now + 25000},
  'you': {
    'seatIndex': 0,
    'chips': 1820000,
    'status': 'active',
    'cards': const <String>[],
    'missedTurns': 0,
    'maxMissedTurns': 3,
  },
  'seats': [
    for (var i = 0; i < 5; i++) _seat(i, empty: empty.contains(i), poker: true),
  ],
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

/// The graph as the table's players stand to the viewer: Ravi nobody yet,
/// Meera asked by the viewer, Arjun asking the viewer (request 41), and
/// Vikramaditya a friend, playing now.
FakeFriendsServer _server() {
  final server = FakeFriendsServer(
    friends: [
      friendJson(
        'u4',
        'Vikramaditya',
        status: 'PLAYING',
        game: 'TEEN_PATTI',
        variant: 'SEEN',
      ),
    ],
    incoming: [requestJson(41, 'u3', 'Arjun')],
    outgoing: [requestJson(43, 'u2', 'Meera')],
  );
  server.profiles['u1'] = {
    ...cardJson('u1', 'Ravi'),
    'friendStatus': 'NONE',
    'stats': statsJson(played: 88, won: 30, lost: 50, left: 8, winRate: 34.09),
  };
  server.profiles['u2'] = {
    ...cardJson('u2', 'Meera'),
    'friendStatus': 'PENDING_SENT',
    'requestId': 43,
    'stats': statsJson(),
  };
  server.profiles['u3'] = {
    ...cardJson('u3', 'Arjun'),
    'friendStatus': 'PENDING_RECEIVED',
    'requestId': 41,
    'stats': statsJson(played: 0, won: 0, lost: 0, left: 0, winRate: 0),
  };
  server.profiles['u4'] = {
    ...cardJson('u4', 'Vikramaditya'),
    'friendStatus': 'FRIENDS',
    'presence': {
      'status': 'PLAYING',
      'online': true,
      'playing': true,
      'game': 'TEEN_PATTI',
      'variant': 'SEEN',
    },
    'stats': statsJson(
      played: 1234567,
      won: 600000,
      lost: 600000,
      left: 34567,
      winRate: 48.6,
    ),
  };
  return server;
}

/// A signed-in GameState in the lobby, as Priya (u0), about to sit down.
GameState _state({AppLang lang = AppLang.english}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: friendsServer);
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
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
    ..screen = Screen.lobby;
}

void _setView(WidgetTester tester, {Size size = const Size(640, 360)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.25;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Sits the viewer down at [room] — the table opens, and the requests waiting
/// are read — and mounts the table as the app does.
Future<void> _mount(
  WidgetTester tester,
  GameState state,
  RoomState room, {
  Brightness brightness = Brightness.dark,
}) async {
  _setView(tester);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  state.handleState(room);
  await tester.pumpWidget(
    tableApp(
      state: state,
      feedback: feedback,
      theme: withScriptFallback(
        brightness == Brightness.dark
            ? AppTheme.dark(sound: false)
            : AppTheme.light(sound: false),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 900));
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

/// Frames enough for a drawer to slide and a read to land.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _key(String key) => find.byKey(ValueKey(key));

Finder _podOf(String userId) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId);

/// The pod itself — its glass plaque, which takes the tap — not the cards and
/// bet hung under it.
Finder _plaqueOf(String userId) =>
    find.descendant(of: _podOf(userId), matching: find.byType(PodImpact));

Finder _badgeOn(String userId) =>
    find.descendant(of: _podOf(userId), matching: _key('seat-friend-request'));

Finder _inDrawer(Finder matching) =>
    find.descendant(of: find.byType(PlayerDrawer), matching: matching);

bool _drawerOpen(GameState state) =>
    state.tableScaffold.currentState?.isEndDrawerOpen ?? false;

Future<void> _tapPod(WidgetTester tester, String userId) async {
  await tester.tap(_plaqueOf(userId));
  await _settle(tester);
}

Future<void> _closeDrawer(WidgetTester tester) async {
  await tester.tap(_key('seat-close'));
  await _settle(tester);
}

/// A rectangle on the screen, through every transform above [box].
Rect _onScreen(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

/// Every line in the drawer whole and inside it, and nothing thrown while
/// laying it out.
void _expectDrawerFits(WidgetTester tester, String where) {
  expect(tester.takeException(), isNull, reason: where);
  final panel = tester.getRect(_inDrawer(find.byType(PremiumGlassPanel)).first);
  for (final e in _inDrawer(find.byType(RichText)).evaluate()) {
    final paragraph = e.renderObject! as RenderParagraph;
    if (!paragraph.attached || !paragraph.hasSize) continue;
    final line = paragraph.text.toPlainText();
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: '$where: "$line" cut short',
    );
    final rect = _onScreen(paragraph);
    expect(
      rect.left,
      greaterThanOrEqualTo(panel.left - 0.5),
      reason: '$where: "$line" $rect outside $panel',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(panel.right + 0.5),
      reason: '$where: "$line" $rect outside $panel',
    );
  }
}

/// Nothing of a wallet, of where a friend is, or of the table in the drawer.
void _expectNothingButTheFriendship(
  WidgetTester tester,
  Strings t,
  String where,
) {
  final lines = [
    for (final e in _inDrawer(find.byType(RichText)).evaluate())
      (e.widget as RichText).text.toPlainText(),
  ];
  final wallet = RegExp(
    r'chip|diamond|hammer|missile|coin|wallet|lakh|crore|₹|balance',
    caseSensitive: false,
  );
  for (final line in lines) {
    expect(wallet.hasMatch(line), isFalse, reason: '$where: "$line"');
    for (final word in _walletWords[t.lang]!) {
      expect(line, isNot(contains(word)), reason: '$where: "$line"');
    }
    // Where a friend is stays on the lobby's Friends page.
    for (final presence in [
      t.presenceOnline,
      t.presenceOffline,
      t.playingNow,
    ]) {
      expect(line, isNot(contains(presence)), reason: '$where: "$line"');
    }
    // And the table is never named.
    expect(line, isNot(contains('ABCD2345')), reason: where);
  }
  expect(_inDrawer(find.byType(PokerChip)), findsNothing, reason: where);
  expect(_inDrawer(find.byIcon(Icons.diamond)), findsNothing, reason: where);
  expect(_inDrawer(find.byIcon(Icons.hardware)), findsNothing, reason: where);
  expect(_inDrawer(_key('presence-dot-online')), findsNothing, reason: where);
  expect(_inDrawer(_key('friend-game')), findsNothing, reason: where);
}

/// Each language's own words for its wallets — chips, diamonds, hammers,
/// missiles, lakh, crore — as stems, so a declension still matches.
const _walletWords = {
  AppLang.english: <String>[],
  AppLang.hindi: ['चिप', 'हीर', 'हथौ', 'मिसाइल', 'लाख', 'करोड़', 'सिक्'],
  AppLang.bengali: ['চিপ', 'হীর', 'হাতুড়', 'মিসাইল', 'লাখ', 'কোটি'],
  AppLang.gujarati: ['ચિપ', 'હીર', 'હથો', 'મિસાઇલ', 'લાખ', 'કરોડ'],
  AppLang.punjabi: ['ਚਿਪ', 'ਹੀਰ', 'ਹਥੌ', 'ਮਿਜ਼ਾਈਲ', 'ਲੱਖ', 'ਕਰੋੜ'],
};

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadScriptFonts();
  });

  const t = Strings(AppLang.english);
  final felts = <String, RoomState Function({List<int> empty})>{
    'Teen Patti': ({List<int> empty = const []}) => _teenPatti(empty: empty),
    'poker': ({List<int> empty = const []}) => _poker(empty: empty),
  };

  for (final MapEntry(key: felt, value: room) in felts.entries) {
    group('on the $felt felt', () {
      testWidgets('a tap on another player\'s pod opens the player drawer on '
          'the right: their name and picture at once, then their move', (
        tester,
      ) async {
        final server = _server()
          ..holdPath = '/api/players/u1/profile'
          ..hold = Completer<void>();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, room());
          expect(_drawerOpen(state), isFalse);
          expect(find.byType(PlayerDrawer), findsNothing);

          await tester.tap(_plaqueOf('u1'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(_drawerOpen(state), isTrue);
          expect(state.tableScaffold.currentState!.isDrawerOpen, isFalse);
          // From the right: it stands against the screen's right edge, as
          // wide as the table's drawers are.
          final list = tester.getRect(_key('player-drawer-list'));
          expect(list.left, greaterThan(640 / 2));
          expect(list.right, greaterThan(640 - 40));
          final panel = tester.widget<GlassDrawerPanel>(
            _inDrawer(find.byType(GlassDrawerPanel)),
          );
          expect(panel.width, TableSpace.drawerW(640));
          expect(panel.alignment, AlignmentDirectional.centerEnd);
          // Who it is, at once, while the profile is still on its way.
          expect(_inDrawer(_key('seat-player-name')), findsOneWidget);
          expect(_inDrawer(find.text('Ravi')), findsOneWidget);
          expect(_inDrawer(_key('seat-player-picture')), findsOneWidget);
          expect(_inDrawer(_key('seat-loading')), findsOneWidget);
          expect(_inDrawer(_key('seat-add-friend')), findsNothing);
          expect(server.count('GET', '/api/players/u1/profile'), 1);

          server.hold!.complete();
          await _settle(tester);
          expect(_inDrawer(_key('seat-loading')), findsNothing);
          expect(_inDrawer(_key('seat-add-friend')), findsOneWidget);
          // The record: the lobby profile's own tiles.
          expect(_inDrawer(find.byType(PlayerStatsGrid)), findsOneWidget);
          expect(_inDrawer(find.text('88')), findsOneWidget);
          expect(_inDrawer(find.text('34.09%')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('the viewer\'s own pod and an empty chair open nothing', (
        tester,
      ) async {
        final server = _server();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, room(empty: [3]));
          // The viewer's pod takes no tap at all; another player's does.
          expect(tester.widget<SeatPod>(_podOf('u0')).onTap, isNull);
          expect(tester.widget<SeatPod>(_podOf('u1')).onTap, isNotNull);
          expect(tester.widget<SeatPod>(_podOf('u0')).requestBadge, isNull);

          await tester.tap(_plaqueOf('u0'), warnIfMissed: false);
          await _settle(tester);
          expect(_drawerOpen(state), isFalse);
          expect(state.friends.seatPlayer, isNull);

          final chair = find.byIcon(Icons.chair_alt_outlined);
          expect(chair, findsOneWidget);
          await tester.tap(chair, warnIfMissed: false);
          await _settle(tester);
          expect(_drawerOpen(state), isFalse);
          expect(
            server.sent.where((r) => r.url.path.startsWith('/api/players/')),
            isEmpty,
          );
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('each friendStatus offers its move — and never Remove, nor '
          'where a friend is', (tester) async {
        final server = _server();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, room());
          for (final (id, move) in [
            ('u1', 'seat-add-friend'),
            ('u2', 'seat-request-sent'),
            ('u3', 'seat-accept'),
            ('u4', 'seat-friends'),
          ]) {
            await _tapPod(tester, id);
            expect(_drawerOpen(state), isTrue, reason: id);
            expect(_inDrawer(find.text(_names[id]!)), findsOneWidget);
            expect(_inDrawer(_key(move)), findsOneWidget, reason: id);
            expect(_inDrawer(find.text(t.removeFriend)), findsNothing);
            expect(_inDrawer(_key('friend-remove')), findsNothing);
            _expectNothingButTheFriendship(tester, t, id);
            switch (id) {
              case 'u2':
                // Quiet and dead: faded as a dead key is, and a press sends
                // nothing.
                final fade = tester.widget<Opacity>(
                  find
                      .descendant(
                        of: _key('seat-request-sent'),
                        matching: find.byType(Opacity),
                      )
                      .first,
                );
                expect(fade.opacity, deadKeyOpacity);
                await tester.tap(_key('seat-request-sent'));
                await _settle(tester);
                expect(server.count('POST', '/api/friends/requests'), 0);
              case 'u3':
                expect(_inDrawer(_key('seat-reject')), findsOneWidget);
                expect(
                  _inDrawer(find.text(t.wantsToBeFriends)),
                  findsOneWidget,
                );
              case 'u4':
                expect(_inDrawer(find.text(t.friends)), findsOneWidget);
                // Hands are counted, never abbreviated as money is.
                expect(_inDrawer(find.text('1,234,567')), findsOneWidget);
            }
            await _closeDrawer(tester);
            expect(_drawerOpen(state), isFalse, reason: id);
          }
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('a seat whose player asked wears the badge, the pod keeps '
          'its size and the ring its places', (tester) async {
        final server = FakeFriendsServer();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, room());
          expect(
            find.byKey(const ValueKey('seat-friend-request')),
            findsNothing,
          );
          final before = {
            for (final id in _names.keys) id: tester.getRect(_plaqueOf(id)),
          };

          state.handleFriendRequest(
            const FriendRequestItem(
              requestId: '77',
              player: PlayerCard(userId: 'u2', displayName: 'Meera'),
              createdAt: 1790442915826,
            ),
          );
          await tester.pump();
          expect(_badgeOn('u2'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('seat-friend-request')),
            findsOneWidget,
          );
          for (final id in _names.keys) {
            expect(tester.getRect(_plaqueOf(id)), before[id], reason: id);
          }
          // On the pod's top corner, most of it over the pod.
          final pod = before['u2']!;
          final badge = tester.getRect(_badgeOn('u2'));
          expect(badge.center.dy, closeTo(pod.top, badge.height * 0.3));
          expect(
            (badge.center.dx - pod.left).abs() < badge.width ||
                (badge.center.dx - pod.right).abs() < badge.width,
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await _unmount(tester, state);
        }, () => server.client);
      });
    });
  }

  group('the moves', () {
    testWidgets('Add Friend sends the request and turns to Request Sent', (
      tester,
    ) async {
      final server = _server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await _tapPod(tester, 'u1');
        await tester.tap(_key('seat-add-friend'));
        await _settle(tester);
        expect(server.count('POST', '/api/friends/requests'), 1);
        final post = server.sent.lastWhere((r) => r.method == 'POST');
        expect(jsonDecode(post.body), {'userId': 'u1'});
        expect(_inDrawer(_key('seat-add-friend')), findsNothing);
        expect(_inDrawer(_key('seat-request-sent')), findsOneWidget);
        expect(state.notice, isNull);
        // Nothing waited on it: the table is where it was.
        expect(state.screen, Screen.table);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('the requests waiting are read once as the table opens, and '
        'nothing at the table asks again', (tester) async {
      final server = _server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        expect(server.count('GET', '/api/friends/requests'), 1);
        await tester.pump();
        expect(_badgeOn('u3'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('seat-friend-request')),
          findsOneWidget,
        );
        // Another snapshot of the same table, and minutes of play.
        state.handleState(_teenPatti());
        await tester.pump(const Duration(minutes: 3));
        expect(server.count('GET', '/api/friends/requests'), 1);
        expect(server.count('GET', '/api/friends'), 0);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets(
      'Accept makes them a friend, and the badge on their seat goes',
      (tester) async {
        final server = _server();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, _teenPatti());
          expect(_badgeOn('u3'), findsOneWidget);
          await _tapPod(tester, 'u3');
          expect(_inDrawer(_key('seat-accept')), findsOneWidget);
          await tester.tap(_key('seat-accept'));
          await _settle(tester);
          expect(server.count('POST', '/api/friends/requests/41/accept'), 1);
          expect(_inDrawer(_key('seat-accept')), findsNothing);
          expect(_inDrawer(_key('seat-reject')), findsNothing);
          expect(_inDrawer(_key('seat-friends')), findsOneWidget);
          expect(_badgeOn('u3'), findsNothing);
          expect(state.friends.incomingCount, 0);
          expect(state.notice, t.friendAdded('Arjun'));
          await _unmount(tester, state);
        }, () => server.client);
      },
    );

    testWidgets('Reject leaves them nobody in particular, and the badge goes', (
      tester,
    ) async {
      final server = _server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await _tapPod(tester, 'u3');
        await tester.tap(_key('seat-reject'));
        await _settle(tester);
        expect(server.count('POST', '/api/friends/requests/41/reject'), 1);
        expect(_inDrawer(_key('seat-add-friend')), findsOneWidget);
        expect(_badgeOn('u3'), findsNothing);
        expect(state.notice, isNull);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('a refusal is said in the drawer, which reads the profile '
        'again and offers the move that fits now', (tester) async {
      final server = _server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await _tapPod(tester, 'u1');
        expect(server.count('GET', '/api/players/u1/profile'), 1);

        // Ravi asked first, while the drawer still offered Add Friend.
        server
          ..sendRefusal = refusal(
            'request_already_received',
            409,
            requestId: 44,
          )
          ..incoming.add(requestJson(44, 'u1', 'Ravi'))
          ..profiles['u1'] = {
            ...server.profiles['u1']!,
            'friendStatus': 'PENDING_RECEIVED',
            'requestId': 44,
          };
        await tester.tap(_key('seat-add-friend'));
        await _settle(tester);
        expect(server.count('GET', '/api/players/u1/profile'), 2);
        expect(_inDrawer(_key('seat-accept')), findsOneWidget);
        expect(
          _inDrawer(find.text(t.friendRefuseAlreadyReceived)),
          findsOneWidget,
        );
        expect(state.notice, isNull, reason: 'said in the drawer, not toasted');
        // His seat wears the request now.
        expect(_badgeOn('u1'), findsOneWidget);

        // And he took it back before the viewer accepted.
        server
          ..answerRefusal = refusal('request_not_pending', 409)
          ..incoming.removeWhere((r) => r['requestId'] == 44)
          ..profiles['u1'] = {...server.profiles['u1']!, 'friendStatus': 'NONE'}
          ..profiles['u1']!.remove('requestId');
        await tester.tap(_key('seat-accept'));
        await _settle(tester);
        expect(server.count('GET', '/api/players/u1/profile'), 3);
        expect(_inDrawer(_key('seat-add-friend')), findsOneWidget);
        expect(_inDrawer(find.text(t.friendRefuseNotPending)), findsOneWidget);
        expect(state.notice, isNull);
        expect(_badgeOn('u1'), findsNothing);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('a profile that cannot be read offers Retry; a player the '
        'server no longer knows says so', (tester) async {
      final server = _server()..unsupported = false;
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        server.unsupported = true;
        await _tapPod(tester, 'u1');
        expect(_inDrawer(find.text(t.profileLoadFailed)), findsOneWidget);
        expect(_inDrawer(_key('seat-retry')), findsOneWidget);
        // The name stays: the seat already said who it is.
        expect(_inDrawer(find.text('Ravi')), findsOneWidget);
        server.unsupported = false;
        await tester.tap(_key('seat-retry'));
        await _settle(tester);
        expect(_inDrawer(_key('seat-add-friend')), findsOneWidget);
        await _closeDrawer(tester);

        server.profiles.remove('u2');
        await _tapPod(tester, 'u2');
        expect(
          _inDrawer(find.text(t.friendRefusePlayerNotFound)),
          findsOneWidget,
        );
        expect(_inDrawer(_key('seat-retry')), findsNothing);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('closing the drawer lets its player go', (tester) async {
      final server = _server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await _tapPod(tester, 'u1');
        expect(state.friends.seatPlayer?.userId, 'u1');
        expect(state.friends.seatProfile, isNotNull);
        await _closeDrawer(tester);
        expect(_drawerOpen(state), isFalse);
        expect(state.friends.seatPlayer, isNull);
        expect(state.friends.seatProfile, isNull);
        // The lobby page's own profile and search were never touched.
        expect(state.friends.profile, isNull);
        expect(state.friends.lookup, isNull);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('only a pod opens it: no swipe from the edge, on either felt', (
      tester,
    ) async {
      final server = _server();
      await http.runWithClient(() async {
        for (final room in [_teenPatti(), _poker()]) {
          final state = _state();
          await _mount(tester, state, room);
          final scaffold = tester.widget<Scaffold>(
            find.byKey(state.tableScaffold),
          );
          expect(scaffold.endDrawer, isA<PlayerDrawer>());
          expect(scaffold.endDrawerEnableOpenDragGesture, isFalse);
          // The room dimmed behind it as behind the table's other drawer.
          expect(scaffold.drawerScrimColor, TableScrim.drawer);
          await tester.dragFrom(const Offset(638, 200), const Offset(-260, 0));
          await _settle(tester);
          expect(_drawerOpen(state), isFalse);
          await _unmount(tester, state);
        }
      }, () => server.client);
    });

    testWidgets('the variation window opening for the viewer closes the '
        'drawer, as it closes the left one', (tester) async {
      final server = _server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await _tapPod(tester, 'u1');
        expect(_drawerOpen(state), isTrue);
        state.handleState(_teenPatti(choosing: true));
        await _settle(tester);
        expect(_drawerOpen(state), isFalse);
        expect(state.variationIsMine, isTrue);
        await _unmount(tester, state);
      }, () => server.client);
    });
  });

  group('the pushes', () {
    testWidgets('friend:request badges the sender\'s seat and says where to '
        'answer; from elsewhere, the plain line; blocked, nothing', (
      tester,
    ) async {
      final server = FakeFriendsServer();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        state.handleFriendRequest(
          const FriendRequestItem(
            requestId: '77',
            player: PlayerCard(userId: 'u2', displayName: 'Meera'),
            createdAt: 1790442915826,
          ),
        );
        await tester.pump();
        expect(state.notice, t.friendRequestAtTable('Meera'));
        expect(
          t.friendRequestAtTable('Meera'),
          'Meera sent you a friend request. Tap their seat to answer.',
        );
        expect(_badgeOn('u2'), findsOneWidget);
        expect(state.friends.incomingCount, 1);

        // Somebody not at this table: the plain line, and no seat to badge.
        state
          ..clearNotice()
          ..handleFriendRequest(
            const FriendRequestItem(
              requestId: '78',
              player: PlayerCard(userId: 'u-kavya', displayName: 'Kavya'),
            ),
          );
        await tester.pump();
        expect(state.notice, 'Kavya sent you a friend request.');
        expect(
          find.byKey(const ValueKey('seat-friend-request')),
          findsOneWidget,
        );

        // Blocked at this table: nothing is said, and the request stands —
        // on their seat too.
        state
          ..clearNotice()
          ..blockPlayer('u1')
          ..handleFriendRequest(
            const FriendRequestItem(
              requestId: '79',
              player: PlayerCard(userId: 'u1', displayName: 'Ravi'),
            ),
          );
        await tester.pump();
        expect(state.notice, isNull);
        expect(state.friends.hasRequestFrom('u1'), isTrue);
        expect(_badgeOn('u1'), findsOneWidget);
        expect(state.friends.incomingCount, 3);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('friend:request from the player an open drawer shows turns '
        'its Add Friend into Accept', (tester) async {
      final server = _server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await _tapPod(tester, 'u1');
        expect(_inDrawer(_key('seat-add-friend')), findsOneWidget);
        server.profiles['u1'] = {
          ...server.profiles['u1']!,
          'friendStatus': 'PENDING_RECEIVED',
          'requestId': 45,
        };
        state.handleFriendRequest(
          const FriendRequestItem(
            requestId: '45',
            player: PlayerCard(userId: 'u1', displayName: 'Ravi'),
          ),
        );
        await tester.pump();
        // At once, and read again to be sure.
        expect(_inDrawer(_key('seat-accept')), findsOneWidget);
        await _settle(tester);
        expect(server.count('GET', '/api/players/u1/profile'), 2);
        expect(_inDrawer(_key('seat-accept')), findsOneWidget);
        expect(_badgeOn('u1'), findsOneWidget);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('friend:accepted turns an open drawer to Friends and says so', (
      tester,
    ) async {
      final server = _server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await _tapPod(tester, 'u2');
        expect(_inDrawer(_key('seat-request-sent')), findsOneWidget);
        expect(state.friends.outgoing.map((r) => r.requestId), ['43']);

        server.profiles['u2'] = {
          ...server.profiles['u2']!,
          'friendStatus': 'FRIENDS',
        }..remove('requestId');
        state.handleFriendAccepted(
          const FriendAccepted(
            requestId: '43',
            player: PlayerCard(userId: 'u2', displayName: 'Meera'),
            friendsSince: 1790442915835,
          ),
        );
        await tester.pump();
        expect(_inDrawer(_key('seat-friends')), findsOneWidget);
        await _settle(tester);
        expect(server.count('GET', '/api/players/u2/profile'), 2);
        expect(_inDrawer(_key('seat-friends')), findsOneWidget);
        expect(state.notice, t.friendAcceptedYours('Meera'));
        expect(state.notice, 'Meera accepted your friend request.');
        expect(state.friends.outgoing, isEmpty);
        expect(state.friends.friends.map((f) => f.userId), contains('u2'));
        await _unmount(tester, state);
      }, () => server.client);
    });

    test(
      'both reach their streams exactly as the server writes them',
      () async {
        // Nothing listens on port 9: the socket tries, fails and is dropped.
        final conn = GameConnection('http://127.0.0.1:9');
        addTearDown(conn.dispose);
        conn.connect('t');
        final requests = <FriendRequestItem>[];
        final accepted = <FriendAccepted>[];
        conn.onFriendRequest.listen(requests.add);
        conn.onFriendAccepted.listen(accepted.add);
        final socket = conn.debugSocket!;
        socket.emitEvent([
          'friend:request',
          {
            'requestId': 1,
            'player': {
              'userId': 'a1c3',
              'displayName': 'Alice',
              'profilePicture': {'id': null, 'url': null},
            },
            'createdAt': 1790442915826,
          },
        ]);
        socket.emitEvent([
          'friend:accepted',
          {
            'requestId': 1,
            'player': {
              'userId': 'b0b0',
              'displayName': 'Bobby',
              'profilePicture': {'id': 7, 'url': 'https://cdn.test/p/7.svg'},
            },
            'friendsSince': 1790442915835,
          },
        ]);
        // Nobody to answer: dropped.
        socket.emitEvent([
          'friend:request',
          {'requestId': 2, 'player': <String, dynamic>{}},
        ]);
        socket.emitEvent(['friend:accepted', <String, dynamic>{}]);
        await pumpEventQueue();

        expect(requests, hasLength(1));
        expect(requests.single.requestId, '1');
        expect(requests.single.player.userId, 'a1c3');
        expect(requests.single.player.displayName, 'Alice');
        expect(requests.single.player.pictureUrl, isNull);
        expect(requests.single.createdAt, 1790442915826);
        expect(accepted, hasLength(1));
        expect(accepted.single.requestId, '1');
        expect(accepted.single.player.displayName, 'Bobby');
        expect(accepted.single.player.pictureId, 7);
        expect(accepted.single.player.pictureUrl, 'https://cdn.test/p/7.svg');
        expect(accepted.single.friendsSince, 1790442915835);
      },
    );

    test('a push before the session is ready is taken without a user or a '
        'table', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final state = GameState(serverUrl: friendsServer);
      debugDefaultTargetPlatformOverride = null;
      expect(state.user, isNull);
      expect(state.room, isNull);
      state.handleFriendRequest(
        const FriendRequestItem(
          requestId: '5',
          player: PlayerCard(userId: 'u9', displayName: 'Isha'),
        ),
      );
      expect(state.notice, 'Isha sent you a friend request.');
      expect(state.friends.incomingCount, 1);
      state.handleFriendAccepted(
        const FriendAccepted(
          requestId: '6',
          player: PlayerCard(userId: 'u8', displayName: 'Dev'),
        ),
      );
      expect(state.notice, 'Dev accepted your friend request.');
      expect(state.friends.friends.map((f) => f.userId), ['u8']);
      state.dispose();
    });

    test('a pushed request joins the requests at the top, once, and a read '
        'already out does not take it away', () async {
      final server = populatedServer()
        ..holdPath = '/api/friends/requests'
        ..hold = Completer<void>();
      final state = signedInState();
      final friends = state.friends;
      await http.runWithClient(() async {
        // A read sets out, and is held on the wire…
        final read = friends.refreshBadge();
        await pumpEventQueue();
        // …a request arrives meanwhile…
        friends.requestArrived(
          const FriendRequestItem(
            requestId: '90',
            player: PlayerCard(userId: 'u-kavya', displayName: 'Kavya'),
          ),
        );
        // …and the read lands, with the lists as they were before it.
        server.hold!.complete();
        await read;
      }, () => server.client);
      expect(friends.incoming.map((r) => r.requestId), ['90']);
      expect(friends.incomingCount, 1);
      // The same request again is still one.
      friends.requestArrived(
        const FriendRequestItem(
          requestId: '90',
          player: PlayerCard(userId: 'u-kavya', displayName: 'Kavya'),
        ),
      );
      expect(friends.incomingCount, 1);
      state.dispose();
    });

    test('a pushed acceptance makes them a friend and ends the request, and '
        'an open Friends page reads its lists', () async {
      final server = populatedServer();
      final state = signedInState();
      final friends = state.friends;
      await http.runWithClient(() => friends.refresh(), () => server.client);
      expect(friends.outgoing.map((r) => r.requestId), ['43']);
      final reads = server.count('GET', '/api/friends');
      friends.requestAccepted(
        const FriendAccepted(
          requestId: '43',
          player: PlayerCard(userId: 'u-dev', displayName: 'Dev'),
          friendsSince: 1790442915835,
        ),
      );
      expect(friends.outgoing, isEmpty);
      expect(friends.friends.map((f) => f.userId), contains('u-dev'));
      // The page is shut: nothing more is asked.
      expect(server.count('GET', '/api/friends'), reads);
      await http.runWithClient(() async {
        friends.pageOpened();
        await pumpEventQueue();
        friends.requestAccepted(
          const FriendAccepted(
            requestId: '44',
            player: PlayerCard(userId: 'u-sneha', displayName: 'Sneha'),
          ),
        );
        await pumpEventQueue();
        expect(server.count('GET', '/api/friends'), reads + 2);
        // A request pushed while the page is open reads its lists too.
        friends.requestArrived(
          const FriendRequestItem(
            requestId: '91',
            player: PlayerCard(userId: 'u-rohit', displayName: 'Rohit'),
          ),
        );
        await pumpEventQueue();
        expect(server.count('GET', '/api/friends'), reads + 3);
        friends.pageClosed();
        await pumpEventQueue();
      }, () => server.client);
      state.dispose();
    });
  });

  testWidgets('back closes the drawer before it asks about leaving, and the '
      'toast reaches the screen', (tester) async {
    final server = _server();
    await http.runWithClient(() async {
      final state = _state()..handleState(_teenPatti());
      _setView(tester);
      final feedback = await silentFeedback();
      addTearDown(feedback.dispose);
      // The app's own root: the back guard and the toast's host are its.
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GameState>.value(value: state),
            ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
          ],
          child: const KingTeenPattiApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 900));

      await _tapPod(tester, 'u1');
      expect(_drawerOpen(state), isTrue);

      Future<void> back() async {
        await tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .maybePop();
        await _settle(tester);
      }

      await back();
      expect(_drawerOpen(state), isFalse);
      expect(find.text(t.leaveTableQ), findsNothing);
      expect(state.screen, Screen.table);
      // Only then does Back ask.
      await back();
      expect(find.text(t.leaveTableQ), findsOneWidget);
      await tester.tap(find.text(t.stay));
      await _settle(tester);
      expect(state.screen, Screen.table);

      // A request pushed at the table, seen as the toast it raises.
      state.handleFriendRequest(
        const FriendRequestItem(
          requestId: '80',
          player: PlayerCard(userId: 'u4', displayName: 'Vikramaditya'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text(t.friendRequestAtTable('Vikramaditya')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
      state.dispose();
    }, () => server.client);
  });

  group('the drawer fits a 640x360 phone at text x1.25', () {
    for (final brightness in Brightness.values) {
      for (final lang in AppLang.values) {
        testWidgets('in ${lang.name} (${brightness.name})', (tester) async {
          final server = _server();
          final t = Strings(lang);
          await http.runWithClient(() async {
            final state = _state(lang: lang);
            await _mount(tester, state, _teenPatti(), brightness: brightness);
            for (final id in ['u1', 'u2', 'u3', 'u4']) {
              await _tapPod(tester, id);
              expect(_inDrawer(find.byType(PlayerStatsGrid)), findsOneWidget);
              _expectDrawerFits(tester, '$id ${lang.name}');
              _expectNothingButTheFriendship(tester, t, '$id ${lang.name}');
              // The keys inside the drawer, every one a whole target.
              for (final key in [
                'seat-add-friend',
                'seat-request-sent',
                'seat-accept',
                'seat-reject',
                'seat-friends',
              ]) {
                final found = _inDrawer(_key(key));
                if (found.evaluate().isEmpty) continue;
                final rect = tester.getRect(found);
                expect(rect.height, greaterThanOrEqualTo(Dim.minTouch - 0.5));
                expect(rect.right, lessThanOrEqualTo(640), reason: key);
              }
              await _closeDrawer(tester);
            }
            // A refusal, said in the drawer.
            server.sendRefusal = refusal('rate_limited', 429);
            await _tapPod(tester, 'u1');
            await tester.tap(_key('seat-add-friend'));
            await _settle(tester);
            expect(
              _inDrawer(find.text(t.friendRefuseRateLimited)),
              findsOneWidget,
            );
            _expectDrawerFits(tester, 'refused ${lang.name}');
            await _closeDrawer(tester);
            // A profile that cannot be read.
            server.unsupported = true;
            await _tapPod(tester, 'u1');
            expect(_inDrawer(_key('seat-retry')), findsOneWidget);
            _expectDrawerFits(tester, 'failed ${lang.name}');
            server.unsupported = false;
            await _unmount(tester, state);
          }, () => server.client);
        });
      }
    }

    testWidgets('on the poker felt too', (tester) async {
      final server = _server();
      await http.runWithClient(() async {
        final state = _state(lang: AppLang.bengali);
        await _mount(tester, state, _poker());
        await _tapPod(tester, 'u3');
        expect(_inDrawer(_key('seat-accept')), findsOneWidget);
        _expectDrawerFits(tester, 'poker');
        await _unmount(tester, state);
      }, () => server.client);
    });
  });

  test('no word of a wallet in anything the drawer or its toasts say, in any '
      'language', () {
    final wallet = RegExp(
      r'chip|diamond|hammer|missile|coin|wallet|lakh|crore|₹',
      caseSensitive: false,
    );
    const codes = [
      'player_not_found',
      'invalid_player_id',
      'self_request',
      'already_friends',
      'request_already_sent',
      'request_already_received',
      'request_not_found',
      'request_not_pending',
      'not_friends',
      'rate_limited',
      friendsNoAnswer,
      'something_new',
    ];
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final line in [
        t.addFriend,
        t.requestSent,
        t.friendAccept,
        t.friendReject,
        t.friends,
        t.wantsToBeFriends,
        t.profileLoadFailed,
        t.friendsRetry,
        t.close,
        t.handsPlayed,
        t.won,
        t.lost,
        t.leftMidHand,
        t.winRate,
        t.friendAdded('Ravi'),
        t.friendRequestArrived('Ravi'),
        t.friendRequestAtTable('Ravi'),
        t.friendAcceptedYours('Ravi'),
        for (final code in codes) friendsRefusalText(t, code),
      ]) {
        expect(wallet.hasMatch(line), isFalse, reason: '${lang.name} $line');
        for (final word in _walletWords[lang]!) {
          expect(line, isNot(contains(word)), reason: '${lang.name} $line');
        }
      }
      // Each new line is this language's own, never the English fallback.
      for (final key in [
        'friendRequestArrived',
        'friendRequestAtTable',
        'friendAcceptedYours',
      ]) {
        final own = t.ownEntry(key);
        expect(own, isNotNull, reason: '${lang.name} $key');
        expect(own, contains('{name}'), reason: '${lang.name} $key');
        if (lang != AppLang.english) {
          expect(
            own,
            isNot(const Strings(AppLang.english).ownEntry(key)),
            reason: '${lang.name} $key',
          );
        }
      }
    }
  });

  test('the record is the lobby profile\'s own widget, not a copy', () {
    final page = File('lib/screens/friends_screen.dart').readAsStringSync();
    final drawer = File('lib/widgets/player_drawer.dart').readAsStringSync();
    expect(page, contains('PlayerStatsGrid('));
    expect(drawer, contains('PlayerStatsGrid('));
    for (final source in [page, drawer]) {
      expect(source, isNot(contains('class _StatTile')));
      expect(source, isNot(contains('class _StatsGrid')));
      expect(source, isNot(contains('String _rate(')));
    }
  });

  test(
    'FriendsState keeps the drawer\'s player in a slot of its own',
    () async {
      final server = populatedServer();
      final state = signedInState();
      final friends = state.friends;
      await http.runWithClient(() async {
        await friends.openProfile('u-meera');
        await friends.openSeat(
          const PlayerCard(userId: 'u-kavya', displayName: 'Kavya'),
        );
      }, () => server.client);
      expect(friends.seatPlayer?.userId, 'u-kavya');
      expect(friends.seatProfile?.userId, 'u-kavya');
      // The Friends page's profile is where it was.
      expect(friends.profileFor, 'u-meera');
      expect(friends.profile?.userId, 'u-meera');
      friends.closeSeat();
      expect(friends.seatPlayer, isNull);
      expect(friends.seatProfile, isNull);
      expect(friends.profile?.userId, 'u-meera');
      state.dispose();
    },
  );
}
