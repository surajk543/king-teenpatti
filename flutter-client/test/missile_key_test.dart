// The Missile key over the Pack key (owner, 14 Sep 2026): dark unless it is
// the viewer's turn and the server allows a missile; lit with missiles to
// spend; greyed but still tappable without, when it offers the store's
// Missiles shelf; and asking first, with a question that closes itself if the
// turn ends under it.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/poker_chip.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

/// A table of three, the viewer (u0) in seat 0.
RoomState _room({
  required bool onTurn,
  bool canMissile = true,
  bool seen = false,
  bool broke = false,
}) => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': 'blind',
  'chipsHidden': true,
  'state': 'betting',
  'handNo': 2,
  'dealerSeat': 1,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 600,
  'maxPot': 0,
  'stake': 200,
  'turn': {
    'seatIndex': onTurn ? 0 : 1,
    'userId': onTurn ? 'u0' : 'u1',
    'deadline': 0,
  },
  'you': {
    'seatIndex': 0,
    'chips': 200000,
    'status': 'active',
    'isBlind': !seen,
    'blindMovesLeft': 4,
    'contributed': 200,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': const [],
    'canMissile': onTurn && canMissile,
    if (onTurn)
      'options': {
        'canSee': true,
        'canPack': true,
        'canSideshow': false,
        'raiseSteps': broke ? <int>[] : (seen ? [400, 800] : [200, 400]),
        'chips': 200000,
        'currentStake': 200,
      },
  },
  'seats': [
    for (var i = 0; i < 3; i++)
      {
        'seatIndex': i,
        'userId': 'u$i',
        'displayName': 'Player $i',
        'chips': i == 0 ? 200000 : null,
        'status': 'active',
        'isBlind': true,
        'lastBet': 200,
        'lastAction': 'chaal',
        'contributed': 200,
        'connected': true,
        'cardCount': 3,
      },
  ],
});

GameState _newState({required int missiles, required RoomState room}) {
  // Play is never started here; the override only keeps the purchase plugin
  // from registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Player 0',
      'chips': 200000,
      'diamond': 2,
      'hammer': 20,
      'missile': missiles,
    })
    ..room = room
    ..screen = Screen.table;
}

Future<void> _pumpTable(WidgetTester tester, GameState state) async {
  tester.view.physicalSize = const Size(891, 411);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
        builder: (context, child) => GlassBudget(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: child,
          ),
        ),
        home: const TableScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _teardown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

final _key = find.byTooltip('Missile');

FilledButton _button(WidgetTester tester) => tester.widget<FilledButton>(
  find.descendant(of: _key, matching: find.byType(FilledButton)),
);

/// The key's own fade: 1 lit, 0.42 dark or greyed.
double _opacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.descendant(of: _key, matching: find.byType(Opacity)).first,
    )
    .opacity;

