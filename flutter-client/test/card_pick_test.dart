// 5-Card Teen Patti's card picker, as the player meets it (owner, 19 Sep 2026).
//
// The server used to choose which three of a player's five played. Now the
// PLAYER chooses, in a window with its own clock, and is told afterwards
// whether they chose the best three. This covers the felt's half of that: the
// panel that asks, what a tap does, what is sent, the verdict that follows,
// and the line everyone else sees while they wait.
//
// The panel has to FIT: it stands in 0.64 of the felt, and a row of five cards
// sized only by the panel's width overflowed the bottom of that box by 16
// pixels on a 640x360 phone. Every size and language here is a guard on that.
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
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/glass_components.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/variation_prompt.dart';

const _ids = ['u0', 'u1', 'u2', 'u3', 'u4'];
const _five = ['As', '7d', 'Ks', '7c', 'Qs'];
const _bestThree = ['As', 'Ks', 'Qs'];

int get _now => DateTime.now().millisecondsSinceEpoch;

Map<String, dynamic> _variation() => {
  'selecting': false,
  'userId': 'u0',
  'displayName': 'Player 0',
  'seatIndex': 0,
  'startedAt': _now,
  'deadline': _now,
  'timeoutMs': 10000,
  'options': Variation.all,
  'selected': Variation.fiveCard,
  'selectedBy': VariationSelectedBy.player,
  'cardsPerPlayer': 5,
};

/// The viewer holds five and still owes a choice.
Map<String, dynamic> _picking({int leftMs = 8000}) => {
  'handName': '',
  'wild': const <String>[],
  'playsAs': _five,
  'best': const <String>[],
  'picking': true,
  'pickDeadline': _now + leftMs,
  'pickTimeoutMs': 8000,
};

/// The viewer has chosen [played]; the best three were [_bestThree].
Map<String, dynamic> _picked(List<String> played, {bool byTimeout = false}) => {
  'handName': 'Pair',
  'wild': const <String>[],
  'playsAs': _five,
  'best': played,
  'picking': false,
  'pickedBy': byTimeout ? 'TIMEOUT' : 'PLAYER',
  'bestPossible': _bestThree,
};

/// A table of five with the viewer (u0) in seat 0, on turn by default.
RoomState _room({
  Map<String, dynamic>? hand,
  List<String> cards = _five,
  int turnSeat = 0,
  int pickingSeat = -1,
}) => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': 'variation',
  'chipsHidden': true,
  'state': 'betting',
  'handNo': 4,
  'dealerSeat': 4,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 1000,
  'maxPot': 0,
  'stake': 200,
  'turn': {
    'seatIndex': turnSeat,
    'userId': _ids[turnSeat],
    'deadline': _now + 25000,
  },
  'variation': _variation(),
  'you': {
    'seatIndex': 0,
    'chips': 200000,
    'status': 'active',
    'isBlind': false,
    'blindMovesLeft': 4,
    'contributed': 200,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': cards,
    'hand': ?hand,
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
        'isBlind': i != 0,
        'lastBet': 200,
        'lastAction': 'boot',
        'contributed': 200,
        'connected': true,
        'cardCount': 5,
        if (i == pickingSeat) 'picking': true,
      },
  ],
});

