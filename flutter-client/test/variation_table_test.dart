// A variation table, as the client sees it.
//
// The server deals the hand and then waits up to ten seconds for ONE player —
// the one who would have acted first — to choose the rules it is played under.
// Everything the client draws of that comes from the `variation` block of the
// table snapshot: the chooser's six keys and their clock, everyone else's
// "… is selecting variation", the announcement once it closes, and the tag
// that names the variation for the rest of the hand and through the showdown.
//
// A seen or blind table carries no such block, and nothing here may change
// what those tables draw.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/variation_prompt.dart';

const _ids = ['u0', 'u1', 'u2', 'u3', 'u4'];

int get _now => DateTime.now().millisecondsSinceEpoch;

/// The snapshot's variation block with the window open for [chooser].
Map<String, dynamic> _selecting(String chooser, {int? deadline}) => {
  'selecting': true,
  'userId': chooser,
  'displayName': 'Player ${chooser.substring(1)}',
  'seatIndex': _ids.indexOf(chooser),
  'startedAt': _now,
  'deadline': deadline ?? _now + 10000,
  'timeoutMs': 10000,
  'options': Variation.all,
  'selected': null,
  'selectedBy': null,
};

/// The same block once the window has closed.
Map<String, dynamic> _selected(
  String chooser,
  String variation, {
  String by = VariationSelectedBy.player,
  String? turnUp,
}) => {
  ..._selecting(chooser),
  'selecting': false,
  'selected': variation,
  'selectedBy': by,
  'turnUp': ?turnUp,
};

/// A table of five with the viewer (u0) in seat 0. [variation] is the
/// snapshot's block, left out entirely when null — as the server leaves it
/// out on seen and blind tables and between hands.
RoomState _room({
  String category = 'variation',
  Object? variation,
  int handNo = 4,
  String state = 'betting',
  String? turn,
  String roomId = 'r1',
}) => RoomState.fromJson({
  'roomId': roomId,
  'code': 'ABCD2345',
  'category': category,
  'chipsHidden': false,
  'state': state,
  'handNo': handNo,
  'dealerSeat': 4,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 1000,
  'maxPot': 2000000,
  'stake': 200,
  // Nobody is on turn while the window is open.
  'turn': turn == null
      ? {'seatIndex': -1, 'userId': null, 'deadline': 0}
      : {
          'seatIndex': _ids.indexOf(turn),
          'userId': turn,
          'deadline': _now + 25000,
        },
  'variation': ?variation,
  'you': {
    'seatIndex': 0,
    'chips': 200000,
    'status': 'active',
    'isBlind': true,
    'blindMovesLeft': 4,
    'contributed': 200,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': const <String>[],
  },
  'seats': [
    for (final (i, id) in _ids.indexed)
      {
        'seatIndex': i,
        'userId': id,
        'displayName': 'Player $i',
        'avatarUrl': null,
        'chips': 200000,
        'status': 'active',
        'isBlind': true,
        'lastBet': 200,
        'lastAction': 'boot',
        'contributed': 200,
        'connected': true,
        'cardCount': 3,
      },
  ],
});

GameState _newState({RoomState? room}) {
  // Play is never started here; the override only keeps the purchase plugin
  // from registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  state
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Player 0',
      'chips': 200000,
      'diamond': 2,
      'hammer': 20,
      'missile': 1,
    })
    ..room = room
    ..screen = Screen.table;
  return state;
}

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

