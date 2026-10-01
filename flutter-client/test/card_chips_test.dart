// The owner's casino chips at the top left of the lobby's cards (1 Oct 2026):
// "Use this animation on top left of lobby cards, change colour acc to card".
//
// assets/animations/Casino Chips.json (widgets/card_chips.dart, over
// widgets/fact_mark.dart) stands beside each category card's name and in each
// table card's badge, where the owner's coins stood from 29 Sep 2026 — in the
// card's colour, as the lock, the wallet, the piggy bank and the rule book
// are. These hold the file to what a phone can play and to the box the widget
// fits its whole loop into, the chips to the card's colour with their white
// faces kept, the widget to playing on through the lobby's one-second
// rebuilds, and the lobby to drawing it in both places in each card's colour —
// the boot's own pile left as it was — with nothing on a card overflowing.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/card_chips.dart';
import 'package:teenpatti/widgets/poker_chip.dart';

import 'level_fixtures.dart';
import 'script_fonts.dart';

final _json =
    jsonDecode(File('assets/animations/Casino Chips.json').readAsStringSync())
        as Map<String, dynamic>;

/// Where the painted pixels of [progress] lie on the file's canvas, drawn a
/// unit to a pixel over a mid grey.
Future<Rect?> _paintedAt(LottieComposition comp, double progress) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(const Color(0xFF808080), BlendMode.src);
  LottieDrawable(comp)
    ..setProgress(progress)
    ..draw(canvas, const Rect.fromLTWH(0, 0, 400, 400), fit: BoxFit.fill);
  final image = await recorder.endRecording().toImage(400, 400);
  final pixels = (await image.toByteData())!;
  image.dispose();
  var left = 400, top = 400, right = -1, bottom = -1;
  for (var y = 0; y < 400; y++) {
    for (var x = 0; x < 400; x++) {
      final i = (y * 400 + x) * 4;
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
  if (right < 0) return null;
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
    test('is 400 units square, four seconds a loop, and nothing a phone '
        'cannot play', () {
      expect(_json['w'], 400);
      expect(_json['h'], 400);
      expect((_json['op'] as num) / (_json['fr'] as num), closeTo(4.03, 0.01));
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
        'fills its height, and stands built from 1.75 s', (tester) async {
      await tester.runAsync(() async {
        final comp = await LottieComposition.fromBytes(
          File('assets/animations/Casino Chips.json').readAsBytesSync(),
        );
        final art = cardChipsArt;
        final box = Rect.fromCenter(
          center: art.centre,
          width: art.extent,
          height: art.extent,
        ).inflate(2);
        final frames = (_json['op'] as num).toInt();
        Rect? all;
        Rect? standing;
        for (var frame = 0; frame < frames; frame++) {
          final painted = await _paintedAt(comp, (frame + 0.5) / frames);
          if (painted == null) {
            expect(frame, 0, reason: 'only the loop\'s first frame is empty');
            continue;
          }
          all = all?.expandToInclude(painted) ?? painted;
          expect(
            box.contains(painted.topLeft) && box.contains(painted.bottomRight),
            isTrue,
            reason: 'frame $frame: $painted outside $box',
          );
          if (frame >= 53) {
            standing ??= painted;
            expect(painted, standing, reason: 'frame $frame stands still');
          }
        }
        expect(all!.height, closeTo(art.extent, 3));
        expect(all.center.dx, closeTo(art.centre.dx, 3));
        // The standing stack: 0.92 of the box tall, 0.52 of it wide.
        expect(standing!.height / art.extent, closeTo(0.92, 0.01));
        expect(standing.width / art.extent, closeTo(0.52, 0.01));
      });
    });
  });

  testWidgets('the chips\' golds take the card\'s colour and their white '
      'faces stay white', (tester) async {
    await tester.runAsync(() => AssetLottie(cardChipsAsset).load());
    const violet = Color(0xFF7650CC);
    final boundary = GlobalKey();
    tester.view.physicalSize = const Size(300, 300);
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
              child: const CardChips(
                size: 160,
                fallbackInk: Colors.red,
                tint: violet,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // Two seconds in, the stack stands built.
    await tester.pump(const Duration(seconds: 2));
    final pixels = await tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!;
    });
    final width = tester.getSize(find.byKey(boundary)).width.toInt();
    final origin = tester.getTopLeft(find.byKey(boundary));
    final chips = tester.getRect(find.byKey(const ValueKey('card-chips')));
    var violetSeen = 0, whiteSeen = 0;
    for (var x = chips.left; x < chips.right; x += 2) {
      for (var y = chips.top; y < chips.bottom; y += 2) {
        final p = Offset(x, y) - origin;
        final i = (p.dy.toInt() * width + p.dx.toInt()) * 4;
        final c = Color.fromARGB(
          255,
          pixels!.getUint8(i),
          pixels.getUint8(i + 1),
          pixels.getUint8(i + 2),
        );
        final hsl = HSLColor.fromColor(c);
        if (hsl.saturation < 0.25) {
          if (hsl.lightness > 0.85 && hsl.lightness < 0.99) whiteSeen++;
          continue;
        }
        expect(
          hsl.hue >= 30 && hsl.hue <= 65,
          isFalse,
          reason: 'the file\'s gold at ($x, $y): $c',
        );
        if ((hsl.hue - HSLColor.fromColor(violet).hue).abs() < 6) {
          violetSeen++;
        }
      }
    }
    expect(violetSeen, greaterThan(50));
    expect(whiteSeen, greaterThan(50), reason: 'the chips\' white faces');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('plays on through its parent rebuilding every second, in its '
      'card\'s colour', (tester) async {
    await tester.runAsync(() => AssetLottie(cardChipsAsset).load());
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
            builder: (context, _) => CardChips(
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
    final loop = (_json['op'] as num) / (_json['fr'] as num);
    expect((progress() - before) % 1, closeTo(0.5 / loop, 0.03));
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

        // The front: one stack of chips a category card, none of the old
        // piles.
        final front = tester
            .widgetList<CardChips>(find.byType(CardChips, skipOffstage: false))
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
          final chips = tester
              .widgetList<CardChips>(find.byType(CardChips))
              .toList();
          expect(chips, isNotEmpty, reason: category);
          for (final c in chips) {
            expect(c.tint, accent(category), reason: category);
          }
          // One in each table card's badge; the boot keeps its own pile.
          if (screen.width >= 1280) {
            final tables = state.lobbyTablesIn(category).length;
            expect(chips, hasLength(tables), reason: category);
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
