// The Friends page's Reported tab (owner, 27 Sep 2026: "There is friends
// button in lobby, when user clicked it, then add one more tab, where user can
// see all the players he reported in detail status, description, time he
// reported but don't show the reported user id, by default it will sorted in
// latest reported user").
//
// The page's head is two tabs, Friends and Reported. Reported reads GET
// /api/reports/mine as it opens and lists every report newest first — the
// player's name and picture, the status in words and an icon, the reason and
// where the two met, the description whole, and when — and no user id of
// anybody, even one a server wrongly sent. Empty, failing and older-server
// states say so; the tab fits a 640x360 phone at text x1.25 in all five
// languages, by day and by night, and a 592dp one.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/report.dart';
import 'package:teenpatti/screens/friends_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'friends_fixture.dart';
import 'script_fonts.dart';

int _at(int day, int hour, int minute) =>
    DateTime(2026, 9, day, hour, minute).millisecondsSinceEpoch;

Map<String, dynamic> _report({
  String name = 'Ravi',
  bool gone = false,
  String reason = 'CHEATING',
  String description = '',
  String category = 'seen',
  String variant = '',
  String status = 'PENDING',
  required int createdAt,
  Map<String, dynamic> extra = const {},
}) => {
  'player': {
    'displayName': gone ? '' : name,
    'profilePicture': {'id': null, 'url': null},
    'gone': gone,
  },
  'reason': reason,
  'description': description,
  'game': 'teen_patti',
  'category': category,
  'variant': variant,
  'status': status,
  'createdAt': createdAt,
  'updatedAt': createdAt,
  ...extra,
};

/// The Friends fake, with the report list in front of it: [mine] is what
/// `GET /api/reports/mine` answers (null → 404, a server from before it),
/// [fail] a 500, and [reads] how often it was asked.
class _Server {
  _Server({this.mine});

  final friends = populatedServer();
  List<Map<String, dynamic>>? mine;
  bool fail = false;
  int reads = 0;

