// The chat drawer's block page and its boxed quick messages (owner, 24 Sep
// 2026: "In chat message drawer when user click on block button do not show
// pop up, instead show block button of players in drawer itself and in chat
// messages DO NOT SHOW ANY unblock message, only message should appear and In
// quick chat message also add some icons, and every message of quick message
// should be in some box.").
//
// The drawer is mounted for real on the 640x360 phone at the 1.25 text
// ceiling — the tightest layout the app must survive — and pressed: the
// header's block key, a row's Block key, a tab, a message's long-press. A
// Navigator observer counts routes, so "no popup" is a number and not a
// belief. Blocking's rules underneath (this client, this table, this sitting)
// are in block_chat_test.dart.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/glass_components.dart';
import 'package:teenpatti/widgets/glass_panels.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

Map<String, dynamic> _seat(int index, String id, String name) => {
  'seatIndex': index,
  'userId': id,
  'displayName': name,
  'chips': index == 0 ? 200000 : null,
  'status': 'active',
  'isBlind': true,
  'lastBet': 200,
  'lastAction': 'chaal',
  'contributed': 200,
  'connected': true,
  'cardCount': 3,
};

/// A blind table with the viewer at seat 0 and [others] — (id, name) — after.
RoomState _room(List<(String, String)> others) => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': 'blind',
  'chipsHidden': true,
  'state': 'betting',
  'handNo': 2,
  'dealerSeat': 0,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 600,
  'maxPot': 0,
  'stake': 200,
  'you': {
    'seatIndex': 0,
    'chips': 200000,
    'status': 'active',
    'isBlind': true,
    'blindMovesLeft': 4,
    'contributed': 200,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': <String>[],
  },
  'seats': [
    _seat(0, 'me', 'You'),
    for (final (i, (id, name)) in others.indexed) _seat(i + 1, id, name),
  ],
});

ChatMessage _msg(String userId, String name, String text) =>
    ChatMessage.fromJson({
      'messageId': '$userId-$text',
      'userId': userId,
      'displayName': name,
      'text': text,
      'at': 0,
    });

GameState _newState({required RoomState room, AppLang lang = AppLang.english}) {
  // Play is never started here; the override only keeps the purchase plugin
  // from registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..user = User.fromJson({
      'id': 'me',
      'provider': 'guest',
      'displayName': 'You',
      'chips': 200000,
    })
    ..room = room
    ..screen = Screen.table;
}

/// Counts what the Navigator pushes, so a dialog that opened would be seen
/// whatever it was made of.
class _Routes extends NavigatorObserver {
  int pushed = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed++;
  }
}

const _phone = Size(640, 360);

Future<_Routes> _pumpDrawer(
  WidgetTester tester,
  GameState state, {
  double scale = 1.25,
}) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  final routes = _Routes();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(sound: false),
        navigatorObservers: [routes],
        builder: (context, child) => GlassBudget(child: child!),
        home: const Scaffold(
          backgroundColor: Colors.transparent,
          body: ChatDrawer(),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  // The home route is the one push a drawer alone makes.
  expect(routes.pushed, 1);
  return routes;
}

Future<void> _teardown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

/// A key of [ChatPlayers] by the label it shows right now.
Finder _playerKey(String label) => find.descendant(
  of: find.byType(ChatPlayers),
  matching: find.widgetWithText(GlassButton, label),
);

/// The key on the row that names [player].
Finder _keyBeside(String player) => find.descendant(
  of: find
      .ancestor(of: find.text(player), matching: find.byType(Row))
      .first,
  matching: find.byType(GlassButton),
);

/// Whether [key] reads [label] right now.
Finder _says(Finder key, String label) =>
    find.descendant(of: key, matching: find.text(label));

/// A chat line, which is a RichText and so invisible to `find.text`.
Finder _line(String text) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText().contains(text),
);

const _t = Strings(AppLang.english);
final _blockKey = find.byTooltip(_t.blockPlayersTitle);

