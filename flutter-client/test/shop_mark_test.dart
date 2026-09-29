// The owner's shop on the Shop key (29 Sep 2026): "use this icon for Shop".
//
// assets/animations/Shop.json builds a shopfront from an empty first frame,
// so widgets/shop_mark.dart plays it through once and then loops from frame
// 40 (FactMarkArt.loopFrom), never back to the blank start. These hold the
// file to that shape — empty at 0, built and still from 40 but for the
// window's glint, still from 61 — and to what a phone can play; the widget to
// building once, looping from 40 through the lobby's one-second rebuilds, and
// standing built when told to stand still; and the Shop key, lobby and table,
// to drawing it in the storefront icon's 19dp box with its tooltip kept.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/fact_mark.dart';
import 'package:teenpatti/widgets/shop_mark.dart';

import 'level_fixtures.dart';

final _json =
    jsonDecode(File('assets/animations/Shop.json').readAsStringSync())
        as Map<String, dynamic>;

const _grey = Color(0xFF808080);

/// Frame [frame] drawn a unit to two pixels over a mid grey, as raw RGBA.
Future<Uint8List> _frame(LottieComposition comp, double frame) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawColor(_grey, BlendMode.src);
  LottieDrawable(comp)
    ..setProgress((frame + 0.5) / 90)
    ..draw(canvas, const Rect.fromLTWH(0, 0, 500, 500));
  final image = await recorder.endRecording().toImage(500, 500);
  return (await image.toByteData(
    format: ui.ImageByteFormat.rawRgba,
  ))!.buffer.asUint8List();
}

bool _painted(Uint8List p, int i) =>
    (p[i] - 0x80).abs() > 6 ||
    (p[i + 1] - 0x80).abs() > 6 ||
    (p[i + 2] - 0x80).abs() > 6;

/// The painted pixels' bounds, in canvas units.
Rect? _bounds(Uint8List p) {
  var left = 500, top = 500, right = -1, bottom = -1;
  for (var y = 0; y < 500; y++) {
    for (var x = 0; x < 500; x++) {
      if (_painted(p, (y * 500 + x) * 4)) {
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
  }
  if (right < 0) return null;
  return Rect.fromLTRB(left * 2.0, top * 2.0, right * 2.0, bottom * 2.0);
}

/// The two frames differ in no more than a few pixels' anti-aliasing.
bool _same(Uint8List a, Uint8List b) {
  var differ = 0;
  for (var i = 0; i < a.length; i += 4) {
    final d =
        (a[i] - b[i]).abs() +
        (a[i + 1] - b[i + 1]).abs() +
        (a[i + 2] - b[i + 2]).abs();
    if (d > 30) differ++;
  }
  return differ <= 10;
}

void main() {
  group('the file', () {
    test('is 1000 units square, 90 frames at 29 fps, and nothing a phone '
        'cannot play', () {
      expect(_json['w'], 1000);
      expect(_json['h'], 1000);
      expect(_json['op'], 90);
      expect(_json['fr'], 29);
      for (final layer in (_json['layers'] as List).cast<Map>()) {
        expect(layer['ddd'] ?? 0, 0, reason: 'no 3D layer');
      }
      expect(
        RegExp(r'"x":"').hasMatch(jsonEncode(_json)),
        isFalse,
        reason: 'no expressions',
      );
      expect((_json['assets'] as List), isEmpty, reason: 'no images');
      expect(shopMarkArt.loopFrom, 40 / 90);
    });

    testWidgets('starts empty, is built by frame 40 — its window\'s glint '
        'drawing in by 61 — and still from 61, where the widget centres it', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final comp = await LottieComposition.fromBytes(
          File('assets/animations/Shop.json').readAsBytesSync(),
        );
        expect(_bounds(await _frame(comp, 0)), isNull, reason: 'empty');
        final built = await _frame(comp, 40);
        final shop = _bounds(built)!;
        expect(shop.center.dx, closeTo(shopMarkArt.centre.dx, 3));
        expect(shop.center.dy, closeTo(shopMarkArt.centre.dy, 3));
        expect(shop.width, closeTo(650, 6));
        // Frames 40 to 53 are the built shop, unchanged.
        expect(_same(await _frame(comp, 53), built), isTrue);
        // From 61 to the end nothing moves.
        final glinted = await _frame(comp, 61);
        expect(_same(glinted, built), isFalse, reason: 'the glint');
        expect(_same(await _frame(comp, 89), glinted), isTrue);
        expect(_bounds(glinted), shop);
      });
    });
  });

  group('the widget', () {
    testWidgets('builds the shop once, then loops from frame 40 through its '
        'parent\'s rebuilds, never back to the empty start', (tester) async {
      await tester.runAsync(() => AssetLottie(shopMarkAsset).load());
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
                  ShopMark(size: 19, fallbackInk: const Color(0xFF14171B)),
            ),
          ),
        ),
      );
      await tester.pump();
      double progress() =>
          tester.widget<RawLottie>(find.byType(RawLottie)).progress;
      expect(progress(), lessThan(0.05), reason: 'the build starts');
      final lottie = find.byType(Lottie);
      final state = tester.state(lottie);
      final loopFrom = shopMarkArt.loopFrom!;
      var sawGlintBuilding = false;
      // Past the build, and three loops more.
      for (var ms = 0; ms < 3200 + 3 * 1750; ms += 100) {
        await tester.pump(const Duration(milliseconds: 100));
        if (ms % 1000 == 0) tick.value++;
        if (ms > 3200) {
          expect(progress(), greaterThanOrEqualTo(loopFrom - 0.001));
          if (progress() < 60 / 90) sawGlintBuilding = true;
        }
      }
      expect(sawGlintBuilding, isTrue, reason: 'the loop replays the glint');
      expect(tester.state(lottie), same(state));
      expect(
        tester.getSize(find.byKey(const ValueKey('shop-mark'))),
        const Size(19, 19),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('told to stand still, stands built, not empty', (tester) async {
      await tester.runAsync(() => AssetLottie(shopMarkAsset).load());
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: FactMark(
              art: shopMarkArt,
              size: 19,
              fallbackInk: Color(0xFF14171B),
              boxKey: ValueKey('still-shop'),
              animate: false,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(tester.widget<RawLottie>(find.byType(RawLottie)).progress, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  for (final compact in [false, true]) {
    testWidgets('the Shop key draws it in the storefront icon\'s 19dp box'
        '${compact ? ', its tooltip kept, icon only' : ''}', (tester) async {
      await tester.runAsync(() => AssetLottie(shopMarkAsset).load());
      final state = levelState(level: levelAt(10, xp: 4180));
      final feedback = FeedbackSettings();
      addTearDown(feedback.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GameState>.value(value: state),
            ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
          ],
          child: MaterialApp(
            theme: levelTheme(dark: false),
            home: Scaffold(
              body: Center(child: ShopButton(compact: compact)),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final mark = find.descendant(
        of: find.byType(ShopButton),
        matching: find.byKey(const ValueKey('shop-mark')),
      );
      expect(mark, findsOneWidget);
      expect(tester.getSize(mark), const Size(19, 19));
      expect(find.byIcon(Icons.storefront_rounded), findsNothing);
      expect(
        find.byTooltip(state.t.shop),
        compact ? findsOneWidget : findsNothing,
      );
      expect(find.text(state.t.shop), compact ? findsNothing : findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 10));
      state.dispose();
    });
  }
}
