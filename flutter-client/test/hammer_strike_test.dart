// A Force Sideshow's hammer (owner, 14 Sep 2026): thrown once per sideshow
// whichever of its events arrive, the two hands kept face down until it lands,
// the loser's fold held until after the flip, no hammer for an ordinary
// sideshow, and nothing left behind when the hand moves on mid-flight.
//
// The events are fed in the order the server sends them (table.go
// settleSideshow): the reveal to the two players, the loser's pack to the
// room, the snapshot that folds them, the resolution to the room, and the
// snapshot that hands the turn back.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/hammer_strike.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/hammer_flight.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

const _cards = {
  'u0': ['As', 'Ad', 'Ah'],
  'u1': ['Kc', 'Kd', '4s'],
  'u2': ['Qs', 'Js', 'Ts'],
  'u4': ['2c', '7d', '9h'],
};

/// A seen table of five, all still in, the viewer (u0) in seat 0 and on turn.
RoomState _room({
  int handNo = 4,
  Set<String> packed = const {},
  Map<String, dynamic>? pending,
}) => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': 'seen',
  'chipsHidden': false,
  'state': 'betting',
  'handNo': handNo,
  'dealerSeat': 2,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 6000,
  'maxPot': 2000000,
  'stake': 400,
  'turn': {'seatIndex': 0, 'userId': 'u0', 'deadline': 0},
  'sideshow': ?pending,
  'you': {
    'seatIndex': 0,
    'chips': 200000,
    'status': packed.contains('u0') ? 'packed' : 'active',
    'isBlind': false,
    'blindMovesLeft': 0,
    'contributed': 1200,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': _cards['u0'],
  },
  'seats': [
    for (var i = 0; i < 5; i++)
      {
        'seatIndex': i,
        'userId': 'u$i',
        'displayName': 'Player $i',
        'avatarUrl': null,
        'chips': 200000,
        'status': packed.contains('u$i') ? 'packed' : 'active',
        'isBlind': false,
        'lastBet': 400,
        'lastAction': packed.contains('u$i') ? 'pack' : 'chaal',
        'contributed': 1200,
        'connected': true,
        'cardCount': 3,
      },
  ],
});

SideshowReveal _reveal(
  String from,
  String to, {
  required String packed,
  String reason = SideshowReason.forced,
}) => SideshowReveal.fromJson({
  'reason': reason,
  'packedUserId': packed,
  'hands': [
    for (final id in [from, to])
      {
        'userId': id,
        'displayName': 'Player ${id.substring(1)}',
        'cards': _cards[id],
        'handName': id == packed ? 'High Card' : 'Trail',
      },
  ],
});

({
  String fromUserId,
  String toUserId,
  bool accepted,
  String reason,
  String? packedUserId,
})
_done(
  String from,
  String to, {
  required String packed,
  String reason = SideshowReason.forced,
}) => (
  fromUserId: from,
  toUserId: to,
  accepted: true,
  reason: reason,
  packedUserId: packed,
);

({String userId, String action, String? reason}) _packFor(String userId) =>
    (userId: userId, action: GameAction.pack, reason: 'sideshow');

GameState _newState() {
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
      'diamond': 1,
      'hammer': 20,
    })
    ..room = _room()
    ..screen = Screen.table;
  return state;
}

/// Every hammer the table asks to be heard, and when.
class _Heard extends FeedbackSettings {
  _Heard(this.now);

  final DateTime Function() now;
  final hammers = <DateTime>[];

  @override
  void hammerHit() => hammers.add(now());
}

Future<void> _pumpTable(
  WidgetTester tester,
  GameState state, {
  Size screen = const Size(891, 411),
  FeedbackSettings? sounds,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final feedback = sounds ?? FeedbackSettings();
  addTearDown(feedback.dispose);
  // Parsed for real, so the painter draws the hammer rather than skipping it.
  await tester.runAsync(HammerArt.load);
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

/// The rim seat of [userId], as the felt is drawing it.
SeatPod _podOf(WidgetTester tester, String userId) => tester.widget<SeatPod>(
  find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId),
);

List<String?> _cardsOn(WidgetTester tester, String userId) => tester
    .widgetList<PlayingCard>(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is SeatPod && w.seat?.userId == userId,
        ),
        matching: find.byType(PlayingCard),
      ),
    )
    .map((card) => card.code)
    .toList();

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