Future<void> _pumpTable(
  WidgetTester tester,
  GameState state, {
  Size screen = const Size(891, 411),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
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
        home: const TableScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

/// Takes the table down and lets every timer it scheduled run out.
Future<void> _teardown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

/// The picker's keys, whichever variations they are for.
Finder get _optionKeys => find.byWidgetPredicate((w) {
  final key = w.key;
  return key is ValueKey<String> && key.value.startsWith('variation-option-');
});

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

SeatPod _podOf(WidgetTester tester, String userId) => tester.widget<SeatPod>(
  find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId),
);

void main() {
  setUpAll(_loadInter);

  group('the snapshot', () {
    test('with a window open says who is choosing, until when, from what', () {
      final v = _room(variation: _selecting('u2')).variation!;
      expect(v.selecting, isTrue);
      expect(v.userId, 'u2');
      expect(v.displayName, 'Player 2');
      expect(v.seatIndex, 2);
      expect(v.timeoutMs, 10000);
      expect(v.options, Variation.all);
      expect(v.selected, isNull);
      expect(v.selectedBy, isNull);
      expect(v.turnUp, isNull);
      expect(v.chosenByServer, isFalse);
      expect(v.secondsLeft, inInclusiveRange(9, 10));
    });

    test('with the window closed says what was chosen and by whom', () {
      final v = _room(
        variation: _selected('u2', Variation.hukam, turnUp: '9h'),
      ).variation!;
      expect(v.selecting, isFalse);
      expect(v.userId, 'u2', reason: 'still the chooser');
      expect(v.selected, Variation.hukam);
      expect(v.selectedBy, VariationSelectedBy.player);
      expect(v.turnUp, '9h');
      expect(v.secondsLeft, 0);

      for (final by in [
        VariationSelectedBy.timeout,
        VariationSelectedBy.left,
      ]) {
        final auto = _room(
          variation: _selected('u2', Variation.muflis, by: by),
        ).variation!;
        expect(auto.chosenByServer, isTrue, reason: by);
      }
    });

    test('of a seen or blind table carries none', () {
      for (final category in ['seen', 'blind']) {
        expect(_room(category: category).variation, isNull, reason: category);
      }
    });

    test('with a malformed block reads as none, and never throws', () {
      for (final bad in <Object>[
        'AK47',
        ['MUFLIS'],
        7,
        true,
      ]) {
        expect(_room(variation: bad).variation, isNull, reason: '$bad');
      }
      // An explicit null, which the server never sends but JSON allows.
      final json = {'variation': null};
      expect(RoomState.fromJson(json).variation, isNull);
    });

    test('with a block of the wrong types inside falls back, not over', () {
      final v = _room(
        variation: {
          'selecting': 'yes',
          'userId': 7,
          'seatIndex': 'two',
          'deadline': 'soon',
          // No menu at all. (A menu that is not a list — 'options': 'MUFLIS'
          // — throws in VariationState.fromJson's `as List?`, as every list
          // in dtos.dart does; the server never sends one.)
          'selected': 3,
          'turnUp': ['9h'],
        },
      ).variation!;
      expect(v.selecting, isFalse);
      expect(v.userId, '');
      expect(v.seatIndex, 0);
      expect(v.deadline, 0);
      expect(v.options, Variation.all, reason: 'never an empty menu');
      expect(v.selected, isNull);
      expect(v.turnUp, isNull);
      expect(v.secondsLeft, 0);
    });

    test('never counts a window below zero', () {
      final late = _room(
        variation: _selecting('u2', deadline: _now - 4000),
      ).variation!;
      expect(late.secondsLeft, 0);
      final none = _room(variation: _selecting('u2', deadline: 0)).variation!;
      expect(none.secondsLeft, 0, reason: 'a server that runs no timeout');
    });

    test('a reveal says which of its cards were wild', () {
      final reveal = Reveal.fromJson({
        'userId': 'u1',
        'displayName': 'Player 1',
        'cards': ['Ah', '7d', '9c'],
        'handName': 'Pair',
        'won': true,
        'wild': ['Ah', '7d'],
      });
      expect(reveal.wild, ['Ah', '7d']);
      final plain = Reveal.fromJson({
        'userId': 'u1',
        'cards': ['Ah', '7d', '9c'],
      });
      expect(plain.wild, isEmpty);
    });
  });

  group('the tag', () {
    String tag(String? selected, String? turnUp) => variationTagText(
      category: 'Variation',
      boot: '200',
      selected: selected,
      turnUp: turnUp,
      nameOf: const Strings(AppLang.english).variationName,
    );

    test('names the stake until the hand has its rules, then the rules', () {
      expect(tag(null, null), 'Variation · 200');
      expect(tag(Variation.ak47, null), 'Variation · AK47');
      expect(tag(Variation.muflis, null), 'Variation · Muflis');
    });

    test(
      'says what is wild under Joker and Hukam, from the turned-up card',
      () {
        expect(tag(Variation.joker, '9h'), 'Variation · Joker · 9');
        expect(tag(Variation.joker, 'Td'), 'Variation · Joker · 10');
        expect(tag(Variation.joker, 'Ks'), 'Variation · Joker · K');
        expect(tag(Variation.hukam, '9h'), 'Variation · Hukam · ♥');
        expect(tag(Variation.hukam, 'As'), 'Variation · Hukam · ♠');
        expect(tag(Variation.hukam, '2d'), 'Variation · Hukam · ♦');
        expect(tag(Variation.hukam, 'Qc'), 'Variation · Hukam · ♣');
      },
    );

    test('ignores a turned-up card no variation asked for, or cannot read', () {
      expect(tag(Variation.ak47, '9h'), 'Variation · AK47');
      expect(tag(Variation.joker, null), 'Variation · Joker');
      expect(tag(Variation.joker, '9'), 'Variation · Joker');
      expect(tag(Variation.hukam, '9x'), 'Variation · Hukam');
    });
  });

  group('the game state', () {
    test('gives the keys to the chooser and to nobody else', () {
      final mine = _newState(room: _room(variation: _selecting('u0')));
      addTearDown(mine.dispose);
      expect(mine.onVariationTable, isTrue);
      expect(mine.variationSelecting, isTrue);
      expect(mine.variationIsMine, isTrue);
      expect(mine.variationProgress, isNotNull);

      final theirs = _newState(room: _room(variation: _selecting('u2')));
      addTearDown(theirs.dispose);
      expect(theirs.variationSelecting, isTrue);
      expect(theirs.variationIsMine, isFalse);
    });

    test('knows nothing of variations at a seen table', () {
      final state = _newState(
        room: _room(category: 'seen', turn: 'u0'),
      );
      addTearDown(state.dispose);
      expect(state.onVariationTable, isFalse);
      expect(state.variation, isNull);
      expect(state.variationSelecting, isFalse);
      expect(state.variationIsMine, isFalse);
      expect(state.variationProgress, isNull);
      expect(state.shownVariation, isNull);
      expect(state.variationAnnounced, isNull);
    });

    test('announces a window it SAW close, with no event at all', () {
      final state = _newState(room: _room(variation: _selecting('u2')));
      addTearDown(state.dispose);
      state.handleState(
        _room(variation: _selected('u2', Variation.ak47), turn: 'u2'),
      );
      expect(state.variationAnnounced?.variation, Variation.ak47);
      expect(state.variationAnnounced?.selectedBy, VariationSelectedBy.player);
      expect(state.shownVariation, Variation.ak47);
    });

    test('announces once when the event and the snapshot both say so', () {
      final state = _newState(room: _room(variation: _selecting('u2')));
      addTearDown(state.dispose);
      var told = 0;
      state.addListener(() {
        if (state.variationAnnounced != null) told++;
      });
      state.handleVariationSelected((
        variation: Variation.muflis,
        selectedBy: VariationSelectedBy.timeout,
        turnUp: null,
      ));
      final first = state.variationAnnounced;
      expect(first?.selectedBy, VariationSelectedBy.timeout);
      state.handleState(
        _room(
          variation: _selected(
            'u2',
            Variation.muflis,
            by: VariationSelectedBy.timeout,
          ),
          turn: 'u2',
        ),
      );
      expect(identical(state.variationAnnounced, first), isTrue);
      expect(told, greaterThan(0));
    });

    test('does not announce a hand it joined after the window closed', () {
      final state = _newState();
      addTearDown(state.dispose);
      state.handleState(
        _room(variation: _selected('u2', Variation.joker, turnUp: '9h')),
      );
      expect(state.variationAnnounced, isNull);
      expect(state.shownVariation, Variation.joker);
      expect(state.shownTurnUp, '9h');
    });

    testWidgets('holds the announcement for about three seconds', (
      tester,
    ) async {
      final state = _newState(room: _room(variation: _selecting('u2')));
      state.handleState(
        _room(variation: _selected('u2', Variation.ak47), turn: 'u2'),
      );
      expect(state.variationAnnounced, isNotNull);
      await tester.pump(const Duration(milliseconds: 2900));
      expect(state.variationAnnounced, isNotNull);
      await tester.pump(const Duration(milliseconds: 200));
      expect(state.variationAnnounced, isNull);
      expect(state.shownVariation, Variation.ak47, reason: 'the tag stays');
      state.dispose();
    });

    test('remembers the variation through the showdown, not past it', () {
      final state = _newState(room: _room(variation: _selecting('u2')));
      addTearDown(state.dispose);
      state.handleState(
        _room(
          variation: _selected('u2', Variation.hukam, turnUp: 'Qd'),
          turn: 'u2',
        ),
      );
      // The hand ends: the snapshot drops its variation block at once.
      state.handleState(_room(state: 'showdown'));
      expect(state.variation, isNull);
      expect(state.shownVariation, Variation.hukam);
      expect(state.shownTurnUp, 'Qd');

      // The next deal opens its own window.
      state.handleState(_room(handNo: 5, variation: _selecting('u3')));
      expect(state.shownVariation, isNull);
      expect(state.shownTurnUp, isNull);
      expect(state.variationAnnounced, isNull);
    });

    test('forgets it on another table whose hand has the same number', () {
      final state = _newState(room: _room(variation: _selecting('u2')));
      addTearDown(state.dispose);
      state.handleState(
        _room(variation: _selected('u2', Variation.ak47), turn: 'u2'),
      );
      expect(state.shownVariation, Variation.ak47);

      // A switch: another room, between hands, and the same hand number.
      state.handleState(_room(roomId: 'another-room', state: 'waiting'));
      expect(state.shownVariation, isNull);
      expect(state.variationAnnounced, isNull);
    });

    test('takes the variation from the showdown when it missed the hand', () {
      final state = _newState(room: _room(state: 'showdown'));
      addTearDown(state.dispose);
      state.handleVariationAtShowdown((
        variation: Variation.joker,
        selectedBy: '',
        turnUp: '4c',
      ));
      expect(state.shownVariation, Variation.joker);
      expect(state.shownTurnUp, '4c');
      expect(state.variationAnnounced, isNull, reason: 'the hand is over');
    });

    test('announces the next hand too, though its number could repeat', () {
      final state = _newState(room: _room(variation: _selecting('u2')));
      addTearDown(state.dispose);
      state.handleState(
        _room(variation: _selected('u2', Variation.ak47), turn: 'u2'),
      );
      state.handleState(_room(handNo: 5, variation: _selecting('u3')));
      state.handleState(
        _room(
          handNo: 5,
          variation: _selected('u3', Variation.muflis),
          turn: 'u3',
        ),
      );
      expect(state.variationAnnounced?.variation, Variation.muflis);
    });
  });

  group('the picker on its own', () {
    // One per choice sent: the server's answer, given when the test says so.
    final answers = <Completer<bool>>[];

    Future<List<String>> pump(
      WidgetTester tester, {
      required Size screen,
      double textScale = 1.0,
      AppLang lang = AppLang.english,
    }) async {
      tester.view.physicalSize = screen;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final sent = <String>[];
      answers.clear();
      final t = Strings(lang);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(sound: false),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              // The box the table gives it: the top 64% of the felt.
              child: SizedBox(
                height: screen.height * 0.64,
                child: VariationPrompt(
                  title: t.variationChooseTitle,
                  options: Variation.all,
                  nameOf: t.variationName,
                  noteOf: t.variationNote,
                  deadlineMs: _now + 10000,
                  totalMs: 10000,
                  onSelect: (wire) {
                    sent.add(wire);
                    final answer = Completer<bool>();
                    answers.add(answer);
                    return answer.future;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      return sent;
    }

    for (final lang in AppLang.values) {
      testWidgets(
        'fits 640x360 at text x1.25 in ${lang.englishName}, six keys of 44dp',
        (tester) async {
          await pump(
            tester,
            screen: const Size(640, 360),
            textScale: 1.25,
            lang: lang,
          );
          expect(tester.takeException(), isNull);
          expect(_optionKeys, findsNWidgets(6));
          for (final element in _optionKeys.evaluate()) {
            final size = element.size!;
            expect(size.height, greaterThanOrEqualTo(44));
            expect(size.width, greaterThanOrEqualTo(44));
          }
          final panel = tester.getRect(find.byType(VariationPrompt));
          for (final element in _optionKeys.evaluate()) {
            final box = element.renderObject! as RenderBox;
            final rect = box.localToGlobal(Offset.zero) & box.size;
            expect(panel.contains(rect.topLeft), isTrue);
            expect(panel.contains(rect.bottomRight), isTrue);
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    testWidgets('says what each variation does where there is room', (
      tester,
    ) async {
      const t = Strings(AppLang.english);
      await pump(tester, screen: const Size(891, 411));
      expect(tester.takeException(), isNull);
      for (final wire in Variation.all) {
        expect(find.text(t.variationName(wire)), findsOneWidget);
        expect(find.text(t.variationNote(wire)), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());

      // A short screen drops the notes and keeps the names.
      await pump(tester, screen: const Size(640, 360));
      expect(find.text(t.variationName(Variation.hukam)), findsOneWidget);
      expect(find.text(t.variationNote(Variation.hukam)), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('counts down in whole seconds', (tester) async {
      await pump(tester, screen: const Size(891, 411));
      final digits = tester.widget<Text>(
        find.byKey(const ValueKey('variation-seconds')),
      );
      expect(int.parse(digits.data!), inInclusiveRange(9, 10));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('sends one choice, and darkens all six while it waits', (
      tester,
    ) async {
      final sent = await pump(tester, screen: const Size(891, 411));
      await tester.tap(
        find.byKey(const ValueKey('variation-option-${Variation.ak47}')),
      );
      await tester.pump();
      expect(sent, [Variation.ak47]);

      // A second tap — the same key or another — sends nothing more.
      await tester.tap(
        find.byKey(const ValueKey('variation-option-${Variation.ak47}')),
        warnIfMissed: false,
      );
      await tester.tap(
        find.byKey(const ValueKey('variation-option-${Variation.muflis}')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(sent, [Variation.ak47]);

      // However long the answer takes, the keys stay dark: a slow link must
      // not turn one choice into a second, refused one.
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(
        find.byKey(const ValueKey('variation-option-${Variation.muflis}')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(sent, [Variation.ak47]);

      // Refused: the player is not left holding a dead panel.
      answers.single.complete(false);
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('variation-option-${Variation.muflis}')),
      );
      await tester.pump();
      expect(sent, [Variation.ak47, Variation.muflis]);

      // Taken: dark until the snapshot takes the panel away.
      answers.last.complete(true);
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('variation-option-${Variation.hukam}')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(sent, [Variation.ak47, Variation.muflis]);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('at the table', () {
    for (final (screen, scale) in [
      (const Size(640, 360), 1.25),
      (const Size(891, 411), 1.0),
      (const Size(1280, 800), 1.0),
    ]) {
      final name = '${screen.width.toInt()}x${screen.height.toInt()} x$scale';
      testWidgets('at $name the chooser gets six keys, clear of their hand', (
        tester,
      ) async {
        final state = _newState(room: _room(variation: _selecting('u0')));
        await _pumpTable(tester, state, screen: screen, textScale: scale);
        expect(tester.takeException(), isNull);

        expect(_optionKeys, findsNWidgets(6));
        expect(find.text(state.t.variationChooseTitle), findsOneWidget);
        // Their own cards and the See key stay in reach under it.
        final panel = tester.getRect(
          find
              .descendant(
                of: find.byType(VariationPrompt),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        final hand = tester.getRect(_private('_OwnHand'));
        expect(
          panel.bottom,
          lessThanOrEqualTo(hand.top),
          reason: 'the picker $panel covers the hand $hand',
        );
        final see = find.text(state.t.seeCards);
        expect(see, findsOneWidget);
        expect(panel.overlaps(tester.getRect(see)), isFalse);
        // And the chooser does not read "is selecting" about themselves.
        expect(find.byType(VariationSelectingLine), findsNothing);

        await _teardown(tester, state);
      });
    }

    testWidgets('everyone else reads who is selecting, and gets no keys', (
      tester,
    ) async {
      final state = _newState(room: _room(variation: _selecting('u2')));
      await _pumpTable(
        tester,
        state,
        screen: const Size(640, 360),
        textScale: 1.25,
      );
      expect(tester.takeException(), isNull);

      expect(_optionKeys, findsNothing);
      expect(find.byType(VariationPrompt), findsNothing);
      expect(
        find.text(state.t.variationSelectingBy('Player 2')),
        findsOneWidget,
      );
      final digits = tester.widget<Text>(
        find.byKey(const ValueKey('variation-seconds')),
      );
      expect(int.parse(digits.data!), inInclusiveRange(9, 10));
      // The chooser's seat is the one on the clock.
      expect(_podOf(tester, 'u2').onTurn, isTrue);
      expect(_podOf(tester, 'u1').onTurn, isFalse);

      await _teardown(tester, state);
    });

    testWidgets('the picker goes with the snapshot that closes the window', (
      tester,
    ) async {
      final state = _newState(room: _room(variation: _selecting('u0')));
      await _pumpTable(tester, state);
      expect(find.byType(VariationPrompt), findsOneWidget);

      // The clock beat them: the server chose, and said so in the snapshot.
      state.handleState(
        _room(
          variation: _selected(
            'u0',
            Variation.muflis,
            by: VariationSelectedBy.timeout,
          ),
          turn: 'u0',
        ),
      );
      await tester.pump();
      expect(find.byType(VariationPrompt), findsNothing);
      expect(find.byType(TableScreen), findsOneWidget, reason: 'no route lost');
      expect(
        find.text(state.t.variationChosen(state.t.variationName('MUFLIS'))),
        findsOneWidget,
      );
      expect(find.text(state.t.variationAutoChosen), findsOneWidget);
      expect(find.text('VARIATION · Muflis'), findsOneWidget);

      // The announcement goes after its three seconds; the tag stays.
      await tester.pump(const Duration(milliseconds: 3200));
      expect(find.text(state.t.variationAutoChosen), findsNothing);
      expect(find.text('VARIATION · Muflis'), findsOneWidget);

      await _teardown(tester, state);
    });

    testWidgets('the tag says what is wild under Joker', (tester) async {
      final state = _newState(
        room: _room(
          variation: _selected('u2', Variation.joker, turnUp: 'Td'),
          turn: 'u2',
        ),
      );
      await _pumpTable(tester, state);
      expect(find.text('VARIATION · Joker · 10'), findsOneWidget);
      await _teardown(tester, state);
    });

    testWidgets('a seen table reads exactly as it did', (tester) async {
      final state = _newState(
        room: _room(category: 'seen', turn: 'u1'),
      );
      await _pumpTable(tester, state);
      // The English category word is written in capitals in the table itself.
      expect(find.text('${state.t.seen} · 200'), findsOneWidget);
      expect(state.t.seen, 'SEEN');
      expect(find.byType(VariationPrompt), findsNothing);
      expect(find.byType(VariationSelectingLine), findsNothing);
      expect(find.byType(VariationChosenLine), findsNothing);
      await _teardown(tester, state);
    });

    testWidgets('a wild card at a reveal is edged, and the rest are not', (
      tester,
    ) async {
      final state = _newState(
        room: _room(variation: _selected('u2', Variation.ak47), turn: 'u2'),
      );
      await _pumpTable(tester, state);
      state.handleShowdown((
        reveals: [
          Reveal.fromJson({
            'userId': 'u2',
            'displayName': 'Player 2',
            'cards': ['Ah', '9d', '9c'],
            'handName': 'Trail',
            'won': true,
            'wild': ['Ah'],
          }),
        ],
        result: '',
        winnerId: null,
        winnerName: '',
        pot: 0,
        nextHandAt: 0,
        reason: 'show',
      ));
      await tester.pump();
      final edges = tester
          .widgetList<WildEdge>(
            find.descendant(
              of: find.byWidgetPredicate(
                (w) => w is SeatPod && w.seat?.userId == 'u2',
              ),
              matching: find.byType(WildEdge),
            ),
          )
          .toList();
      expect(edges.map((e) => e.wild), [true, false, false]);
      await _teardown(tester, state);
    });
  });
}
