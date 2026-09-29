// The owner's piggy bank on the lobby's table cards (29 Sep 2026): "use this
// for piggy bank for card icon".
//
// assets/animations/Piggy Bank.json is played on the "Pot limit" row
// (widgets/pot_piggy.dart, over widgets/fact_mark.dart) in its own colours by
// night and with its near-white ground in the lock's blue by day, where the
// file's pale blues vanish into the white card. These hold the file to what a
// phone can play and to the ground the widget centres and recolours, the
// colours to a mark's contrast on both cards, the widget to playing on through
// the lobby's one-second rebuilds, and the lobby to drawing it on every Teen
// Patti table card — still where the table is shut.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/fact_mark.dart';
import 'package:teenpatti/widgets/pot_piggy.dart';

import 'level_fixtures.dart';
import 'script_fonts.dart';

final _json =
    jsonDecode(File('assets/animations/Piggy Bank.json').readAsStringSync())
        as Map<String, dynamic>;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

const _ground = Color(0xFFEBF4FF);
const _pig = Color(0xFFC2DFFF);
const _nightCard = Color(0xFF23262A);

/// The file drawn a unit to a pixel at [progress], recoloured for
/// [brightness], over [card].
Future<ByteData> _draw(
  LottieComposition comp,
  Brightness brightness,
  Color card,
) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawColor(card, BlendMode.src);
  final drawable = LottieDrawable(comp);
  final recolour = potPiggyArt.recolour!(brightness, (c) => c);
  if (recolour.isNotEmpty) {
    drawable.delegates = LottieDelegates(values: recolour);
  }
  drawable
    ..setProgress(0)
    ..draw(canvas, const Rect.fromLTWH(0, 0, 500, 500));
  final image = await recorder.endRecording().toImage(500, 500);
  return (await image.toByteData())!;
}

Color _at(ByteData pixels, int x, int y) {
  final i = (y * 500 + x) * 4;
  return Color.fromARGB(
    255,
    pixels.getUint8(i),
    pixels.getUint8(i + 1),
    pixels.getUint8(i + 2),
  );
}

