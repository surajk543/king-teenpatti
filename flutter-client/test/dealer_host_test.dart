// The table's host (owner's brief, 24 Sep 2026: "an elegant female
// dealer/host ... behind the center of the table ... never cover player cards;
// never cover action buttons ... Gameplay always has priority over
// decoration"): what she does and when, the artwork contract a commissioned
// illustration meets, how far she moves, and — laid out for real on the Teen
// Patti table at every phone size the table is checked at — that her box never
// touches a seat, a card, the pot, the tag, the waiting line, a speech bubble
// or a key.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/casino_table.dart';
import 'package:teenpatti/widgets/deal_flight.dart';
import 'package:teenpatti/widgets/dealer_host.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/table_chrome.dart';
import 'package:teenpatti/widgets/variation_prompt.dart';

import 'table_scenes.dart';

TableScene _scene(String prefix) =>
    tableScenes.firstWhere((s) => s.name.startsWith(prefix));

/// The table mounted in [scene] at [size] with text at [textScale], settled.
Future<GameState> _mount(
  WidgetTester tester,
  TableScene scene, {
  Size size = const Size(640, 360),
  double textScale = 1.0,
  bool dark = true,
  bool act = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = sceneState(scene);
  await tester.pumpWidget(
    tableApp(
      state: state,
      feedback: feedback,
      theme: dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
    ),
  );
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 900));
  final then = scene.act;
  if (act && then != null) {
    await then(tester, state);
    await tester.pump(const Duration(milliseconds: 100));
  }
  return state;
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

DealerState _hostState(WidgetTester tester) =>
    tester.widget<DealerHost>(find.byType(DealerHost)).state;

