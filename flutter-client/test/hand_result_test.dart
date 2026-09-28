// The hand-result card animations (owner's brief, 29 Sep 2026): the winning
// hand's cards light up where they lie, by what the SERVER named them —
// Pair a small pulse, Color a coloured sweep, Sequence card after card, Pure
// Sequence a settling gold edge, Trail a short burst — from the moment the
// WINNER ribbon strikes, on the celebration's own clock.
//
// Held here: which profile runs and on which cards (a Pair's two alone; a
// wild card by what it counted as; 5-Card's three that played; a High Card,
// a Muflis hand and a sideshow nothing); that intensity rises Pair → Trail;
// that nothing lights before the result or after the next deal, a rebuilt
// seat takes the animation up where it is and a remounted felt shows it
// settled; that the light stops repainting once settled; reduced motion;
// both themes and a 640dp phone at x1.25; a head seat; the sound hook; and
// that the next snapshot is never held up.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/hand_result_motion.dart';
import 'package:teenpatti/widgets/hammer_flight.dart' show PodImpact;
import 'package:teenpatti/widgets/hand_result.dart';
import 'package:teenpatti/widgets/seat_pod.dart' show SeatBet, SeatPod;

import 'hand_result_scenes.dart';
import 'table_scenes.dart' show tableApp;

/// Feedback that notes every hand-result hook it is asked for, sound off.
class _Heard extends FeedbackSettings {
  final heard = <HandResultLevel>[];

  @override
  void handResult(HandResultLevel level) {
    heard.add(level);
    super.handResult(level);
  }
}

Future<_Heard> _feedback() async {
  SharedPreferences.setMockInitialValues({'soundOn': false});
  final feedback = _Heard();
  await feedback.load();
  return feedback;
}

Finder _cardFinder(String code) =>
    find.byWidgetPredicate((w) => w is HandResultCard && w.code == code);

RenderHandResultCard _card(WidgetTester tester, String code) =>
    tester.renderObject<RenderHandResultCard>(_cardFinder(code));

HandResultGroupState _group(WidgetTester tester, String userId) =>
    tester.state<HandResultGroupState>(
      find.byWidgetPredicate((w) => w is HandResultGroup && w.userId == userId),
    );

/// Every card on the table that is lit right now, by code.
Iterable<String> _litCodes(WidgetTester tester) => tester
    .widgetList<HandResultCard>(find.byType(HandResultCard))
    .where((w) => w.code != null)
    .where(
      (w) => tester
          .renderObject<RenderHandResultCard>(_cardFinder(w.code!))
          .effect
          .paints,
    )
    .map((w) => w.code!);

