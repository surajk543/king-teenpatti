// The 6-hour bonus (owner, 30 Sep 2026: "IN Top left Add Again Every 6 hours
// bonus 25000 Coins" — requirement 18's four-hour bonus, taken away that
// morning with the other two lobby rewards, back the same evening as six
// hours and 25,000 chips). Its chip stands in the top bar's left-hand corner,
// before the picture: counting down, the time left under its title; ready,
// the wallet's coin and what it pays (owner, 24 Sep 2026: "show coin icon
// instead of collect text"), and a tap collects it through
// POST /api/rewards/bonus. Tapped while it counts down it opens a popup
// with the reward, the wait and "A new bonus every 6 hours."; ready, the
// popup offers Collect. A server offering no bonus (no `user.rewards`) draws
// no chip and gives the name the whole bar. A RenderFlex overflow fails a
// test by itself.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
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

/// The bonus as the server sends it: a zero wait is a bonus ready now.
Map<String, dynamic> _rewards({Duration bonusIn = Duration.zero}) => {
  'bonusReward': 25000,
  'bonusReadyAt': bonusIn == Duration.zero ? 0 : _at(bonusIn),
  'bonusAvailable': bonusIn == Duration.zero,
  'bonusIntervalMs': 6 * 60 * 60 * 1000,
};

Map<String, dynamic> _userJson({Map<String, dynamic>? rewards}) => {
  'id': 'u1',
  'provider': 'guest',
  'displayName': 'Guest0E00B',
  'chips': 500000,
  'diamond': 5,
  'hammer': 10,
  'missile': 1,
  'rewards': ?rewards,
};

