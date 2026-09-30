// The owner's coins at the top left of the lobby's cards (29 Sep 2026): "use
// this animation in lobby cards on top left for coin and change color acc to
// card".
//
// assets/animations/Coins.json (widgets/card_coins.dart, over
// widgets/fact_mark.dart) stands beside each category card's name, where the
// two-chip pile was, and in each table card's badge, where the spinning chip
// was — in the card's colour, as the lock, the wallet, the piggy bank and the
// rule book are. These hold the file to what a phone can play and to the box
// the widget fits its whole loop into, the widget to playing on through the
// lobby's one-second rebuilds, and the lobby to drawing it in both places in
// each card's colour — the boot's own pile left as it was — with nothing on a
// card overflowing.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/card_coins.dart';
import 'package:teenpatti/widgets/poker_chip.dart';

import 'level_fixtures.dart';
import 'script_fonts.dart';

final _json =
    jsonDecode(File('assets/animations/Coins.json').readAsStringSync())
        as Map<String, dynamic>;

/// Where the painted pixels of [progress] lie on the file's canvas, drawn a
/// unit to a pixel over a mid grey.
Future<Rect> _paintedAt(LottieComposition comp, double progress) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(const Color(0xFF808080), BlendMode.src);
  LottieDrawable(comp)
    ..setProgress(progress)
    ..draw(canvas, const Rect.fromLTWH(0, 0, 800, 800));
  final image = await recorder.endRecording().toImage(800, 800);
  final pixels = (await image.toByteData())!;
  var left = 800, top = 800, right = -1, bottom = -1;
  for (var y = 0; y < 800; y += 2) {
    for (var x = 0; x < 800; x += 2) {
      final i = (y * 800 + x) * 4;
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
  return Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    right.toDouble(),
    bottom.toDouble(),
  );
}

/// Priya holds 60 Crore: some tables shut to her, some open.
final _menu = GameConfig.fromJson({
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'categories': ['seen', 'blind', 'variation'],
  'tables': [
    {'category': 'seen', 'bootAmount': 200},
    {'category': 'seen', 'bootAmount': 5000, 'maxChips': 50000000},
    {'category': 'blind', 'bootAmount': 200, 'maxChips': 2000000},
    {'category': 'blind', 'bootAmount': 50000, 'maxChips': 2000000000},
    {'category': 'blind', 'bootAmount': 2000000, 'minChips': 500000000},
    {'category': 'variation', 'bootAmount': 50000, 'maxChips': 2000000000},
    {'category': 'variation', 'bootAmount': 2000000, 'minChips': 500000000},
  ],
});

void main() {
  setUpAll(loadScriptFonts);

  group('the file', () {
    test('is 800 units square, two seconds a loop, and nothing a phone '
        'cannot play', () {
      expect(_json['w'], 800);
      expect(_json['h'], 800);
      expect((_json['op'] as num) / (_json['fr'] as num), 2);
      for (final layer in (_json['layers'] as List).cast<Map>()) {
        expect(layer['ddd'] ?? 0, 0, reason: 'no 3D layer');
      }
      expect(
        RegExp(r'"x":"').hasMatch(jsonEncode(_json)),
        isFalse,
        reason: 'no expressions',
      );
      for (final asset in (_json['assets'] as List).cast<Map>()) {
        expect(asset.containsKey('layers'), isTrue, reason: 'no images');
      }
    });

    testWidgets('its whole loop lies inside the box the widget fits it to, '
        'and fills its width', (tester) async {
      await tester.runAsync(() async {
        final comp = await LottieComposition.fromBytes(
          File('assets/animations/Coins.json').readAsBytesSync(),
        );
        final art = cardCoinsArt;
        final box = Rect.fromCenter(
          center: art.centre,
          width: art.extent,
          height: art.extent,
        ).inflate(2);
        var all = Rect.zero;
        for (var frame = 0; frame < 60; frame += 3) {
          final painted = await _paintedAt(comp, (frame + 0.5) / 60);
          all = frame == 0 ? painted : all.expandToInclude(painted);
          expect(
            box.contains(painted.topLeft) && box.contains(painted.bottomRight),
            isTrue,
            reason: 'frame $frame: $painted outside $box',
          );
        }
        expect(all.width, closeTo(art.extent, 6));
      });
    });
  });

  testWidgets('plays on through its parent rebuilding every second, in its '
      'card\'s colour', (tester) async {
    await tester.runAsync(() => AssetLottie(cardCoinsAsset).load());
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
            builder: (context, _) => CardCoins(
              size: 20,
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
    expect(widget.delegates, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final dark in [true, false]) {
    for (final screen in const [Size(640, 360), Size(1280, 800)]) {
      testWidgets('beside every category card\'s name and in every table '
          'card\'s badge, in its card\'s colour, the boot\'s pile kept '
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
        final scheme = levelTheme(dark: dark).colorScheme;
        Color accent(String category) => AppTheme.paletteFor(
          scheme,
          category: category,
          bootAmount: 200,
        ).accent;

        // The front: one pile of coins a category card, none of the old
        // piles.
        final front = tester
            .widgetList<CardCoins>(find.byType(CardCoins, skipOffstage: false))
            .toList();
        final colours = {
          for (final c in const ['seen', 'blind', 'variation']) accent(c),
        };
        expect(front, isNotEmpty);
        for (final c in front) {
          expect(colours, contains(c.tint), reason: 'the front');
        }
        if (screen.width >= 1280) {
          expect(front.map((c) => c.tint).toSet(), colours);
        }
        if (screen.width >= 1280) expect(front, hasLength(3));
        expect(find.byType(LivelyChipStack), findsNothing);
        expect(tester.takeException(), isNull, reason: 'the front');

        for (final category in const ['seen', 'blind', 'variation']) {
          state.openLobbyCategory(category);
          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 1));
          final coins = tester
              .widgetList<CardCoins>(find.byType(CardCoins))
              .toList();
          expect(coins, isNotEmpty, reason: category);
          for (final c in coins) {
            expect(c.tint, accent(category), reason: category);
          }
          // One in each table card's badge; the boot keeps its own pile.
          if (screen.width >= 1280) {
            final tables = state.lobbyTablesIn(category).length;
            expect(coins, hasLength(tables), reason: category);
            expect(
              find.byType(LivelyChipStack),
              findsNWidgets(tables),
              reason: category,
            );
          }
          expect(find.byType(SpinningChip), findsNothing, reason: category);
          expect(tester.takeException(), isNull, reason: category);
        }
        await unmountLevel(tester, state);
      });
    }
  }
}
