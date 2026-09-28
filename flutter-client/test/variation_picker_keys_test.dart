// The variation picker's keys (owner, 28 Sep 2026: the picker "is not
// glasmorpphism and have no depth, and add icon also").
//
// Each key wears its variation's mark over its name, and the review of that
// change found three things this file now holds:
//
//  * the key is exactly the height the panel's arithmetic says — its hairline
//    was an Ink border, and an Ink pads its child by its border's width, so
//    every key stood 2dp taller than stated (46, 64) and the 640x360 panel
//    passed its 170dp ceiling with nothing to spare;
//  * the mark takes no room the words need — the first cut left a roomy
//    key's name and note 36dp between them and drew the Hindi and Bengali
//    notes some 15% smaller at text x1.25. Laid out in the fonts a phone draws
//    the Indic scripts in (script_fonts.dart), every name and note in all five
//    languages now fits its box's HEIGHT, so only a key's width ever sets its
//    words smaller, as it did in the keys without a mark;
//  * a key held down takes a third of its raised light, as a Material key
//    does — which the key's doc comment claimed and nothing did — and a press
//    rebuilds none of the words under it.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/variation_prompt.dart';

import 'script_fonts.dart';

int get _now => DateTime.now().millisecondsSinceEpoch;

Finder _key(String wire) => find.byKey(ValueKey('variation-option-$wire'));

/// The picker as the table stands it: in the top 64% of the screen.
Future<List<String>> _pump(
  WidgetTester tester, {
  required Size screen,
  double textScale = 1.0,
  AppLang lang = AppLang.english,
  bool Function(String wire)? answer,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final sent = <String>[];
  final t = Strings(lang);
  await tester.pumpWidget(
    MaterialApp(
      theme: withScriptFallback(AppTheme.dark(sound: false)),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: screen.height * 0.64,
            child: VariationPrompt(
              title: t.variationChooseTitle,
              options: Variation.all,
              nameOf: t.variationName,
              noteOf: t.variationNote,
              deadlineMs: _now + 10000,
              totalMs: 10000,
              onSelect: (wire) async {
                sent.add(wire);
                return answer?.call(wire) ?? true;
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  return sent;
}

/// The light on [wire]'s face, as its [DepthFace] is told to draw it.
double _light(WidgetTester tester, String wire) => tester
    .widget<DepthFace>(
      find.descendant(of: _key(wire), matching: find.byType(DepthFace)),
    )
    .strength;

void main() {
  // Inter as the app bundles it, and the Noto fonts a phone falls back to.
  setUpAll(loadScriptFonts);

  group('every key', () {
    for (final (screen, height, mark) in const [
      (Size(640, 360), 44.0, 15.0),
      (Size(891, 411), 64.0, 16.0),
    ]) {
      for (final scale in const [1.0, 1.25]) {
        final where =
            '${screen.width.toInt()}x${screen.height.toInt()} x$scale';
        for (final lang in AppLang.values) {
          testWidgets(
            'at $where in ${lang.englishName} is ${height.toInt()}dp, its '
            'mark over words that fit its height',
            (tester) async {
              if (lang != AppLang.english && !haveScriptFonts()) {
                markTestSkipped('the Noto script fonts are not installed');
                return;
              }
              await _pump(tester, screen: screen, textScale: scale, lang: lang);
              expect(tester.takeException(), isNull);
              for (final wire in Variation.all) {
                final key = _key(wire);
                // Exactly the height the panel's sum is built on.
                expect(tester.getSize(key).height, height, reason: wire);

                // The variation's mark, at its fixed size, in every key.
                final icon = tester.widget<Icon>(
                  find.descendant(of: key, matching: find.byType(Icon)),
                );
                expect(icon.icon, variationIcon(wire));
                expect(icon.size, mark);

                // The name (and on a roomy key the note) is fitted into a box
                // at least as tall as its line: whatever scales it down is
                // the key's width, never the mark above it.
                final boxes = <RenderFittedBox>[];
                void walk(RenderObject r) {
                  if (r is RenderFittedBox) boxes.add(r);
                  r.visitChildren(walk);
                }

                walk(tester.renderObject(key));
                expect(boxes, hasLength(screen.width >= 700 ? 2 : 1));
                for (final box in boxes) {
                  final line = box.child!.size.height;
                  expect(
                    box.constraints.maxHeight,
                    greaterThanOrEqualTo(line - 0.01),
                    reason:
                        '$wire: a ${line}dp line in a '
                        '${box.constraints.maxHeight}dp box',
                  );
                }
              }
              await tester.pumpWidget(const SizedBox.shrink());
            },
          );
        }
      }
    }
  });

  testWidgets('a key held down takes a third of its light, and gets it back', (
    tester,
  ) async {
    final sent = await _pump(tester, screen: const Size(891, 411));
    final name = const Strings(AppLang.english).variationName(Variation.muflis);
    final words = tester.widget<Text>(find.text(name));
    final mark = tester.widget<Icon>(
      find.descendant(of: _key(Variation.muflis), matching: find.byType(Icon)),
    );
    for (final wire in Variation.all) {
      expect(_light(tester, wire), 1, reason: wire);
    }

    final press = await tester.startGesture(
      tester.getCenter(_key(Variation.muflis)),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(_light(tester, Variation.muflis), closeTo(1 / 3, 1e-9));
    // Only the key under the finger.
    expect(_light(tester, Variation.ak47), 1);
    // The press moved the light and nothing else: the very same widgets.
    expect(identical(tester.widget<Text>(find.text(name)), words), isTrue);
    expect(
      identical(
        tester.widget<Icon>(
          find.descendant(
            of: _key(Variation.muflis),
            matching: find.byType(Icon),
          ),
        ),
        mark,
      ),
      isTrue,
    );

    // Let go without choosing: the light comes back, and nothing is sent.
    await press.cancel();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_light(tester, Variation.muflis), 1);
    expect(sent, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('once a choice is sent no key takes any light', (tester) async {
    final sent = await _pump(tester, screen: const Size(891, 411));
    await tester.tap(_key(Variation.ak47));
    await tester.pump();
    expect(sent, [Variation.ak47]);
    // The chosen key is struck gold, which has a face of its own; the others
    // have stepped back and sit flush.
    for (final wire in Variation.all) {
      expect(_light(tester, wire), 0, reason: wire);
    }

    // A key that has stepped back cannot be pressed into any light either.
    final press = await tester.startGesture(
      tester.getCenter(_key(Variation.hukam)),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(_light(tester, Variation.hukam), 0);
    await press.up();
    await tester.pump();
    expect(sent, [Variation.ak47]);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
