// Close-ups of the playing cards (premium-card brief, 25 Sep 2026): every
// face the brief names and both backs, at each height the table draws a card
// at, on each game's cloth in both themes. Not part of `flutter test` (the name
// has no `_test`): run it by hand.
//
//   flutter test test/card_shots.dart --dart-define=SHOTS_DIR=/abs/dir
//
// Written to SHOTS_DIR as PNGs at three times the logical size, so the
// smallest faces can be looked at pixel by pixel.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/playing_card.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');

/// The heights a card is drawn at: a rim seat's at 640x360 and at 915x412,
/// the rules sheet's, a picker's, and the viewer's hand at 640x360 and on a
/// tall phone.
const _heights = [38.0, 45.0, 52.0, 66.0, 84.0, 104.0];

/// The faces the brief names, red and black, a ten and every court.
const _codes = ['5c', '9c', '5d', 'As', 'Kh', 'Qd', 'Jc', 'Ts'];

Future<void> _loadFonts() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

void main() {
  setUpAll(_loadFonts);

  for (final dark in [true, false]) {
    for (final game in ['seen', 'blind', 'variation']) {
      final name = 'cards_${game}_${dark ? 'dark' : 'light'}.png';
      testWidgets(name, (tester) async {
        debugDisableShadows = false;
        try {
          await _shoot(tester, name, dark: dark, game: game);
        } finally {
          debugDisableShadows = true;
        }
      });
    }
  }
}

Future<void> _shoot(
  WidgetTester tester,
  String file, {
  required bool dark,
  required String game,
}) async {
  const size = Size(1180, 760);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final theme = dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Builder(
          builder: (context) {
            final colours = Theme.of(context).extension<CasinoTableColors>()!;
            final cloth = colours.clothFor(game);
            return Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  radius: 1.1,
                  colors: [cloth.centre, cloth.edge],
                ),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final h in _heights)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          SizedBox(
                            width: 40,
                            child: Text(
                              '${h.toInt()}',
                              style: TextStyle(
                                fontFamily: AppTheme.fontFamily,
                                fontSize: 12,
                                color: dark ? Colors.white70 : Colors.black54,
                              ),
                            ),
                          ),
                          for (final code in _codes)
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: PlayingCard(code: code, height: h),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: PlayingCard(height: h),
                          ),
                          PlayingCard(height: h, tint: AppTheme.cardSeenBack),
                        ],
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
  // The backs are SVGs, decoded off the frame.
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(tester.takeException(), isNull);

  if (_dir.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 3);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_dir/$file').writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}
