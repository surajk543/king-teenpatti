// The 4-hour and the daily bonus, tapped while they are still counting down
// (owner, 14 Sep 2026): a popup says what the bonus pays and how long is left,
// and offers Collect once it is ready. Laid out on the three screens the game
// is checked on, in all five languages, at the 1.25 text ceiling. A RenderFlex
// overflow fails a test by itself.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

int _at(Duration fromNow) =>
    DateTime.now().add(fromNow).millisecondsSinceEpoch;

/// Both bonuses; a zero wait is a bonus ready now.
Map<String, dynamic> _rewards({
  Duration bonusIn = Duration.zero,
  Duration dailyIn = Duration.zero,
}) => {
  'milestoneAvailable': false,
  'milestoneReward': 25000,
  'handsToNextMilestone': 4,
  'bonusReward': 10000,
  'bonusReadyAt': bonusIn == Duration.zero ? 0 : _at(bonusIn),
  'bonusAvailable': bonusIn == Duration.zero,
  'dailyReward': 100000,
  'dailyHammers': 1,
  'dailyReadyAt': dailyIn == Duration.zero ? 0 : _at(dailyIn),
  'dailyAvailable': dailyIn == Duration.zero,
};

GameState _state(
  Map<String, dynamic> rewards, {
  AppLang lang = AppLang.english,
}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = Screen.lobby
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 200000,
      'diamond': 2,
      'hammer': 20,
      'missile': 1,
      'rewards': rewards,
    });
}

void _setScreen(WidgetTester tester, Size size, {double scale = 1.0}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// An empty screen as main.dart builds one, returning a context to open the
/// popup from.
Future<BuildContext> _host(
  WidgetTester tester,
  GameState state,
  FeedbackSettings feedback,
) async {
  late BuildContext host;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(sound: false),
        builder: (context, child) => GlassBudget(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: child,
          ),
        ),
        home: Builder(
          builder: (context) {
            host = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  return host;
}

/// The popup, set out. Not pumpAndSettle: the hourglass never stops turning.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _close(
  WidgetTester tester,
  GameState state,
  FeedbackSettings feedback,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
  state.dispose();
  feedback.dispose();
}

void main() {
  setUpAll(_loadInter);

  testWidgets('the 4-hour bonus says what it pays and how long is left', (
    tester,
  ) async {
    _setScreen(tester, const Size(891, 411));
    final state = _state(
      _rewards(bonusIn: const Duration(hours: 2, minutes: 30)),
    );
    final feedback = FeedbackSettings();
    final host = await _host(tester, state, feedback);

    openBonusDetails(host, 'bonus');
    await _settle(tester);

    expect(find.text('4-HOUR BONUS'), findsOneWidget);
    expect(find.text('You will get'), findsOneWidget);
    expect(find.text(formatChips(10000)), findsOneWidget);
    expect(find.text('Next reward in'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^2h (29|30)m')), findsOneWidget);
    expect(find.text('A new bonus every 4 hours.'), findsOneWidget);
    // Nothing to take yet, and no hammer on the 4-hour bonus.
    expect(find.text('Collect'), findsNothing);
    expect(find.textContaining('Hammer'), findsNothing);

    await tester.tap(find.text('Close'));
    await _settle(tester);
    expect(find.text('Next reward in'), findsNothing);
    await _close(tester, state, feedback);
  });

  testWidgets('the daily bonus says its lakh and its hammer, and the wait', (
    tester,
  ) async {
    _setScreen(tester, const Size(891, 411));
    final state = _state(_rewards(dailyIn: const Duration(hours: 23)));
    final feedback = FeedbackSettings();
    final host = await _host(tester, state, feedback);

    openBonusDetails(host, 'daily');
    await _settle(tester);

    expect(find.text('DAILY BONUS'), findsOneWidget);
    expect(find.text(formatChips(100000)), findsOneWidget);
    expect(find.text('+1 Hammer'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^2[23]h \d+m')), findsOneWidget);
    expect(find.text('A new bonus every 24 hours.'), findsOneWidget);
    expect(find.text('Collect'), findsNothing);
    await _close(tester, state, feedback);
  });

  testWidgets('a bonus that is ready offers Collect, which closes the popup', (
    tester,
  ) async {
    _setScreen(tester, const Size(891, 411));
    final state = _state(_rewards());
    final feedback = FeedbackSettings();
    final host = await _host(tester, state, feedback);

    openBonusDetails(host, 'bonus');
    await _settle(tester);
    expect(find.text('Ready to collect now'), findsOneWidget);
    expect(find.text('Next reward in'), findsNothing);

    // No session in a unit test, so the claim itself goes nowhere; what is
    // checked is that the popup gets out of the celebration's way.
    await tester.tap(find.text('Collect'));
    await _settle(tester);
    expect(find.text('Ready to collect now'), findsNothing);
    await _close(tester, state, feedback);
  });

  group('lays out without overflowing', () {
    const screens = [Size(640, 360), Size(891, 411), Size(1280, 800)];
    for (final size in screens) {
      for (final lang in AppLang.values) {
        testWidgets('at $size in ${lang.englishName}, text x1.25', (
          tester,
        ) async {
          _setScreen(tester, size, scale: 1.25);
          final state = _state(
            _rewards(
              bonusIn: const Duration(hours: 3, minutes: 59, seconds: 59),
              dailyIn: const Duration(hours: 23, minutes: 59, seconds: 59),
            ),
            lang: lang,
          );
          final feedback = FeedbackSettings();
          final host = await _host(tester, state, feedback);

          for (final kind in ['bonus', 'daily']) {
            openBonusDetails(host, kind);
            await _settle(tester);
            expect(tester.takeException(), isNull, reason: kind);
            Navigator.of(host).pop();
            await _settle(tester);
          }
          await _close(tester, state, feedback);
        });
      }
    }
  });
}
