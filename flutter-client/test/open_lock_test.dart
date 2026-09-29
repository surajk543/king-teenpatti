// The owner's lock on the lobby's category cards (29 Sep 2026): "use this lock
// animation on lobby card instead of using lock icons in front of text 'open
// to you'. Make sure it look visible in dark and night mode".
//
// assets/animations/Lock.json is played in its own colours
// (widgets/open_lock.dart). These hold the file to the disc the widget sizes
// by, its blue to a mark's contrast on both cards, the lobby to drawing it on
// the "Open to you" row, and the widget to playing on through the lobby's
// one-second rebuilds.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/open_lock.dart';

import 'level_fixtures.dart';

final _json =
    jsonDecode(File('assets/animations/Lock.json').readAsStringSync())
        as Map<String, dynamic>;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('the file', () {
    test('is 210 units square with a 100-unit blue disc at its middle, and '
        'nothing a phone cannot play', () {
      expect(_json['w'], 210);
      expect(_json['h'], 210);
      for (final layer in (_json['layers'] as List).cast<Map>()) {
        expect(layer['ddd'] ?? 0, 0, reason: 'no 3D layer');
      }
      // An expression is a property's "x" string (a bezier handle's "x" is
      // a number or a list).
      expect(
        RegExp(r'"x":"').hasMatch(jsonEncode(_json)),
        isFalse,
        reason: 'no expressions',
      );
      expect((_json['assets'] as List), isEmpty, reason: 'no images');
      final disc = (_json['layers'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((l) => l['nm'] == 'b' && l['tt'] == 1);
      expect(disc['ks']['p']['k'], [105, 105, 0]);
      final shapes = jsonEncode(disc['shapes']);
      expect(shapes, contains('"s":{"a":0,"k":[100,100]}'));
      expect(100 / 210, openLockDiscShare);
    });

    test('its blue stands clear of the lobby card by night and by day', () {
      const blue = Color.from(alpha: 1, red: .161, green: .529, blue: 1);
      expect(
        _contrast(blue, GlassColors.dark.cardFill.withValues(alpha: 1)),
        greaterThan(3),
      );
      expect(_contrast(blue, const Color(0xFFFFFFFF)), greaterThan(3));
      // The white lock on the blue.
      expect(_contrast(const Color(0xFFFFFFFF), blue), greaterThan(3));
    });
  });

  group('the widget', () {
    testWidgets('plays on through its parent rebuilding every second', (
      tester,
    ) async {
      await tester.runAsync(() => AssetLottie(openLockAsset).load());
      final tick = ValueNotifier<int>(0);
      addTearDown(tick.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ListenableBuilder(
              listenable: tick,
              builder: (context, _) =>
                  const OpenLock(size: 16, fallbackInk: Color(0xFFC9A227)),
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
      // Half a second of a three-second loop, never back to its start.
      expect((progress() - before) % 1, closeTo(0.5 / 3.003, 0.02));
      expect(
        tester.getSize(find.byKey(const ValueKey('open-lock'))),
        const Size(16, 16),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('stands still and faded when no table is open', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: OpenLock(
              size: 16,
              fallbackInk: Color(0xFFC9A227),
              quiet: true,
            ),
          ),
        ),
      );
      final lottie = tester.widget<Lottie>(find.byType(Lottie));
      expect(lottie.animate, isFalse);
      expect(
        tester.widget<Opacity>(find.byType(Opacity)).opacity,
        OpenLock.quietOpacity,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  for (final dark in [true, false]) {
    testWidgets('the lobby draws it on every category card\'s "Open to you" '
        'row, in the icon\'s place (${dark ? 'night' : 'day'})', (
      tester,
    ) async {
      primeBadges();
      final state = levelState(level: levelAt(10, xp: 4180));
      await pumpLevelLobby(
        tester,
        state,
        screen: const Size(640, 360),
        scale: 1.25,
        dark: dark,
      );
      final locks = find.byKey(const ValueKey('open-lock'));
      // Seen and Blind.
      expect(locks, findsNWidgets(2));
      expect(find.byIcon(Icons.lock_open_rounded), findsNothing);
      for (final lock in tester.widgetList<OpenLock>(find.byType(OpenLock))) {
        expect(lock.quiet, isFalse, reason: 'every table is open to Priya');
      }
      // Each in its card's colour: Seen's gold, Blind's blue.
      final scheme = levelTheme(dark: dark).colorScheme;
      expect(
        {
          for (final lock in tester.widgetList<OpenLock>(find.byType(OpenLock)))
            lock.tint,
        },
        {
          for (final category in const ['seen', 'blind'])
            AppTheme.paletteFor(
              scheme,
              category: category,
              bootAmount: 200,
            ).accent,
        },
      );
      final row = find
          .ancestor(of: locks.first, matching: find.byType(Row))
          .first;
      expect(
        find.descendant(of: row, matching: find.text(state.t.openToYouLabel)),
        findsOneWidget,
      );
      final size = tester.getSize(locks.first);
      expect(size.width, inInclusiveRange(13, 19));
      expect(tester.takeException(), isNull);
      await unmountLevel(tester, state);
    });
  }
}