  MockClient get client => MockClient((r) async {
    if (r.url.path == '/api/reports/mine') {
      reads++;
      if (fail) {
        return http.Response(
          jsonEncode({'error': 'internal_error', 'message': 'x'}),
          500,
        );
      }
      final list = mine;
      if (list == null) {
        return http.Response(
          jsonEncode({'error': 'not_found', 'message': 'x'}),
          404,
        );
      }
      return http.Response(
        jsonEncode({'reports': list}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    final copy = http.Request(r.method, r.url)
      ..headers.addAll(r.headers)
      ..bodyBytes = r.bodyBytes;
    return http.Response.fromStream(await friends.client.send(copy));
  });
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

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _openPage(
  WidgetTester tester,
  GameState state, {
  Brightness brightness = Brightness.dark,
}) async {
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withScriptFallback(AppTheme.light(sound: false)),
        darkTheme: withScriptFallback(AppTheme.dark(sound: false)),
        themeMode: brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        builder: (context, child) => GlassBudget(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showFriends(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
}

Future<void> _openReported(WidgetTester tester) async {
  await tester.tap(_key('friends-tab-reported'));
  await _settle(tester);
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

Finder _key(String key) => find.byKey(ValueKey(key));

Finder _inPage(Finder matching) =>
    find.descendant(of: find.byType(FriendsScreen), matching: matching);

String _textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(_key(key)).data ?? '';

Rect _onScreen(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

/// Every line on the page whole and inside the screen.
void _expectFits(WidgetTester tester, String where) {
  expect(tester.takeException(), isNull, reason: where);
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  for (final e in _inPage(find.byType(RichText)).evaluate()) {
    final paragraph = e.renderObject! as RenderParagraph;
    if (!paragraph.attached || !paragraph.hasSize) continue;
    final line = paragraph.text.toPlainText();
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: '$where: "$line" cut short',
    );
    final rect = _onScreen(paragraph);
    expect(rect.left, greaterThanOrEqualTo(-0.5), reason: '$where: "$line"');
    expect(rect.right, lessThanOrEqualTo(width + 0.5), reason: '$where: $line');
  }
}

/// Four reports, sent OUT of order, one about an account deleted since, one
/// carrying ids a server must never send.
List<Map<String, dynamic>> _four() => [
  _report(
    name: 'Meera',
    reason: 'SPAM',
    status: 'DISMISSED',
    createdAt: _at(20, 9, 5),
  ),
  _report(
    name: 'Ravi',
    reason: 'CHEATING',
    status: 'PENDING',
    createdAt: _at(27, 19, 44),
    extra: {
      'userId': 'u-ravi-secret',
      'reportedUserId': 'u-ravi-secret',
      'tableId': 'room-secret',
      'handId': 'hand-secret',
    },
  ),
  _report(
    gone: true,
    reason: 'COLLUSION',
    status: 'ACTION_TAKEN',
    createdAt: _at(22, 14, 0),
  ),
  _report(
    name: 'Arjun',
    reason: 'OTHER',
    description:
        'Kept calling us names in the chat and would not stop even after '
        'everybody asked him to.',
    category: 'variation',
    variant: 'AK47',
    status: 'UNDER_REVIEW',
    createdAt: _at(25, 8, 30),
  ),
];

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadScriptFonts();
  });

  const t = Strings(AppLang.english);

  group('the wire', () {
    test('a report is read without anybody\'s id, and listed newest first', () {
      final list = [for (final j in _four()) FiledReport.fromJson(j)!];
      expect(FiledReport.fromJson('nonsense'), isNull);
      final sorted = FiledReport.newestFirst(list);
      expect(
        [for (final r in sorted) r.displayName],
        ['Ravi', 'Arjun', '', 'Meera'],
      );
      expect(sorted[2].gone, isTrue);
      expect(sorted[0].reasonKind, ReportReason.cheating);
      expect(
        FiledReport.fromJson({..._four()[0], 'reason': 'NEW'})!.reasonKind,
        isNull,
      );
      // Two filed in the same millisecond keep the order the server sent.
      final same = FiledReport.newestFirst([
        FiledReport.fromJson(_report(name: 'A', createdAt: 5))!,
        FiledReport.fromJson(_report(name: 'B', createdAt: 5))!,
      ]);
      expect([for (final r in same) r.displayName], ['A', 'B']);
    });
  });

  group('the tab', () {
    testWidgets(
      'the head is Friends and Reported; Reported lists every report newest '
      'first with its status, reason, description and time, and no id',
      (tester) async {
        _setView(tester, size: const Size(891, 411), scale: 1.0);
        final server = _Server(mine: _four());
        await http.runWithClient(() async {
          final state = signedInState();
          await _openPage(tester, state);
          // Friends first, with the Player ID; nothing read of the reports.
          expect(_key('friends-tab-friends'), findsOneWidget);
          expect(_key('friends-tab-reported'), findsOneWidget);
          expect(_key('friends-player-id'), findsOneWidget);
          expect(_key('friends-view-list'), findsOneWidget);
          expect(server.reads, 0);
          final friendsTab = tester.getRect(_key('friends-tab-friends'));
          final under = tester.getRect(_key('friends-tab-indicator'));
          expect(under.center.dx, closeTo(friendsTab.center.dx, 1));

          await _openReported(tester);
          expect(server.reads, 1);
          expect(_key('friends-view-reported'), findsOneWidget);
          // The Player ID heads the Friends tab alone.
          expect(_key('friends-player-id'), findsNothing);
          final reportedTab = tester.getRect(_key('friends-tab-reported'));
          expect(
            tester.getRect(_key('friends-tab-indicator')).center.dx,
            closeTo(reportedTab.center.dx, 1),
          );
          final semantics = tester.ensureSemantics();
          expect(
            tester.getSemantics(_key('friends-tab-reported')),
            isSemantics(isSelected: true, isButton: true),
          );
          semantics.dispose();
          expect(find.text(t.myReportsTitle.toUpperCase()), findsOneWidget);

          // Newest first, whatever order the server sent.
          expect(_textOf(tester, 'reported-0-name'), 'Ravi');
          expect(_textOf(tester, 'reported-1-name'), 'Arjun');
          expect(_textOf(tester, 'reported-2-name'), t.reportedPlayerGone);
          expect(_textOf(tester, 'reported-3-name'), 'Meera');
          final tops = [
            for (var i = 0; i < 3; i++) tester.getRect(_key('reported-$i')).top,
          ];
          expect(tops, orderedEquals([...tops]..sort()));

          // Ravi: the reason and the table's kind, the status, the time.
          expect(
            _textOf(tester, 'reported-0-reason'),
            '${t.reportReasonCheating} · Teen Patti • Seen',
          );
          expect(
            find.descendant(
              of: _key('reported-0-status'),
              matching: find.text(t.reportStatusPending),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: _key('reported-0-status'),
              matching: find.byIcon(Icons.hourglass_top_rounded),
            ),
            findsOneWidget,
          );
          expect(
            _textOf(tester, 'reported-0-when'),
            t.reportedOn('27/09/2026 · 7:44 PM'),
          );
          expect(_key('reported-0-description'), findsNothing);
          // The status stands at the row's right end, clear of the name.
          for (var i = 0; i < 2; i++) {
            expect(
              tester.getRect(_key('reported-$i-status')).right,
              closeTo(tester.getRect(_key('reported-$i')).right - Space.md, 1),
              reason: 'row $i',
            );
          }
          // Arjun: OTHER, what was written, whole; under review.
          expect(
            _textOf(tester, 'reported-1-description'),
            startsWith('Kept calling us names'),
          );
          expect(
            tester.widget<Text>(_key('reported-1-description')).maxLines,
            isNull,
          );
          expect(
            _textOf(tester, 'reported-1-reason'),
            '${t.reportReasonOther} · Teen Patti • Variation',
          );
          expect(
            find.descendant(
              of: _key('reported-1-status'),
              matching: find.text(t.reportStatusUnderReview),
            ),
            findsOneWidget,
          );
          // The deleted account and Meera's dismissed report.
          await tester.ensureVisible(_key('reported-3'));
          await tester.pump();
          expect(
            find.descendant(
              of: _key('reported-2-status'),
              matching: find.text(t.reportStatusActionTaken),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: _key('reported-3-status'),
              matching: find.text(t.reportStatusDismissed),
            ),
            findsOneWidget,
          );

          // No id anywhere, even the ones a server wrongly sent.
          for (final e in _inPage(find.byType(RichText)).evaluate()) {
            final line = (e.widget as RichText).text.toPlainText();
            expect(line, isNot(contains('secret')), reason: line);
            expect(line, isNot(contains('u-')), reason: line);
          }
          _expectFits(tester, 'reported');

          // Back to Friends: the Player ID and the lists again.
          await tester.tap(_key('friends-tab-friends'));
          await _settle(tester);
          expect(_key('friends-player-id'), findsOneWidget);
          expect(_key('friends-view-list'), findsOneWidget);
          // Opening Reported again reads the list again.
          await _openReported(tester);
          expect(server.reads, 2);
          await _unmount(tester, state);
        }, () => server.client);
      },
    );

    testWidgets('nobody reported: it says so', (tester) async {
      _setView(tester);
      final server = _Server(mine: const []);
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await _openReported(tester);
        expect(_key('reported-none'), findsOneWidget);
        expect(find.text(t.noReportsYet), findsOneWidget);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('a read that fails offers Retry, which reads again', (
      tester,
    ) async {
      _setView(tester);
      final server = _Server(mine: _four())..fail = true;
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await _openReported(tester);
        expect(_key('reported-failed'), findsOneWidget);
        expect(find.text(t.reportsLoadFailed), findsOneWidget);
        server.fail = false;
        await tester.tap(_key('friends-retry'));
        await _settle(tester);
        expect(_key('reported-failed'), findsNothing);
        expect(_textOf(tester, 'reported-0-name'), 'Ravi');
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('a server from before the list: an empty list, not an error', (
      tester,
    ) async {
      _setView(tester);
      final server = _Server();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await _openReported(tester);
        expect(_key('reported-none'), findsOneWidget);
        expect(_key('reported-failed'), findsNothing);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('signing out forgets the list', (tester) async {
      _setView(tester);
      final server = _Server(mine: _four());
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await _openReported(tester);
        expect(state.reports.mine, hasLength(4));
        state.reports.reset();
        expect(state.reports.mine, isNull);
        expect(state.reports.mineRead, isFalse);
        await _unmount(tester, state);
      }, () => server.client);
    });
  });

  group('fits', () {
    for (final (size, langs) in [
      (const Size(640, 360), AppLang.values),
      (const Size(592, 360), const [AppLang.english, AppLang.hindi]),
    ]) {
      for (final brightness in Brightness.values) {
        for (final lang in langs) {
          final where =
              '${size.width.toInt()}x${size.height.toInt()} x1.25 '
              '${lang.name} ${brightness.name}';
          testWidgets(where, (tester) async {
            _setView(tester, size: size);
            final server = _Server(mine: _four());
            final t = Strings(lang);
            await http.runWithClient(() async {
              final state = signedInState(lang: lang);
              await _openPage(tester, state, brightness: brightness);
              expect(t.ownEntry('reportedTab'), isNotNull);
              // The head: both tabs, Add Friend and Close, on screen and
              // apart, each tab's word whole.
              final heads = [
                tester.getRect(_key('friends-tab-friends')),
                tester.getRect(_key('friends-tab-reported')),
                tester.getRect(_key('friends-add')),
                tester.getRect(_key('friends-close')),
              ];
              for (var i = 0; i < heads.length; i++) {
                expect(heads[i].left, greaterThanOrEqualTo(0), reason: where);
                expect(
                  heads[i].right,
                  lessThanOrEqualTo(size.width),
                  reason: where,
                );
                expect(heads[i].height, greaterThanOrEqualTo(44));
                for (var j = i + 1; j < heads.length; j++) {
                  expect(
                    heads[i].overlaps(heads[j]),
                    isFalse,
                    reason: '$where: head keys $i and $j overlap',
                  );
                }
              }
              _expectFits(tester, '$where friends');
              await _openReported(tester);
              _expectFits(tester, '$where reported');
              for (var i = 0; i < 4; i++) {
                await tester.ensureVisible(_key('reported-$i'));
                await tester.pump();
                _expectFits(tester, '$where reported row $i');
                final row = tester.getRect(_key('reported-$i'));
                final tag = tester.getRect(_key('reported-$i-status'));
                expect(tag.right, lessThanOrEqualTo(row.right + 0.5));
                expect(
                  tag.overlaps(tester.getRect(_key('reported-$i-name'))),
                  isFalse,
                  reason: '$where row $i: the status on the name',
                );
              }
              await _unmount(tester, state);
            }, () => server.client);
          });
        }
      }
    }
  });
}
