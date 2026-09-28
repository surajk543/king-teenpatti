// Pictures of the app version gate's surfaces (owner, 28 Sep 2026): Force
// Update, Maintenance (with the app's own words and with an operator's
// message) and the Soft Update prompt over the sign-in screen — each in the
// real app root — at 640x360, 844x390 and 915x412, both themes, text x1.0 and
// x1.25, and in Hindi at the tightest size. Not part of `flutter test` (the
// name has no `_test`): run it by hand.
//
//   flutter test test/app_gate_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=update_640   a substring of the names
//
// Each picture is the whole screen at twice its size; anything that overflows
// or throws is written to SHOTS_DIR/problems.txt rather than failing the run.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/net/app_version.dart';
import 'package:teenpatti/screens/login_screen.dart';
import 'package:teenpatti/screens/update_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');
const _operatorWords =
    'We are moving King Teen Patti to a faster server. Back at 14:00 IST.';

enum _Surface { update, maintenance, maintenanceMessage, softUpdate }

class _Shot {
  const _Shot(
    this.surface,
    this.size,
    this.dark,
    this.scale, {
    this.lang = AppLang.english,
  });

  final _Surface surface;
  final Size size;
  final bool dark;
  final double scale;
  final AppLang lang;

  String get file =>
      '${surface.name}_${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}';
}

final _shots = [
  for (final surface in _Surface.values)
    for (final size in const [Size(640, 360), Size(844, 390), Size(915, 412)])
      for (final dark in [true, false])
        for (final scale in [1.0, 1.25]) _Shot(surface, size, dark, scale),
  for (final surface in _Surface.values)
    _Shot(surface, const Size(640, 360), true, 1.25, lang: AppLang.hindi),
];

void main() {
  setUpAll(() async {
    await loadScriptFonts();
    // On a Mac (no Noto fonts at the Linux path script_fonts.dart reads) the
    // system's own Indic fonts stand in under the Noto names, so the Hindi
    // pictures show Hindi rather than empty boxes.
    if (!haveScriptFonts()) {
      const mac = {
        'Noto Sans Devanagari': '/System/Library/Fonts/Kohinoor.ttc',
        'Noto Sans Bengali': '/System/Library/Fonts/KohinoorBangla.ttc',
        'Noto Sans Gujarati': '/System/Library/Fonts/KohinoorGujarati.ttc',
        'Noto Sans Gurmukhi': '/System/Library/Fonts/Supplemental/Gurmukhi.ttf',
      };
      for (final MapEntry(key: family, value: path) in mac.entries) {
        final file = File(path);
        if (!file.existsSync()) continue;
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
        await loader.load();
      }
    }
    final icons = File(const String.fromEnvironment('ICON_FONT'));
    if (icons.path.isNotEmpty && icons.existsSync()) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
      await loader.load();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final problems = <String>[];
  tearDownAll(() {
    if (_dir.isEmpty) return;
    File('$_dir/problems.txt').writeAsStringSync(
      problems.isEmpty ? 'none\n' : '${problems.join('\n')}\n',
    );
  });

  for (final shot in _shots) {
    if (_only.isNotEmpty &&
        !_only.split(',').any((term) => shot.file.contains(term))) {
      continue;
    }
    testWidgets(shot.file, (tester) async {
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
  tester.platformDispatcher.textScaleFactorTestValue = shot.scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  state
    ..lang = shot.lang
    ..themeMode = shot.dark ? ThemeMode.dark : ThemeMode.light
    ..appVersion = '1.4.2 (12)';
  switch (shot.surface) {
    case _Surface.update:
      state.handleAppGate(
        AppGateVerdict(
          AppGateStatus.forceUpdate,
          storeUrl:
              'https://play.google.com/store/apps/details?id=com.sungamestudio.kingteenpatti',
          minimumVersion: SemVer.tryParse('1.5.0'),
        ),
      );
      state.screen = Screen.update;
    case _Surface.maintenance:
      state.handleAppGate(const AppGateVerdict(AppGateStatus.maintenance));
      state.screen = Screen.maintenance;
    case _Surface.maintenanceMessage:
      state.handleAppGate(
        const AppGateVerdict(
          AppGateStatus.maintenance,
          message: _operatorWords,
        ),
      );
      state.screen = Screen.maintenance;
    case _Surface.softUpdate:
      state
        ..screen = Screen.login
        ..softUpdate = AppGateVerdict(
          AppGateStatus.softUpdate,
          latestVersion: SemVer.tryParse('1.6.2'),
        );
  }

  // The app's own screens under the app's theme, with the script fallback a
  // phone applies by itself made explicit (script_fonts.dart).
  final base = shot.dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  final boundary = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: MultiProvider(
        providers: [
          ChangeNotifierProvider<GameState>.value(value: state),
          ChangeNotifierProvider<FeedbackSettings>.value(
            value: FeedbackSettings(),
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: withScriptFallback(base),
          builder: (context, child) => MediaQuery.withClampedTextScaling(
            minScaleFactor: 0.9,
            maxScaleFactor: 1.25,
            child: GlassBudget(child: child!),
          ),
          home: switch (shot.surface) {
            _Surface.update => const UpdateScreen(),
            _Surface.maintenance ||
            _Surface.maintenanceMessage => const MaintenanceScreen(),
            _Surface.softUpdate => const Stack(
              fit: StackFit.expand,
              children: [LoginScreen(), SoftUpdatePrompt()],
            ),
          },
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 900));
  final problem = tester.takeException();
  if (problem != null) problems.add('${shot.file}: $problem');
  if (_dir.isNotEmpty) {
    await tester.runAsync(() async {
      final box =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await box.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '$_dir/${shot.file}.png',
      ).writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}
