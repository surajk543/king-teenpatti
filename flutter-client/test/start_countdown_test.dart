// The countdown before a deal (owner, 29 Sep 2026: "whenever Game starts in
// any game table, instead of showing text "Starting game .." show this count
// Down animation 3,2,1 … when countdown finishes then distribute card").
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart' show ShowdownNews;
import 'package:teenpatti/settings/feedback_settings.dart';
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
  ShowdownNews? showdown,
  FeedbackSettings? feedback,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final sounds = feedback ?? await silentFeedback();
  if (feedback == null) addTearDown(sounds.dispose);
  final state = sceneState(
    TableScene('countdown', (s) {
      s.user = countdownViewer();
      s.config = s.config.copyWith(maxPlayers: maxPlayers);
      s.handleState(room);
      // The hand before the countdown, still on show (its reveals).
      if (showdown != null) s.handleShowdown(showdown);
    }),
    lang: lang,
  );
  final base = dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  final app = tableApp(
    state: state,
    feedback: sounds,
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

/// How opaque the countdown is drawn: 0 before it has been placed at all.
double _opacity(WidgetTester tester) {
  final fade = find.descendant(
    of: find.byType(StartCountdownLayer),
    matching: find.byType(FadeTransition),
  );
  if (fade.evaluate().isEmpty) return 0;
  return tester.widget<FadeTransition>(fade).opacity.value;
}

/// The deal's flying cards, while they fly.
Finder get _dealFlying => find.descendant(
  of: find.byType(DealFlights),
  matching: find.byType(CustomPaint),
);

/// The disc at the top of its pulse, in the screen's coordinates: where the
/// countdown placed it, under whatever stands over its slot.
Rect _disc(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('start-countdown-disc')));

/// Where the countdown stands and how far its stars may fly, in the screen's
/// coordinates.
({Rect disc, Rect painted, Rect? bounds, Rect? room}) _placed(
  WidgetTester tester,
) {
  final finder = find.byType(StartCountdownLayer);
  final placement = StartCountdownLayer.placementIn(finder.evaluate().single)!;
  final origin = tester.getTopLeft(finder);
  final bounds = placement.bounds;
  return (
    disc: placement.disc.shift(origin),
    painted: placement.painted.shift(origin),
    room: placement.room?.shift(origin),
    bounds: bounds == null
        ? null
        : Rect.fromLTRB(
            bounds.left + origin.dx,
            bounds.top + origin.dy,
            bounds.right + origin.dx,
            bounds.bottom + origin.dy,
          ),
  );
}

/// Every number the felt asks to be said aloud.
class _Said extends FeedbackSettings {
  final said = <int>[];

  @override
  void countdown(int number) => said.add(number);
}

/// Every clip the settings would play, with the Sound switch still deciding.
class _Clips extends FeedbackSettings {
  final played = <String>[];

  @override
  Future<void> playClip(
    String asset, {
    required double volume,
    required int voice,
  }) async => played.add(asset);
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

