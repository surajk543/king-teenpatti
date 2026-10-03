// The hand-result card animations (owner's brief, 29 Sep 2026), played the
// moment the viewer LOOKS at their own cards and never at a result (owner, the
// same day: "Animation should be played on UI side, no backend change,
// animation should not played on once user take show, this is purely UI
// change, when user click on see card, then acc to rank of card play
// animation"): Pair a small pulse on the two paired cards, Color one light
// across the hand, Sequence card 1 → 2 → 3, Pure Sequence a lift, a sweep and
// a settling gold edge, Trail a lift, a sweep, a spark burst and a radial
// light; a High Card nothing.
//
// Held here: which profile runs and on which cards, at a Seen and a Blind
// table (read from the three cards on the phone, lib/models/own_look.dart) and
// at a Variation table (the server's own `you.hand`: a wild card by what it
// played as, Muflis nothing, 5-Card's three once chosen or lapsed, nothing
// while they are being chosen); the fourth blind bet's reveal as well as the
// tap; that the light lands on cards at rest — after the flip, the wild turn
// and the 5-Card arrangement, measured on the real felt; that nothing lights
// at a show, a showdown, a missile or a sideshow — in the server's own order
// too, the look's snapshot a frame or more before the showdown the same move
// runs, and a look still on its way when a show, the last pack, a missile or
// a sideshow ends it (dropped before it lands, settled once it has); once a
// hand — a snapshot repeat, a rebuilt felt, the next deal, a switch of table,
// packing; reduced motion; both themes; that a settled hand repaints nothing;
// that nothing it draws crosses the bet badge over the hand, the viewer's pod
// beside it or a key, at every phone size; 640x360 at x1.25 in all five
// languages; and, below the table, the levels' own rows and the group and
// card on their own.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/hand_result_motion.dart';
import 'package:teenpatti/widgets/hand_result.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/seat_pod.dart' show SeatBet, SeatPod;
import 'package:teenpatti/widgets/table_chrome.dart'
    show MachinedKey, StepperKey;
import 'package:teenpatti/widgets/wild_transform.dart';

import 'hand_result_scenes.dart';
import 'script_fonts.dart';
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

/// The viewer's own hand: their bet, their fan.
Finder get _ownColumn => find.byKey(const ValueKey('own-hand-column'));