void main() {
  testWidgets('stands directly above the Pack key', (tester) async {
    final state = _newState(missiles: 1, room: _room(onTurn: true));
    await _pumpTable(tester, state);

    final missile = tester.getRect(_key);
    final pack = tester.getRect(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_PackKey',
        ),
        matching: find.byType(FilledButton),
      ),
    );
    expect(missile.left, pack.left);
    expect(missile.width, pack.width);
    expect(missile.bottom, lessThan(pack.top));
    expect(pack.top - missile.bottom, lessThanOrEqualTo(12));
    expect(find.text('Missile'), findsOneWidget);

    await _teardown(tester, state);
  });

  // A missile needs the chips a show would cost (owner, 14 Sep 2026), and the
  // key says how many under its name, on turn and off, as Chaal shows its bet.
  // A player without the chips for the chaal gets a dark Chaal key on their own
  // turn (owner, 14 Sep 2026); the server's ladder is empty for them, and the
  // key still shows what the chaal would take.
  testWidgets('Chaal is disabled when the player cannot afford the chaal', (
    tester,
  ) async {
    FilledButton chaal() => tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Chaal'),
        matching: find.byType(FilledButton),
      ),
    );

    final state = _newState(
      missiles: 1,
      room: _room(onTurn: true, broke: true),
    );
    await _pumpTable(tester, state);
    expect(state.canChaal, isFalse);
    expect(chaal().onPressed, isNull, reason: 'short of the chaal');
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Chaal'),
          matching: find.byType(FilledButton),
        ),
        matching: find.text('200'),
      ),
      findsOneWidget,
      reason: 'the price still shows',
    );

    state.handleState(_room(onTurn: true));
    await tester.pump();
    expect(state.canChaal, isTrue);
    expect(chaal().onPressed, isNotNull, reason: 'able to pay');

    state.handleState(_room(onTurn: false));
    await tester.pump();
    expect(chaal().onPressed, isNull, reason: 'off turn');

    await _teardown(tester, state);
  });

  testWidgets('carries the chips a show would cost', (tester) async {
    Finder figure(String text) =>
        find.descendant(of: _key, matching: find.text(text));

    final state = _newState(missiles: 1, room: _room(onTurn: true));
    await _pumpTable(tester, state);
    expect(figure('200'), findsOneWidget, reason: 'blind, on turn');
    // One missile a shot, by the rocket the wallets use, and the chips by a
    // chip (owner, 14 Sep 2026).
    expect(figure('1'), findsOneWidget, reason: 'one missile a shot');
    expect(
      find.descendant(of: _key, matching: find.byIcon(missileIcon)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _key, matching: find.byType(PokerChip)),
      findsOneWidget,
    );

    state.handleState(_room(onTurn: false));
    await tester.pump();
    expect(figure('200'), findsOneWidget, reason: 'blind, off turn');

    state.handleState(_room(onTurn: true, seen: true));
    await tester.pump();
    expect(figure('400'), findsOneWidget, reason: 'seen, on turn');
    expect(figure('200'), findsNothing);

    state.handleState(_room(onTurn: false, seen: true));
    await tester.pump();
    expect(figure('400'), findsOneWidget, reason: 'seen, off turn');

    await _teardown(tester, state);
  });

  testWidgets('is dark off turn, and when the server does not allow one', (
    tester,
  ) async {
    final state = _newState(missiles: 5, room: _room(onTurn: false));
    await _pumpTable(tester, state);
    expect(_button(tester).onPressed, isNull);
    expect(_opacity(tester), 0.42);

    state.handleState(_room(onTurn: true, canMissile: false));
    await tester.pump();
    expect(_button(tester).onPressed, isNull);
    expect(_opacity(tester), 0.42);

    // Lit the moment the server says so.
    state.handleState(_room(onTurn: true));
    await tester.pump();
    expect(_button(tester).onPressed, isNotNull);
    expect(_opacity(tester), 1);

    await _teardown(tester, state);
  });

  testWidgets('asks first, and closes the question when the turn ends', (
    tester,
  ) async {
    final state = _newState(missiles: 1, room: _room(onTurn: true));
    await _pumpTable(tester, state);

    await tester.tap(_key);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Fire a missile?'), findsOneWidget);
    expect(
      find.text(
        'Every player still in the hand shows their cards and the best '
        'hand takes the pot. Costs 1 missile.',
      ),
      findsOneWidget,
    );
    expect(find.text('Fire'), findsOneWidget);

    // The turn times out under the question.
    state.handleState(_room(onTurn: false));
    // The rebuild that notices, the pop it schedules, and the dialog's exit.
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('Fire a missile?'), findsNothing);
    expect(
      state.notice,
      'Too late — the missile was not fired. No missile was spent.',
    );

    await _teardown(tester, state);
  });

  // Firing ends the hand, so the answer takes the missile away while the
  // question is still animating out, and the table must still be there after.
  // On a phone the closing question's second pop took the table with it (a
  // black screen on the phone that fired, 14 Sep 2026). This test does not
  // reproduce that timing — it passes without the fix too — so the fix in
  // _WhileStillOpen was verified on an emulator; this guards the outcome.
  testWidgets('firing takes the question away without taking the table with '
      'it', (tester) async {
    final state = _newState(missiles: 1, room: _room(onTurn: true));
    await _pumpTable(tester, state);

    await tester.tap(_key);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Fire'));
    await tester.pump();

    // The hand is over before the dialog has finished leaving.
    state.handleState(_room(onTurn: false));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('Fire a missile?'), findsNothing);
    expect(find.byType(TableScreen), findsOneWidget);
    expect(_key, findsOneWidget);
    expect(tester.takeException(), isNull);

    await _teardown(tester, state);
  });

  testWidgets('with no missiles it is greyed, and offers the Missiles shelf', (
    tester,
  ) async {
    final state = _newState(missiles: 0, room: _room(onTurn: true));
    await _pumpTable(tester, state);
    expect(_button(tester).onPressed, isNotNull);
    expect(_opacity(tester), 0.42);

    await tester.tap(_key);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No missiles left'), findsOneWidget);
    expect(find.text('Fire a missile?'), findsNothing);

    await tester.tap(find.text('Get missiles'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Missile Store'), findsOneWidget);

    await _teardown(tester, state);
  });

  testWidgets('takes no second tap while a missile is with the server', (
    tester,
  ) async {
    final state = _newState(missiles: 3, room: _room(onTurn: true))
      ..firingMissile = true;
    await _pumpTable(tester, state);
    expect(_button(tester).onPressed, isNull);

    await _teardown(tester, state);
  });
}
