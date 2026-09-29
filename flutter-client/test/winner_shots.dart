// The end of a hand, frame by frame (owner, 26 Sep 2026: "check winner
// animation and coin flow, make it smooth"): the show paid, the cards turned
// over, the WINNER ribbon, the fireworks, the pot crossing to the winner and
// the next deal. Not part of `flutter test` (the name has no `_test`): run it
// by hand.
//
//   flutter test test/winner_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=you-win_640   a substring of the names;
//              several, comma-separated, take any of them
//
// Every frame is the whole TableScreen laid out for real, Inter, the Material
// icons and the fireworks loaded, written as <run>_t<ms>.png at twice the
// logical size, where t is the time since the result arrived. Anything that
// overflows or throws is written to SHOTS_DIR/problems.txt rather than
// failing the run.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/theme/app_theme.dart';

import 'table_scenes.dart' show silentFeedback, tableApp;
import 'winner_scenes.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');

/// Every frame of the whole sequence, in ms since the result arrived.
const _sequence = [
  0, 80, 160, 250, 350, 450, 520, 600, 700, 800, 900, 1000, 1100, 1200, //
  1350, 1500, 1650, 1800, 2000, 2300, 2700, 3200, 3700,
];

/// The frames a size, a text scale or a language is checked at: the reveal,
/// the result landing, the chips in the air, landing, and after.
const _keyFrames = [250, 600, 1000, 1500, 2300];

/// After the next deal, in ms since its snapshot.
const _dealFrames = [0, 150, 350, 600, 900];

class _Run {
  const _Run(
    this.winner,
    this.size,
    this.dark,
    this.scale, {
    this.lang = AppLang.english,
    this.frames = _sequence,
    this.revealed = true,
    this.deal = false,
  });

  final String winner;
  final Size size;
  final bool dark;
  final double scale;
  final AppLang lang;
  final List<int> frames;
  final bool revealed;
  final bool deal;

  String get name =>
      '${revealed ? (winner == 'u0' ? 'you-win' : 'rim-wins') : 'last-standing'}_'
      '${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}';
}

List<_Run> _runs() => [
  for (final winner in ['u0', 'u3'])
    for (final size in const [Size(640, 360), Size(891, 411)])
      for (final dark in [true, false])
        _Run(winner, size, dark, 1.0, deal: winner == 'u0'),
  for (final size in const [Size(592, 360), Size(915, 412)])
    for (final dark in [true, false])
      _Run('u0', size, dark, 1.0, frames: _keyFrames),
  for (final dark in [true, false]) ...[
    _Run('u0', const Size(640, 360), dark, 1.25, frames: _keyFrames),
    _Run('u3', const Size(640, 360), dark, 1.25, frames: _keyFrames),
  ],
  for (final winner in ['u0', 'u3'])
    _Run(
      winner,
      const Size(640, 360),
      true,
      1.25,
      lang: AppLang.hindi,
      frames: _keyFrames,
    ),
  _Run('u0', const Size(891, 411), true, 1.0, revealed: false),
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
  for (final path in const [
    '/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final loader = FontLoader('Devanagari')
      ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await loader.load();
  }
  // Parsed where async is real, as the table does when it opens: a future
  // first awaited inside one test's fake clock never completes in the next
  // (CLAUDE.md §12.3).
  await FireworksArt.load();
}

ThemeData _theme(bool dark, AppLang lang) {
  final base = dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  if (lang == AppLang.english) return base;
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamilyFallback: const ['Devanagari']),
  );
}

void main() {
  setUpAll(_loadAssets);
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
}

Future<void> _save(WidgetTester tester, GlobalKey key, String file) async {
  if (_dir.isEmpty) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
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
  tester.platformDispatcher.textScaleFactorTestValue = run.scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = winnerState(lang: run.lang);

  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: tableApp(
        state: state,
        feedback: feedback,
        theme: _theme(run.dark, run.lang),
      ),
    ),
  );
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }

  if (run.revealed) {
    // The show is paid, its chip crosses to the pot, and the server turns the
    // hands over: the reveal, then the result a moment later.
    state.handleState(winnerShowPaid());
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    state.handleShowdown(winnerReveal(run.winner));
    await tester.pump(const Duration(milliseconds: 16));
  }
  state
    ..handleShowdown(winnerEnded(run.winner, revealed: run.revealed))
    ..handleState(winnerSettled(run.winner, revealed: run.revealed));

  // Frame by frame, as a phone draws: a clock started after one frame starts
  // one frame later, not at the end of however long the next pump happens
  // to be.
  var at = 0;
  Future<void> until(int ms) async {
    await tester.pump();
    while (at < ms) {
      final step = ms - at < 16 ? ms - at : 16;
      await tester.pump(Duration(milliseconds: step));
      at += step;
    }
  }

  for (final ms in run.frames) {
    await until(ms);
    await _save(
      tester,
      key,
      '${run.name}_t${ms.toString().padLeft(4, '0')}.png',
    );
    final problem = tester.takeException();
    if (problem != null) problems.add('${run.name} t=$ms: $problem');
  }

  if (run.deal) {
    // The celebration's own clock ends it on the next hand's snapshot.
    await until(4000);
    state.handleState(winnerNextDeal(run.winner));
    final dealt = at;
    for (final ms in _dealFrames) {
      await until(dealt + ms);
      await _save(
        tester,
        key,
        '${run.name}_deal${ms.toString().padLeft(4, '0')}.png',
      );
      final problem = tester.takeException();
      if (problem != null) problems.add('${run.name} deal $ms: $problem');
    }
  }

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  final late = tester.takeException();
  if (late != null) problems.add('${run.name} (teardown): $late');
  state.dispose();
}