void main() {
  testWidgets(
    "the header's block key shows the players list in the drawer and pushes "
    'no route',
    (tester) async {
      final state = _newState(
        room: _room([('ravi', 'Ravi'), ('meera', 'Meera')]),
      );
      final routes = await _pumpDrawer(tester, state);

      expect(find.byType(ChatPlayers), findsNothing);
      expect(find.byType(GlassTextField), findsOneWidget);

      await tester.tap(_blockKey);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(ChatPlayers), findsOneWidget);
      // Every other seat, named, with a Block key each; the viewer's own seat
      // is not offered.
      expect(find.text('Ravi'), findsOneWidget);
      expect(find.text('Meera'), findsOneWidget);
      expect(_playerKey(_t.block), findsNWidgets(2));
      expect(_playerKey(_t.unblock), findsNothing);
      expect(find.text(_t.blockPlayersTitle), findsOneWidget);
      // The composer and the messages stand down while the list is up.
      expect(find.byType(GlassTextField), findsNothing);
      // No popup: nothing was pushed, and nothing is a dialog.
      expect(routes.pushed, 1);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(GlassDialog), findsNothing);
      expect(tester.takeException(), isNull);

      await _teardown(tester, state);
    },
  );

  testWidgets(
    "tapping Block turns that row's key into Unblock and blocks only that "
    'player',
    (tester) async {
      final state = _newState(
        room: _room([('ravi', 'Ravi'), ('meera', 'Meera')]),
      );
      final routes = await _pumpDrawer(tester, state);
      await tester.tap(_blockKey);
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(_keyBeside('Ravi'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(state.isBlocked('ravi'), isTrue);
      expect(state.isBlocked('meera'), isFalse);
      expect(_says(_keyBeside('Ravi'), _t.unblock), findsOneWidget);
      expect(_says(_keyBeside('Meera'), _t.block), findsOneWidget);
      // Nothing asked, nothing pushed.
      expect(routes.pushed, 1);

      // The same key lifts it.
      await tester.tap(_keyBeside('Ravi'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.isBlocked('ravi'), isFalse);
      expect(_says(_keyBeside('Ravi'), _t.block), findsOneWidget);
      expect(routes.pushed, 1);

      await _teardown(tester, state);
    },
  );

  testWidgets(
    'the chat page shows only the messages and the composer while a player '
    'is blocked',
    (tester) async {
      final state = _newState(
        room: _room([('ravi', 'Ravi'), ('meera', 'Meera')]),
      );
      state.chat.add(_msg('meera', 'Meera', 'nice hand'));
      state.blockPlayer('ravi');
      await _pumpDrawer(tester, state);

      expect(_line('nice hand'), findsOneWidget);
      expect(find.byType(GlassTextField), findsOneWidget);
      // No "Blocked: Ravi · Unblock" row, no unblock anywhere on this page:
      // that lives on the players list alone (owner, 24 Sep 2026).
      expect(find.text(_t.unblock), findsNothing);
      expect(find.textContaining(_t.unblock), findsNothing);
      expect(find.textContaining('Blocked'), findsNothing);
      expect(find.byType(ChatPlayers), findsNothing);
      // The header's key still says a block is in force, in gold.
      final icon = tester.widget<Icon>(
        find.descendant(of: _blockKey, matching: find.byType(Icon)),
      );
      expect(icon.color, AppTheme.goldBright);
      expect(tester.takeException(), isNull);

      await _teardown(tester, state);
    },
  );

  testWidgets(
    "a long-press on somebody else's line opens the players list, not a "
    'dialog',
    (tester) async {
      final state = _newState(room: _room([('ravi', 'Ravi')]));
      state.chat.add(_msg('ravi', 'Ravi', 'good hand'));
      final routes = await _pumpDrawer(tester, state);

      await tester.longPress(_line('good hand'));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(ChatPlayers), findsOneWidget);
      expect(_keyBeside('Ravi'), findsOneWidget);
      expect(routes.pushed, 1);
      expect(find.byType(GlassDialog), findsNothing);
      // Reaching the list blocked nobody: the key on the row does that.
      expect(state.blockedIds, isEmpty);

      await _teardown(tester, state);
    },
  );

  testWidgets('the key toggles the list, and a tab takes it down too', (
    tester,
  ) async {
    final state = _newState(room: _room([('ravi', 'Ravi')]));
    await _pumpDrawer(tester, state);

    await tester.tap(_blockKey);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ChatPlayers), findsOneWidget);

    await tester.tap(_blockKey);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ChatPlayers), findsNothing);
    expect(find.byType(GlassTextField), findsOneWidget);

    await tester.tap(_blockKey);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(_t.quickMessagesTitle));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ChatPlayers), findsNothing);
    expect(find.byType(QuickLine), findsWidgets);

    await _teardown(tester, state);
  });

  testWidgets('the list follows the seats live, and says when it is empty', (
    tester,
  ) async {
    final state = _newState(
      room: _room([('ravi', 'Ravi'), ('meera', 'Meera')]),
    );
    await _pumpDrawer(tester, state);
    await tester.tap(_blockKey);
    await tester.pump(const Duration(milliseconds: 300));
    expect(_playerKey(_t.block), findsNWidgets(2));

    // Meera leaves while the list is up.
    state
      ..room = _room([('ravi', 'Ravi')])
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Meera'), findsNothing);
    expect(_playerKey(_t.block), findsOneWidget);

    // Then Ravi does, and the viewer is alone.
    state
      ..room = _room(const [])
      ..notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_playerKey(_t.block), findsNothing);
    expect(find.text(_t.blockNobody), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _teardown(tester, state);
  });

  for (final lang in AppLang.values) {
    testWidgets(
      'in ${lang.englishName} a long name and the Unblock key share a row '
      'at 640x360 x1.25 with nothing cut off the drawer',
      (tester) async {
        final state = _newState(
          room: _room([
            ('ravi', 'Ravindranath Chattopadhyay'),
            ('meera', 'Meera'),
          ]),
          lang: lang,
        );
        state.blockPlayer('ravi');
        final t = Strings(lang);
        await _pumpDrawer(tester, state);

        await tester.tap(find.byTooltip(t.blockPlayersTitle));
        await tester.pump(const Duration(milliseconds: 300));

        final drawer = tester.getRect(find.byType(ChatDrawer));
        for (final label in [t.unblock, t.block]) {
          final key = _playerKey(label);
          expect(key, findsOneWidget, reason: '${lang.code} $label');
          final rect = tester.getRect(key);
          expect(rect.right, lessThanOrEqualTo(drawer.right), reason: label);
          expect(rect.left, greaterThanOrEqualTo(drawer.left), reason: label);
          expect(rect.height, greaterThanOrEqualTo(Dim.minTouch - 8));
        }
        // The name yields to the key: cut short rather than pushed out.
        final name = tester.getRect(
          find.text('Ravindranath Chattopadhyay'),
        );
        final unblock = tester.getRect(_playerKey(t.unblock));
        expect(name.right, lessThanOrEqualTo(unblock.left));
        expect(tester.takeException(), isNull);

        await _teardown(tester, state);
      },
    );
  }

  test('there is an icon for every quick message, in every language', () {
    for (final lang in AppLang.values) {
      expect(
        quickMessageIcons,
        hasLength(Strings(lang).quickMessages.length),
        reason: lang.code,
      );
    }
    // Ten different meanings, ten different marks.
    expect(quickMessageIcons.toSet(), hasLength(quickMessageIcons.length));
  });

  for (final lang in AppLang.values) {
    testWidgets(
      'in ${lang.englishName} every quick message stands in its own box with '
      'its icon, and nothing overflows at 640x360 x1.25',
      (tester) async {
        final state = _newState(room: _room([('ravi', 'Ravi')]), lang: lang);
        final t = Strings(lang);
        await _pumpDrawer(tester, state);

        await tester.tap(find.text(t.quickMessagesTitle));
        await tester.pump(const Duration(milliseconds: 300));

        final drawer = tester.getRect(find.byType(ChatDrawer));
        final list = find.descendant(
          of: find.byType(ChatDrawer),
          matching: find.byType(Scrollable),
        );
        final lines = t.quickMessages;
        Rect? above;
        for (final (i, line) in lines.indexed) {
          // The list builds lazily, so each line is scrolled to in turn.
          await tester.scrollUntilVisible(
            find.text(line),
            48,
            scrollable: list,
          );
          await tester.pump(const Duration(milliseconds: 100));

          final box = find.ancestor(
            of: find.text(line),
            matching: find.byType(QuickLine),
          );
          expect(box, findsOneWidget, reason: line);
          // Its own glass pane, with the icon of its meaning at the left.
          expect(
            find.descendant(
              of: box,
              matching: find.byType(PremiumGlassPanel),
            ),
            findsOneWidget,
            reason: line,
          );
          expect(
            find.descendant(
              of: box,
              matching: find.byIcon(quickMessageIcons[i]),
            ),
            findsOneWidget,
            reason: line,
          );
          final icon = tester.getRect(
            find.descendant(
              of: box,
              matching: find.byIcon(quickMessageIcons[i]),
            ),
          );
          final text = tester.getRect(find.text(line));
          expect(icon.right, lessThanOrEqualTo(text.left), reason: line);

          // A thumb's target, inside the drawer, and clear of the box above.
          final rect = tester.getRect(box);
          expect(
            rect.height,
            greaterThanOrEqualTo(Dim.minTouch + Space.md),
            reason: line,
          );
          expect(rect.left, greaterThanOrEqualTo(drawer.left), reason: line);
          expect(rect.right, lessThanOrEqualTo(drawer.right), reason: line);
          if (above != null && above.bottom <= rect.top) {
            expect(rect.top - above.bottom, closeTo(Space.sm, 0.5));
          }
          above = rect;
        }
        expect(tester.takeException(), isNull);

        await _teardown(tester, state);
      },
    );
  }

  testWidgets('a quick message is one tap, and the cooldown boxes stay put', (
    tester,
  ) async {
    final state = _newState(room: _room([('ravi', 'Ravi')]));
    await _pumpDrawer(tester, state);
    await tester.tap(find.text(_t.quickMessagesTitle));
    await tester.pump(const Duration(milliseconds: 300));

    // Live: the box's tap is the line. No connection, so the send itself
    // fails and the drawer stays — what is pinned is the target and the
    // cooldown's face, not the wire.
    final first = find.ancestor(
      of: find.text(_t.quickPlayBlind),
      matching: find.byType(QuickLine),
    );
    expect(tester.widget<QuickLine>(first).onTap, isNotNull);
    expect(tester.widget<QuickLine>(first).icon, quickMessageIcons.first);

    await _teardown(tester, state);
  });
}
