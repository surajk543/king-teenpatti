// The chat drawer's quick messages as the player arranges them (owner, 25 Sep
// 2026: "make sure user can drag and reorder the quick message in UI, This is
// UI change only and save that order in UI only", then "Add a button in quick
// message drawer so that when user clicks and type and save that typed message
// will be seen in quick message list, add icon in custom saved quick message
// … when user restart the app, make sure ordering and custom message should be
// preserved in phone").
//
// The rules are pure functions and are held here first; then GameState keeps
// and restores them; then the drawer is mounted for real on the 640x360 phone
// at the 1.25 text ceiling, a line is dragged by its grip and by a long-press,
// a line of the player's own is written, saved and deleted, and a "restart" —
// a new GameState reading what the phone saved — finds all of it again.
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

/// A fresh GameState that takes up what the phone saved, as a launch does.
Future<GameState> _relaunch() async {
  final state = _newState();
  state.restoreQuickOrder(await SharedPreferences.getInstance());
  return state;
}

/// The keys of the ten set lines, in the owner's order.
final _owners = [for (var i = 0; i < 10; i++) '$i'];

void main() {
  group('the order rules', () {
    test("nothing saved is the owner's order", () {
      expect(normaliseQuickOrder(const [], 4, const []), ['0', '1', '2', '3']);
    });

    test('a saved order is kept, and lines it does not name follow it', () {
      expect(normaliseQuickOrder(const ['3', '1'], 5, const []), [
        '3',
        '1',
        '0',
        '2',
        '4',
      ]);
      expect(normaliseQuickOrder(const ['c:a', '1'], 2, const ['a', 'b']), [
        'c:a',
        '1',
        '0',
        'c:b',
      ]);
    });

    test('an order saved before there were lines of their own still reads', () {
      // The first build of the reorder saved the set lines' indices alone.
      expect(normaliseQuickOrder(const ['2', '0'], 3, const ['x']), [
        '2',
        '0',
        '1',
        'c:x',
      ]);
    });

    test('a key naming no line, or named twice, is skipped', () {
      expect(
        normaliseQuickOrder(
          const ['9', '1', '1', '-1', 'c:gone', 'c:', 'junk', '0'],
          3,
          const ['kept'],
        ),
        ['1', '0', '2', 'c:kept'],
      );
    });

    test('the result is always every line exactly once', () {
      for (final saved in [
        const <String>[],
        const ['4', '4', 'c:a', 'c:a'],
        const ['7', '6', '5', '4', '3', '2', '1', '0'],
        const ['0', '2', '99', 'c:zz'],
      ]) {
        final order = normaliseQuickOrder(saved, 5, const ['a', 'b']);
        expect(order.toSet(), {
          '0',
          '1',
          '2',
          '3',
          '4',
          'c:a',
          'c:b',
        }, reason: '$saved');
        expect(order, hasLength(7), reason: '$saved');
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

    test('keys say which line they name', () {
      expect(builtInIndexOf(builtInQuickKey(7)), 7);
      expect(customIdOf(builtInQuickKey(7)), isNull);
      expect(customIdOf(customQuickKey('abc')), 'abc');
      expect(builtInIndexOf(customQuickKey('12')), isNull);
      expect(parseQuickOrder(const ['2', '', 'c:a']), ['2', 'c:a']);
      expect(parseQuickOrder(null), isEmpty);
    });

    test('lines of their own round-trip, and a broken save reads as none', () {
      const lines = [
        CustomQuickMessage(id: 'a', text: 'Good game!'),
        CustomQuickMessage(id: 'b', text: 'बहुत बढ़िया'),
      ];
      final back = decodeCustomQuickMessages(encodeCustomQuickMessages(lines));
      expect(
        [for (final l in back) (l.id, l.text)],
        [('a', 'Good game!'), ('b', 'बहुत बढ़िया')],
      );
      expect(decodeCustomQuickMessages(null), isEmpty);
      expect(decodeCustomQuickMessages('not json'), isEmpty);
      expect(decodeCustomQuickMessages('{"id":"a"}'), isEmpty);
      // A broken entry and a repeated id are dropped; the rest is kept.
      expect(
        decodeCustomQuickMessages(
          '[{"id":"a","text":"hi"},{"id":7},{"id":"a","text":"again"},'
          '{"id":"b","text":"   "},{"id":"c","text":"ok"}]',
        ).map((l) => l.id),
        ['a', 'c'],
      );
    });

    test('a line is kept as the server will read it, whole', () {
      expect(cleanQuickMessage('  Nice\tone \n  mate  '), 'Nice one mate');
      expect(cleanQuickMessage('मद‌द'), 'मद द');
      expect(cleanQuickMessage('   '), isEmpty);
      final long = cleanQuickMessage('x' * 200);
      expect(long.length, customQuickMessageMaxLength);
      // Never cut between the two halves of one character.
      final emoji = cleanQuickMessage('${'a' * 139}😀');
      expect(emoji, 'a' * 139);
    });
  });

  group('GameState', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('keeps the order in keys, so it holds in every language', () async {
      final state = _newState();
      await state.moveQuickMessage(9, 0);
      expect(state.quickMessageOrder, ['9', ..._owners.take(9)]);
      expect(state.quickMessageEntries.first.text, _en.quickHelpMe);

      state.lang = AppLang.hindi;
      expect(
        state.quickMessageEntries.first.text,
        const Strings(AppLang.hindi).quickHelpMe,
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
          ..._owners.skip(4),
        ]);
        state.dispose();

        final next = await _relaunch();
        expect(next.quickMessageOrder, [
          '1',
          '2',
          '3',
          '0',
          ..._owners.skip(4),
        ]);
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

    test("a line of the player's own goes to the top, and a launch finds it "
        'and the order', () async {
      final state = _newState();
      await state.moveQuickMessage(9, 0);
      expect(
        await state.addCustomQuickMessage('  Well   played!  '),
        QuickAddResult.added,
      );
      final own = state.customQuickMessages.single;
      expect(own.text, 'Well played!');
      expect(state.quickMessageEntries.first, (
        key: customQuickKey(own.id),
        text: 'Well played!',
        builtIn: null,
        customId: own.id,
      ));
      // Moved after it was added: the order is the player's, their own
      // line included.
      await state.moveQuickMessage(0, 2);
      final order = state.quickMessageOrder;
      expect(order.take(3), ['9', '0', customQuickKey(own.id)]);
      state.dispose();

      final next = await _relaunch();
      expect(next.customQuickMessages.single.text, 'Well played!');
      expect(next.quickMessageOrder, order);
      expect(next.quickMessageEntries[2].text, 'Well played!');
      next.dispose();
    });

    test(
      'a line that says nothing, or what the list already says, is refused',
      () async {
        final state = _newState();
        expect(await state.addCustomQuickMessage('   '), QuickAddResult.empty);
        expect(
          await state.addCustomQuickMessage(_en.quickTakeShow),
          QuickAddResult.duplicate,
        );
        await state.addCustomQuickMessage('Hurry up');
        expect(
          await state.addCustomQuickMessage(' Hurry  up '),
          QuickAddResult.duplicate,
        );
        expect(state.customQuickMessages, hasLength(1));
        state.dispose();
      },
    );

    test(
      'a player keeps at most $maxCustomQuickMessages of their own',
      () async {
        final state = _newState();
        for (var i = 0; i < maxCustomQuickMessages; i++) {
          expect(
            await state.addCustomQuickMessage('Line $i'),
            QuickAddResult.added,
          );
        }
        expect(
          await state.addCustomQuickMessage('One more'),
          QuickAddResult.full,
        );
        expect(state.customQuickMessages, hasLength(maxCustomQuickMessages));
        expect(state.quickMessageOrder, hasLength(10 + maxCustomQuickMessages));
        // The newest first.
        expect(state.quickMessageEntries.first.text, 'Line 9');
        state.dispose();
      },
    );

    test('a deleted line is gone from the list and from the phone', () async {
      final state = _newState();
      await state.addCustomQuickMessage('Keep me');
      await state.addCustomQuickMessage('Delete me');
      final gone = state.customQuickMessages.last.id;
      await state.removeCustomQuickMessage(gone);
      expect(state.customQuickMessages.map((l) => l.text), ['Keep me']);
      expect(state.quickMessageOrder, isNot(contains(customQuickKey(gone))));
      state.dispose();

      final next = await _relaunch();
      expect(next.customQuickMessages.map((l) => l.text), ['Keep me']);
      expect(next.quickMessageOrder, hasLength(11));
      expect(next.quickMessageEntries.first.text, 'Keep me');
      next.dispose();
    });

    test('the full-list note names the same limit the code keeps', () {
      for (final lang in AppLang.values) {
        expect(
          Strings(lang).quickCustomFull,
          contains('$maxCustomQuickMessages'),
          reason: lang.code,
        );
      }
    });
  });

  group('the drawer', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets(
      'a tap on the grip or the bin says nothing; a tap on the words does',
      (tester) async {
        var said = 0;
        var deleted = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(sound: false),
            home: Scaffold(
              body: GlassBudget(
                child: QuickLine(
                  text: 'Good game!',
                  icon: customQuickMessageIcon,
                  secondsLeft: 0,
                  onTap: () => said++,
                  reorder: (index: 0, label: 'Hold and drag'),
                  onDelete: () => deleted++,
                  deleteLabel: 'Delete message',
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(QuickDragHandle));
        await tester.pump(const Duration(milliseconds: 300));
        expect(said, 0);
        await tester.tap(find.byType(QuickDeleteKey));
        await tester.pump(const Duration(milliseconds: 300));
        expect((said, deleted), (0, 1));
        await tester.tap(find.text('Good game!'));
        await tester.pump(const Duration(milliseconds: 300));
        expect((said, deleted), (1, 1));
      },
    );

    testWidgets('a set line has no bin', (tester) async {
      final state = _newState();
      await _pumpQuickPage(tester, state);
      expect(find.byType(QuickDragHandle), findsWidgets);
      expect(find.byType(QuickDeleteKey), findsNothing);
      await _teardown(tester, state);
    });

    testWidgets(
      'dragging a line by its grip moves it, its icon with it, and the phone '
      'keeps the order',
      (tester) async {
        final state = _newState();
        await _pumpQuickPage(tester, state);
        expect(_shown(tester).take(2), [_en.quickPlayBlind, _en.quickPlayFast]);

        // The second line, up above the first. (Upwards, from a list already
        // at its top: a drop near the foot of a list this short would scroll
        // it on the way.)
        final first = tester.getRect(_box(_en.quickPlayBlind));
        final second = tester.getRect(_box(_en.quickPlayFast));
        await _drag(
          tester,
          _grip(_en.quickPlayFast),
          first.top - second.center.dy - 8,
        );

        expect(state.quickMessageOrder.take(3), ['1', '0', '2']);
        expect(_shown(tester).take(2), [_en.quickPlayFast, _en.quickPlayBlind]);
        // The icon belongs to the line, not the place.
        expect(
          tester.widget<QuickLine>(_box(_en.quickPlayFast)).icon,
          quickMessageIcons[1],
        );
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getStringList(quickOrderPrefsKey)!.take(3), [
          '1',
          '0',
          '2',
        ]);
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

      expect(state.quickMessageOrder.take(2), ['1', '0']);
      expect(tester.takeException(), isNull);

      await _teardown(tester, state);
    });

    testWidgets('a saved order is the order the drawer opens in', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        quickOrderPrefsKey: ['9', '8'],
      });
      final state = await _relaunch();
      await _pumpQuickPage(tester, state);

      expect(_shown(tester).take(3), [
        _en.quickHelpMe,
        _en.quickSwitchTable,
        _en.quickPlayBlind,
      ]);

      await _teardown(tester, state);
    });

    testWidgets(
      'Add message: typed and saved, the line is at the top with its mark, '
      'and after a restart it is still there, in its place',
      (tester) async {
        final state = _newState();
        await _pumpQuickPage(tester, state);

        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.text(_en.quickAddMessage));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(TextField), findsOneWidget);

        await tester.enterText(
          find.byType(TextField),
          'Nice hand, well played',
        );
        await tester.tap(find.byTooltip(_en.save));
        await _settleDrop(tester);

        // Saved: the field has gone, and the line heads the list with the
        // mark of a line of the player's own, a bin and a grip.
        expect(find.byType(TextField), findsNothing);
        expect(find.text(_en.quickAddMessage), findsOneWidget);
        expect(_shown(tester).first, 'Nice hand, well played');
        final own = _box('Nice hand, well played');
        expect(tester.widget<QuickLine>(own).icon, customQuickMessageIcon);
        expect(
          find.descendant(
            of: own,
            matching: find.byIcon(customQuickMessageIcon),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: own, matching: find.byType(QuickDeleteKey)),
          findsOneWidget,
        );
        expect(
          tester.widget<QuickLine>(own).onTap,
          isNotNull,
          reason: 'a line of their own is said with one tap, like any other',
        );
        expect(tester.takeException(), isNull);
        await _teardown(tester, state);

        // The app is closed and opened again.
        final next = await _relaunch();
        await _pumpQuickPage(tester, next);
        expect(_shown(tester).first, 'Nice hand, well played');
        expect(
          tester.widget<QuickLine>(_box('Nice hand, well played')).icon,
          customQuickMessageIcon,
        );
        await _teardown(tester, next);
      },
    );

    testWidgets('Cancel leaves the list as it was', (tester) async {
      final state = _newState();
      await _pumpQuickPage(tester, state);
      await tester.tap(find.text(_en.quickAddMessage));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField), 'Never mind');
      await tester.tap(find.byTooltip(_en.cancel));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(TextField), findsNothing);
      expect(state.customQuickMessages, isEmpty);
      expect(find.text('Never mind'), findsNothing);
      await _teardown(tester, state);
    });

    testWidgets('a line the list already says is refused with a note', (
      tester,
    ) async {
      final state = _newState();
      await _pumpQuickPage(tester, state);
      await tester.tap(find.text(_en.quickAddMessage));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField), _en.quickPlayFast);
      await tester.tap(find.byTooltip(_en.save));
      await tester.pump(const Duration(milliseconds: 300));

      expect(state.notice, _en.quickCustomDuplicate);
      // The field stays, words and all, for the player to change.
      expect(find.byType(TextField), findsOneWidget);
      expect(state.customQuickMessages, isEmpty);
      await _teardown(tester, state);
    });

    testWidgets('with the list full, Add message says so and opens nothing', (
      tester,
    ) async {
      final state = _newState();
      for (var i = 0; i < maxCustomQuickMessages; i++) {
        await state.addCustomQuickMessage('Mine $i');
      }
      await _pumpQuickPage(tester, state);
      await tester.tap(find.text(_en.quickAddMessage));
      await tester.pump(const Duration(milliseconds: 300));

      expect(state.notice, _en.quickCustomFull);
      expect(find.byType(TextField), findsNothing);
      await _teardown(tester, state);
    });

    testWidgets('the bin takes a line of their own away, for good', (
      tester,
    ) async {
      final state = _newState();
      await state.addCustomQuickMessage('Too slow');
      await _pumpQuickPage(tester, state);
      expect(_shown(tester).first, 'Too slow');

      await tester.tap(
        find.descendant(
          of: _box('Too slow'),
          matching: find.byType(QuickDeleteKey),
        ),
      );
      await _settleDrop(tester);

      expect(find.text('Too slow'), findsNothing);
      expect(_shown(tester).first, _en.quickPlayBlind);
      expect(state.notice, isNull, reason: 'nothing was said to the table');
      await _teardown(tester, state);

      final next = await _relaunch();
      expect(next.customQuickMessages, isEmpty);
      next.dispose();
    });

    for (final lang in AppLang.values) {
      testWidgets(
        'in ${lang.englishName} the Add key, the field and a line of their own '
        'fit the drawer at 640x360 x1.25',
        (tester) async {
          final state = _newState(lang: lang);
          final t = Strings(lang);
          await state.addCustomQuickMessage(
            'A rather long message of my own that wraps onto a second line',
          );
          await _pumpQuickPage(tester, state);

          final drawer = tester.getRect(find.byType(ChatDrawer));
          final add = tester.getRect(find.text(t.quickAddMessage));
          expect(add.left, greaterThanOrEqualTo(drawer.left));
          expect(add.right, lessThanOrEqualTo(drawer.right));
          expect(add.bottom, lessThanOrEqualTo(drawer.bottom));
          final own = tester.getRect(
            _box(
              'A rather long message of my own that wraps onto a second line',
            ),
          );
          expect(own.right, lessThanOrEqualTo(drawer.right));

          await tester.tap(find.text(t.quickAddMessage));
          await tester.pump(const Duration(milliseconds: 300));
          final field = tester.getRect(find.byType(TextField));
          final save = tester.getRect(find.byTooltip(t.save));
          final cancel = tester.getRect(find.byTooltip(t.cancel));
          expect(field.right, lessThanOrEqualTo(save.left));
          expect(save.right, lessThanOrEqualTo(cancel.left));
          expect(cancel.right, lessThanOrEqualTo(drawer.right));
          expect(tester.takeException(), isNull);

          await _teardown(tester, state);
        },
      );
    }
  });
}
