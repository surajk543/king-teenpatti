// Pagination on the phone (owner, 27 Sep 2026: "make sure that reported user
// should be fetched using pagination, and same with friend list, as user
// scroll, then it will fetch more pagination" — "All apis should be
// pagination and default page size is 20").
//
// Against a fake server that really pages — 20 by default, a cursor to the
// next page, the total beside it — the friends, the requests waiting and the
// player's reports each come a page at a time: the first page as the list
// opens, the next as it is scrolled near its end, a spinner at the end while
// it comes, every item once, and the counts are the totals, not the pages
// read. A table reads every page, so its marks are for every friend. A pull
// re-reads as far down as the player had scrolled.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/screens/friends_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/paged_scroll.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'friends_fixture.dart';
import 'script_fonts.dart';

/// A server with [friends] friends, [waiting] requests waiting and [reports]
/// reports, each paged as the real one pages: ?limit (20 by default, 100 at
/// most) and ?cursor, the offset here.
class _PagingServer {
  _PagingServer({this.friends = 0, this.waiting = 0, this.reports = 0});

  final int friends;
  final int waiting;
  final int reports;

  /// Every list request, as "path?query".
  final asked = <String>[];

  /// While set, a page after the first waits for it.
  Future<void>? hold;

  http.Response _json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );

  (int, int, String?) _page(Uri url, int total) {
    final limit = int.tryParse(url.queryParameters['limit'] ?? '') ?? 20;
    final from = int.tryParse(url.queryParameters['cursor'] ?? '') ?? 0;
    final end = (from + limit).clamp(0, total);
    return (from.clamp(0, total), end, end < total ? '$end' : null);
  }

  MockClient get client => MockClient((r) async {
    final url = r.url;
    switch (url.path) {
      case '/api/friends':
        asked.add('${url.path}?${url.query}');
        if (url.queryParameters.containsKey('cursor') && hold != null) {
          await hold;
        }
        final (from, end, next) = _page(url, friends);
        return _json({
          'friends': [
            for (var i = from; i < end; i++)
              friendJson('u-$i', 'Friend${i.toString().padLeft(2, '0')}'),
          ],
          'total': friends,
          'nextCursor': next,
        });
      case '/api/friends/requests':
        asked.add('${url.path}?${url.query}');
        final (from, end, next) = _page(url, waiting);
        final page = [
          for (var i = from; i < end; i++)
            requestJson(100 + i, 'r-$i', 'Asker$i'),
        ];
        if (url.queryParameters['box'] == 'incoming') {
          return _json({
            'requests': page,
            'total': waiting,
            'nextCursor': next,
          });
        }
        return _json({
          'incoming': page,
          'outgoing': const [],
          'incomingTotal': waiting,
          'outgoingTotal': 0,
          'nextIncoming': next,
          'nextOutgoing': null,
        });
      case '/api/reports/mine':
        asked.add('${url.path}?${url.query}');
        final (from, end, next) = _page(url, reports);
        return _json({
          'reports': [
            for (var i = from; i < end; i++)
              {
                'player': {
                  'displayName': 'Reported$i',
                  'profilePicture': {'id': null, 'url': null},
                  'gone': false,
                },
                'reason': 'SPAM',
                'description': '',
                'game': 'teen_patti',
                'category': 'seen',
                'variant': '',
                'status': 'PENDING',
                // Newest first: the first is the latest.
                'createdAt': 1790000000000 - i * 60000,
                'updatedAt': 1790000000000 - i * 60000,
              },
          ],
          'total': reports,
          'nextCursor': next,
        });
    }
    return http.Response(jsonEncode({'error': 'not_found'}), 404);
  });

  int count(String path, {bool withCursor = false}) => asked
      .where((a) => a.startsWith('$path?'))
      .where((a) => !withCursor || a.contains('cursor='))
      .length;
}

