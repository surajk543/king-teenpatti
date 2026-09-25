// Close-ups of the playing cards (premium-card brief, 25 Sep 2026): every
// face the brief names and both backs, at each height the table draws a card
// at, on each game's cloth in both themes; and the two motions, frame by
// frame — a hand turned over ("See cards") and a hand dealt. Not part of
// `flutter test` (the name has no `_test`): run it by hand.
//
//   flutter test test/card_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//
// Written to SHOTS_DIR as PNGs: the close-ups at three times the logical size,
// so the smallest faces can be looked at pixel by pixel; the motions at twice,
// one file a frame (flip_<ms>.png, deal_<ms>.png).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/playing_card.dart';

import 'table_scenes.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');

/// The heights a card is drawn at: a rim seat's at 640x360 and at 915x412,
/// the rules sheet's, a picker's, and the viewer's hand at 640x360 and on a
/// tall phone.
const _heights = [38.0, 45.0, 52.0, 66.0, 88.0, 104.0];

/// The faces the brief names, red and black, a ten and every court card.
const _codes = ['5c', '9c', '5d', 'As', 'Kh', 'Qd', 'Jc', 'Ts'];

Future<void> _loadFonts() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
  final icons = File(const String.fromEnvironment('ICON_FONT'));
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
}

Future<void> _save(
  WidgetTester tester,
  GlobalKey key,
  String file, {
  double pixelRatio = 2,
}) async {
  if (_dir.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: pixelRatio);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_dir/$file').writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}

/// Lets the backs' SVG decode, which happens off the frame.
Future<void> _decode(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(_loadFonts);

  Future<void> shadows(Future<void> Function() body) async {
    debugDisableShadows = false;
    try {
      await body();
    } finally {
      debugDisableShadows = true;
    }
  }

  for (final dark in [true, false]) {
    for (final game in ['seen', 'blind', 'variation']) {
      final name = 'cards_${game}_${dark ? 'dark' : 'light'}.png';
      testWidgets(
        name,
        (tester) => shadows(() => _faces(tester, name, dark: dark, game: game)),
      );
    }
  }
  testWidgets('flip frames', (tester) => shadows(() => _flip(tester)));
  testWidgets('deal frames', (tester) => shadows(() => _deal(tester)));
}

Widget _onCloth({
  required bool dark,
  required String game,
  required Widget child,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
  home: Builder(
    builder: (context) {
      final cloth = Theme.of(
        context,
      ).extension<CasinoTableColors>()!.clothFor(game);
      return Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            radius: 1.1,
            colors: [cloth.centre, cloth.edge],
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: child,
      );
    },
  ),
);

Future<void> _faces(
  WidgetTester tester,
  String file, {
  required bool dark,
  required String game,
}) async {
  tester.view.physicalSize = const Size(960, 540);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: _onCloth(
        dark: dark,
        game: game,
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
                          decoration: TextDecoration.none,
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
      ),
    ),
  );
  await _decode(tester);
  expect(tester.takeException(), isNull);
  await _save(tester, key, file, pixelRatio: 3);
}

/// A hand of three turned over, as "See cards" turns it: one card after
/// another, each lifting as it turns.
Future<void> _flip(WidgetTester tester) async {
  tester.view.physicalSize = const Size(420, 200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  Widget hand(List<String?> codes) => RepaintBoundary(
    key: key,
    child: _onCloth(
      dark: true,
      game: 'seen',
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, code) in codes.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: PlayingCard(
                  code: code,
                  height: 120,
                  flipDelay: PlayingCard.flipStagger * i,
                ),
              ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpWidget(hand(const [null, null, null]));
  await _decode(tester);
  await tester.pumpWidget(hand(const ['5c', '9c', '5d']));
  var ms = 0;
  for (final step in const [0, 90, 90, 60, 60, 60, 90, 120]) {
    await tester.pump(Duration(milliseconds: step));
    ms += step;
    await _save(tester, key, 'flip_${ms.toString().padLeft(3, '0')}.png');
  }
  expect(tester.takeException(), isNull);
}

/// A hand dealt to the table at 732x412: the viewer's three backs landing.
Future<void> _deal(WidgetTester tester) async {
  tester.view.physicalSize = const Size(732, 412);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = sceneState(tableScenes.first);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: tableApp(
        state: state,
        feedback: feedback,
        theme: AppTheme.dark(sound: false),
      ),
    ),
  );
  await _decode(tester);
  await tester.pump(const Duration(milliseconds: 900));
  state.handleState(opponentTurnRoom(handNo: 8));
  await tester.pump();
  var ms = 0;
  while (ms <= 720) {
    if (ms % 80 == 0) {
      await _save(tester, key, 'deal_${ms.toString().padLeft(3, '0')}.png');
    }
    await tester.pump(const Duration(milliseconds: 16));
    ms += 16;
  }
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}
