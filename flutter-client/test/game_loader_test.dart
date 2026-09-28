// The game's loader (owner, 28 Sep 2026: "change the loader of game … use
// this lottie json … whereever loader you are showing show this loader, and
// below text also please wait...").
//
// Held here: the owner's file is what is bundled; its black arc is drawn in
// the theme's ink and its teal kept; the ring fills the box it is given;
// "Please wait..." stands under it in every language, with what is being
// waited for under that where there is one, and a screen reader hears the
// words; the ring alone carries no words; and no Material spinner is left
// anywhere in the app.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/widgets/game_loader.dart';

Future<void> _pump(WidgetTester tester, Widget child, {bool dark = true}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        home: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  test(
    'the bundled file is the owner\'s GameLoader.json, as uploaded',
    () async {
      final bytes = File('assets/animations/GameLoader.json').readAsBytesSync();
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(json['w'], 540);
      expect(json['h'], 540);
      expect((json['layers'] as List).length, 2);
      // Nothing a phone cannot play: no 3D layer, no expression, no image.
      final raw = utf8.decode(bytes);
      expect(raw.contains('"ddd":1'), isFalse);
      expect(RegExp(r'"x"\s*:\s*"').hasMatch(raw), isFalse);
      expect((json['assets'] as List), isEmpty);
      // And it is declared: the pubspec bundles the whole folder.
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('assets/animations/'));
      expect(await rootBundle.loadString(gameLoaderAsset), isNotEmpty);
    },
  );

  test('the black arc is drawn in the ink, the teal is the file\'s own', () {
    const ink = Color(0xFFF2F2F2);
    expect(gameLoaderArc(const Color(0xFF000000), ink), ink);
    const teal = Color.fromRGBO(66, 232, 203, 1);
    expect(gameLoaderArc(teal, ink), teal);
  });

  testWidgets('the ring fills the box it is given and carries no words', (
    tester,
  ) async {
    await _pump(tester, const GameLoaderRing(size: 18));
    await tester.pump(const Duration(milliseconds: 100));
    final ring = find.byKey(const ValueKey('game-loader-ring'));
    expect(tester.getSize(ring), const Size(18, 18));
    expect(
      find.descendant(of: ring, matching: find.byType(LottieBuilder)),
      findsOneWidget,
    );
    expect(find.byType(Text), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"Please wait..." under the ring, and what is being waited for '
      'under that; a screen reader hears both', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, const GameLoader(detail: 'Reconnecting…'));
    await tester.pump(const Duration(milliseconds: 100));
    final ring = tester.getRect(find.byKey(const ValueKey('game-loader-ring')));
    final words = tester.getRect(find.text('Please wait...'));
    final detail = tester.getRect(find.text('Reconnecting…'));
    expect(words.top, greaterThanOrEqualTo(ring.bottom));
    expect(detail.top, greaterThanOrEqualTo(words.bottom));
    expect(
      find.bySemanticsLabel('Please wait... Reconnecting…'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('the words in every language, dark and light, nothing cut', (
    tester,
  ) async {
    for (final dark in [true, false]) {
      await _pump(tester, const GameLoader(), dark: dark);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Please wait...'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    final english = Strings(AppLang.english);
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      expect(t.pleaseWait, isNotEmpty, reason: lang.code);
      if (lang != AppLang.english) {
        expect(t.pleaseWait, isNot(english.pleaseWait), reason: lang.code);
      }
    }
  });

  test(
    'no Material spinner is left in the app: every loader is the game\'s',
    () {
      final spinners = RegExp(
        r'CircularProgressIndicator|LinearProgressIndicator|'
        r'RefreshProgressIndicator|CupertinoActivityIndicator',
      );
      final found = [
        for (final f in Directory('lib').listSync(recursive: true))
          if (f is File &&
              f.path.endsWith('.dart') &&
              spinners.hasMatch(f.readAsStringSync()))
            f.path,
      ];
      expect(found, isEmpty);
    },
  );
}