  group('where it stands', () {
    const anchor = Offset(300, 120);
    const size = 48.0;

    test('with nothing over it, where the felt asked', () {
      final p = StartCountdownPlacement.of(anchor: anchor, size: size);
      expect(p.disc, Rect.fromCircle(center: anchor, radius: size / 2));
      expect(p.feather, EdgeInsets.zero);
      expect(p.painted, p.reach);
    });

    test('under a head seat it gives way from its top and keeps its foot', () {
      const ceiling = 104.0; // the pod's foot, 8 below the default disc's top
      final p = StartCountdownPlacement.of(
        anchor: anchor,
        size: size,
        bounds: const Rect.fromLTRB(
          double.negativeInfinity,
          ceiling,
          double.infinity,
          double.infinity,
        ),
      );
      expect(p.disc.top, ceiling + StartCountdownPlacement.gap);
      expect(p.disc.bottom, anchor.dy + size / 2);
      expect(p.disc.width, p.disc.height);
      expect(p.disc.center.dx, anchor.dx);
      // The stars fade over the gap and no further: the disc is never faded.
      expect(p.feather.top, StartCountdownPlacement.gap);
      expect(p.painted.top, ceiling);
      expect(p.feather.left, 0);
    });

    test('with room above, the stars fade over at most the feather', () {
      final p = StartCountdownPlacement.of(
        anchor: anchor,
        size: size,
        bounds: const Rect.fromLTRB(
          double.negativeInfinity,
          40,
          double.infinity,
          double.infinity,
        ),
      );
      expect(p.disc, Rect.fromCircle(center: anchor, radius: size / 2));
      expect(p.feather.top, StartCountdownLayer.feather);
    });

    test('a pocket bounds it on every side it names', () {
      final p = StartCountdownPlacement.of(
        anchor: anchor,
        size: size,
        bounds: const Rect.fromLTRB(double.negativeInfinity, 90, 340, 140),
      );
      expect(p.disc.bottom, 140 - StartCountdownPlacement.gap);
      expect(p.disc.top, 96);
      expect(p.feather.bottom, StartCountdownPlacement.gap);
      expect(p.feather.right, StartCountdownLayer.feather);
      expect(p.reach.right, greaterThan(340));
      expect(p.painted.right, 340);
    });

    test('with no room, the least disc, centred on what room there is', () {
      final p = StartCountdownPlacement.of(
        anchor: anchor,
        size: size,
        bounds: const Rect.fromLTRB(
          double.negativeInfinity,
          130,
          double.infinity,
          double.infinity,
        ),
      );
      expect(p.disc.width, StartCountdownPlacement.least);
      expect(p.disc.center.dy, closeTo((134 + 144) / 2, 1e-9));
    });

    test('it moves by easing, never by a jump', () {
      final from = StartCountdownPlacement.of(anchor: anchor, size: size);
      final to = StartCountdownPlacement.of(
        anchor: anchor + const Offset(0, 9),
        size: size,
      );
      final step = from.towards(to);
      expect(step.disc.top, closeTo(from.disc.top + 3, 1e-9));
      var p = step;
      for (var i = 0; i < 30; i++) {
        p = p.towards(to);
      }
      expect(p, to);
    });

    test('its reach is the art scaled round the disc', () {
      final p = StartCountdownPlacement.of(
        anchor: anchor,
        size: StartCountdownArt.discPeak,
      );
      const r = StartCountdownArt.reach;
      const c = StartCountdownArt.discCentre;
      expect(p.reach, r.shift(anchor - c));
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

    test('everything it paints stays inside its reach, every frame', () async {
      final composition = StartCountdownArt.composition!;
      final drawable = LottieDrawable(composition);
      final b = composition.bounds;
      final frames = (composition.endFrame - composition.startFrame).round();
      var seen = Rect.zero;
      for (var f = 0; f <= frames; f++) {
        final recorder = ui.PictureRecorder();
        drawable
          ..setProgress(f / frames)
          ..draw(
            Canvas(recorder),
            Rect.fromLTWH(0, 0, b.width.toDouble(), b.height.toDouble()),
          );
        final image = await recorder.endRecording().toImage(b.width, b.height);
        final data = (await image.toByteData())!;
        for (var y = 0; y < image.height; y++) {
          for (var x = 0; x < image.width; x++) {
            if (data.getUint8((y * image.width + x) * 4 + 3) <= 8) continue;
            final pixel = Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1);
            seen = seen == Rect.zero ? pixel : seen.expandToInclude(pixel);
          }
        }
        image.dispose();
      }
      const reach = StartCountdownArt.reach;
      expect(reach.inflate(1).contains(seen.topLeft), isTrue, reason: '$seen');
      expect(
        reach.inflate(1).contains(seen.bottomRight - const Offset(1, 1)),
        isTrue,
        reason: '$seen',
      );
      // And not a loose box: every edge is reached.
      expect(seen.left, lessThan(reach.left + 2));
      expect(seen.top, lessThan(reach.top + 2));
      expect(seen.right, greaterThan(reach.right - 2));
      expect(seen.bottom, greaterThan(reach.bottom - 2));
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
          // On the disc above its number (the table's own, large: the
          // file's digit is hidden), where the gold shows whatever the font.
          final at = disc.center - Offset(0, disc.height * 0.4);
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

    testWidgets('a missed-turn warning keeps its five seconds, and the '
        'countdown comes in after it at the number the time left names', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      // The miss that ended the hand: its snapshot raised the warning, and
      // the countdown is due 3 s later (6 s window, the last 3 s).
      final state = await _mount(
        tester,
        countingDownRoom(leftMs: 6000, missedTurns: 2),
      );
      expect(state.missedTurnsNoticeShowing, isTrue);
      await _walk(tester, 3100);
      expect(state.countdownShowing, isTrue, reason: 'the countdown is due');
      expect(find.byType(MissedTurnsNotice), findsOneWidget);
      expect(_anyNumber, findsNothing, reason: 'the warning keeps the slot');
      expect(_opacity(tester), 0);
      // Five seconds after it was raised the warning goes, and the countdown
      // comes in at the number the time left names — "1", the deal a second
      // away — never from "3".
      await _walk(tester, 1920);
      expect(state.missedTurnsNoticeShowing, isFalse);
      await _walk(tester, 200);
      expect(find.byType(MissedTurnsNotice), findsNothing);
      expect(_saying(1), findsOneWidget);
      expect(_saying(3), findsNothing);
      expect(_saying(2), findsNothing);
      expect(_opacity(tester), greaterThan(0.9));
      semantics.dispose();
      await _unmount(tester, state);
    });

    testWidgets("at a head seat's table the warning has its own pocket, and "
        'both show', (tester) async {
      final semantics = tester.ensureSemantics();
      final state = await _mount(
        tester,
        countingDownRoom(
          leftMs: 2500,
          missedTurns: 1,
          players: 2,
          maxPlayers: 2,
        ),
        maxPlayers: 2,
      );
      await _walk(tester, 200);
      expect(find.byType(MissedTurnsNotice), findsOneWidget);
      expect(_saying(3), findsOneWidget);
      final notice = tester.getRect(find.byType(MissedTurnsNotice));
      final disc = _disc(tester);
      expect(notice.overlaps(disc), isFalse);
      semantics.dispose();
      await _unmount(tester, state);
    });

    testWidgets("a new table's first hand: the countdown, then the cards "
        'fly (handNo 0 to 1)', (tester) async {
      final state = await _mount(
        tester,
        countingDownRoom(leftMs: 900, handNo: 0),
      );
      await _walk(tester, 900);
      expect(_dealFlying, findsNothing);
      state.handleState(dealtRoom(handNo: 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(_dealFlying, findsOneWidget);
      await _unmount(tester, state);
    });

    testWidgets('art that arrives mid-number waits for the next one: no swap '
        'in the middle of a number', (tester) async {
      final art = StartCountdownArt.composition!;
      final arriving = Completer<LottieComposition?>();
      StartCountdownArt.debugLoading = arriving.future;
      addTearDown(() => StartCountdownArt.debugComposition = art);
      // The plain disc, saying [n]; the art's painter.
      Finder plain(int n) => find.descendant(
        of: find.byType(StartCountdownLayer),
        matching: find.byWidgetPredicate(
          (w) =>
              w.runtimeType.toString() == '_PlainDisc' &&
              (w as dynamic).number == n,
        ),
      );
      Finder painted() => find.descendant(
        of: find.byType(StartCountdownLayer),
        matching: find.byWidgetPredicate(
          (w) =>
              w is CustomPaint &&
              w.painter.runtimeType.toString() == '_CountdownPainter',
        ),
      );
      final state = await _mount(tester, countingDownRoom(leftMs: 2900));
      await _walk(tester, 100);
      expect(plain(3), findsOneWidget, reason: 'the plain disc says it');
      arriving.complete(art);
      await _walk(tester, 300);
      expect(plain(3), findsOneWidget, reason: 'the 3 is not swapped');
      expect(painted(), findsNothing);
      await _walk(tester, 700);
      expect(plain(2), findsNothing, reason: 'the art has taken over at 2');
      expect(painted(), findsOneWidget);
      await _unmount(tester, state);
    });

    testWidgets('before a first deal the poker board stands its empty places '
        'back while the numbers show, and brings them back with the deal', (
      tester,
    ) async {
      final state = await _mount(tester, countingDownPokerRoom(leftMs: 4000));
      double outline() => tester
          .widgetList<AnimatedOpacity>(
            find.ancestor(
              of: find.byWidgetPredicate(
                (w) => w.runtimeType.toString() == '_EmptySlot',
              ),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .map((w) => w.opacity)
          .reduce(math.max);
      await _walk(tester, 200);
      expect(outline(), 1, reason: 'before the numbers');
      await _walk(tester, 1000);
      expect(state.countdownShowing, isTrue);
      expect(outline(), 0);
      // Dealt: the flop out, its two places still to come shown again.
      state.handleState(RoomState.fromJson(pokerRoomJson()));
      await tester.pump(const Duration(milliseconds: 400));
      expect(outline(), 1, reason: 'the countdown over');
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

  /// The least the countdown's disc is across on the Teen Patti felt, as a
  /// share of the screen's height: 126dp on a 360dp phone, where the disc it
  /// replaced was 48 (29 Sep 2026: "count down text should be big").
  const bigAtLeast = 0.35;

  group('it never covers a seat, the pot, the tag, the tax or a key, and its '
      'stars never show through one', () {
    setUpAll(loadScriptFonts);

    /// Every box on the felt [what] names, in the screen's coordinates.
    Iterable<(String, Rect)> boxes(
      WidgetTester tester,
      Map<String, Finder> of,
    ) => [
      for (final MapEntry(key: name, value: finder) in of.entries)
        for (final element in finder.evaluate())
          if (element.renderObject case final RenderBox box
              when box.hasSize && box.attached)
            (name, box.localToGlobal(Offset.zero) & box.size),
    ];

    Future<void> check(
      WidgetTester tester, {
      required Size size,
      required double scale,
      AppLang lang = AppLang.english,
      int places = 5,
      bool dark = true,
      String category = 'blind',
      bool afterHand = false,
    }) async {
      final state = await _mount(
        tester,
        countingDownRoom(
          leftMs: 2530,
          players: places,
          maxPlayers: places,
          category: category,
          afterHand: afterHand,
        ),
        size: size,
        scale: scale,
        lang: lang,
        maxPlayers: places,
        dark: dark,
        showdown: afterHand ? countdownShowdown(players: places) : null,
      );
      await tester.pump(const Duration(milliseconds: 300));
      final what =
          '${size.width.toInt()}x${size.height.toInt()} x$scale '
          '${lang.code} $places places $category'
          '${afterHand ? ' after a hand' : ''}';
      expect(tester.takeException(), isNull, reason: what);
      final placed = _placed(tester);
      final disc = placed.disc;
      final keyed = _disc(tester);
      for (final (a, b) in [
        (keyed.left, disc.left),
        (keyed.top, disc.top),
        (keyed.right, disc.right),
        (keyed.bottom, disc.bottom),
      ]) {
        expect(a, closeTo(b, 0.01), reason: '$what: the disc the layer placed');
      }
      final screen = Offset.zero & size;
      expect(
        screen.contains(disc.topLeft) && screen.contains(disc.bottomRight),
        isTrue,
        reason: '$what: on screen',
      );
      expect(
        disc.width,
        greaterThanOrEqualTo(StartCountdownPlacement.least),
        reason: what,
      );
      final others = <String, Finder>{
        'seat': find.byType(SeatPod),
        'tax': find.byType(WinningTaxTag),
        'tag': find.byKey(const ValueKey('tag')),
        'key': find.byType(MachinedKey),
        'stepper': find.byType(StepperKey),
        'rail': find.byType(RailKey),
        'shop': find.byType(ShopButton),
        'wallet': find.byType(TableWallet),
      };
      // Nothing vacuous: every seat, the tax, the tag and the keys were found
      // to be measured against.
      expect(others['seat']!.evaluate().length, places, reason: what);
      for (final name in ['tax', 'tag', 'key', 'shop']) {
        expect(others[name]!, findsWidgets, reason: '$what: $name');
      }
      // Big (owner, 29 Sep 2026: "count down text should be big"): its disc
      // takes its share of the clear circle it stands in, and is at least
      // [bigAtLeast] of the screen's height across.
      final room = placed.room!;
      expect(
        disc.width,
        closeTo(room.width * StartCountdownPlacement.discShare, 0.01),
        reason: what,
      );
      expect(
        disc.width,
        greaterThanOrEqualTo(
          math.min(bigAtLeast * size.height, StartCountdownLayer.bigDisc),
        ),
        reason: '$what: ${disc.width.toStringAsFixed(1)} across',
      );
      // The disc and its stars' circle meet nothing: the stars fly no further
      // than that circle, which is clear of every seat — the viewer's own
      // included —, the viewer's cards, the tag, the tax pill and every key.
      for (final (name, rect) in boxes(tester, others)) {
        final nearest = Offset(
          room.center.dx.clamp(rect.left, rect.right),
          room.center.dy.clamp(rect.top, rect.bottom),
        );
        expect(
          (nearest - room.center).distance,
          greaterThanOrEqualTo(room.width / 2 - 0.01),
          reason: '$what: the countdown meets the $name at $rect ($room)',
        );
      }
      // The last hand's cards have cleared for it, and the pot, which holds
      // nothing between hands, steps back while the numbers stand over its
      // place.
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('own-hand-clear')),
            )
            .opacity,
        0,
        reason: '$what: the last hand clears',
      );
      expect(
        tester
            .widget<AnimatedOpacity>(find.byKey(const ValueKey('pot-plate')))
            .opacity,
        0,
        reason: '$what: the pot steps back',
      );
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
        // A table of two or four places has a head seat over the slot, and
        // a seen table's pods carry their stacks — taller than wide — as do
        // the hands shown down after a hand.
        for (final places in [2, 4]) {
          testWidgets('${size.width.toInt()}x${size.height.toInt()} x$scale, '
              '$places places, seen and blind, before and after a hand', (
            tester,
          ) async {
            for (final category in ['seen', 'blind']) {
              for (final afterHand in [false, true]) {
                await check(
                  tester,
                  size: size,
                  scale: scale,
                  places: places,
                  category: category,
                  afterHand: afterHand,
                );
              }
            }
          });
        }
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
          await check(
            tester,
            size: const Size(640, 360),
            scale: 1.25,
            lang: lang,
            dark: dark,
            places: 2,
            category: 'seen',
            afterHand: true,
          );
        });
      }
    }
    for (final places in [3, 5]) {
      testWidgets('$places places after a hand, seen, 640x360 x1.25', (
        tester,
      ) async {
        await check(
          tester,
          size: const Size(640, 360),
          scale: 1.25,
          places: places,
          category: 'seen',
          afterHand: true,
        );
      });
    }
  });

  group('on the poker felt it never covers a seat or a key, and its stars '
      'never show through one', () {
    setUpAll(loadScriptFonts);

    Future<void> check(
      WidgetTester tester, {
      required Size size,
      required double scale,
      required bool afterHand,
      bool dark = true,
      AppLang lang = AppLang.english,
    }) async {
      final state = await _mount(
        tester,
        countingDownPokerRoom(leftMs: 2530, afterHand: afterHand),
        size: size,
        scale: scale,
        dark: dark,
        lang: lang,
      );
      await tester.pump(const Duration(milliseconds: 300));
      final what =
          '${size.width.toInt()}x${size.height.toInt()} x$scale ${lang.code} '
          '${afterHand ? 'after a hand' : 'before a first deal'}';
      expect(tester.takeException(), isNull, reason: what);
      final placed = _placed(tester);
      final disc = placed.disc;
      expect(disc.width, greaterThanOrEqualTo(StartCountdownPlacement.least));
      final keys = <Finder>[
        find.byType(MachinedKey),
        find.byType(StepperKey),
        find.byType(RailKey),
        find.byType(ShopButton),
        find.byType(TableWallet),
      ];
      final seats = find.byWidgetPredicate((w) => w is SeatPod && !w.isMe);
      expect(seats, findsNWidgets(4), reason: what);
      Iterable<Rect> rects(Finder f) => [
        for (final element in f.evaluate())
          if (element.renderObject case final RenderBox box
              when box.hasSize && box.attached)
            box.localToGlobal(Offset.zero) & box.size,
      ];
      final painted = placed.painted.deflate(0.5);
      for (final f in [find.byType(SeatPod), ...keys]) {
        for (final rect in rects(f)) {
          final nearest = Offset(
            disc.center.dx.clamp(rect.left, rect.right),
            disc.center.dy.clamp(rect.top, rect.bottom),
          );
          expect(
            (nearest - disc.center).distance,
            greaterThanOrEqualTo(disc.width / 2),
            reason: '$what: the disc meets $rect',
          );
        }
      }
      for (final f in [seats, ...keys]) {
        for (final rect in rects(f)) {
          expect(
            painted.overlaps(rect),
            isFalse,
            reason: '$what: the stars reach $rect ($painted)',
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
          for (final afterHand in [false, true]) {
            await check(tester, size: size, scale: scale, afterHand: afterHand);
          }
        });
      }
    }
    for (final lang in AppLang.values) {
      testWidgets('640x360 x1.25 ${lang.code}, both themes', (tester) async {
        for (final dark in [true, false]) {
          for (final afterHand in [false, true]) {
            await check(
              tester,
              size: const Size(640, 360),
              scale: 1.25,
              afterHand: afterHand,
              dark: dark,
              lang: lang,
            );
          }
        }
      });
    }
  });

  group('no star shows through a seat, pixel for pixel', () {
    setUpAll(loadScriptFonts);

    /// Every seat but the viewer's, the tag and the tax pill, in the
    /// screen's coordinates: what stands over the countdown.
    List<Rect> over(WidgetTester tester) => [
      for (final element
          in find.byWidgetPredicate((w) => w is SeatPod && !w.isMe).evaluate())
        if (element.renderObject case final RenderBox box when box.hasSize)
          box.localToGlobal(Offset.zero) & box.size,
      for (final element in find.byType(WinningTaxTag).evaluate())
        if (element.renderObject case final RenderBox box when box.hasSize)
          box.localToGlobal(Offset.zero) & box.size,
    ];

    /// The table walked from the countdown's start to each of [at] (ms left),
    /// and its pixels inside [boxes] at each. [due] false: the same table, the
    /// same instants, with the deal a further 10 s off — nothing of the
    /// countdown drawn.
    Future<List<List<int>>> frames(
      WidgetTester tester, {
      required bool due,
      required List<int> at,
      required int places,
      required String category,
      required bool afterHand,
      required bool dark,
      required Size size,
      required double scale,
      required void Function(List<Rect>) boxes,
    }) async {
      final key = GlobalKey();
      final state = await _mount(
        tester,
        countingDownRoom(
          leftMs: due ? 3000 : 13000,
          players: places,
          maxPlayers: places,
          category: category,
          afterHand: afterHand,
        ),
        size: size,
        scale: scale,
        dark: dark,
        maxPlayers: places,
        boundary: key,
        showdown: afterHand ? countdownShowdown(players: places) : null,
      );
      final regions = over(tester);
      boxes(regions);
      final out = <List<int>>[];
      var left = 3000;
      for (final target in at) {
        await _walk(tester, left - target);
        left = target;
        final pixels = await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          final picked = <int>[];
          for (final r in regions) {
            final region = r.intersect(Offset.zero & size);
            for (var y = region.top.ceil(); y < region.bottom.floor(); y++) {
              for (var x = region.left.ceil(); x < region.right.floor(); x++) {
                final i = (y * image.width + x) * 4;
                picked
                  ..add(data.getUint8(i))
                  ..add(data.getUint8(i + 1))
                  ..add(data.getUint8(i + 2));
              }
            }
          }
          image.dispose();
          return picked;
        });
        out.add(pixels!);
      }
      await _unmount(tester, state);
      countdownNow -= 3000 - left;
      return out;
    }

    const at = [2600, 2000, 1400, 700];
    for (final (size, scale) in const [
      (Size(640, 360), 1.25),
      (Size(891, 411), 1.0),
    ]) {
      for (final places in [2, 4, 5]) {
        for (final dark in [true, false]) {
          testWidgets(
            '${size.width.toInt()}x${size.height.toInt()} x$scale, $places '
            'places, ${dark ? 'night' : 'day'}, seen, before and after a hand',
            (tester) async {
              for (final afterHand in [false, true]) {
                late List<Rect> boxesA, boxesB;
                final a = await frames(
                  tester,
                  due: true,
                  at: at,
                  places: places,
                  category: 'seen',
                  afterHand: afterHand,
                  dark: dark,
                  size: size,
                  scale: scale,
                  boxes: (b) => boxesA = b,
                );
                final b = await frames(
                  tester,
                  due: false,
                  at: at,
                  places: places,
                  category: 'seen',
                  afterHand: afterHand,
                  dark: dark,
                  size: size,
                  scale: scale,
                  boxes: (b) => boxesB = b,
                );
                expect(boxesA, boxesB);
                expect(boxesA, isNotEmpty);
                for (var i = 0; i < at.length; i++) {
                  expect(a[i].length, b[i].length);
                  var worst = 0;
                  for (var j = 0; j < a[i].length; j++) {
                    worst = math.max(worst, (a[i][j] - b[i][j]).abs());
                  }
                  expect(
                    worst,
                    lessThanOrEqualTo(2),
                    reason:
                        '${at[i]} ms left${afterHand ? ', after a hand' : ''}',
                  );
                }
              }
            },
          );
        }
      }
    }
  });

  group('said aloud (29 Sep 2026: "can u add sound also saying 3,2,1")', () {
    testWidgets('each number is said once as it comes up, and nothing after '
        'the deal', (tester) async {
      final said = _Said();
      addTearDown(said.dispose);
      final state = await _mount(
        tester,
        countingDownRoom(leftMs: 3000),
        feedback: said,
      );
      await _walk(tester, 100);
      expect(said.said, [3]);
      await _walk(tester, 1000);
      expect(said.said, [3, 2]);
      // The same deal again (a chat line, a reconnect): nothing said twice.
      state.handleState(countingDownRoom(leftMs: 1900));
      await _walk(tester, 1000);
      expect(said.said, [3, 2, 1]);
      await _walk(tester, 1000);
      state.handleState(countingDownRoom(leftMs: 0, state: 'betting'));
      await _walk(tester, 2000);
      expect(said.said, [3, 2, 1]);
      await _unmount(tester, state);
    });

    testWidgets('a countdown joined at "2" says two and one', (tester) async {
      final said = _Said();
      addTearDown(said.dispose);
      final state = await _mount(
        tester,
        countingDownRoom(leftMs: 1800),
        feedback: said,
      );
      await _walk(tester, 1900);
      expect(said.said, [2, 1]);
      await _unmount(tester, state);
    });

    test(
      "the owner's three clips, one a number, behind the Sound switch",
      () async {
        for (final n in [1, 2, 3]) {
          expect(
            File('assets/${FeedbackSettings.countdownClip(n)}').existsSync(),
            isTrue,
            reason: '$n',
          );
        }
        SharedPreferences.setMockInitialValues({'soundOn': true});
        final clips = _Clips();
        await clips.load();
        clips
          ..countdown(3)
          ..countdown(2)
          ..countdown(1)
          ..countdown(0)
          ..countdown(4);
        await Future<void>.delayed(Duration.zero);
        expect(clips.played, [
          'sound/countdown 3.mp3',
          'sound/countdown 2.mp3',
          'sound/countdown 1.mp3',
        ]);
        await clips.setSound(false);
        clips.played.clear();
        clips.countdown(3);
        await Future<void>.delayed(Duration.zero);
        expect(clips.played, isEmpty, reason: 'the Sound switch off');
        clips.dispose();
      },
    );
  });

  group('big (29 Sep 2026: "count down text should be big")', () {
    test("the number's second: it pops in, holds, and fades as the next "
        'comes', () {
      expect(StartCountdownDigit.numberAt(0), 3);
      expect(StartCountdownDigit.numberAt(0.34), 2);
      expect(StartCountdownDigit.numberAt(0.67), 1);
      expect(StartCountdownDigit.numberAt(1), 1);
      expect(StartCountdownDigit.withinAt(0.5), closeTo(0.5, 1e-9));
      expect(StartCountdownDigit.opacityAt(0), 0);
      expect(StartCountdownDigit.scaleAt(0), StartCountdownDigit.popFrom);
      for (final within in [0.2, 0.47, 0.8]) {
        expect(StartCountdownDigit.opacityAt(within), 1, reason: '$within');
        expect(StartCountdownDigit.scaleAt(within), 1, reason: '$within');
      }
      expect(StartCountdownDigit.opacityAt(0.99), lessThan(0.2));
      // Still (reduce motion): each number at the top of its second, whole.
      for (final n in [3, 2, 1]) {
        final at = StartCountdownArt.peakOf(n);
        expect(StartCountdownDigit.numberAt(at), n);
        expect(
          StartCountdownDigit.opacityAt(StartCountdownDigit.withinAt(at)),
          1,
        );
      }
    });

    test('it stands in the largest clear circle on the vertical, nearest the '
        'middle of the table where it could be as large higher or lower', () {
      const area = Rect.fromLTWH(0, 0, 600, 360);
      // A seat to the right of the vertical, low down.
      const seat = Rect.fromLTRB(360, 200, 460, 330);
      final placed = StartCountdownPlacement.largest(
        centreX: 300,
        area: area,
        keepClear: const [seat],
        preferY: 250,
        maxDisc: 400,
      );
      final room = placed.room!;
      final nearest = Offset(
        room.center.dx.clamp(seat.left, seat.right),
        room.center.dy.clamp(seat.top, seat.bottom),
      );
      expect(
        (nearest - room.center).distance,
        greaterThanOrEqualTo(room.width / 2),
      );
      expect((placed.disc.center - room.center).distance, lessThan(1e-9));
      expect(
        placed.disc.width,
        closeTo(room.width * StartCountdownPlacement.discShare, 1e-9),
      );
      // Pushed up from the seat, as far as it needed.
      expect(room.center.dy, lessThan(250));
      // With room to spare it keeps its preferred height and its cap.
      final roomy = StartCountdownPlacement.largest(
        centreX: 300,
        area: area,
        keepClear: const [],
        preferY: 180,
        maxDisc: 120,
      );
      expect(
        (roomy.disc.center - const Offset(300, 180)).distance,
        lessThan(1e-9),
      );
      expect(roomy.disc.width, closeTo(120, 1e-9));
    });

    testWidgets('its number is set on the disc, large, and the file\'s own '
        'digit is hidden', (tester) async {
      final delegates = StartCountdownColours.night.delegates;
      for (final n in ['3', '2', '1']) {
        expect(
          delegates.any((d) => d.keyPath.join('/') == n && d.value == 0),
          isTrue,
          reason: 'the file\'s $n hidden',
        );
      }
      expect(StartCountdownDigit.capShare, greaterThanOrEqualTo(0.5));
    });
  });
}
