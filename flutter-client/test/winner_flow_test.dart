// The end of a hand and the chips on the table (owner, 26 Sep 2026: "check
// winner animation and coin flow, make it smooth").
//
// What was wrong, each held here: every bet after the first at a table left
// its seat later than the one before (its clock restarted from nought while
// each chip was stamped with the last run's end); the celebration was built
// again from nothing when an overlay above it left the felt (a missile's
// volley, 80 ms after the reveal), so the fireworks and the pot restarted; the
// fireworks went up over the middle of the felt on the reveal and jumped to
// the winner, grown, when the result came a moment later, and were read and
// parsed from the bundle on the frame of the first win and then drawn at the
// file's 30 frames a second; the plinth counted to nought and the winner's
// stack jumped before a chip had moved; the ribbon struck over cards still
// turning, and its shine flipped the word from deep gold to bright every
// 2.2 s; and the pot's breathing glow re-laid-out and repainted the whole
// table screen every frame for as long as the table was open.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/missile_strike.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/missile_flight.dart';
import 'package:teenpatti/widgets/pot_flight.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'table_scenes.dart' show silentFeedback, tableApp;
import 'winner_scenes.dart';

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

Finder _pod(String userId) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId);

/// The felt's Stack, whose coordinates every place on it is given in: inside
/// the felt's padding.
Rect _stage(WidgetTester tester) => tester.getRect(
  find
      .descendant(of: _private('_Felt'), matching: find.byType(LayoutBuilder))
      .first,
);

final _figure = RegExp(r'^[0-9][0-9,.]*( Lakh| Crore)?$');

/// The figure on the pot's plinth.
String _pot(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(of: _private('_Pot'), matching: find.byType(Text)),
    )
    .map((t) => t.data ?? '')
    .firstWhere(_figure.hasMatch);

/// The stack on [userId]'s pod.
String _stack(WidgetTester tester, String userId) => tester
    .widgetList<Text>(
      find.descendant(of: _pod(userId), matching: find.byType(Text)),
    )
    .map((t) => t.data ?? '')
    .firstWhere(_figure.hasMatch);

/// How far the WINNER ribbon has faded in on [userId]'s pod, or null when
/// there is none.
double? _ribbon(WidgetTester tester, String userId) {
  final fade = find.descendant(
    of: find.descendant(of: _pod(userId), matching: _private('_WinnerFlash')),
    matching: find.byType(FadeTransition),
  );
  if (fade.evaluate().isEmpty) return null;
  return tester.widget<FadeTransition>(fade.first).opacity.value;
}

Future<GameState> _mount(
  WidgetTester tester, {
  Size size = const Size(891, 411),
  double scale = 1,
  AppLang lang = AppLang.english,
  bool dark = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = winnerState(lang: lang);
  await tester.pumpWidget(
    tableApp(
      state: state,
      feedback: feedback,
      theme: dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
    ),
  );
  await _frames(tester, 600);
  return state;
}

/// [ms] of frames, one every 16 ms, as a phone draws them.
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

/// The server's end of a show: the reveal, and a frame later the result and
/// the settled table.
Future<void> _showdown(
  WidgetTester tester,
  GameState state,
  String winner,
) async {
  state
    ..handleState(winnerShowPaid())
    ..handleShowdown(winnerReveal(winner));
  await tester.pump(const Duration(milliseconds: 16));
  state
    ..handleShowdown(winnerEnded(winner))
    ..handleState(winnerSettled(winner));
  await tester.pump(const Duration(milliseconds: 16));
}

Seat _seat(int i, {int contributed = 0, bool occupied = true}) =>
    Seat.fromJson({
      'seatIndex': i,
      'userId': occupied ? 'u$i' : null,
      'displayName': 'Player $i',
      'chips': 100000,
      'status': 'active',
      'isBlind': true,
      'lastBet': 200,
      'lastAction': 'chaal',
      'contributed': contributed,
      'connected': true,
      'cardCount': 3,
    });

Widget _bets(List<Seat> seats, {int handNo = 3, String roomId = 'r1'}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          Positioned.fill(
            child: BetFlights(
              seats: seats,
              roomId: roomId,
              handNo: handNo,
              centreOf: (i) => Offset(60.0 + 120 * i, 300),
              pot: const Offset(400, 120),
              size: 20,
            ),
          ),
        ],
      ),
    );