/// Priya holds 60 Crore: Blind 200 (up to 20 Lakh) and Seen 5,000 (up to 5
/// Crore) are shut to her, the rest open.
final _menu = GameConfig.fromJson({
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'categories': ['seen', 'blind', 'variation'],
  'tables': [
    {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
    {'category': 'seen', 'bootAmount': 5000, 'maxChips': 50000000},
    {'category': 'blind', 'bootAmount': 200, 'maxChips': 2000000},
    {'category': 'blind', 'bootAmount': 50000, 'maxChips': 2000000000},
    {'category': 'blind', 'bootAmount': 2000000, 'minChips': 500000000},
    {'category': 'variation', 'bootAmount': 50000, 'maxChips': 2000000000},
    {'category': 'variation', 'bootAmount': 2000000, 'minChips': 500000000},
  ],
});

void main() {
  // Inter, as the app draws its words: the test font's em-wide glyphs
  // overflow a table card's facts at text x1.25.
  setUpAll(loadScriptFonts);

  group('the file', () {
    test('is 500 units square, a second a loop, and nothing a phone cannot '
        'play; its ground is the one layer "I", in #EBF4FF', () {
      expect(_json['w'], 500);
      expect(_json['h'], 500);
      expect((_json['op'] as num) / (_json['fr'] as num), closeTo(1, 0.002));
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
      final ground = layers.where((l) => l['nm'] == 'I').toList();
      expect(ground, hasLength(1));
      expect(potPiggyGround.first, 'I');
      expect(
        jsonEncode(ground.single['shapes']),
        contains('"k":[0.922,0.957,1,1]'),
      );
    });

    testWidgets('the ground is a circle 396 units across at the middle of '
        'the canvas, where the widget centres it; by day it is the lock\'s '
        'blue and the pig still its own', (tester) async {
      await tester.runAsync(() async {
        final comp = await LottieComposition.fromBytes(
          File('assets/animations/Piggy Bank.json').readAsBytesSync(),
        );
        final night = await _draw(comp, Brightness.dark, _nightCard);
        // Across the middle row, the ground runs from 52 to 447.
        int? left, right;
        for (var x = 0; x < 500; x++) {
          if (_at(night, x, 250) != _nightCard) {
            left ??= x;
            right = x;
          }
        }
        expect(left, 52);
        expect(right, 447);
        expect((left! + right!) / 2, potPiggyArt.centre.dx);
        expect(right - left + 1, potPiggyArt.extent);
        // Inside the ground, clear of the pig and the coins.
        expect(_at(night, 250, 70), _ground);

        final day = await _draw(comp, Brightness.light, Colors.white);
        expect(_at(day, 250, 70), potPiggyDayGround);
        expect(_at(day, 450, 250), Colors.white, reason: 'off the ground');
        // The pig's body is not recoloured.
        final pigPixels = <Color>{
          for (var x = 150; x < 350; x += 5) _at(day, x, 330),
        };
        expect(pigPixels, contains(_pig));
      });
    });

    test('by night the file stands clear of the card as it is; by day its '
        'pale blues do not, and the lock\'s blue does', () {
      final night = GlassColors.dark.cardFill.withValues(alpha: 1);
      expect(_contrast(_ground, night), greaterThan(10));
      const white = Color(0xFFFFFFFF);
      expect(_contrast(_ground, white), lessThan(1.5));
      expect(_contrast(_pig, white), lessThan(1.5));
      expect(_contrast(potPiggyDayGround, white), greaterThan(3));
      expect(_contrast(_pig, potPiggyDayGround), greaterThan(2.5));
    });
  });

  group('the widget', () {
    testWidgets('plays on through its parent rebuilding every second', (
      tester,
    ) async {
      await tester.runAsync(() => AssetLottie(potPiggyAsset).load());
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
                  PotPiggy(size: 16, fallbackInk: const Color(0xFFC9A227)),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final lottie = find.byType(Lottie);
      expect(lottie, findsOneWidget);
      final state = tester.state(lottie);
      final widget = tester.widget<Lottie>(lottie);
      double progress() =>
          tester.widget<RawLottie>(find.byType(RawLottie)).progress;

      await tester.pump(const Duration(milliseconds: 100));
      final before = progress();
      tick.value++;
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.state(lottie), same(state));
      expect(tester.widget<Lottie>(lottie), same(widget));
      // A quarter of a one-second loop, never back to its start.
      expect((progress() - before) % 1, closeTo(0.25, 0.03));
      expect(
        tester.getSize(find.byKey(const ValueKey('pot-piggy'))),
        const Size(16, 16),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('stands still, unfaded, on a table the player cannot sit at', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: PotPiggy(
              size: 16,
              fallbackInk: Color(0xFFC9A227),
              still: true,
            ),
          ),
        ),
      );
      expect(tester.widget<Lottie>(find.byType(Lottie)).animate, isFalse);
      expect(find.byType(Opacity), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('takes the lock\'s blue ground by day and none by night, '
        'and changes with the theme', (tester) async {
      final brightness = ValueNotifier(Brightness.light);
      addTearDown(brightness.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder(
          valueListenable: brightness,
          builder: (context, value, _) => Theme(
            data: ThemeData(brightness: value),
            child: const Directionality(
              textDirection: TextDirection.ltr,
              child: Center(
                child: PotPiggy(size: 16, fallbackInk: Color(0xFFC9A227)),
              ),
            ),
          ),
        ),
      );
      LottieDelegates? delegates() =>
          tester.widget<Lottie>(find.byType(Lottie)).delegates;
      final day = delegates()!.values!.single;
      expect(day.value, potPiggyDayGround);
      expect(day.keyPath, potPiggyGround);

      brightness.value = Brightness.dark;
      await tester.pump();
      expect(delegates(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  for (final dark in [true, false]) {
    for (final screen in const [Size(640, 360), Size(1280, 800)]) {
      testWidgets('the lobby draws it on every table card\'s Pot limit row, '
          'in the icon\'s place, still where the table is shut '
          '(${dark ? 'night' : 'day'}, ${screen.width.toInt()}x'
          '${screen.height.toInt()})', (tester) async {
        primeBadges();
        final state = levelState(level: levelAt(10, xp: 4180))..config = _menu;
        await pumpLevelLobby(
          tester,
          state,
          screen: screen,
          scale: 1.25,
          dark: dark,
        );
        expect(find.byType(PotPiggy), findsNothing, reason: 'the front');
        var sawStill = false, sawMoving = false;
        for (final category in const ['seen', 'blind', 'variation']) {
          state.openLobbyCategory(category);
          expect(state.lobbyCategory, category);
          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 1));
          final piggies = tester
              .widgetList<PotPiggy>(find.byType(PotPiggy))
              .toList();
          expect(piggies, isNotEmpty, reason: category);
          expect(
            find.byIcon(Icons.savings_rounded),
            findsNothing,
            reason: category,
          );
          final tables = state.lobbyTablesIn(category);
          expect(piggies.length, lessThanOrEqualTo(tables.length));
          if (screen.width >= 1280) {
            expect(piggies.length, tables.length, reason: category);
            expect(
              piggies.where((p) => p.still).length,
              tables.where(state.tableShut).length,
              reason: category,
            );
          }
          for (final piggy in piggies) {
            if (piggy.still) {
              sawStill = true;
            } else {
              sawMoving = true;
            }
          }
          // In the card's colour, and by day on a ground in that colour at
          // the lock blue's luminance.
          final accent = AppTheme.paletteFor(
            levelTheme(dark: dark).colorScheme,
            category: category,
            bootAmount: 200,
          ).accent;
          for (final piggy in piggies) {
            expect(piggy.tint, accent, reason: category);
          }
          for (final lottie in tester.widgetList<Lottie>(
            find.descendant(
              of: find.byType(PotPiggy),
              matching: find.byType(Lottie),
            ),
          )) {
            final ground = lottie.delegates!.values!.where(
              (d) => listEquals(d.keyPath, potPiggyGround),
            );
            if (dark) {
              expect(ground, isEmpty, reason: category);
            } else {
              expect(
                ground.single.value,
                tintAt(potPiggyDayGround, accent),
                reason: category,
              );
            }
          }
          for (final box
              in find.byKey(const ValueKey('pot-piggy')).evaluate()) {
            final row = find
                .ancestor(
                  of: find.byWidget(box.widget),
                  matching: find.byType(Row),
                )
                .first;
            expect(
              find.descendant(
                of: row,
                matching: find.text(state.t.potLimitLabel),
              ),
              findsOneWidget,
            );
            expect(
              tester.getSize(find.byWidget(box.widget)).width,
              inInclusiveRange(13, 19),
            );
          }
          expect(tester.takeException(), isNull, reason: category);
        }
        if (screen.width >= 1280) {
          expect(sawMoving, isTrue, reason: 'Priya can sit at some tables');
          expect(sawStill, isTrue, reason: 'and has outgrown others');
        }
        await unmountLevel(tester, state);
      });
    }
  }
}
