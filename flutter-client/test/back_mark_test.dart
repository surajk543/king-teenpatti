// The owner's back key on the lobby (30 Sep 2026): "after clicking Lobby card
// … use this back button animation for going back instead of using that
// icon".
//
// assets/animations/Back Button.json plays in the back tile a category's
// tables stand behind (widgets/back_mark.dart, over widgets/fact_mark.dart),
// its ring the key's own edge, in the card's display ink — the file's
// charcoal would all but vanish by night. These hold the file to what a
// phone can play and to the box the widget fits it into; the widget to the
// ink of each theme, to its box, and to playing on through the lobby's
// one-second rebuilds; and the lobby to drawing it in the back tile, where a
// tap still goes back.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/back_mark.dart';

import 'level_fixtures.dart';
import 'script_fonts.dart';

final _json =
    jsonDecode(File('assets/animations/Back Button.json').readAsStringSync())
        as Map<String, dynamic>;

/// Where the painted pixels of [progress] lie on the file's canvas, drawn at
/// 0.4 of a pixel a unit over a mid grey. `fit: BoxFit.fill`: the drawable's
/// default, `BoxFit.scaleDown`, never scales up (info_wave_test's lesson).
Future<Rect> _paintedAt(LottieComposition comp, double progress) async {
  const px = 432;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(const Color(0xFF808080), BlendMode.src);
  LottieDrawable(comp)
    ..setProgress(progress)
    ..draw(
      canvas,
      Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble()),
      fit: BoxFit.fill,
    );
  final image = await recorder.endRecording().toImage(px, px);
  final pixels = (await image.toByteData())!;
  var left = px, top = px, right = -1, bottom = -1;
  for (var y = 0; y < px; y++) {
    for (var x = 0; x < px; x++) {
      final i = (y * px + x) * 4;
      if ((pixels.getUint8(i) - 0x80).abs() > 6 ||
          (pixels.getUint8(i + 1) - 0x80).abs() > 6 ||
          (pixels.getUint8(i + 2) - 0x80).abs() > 6) {
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
  }
  const unit = 1080 / px;
  return Rect.fromLTRB(
    left * unit,
    top * unit,
    (right + 1) * unit,
    (bottom + 1) * unit,
  );
}

final _menu = GameConfig.fromJson({
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'categories': ['seen', 'blind', 'variation'],
  'tables': [
    {'category': 'seen', 'bootAmount': 200},
    {'category': 'blind', 'bootAmount': 200, 'maxChips': 2000000},
    {'category': 'variation', 'bootAmount': 50000, 'maxChips': 2000000000},
  ],
});

/// The painted pixels of a 60x60 box with [child] in its middle over a mid
/// grey, four pixels a dp.
Future<(Rect, List<Color>)> _paint(
  WidgetTester tester,
  GlobalKey boundary,
) async {
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final bytes = await tester.runAsync(() async {
    final image = await render.toImage(pixelRatio: 4);
    return (await image.toByteData())!;
  });
  var left = 240, top = 240, right = -1, bottom = -1;
  final colours = <Color>[];
  for (var y = 0; y < 240; y++) {
    for (var x = 0; x < 240; x++) {
      final i = (y * 240 + x) * 4;
      final r = bytes!.getUint8(i), g = bytes.getUint8(i + 1);
      final b = bytes.getUint8(i + 2);
      if ((r - 0x80).abs() > 6 ||
          (g - 0x80).abs() > 6 ||
          (b - 0x80).abs() > 6) {
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
        colours.add(Color.fromARGB(255, r, g, b));
      }
    }
  }
  return (
    Rect.fromLTRB(left / 4, top / 4, (right + 1) / 4, (bottom + 1) / 4),
    colours,
  );
}

Widget _host(GlobalKey boundary, Brightness brightness, Widget child) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(
        data: ThemeData(brightness: brightness),
        child: Center(
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox(
              width: 60,
              height: 60,
              child: ColoredBox(
                color: const Color(0xFF808080),
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  setUpAll(loadScriptFonts);

  group('the file', () {
    test('is 1080 units square, a second and a half a loop, nothing a phone '
        'cannot play, drawn in one charcoal', () {
      expect(_json['w'], 1080);
      expect(_json['h'], 1080);
      expect(
        ((_json['op'] as num) - (_json['ip'] as num)) / (_json['fr'] as num),
        closeTo(1.53, 0.01),
      );
      final text = jsonEncode(_json);
      for (final layer in (_json['layers'] as List).cast<Map>()) {
        expect(layer['ddd'] ?? 0, 0, reason: 'no 3D layer');
      }
      expect(RegExp(r'"x":"').hasMatch(text), isFalse, reason: 'expressions');
      expect(_json['assets'] as List, isEmpty, reason: 'no images');
      // #2B2B2B, the one colour, on 0..1 channels.
      expect(text, contains('0.168,0.168,0.168'));
    });

    testWidgets('its ring at rest fills the box the widget fits it to, '
        'centred, and the press only draws it in', (tester) async {
      await tester.runAsync(() async {
        final comp = await LottieComposition.fromBytes(
          File('assets/animations/Back Button.json').readAsBytesSync(),
        );
        const art = backMarkArt;
        final box = Rect.fromCenter(
          center: art.centre,
          width: art.extent,
          height: art.extent,
        ).inflate(4);
        var all = Rect.zero;
        for (var frame = 0; frame <= 46; frame += 2) {
          final painted = await _paintedAt(comp, frame / 46);
          all = frame == 0 ? painted : all.expandToInclude(painted);
          expect(
            box.contains(painted.topLeft) && box.contains(painted.bottomRight),
            isTrue,
            reason: 'frame $frame: $painted outside $box',
          );
        }
        expect(all.width, closeTo(art.extent, 5));
        expect(all.center.dx, closeTo(art.centre.dx, 3));
        expect(all.center.dy, closeTo(art.centre.dy, 3));
      });
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('the widget fills its 44dp box and no more, in the '
        '${brightness.name} theme\'s display ink', (tester) async {
      await tester.runAsync(() => AssetLottie(backMarkAsset).load());
      final boundary = GlobalKey();
      await tester.pumpWidget(
        _host(
          boundary,
          brightness,
          const BackMark(size: 44, fallbackInk: Color(0xFFFF00FF)),
        ),
      );
      await tester.pump();
      final ink = brightness == Brightness.dark
          ? GlassColors.dark.textDisplay
          : GlassColors.light.textDisplay;
      const box = Rect.fromLTWH(8, 8, 44, 44);
      var all = Rect.zero;
      for (var step = 0; step < 12; step++) {
        await tester.pump(const Duration(milliseconds: 125));
        final (painted, colours) = await _paint(tester, boundary);
        all = step == 0 ? painted : all.expandToInclude(painted);
        expect(
          box.inflate(0.5).contains(painted.topLeft) &&
              box.inflate(0.5).contains(painted.bottomRight),
          isTrue,
          reason: 'step $step: $painted outside $box',
        );
        // Every solid pixel is the ink; the rest is its anti-aliased edge
        // over the grey, never the file's charcoal on the dark theme.
        final solid = colours.where(
          (c) =>
              (c.r - ink.r).abs() < 0.02 &&
              (c.g - ink.g).abs() < 0.02 &&
              (c.b - ink.b).abs() < 0.02,
        );
        expect(solid, isNotEmpty, reason: 'step $step: drawn in $ink');
        if (brightness == Brightness.dark) {
          expect(
            colours.where((c) => c.computeLuminance() < 0.05),
            isEmpty,
            reason: 'step $step: no charcoal on the night card',
          );
        }
      }
      expect(all.width, greaterThan(42), reason: '$all');
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('plays on through its parent rebuilding every second', (
    tester,
  ) async {
    await tester.runAsync(() => AssetLottie(backMarkAsset).load());
    final tick = ValueNotifier<int>(0);
    addTearDown(tick.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: ListenableBuilder(
            listenable: tick,
            // Not const: a new widget every tick, as the lobby hands it.
            // ignore: prefer_const_constructors
            builder: (context, _) =>
                BackMark(size: 44, fallbackInk: const Color(0xFFFFFFFF)),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final lottie = find.byType(Lottie);
    final state = tester.state(lottie);
    final widget = tester.widget<Lottie>(lottie);
    double progress() =>
        tester.widget<RawLottie>(find.byType(RawLottie)).progress;
    await tester.pump(const Duration(milliseconds: 100));
    final before = progress();
    tick.value++;
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.state(lottie), same(state));
    expect(tester.widget<Lottie>(lottie), same(widget));
    expect((progress() - before) % 1, closeTo(500 / 1533, 0.03));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final dark in [true, false]) {
    testWidgets('the back tile of every category carries it where the arrow '
        'was, and a tap on it still goes back '
        '(${dark ? 'night' : 'day'})', (tester) async {
      primeBadges();
      final state = levelState(level: levelAt(10, xp: 4180))..config = _menu;
      await pumpLevelLobby(
        tester,
        state,
        screen: const Size(640, 360),
        scale: 1.25,
        dark: dark,
      );
      expect(find.byType(BackMark), findsNothing, reason: 'the front');
      for (final category in const ['seen', 'blind', 'variation']) {
        state.openLobbyCategory(category);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(BackMark), findsOneWidget, reason: category);
        expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
        final mark = tester.getRect(find.byKey(const ValueKey('back-mark')));
        expect(mark.width, 44, reason: '$category: the key\'s own size');
        expect(tester.takeException(), isNull, reason: category);
        await tester.tap(find.byKey(const ValueKey('back-mark')));
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        expect(state.lobbyCategory, isNull, reason: '$category: back');
        expect(find.byType(BackMark), findsNothing, reason: category);
      }
      await unmountLevel(tester, state);
    });
  }
}
