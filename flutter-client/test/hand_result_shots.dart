// The hand-result card animations (owner's brief, 29 Sep 2026), frame by
// frame: each of the five levels won at the viewer's seat and at a rim seat,
// dark and light, at 640x360 and 891x411 — and the Trail under reduced
// motion. Not part of `flutter test` (the name has no `_test`): run it by
// hand.
//
//   flutter test test/hand_result_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=trail_rim   a substring of the names;
//              several, comma-separated, take any of them
//
// Every frame is the whole TableScreen laid out for real, Inter, the Material
// icons and the fireworks loaded. Written to SHOTS_DIR at twice the logical
// size: the winner's seat and cards cropped out of every frame as
// <run>_t<ms>.png, where t is the time since the result arrived, and the whole
// table once, at the height of the animation, as <run>_full.png. Anything that
// overflows or throws is written to SHOTS_DIR/problems.txt rather than
// failing the run. The hands are test/hand_result_scenes.dart's.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/hand_result_motion.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/hand_result.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'hand_result_scenes.dart';
import 'table_scenes.dart' show silentFeedback, tableApp;

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');

/// The frames, in ms since the result arrived: the cards still turning, the
/// ribbon's strike (about 500 ms in), every level's run and its rest.
const _frames = [
  300, 480, 530, 580, 630, 680, 740, 800, 870, 940, 1020, 1100, 1200, //
  1320, 1450, 1650, 2000, 2600,
];

/// The one full frame of the table a run keeps, at the height of it.
const _fullAt = 800;

class _Run {
  const _Run(
    this.level,
    this.winner,
    this.size,
    this.dark, {
    this.reduced = false,
  });

  final String level;
  final String winner;
  final Size size;
  final bool dark;
  final bool reduced;

  String get name =>
      '${level}_${winner == 'u0' ? 'you' : 'rim'}_'
      '${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}${reduced ? '_reduced' : ''}';
}

List<_Run> _runs() => [
  for (final level in resultHands.keys)
    for (final winner in ['u0', 'u3'])
      for (final size in const [Size(640, 360), Size(891, 411)])
        for (final dark in [true, false]) _Run(level, winner, size, dark),
  for (final winner in ['u0', 'u3'])
    for (final dark in [true, false])
      _Run('trail', winner, const Size(891, 411), dark, reduced: true),
];

Future<void> _loadAssets() async {
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
  // Parsed where async is real (CLAUDE.md §12.3).
  // NO_FIREWORKS=true leaves them out, to see the cards' own light alone.
  if (!const bool.fromEnvironment('NO_FIREWORKS')) await FireworksArt.load();
}

void main() {
  setUpAll(_loadAssets);
  setUp(HandResultMemory.reset);
  final problems = <String>[];
  tearDownAll(() {
    if (_dir.isEmpty) return;
    File('$_dir/problems.txt').writeAsStringSync(
      problems.isEmpty ? 'none\n' : '${problems.join('\n')}\n',
    );
  });

  bool wanted(String name) =>
      _only.isEmpty || _only.split(',').any((term) => name.contains(term));

  for (final run in _runs()) {
    if (!wanted(run.name)) continue;
    testWidgets(run.name, (tester) async {
      debugDisableShadows = false;
      try {
        await _shoot(tester, run, problems);
      } finally {
        debugDisableShadows = true;
      }
    });
  }

  // The studio: each level's cards alone on its cloth, at a rim seat's size
  // and the viewer's, with nothing else on the table — the fireworks, the
  // ribbon and the pot's flight left out — to judge the cards' own light.
  for (final level in HandResultLevel.values) {
    for (final dark in [true, false]) {
      for (final reduced in [false, true]) {
        final name =
            'studio_${level.name}_${dark ? 'dark' : 'light'}'
            '${reduced ? '_reduced' : ''}';
        if (!wanted(name)) continue;
        testWidgets(name, (tester) async {
          debugDisableShadows = false;
          try {
            await _studio(tester, name, level, dark: dark, reduced: reduced);
          } finally {
            debugDisableShadows = true;
          }
        });
      }
    }
  }
}

/// The studio's frames, in ms since the result.
const _studioFrames = [
  0, 60, 120, 180, 240, 300, 380, 460, 540, 620, 700, 780, 860, 940, 1020, //
  1100, 1300,
];

