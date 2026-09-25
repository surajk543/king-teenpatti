// A player's name on their pod is whole (owner's table polish brief, 25 Sep
// 2026: "Never allow: player names to clip"): a name a little wider than its
// pod is set a little smaller rather than cut. Measured in Inter, the face the
// phone draws — the test font's square glyphs are half as wide again.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'table_scenes.dart';

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

TableScene _scene(String prefix) =>
    tableScenes.firstWhere((s) => s.name.startsWith(prefix));

void main() {
  setUpAll(_loadInter);

  for (final size in const [Size(640, 360), Size(592, 360)]) {
    testWidgets('every name at the table is whole at ${size.width.toInt()}x'
        '${size.height.toInt()} with text at x1.25', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.25;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      for (final prefix in ['01', '20']) {
        for (final dark in [true, false]) {
          final feedback = await silentFeedback();
          final state = sceneState(_scene(prefix));
          await tester.pumpWidget(
            tableApp(
              state: state,
              feedback: feedback,
              theme: dark
                  ? AppTheme.dark(sound: false)
                  : AppTheme.light(sound: false),
            ),
          );
          await tester.pump(const Duration(milliseconds: 900));
          for (final name in [
            'Ravi',
            'Meera',
            'Arjun',
            'Vikramaditya',
            'YOU',
          ]) {
            final text = find.descendant(
              of: find.byType(SeatName),
              matching: find.text(name),
            );
            expect(text, findsOneWidget, reason: name);
            final paragraph = tester.renderObject<RenderParagraph>(text);
            expect(
              paragraph.didExceedMaxLines,
              isFalse,
              reason: '$prefix $name',
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 10));
          state.dispose();
          feedback.dispose();
        }
      }
    });
  }

  testWidgets('a name too long for any pod is cut, at the smallest size', (
    tester,
  ) async {
    const style = TextStyle(fontFamily: 'Inter', fontSize: 12);
    Future<TextStyle> styleIn(String name, double width) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: width,
              child: SeatName(name, style: style),
            ),
          ),
        ),
      );
      return tester.widget<Text>(find.text(name)).style!;
    }

    // Room to spare: its own size.
    expect((await styleIn('Ravi', 80)).fontSize, 12);
    // A little too wide: a little smaller, whole.
    final squeezed = await styleIn('Vikramaditya', 64);
    expect(squeezed.fontSize, lessThan(12));
    expect(squeezed.fontSize, greaterThanOrEqualTo(12 * SeatName.minScale));
    expect(
      tester
          .renderObject<RenderParagraph>(find.text('Vikramaditya'))
          .didExceedMaxLines,
      isFalse,
    );
    // Twenty-four letters in a pod: the smallest size, and an ellipsis.
    const long = 'Abcdefghijklmnopqrstuvwx';
    expect((await styleIn(long, 64)).fontSize, 12 * SeatName.minScale);
  });
}