Future<(GameState, _Heard)> _mount(
  WidgetTester tester, {
  Size size = const Size(891, 411),
  double scale = 1,
  bool dark = true,
  int places = 5,
  bool reduced = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  if (reduced) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await _feedback();
  addTearDown(feedback.dispose);
  final state = resultState(places: places);
  await tester.pumpWidget(
    tableApp(
      state: state,
      feedback: feedback,
      theme: dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
    ),
  );
  await _frames(tester, 300);
  return (state, feedback);
}

Future<void> _frames(WidgetTester tester, int ms) async {
  for (var at = 0; at < ms; at += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

/// The hand's end as the server sends it: the table as the show is paid, the
/// reveal, and a frame later the result and the settled table.
Future<void> _play(
  WidgetTester tester,
  GameState state, {
  required String winner,
  required ResultHand won,
  String? loser,
  int places = 5,
  String category = 'seen',
  String? variation,
  String? turnUp,
  Duration dealtFor = Duration.zero,
}) async {
  final beaten = loser ?? (winner == 'u0' ? 'u3' : 'u0');
  final viewerCards = winner == 'u0' ? won.cards : beatenHand.cards;
  final cardCount = won.cards.length;
  state.handleState(
    resultRoom(
      places: places,
      inHand: [winner, beaten],
      cards: viewerCards,
      cardCount: cardCount,
      category: category,
    ),
  );
  await tester.pump(const Duration(milliseconds: 16));
  // The hand on the table this long before it is shown down: its cards dealt
  // and at rest, as they are at a real table.
  await _frames(tester, dealtFor.inMilliseconds);
  if (variation != null) {
    state.handleVariationAtShowdown((
      variation: variation,
      selectedBy: 'PLAYER',
      turnUp: turnUp,
    ));
  }
  state.handleShowdown(resultReveal(winner, won, loser: beaten));
  await tester.pump(const Duration(milliseconds: 16));
  state
    ..handleShowdown(resultEnded(winner, won, loser: beaten))
    ..handleState(
      resultSettled(
        winner,
        loser: beaten,
        places: places,
        cards: viewerCards,
        cardCount: cardCount,
        category: category,
      ),
    );
  await tester.pump(const Duration(milliseconds: 16));
  // The celebration is launched after the frame that learnt the result.
  await tester.pump(const Duration(milliseconds: 16));
}

/// Every lit card's strongest moment over [ms] of frames: its largest scale,
/// highest lift and brightest edge, and whether anything else lit at all.
Future<Map<String, HandResultCardEffect>> _peaks(
  WidgetTester tester,
  List<String> codes, {
  int ms = 1600,
}) async {
  final peaks = <String, HandResultCardEffect>{
    for (final c in codes) c: HandResultCardEffect.rest,
  };
  for (var at = 0; at < ms; at += 16) {
    await tester.pump(const Duration(milliseconds: 16));
    for (final c in codes) {
      final e = _card(tester, c).effect;
      final p = peaks[c]!;
      peaks[c] = HandResultCardEffect(
        scale: e.scale > p.scale ? e.scale : p.scale,
        lift: e.lift > p.lift ? e.lift : p.lift,
        glow: e.glow > p.glow ? e.glow : p.glow,
        sweep: e.sweep > p.sweep ? e.sweep : p.sweep,
      );
    }
  }
  return peaks;
}

void main() {
  setUpAll(() async {
    // Where async is real (CLAUDE.md §12.3).
    await FireworksArt.load();
  });
  setUp(HandResultMemory.reset);

  group('which cards made the hand', () {
    test('the level is the server\'s category, else its English name', () {
      expect(HandResultLevel.fromCategory(0), isNull);
      expect(HandResultLevel.fromCategory(1), HandResultLevel.pair);
      expect(HandResultLevel.fromCategory(2), HandResultLevel.color);
      expect(HandResultLevel.fromCategory(3), HandResultLevel.sequence);
      expect(HandResultLevel.fromCategory(4), HandResultLevel.pureSequence);
      expect(HandResultLevel.fromCategory(5), HandResultLevel.trail);
      expect(HandResultLevel.fromCategory(6), isNull);
      expect(
        HandResultLevel.fromHandName('Pure Sequence'),
        HandResultLevel.pureSequence,
      );
      expect(HandResultLevel.fromHandName('High Card'), isNull);
      expect(HandResultLevel.fromHandName('Colour'), isNull);
    });

    test('a Pair lights its two cards and not the third', () {
      expect(
        handResultCards(level: HandResultLevel.pair, cards: ['7s', '7h', 'Kc']),
        {'7s': 0, '7h': 1},
      );
      expect(
        handResultCards(level: HandResultLevel.pair, cards: ['Kc', '7s', '7h']),
        {'7s': 0, '7h': 1},
      );
    });

    test('a wild card pairs by the card it counted as', () {
      // A real AK47 hand: the K is wild and stood for a nine, making a Pair of
      // nines with the natural 9d (the strongest it could make: 9 9 2).
      expect(
        handResultCards(
          level: HandResultLevel.pair,
          cards: ['Ks', '9d', '2c'],
          playsAs: ['9h', '9d', '2c'],
        ),
        {'Ks': 0, '9d': 1},
      );
    });

    test('the level is the category the server sent, never what the faces '
        'look like', () {
      final clock = AnimationController(vsync: const TestVSync());
      addTearDown(clock.dispose);
      HandResultCue? cue(Map<String, Object?> reveal) =>
          HandResultCue.forWinner(
            key: 'r1:7:u0',
            reveal: Reveal.fromJson({'userId': 'u0', ...reveal}),
            clock: clock,
            total: const Duration(seconds: 3),
            startAt: Duration.zero,
          );
      // A JOKER Trail (the turned-up card a two): dealt 7 7 2, a Pair by its
      // faces; the wild 2d played as a seven. The server says Trail.
      final joker = cue({
        'cards': ['7s', '7h', '2d'],
        'handName': 'Trail',
        'category': 5,
        'wild': ['2d'],
        'playsAs': ['7s', '7h', '7d'],
      });
      expect(joker?.level, HandResultLevel.trail);
      expect(joker?.cards, {'7s': 0, '7h': 1, '2d': 2});
      // The category decides even against the name beside it.
      final named = cue({
        'cards': ['As', 'Ah', 'Ad'],
        'handName': 'Pair',
        'category': 5,
      });
      expect(named?.level, HandResultLevel.trail);
      expect(named?.cards, {'As': 0, 'Ah': 1, 'Ad': 2});
    });

    test('under 5-Card only the three that played', () {
      final five = ['As', '2c', 'Ah', '9d', 'Ad'];
      expect(
        handResultCards(
          level: HandResultLevel.trail,
          cards: five,
          best: ['As', 'Ah', 'Ad'],
        ),
        {'As': 0, 'Ah': 1, 'Ad': 2},
      );
      expect(
        handResultCards(
          level: HandResultLevel.pair,
          cards: ['7s', '2c', '7h', '9d', 'Kd'],
          best: ['7s', '7h', 'Kd'],
        ),
        {'7s': 0, '7h': 1},
      );
    });

    test('a High Card, a Muflis hand, a missing reveal or an unfindable pair '
        'light nothing', () {
      final clock = AnimationController(vsync: const TestVSync());
      addTearDown(clock.dispose);
      HandResultCue? cue(Reveal? r, {String? variation}) =>
          HandResultCue.forWinner(
            key: 'r1:7:u0',
            reveal: r,
            clock: clock,
            total: const Duration(seconds: 3),
            startAt: Duration.zero,
            variation: variation,
          );
      Reveal reveal(List<String> cards, String name, int category) =>
          Reveal.fromJson({
            'userId': 'u0',
            'cards': cards,
            'handName': name,
            'category': category,
          });
      expect(cue(reveal(['Kd', '9c', '2h'], 'High Card', 0)), isNull);
      expect(cue(null), isNull);
      expect(
        cue(reveal(['As', 'Ah', 'Ad'], 'Trail', 5), variation: 'MUFLIS'),
        isNull,
      );
      expect(cue(reveal(['7s', '8h', 'Kc'], 'Pair', 1)), isNull);
      final trail = cue(reveal(['As', 'Ah', 'Ad'], 'Trail', 5));
      expect(trail?.level, HandResultLevel.trail);
      expect(trail?.cards, {'As': 0, 'Ah': 1, 'Ad': 2});
    });
  });

  group('the profiles', () {
    test('intensity never falls from Pair to Trail', () {
      final rows = HandResultProfile.all;
      expect(rows.map((r) => r.level), HandResultLevel.values);
      for (var i = 1; i < rows.length; i++) {
        final a = rows[i - 1];
        final b = rows[i];
        expect(b.peakScale, greaterThanOrEqualTo(a.peakScale), reason: '$i');
        expect(b.liftShare, greaterThanOrEqualTo(a.liftShare), reason: '$i');
        expect(b.glow, greaterThanOrEqualTo(a.glow), reason: '$i');
        expect(b.restGlow, greaterThanOrEqualTo(a.restGlow), reason: '$i');
        expect(b.sparks, greaterThanOrEqualTo(a.sparks), reason: '$i');
        expect(b.radialGlow, greaterThanOrEqualTo(a.radialGlow), reason: '$i');
        expect(b.duration, greaterThanOrEqualTo(a.duration), reason: '$i');
      }
      // And the peaks actually reached, frame by frame, agree.
      ({double scale, double lift, double glow}) peak(HandResultProfile p) {
        var scale = 1.0, lift = 0.0, glow = 0.0;
        for (var t = 0.0; t <= 1; t += 0.005) {
          for (var o = 0; o < 3; o++) {
            final e = p.cardAt(t, order: o, count: 3, cardHeight: 80);
            if (e.scale > scale) scale = e.scale;
            if (e.lift > lift) lift = e.lift;
            if (e.glow > glow) glow = e.glow;
          }
        }
        return (scale: scale, lift: lift, glow: glow);
      }

      final peaks = rows.map(peak).toList();
      for (var i = 1; i < peaks.length; i++) {
        expect(peaks[i].scale, greaterThanOrEqualTo(peaks[i - 1].scale - 1e-6));
        expect(peaks[i].lift, greaterThanOrEqualTo(peaks[i - 1].lift - 1e-6));
        expect(peaks[i].glow, greaterThanOrEqualTo(peaks[i - 1].glow - 1e-6));
      }
      // Only the Trail bursts; a Pair's only light is a thin edge that rises
      // and falls with its two cards — no sweep, nothing kept once still.
      expect(
        rows.where((r) => r.sparks > 0).single.level,
        HandResultLevel.trail,
      );
      expect(HandResultProfile.pair.glow, inInclusiveRange(0.2, 0.25));
      expect(HandResultProfile.pair.glowFollowsLift, isTrue);
      expect(HandResultProfile.pair.restGlow, 0);
      expect(HandResultProfile.pair.sweep, 0);
    });

    test('each level runs for the brief\'s time, moves a card 2–6 px and '
        'never past 1.04', () {
      bool within(Duration d, int lo, int hi) =>
          d.inMilliseconds >= lo && d.inMilliseconds <= hi;
      expect(within(HandResultProfile.pair.duration, 250, 350), isTrue);
      expect(within(HandResultProfile.color.duration, 450, 600), isTrue);
      expect(within(HandResultProfile.sequence.duration, 550, 700), isTrue);
      expect(within(HandResultProfile.pureSequence.duration, 700, 900), isTrue);
      expect(within(HandResultProfile.trail.duration, 900, 1200), isTrue);
      for (final p in HandResultProfile.all) {
        expect(p.peakScale, inInclusiveRange(1.02, 1.04));
        // The viewer's cards (80dp) rise 2–6 px.
        final lift = p.liftShare * 80;
        expect(
          lift.clamp(0, HandResultProfile.liftMax),
          inInclusiveRange(2, 6),
        );
        // Settled: at rest, but for the edge light the rarer hands keep.
        final end = p.cardAt(1, order: 0, count: 3, cardHeight: 80);
        expect(end.scale, 1);
        expect(end.lift, 0);
        expect(end.sweep, 0);
        expect(end.glow, p.restGlow);
      }
    });

    test('a Sequence lights card 1, then 2, then 3, overlapping', () {
      final p = HandResultProfile.sequence;
      double peakAt(int order) {
        var best = 0.0, at = 0.0;
        for (var t = 0.0; t <= 1; t += 0.002) {
          final e = p.cardAt(t, order: order, count: 3, cardHeight: 80);
          if (e.lift > best) {
            best = e.lift;
            at = t;
          }
        }
        return at;
      }

      final peaks = [peakAt(0), peakAt(1), peakAt(2)];
      expect(peaks[0], lessThan(peaks[1]));
      expect(peaks[1], lessThan(peaks[2]));
      // Card 2 has begun before card 1 has settled.
      final overlap = p.cardAt(
        p.stagger + p.cardSpan * 0.1,
        order: 1,
        count: 3,
        cardHeight: 80,
      );
      final stillUp = p.cardAt(
        p.stagger + p.cardSpan * 0.1,
        order: 0,
        count: 3,
        cardHeight: 80,
      );
      expect(overlap.lift, greaterThan(0));
      expect(stillUp.lift, greaterThan(0));
    });

    test('a Color\'s light crosses the hand once, first card to last', () {
      final p = HandResultProfile.color;
      expect(p.sweepTint, HandResultSweepTint.accent);
      var last = -1.0;
      var seen = 0;
      for (var t = 0.0; t <= 1; t += 0.002) {
        final e = p.cardAt(t, order: 0, count: 3, cardHeight: 80);
        if (e.sweep <= 0) continue;
        seen++;
        // One light for the whole hand, only ever moving on.
        expect(e.sweepAcross, isTrue);
        expect(e.sweepAt, greaterThanOrEqualTo(last));
        last = e.sweepAt;
      }
      expect(seen, greaterThan(100));
      expect(last, greaterThan(0.99));
      // Side by side, it is on the first card before the last.
      double onFace(double progress, int order) =>
          HandResultProfile.acrossSideBySide(
            progress: progress,
            count: 3,
            order: order,
            width: p.sweepWidth,
          );
      expect(onFace(0.25, 0), inInclusiveRange(0, 1));
      expect(onFace(0.25, 2), lessThan(-p.sweepWidth));
      expect(onFace(0.8, 2), inInclusiveRange(0, 1));
      expect(onFace(0.8, 0), greaterThan(1 + p.sweepWidth));
    });

    test('reduced motion keeps less movement, no sweep, no sparks — and '
        'still marks the cards', () {
      for (final level in HandResultLevel.values) {
        final full = HandResultProfile.of(level);
        final calm = HandResultProfile.reducedOf(level);
        expect(identical(calm, HandResultProfile.reducedOf(level)), isTrue);
        expect(calm.peakScale, lessThan(full.peakScale));
        expect(calm.liftShare, lessThan(full.liftShare));
        expect(calm.sweep, 0);
        expect(calm.sparks, 0);
        expect(calm.radialGlow, 0);
        expect(calm.glow, greaterThan(0));
      }
    });

    test('a card fitted to its room rises no further than the room, and its '
        'foot never sinks', () {
      for (final p in HandResultProfile.all) {
        for (final h in [40.0, 46.0, 80.0, 101.0]) {
          for (var t = 0.0; t <= 1; t += 0.01) {
            final e = p.cardAt(t, order: 0, count: 3, cardHeight: h);
            // Room enough: left exactly as it was.
            expect(e.within(100, h), same(e));
            for (final room in [0.0, 1.5, 3.0, 4.8, 5.3]) {
              final f = e.within(room, h);
              expect(f.riseOf(h), lessThanOrEqualTo(room + 1e-9));
              // The foot's rise: the lift less the half growth that goes down.
              expect(f.lift - (f.scale - 1) * h / 2, greaterThan(-1e-9));
              expect(f.scale, lessThanOrEqualTo(e.scale + 1e-12));
              expect(f.glow, e.glow);
              expect(f.sweep, e.sweep);
            }
          }
        }
      }
    });

    test('the light round a hand stays under what stands over it', () {
      for (final h in [40.0, 46.0, 96.0, 108.0]) {
        // The radial light gives way above and keeps its reach elsewhere.
        final hand = Size(h * 2, h);
        final free = HandResultShape.radialBounds(hand, 1.15);
        final held = HandResultShape.radialBounds(hand, 1.15, ceiling: -3);
        expect(free.top, lessThan(-3));
        expect(held.top, -3);
        expect(held.bottom, free.bottom);
        expect(held.left, free.left);
        expect(held.right, free.right);
        // A spark ends its flight no higher than the room allows, whichever
        // way it leaves.
        for (var a = 0.0; a < 2 * math.pi; a += 0.05) {
          const room = 3.0;
          final reach = h * HandResultShape.sparkReach * 1.2;
          const head = 2.0;
          final rise = HandResultShape.sparkRiseFor(
            angle: a,
            reach: reach,
            halfHeight: h / 2,
            room: room,
            head: head,
          );
          final up = -math.sin(a);
          expect(rise, inInclusiveRange(0, HandResultShape.sparkRise));
          if (up > 0) {
            final aboveTop = up * (h / 2 + reach * rise) - h / 2 + head / 2;
            expect(aboveTop, lessThanOrEqualTo(room + 1e-9));
          } else {
            expect(rise, HandResultShape.sparkRise);
          }
        }
        expect(
          HandResultShape.sparkRiseFor(
            angle: -math.pi / 2,
            reach: 50,
            halfHeight: h / 2,
            room: double.infinity,
          ),
          HandResultShape.sparkRise,
        );
      }
    });

    test('the progress tells its listeners only while it moves', () {
      final clock = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(seconds: 3),
      );
      addTearDown(clock.dispose);
      final progress = HandResultProgress(
        clock: clock,
        total: const Duration(seconds: 3),
        startAt: const Duration(milliseconds: 500),
        duration: const Duration(milliseconds: 1000),
      );
      var told = 0;
      progress.addListener(() => told++);
      clock.value = 0.1; // 300 ms: before the result
      expect(progress.value, 0);
      expect(told, 0);
      clock.value = 0.3; // 900 ms
      expect(progress.value, closeTo(0.4, 1e-9));
      expect(told, 1);
      clock.value = 0.6; // 1800 ms: settled
      expect(progress.value, 1);
      final settled = told;
      clock.value = 0.8;
      clock.value = 0.95;
      expect(told, settled, reason: 'a settled result says nothing more');
    });
  });

  group('on the table', () {
    for (final (who, winner) in [('the viewer', 'u0'), ('a rim seat', 'u3')]) {
      for (final MapEntry(key: name, value: won) in resultHands.entries) {
        testWidgets('$name at $who: its profile, on its cards alone', (
          tester,
        ) async {
          final (state, heard) = await _mount(tester);
          await _play(tester, state, winner: winner, won: won);
          final level = HandResultLevel.fromCategory(won.category)!;
          final group = _group(tester, winner);
          expect(group.cue?.level, level);
          expect(group.profile, same(HandResultProfile.of(level)));

          // Nothing before the result: the cards are still turning.
          for (var at = 0; at < 400; at += 16) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(_litCodes(tester), isEmpty, reason: 'at $at ms');
          }
          final codes = [...won.cards, ...beatenHand.cards];
          final peaks = await _peaks(tester, codes);
          final lit = level == HandResultLevel.pair ? ['7s', '7h'] : won.cards;
          final profile = HandResultProfile.of(level);
          for (final c in codes) {
            final p = peaks[c]!;
            if (lit.contains(c)) {
              // Its full growth, or as much as the room over the hand leaves
              // (the viewer's middle card stands 4dp under their own badge).
              expect(
                p.scale,
                inInclusiveRange(
                  1 + (profile.peakScale - 1) * 0.8,
                  profile.peakScale + 1e-9,
                ),
                reason: c,
              );
              expect(p.lift, greaterThan(0), reason: c);
              expect(p.glow, closeTo(profile.glow, 0.02), reason: c);
            } else {
              expect(p, HandResultCardEffect.rest, reason: '$c stays still');
            }
          }
          expect(heard.heard, [level]);
          await _unmount(tester, state);
        });
      }
    }

    // Nothing a result draws — a risen card, its edge light, a Trail's radial
    // light and sparks — reaches what stands over the hand: the viewer's own
    // bet badge, a rim seat's pod (review, 29 Sep 2026: a Trail's middle card
    // lay over the lower third of "SEEN 800" and its light tinted the words).
    for (final (size, scale) in [
      (const Size(640, 360), 1.25),
      (const Size(891, 411), 1.0),
    ]) {
      for (final (who, winner) in [
        ('the viewer', 'u0'),
        ('a rim seat', 'u3'),
      ]) {
        for (final MapEntry(key: name, value: won) in resultHands.entries) {
          testWidgets('$name at $who, ${size.width.toInt()}x'
              '${size.height.toInt()} x$scale: never over what stands over '
              'the hand', (tester) async {
            final (state, _) = await _mount(tester, size: size, scale: scale);
            await _play(
              tester,
              state,
              winner: winner,
              won: won,
              dealtFor: const Duration(seconds: 1),
            );
            final over = winner == 'u0'
                ? find.descendant(
                    of: find.byKey(const ValueKey('own-hand-column')),
                    matching: find.byType(SeatBet),
                  )
                : find.descendant(
                    of: find.byWidgetPredicate(
                      (w) => w is SeatPod && w.seat?.userId == winner,
                    ),
                    matching: find.byType(PodImpact),
                  );
            expect(over, findsOneWidget);
            final lit = won.category == 1 ? ['7s', '7h'] : won.cards;
            var rose = 0.0;
            for (var at = 0; at < 1800; at += 16) {
              await tester.pump(const Duration(milliseconds: 16));
              // Read every frame: at the showdown the viewer's column glides
              // up to make room for their hand's name, badge and cards alike.
              final line = tester.getRect(over).bottom;
              for (final c in lit) {
                final card = _card(tester, c);
                final child = card.child!;
                final toScreen = child.getTransformTo(null);
                final painted = MatrixUtils.transformRect(
                  toScreen,
                  Offset.zero & child.size,
                );
                expect(
                  painted.top,
                  greaterThanOrEqualTo(line),
                  reason: '$c at $at ms: its top',
                );
                final halo = card.debugLightBounds;
                if (halo != null) {
                  expect(
                    MatrixUtils.transformRect(toScreen, halo).top,
                    greaterThanOrEqualTo(line - 0.01),
                    reason: '$c at $at ms: its edge light',
                  );
                }
                if (card.effect.moves) {
                  rose = math.max(rose, card.effect.riseOf(child.size.height));
                }
              }
              final light = _group(tester, winner).debugLightBounds;
              if (light != null) {
                expect(
                  light.top,
                  greaterThanOrEqualTo(line - 0.01),
                  reason: 'the burst at $at ms',
                );
              }
            }
            // And it did rise: the brief's 2–6 px, bounded, not taken away.
            expect(rose, greaterThanOrEqualTo(2.5));
            await _unmount(tester, state);
          });
        }
      }
    }

    testWidgets('a High Card lights nothing and says nothing', (tester) async {
      final (state, heard) = await _mount(tester);
      await _play(tester, state, winner: 'u3', won: highCardHand);
      for (var at = 0; at < 2000; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_litCodes(tester), isEmpty);
      }
      expect(_group(tester, 'u3').cue, isNull);
      expect(heard.heard, isEmpty);
      await _unmount(tester, state);
    });

    testWidgets('a wild card lights with the natural card it paired', (
      tester,
    ) async {
      final (state, _) = await _mount(tester);
      // AK47: the K is wild and played as a nine beside the natural 9d.
      final wildPair = hand(
        ['Ks', '9d', '2c'],
        'Pair',
        1,
        wild: ['Ks'],
        playsAs: ['9h', '9d', '2c'],
      );
      await _play(
        tester,
        state,
        winner: 'u3',
        won: wildPair,
        category: 'variation',
        variation: 'AK47',
      );
      final peaks = await _peaks(tester, ['Ks', '9d', '2c']);
      expect(peaks['Ks']!.scale, greaterThan(1.02));
      expect(peaks['9d']!.scale, greaterThan(1.02));
      expect(peaks['2c'], HandResultCardEffect.rest);
      await _unmount(tester, state);
    });

    testWidgets('a JOKER Trail dealt 7 7 2 plays the Trail on all three, '
        'however its faces read', (tester) async {
      final (state, heard) = await _mount(tester);
      final jokerTrail = hand(
        ['7s', '7h', '2d'],
        'Trail',
        5,
        wild: ['2d'],
        playsAs: ['7s', '7h', '7d'],
      );
      await _play(
        tester,
        state,
        winner: 'u3',
        won: jokerTrail,
        category: 'variation',
        variation: 'JOKER',
        turnUp: '2c',
      );
      final group = _group(tester, 'u3');
      expect(group.cue?.level, HandResultLevel.trail);
      expect(group.profile, same(HandResultProfile.trail));
      final peaks = await _peaks(tester, jokerTrail.cards);
      for (final c in jokerTrail.cards) {
        expect(
          peaks[c]!.scale,
          closeTo(HandResultProfile.trail.peakScale, 0.004),
          reason: c,
        );
        expect(
          peaks[c]!.glow,
          closeTo(HandResultProfile.trail.glow, 0.02),
          reason: c,
        );
      }
      expect(heard.heard, [HandResultLevel.trail]);
      await _unmount(tester, state);
    });

    testWidgets('under 5-Card only the three that played light, at both '
        'seats', (tester) async {
      for (final winner in ['u0', 'u3']) {
        HandResultMemory.reset();
        final (state, _) = await _mount(tester);
        final five = hand(
          ['As', '2c', 'Ah', '9d', 'Ad'],
          'Trail',
          5,
          best: ['As', 'Ah', 'Ad'],
        );
        await _play(
          tester,
          state,
          winner: winner,
          won: five,
          category: 'variation',
          variation: 'FIVE_CARD',
        );
        final peaks = await _peaks(tester, five.cards);
        for (final c in ['As', 'Ah', 'Ad']) {
          expect(peaks[c]!.scale, greaterThan(1.03), reason: '$winner $c');
        }
        for (final c in ['2c', '9d']) {
          expect(peaks[c], HandResultCardEffect.rest, reason: '$winner $c');
        }
        await _unmount(tester, state);
      }
    });

    testWidgets('a Muflis hand is not lit by its rarity', (tester) async {
      final (state, heard) = await _mount(tester);
      await _play(
        tester,
        state,
        winner: 'u3',
        won: pairHand,
        category: 'variation',
        variation: 'MUFLIS',
      );
      for (var at = 0; at < 1600; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_litCodes(tester), isEmpty);
      }
      expect(heard.heard, isEmpty);
      await _unmount(tester, state);
    });

    testWidgets('a sideshow won lights nothing: it is not the hand\'s result', (
      tester,
    ) async {
      final (state, heard) = await _mount(tester);
      state.handleState(
        resultRoom(inHand: ['u0', 'u3', 'u4'], cards: trailHand.cards),
      );
      await tester.pump(const Duration(milliseconds: 16));
      state.handleSideshowReveal(
        SideshowReveal.fromJson({
          'hands': [
            {'userId': 'u0', 'cards': trailHand.cards, 'handName': 'Trail'},
            {
              'userId': 'u3',
              'cards': beatenHand.cards,
              'handName': 'High Card',
            },
          ],
          'packedUserId': 'u3',
        }),
      );
      for (var at = 0; at < 1600; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_litCodes(tester), isEmpty);
      }
      expect(heard.heard, isEmpty);
      await _unmount(tester, state);
    });

    testWidgets('the next deal takes the light with it, mid-flight, and it '
        'never comes back', (tester) async {
      final (state, _) = await _mount(tester);
      await _play(tester, state, winner: 'u3', won: trailHand);
      await _frames(tester, 900); // the result has landed; the burst is on
      expect(_litCodes(tester), isNotEmpty);
      state.handleState(resultNextDeal());
      await tester.pump(const Duration(milliseconds: 16));
      // At once: the next snapshot is never held for the animation.
      expect(state.room?.handNo, 8);
      expect(state.showdown, isEmpty);
      expect(_litCodes(tester), isEmpty);
      for (final c in trailHand.cards) {
        expect(_cardFinder(c), findsNothing, reason: 'the cards are backs');
      }
      for (var at = 0; at < 2500; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_litCodes(tester), isEmpty);
      }
      await _unmount(tester, state);
    });

    testWidgets('a rebuild never restarts it, and it repaints nothing once '
        'settled', (tester) async {
      final (state, heard) = await _mount(tester);
      await _play(tester, state, winner: 'u3', won: pureSequenceHand);
      await _frames(tester, 900);
      final before = _group(tester, 'u3').progress;
      expect(before, inExclusiveRange(0, 1));
      // The one-second tick, and a snapshot of the same hand.
      state.notifyListeners();
      await tester.pump(const Duration(milliseconds: 16));
      state.handleState(resultSettled('u3'));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_group(tester, 'u3').progress, greaterThanOrEqualTo(before));
      expect(heard.heard, [HandResultLevel.pureSequence]);
      // Settled: the edge light it keeps, and not one more paint for it.
      await _frames(tester, 1200);
      expect(_group(tester, 'u3').progress, 1);
      final settled = _card(tester, '5s').effect;
      expect(settled.scale, 1);
      expect(settled.glow, HandResultProfile.pureSequence.restGlow);
      RenderHandResultCard.debugLitPaints = 0;
      await _frames(tester, 600);
      state.notifyListeners();
      await _frames(tester, 200);
      expect(RenderHandResultCard.debugLitPaints, 0);
      await _unmount(tester, state);
    });

    testWidgets('a reconnect\'s snapshot of a finished result shows it '
        'settled, and a felt built again never replays it', (tester) async {
      final (state, heard) = await _mount(tester);
      await _play(tester, state, winner: 'u3', won: trailHand);
      await _frames(tester, 1800);
      expect(_group(tester, 'u3').progress, 1);
      // The reconnect's room:joined: the same hand, the same result.
      state.handleState(resultSettled('u3'));
      await tester.pump(const Duration(milliseconds: 16));
      final e = _card(tester, 'Ah').effect;
      expect(e.scale, 1);
      expect(e.glow, HandResultProfile.trail.restGlow);

      // The table screen built again round the same celebration: a new felt,
      // a new clock — and the cards settled from their first frame.
      final feedback = await _feedback();
      addTearDown(feedback.dispose);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        tableApp(
          state: state,
          feedback: feedback,
          theme: AppTheme.dark(sound: false),
        ),
      );
      for (var at = 0; at < 1600; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        final again = _card(tester, 'Ah').effect;
        expect(again.scale, 1, reason: 'at $at ms');
        expect(again.lift, 0, reason: 'at $at ms');
      }
      expect(heard.heard, [HandResultLevel.trail]);
      expect(feedback.heard, isEmpty);
      await _unmount(tester, state);
    });

    testWidgets(
      'reduced motion moves less, sweeps nothing and bursts nothing',
      (tester) async {
        final (state, _) = await _mount(tester, reduced: true);
        await _play(tester, state, winner: 'u3', won: trailHand);
        expect(
          _group(tester, 'u3').profile,
          same(HandResultProfile.reducedOf(HandResultLevel.trail)),
        );
        final peaks = await _peaks(tester, trailHand.cards);
        for (final c in trailHand.cards) {
          expect(peaks[c]!.scale, lessThan(HandResultProfile.trail.peakScale));
          expect(peaks[c]!.sweep, 0);
          expect(peaks[c]!.glow, greaterThan(0));
        }
        await _unmount(tester, state);
      },
    );

    for (final dark in [true, false]) {
      for (final winner in ['u0', 'u3']) {
        testWidgets('a Trail at 640x360 x1.25, ${dark ? 'dark' : 'light'}, '
            '$winner winning: nothing overflows', (tester) async {
          final (state, _) = await _mount(
            tester,
            size: const Size(640, 360),
            scale: 1.25,
            dark: dark,
          );
          await _play(tester, state, winner: winner, won: trailHand);
          await _frames(tester, 2000);
          expect(tester.takeException(), isNull);
          await _unmount(tester, state);
        });
      }
    }

    for (final places in [2, 3, 4]) {
      testWidgets('the head seat or an end seat at $places places lights its '
          'own cards', (tester) async {
        final (state, _) = await _mount(
          tester,
          size: const Size(640, 360),
          scale: 1.25,
          places: places,
        );
        // At two and four places the seat across the table is the head
        // seat, which lays its cards beside its pod.
        final winner = resultIds[places - 1 == 3 ? 2 : places - 1];
        await _play(
          tester,
          state,
          winner: winner,
          won: colorHand,
          places: places,
        );
        final peaks = await _peaks(tester, colorHand.cards);
        for (final c in colorHand.cards) {
          expect(peaks[c]!.sweep, greaterThan(0), reason: c);
        }
        expect(tester.takeException(), isNull);
        await _unmount(tester, state);
      });
    }
  });

  group('the group on its own', () {
    Widget stage(
      AnimationController clock, {
      Key? key,
      HandResultLevel level = HandResultLevel.trail,
      double headroom = 20,
    }) {
      final cue = HandResultCue(
        key: 'r9:3:u0',
        userId: 'u0',
        level: level,
        cards: const {'As': 0, 'Ah': 1, 'Ad': 2},
        clock: clock,
        total: const Duration(seconds: 3),
        startAt: const Duration(milliseconds: 500),
      );
      return MaterialApp(
        home: Center(
          child: HandResultScope(
            cue: cue,
            child: HandResultGroup(
              key: key,
              userId: 'u0',
              headroom: headroom,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final c in ['As', 'Ah', 'Ad', 'Kc'])
                    HandResultCard(
                      code: c,
                      cardHeight: 80,
                      child: const SizedBox(width: 57, height: 80),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a Color\'s one light lies where each card lies in the hand', (
      tester,
    ) async {
      final clock = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(seconds: 3),
      );
      addTearDown(clock.dispose);
      await tester.pumpWidget(stage(clock, level: HandResultLevel.color));
      RenderHandResultCard card(String c) =>
          tester.renderObject<RenderHandResultCard>(_cardFinder(c));
      // Where the light is, in the row's own pixels, seen from each card: the
      // same place whichever card is asked.
      double lightX(String c) {
        final r = card(c);
        final at = r.sweepOnFace(r.effect);
        final rect = tester.getRect(_cardFinder(c));
        return rect.left + at * rect.width;
      }

      final p = HandResultProfile.color;
      final ms = p.duration.inMilliseconds;
      var sawFirst = false, sawLast = false;
      for (var share = 0.1; share < 0.9; share += 0.05) {
        // 500 ms to the result, then [share] of the Color's run.
        clock.value = (500 + share * ms) / 3000;
        await tester.pump();
        expect(lightX('Ah'), closeTo(lightX('As'), 0.01));
        expect(lightX('Ad'), closeTo(lightX('As'), 0.01));
        bool on(String c) {
          final at = card(c).sweepOnFace(card(c).effect);
          return card(c).effect.sweep > 0 && at > 0 && at < 1;
        }

        if (on('As') && !on('Ad')) sawFirst = !sawLast;
        if (on('Ad') && !on('As')) sawLast = sawFirst;
      }
      expect(sawFirst, isTrue);
      expect(sawLast, isTrue, reason: 'the first card, then the last');
    });

    testWidgets('a seat built again mid-way takes it up where the clock is', (
      tester,
    ) async {
      final heard = await _feedback();
      addTearDown(heard.dispose);
      final clock = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(seconds: 3),
      );
      addTearDown(clock.dispose);
      Widget withSounds(Widget child) =>
          ChangeNotifierProvider<FeedbackSettings>.value(
            value: heard,
            child: child,
          );
      await tester.pumpWidget(withSounds(stage(clock, key: const ValueKey(1))));
      clock.value = 0.1;
      await tester.pump();
      clock.value = 0.3; // 900 ms: 400 ms into the Trail's 1100
      await tester.pump();
      final state = tester.state<HandResultGroupState>(
        find.byType(HandResultGroup),
      );
      final before = state.progress;
      expect(before, closeTo(400 / 1100, 1e-6));
      expect(heard.heard, [HandResultLevel.trail]);
      // A new element for the same seat, the same result, the same clock.
      await tester.pumpWidget(withSounds(stage(clock, key: const ValueKey(2))));
      final rebuilt = tester.state<HandResultGroupState>(
        find.byType(HandResultGroup),
      );
      expect(identical(rebuilt, state), isFalse);
      expect(rebuilt.progress, closeTo(before, 1e-6));
      expect(
        tester
            .renderObject<RenderHandResultCard>(_cardFinder('Ah'))
            .effect
            .moves,
        isTrue,
      );
      expect(heard.heard, [HandResultLevel.trail], reason: 'heard once');
      expect(
        tester
            .renderObject<RenderHandResultCard>(_cardFinder('Kc'))
            .effect
            .paints,
        isFalse,
      );
    });

    testWidgets('its light moves only the cards\' paint, never the layout', (
      tester,
    ) async {
      final clock = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(seconds: 3),
      );
      addTearDown(clock.dispose);
      await tester.pumpWidget(stage(clock));
      final rest = tester.getRect(_cardFinder('Ah'));
      final row = tester.getRect(find.byType(Row));
      clock.value = 0.3;
      await tester.pump();
      final box = tester.renderObject<RenderBox>(_cardFinder('Ah'));
      expect(box.size, rest.size);
      expect(tester.getRect(find.byType(Row)), row);
      // But what is painted — the card under it — has risen, grown about
      // its middle: its top by its lift and half its growth, its foot by
      // what is left of the lift.
      final face = find.descendant(
        of: _cardFinder('Ah'),
        matching: find.byType(SizedBox),
      );
      final e = HandResultProfile.trail.cardAt(
        400 / 1100,
        order: 1,
        count: 3,
        cardHeight: 80,
      );
      expect(tester.getRect(face).top, closeTo(rest.top - e.riseOf(80), 0.01));
      expect(tester.getRect(face).top, lessThan(rest.top - 5));
      expect(tester.getRect(face).bottom, lessThanOrEqualTo(rest.bottom));
    });

    testWidgets('it rises only as far as the room over the hand, and its light '
        'no further', (tester) async {
      final clock = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(seconds: 3),
      );
      addTearDown(clock.dispose);
      await tester.pumpWidget(stage(clock, headroom: 4));
      final rest = tester.getRect(_cardFinder('Ah'));
      final group = tester.getRect(find.byType(HandResultGroup));
      final ceiling = group.top - 4 + HandResultShape.clearance;
      for (var ms = 500; ms <= 1700; ms += 20) {
        clock.value = ms / 3000;
        await tester.pump();
        for (final c in ['As', 'Ah', 'Ad']) {
          final card = _card(tester, c);
          final child = card.child!;
          final painted = MatrixUtils.transformRect(
            child.getTransformTo(null),
            Offset.zero & child.size,
          );
          expect(painted.top, greaterThanOrEqualTo(ceiling - 1e-6), reason: c);
          expect(painted.bottom, lessThanOrEqualTo(rest.bottom + 1e-6));
          final halo = card.debugLightBounds;
          if (halo != null) {
            final lit = MatrixUtils.transformRect(
              child.getTransformTo(null),
              halo,
            );
            expect(lit.top, greaterThanOrEqualTo(ceiling - 0.01), reason: c);
          }
        }
        final light = tester
            .state<HandResultGroupState>(find.byType(HandResultGroup))
            .debugLightBounds;
        if (light != null) {
          expect(
            light.top,
            greaterThanOrEqualTo(ceiling - 0.01),
            reason: '$ms',
          );
        }
      }
    });

    testWidgets('a result played before, on a clock built again, is settled '
        'from the moment it lands — not while the cards still turn', (
      tester,
    ) async {
      final first = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(seconds: 3),
      );
      addTearDown(first.dispose);
      await tester.pumpWidget(
        stage(first, level: HandResultLevel.pureSequence),
      );
      first.value = 1;
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      // The felt built again: a new clock, the same result.
      final again = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(seconds: 3),
      );
      addTearDown(again.dispose);
      await tester.pumpWidget(
        stage(again, level: HandResultLevel.pureSequence),
      );
      again.value = 0.1; // 300 ms: before the result lands at 500
      await tester.pump();
      expect(_card(tester, 'Ah').effect, HandResultCardEffect.rest);
      again.value = 0.2; // 600 ms: it has landed — settled at once
      await tester.pump();
      final settled = _card(tester, 'Ah').effect;
      expect(settled.moves, isFalse);
      expect(settled.glow, HandResultProfile.pureSequence.restGlow);
    });
  });
}
