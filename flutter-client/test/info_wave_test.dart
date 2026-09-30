// The owner's info mark on the lobby's table cards (29 Sep 2026): "use this
// icon for info on top right for seen 200 table, 50000 table, blind 200,
// blind 50000, variation etc. and change color acc to card type".
//
// assets/animations/Info icon wave.json plays in each table card's info key
// (widgets/info_wave.dart, over widgets/fact_mark.dart), in the card's colour,
// its "i" a slate by day where the file's pale grey would not read. These
// hold the file to what a phone can play and to the box the widget fits its
// waves into; the day "i" to a line's contrast on the white card; the widget
// to playing on through the lobby's one-second rebuilds; and the lobby to
// drawing it in every table card's info key, in the card's colour, inside the
// key's disc — a tap on it still the card's info.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/fact_mark.dart';
import 'package:teenpatti/widgets/info_wave.dart';

import 'level_fixtures.dart';
import 'script_fonts.dart';

final _json =
    jsonDecode(File('assets/animations/Info icon wave.json').readAsStringSync())
        as Map<String, dynamic>;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Where the painted pixels of [progress] lie on the file's canvas, drawn
/// four pixels a unit over a mid grey. `fit: BoxFit.fill`: the drawable's
/// default, `BoxFit.scaleDown`, never scales UP, and drew the 120-unit file at
/// 120px — a quarter of the art — which is how the first cut came to draw the
/// waves four times too large.
Future<Rect> _paintedAt(LottieComposition comp, double progress) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(const Color(0xFF808080), BlendMode.src);
  LottieDrawable(comp)
    ..setProgress(progress)
    ..draw(canvas, const Rect.fromLTWH(0, 0, 480, 480), fit: BoxFit.fill);
  final image = await recorder.endRecording().toImage(480, 480);
  final pixels = (await image.toByteData())!;
  var left = 480, top = 480, right = -1, bottom = -1;
  for (var y = 0; y < 480; y++) {
    for (var x = 0; x < 480; x++) {
      final i = (y * 480 + x) * 4;
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
  return Rect.fromLTRB(left / 4, top / 4, right / 4, bottom / 4);
}

final _menu = GameConfig.fromJson({
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'categories': ['seen', 'blind', 'variation'],
  'tables': [
    {'category': 'seen', 'bootAmount': 200},
    {'category': 'seen', 'bootAmount': 50000},
    {'category': 'blind', 'bootAmount': 200, 'maxChips': 2000000},
    {'category': 'blind', 'bootAmount': 50000, 'maxChips': 2000000000},
    {'category': 'variation', 'bootAmount': 50000, 'maxChips': 2000000000},
  ],
});

void main() {
  setUpAll(loadScriptFonts);

  group('the file', () {
    test('is 120 units square, two seconds a loop, nothing a phone cannot '
        'play; its "i" is the one layer "i Outlines", in #ACB6C3', () {
      expect(_json['w'], 120);
      expect(_json['h'], 120);
      expect((_json['op'] as num) / (_json['fr'] as num), closeTo(2, 0.01));
      final layers = (_json['layers'] as List).cast<Map<String, dynamic>>();
      for (final layer in layers) {
        expect(layer['ddd'] ?? 0, 0, reason: 'no 3D layer');
      }
      expect(
        RegExp(r'"x":"').hasMatch(jsonEncode(_json)),
        isFalse,
        reason: 'no expressions',
      );
      expect((_json['assets'] as List), isEmpty, reason: 'no images');
      final glyph = layers.where((l) => l['nm'] == infoWaveGlyph.first);
      expect(glyph, hasLength(1));
      expect(jsonEncode(glyph.single['shapes']), contains('0.675,0.714,0.765'));
    });

    testWidgets('its waves at their widest fill the box the widget fits it '
        'to, centred', (tester) async {
      await tester.runAsync(() async {
        final comp = await LottieComposition.fromBytes(
          File('assets/animations/Info icon wave.json').readAsBytesSync(),
        );
        final art = infoWaveArt;
        final box = Rect.fromCenter(
          center: art.centre,
          width: art.extent,
          height: art.extent,
        ).inflate(0.5);
        var all = Rect.zero;
        for (var frame = 0; frame < 48; frame += 2) {
          final painted = await _paintedAt(comp, (frame + 0.5) / 48);
          all = frame == 0 ? painted : all.expandToInclude(painted);
          expect(
            box.contains(painted.topLeft) && box.contains(painted.bottomRight),
            isTrue,
            reason: 'frame $frame: $painted outside $box',
          );
        }
        expect(all.width, closeTo(art.extent, 1));
        expect(all.center.dx, closeTo(art.centre.dx, 0.5));
        expect(all.center.dy, closeTo(art.centre.dy, 0.5));
      });
    });
  });

  testWidgets('the widget paints nothing outside its 26dp box, and its '
      'waves reach the box', (tester) async {
    await tester.runAsync(() => AssetLottie(infoWaveAsset).load());
    final boundary = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: boundary,
            child: const SizedBox(
              width: 60,
              height: 60,
              child: ColoredBox(
                color: Color(0xFF808080),
                child: Center(
                  child: InfoWave(
                    size: 26,
                    fallbackInk: Color(0xFFC9A227),
                    tint: Color(0xFFC9A227),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    const box = Rect.fromLTWH(17, 17, 26, 26);
    var all = Rect.zero;
    for (var step = 0; step < 16; step++) {
      await tester.pump(const Duration(milliseconds: 125));
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = await tester.runAsync(() async {
        final image = await render.toImage(pixelRatio: 4);
        return (await image.toByteData())!;
      });
      var left = 240, top = 240, right = -1, bottom = -1;
      for (var y = 0; y < 240; y++) {
        for (var x = 0; x < 240; x++) {
          final i = (y * 240 + x) * 4;
          if ((bytes!.getUint8(i) - 0x80).abs() > 6 ||
              (bytes.getUint8(i + 1) - 0x80).abs() > 6 ||
              (bytes.getUint8(i + 2) - 0x80).abs() > 6) {
            if (x < left) left = x;
            if (x > right) right = x;
            if (y < top) top = y;
            if (y > bottom) bottom = y;
          }
        }
      }
      final painted = Rect.fromLTRB(
        left / 4,
        top / 4,
        (right + 1) / 4,
        (bottom + 1) / 4,
      );
      all = step == 0 ? painted : all.expandToInclude(painted);
      expect(
        box.inflate(0.5).contains(painted.topLeft) &&
            box.inflate(0.5).contains(painted.bottomRight),
        isTrue,
        reason: 'step $step: $painted outside $box',
      );
    }
    expect(all.width, greaterThan(24), reason: '$all');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('the "i" reads on the day card in every card colour; the file\'s '
      'grey reads on the night card', () {
    const white = Color(0xFFFFFFFF);
    expect(_contrast(const Color(0xFFACB6C3), white), lessThan(2.2));
    for (final category in const ['seen', 'blind', 'variation']) {
      final accent = AppTheme.paletteFor(
        levelTheme(dark: false).colorScheme,
        category: category,
        bootAmount: 200,
      ).accent;
      expect(
        _contrast(tintAt(infoWaveDayGlyph, accent), white),
        greaterThan(4.5),
        reason: category,
      );
    }
    expect(
      _contrast(const Color(0xFFACB6C3), const Color(0xFF23262A)),
      greaterThan(7),
    );
  });

  testWidgets('plays on through its parent rebuilding every second', (
    tester,
  ) async {
    await tester.runAsync(() => AssetLottie(infoWaveAsset).load());
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
            builder: (context, _) => InfoWave(
              size: 26,
              fallbackInk: const Color(0xFFC9A227),
              tint: const Color(0xFF7650CC),
            ),
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
    expect((progress() - before) % 1, closeTo(0.25, 0.03));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final dark in [true, false]) {
    testWidgets('every table card\'s info key carries it, in its card\'s '
        'colour, inside its disc, and still opens the card\'s info '
        '(${dark ? 'night' : 'day'})', (tester) async {
      primeBadges();
      final state = levelState(level: levelAt(10, xp: 4180))..config = _menu;
      await pumpLevelLobby(
        tester,
        state,
        screen: const Size(1280, 800),
        scale: 1.25,
        dark: dark,
      );
      expect(find.byType(InfoWave), findsNothing, reason: 'the front');
      for (final category in const ['seen', 'blind', 'variation']) {
        state.openLobbyCategory(category);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        final waves = tester.widgetList<InfoWave>(find.byType(InfoWave));
        expect(
          waves.length,
          state.lobbyTablesIn(category).length,
          reason: category,
        );
        final accent = AppTheme.paletteFor(
          levelTheme(dark: dark).colorScheme,
          category: category,
          bootAmount: 200,
        ).accent;
        for (final wave in waves) {
          expect(wave.tint, accent, reason: category);
        }
        expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
        // By day the "i" is the slate in the card's colour; by night the
        // file's own grey, tinted with the rest.
        for (final lottie in tester.widgetList<Lottie>(
          find.descendant(
            of: find.byType(InfoWave),
            matching: find.byType(Lottie),
          ),
        )) {
          final glyph = lottie.delegates!.values!.where(
            (d) => listEquals(d.keyPath, infoWaveGlyph),
          );
          if (dark) {
            expect(glyph, isEmpty, reason: category);
          } else {
            expect(glyph.map((d) => d.value).toSet(), {
              tintAt(infoWaveDayGlyph, accent),
            }, reason: category);
          }
        }
        for (final box in find.byKey(const ValueKey('info-wave')).evaluate()) {
          final rect = tester.getRect(find.byWidget(box.widget));
          expect(rect.width, 26, reason: 'inside the 28dp disc\'s hairline');
        }
        expect(tester.takeException(), isNull, reason: category);
      }
      await tester.tap(find.byKey(const ValueKey('info-wave')).first);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.textContaining(state.t.tableInfoTitle), findsWidgets);
      await unmountLevel(tester, state);
    });
  }
}