/// The viewer's own fan's group (u0 is the viewer).
HandResultGroupState _group(WidgetTester tester) =>
    tester.state<HandResultGroupState>(
      find.byWidgetPredicate((w) => w is HandResultGroup && w.userId == 'u0'),
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

/// The viewer's face-up cards, by code — in the order the fan PAINTS them,
/// its card on top last (CLAUDE.md §12.3), not the order they are held.
List<String> _ownCodes(WidgetTester tester) => [
  for (final w in tester.widgetList<HandResultCard>(
    find.descendant(of: _ownColumn, matching: find.byType(HandResultCard)),
  ))
    ?w.code,
];

Future<(GameState, _Heard)> _mount(
  WidgetTester tester, {
  Size size = const Size(891, 411),
  double scale = 1,
  bool dark = true,
  int places = 5,
  bool reduced = false,
  AppLang lang = AppLang.english,
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
  final state = resultState(places: places, lang: lang);
  await tester.pumpWidget(
    tableApp(
      state: state,
      feedback: feedback,
      theme: withScriptFallback(
        dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
      ),
    ),
  );
  await _frames(tester, 100);
  return (state, feedback);
}

/// [ms] of frames, 16 ms apart.
Future<void> _frames(WidgetTester tester, int ms) async {
  for (var at = 0; at < ms; at += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// [ms] of time, in coarser steps, for what is not being watched.
Future<void> _settle(WidgetTester tester, int ms) async {
  for (var at = 0; at < ms; at += 100) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

/// The hand dealt, the viewer blind in it: its deal played out and its cards
/// at rest, face down, under See cards.
Future<void> _deal(
  WidgetTester tester,
  GameState state, {
  String roomId = 'r1',
  int handNo = 7,
  int places = 5,
  String category = 'seen',
  bool isPrivate = false,
  int cardCount = 3,
  int blindMovesLeft = 4,
  Map<String, dynamic>? variation,
  List<String> inHand = const ['u0', 'u3'],
}) async {
  state.handleState(
    resultRoom(
      roomId: roomId,
      handNo: handNo,
      places: places,
      category: category,
      isPrivate: isPrivate,
      cardCount: cardCount,
      blind: true,
      blindMovesLeft: blindMovesLeft,
      variation: variation,
      inHand: inHand,
    ),
  );
  await _settle(tester, 3200);
}

/// The viewer's tap on See cards (its move goes nowhere: there is no server).
Future<void> _tapSee(WidgetTester tester, GameState state) async {
  await tester.tap(find.text(state.t.see.toUpperCase()));
  await tester.pump();
}

/// The server's answer to a look: the viewer's cards [h] face up — and at a
/// Variation table [ownHand], their `you.hand` — in the same hand.
Future<void> _see(
  WidgetTester tester,
  GameState state,
  ResultHand h, {
  String roomId = 'r1',
  int handNo = 7,
  int places = 5,
  String category = 'seen',
  bool isPrivate = false,
  Map<String, dynamic>? ownHand,
  Map<String, dynamic>? variation,
  String status = 'active',
  List<String> inHand = const ['u0', 'u3'],
}) async {
  state.handleState(
    resultRoom(
      roomId: roomId,
      handNo: handNo,
      places: places,
      category: category,
      isPrivate: isPrivate,
      cards: h.cards,
      cardCount: h.cards.length,
      ownHand: ownHand,
      variation: variation,
      status: {'u0': status},
      inHand: inHand,
    ),
  );
  await tester.pump(const Duration(milliseconds: 16));
}

/// The first Transform under [e]: a card's own turn, as PlayingCard draws it.
Transform? _turnOf(Element e) {
  Transform? found;
  void visit(Element child) {
    if (found != null) return;
    if (child.widget is Transform) {
      found = child.widget as Transform;
      return;
    }
    child.visitChildren(visit);
  }

  e.visitChildren(visit);
  return found;
}

/// Whether every one of the viewer's cards lies face up and still: a card at
/// rest face up is drawn turned exactly half a turn (PlayingCard's rotateY(π),
/// its lift gone), one still turning or not yet turned is not.
bool _faceUpAtRest(WidgetTester tester) {
  for (final e
      in find
          .descendant(of: _ownColumn, matching: find.byType(PlayingCard))
          .evaluate()) {
    final turn = _turnOf(e);
    if (turn == null) return false;
    final m = turn.transform;
    if ((m.entry(0, 0) + 1).abs() > 1e-6) return false;
    if (m.entry(1, 3).abs() > 1e-6) return false;
  }
  return true;
}

/// Whether every wild card of the viewer's own has finished turning into its
/// stand-in: its "Wild" ribbon and real-card tab stand at full strength.
bool _wildsAtRest(WidgetTester tester) {
  for (final e
      in find
          .descendant(of: _ownColumn, matching: find.byType(WildTransform))
          .evaluate()) {
    if ((e.widget as WildTransform).standIn == null) continue;
    final marks = find
        .descendant(of: find.byWidget(e.widget), matching: find.byType(Opacity))
        .evaluate()
        .map((o) => (o.widget as Opacity).opacity)
        .toList();
    if (marks.isEmpty || marks.any((o) => o < 1)) return false;
  }
  return true;
}

/// Where each of the viewer's cards lies (its own box, before any light).
Map<String, Rect> _places(WidgetTester tester) => {
  for (final c in _ownCodes(tester)) c: tester.getRect(_cardFinder(c)),
};

bool _samePlaces(Map<String, Rect> a, Map<String, Rect> b) =>
    a.length == b.length &&
    a.entries.every(
      (e) =>
          b[e.key] != null &&
          (b[e.key]!.left - e.value.left).abs() < 0.01 &&
          (b[e.key]!.top - e.value.top).abs() < 0.01 &&
          (b[e.key]!.width - e.value.width).abs() < 0.01,
    );

typedef _Moment = ({int at, bool lit, bool still, Map<String, Rect> places});

/// [ms] of frames after a look: each frame's moment, and every card's
/// strongest moment — its largest scale, highest lift, brightest edge.
Future<({List<_Moment> moments, Map<String, HandResultCardEffect> peaks})>
_watch(WidgetTester tester, {int ms = 2600}) async {
  final moments = <_Moment>[];
  final peaks = <String, HandResultCardEffect>{};
  for (var at = 16; at <= ms; at += 16) {
    await tester.pump(const Duration(milliseconds: 16));
    final places = _places(tester);
    for (final c in places.keys) {
      final e = _card(tester, c).effect;
      final p = peaks[c] ?? HandResultCardEffect.rest;
      peaks[c] = HandResultCardEffect(
        scale: math.max(e.scale, p.scale),
        lift: math.max(e.lift, p.lift),
        glow: math.max(e.glow, p.glow),
        sweep: math.max(e.sweep, p.sweep),
      );
    }
    moments.add((
      at: at,
      lit: _group(tester).progress > 0,
      still: _faceUpAtRest(tester) && _wildsAtRest(tester),
      places: places,
    ));
  }
  return (moments: moments, peaks: peaks);
}

/// When the fan came to rest for good — every card face up, every wild card
/// turned, every card where it ends — in ms since the look.
int? _restAt(List<_Moment> moments) {
  final last = moments.last.places;
  int? at;
  for (final m in moments) {
    if (m.still && _samePlaces(m.places, last)) {
      at ??= m.at;
    } else {
      at = null;
    }
  }
  return at;
}

/// When the light landed, in ms since the look.
int? _litAt(List<_Moment> moments) =>
    moments.where((m) => m.lit).firstOrNull?.at;

/// The light lands a beat after the fan is at rest — never before it, never
/// long after ([late], in ms).
void _landsOnStillCards(
  List<_Moment> moments, {
  String reason = '',
  int late = 160,
}) {
  final rest = _restAt(moments);
  final lit = _litAt(moments);
  expect(rest, isNotNull, reason: '$reason: the fan came to rest');
  expect(lit, isNotNull, reason: '$reason: the light landed');
  expect(lit, greaterThanOrEqualTo(rest!), reason: '$reason: on still cards');
  expect(lit! - rest, lessThanOrEqualTo(late), reason: '$reason: at once');
}

/// The peaks of a hand's lit cards are its level's, and every other card of
/// the viewer's stayed exactly as it was.
void _litAsItsLevel(
  Map<String, HandResultCardEffect> peaks,
  List<String> lit,
  HandResultProfile profile, {
  double growthKept = 0.8,
}) {
  for (final MapEntry(key: c, value: p) in peaks.entries) {
    if (lit.contains(c)) {
      // Its full growth, or as much as the room over the hand leaves (the
      // viewer's middle card stands under their own bet badge).
      expect(
        p.scale,
        inInclusiveRange(
          1 + (profile.peakScale - 1) * growthKept,
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
}

/// The end of a hand shown down: the reveal, and a frame later the result
/// and the settled table — the viewer's cards face up unless [viewerBlind];
/// [also] every other hand shown down and beaten (a missile's showdown has
/// three or more).
Future<void> _showdown(
  WidgetTester tester,
  GameState state, {
  required String winner,
  required ResultHand won,
  required ResultHand beaten,
  String? loser,
  Map<String, ResultHand> also = const {},
  bool viewerBlind = false,
  String reason = 'show',
  String category = 'seen',
}) async {
  final lost = loser ?? (winner == 'u0' ? 'u3' : 'u0');
  final viewer = winner == 'u0' ? won : (also['u0'] ?? beaten);
  state.handleShowdown(
    resultReveal(
      winner,
      won,
      loser: lost,
      beaten: beaten,
      also: also,
      reason: reason,
    ),
  );
  await tester.pump(const Duration(milliseconds: 16));
  state
    ..handleShowdown(
      resultEnded(
        winner,
        won,
        loser: lost,
        beaten: beaten,
        also: also,
        reason: reason,
      ),
    )
    ..handleState(
      resultSettled(
        winner,
        loser: lost,
        alsoLost: also.keys.toList(),
        cards: viewer.cards,
        cardCount: viewer.cards.length,
        category: category,
        blind: viewerBlind,
      ),
    );
  await tester.pump(const Duration(milliseconds: 16));
}

/// For [ms] of frames from now: not one of the viewer's cards moves or is
/// swept by the look's light, and — unless [settledOk], where a look that
/// had landed keeps the small light its level rests at (a Trail's radial
/// light included) — no card and no burst carries any light at all.
Future<void> _nothingLands(
  WidgetTester tester, {
  int ms = 2500,
  bool settledOk = false,
  String why = '',
}) async {
  for (var at = 0; at < ms; at += 16) {
    await tester.pump(const Duration(milliseconds: 16));
    if (!settledOk) expect(_litCodes(tester), isEmpty, reason: '$why $at ms');
    for (final c in _ownCodes(tester)) {
      final e = _card(tester, c).effect;
      expect(e.moves, isFalse, reason: '$why $c at $at ms');
      expect(e.sweep, 0, reason: '$why $c at $at ms');
    }
    if (settledOk) {
      expect(_group(tester).progress, 1, reason: '$why $at ms');
    } else {
      expect(_group(tester).debugLightBounds, isNull, reason: '$why $at ms');
    }
  }
}

/// Everything the viewer's own look paints this frame — each card as it is
/// drawn, each card's edge light, the hand's burst — in global pixels.
List<Rect> _lookPaints(WidgetTester tester) => [
  for (final c in _ownCodes(tester)) ...[
    MatrixUtils.transformRect(
      _card(tester, c).child!.getTransformTo(null),
      Offset.zero & _card(tester, c).child!.size,
    ),
    if (_card(tester, c).debugLightBounds case final halo?)
      MatrixUtils.transformRect(
        _card(tester, c).child!.getTransformTo(null),
        halo,
      ),
  ],
  ?_group(tester).debugLightBounds,
];

/// The viewer's own pod, and every key on the felt (Missile and Pack; the
/// sideshow keys, Chaal and its steppers), in global pixels.
({Rect pod, List<Rect> keys}) _besideTheHand(WidgetTester tester) => (
  pod: tester.getRect(
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == 'u0'),
  ),
  keys: [
    ...tester.widgetList(find.byType(MachinedKey)),
    ...tester.widgetList(find.byType(StepperKey)),
  ].map((w) => tester.getRect(find.byWidget(w))).toList(),
);

/// Nothing the look paints this frame ([_lookPaints]) lies over the viewer's
/// pod or a key.
void _clearOfPodAndKeys(
  WidgetTester tester,
  ({Rect pod, List<Rect> keys}) beside,
  String why,
) {
  for (final r in _lookPaints(tester)) {
    expect(r.overlaps(beside.pod), isFalse, reason: '$why: over the pod $r');
    for (final key in beside.keys) {
      expect(r.overlaps(key), isFalse, reason: '$why: over a key $key: $r');
    }
  }
}

/// A look at [h]: the hand dealt blind, the tap on See cards, the server's
/// answer.
Future<void> _look(
  WidgetTester tester,
  GameState state,
  ResultHand h, {
  String category = 'seen',
  bool isPrivate = false,
  String roomId = 'r1',
  int handNo = 7,
  List<String> inHand = const ['u0', 'u3'],
}) async {
  await _deal(
    tester,
    state,
    category: category,
    isPrivate: isPrivate,
    roomId: roomId,
    handNo: handNo,
    inHand: inHand,
  );
  await _tapSee(tester, state);
  await _see(
    tester,
    state,
    h,
    category: category,
    isPrivate: isPrivate,
    roomId: roomId,
    handNo: handNo,
    inHand: inHand,
  );
}

void main() {
  setUpAll(() async {
    // Where async is real (CLAUDE.md §12.3).
    await FireworksArt.load();
    await loadScriptFonts();
  });
  setUp(HandResultMemory.reset);

  group('which cards make the hand', () {
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

    test('the viewer\'s own hand carries the server\'s category, as sent', () {
      final hand = OwnHand.fromJson({
        'handName': 'Trail',
        'category': 5,
        'wild': ['2d'],
        'playsAs': ['7s', '7h', '7d'],
        'best': ['7s', '7h', '2d'],
      });
      expect(hand.category, 5);
      // A server that sends none reads -1, and the name decides.
      expect(OwnHand.fromJson({'handName': 'Pair'}).category, -1);
      // While a 5-Card choice is owed it names nothing.
      final picking = OwnHand.fromJson(ownHandOf(pairHand, picking: true));
      expect(picking.picking, isTrue);
      expect(HandResultLevel.fromCategory(picking.category), isNull);
      expect(HandResultLevel.fromHandName(picking.handName), isNull);
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

  group('the viewer\'s look at a Seen or Blind table', () {
    // Both tables, both themes: Seen by night, Blind by day.
    for (final (table, dark) in [('seen', true), ('blind', false)]) {
      for (final MapEntry(key: name, value: h) in lookHands.entries) {
        testWidgets('$name seen at a $table table (${dark ? 'dark' : 'light'})'
            ': its profile on its cards alone, on still cards, heard once', (
          tester,
        ) async {
          final (state, heard) = await _mount(tester, dark: dark);
          await _look(tester, state, h, category: table);
          final level = HandResultLevel.fromCategory(h.category);
          final watched = await _watch(tester);
          final group = _group(tester);
          if (level == null) {
            // A High Card: nothing among its cards to point at.
            expect(group.cue, isNull);
            expect(watched.moments.where((m) => m.lit), isEmpty);
            for (final p in watched.peaks.values) {
              expect(p, HandResultCardEffect.rest);
            }
            expect(heard.heard, isEmpty);
          } else {
            expect(group.cue?.level, level);
            expect(group.cue?.userId, 'u0');
            expect(group.profile, same(HandResultProfile.of(level)));
            expect(group.progress, 1);
            _litAsItsLevel(
              watched.peaks,
              litOf(h),
              HandResultProfile.of(level),
            );
            _landsOnStillCards(watched.moments, reason: name);
            expect(heard.heard, [level]);
          }
          // Settled: at rest, but for the edge light the rarer hands keep.
          for (final c in h.cards) {
            final e = _card(tester, c).effect;
            expect(e.moves, isFalse, reason: c);
            expect(
              e.glow,
              litOf(h).contains(c) && level != null
                  ? HandResultProfile.of(level).restGlow
                  : 0,
              reason: c,
            );
          }
          // The phone reads what the cards make and says nothing of it: no
          // hand name on the felt at a Seen or Blind table.
          expect(find.text(h.name), findsNothing);
          expect(tester.takeException(), isNull);
          await _unmount(tester, state);
        });
      }
    }

    testWidgets('the fourth blind bet\'s reveal plays it the same way', (
      tester,
    ) async {
      final (state, heard) = await _mount(tester);
      await _deal(tester, state, category: 'blind', blindMovesLeft: 1);
      // The fourth blind chaal: the server turns the cards up by itself, in
      // the snapshot after the bet — no tap.
      await _see(tester, state, sequenceHand, category: 'blind');
      final watched = await _watch(tester);
      expect(_group(tester).cue?.level, HandResultLevel.sequence);
      _litAsItsLevel(
        watched.peaks,
        sequenceHand.cards,
        HandResultProfile.sequence,
      );
      _landsOnStillCards(watched.moments, reason: 'the forced reveal');
      expect(heard.heard, [HandResultLevel.sequence]);
      await _unmount(tester, state);
    });

    testWidgets('a private table plays it by its game', (tester) async {
      final (state, heard) = await _mount(tester);
      await _look(tester, state, colorHand, category: 'blind', isPrivate: true);
      expect(state.room?.isPrivate, isTrue);
      final watched = await _watch(tester);
      _litAsItsLevel(watched.peaks, colorHand.cards, HandResultProfile.color);
      expect(heard.heard, [HandResultLevel.color]);
      await _unmount(tester, state);
    });

    // Nothing the look draws — a risen card, its edge light, a Trail's radial
    // light and sparks — reaches the viewer's own bet badge over their cards
    // (review, 29 Sep 2026: a Trail's middle card lay over the lower third of
    // "SEEN 800" and its light tinted the words), nor the viewer's own pod
    // beside it or a key (the next review, the same day: a Trail's sparks
    // crossed the pod at every size and the key cluster on a 640dp phone).
    for (final (size, scale) in [
      (const Size(592, 360), 1.25),
      (const Size(640, 360), 1.0),
      (const Size(640, 360), 1.25),
      (const Size(891, 411), 1.0),
    ]) {
      for (final MapEntry(key: name, value: h) in resultHands.entries) {
        testWidgets('$name at ${size.width.toInt()}x${size.height.toInt()} '
            'x$scale: never over the bet badge over the hand, the pod beside '
            'it or a key', (tester) async {
          final (state, _) = await _mount(tester, size: size, scale: scale);
          await _look(tester, state, h);
          final over = find.descendant(
            of: _ownColumn,
            matching: find.byType(SeatBet),
          );
          expect(over, findsOneWidget);
          var rose = 0.0;
          var burst = false;
          for (var at = 0; at < 2000; at += 16) {
            await tester.pump(const Duration(milliseconds: 16));
            final line = tester.getRect(over).bottom;
            for (final c in litOf(h)) {
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
            final light = _group(tester).debugLightBounds;
            if (light != null) {
              expect(
                light.top,
                greaterThanOrEqualTo(line - 0.01),
                reason: 'the burst at $at ms',
              );
              burst = true;
            }
            _clearOfPodAndKeys(tester, _besideTheHand(tester), '$at ms');
          }
          // And it did rise: the brief's 2–6 px, bounded, not taken away.
          expect(rose, greaterThanOrEqualTo(2.5));
          // And a Trail's burst was painted, within its bounds, not taken
          // away either.
          expect(burst, h == trailHand);
          await _unmount(tester, state);
        });
      }
    }
  });

  // The Trail's burst — the one light that reaches past the cards — at every
  // phone size: off the viewer's pod on its left and the key cluster on its
  // right, however much room there is between them, while it still sparks.
  for (final (size, scale) in [
    (const Size(592, 360), 1.0),
    (const Size(732, 412), 1.25),
    (const Size(844, 390), 1.25),
    (const Size(915, 412), 1.25),
    (const Size(1280, 800), 1.25),
  ]) {
    testWidgets('a Trail at ${size.width.toInt()}x${size.height.toInt()} '
        'x$scale: its burst stays between the pod and the keys', (
      tester,
    ) async {
      final (state, _) = await _mount(tester, size: size, scale: scale);
      await _look(tester, state, trailHand);
      var burst = 0;
      for (var at = 0; at < 2400; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        if (_group(tester).debugLightBounds != null) burst++;
        _clearOfPodAndKeys(tester, _besideTheHand(tester), '$at ms');
      }
      expect(burst, greaterThan(20), reason: 'it burst');
      await _unmount(tester, state);
    });
  }

  group('never at a result', () {
    testWidgets('a show won by another seat, the viewer blind: their cards '
        'turn up in the reveal and nothing lights anywhere', (tester) async {
      final (state, heard) = await _mount(tester);
      await _deal(tester, state);
      await _showdown(
        tester,
        state,
        winner: 'u3',
        won: trailHand,
        beaten: pureSequenceHand,
        viewerBlind: true,
      );
      for (var at = 0; at < 2500; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_litCodes(tester), isEmpty, reason: 'at $at ms');
      }
      // The viewer's cards are up — the reveal's — and the winner's Trail at
      // its seat: not one card anywhere carries the light.
      expect(_ownCodes(tester), unorderedEquals(pureSequenceHand.cards));
      expect(_group(tester).cue, isNull);
      expect(heard.heard, isEmpty);
      // Only the viewer's own fan is ever wrapped for the light.
      for (final e in find.byType(HandResultCard).evaluate()) {
        expect(
          find.descendant(of: _ownColumn, matching: find.byWidget(e.widget)),
          findsOneWidget,
        );
      }
      expect(
        find.descendant(
          of: find.byWidgetPredicate(
            (w) => w is SeatPod && w.seat?.userId == 'u3',
          ),
          matching: find.byType(HandResultCard),
        ),
        findsNothing,
      );
      await _unmount(tester, state);
    });

    for (final reason in ['show', 'forced_showdown', 'pot_limit', 'missile']) {
      testWidgets('a $reason the viewer looked before: nothing plays again, '
          'the look stays as it settled', (tester) async {
        // A missile needs three players still in the hand (the firer's
        // included).
        final missile = reason == 'missile';
        final inHand = missile ? ['u0', 'u1', 'u3'] : ['u0', 'u3'];
        final (state, heard) = await _mount(tester);
        await _look(tester, state, pureSequenceHand, inHand: inHand);
        await _settle(tester, 2000);
        expect(heard.heard, [HandResultLevel.pureSequence]);
        await _showdown(
          tester,
          state,
          winner: 'u0',
          won: pureSequenceHand,
          beaten: pairHand,
          also: missile ? {'u1': beatenHand} : const {},
          reason: reason,
        );
        for (var at = 0; at < 2500; at += 16) {
          await tester.pump(const Duration(milliseconds: 16));
          for (final c in pureSequenceHand.cards) {
            final e = _card(tester, c).effect;
            expect(e.moves, isFalse, reason: '$c at $at ms');
            expect(e.sweep, 0, reason: '$c at $at ms');
            expect(
              e.glow,
              HandResultProfile.pureSequence.restGlow,
              reason: '$c at $at ms',
            );
          }
        }
        expect(heard.heard, [HandResultLevel.pureSequence]);
        await _unmount(tester, state);
      });
    }
  });

  // The server's own order (review, 29 Sep 2026): the look's own snapshot
  // goes out BEFORE a showdown the same move runs — go-server table.go `see`
  // emits the viewer's cards up and still betting, and only then does `bet`
  // run advanceTurn into the round-cap or pot-cap showdown; table_fivecard.go
  // `settlePick` emits the choice before runDeferredShowdown — and a look made
  // a moment before a show, a missile or the last pack is still on its way
  // when the result arrives. However the snapshots fall into frames, nothing
  // lands once the hand is over: a look still waiting to land is dropped (not
  // heard, never lit), and one already playing is settled at once.
  group('a hand that ends while the look is on its way', () {
    // The viewer's losing Trail: twos, beaten by Arjun's aces.
    final twos = hand(['2s', '2h', '2d'], 'Trail', 5);

    for (final between in [0, 1, 3]) {
      testWidgets('the fourth blind bet reaching the pot cap, $between '
          'frame(s) between the look and the showdown: the cards turn up and '
          'nothing lights', (tester) async {
        final (state, heard) = await _mount(tester);
        await _deal(tester, state, blindMovesLeft: 1);
        // `see`'s own room:state: still betting, the cards up …
        state.handleState(resultRoom(cards: twos.cards));
        for (var frame = 0; frame < between; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        // … then the bet's advanceTurn: the pot cap reached, every hand
        // shown down, Arjun's aces take it.
        await _showdown(
          tester,
          state,
          winner: 'u3',
          won: trailHand,
          beaten: twos,
          reason: 'pot_limit',
        );
        expect(_ownCodes(tester), unorderedEquals(twos.cards));
        await _nothingLands(tester, why: 'pot limit');
        expect(_group(tester).cue, isNull);
        expect(heard.heard, isEmpty);
        await _unmount(tester, state);
      });
    }

    testWidgets('the round cap reached by the same move, in one snapshot: '
        'nothing lights', (tester) async {
      final (state, heard) = await _mount(tester);
      await _deal(tester, state, blindMovesLeft: 1);
      // Both of the server's snapshots handled before one frame is drawn:
      // the look is first seen with the hand already shown down.
      state.handleState(resultRoom(cards: twos.cards));
      await _showdown(
        tester,
        state,
        winner: 'u3',
        won: trailHand,
        beaten: twos,
        reason: 'forced_showdown',
      );
      await _nothingLands(tester, why: 'forced showdown');
      expect(heard.heard, isEmpty);
      await _unmount(tester, state);
    });

    // See cards tapped a moment (200 ms) before the hand ends another way.
    Future<void> lookThenEnd(
      WidgetTester tester, {
      required ResultHand h,
      required Future<void> Function(GameState state) end,
      List<String> inHand = const ['u0', 'u3'],
      bool heardNothing = true,
    }) async {
      final (state, heard) = await _mount(tester);
      await _look(tester, state, h, inHand: inHand);
      await _frames(tester, 200);
      expect(_litCodes(tester), isEmpty, reason: 'not landed yet');
      await end(state);
      await tester.pump(const Duration(milliseconds: 16));
      await _nothingLands(tester, why: h.name);
      expect(_group(tester).cue, isNull);
      expect(heard.heard, isEmpty);
      await _unmount(tester, state);
    }

    testWidgets('a show won by another seat a moment after the look: its '
        'light never lands', (tester) async {
      await lookThenEnd(
        tester,
        h: twos,
        end: (state) => _showdown(
          tester,
          state,
          winner: 'u3',
          won: trailHand,
          beaten: twos,
        ),
      );
    });

    testWidgets('a show the viewer wins a moment after the look: its light '
        'never lands under the winner\'s celebration', (tester) async {
      await lookThenEnd(
        tester,
        h: trailHand,
        end: (state) => _showdown(
          tester,
          state,
          winner: 'u0',
          won: trailHand,
          beaten: pairHand,
        ),
      );
    });

    testWidgets('the last other player packing a moment after the look: its '
        'light never lands', (tester) async {
      await lookThenEnd(
        tester,
        h: pureSequenceHand,
        end: (state) async {
          state
            ..handleShowdown((
              reveals: const [],
              result: 'Priya won 13400',
              winnerId: 'u0',
              winnerName: 'Priya',
              pot: 13400,
              nextHandAt: DateTime.now().millisecondsSinceEpoch + 6000,
              reason: 'last_standing',
            ))
            ..handleState(resultSettled('u0', cards: pureSequenceHand.cards));
        },
      );
    });

    testWidgets('a missile fired a moment after the look: its light never '
        'lands, in the volley or at the showdown it brings', (tester) async {
      await lookThenEnd(
        tester,
        h: twos,
        inHand: const ['u0', 'u1', 'u3'],
        end: (state) async {
          state.handleTableAction((
            userId: 'u3',
            action: GameAction.missile,
            reason: null,
          ));
          expect(state.missileStrike, isNotNull);
          await tester.pump(const Duration(milliseconds: 16));
          await _showdown(
            tester,
            state,
            winner: 'u3',
            won: trailHand,
            beaten: twos,
            also: {'u1': beatenHand},
            reason: 'missile',
          );
        },
      );
    });

    testWidgets('a sideshow\'s two hands turned over a moment after the look: '
        'its light never lands on them', (tester) async {
      await lookThenEnd(
        tester,
        h: trailHand,
        end: (state) async => state.handleSideshowReveal(
          SideshowReveal.fromJson({
            'hands': [
              {'userId': 'u0', 'cards': trailHand.cards, 'handName': 'Trail'},
              {
                'userId': 'u3',
                'cards': sequenceHand.cards,
                'handName': 'Sequence',
              },
            ],
            'packedUserId': 'u3',
          }),
        ),
      );
    });

    testWidgets('the 5-Card three chosen, and a frame later the pot-cap '
        'showdown it was holding: nothing lights', (tester) async {
      // A private Variation table (a public one has no pot cap).
      final five = variationBlock(selected: Variation.fiveCard);
      final dealt = ['7s', '2c', '7h', '9d', '7d'];
      final (state, heard) = await _mount(tester);
      await _deal(
        tester,
        state,
        category: 'variation',
        isPrivate: true,
        variation: five,
        cardCount: 5,
      );
      await _tapSee(tester, state);
      await _see(
        tester,
        state,
        hand(dealt, '', 0),
        category: 'variation',
        isPrivate: true,
        variation: five,
        ownHand: ownHandOf(hand(dealt, '', 0), picking: true),
      );
      await _settle(tester, 1000);
      // settlePick's own snapshot: the three chosen, still betting …
      final sevens = hand(dealt, 'Trail', 5, best: ['7s', '7h', '7d']);
      await _see(
        tester,
        state,
        sevens,
        category: 'variation',
        isPrivate: true,
        variation: five,
        ownHand: ownHandOf(sevens, pickedBy: 'PLAYER'),
      );
      // … and a frame later runDeferredShowdown: Arjun's aces.
      await _showdown(
        tester,
        state,
        winner: 'u3',
        won: trailHand,
        beaten: sevens,
        reason: 'pot_limit',
        category: 'variation',
      );
      await _nothingLands(tester, ms: 3400, why: '5-Card');
      expect(heard.heard, isEmpty);
      await _unmount(tester, state);
    });

    testWidgets('a look already playing when a show ends the hand settles at '
        'once and plays no further', (tester) async {
      final (state, heard) = await _mount(tester);
      await _look(tester, state, trailHand);
      await _frames(tester, 900); // landed: the burst is on
      expect(_group(tester).progress, inExclusiveRange(0, 1));
      expect(heard.heard, [HandResultLevel.trail]);
      await _showdown(
        tester,
        state,
        winner: 'u0',
        won: trailHand,
        beaten: pairHand,
      );
      expect(_group(tester).progress, 1);
      await _nothingLands(tester, settledOk: true, why: 'settled');
      for (final c in trailHand.cards) {
        expect(
          _card(tester, c).effect.glow,
          HandResultProfile.trail.restGlow,
          reason: c,
        );
      }
      expect(heard.heard, [HandResultLevel.trail]);
      await _unmount(tester, state);
    });

    // The felt built again in the same hand (the table screen rebuilt, a
    // reconnect) shows the look as this phone showed it.
    Future<void> rebuild(WidgetTester tester, GameState state) async {
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
    }

    // Dropped: the showdown came in the same frame as the look (the round
    // cap reached by the fourth blind bet, both snapshots handled before one
    // frame is drawn — review, 29 Sep 2026: that look was never recorded as
    // dropped, and the felt built again lit the viewer's losing Trail over
    // the winner's result) or a frame after it.
    for (final between in [0, 1]) {
      testWidgets('a felt built again after the hand ended shows a look '
          'dropped $between frame(s) before the showdown as nothing', (
        tester,
      ) async {
        final (state, heard) = await _mount(tester);
        await _deal(tester, state, blindMovesLeft: 1);
        state.handleState(resultRoom(cards: twos.cards));
        for (var frame = 0; frame < between; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        await _showdown(
          tester,
          state,
          winner: 'u3',
          won: trailHand,
          beaten: twos,
          reason: 'forced_showdown',
        );
        await _nothingLands(tester, ms: 400, why: 'dropped');
        await rebuild(tester, state);
        await _nothingLands(tester, ms: 1200, why: 'dropped, rebuilt');
        expect(_group(tester).cue, isNull);
        expect(heard.heard, isEmpty);
        await _unmount(tester, state);
      });
    }

    testWidgets('a felt built again after the hand ended shows a played look '
        'settled', (tester) async {
      final (state, _) = await _mount(tester);
      await _look(tester, state, trailHand);
      await _settle(tester, 2500);
      await _showdown(
        tester,
        state,
        winner: 'u0',
        won: trailHand,
        beaten: pairHand,
      );
      await rebuild(tester, state);
      await _nothingLands(tester, ms: 1200, settledOk: true, why: 'rebuilt');
      for (final c in trailHand.cards) {
        expect(
          _card(tester, c).effect.glow,
          HandResultProfile.trail.restGlow,
          reason: c,
        );
      }
      await _unmount(tester, state);
    });

    testWidgets('an app started afresh at the result lights nothing it never '
        'played there', (tester) async {
      final (state, _) = await _mount(tester);
      await _look(tester, state, trailHand);
      await _settle(tester, 2500);
      await _showdown(
        tester,
        state,
        winner: 'u0',
        won: trailHand,
        beaten: pairHand,
      );
      // The app's memory of the looks it played goes with the process.
      HandResultMemory.reset();
      await rebuild(tester, state);
      await _nothingLands(tester, ms: 1200, why: 'started afresh');
      expect(_group(tester).cue, isNull);
      await _unmount(tester, state);
    });
  });

  group('never at a result, a sideshow', () {
    testWidgets('a sideshow lights neither hand: the look was the viewer\'s '
        'moment', (tester) async {
      final (state, heard) = await _mount(tester);
      await _look(tester, state, trailHand);
      await _settle(tester, 2000);
      state.handleSideshowReveal(
        SideshowReveal.fromJson({
          'hands': [
            {'userId': 'u0', 'cards': trailHand.cards, 'handName': 'Trail'},
            {
              'userId': 'u3',
              'cards': sequenceHand.cards,
              'handName': 'Sequence',
            },
          ],
          'packedUserId': 'u3',
        }),
      );
      for (var at = 0; at < 1600; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        for (final c in _litCodes(tester)) {
          expect(trailHand.cards, contains(c), reason: 'at $at ms');
          expect(_card(tester, c).effect.moves, isFalse, reason: 'at $at ms');
        }
      }
      expect(heard.heard, [HandResultLevel.trail]);
      await _unmount(tester, state);
    });
  });

  group('once a hand', () {
    testWidgets('a snapshot repeat plays nothing, and a settled hand paints '
        'nothing more over 60 frames', (tester) async {
      for (final h in [trailHand, pureSequenceHand, pairHand]) {
        HandResultMemory.reset();
        final (state, heard) = await _mount(tester);
        await _look(tester, state, h);
        await _settle(tester, 2500);
        final level = HandResultLevel.fromCategory(h.category)!;
        expect(_group(tester).progress, 1);
        RenderHandResultCard.debugLitPaints = 0;
        for (var frame = 0; frame < 60; frame++) {
          // The one-second tick, and the same hand's snapshot again (a
          // reconnect's room:joined, another player's move).
          if (frame % 15 == 0) state.notifyListeners();
          if (frame == 30) await _see(tester, state, h);
          await tester.pump(const Duration(milliseconds: 16));
          for (final c in h.cards) {
            expect(_card(tester, c).effect.moves, isFalse, reason: c);
          }
        }
        expect(RenderHandResultCard.debugLitPaints, 0, reason: h.name);
        expect(heard.heard, [level]);
        await _unmount(tester, state);
      }
    });

    testWidgets('a felt built again mid-look shows it settled and plays '
        'nothing', (tester) async {
      final (state, heard) = await _mount(tester);
      await _look(tester, state, trailHand);
      await _frames(tester, 900); // the light has landed; the burst is on
      expect(_group(tester).progress, inExclusiveRange(0, 1));
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
        for (final c in trailHand.cards) {
          final e = _card(tester, c).effect;
          expect(e.moves, isFalse, reason: '$c at $at ms');
          expect(e.glow, HandResultProfile.trail.restGlow, reason: c);
        }
      }
      expect(heard.heard, [HandResultLevel.trail]);
      expect(feedback.heard, isEmpty);
      await _unmount(tester, state);
    });

    testWidgets('the next deal takes the light with it, and the next look '
        'plays again', (tester) async {
      final (state, heard) = await _mount(tester);
      await _look(tester, state, trailHand);
      await _frames(tester, 900);
      expect(_litCodes(tester), isNotEmpty);
      state.handleState(resultNextDeal());
      await tester.pump(const Duration(milliseconds: 16));
      // At once: the next snapshot is never held for the animation.
      expect(state.room?.handNo, 8);
      expect(_litCodes(tester), isEmpty);
      expect(_group(tester).cue, isNull);
      await _settle(tester, 3000);
      expect(_litCodes(tester), isEmpty);
      await _tapSee(tester, state);
      await _see(tester, state, trailHand, handNo: 8);
      final watched = await _watch(tester);
      _litAsItsLevel(watched.peaks, trailHand.cards, HandResultProfile.trail);
      expect(heard.heard, [HandResultLevel.trail, HandResultLevel.trail]);
      await _unmount(tester, state);
    });

    testWidgets('a switch of table is a new hand: nothing is carried to it, '
        'and a look there plays', (tester) async {
      final (state, heard) = await _mount(tester);
      await _look(tester, state, trailHand);
      await _settle(tester, 2000);
      // Another table whose hand carries the same number.
      await _deal(tester, state, roomId: 'r2');
      expect(_litCodes(tester), isEmpty);
      expect(_group(tester).cue, isNull);
      await _tapSee(tester, state);
      await _see(tester, state, trailHand, roomId: 'r2');
      final watched = await _watch(tester);
      _litAsItsLevel(watched.peaks, trailHand.cards, HandResultProfile.trail);
      _landsOnStillCards(watched.moments, reason: 'at the new table');
      expect(heard.heard, [HandResultLevel.trail, HandResultLevel.trail]);
      await _unmount(tester, state);
    });

    testWidgets('packing takes the light away', (tester) async {
      final (state, _) = await _mount(tester);
      await _look(tester, state, pureSequenceHand);
      await _settle(tester, 2000);
      expect(_litCodes(tester), isNotEmpty);
      await _see(tester, state, pureSequenceHand, status: 'packed');
      await _settle(tester, 500);
      expect(_litCodes(tester), isEmpty);
      expect(_group(tester).cue, isNull);
      await _unmount(tester, state);
    });
  });

  group('the viewer\'s look at a Variation table', () {
    // AK47: the K is wild and played as a nine beside the natural 9d — a Pair
    // of nines (the strongest it could make: 9 9 2).
    final wildPair = hand(
      ['Ks', '9d', '2c'],
      'Pair',
      1,
      wild: ['Ks'],
      playsAs: ['9h', '9d', '2c'],
    );
    final ak47 = variationBlock(selected: Variation.ak47);

    testWidgets('looked after the choice: a wild card lights with the natural '
        'card it paired, once it has turned', (tester) async {
      final (state, heard) = await _mount(tester);
      await _deal(tester, state, category: 'variation', variation: ak47);
      await _tapSee(tester, state);
      await _see(
        tester,
        state,
        wildPair,
        category: 'variation',
        variation: ak47,
        ownHand: ownHandOf(wildPair),
      );
      final watched = await _watch(tester, ms: 3200);
      expect(_group(tester).cue?.level, HandResultLevel.pair);
      _litAsItsLevel(watched.peaks, ['Ks', '9d'], HandResultProfile.pair);
      _landsOnStillCards(watched.moments, reason: 'after the wild turn');
      expect(heard.heard, [HandResultLevel.pair]);
      await _unmount(tester, state);
    });

    testWidgets('looked before the choice: nothing until it lands, then '
        'once the wild card has turned', (tester) async {
      final (state, heard) = await _mount(tester);
      final open = variationBlock();
      await _deal(tester, state, category: 'variation', variation: open);
      await _tapSee(tester, state);
      await _see(
        tester,
        state,
        wildPair,
        category: 'variation',
        variation: open,
      );
      for (var at = 0; at < 1500; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_litCodes(tester), isEmpty, reason: 'at $at ms');
      }
      expect(_group(tester).cue, isNull);
      await _see(
        tester,
        state,
        wildPair,
        category: 'variation',
        variation: ak47,
        ownHand: ownHandOf(wildPair),
      );
      final watched = await _watch(tester, ms: 3000);
      _litAsItsLevel(watched.peaks, ['Ks', '9d'], HandResultProfile.pair);
      _landsOnStillCards(watched.moments, reason: 'the choice landing');
      expect(heard.heard, [HandResultLevel.pair]);
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
      final joker = variationBlock(selected: Variation.joker, turnUp: '2c');
      await _deal(tester, state, category: 'variation', variation: joker);
      await _tapSee(tester, state);
      await _see(
        tester,
        state,
        jokerTrail,
        category: 'variation',
        variation: joker,
        ownHand: ownHandOf(jokerTrail),
      );
      final watched = await _watch(tester, ms: 3200);
      expect(_group(tester).profile, same(HandResultProfile.trail));
      _litAsItsLevel(watched.peaks, jokerTrail.cards, HandResultProfile.trail);
      _landsOnStillCards(watched.moments, reason: 'the joker');
      expect(heard.heard, [HandResultLevel.trail]);
      await _unmount(tester, state);
    });

    testWidgets('a Muflis hand is not lit by its rarity', (tester) async {
      final (state, heard) = await _mount(tester);
      final muflis = variationBlock(selected: Variation.muflis);
      await _deal(tester, state, category: 'variation', variation: muflis);
      await _tapSee(tester, state);
      await _see(
        tester,
        state,
        trailHand,
        category: 'variation',
        variation: muflis,
        ownHand: ownHandOf(trailHand),
      );
      for (var at = 0; at < 2000; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_litCodes(tester), isEmpty, reason: 'at $at ms');
      }
      expect(heard.heard, isEmpty);
      await _unmount(tester, state);
    });

    testWidgets('what the server says the hand makes, not what the phone '
        'would read — and a changed answer plays once more', (tester) async {
      final (state, heard) = await _mount(tester);
      await _deal(tester, state, category: 'variation', variation: ak47);
      await _tapSee(tester, state);
      await _see(
        tester,
        state,
        wildPair,
        category: 'variation',
        variation: ak47,
        ownHand: ownHandOf(wildPair),
      );
      await _settle(tester, 3000);
      expect(heard.heard, [HandResultLevel.pair]);
      // Were the server to name the hand anew within it (it never does at a
      // variation table), the new answer plays once, as a look already made.
      final named = hand(['Ks', '9d', '2c'], 'Trail', 5, wild: ['Ks']);
      await _see(
        tester,
        state,
        wildPair,
        category: 'variation',
        variation: ak47,
        ownHand: ownHandOf(named),
      );
      final watched = await _watch(tester);
      _litAsItsLevel(watched.peaks, wildPair.cards, HandResultProfile.trail);
      await _see(
        tester,
        state,
        wildPair,
        category: 'variation',
        variation: ak47,
        ownHand: ownHandOf(named),
      );
      await _settle(tester, 1500);
      expect(heard.heard, [HandResultLevel.pair, HandResultLevel.trail]);
      await _unmount(tester, state);
    });
  });

  group('5-Card', () {
    final five = variationBlock(selected: Variation.fiveCard);
    final dealt = ['As', '2c', 'Ah', '9d', 'Ad'];
    final picking = hand(dealt, '', 0);

    Future<void> lookAtFive(WidgetTester tester, GameState state) async {
      await _deal(
        tester,
        state,
        category: 'variation',
        variation: five,
        cardCount: 5,
      );
      await _tapSee(tester, state);
      await _see(
        tester,
        state,
        picking,
        category: 'variation',
        variation: five,
        ownHand: ownHandOf(picking, picking: true),
      );
    }

    testWidgets('nothing while the three are being chosen; once chosen, the '
        'three that play, after the fan is set out', (tester) async {
      final (state, heard) = await _mount(tester);
      await lookAtFive(tester, state);
      for (var at = 0; at < 1500; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(_litCodes(tester), isEmpty, reason: 'at $at ms');
      }
      expect(_group(tester).cue, isNull);
      final chosen = hand(dealt, 'Trail', 5, best: ['As', 'Ah', 'Ad']);
      await _see(
        tester,
        state,
        chosen,
        category: 'variation',
        variation: five,
        ownHand: ownHandOf(chosen, pickedBy: 'PLAYER'),
      );
      final watched = await _watch(tester, ms: 3400);
      // The three that count stand raised in the arranged fan, right under
      // the bet badge over it (about 2dp of room at 891x411): they rise and
      // grow only as far as that room — the hand rises as one — and the Trail
      // is carried by its light.
      _litAsItsLevel(
        watched.peaks,
        ['As', 'Ah', 'Ad'],
        HandResultProfile.trail,
        growthKept: 0,
      );
      _landsOnStillCards(watched.moments, reason: 'the three set out');
      expect(heard.heard, [HandResultLevel.trail]);
      await _unmount(tester, state);
    });

    testWidgets('the window lapsing plays the first three dealt', (
      tester,
    ) async {
      final (state, heard) = await _mount(tester);
      await lookAtFive(tester, state);
      await _settle(tester, 1000);
      // The same five cards (a hand's cards never change): the lapse plays
      // the first three dealt, A♠ 2♣ A♥ — a pair of aces — and the server
      // names it so, not the Trail the five could have made.
      final lapsed = hand(dealt, 'Pair', 1, best: ['As', '2c', 'Ah']);
      await _see(
        tester,
        state,
        lapsed,
        category: 'variation',
        variation: five,
        ownHand: ownHandOf(lapsed, pickedBy: 'TIMEOUT'),
      );
      final watched = await _watch(tester, ms: 3000);
      // The three that count stand raised in the arranged fan, right under
      // the bet badge: the pair grows only as far as that room.
      _litAsItsLevel(
        watched.peaks,
        ['As', 'Ah'],
        HandResultProfile.pair,
        growthKept: 0,
      );
      _landsOnStillCards(watched.moments, reason: 'the lapse');
      expect(heard.heard, [HandResultLevel.pair]);
      await _unmount(tester, state);
    });
  });

  group('the light lands on cards at rest', () {
    // Measured on the real felt, frame by frame: when the fan stops moving
    // and when the light lands, in ms since the look's snapshot.
    testWidgets('the numbers', (tester) async {
      final rows = <String>[];
      Future<void> measure(String name, Future<void> Function() look) async {
        HandResultMemory.reset();
        await look();
        final watched = await _watch(tester, ms: 3400);
        final rest = _restAt(watched.moments)!;
        final lit = _litAt(watched.moments)!;
        rows.add('$name: still at $rest ms, light at $lit ms (+${lit - rest})');
        _landsOnStillCards(watched.moments, reason: name);
      }

      var (state, _) = await _mount(tester);
      await measure('See cards, three cards', () async {
        await _deal(tester, state);
        await _tapSee(tester, state);
        await _see(tester, state, trailHand);
      });
      await _unmount(tester, state);

      (state, _) = await _mount(tester);
      final wildPair = hand(
        ['Ks', '9d', '2c'],
        'Pair',
        1,
        wild: ['Ks'],
        playsAs: ['9h', '9d', '2c'],
      );
      final ak47 = variationBlock(selected: Variation.ak47);
      await measure('See cards with a wild card', () async {
        await _deal(tester, state, category: 'variation', variation: ak47);
        await _tapSee(tester, state);
        await _see(
          tester,
          state,
          wildPair,
          category: 'variation',
          variation: ak47,
          ownHand: ownHandOf(wildPair),
        );
      });
      await _unmount(tester, state);

      (state, _) = await _mount(tester);
      await measure('the variation chosen on a player looking', () async {
        final open = variationBlock();
        await _deal(tester, state, category: 'variation', variation: open);
        await _tapSee(tester, state);
        await _see(
          tester,
          state,
          wildPair,
          category: 'variation',
          variation: open,
        );
        await _settle(tester, 1000);
        await _see(
          tester,
          state,
          wildPair,
          category: 'variation',
          variation: ak47,
          ownHand: ownHandOf(wildPair),
        );
      });
      await _unmount(tester, state);

      (state, _) = await _mount(tester);
      final five = variationBlock(selected: Variation.fiveCard);
      final dealt = ['As', '2c', 'Ah', '9d', 'Ad'];
      await measure('the 5-Card three chosen', () async {
        await _deal(
          tester,
          state,
          category: 'variation',
          variation: five,
          cardCount: 5,
        );
        await _tapSee(tester, state);
        await _see(
          tester,
          state,
          hand(dealt, '', 0),
          category: 'variation',
          variation: five,
          ownHand: ownHandOf(hand(dealt, '', 0), picking: true),
        );
        await _settle(tester, 1000);
        final chosen = hand(dealt, 'Trail', 5, best: ['As', 'Ah', 'Ad']);
        await _see(
          tester,
          state,
          chosen,
          category: 'variation',
          variation: five,
          ownHand: ownHandOf(chosen, pickedBy: 'PLAYER'),
        );
      });
      await _unmount(tester, state);
      // For the review: where the light lands against the fan's own motion.
      // ignore: avoid_print
      rows.forEach(print);
    });
  });

  group('motion, themes and idle', () {
    testWidgets('reduced motion moves less, sweeps nothing and bursts '
        'nothing, and still marks the cards', (tester) async {
      for (final h in [trailHand, pairHand]) {
        HandResultMemory.reset();
        final (state, _) = await _mount(tester, reduced: true);
        await _look(tester, state, h);
        final level = HandResultLevel.fromCategory(h.category)!;
        final watched = await _watch(tester);
        expect(
          _group(tester).profile,
          same(HandResultProfile.reducedOf(level)),
        );
        for (final c in litOf(h)) {
          final p = watched.peaks[c]!;
          expect(p.scale, lessThan(HandResultProfile.of(level).peakScale));
          expect(p.sweep, 0);
          // At least the reduced mark's light, give or take a frame's sample.
          expect(
            p.glow,
            greaterThanOrEqualTo(HandResultProfile.reducedMark - 0.01),
          );
        }
        expect(_group(tester).debugLightBounds, isNull);
        // The phone's own reduced motion runs the cards' turns twenty times
        // faster (their beats are timers, and keep their length); the look
        // waits for the turns as they then run, so its mark lands a beat after
        // the cards are still, as it does at full motion — and keeps its own
        // time, so it stays up for the level's run, not a frame.
        _landsOnStillCards(watched.moments, reason: '${h.name} reduced');
        await _unmount(tester, state);
        // And the mark stays up for the level's run, not a frame: frame by
        // frame over the look again, the edge light of a card it lights.
        HandResultMemory.reset();
        final (again, _) = await _mount(tester, reduced: true);
        await _look(tester, again, h);
        var marked = 0;
        for (var at = 0; at < 2600; at += 16) {
          await tester.pump(const Duration(milliseconds: 16));
          if (_card(tester, litOf(h).first).effect.glow >=
              HandResultProfile.reducedMark * 0.5) {
            marked++;
          }
        }
        expect(
          marked * 16,
          greaterThanOrEqualTo(
            HandResultProfile.of(level).duration.inMilliseconds ~/ 2,
          ),
        );
        await _unmount(tester, again);
      }
    });

    testWidgets('reduced motion: a wild card turned and the 5-Card three set '
        'out, the mark a beat after the fan is still', (tester) async {
      final wildPair = hand(
        ['Ks', '9d', '2c'],
        'Pair',
        1,
        wild: ['Ks'],
        playsAs: ['9h', '9d', '2c'],
      );
      final ak47 = variationBlock(selected: Variation.ak47);
      var (state, _) = await _mount(tester, reduced: true);
      await _deal(tester, state, category: 'variation', variation: ak47);
      await _tapSee(tester, state);
      await _see(
        tester,
        state,
        wildPair,
        category: 'variation',
        variation: ak47,
        ownHand: ownHandOf(wildPair),
      );
      var watched = await _watch(tester, ms: 3000);
      expect(
        _group(tester).profile,
        same(HandResultProfile.reducedOf(HandResultLevel.pair)),
      );
      _landsOnStillCards(watched.moments, reason: 'the wild card, reduced');
      await _unmount(tester, state);

      HandResultMemory.reset();
      (state, _) = await _mount(tester, reduced: true);
      final five = variationBlock(selected: Variation.fiveCard);
      final dealt = ['As', '2c', 'Ah', '9d', 'Ad'];
      await _deal(
        tester,
        state,
        category: 'variation',
        variation: five,
        cardCount: 5,
      );
      await _tapSee(tester, state);
      await _see(
        tester,
        state,
        hand(dealt, '', 0),
        category: 'variation',
        variation: five,
        ownHand: ownHandOf(hand(dealt, '', 0), picking: true),
      );
      await _settle(tester, 1000);
      final chosen = hand(dealt, 'Trail', 5, best: ['As', 'Ah', 'Ad']);
      await _see(
        tester,
        state,
        chosen,
        category: 'variation',
        variation: five,
        ownHand: ownHandOf(chosen, pickedBy: 'PLAYER'),
      );
      watched = await _watch(tester, ms: 3000);
      _landsOnStillCards(watched.moments, reason: 'the 5-Card three, reduced');
      await _unmount(tester, state);
    });

    for (final dark in [true, false]) {
      testWidgets('a Trail by ${dark ? 'night' : 'day'} takes the theme\'s '
          'light and settles still', (tester) async {
        final (state, _) = await _mount(tester, dark: dark);
        await _look(tester, state, trailHand);
        // At the height of the burst the hand's own light is painted …
        await _frames(tester, 900);
        expect(_group(tester).debugLightBounds, isNotNull);
        // … and once settled, only the small light a Trail keeps.
        await _settle(tester, 2000);
        for (final c in trailHand.cards) {
          final e = _card(tester, c).effect;
          expect(e.moves, isFalse);
          expect(e.glow, HandResultProfile.trail.restGlow);
        }
        RenderHandResultCard.debugLitPaints = 0;
        await _frames(tester, 60 * 16);
        expect(RenderHandResultCard.debugLitPaints, 0);
        expect(tester.takeException(), isNull);
        await _unmount(tester, state);
      });
    }
  });

  group('640x360 at x1.25, every language', () {
    for (final lang in AppLang.values) {
      for (final dark in [true, false]) {
        testWidgets('${lang.code} ${dark ? 'dark' : 'light'}: See cards, a '
            'Trail and a Pair, nothing cut and nothing over a key', (
          tester,
        ) async {
          if (!haveScriptFonts()) {
            markTestSkipped('the Noto fonts are not on this machine');
            return;
          }
          for (final h in [trailHand, pairHand]) {
            HandResultMemory.reset();
            final (state, heard) = await _mount(
              tester,
              size: const Size(640, 360),
              scale: 1.25,
              dark: dark,
              lang: lang,
            );
            await _deal(tester, state);
            expect(find.text(state.t.see.toUpperCase()), findsOneWidget);
            await _tapSee(tester, state);
            await _see(tester, state, h);
            final view = Offset.zero & const Size(640, 360);
            final beside = _besideTheHand(tester);
            final keys = beside.keys;
            final pod = beside.pod;
            for (var at = 0; at < 2200; at += 16) {
              await tester.pump(const Duration(milliseconds: 16));
              final badge = tester.getRect(
                find.descendant(of: _ownColumn, matching: find.byType(SeatBet)),
              );
              for (final c in h.cards) {
                final card = _card(tester, c);
                final child = card.child!;
                final painted = MatrixUtils.transformRect(
                  child.getTransformTo(null),
                  Offset.zero & child.size,
                );
                final why = '${lang.code} ${h.name} $c at $at ms';
                expect(view.contains(painted.topLeft), isTrue, reason: why);
                expect(view.contains(painted.bottomRight), isTrue, reason: why);
                expect(painted.top, greaterThanOrEqualTo(badge.bottom));
                expect(painted.overlaps(pod), isFalse, reason: why);
                for (final key in keys) {
                  expect(painted.overlaps(key), isFalse, reason: why);
                }
              }
              // And every light it paints — each card's edge light, a
              // Trail's radial light and sparks — as well as the cards.
              _clearOfPodAndKeys(
                tester,
                beside,
                '${lang.code} ${h.name} at $at ms',
              );
            }
            expect(heard.heard, [HandResultLevel.fromCategory(h.category)]);
            expect(tester.takeException(), isNull);
            await _unmount(tester, state);
          }
        });
      }
    }
  });

  group('the group on its own', () {
    Widget stage(
      AnimationController clock, {
      Key? key,
      HandResultLevel level = HandResultLevel.trail,
      double headroom = 20,
      ({double left, double right})? beside,
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
      final hand = Center(
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
      );
      return MaterialApp(
        home: beside == null
            ? hand
            : HandResultBounds(edges: () => beside, child: hand),
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

    testWidgets('its light stays between what stands beside the hand, and '
        'still bursts', (tester) async {
      final clock = AnimationController(
        vsync: const TestVSync(),
        duration: const Duration(seconds: 3),
      );
      addTearDown(clock.dispose);
      // Without bounds, a Trail's light reaches well past the hand's sides.
      await tester.pumpWidget(stage(clock));
      final hand = tester.getRect(find.byType(HandResultGroup));
      HandResultGroupState group() =>
          tester.state<HandResultGroupState>(find.byType(HandResultGroup));
      var widest = hand;
      for (var ms = 500; ms <= 1700; ms += 20) {
        clock.value = ms / 3000;
        await tester.pump();
        if (group().debugLightBounds case final l?) {
          widest = widest.expandToInclude(l);
        }
      }
      expect(widest.left, lessThan(hand.left - 20));
      expect(widest.right, greaterThan(hand.right + 20));
      // With the viewer's pod 6 px to its left and the keys 3 px to its
      // right, it stays between them — less the clearance — and still
      // bursts.
      final left = hand.left - 6;
      final right = hand.right + 3;
      clock.value = 0;
      await tester.pumpWidget(stage(clock, beside: (left: left, right: right)));
      var painted = 0;
      var sparked = false;
      for (var ms = 500; ms <= 1700; ms += 20) {
        clock.value = ms / 3000;
        await tester.pump();
        final l = group().debugLightBounds;
        if (l == null) continue;
        painted++;
        expect(
          l.left,
          greaterThanOrEqualTo(left + HandResultShape.clearance - 0.01),
          reason: '$ms ms',
        );
        expect(
          l.right,
          lessThanOrEqualTo(right - HandResultShape.clearance + 0.01),
          reason: '$ms ms',
        );
        // Sparks still fly out past the top or foot of the hand.
        if (l.bottom > hand.bottom + 10) sparked = true;
      }
      expect(painted, greaterThan(20));
      expect(sparked, isTrue);
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
