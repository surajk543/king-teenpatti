// Report Player (owner, 27 Sep 2026: "A player sitting at a gameplay table
// must be able to report another player currently at the same table … Add
// 'Report Player' to the existing player interaction menu. Do not place a
// large report button directly on the gameplay table").
//
// Pressed for real on both felts: a tap on another player's pod opens the
// player drawer, whose quiet Report player line turns the drawer — never a
// route — to the report page: nine reasons, a description (required for
// OTHER, never past the server's 500), Submit and Cancel. Submitting sends
// the three things the client may say and nothing else, shows it is sending,
// cannot be pressed twice, and ends on the brief's thank-you; every refusal
// the server can give is said in the page in the player's language. The page
// fits a 640x360 phone at text x1.25 in all five languages, by day and by
// night, and rides above the keyboard.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/models/report.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/player_reports.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/hammer_flight.dart' show PodImpact;
import 'package:teenpatti/widgets/player_drawer.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/report_player.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

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

int get _now => DateTime.now().millisecondsSinceEpoch;

Map<String, dynamic> _seat(int i, {bool poker = false}) => {
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

RoomState _teenPatti() => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'isPrivate': false,
  'category': 'seen',
  'state': 'betting',
  'handNo': 7,
  'dealerSeat': 3,
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'pot': 6800,
  'maxPot': 2000000,
  'stake': 400,
  'turn': {'seatIndex': 2, 'userId': 'u2', 'deadline': _now + 20000},
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
  'seats': [for (var i = 0; i < 5; i++) _seat(i)],
});

