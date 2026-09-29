// The owner's wallet on the lobby's table cards (29 Sep 2026): "The Entry
// icon on table card use this animation".
//
// assets/animations/Wallet.json is played in its own colours
// (widgets/entry_wallet.dart, over widgets/fact_mark.dart, which the "Open to
// you" lock shares). These hold the file to what a phone can play and to the
// rest pose the widget centres, its blue to a mark's contrast on both cards,
// the widget to playing on through the lobby's one-second rebuilds, and the
// lobby to drawing it on every table card's Entry row — still on a table the
// player cannot sit at.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/entry_wallet.dart';

import 'level_fixtures.dart';
import 'script_fonts.dart';

final _json =
    jsonDecode(File('assets/animations/Wallet.json').readAsStringSync())
        as Map<String, dynamic>;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Where the painted pixels of [progress] lie on the file's canvas, drawn a
/// unit to a pixel over [ground].
Future<Rect> _paintedAt(LottieComposition comp, double progress) async {
  const ground = Color(0xFF23262A);
  const side = 1080;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..drawColor(ground, BlendMode.src);
  final drawable = LottieDrawable(comp)..setProgress(progress);
  drawable.draw(canvas, const Rect.fromLTWH(0, 0, 1080, 1080));
  final image = await recorder.endRecording().toImage(side, side);
  final pixels = (await image.toByteData())!;
  var left = side, top = side, right = -1, bottom = -1;
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final i = (y * side + x) * 4;
      final r = pixels.getUint8(i), g = pixels.getUint8(i + 1);
      final b = pixels.getUint8(i + 2);
      if ((r - 0x23).abs() > 6 ||
          (g - 0x26).abs() > 6 ||
          (b - 0x2A).abs() > 6) {
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

/// Priya holds 60 Crore: Blind 200 (up to 20 Lakh) and Seen 5,000 (up to 5
/// Crore) are shut to her, the rest open.
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
  // Inter, as the app draws its words: the test font's em-wide glyphs
  // overflow a table card's facts at text x1.25.
  setUpAll(loadScriptFonts);

  group('the file', () {
    test('is 1080 units square, two seconds a loop, and nothing a phone '
        'cannot play', () {
      expect(_json['w'], 1080);
      expect(_json['h'], 1080);
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
      expect(entryWalletArt.canvas, 1080);
    });

    testWidgets('the wallet at rest is where the widget centres it, and '
        'fanned open stays within a quarter of the box', (tester) async {
      await tester.runAsync(() async {
        final comp = await LottieComposition.fromBytes(
          File('assets/animations/Wallet.json').readAsBytesSync(),
        );
        final rest = await _paintedAt(comp, 0);
        final art = entryWalletArt;
        expect(rest.center.dx, closeTo(art.centre.dx, 3));
        expect(rest.center.dy, closeTo(art.centre.dy, 3));
        expect(rest.width, closeTo(art.extent, 4));
        expect(rest.height, lessThanOrEqualTo(art.extent));
        // The box, in canvas units, and how far the fanned wallet reaches
        // past it at the loop's widest.
        final box = Rect.fromCenter(
          center: art.centre,
          width: art.extent,
          height: art.extent,
        );
        for (final progress in [0.25, 0.75]) {
          final open = await _paintedAt(comp, progress);
          expect(box.left - open.left, lessThan(art.extent * 0.27));
          expect(open.bottom - box.bottom, lessThan(art.extent * 0.14));
          expect(box.top - open.top, lessThan(art.extent * 0.05));
          expect(open.right - box.right, lessThan(art.extent * 0.02));
        }
      });
    });

    test(
      'its deep blue stands clear of the lobby card by night and by day',
      () {
        const deep = Color.from(alpha: 1, red: .251, green: .533, blue: .957);
        final gradients = RegExp(
          r'"k":\[0,0\.498,0\.753,0\.984,0\.5,0\.375,0\.643,0\.971,1,0\.251,'
          r'0\.533,0\.957\]',
        ).allMatches(jsonEncode(_json));
        expect(gradients, isNotEmpty, reason: 'the back runs to #4088F4');
        expect(
          _contrast(deep, GlassColors.dark.cardFill.withValues(alpha: 1)),
          greaterThan(3),
        );
        expect(_contrast(deep, const Color(0xFFFFFFFF)), greaterThan(3));
      },
    );
  });

  group('the widget', () {
    testWidgets('plays on through its parent rebuilding every second', (
      tester,
    ) async {
      await tester.runAsync(() => AssetLottie(entryWalletAsset).load());
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
                  EntryWallet(size: 16, fallbackInk: const Color(0xFFC9A227)),
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

      await tester.pump(const Duration(milliseconds: 500));
      final before = progress();
      tick.value++;
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.state(lottie), same(state));
      expect(tester.widget<Lottie>(lottie), same(widget));
      // Half a second of a two-second loop, never back to its start.
      expect((progress() - before) % 1, closeTo(0.25, 0.02));
      expect(
        tester.getSize(find.byKey(const ValueKey('entry-wallet'))),
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
            child: EntryWallet(
              size: 16,
              fallbackInk: Color(0xFFC9A227),
              still: true,
            ),
          ),
        ),
      );
      expect(tester.widget<Lottie>(find.byType(Lottie)).animate, isFalse);
      // The card's own fade is the quiet; a second would bury it.
      expect(find.byType(Opacity), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  for (final dark in [true, false]) {
    for (final screen in const [Size(640, 360), Size(1280, 800)]) {
      testWidgets('the lobby draws it on every table card\'s Entry row, in the '
          'icon\'s place, still where the table is shut '
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
        // No table card at the front: no wallet there.
        expect(find.byType(EntryWallet), findsNothing);
        var sawStill = false, sawMoving = false;
        for (final category in const ['seen', 'blind', 'variation']) {
          state.openLobbyCategory(category);
          expect(state.lobbyCategory, category);
          await tester.pump(const Duration(seconds: 1));
          await tester.pump(const Duration(seconds: 1));
          final wallets = tester
              .widgetList<EntryWallet>(find.byType(EntryWallet))
              .toList();
          expect(wallets, isNotEmpty, reason: category);
          expect(
            find.byIcon(Icons.account_balance_wallet_rounded),
            findsNothing,
            reason: category,
          );
          final accent = AppTheme.paletteFor(
            levelTheme(dark: dark).colorScheme,
            category: category,
            bootAmount: 200,
          ).accent;
          for (final wallet in wallets) {
            expect(
              wallet.tint,
              accent,
              reason: '$category: its card\'s colour',
            );
          }
          final tables = state.lobbyTablesIn(category);
          // Every table card built shows one; the shut ones stand still.
          expect(wallets.length, lessThanOrEqualTo(tables.length));
          if (screen.width >= 1280) {
            expect(wallets.length, tables.length, reason: category);
            expect(
              wallets.where((w) => w.still).length,
              tables.where(state.tableShut).length,
              reason: category,
            );
          }
          for (final wallet in wallets) {
            (wallet.still ? () => sawStill = true : () => sawMoving = true)();
          }
          for (final box
              in find.byKey(const ValueKey('entry-wallet')).evaluate()) {
            final row = find
                .ancestor(
                  of: find.byWidget(box.widget),
                  matching: find.byType(Row),
                )
                .first;
            expect(
              find.descendant(of: row, matching: find.text(state.t.entryLabel)),
              findsOneWidget,
            );
            final size = tester.getSize(find.byWidget(box.widget));
            expect(size.width, inInclusiveRange(13, 19));
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