void _setView(WidgetTester tester) {
  tester.view.physicalSize = const Size(891, 411);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _openPage(WidgetTester tester, GameState state) async {
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
        theme: withScriptFallback(AppTheme.dark(sound: false)),
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

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

Finder _key(String key) => find.byKey(ValueKey(key));

/// Scrolls the list keyed [list] to its end, a drag at a time.
Future<void> _scrollToEnd(WidgetTester tester, String list) async {
  for (var i = 0; i < 12; i++) {
    await tester.drag(_key(list), const Offset(0, -600));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await _settle(tester);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadScriptFonts();
  });

  group('the state', () {
    test('the friends come a page at a time, each once, the count the total, '
        'and a re-read keeps as many as were read', () async {
      final server = _PagingServer(friends: 45, waiting: 3);
      await http.runWithClient(() async {
        final state = signedInState();
        final f = state.friends;
        await f.refresh();
        expect(f.friends, hasLength(20));
        expect(f.friendsTotal, 45);
        expect(f.hasMoreFriends, isTrue);
        expect(server.asked.first, '/api/friends?limit=20');
        expect(await f.loadMoreFriends(), isTrue);
        expect(await f.loadMoreFriends(), isTrue);
        expect(f.friends, hasLength(45));
        expect(f.hasMoreFriends, isFalse);
        expect(await f.loadMoreFriends(), isFalse, reason: 'no page left');
        expect({for (final x in f.friends) x.userId}, hasLength(45));
        // A poll re-reads as far down as the player went (45, within 100).
        server.asked.clear();
        await f.refresh();
        expect(server.asked, contains('/api/friends?limit=45'));
        expect(f.friends, hasLength(45));
        state.dispose();
      }, () => server.client);
    });

    test('the requests: the badge counts every one waiting, and a request '
        'answered beyond the page read still leaves the count', () async {
      final server = _PagingServer(waiting: 26);
      await http.runWithClient(() async {
        final state = signedInState();
        final f = state.friends;
        await f.refreshBadge();
        expect(f.incomingCount, 26);
        await f.refresh();
        expect(f.incoming, hasLength(20));
        expect(f.hasMoreIncoming, isTrue);
        expect(await f.loadMoreIncoming(), isTrue);
        expect(f.incoming, hasLength(26));
        expect(f.incomingCount, 26);
        state.dispose();
      }, () => server.client);
    });

    test('a table reads every page: every friend wears the mark', () async {
      final server = _PagingServer(friends: 230, waiting: 130);
      await http.runWithClient(() async {
        final state = signedInState();
        final f = state.friends;
        await f.tableOpened();
        expect(f.friends, hasLength(230));
        expect(f.isFriend('u-229'), isTrue);
        expect(f.incoming, hasLength(130));
        expect(f.hasMoreFriends, isFalse);
        expect(f.hasMoreIncoming, isFalse);
        // The pages after the first, a hundred at a time.
        expect(
          server.asked.where(
            (a) => a.startsWith('/api/friends?') && a.contains('limit=100'),
          ),
          hasLength(3),
        );
        state.dispose();
      }, () => server.client);
    });

    test('the reports come a page at a time, newest first', () async {
      final server = _PagingServer(reports: 25);
      await http.runWithClient(() async {
        final state = signedInState();
        final r = state.reports;
        await r.loadMine();
        expect(r.mine, hasLength(20));
        expect(r.mineTotal, 25);
        expect(r.mineHasMore, isTrue);
        await r.loadMoreMine();
        expect(r.mine, hasLength(25));
        expect(r.mineHasMore, isFalse);
        expect(r.mine!.first.displayName, 'Reported0');
        expect(r.mine!.last.displayName, 'Reported24');
        // A pull starts again from the first page.
        await r.loadMine();
        expect(r.mine, hasLength(20));
        state.dispose();
      }, () => server.client);
    });
  });

  group('on screen', () {
    testWidgets(
      'the friends list reads the next page as it is scrolled to its end, '
      'a spinner at the end meanwhile, and says the total',
      (tester) async {
        _setView(tester);
        final server = _PagingServer(friends: 45, waiting: 2);
        await http.runWithClient(() async {
          final state = signedInState();
          await _openPage(tester, state);
          expect(find.text('45'), findsOneWidget, reason: 'the total');
          expect(state.friends.friends, hasLength(20));
          expect(server.count('/api/friends', withCursor: true), 0);

          // Held, so the spinner at the end can be seen.
          final gate = Completer<void>();
          server.hold = gate.future;
          await tester.drag(_key('friends-list'), const Offset(0, -2000));
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 100));
          expect(server.count('/api/friends', withCursor: true), 1);
          expect(state.friends.loadingMoreFriends, isTrue);
          await tester.drag(_key('friends-list'), const Offset(0, -2000));
          await tester.pump();
          expect(_key('paged-more'), findsOneWidget);
          gate.complete();
          server.hold = null;
          await _settle(tester);
          await _scrollToEnd(tester, 'friends-list');
          expect(state.friends.friends, hasLength(45));
          expect(find.text('Friend44'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await _unmount(tester, state);
        }, () => server.client);
      },
    );

    testWidgets('a page that does not fill its view asks for the next at '
        'once, and asks once while one is out', (tester) async {
      var asked = 0;
      var loading = false;
      var hasMore = true;
      late StateSetter set;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              set = setState;
              return PagedScroll(
                hasMore: hasMore,
                loading: loading,
                onMore: () => setState(() {
                  asked++;
                  loading = true;
                }),
                builder: (context, controller) => ListView(
                  controller: controller,
                  children: [
                    for (var i = 0; i < 3; i++)
                      SizedBox(height: 40, child: Text('row $i')),
                  ],
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(asked, 1, reason: 'three rows fill nothing: the next page');
      await tester.pump();
      expect(asked, 1, reason: 'one read at a time');
      // The page came in, and it was the last: nothing more is asked.
      set(() {
        loading = false;
        hasMore = false;
      });
      await tester.pump();
      await tester.pump();
      expect(asked, 1);
    });

    testWidgets('the Reported tab reads its next page as it is scrolled', (
      tester,
    ) async {
      _setView(tester);
      final server = _PagingServer(reports: 25);
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await tester.tap(_key('friends-tab-reported'));
        await _settle(tester);
        expect(find.text('25'), findsOneWidget, reason: 'the total');
        expect(state.reports.mine, hasLength(20));
        await _scrollToEnd(tester, 'reported-list');
        expect(state.reports.mine, hasLength(25));
        expect(find.text('Reported24'), findsOneWidget);
        expect(server.count('/api/reports/mine', withCursor: true), 1);
        expect(tester.takeException(), isNull);
        await _unmount(tester, state);
      }, () => server.client);
    });
  });
}
