// The countdown before a deal (owner, 29 Sep 2026: "whenever Game starts in
// any game table, instead of showing text "Starting game .." show this count
// Down animation 3,2,1 … when countdown finishes then distribute card").
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/start_countdown.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/deal_flight.dart';
import 'package:teenpatti/widgets/missed_turns_notice.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/start_countdown.dart';
import 'package:teenpatti/widgets/table_chrome.dart';
import 'package:teenpatti/widgets/table_tax.dart';

import 'script_fonts.dart';
import 'start_countdown_fixture.dart';
import 'table_scenes.dart';

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// The table mounted on [room], the phone's clock at [countdownNow].
Future<GameState> _mount(
  WidgetTester tester,
  RoomState room, {
  bool dark = true,
  AppLang lang = AppLang.english,
  Size size = const Size(640, 360),
  double scale = 1.0,
  int maxPlayers = 5,
  GlobalKey? boundary,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = sceneState(
    TableScene('countdown', (s) {
      s.user = countdownViewer();
      s.config = s.config.copyWith(maxPlayers: maxPlayers);
      s.handleState(room);
    }),
    lang: lang,
  );
  final base = dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  final app = tableApp(
    state: state,
    feedback: feedback,
    theme: lang == AppLang.english ? base : withScriptFallback(base),
  );
  await tester.pumpWidget(
    boundary == null ? app : RepaintBoundary(key: boundary, child: app),
  );
  await tester.pump();
  return state;
}

/// The phone's clock and the frames moved on together by [ms].
Future<void> _walk(WidgetTester tester, int ms) async {
  var left = ms;
  while (left > 0) {
    final step = math.min(16, left);
    countdownNow += step;
    left -= step;
    await tester.pump(Duration(milliseconds: step));
  }
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

Finder _saying(int n, [AppLang lang = AppLang.english]) =>
    find.bySemanticsLabel(Strings(lang).startingIn(n));

Finder get _anyNumber => find.bySemanticsLabel(RegExp(r'^Starting in \d$'));

/// How opaque the countdown is drawn.
double _opacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find.descendant(
        of: find.byType(StartCountdownLayer),
        matching: find.byType(FadeTransition),
      ),
    )
    .opacity
    .value;

/// The deal's flying cards, while they fly.
Finder get _dealFlying => find.descendant(
  of: find.byType(DealFlights),
  matching: find.byType(CustomPaint),
);

/// The disc at the top of its pulse, in the screen's coordinates.
Rect _disc(WidgetTester tester) {
  final layer = tester.widget<StartCountdownLayer>(
    find.byType(StartCountdownLayer),
  );
  final origin = tester.getTopLeft(find.byType(StartCountdownLayer));
  return Rect.fromCircle(
    center: origin + layer.anchor,
    radius: layer.discSize / 2,
  );
}

void main() {
  late void Function() restoreClock;
  setUpAll(loadCountdownArt);
  setUp(() => restoreClock = holdCountdownClock());
  tearDown(() => restoreClock());

  group('the countdown as the phone keeps it', () {
    test('it is anchored to when the snapshot arrived, not to the phone '
        'clock', () {
      // The server's startsAt is an hour off this phone's clock: only the
      // time left counts.
      final room = countingDownRoom(
        leftMs: 2400,
        startsAt: countdownNow + 3600000,
      );
      final countdown = StartCountdown.follow(
        null,
        room,
        receivedAtMs: countdownNow,
      )!;
      expect(countdown.dealAt, countdownNow + 2400);
      expect(countdown.leftMs(countdownNow + 400), 2000);
      expect(countdown.showingAt(countdownNow), isTrue);
    });

    test('a later snapshot of the same deal never restarts it: the earlier '
        'estimate is kept', () {
      final first = StartCountdown.follow(
        null,
        countingDownRoom(leftMs: 2000, startsAt: 77),
        receivedAtMs: 1000,
      )!;
      // Arrived slower: the deal it names is later on this phone's clock.
      final slower = StartCountdown.follow(
        first,
        countingDownRoom(leftMs: 1500, startsAt: 77),
        receivedAtMs: 1600,
      );
      expect(identical(slower, first), isTrue);
      // Arrived faster: a truer estimate, a few frames sooner.
      final faster = StartCountdown.follow(
        first,
        countingDownRoom(leftMs: 1500, startsAt: 77),
        receivedAtMs: 1450,
      )!;
      expect(faster.dealAt, 2950);
      // Another deal (cancelled and started again, or a hold): a new one.
      final another = StartCountdown.follow(
        faster,
        countingDownRoom(leftMs: 3000, startsAt: 99),
        receivedAtMs: 1450,
      )!;
      expect(another.startsAt, 99);
      expect(another.dealAt, 4450);
    });

    test('no countdown outside starting, and a server from before counts on '
        'the phone clock', () {
      expect(
        StartCountdown.follow(
          null,
          countingDownRoom(leftMs: 0, state: 'waiting'),
          receivedAtMs: 0,
        ),
        isNull,
      );
      expect(StartCountdown.follow(null, dealtRoom(), receivedAtMs: 0), isNull);
      final old = StartCountdown.follow(
        null,
        countingDownRoom(leftMs: 2000, startsAt: 123456, withStartsIn: false),
        receivedAtMs: 1,
      )!;
      expect(old.dealAt, 123456);
    });

    test('time left names the number and the frame', () {
      expect(StartCountdown.numberFor(3000), 3);
      expect(StartCountdown.numberFor(2001), 3);
      expect(StartCountdown.numberFor(2000), 2);
      expect(StartCountdown.numberFor(1500), 2);
      expect(StartCountdown.numberFor(1000), 1);
      expect(StartCountdown.numberFor(1), 1);
      expect(StartCountdown.progressFor(3000), 0);
      expect(StartCountdown.progressFor(1500), 0.5);
      expect(StartCountdown.progressFor(0), 1);
      expect(StartCountdown.progressFor(-200), 1);
      expect(StartCountdown.progressFor(9000), 0);
    });

    test('the wire: startsInMs read when present, nothing when absent or '
        'nonsense', () {
      expect(countingDownRoom(leftMs: 2345).startsInMs, 2345);
      expect(
        countingDownRoom(leftMs: 2345, withStartsIn: false).startsInMs,
        isNull,
      );
      final json = {
        'roomId': 'r',
        'state': 'starting',
        'startsAt': 5,
        'startsInMs': -4,
        'seats': <Object>[],
      };
      expect(RoomState.fromJson(json).startsInMs, isNull);
      expect(
        RoomState.fromJson({...json, 'startsInMs': 'x'}).startsInMs,
        isNull,
      );
    });
  });

  group("the owner's file, cut to its 3-2-1", () {
    test('only the layers of 3, 2 and 1, over frames 180 to 270', () {
      final bytes = File(StartCountdownArt.asset).readAsBytesSync();
      final cut = StartCountdownArt.threeTwoOne(bytes);
      expect(cut.length, lessThan(bytes.length ~/ 3));
      final composition = LottieComposition.parseJsonBytes(cut);
      expect(composition.startFrame, 180);
      expect(composition.endFrame, closeTo(270, 0.02));
      expect(composition.duration.inMilliseconds, closeTo(3003, 5));
      final names = {for (final layer in composition.layers) layer.name};
      expect(names, containsAll(['3', '2', '1']));
      expect(names.difference({'3', '2', '1', 'c', 's'}), isEmpty);
      for (final layer in composition.layers) {
        expect(layer.startFrame, inInclusiveRange(180, 268));
      }
    });

    test('a file with no 3-2-1 is refused rather than played as another '
        'countdown', () {
      final bytes = Uint8List.fromList(
        '{"v":"5","ip":0,"op":10,"w":1,"h":1,"layers":[{"nm":"x","ip":0}]}'
            .codeUnits,
      );
      expect(() => StartCountdownArt.threeTwoOne(bytes), throwsFormatException);
    });

    test('each number stands at its fullest half a second into its '
        'second', () {
      expect(StartCountdownArt.peakOf(3), closeTo((194 - 180) / 90, 0.02));
      expect(StartCountdownArt.peakOf(2), closeTo((225 - 180) / 90, 0.02));
      expect(StartCountdownArt.peakOf(1), closeTo((254 - 180) / 90, 0.02));
    });
  });

  group('its colours, measured', () {
    final themes = {
      'day': AppTheme.light(sound: false),
      'night': AppTheme.dark(sound: false),
    };

    test('the day disc is the theme gold a step deeper', () {
      expect(
        StartCountdownColours.dayDisc.toARGB32(),
        Color.lerp(AppTheme.goldDeep, AppTheme.ink900, 0.15)!.toARGB32(),
      );
    });

    for (final MapEntry(key: name, value: theme) in themes.entries) {
      test('$name: the digit reads on its disc, and the disc on every cloth, '
          'the rail and the room', () {
        final colours = theme.brightness == Brightness.dark
            ? StartCountdownColours.night
            : StartCountdownColours.day;
        expect(
          StartCountdownColours.at(theme.extension<GlassColors>()!.dayShare),
          colours,
        );
        expect(_contrast(colours.digit, colours.disc), greaterThan(6));
        final table = theme.extension<CasinoTableColors>()!;
        final glass = theme.extension<GlassColors>()!;
        // Seen, blind, variation, the fallback teal; a private table lays
        // its game's cloth.
        for (final game in ['seen', 'blind', 'variation', 'teen_patti']) {
          final cloth = table.clothFor(game);
          for (final ground in [cloth.centre, cloth.edge]) {
            expect(
              _contrast(colours.disc, ground),
              greaterThanOrEqualTo(3.4),
              reason: '$name $game',
            );
          }
        }
        for (final ground in [table.railTop, table.railBottom, glass.ground]) {
          expect(_contrast(colours.disc, ground), greaterThanOrEqualTo(3.4));
        }
      });
    }

    test('a theme change cross-fades them', () {
      final half = StartCountdownColours.at(0.5);
      expect(
        half.disc,
        Color.lerp(
          StartCountdownColours.night.disc,
          StartCountdownColours.day.disc,
          0.5,
        ),
      );
    });

    for (final dark in [true, false]) {
      testWidgets('${dark ? 'night' : 'day'}: the disc on the table is '
          "drawn in the theme's gold, not the file's blue", (tester) async {
        final key = GlobalKey();
        final state = await _mount(
          tester,
          countingDownRoom(leftMs: 2530),
          dark: dark,
          boundary: key,
        );
        await _walk(tester, 0);
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(_opacity(tester), 1);
        final disc = _disc(tester);
        final origin = tester.getTopLeft(find.byType(StartCountdownLayer));
        final pixel = await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final at = disc.center - Offset(disc.width * 0.34, 0);
          final i = (at.dy.round() * image.width + at.dx.round()) * 4;
          image.dispose();
          return Color.fromARGB(
            255,
            data.getUint8(i),
            data.getUint8(i + 1),
            data.getUint8(i + 2),
          );
        });
        final want = dark
            ? StartCountdownColours.night.disc
            : StartCountdownColours.day.disc;
        expect(origin, isNotNull);
        expect((pixel!.r - want.r).abs(), lessThan(0.03));
        expect((pixel.g - want.g).abs(), lessThan(0.03));
        expect((pixel.b - want.b).abs(), lessThan(0.03));
        await _unmount(tester, state);
      });
    }
  });

  group('on the table', () {
    testWidgets('the numbers stand where "Starting game…" stood, and the '
        'words are gone', (tester) async {
      final semantics = tester.ensureSemantics();
      final state = await _mount(tester, countingDownRoom(leftMs: 2530));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_saying(3), findsOneWidget);
      expect(find.text(state.t.startingGame), findsNothing);
      expect(_opacity(tester), 1);
      await _walk(tester, 1000);
      expect(_saying(2), findsOneWidget);
      await _walk(tester, 1000);
      expect(_saying(1), findsOneWidget);
      semantics.dispose();
      await _unmount(tester, state);
    });

    testWidgets('after a hand the celebration has the table first: nothing '
        'until the last three seconds, then 3 on the dot', (tester) async {
      final semantics = tester.ensureSemantics();
      final state = await _mount(tester, countingDownRoom(leftMs: 6000));
      await _walk(tester, 100);
      expect(_anyNumber, findsNothing);
      expect(find.text(state.t.startingGame), findsNothing);
      expect(state.countdownShowing, isFalse);
      await _walk(tester, 2880);
      expect(_anyNumber, findsNothing);
      await _walk(tester, 40);
      expect(state.countdownShowing, isTrue);
      expect(_saying(3), findsOneWidget);
      semantics.dispose();
      await _unmount(tester, state);
    });

    testWidgets('joined mid-countdown (a reconnect) it shows the number the '
        'time left names, never 3', (tester) async {
      final semantics = tester.ensureSemantics();
      for (final (left, number) in [(1500, 2), (500, 1)]) {
        final state = await _mount(tester, countingDownRoom(leftMs: left));
        await tester.pump(const Duration(milliseconds: 50));
        expect(_saying(number), findsOneWidget, reason: '$left ms left');
        expect(_saying(3), findsNothing);
        await _unmount(tester, state);
      }
      semantics.dispose();
    });

    testWidgets('snapshots of the same deal and the one-second notify never '
        'restart it', (tester) async {
      final semantics = tester.ensureSemantics();
      final startsAt = countdownNow + 999999;
      final state = await _mount(
        tester,
        countingDownRoom(leftMs: 1800, startsAt: startsAt),
      );
      await _walk(tester, 100);
      expect(_saying(2), findsOneWidget);
      final held = state.startCountdown;
      // A player sits down; the snapshot, slower on the wire, says a little
      // more is left than the phone already knows.
      state.handleState(countingDownRoom(leftMs: 1900, startsAt: startsAt));
      for (var i = 0; i < 3; i++) {
        state.notifyListeners();
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(state.startCountdown, held);
      expect(_saying(2), findsOneWidget);
      // 1700 ms were left: 1 comes 700 ms on, as the first snapshot said.
      await _walk(tester, 690);
      expect(_saying(2), findsOneWidget);
      await _walk(tester, 30);
      expect(_saying(1), findsOneWidget);
      semantics.dispose();
      await _unmount(tester, state);
    });

    testWidgets('it ends at the deal: no card flies before it, the cards fly '
        'as it goes, and nothing can be played before', (tester) async {
      final semantics = tester.ensureSemantics();
      final state = await _mount(tester, countingDownRoom(leftMs: 900));
      await _walk(tester, 400);
      expect(_saying(1), findsOneWidget);
      expect(_dealFlying, findsNothing);
      // No move is offered before the deal: there is no hand.
      expect(state.myTurn, isFalse);
      expect(state.room!.you!.options, isNull);
      // The last of "1" has gone; the countdown leaves as the deal arrives.
      await _walk(tester, 400);
      expect(_dealFlying, findsNothing);
      await _walk(tester, 100);
      state.handleState(dealtRoom());
      await tester.pump();
      expect(state.startCountdown, isNull);
      await tester.pump(const Duration(milliseconds: 100));
      expect(_dealFlying, findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_opacity(tester), 0);
      expect(_anyNumber, findsNothing);
      semantics.dispose();
      await _unmount(tester, state);
    });

    testWidgets('a deal that comes a moment early cuts it short and the cards '
        'fly', (tester) async {
      final state = await _mount(tester, countingDownRoom(leftMs: 1500));
      await _walk(tester, 200);
      expect(_opacity(tester), 1);
      state.handleState(dealtRoom());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_dealFlying, findsOneWidget);
      await tester.pump(StartCountdownLayer.fadeOut);
      expect(_opacity(tester), 0);
      await _unmount(tester, state);
    });

    testWidgets('cancelled (a player left) it goes at once and the waiting '
        'line comes back', (tester) async {
      final semantics = tester.ensureSemantics();
      final state = await _mount(tester, countingDownRoom(leftMs: 2200));
      await _walk(tester, 100);
      expect(_saying(3), findsOneWidget);
      state.handleState(
        countingDownRoom(leftMs: 0, state: 'waiting', players: 1),
      );
      await tester.pump();
      expect(_opacity(tester), 0);
      expect(_anyNumber, findsNothing);
      expect(find.textContaining(state.t.waitingForPlayers), findsOneWidget);
      semantics.dispose();
      await _unmount(tester, state);
    });

    testWidgets('extended (a missile hold, or a countdown started again) it '
        'starts late, from 3', (tester) async {
      final semantics = tester.ensureSemantics();
      final state = await _mount(tester, countingDownRoom(leftMs: 2500));
      await _walk(tester, 100);
      expect(_saying(3), findsOneWidget);
      // Cancelled, and a new countdown that runs to a later deal.
      state.handleState(
        countingDownRoom(leftMs: 0, state: 'waiting', players: 1),
      );
      await tester.pump();
      state.handleState(countingDownRoom(leftMs: 5000, startsAt: 42));
      await _walk(tester, 50);
      expect(_anyNumber, findsNothing);
      await _walk(tester, 2000);
      expect(_saying(3), findsOneWidget);
      semantics.dispose();
      await _unmount(tester, state);
    });

    testWidgets('a phone set to reduce motion shows each number still, with '
        'no fades', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final semantics = tester.ensureSemantics();
      final state = await _mount(tester, countingDownRoom(leftMs: 2900));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_opacity(tester), 1, reason: 'no fade in');
      expect(_saying(3), findsOneWidget);
      await _walk(tester, 1000);
      expect(_saying(2), findsOneWidget);
      await _walk(tester, 1000);
      expect(_saying(1), findsOneWidget);
      expect(_opacity(tester), 1);
      await _walk(tester, 900);
      expect(_opacity(tester), 0, reason: 'gone at the deal, at once');
      semantics.dispose();
      await _unmount(tester, state);
    });

    testWidgets('a seat held for a chip purchase keeps its own line, and the '
        'countdown stays off it', (tester) async {
      final semantics = tester.ensureSemantics();
      final state = await _mount(
        tester,
        countingDownRoom(
          leftMs: 2000,
          unfundedDeadline: DateTime.now().millisecondsSinceEpoch + 20000,
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(_anyNumber, findsNothing);
      expect(find.textContaining(RegExp(r'Buy chips in \d+s')), findsOneWidget);
      semantics.dispose();
      await _unmount(tester, state);
    });

    testWidgets('a missed-turn notice has the slot until the countdown takes '
        'it', (tester) async {
      final state = await _mount(
        tester,
        countingDownRoom(leftMs: 4000, missedTurns: 1),
      );
      await _walk(tester, 100);
      expect(find.byType(MissedTurnsNotice), findsOneWidget);
      await _walk(tester, 1000);
      expect(find.byType(MissedTurnsNotice), findsNothing);
      expect(_opacity(tester), greaterThan(0));
      await _unmount(tester, state);
    });

    testWidgets('the poker felt counts down the same way', (tester) async {
      final semantics = tester.ensureSemantics();
      final json = pokerRoomJson()
        ..['state'] = 'starting'
        ..['turn'] = null
        ..['pot'] = 0
        ..['startsAt'] = countdownNow + 1500
        ..['startsInMs'] = 1500;
      (json['you'] as Map<String, dynamic>)
        ..remove('options')
        ..['cards'] = <String>[];
      (json['poker'] as Map<String, dynamic>)
        ..['community'] = <String>[]
        ..['pots'] = <Object>[];
      final state = await _mount(tester, RoomState.fromJson(json));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(StartCountdownLayer), findsOneWidget);
      expect(_saying(2), findsOneWidget);
      expect(find.text(state.t.startingGame), findsNothing);
      semantics.dispose();
      await _unmount(tester, state);
    });
  });

  group('it never covers a seat, the pot, the tag, the tax or a key', () {
    setUpAll(loadScriptFonts);

    Future<void> check(
      WidgetTester tester, {
      required Size size,
      required double scale,
      AppLang lang = AppLang.english,
      int places = 5,
      bool dark = true,
    }) async {
      final state = await _mount(
        tester,
        countingDownRoom(leftMs: 2530, players: places, maxPlayers: places),
        size: size,
        scale: scale,
        lang: lang,
        maxPlayers: places,
        dark: dark,
      );
      await tester.pump(const Duration(milliseconds: 300));
      final what =
          '${size.width.toInt()}x${size.height.toInt()} x$scale '
          '${lang.code} $places places';
      expect(tester.takeException(), isNull, reason: what);
      final disc = _disc(tester);
      final screen = Offset.zero & size;
      expect(
        screen.contains(disc.topLeft) && screen.contains(disc.bottomRight),
        isTrue,
        reason: '$what: on screen',
      );
      expect(disc.width, greaterThanOrEqualTo(StartCountdownLayer.minDisc));
      final others = <String, Finder>{
        'seat': find.byType(SeatPod),
        'tax': find.byType(WinningTaxTag),
        'tag': find.byKey(const ValueKey('tag')),
        'pot': find.descendant(
          of: find.byKey(const ValueKey('pot')),
          matching: find.byType(Plate),
        ),
        'key': find.byType(MachinedKey),
        'stepper': find.byType(StepperKey),
        'rail': find.byType(RailKey),
        'shop': find.byType(ShopButton),
        'wallet': find.byType(TableWallet),
      };
      // Nothing vacuous: every seat, the tax, the tag, the pot and the keys
      // were found to be measured against.
      expect(others['seat']!.evaluate().length, places, reason: what);
      for (final name in ['tax', 'tag', 'pot', 'key', 'shop']) {
        expect(others[name]!, findsWidgets, reason: '$what: $name');
      }
      for (final MapEntry(key: name, value: finder) in others.entries) {
        for (final element in finder.evaluate()) {
          final box = element.renderObject;
          if (box is! RenderBox || !box.hasSize) continue;
          final rect = box.localToGlobal(Offset.zero) & box.size;
          // The disc is round: a box meets it only where it comes nearer
          // its middle than its radius.
          final nearest = Offset(
            disc.center.dx.clamp(rect.left, rect.right),
            disc.center.dy.clamp(rect.top, rect.bottom),
          );
          expect(
            (nearest - disc.center).distance,
            greaterThanOrEqualTo(disc.width / 2),
            reason: '$what: the disc meets the $name at $rect',
          );
        }
      }
      await _unmount(tester, state);
    }

    for (final size in const [
      Size(592, 360),
      Size(640, 360),
      Size(732, 412),
      Size(844, 390),
      Size(891, 411),
      Size(915, 412),
      Size(1280, 800),
    ]) {
      for (final scale in [1.0, 1.25]) {
        testWidgets('${size.width.toInt()}x${size.height.toInt()} x$scale', (
          tester,
        ) async {
          await check(tester, size: size, scale: scale);
        });
      }
    }
    for (final lang in AppLang.values) {
      for (final dark in [true, false]) {
        testWidgets('640x360 x1.25 ${lang.code} ${dark ? 'night' : 'day'}', (
          tester,
        ) async {
          await check(
            tester,
            size: const Size(640, 360),
            scale: 1.25,
            lang: lang,
            dark: dark,
          );
        });
      }
    }
    for (final places in [2, 3, 4]) {
      testWidgets('$places places, 640x360 x1.25', (tester) async {
        await check(
          tester,
          size: const Size(640, 360),
          scale: 1.25,
          places: places,
        );
      });
    }
  });
}
