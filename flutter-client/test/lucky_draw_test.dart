// The Lucky Draw on the client (owner, 24 Sep 2026): a wheel of six prizes
// the SERVER spins. The client asks for a spin and nothing more; the server
// draws the slot, grants the prize and says where the wheel must stop. These
// hold the wire (the prizes and the spin read as sent, the spin sends only its
// key and the draw), the wheel's geometry (the slot the server names is the
// slot under the needle), the countdown, and the screen: the lobby's key opens
// it, it shows six prizes, the key goes quiet while a spin is out, the wheel
// stops where the server said, the prize is shown, and the wait after it
// counts down — on the tightest phone, in all five languages.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/lucky_draw_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/glass_components.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

const _server = 'http://127.0.0.1:9';
const _threeDays = 3 * 24 * 60 * 60 * 1000;

/// The owner's beginner draw, as GET /api/lucky-draw sends it.
const _beginnerSlots = [
  {
    'slotNumber': 1,
    'rewardType': 'HAMMER',
    'rewardValue': 1,
    'rewardRefId': null,
  },
  {
    'slotNumber': 2,
    'rewardType': 'HAMMER',
    'rewardValue': 4,
    'rewardRefId': null,
  },
  {
    'slotNumber': 3,
    'rewardType': 'CHIPS',
    'rewardValue': 1000000,
    'rewardRefId': null,
  },
  {
    'slotNumber': 4,
    'rewardType': 'CHIPS',
    'rewardValue': 100000,
    'rewardRefId': null,
  },
  {
    'slotNumber': 5,
    'rewardType': 'NO_REWARD',
    'rewardValue': 0,
    'rewardRefId': null,
  },
  {
    'slotNumber': 6,
    'rewardType': 'CHIPS',
    'rewardValue': 500000,
    'rewardRefId': null,
  },
];

Map<String, dynamic> _drawJson({
  int nextSpinAt = 0,
  List<Map<String, dynamic>> slots = _beginnerSlots,
}) => {
  'draw': {
    'code': 'BEGINNER_LUCKY_DRAW',
    'name': 'Beginner Lucky Draw',
    'spinnerType': 'BEGINNER',
    'cooldownMs': _threeDays,
  },
  'slots': slots,
  'nextSpinAt': nextSpinAt,
};

Map<String, dynamic> _userJson({int chips = 300000, int hammer = 20}) => {
  'id': 'u1',
  'provider': 'guest',
  'displayName': 'Ravi',
  'chips': chips,
  'diamond': 9,
  'hammer': hammer,
  'missile': 1,
  'rewards': {
    'milestoneAvailable': false,
    'milestoneReward': 25000,
    'handsToNextMilestone': 4,
    'bonusReward': 10000,
    'bonusReadyAt': DateTime.now()
        .add(const Duration(hours: 3))
        .millisecondsSinceEpoch,
    'bonusAvailable': false,
    'dailyReward': 100000,
    'dailyHammers': 1,
    'dailyReadyAt': DateTime.now()
        .add(const Duration(hours: 20))
        .millisecondsSinceEpoch,
    'dailyAvailable': false,
  },
};

/// What POST /api/lucky-draw/spin answers for a spin landing on [slot].
Map<String, dynamic> _spinJson(
  int slot,
  Map<String, dynamic> reward, {
  bool alreadyOwned = false,
  int chips = 300000,
}) => {
  'actionId': 'answered',
  'slotNumber': slot,
  'reward': reward,
  'alreadyOwned': alreadyOwned,
  'replayed': false,
  'nextSpinAt': DateTime.now().millisecondsSinceEpoch + _threeDays,
  'user': _userJson(chips: chips),
};

GameState _state({AppLang lang = AppLang.english, Map<String, dynamic>? draw}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: _server);
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = Screen.lobby
    ..debugToken = 'tok'
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
      ],
    })
    ..user = User.fromJson(_userJson())
    ..luckyDraw = LuckyDrawState.fromJson(draw ?? _drawJson());
}

/// A fake server: GET /api/lucky-draw answers [draw]; the spin answers
/// [spin] once [release] completes (at once without one). Every request is
/// kept in [sent].
MockClient _server0({
  required List<http.Request> sent,
  Map<String, dynamic>? draw,
  Map<String, dynamic>? spin,
  Completer<void>? release,
  http.Response? spinResponse,
}) => MockClient((request) async {
  sent.add(request);
  if (request.url.path == '/api/lucky-draw') {
    return http.Response(jsonEncode(draw ?? _drawJson()), 200);
  }
  if (request.url.path == '/api/lucky-draw/spin') {
    if (release != null) await release.future;
    return spinResponse ?? http.Response(jsonEncode(spin), 200);
  }
  return http.Response(jsonEncode({'error': 'not_found'}), 404);
});

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

