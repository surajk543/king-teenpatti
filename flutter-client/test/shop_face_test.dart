// The Shop key's ice face (owner, 30 Sep 2026: "The Shop button background
// colour yellow does not look good with blue icon, change yellow to something
// else which looks good in day and night mode both").
//
// The key (widgets/buy_chips.dart ShopButton — the lobby's top bar and the
// table's top-left corner) was struck gold under the owner's shop Lottie,
// which is stroked in #1365E8 and filled in white and pale blues. It now wears
// the ice that shop was drawn for (ShopFace): a white-to-pale-blue face, a rim
// in the icon's blue, the word in a deeper blue, a blue bloom. These hold the
// colours to what can be read — the word 4.5:1 and the icon 3:1 on every stop
// of both faces, the day rim 3:1 against the pale grounds it stands on — the
// widget to wearing them in both themes, compact or not, at exactly the size
// the gold key had, and the rendered key to a rim and a shadow that part it
// from the light bar and a face that stands clear of the night one.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/glass_components.dart';
import 'package:teenpatti/widgets/shop_mark.dart';
import 'package:teenpatti/widgets/table_ground.dart';

import 'level_fixtures.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

/// Every colour the owner's shop is stroked and filled in.
Set<Color> _fileColours(String type) {
  final json =
      jsonDecode(File('assets/animations/Shop.json').readAsStringSync())
          as Map<String, dynamic>;
  final found = <Color>{};
  void walk(Object? o) {
    if (o is Map) {
      if (o['ty'] == type && o['c'] is Map) {
        final k = (o['c'] as Map)['k'];
        if (k is List && k.length >= 3 && k.every((v) => v is num)) {
          int c(Object v) => ((v as num) * 255).round();
          found.add(Color.fromARGB(255, c(k[0]), c(k[1]), c(k[2])));
        }
      }
      o.values.forEach(walk);
    } else if (o is List) {
      o.forEach(walk);
    }
  }

  walk(json);
  return found;
}

/// The pale grounds the key stands on by day: the lobby's ground behind its
/// top bar, the table's pearl room, and plain white (the lightest a bar can be).
const _dayGrounds = [AppTheme.bone100, TableGround.pearl, Color(0xFFFFFFFF)];

/// The dark grounds by night: the lobby's obsidian and the vignette's close.
const _nightGrounds = [AppTheme.ink800, AppTheme.ink900];

