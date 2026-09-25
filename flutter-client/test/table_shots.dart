// Pictures of the Teen Patti table in every state the table polish brief
// names (24 Sep 2026), at the landscape phone sizes it is checked on, in both
// themes, at text x1.0 and x1.25, in Hindi at the tightest size, and behind a
// camera cutout. Not part of `flutter test` (the name has no `_test`): run it
// by hand.
//
//   flutter test test/table_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=02-your-turn   a substring of the names
//
// Every shot is laid out for real — the whole TableScreen, Inter and the
// Material icons loaded — and written to SHOTS_DIR as a PNG at twice the
// logical size. Anything that overflows or throws is written to
// SHOTS_DIR/problems.txt rather than failing the run. The scenes themselves
// are test/table_scenes.dart, which test/table_polish_test.dart lays out too.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/theme/app_theme.dart';

import 'table_scenes.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');

class _Shot {
  const _Shot(
    this.scene,
    this.size,
    this.dark,
    this.scale, {
    this.lang = AppLang.english,
    this.cutout = false,
  });
  final TableScene scene;
  final Size size;
  final bool dark;
  final double scale;
  final AppLang lang;
  final bool cutout;

  String get file =>
      '${scene.name}_${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}'
      '${cutout ? '_cutout' : ''}.png';
}

const _sizes = [
  Size(640, 360),
  Size(732, 412),
  Size(844, 390),
  Size(891, 411),
  Size(915, 412),
];

List<_Shot> _shots() => [
  for (final scene in tableScenes)
    for (final size in _sizes)
      for (final dark in [true, false])
        for (final scale in [1.0, 1.25]) _Shot(scene, size, dark, scale),
  for (final scene in tableScenes.where(
    (s) => const [
      '02-your-turn-blind',
      '03-your-turn-seen-sideshow',
      '06-showdown-card-reveal',
      '10-menu-drawer',
      '11-chat-drawer',
      '12-quick-messages',
    ].contains(s.name),
  ))
    for (final dark in [true, false])
      _Shot(scene, const Size(640, 360), dark, 1.25, lang: AppLang.hindi),
  for (final scene in tableScenes.where(
    (s) => const [
      '01-opponent-turn',
      '03-your-turn-seen-sideshow',
      '10-menu-drawer',
    ].contains(s.name),
  ))
    _Shot(scene, const Size(915, 412), true, 1.0, cutout: true),
];

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
  // A Devanagari face for the Hindi pass, as a phone falls back to one.
  for (final path in const [
    '/System/Library/Fonts/Supplemental/Devanagari Sangam MN.ttc',
    '/Library/Fonts/Arial Unicode.ttf',
    '/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final loader = FontLoader('Devanagari')
      ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await loader.load();
    break;
  }
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
  setUpAll(_loadFonts);
  final problems = <String>[];
  tearDownAll(() {
    if (_dir.isEmpty) return;
    File('$_dir/problems.txt').writeAsStringSync(
      problems.isEmpty ? 'none\n' : '${problems.join('\n')}\n',
    );
  });

  for (final shot in _shots()) {
    if (_only.isNotEmpty && !shot.file.contains(_only)) continue;
    testWidgets(shot.file, (tester) async {
      // The test binding draws every shadow as a solid block unless told not
      // to, which rings every lifted key in black; a picture wants them soft.
      debugDisableShadows = false;
      try {
        await _shoot(tester, shot, problems);
      } finally {
        debugDisableShadows = true;
      }
    });
  }
}

Future<void> _shoot(
  WidgetTester tester,
  _Shot shot,
  List<String> problems,
) async {
  tester.view.physicalSize = shot.size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = shot.cutout
      ? const FakeViewPadding(left: 32)
      : FakeViewPadding.zero;
  tester.platformDispatcher.textScaleFactorTestValue = shot.scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = sceneState(shot.scene, lang: shot.lang);

  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: tableApp(
        state: state,
        feedback: feedback,
        theme: _theme(shot.dark, shot.lang),
      ),
    ),
  );
  Future<void> settle(int ms) async {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump(Duration(milliseconds: ms));
  }

  await settle(900);
  await settle(900);
  final act = shot.scene.act;
  if (act != null) {
    await act(tester, state);
    await settle(700);
  }
  await settle(300);
  final problem = tester.takeException();
  if (problem != null) problems.add('${shot.file}: $problem');

  if (_dir.isNotEmpty) {
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_dir/${shot.file}').writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  final late = tester.takeException();
  if (late != null) problems.add('${shot.file} (teardown): $late');
  state.dispose();
}