RoomState _poker() => RoomState.fromJson({
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
  'seats': [for (var i = 0; i < 5; i++) _seat(i, poker: true)],
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

/// The fake server: Friends' contract (the drawer reads a profile) and the
/// report route, which answers [answer] — 201 by default — once [hold] (when
/// set) completes, and keeps every report it was sent.
class _Server {
  _Server() {
    friends.profiles['u1'] = {
      ...cardJson('u1', 'Ravi'),
      'friendStatus': 'NONE',
      'stats': statsJson(
        played: 88,
        won: 30,
        lost: 50,
        left: 8,
        winRate: 34.09,
      ),
    };
    for (final id in ['u2', 'u3', 'u4']) {
      friends.profiles[id] = {
        ...cardJson(id, _names[id]!),
        'friendStatus': 'NONE',
        'stats': statsJson(
          played: 12,
          won: 4,
          lost: 7,
          left: 1,
          winRate: 33.33,
        ),
      };
    }
  }

  final friends = FakeFriendsServer();
  final reports = <Map<String, dynamic>>[];
  Completer<void>? hold;
  http.Response Function()? answer;
  bool unreachable = false;

  /// What `GET /api/reports/limit` answers (`{limit: …}`); null → 404, a
  /// server from before the limit was said.
  Map<String, dynamic>? limit;

  /// The limit a filed report's answer carries; null → none.
  Map<String, dynamic>? filedLimit;

  /// How many times the limit was read.
  int limitReads = 0;

  MockClient get client => MockClient((r) async {
    if (r.url.path == '/api/reports/limit') {
      limitReads++;
      final l = limit;
      if (r.method != 'GET' || l == null) return refusal('not_found', 404);
      return http.Response(
        jsonEncode({'limit': l}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (r.url.path == '/api/reports') {
      if (r.method != 'POST') return refusal('not_found', 404);
      reports.add(Map<String, dynamic>.from(jsonDecode(r.body) as Map));
      if (hold != null) await hold!.future;
      if (unreachable) throw http.ClientException('offline');
      final a = answer;
      if (a != null) return a();
      return http.Response(
        jsonEncode({
          'success': true,
          'message': 'Report submitted successfully.',
          'limit': ?filedLimit,
        }),
        201,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    // A request is sent once: the Friends fake is handed a copy.
    final copy = http.Request(r.method, r.url)
      ..headers.addAll(r.headers)
      ..bodyBytes = r.bodyBytes;
    return http.Response.fromStream(await friends.client.send(copy));
  });
}

GameState _state({AppLang lang = AppLang.english}) {
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

void _setView(
  WidgetTester tester, {
  Size size = const Size(640, 360),
  double scale = 1.25,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

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

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _key(String key) => find.byKey(ValueKey(key));

Finder _inDrawer(Finder matching) =>
    find.descendant(of: find.byType(PlayerDrawer), matching: matching);

Finder _plaqueOf(String userId) => find.descendant(
  of: find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId),
  matching: find.byType(PodImpact),
);

/// Opens the drawer on [userId]'s pod and turns it to the report page.
Future<void> _openReport(WidgetTester tester, {String userId = 'u1'}) async {
  await tester.tap(_plaqueOf(userId));
  await _settle(tester);
  await tester.ensureVisible(_inDrawer(_key('seat-report')));
  await tester.pump();
  await tester.tap(_inDrawer(_key('seat-report')));
  await _settle(tester);
}

Future<void> _choose(WidgetTester tester, ReportReason r) async {
  final chip = _inDrawer(_key('report-reason:${r.wire}'));
  await tester.ensureVisible(chip);
  await tester.pump();
  await tester.tap(chip);
  await tester.pump();
}

Future<void> _submit(WidgetTester tester) async {
  final key = _inDrawer(_key('report-submit'));
  await tester.ensureVisible(key);
  await tester.pump();
  await tester.tap(key, warnIfMissed: false);
  await tester.pump();
}

/// Whether the drawer key under [key] can be pressed.
bool _live(WidgetTester tester, String key) =>
    tester.widget<DrawerKey>(_inDrawer(_key(key))).onPressed != null;

Rect _onScreen(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

/// Every line in the drawer whole and inside it.
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

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadScriptFonts();
  });

  const t = Strings(AppLang.english);

  group('the drawer', () {
    for (final MapEntry(key: felt, value: room) in {
      'Teen Patti': _teenPatti,
      'poker': _poker,
    }.entries) {
      testWidgets(
        'on the $felt felt offers Report player as a quiet line, and it '
        'turns the drawer to the report page — no route over the table',
        (tester) async {
          final server = _Server();
          await http.runWithClient(() async {
            final state = _state();
            await _mount(tester, state, room());
            final routesBefore = find.byType(ModalBarrier).evaluate().length;
            await tester.tap(_plaqueOf('u1'));
            await _settle(tester);
            final row = _inDrawer(_key('seat-report'));
            expect(row, findsOneWidget);
            expect(_inDrawer(find.text(t.reportPlayer)), findsOneWidget);
            // Quiet: a line, not a key — no gold, no fill, a touch target high.
            expect(
              find.descendant(of: row, matching: find.byType(DrawerKey)),
              findsNothing,
            );
            expect(tester.getSize(row).height, lessThan(64));
            expect(tester.getSize(row).height, greaterThanOrEqualTo(44));
            // And nowhere on the felt itself.
            expect(find.text(t.reportPlayer), findsOneWidget);

            await tester.tap(row);
            await _settle(tester);
            expect(_inDrawer(_key('report-reasons')), findsOneWidget);
            for (final r in ReportReason.values) {
              expect(
                _inDrawer(_key('report-reason:${r.wire}')),
                findsOneWidget,
              );
            }
            // Who is being reported stays in the head.
            expect(_inDrawer(_key('seat-player-name')), findsOneWidget);
            expect(_inDrawer(find.text('Ravi')), findsOneWidget);
            // Nothing chosen: nothing to send.
            expect(_live(tester, 'report-submit'), isFalse);
            expect(_live(tester, 'report-cancel'), isTrue);
            expect(
              find.byType(ModalBarrier).evaluate().length,
              routesBefore,
              reason: 'the page is the drawer, not a route',
            );

            // Cancel turns it back to the player's card.
            await tester.ensureVisible(_inDrawer(_key('report-cancel')));
            await tester.pump();
            await tester.tap(_inDrawer(_key('report-cancel')));
            await _settle(tester);
            expect(_inDrawer(_key('report-reasons')), findsNothing);
            expect(_inDrawer(_key('seat-report')), findsOneWidget);
            expect(server.reports, isEmpty);
            await _unmount(tester, state);
          }, () => server.client);
        },
      );
    }

    testWidgets('the viewer\'s own pod offers no report', (tester) async {
      final server = _Server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await tester.tap(_plaqueOf('u0'));
        await _settle(tester);
        expect(find.text(t.reportPlayer), findsNothing);
        await _unmount(tester, state);
      }, () => server.client);
    });
  });

  group('sending a report', () {
    testWidgets(
      'sends who, why and what happened and nothing else, shows it is '
      'sending, cannot be pressed twice, and thanks the player',
      (tester) async {
        final server = _Server()..hold = Completer<void>();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, _teenPatti());
          await _openReport(tester);
          await _choose(tester, ReportReason.collusion);
          expect(_live(tester, 'report-submit'), isTrue);
          await tester.enterText(
            _inDrawer(_key('report-description')),
            '  Always calls with Meera  ',
          );
          await tester.pump();

          await _submit(tester);
          // Sending: the key is busy and dead, its words say so.
          expect(_inDrawer(find.text(t.reportSubmitting)), findsOneWidget);
          expect(
            find.descendant(
              of: _inDrawer(_key('report-submit')),
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
          );
          expect(state.reports.submitting, isTrue);
          expect(state.reports.canSubmit, isFalse);
          // A second press, and the state asked straight: still one report.
          await tester.tap(
            _inDrawer(_key('report-submit')),
            warnIfMissed: false,
          );
          await tester.pump();
          expect(await state.reports.submit(), isFalse);
          expect(server.reports, hasLength(1));
          expect(_live(tester, 'report-cancel'), isFalse);

          server.hold!.complete();
          await _settle(tester);
          expect(server.reports.single, {
            'reportedUserId': 'u1',
            'reason': 'COLLUSION',
            'description': 'Always calls with Meera',
          });
          // The brief's thank-you, word for word.
          expect(_inDrawer(_key('report-sent-mark')), findsOneWidget);
          expect(_inDrawer(find.text('Report submitted')), findsOneWidget);
          expect(
            _inDrawer(find.text('Thank you for helping keep the game fair.')),
            findsOneWidget,
          );
          expect(
            _inDrawer(find.text('Our team will review the report.')),
            findsOneWidget,
          );
          _expectDrawerFits(tester, 'the thank-you');

          await tester.ensureVisible(_inDrawer(_key('report-done')));
          await tester.pump();
          await tester.tap(_inDrawer(_key('report-done')));
          await _settle(tester);
          // Back on the card, the player reads as reported: no second report.
          expect(_inDrawer(_key('seat-reported')), findsOneWidget);
          expect(_inDrawer(_key('seat-report')), findsNothing);
          expect(_inDrawer(find.text(t.reportedTag)), findsOneWidget);
          await _unmount(tester, state);
        }, () => server.client);
      },
    );

    testWidgets('a reason with no words sends no description key at all', (
      tester,
    ) async {
      final server = _Server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await _openReport(tester);
        await _choose(tester, ReportReason.spam);
        await _submit(tester);
        await _settle(tester);
        expect(server.reports.single, {
          'reportedUserId': 'u1',
          'reason': 'SPAM',
        });
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets(
      'OTHER needs a description; the field stops at the server\'s 500 '
      'characters, counted as the server counts them',
      (tester) async {
        final server = _Server();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, _teenPatti());
          await _openReport(tester);
          await _choose(tester, ReportReason.other);
          TextField field() =>
              tester.widget<TextField>(_inDrawer(_key('report-description')));
          expect(field().decoration!.hintText, t.reportDetailsRequiredHint);
          expect(
            _inDrawer(find.text(t.reportDetailsRequiredHint)),
            findsOneWidget,
          );
          expect(_live(tester, 'report-submit'), isFalse);
          await tester.enterText(_inDrawer(_key('report-description')), '    ');
          await tester.pump();
          expect(
            _live(tester, 'report-submit'),
            isFalse,
            reason: 'blanks are no description',
          );
          await tester.enterText(
            _inDrawer(_key('report-description')),
            'He shouted at everyone',
          );
          await tester.pump();
          expect(_live(tester, 'report-submit'), isTrue);
          // Back to a reason that needs none: the field says it is optional.
          await _choose(tester, ReportReason.cheating);
          expect(field().decoration!.hintText, t.reportDetailsHint);
          expect(_live(tester, 'report-submit'), isTrue);

          await tester.enterText(
            _inDrawer(_key('report-description')),
            'x' * 600,
          );
          await tester.pump();
          expect(field().controller!.text.length, reportDescriptionMax);
          expect(_inDrawer(find.text('500 / 500')), findsOneWidget);
          // An emoji of two code points (a thumb and its skin tone) counts
          // two, as the server counts it.
          await tester.enterText(
            _inDrawer(_key('report-description')),
            '\u{1F44D}\u{1F3FD}' * 260,
          );
          await tester.pump();
          expect(field().controller!.text.runes.length, reportDescriptionMax);
          expect(server.reports, isEmpty);
          await _unmount(tester, state);
        }, () => server.client);
      },
    );

    testWidgets(
      'a refusal is said in the page and the report can be sent again',
      (tester) async {
        final server = _Server()
          ..answer = () => refusal('player_not_at_table', 409);
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, _teenPatti());
          await _openReport(tester);
          await _choose(tester, ReportReason.harassment);
          await _submit(tester);
          await _settle(tester);
          expect(_inDrawer(_key('report-error')), findsOneWidget);
          expect(_inDrawer(find.text(t.reportNotAtTable)), findsOneWidget);
          expect(_inDrawer(_key('report-sent')), findsNothing);
          expect(_live(tester, 'report-submit'), isTrue);
          _expectDrawerFits(tester, 'a refusal');

          server.answer = null;
          await _submit(tester);
          await _settle(tester);
          expect(_inDrawer(_key('report-sent')), findsOneWidget);
          expect(server.reports, hasLength(2));
          await _unmount(tester, state);
        }, () => server.client);
      },
    );

    testWidgets(
      'the drawer shutting drops the page; reopening shows the card',
      (tester) async {
        final server = _Server();
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, _teenPatti());
          await _openReport(tester);
          await _choose(tester, ReportReason.spam);
          await tester.tap(_inDrawer(_key('seat-close')));
          await _settle(tester);
          expect(find.byType(PlayerDrawer), findsNothing);
          expect(state.reports.target, isNull);
          await tester.tap(_plaqueOf('u1'));
          await _settle(tester);
          expect(_inDrawer(_key('report-reasons')), findsNothing);
          expect(_inDrawer(_key('seat-report')), findsOneWidget);
          await _unmount(tester, state);
        }, () => server.client);
      },
    );

    testWidgets('the page rides above the keyboard: the head stands aside and '
        'the field stays in view', (tester) async {
      final server = _Server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await _openReport(tester);
        await _choose(tester, ReportReason.other);
        await tester.showKeyboard(_inDrawer(_key('report-description')));
        tester.view.viewInsets = const FakeViewPadding(bottom: 190);
        addTearDown(tester.view.resetViewInsets);
        await _settle(tester);
        expect(_inDrawer(_key('seat-player-name')), findsNothing);
        await tester.ensureVisible(_inDrawer(_key('report-description')));
        await tester.pump();
        final field = tester.getRect(_inDrawer(_key('report-description')));
        expect(field.bottom, lessThanOrEqualTo(360 - 190 + 0.5));
        expect(field.top, greaterThanOrEqualTo(-0.5));
        expect(tester.takeException(), isNull);
        await _unmount(tester, state);
      }, () => server.client);
    });
  });

  group('every refusal, in words', () {
    final cases = <String, String Function(Strings)>{
      'already_reported': (t) => t.reportAlready,
      'report_limit_reached': (t) => t.reportLimited,
      'rate_limited': (t) => t.reportLimited,
      'player_not_at_table': (t) => t.reportNotAtTable,
      'player_not_found': (t) => t.reportInvalidPlayer,
      'invalid_player_id': (t) => t.reportInvalidPlayer,
      'self_report': (t) => t.reportInvalidPlayer,
      'description_required': (t) => t.reportDescriptionRequired,
      'description_too_long': (t) => t.reportDescriptionTooLong,
      'internal_error': (t) => t.reportServerError,
      'invalid_session': (t) => t.reportServerError,
      reportNoAnswer: (t) => t.reportNetworkError,
      'something_new': (t) => t.reportServerError,
    };
    for (final lang in AppLang.values) {
      test('in ${lang.name}', () {
        final t = Strings(lang);
        for (final MapEntry(key: code, value: want) in cases.entries) {
          expect(reportRefusalText(t, code), want(t), reason: code);
        }
      });
    }

    const statuses = {
      'already_reported': 409,
      'report_limit_reached': 429,
      'rate_limited': 429,
      'player_not_at_table': 409,
      'player_not_found': 404,
      'internal_error': 500,
      'invalid_session': 401,
    };
    for (final MapEntry(key: code, value: status) in statuses.entries) {
      test('$status $code reaches the page as its code', () async {
        final server = _Server()..answer = () => refusal(code, status);
        await http.runWithClient(() async {
          final reports =
              PlayerReports(api: ApiClient(friendsServer), token: () => 'tok')
                ..open('u1')
                ..choose(ReportReason.spam);
          expect(await reports.submit(), isFalse);
          expect(reports.error, code);
          expect(reports.submitting, isFalse);
          expect(reports.sent, isFalse);
          // Already reported: the drawer offers them no second report.
          expect(reports.wasReported('u1'), code == 'already_reported');
          reports.dispose();
        }, () => server.client);
      });
    }

    test(
      'no connection is no_answer, and nothing is marked reported',
      () async {
        final server = _Server()..unreachable = true;
        await http.runWithClient(() async {
          final reports =
              PlayerReports(api: ApiClient(friendsServer), token: () => 'tok')
                ..open('u1')
                ..choose(ReportReason.cheating);
          expect(await reports.submit(), isFalse);
          expect(reports.error, reportNoAnswer);
          expect(reports.wasReported('u1'), isFalse);
          reports.dispose();
        }, () => server.client);
      },
    );

    test(
      'a signed-out phone sends nothing; sign-out forgets who was reported',
      () async {
        final server = _Server();
        await http.runWithClient(() async {
          String? token;
          final reports =
              PlayerReports(api: ApiClient(friendsServer), token: () => token)
                ..open('u1')
                ..choose(ReportReason.cheating);
          expect(await reports.submit(), isFalse);
          expect(reports.error, reportNoAnswer);
          expect(server.reports, isEmpty);
          token = 'tok';
          expect(await reports.submit(), isTrue);
          expect(reports.wasReported('u1'), isTrue);
          reports.reset();
          expect(reports.wasReported('u1'), isFalse);
          expect(reports.target, isNull);
          reports.dispose();
        }, () => server.client);
      },
    );

    test(
      'an answer for a page that has been closed changes nothing on it',
      () async {
        final server = _Server()..hold = Completer<void>();
        await http.runWithClient(() async {
          final reports =
              PlayerReports(api: ApiClient(friendsServer), token: () => 'tok')
                ..open('u1')
                ..choose(ReportReason.cheating);
          final sending = reports.submit();
          reports.open('u2');
          server.hold!.complete();
          await sending;
          expect(reports.target, 'u2');
          expect(reports.sent, isFalse);
          expect(reports.error, isNull);
          expect(reports.wasReported('u1'), isTrue);
          reports.dispose();
        }, () => server.client);
      },
    );
  });

  group('the report limit', () {
    Map<String, dynamic> spent(Duration wait) => {
      'max': 2,
      'used': 2,
      'remaining': 0,
      'windowMs': 86400000,
      'availableAt': _now + wait.inMilliseconds,
      'waitMs': wait.inMilliseconds,
    };
    const oneLeft = {
      'max': 2,
      'used': 1,
      'remaining': 1,
      'windowMs': 86400000,
      'availableAt': 0,
      'waitMs': 0,
    };

    test('is read off the wire, anchored to when the answer came', () {
      final at = DateTime(2026, 9, 27, 19, 44);
      final l = ReportLimit.fromJson(
        spent(const Duration(hours: 23, minutes: 41)),
        receivedAt: at,
      )!;
      expect((l.max, l.used, l.remaining), (2, 2, 0));
      expect(l.availableAt, at.add(const Duration(hours: 23, minutes: 41)));
      expect(l.limitedAt(at), isTrue);
      expect(l.waitAt(at), const Duration(hours: 23, minutes: 41));
      expect(l.limitedAt(at.add(const Duration(hours: 24))), isFalse);
      final open = ReportLimit.fromJson(oneLeft, receivedAt: at)!;
      expect(open.availableAt, isNull);
      expect(open.limitedAt(at), isFalse);
      expect(ReportLimit.fromJson('nonsense', receivedAt: at), isNull);
      expect(ReportLimit.fromJson(null, receivedAt: at), isNull);
    });

    test('the countdown rounds up and says nothing once it is over', () {
      final at = DateTime(2026, 9, 27, 19, 44);
      String? line(Duration left) => ReportCooldown.lineAt(t, at.add(left), at);
      expect(
        line(
          const Duration(hours: 23, minutes: 41, seconds: 4, milliseconds: 1),
        ),
        'You can report again in 23h 41m 5s',
      );
      expect(line(const Duration(minutes: 3)), 'You can report again in 3m 0s');
      expect(
        line(const Duration(milliseconds: 200)),
        'You can report again in 1s',
      );
      expect(line(Duration.zero), isNull);
      expect(line(const Duration(seconds: -5)), isNull);
      const hi = Strings(AppLang.hindi);
      expect(
        ReportCooldown.lineAt(hi, at.add(const Duration(hours: 2)), at),
        hi.reportAgainIn(formatCountdown(const Duration(hours: 2), hi)),
      );
    });

    testWidgets(
      'both reports used: the Report line is off, says so, counts down '
      'every second, and comes back the moment the wait is over',
      (tester) async {
        final server = _Server()
          ..limit = spent(const Duration(hours: 23, minutes: 41, seconds: 5));
        await http.runWithClient(() async {
          final state = _state();
          var offset = Duration.zero;
          state.reports.clock = () => DateTime.now().add(offset);
          await _mount(tester, state, _teenPatti());
          await tester.tap(_plaqueOf('u1'));
          await _settle(tester);
          expect(server.limitReads, 1, reason: 'read as the drawer opens');
          expect(state.reports.limited, isTrue);

          final row = _inDrawer(_key('seat-report-limited'));
          expect(row, findsOneWidget);
          expect(_inDrawer(_key('seat-report')), findsNothing);
          expect(
            _inDrawer(find.text('Report limit reached · 2 of 2 reports used')),
            findsOneWidget,
          );
          Text cooldown() => tester.widget<Text>(
            find.descendant(
              of: _inDrawer(_key('seat-report-cooldown')),
              matching: find.byType(Text),
            ),
          );
          final first = cooldown().data!;
          expect(
            first,
            matches(RegExp(r'^You can report again in 23h 41m [45]s$')),
          );
          // Dead: a tap opens no report page.
          await tester.tap(row, warnIfMissed: false);
          await _settle(tester);
          expect(_inDrawer(_key('report-reasons')), findsNothing);
          expect(state.reports.target, isNull);
          _expectDrawerFits(tester, 'the limited line');

          // A minute on: the line has counted down by itself.
          offset += const Duration(minutes: 1);
          await tester.pump(const Duration(seconds: 1));
          expect(
            cooldown().data,
            matches(RegExp(r'^You can report again in 23h 40m [45]s$')),
          );

          // Another player's drawer, a minute on (past limitFresh): the limit
          // is read again, and the line is off there too.
          state.tableScaffold.currentState!.closeEndDrawer();
          await _settle(tester);
          await tester.tap(_plaqueOf('u2'));
          await _settle(tester);
          expect(server.limitReads, 2);
          expect(_inDrawer(_key('seat-report-limited')), findsOneWidget);

          // The wait runs out: the line is back, and the server is asked.
          server.limit = oneLeft;
          offset += const Duration(hours: 23, minutes: 41);
          await tester.pump(const Duration(hours: 23, minutes: 41));
          await _settle(tester);
          expect(state.reports.limited, isFalse);
          expect(server.limitReads, 3, reason: 'read again as it opened');
          expect(_inDrawer(_key('seat-report-limited')), findsNothing);
          expect(_inDrawer(_key('seat-report')), findsOneWidget);
          await tester.tap(_inDrawer(_key('seat-report')));
          await _settle(tester);
          expect(_inDrawer(_key('report-reasons')), findsOneWidget);
          await _unmount(tester, state);
        }, () => server.client);
      },
    );

    testWidgets(
      'the report that uses the last one says when the next opens, and the '
      'next player\'s line is off',
      (tester) async {
        final server = _Server()
          ..limit = oneLeft
          ..filedLimit = spent(const Duration(hours: 24));
        await http.runWithClient(() async {
          final state = _state();
          await _mount(tester, state, _teenPatti());
          await _openReport(tester);
          expect(state.reports.limited, isFalse);
          await _choose(tester, ReportReason.cheating);
          await _submit(tester);
          await _settle(tester);
          expect(_inDrawer(find.text(t.reportSubmitted)), findsOneWidget);
          final line = tester.widget<Text>(
            find.descendant(
              of: _inDrawer(_key('report-sent-cooldown')),
              matching: find.byType(Text),
            ),
          );
          expect(
            line.data,
            matches(
              RegExp(r'^You can report again in (24h 0m 0s|23h 59m 59s)$'),
            ),
          );
          _expectDrawerFits(tester, 'the last report\'s thank-you');
          await tester.ensureVisible(_inDrawer(_key('report-done')));
          await tester.pump();
          await tester.tap(_inDrawer(_key('report-done')));
          await _settle(tester);
          // The player just reported reads Reported; the next one is off.
          expect(_inDrawer(_key('seat-reported')), findsOneWidget);
          server.limit = spent(const Duration(hours: 24));
          state.tableScaffold.currentState!.closeEndDrawer();
          await _settle(tester);
          await tester.tap(_plaqueOf('u3'));
          await _settle(tester);
          expect(_inDrawer(_key('seat-report-limited')), findsOneWidget);
          expect(_inDrawer(_key('seat-report-cooldown')), findsOneWidget);
          await _unmount(tester, state);
        }, () => server.client);
      },
    );

    testWidgets(
      'a limit reached elsewhere is said on the page with the countdown, '
      'and Submit stays off until it opens',
      (tester) async {
        final server = _Server()
          ..answer = () => http.Response(
            jsonEncode({
              'error': 'report_limit_reached',
              'message': 'You have reached the report limit. Try again later.',
              'limit': spent(const Duration(minutes: 5)),
            }),
            429,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        await http.runWithClient(() async {
          final state = _state();
          var offset = Duration.zero;
          state.reports.clock = () => DateTime.now().add(offset);
          await _mount(tester, state, _teenPatti());
          await _openReport(tester);
          await _choose(tester, ReportReason.spam);
          await _submit(tester);
          await _settle(tester);
          expect(state.reports.limited, isTrue);
          expect(_inDrawer(_key('report-cooldown')), findsOneWidget);
          expect(_inDrawer(find.text(t.reportLimitTitle)), findsOneWidget);
          expect(
            _inDrawer(find.textContaining('You can report again in 5m')),
            findsOneWidget,
          );
          expect(_live(tester, 'report-submit'), isFalse);
          expect(server.reports, hasLength(1));
          _expectDrawerFits(tester, 'the limit on the page');

          // Five minutes on, the note goes and Submit is back.
          server.answer = null;
          offset += const Duration(minutes: 5, seconds: 1);
          await tester.pump(const Duration(minutes: 5, seconds: 1));
          await _settle(tester);
          expect(state.reports.limited, isFalse);
          expect(_inDrawer(_key('report-cooldown')), findsNothing);
          expect(_inDrawer(_key('report-error')), findsNothing);
          expect(_live(tester, 'report-submit'), isTrue);
          await _unmount(tester, state);
        }, () => server.client);
      },
    );

    testWidgets('a server that does not say leaves the line as it was', (
      tester,
    ) async {
      final server = _Server();
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await tester.tap(_plaqueOf('u1'));
        await _settle(tester);
        expect(server.limitReads, 1);
        expect(state.reports.limit, isNull);
        expect(_inDrawer(_key('seat-report')), findsOneWidget);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('signing out forgets the limit', (tester) async {
      final server = _Server()..limit = spent(const Duration(hours: 3));
      await http.runWithClient(() async {
        final state = _state();
        await _mount(tester, state, _teenPatti());
        await tester.tap(_plaqueOf('u1'));
        await _settle(tester);
        expect(state.reports.limited, isTrue);
        state.reports.reset();
        expect(state.reports.limited, isFalse);
        expect(state.reports.limit, isNull);
        await _unmount(tester, state);
      }, () => server.client);
    });

    for (final brightness in Brightness.values) {
      for (final lang in AppLang.values) {
        testWidgets('the limited line and the page fit 640x360 at x1.25 in '
            '${lang.name} (${brightness.name})', (tester) async {
          final server = _Server()
            ..limit = spent(const Duration(hours: 23, minutes: 41, seconds: 5));
          final t = Strings(lang);
          await http.runWithClient(() async {
            final state = _state(lang: lang);
            await _mount(tester, state, _teenPatti(), brightness: brightness);
            await tester.tap(_plaqueOf('u4'));
            await _settle(tester);
            expect(_inDrawer(_key('seat-report-limited')), findsOneWidget);
            expect(t.ownEntry('reportLimitTitle'), isNotNull);
            expect(t.ownEntry('reportLimitUsed'), isNotNull);
            expect(t.ownEntry('reportAgainIn'), isNotNull);
            expect(
              _inDrawer(
                find.text('${t.reportLimitTitle} · ${t.reportLimitUsed(2, 2)}'),
              ),
              findsOneWidget,
            );
            _expectDrawerFits(tester, '${lang.name}: the limited line');
            await _unmount(tester, state);
          }, () => server.client);
        });
      }
    }
  });

  group('the page fits a 640x360 phone at text x1.25', () {
    for (final brightness in Brightness.values) {
      for (final lang in AppLang.values) {
        testWidgets('in ${lang.name} (${brightness.name})', (tester) async {
          final server = _Server()
            ..answer = () => refusal('report_limit_reached', 429);
          final t = Strings(lang);
          await http.runWithClient(() async {
            final state = _state(lang: lang);
            await _mount(tester, state, _teenPatti(), brightness: brightness);
            await tester.tap(_plaqueOf('u1'));
            await _settle(tester);
            _expectDrawerFits(
              tester,
              '${lang.name}: the card with its report line',
            );
            expect(t.ownEntry('reportPlayer'), isNotNull, reason: 'translated');
            await tester.ensureVisible(_inDrawer(_key('seat-report')));
            await tester.pump();
            await tester.tap(_inDrawer(_key('seat-report')));
            await _settle(tester);
            await _choose(tester, ReportReason.other);
            _expectDrawerFits(
              tester,
              '${lang.name}: the reasons and the field',
            );
            // Every reason is whole, and none overlaps another.
            final rects = [
              for (final r in ReportReason.values)
                tester.getRect(_inDrawer(_key('report-reason:${r.wire}'))),
            ];
            for (var i = 0; i < rects.length; i++) {
              for (var j = i + 1; j < rects.length; j++) {
                expect(
                  rects[i].overlaps(rects[j]),
                  isFalse,
                  reason: '${lang.name}: reasons $i and $j overlap',
                );
              }
            }
            await tester.enterText(
              _inDrawer(_key('report-description')),
              'Kept calling us names',
            );
            await tester.pump();
            await _submit(tester);
            await _settle(tester);
            expect(_inDrawer(find.text(t.reportLimited)), findsOneWidget);
            _expectDrawerFits(tester, '${lang.name}: a refusal');

            server.answer = null;
            await _submit(tester);
            await _settle(tester);
            expect(_inDrawer(find.text(t.reportSubmitted)), findsOneWidget);
            expect(_inDrawer(find.text(t.reportThanks)), findsOneWidget);
            expect(_inDrawer(find.text(t.reportReview)), findsOneWidget);
            _expectDrawerFits(tester, '${lang.name}: the thank-you');
            for (final key in [
              'reportWhy',
              'reportSubmit',
              'reportSubmitted',
              'reportThanks',
              'reportReview',
              'reportReasonCheating',
              'reportReasonOther',
              'reportLimited',
              'reportNotAtTable',
              'reportNetworkError',
              'reportServerError',
              'reportedTag',
            ]) {
              expect(
                t.ownEntry(key),
                isNotNull,
                reason: '$key in ${lang.name}',
              );
            }
            await _unmount(tester, state);
          }, () => server.client);
        });
      }
    }
  });
}
