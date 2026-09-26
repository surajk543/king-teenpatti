// Friends V1 on screen (owner, 26 Sep 2026): the lobby's key and its count,
// the Friends page — requests with Accept and Reject, friends playing first,
// then online, then offline — Add Friend's card for every friendStatus, a
// friend's profile and the question before Remove Friend, every loading, empty
// and error state; no wallet anywhere on these pages; nothing of it at a
// table; and every page laid out on a 640x360 phone at text x1.25 in all five
// languages, by day and by night, with nothing overflowing or cut.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/friends_screen.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/poker_chip.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'friends_fixture.dart';
import 'script_fonts.dart';

Future<void> _setView(
  WidgetTester tester, {
  Size screen = const Size(640, 360),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Widget _app(
  GameState state,
  FeedbackSettings feedback,
  Widget home, {
  Brightness brightness = Brightness.dark,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<GameState>.value(value: state),
    ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withScriptFallback(AppTheme.light(sound: false)),
    darkTheme: withScriptFallback(AppTheme.dark(sound: false)),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    builder: (context, child) => GlassBudget(child: child!),
    home: home,
  ),
);

/// Frames enough for the page to rise, read its lists and settle.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 300));
}

/// A bare screen with a key that opens the Friends page, as the lobby's does.
Future<void> _openPage(
  WidgetTester tester,
  GameState state, {
  Brightness brightness = Brightness.dark,
}) async {
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    _app(
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
      brightness: brightness,
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
}

Future<void> _pumpLobby(
  WidgetTester tester,
  GameState state, {
  Brightness brightness = Brightness.dark,
}) async {
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    _app(state, feedback, const LobbyScreen(), brightness: brightness),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// Nothing left in the tree — the page's and the lobby's clocks with it —
/// before the state goes.
Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

Finder _inPage(Finder matching) =>
    find.descendant(of: find.byType(FriendsScreen), matching: matching);

Finder _key(String key) => find.byKey(ValueKey(key));

/// Back, as the phone's back gesture gives it: the Navigator is asked, and
/// the page's own PopScope answers.
Future<void> _systemBack(WidgetTester tester) async {
  await tester.state<NavigatorState>(find.byType(Navigator).first).maybePop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Taps [finder] once it has been scrolled into view: the page is a list,
/// and on a 360dp phone its lower rows start below the fold.
Future<void> _tapShown(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
}

Future<void> _search(WidgetTester tester, String id) async {
  await tester.enterText(_key('friends-id-field'), id);
  await tester.tap(_key('friends-search'));
  await _settle(tester);
}

/// A rectangle on the screen, through every transform above [box].
Rect _onScreen(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

/// Every line of the Friends page (and of a dialog over it) whole and inside
/// the screen's width, and nothing thrown while laying it out.
void _expectFits(WidgetTester tester, String where) {
  expect(tester.takeException(), isNull, reason: where);
  final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  final roots = [
    find.byType(FriendsScreen),
    find.byKey(const ValueKey('friend-remove-dialog')),
  ];
  for (final root in roots) {
    for (final e
        in find
            .descendant(of: root, matching: find.byType(RichText))
            .evaluate()) {
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
      expect(
        rect.right,
        lessThanOrEqualTo(width + 0.5),
        reason: '$where: "$line"',
      );
    }
  }
}

/// No wallet on a Friends page: no word of one, no figure of the player's,
/// no coin, gem or wallet mark.
void _expectNoWallet(WidgetTester tester, String where) {
  final wallet = RegExp(
    r'chip|diamond|hammer|missile|coin|wallet|lakh|crore|₹|balance',
    caseSensitive: false,
  );
  for (final e in _inPage(find.byType(RichText)).evaluate()) {
    final line = (e.widget as RichText).text.toPlainText();
    expect(wallet.hasMatch(line), isFalse, reason: '$where: "$line"');
  }
  expect(_inPage(find.textContaining(formatChips(324500))), findsNothing);
  expect(_inPage(find.byType(PokerChip)), findsNothing);
  expect(_inPage(find.byIcon(Icons.diamond)), findsNothing);
  expect(_inPage(find.byIcon(Icons.hardware)), findsNothing);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadScriptFonts();
  });

  group('the lobby', () {
    testWidgets('its Friends key counts the requests waiting and opens the '
        'page', (tester) async {
      await _setView(tester);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _pumpLobby(tester, state);
        final key = find.byType(FriendsKey);
        expect(key, findsOneWidget);
        expect(find.byTooltip('Friends'), findsOneWidget);
        // Read as the lobby appeared.
        expect(server.count('GET', '/api/friends/requests'), 1);
        final badge = tester.widget<Badge>(_key('friends-badge'));
        expect(badge.isLabelVisible, isTrue);
        expect(
          find.descendant(of: _key('friends-badge'), matching: find.text('2')),
          findsOneWidget,
        );
        // One node for a screen reader: its name, its count, and its tap.
        expect(
          tester.getSemantics(find.byTooltip('Friends')),
          isSemantics(
            label: 'Friends, 2 new friend requests',
            isButton: true,
            hasTapAction: true,
          ),
        );

        await tester.tap(find.byTooltip('Friends'));
        await _settle(tester);
        expect(find.byType(FriendsScreen), findsOneWidget);
        expect(_inPage(find.text('Friends')), findsWidgets);
        expect(_inPage(find.text('Ravi')), findsOneWidget);
        expect(_inPage(find.text('Meera')), findsOneWidget);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('a toast raised over the page takes the plain foot, not the '
        'gap between the lobby chips the page covers', (tester) async {
      await _setView(tester);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _pumpLobby(tester, state);
        final lobby = tester.element(find.byType(LobbyScreen));
        final between = lobbyNoticeArea(lobby);
        expect(between, isNotNull);
        expect(between!.width, lessThan(Dim.toastW(640)));

        await tester.tap(find.byTooltip('Friends'));
        await _settle(tester);
        expect(find.byType(FriendsScreen), findsOneWidget);
        expect(lobbyNoticeArea(lobby), isNull);

        await _systemBack(tester);
        await _settle(tester);
        expect(find.byType(FriendsScreen), findsNothing);
        expect(lobbyNoticeArea(lobby), between);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('no request waiting, no count; a server from before Friends, '
        'no key', (tester) async {
      await _setView(tester);
      final server = FakeFriendsServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _pumpLobby(tester, state);
        expect(find.byTooltip('Friends'), findsOneWidget);
        expect(
          tester.widget<Badge>(_key('friends-badge')).isLabelVisible,
          isFalse,
        );
        server.unsupported = true;
        await state.friends.refreshBadge();
        await tester.pump();
        expect(find.byTooltip('Friends'), findsNothing);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('while the lobby shows the count is read every minute', (
      tester,
    ) async {
      await _setView(tester);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _pumpLobby(tester, state);
        final before = server.count('GET', '/api/friends/requests');
        server.incoming.add(requestJson(44, 'u-neha', 'Neha'));
        await tester.pump(const Duration(seconds: 60));
        expect(server.count('GET', '/api/friends/requests'), before + 1);
        expect(
          find.descendant(of: _key('friends-badge'), matching: find.text('3')),
          findsOneWidget,
        );
        // The lobby gone, the clock stops.
        await tester.pumpWidget(const SizedBox.shrink());
        final after = server.count('GET', '/api/friends/requests');
        await tester.pump(const Duration(minutes: 3));
        expect(server.count('GET', '/api/friends/requests'), after);
        state.dispose();
      }, () => server.client);
    });

    for (final brightness in Brightness.values) {
      for (final lang in AppLang.values) {
        testWidgets('on a 640x360 phone at text x1.25 in ${lang.name} '
            '(${brightness.name}) the key stands in the foot, clear of every '
            'chip, and the name keeps its width', (tester) async {
          await _setView(tester, textScale: 1.25);
          final server = populatedServer();
          await http.runWithClient(() async {
            // The foot as full as it gets: the daily bonus, the Lucky Draw
            // counting down, the milestone.
            final state = signedInState(lang: lang)
              ..luckyDraw = LuckyDrawState.fromJson({
                'draw': {
                  'code': 'BEGINNER_LUCKY_DRAW',
                  'name': 'Beginner Lucky Draw',
                  'spinnerType': 'BEGINNER',
                  'cooldownMs': 259200000,
                },
                'slots': const [],
                'nextSpinAt': DateTime.now()
                    .add(const Duration(hours: 50))
                    .millisecondsSinceEpoch,
              });
            await _pumpLobby(tester, state, brightness: brightness);
            expect(tester.takeException(), isNull);
            final key = tester.getRect(find.byTooltip(Strings(lang).friends));
            const screen = Rect.fromLTWH(0, 0, 640, 360);
            expect(screen.contains(key.topLeft), isTrue);
            expect(
              screen.contains(key.bottomRight - const Offset(1, 1)),
              isTrue,
            );
            expect(key.width, greaterThanOrEqualTo(Dim.minTouch));
            expect(key.height, greaterThanOrEqualTo(Dim.minTouch));
            final chips = find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_CornerChip',
            );
            expect(chips, findsWidgets);
            for (final chip in chips.evaluate()) {
              final rect = _onScreen(chip.renderObject! as RenderBox);
              expect(rect.overlaps(key), isFalse, reason: '$rect / $key');
            }
            // Not in the top bar: the name has exactly the room it has
            // without the key.
            final name = tester.renderObject<RenderParagraph>(
              find.text('Guest0E00B'),
            );
            final withKey = name.size.width;
            final lobby = tester.element(find.byType(LobbyScreen));
            final toastWithKey = lobbyNoticeArea(lobby);
            server.unsupported = true;
            await state.friends.refreshBadge();
            await tester.pump();
            expect(find.byTooltip(Strings(lang).friends), findsNothing);
            expect(
              tester
                  .renderObject<RenderParagraph>(find.text('Guest0E00B'))
                  .size
                  .width,
              withKey,
            );
            // A toast keeps clear of the key where it still has room, and
            // never stands narrower than it did before the key.
            final toastWithout = lobbyNoticeArea(lobby);
            if (toastWithKey != null && toastWithout != null) {
              if (toastWithKey != toastWithout) {
                expect(toastWithKey.overlaps(key), isFalse);
                expect(toastWithKey.width, greaterThanOrEqualTo(160));
              }
            }
            await _unmount(tester, state);
          }, () => server.client);
        });
      }
    }
  });

  group('the page', () {
    testWidgets('shows the requests with Accept and Reject, and the friends '
        'playing first, then online, then offline', (tester) async {
      await _setView(tester);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        expect(_inPage(find.text('FRIEND REQUESTS')), findsOneWidget);
        expect(_key('friend-accept-41'), findsOneWidget);
        expect(_key('friend-reject-41'), findsOneWidget);
        expect(_key('friend-accept-42'), findsOneWidget);
        expect(_inPage(find.text('Wants to be your friend')), findsNWidgets(2));
        final meera = _key('friend-u-meera');
        final arjun = _key('friend-u-arjun');
        final kavya = _key('friend-u-kavya');
        expect(
          tester.getTopLeft(meera).dy,
          lessThan(tester.getTopLeft(arjun).dy),
        );
        expect(
          tester.getTopLeft(arjun).dy,
          lessThan(tester.getTopLeft(kavya).dy),
        );
        // Playing: online, "Playing now", and the game in the app's names.
        expect(
          find.descendant(
            of: meera,
            matching: find.textContaining('Playing now'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: meera, matching: find.textContaining('Online')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: meera, matching: find.text('Teen Patti • Seen')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: meera, matching: _key('presence-dot-online')),
          findsOneWidget,
        );
        // Online, not playing: no game.
        expect(
          find.descendant(of: arjun, matching: find.textContaining('Online')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: arjun, matching: find.textContaining('Playing')),
          findsNothing,
        );
        // Offline: the grey dot and the word.
        expect(
          find.descendant(of: kavya, matching: find.textContaining('Offline')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: kavya, matching: _key('presence-dot-offline')),
          findsOneWidget,
        );
        // The player's own ID, to give a friend.
        expect(_inPage(find.text('Your Player ID')), findsOneWidget);
        expect(_inPage(find.text(myId)), findsOneWidget);
        _expectNoWallet(tester, 'list');
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('a playing poker friend reads "Poker • Texas Hold\'em"', (
      tester,
    ) async {
      await _setView(tester);
      final server = FakeFriendsServer(
        friends: [
          friendJson(
            'u-dev',
            'Dev',
            status: 'PLAYING',
            game: 'POKER',
            variant: 'TEXAS_HOLDEM',
          ),
        ],
      );
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        expect(
          find.descendant(
            of: _key('friend-u-dev'),
            matching: find.text("Poker • Texas Hold'em"),
          ),
          findsOneWidget,
        );
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('Accept moves the request into the friends; Reject takes it '
        'away', (tester) async {
      await _setView(tester);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await _tapShown(tester, _key('friend-accept-41'));
        await _settle(tester);
        expect(_key('friend-request-41'), findsNothing);
        expect(_key('friend-u-ravi'), findsOneWidget);
        expect(state.notice, 'Ravi is now your friend.');
        expect(state.friends.incomingCount, 1);

        await _tapShown(tester, _key('friend-reject-42'));
        await _settle(tester);
        expect(_key('friend-request-42'), findsNothing);
        expect(_key('friend-u-isha'), findsNothing);
        expect(_key('friends-no-requests'), findsOneWidget);
        expect(_inPage(find.text('No Friend Requests')), findsOneWidget);
        expect(state.friends.incomingCount, 0);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('empty: No Friend Requests, and No Friends Yet with its Add '
        'Friend key', (tester) async {
      await _setView(tester);
      final server = FakeFriendsServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        expect(_inPage(find.text('No Friend Requests')), findsOneWidget);
        expect(_inPage(find.text('No Friends Yet')), findsOneWidget);
        expect(
          _inPage(find.text('Add friends using their Player ID.')),
          findsOneWidget,
        );
        await _tapShown(tester, _key('friends-empty-add'));
        await _settle(tester);
        expect(_key('friends-id-field'), findsOneWidget);
        expect(_inPage(find.text('Search by Player ID')), findsOneWidget);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('loading, then "Could not load friends." with Retry', (
      tester,
    ) async {
      await _setView(tester);
      final server = populatedServer()..failLists = true;
      await http.runWithClient(() async {
        final state = signedInState();
        final feedback = FeedbackSettings();
        addTearDown(feedback.dispose);
        await tester.pumpWidget(
          _app(
            state,
            feedback,
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showFriends(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pump();
        // The first frame: nothing read yet.
        expect(_key('friends-loading'), findsOneWidget);
        await _settle(tester);
        expect(_key('friends-load-failed'), findsOneWidget);
        expect(_inPage(find.text('Could not load friends.')), findsOneWidget);
        expect(_inPage(find.text('Retry')), findsOneWidget);
        server.failLists = false;
        await _tapShown(tester, _key('friends-retry'));
        await _settle(tester);
        expect(_key('friends-load-failed'), findsNothing);
        expect(_key('friend-u-meera'), findsOneWidget);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('the lists are read every 15 s while it is open, and not once '
        'it has closed', (tester) async {
      await _setView(tester);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        expect(server.count('GET', '/api/friends'), 1);
        await tester.pump(const Duration(seconds: 15));
        expect(server.count('GET', '/api/friends'), 2);
        await tester.tap(_key('friends-close'));
        await _settle(tester);
        expect(find.byType(FriendsScreen), findsNothing);
        await tester.pump(const Duration(minutes: 2));
        expect(server.count('GET', '/api/friends'), 2);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('the app\'s one-second tick rebuilds nothing on it; a '
        'friend\'s news does', (tester) async {
      await _setView(tester);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        final row = tester.widget(_key('friend-u-meera'));
        // GameState notifies as its clock does, once a second.
        for (var i = 0; i < 3; i++) {
          state.markChatRead();
          await tester.pump(const Duration(seconds: 1));
        }
        expect(identical(tester.widget(_key('friend-u-meera')), row), isTrue);
        // The friend list read again with a change in it is news.
        server.friends.removeWhere((f) => f['userId'] == 'u-arjun');
        await state.friends.refresh();
        await tester.pump();
        expect(_key('friend-u-arjun'), findsNothing);
        expect(identical(tester.widget(_key('friend-u-meera')), row), isFalse);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('Copy puts the Player ID on the clipboard', (tester) async {
      await _setView(tester);
      final copied = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text']);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await tester.tap(_key('friends-copy-id'));
        await tester.pump();
        expect(copied, [myId]);
        expect(_inPage(find.text('Copied')), findsOneWidget);
        await tester.pump(FriendsScreen.copiedFor);
        expect(_inPage(find.text('Copy')), findsOneWidget);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('Back returns from a page inside it before it closes it', (
      tester,
    ) async {
      await _setView(tester);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await tester.tap(_key('friends-add'));
        await _settle(tester);
        expect(_key('friends-id-field'), findsOneWidget);
        await _systemBack(tester);
        expect(find.byType(FriendsScreen), findsOneWidget);
        expect(_key('friends-list'), findsOneWidget);
        await _systemBack(tester);
        expect(find.byType(FriendsScreen), findsNothing);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('it closes itself when the app leaves the lobby', (
      tester,
    ) async {
      await _setView(tester);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        expect(find.byType(FriendsScreen), findsOneWidget);
        state.screen = Screen.table;
        state.say('seated');
        await _settle(tester);
        expect(find.byType(FriendsScreen), findsNothing);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('it takes the question over it with it when it goes', (
      tester,
    ) async {
      await _setView(tester);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await _tapShown(tester, _key('friend-u-meera'));
        await _settle(tester);
        await _tapShown(tester, _key('friend-remove'));
        await _settle(tester);
        expect(_key('friend-remove-dialog'), findsOneWidget);
        // Signed out from under it.
        state.screen = Screen.login;
        state.say('signed out');
        await _settle(tester);
        await _settle(tester);
        expect(_key('friend-remove-dialog'), findsNothing);
        expect(find.byType(FriendsScreen), findsNothing);
        expect(find.text('open'), findsOneWidget);
        expect(server.count('DELETE', '/api/friends/u-meera'), 0);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('side by side on a phone: the requests beside the friends, '
        'both on screen', (tester) async {
      await _setView(tester, textScale: 1.25);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        final requests = tester.getRect(_key('friends-requests'));
        final friends = tester.getRect(_key('friends-list'));
        expect(requests.right, lessThanOrEqualTo(friends.left));
        expect(requests.top, closeTo(friends.top, 0.5));
        // Every friend and the first request are there without a scroll.
        for (final key in [
          'friend-request-41',
          'friend-u-meera',
          'friend-u-arjun',
        ]) {
          final rect = tester.getRect(_key(key));
          expect(rect.top, lessThan(360), reason: key);
        }
        expect(
          find.descendant(
            of: _key('friends-requests'),
            matching: _key('friend-u-meera'),
          ),
          findsNothing,
        );
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('narrower than two columns: one list, the requests then the '
        'friends', (tester) async {
      await _setView(tester, screen: const Size(520, 360), textScale: 1.25);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        expect(_key('friends-requests'), findsNothing);
        final list = _key('friends-list');
        // Below the fold here, so looked for past the list's edge too.
        Finder below(String key) =>
            find.byKey(ValueKey(key), skipOffstage: false);
        expect(
          find.descendant(
            of: list,
            matching: below('friend-request-41'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: list,
            matching: below('friend-u-meera'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        expect(
          tester.getTopLeft(below('friend-request-42')).dy,
          lessThan(tester.getTopLeft(below('friend-u-meera')).dy),
        );
        _expectFits(tester, 'one list');
        await _unmount(tester, state);
      }, () => server.client);
    });
  });

  group('Add Friend', () {
    testWidgets('draws the card each friendStatus calls for', (tester) async {
      await _setView(tester);
      final server = populatedServer();
      server.players
        ..['u-asha'] = {
          'player': cardJson('u-asha', 'Asha'),
          'friendStatus': 'NONE',
        }
        ..['u-dev'] = {
          'player': cardJson('u-dev', 'Dev'),
          'friendStatus': 'PENDING_SENT',
          'requestId': 43,
        }
        ..['u-ravi'] = {
          'player': cardJson('u-ravi', 'Ravi'),
          'friendStatus': 'PENDING_RECEIVED',
          'requestId': 41,
        }
        ..['u-meera'] = {
          'player': cardJson('u-meera', 'Meera'),
          'friendStatus': 'FRIENDS',
        }
        ..[myId] = {
          'player': cardJson(myId, 'Guest0E00B'),
          'friendStatus': 'SELF',
        };
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await tester.tap(_key('friends-add'));
        await _settle(tester);
        // Nothing asked yet: where a friend's ID comes from.
        expect(
          _inPage(
            find.text(
              'Ask your friend for their Player ID — it is at the top of '
              'their Friends page.',
            ),
          ),
          findsOneWidget,
        );

        await _search(tester, 'u-asha');
        expect(_key('friend-search-how'), findsNothing);
        expect(_key('friend-result-u-asha'), findsOneWidget);
        expect(_key('friend-send'), findsOneWidget);
        expect(
          find.descendant(
            of: _key('friend-send'),
            matching: find.text('Add Friend'),
          ),
          findsOneWidget,
        );

        await _search(tester, 'u-dev');
        expect(_key('friend-request-sent'), findsOneWidget);
        expect(_inPage(find.text('Request Sent')), findsOneWidget);

        await _search(tester, 'u-ravi');
        expect(_key('friend-lookup-accept'), findsOneWidget);
        expect(
          find.descendant(
            of: _key('friend-lookup-accept'),
            matching: find.text('Accept'),
          ),
          findsOneWidget,
        );

        await _search(tester, 'u-meera');
        expect(_key('friend-already'), findsOneWidget);
        expect(
          find.descendant(
            of: _key('friend-already'),
            matching: find.text('Friends'),
          ),
          findsOneWidget,
        );

        await _search(tester, myId);
        expect(_key('friend-thats-you'), findsOneWidget);
        expect(_key('friend-send'), findsNothing);
        expect(_key('friend-lookup-accept'), findsNothing);
        expect(_key('friend-request-sent'), findsNothing);
        expect(_key('friend-already'), findsNothing);

        await _search(tester, 'nobody-at-all');
        expect(_key('friend-search-error'), findsOneWidget);
        expect(_inPage(find.text('Player not found.')), findsOneWidget);

        await _search(tester, '   ');
        expect(_inPage(find.text('Enter a Player ID.')), findsOneWidget);
        _expectNoWallet(tester, 'add');
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('Add Friend sends the request, and the card says Request '
        'Sent', (tester) async {
      await _setView(tester);
      final server = populatedServer();
      server.players['u-asha'] = {
        'player': cardJson('u-asha', 'Asha'),
        'friendStatus': 'NONE',
      };
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await tester.tap(_key('friends-add'));
        await _settle(tester);
        await _search(tester, 'u-asha');
        await tester.tap(_key('friend-send'));
        await _settle(tester);
        expect(_key('friend-request-sent'), findsOneWidget);
        expect(server.count('POST', '/api/friends/requests'), 1);
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('a request the other player already sent turns into Accept, '
        'and says so', (tester) async {
      await _setView(tester);
      final server = populatedServer()
        ..sendRefusal = refusal('request_already_received', 409, requestId: 41);
      server.players['u-ravi'] = {
        'player': cardJson('u-ravi', 'Ravi'),
        'friendStatus': 'NONE',
      };
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await tester.tap(_key('friends-add'));
        await _settle(tester);
        await _search(tester, 'u-ravi');
        await tester.tap(_key('friend-send'));
        await _settle(tester);
        expect(_key('friend-lookup-accept'), findsOneWidget);
        expect(
          _inPage(
            find.text('This player already sent you a request — accept it.'),
          ),
          findsOneWidget,
        );
        await tester.tap(_key('friend-lookup-accept'));
        await _settle(tester);
        expect(_key('friend-already'), findsOneWidget);
        expect(server.count('POST', '/api/friends/requests/41/accept'), 1);
        await _unmount(tester, state);
      }, () => server.client);
    });
  });

  group('a profile', () {
    testWidgets('shows where the friend is and their record, and Remove Friend '
        'asks first', (tester) async {
      await _setView(tester);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await _tapShown(tester, _key('friend-u-meera'));
        await _settle(tester);
        expect(_key('friend-profile'), findsOneWidget);
        expect(_key('friend-profile-name'), findsOneWidget);
        expect(_inPage(find.textContaining('Playing now')), findsOneWidget);
        expect(_inPage(find.text('Teen Patti • Seen')), findsOneWidget);
        for (final (label, value) in [
          ('Hands played', '120'),
          ('Won', '61'),
          ('Lost', '52'),
          ('Left mid-hand', '7'),
          ('Win rate', '50.83%'),
        ]) {
          expect(_inPage(find.text(label)), findsOneWidget, reason: label);
          expect(_inPage(find.text(value)), findsOneWidget, reason: value);
        }
        _expectNoWallet(tester, 'profile');

        // Asked, and cancelled: nothing happens.
        await _tapShown(tester, _key('friend-remove'));
        await _settle(tester);
        expect(_key('friend-remove-dialog'), findsOneWidget);
        expect(find.text('Remove Meera from your friends?'), findsOneWidget);
        await tester.tap(_key('friend-remove-cancel'));
        await _settle(tester);
        expect(_key('friend-remove-dialog'), findsNothing);
        expect(server.count('DELETE', '/api/friends/u-meera'), 0);
        expect(_key('friend-profile'), findsOneWidget);

        // Asked, and confirmed: gone, and back on the list.
        await _tapShown(tester, _key('friend-remove'));
        await _settle(tester);
        await tester.tap(_key('friend-remove-confirm'));
        await _settle(tester);
        expect(server.count('DELETE', '/api/friends/u-meera'), 1);
        expect(_key('friends-list'), findsOneWidget);
        expect(_key('friend-u-meera'), findsNothing);
        expect(state.notice, 'Meera is no longer your friend.');
        await _unmount(tester, state);
      }, () => server.client);
    });

    testWidgets('an offline friend reads Offline, and a player who is not a '
        'friend shows no presence', (tester) async {
      await _setView(tester);
      final server = populatedServer();
      await http.runWithClient(() async {
        final state = signedInState();
        await _openPage(tester, state);
        await _tapShown(tester, _key('friend-u-kavya'));
        await _settle(tester);
        expect(_inPage(find.textContaining('Offline')), findsOneWidget);
        expect(_inPage(_key('presence-dot-offline')), findsOneWidget);
        expect(_inPage(find.text('40%')), findsOneWidget);
        await _systemBack(tester);
        // Ravi asked to be friends: his profile offers Accept, no presence.
        await _tapShown(tester, find.text('Ravi'));
        await _settle(tester);
        expect(_key('friend-lookup-accept'), findsOneWidget);
        expect(_inPage(_key('presence-dot-online')), findsNothing);
        expect(_inPage(_key('presence-dot-offline')), findsNothing);
        await _unmount(tester, state);
      }, () => server.client);
    });
  });

  test('the gameplay screens know nothing of Friends', () {
    const files = [
      'lib/screens/table_screen.dart',
      'lib/screens/poker_table_screen.dart',
      'lib/widgets/table_chrome.dart',
      'lib/widgets/seat_pod.dart',
    ];
    final friends = RegExp(
      r'friends_screen|friends_state|models/friends|FriendsKey|FriendsScreen|'
      r'FriendsState|showFriends|\.friends\b',
    );
    for (final path in files) {
      final source = File(path).readAsStringSync();
      expect(friends.hasMatch(source), isFalse, reason: path);
    }
  });

  group('every page fits a 640x360 phone at text x1.25', () {
    for (final brightness in Brightness.values) {
      for (final lang in AppLang.values) {
        testWidgets('in ${lang.name} (${brightness.name})', (tester) async {
          await _setView(tester, textScale: 1.25);
          final t = Strings(lang);
          final server = populatedServer();
          server.players['u-asha'] = {
            'player': cardJson('u-asha', 'Asha'),
            'friendStatus': 'NONE',
          };
          await http.runWithClient(() async {
            final state = signedInState(lang: lang);
            await _openPage(tester, state, brightness: brightness);
            _expectFits(tester, 'list');
            // The header's keys, all on screen and apart.
            final keys = [
              tester.getRect(_key('friends-add')),
              tester.getRect(_key('friends-close')),
              tester.getRect(_key('friends-copy-id')),
            ];
            for (final rect in keys) {
              expect(rect.left, greaterThanOrEqualTo(0));
              expect(rect.right, lessThanOrEqualTo(640));
            }
            expect(keys[0].overlaps(keys[1]), isFalse);
            // Every request's keys inside its row.
            for (final id in ['41', '42']) {
              final row = tester.getRect(_key('friend-request-$id'));
              for (final k in ['friend-accept-$id', 'friend-reject-$id']) {
                final rect = tester.getRect(_key(k));
                expect(
                  rect.right,
                  lessThanOrEqualTo(row.right + 0.5),
                  reason: k,
                );
                expect(
                  rect.left,
                  greaterThanOrEqualTo(row.left - 0.5),
                  reason: k,
                );
              }
            }

            // Add Friend, with a player found.
            await tester.tap(_key('friends-add'));
            await _settle(tester);
            _expectFits(tester, 'add');
            await _search(tester, 'u-asha');
            expect(_key('friend-send'), findsOneWidget);
            _expectFits(tester, 'add with a result');
            await _search(tester, 'nobody');
            expect(
              _inPage(find.text(t.friendRefusePlayerNotFound)),
              findsOneWidget,
            );
            _expectFits(tester, 'nobody found');
            await _systemBack(tester);

            // A playing friend's profile, and the question before removing.
            await _tapShown(tester, _key('friend-u-meera'));
            await _settle(tester);
            expect(_key('friend-profile'), findsOneWidget);
            _expectFits(tester, 'profile');
            await _tapShown(tester, _key('friend-remove'));
            await _settle(tester);
            expect(_key('friend-remove-dialog'), findsOneWidget);
            _expectFits(tester, 'remove dialog');
            await tester.tap(_key('friend-remove-cancel'));
            await _settle(tester);
            await _unmount(tester, state);
          }, () => server.client);
        });
      }
    }

    for (final lang in AppLang.values) {
      testWidgets('empty, and could not load, in ${lang.name}', (tester) async {
        await _setView(tester, textScale: 1.25);
        final server = FakeFriendsServer();
        await http.runWithClient(() async {
          final state = signedInState(lang: lang);
          await _openPage(tester, state);
          expect(_key('friends-empty'), findsOneWidget);
          _expectFits(tester, 'empty');
          await _unmount(tester, state);
          final failing = populatedServer()..failLists = true;
          await http.runWithClient(() async {
            final state = signedInState(lang: lang);
            await _openPage(tester, state, brightness: Brightness.light);
            expect(_key('friends-load-failed'), findsOneWidget);
            _expectFits(tester, 'failed');
            await _unmount(tester, state);
          }, () => failing.client);
        }, () => server.client);
      });
    }
  });

  testWidgets('a wide tablet stands the page in the middle of the room', (
    tester,
  ) async {
    await _setView(tester, screen: const Size(1280, 800));
    final server = populatedServer();
    await http.runWithClient(() async {
      final state = signedInState();
      await _openPage(tester, state);
      final page = tester.getRect(find.byType(PremiumGlassPanel).first);
      expect(page.width, lessThanOrEqualTo(FriendsScreen.largest.width));
      expect(page.height, lessThanOrEqualTo(FriendsScreen.largest.height));
      expect(page.center.dx, closeTo(640, 1));
      _expectFits(tester, 'tablet');
      await _unmount(tester, state);
    }, () => server.client);
  });

  test('the page names no wallet in any language', () {
    // Every word the page can say, in every language, is free of the wallet.
    final wallet = RegExp(
      r'chip|diamond|hammer|missile|coin|wallet|lakh|crore|₹',
      caseSensitive: false,
    );
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final line in [
        t.friends,
        t.yourPlayerId,
        t.addFriend,
        t.friendRequests,
        t.noFriendsBody,
        t.playingNow,
        t.winRate,
        t.removeFriendBody,
      ]) {
        expect(wallet.hasMatch(line), isFalse, reason: '${lang.name} $line');
      }
    }
  });
  // A landscape phone's keyboard takes about 69% of its height (Gboard on
  // TP_Small: 248 of 360dp). The page stands above it, and what is being
  // typed must stay in view — the header above the field once pushed the
  // field under the keyboard on a 640x360 phone (26 Sep 2026).
  group('the keyboard', () {
    for (final screen in const [
      Size(640, 360),
      Size(732, 412),
      Size(915, 412),
    ]) {
      for (final scale in const [1.0, 1.25]) {
        for (final lang in AppLang.values) {
          testWidgets('on a ${screen.width.toInt()}x${screen.height.toInt()} '
              'phone at text x$scale in ${lang.name} the Player ID field and '
              'its Search key stay above the keyboard', (tester) async {
            await _setView(tester, screen: screen, textScale: scale);
            final keyboard = (screen.height * 0.69).roundToDouble();
            final server = populatedServer();
            await http.runWithClient(() async {
              final state = signedInState(lang: lang);
              await _openPage(tester, state);
              await tester.tap(_key('friends-add'));
              await _settle(tester);
              await tester.tap(_key('friends-id-field'));
              await tester.pump();
              tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
              addTearDown(tester.view.resetViewInsets);
              await tester.enterText(
                _key('friends-id-field'),
                'c1fccbdc-a814-4399-890c-ded08523f5c1',
              );
              await _settle(tester);
              expect(tester.takeException(), isNull);
              // Above the keyboard, and inside the view that scrolls — which
              // clips at its edges once its contents overflow it.
              final scroller = find
                  .descendant(
                    of: _key('friends-view-add'),
                    matching: find.byType(Scrollable),
                  )
                  .first;
              final visible = Rect.fromLTRB(
                0,
                0,
                screen.width,
                screen.height - keyboard,
              ).intersect(tester.getRect(scroller));
              final label = find.descendant(
                of: _key('friends-id-field'),
                matching: find.text(Strings(lang).playerIdLabel),
              );
              for (final (what, finder) in [
                ('field', _key('friends-id-field')),
                ('its label', label),
                ('Search', _key('friends-search')),
              ]) {
                final rect = tester.getRect(finder);
                expect(
                  visible.contains(rect.topLeft) &&
                      visible.contains(rect.bottomRight - const Offset(1, 1)),
                  isTrue,
                  reason: '$what $rect outside $visible',
                );
              }
              // Still the field being typed in.
              expect(
                tester.testTextInput.isVisible && state.friends.lookup == null,
                isTrue,
              );
              // Searching puts the keyboard away and the header back.
              await tester.tap(_key('friends-search'));
              tester.view.resetViewInsets();
              await _settle(tester);
              expect(_key('friends-back'), findsOneWidget);
              expect(_key('friends-close'), findsOneWidget);
              await _unmount(tester, state);
            }, () => server.client);
          });
        }
      }
    }
  });
}
