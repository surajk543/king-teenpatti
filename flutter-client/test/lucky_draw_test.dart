// The Lucky Draw on the client (owner, 24 Sep 2026): a wheel of six prizes
// the SERVER spins. The client asks for a spin and nothing more; the server
// draws the slot, grants the prize and says where the wheel must stop. These
// hold the wire (the prizes and the spin read as sent, the spin sends only its
// key and the draw), the wheel's geometry (the slot the server names is the
// slot under the needle), the countdown, and the screen: the lobby's key opens
// it, it shows six prizes, the key goes quiet while a spin is out, the wheel
// stops where the server said, the prize is shown, and the wait after it
// counts down — on the tightest phone, in all five languages.
//
// And the polish of 26 Sep 2026: the wheel starts to turn at the tap and the
// server's answer, whenever it comes, lands it on the server's slot with no
// jolt (or, refused, runs it down with no prize); at rest its wedge and its
// tile are lit, and only they, before the prize is shown; the key is struck
// gold while a spin is due and says NEXT FREE SPIN over the server's wait
// while it is not; each tile leads with its figure; and the wheel stands a
// tenth larger than it did.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:teenpatti/widgets/fireworks.dart';
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

/// Whether the Lucky Draw's key can be pressed: the gold key's own ink, with
/// a tap behind it. The keys that cannot be pressed have none.
bool _canSpin(WidgetTester tester) => find
    .descendant(
      of: find.byKey(const ValueKey('lucky-spin')),
      matching: find.byType(InkWell),
    )
    .evaluate()
    .any((e) => (e.widget as InkWell).onTap != null);

/// Frames, as a phone draws them, until the wheel is at rest on its prize;
/// how long that took.
Future<Duration> _untilWon(
  WidgetTester tester, {
  Duration frame = const Duration(milliseconds: 50),
}) async {
  final wheel = find.byType(LuckyWheel);
  var waited = Duration.zero;
  while (tester.widget<LuckyWheel>(wheel).won == null) {
    if (waited > const Duration(seconds: 20)) {
      fail('the wheel never came to rest');
    }
    await tester.pump(frame);
    waited += frame;
  }
  return waited;
}

/// A tile's words: what is written in slot [slot]'s tile.
Finder _inTile(int slot, String text) => find.descendant(
  of: find.byKey(ValueKey('lucky-slot-$slot')),
  matching: find.text(text),
);

