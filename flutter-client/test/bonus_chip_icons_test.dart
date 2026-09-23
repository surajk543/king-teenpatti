// The lobby's two bonus chips once their reward is ready (owner, 24 Sep 2026):
// "In daily Bonus button instead of showing text 'collect' show coins icon and
// instead of text 'Hammer' show icon. Same in case of 4 Hour Bonus show coin
// icon instead of collect text." The second line is what the reward pays, as
// the top bar's own glyphs and the figures — a coin before the chips, "+1" and
// the hammer after them — and no word; "Collect 1,00,000 +1 Hammer" was cut to
// "Collect 100,000 +..." on a 640dp phone, so the line is held to fit there
// whole at the 1.25 text ceiling. The countdown, the milestone chip and the
// popup keep their words. A RenderFlex overflow fails a test by itself.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/poker_chip.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

int _at(Duration fromNow) => DateTime.now().add(fromNow).millisecondsSinceEpoch;

/// The three rewards as the server sends them: a bonus with no wait is ready.
Map<String, dynamic> _rewards({
  Duration bonusIn = Duration.zero,
  Duration dailyIn = Duration.zero,
  bool milestone = false,
}) => {
  'milestoneAvailable': milestone,
  'milestoneReward': 25000,
  'handsToNextMilestone': milestone ? 0 : 4,
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
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
        {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
      ],
    })
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

/// The lobby on a 640x360 phone at the 1.25 text ceiling, the tightest
/// layout the app must survive, unless a test says otherwise.
Future<void> _pumpLobby(
  WidgetTester tester,
  GameState state, {
  Size screen = const Size(640, 360),
  double textScale = 1.25,
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  addTearDown(state.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: brightness == Brightness.dark
            ? AppTheme.dark(sound: false)
            : AppTheme.light(sound: false),
        builder: (context, child) => GlassBudget(child: child!),
        home: const LobbyScreen(),
      ),
    ),
  );
  // The cards' entrances and the balance's count-up.
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// Nothing pumped in the tree ends the hourglass and the drifting chips before
/// the state is disposed.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// A private widget of the lobby by its type's name.
Finder _chip(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

const _bonus = '_BonusChip';
const _daily = '_DailyBonusChip';
const _milestone = '_MilestoneChip';

/// A figure on the chip's second line, by its text.
Finder _figure(Finder chip, String text) =>
    find.descendant(of: chip, matching: find.text(text));

/// The paragraph was given the room it asked for: nothing was cut to "…".
void _expectWhole(WidgetTester tester, Finder paragraph, String reason) {
  final p = tester.renderObject<RenderParagraph>(paragraph);
  expect(
    p.size.width,
    greaterThanOrEqualTo(p.getMaxIntrinsicWidth(p.size.height) - 0.01),
    reason: '$reason: the figure was ellipsised',
  );
}

void main() {
  setUpAll(_loadInter);

  group('ready, at 640x360 with text x1.25', () {
    for (final lang in AppLang.values) {
      testWidgets('in ${lang.englishName} both chips pay in glyphs, whole', (
        tester,
      ) async {
        final state = _state(_rewards(), lang: lang);
        final t = state.t;
        await _pumpLobby(tester, state);
        expect(tester.takeException(), isNull);

        for (final type in [_bonus, _daily]) {
          final chip = _chip(type);
          expect(chip, findsOneWidget, reason: type);
          // No word — not Collect, not Hammer, in any language.
          for (final word in [
            'Collect',
            'Hammer',
            t.collect,
            t.plusHammers(1),
          ]) {
            expect(
              find.descendant(
                of: chip,
                matching: find.textContaining(word, findRichText: true),
              ),
              findsNothing,
              reason: '$type shows "$word" in ${lang.code}',
            );
          }
          // The coin the top bar counts chips with, before the figure.
          expect(
            find.descendant(of: chip, matching: find.byType(PokerChip)),
            findsOneWidget,
            reason: type,
          );
          final figure = _figure(
            chip,
            formatChips(type == _daily ? 100000 : 10000),
          );
          expect(figure, findsOneWidget, reason: type);
          _expectWhole(tester, figure, '$type in ${lang.code}');
          // And the hammer, only where a hammer is paid.
          expect(
            find.descendant(of: chip, matching: find.byIcon(Icons.hardware)),
            type == _daily ? findsOneWidget : findsNothing,
            reason: type,
          );
          expect(
            _figure(chip, '+1'),
            type == _daily ? findsOneWidget : findsNothing,
            reason: type,
          );
          if (type == _daily) _expectWhole(tester, _figure(chip, '+1'), type);
        }
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });
    }
  });

  testWidgets('on the light theme too, in the wallet\'s own inks', (tester) async {
    final state = _state(_rewards());
    await _pumpLobby(tester, state, brightness: Brightness.light);
    for (final type in [_bonus, _daily]) {
      final chip = _chip(type);
      final coin = tester.widget<PokerChip>(
        find.descendant(of: chip, matching: find.byType(PokerChip)),
      );
      // The wallet's coin, the top bar's gold on either theme — not the
      // chip's champagne foreground (review, 24 Sep 2026).
      expect(coin.colour, AppTheme.gold, reason: type);
      _expectWhole(
        tester,
        _figure(chip, formatChips(type == _daily ? 100000 : 10000)),
        type,
      );
    }
    final hammer = tester.widget<Icon>(
      find.descendant(of: _chip(_daily), matching: find.byIcon(Icons.hardware)),
    );
    // And the hammer in its copper, as the bar draws it on a light ground.
    expect(hammer.color, hammerInkOn(Brightness.light));
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets(
    'counting down, the time is still written, and the milestone keeps its '
    'word',
    (tester) async {
      final state = _state(
        _rewards(
          bonusIn: const Duration(hours: 3, minutes: 59, seconds: 30),
          dailyIn: const Duration(hours: 23, minutes: 59, seconds: 30),
          milestone: true,
        ),
      );
      await _pumpLobby(tester, state);

      expect(
        find.descendant(
          of: _chip(_bonus),
          matching: find.textContaining(RegExp(r'^3h 59m \d+s$')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _chip(_daily),
          matching: find.textContaining(RegExp(r'^23h 59m \d+s$')),
        ),
        findsOneWidget,
      );
      for (final type in [_bonus, _daily]) {
        expect(
          find.descendant(of: _chip(type), matching: find.byType(PokerChip)),
          findsNothing,
          reason: type,
        );
        expect(
          find.descendant(
            of: _chip(type),
            matching: find.byIcon(Icons.hardware),
          ),
          findsNothing,
          reason: type,
        );
      }
      // The milestone was not asked about and reads as it did.
      expect(
        find.descendant(
          of: _chip(_milestone),
          matching: find.text('Collect ${formatChips(25000)}'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  testWidgets('a chip is the same size ready as counting down', (tester) async {
    // Both states carry the same body, so a chip becoming claimable does not
    // shove the row it is in — the glyphs must not grow the line.
    final counting = _state(
      _rewards(
        bonusIn: const Duration(hours: 1),
        dailyIn: const Duration(hours: 1),
      ),
    );
    await _pumpLobby(tester, counting);
    final before = {
      for (final type in [_bonus, _daily]) type: tester.getSize(_chip(type)),
    };
    await _unmount(tester);

    final ready = _state(_rewards());
    await _pumpLobby(tester, ready);
    for (final type in [_bonus, _daily]) {
      final size = tester.getSize(_chip(type));
      expect(size.height, before[type]!.height, reason: type);
      expect(size.width, greaterThan(0), reason: type);
    }
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });
}