List<({Offset centre, double alpha, double scale})> _chips(
  WidgetTester tester,
) => tester.state<BetFlightsState>(find.byType(BetFlights)).chipsInFlight;

/// Whether [boundary]'s picture was recorded again since [before].
List<Layer> _layers(RenderRepaintBoundary boundary) {
  final out = <Layer>[];
  var child = boundary.debugLayer?.firstChild;
  while (child != null) {
    out.add(child);
    child = child.nextSibling;
  }
  return out;
}

bool _same(List<Layer> a, List<Layer> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) identical(a[i], b[i])].every((x) => x);

void main() {
  setUpAll(() async {
    // Where async is real: a future first awaited inside one test's fake
    // clock never completes in the next (CLAUDE.md §12.3).
    await FireworksArt.load();
    await MissileArt.load();
  });

  group('a bet crossing to the pot', () {
    testWidgets('leaves its seat on the frame of the bet, the tenth bet at a '
        'table as the first', (tester) async {
      var put = 200;
      final seats = [for (var i = 0; i < 4; i++) _seat(i, contributed: 200)];
      await tester.pumpWidget(_bets(seats));
      for (var bet = 0; bet < 10; bet++) {
        put += 400;
        seats[1] = _seat(1, contributed: put);
        await tester.pumpWidget(_bets(List.of(seats)));
        // Born at the seat, and rising in rather than popping.
        expect(_chips(tester), hasLength(1), reason: 'bet $bet');
        expect(_chips(tester).single.alpha, lessThan(0.05));
        await tester.pump(const Duration(milliseconds: 16));
        final chip = _chips(tester).single;
        expect(chip.alpha, greaterThan(0.1), reason: 'bet $bet');
        expect(
          (chip.centre - const Offset(180, 300)).distance,
          lessThan(12),
          reason: 'bet $bet: it has only just left the seat',
        );
        // It lands within its trip, whatever came before it.
        await tester.pump(BetFlights.travel);
        expect(_chips(tester), isEmpty, reason: 'bet $bet');
        await tester.pump(const Duration(seconds: 2));
      }
    });

    testWidgets("every seat's boot sets off at the deal, a stagger apart, and "
        'a switch to another table flies nothing', (tester) async {
      final seats = [for (var i = 0; i < 5; i++) _seat(i, contributed: 1200)];
      await tester.pumpWidget(_bets(seats));
      // Something flew earlier in the sitting.
      seats[2] = _seat(2, contributed: 1600);
      await tester.pumpWidget(_bets(List.of(seats)));
      await tester.pump(const Duration(seconds: 3));

      final dealt = [for (var i = 0; i < 5; i++) _seat(i, contributed: 200)];
      await tester.pumpWidget(_bets(dealt, handNo: 4));
      final launched = <int>[];
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        launched.add(_chips(tester).where((c) => c.alpha > 0.05).length);
      }
      expect(launched.first, greaterThanOrEqualTo(1));
      // All five are in the air by the fifth stagger, and none waits longer.
      final allAt = launched.indexWhere((n) => n == 5);
      expect(allAt, isNonNegative);
      expect(
        allAt * 16,
        lessThanOrEqualTo(BetFlights.stagger.inMilliseconds * 4 + 32),
      );
      await tester.pump(const Duration(seconds: 2));

      // Another table, its bets made before the player got there.
      final elsewhere = [
        for (var i = 0; i < 5; i++) _seat(i, contributed: 9000),
      ];
      await tester.pumpWidget(_bets(elsewhere, roomId: 'r2', handNo: 9));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_chips(tester), isEmpty);
    });

    test('rises in at the seat and settles into the pile without a jump', () {
      final path = [
        for (var ms = 0; ms <= 640; ms += 4)
          ?betChipAt(Duration(milliseconds: ms)),
      ];
      expect(path.first.alpha, lessThan(0.05), reason: 'no pop at the seat');
      expect(path.first.along, lessThan(0.01));
      expect(path.last.alpha, lessThan(0.1), reason: 'no pop on the pile');
      expect(path.last.along, greaterThan(0.99));
      for (var k = 1; k < path.length; k++) {
        expect((path[k].alpha - path[k - 1].alpha).abs(), lessThan(0.15));
        expect((path[k].along - path[k - 1].along).abs(), lessThan(0.03));
      }
    });

    testWidgets('the pot flares when the chip comes down on its pile, not when '
        'the bet is made', (tester) async {
      final state = await _mount(tester);
      Matrix4 swell() => tester
          .widget<Transform>(
            find
                .descendant(
                  of: _private('_PotPulse'),
                  matching: find.byType(Transform),
                )
                .first,
          )
          .transform;
      expect(swell().getMaxScaleOnAxis(), 1);

      state.handleState(winnerShowPaid());
      await tester.pump(const Duration(milliseconds: 16));
      await _frames(tester, BetFlights.landsAt.inMilliseconds - 64);
      expect(swell().getMaxScaleOnAxis(), 1, reason: 'the chip is in the air');
      await _frames(tester, 160);
      expect(swell().getMaxScaleOnAxis(), greaterThan(1.01));
      await _unmount(tester, state);
    });
  });

  group('the celebration', () {
    testWidgets('waits for the winner, and goes up over them from its first '
        'frame', (tester) async {
      final state = await _mount(tester);
      state
        ..handleState(winnerShowPaid())
        ..handleShowdown(winnerReveal('u0'));
      await _frames(tester, 200);
      // The cards are turning; nobody has been named.
      expect(_private('_WinnerBurst'), findsNothing);
      expect(find.byType(PotFlight), findsNothing);

      state
        ..handleShowdown(winnerEnded('u0'))
        ..handleState(winnerSettled('u0'));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final burst = tester.widget(_private('_WinnerBurst')) as dynamic;
      final focus = burst.focus as Offset;
      expect(burst.big, isTrue, reason: 'the viewer won');
      final felt = _stage(tester);
      final pod = tester.getRect(_pod('u0'));
      expect(
        felt.topLeft + Offset(focus.dx * felt.width, focus.dy * felt.height),
        isA<Offset>().having(
          (at) => pod.inflate(24).contains(at),
          'over the winner',
          isTrue,
        ),
      );
      await _frames(tester, 1500);
      final later = tester.widget(_private('_WinnerBurst')) as dynamic;
      expect(later.focus, focus, reason: 'it never moves');
      await _unmount(tester, state);
    });

    testWidgets('the fireworks are parsed when the table opens, and drawn at '
        "the screen's rate", (tester) async {
      final state = await _mount(tester);
      expect(FireworksArt.composition, isNotNull);
      await _showdown(tester, state, 'u3');
      await _frames(tester, 480);

      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find
            .descendant(
              of: _private('_WinnerBurst'),
              matching: find.byType(RepaintBoundary),
            )
            .first,
      );
      final shots = <List<int>>[];
      for (var frame = 0; frame < 6; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 0.5);
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          shots.add(bytes!.buffer.asUint8List().toList());
        });
      }
      // At the file's own 30 frames a second, two frames of the screen's in
      // a row showed the same picture.
      for (var i = 1; i < shots.length; i++) {
        expect(listEquals(shots[i], shots[i - 1]), isFalse, reason: 'frame $i');
      }
      await _unmount(tester, state);
    });

    testWidgets('the ribbon strikes once the hands have turned over, with the '
        'pot setting off', (tester) async {
      final state = await _mount(tester);
      await _showdown(tester, state, 'u3');
      final turn = WinnerTiming.turnOf(3).inMilliseconds;
      await _frames(tester, turn - 120);
      expect(_ribbon(tester, 'u3'), 0, reason: 'the cards are still turning');
      expect(_pot(tester), formatChips(winnerPot), reason: 'still on the pile');
      await _frames(tester, 300);
      expect(_ribbon(tester, 'u3'), greaterThan(0.3));
      expect(
        _pot(tester),
        isNot(formatChips(winnerPot)),
        reason: 'the chips have set off',
      );
      await _unmount(tester, state);
    });

    testWidgets('with nothing to turn over (everyone else packed) it all lands '
        'at once', (tester) async {
      final state = await _mount(tester);
      state
        ..handleShowdown(winnerEnded('u0', revealed: false))
        ..handleState(winnerSettled('u0', revealed: false));
      await _frames(tester, 200);
      expect(_ribbon(tester, 'u0'), greaterThan(0.3));
      expect(find.byType(PotFlight), findsOneWidget);
      await _unmount(tester, state);
    });

    testWidgets("the plinth's figure falls as the chips leave the pile and the "
        "winner's stack rises as they land on it", (tester) async {
      final state = await _mount(tester);
      await _showdown(tester, state, 'u0');
      final settled = winnerStacks[0] - winnerShowCost + winnerPot;
      final before = formatChips(settled - winnerPot);

      int number(String figure) =>
          int.parse(figure.replaceAll(RegExp(r'[^0-9]'), ''));
      final pots = <int>[];
      final stacks = <String>[];
      for (var at = 0; at < 2400; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        pots.add(number(_pot(tester)));
        stacks.add(_stack(tester, 'u0'));
      }

      // The pot: whole until the result, then only down, to nought.
      final result = WinnerTiming.turnOf(3).inMilliseconds;
      expect(pots.take((result - 40) ~/ 16), everyElement(winnerPot));
      for (var i = 1; i < pots.length; i++) {
        expect(pots[i], lessThanOrEqualTo(pots[i - 1]), reason: 'frame $i');
      }
      final emptied = pots.indexOf(0) * 16;
      expect(emptied, greaterThan(result));
      expect(emptied, lessThan(result + 800), reason: 'as the chips leave');

      // The stack: what it was until the first chip lands, then up to what
      // the table settled.
      final firstLands =
          result +
          (PotFlight.flight.inMilliseconds * (1 - PotFlight.landing)).round();
      expect(stacks.take((firstLands - 40) ~/ 16), everyElement(before));
      expect(stacks.last, formatChips(settled));
      final rose = stacks.indexOf(formatChips(settled)) * 16;
      expect(rose, greaterThan(firstLands));
      expect(
        rose,
        lessThanOrEqualTo(result + PotFlight.total.inMilliseconds + 64),
      );
      await _unmount(tester, state);
    });

    testWidgets('the chips land on the winner\'s stack and leave from the '
        'pile', (tester) async {
      final state = await _mount(tester);
      await _showdown(tester, state, 'u3');
      await _frames(tester, 200);
      final flight = tester.widget<PotFlight>(find.byType(PotFlight));
      final felt = _stage(tester);
      final stack = tester.getRect(
        find
            .descendant(
              of: _pod('u3'),
              matching: find.text(formatChips(530000)),
            )
            .first,
      );
      final pile = tester.getRect(_private('_PotChips'));
      expect(
        stack.inflate(2).contains(felt.topLeft + flight.to),
        isTrue,
        reason: 'on the stack the chips are counted into',
      );
      expect(pile.inflate(2).contains(felt.topLeft + flight.from), isTrue);
      await _unmount(tester, state);
    });

    testWidgets('is not built again when an overlay above it leaves the felt '
        '(a missile volley ending)', (tester) async {
      final state = await _mount(tester);
      state.handleTableAction((
        userId: 'u0',
        action: GameAction.missile,
        reason: null,
      ));
      state
        ..handleShowdown(winnerReveal('u0'))
        ..handleShowdown(winnerEnded('u0'))
        ..handleState(winnerSettled('u0'));
      await _frames(tester, MissileTiming.reveal(1).inMilliseconds + 48);
      expect(state.missileStrike, isNotNull);
      final burst = tester.state(_private('_WinnerBurst'));
      final flight = tester.state(find.byType(PotFlight));
      final strike = tester.widget<PotFlight>(find.byType(PotFlight)).progress!;
      final before = strike.value;

      await _frames(tester, 200);
      expect(state.missileStrike, isNull, reason: 'the volley has gone');
      expect(identical(tester.state(_private('_WinnerBurst')), burst), isTrue);
      expect(identical(tester.state(find.byType(PotFlight)), flight), isTrue);
      expect(
        tester.widget<PotFlight>(find.byType(PotFlight)).progress!.value,
        greaterThanOrEqualTo(before),
      );
      await _unmount(tester, state);
    });
  });

  group('the ribbon', () {
    testWidgets("WINNER's shine crosses the word and comes back without a "
        'jump', (tester) async {
      // The shader itself, painted over a word-shaped box and read back.
      const box = Size(160, 32);
      Future<List<int>> painted(double t) async {
        late List<int> pixels;
        await tester.runAsync(() async {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawRect(
            Offset.zero & box,
            Paint()..shader = winnerShine(t).createShader(Offset.zero & box),
          );
          final picture = recorder.endRecording();
          final image = await picture.toImage(160, 32);
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          picture.dispose();
          pixels = bytes!.buffer.asUint8List().toList();
        });
        return pixels;
      }

      int far(List<int> a, List<int> b) {
        var most = 0;
        for (var i = 0; i < a.length; i++) {
          final d = (a[i] - b[i]).abs();
          if (d > most) most = d;
        }
        return most;
      }

      int channel(double c) => (c * 255).round();
      bool all(List<int> pixels, Color colour) {
        for (var i = 0; i < pixels.length; i += 4) {
          if ((pixels[i] - channel(colour.r)).abs() > 2 ||
              (pixels[i + 1] - channel(colour.g)).abs() > 2 ||
              (pixels[i + 2] - channel(colour.b)).abs() > 2) {
            return false;
          }
        }
        return true;
      }

      // A frame of the shine's 2.2 s is 0.0073 of it: stepping twice that,
      // no pixel of the word moves by more than a sixth of its range —
      // where it used to flip wholesale, deep to bright, once a loop, and
      // flick its first letters as the band came on.
      var last = await painted(0);
      for (var t = 0.015; t <= 1.0001; t += 0.015) {
        final now = await painted(t);
        expect(far(last, now), lessThan(44), reason: 't=$t');
        last = now;
      }
      // Off the word at both ends — all bright, then all deep — so turning
      // back at either end shows nothing.
      expect(all(await painted(0), AppTheme.goldBright), isTrue);
      expect(all(await painted(1), AppTheme.goldDeep), isTrue);
    });

    testWidgets('its shine turns back at the end of a crossing rather than '
        'flipping the word', (tester) async {
      final state = await _mount(tester);
      await _showdown(tester, state, 'u0');
      final word = tester.renderObject<RenderRepaintBoundary>(
        find
            .descendant(
              of: _private('_WinnerFlash'),
              matching: find.byType(RepaintBoundary),
            )
            .first,
      );
      Future<List<int>> shot() async {
        late List<int> pixels;
        await tester.runAsync(() async {
          final image = await word.toImage();
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          pixels = bytes!.buffer.asUint8List().toList();
        });
        return pixels;
      }

      // Across the end of the first crossing, 2.2 s after the ribbon came.
      await _frames(tester, 2100);
      var last = await shot();
      for (var frame = 0; frame < 14; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final now = await shot();
        var most = 0;
        for (var i = 0; i < now.length; i++) {
          final d = (now[i] - last[i]).abs();
          if (d > most) most = d;
        }
        expect(most, lessThan(48), reason: 'frame $frame');
        last = now;
      }
      await _unmount(tester, state);
    });

    testWidgets('is laid out once and only its shine repaints', (tester) async {
      final state = await _mount(tester);
      await _showdown(tester, state, 'u0');
      await _frames(tester, 3000);
      final rebuilt = <String>[];
      debugOnRebuildDirtyWidget = (element, _) {
        final chain = <String>[];
        element.visitAncestorElements((a) {
          chain.add(a.widget.runtimeType.toString());
          return true;
        });
        if (chain.contains('_WinnerFlash')) {
          rebuilt.add(element.widget.runtimeType.toString());
        }
      };
      await _frames(tester, 400);
      debugOnRebuildDirtyWidget = null;
      expect(rebuilt, isEmpty);
      await _unmount(tester, state);
    });
  });

  group('what the table repaints', () {
    // The felt's own layer: the boundary it stands in, which it fills.
    RenderRepaintBoundary feltLayer(WidgetTester tester) {
      final boundary = find
          .ancestor(
            of: _private('_Felt'),
            matching: find.byType(RepaintBoundary),
          )
          .first;
      expect(tester.getRect(_private('_Felt')), tester.getRect(boundary));
      return tester.renderObject<RenderRepaintBoundary>(boundary);
    }

    RenderRepaintBoundary screenLayer(WidgetTester tester) {
      RenderObject? up = feltLayer(tester).parent;
      while (up != null && !up.isRepaintBoundary) {
        up = up.parent;
      }
      return up! as RenderRepaintBoundary;
    }

    Future<int> recorded(WidgetTester tester, RenderRepaintBoundary b) async {
      var count = 0;
      var last = _layers(b);
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final now = _layers(b);
        if (!_same(last, now)) count++;
        last = now;
      }
      return count;
    }

    testWidgets('the pot breathing between hands repaints its glow, not the '
        'felt or the screen', (tester) async {
      final state = await _mount(tester);
      state.handleState(winnerRoom(state: 'waiting', turn: null));
      await _frames(tester, 1000);
      expect(await recorded(tester, feltLayer(tester)), 0);
      expect(await recorded(tester, screenLayer(tester)), 0);
      await _unmount(tester, state);
    });

    testWidgets('once the pot has landed, the celebration left up repaints '
        'neither the felt nor the screen', (tester) async {
      final state = await _mount(tester);
      await _showdown(tester, state, 'u0');
      await _frames(tester, 3000);
      expect(await recorded(tester, feltLayer(tester)), 0);
      expect(await recorded(tester, screenLayer(tester)), 0);
      await _unmount(tester, state);
    });
  });

  group('at 640x360, text x1.25', () {
    for (final lang in AppLang.values) {
      for (final winner in ['u0', 'u3']) {
        testWidgets('${lang.code}: $winner wins with nothing cut or thrown', (
          tester,
        ) async {
          final state = await _mount(
            tester,
            size: const Size(640, 360),
            scale: 1.25,
            lang: lang,
          );
          await _showdown(tester, state, winner);
          for (var at = 0; at < 2600; at += 200) {
            await _frames(tester, 200);
            expect(tester.takeException(), isNull, reason: 't=$at');
          }
          // The ribbon lies on the winner's pod, the chips' figures read.
          final pod = tester.getRect(_pod(winner));
          final ribbon = tester.getRect(
            find.descendant(
              of: _pod(winner),
              matching: _private('_WinnerFlash'),
            ),
          );
          expect(pod.inflate(1).contains(ribbon.topLeft), isTrue);
          expect(pod.inflate(1).contains(ribbon.bottomRight), isTrue);
          expect(_ribbon(tester, winner), 1);
          expect(_pot(tester), '0');
          await _unmount(tester, state);
        });
      }
    }
  });
}