GameState _newState(RoomState room) {
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

Future<void> _pumpTable(
  WidgetTester tester,
  GameState state, {
  required Size screen,
  double textScale = 1.0,
  AppLang lang = AppLang.english,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  state.lang = lang;
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
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _teardown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

Finder get _prompt => find.byType(CardPickPrompt);
Finder _inPrompt(Type type) =>
    find.descendant(of: _prompt, matching: find.byType(type));

/// The codes of the cards drawn inside the picker, in the order drawn.
List<String?> _promptCards(WidgetTester tester) => tester
    .widgetList<PlayingCard>(_inPrompt(PlayingCard))
    .map((c) => c.code)
    .toList();

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter');
    for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
    }
    await inter.load();
  });

  group('the picker', () {
    // The box it stands in is 0.64 of the felt, and a row of five cards is
    // what fills it. Every screen and language the app ships, so the panel
    // can never again overflow the way it did at 640x360 (19 Sep 2026).
    for (final (screen, scale) in [
      (const Size(640, 360), 1.25),
      (const Size(640, 360), 1.0),
      (const Size(891, 411), 1.0),
      (const Size(1280, 800), 1.25),
    ]) {
      final size = '${screen.width.toInt()}x${screen.height.toInt()} x$scale';
      for (final lang in AppLang.values) {
        testWidgets('fits at $size in ${lang.name}, with all five cards and '
            'the key to confirm', (tester) async {
          final state = _newState(_room(hand: _picking()));
          await _pumpTable(
            tester,
            state,
            screen: screen,
            textScale: scale,
            lang: lang,
          );
          expect(tester.takeException(), isNull);

          expect(_prompt, findsOneWidget);
          expect(_promptCards(tester), _five);
          final t = Strings(lang);
          expect(find.text(t.pickTitle), findsOneWidget);
          // The panel stands inside the box it was given.
          final box = tester.getRect(_prompt);
          expect(box.height, lessThanOrEqualTo(screen.height * 0.64 + 0.5));
          expect(box.width, lessThanOrEqualTo(screen.width));
          // And the confirm key is inside the panel, not pushed off it.
          final key = tester.getRect(
            find.descendant(
              of: _prompt,
              matching: find.textContaining(t.pickConfirm),
            ),
          );
          expect(box.contains(key.topLeft), isTrue);
          expect(box.contains(key.bottomRight), isTrue);

          await _teardown(tester, state);
        });
      }
    }

    testWidgets('marks a card on a tap, unmarks it on another, and stops at '
        'three', (tester) async {
      final state = _newState(_room(hand: _picking()));
      await _pumpTable(
        tester,
        state,
        screen: const Size(891, 411),
      );
      expect(state.pickSelection, isEmpty);

      Future<void> tap(String code) async {
        await tester.tap(find.byKey(ValueKey('pick-card-$code')));
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tap('As');
      await tap('Ks');
      expect(state.pickSelection, ['As', 'Ks']);
      // Tapping a marked card takes it back.
      await tap('As');
      expect(state.pickSelection, ['Ks']);
      await tap('7d');
      await tap('7c');
      expect(state.pickSelection, ['Ks', '7d', '7c']);
      // A fourth tap is ignored: it would have to drop one of the three, and
      // which one is not the client's to decide.
      await tap('Qs');
      expect(state.pickSelection, ['Ks', '7d', '7c']);
      // Taking one back makes room again.
      await tap('7d');
      await tap('Qs');
      expect(state.pickSelection, ['Ks', '7c', 'Qs']);

      await _teardown(tester, state);
    });

    testWidgets('has nothing to confirm until three are marked', (
      tester,
    ) async {
      final state = _newState(_room(hand: _picking()));
      await _pumpTable(tester, state, screen: const Size(891, 411));
      final t = state.t;

      Finder key() => find.ancestor(
        of: find.textContaining(t.pickConfirm),
        matching: find.byType(GlassButton),
      );
      expect(tester.widget<GlassButton>(key()).onPressed, isNull);
      expect(find.textContaining('0/3'), findsOneWidget);

      for (final code in ['As', 'Ks']) {
        await tester.tap(find.byKey(ValueKey('pick-card-$code')));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(tester.widget<GlassButton>(key()).onPressed, isNull);
      expect(find.textContaining('2/3'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pick-card-Qs')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<GlassButton>(key()).onPressed, isNotNull);
      expect(find.textContaining('3/3'), findsOneWidget);

      await _teardown(tester, state);
    });

    testWidgets('is gone once the choice is made, and the felt names the hand',
        (tester) async {
      final state = _newState(_room(hand: _picking()));
      await _pumpTable(tester, state, screen: const Size(891, 411));
      expect(_prompt, findsOneWidget);

      state.handleState(_room(hand: _picked(['As', '7d', '7c'])));
      await tester.pump();
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(_prompt, findsNothing);
      expect(find.text('Pair'), findsWidgets);

      await _teardown(tester, state);
    });

    // A hand that never asked — three cards — never shows the picker.
    testWidgets('never stands over a three-card hand', (tester) async {
      final state = _newState(
        _room(
          cards: const ['As', 'Ks', 'Qs'],
          hand: {
            'handName': 'Pure Sequence',
            'wild': const <String>[],
            'playsAs': const ['As', 'Ks', 'Qs'],
            'best': const ['As', 'Ks', 'Qs'],
          },
        ),
      );
      await _pumpTable(tester, state, screen: const Size(891, 411));
      expect(_prompt, findsNothing);
      await _teardown(tester, state);
    });
  });

  group('the verdict', () {
    testWidgets('says so when the best three were played', (tester) async {
      final state = _newState(_room(hand: _picking()));
      await _pumpTable(tester, state, screen: const Size(891, 411));

      state.handleState(_room(hand: _picked(_bestThree)));
      await tester.pump();
      await _settle(tester);
      expect(tester.takeException(), isNull);

      expect(find.byType(PickVerdict), findsOneWidget);
      expect(find.text(state.t.pickWasBest), findsOneWidget);
      // Nothing to compare against: they played it.
      expect(find.text(state.t.pickNotBest), findsNothing);
      expect(
        find.descendant(
          of: find.byType(PickVerdict),
          matching: find.byType(PlayingCard),
        ),
        findsNothing,
      );

      await _teardown(tester, state);
    });

    // Owner, 19 Sep 2026: "while showing the best card in UI in pop up window,
    // also show your selected card in pop up".
    testWidgets('shows what was played beside what would have been best', (
      tester,
    ) async {
      const played = ['As', '7d', '7c'];
      final state = _newState(_room(hand: _picking()));
      await _pumpTable(tester, state, screen: const Size(891, 411));

      state.handleState(_room(hand: _picked(played)));
      await tester.pump();
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final verdict = find.byType(PickVerdict);
      expect(verdict, findsOneWidget);
      expect(find.text(state.t.pickNotBest), findsOneWidget);
      expect(find.text(state.t.pickYouPlayed), findsOneWidget);
      expect(find.text(state.t.pickTheBest), findsOneWidget);
      // Both hands are drawn: the three played, then the three that were best.
      expect(
        tester
            .widgetList<PlayingCard>(
              find.descendant(of: verdict, matching: find.byType(PlayingCard)),
            )
            .map((c) => c.code),
        [...played, ..._bestThree],
      );

      await _teardown(tester, state);
    });

    testWidgets('says when the clock chose, and stands for a few seconds', (
      tester,
    ) async {
      final state = _newState(_room(hand: _picking()));
      await _pumpTable(tester, state, screen: const Size(891, 411));

      state.handleState(
        _room(hand: _picked(['As', '7d', 'Ks'], byTimeout: true)),
      );
      await tester.pump();
      await _settle(tester);
      expect(find.text(state.t.pickTimedOut), findsOneWidget);

      // It goes by itself.
      await tester.pump(GameState.pickAnnouncedFor);
      await _settle(tester);
      expect(find.byType(PickVerdict), findsNothing);

      await _teardown(tester, state);
    });
  });

  group('everyone else', () {
    // Owner, 19 Sep 2026: "while player is choosing best card and the turn is
    // also his then, others should see that he is choosing".
    testWidgets('is told who the table is waiting on', (tester) async {
      // Seat 2 is on turn and still choosing; the viewer is seat 0.
      final state = _newState(
        _room(
          hand: _picked(_bestThree),
          turnSeat: 2,
          pickingSeat: 2,
        ),
      );
      await _pumpTable(
        tester,
        state,
        screen: const Size(640, 360),
        textScale: 1.25,
      );
      expect(tester.takeException(), isNull);
      expect(state.someoneChoosingCards?.userId, 'u2');
      expect(find.text(state.t.pickChoosing('Player 2')), findsOneWidget);
      // And the viewer is not shown a picker of their own.
      expect(_prompt, findsNothing);

      await _teardown(tester, state);
    });

    testWidgets('is told nothing about a chooser who is not on turn', (
      tester,
    ) async {
      final state = _newState(
        _room(hand: _picked(_bestThree), turnSeat: 1, pickingSeat: 2),
      );
      await _pumpTable(tester, state, screen: const Size(891, 411));
      expect(state.someoneChoosingCards, isNull);
      expect(find.text(state.t.pickChoosing('Player 2')), findsNothing);
      await _teardown(tester, state);
    });

    testWidgets('the chooser sees their own picker, not a line about '
        'themselves', (tester) async {
      final state = _newState(
        _room(hand: _picking(), turnSeat: 0, pickingSeat: 0),
      );
      await _pumpTable(tester, state, screen: const Size(891, 411));
      expect(state.someoneChoosingCards, isNull);
      expect(_prompt, findsOneWidget);
      await _teardown(tester, state);
    });
  });
}