Future<void> _studio(
  WidgetTester tester,
  String name,
  HandResultLevel level, {
  required bool dark,
  required bool reduced,
}) async {
  const size = Size(460, 200);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  if (reduced) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  addTearDown(tester.view.reset);
  final won = resultHands.values.elementAt(level.index);
  final lit = handResultCards(level: level, cards: won.cards);
  final clock = AnimationController(
    vsync: const TestVSync(),
    duration: const Duration(seconds: 2),
  );
  addTearDown(clock.dispose);
  final cue = HandResultCue(
    key: name,
    userId: 'u0',
    level: level,
    cards: lit,
    clock: clock,
    total: const Duration(seconds: 2),
    startAt: Duration.zero,
    category: 'seen',
    bootAmount: 200,
  );
  Widget hand(double height, double overlap) => HandResultGroup(
    userId: 'u0',
    child: SizedBox(
      width: height * PlayingCard.aspect * (3 - 2 * overlap) + 8,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final (i, code) in won.cards.indexed)
            Positioned(
              left: 4 + i * height * PlayingCard.aspect * (1 - overlap),
              top: 0,
              child: HandResultCard(
                code: code,
                cardHeight: height,
                child: PlayingCard(code: code, height: height),
              ),
            ),
        ],
      ),
    ),
  );
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: dark
            ? AppTheme.dark(sound: false)
            : AppTheme.light(sound: false),
        home: Builder(
          builder: (context) {
            final cloth = CasinoTableColors.of(context).clothFor('seen');
            return DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(colors: [cloth.centre, cloth.edge]),
              ),
              child: HandResultScope(
                cue: cue,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [hand(40, 0), hand(84, 0.46)],
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 600));
  for (final ms in _studioFrames) {
    clock.value = ms / 2000;
    await tester.pump();
    await _save(tester, key, '${name}_t${ms.toString().padLeft(4, '0')}.png');
  }
}

/// Saves [crop] (logical pixels, or the whole view when null) of the frame.
Future<void> _save(
  WidgetTester tester,
  GlobalKey key,
  String file, {
  Rect? crop,
}) async {
  if (_dir.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    const ratio = 2.0;
    var image = await boundary.toImage(pixelRatio: ratio);
    if (crop != null) {
      final from = Rect.fromLTRB(
        crop.left * ratio,
        crop.top * ratio,
        crop.right * ratio,
        crop.bottom * ratio,
      ).intersect(Offset.zero & Size(image.width * 1.0, image.height * 1.0));
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        image,
        from,
        Offset.zero & from.size,
        Paint()..filterQuality = FilterQuality.none,
      );
      final cropped = await recorder.endRecording().toImage(
        from.width.round(),
        from.height.round(),
      );
      image.dispose();
      image = cropped;
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$_dir/$file').writeAsBytesSync(data!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _shoot(
  WidgetTester tester,
  _Run run,
  List<String> problems,
) async {
  tester.view.physicalSize = run.size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1;
  if (run.reduced) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = resultState();
  final won = resultHands[run.level]!;
  final loser = run.winner == 'u0' ? 'u3' : 'u0';
  final viewerCards = run.winner == 'u0' ? won.cards : beatenHand.cards;

  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: tableApp(
        state: state,
        feedback: feedback,
        theme: run.dark
            ? AppTheme.dark(sound: false)
            : AppTheme.light(sound: false),
      ),
    ),
  );
  state.handleState(resultRoom(cards: viewerCards));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  state.handleShowdown(resultReveal(run.winner, won, loser: loser));
  await tester.pump(const Duration(milliseconds: 16));
  state
    ..handleShowdown(resultEnded(run.winner, won, loser: loser))
    ..handleState(resultSettled(run.winner, loser: loser, cards: viewerCards));

  // Where the winner's seat and cards are: their pod and their cards' group,
  // with room round them for the light and the sparks.
  Rect? cropRect() {
    final group = find.byWidgetPredicate(
      (w) => w is HandResultGroup && w.userId == run.winner,
    );
    final pod = find.byWidgetPredicate(
      (w) => w is SeatPod && w.seat?.userId == run.winner,
    );
    if (group.evaluate().isEmpty || pod.evaluate().isEmpty) return null;
    final rect = tester
        .getRect(group)
        .expandToInclude(tester.getRect(pod))
        .inflate(36);
    return Rect.fromLTRB(
      rect.left.clamp(0, run.size.width),
      rect.top.clamp(0, run.size.height),
      rect.right.clamp(0, run.size.width),
      rect.bottom.clamp(0, run.size.height),
    );
  }

  var at = 0;
  Future<void> until(int ms) async {
    await tester.pump();
    while (at < ms) {
      final step = ms - at < 16 ? ms - at : 16;
      await tester.pump(Duration(milliseconds: step));
      at += step;
    }
  }

  for (final ms in _frames) {
    await until(ms);
    await _save(
      tester,
      key,
      '${run.name}_t${ms.toString().padLeft(4, '0')}.png',
      crop: cropRect(),
    );
    if (ms == _fullAt) await _save(tester, key, '${run.name}_full.png');
    final problem = tester.takeException();
    if (problem != null) problems.add('${run.name} t=$ms: $problem');
  }

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  final late = tester.takeException();
  if (late != null) problems.add('${run.name} (teardown): $late');
  state.dispose();
}