Widget _app(GameState state, FeedbackSettings feedback, Widget home) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withScriptFallback(AppTheme.dark(sound: false)),
        builder: (context, child) => GlassBudget(child: child!),
        home: home,
      ),
    );

/// A bare page with a key that opens the Lucky Draw, as the lobby's does.
Future<void> _openDraw(WidgetTester tester, GameState state) async {
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
              onPressed: () => showLuckyDraw(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// Nothing pumped in the tree ends the wheel's lights, the lobby's drifting
/// chips and the glyph's turn before the state is disposed.
Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

GlassButton _spinKey(WidgetTester tester) =>
    tester.widget<GlassButton>(find.byKey(const ValueKey('lucky-spin')));

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadScriptFonts();
  });

  group('the wire', () {
    test('the draw reads its six prizes in wheel order, and no weight', () {
      final draw = LuckyDrawState.fromJson(
        _drawJson(slots: _beginnerSlots.reversed.toList()),
      );
      expect(draw.code, 'BEGINNER_LUCKY_DRAW');
      expect(draw.spinnerType, 'BEGINNER');
      expect(draw.cooldownMs, _threeDays);
      expect(draw.slots.map((s) => s.slotNumber), [1, 2, 3, 4, 5, 6]);
      expect(draw.slots[2].prize.type, LuckyReward.chips);
      expect(draw.slots[2].prize.amount, 1000000);
      expect(draw.slots[4].prize.isNothing, isTrue);
      expect(draw.readyAt(DateTime.now()), isTrue);
    });

    test('a picture prize carries its catalogue row', () {
      final draw = LuckyDrawState.fromJson(
        _drawJson(
          slots: [
            {
              'slotNumber': 1,
              'rewardType': 'PROFILE_PICTURE',
              'rewardValue': null,
              'rewardRefId': '23',
              'picture': {
                'id': 23,
                'name': 'Lovestruck Cat',
                'url': '',
                'assetFormat': 'LOTTIE',
                'currency': 'HAMMER',
                'type': 'PREMIUM',
                'cost': 50,
                'durationDays': 50,
                'owned': false,
              },
            },
            {
              'slotNumber': 2,
              'rewardType': 'TABLE_PICTURE',
              'rewardRefId': '5',
              'tablePicture': {
                'id': 5,
                'name': 'Circle Background Pattern',
                'dayUrl': '',
                'nightUrl': '',
                'type': 'PREMIUM',
                'cost': 300000,
                'durationDays': 7,
              },
            },
          ],
        ),
      );
      final cat = draw.slots[0].prize;
      expect(cat.isPicture, isTrue);
      expect(cat.refId, '23');
      expect(cat.picture?.name, 'Lovestruck Cat');
      expect(cat.value, isNull);
      expect(draw.slots[1].prize.tablePicture?.durationDays, 7);
      expect(draw.slots[1].prize.pictureName, 'Circle Background Pattern');
    });

    test('GET: a server with no draw, or none open, shows none', () async {
      for (final status in [404, 503]) {
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({'error': 'lucky_draw_unavailable'}),
            status,
          ),
        );
        final draw = await http.runWithClient(
          () => ApiClient('http://api.test').luckyDraw('tok'),
          () => client,
        );
        expect(draw, isNull, reason: '$status');
      }
    });

    test('a spin sends its key and the draw — never a prize', () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode(
            _spinJson(3, {'type': 'CHIPS', 'value': 1000000, 'refId': null}),
          ),
          200,
        );
      });
      final spin = await http.runWithClient(
        () => ApiClient(
          'http://api.test',
        ).spinLuckyDraw('tok', 'key-1', code: 'BEGINNER_LUCKY_DRAW'),
        () => client,
      );
      expect(sent.method, 'POST');
      expect(sent.url.toString(), 'http://api.test/api/lucky-draw/spin');
      expect(sent.headers['Authorization'], 'Bearer tok');
      expect(jsonDecode(sent.body), {
        'actionId': 'key-1',
        'code': 'BEGINNER_LUCKY_DRAW',
      });
      expect(spin.slotNumber, 3);
      expect(spin.prize.amount, 1000000);
      expect(spin.user?.id, 'u1');
    });

    test('a spin before the wheel recharges says when it will', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': 'lucky_draw_not_ready',
            'message': 'Your next Lucky Draw spin is not ready yet.',
            'readyAt': 1234567890000,
          }),
          409,
        ),
      );
      await expectLater(
        http.runWithClient(
          () => ApiClient('http://api.test').spinLuckyDraw('tok', 'k'),
          () => client,
        ),
        throwsA(
          isA<LuckyDrawNotReady>()
              .having((e) => e.readyAt, 'readyAt', 1234567890000)
              .having((e) => e.code, 'code', 'lucky_draw_not_ready'),
        ),
      );
      final seated = MockClient(
        (_) async => http.Response(
          jsonEncode({'error': 'seated', 'message': 'lobby'}),
          409,
        ),
      );
      await expectLater(
        http.runWithClient(
          () => ApiClient('http://api.test').spinLuckyDraw('tok', 'k'),
          () => seated,
        ),
        throwsA(
          isA<ApiException>()
              .having((e) => e is LuckyDrawNotReady, 'not ready', isFalse)
              .having((e) => e.code, 'code', 'seated'),
        ),
      );
    });
  });

  group('the wheel', () {
    test('each slot rests under the needle, and is read back from there', () {
      for (var slot = 1; slot <= 6; slot++) {
        expect(luckySlotAt(luckyRestAngle(slot)), slot);
        // Whole turns change nothing.
        expect(luckySlotAt(luckyRestAngle(slot) + 720), slot);
        expect(luckySlotAt(luckyRestAngle(slot) - 1080), slot);
      }
    });

    test('a spin runs at least five turns on and stops in its slot', () {
      for (final from in [0.0, 17.5, 180.0, 359.9, -45.0]) {
        for (var slot = 1; slot <= 6; slot++) {
          for (final nudge in [-10.0, 0.0, 10.0, 40.0]) {
            final to = luckySpinTarget(
              from: from,
              slotNumber: slot,
              nudge: nudge,
            );
            expect(to - from, greaterThanOrEqualTo(5 * 360));
            expect(to - from, lessThan(6 * 360));
            expect(luckySlotAt(to), slot, reason: 'from $from nudge $nudge');
          }
        }
      }
      // The nudge never takes the needle out of the wedge.
      for (final id in ['a', 'b', 'answered', 'a-much-longer-key-0123456789']) {
        expect(luckyNudge(id).abs(), lessThanOrEqualTo(10));
      }
    });

    test('a spin gathers speed gently and runs down slowly to rest', () {
      const curve = LuckySpinCurve();
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
      var last = 0.0;
      for (var i = 1; i <= 1000; i++) {
        final t = i / 1000;
        final p = curve.transform(t);
        expect(p, greaterThanOrEqualTo(last), reason: 'at $t');
        // The speed is the run's slope, and never jumps.
        if (i < 1000) {
          expect(
            (curve.speedAt(t) - curve.speedAt(t - 0.001)).abs(),
            lessThan(0.02),
            reason: 'at $t',
          );
        }
        last = p;
      }
      // At rest at both ends, full speed between.
      expect(curve.speedAt(0.002), lessThan(0.01));
      expect(curve.speedAt(0.998), lessThan(0.001));
      expect(curve.speedAt(0.3), 1);
      // Of six seconds: the first covers a tenth of the turn, the last well
      // under a hundredth.
      const second = 1 / 6;
      expect(curve.transform(second), lessThan(0.12));
      expect(1 - curve.transform(1 - second), lessThan(0.01));
      expect(LuckyDrawScreen.spinTime, const Duration(seconds: 6));
    });

    test('the rim bulbs blink lit and unlit, and nothing else changes', () {
      // The file's two bulb colours, and the orange ring round each bulb.
      const ivory = Color.from(alpha: 1, red: 1, green: 1, blue: 0.961);
      const yellow = Color.from(alpha: 1, red: 0.935, green: 1, blue: 0.212);
      const ring = Color.from(alpha: 1, red: 0.957, green: 0.404, blue: 0.216);
      expect(luckyBulbColour(yellow), luckyBulbLit);
      expect(luckyBulbColour(ivory), luckyBulbUnlit);
      expect(luckyBulbColour(ring), ring);
    });

    test('the badge of the slot at rest stands straight above the hub', () {
      const h = 264.0;
      final hub = LuckyWheel.hubCentre(h);
      for (var slot = 1; slot <= 6; slot++) {
        final c = LuckyWheel.badgeCentre(slot, luckyRestAngle(slot), h);
        expect(c.dx, closeTo(hub.dx, 0.001));
        expect(c.dy, lessThan(hub.dy));
      }
    });
  });

  test('the wait reads as hours, minutes and seconds past a day', () {
    expect(formatSpinClock(const Duration(days: 3)), '72:00:00');
    expect(
      formatSpinClock(const Duration(hours: 71, minutes: 59, seconds: 59)),
      '71:59:59',
    );
    expect(formatSpinClock(const Duration(milliseconds: 1)), '00:00:01');
    expect(formatSpinClock(Duration.zero), '00:00:00');
    expect(formatSpinClock(const Duration(seconds: -5)), '00:00:00');
  });

  test('every word of the Lucky Draw is in all five languages', () {
    const keys = [
      'luckyDrawChip',
      'luckyDrawTitle',
      'luckySpinReady',
      'luckySpinNow',
      'luckySpinning',
      'luckyNextSpin',
      'luckyEvery',
      'luckyPrizes',
      'luckyNoPrize',
      'luckyCongrats',
      'luckyYouWon',
      'luckyNothingTitle',
      'luckyNothingBody',
      'luckyAlreadyOwned',
      'luckyPictureFor',
      'luckyWearNow',
      'luckyLayNow',
      'luckyProfilePicture',
      'luckyTablePicture',
      'luckyClosed',
      'luckyLoadFailed',
      'luckyRetry',
      'luckyLobbyOnly',
      'luckyNotReady',
      'countMissileOne',
      'countMissiles',
    ];
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final key in keys) {
        expect(t.ownEntry(key), isNotNull, reason: '${lang.name} $key');
      }
      expect(t.luckyEvery('3 x'), contains('3 x'));
      expect(t.countMissiles(2), contains('2'));
    }
  });

  group('the lobby', () {
    Future<void> pumpLobby(WidgetTester tester, GameState state) async {
      await _setView(tester, textScale: 1.25);
      final feedback = FeedbackSettings();
      addTearDown(feedback.dispose);
      await tester.pumpWidget(_app(state, feedback, const LobbyScreen()));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('its Lucky Draw key opens the Lucky Draw', (tester) async {
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = _state();
        await pumpLobby(tester, state);
        final chip = find.byKey(const ValueKey('lucky-draw-chip'));
        expect(chip, findsOneWidget);
        expect(
          find.descendant(of: chip, matching: find.text('LUCKY DRAW')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: chip, matching: find.text('Spin now')),
          findsOneWidget,
        );
        await tester.tap(chip);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(LuckyDrawScreen), findsOneWidget);
        expect(find.text('Lucky Draw'), findsOneWidget);
        // Opening reads the draw again.
        expect(sent.map((r) => r.url.path), contains('/api/lucky-draw'));
        await _unmount(tester, state);
      }, () => _server0(sent: sent));
    });

    testWidgets('while the wheel recharges the key counts down', (
      tester,
    ) async {
      final state = _state(
        draw: _drawJson(
          nextSpinAt: DateTime.now()
              .add(const Duration(hours: 50))
              .millisecondsSinceEpoch,
        ),
      );
      await pumpLobby(tester, state);
      final chip = find.byKey(const ValueKey('lucky-draw-chip'));
      expect(
        find.descendant(
          of: chip,
          matching: find.textContaining(RegExp(r'^(49|50):\d\d:\d\d$')),
        ),
        findsOneWidget,
      );
      await _unmount(tester, state);
    });

    testWidgets('while the draw first loads, the room of its key is kept', (
      tester,
    ) async {
      final state = _state()
        ..luckyDraw = null
        ..luckyDrawLoading = true;
      await pumpLobby(tester, state);
      expect(find.byKey(const ValueKey('lucky-draw-chip')), findsNothing);
      final held = find.ancestor(
        of: find.text('LUCKY DRAW'),
        matching: find.byType(Visibility),
      );
      expect(held, findsOneWidget);
      expect(tester.widget<Visibility>(held).visible, isFalse);
      expect(tester.getSize(held).width, greaterThan(100));
      await _unmount(tester, state);
    });

    testWidgets('a server with no draw shows no key', (tester) async {
      final state = _state()..luckyDraw = null;
      await pumpLobby(tester, state);
      expect(find.byKey(const ValueKey('lucky-draw-chip')), findsNothing);
      await _unmount(tester, state);
    });
  });

  group('the screen', () {
    setUp(() async {
      await AssetLottie(luckySpinnerAsset).load();
    });

    testWidgets('shows the six prizes on the wheel and beside it', (
      tester,
    ) async {
      await _setView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = _state();
        await _openDraw(tester, state);
        for (var slot = 1; slot <= 6; slot++) {
          expect(
            find.byKey(ValueKey('lucky-badge-$slot')),
            findsOneWidget,
            reason: 'badge $slot',
          );
          expect(
            find.byKey(ValueKey('lucky-slot-$slot')),
            findsOneWidget,
            reason: 'tile $slot',
          );
        }
        expect(find.text('10 Lakh chips'), findsOneWidget);
        expect(find.text('4 hammers'), findsOneWidget);
        expect(find.text('No prize'), findsOneWidget);
        expect(find.text('One free spin every 3 days.'), findsOneWidget);
        expect(find.text('SPIN NOW'), findsOneWidget);
        expect(_spinKey(tester).onPressed, isNotNull);
        await _unmount(tester, state);
      }, () => _server0(sent: sent));
    });

    testWidgets('the wheel stops on the slot the server drew, and shows it', (
      tester,
    ) async {
      await _setView(tester);
      final sent = <http.Request>[];
      final release = Completer<void>();
      await http.runWithClient(
        () async {
          final state = _state();
          await _openDraw(tester, state);
          final before = tester.widget<LuckyWheel>(find.byType(LuckyWheel));
          expect(luckySlotAt(before.angle), 1);

          await tester.tap(find.byKey(const ValueKey('lucky-spin')));
          await tester.pump();
          // Out with the server: the key is quiet and the wheel has not moved.
          expect(find.text('SPINNING…'), findsOneWidget);
          expect(_spinKey(tester).onPressed, isNull);
          expect(
            tester.widget<LuckyWheel>(find.byType(LuckyWheel)).angle,
            before.angle,
          );
          final spinRequest = sent.lastWhere(
            (r) => r.url.path == '/api/lucky-draw/spin',
          );
          final body = jsonDecode(spinRequest.body) as Map<String, dynamic>;
          expect(body.keys.toSet(), {'actionId', 'code'});
          expect(body['code'], 'BEGINNER_LUCKY_DRAW');
          // A second tap sends nothing.
          await tester.tap(find.byKey(const ValueKey('lucky-spin')));
          await tester.pump();
          expect(
            sent.where((r) => r.url.path == '/api/lucky-draw/spin'),
            hasLength(1),
          );

          // The server draws slot 4; the wheel turns there.
          release.complete();
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(find.text('SPINNING…'), findsOneWidget);
          final mid = tester.widget<LuckyWheel>(find.byType(LuckyWheel));
          expect(mid.angle, isNot(before.angle));
          await tester.pump(LuckyDrawScreen.spinTime);
          await tester.pump(const Duration(milliseconds: 600));

          final after = tester.widget<LuckyWheel>(find.byType(LuckyWheel));
          expect(luckySlotAt(after.angle), 4);
          expect(after.won, 4);
          // Its badge is the one at the top, under the needle.
          final tops = {
            for (var slot = 1; slot <= 6; slot++)
              slot: tester.getCenter(find.byKey(ValueKey('lucky-badge-$slot'))),
          };
          final highest = tops.entries.reduce(
            (a, b) => a.value.dy <= b.value.dy ? a : b,
          );
          expect(highest.key, 4);

          // The prize.
          expect(find.byKey(const ValueKey('lucky-result')), findsOneWidget);
          expect(find.text('Congratulations!'), findsOneWidget);
          expect(find.text('You won'), findsOneWidget);
          expect(
            tester
                .widget<Text>(find.byKey(const ValueKey('lucky-result-prize')))
                .data,
            '100,000 chips',
          );
          // The wallet took the server's figure.
          expect(state.user?.chips, 400000);

          // Closed, the key counts down to the next spin.
          await tester.tap(find.text('Close'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byKey(const ValueKey('lucky-result')), findsNothing);
          expect(find.text('NEXT SPIN'), findsOneWidget);
          expect(
            tester
                .widget<Text>(find.byKey(const ValueKey('lucky-next-spin')))
                .data,
            matches(RegExp(r'^7[12]:\d\d:\d\d$')),
          );
          expect(_spinKey(tester).onPressed, isNull);
          await _unmount(tester, state);
        },
        () => _server0(
          sent: sent,
          release: release,
          spin: _spinJson(4, {
            'type': 'CHIPS',
            'value': 100000,
            'refId': null,
          }, chips: 400000),
        ),
      );
    });

    testWidgets('the empty slot says better luck next time', (tester) async {
      await _setView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = _state();
          await _openDraw(tester, state);
          await tester.tap(find.byKey(const ValueKey('lucky-spin')));
          await tester.pump();
          await tester.pump();
          await tester.pump(LuckyDrawScreen.spinTime);
          await tester.pump(const Duration(milliseconds: 600));
          expect(
            luckySlotAt(
              tester.widget<LuckyWheel>(find.byType(LuckyWheel)).angle,
            ),
            5,
          );
          expect(find.text('Better luck next time!'), findsOneWidget);
          expect(find.text('Congratulations!'), findsNothing);
          await _unmount(tester, state);
        },
        () => _server0(
          sent: sent,
          spin: _spinJson(5, {'type': 'NO_REWARD', 'value': 0, 'refId': null}),
        ),
      );
    });

    testWidgets('a refused spin leaves the wheel where it was', (tester) async {
      await _setView(tester);
      final sent = <http.Request>[];
      final readyAt = DateTime.now()
          .add(const Duration(hours: 30))
          .millisecondsSinceEpoch;
      await http.runWithClient(
        () async {
          final state = _state();
          await _openDraw(tester, state);
          await tester.tap(find.byKey(const ValueKey('lucky-spin')));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          expect(
            luckySlotAt(
              tester.widget<LuckyWheel>(find.byType(LuckyWheel)).angle,
            ),
            1,
          );
          expect(find.byKey(const ValueKey('lucky-result')), findsNothing);
          // The server's moment is the one counted down to.
          expect(state.luckyDraw?.nextSpinAt, readyAt);
          expect(find.text('NEXT SPIN'), findsOneWidget);
          await _unmount(tester, state);
        },
        () => _server0(
          sent: sent,
          spinResponse: http.Response(
            jsonEncode({
              'error': 'lucky_draw_not_ready',
              'message': 'Your next Lucky Draw spin is not ready yet.',
              'readyAt': readyAt,
            }),
            409,
          ),
        ),
      );
    });

    testWidgets('while the wheel recharges it shows the wait', (tester) async {
      await _setView(tester);
      final sent = <http.Request>[];
      final draw = _drawJson(
        nextSpinAt: DateTime.now()
            .add(const Duration(hours: 5, minutes: 3))
            .millisecondsSinceEpoch,
      );
      await http.runWithClient(() async {
        final state = _state(draw: draw);
        await _openDraw(tester, state);
        expect(find.text('NEXT SPIN'), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('lucky-next-spin')))
              .data,
          matches(RegExp(r'^05:0[23]:\d\d$')),
        );
        expect(_spinKey(tester).onPressed, isNull);
        await _unmount(tester, state);
      }, () => _server0(sent: sent, draw: draw));
    });

    for (final lang in AppLang.values) {
      testWidgets(
        'fits a 640x360 phone at text x1.25 in ${lang.name}, prize and all',
        (tester) async {
          await _setView(tester, textScale: 1.25);
          final sent = <http.Request>[];
          await http.runWithClient(
            () async {
              final state = _state(lang: lang);
              await _openDraw(tester, state);
              expect(find.byType(LuckyWheel), findsOneWidget);
              await tester.tap(find.byKey(const ValueKey('lucky-spin')));
              await tester.pump();
              await tester.pump();
              await tester.pump(LuckyDrawScreen.spinTime);
              await tester.pump(const Duration(milliseconds: 600));
              expect(
                find.byKey(const ValueKey('lucky-result')),
                findsOneWidget,
              );
              await _unmount(tester, state);
            },
            () => _server0(
              sent: sent,
              spin: _spinJson(1, {
                'type': 'PROFILE_PICTURE',
                'value': null,
                'refId': '23',
                'picture': {
                  'id': 23,
                  'name': 'Lovestruck Cat',
                  'url': '',
                  'assetFormat': 'LOTTIE',
                  'currency': 'HAMMER',
                  'type': 'PREMIUM',
                  'cost': 50,
                  'durationDays': 50,
                  'owned': true,
                },
              }),
            ),
          );
        },
      );
    }
  });
}