Future<void> _pumpKey(
  WidgetTester tester, {
  required bool dark,
  required bool compact,
  Color? ground,
  GlobalKey? boundary,
}) async {
  await tester.runAsync(() => AssetLottie(shopMarkAsset).load());
  final state = levelState(level: levelAt(10, xp: 4180));
  final feedback = FeedbackSettings();
  addTearDown(() {
    state.dispose();
    feedback.dispose();
  });
  tester.view.physicalSize = const Size(300, 120);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final bg = ground ?? (dark ? AppTheme.ink800 : AppTheme.bone100);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        theme: levelTheme(dark: dark),
        home: Scaffold(
          backgroundColor: bg,
          body: RepaintBoundary(
            key: boundary,
            child: ColoredBox(
              color: bg,
              child: Center(child: ShopButton(compact: compact)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
}

/// The key drawn at [ratio] pixels a dp, as raw RGBA, with the sweep resting
/// off its edge (the capture is taken three seconds into its six-second
/// cycle, where it has long crossed).
Future<(Uint8List, int)> _capture(
  WidgetTester tester,
  GlobalKey boundary,
  double ratio,
) async {
  await tester.pump(const Duration(milliseconds: 3000));
  late Uint8List bytes;
  late int width;
  await tester.runAsync(() async {
    final box =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await box.toImage(pixelRatio: ratio);
    width = image.width;
    bytes = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    image.dispose();
  });
  return (bytes, width);
}

Color _pixel(Uint8List p, int width, double x, double y) {
  final i = (y.round() * width + x.round()) * 4;
  return Color.fromARGB(255, p[i], p[i + 1], p[i + 2]);
}

void main() {
  setUpAll(() => loadLevelFonts());

  group('the colours', () {
    test('the face is built round the icon: the shop is stroked in exactly '
        'the blue the rim and the bloom are laid in', () {
      expect(_fileColours('st'), {ShopFace.iconBlue});
      expect(ShopFace.iconBlue, const Color(0xFF1365E8));
      // Every fill is white, a pale blue or that blue: no gold in the file.
      expect(_fileColours('fl'), {
        const Color(0xFFFFFFFF),
        const Color(0xFFBAD8FF),
        const Color(0xFF7DB7FF),
        ShopFace.iconBlue,
      });
    });

    for (final b in Brightness.values) {
      final name = b == Brightness.dark ? 'night' : 'day';
      test('the word "Shop" stands 4.5:1 on every stop of the $name face', () {
        for (final stop in ShopFace.face(b).colors) {
          expect(
            _contrast(ShopFace.ink, stop),
            greaterThanOrEqualTo(4.5),
            reason: '$stop',
          );
        }
      });

      test(
        'the icon\'s #1365E8 stands 3:1 on every stop of the $name face',
        () {
          for (final stop in ShopFace.face(b).colors) {
            expect(
              _contrast(ShopFace.iconBlue, stop),
              greaterThanOrEqualTo(3),
              reason: '$stop',
            );
          }
        },
      );

      test('the $name face is ice, not gold: white to pale blue, lit at the '
          'top', () {
        final face = ShopFace.face(b);
        expect(face, isNot(AppTheme.goldFace));
        expect(face.colors, hasLength(3));
        for (final stop in face.colors) {
          // Blue leads every stop; no warm stop is left in it.
          expect(stop.b, greaterThanOrEqualTo(stop.g), reason: '$stop');
          expect(stop.g, greaterThanOrEqualTo(stop.r), reason: '$stop');
        }
        // Lightest at the top, darkest at the foot.
        final l = [for (final c in face.colors) c.computeLuminance()];
        expect(l[0], greaterThan(l[1]));
        expect(l[1], greaterThan(l[2]));
      });

      test('the $name key casts a blue bloom, never a gold one', () {
        final shadows = ShopFace.shadows(b);
        final coloured = [
          for (final s in shadows)
            if (s.color.r != s.color.g || s.color.g != s.color.b) s.color,
        ];
        // Every coloured shadow is the icon's blue; the rest are neutral.
        expect(coloured, isNotEmpty);
        for (final c in coloured) {
          if (c.withValues(alpha: 1) == ShopFace.iconBlue) continue;
          // The day's slate contact shadow: a cool neutral, never warm.
          expect(c.b, greaterThanOrEqualTo(c.r), reason: '$c');
        }
        expect(
          shadows.any((s) => s.color.withValues(alpha: 1) == ShopFace.iconBlue),
          isTrue,
        );
        expect(
          shadows.any(
            (s) =>
                s.color.withValues(alpha: 1) ==
                AppTheme.gold.withValues(alpha: 1),
          ),
          isFalse,
        );
      });
    }

    test('by day the rim parts the key from every pale ground 3:1, over every '
        'stop of the face it is laid on', () {
      final rim = ShopFace.rim(Brightness.light);
      for (final stop in ShopFace.face(Brightness.light).colors) {
        final seen = Color.alphaBlend(rim, stop);
        for (final ground in _dayGrounds) {
          expect(
            _contrast(seen, ground),
            greaterThanOrEqualTo(3),
            reason: 'rim over $stop on $ground',
          );
        }
      }
    });

    test('by night the face stands clear of the obsidian, a step down from the '
        'day\'s ice so it does not glare', () {
      final night = ShopFace.face(Brightness.dark).colors;
      final day = ShopFace.face(Brightness.light).colors;
      for (var i = 0; i < 3; i++) {
        expect(
          night[i].computeLuminance(),
          lessThan(day[i].computeLuminance()),
          reason: 'stop $i',
        );
        for (final ground in _nightGrounds) {
          expect(
            _contrast(night[i], ground),
            greaterThanOrEqualTo(7),
            reason: '${night[i]} on $ground',
          );
        }
      }
      // The rim is quieter by night, where the face is its own edge.
      expect(
        ShopFace.rim(Brightness.dark).a,
        lessThan(ShopFace.rim(Brightness.light).a),
      );
    });
  });

  group('the key', () {
    for (final dark in [false, true]) {
      for (final compact in [false, true]) {
        final b = dark ? Brightness.dark : Brightness.light;
        testWidgets('wears the ice face, rim and blue lift '
            '(${dark ? 'night' : 'day'}${compact ? ', compact' : ''}), at the '
            'gold key\'s size', (tester) async {
          await _pumpKey(tester, dark: dark, compact: compact);
          final key = find.byType(ShopButton);
          final face = tester.widget<Ink>(
            find.descendant(
              of: key,
              matching: find.byKey(const ValueKey('shop-key-face')),
            ),
          );
          final faceBox = face.decoration! as BoxDecoration;
          expect(faceBox.gradient, ShopFace.face(b));
          expect(faceBox.gradient, isNot(AppTheme.goldFace));

          final rim = tester.widget<DecoratedBox>(
            find.byKey(const ValueKey('shop-key-rim')),
          );
          expect(rim.position, DecorationPosition.foreground);
          final border = (rim.decoration as BoxDecoration).border! as Border;
          expect(border.top.color, ShopFace.rim(b));
          expect(border.left.color, ShopFace.rim(b));
          expect(border.bottom.width, ShopFace.rimWidth);
          expect(ShopFace.rimWidth, 1.5);

          final lift = tester.widget<DecoratedBox>(
            find.byKey(const ValueKey('shop-key-lift')),
          );
          expect(
            (lift.decoration as BoxDecoration).boxShadow,
            ShopFace.shadows(b),
          );

          // The pressed state is as it was: the press-down and the splash.
          expect(
            find.descendant(of: key, matching: find.byType(PressScale)),
            findsOneWidget,
          );
          final well = tester.widget<InkWell>(
            find.descendant(of: key, matching: find.byType(InkWell)),
          );
          expect(well.splashColor, AppTheme.inkOnLight.withValues(alpha: 0.16));
          expect(
            well.highlightColor,
            AppTheme.inkOnLight.withValues(alpha: 0.08),
          );

          final t = tester.element(key).read<GameState>().t;
          if (compact) {
            expect(find.byTooltip(t.shop), findsOneWidget);
            expect(find.text(t.shop), findsNothing);
            // The storefront's box and the key's padding, as before; the rim
            // is painted over the face and takes no room.
            expect(
              tester.getSize(key),
              const Size(19 + 2 * Space.md, Dim.minTouch + 1),
            );
          } else {
            final word = tester.widget<Text>(find.text(t.shop));
            expect(word.style!.color, ShopFace.ink);
            expect(word.style!.fontWeight, FontWeight.w700);
            expect(tester.getSize(key).height, Dim.minTouch + 1);
          }
          expect(tester.takeException(), isNull);
          await _unmount(tester);
        });
      }
    }
  });

  group('the key as drawn', () {
    for (final ground in _dayGrounds.take(2)) {
      testWidgets('on the pale ground $ground its rim and its shadow part it '
          'from the bar', (tester) async {
        // The test binding draws every shadow as a solid block unless told
        // not to; this one wants them as a phone draws them.
        debugDisableShadows = false;
        try {
          final boundary = GlobalKey();
          await _pumpKey(
            tester,
            dark: false,
            compact: false,
            ground: ground,
            boundary: boundary,
          );
          const ratio = 4.0;
          final rect = tester.getRect(find.byType(ShopButton));
          final (p, width) = await _capture(tester, boundary, ratio);
          // The rim where the pill's end is upright: its middle row, the
          // middle of the 1.5dp stroke.
          final rim = _pixel(
            p,
            width,
            (rect.left + ShopFace.rimWidth / 2) * ratio,
            rect.center.dy * ratio,
          );
          expect(
            _contrast(rim, ground),
            greaterThanOrEqualTo(2.8),
            reason: '$rim',
          );
          // Just under the key, the contact shadow darkens the bar.
          final under = _pixel(
            p,
            width,
            rect.center.dx * ratio,
            (rect.bottom + 1.5) * ratio,
          );
          expect(
            ground.computeLuminance() - under.computeLuminance(),
            greaterThan(0.08),
            reason: '$under under the key on $ground',
          );
          // Far from it, the bar is untouched.
          final far = _pixel(p, width, 4 * ratio, 4 * ratio);
          expect(far, ground);
          await _unmount(tester);
        } finally {
          debugDisableShadows = true;
        }
      });
    }

    testWidgets('on the night bar the face stands clear and its bloom is blue, '
        'with no gold anywhere on the key', (tester) async {
      debugDisableShadows = false;
      try {
        final boundary = GlobalKey();
        await _pumpKey(
          tester,
          dark: true,
          compact: false,
          ground: AppTheme.ink800,
          boundary: boundary,
        );
        const ratio = 4.0;
        final rect = tester.getRect(find.byType(ShopButton));
        final (p, width) = await _capture(tester, boundary, ratio);
        // The face over the word, inside the rim and the lit top edge.
        final face = _pixel(
          p,
          width,
          rect.center.dx * ratio,
          (rect.top + 3) * ratio,
        );
        expect(_contrast(face, AppTheme.ink800), greaterThanOrEqualTo(7));
        // Beyond the key's end the bloom tints the obsidian blue.
        final bloom = _pixel(
          p,
          width,
          rect.center.dx * ratio,
          (rect.bottom + 4) * ratio,
        );
        expect(bloom.b, greaterThan(bloom.r), reason: '$bloom');
        // No pixel of the key is gold: warm, saturated, red over blue.
        var gold = 0;
        for (var y = rect.top; y < rect.bottom; y += 0.5) {
          for (var x = rect.left; x < rect.right; x += 0.5) {
            final c = _pixel(p, width, x * ratio, y * ratio);
            final r = (c.r * 255).round();
            final g = (c.g * 255).round();
            final bl = (c.b * 255).round();
            if (r > 150 && g > 100 && bl < 90 && r - bl > 80) gold++;
          }
        }
        expect(gold, 0);
        await _unmount(tester);
      } finally {
        debugDisableShadows = true;
      }
    });
  });
}
