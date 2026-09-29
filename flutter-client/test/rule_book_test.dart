// The owner's rule book on the lobby's table cards (29 Sep 2026): "use this
// icon for rule book on card".
//
// assets/animations/Rule Book.json plays in the table card's rules key
// (widgets/rule_book.dart, over widgets/fact_mark.dart), in the card's colour
// as the lock, the wallet and the piggy bank are. These hold the file to what
// a phone can play and to the extent the widget fits into the key's disc, the
// widget to playing on through the lobby's one-second rebuilds, and the lobby
// to drawing it — in each card's colour, inside its disc — on every Teen
// Patti table card's rules key, which still opens that table's rules.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/rule_book.dart';

import 'level_fixtures.dart';
import 'script_fonts.dart';

final _json =
    jsonDecode(File('assets/animations/Rule Book.json').readAsStringSync())
        as Map<String, dynamic>;

/// Where the painted pixels of [progress] lie on the file's canvas, drawn a
/// unit to a pixel over a mid grey (the book's shadow is near-black and its
/// pages white).
Future<Rect> _paintedAt(LottieComposition comp, double progress) async {
  const ground = Color(0xFF808080);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawColor(ground, BlendMode.src);
  LottieDrawable(comp)
    ..setProgress(progress)
    ..draw(canvas, const Rect.fromLTWH(0, 0, 500, 500));
  final image = await recorder.endRecording().toImage(500, 500);
  final pixels = (await image.toByteData())!;
  var left = 500, top = 500, right = -1, bottom = -1;
  for (var y = 0; y < 500; y++) {
    for (var x = 0; x < 500; x++) {
      final i = (y * 500 + x) * 4;
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
    {'category': 'variation', 'bootAmount': 50000, 'maxChips': 2000000000},
  ],
});

void main() {
  setUpAll(loadScriptFonts);

  group('the file', () {
    test('is 500 units square, two seconds a loop, and nothing a phone '
        'cannot play', () {
      expect(_json['w'], 500);
      expect(_json['h'], 500);
      expect((_json['op'] as num) / (_json['fr'] as num), 2);
      for (final layer in (_json['layers'] as List).cast<Map>()) {
        expect(layer['ddd'] ?? 0, 0, reason: 'no 3D layer');
      }
      expect(
        RegExp(r'"x":"').hasMatch(jsonEncode(_json)),
        isFalse,
        reason: 'no expressions',
      );
      expect((_json['assets'] as List), isEmpty, reason: 'no images');
    });

    testWidgets('its whole loop — the hop, the pages, the shadow — lies '
        'inside the box the widget fits it to', (tester) async {
      await tester.runAsync(() async {
        final comp = await LottieComposition.fromBytes(
          File('assets/animations/Rule Book.json').readAsBytesSync(),
        );
        final art = ruleBookArt;
        final box = Rect.fromCenter(
          center: art.centre,
          width: art.extent,
          height: art.extent,
        );
        var all = Rect.zero;
        for (var frame = 0; frame < 60; frame += 3) {
          final painted = await _paintedAt(comp, frame / 60);
          all = frame == 0 ? painted : all.expandToInclude(painted);
          expect(
            box.inflate(1).contains(painted.topLeft) &&
                box.inflate(1).contains(painted.bottomRight),
            isTrue,
            reason: 'frame $frame: $painted outside $box',
          );
        }
        // And it fills the box's height, so the book is as large as the key
        // lets it be.
        expect(all.height, closeTo(art.extent, 6));
      });
    });
  });

  testWidgets('plays on through its parent rebuilding every second', (
    tester,
  ) async {
    await tester.runAsync(() => AssetLottie(ruleBookAsset).load());
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
            builder: (context, _) => RuleBook(
              size: 22,
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
    expect(widget.animate, isTrue);
    expect(widget.delegates, isNotNull, reason: 'in the card\'s colour');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final dark in [true, false]) {
    testWidgets('every table card\'s rules key carries it, in its card\'s '
        'colour, inside its disc, and still opens that table\'s rules '
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
      expect(find.byType(RuleBook), findsNothing, reason: 'the front');
      for (final category in const ['seen', 'blind', 'variation']) {
        state.openLobbyCategory(category);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        final books = tester.widgetList<RuleBook>(find.byType(RuleBook));
        expect(
          books.length,
          state.lobbyTablesIn(category).length,
          reason: category,
        );
        final accent = AppTheme.paletteFor(
          levelTheme(dark: dark).colorScheme,
          category: category,
          bootAmount: 200,
        ).accent;
        for (final book in books) {
          expect(book.tint, accent, reason: category);
        }
        expect(
          find.byIcon(Icons.menu_book_outlined),
          findsNothing,
          reason: category,
        );
        // Inside the key's 28dp disc, centred on it.
        for (final box in find.byKey(const ValueKey('rule-book')).evaluate()) {
          final rect = tester.getRect(find.byWidget(box.widget));
          expect(rect.width, 22);
          final disc = tester.getRect(
            find
                .ancestor(
                  of: find.byWidget(box.widget),
                  matching: find.byWidgetPredicate(
                    (w) =>
                        w is Container &&
                        w.decoration is BoxDecoration &&
                        (w.decoration! as BoxDecoration).shape ==
                            BoxShape.circle,
                  ),
                )
                .first,
          );
          expect(disc.width, 28);
          expect((rect.center - disc.center).distance, lessThan(0.5));
        }
        expect(tester.takeException(), isNull, reason: category);
      }
      // A tap on the book is a tap on the key: the rules of that table.
      await tester.tap(find.byKey(const ValueKey('rule-book')).first);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text(state.t.tableRulesTitle), findsOneWidget);
      await unmountLevel(tester, state);
    });
  }
}
