// The lobby cards' Lottie marks in the card's colour (owner, 29 Sep 2026:
// "change the wallet color and lock and piggy bank animation color acc to
// card, yellow, blue, purple, but keep the animation").
//
// widgets/fact_mark.dart lays the card's hue on every coloured part of a mark
// at that part's own luminance (tintAt). These hold the rule — the luminance,
// and so every contrast, kept; the hue the card's; whites left alone — and the
// marks to it as a phone draws them: the lock's disc and the wallet's
// gradient in the card's colour, a card of one colour sharing its callbacks
// with the others of that colour and never with another's, and the motion
// untouched.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/entry_wallet.dart';
import 'package:teenpatti/widgets/fact_mark.dart';
import 'package:teenpatti/widgets/open_lock.dart';
import 'package:teenpatti/widgets/pot_piggy.dart';

import 'level_fixtures.dart';

/// The accents of the three Teen Patti cards in [theme].
Map<String, Color> _accents(ThemeData theme) => {
  for (final category in const ['seen', 'blind', 'variation'])
    category: AppTheme.paletteFor(
      theme.colorScheme,
      category: category,
      bootAmount: 200,
    ).accent,
};

void main() {
  group('tintAt', () {
    const fileBlues = [
      Color(0xFF2987FF), // the lock's disc
      Color(0xFF81BCFE), // its circling copy
      Color(0xFF4088F4), // the wallet's deep end
      Color(0xFFB9DDFF), // its frosted front
      Color(0xFF027EFF), // the piggy bank's eyes
      Color(0xFFEBF4FF), // its ground
    ];
    for (final dark in [true, false]) {
      for (final MapEntry(key: category, value: accent) in _accents(
        levelTheme(dark: dark),
      ).entries) {
        test('keeps each blue\'s luminance in the $category card\'s hue '
            '(${dark ? 'night' : 'day'})', () {
          final hue = HSLColor.fromColor(accent).hue;
          for (final blue in fileBlues) {
            final tinted = tintAt(blue, accent);
            // The same luminance, to the 8 bits a channel a colour is stored
            // in: no contrast against anything moves by more than 1.5%.
            final y1 = tinted.computeLuminance() + 0.05;
            final y2 = blue.computeLuminance() + 0.05;
            expect(
              (y1 > y2 ? y1 / y2 : y2 / y1),
              lessThan(1.015),
              reason: '$blue → $tinted',
            );
            // The palest tones are rounded to 8 bits a channel; their hue
            // is the card's within a few degrees.
            final off = (HSLColor.fromColor(tinted).hue - hue).abs();
            expect(math360(off), lessThan(6), reason: '$blue → $tinted');
          }
        });
      }
    }

    test('leaves a white, a grey and a transparent alpha as they were', () {
      const gold = Color(0xFFC9A227);
      expect(tintAt(const Color(0xFFFFFFFF), gold), const Color(0xFFFFFFFF));
      expect(tintAt(const Color(0xFF808080), gold), const Color(0xFF808080));
      final half = tintAt(const Color(0x802987FF), gold);
      expect(half.a, closeTo(0x80 / 255, 0.001));
    });
  });

  testWidgets('a mark draws its card\'s colour — the lock\'s disc, the '
      'wallet\'s gradient — and keeps its motion', (tester) async {
    await tester.runAsync(() async {
      for (final asset in [openLockAsset, entryWalletAsset, potPiggyAsset]) {
        await AssetLottie(asset).load();
      }
    });
    const violet = Color(0xFF7650CC);
    final boundary = GlobalKey();
    tester.view.physicalSize = const Size(400, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: boundary,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(40),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OpenLock(size: 100, fallbackInk: Colors.red, tint: violet),
                  SizedBox(width: 60),
                  EntryWallet(
                    size: 100,
                    fallbackInk: Colors.red,
                    tint: violet,
                    still: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final lock = find.byType(OpenLock);
    final progress = tester
        .widget<RawLottie>(
          find.descendant(of: lock, matching: find.byType(RawLottie)),
        )
        .progress;
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      tester
          .widget<RawLottie>(
            find.descendant(of: lock, matching: find.byType(RawLottie)),
          )
          .progress,
      isNot(progress),
      reason: 'the lock still plays',
    );

    final pixels = await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    final width = tester.getSize(find.byKey(boundary)).width.toInt();
    Color at(Offset p) {
      final i = (p.dy.toInt() * width + p.dx.toInt()) * 4;
      return Color.fromARGB(
        255,
        pixels!.getUint8(i),
        pixels.getUint8(i + 1),
        pixels.getUint8(i + 2),
      );
    }

    final origin = tester.getTopLeft(find.byKey(boundary));
    // The lock's disc, just inside its left edge, level with its middle:
    // blue there in the file, violet here.
    final disc = tester.getRect(find.byKey(const ValueKey('open-lock')));
    final onDisc = at(disc.centerLeft - origin + const Offset(6, 0));
    expect(
      onDisc.computeLuminance(),
      closeTo(const Color(0xFF2987FF).computeLuminance(), 0.02),
    );
    expect(
      (HSLColor.fromColor(onDisc).hue - HSLColor.fromColor(violet).hue).abs(),
      lessThan(4),
      reason: '$onDisc',
    );
    // The wallet's back, where its gradient shows at rest, is violet too, and
    // nowhere in the wallet's box is the file's blue left.
    final wallet = tester.getRect(find.byKey(const ValueKey('entry-wallet')));
    var violetSeen = false;
    for (var x = wallet.left; x < wallet.right; x += 3) {
      for (var y = wallet.top; y < wallet.bottom; y += 3) {
        final c = at(Offset(x, y) - origin);
        final hsl = HSLColor.fromColor(c);
        if (hsl.saturation < 0.25) continue;
        final hue = hsl.hue;
        expect(
          hue >= 190 && hue <= 225,
          isFalse,
          reason: 'the file\'s blue at ($x, $y): $c',
        );
        if ((hue - HSLColor.fromColor(violet).hue).abs() < 6) {
          violetSeen = true;
        }
      }
    }
    expect(violetSeen, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cards of one colour share their callbacks, and a card of '
      'another colour never does', (tester) async {
    Widget mark(Color? tint) =>
        EntryWallet(size: 16, fallbackInk: Colors.red, tint: tint);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            mark(const Color(0xFFC9A227)),
            mark(const Color(0xFFC9A227)),
            mark(const Color(0xFF7650CC)),
            mark(null),
          ],
        ),
      ),
    );
    final delegates = [
      for (final l in tester.widgetList<Lottie>(find.byType(Lottie)))
        l.delegates?.values,
    ];
    expect(identical(delegates[0], delegates[1]), isTrue);
    expect(identical(delegates[0], delegates[2]), isFalse);
    expect(delegates[3], isNull, reason: 'the file\'s own colours');
    // The wallet's gradient is given, tinted, as its stops.
    final gradient = delegates[2]!.firstWhere((d) => d.value is List<Color>);
    expect(gradient.value, [
      for (final c in entryWalletGradient) tintAt(c, const Color(0xFF7650CC)),
    ]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// A difference between two hues, the short way round the wheel.
double math360(double d) => d > 180 ? 360 - d : d;
