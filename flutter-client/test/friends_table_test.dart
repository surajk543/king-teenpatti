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
import 'package:teenpatti/widgets/avatar.dart';
import 'package:teenpatti/widgets/glass_panels.dart';
import 'package:teenpatti/widgets/hammer_flight.dart';
import 'package:teenpatti/widgets/level_art.dart';
import 'package:teenpatti/widgets/player_drawer.dart';
import 'package:teenpatti/widgets/own_record.dart';
import 'package:teenpatti/widgets/own_seat_drawer.dart';
import 'package:teenpatti/widgets/player_profile.dart';
import 'package:teenpatti/widgets/poker_chip.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

import 'friends_fixture.dart';
import 'level_fixtures.dart' show levelArtJson, levelArtUrl, primeLevelArt;
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
/// [levels] gives a player's seat its `level`, by user id.
RoomState _teenPatti({
  List<int> empty = const [],
  bool choosing = false,
  Map<String, Map<String, Object?>> levels = const {},
}) => RoomState.fromJson({
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
  'seats': [
    for (var i = 0; i < 5; i++)
      {
        ..._seat(i, empty: empty.contains(i)),
        if (!empty.contains(i)) 'level': ?levels['u$i'],
      },
  ],
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
    'level': {
      'level': 10,
      'title': 'Rising Star',
      'icon': '🌟',
      ...levelArtJson(10),
    },
    'stats': {
      ...statsJson(played: 88, won: 30, lost: 50, left: 8, winRate: 34.09),
      // Were a server ever to send them, another player's chip figures are
      // dropped on the phone (StatsByCategory.fromJson(chips: false)).
      'totalWinnings': 7500000,
      'biggestPot': 5000000,
    },
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
    // The longest level the ladder has, for the head's room.
    'level': {'level': 44, 'title': 'Supreme Overlord', 'icon': '🔥🔱'},
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

Finder _markOn(String userId) =>
    find.descendant(of: _podOf(userId), matching: _key('seat-friend-mark'));

/// The player's picture on their pod.
Finder _pictureOf(String userId) =>
    find.descendant(of: _plaqueOf(userId), matching: find.byType(Avatar));

/// [mark] stands on a lower corner of [userId]'s picture — its foot on the
/// picture's foot, a quarter of it past the picture's [left] or right side —
/// inside the pod, and clear of the name over the picture.
void _expectOnPicture(
  WidgetTester tester,
  String userId,
  Finder mark, {
  required bool left,
}) {
  final pod = tester.getRect(_plaqueOf(userId));
  final picture = tester.getRect(_pictureOf(userId));
  final rect = tester.getRect(mark);
  expect(rect.width, closeTo(SeatPod.markSide(pod.width), 0.01));
  expect(rect.bottom, closeTo(picture.bottom, 0.01), reason: userId);
  if (left) {
    expect(rect.left, closeTo(picture.left - rect.width * 0.25, 0.01));
  } else {
    expect(rect.right, closeTo(picture.right + rect.width * 0.25, 0.01));
  }
  // Inside the pod's glass, and nowhere near the name above the picture.
  expect(pod.contains(rect.topLeft), isTrue, reason: '$userId $rect $pod');
  expect(
    pod.contains(rect.bottomRight - const Offset(0.01, 0.01)),
    isTrue,
    reason: '$userId $rect $pod',
  );
  final name = tester.getRect(
    find.descendant(of: _plaqueOf(userId), matching: find.byType(SeatName)),
  );
  expect(rect.overlaps(name), isFalse, reason: '$userId $rect over $name');
}

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
    // Nor another player's winnings or biggest pot (owner, 27 Sep 2026:
    // "players should not able to see each other total winnings and biggest
    // pot").
    expect(line, isNot(contains(t.totalWinnings)), reason: '$where: "$line"');
    expect(line, isNot(contains(t.biggestPot)), reason: '$where: "$line"');
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

      testWidgets('the viewer\'s own pod opens their own drawer, never '
          'another player\'s card; an empty chair opens nothing', (
        tester,
      ) async {
        final server = _server();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, room(empty: [3]));
          // Both take a tap; the viewer's own pod wears no request badge and
          // no friend mark.
          expect(tester.widget<SeatPod>(_podOf('u0')).onTap, isNotNull);
          expect(tester.widget<SeatPod>(_podOf('u1')).onTap, isNotNull);
          expect(tester.widget<SeatPod>(_podOf('u0')).requestBadge, isNull);
          expect(tester.widget<SeatPod>(_podOf('u0')).friendMark, isNull);

          // Owner, 27 Sep 2026: "player can click his own pod and it will his
          // own stats … and also shows his friend list".
          await tester.tap(_plaqueOf('u0'));
          await _settle(tester);
          expect(_drawerOpen(state), isTrue);
          expect(state.friends.ownOpen, isTrue);
          expect(state.friends.seatPlayer, isNull);
          expect(_inDrawer(_key('own-drawer')), findsOneWidget);
          // No profile of their own is read: the account already has it.
          expect(
            server.sent.where((r) => r.url.path.startsWith('/api/players/')),
            isEmpty,
          );
          await tester.tap(_key('stats-close'));
          await _settle(tester);
          expect(_drawerOpen(state), isFalse);
          expect(state.friends.ownOpen, isFalse);

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
          // On the lower-left corner of the picture, inside the pod, clear
          // of the name.
          _expectOnPicture(tester, 'u2', _badgeOn('u2'), left: true);
          expect(tester.takeException(), isNull);
          await _unmount(tester, state);
        }, () => server.client);
      });
    });

    // The owner, 26 Sep 2026: "if two or more friends are on same table
    // playing game then their should appear small icon on each of them so
    // that they can know they are friends while other are not their friend so
    // they cannot see that icon".
    group('the friend mark on the $felt felt', () {
      testWidgets('a friend\'s pod wears it, named "Friend", and nobody '
          'else\'s — never the viewer\'s own, never an empty chair', (
        tester,
      ) async {
        // Even a list that named the viewer, and a friend in no seat here.
        final server = _server()
          ..friends.addAll([
            friendJson('u0', 'Priya'),
            friendJson('u1', 'Ravi'),
          ]);
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, room(empty: [1]));
          expect(_markOn('u4'), findsOneWidget);
          for (final id in ['u0', 'u2', 'u3']) {
            expect(_markOn(id), findsNothing, reason: id);
          }
          // One mark on the whole table — Vikramaditya's: the viewer's own
          // pod and the empty chair wear none, whatever the list says.
          expect(state.friends.isFriend('u0'), isTrue);
          expect(state.friends.isFriend('u1'), isTrue);
          expect(_key('seat-friend-mark'), findsOneWidget);
          expect(find.byType(SeatFriendMark), findsNWidgets(3));
          _expectOnPicture(tester, 'u4', _markOn('u4'), left: false);
          expect(find.bySemanticsLabel(t.friendMark), findsOneWidget);
          expect(t.friendMark, 'Friend');
          expect(tester.takeException(), isNull);
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('it comes at once when the viewer\'s request is accepted, '
          'and when the viewer accepts one — the list is not read again', (
        tester,
      ) async {
        final server = _server();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, room());
          expect(_markOn('u2'), findsNothing);
          expect(_markOn('u3'), findsNothing);
          // Meera accepts the request the viewer sent her (friend:accepted).
          state.handleFriendAccepted(
            const FriendAccepted(
              requestId: '43',
              player: PlayerCard(userId: 'u2', displayName: 'Meera'),
              friendsSince: 1790442915835,
            ),
          );
          await tester.pump();
          expect(_markOn('u2'), findsOneWidget);
          // The viewer accepts Arjun's in the drawer his seat opens.
          await _tapPod(tester, 'u3');
          await tester.tap(_key('seat-accept'));
          await _settle(tester);
          expect(_markOn('u3'), findsOneWidget);
          expect(_badgeOn('u3'), findsNothing);
          await _closeDrawer(tester);
          expect(_key('seat-friend-mark'), findsNWidgets(3));
          expect(server.count('GET', '/api/friends'), 1);
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('it changes neither the pod\'s size nor the ring\'s places', (
        tester,
      ) async {
        final server = _server()
          ..holdPath = '/api/friends'
          ..hold = Completer<void>();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, room());
          // The list is still on its way: no mark yet.
          expect(_key('seat-friend-mark'), findsNothing);
          final pods = {
            for (final id in _names.keys) id: tester.getRect(_plaqueOf(id)),
          };
          final pictures = {
            for (final id in _names.keys) id: tester.getRect(_pictureOf(id)),
          };
          server.hold!.complete();
          await _settle(tester);
          expect(_markOn('u4'), findsOneWidget);
          // The pod on turn is left out: its turn ring breathes, which moves
          // its box by a fraction of a pixel between any two moments, mark or
          // no mark. The mark itself is on u4, which is not on turn.
          final onTurn = state.room?.turn?.userId;
          expect(onTurn, isNot('u4'));
          for (final id in _names.keys) {
            if (id == onTurn) continue;
            expect(tester.getRect(_plaqueOf(id)), pods[id], reason: id);
            expect(tester.getRect(_pictureOf(id)), pictures[id], reason: id);
          }
          expect(tester.takeException(), isNull);
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('it and the request badge stand on opposite corners of the '
          'picture, so the two could be worn together', (tester) async {
        // Never both in truth — a friend has no request waiting — so the list
        // is made to say both of Arjun.
        final server = _server()..friends.add(friendJson('u3', 'Arjun'));
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, room());
          expect(_markOn('u3'), findsOneWidget);
          expect(_badgeOn('u3'), findsOneWidget);
          _expectOnPicture(tester, 'u3', _markOn('u3'), left: false);
          _expectOnPicture(tester, 'u3', _badgeOn('u3'), left: true);
          expect(
            tester
                .getRect(_markOn('u3'))
                .overlaps(tester.getRect(_badgeOn('u3'))),
            isFalse,
          );
          await _unmount(tester, state);
        }, () => server.client);
      });
    });
  }

  group('the friend mark', () {
    testWidgets('a server from before Friends shows no marks, no badges and '
        'no drawer', (tester) async {
      final server = FakeFriendsServer(
        friends: [friendJson('u4', 'Vikramaditya')],
        incoming: [requestJson(41, 'u3', 'Arjun')],
      )..unsupported = true;
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        expect(state.friends.available, isFalse);
        expect(_key('seat-friend-mark'), findsNothing);
        expect(_key('seat-friend-request'), findsNothing);
        await tester.tap(_plaqueOf('u4'), warnIfMissed: false);
        await _settle(tester);
        expect(_drawerOpen(state), isFalse);
        // Asked once, as the table opened, and never again.
        await tester.pump(const Duration(minutes: 3));
        expect(server.count('GET', '/api/friends'), 1);
        await _unmount(tester, state);
      }, () => server.client);
    });

    test(
      'the Friends page and the table read one answer to "is this player '
      'my friend", kept by the list, an accept, the push and a removal',
      () async {
        final server = populatedServer();
        final state = signedInState();
        final friends = state.friends;
        Future<T> on<T>(Future<T> Function() body) =>
            http.runWithClient(body, () => server.client);
        void agrees() {
          for (final id in [
            'u-meera',
            'u-arjun',
            'u-kavya',
            'u-ravi',
            'u-isha',
            'u-dev',
          ]) {
            expect(
              friends.isFriend(id),
              friends.friends.any((f) => f.userId == id),
              reason: id,
            );
          }
        }

        expect(friends.isFriend('u-meera'), isFalse);
        // A read of the list: the page's, and the table's as it opens.
        await on(friends.tableOpened);
        expect(friends.isFriend('u-meera'), isTrue);
        expect(friends.isFriend('u-ravi'), isFalse);
        agrees();
        // The player's own Accept.
        await on(() => friends.accept('41'));
        expect(friends.isFriend('u-ravi'), isTrue);
        agrees();
        // An acceptance pushed to the player who asked.
        friends.requestAccepted(
          const FriendAccepted(
            requestId: '43',
            player: PlayerCard(userId: 'u-dev', displayName: 'Dev'),
          ),
        );
        expect(friends.isFriend('u-dev'), isTrue);
        agrees();
        // A removal — in the lobby, the only place one is made.
        await on(() => friends.remove('u-meera'));
        expect(friends.isFriend('u-meera'), isFalse);
        agrees();
        expect(friends.isFriend(null), isFalse);
        expect(friends.isFriend(''), isFalse);
        // Signed out: nobody.
        friends.reset();
        expect(friends.isFriend('u-ravi'), isFalse);
        agrees();
        state.dispose();
      },
    );

    test('its glyph holds 3:1 or more on its disc, by day and by night', () {
      double contrast(Color a, Color b) {
        final la = a.computeLuminance();
        final lb = b.computeLuminance();
        return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
      }

      for (final b in Brightness.values) {
        expect(
          contrast(friendMarkInk(b), friendsGreen(b)),
          greaterThanOrEqualTo(3),
          reason: b.name,
        );
      }
    });
  });

  group('the marks read at 640x360, text x1.25', () {
    for (final brightness in Brightness.values) {
      for (final lang in AppLang.values) {
        testWidgets('in ${lang.name} (${brightness.name})', (tester) async {
          final t = Strings(lang);
          for (final room in [_teenPatti(), _poker()]) {
            // Ravi and Vikramaditya friends, Arjun asking.
            final server = _server()..friends.add(friendJson('u1', 'Ravi'));
            await http.runWithClient(() async {
              final state = _state(lang: lang);
              await _mount(tester, state, room, brightness: brightness);
              final where = '${room.category} ${lang.name}';
              expect(tester.takeException(), isNull, reason: where);
              expect(_markOn('u1'), findsOneWidget, reason: where);
              expect(_markOn('u4'), findsOneWidget, reason: where);
              expect(_badgeOn('u3'), findsOneWidget, reason: where);
              _expectOnPicture(tester, 'u1', _markOn('u1'), left: false);
              _expectOnPicture(tester, 'u4', _markOn('u4'), left: false);
              _expectOnPicture(tester, 'u3', _badgeOn('u3'), left: true);
              for (final id in ['u1', 'u4']) {
                final mark = tester.getRect(_markOn(id));
                expect(mark.width, greaterThanOrEqualTo(15), reason: where);
                expect(
                  Offset.zero & const Size(640, 360),
                  predicate<Rect>((screen) => screen.contains(mark.center)),
                  reason: where,
                );
              }
              expect(
                find.bySemanticsLabel(t.friendMark),
                findsNWidgets(2),
                reason: where,
              );
              await _unmount(tester, state);
            }, () => server.client);
          }
        });
      }
    }
  });

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

    testWidgets('the requests waiting and the friends are read once as the '
        'table opens, and nothing at the table asks again', (tester) async {
      final server = _server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        expect(server.count('GET', '/api/friends/requests'), 1);
        expect(server.count('GET', '/api/friends'), 1);
        await tester.pump();
        expect(_badgeOn('u3'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('seat-friend-request')),
          findsOneWidget,
        );
        expect(_markOn('u4'), findsOneWidget);
        // Another snapshot of the same table, and minutes of play.
        state.handleState(_teenPatti());
        await tester.pump(const Duration(minutes: 3));
        expect(server.count('GET', '/api/friends/requests'), 1);
        expect(server.count('GET', '/api/friends'), 1);
        expect(_markOn('u4'), findsOneWidget);
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

  // Owner, 27 Sep 2026: "In game table each player can see each other level
  // of player also by clicking other player pod … but players should not able
  // to see each other total winnings and biggest pot".
  group('the player\'s level', () {
    testWidgets('under the name once the profile says it; nothing before, '
        'and nothing where the profile has none', (tester) async {
      final server = _server()
        ..holdPath = '/api/players/u1/profile'
        ..hold = Completer<void>();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await tester.tap(_plaqueOf('u1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(_inDrawer(_key('seat-loading')), findsOneWidget);
        expect(_inDrawer(_key('seat-player-level')), findsNothing);
        server.hold!.complete();
        await _settle(tester);
        final level = _inDrawer(_key('seat-player-level'));
        expect(level, findsOneWidget);
        expect(
          tester.widget<Text>(level).data,
          state.t.levelName(10, 'Rising Star'),
        );
        // Under the name, in the head.
        final name = tester.getRect(_inDrawer(_key('seat-player-name')));
        expect(tester.getRect(level).top, greaterThanOrEqualTo(name.bottom));
        await _closeDrawer(tester);

        // Meera's profile has no level (a server from before levels).
        await _tapPod(tester, 'u2');
        expect(_inDrawer(_key('seat-player-name')), findsOneWidget);
        expect(_inDrawer(_key('seat-player-level')), findsNothing);
        await _unmount(tester, state);
      }, () => server.client);
    });

    // Owner, 29 Sep 2026: "when i click on Player pod and it opens player
    // drawer then profile pic should be big and in top right of profile pic
    // it should show his level icon".
    group('on the portrait', () {
      setUp(primeLevelArt);
      final mark = _key('seat-player-level-mark');

      testWidgets('the picture is large, with the level\'s disc on its '
          'top-right: the seat\'s level at once, the profile\'s once it has '
          'come', (tester) async {
        final server = _server()
          ..holdPath = '/api/players/u1/profile'
          ..hold = Completer<void>();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(
            tester,
            state,
            _teenPatti(
              levels: {
                'u1': {'level': 3, ...levelArtJson(3)},
              },
            ),
          );
          await tester.tap(_plaqueOf('u1'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));

          final picture = tester.getRect(
            _inDrawer(_key('seat-player-picture')),
          );
          // The portrait, large: 68 across, and its ring round it.
          expect(picture.width, 71);
          expect(picture.height, 71);

          // Before the profile: the seat's level.
          expect(_inDrawer(mark), findsOneWidget);
          final art = _inDrawer(_key('seat-player-level-art'));
          expect(tester.widget<LevelArt>(art).assetUrl, levelArtUrl(3));

          // A gold-rimmed disc, its middle on the picture's rim at the
          // top-right, the art inside it.
          final disc = tester.getRect(_inDrawer(mark));
          expect(disc.width, closeTo(68 * 0.44, 0.5));
          final off = disc.center - picture.center;
          expect(off.dx, closeTo(picture.width / 2 * 0.7071, 0.5));
          expect(off.dy, closeTo(-picture.width / 2 * 0.7071, 0.5));
          final decoration =
              tester.widget<Container>(_inDrawer(mark)).decoration!
                  as BoxDecoration;
          expect(decoration.shape, BoxShape.circle);
          expect(decoration.border, isNotNull);
          expect(tester.getRect(art).center.dx, closeTo(disc.center.dx, 0.5));
          // Inside the drawer, and clear of the name beside it.
          final panel = tester.getRect(
            _inDrawer(find.byType(PremiumGlassPanel)).first,
          );
          expect(disc.top, greaterThanOrEqualTo(panel.top));
          expect(
            tester.getRect(_inDrawer(_key('seat-player-name'))).left,
            greaterThanOrEqualTo(disc.right),
          );

          // The profile's level replaces it; its words stay under the name,
          // with no second copy of the art beside them.
          server.hold!.complete();
          await _settle(tester);
          expect(
            tester
                .widget<LevelArt>(_inDrawer(_key('seat-player-level-art')))
                .assetUrl,
            levelArtUrl(10),
          );
          expect(_inDrawer(find.byType(LevelArt)), findsOneWidget);
          expect(_inDrawer(_key('seat-player-level')), findsOneWidget);
          await _closeDrawer(tester);

          // No art at either: Vikramaditya's profile sends his Level 44 with
          // none, and Meera's has no level at all.
          for (final id in ['u4', 'u2']) {
            await _tapPod(tester, id);
            expect(_inDrawer(_key('seat-player-picture')), findsOneWidget);
            expect(_inDrawer(mark), findsNothing, reason: id);
            await _closeDrawer(tester);
          }
          await _unmount(tester, state);
        }, () => server.client);
      });

      // Owner, 29 Sep 2026: "When i open player drawer, then scrolling gets
      // stuck": the large head was fixed above the record.
      testWidgets('the whole drawer scrolls — a drag that begins on the '
          'portrait moves it — and the close key stays', (tester) async {
        final server = _server();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, _teenPatti());
          await _tapPod(tester, 'u1');
          final list = _inDrawer(_key('player-drawer-list'));
          ScrollPosition position() => tester
              .state<ScrollableState>(
                find.descendant(of: list, matching: find.byType(Scrollable)),
              )
              .position;
          expect(position().pixels, 0);
          final close = tester.getRect(_key('seat-close'));
          final picture = _inDrawer(_key('seat-player-picture'));
          final before = tester.getRect(picture);

          // From the portrait, up: the whole drawer moves with the finger.
          await tester.dragFrom(before.center, const Offset(0, -80));
          await _settle(tester);
          expect(position().pixels, greaterThan(40));
          expect(tester.getRect(picture).top, lessThan(before.top - 40));
          // The close key where it was, over the scroll.
          expect(tester.getRect(_key('seat-close')), close);

          // To the end of the record, and back to the head.
          await tester.fling(list, const Offset(0, -2000), 3000);
          await _settle(tester);
          await tester.pump(const Duration(seconds: 1));
          expect(position().pixels, position().maxScrollExtent);
          expect(position().maxScrollExtent, greaterThan(0));
          await tester.fling(list, const Offset(0, 2000), 3000);
          await _settle(tester);
          await tester.pump(const Duration(seconds: 1));
          expect(position().pixels, 0);
          expect(tester.getRect(picture), before);

          // And it still closes the drawer.
          await _closeDrawer(tester);
          expect(_drawerOpen(state), isFalse);
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('the head fits at 640x360 x1.25 in every language, both '
          'themes', (tester) async {
        for (final brightness in Brightness.values) {
          for (final lang in AppLang.values) {
            final server = _server();
            await http.runWithClient(() async {
              final state = _state(lang: lang);
              await _mount(tester, state, _teenPatti(), brightness: brightness);
              await _tapPod(tester, 'u1');
              expect(_inDrawer(mark), findsOneWidget, reason: lang.name);
              final where = '${lang.name} ${brightness.name}';
              _expectDrawerFits(tester, where);
              final disc = tester.getRect(_inDrawer(mark));
              final name = tester.getRect(_inDrawer(_key('seat-player-name')));
              expect(
                name.left,
                greaterThanOrEqualTo(disc.right),
                reason: where,
              );
              await _unmount(tester, state);
            }, () => server.client);
          }
        }
      });
    });

    testWidgets('no winnings, no biggest pot — even were the server to send '
        'them', (tester) async {
      final server = _server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await _tapPod(tester, 'u1');
        expect(_inDrawer(find.byType(PlayerStatsGrid)), findsOneWidget);
        final t = state.t;
        expect(_inDrawer(find.textContaining(t.totalWinnings)), findsNothing);
        expect(_inDrawer(find.textContaining(t.biggestPot)), findsNothing);
        expect(_inDrawer(find.textContaining('75 Lakh')), findsNothing);
        expect(_inDrawer(find.textContaining('50 Lakh')), findsNothing);
        _expectNothingButTheFriendship(tester, t, 'u1');
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('the longest level fits the head whole at 640x360 x1.25 in '
        'every language', (tester) async {
      for (final lang in AppLang.values) {
        final server = _server();
        await http.runWithClient(() async {
          final state = _state(lang: lang);
          await _mount(tester, state, _teenPatti());
          await _tapPod(tester, 'u4');
          final level = _inDrawer(_key('seat-player-level'));
          expect(level, findsOneWidget, reason: lang.name);
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: level, matching: find.byType(RichText)),
          );
          expect(paragraph.didExceedMaxLines, isFalse, reason: lang.name);
          final head = tester.getRect(_inDrawer(_key('seat-player-name')));
          final rect = tester.getRect(level);
          expect(rect.left, greaterThanOrEqualTo(head.left - 0.5));
          expect(
            rect.right,
            lessThanOrEqualTo(640.5),
            reason: '${lang.name}: $rect',
          );
          _expectDrawerFits(tester, 'level ${lang.name}');
          await _unmount(tester, state);
        }, () => server.client);
      }
    });
  });

  // Owner, 27 Sep 2026: "In game table, player can click his own pod and it
  // will his own stats which you show when you click in lobby and also shows
  // his friend list with status who all are online and other info".
  group('the viewer\'s own drawer', () {
    /// Vikramaditya playing (the table's friend), Kavya online, Dev offline.
    FakeFriendsServer ownServer() => _server()
      ..friends.addAll([
        friendJson('u8', 'Dev'),
        friendJson('u9', 'Kavya', status: 'ONLINE'),
      ]);

    Future<void> openOwn(WidgetTester tester) async {
      await tester.tap(_plaqueOf('u0'));
      await _settle(tester);
    }

    testWidgets('the record first, the lobby Stats drawer\'s own: the head, '
        'the scope menu and the figures', (tester) async {
      final server = ownServer();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await openOwn(tester);
        expect(_inDrawer(_key('own-drawer')), findsOneWidget);
        expect(_inDrawer(find.byType(PlayerStatsHeader)), findsOneWidget);
        expect(_inDrawer(find.text('Priya')), findsOneWidget);
        expect(_inDrawer(find.byType(OwnRecord)), findsOneWidget);
        expect(_inDrawer(find.byType(StatsScopeSelector)), findsOneWidget);
        // As wide as the lobby's Stats drawer, wider than a player's card.
        final panel = tester.widget<GlassDrawerPanel>(
          _inDrawer(find.byType(GlassDrawerPanel)),
        );
        expect(panel.width, OwnSeatBody.widthFor(640));
        expect(panel.alignment, AlignmentDirectional.centerEnd);
        _expectDrawerFits(tester, 'record');
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('Friends: every friend with where they are, playing first, '
        'then online, then offline, and how many are online', (tester) async {
      final server = ownServer();
      await http.runWithClient(() async {
        final state = _state();
        final t = state.t;
        await _mount(tester, state, _teenPatti());
        await openOwn(tester);
        // The tab says how many are online before it is opened.
        expect(
          _inDrawer(find.textContaining(t.friendsOnlineCount(2))),
          findsOneWidget,
        );
        await tester.tap(_key('own-tab-friends'));
        await _settle(tester);
        final rows = [
          for (final id in ['u4', 'u9', 'u8'])
            tester.getRect(_inDrawer(_key('own-friend:$id'))),
        ];
        expect(rows[0].top, lessThan(rows[1].top));
        expect(rows[1].top, lessThan(rows[2].top));
        Finder inRow(String id, Finder f) =>
            find.descendant(of: _inDrawer(_key('own-friend:$id')), matching: f);
        expect(inRow('u4', find.textContaining(t.playingNow)), findsOneWidget);
        expect(
          inRow(
            'u4',
            find.text(
              '${friendlyName(t.teenPatti)} • '
              '${friendlyName(t.seen)}',
            ),
          ),
          findsOneWidget,
        );
        expect(inRow('u9', _key('presence-dot-online')), findsOneWidget);
        expect(inRow('u9', find.textContaining(t.playingNow)), findsNothing);
        expect(inRow('u8', _key('presence-dot-offline')), findsOneWidget);
        expect(
          inRow('u8', find.textContaining(t.presenceOffline)),
          findsOneWidget,
        );
        _expectDrawerFits(tester, 'friends');
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('the list is read as it opens and every 15 s while it shows, '
        'and no more once it has closed', (tester) async {
      final server = ownServer();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        final before = server.count('GET', '/api/friends');
        await openOwn(tester);
        expect(server.count('GET', '/api/friends'), before + 1);
        // Kavya goes offline and Dev comes online, between two reads.
        server.friends
          ..removeWhere((f) => f['userId'] == 'u9' || f['userId'] == 'u8')
          ..addAll([
            friendJson('u9', 'Kavya'),
            friendJson('u8', 'Dev', status: 'ONLINE'),
          ]);
        await tester.tap(_key('own-tab-friends'));
        await tester.pump(FriendsState.pollEvery);
        await _settle(tester);
        expect(server.count('GET', '/api/friends'), before + 2);
        expect(
          find.descendant(
            of: _inDrawer(_key('own-friend:u8')),
            matching: _key('presence-dot-online'),
          ),
          findsOneWidget,
        );
        await tester.tap(_key('stats-close'));
        await _settle(tester);
        final closed = server.count('GET', '/api/friends');
        await tester.pump(FriendsState.pollEvery * 3);
        expect(server.count('GET', '/api/friends'), closed);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('no friends says so; a list that cannot be read offers Retry', (
      tester,
    ) async {
      final server = FakeFriendsServer();
      await http.runWithClient(() async {
        final state = _state();
        final t = state.t;
        await _mount(tester, state, _teenPatti());
        await openOwn(tester);
        await tester.tap(_key('own-tab-friends'));
        await _settle(tester);
        expect(_inDrawer(find.text(t.noFriendsTitle)), findsOneWidget);
        await tester.tap(_key('stats-close'));
        await _settle(tester);

        server.failLists = true;
        state.friends.reset();
        await openOwn(tester);
        await tester.tap(_key('own-tab-friends'));
        await _settle(tester);
        expect(_inDrawer(find.text(t.friendsLoadFailed)), findsOneWidget);
        server.failLists = false;
        server.friends.add(friendJson('u9', 'Kavya', status: 'ONLINE'));
        await tester.tap(_key('own-friends-retry'));
        await _settle(tester);
        expect(_inDrawer(_key('own-friend:u9')), findsOneWidget);
        await _unmount(tester, state);
      }, () => server.client);
    });

    for (final brightness in Brightness.values) {
      testWidgets('both tabs fit 640x360 at text x1.25 in every language '
          '(${brightness.name}), on both felts', (tester) async {
        for (final lang in AppLang.values) {
          for (final room in [_teenPatti(), _poker()]) {
            final server = ownServer();
            await http.runWithClient(() async {
              final state = _state(lang: lang);
              await _mount(tester, state, room, brightness: brightness);
              final where = '${lang.name} ${room.category}';
              await openOwn(tester);
              expect(
                _inDrawer(_key('own-drawer')),
                findsOneWidget,
                reason: where,
              );
              _expectDrawerFits(tester, 'record $where');
              await tester.tap(_key('own-tab-friends'));
              await _settle(tester);
              _expectDrawerFits(tester, 'friends $where');
              await _unmount(tester, state);
            }, () => server.client);
          }
        }
      });
    }
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
            // A profile that cannot be read, for a player with none kept: a
            // record read before would show instead ('a drawer opened
            // again'), so what this account kept is forgotten first.
            state.friends.reset();
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
  // Owner, 29 Sep 2026: "when i click player pod, it calls api to get
  // information, if i close that pod, open again it should show previous
  // fetched record and meanwhile it will async api to fetch latest record,
  // and it will update, otherwise it will show previous fetched record".
  group('a drawer opened again', () {
    const kavya = PlayerCard(userId: 'u-kavya', displayName: 'Kavya');
    const path = '/api/players/u-kavya/profile';

    test('shows the profile read last time at once, reads it again, and '
        'takes the fresh one', () async {
      final server = populatedServer();
      final state = signedInState();
      final friends = state.friends;
      await http.runWithClient(() async {
        await friends.openSeat(kavya);
        final first = friends.seatProfile!;
        expect(first.stats.handsPlayed, 10);
        friends.closeSeat();
        expect(friends.seatProfile, isNull);
        expect(friends.cachedSeatProfile('u-kavya'), same(first));

        // Kavya has played since; the read is slow to answer.
        server.profiles['u-kavya'] = {
          ...server.profiles['u-kavya']!,
          'stats': statsJson(played: 11, won: 5, lost: 6, left: 0),
        };
        server
          ..holdPath = path
          ..hold = Completer<void>();
        final reading = friends.openSeat(kavya);
        // On show at once, while the read is out.
        expect(friends.seatProfile, same(first));
        expect(friends.seatLoading, isTrue);
        // The read has gone out, and is held: the old profile still shows.
        await pumpEventQueue();
        expect(server.count('GET', path), 2);
        expect(friends.seatProfile, same(first));
        server.hold!.complete();
        await reading;
        expect(friends.seatLoading, isFalse);
        expect(friends.seatProfile!.stats.handsPlayed, 11);
        expect(friends.seatError, isNull);
        // And kept for next time.
        expect(friends.cachedSeatProfile('u-kavya')!.stats.handsPlayed, 11);
      }, () => server.client);
      state.dispose();
    });

    test('keeps the profile read last time when the read fails; a player '
        'the server no longer knows is dropped', () async {
      final server = populatedServer();
      final state = signedInState();
      final friends = state.friends;
      await http.runWithClient(() async {
        await friends.openSeat(kavya);
        final first = friends.seatProfile!;
        friends.closeSeat();

        server.failProfiles = true;
        await friends.openSeat(kavya);
        expect(friends.seatProfile, same(first));
        expect(friends.seatError, isNotNull);
        friends.closeSeat();

        // Gone since: nothing left to show, then or next time.
        server
          ..failProfiles = false
          ..profiles.remove('u-kavya');
        await friends.openSeat(kavya);
        expect(friends.seatProfile, isNull);
        expect(friends.seatError, 'player_not_found');
        expect(friends.cachedSeatProfile('u-kavya'), isNull);
      }, () => server.client);
      state.dispose();
    });

    test(
      'shows what changed while it was shut, never a move from before it',
      () async {
        final server = populatedServer();
        final state = signedInState();
        final friends = state.friends;
        await http.runWithClient(() async {
          await friends.openSeat(kavya);
          expect(friends.seatProfile!.friendStatus, FriendStatus.friends);
          friends.closeSeat();
          // Removed from the Friends page while the drawer was shut.
          await friends.remove('u-kavya');
          expect(
            friends.cachedSeatProfile('u-kavya')!.friendStatus,
            FriendStatus.none,
          );
          server
            ..holdPath = path
            ..hold = Completer<void>();
          final reading = friends.openSeat(kavya);
          expect(friends.seatProfile!.friendStatus, FriendStatus.none);
          server.hold!.complete();
          await reading;
        }, () => server.client);
        state.dispose();
      },
    );

    test(
      'is forgotten at sign-out, and keeps the players opened last',
      () async {
        final server = populatedServer();
        final state = signedInState();
        final friends = state.friends;
        await http.runWithClient(() async {
          await friends.openSeat(kavya);
          friends.closeSeat();
        }, () => server.client);
        expect(friends.cachedSeatProfile('u-kavya'), isNotNull);
        friends.reset();
        expect(friends.cachedSeatProfile('u-kavya'), isNull);

        // A bounded memory: past its size the player opened longest ago goes.
        final many = FakeFriendsServer();
        for (var i = 0; i <= FriendsState.seatCacheSize; i++) {
          many.profiles['p$i'] = {
            ...cardJson('p$i', 'P$i'),
            'friendStatus': 'NONE',
            'stats': statsJson(),
          };
        }
        await http.runWithClient(() async {
          for (var i = 0; i <= FriendsState.seatCacheSize; i++) {
            await friends.openSeat(
              PlayerCard(userId: 'p$i', displayName: 'P$i'),
            );
          }
        }, () => many.client);
        expect(friends.cachedSeatProfile('p0'), isNull);
        expect(friends.cachedSeatProfile('p1'), isNotNull);
        expect(
          friends.cachedSeatProfile('p${FriendsState.seatCacheSize}'),
          isNotNull,
        );
        state.dispose();
      },
    );

    testWidgets('at the table: the record on show at once, no loader, the '
        'fresh one laid over it', (tester) async {
      final server = _server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await _tapPod(tester, 'u1');
        expect(_inDrawer(find.byType(PlayerStatsGrid)), findsOneWidget);
        await _closeDrawer(tester);

        server.profiles['u1'] = {
          ...server.profiles['u1']!,
          'stats': statsJson(played: 89, won: 31, lost: 50, left: 8),
        };
        server
          ..holdPath = '/api/players/u1/profile'
          ..hold = Completer<void>();
        await tester.tap(_plaqueOf('u1'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(_inDrawer(_key('seat-loading')), findsNothing);
        expect(_inDrawer(find.byType(PlayerStatsGrid)), findsOneWidget);
        expect(_inDrawer(find.text('88')), findsWidgets);
        expect(_inDrawer(_key('seat-player-level')), findsOneWidget);

        server.hold!.complete();
        await _settle(tester);
        expect(_inDrawer(find.text('89')), findsWidgets);
        expect(_inDrawer(find.text('88')), findsNothing);
        await _unmount(tester, state);
      }, () => server.client);
    });
  });

  // The owner, 26 Sep 2026: "In the friends drawer also show each other at the
  // top how long they are friends in time, friendship time".
  group('how long two players have been friends', () {
    test('is counted in the largest whole unit, in every language', () {
      String at(Duration d) => t.friendsFor(d);
      expect(at(Duration.zero), 'Friends since just now');
      expect(at(const Duration(seconds: 59)), 'Friends since just now');
      expect(at(const Duration(seconds: -5)), 'Friends since just now');
      expect(at(const Duration(minutes: 1)), 'Friends for 1 minute');
      expect(at(const Duration(minutes: 59)), 'Friends for 59 minutes');
      expect(at(const Duration(hours: 1)), 'Friends for 1 hour');
      expect(at(const Duration(hours: 23)), 'Friends for 23 hours');
      expect(at(const Duration(days: 1)), 'Friends for 1 day');
      expect(at(const Duration(days: 29)), 'Friends for 29 days');
      expect(at(const Duration(days: 30)), 'Friends for 1 month');
      expect(at(const Duration(days: 364)), 'Friends for 12 months');
      expect(at(const Duration(days: 365)), 'Friends for 1 year');
      expect(at(const Duration(days: 800)), 'Friends for 2 years');
      for (final lang in AppLang.values) {
        final s = Strings(lang);
        for (final d in const [
          Duration.zero,
          Duration(minutes: 5),
          Duration(hours: 5),
          Duration(days: 3),
          Duration(days: 90),
          Duration(days: 800),
        ]) {
          final line = s.friendsFor(d);
          expect(line, isNot(contains('{')), reason: '${lang.name} $d');
          expect(line.trim(), isNotEmpty, reason: '${lang.name} $d');
          if (d > Duration.zero) {
            expect(line, contains(RegExp(r'\d')), reason: '${lang.name} $d');
          }
        }
      }
    });

    for (final MapEntry(key: felt, value: room) in felts.entries) {
      testWidgets('on the $felt felt a friend\'s drawer says it under their '
          'name, and nobody else\'s does', (tester) async {
        final since = DateTime.now()
            .subtract(const Duration(days: 3, hours: 2))
            .millisecondsSinceEpoch;
        final server = _server();
        server.friends
          ..clear()
          ..add(
            friendJson(
              'u4',
              'Vikramaditya',
              status: 'PLAYING',
              game: 'TEEN_PATTI',
              variant: 'SEEN',
              since: since,
            ),
          );
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, room());
          await _tapPod(tester, 'u4');
          expect(_key('seat-friends-for'), findsOneWidget);
          expect(_inDrawer(find.text('Friends for 3 days')), findsOneWidget);
          await _closeDrawer(tester);
          for (final other in ['u1', 'u2', 'u3']) {
            await _tapPod(tester, other);
            expect(_key('seat-friends-for'), findsNothing, reason: other);
            await _closeDrawer(tester);
          }
          await _unmount(tester, state);
        }, () => server.client);
      });
    }

    for (final brightness in Brightness.values) {
      for (final lang in AppLang.values) {
        testWidgets('its longest lines fit the drawer at 640x360 x1.25 in '
            '${lang.name} (${brightness.name})', (tester) async {
          for (final age in const [Duration.zero, Duration(days: 300)]) {
            final server = _server();
            server.friends
              ..clear()
              ..add(
                friendJson(
                  'u4',
                  'Vikramaditya',
                  since: DateTime.now().subtract(age).millisecondsSinceEpoch,
                ),
              );
            await http.runWithClient(() async {
              final state = _state(lang: lang);
              await _mount(
                tester,
                state,
                felts.values.first(),
                brightness: brightness,
              );
              await _tapPod(tester, 'u4');
              expect(_key('seat-friends-for'), findsOneWidget);
              _expectDrawerFits(tester, '${lang.name} $age');
              await _unmount(tester, state);
            }, () => server.client);
          }
        });
      }
    }
  });
}
