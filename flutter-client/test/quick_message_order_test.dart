// The player's own order for the chat drawer's quick messages (owner, 25 Sep
// 2026: "make sure user can drag and reorder the quick message in UI, This is
// UI change only and save that order in UI only").
//
// The rules are pure functions and are held here first; then the drawer is
// mounted for real on the 640x360 phone at the 1.25 text ceiling and a line is
// dragged by its grip and by a long-press, and the order is read back from
// what the phone saved.
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/quick_message_order.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

RoomState _room() => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': 'seen',
  'state': 'waiting',
  'handNo': 1,
  'dealerSeat': 0,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 0,
  'maxPot': 0,
  'stake': 200,
  'you': {
    'seatIndex': 0,
    'chips': 200000,
    'status': 'waiting',
    'isBlind': true,
    'contributed': 0,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': <String>[],
  },
  'seats': [
    {
      'seatIndex': 0,
      'userId': 'me',
      'displayName': 'You',
      'chips': 200000,
      'status': 'waiting',
      'isBlind': true,
      'connected': true,
      'cardCount': 0,
    },
  ],
});

GameState _newState({AppLang lang = AppLang.english}) {
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
    ..room = _room()
    ..screen = Screen.table;
}

Future<void> _pumpQuickPage(WidgetTester tester, GameState state) async {
  tester.view.physicalSize = const Size(640, 360);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.25;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
        theme: AppTheme.dark(sound: false),
        builder: (context, child) => GlassBudget(child: child!),
        home: const Scaffold(
          backgroundColor: Colors.transparent,
          body: ChatDrawer(),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(find.text(state.t.quickMessagesTitle));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _teardown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

/// The box that says [line].
Finder _box(String line) =>
    find.ancestor(of: find.text(line), matching: find.byType(QuickLine));

/// The grip of the box that says [line].
Finder _grip(String line) =>
    find.descendant(of: _box(line), matching: find.byType(QuickDragHandle));

/// The lines in the order the drawer shows them, top to bottom, of those on
/// screen.
List<String> _shown(WidgetTester tester) {
  final boxes = tester.widgetList<QuickLine>(find.byType(QuickLine)).toList()
    ..sort(
      (a, b) => tester
          .getTopLeft(find.byWidget(a))
          .dy
          .compareTo(tester.getTopLeft(find.byWidget(b)).dy),
    );
  return [for (final b in boxes) b.text];
}

/// Drags [from] by [dy] the way a finger does: down, a few steps, up.
Future<void> _drag(WidgetTester tester, Finder from, double dy) async {
  final gesture = await tester.startGesture(tester.getCenter(from));
  await tester.pump(const Duration(milliseconds: 50));
  for (var i = 0; i < 10; i++) {
    await gesture.moveBy(Offset(0, dy / 10));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await _settleDrop(tester);
}

/// Frames until a dropped box has come to rest and the list has reported the
/// move — frame by frame, since one long pump runs the drop animation's ticker
/// once and the move is reported only when it finishes.
Future<void> _settleDrop(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

const _en = Strings(AppLang.english);

void main() {
  group('the order rules', () {
    test('nothing saved is the owner\'s order', () {
      expect(normaliseQuickOrder(const [], 4), [0, 1, 2, 3]);
    });

    test('a saved order is kept, and lines it does not name follow it', () {
      expect(normaliseQuickOrder(const [3, 1], 5), [3, 1, 0, 2, 4]);
      expect(normaliseQuickOrder(const [2, 0, 1], 3), [2, 0, 1]);
    });

    test('a line a later build dropped, or one named twice, is skipped', () {
      expect(normaliseQuickOrder(const [9, 1, 1, -1, 0], 3), [1, 0, 2]);
    });

    test('the result is always every line exactly once', () {
      for (final saved in [
        const <int>[],
        const [4, 4, 4],
        const [7, 6, 5, 4, 3, 2, 1, 0],
        const [0, 2, 99],
      ]) {
        final order = normaliseQuickOrder(saved, 5);
        expect(order.toSet(), {0, 1, 2, 3, 4}, reason: '$saved');
        expect(order, hasLength(5), reason: '$saved');
      }
    });

    test('a move lands the line at the place it was dropped', () {
      // Down: the first line to the third place.
      expect(moveInQuickOrder(const [0, 1, 2, 3], 0, 2), [1, 2, 0, 3]);
      // Up: the last line to the top.
      expect(moveInQuickOrder(const [0, 1, 2, 3], 3, 0), [3, 0, 1, 2]);
      // Nowhere.
      expect(moveInQuickOrder(const [0, 1, 2, 3], 1, 1), [0, 1, 2, 3]);
      // Past the end is the end.
      expect(moveInQuickOrder(const [0, 1, 2], 0, 9), [1, 2, 0]);
    });

    test('what is read back is only whole numbers, and round-trips', () {
      expect(parseQuickOrder(null), isEmpty);
      expect(parseQuickOrder(const ['2', 'x', '', '0', '1.5']), [2, 0]);
      expect(parseQuickOrder(encodeQuickOrder(const [4, 0, 3])), [4, 0, 3]);
    });
  });

  group('GameState', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('keeps the order in indices, so it holds in every language', () async {
      final state = _newState();
      await state.moveQuickMessage(9, 0);
      expect(state.quickMessageOrder, [9, 0, 1, 2, 3, 4, 5, 6, 7, 8]);
      expect(
        state.t.quickMessages[state.quickMessageOrder.first],
        _en.quickHelpMe,
      );

      state.lang = AppLang.hindi;
      final hindi = Strings(AppLang.hindi);
      expect(
        state.t.quickMessages[state.quickMessageOrder.first],
        hindi.quickHelpMe,
      );
      state.dispose();
    });

    test(
      'saves the order on the phone, and a launch takes it up again',
      () async {
        final state = _newState();
        await state.moveQuickMessage(0, 3);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList(quickOrderPrefsKey), [
          '1',
          '2',
          '3',
          '0',
          '4',
          '5',
          '6',
          '7',
          '8',
          '9',
        ]);
        state.dispose();

        final next = _newState();
        expect(next.quickMessageOrder.first, 0);
        next.restoreQuickOrder(prefs);
        expect(next.quickMessageOrder, [1, 2, 3, 0, 4, 5, 6, 7, 8, 9]);
        next.dispose();
      },
    );

    test('a move to where the line already is writes nothing', () async {
      final state = _newState();
      var told = 0;
      state.addListener(() => told++);
      await state.moveQuickMessage(2, 2);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList(quickOrderPrefsKey), isNull);
      expect(told, 0);
      state.dispose();
    });
  });

  group('the drawer', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets(
      'every quick message has a grip, and a tap on it says nothing',
      (tester) async {
        var said = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(sound: false),
            home: Scaffold(
              body: GlassBudget(
                child: QuickLine(
                  text: 'Please Play Blind.',
                  icon: Icons.visibility_off_rounded,
                  secondsLeft: 0,
                  onTap: () => said++,
                  reorder: (index: 0, label: 'Hold and drag'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(QuickDragHandle));
        await tester.pump(const Duration(milliseconds: 300));
        expect(said, 0);
        await tester.tap(find.text('Please Play Blind.'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(said, 1);
      },
    );

    testWidgets(
      'dragging a line by its grip moves it, its icon with it, and the phone '
      'keeps the order',
      (tester) async {
        final state = _newState();
        await _pumpQuickPage(tester, state);
        expect(find.byType(QuickDragHandle), findsWidgets);
        expect(_shown(tester).take(3), [
          _en.quickPlayBlind,
          _en.quickPlayFast,
          _en.quickHowToWin,
        ]);

        // The second line, up above the first. (Upwards, from a list already
        // at its top: a drop near the foot of a list this short would scroll
        // it on the way, and the third box is only half on screen.)
        final first = tester.getRect(_box(_en.quickPlayBlind));
        final second = tester.getRect(_box(_en.quickPlayFast));
        await _drag(
          tester,
          _grip(_en.quickPlayFast),
          first.top - second.center.dy - 8,
        );

        expect(state.quickMessageOrder.take(3), [1, 0, 2]);
        expect(_shown(tester).take(2), [_en.quickPlayFast, _en.quickPlayBlind]);
        // The icon belongs to the line, not the place.
        expect(
          tester.widget<QuickLine>(_box(_en.quickPlayFast)).icon,
          quickMessageIcons[1],
        );
        final prefs = await SharedPreferences.getInstance();
        expect(
          parseQuickOrder(prefs.getStringList(quickOrderPrefsKey)).take(3),
          [1, 0, 2],
        );
        expect(tester.takeException(), isNull);

        await _teardown(tester, state);
      },
    );

    testWidgets('a long-press anywhere on a box drags it too', (tester) async {
      final state = _newState();
      await _pumpQuickPage(tester, state);

      final second = tester.getRect(_box(_en.quickPlayFast));
      final first = tester.getRect(_box(_en.quickPlayBlind));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(_en.quickPlayFast)),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(
          Offset(0, (first.top - second.center.dy - 8) / 10),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await _settleDrop(tester);

      expect(state.quickMessageOrder.take(2), [1, 0]);
      expect(tester.takeException(), isNull);

      await _teardown(tester, state);
    });

    testWidgets('a saved order is the order the drawer opens in', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        quickOrderPrefsKey: ['9', '8'],
      });
      final state = _newState();
      state.restoreQuickOrder(await SharedPreferences.getInstance());
      await _pumpQuickPage(tester, state);

      expect(_shown(tester).take(3), [
        _en.quickHelpMe,
        _en.quickSwitchTable,
        _en.quickPlayBlind,
      ]);

      await _teardown(tester, state);
    });
  });
}