Finder _private(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

List<Rect> _rects(WidgetTester tester, Finder finder) => [
  for (var i = 0; i < finder.evaluate().length; i++)
    if (tester.getSize(finder.at(i)).width > 0.5 &&
        tester.getSize(finder.at(i)).height > 0.5)
      tester.getRect(finder.at(i)),
];

bool _touches(Rect a, Rect b) {
  final o = a.intersect(b);
  return o.width > 0.5 && o.height > 0.5;
}

void main() {
  group('what she does, from what the table shows', () {
    test('a celebration outranks everything', () {
      for (final since in [null, Duration.zero, DealerTiming.newHand]) {
        expect(
          dealerStateFor(
            celebrating: true,
            myTurn: true,
            sinceNewHand: since,
            dealLength: const Duration(seconds: 3),
          ),
          DealerState.win,
        );
      }
    });

    test('a new hand nods, deals while the cards fly, then rests', () {
      final deal = DealFlights.total(15);
      DealerState at(Duration since, {bool myTurn = false}) => dealerStateFor(
        celebrating: false,
        myTurn: myTurn,
        sinceNewHand: since,
        dealLength: deal,
      );
      expect(at(Duration.zero), DealerState.newHand);
      expect(
        at(DealerTiming.newHand - const Duration(milliseconds: 1)),
        DealerState.newHand,
      );
      expect(at(DealerTiming.newHand), DealerState.dealing);
      expect(
        at(deal - const Duration(milliseconds: 1), myTurn: true),
        DealerState.dealing,
      );
      expect(at(deal), DealerState.idle);
      expect(at(deal, myTurn: true), DealerState.yourTurn);
    });

    test('a hand dealt to nobody in view nods and does not deal', () {
      expect(
        dealerStateFor(
          celebrating: false,
          myTurn: false,
          sinceNewHand: DealerTiming.newHand,
        ),
        DealerState.idle,
      );
    });

    test('otherwise the viewer\'s turn, or rest', () {
      expect(
        dealerStateFor(celebrating: false, myTurn: true),
        DealerState.yourTurn,
      );
      expect(
        dealerStateFor(celebrating: false, myTurn: false),
        DealerState.idle,
      );
      expect(
        dealerStateFor(
          celebrating: false,
          myTurn: false,
          sinceNewHand: const Duration(milliseconds: -5),
        ),
        DealerState.idle,
      );
    });

    testWidgets('on the table: idle, your turn and a win', (tester) async {
      for (final (prefix, want) in [
        ('01', DealerState.idle),
        ('03', DealerState.yourTurn),
        ('07', DealerState.win),
        ('06', DealerState.win),
      ]) {
        final state = await _mount(tester, _scene(prefix));
        expect(_hostState(tester), want, reason: prefix);
        await _unmount(tester, state);
      }
    });

    testWidgets('on the table: the next hand nods, deals, and rests when the '
        'flight\'s last card lands', (tester) async {
      final state = await _mount(tester, _scene('01'));
      expect(_hostState(tester), DealerState.idle);

      state.handleState(opponentTurnRoom(handNo: 8));
      await tester.pump();
      expect(_hostState(tester), DealerState.newHand);

      await tester.pump(DealerTiming.newHand);
      expect(_hostState(tester), DealerState.dealing);

      // Five players, three cards each: the flight's own arithmetic.
      final deal = DealFlights.total(DealFlights.cardsEach * 5);
      await tester.pump(deal - DealerTiming.newHand - Durations.short1);
      expect(_hostState(tester), DealerState.dealing);
      await tester.pump(Durations.short2);
      expect(_hostState(tester), DealerState.idle);

      await _unmount(tester, state);
    });

    testWidgets('the first hand at a fresh table and a change of table deal '
        'nothing', (tester) async {
      final state = await _mount(tester, _scene('09'));
      // The fresh table's first hand: the flight does not fly it, and she
      // only nods.
      state.handleState(opponentTurnRoom(handNo: 1));
      await tester.pump();
      expect(_hostState(tester), DealerState.newHand);
      await tester.pump(DealerTiming.newHand);
      expect(_hostState(tester), DealerState.idle);

      // Another table: nothing to open.
      state.handleState(opponentTurnRoom(handNo: 30, roomId: 'r2'));
      await tester.pump();
      expect(_hostState(tester), DealerState.idle);
      await _unmount(tester, state);
    });

    testWidgets('she steps out while a picker lies over the felt', (
      tester,
    ) async {
      final state = await _mount(tester, _scene('01'));
      state.handleState(variationSelectingRoom(mine: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(VariationPrompt), findsOneWidget);
      final fade = tester.widget<AnimatedOpacity>(
        find.ancestor(
          of: find.byType(DealerHost),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(fade.opacity, 0);
      await _unmount(tester, state);
    });
  });

  group('the artwork contract', () {
    testWidgets('once loaded, she is drawn in the first frame of a table', (
      tester,
    ) async {
      await tester.runAsync(() => DealerArt.load(DealerArt.defaultAsset));
      expect(DealerArt.loaded(DealerArt.defaultAsset), isNotNull);
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: SizedBox(
              width: 80,
              height: 100,
              child: DealerHost(state: DealerState.idle),
            ),
          ),
        ),
      );
      // One frame, no await in between: a table opened again shows her at
      // once rather than popping her in a moment later.
      expect(
        find.descendant(
          of: find.byType(DealerHost),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    test('the bundled host splits into her seven layers, in paint order', () {
      final art = parseDealerArt(
        File('assets/dealer/host.svg').readAsStringSync(),
      );
      expect(art.layers.map((l) => l.id), [
        DealerArt.hairBack,
        DealerArt.body,
        DealerArt.armRight,
        DealerArt.armLeft,
        DealerArt.head,
        DealerArt.eyes,
        DealerArt.card,
      ]);
      expect(art.viewBox, const Rect.fromLTWH(25, 12, 150, 228));
      expect(art.rimY, 200);
      // Every layer turns about a point of its own.
      for (final layer in art.layers) {
        expect(layer.pivot, isNotNull, reason: layer.id);
        // On the canvas, its edges included (her body turns about its foot).
        expect(
          art.viewBox.inflate(0.01).contains(layer.pivot!),
          isTrue,
          reason: layer.id,
        );
      }
      // The slot is shaped for her: her canvas above the rail.
      expect(
        art.visible.width / art.visible.height,
        closeTo(DealerArt.boxAspect, 0.01),
      );
      // Each layer is its own group alone, with the shared gradients.
      for (final layer in art.layers) {
        expect(layer.svg, contains('id="${layer.id}"'));
        expect(layer.svg, contains('<defs>'));
        for (final other in art.layers.where((o) => o.id != layer.id)) {
          expect(layer.svg, isNot(contains('id="${other.id}"')));
        }
      }
    });

    test('her art keeps to what flutter_svg draws, and never red felt', () {
      final svg = File('assets/dealer/host.svg').readAsStringSync();
      for (final unsupported in ['<filter', '<mask', 'feGaussianBlur']) {
        expect(svg, isNot(contains(unsupported)));
      }
    });

    test('a group inside a layer stays in it, and the rest ride the body', () {
      const svg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 120" data-rim-y="100">
  <defs><linearGradient id="g"><stop offset="0" stop-color="#000"/></linearGradient></defs>
  <g id="host-body" data-pivot="50 120"><rect width="10" height="10"/><g><g/></g></g>
  <g id="host-necklace"><circle r="2"/></g>
  <g id="host-head" data-pivot="50 40"><g id="host-inner"><circle r="3"/></g></g>
</svg>''';
      final art = parseDealerArt(svg);
      expect(art.layers.map((l) => l.id), [
        'host-body',
        'host-necklace',
        'host-head',
      ]);
      expect(art.layer('host-head')!.svg, contains('host-inner'));
      expect(art.layer('host-body')!.pivot, const Offset(50, 120));
      expect(art.layer('host-necklace')!.pivot, isNull);
      expect(art.rimY, 100);
    });

    test('a flat illustration is drawn whole, as her body', () {
      const svg =
          '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="100">'
          '<defs><linearGradient id="g"/></defs><circle r="5"/></svg>';
      final art = parseDealerArt(svg);
      expect(art.layers.single.id, DealerArt.body);
      expect(art.layers.single.svg, contains('<circle r="5"/>'));
      expect(art.viewBox, const Rect.fromLTWH(0, 0, 80, 100));
      // No rim said: the rail meets her at the default share.
      expect(art.rimY, closeTo(100 * DealerArt.defaultRimShare, 1e-9));
    });

    test('a file that is not a host says so', () {
      expect(() => parseDealerArt('<html></html>'), throwsFormatException);
      expect(
        () => parseDealerArt('<svg viewBox="0 0 0 10"></svg>'),
        throwsFormatException,
      );
      expect(
        () => parseDealerArt(
          '<svg viewBox="0 0 10 10"><g id="host-head"><g></svg>',
        ),
        throwsFormatException,
      );
    });
  });

  group('how far she moves', () {
    DealerPose at(DealerState s, double inState, {double clock = 1.2}) =>
        dealerPose(s, inState: inState, clock: clock);

    test('at rest she breathes and, now and then, blinks', () {
      final a = at(DealerState.idle, 1, clock: 1.05);
      final b = at(DealerState.idle, 1, clock: 3.15);
      expect((a.breath - b.breath).abs(), greaterThan(0.5));
      expect(at(DealerState.idle, 1, clock: 2).lid, 1);
      expect(at(DealerState.idle, 1, clock: 4.375).lid, lessThan(0.2));
    });

    test('the phone asking for less motion stills the loops', () {
      final p = dealerPose(
        DealerState.idle,
        inState: 1,
        clock: 4.375,
        still: true,
      );
      expect(p.breath, 0);
      expect(p.lid, 1);
    });

    test('each state moves the way it says', () {
      final deal = at(DealerState.dealing, 0.24);
      expect(deal.card, 1);
      expect(deal.armRight, lessThan(-0.05), reason: 'the right hand lifts');
      final turn = at(DealerState.yourTurn, 1);
      expect(turn.headTilt, lessThan(0), reason: 'towards the viewer');
      expect(turn.lookX, lessThan(0));
      expect(turn.haloTurn, greaterThan(0.5));
      final nod = at(DealerState.newHand, 0.22);
      expect(nod.headNod, greaterThan(1));
      final win = at(DealerState.win, 0.35);
      expect(win.lift, greaterThan(1.5));
      expect(win.sparkle, inInclusiveRange(0, 1));
      expect(at(DealerState.win, 2).sparkle, lessThan(0));
    });

    test(
      'never much: small turns and lifts, whatever the state and moment',
      () {
        for (final s in DealerState.values) {
          for (var t = 0.0; t < 8; t += 0.05) {
            final p = at(s, t, clock: t * 1.7);
            expect(p.headTilt.abs(), lessThanOrEqualTo(0.06), reason: '$s $t');
            expect(p.lift.abs(), lessThanOrEqualTo(3), reason: '$s $t');
            expect(p.headNod.abs(), lessThanOrEqualTo(2), reason: '$s $t');
            expect(p.armRight.abs(), lessThanOrEqualTo(0.15), reason: '$s $t');
            expect(p.armLeft.abs(), lessThanOrEqualTo(0.15), reason: '$s $t');
            expect(p.lookX.abs(), lessThanOrEqualTo(1), reason: '$s $t');
            expect(p.lid, inInclusiveRange(0.1, 1), reason: '$s $t');
          }
        }
      },
    );
  });

  group('her box', () {
    test('stands on the rail, centred, as tall as the gap allows', () {
      final box = dealerSlot(
        feltWidth: 800,
        top: 40,
        rimTop: 100,
        left: 300,
        right: 500,
        screenHeight: 412,
      )!;
      expect(box.bottom, 100);
      expect(box.center.dx, 400);
      expect(box.top, closeTo(40 + DealerSlot.margin, 1e-9));
      expect(box.width / box.height, closeTo(DealerArt.boxAspect, 1e-9));
    });

    test('narrows to the free span, and caps on a tall screen', () {
      final narrow = dealerSlot(
        feltWidth: 800,
        top: 20,
        rimTop: 200,
        left: 370,
        right: 430,
        screenHeight: 800,
      )!;
      expect(narrow.width, closeTo(60 - 2 * DealerSlot.margin, 1e-9));
      final tall = dealerSlot(
        feltWidth: 1200,
        top: 20,
        rimTop: 400,
        left: 300,
        right: 900,
        screenHeight: 800,
      )!;
      expect(tall.height, closeTo(800 * DealerSlot.maxShare, 1e-9));
    });

    test('is no box at all when she would be too small to read', () {
      expect(
        dealerSlot(
          feltWidth: 800,
          top: 60,
          rimTop: 90,
          left: 300,
          right: 500,
          screenHeight: 360,
        ),
        isNull,
      );
      expect(
        dealerSlot(
          feltWidth: 800,
          top: 0,
          rimTop: 200,
          left: 390,
          right: 410,
          screenHeight: 360,
        ),
        isNull,
      );
    });
  });

  group('never over the game', () {
    const sizes = [
      Size(640, 360),
      Size(732, 412),
      Size(844, 390),
      Size(891, 411),
      Size(915, 412),
    ];
    const scenes = ['01', '03', '05', '06', '08', '09', '17', '18', '19'];

    for (final size in sizes) {
      for (final scale in [1.0, 1.25]) {
        testWidgets(
          'at ${size.width.toInt()}x${size.height.toInt()}, text x$scale',
          (tester) async {
            for (final prefix in scenes) {
              final state = await _mount(
                tester,
                _scene(prefix),
                size: size,
                textScale: scale,
              );
              final why = '$prefix at $size x$scale';
              expect(tester.takeException(), isNull, reason: why);
              final host = find.byType(DealerHost);
              expect(host, findsOneWidget, reason: why);
              final box = tester.getRect(host);
              // Stepped out: drawn nowhere, so over nothing. The two-line
              // notices in the waiting line's slot are why she steps out.
              final shown =
                  tester
                      .widget<AnimatedOpacity>(
                        find.ancestor(
                          of: host,
                          matching: find.byType(AnimatedOpacity),
                        ),
                      )
                      .opacity >
                  0;
              expect(shown, prefix != '19' && prefix != '08', reason: why);

              // As tall as a phone this size can give her, never more than
              // her share of the screen, and on the screen.
              expect(box.height, greaterThanOrEqualTo(DealerSlot.minHeight));
              expect(
                box.height,
                lessThanOrEqualTo(size.height * DealerSlot.maxShare + 1e-6),
              );
              expect(
                (Offset.zero & size).contains(box.topLeft) &&
                    (Offset.zero & size).contains(box.bottomRight),
                isTrue,
                reason: why,
              );

              // Standing behind the table's far rail.
              final table = tester.widget<CasinoTableSurface>(
                find.byType(CasinoTableSurface),
              );
              final felt = tester.getRect(find.byType(CasinoTableSurface));
              expect(
                box.bottom,
                closeTo(felt.top + table.geometry.rimTop, 0.5),
                reason: why,
              );

              final game = <String, List<Rect>>{
                'seat': _rects(tester, find.byType(SeatPod)),
                'hand': _rects(tester, _private('_OwnHand')),
                'pot': _rects(tester, _private('_Pot')),
                'tag': _rects(
                  tester,
                  find.descendant(
                    of: _private('_CategoryTag'),
                    matching: find.byType(Plate),
                  ),
                ),
                'status': [
                  ..._rects(
                    tester,
                    find.descendant(
                      of: _private('_Status'),
                      matching: find.byType(Text),
                    ),
                  ),
                  ..._rects(tester, find.byType(VariationSelectingLine)),
                ],
                'bubble': _rects(tester, _private('_Bubble')),
                'prompt': _rects(
                  tester,
                  find.descendant(
                    of: _private('_SideshowPrompt'),
                    matching: find.byType(Plate),
                  ),
                ),
                'key': [
                  ..._rects(tester, find.byType(MachinedKey)),
                  ..._rects(tester, find.byType(StepperKey)),
                ],
              };
              expect(game['seat'], isNotEmpty, reason: why);
              if (prefix == '18') {
                expect(game['bubble'], hasLength(2), reason: why);
              }
              if (prefix == '09' || prefix == '19') {
                expect(game['status'], isNotEmpty, reason: why);
              }
              for (final MapEntry(key: what, value: rects) in game.entries) {
                if (!shown) break;
                for (final r in rects) {
                  expect(
                    _touches(box, r),
                    isFalse,
                    reason: '$why: the host at $box is over the $what at $r',
                  );
                }
              }
              await _unmount(tester, state);
            }
          },
        );
      }
    }

    testWidgets('a phone too short for her shows the table without her', (
      tester,
    ) async {
      final state = await _mount(
        tester,
        _scene('01'),
        size: const Size(568, 320),
        textScale: 1.25,
      );
      expect(find.byType(CasinoTableSurface), findsOneWidget);
      expect(find.byType(DealerHost), findsNothing);
      await _unmount(tester, state);
    });

    testWidgets('a tablet gives her more room, and no more than her share', (
      tester,
    ) async {
      final state = await _mount(
        tester,
        _scene('01'),
        size: const Size(1280, 800),
      );
      final box = tester.getRect(find.byType(DealerHost));
      expect(box.height, greaterThan(100));
      expect(box.height, lessThanOrEqualTo(800 * DealerSlot.maxShare));
      await _unmount(tester, state);
    });
  });
}