/// The wheel's angle now.
double _angle(WidgetTester tester) =>
    tester.widget<LuckyWheel>(find.byType(LuckyWheel)).angle;

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

  group('the spin, from the tap (26 Sep 2026)', () {
    /// Every millisecond of [motion] from the tap to rest: the turn never runs
    /// backwards, and neither the angle nor the speed ever jumps — the speed
    /// changes by less than a degree a second from one millisecond to the next.
    void smooth(LuckySpinMotion motion, {required String reason}) {
      var lastX = motion.x(0);
      var lastV = motion.dx(0);
      expect(lastV, 0, reason: '$reason: at rest at the tap');
      final end = motion.restsAt! + 0.2;
      for (var ms = 1; ms / 1000 <= end; ms++) {
        final t = ms / 1000;
        final x = motion.x(t);
        final v = motion.dx(t);
        expect(x, greaterThanOrEqualTo(lastX - 1e-9), reason: '$reason at $t');
        expect(
          (x - lastX).abs(),
          lessThanOrEqualTo(motion.fullSpeed / 1000 + 1e-6),
          reason: '$reason: the angle jumped at $t',
        );
        expect(
          (v - lastV).abs(),
          lessThan(1),
          reason: '$reason: the speed jumped at $t',
        );
        lastX = x;
        lastV = v;
      }
      expect(motion.isDone(end), isTrue, reason: reason);
      expect(motion.dx(end), 0, reason: '$reason: at rest at the end');
    }

    test('it lands on the slot the server drew, whenever the answer comes', () {
      for (final from in [0.0, 17.5, 200.0, -40.0]) {
        for (final now in [0.0, 0.3, 1.2, 2.0, 3.5, 6.0]) {
          for (var slot = 1; slot <= 6; slot++) {
            final motion = LuckySpinMotion(from: from);
            // Before the answer the turn is the same whatever it will be.
            final before = motion.x(now);
            final rests = motion.landOn(slotNumber: slot, now: now, nudge: 7);
            final reason = 'from $from, answered at $now, slot $slot';
            expect(motion.x(now), closeTo(before, 1e-9), reason: reason);
            expect(rests, motion.restsAt, reason: reason);
            expect(motion.x(rests), motion.restAngle, reason: reason);
            expect(luckySlotAt(motion.x(rests)), slot, reason: reason);
            // A few degrees off the wedge's middle, as the nudge asks.
            final off = (motion.restAngle! - luckyRestAngle(slot) - 7) % 360;
            expect(math.min(off, 360 - off), lessThan(1e-6), reason: reason);
            // Five whole turns at the least.
            expect(motion.restAngle! - from, greaterThanOrEqualTo(5 * 360));
            smooth(motion, reason: reason);
          }
        }
      }
    });

    test('answered at once, it rests about six seconds after the tap', () {
      for (var slot = 1; slot <= 6; slot++) {
        for (final from in [0.0, 45.0, 290.0]) {
          final motion = LuckySpinMotion(from: from);
          final rests = motion.landOn(slotNumber: slot, now: 0.4);
          expect(rests, inInclusiveRange(5.6, 6.4), reason: 'slot $slot');
          // It gathers speed for a second and a half, holds under two turns
          // a second, and takes three and a half to run down.
          expect(motion.speedUpFor, 1.5);
          expect(motion.runDownFor, closeTo(3.6, 1e-9));
          expect(motion.fullSpeed, lessThan(2 * 360));
          expect(motion.dx(1.0), lessThan(motion.fullSpeed));
          expect(motion.dx(1.6), motion.fullSpeed);
          // The first second covers a tenth or so of the turn (the curve's
          // own promise, above); the last second far less.
          expect(
            motion.x(1) - from,
            lessThan(0.12 * (motion.restAngle! - from)),
          );
          expect(
            motion.restAngle! - motion.x(rests - 1),
            lessThan(0.01 * (motion.restAngle! - from)),
          );
        }
      }
    });

    test('a late answer keeps full speed until it comes, then runs down', () {
      final motion = LuckySpinMotion(from: 0);
      expect(motion.dx(4), motion.fullSpeed);
      expect(motion.isDone(30), isFalse, reason: 'no answer, no stop');
      final rests = motion.landOn(slotNumber: 3, now: 4);
      expect(rests - 4, inInclusiveRange(3.6, 3.6 + 360 / motion.fullSpeed));
      expect(luckySlotAt(motion.restAngle!), 3);
      smooth(motion, reason: 'late');
    });

    test('refused, it runs down from wherever it is, with no prize', () {
      for (final now in [0.0, 0.2, 0.9, 1.5, 4.0]) {
        final motion = LuckySpinMotion(from: 30);
        final at = motion.x(now);
        final speed = motion.dx(now);
        motion.stop(now: now);
        expect(motion.x(now), closeTo(at, 1e-9));
        expect(motion.dx(now), closeTo(speed, 1e-9));
        expect(motion.restsAt! - now, greaterThanOrEqualTo(0.5 - 1e-9));
        expect(motion.restsAt! - now, lessThanOrEqualTo(motion.runDownFor));
        expect(motion.restAngle!, greaterThanOrEqualTo(at));
        smooth(motion, reason: 'refused at $now');
      }
      // Refused at the tap, it never moves.
      final still = LuckySpinMotion(from: 30)..stop(now: 0);
      expect(still.restAngle, 30);
    });

    test('its parts are the curve the owner chose', () {
      const curve = LuckySpinCurve();
      final motion = LuckySpinMotion(from: 0);
      for (var i = 0; i <= 100; i++) {
        final t = i / 100 * motion.speedUpFor;
        expect(
          motion.dx(t) / motion.fullSpeed,
          closeTo(curve.speedAt(t / 6), 1e-9),
          reason: 'the speed-up at $t',
        );
      }
      motion.landOn(slotNumber: 2, now: 0);
      final leave = motion.restsAt! - motion.runDownFor;
      for (var i = 0; i <= 100; i++) {
        final x = i / 100;
        expect(
          motion.dx(leave + x * motion.runDownFor) / motion.fullSpeed,
          closeTo(curve.speedAt(0.4 + 0.6 * x), 1e-9),
          reason: 'the run-down at $x',
        );
      }
    });

    test('the winning wedge lights in two beats and keeps a glow', () {
      expect(luckyWedgeLight(0), 0);
      expect(luckyWedgeLight(0.18), closeTo(1, 1e-9));
      expect(luckyWedgeLight(0.4), closeTo(0.45, 1e-9));
      expect(luckyWedgeLight(0.58), closeTo(0.85, 1e-9));
      expect(luckyWedgeLight(1), closeTo(0.35, 1e-9));
      for (var i = 1; i <= 1000; i++) {
        expect(
          (luckyWedgeLight(i / 1000) - luckyWedgeLight((i - 1) / 1000)).abs(),
          lessThan(0.02),
        );
      }
    });

    test(
      'the file\'s cream needle is left out and nothing else of the hub',
      () {
        // The file's colours: the cream needle and cap, its gold pin, the
        // orange collar and dark ring, and the collar's shadow.
        const cream = Color.from(
          alpha: 1,
          red: 0.941,
          green: 0.898,
          blue: 0.475,
        );
        const gold = Color.from(alpha: 1, red: 0.961, green: 0.729, blue: 0.2);
        const collar = Color.from(
          alpha: 1,
          red: 0.863,
          green: 0.569,
          blue: 0.18,
        );
        const ring = Color.from(
          alpha: 1,
          red: 0.788,
          green: 0.459,
          blue: 0.165,
        );
        const shadow = Color.from(alpha: 1, red: 0, green: 0, blue: 0);
        expect(luckyHubColour(cream).a, 0);
        for (final c in [gold, collar, ring, shadow]) {
          expect(luckyHubColour(c), c);
        }
      },
    );
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
      'luckyFreeSpin',
      'luckyNextFreeSpin',
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

  group('the tiles', () {
    test(
      'lead with the figure and follow with its word, in every language',
      () {
        const prizes = [
          LuckyPrize(type: LuckyReward.chips, value: 1000000),
          LuckyPrize(type: LuckyReward.chips, value: 100000),
          LuckyPrize(type: LuckyReward.hammer, value: 1),
          LuckyPrize(type: LuckyReward.hammer, value: 4),
          LuckyPrize(type: LuckyReward.diamond, value: 1),
          LuckyPrize(type: LuckyReward.diamond, value: 5),
          LuckyPrize(type: LuckyReward.missile, value: 1),
          LuckyPrize(type: LuckyReward.missile, value: 2),
        ];
        String squeeze(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
        for (final lang in AppLang.values) {
          final t = Strings(lang);
          for (final prize in prizes) {
            final phrase = luckyPrizeLabel(t, prize);
            final parts = luckyPrizeParts(t, prize);
            final figure =
                prize.type == LuckyReward.chips ||
                    prize.type == LuckyReward.diamond
                ? formatChips(prize.amount)
                : '${prize.amount}';
            final reason = '${lang.name}: $phrase';
            expect(parts.amount, startsWith(figure), reason: reason);
            expect(parts.unit, isNotEmpty, reason: reason);
            // Nothing of the sentence lost or added: it reads the same whole.
            expect(
              squeeze('${parts.amount} ${parts.unit}'),
              squeeze(phrase),
              reason: reason,
            );
          }
          const nothing = LuckyPrize(type: LuckyReward.none);
          expect(luckyPrizeParts(t, nothing).amount, t.luckyNoPrize);
          expect(luckyPrizeParts(t, nothing).unit, isEmpty);
        }
        // A picture leads with its name and says what kind it is.
        final cat = LuckyPrize(
          type: LuckyReward.profilePicture,
          picture: ProfilePicture.fromJson({
            'id': 23,
            'name': 'Lovestruck Cat',
            'url': '',
          }),
        );
        final t = Strings(AppLang.english);
        expect(luckyPrizeParts(t, cat), (
          amount: 'Lovestruck Cat',
          unit: 'Profile picture',
        ));
      },
    );

    testWidgets('stand the figure over its word where the tile is tall enough, '
        'and put them on one line where it is not', (tester) async {
      Future<void> tileAt(double height) => tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(sound: false),
          home: Center(
            child: SizedBox(
              width: 170,
              height: height,
              child: LuckyPrizeTile(
                slot: const LuckySlot(
                  slotNumber: 3,
                  prize: LuckyPrize(type: LuckyReward.chips, value: 1000000),
                ),
                t: Strings(AppLang.english),
              ),
            ),
          ),
        ),
      );
      await tileAt(60);
      expect(find.text('10 Lakh'), findsOneWidget);
      expect(find.text('chips'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      // The figure is above its word, and the mark stands beside them.
      expect(
        tester.getCenter(find.text('10 Lakh')).dy,
        lessThan(tester.getCenter(find.text('chips')).dy),
      );
      await tileAt(32);
      expect(find.text('10 Lakh chips'), findsOneWidget);
      expect(tester.takeException(), isNull);
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
        // Each tile leads with its figure, the wallet's word under it…
        expect(_inTile(3, '10 Lakh'), findsOneWidget);
        expect(_inTile(3, 'chips'), findsOneWidget);
        expect(_inTile(2, '4'), findsOneWidget);
        expect(_inTile(2, 'hammers'), findsOneWidget);
        expect(_inTile(1, 'hammer'), findsOneWidget);
        expect(_inTile(5, 'No prize'), findsOneWidget);
        // …and says the whole prize, with its number, to a screen reader.
        final semantics = tester.ensureSemantics();
        await tester.pump();
        expect(find.bySemanticsLabel('3. 10 Lakh chips'), findsOneWidget);
        expect(find.bySemanticsLabel('2. 4 hammers'), findsOneWidget);
        semantics.dispose();
        expect(find.text('One free spin every 3 days.'), findsOneWidget);
        // A free spin is waiting, and the page says so at the top.
        expect(find.byKey(const ValueKey('lucky-free-spin')), findsOneWidget);
        expect(find.text('FREE SPIN'), findsOneWidget);
        expect(find.text('SPIN NOW'), findsOneWidget);
        expect(_canSpin(tester), isTrue);
        expect(
          tester.widget<LuckyWheel>(find.byType(LuckyWheel)).light,
          LuckyWheelLight.ready,
        );
        await _unmount(tester, state);
      }, () => _server0(sent: sent));
    });

    testWidgets('the key is struck gold while a spin is due', (tester) async {
      await _setView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = _state();
        await _openDraw(tester, state);
        final key = find.byType(LuckyGoldKey);
        expect(key, findsOneWidget);
        // The Shop key's and the table's Chaal face, with its press-down.
        final face = tester.widget<Ink>(
          find.descendant(of: key, matching: find.byType(Ink)),
        );
        expect((face.decoration! as BoxDecoration).gradient, AppTheme.goldFace);
        expect(
          find.descendant(of: key, matching: find.byType(PressScale)),
          findsOneWidget,
        );
        expect(
          tester.widget<Text>(find.text('SPIN NOW')).style?.color,
          AppTheme.inkOnLight,
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('lucky-spin'))).height,
          greaterThanOrEqualTo(Dim.minTouch),
        );
        await _unmount(tester, state);
      }, () => _server0(sent: sent));
    });

    testWidgets(
      'the wheel turns from the tap and stops where the server drew',
      (tester) async {
        await _setView(tester);
        final sent = <http.Request>[];
        final release = Completer<void>();
        await http.runWithClient(
          () async {
            final state = _state();
            await _openDraw(tester, state);
            final before = _angle(tester);
            expect(luckySlotAt(before), 1);

            await tester.tap(find.byKey(const ValueKey('lucky-spin')));
            await tester.pump();
            // Out with the server: the key is quiet at once…
            expect(find.text('SPINNING…'), findsOneWidget);
            expect(_canSpin(tester), isFalse);
            expect(find.byKey(const ValueKey('lucky-free-spin')), findsNothing);
            // …and the wheel is already gathering speed, gently: nothing about
            // its turn yet depends on the prize.
            await tester.pump(const Duration(milliseconds: 300));
            final early = _angle(tester);
            expect(early, greaterThan(before));
            expect(early - before, lessThan(20));
            expect(
              tester.widget<LuckyWheel>(find.byType(LuckyWheel)).light,
              LuckyWheelLight.spinning,
            );
            final spinRequest = sent.lastWhere(
              (r) => r.url.path == '/api/lucky-draw/spin',
            );
            final body = jsonDecode(spinRequest.body) as Map<String, dynamic>;
            expect(body.keys.toSet(), {'actionId', 'code'});
            expect(body['code'], 'BEGINNER_LUCKY_DRAW');
            // A second tap sends nothing.
            await tester.tap(
              find.byKey(const ValueKey('lucky-spin')),
              warnIfMissed: false,
            );
            await tester.pump();
            expect(
              sent.where((r) => r.url.path == '/api/lucky-draw/spin'),
              hasLength(1),
            );

            // The server draws slot 4. Its answer does not jolt the wheel…
            final atAnswer = _angle(tester);
            release.complete();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 16));
            expect(_angle(tester) - atAnswer, lessThan(5));
            // …which runs on, and down onto the slot.
            await tester.pump(const Duration(seconds: 1));
            expect(find.text('SPINNING…'), findsOneWidget);
            expect(_angle(tester), greaterThan(early));
            final waited = await _untilWon(tester);
            // About six seconds from the tap.
            final fromTap =
                const Duration(milliseconds: 300 + 16 + 1000) + waited;
            expect(fromTap.inMilliseconds, inInclusiveRange(5600, 6600));

            final after = tester.widget<LuckyWheel>(find.byType(LuckyWheel));
            expect(luckySlotAt(after.angle), 4);
            expect(after.won, 4);
            // Its badge is the one at the top, under the needle.
            final tops = {
              for (var slot = 1; slot <= 6; slot++)
                slot: tester.getCenter(
                  find.byKey(ValueKey('lucky-badge-$slot')),
                ),
            };
            final highest = tops.entries.reduce(
              (a, b) => a.value.dy <= b.value.dy ? a : b,
            );
            expect(highest.key, 4);
            // At rest the win is lit, and the prize is still to come.
            expect(
              find.byKey(const ValueKey('lucky-winning-wedge')),
              findsOneWidget,
            );
            expect(find.byKey(const ValueKey('lucky-result')), findsNothing);

            await tester.pump(LuckyDrawScreen.revealAfter);
            await tester.pump(const Duration(milliseconds: 600));
            // The prize.
            expect(find.byKey(const ValueKey('lucky-result')), findsOneWidget);
            expect(find.text('Congratulations!'), findsOneWidget);
            expect(find.text('You won'), findsOneWidget);
            expect(
              tester
                  .widget<Text>(
                    find.byKey(const ValueKey('lucky-result-prize')),
                  )
                  .textSpan!
                  .toPlainText(),
              '100,000 chips',
            );
            // The wallet took the server's figure.
            expect(state.user?.chips, 400000);

            // Closed, the key counts down to the next spin, and the slot won
            // stays lit.
            await tester.tap(find.byKey(const ValueKey('lucky-result-go')));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(find.byKey(const ValueKey('lucky-result')), findsNothing);
            expect(find.text('NEXT FREE SPIN'), findsOneWidget);
            expect(
              tester
                  .widget<Text>(find.byKey(const ValueKey('lucky-next-spin')))
                  .data,
              matches(RegExp(r'^7[12]:\d\d:\d\d$')),
            );
            expect(_canSpin(tester), isFalse);
            expect(tester.widget<LuckyWheel>(find.byType(LuckyWheel)).won, 4);
            expect(
              tester
                  .widget<LuckyPrizeTile>(
                    find.byKey(const ValueKey('lucky-slot-4')),
                  )
                  .won,
              isTrue,
            );
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
      },
    );

    testWidgets('at rest, the win is lit in its tile and nowhere else', (
      tester,
    ) async {
      await _setView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = _state();
          await _openDraw(tester, state);
          await tester.tap(find.byKey(const ValueKey('lucky-spin')));
          await tester.pump();
          await _untilWon(tester, frame: const Duration(milliseconds: 16));
          await tester.pump(const Duration(milliseconds: 250));
          for (var slot = 1; slot <= 6; slot++) {
            final tile = find.byKey(ValueKey('lucky-slot-$slot'));
            expect(
              tester.widget<LuckyPrizeTile>(tile).won,
              slot == 3,
              reason: 'slot $slot',
            );
            // The others step back while the win is shown.
            expect(
              tester
                  .widget<AnimatedOpacity>(
                    find.descendant(
                      of: tile,
                      matching: find.byType(AnimatedOpacity),
                    ),
                  )
                  .opacity,
              slot == 3 ? 1 : 0.5,
              reason: 'slot $slot',
            );
          }
          expect(find.byKey(const ValueKey('lucky-result')), findsNothing);
          await tester.pump(LuckyDrawScreen.revealAfter);
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byKey(const ValueKey('lucky-result')), findsOneWidget);
          await _unmount(tester, state);
        },
        () => _server0(
          sent: sent,
          spin: _spinJson(3, {'type': 'CHIPS', 'value': 1000000}),
        ),
      );
    });

    testWidgets('the empty slot says better luck next time, quietly', (
      tester,
    ) async {
      await _setView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = _state();
          await _openDraw(tester, state);
          await tester.tap(find.byKey(const ValueKey('lucky-spin')));
          await tester.pump();
          await tester.pump();
          await _untilWon(tester);
          // Where it stopped is ringed, in a neutral line: nothing was won.
          final tile = find.byKey(const ValueKey('lucky-slot-5'));
          expect(tester.widget<LuckyPrizeTile>(tile).won, isTrue);
          final ring =
              (tester
                          .widget<DecoratedBox>(
                            find
                                .descendant(
                                  of: tile,
                                  matching: find.byType(DecoratedBox),
                                )
                                .first,
                          )
                          .decoration
                      as BoxDecoration)
                  .border!
                  .top;
          expect(ring.width, 2);
          expect(ring.color, isNot(AppTheme.goldInk(Brightness.dark)));
          await tester.pump(LuckyDrawScreen.revealAfter);
          await tester.pump(const Duration(milliseconds: 600));
          expect(luckySlotAt(_angle(tester)), 5);
          expect(find.text('Better luck next time!'), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('lucky-result')),
              matching: find.text('No prize'),
            ),
            findsOneWidget,
          );
          expect(find.text('Congratulations!'), findsNothing);
          // A shrug, not a celebration.
          expect(find.byType(Fireworks), findsNothing);
          await _unmount(tester, state);
        },
        () => _server0(
          sent: sent,
          spin: _spinJson(5, {'type': 'NO_REWARD', 'value': 0, 'refId': null}),
        ),
      );
    });

    testWidgets('a spin refused at once leaves the wheel where it was', (
      tester,
    ) async {
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
          expect(luckySlotAt(_angle(tester)), 1);
          expect(find.byKey(const ValueKey('lucky-result')), findsNothing);
          // The server's moment is the one counted down to.
          expect(state.luckyDraw?.nextSpinAt, readyAt);
          expect(find.text('NEXT FREE SPIN'), findsOneWidget);
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

    testWidgets('a spin refused mid-turn runs down to rest with no prize, '
        'and the key comes back', (tester) async {
      await _setView(tester);
      final sent = <http.Request>[];
      final release = Completer<void>();
      final readyAt = DateTime.now()
          .add(const Duration(hours: 30))
          .millisecondsSinceEpoch;
      await http.runWithClient(
        () async {
          final state = _state();
          await _openDraw(tester, state);
          final before = _angle(tester);
          await tester.tap(find.byKey(const ValueKey('lucky-spin')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 1200));
          final atAnswer = _angle(tester);
          expect(atAnswer - before, greaterThan(40), reason: 'turning');
          release.complete();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 16));
          // No jolt at the answer; it runs down, still SPINNING…
          expect(_angle(tester) - atAnswer, lessThan(15));
          expect(find.text('SPINNING…'), findsOneWidget);
          // …to rest.
          await tester.pump(const Duration(seconds: 4));
          final rested = _angle(tester);
          await tester.pump(const Duration(milliseconds: 500));
          expect(_angle(tester), rested);
          // No prize: nothing lit, nothing shown. The key is back, counting
          // down to the server's moment.
          expect(
            tester.widget<LuckyWheel>(find.byType(LuckyWheel)).won,
            isNull,
          );
          expect(
            find.byKey(const ValueKey('lucky-winning-wedge')),
            findsNothing,
          );
          expect(find.byKey(const ValueKey('lucky-result')), findsNothing);
          expect(state.luckyDraw?.nextSpinAt, readyAt);
          expect(find.text('SPINNING…'), findsNothing);
          expect(find.text('NEXT FREE SPIN'), findsOneWidget);
          await _unmount(tester, state);
        },
        () => _server0(
          sent: sent,
          release: release,
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
        expect(find.text('NEXT FREE SPIN'), findsOneWidget);
        expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('lucky-next-spin')))
              .data,
          matches(RegExp(r'^05:0[23]:\d\d$')),
        );
        expect(_canSpin(tester), isFalse);
        expect(find.byType(LuckyGoldKey), findsNothing);
        expect(find.byKey(const ValueKey('lucky-free-spin')), findsNothing);
        // The light round the wheel rests; it breathes only for a free spin.
        expect(
          tester.widget<LuckyWheel>(find.byType(LuckyWheel)).light,
          LuckyWheelLight.resting,
        );
        await _unmount(tester, state);
      }, () => _server0(sent: sent, draw: draw));
    });

    testWidgets('the wheel stands a tenth larger than it did', (tester) async {
      await _setView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = _state();
        await _openDraw(tester, state);
        final wheel = tester.widget<LuckyWheel>(find.byType(LuckyWheel));
        // Its rim was 198.5dp across on a 640x360 phone (a window of the
        // canvas 264 units tall in 262dp of page).
        expect(
          LuckyWheel.rimDiameter(wheel.height),
          greaterThanOrEqualTo(198.5 * 1.09),
        );
        expect(tester.getSize(find.byType(LuckyWheel)).height, wheel.height);
        await _unmount(tester, state);
      }, () => _server0(sent: sent));
    });

    // The tightest phone the app is checked on, and a narrow one with its
    // navigation bar down the side.
    for (final screen in const [Size(640, 360), Size(592, 360)]) {
      for (final lang in AppLang.values) {
        testWidgets(
          'fits a ${screen.width.toInt()}x${screen.height.toInt()} phone at '
          'text x1.25 in ${lang.name}, prize and all',
          (tester) async {
            await _setView(tester, screen: screen, textScale: 1.25);
            final sent = <http.Request>[];
            await http.runWithClient(
              () async {
                final state = _state(lang: lang);
                await _openDraw(tester, state);
                expect(find.byType(LuckyWheel), findsOneWidget);
                // Every tile's words are whole: none cut short.
                for (var slot = 1; slot <= 6; slot++) {
                  final tile = find.byKey(ValueKey('lucky-slot-$slot'));
                  for (final paragraph
                      in tester.renderObjectList<RenderParagraph>(
                        find.descendant(
                          of: tile,
                          matching: find.byType(RichText),
                        ),
                      )) {
                    expect(
                      paragraph.didExceedMaxLines,
                      isFalse,
                      reason: '${lang.name} slot $slot: ${paragraph.text}',
                    );
                  }
                }
                // The wheel, the prizes and the key keep to their own places,
                // all on screen.
                final view = Offset.zero & screen;
                final wheel = tester.getRect(find.byType(LuckyWheel));
                final key = tester.getRect(
                  find.byKey(const ValueKey('lucky-spin')),
                );
                final tiles = tester.getRect(find.byType(LuckyPrizeGrid));
                for (final r in [wheel, key, tiles]) {
                  expect(view.intersect(r), r, reason: '${lang.name} $r');
                }
                expect(wheel.right, lessThanOrEqualTo(tiles.left));
                expect(tiles.bottom, lessThanOrEqualTo(key.top));
                await tester.tap(find.byKey(const ValueKey('lucky-spin')));
                await tester.pump();
                await tester.pump();
                await _untilWon(tester);
                await tester.pump(LuckyDrawScreen.revealAfter);
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
    }
  });
}