/// The pods whose jolt is wired to a strike.
Iterable<PodImpact> _jolting(WidgetTester tester) => tester
    .widgetList<PodImpact>(find.byType(PodImpact))
    .where((impact) => impact.clock != null);

/// The viewer (u0) forces a sideshow on u4 and wins it, exactly as the
/// viewer's socket hears it.
void _viewerForcesAndWins(GameState state) {
  state
    ..handleSideshowReveal(_reveal('u0', 'u4', packed: 'u4'))
    ..handleTableAction(_packFor('u4'))
    ..handleState(_room(packed: {'u4'}))
    ..handleSideshowDone(_done('u0', 'u4', packed: 'u4'))
    ..handleState(_room(packed: {'u4'}));
}

Duration _ms(int ms) => Duration(milliseconds: ms);

void main() {
  testWidgets(
    'a forced sideshow throws one hammer, however many of its events arrive',
    (tester) async {
      final state = _newState();
      await _pumpTable(tester, state);

      // The player's order: the reveal first.
      state.handleSideshowReveal(_reveal('u0', 'u4', packed: 'u4'));
      final strike = state.hammerStrike;
      expect(strike, isNotNull);
      expect(strike!.fromUserId, 'u0');
      expect(strike.toUserId, 'u4');
      await tester.pump();
      await tester.pump(_ms(200));
      expect(find.byType(HammerFlight), findsOneWidget);
      final clock = tester
          .widget<HammerFlight>(find.byType(HammerFlight))
          .clock;
      final before = clock.value;
      expect(before, greaterThan(0));

      // The rest of the same sideshow, the resolution delivered twice over.
      state
        ..handleTableAction(_packFor('u4'))
        ..handleState(_room(packed: {'u4'}))
        ..handleSideshowDone(_done('u0', 'u4', packed: 'u4'))
        ..handleSideshowDone(_done('u0', 'u4', packed: 'u4'))
        ..handleState(_room(packed: {'u4'}));
      await tester.pump(_ms(16));
      expect(identical(state.hammerStrike, strike), isTrue);
      expect(find.byType(HammerFlight), findsOneWidget);
      expect(
        tester.widget<HammerFlight>(find.byType(HammerFlight)).clock.value,
        greaterThan(before),
        reason: 'the flight carried on rather than starting again',
      );
      // Only the pod that is hit is wired to the jolt.
      final jolting = _jolting(tester).toList();
      expect(jolting, hasLength(1));
      expect(
        find.descendant(
          of: find.byWidgetPredicate(
            (w) => w is SeatPod && w.seat?.userId == 'u4',
          ),
          matching: find.byWidget(jolting.single),
        ),
        findsOneWidget,
      );

      // Crossed the other way in the next hand — the resolution first, then
      // the reveal — and still one hammer.
      await tester.pump(HammerTiming.total);
      await tester.pump();
      expect(find.byType(HammerFlight), findsNothing);
      state
        ..handleState(_room(handNo: 5))
        ..handleSideshowDone(_done('u0', 'u4', packed: 'u4'));
      final crossed = state.hammerStrike;
      expect(crossed, isNotNull);
      expect(crossed!.handNo, 5);
      state.handleSideshowReveal(_reveal('u0', 'u4', packed: 'u4'));
      expect(identical(state.hammerStrike, crossed), isTrue);
      await tester.pump();
      await tester.pump(_ms(16));
      expect(find.byType(HammerFlight), findsOneWidget);
      expect(_podOf(tester, 'u4').revealed, isNull);

      await _teardown(tester, state);
    },
  );

  testWidgets('a bystander sees the link and one hammer, and never a card', (
    tester,
  ) async {
    final state = _newState();
    await _pumpTable(tester, state);

    // u2 forces a sideshow on u1, and u1 loses. The viewer is not in it and
    // gets no reveal: the pack, the snapshot, then the resolution.
    state.handleTableAction(_packFor('u1'));
    expect(
      state.foldHeldFor('u1'),
      isTrue,
      reason: 'a sideshow pack with nothing pending is a forced one',
    );
    state.handleState(_room(packed: {'u1'}));
    await tester.pump();
    expect(
      _podOf(tester, 'u1').seat!.status,
      SeatState.active,
      reason: 'the fold waits for the hammer even before the table knows',
    );

    state.handleSideshowDone(_done('u2', 'u1', packed: 'u1'));
    final strike = state.hammerStrike;
    expect(strike, isNotNull);
    expect(strike!.fromUserId, 'u2');
    expect(strike.toUserId, 'u1');

    // A second copy of the resolution — a flaky socket delivering twice —
    // throws nothing more.
    state.handleSideshowDone(_done('u2', 'u1', packed: 'u1'));
    expect(identical(state.hammerStrike, strike), isTrue);

    await tester.pump();
    await tester.pump(_ms(300));
    // Everything an ordinary sideshow shows a bystander — the link between
    // the two seats — plus the hammer on its way from u2's pod to u1's.
    expect(find.byType(HammerFlight), findsOneWidget);
    expect(_private('_SideshowLink'), findsOneWidget);
    expect(_jolting(tester), hasLength(1));
    expect(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is SeatPod && w.seat?.userId == 'u1',
        ),
        matching: find.byWidget(_jolting(tester).single),
      ),
      findsOneWidget,
    );
    expect(state.notice, isNull, reason: 'the news waits for the hit');

    // Through the hit: still one hammer, and never a card — a bystander is
    // sent no reveal, so neither hand can turn over here.
    await tester.pump(HammerTiming.impact);
    await tester.pump();
    expect(find.byType(HammerFlight), findsOneWidget);
    expect(state.sideshowReveal, isNull);
    for (final id in ['u1', 'u2']) {
      expect(_podOf(tester, id).revealed, isNull);
      expect(_cardsOn(tester, id), [null, null, null]);
    }
    expect(_private('_OwnHandName'), findsNothing);

    // The result: the loser folds, the table is told, the link goes.
    await tester.pump(HammerTiming.result - HammerTiming.impact);
    await tester.pump();
    expect(_podOf(tester, 'u1').seat!.status, SeatState.packed);
    expect(state.notice, 'Player 2 forced a sideshow on Player 1');
    expect(_private('_SideshowLink'), findsNothing);
    expect(_podOf(tester, 'u1').revealed, isNull);

    await _teardown(tester, state);
  });

  testWidgets(
    "the forced hands stay face down until the hammer lands, then the loser folds",
    (tester) async {
      final state = _newState();
      await _pumpTable(tester, state);
      expect(_cardsOn(tester, 'u4'), [null, null, null]);

      _viewerForcesAndWins(state);
      await tester.pump();
      await tester.pump(_ms(16));

      // In the air: the reveal arrived, but nothing shows it yet.
      expect(state.sideshowReveal, isNotNull);
      expect(state.shownSideshowReveal, isNull);
      expect(_podOf(tester, 'u4').revealed, isNull);
      expect(_cardsOn(tester, 'u4'), [null, null, null]);
      expect(_private('_OwnHandName'), findsNothing);
      expect(_podOf(tester, 'u4').seat!.status, SeatState.active);
      expect(state.notice, isNull);

      // A breath before the hit: still face down.
      await tester.pump(HammerTiming.impact - _ms(80));
      expect(_podOf(tester, 'u4').revealed, isNull);
      expect(_private('_OwnHandName'), findsNothing);

      // The hit: the hands turn over, the winner's is named — and the loser
      // is still sitting in the hand while their cards flip.
      await tester.pump(_ms(120));
      await tester.pump();
      expect(_podOf(tester, 'u4').revealed, _cards['u4']);
      expect(find.text('Trail'), findsOneWidget);
      expect(_private('_OwnHandName'), findsOneWidget);
      expect(_podOf(tester, 'u4').seat!.status, SeatState.active);
      expect(state.notice, isNull);

      // The result: the loser folds and the table is told.
      await tester.pump(HammerTiming.result - HammerTiming.impact);
      await tester.pump();
      expect(_podOf(tester, 'u4').seat!.status, SeatState.packed);
      expect(state.notice, 'You forced a sideshow with Player 4');
      expect(_podOf(tester, 'u4').revealed, _cards['u4']);

      // Gone: no hammer left in the air, the cards stay up for their look.
      await tester.pump(HammerTiming.total - HammerTiming.result);
      await tester.pump();
      expect(state.hammerStrike, isNull);
      expect(find.byType(HammerFlight), findsNothing);
      expect(_jolting(tester), isEmpty);
      expect(_podOf(tester, 'u4').revealed, _cards['u4']);

      await _teardown(tester, state);
    },
  );

  testWidgets('an ordinary sideshow shows its cards at once and no hammer', (
    tester,
  ) async {
    final state = _newState();
    // u4 asked the viewer, and the viewer accepted: the request is pending in
    // the snapshot until after the loser's pack.
    final pending = {
      'fromUserId': 'u0',
      'fromSeat': 0,
      'toUserId': 'u4',
      'toSeat': 4,
      'expiresAt': 0,
    };
    state.room = _room(pending: pending);
    await _pumpTable(tester, state);

    state
      ..handleSideshowReveal(
        _reveal('u0', 'u4', packed: 'u4', reason: SideshowReason.accepted),
      )
      ..handleTableAction(_packFor('u4'));
    expect(state.hammerStrike, isNull);
    expect(state.foldHeldFor('u4'), isFalse);
    state
      ..handleState(_room(packed: {'u4'}))
      ..handleSideshowDone(
        _done('u0', 'u4', packed: 'u4', reason: SideshowReason.accepted),
      );
    await tester.pump();
    await tester.pump(_ms(16));

    expect(state.hammerStrike, isNull);
    expect(find.byType(HammerFlight), findsNothing);
    expect(_jolting(tester), isEmpty);
    expect(_podOf(tester, 'u4').revealed, _cards['u4']);
    expect(_podOf(tester, 'u4').seat!.status, SeatState.packed);

    await tester.pump(const Duration(seconds: 2));
    expect(find.byType(HammerFlight), findsNothing);

    await _teardown(tester, state);
  });

  // The owner's hammer sound (26 Sep 2026: "when someone hit force side show
  // then this sound should be played"): once per Force Sideshow, for every
  // player at the table, its strike landing with the hammer.
  group('the hammer is heard', () {
    /// Frame by frame for [total], as a phone draws them.
    Future<void> frames(WidgetTester tester, Duration total) async {
      for (var t = Duration.zero; t < total; t += _ms(16)) {
        await tester.pump(_ms(16));
      }
    }

    testWidgets('by a bystander, once, as it lands', (tester) async {
      final state = _newState();
      final sounds = _Heard(() => tester.binding.clock.now());
      await _pumpTable(tester, state, sounds: sounds);

      state
        ..handleTableAction(_packFor('u1'))
        ..handleState(_room(packed: {'u1'}))
        ..handleSideshowDone(_done('u2', 'u1', packed: 'u1'));
      final thrown = tester.binding.clock.now();
      await tester.pump();
      await frames(tester, _ms(600));
      expect(sounds.hammers, isEmpty, reason: 'not while it is in the air');

      // The same resolution twice throws, and sounds, one hammer.
      state.handleSideshowDone(_done('u2', 'u1', packed: 'u1'));
      await frames(tester, HammerTiming.total);
      expect(sounds.hammers, hasLength(1));
      // Started 90 ms before the impact, so the clip's strike (90–100 ms in)
      // comes with the hammer — within a few frames: the felt starts the
      // strike's clock where the real clock says it has got to since the
      // event, which a test's frames only approximate.
      expect(
        sounds.hammers.single.difference(thrown).inMilliseconds,
        inInclusiveRange(
          HammerTiming.sound.inMilliseconds - 50,
          HammerTiming.sound.inMilliseconds + 50,
        ),
      );
      expect(
        (HammerTiming.impact - HammerTiming.sound).inMilliseconds,
        inInclusiveRange(80, 100),
      );

      await _teardown(tester, state);
    });

    testWidgets('by the player who forced it', (tester) async {
      final state = _newState();
      final sounds = _Heard(() => tester.binding.clock.now());
      await _pumpTable(tester, state, sounds: sounds);

      state
        ..handleSideshowReveal(_reveal('u0', 'u4', packed: 'u4'))
        ..handleTableAction(_packFor('u4'))
        ..handleState(_room(packed: {'u4'}))
        ..handleSideshowDone(_done('u0', 'u4', packed: 'u4'));
      await tester.pump();
      await frames(tester, HammerTiming.total + _ms(200));
      expect(sounds.hammers, hasLength(1));

      await _teardown(tester, state);
    });

    testWidgets('never for an ordinary sideshow', (tester) async {
      final state = _newState();
      final sounds = _Heard(() => tester.binding.clock.now());
      state.room = _room(
        pending: {
          'fromUserId': 'u0',
          'fromSeat': 0,
          'toUserId': 'u4',
          'toSeat': 4,
          'expiresAt': 0,
        },
      );
      await _pumpTable(tester, state, sounds: sounds);

      state
        ..handleSideshowReveal(
          _reveal('u0', 'u4', packed: 'u4', reason: SideshowReason.accepted),
        )
        ..handleTableAction(_packFor('u4'))
        ..handleState(_room(packed: {'u4'}))
        ..handleSideshowDone(
          _done('u0', 'u4', packed: 'u4', reason: SideshowReason.accepted),
        );
      await tester.pump();
      await frames(tester, HammerTiming.total + _ms(200));
      expect(sounds.hammers, isEmpty);

      await _teardown(tester, state);
    });
  });

  test(
    "the owner's hammer clip is bundled where the table plays it from",
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      expect(FeedbackSettings.hammerHitClip, 'sound/hammer hit.mp3');
      final clip = await rootBundle.load(
        'assets/${FeedbackSettings.hammerHitClip}',
      );
      expect(clip.lengthInBytes, greaterThan(10000));
    },
  );

  const screens = [Size(640, 360), Size(891, 411), Size(1280, 800)];
  for (final screen in screens) {
    final name = '${screen.width.toInt()}x${screen.height.toInt()}';
    testWidgets(
      'at $name a new hand mid-flight takes the hammer down cleanly',
      (tester) async {
        final state = _newState();
        await _pumpTable(tester, state, screen: screen);

        _viewerForcesAndWins(state);
        await tester.pump();
        // Through launch, most of the flight and into the swing, frame by
        // frame, so every stage of the painter runs at this size.
        for (var i = 0; i < 50; i++) {
          await tester.pump(_ms(16));
        }
        expect(find.byType(HammerFlight), findsOneWidget);
        expect(_jolting(tester), hasLength(1));

        // The next deal lands while the hammer is still in the air.
        state.handleState(_room(handNo: 5));
        await tester.pump();
        await tester.pump(_ms(16));
        expect(state.hammerStrike, isNull);
        expect(state.shownSideshowReveal, isNull);
        expect(state.foldHeldFor('u4'), isFalse);
        expect(find.byType(HammerFlight), findsNothing);
        expect(_jolting(tester), isEmpty);
        expect(_podOf(tester, 'u4').revealed, isNull);
        expect(_podOf(tester, 'u4').seat!.status, SeatState.active);

        // The old strike's timers find nothing to change, and never raise
        // its news over the new hand.
        await tester.pump(const Duration(seconds: 3));
        expect(state.notice, isNull);
        expect(find.byType(HammerFlight), findsNothing);

        // And the next forced sideshow in the new hand flies again.
        state
          ..handleSideshowReveal(_reveal('u0', 'u4', packed: 'u4'))
          ..handleState(_room(handNo: 5, packed: {'u4'}))
          ..handleSideshowDone(_done('u0', 'u4', packed: 'u4'));
        await tester.pump();
        await tester.pump(_ms(16));
        expect(find.byType(HammerFlight), findsOneWidget);
        for (var i = 0; i < 100; i++) {
          await tester.pump(_ms(16));
        }
        expect(state.hammerStrike, isNull);
        expect(find.byType(HammerFlight), findsNothing);
        expect(tester.takeException(), isNull);

        await _teardown(tester, state);
      },
    );
  }
}