GameState _state(
  Map<String, dynamic>? rewards, {
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
    ..user = User.fromJson(_userJson(rewards: rewards));
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

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_loadInter);

  group('the account', () {
    test('reads the bonus, and a server without it offers none', () {
      final user = User.fromJson(_userJson(rewards: _rewards()));
      final r = user.rewards!;
      expect(r.bonusReward, 25000);
      expect(r.bonusReadyAt, 0);
      expect(r.bonusAvailable, isTrue);
      expect(r.bonusReady, isTrue);
      expect(r.bonusIntervalMs, 21600000);
      expect(r.bonusEveryHours, 6);
      expect(r.untilBonus, Duration.zero);
      // Recharging: the server's clock, and the time left counted from it.
      final later = User.fromJson(
        _userJson(rewards: _rewards(bonusIn: const Duration(hours: 5))),
      ).rewards!;
      expect(later.bonusReady, isFalse);
      expect(later.untilBonus.inMinutes, inInclusiveRange(299, 300));
      // The server's verdict wins over the phone's clock.
      final verdict = Rewards.fromJson({
        'bonusReward': 25000,
        'bonusReadyAt': _at(const Duration(hours: 1)),
        'bonusAvailable': true,
      });
      expect(verdict.bonusReady, isTrue);
      expect(verdict.bonusEveryHours, 6);
      // None from a server that predates it, and none in a copy of the
      // account that has it — the copies carry it.
      expect(User.fromJson(_userJson()).rewards, isNull);
      expect(user.withHammer(3).rewards, isNotNull);
      expect(user.withMissile(2).rewards!.bonusReward, 25000);
    });

    test('the eight strings exist in all five languages', () {
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        for (final s in [
          t.sixHourBonus,
          t.collect,
          t.bonusYouGet,
          t.bonusNextIn,
          t.bonusReadyNow,
          t.bonusEveryHours(6),
          t.bonusComeBack(6),
          t.bonusRefused,
        ]) {
          expect(s.trim(), isNotEmpty, reason: lang.code);
          expect(s, isNot(contains('{')), reason: '${lang.code}: $s');
        }
        expect(t.bonusEveryHours(6), contains('6'), reason: lang.code);
        expect(t.bonusComeBack(6), contains('6'), reason: lang.code);
      }
      expect(const Strings(AppLang.english).sixHourBonus, '6-HOUR BONUS');
      expect(
        const Strings(AppLang.english).bonusEveryHours(6),
        'A new bonus every 6 hours.',
      );
    });
  });

  group('the chip', () {
    testWidgets('stands at the top left, before the picture, and none '
        'without a bonus', (tester) async {
      final state = _state(_rewards(bonusIn: const Duration(hours: 1)));
      await _pumpLobby(tester, state);
      expect(tester.takeException(), isNull);
      final chip = tester.getRect(_chip(_bonus));
      final picture = tester.getRect(find.byTooltip(state.t.yourPicture));
      final screen = tester.view.physicalSize;
      expect(chip.left, lessThan(screen.width * 0.05));
      expect(chip.top, lessThan(screen.height * 0.2));
      expect(chip.right, lessThanOrEqualTo(picture.left + 0.5));
      expect(chip.height, greaterThanOrEqualTo(Dim.minTouch));
      expect(
        find.descendant(of: _chip(_bonus), matching: find.text('6-HOUR BONUS')),
        findsOneWidget,
      );
      await _unmount(tester);

      final none = _state(null);
      await _pumpLobby(tester, none);
      expect(_chip(_bonus), findsNothing);
      expect(find.text('6-HOUR BONUS'), findsNothing);
      final alone = tester.getRect(find.byTooltip(none.t.yourPicture));
      expect(alone.left, lessThanOrEqualTo(Space.md + 1));
      await _unmount(tester);
    });

    for (final lang in AppLang.values) {
      testWidgets('ready, in ${lang.englishName} at 640x360 x1.25, it pays in '
          'a coin and the figure, whole', (tester) async {
        final state = _state(_rewards(), lang: lang);
        final t = state.t;
        await _pumpLobby(tester, state);
        expect(tester.takeException(), isNull);
        final chip = _chip(_bonus);
        expect(chip, findsOneWidget);
        // No word — not Collect, in any language.
        for (final word in ['Collect', t.collect]) {
          expect(
            find.descendant(
              of: chip,
              matching: find.textContaining(word, findRichText: true),
            ),
            findsNothing,
            reason: 'the chip shows "$word" in ${lang.code}',
          );
        }
        // The coin the top bar counts chips with, before the figure.
        expect(
          find.descendant(of: chip, matching: find.byType(PokerChip)),
          findsOneWidget,
        );
        final figure = _figure(chip, formatChips(25000));
        expect(figure, findsOneWidget);
        _expectWhole(tester, figure, lang.code);
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      });
    }

    testWidgets('on the light theme too, in the wallet\'s own gold', (
      tester,
    ) async {
      final state = _state(_rewards());
      await _pumpLobby(tester, state, brightness: Brightness.light);
      final coin = tester.widget<PokerChip>(
        find.descendant(of: _chip(_bonus), matching: find.byType(PokerChip)),
      );
      expect(coin.colour, AppTheme.gold);
      _expectWhole(tester, _figure(_chip(_bonus), formatChips(25000)), 'light');
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });

    testWidgets('counting down, the time is written and no coin shown', (
      tester,
    ) async {
      final state = _state(
        _rewards(bonusIn: const Duration(hours: 5, minutes: 59, seconds: 30)),
      );
      await _pumpLobby(tester, state);
      expect(
        find.descendant(
          of: _chip(_bonus),
          matching: find.textContaining(RegExp(r'^5h 59m \d+s$')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _chip(_bonus), matching: find.byType(PokerChip)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });

    testWidgets('is the same size ready as counting down', (tester) async {
      final counting = _state(_rewards(bonusIn: const Duration(hours: 1)));
      await _pumpLobby(tester, counting);
      final before = tester.getSize(_chip(_bonus));
      await _unmount(tester);
      final ready = _state(_rewards());
      await _pumpLobby(tester, ready);
      final size = tester.getSize(_chip(_bonus));
      expect(size.height, before.height);
      expect(size.width, greaterThan(0));
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });

    testWidgets('a tap collects it: one POST with an empty body, the '
        'account taken from the answer, the celebration raised, and a '
        'second tap while the first is out sends nothing', (tester) async {
      final sent = <http.Request>[];
      var release = false;
      await http.runWithClient(
        () async {
          final state = _state(_rewards())..debugToken = 'tok';
          await _pumpLobby(tester, state);
          await tester.tap(_chip(_bonus));
          await tester.pump();
          // The lobby's own reads (the Friends key's count, the reward
          // programs) come and go; the bonus is one POST with an empty body.
          Iterable<http.Request> claims() =>
              sent.where((r) => r.url.path == '/api/rewards/bonus');
          expect(claims(), hasLength(1));
          expect(claims().single.method, 'POST');
          expect(claims().single.body, '{}');
          expect(state.claimingBonus, isTrue);
          // Pressed again meanwhile: nothing more is sent.
          await tester.tap(_chip(_bonus), warnIfMissed: false);
          await tester.pump();
          expect(claims(), hasLength(1));
          release = true;
          await tester.pump(const Duration(milliseconds: 50));
          await tester.pump(const Duration(milliseconds: 50));
          expect(state.claimingBonus, isFalse);
          expect(state.rewardWon?.kind, 'bonus');
          expect(state.rewardWon?.amount, 25000);
          expect(state.user?.chips, 525000);
          expect(state.user?.rewards?.bonusReady, isFalse);
          // The chip now counts down.
          await tester.pump(const Duration(seconds: 1));
          expect(
            find.descendant(
              of: _chip(_bonus),
              matching: find.textContaining(RegExp(r'^5h 59m \d+s$')),
            ),
            findsOneWidget,
          );
          await _unmount(tester);
        },
        () => MockClient((request) async {
          sent.add(request);
          while (!release) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          return _json({
            'claimed': true,
            'amount': 25000,
            'readyAt': _at(const Duration(hours: 6)),
            'user': _userJson(
              rewards: _rewards(bonusIn: const Duration(hours: 6)),
            )..['chips'] = 525000,
          });
        }),
      );
    });

    testWidgets('a refusal keeps the server\'s words and takes the '
        'account\'s clock afresh', (tester) async {
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = _state(_rewards())..debugToken = 'tok';
          await _pumpLobby(tester, state);
          await tester.tap(_chip(_bonus));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          expect(state.notice, 'The bonus is still recharging.');
          expect(state.rewardWon, isNull);
          // Told it is not ready, the account is read again for its clock.
          expect(
            sent
                .map((r) => r.url.path)
                .where((p) => p == '/api/rewards/bonus' || p == '/api/auth/me'),
            ['/api/rewards/bonus', '/api/auth/me'],
          );
          await tester.pump(const Duration(milliseconds: 50));
          expect(state.user?.rewards?.bonusReady, isFalse);
          await _unmount(tester);
        },
        () => MockClient((request) async {
          sent.add(request);
          if (request.url.path == '/api/auth/me') {
            return _json({
              'user': _userJson(
                rewards: _rewards(bonusIn: const Duration(hours: 3)),
              ),
            });
          }
          return _json({
            'error': 'reward_not_ready',
            'message': 'The bonus is still recharging.',
            'readyAt': _at(const Duration(hours: 3)),
          }, 409);
        }),
      );
    });
  });

  group('the popup', () {
    testWidgets('says what the bonus pays and how long is left, and closes', (
      tester,
    ) async {
      final state = _state(
        _rewards(bonusIn: const Duration(hours: 2, minutes: 30)),
      );
      await _pumpLobby(tester, state, screen: const Size(891, 411));
      await tester.tap(_chip(_bonus));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('6-HOUR BONUS'), findsNWidgets(2));
      expect(find.text('You will get'), findsOneWidget);
      expect(find.byKey(const ValueKey('bonus-details-chips')), findsOneWidget);
      expect(find.text('Next reward in'), findsOneWidget);
      // The popup's own countdown (the chip behind it counts too).
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('bonus-details-countdown')))
            .data,
        matches(RegExp(r'^2h (29|30)m')),
      );
      expect(find.text('A new bonus every 6 hours.'), findsOneWidget);
      // Nothing to take yet.
      expect(find.byKey(const ValueKey('bonus-details-collect')), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('Next reward in'), findsNothing);
      await _unmount(tester);
    });

    testWidgets('ready, it offers Collect, which closes it and collects', (
      tester,
    ) async {
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = _state(_rewards())..debugToken = 'tok';
          await _pumpLobby(tester, state, screen: const Size(891, 411));
          openBonusDetails(tester.element(find.byType(LobbyScreen)));
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          expect(find.text('Ready to collect now'), findsOneWidget);
          expect(find.text('Next reward in'), findsNothing);
          await tester.tap(find.byKey(const ValueKey('bonus-details-collect')));
          await tester.pump();
          await tester.pump(const Duration(seconds: 2));
          expect(find.text('Ready to collect now'), findsNothing);
          expect(
            sent.map((r) => r.url.path).where((p) => p == '/api/rewards/bonus'),
            ['/api/rewards/bonus'],
          );
          await _unmount(tester);
        },
        () => MockClient((request) async {
          sent.add(request);
          return _json({
            'claimed': true,
            'amount': 25000,
            'readyAt': _at(const Duration(hours: 6)),
            'user': _userJson(
              rewards: _rewards(bonusIn: const Duration(hours: 6)),
            ),
          });
        }),
      );
    });

    for (final size in const [
      Size(640, 360),
      Size(891, 411),
      Size(1280, 800),
    ]) {
      for (final lang in AppLang.values) {
        testWidgets(
          'lays out at $size in ${lang.englishName}, text x1.25, with the '
          'chip and the popup whole',
          (tester) async {
            final state = _state(
              _rewards(
                bonusIn: const Duration(hours: 5, minutes: 59, seconds: 59),
              ),
              lang: lang,
            );
            await _pumpLobby(tester, state, screen: size);
            expect(tester.takeException(), isNull, reason: '$size $lang chip');
            // The chip whole on the screen, its title uncut.
            final chip = tester.getRect(_chip(_bonus));
            expect(chip.left, greaterThanOrEqualTo(0));
            expect(chip.top, greaterThanOrEqualTo(0));
            for (final p in tester.renderObjectList<RenderParagraph>(
              find.descendant(
                of: _chip(_bonus),
                matching: find.byType(RichText),
              ),
            )) {
              expect(
                p.didExceedMaxLines,
                isFalse,
                reason: '$size ${lang.code}: ${p.text.toPlainText()}',
              );
            }
            await tester.tap(_chip(_bonus));
            await tester.pump();
            await tester.pump(const Duration(seconds: 2));
            expect(tester.takeException(), isNull, reason: '$size $lang popup');
            expect(find.text(state.t.bonusNextIn), findsOneWidget);
            await tester.tap(find.text(state.t.close));
            await tester.pump();
            await tester.pump(const Duration(seconds: 2));
            await _unmount(tester);
          },
        );
      }
    }
  });
}
