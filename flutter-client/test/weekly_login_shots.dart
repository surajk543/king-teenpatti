// Pictures of the weekly login popup (30 Sep 2026), by hand, not part of
// `flutter test`:
//
//   flutter test test/weekly_login_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//
// The lobby with the popup up — the third day still to collect — and again
// once it is collected, at 640x360 and 891x411, both themes, x1.0 and x1.25,
// and Hindi at 640x360, written to SHOTS_DIR as PNGs at twice the logical
// size. Anything that throws goes to SHOTS_DIR/problems.txt.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'reward_fixtures.dart';
import 'script_fonts.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');

class _Shot {
  const _Shot(this.size, this.dark, this.scale, {this.lang = AppLang.english});
  final Size size;
  final bool dark;
  final double scale;
  final AppLang lang;

  String get tag =>
      '${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}';
}

final _shots = [
  for (final size in const [Size(640, 360), Size(891, 411)])
    for (final dark in [true, false])
      for (final scale in [1.0, 1.25]) _Shot(size, dark, scale),
  const _Shot(Size(640, 360), true, 1.25, lang: AppLang.hindi),
  const _Shot(Size(592, 360), false, 1.25, lang: AppLang.bengali),
];

Future<void> _loadFonts() async {
  await loadRewardFonts();
  final icons = File(const String.fromEnvironment('ICON_FONT'));
  if (icons.path.isNotEmpty && icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
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

  for (final shot in _shots) {
    testWidgets(shot.tag, (tester) async {
      tester.view.physicalSize = shot.size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = shot.scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      SharedPreferences.setMockInitialValues({'soundOn': false});
      final feedback = FeedbackSettings();
      await feedback.load();
      addTearDown(feedback.dispose);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = rewardState(lang: shot.lang);
          final key = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MultiProvider(
                providers: [
                  ChangeNotifierProvider<GameState>.value(value: state),
                  ChangeNotifierProvider<FeedbackSettings>.value(
                    value: feedback,
                  ),
                ],
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: withScriptFallback(
                    shot.dark
                        ? AppTheme.dark(sound: false)
                        : AppTheme.light(sound: false),
                  ),
                  builder: (context, child) => GlassBudget(
                    child: Scaffold(
                      backgroundColor: Colors.transparent,
                      resizeToAvoidBottomInset: false,
                      body: child ?? const SizedBox.shrink(),
                    ),
                  ),
                  home: const LobbyScreen(),
                ),
              ),
            ),
          );
          Future<void> real([int ms = 60]) => tester.runAsync(
            () => Future<void>.delayed(Duration(milliseconds: ms)),
          );
          Future<void> snap(String moment) async {
            await real(30);
            await tester.pump(const Duration(milliseconds: 1));
            final problem = tester.takeException();
            if (problem != null) problems.add('${shot.tag}-$moment: $problem');
            if (_dir.isEmpty) return;
            await tester.runAsync(() async {
              final boundary =
                  key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 2);
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File(
                '$_dir/weekly-${moment}_${shot.tag}.png',
              ).writeAsBytesSync(data!.buffer.asUint8List());
              image.dispose();
            });
          }

          await tester.pump();
          await real();
          await tester.pump(const Duration(seconds: 1));
          await real();
          await tester.pump(const Duration(milliseconds: 700));
          await snap('popping');
          await tester.pump(const Duration(seconds: 2));
          await real();
          await snap('due');
          await tester.tap(find.byKey(const ValueKey('weekly-login-collect')));
          await tester.pump();
          await real();
          await tester.pump(const Duration(milliseconds: 600));
          await real();
          await tester.pump(const Duration(seconds: 1));
          await snap('collected');
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
          state.dispose();
        },
        () => fakeRewards(
          sent: sent,
          programs: {
            'programs': [streakJson(claimedToday: false), calendarJson()],
          },
          claim: claimJson(
            granted: twoGrants(),
            programs: [streakJson(), calendarJson(claimedToday: true)],
            chips: 1020000,
          ),
        ),
      );
    });
  }
}
