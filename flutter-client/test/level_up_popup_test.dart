// The popup that congratulates a player on a new level (owner, 2 Oct 2026:
// "Use this animation to COngrats Player once his level upgraded , show a pop
// in UI, and Tell in pop up that something like that now you will pay less
// tax and how much less tax u pay tell that in pop up"): which standings
// raise it, what it says about the winning tax, how it is put away, where it
// waits, and that it fits every phone in every language — and its sound
// (owner, the same day: "play this sound when congrats pop up comes and when
// pop up closed, stop this sound"): `Congrats.mp3` from the moment the popup
// appears to the moment it is put away.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/main.dart' show KingTeenPattiApp;
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/level_up.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/level_up_popup.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/xp_mission_bar.dart';

import 'level_fixtures.dart';
import 'table_scenes.dart' show seenTurnRoom, silentFeedback;

final int _window = DateTime.now().millisecondsSinceEpoch + 20 * hourMs;

/// A level-[level] standing's `playerLevel` at [xp].
Map<String, Object?> _lv(
  int level,
  int xp, {
  Map<String, int> claimed = const {},
}) {
  final (n, _, title, icon, taxBps) = ownersLevels[level - 1];
  final next = level < ownersLevels.length ? ownersLevels[level] : null;
  return {
    'level': n,
    'title': title,
    'icon': icon,
    'xp': xp,
    'taxBps': taxBps,
    if (next != null)
      'next': {
        'level': next.$1,
        'title': next.$3,
        'icon': next.$4,
        'minXp': next.$2,
        'taxBps': next.$5,
      },
    'daily': {'claimed': claimed, 'resetsAt': _window},
  };
}

PlayerLevel _pl(Map<String, Object?> j) => PlayerLevel.maybe(j)!;

Standing _standing(
  Map<String, Object?> level, {
  List<Map<String, Object?>>? badges,
  int? taxBps,
}) => Standing.maybe({
  'playerLevel': level,
  'badges': badges ?? [regularBadge()],
  'taxBps': taxBps ?? level['taxBps'],
})!;

List<Map<String, Object?>> _royal() => [
  regularBadge(),
  royalBadge('ROYAL_ACE', const Duration(days: 3)),
];

/// The app as main.dart builds it above the Navigator: the mission bar, and
/// over it the level-up popup.
Widget _app(
  GameState state,
  FeedbackSettings feedback,
  Widget home,
  bool dark,
) => MultiProvider(
  providers: [
    ChangeNotifierProvider<GameState>.value(value: state),
    ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: levelTheme(dark: dark),
    builder: (context, child) => MediaQuery.withClampedTextScaling(
      minScaleFactor: 0.9,
      maxScaleFactor: 1.25,
      child: GlassBudget(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Scaffold(
              backgroundColor: Colors.transparent,
              resizeToAvoidBottomInset: false,
              body: child ?? const SizedBox.shrink(),
            ),
            const XpMissionHost(),
            const LevelUpHost(),
          ],
        ),
      ),
    ),
    home: home,
  ),
);

/// What the app asks the audio plugin to do, in order, past the Sound switch
/// (which the real [FeedbackSettings] still applies): the popup's cheer, and
/// the lobby's music that waits under it. No audio plugin runs here.
class _Heard extends FeedbackSettings {
  final heard = <String>[];

  /// Only what was asked of the cheer, and only what was asked of the music.
  List<String> get cheer => [
    for (final h in heard)
      if (h.startsWith('cheer')) h,
  ];
  List<String> get music => [
    for (final h in heard)
      if (h.startsWith('music')) h,
  ];

  // The game's other clips are not this file's business.
  @override
  Future<void> playClip(
    String asset, {
    required double volume,
    required int voice,
  }) async {}

  @override
  Future<void> startFanfare(String asset, {required double volume}) async =>
      heard.add('cheer start $asset @$volume');

  @override
  Future<void> stopFanfare() async => heard.add('cheer stop');

  @override
  Future<void> startLoop(String asset, {required double volume}) async =>
      heard.add('music start');

  @override
  Future<void> pauseLoop() async => heard.add('music pause');

  @override
  Future<void> resumeLoop() async => heard.add('music resume');

  @override
  Future<void> stopLoop() async => heard.add('music stop');
}

const _cheer = 'cheer start sound/Congrats.mp3 @0.85';

Future<void> _mount(
  WidgetTester tester,
  GameState state, {
  Widget home = const LobbyScreen(),
  Size screen = const Size(640, 360),
  double scale = 1.0,
  bool dark = true,
  FeedbackSettings? sounds,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = sounds ?? await silentFeedback();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(_app(state, feedback, home, dark));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 20));
  state.dispose();
}

/// In and settled.
Future<void> _arrive(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(LevelUpHost.enter + const Duration(milliseconds: 40));
}

/// Out and gone.
Future<void> _gone(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(LevelUpHost.leave + const Duration(milliseconds: 40));
}

final Finder _popup = find.byKey(const ValueKey('level-up-popup'));

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(ValueKey(key))).data!;

/// Level 1 at 95 XP lifted to Level 2: the owner's ladder takes the winning
/// tax from 20% to 19.71%.
GameState _atLevelOne({AppLang lang = AppLang.english}) =>
    levelState(level: _lv(1, 95), lang: lang);

void _levelUp(GameState state) =>
    state.handlePlayerLevel(_standing(_lv(2, 115, claimed: {'WIN_TRAIL': 1})));

void main() {
  setUpAll(() async {
    primeBadges();
    primeLevelArt();
    await loadLevelFonts();
  });

  group('what a level up tells', () {
    test('the tax paid before is the lowest of the level\'s rate and the '
        'badges\' that still run', () {
      final now = DateTime.now();
      final one = _pl(_lv(1, 95));
      expect(LevelUps.paidAt(one, const [], now), 2000);
      final regular = PlayerBadge.listOf([regularBadge()]);
      expect(LevelUps.paidAt(_pl(_lv(10, 4200)), regular, now), 1743);
      final royal = PlayerBadge.listOf(_royal());
      expect(LevelUps.paidAt(one, royal, now), 0);
      // A badge that has run out no longer counts, and one with no rate
      // never did.
      final lapsed = PlayerBadge.listOf([
        regularBadge(),
        {
          ...royalBadge('ROYAL_ACE', const Duration(days: 3)),
          'expiresAt': now.millisecondsSinceEpoch - 1000,
        },
        {'code': 'PLAIN', 'title': 'Plain'},
      ]);
      expect(LevelUps.paidAt(one, lapsed, now), 2000);
    });

    test('player:level that lifts the player a level raises the popup: the '
        'level, what was paid, what is paid, and how much less — and no '
        'toast', () {
      final state = _atLevelOne();
      expect(state.levelUps.current, isNull);
      _levelUp(state);
      final news = state.levelUps.current!;
      expect(news.from.level, 1);
      expect(news.to.level, 2);
      expect(news.paidBefore, 2000);
      expect(news.paidNow, 1971);
      expect(news.savedBps, 29);
      expect(news.paysLess, isTrue);
      expect(news.rateBadge, isNull);
      expect(state.notice, isNull, reason: 'the popup says it, not a toast');
      // The mission that brought the XP is still told on its bar.
      expect(state.xpMissions.queue.map((n) => n.code), ['WIN_TRAIL']);

      final lines = LevelUpLines.of(state.t, news);
      expect(lines.kicker, 'Level up');
      expect(lines.level, 'Level 2 · Rookie');
      expect(lines.reached, 'You reached Level 2 · Rookie');
      expect(lines.headline, 'You now pay less winning tax');
      expect(lines.before, '20%');
      expect(lines.now, '19.71%');
      expect(lines.detail, 'You pay 0.29% less than before');
      expect(
        lines.spoken,
        'Level up. You reached Level 2 · Rookie. You now pay less winning '
        'tax. 20% → 19.71%. You pay 0.29% less than before',
      );
      state.dispose();
    });

    test('more XP at the same level, the same standing again and an older '
        'one heard late raise nothing', () {
      final state = levelState(level: _lv(2, 115));
      state.seeSessionStanding();
      state.handlePlayerLevel(_standing(_lv(2, 140, claimed: {'WIN_PAIR': 1})));
      expect(state.levelUps.current, isNull);
      state.handlePlayerLevel(_standing(_lv(2, 140, claimed: {'WIN_PAIR': 1})));
      expect(state.levelUps.current, isNull);

      // Up to Level 3, put away; then the Level 2 standing heard late, and
      // the Level 3 one again: neither raises it a second time.
      state.handlePlayerLevel(_standing(_lv(3, 260)));
      final first = state.levelUps.current!;
      expect(first.to.level, 3);
      state.levelUps.dismiss(first.id);
      state.handlePlayerLevel(_standing(_lv(2, 140)));
      expect(state.levelUps.current, isNull);
      state.handlePlayerLevel(_standing(_lv(3, 260)));
      expect(state.levelUps.current, isNull);
      state.dispose();
    });

    test('an account /api/auth/me refreshed before the push is still '
        'congratulated, with the rate it paid before', () {
      final state = _atLevelOne();
      state.seeSessionStanding();
      // The refresh lands first: the account already reads Level 2 at 19.71%.
      state.user = playerUser(level: _lv(2, 115, claimed: {'WIN_TRAIL': 1}));
      expect(state.user!.paysTaxBps, 1971);
      _levelUp(state);
      final news = state.levelUps.current!;
      expect(news.from.level, 1);
      expect(news.to.level, 2);
      expect(news.paidBefore, 2000);
      expect(news.paidNow, 1971);
      state.dispose();
    });

    test('under a badge that keeps the rate lower, the popup says the badge '
        'holds it and what the level\'s own rate became', () {
      final state = levelState(level: _lv(1, 95), badges: _royal(), taxBps: 0);
      state.handlePlayerLevel(
        _standing(
          _lv(2, 115, claimed: {'WIN_TRAIL': 1}),
          badges: _royal(),
          taxBps: 0,
        ),
      );
      final news = state.levelUps.current!;
      expect(news.paidBefore, 0);
      expect(news.paidNow, 0);
      expect(news.paysLess, isFalse);
      expect(news.rateBadge!.code, 'ROYAL_ACE');
      final lines = LevelUpLines.of(state.t, news);
      expect(lines.hasRates, isFalse);
      expect(
        lines.headline,
        'Your Royal Ace badge already keeps your winning tax at 0%.',
      );
      expect(lines.detail, 'This level\'s own rate is 19.71%, down from 20%.');
      state.dispose();
    });

    test('a second level up before the first is put away is one popup for '
        'the whole climb', () {
      final state = _atLevelOne();
      _levelUp(state);
      final first = state.levelUps.current!;
      state.handlePlayerLevel(_standing(_lv(3, 260)));
      final both = state.levelUps.current!;
      expect(both.id, isNot(first.id));
      expect(both.from.level, 1);
      expect(both.to.level, 3);
      expect(both.paidBefore, 2000);
      expect(both.paidNow, 1943);
      expect(LevelUpLines.of(state.t, both).detail, contains('0.57%'));
      // The first popup's id no longer puts anything away; the current one's
      // does.
      state.levelUps.dismiss(first.id);
      expect(state.levelUps.current, isNotNull);
      state.levelUps.dismiss(both.id);
      expect(state.levelUps.current, isNull);
      state.dispose();
    });

    test('a ladder that gives two levels one rate says nothing about tax', () {
      final from = _pl({..._lv(1, 95), 'taxBps': 2000});
      final to = _pl({..._lv(2, 115), 'taxBps': 2000});
      final news = LevelUps().raise(
        from: from,
        to: to,
        paidBefore: 2000,
        paidNow: 2000,
      );
      final lines = LevelUpLines.of(Strings(AppLang.english), news);
      expect(lines.headline, isNull);
      expect(lines.detail, isNull);
      expect(lines.hasRates, isFalse);
      expect(lines.spoken, 'Level up. You reached Level 2 · Rookie');
    });

    for (final lang in AppLang.values) {
      test('the popup reads in ${lang.englishName}', () {
        final state = _atLevelOne(lang: lang);
        _levelUp(state);
        final t = Strings(lang);
        final lines = LevelUpLines.of(t, state.levelUps.current!);
        expect(lines.level, t.levelName(2, 'Rookie'));
        expect(lines.reached, contains(lines.level));
        expect(lines.before, '20%');
        expect(lines.now, '19.71%');
        expect(lines.detail, contains('0.29%'));
        final english = Strings(AppLang.english);
        if (lang != AppLang.english) {
          // Written in the language itself, not fallen back to English.
          expect(lines.kicker, isNot(english.levelUpKicker));
          expect(lines.headline, isNot(english.levelUpPaysLess));
          expect(lines.detail, isNot(english.levelUpSaved('0.29%')));
          expect(
            t.levelUpBadgeKeeps('Royal Ace', '0%'),
            isNot(english.levelUpBadgeKeeps('Royal Ace', '0%')),
          );
          expect(
            t.levelUpLevelRate('19.71%', '20%'),
            isNot(english.levelUpLevelRate('19.71%', '20%')),
          );
        }
        for (final line in [
          t.levelUpBadgeKeeps('Royal Ace', '0%'),
          t.levelUpLevelRate('19.71%', '20%'),
          lines.reached,
          lines.detail!,
        ]) {
          expect(line, isNot(contains('{')), reason: line);
        }
        state.dispose();
      });
    }
  });

  group('the owner\'s animation', () {
    test('is the file the popup recolours by its layers\' names: the word '
        'in three text layers named C with its glyphs embedded, the rings '
        'under layers named B, and nothing a phone cannot draw', () {
      final raw = File(CongratsArt.asset).readAsStringSync();
      final file = jsonDecode(raw) as Map<String, dynamic>;
      expect(file['w'], 1000);
      expect(file['h'], 1000);
      final layers = (file['layers'] as List).cast<Map<String, dynamic>>();
      final word = layers.where((l) => l['nm'] == CongratsArt.wordPath.single);
      expect(word.length, 3);
      expect(word.every((l) => l['ty'] == 5), isTrue, reason: 'text layers');
      final rings = layers.where((l) => l['nm'] == CongratsArt.ringsPath.first);
      expect(rings.length, 5);
      expect(rings.every((l) => l['ty'] == 0), isTrue, reason: 'precomps');
      // The word is drawn from the file's own glyphs: no font is needed.
      final glyphs = (file['chars'] as List).map((c) => (c as Map)['ch']);
      expect(glyphs.toSet(), 'Congrats!'.split('').toSet());
      // No expressions, no 3D layers, no embedded images.
      expect(RegExp(r'"x"\s*:\s*"').hasMatch(raw), isFalse);
      expect(layers.any((l) => l['ddd'] == 1), isFalse);
      expect(
        (file['assets'] as List).any((a) => (a as Map).containsKey('p')),
        isFalse,
      );
    });

    test('plays in its own colours by day and in gold by night', () {
      expect(CongratsArt.delegatesFor(Brightness.light), isNull);
      final night = CongratsArt.delegatesFor(Brightness.dark)!;
      expect(night.values, hasLength(2));
      expect(
        identical(night, CongratsArt.delegatesFor(Brightness.dark)),
        isTrue,
        reason: 'one object: a new one each build would restart the art',
      );
      // Gold on the dark popup reads; the file's navy would not.
      double contrast(Color a, Color b) {
        final la = a.computeLuminance(), lb = b.computeLuminance();
        return (la > lb ? la + 0.05 : lb + 0.05) /
            (la > lb ? lb + 0.05 : la + 0.05);
      }

      final ground = AppTheme.panelBase(Brightness.dark);
      expect(contrast(AppTheme.goldOnDark, ground), greaterThan(4.5));
      expect(contrast(const Color(0xFF001D87), ground), lessThan(1.6));
    });
  });

  group('the popup', () {
    testWidgets('congratulates over the lobby: the animation, the level, the '
        'two rates and how much less', (tester) async {
      final state = _atLevelOne();
      await _mount(tester, state);
      expect(_popup, findsNothing);
      _levelUp(state);
      await _arrive(tester);
      expect(_popup, findsOneWidget);
      expect(find.byType(CongratsArt), findsOneWidget);
      expect(
        find.descendant(of: _popup, matching: find.byType(Lottie)),
        findsWidgets,
      );
      expect(_text(tester, 'level-up-kicker'), 'LEVEL UP');
      expect(_text(tester, 'level-up-level'), 'Level 2 · Rookie');
      expect(
        _text(tester, 'level-up-headline'),
        'You now pay less winning tax',
      );
      expect(_text(tester, 'level-up-rate-before'), '20%');
      expect(_text(tester, 'level-up-rate-now'), '19.71%');
      expect(
        _text(tester, 'level-up-detail'),
        'You pay 0.29% less than before',
      );
      expect(
        find.descendant(of: _popup, matching: find.text('Continue')),
        findsOneWidget,
      );
      // The old rate is struck through; the new one is the larger figure.
      final before = tester.widget<Text>(
        find.byKey(const ValueKey('level-up-rate-before')),
      );
      final now = tester.widget<Text>(
        find.byKey(const ValueKey('level-up-rate-now')),
      );
      expect(before.style!.decoration, TextDecoration.lineThrough);
      expect(now.style!.fontSize!, greaterThan(before.style!.fontSize!));
      // A screen reader hears it as one sentence.
      expect(
        find.bySemanticsLabel(RegExp('You reached Level 2 · Rookie')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _unmount(tester, state);
    });

    testWidgets('Continue puts it away', (tester) async {
      final state = _atLevelOne();
      await _mount(tester, state);
      _levelUp(state);
      await _arrive(tester);
      await tester.tap(find.byKey(const ValueKey('level-up-continue')));
      await _gone(tester);
      expect(_popup, findsNothing);
      expect(state.levelUps.current, isNull);
      await _unmount(tester, state);
    });

    testWidgets('a tap outside puts it away and presses nothing under it', (
      tester,
    ) async {
      final state = _atLevelOne();
      await _mount(tester, state);
      _levelUp(state);
      await _arrive(tester);
      // The top-left corner: the lobby's bonus chip and picture are there.
      await tester.tapAt(const Offset(24, 24));
      await _gone(tester);
      expect(_popup, findsNothing);
      expect(state.levelUps.current, isNull);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(state.screen, Screen.lobby);
      await _unmount(tester, state);
    });

    testWidgets('it goes by itself once its time is up', (tester) async {
      final state = _atLevelOne();
      await _mount(tester, state);
      _levelUp(state);
      await _arrive(tester);
      await tester.pump(LevelUpHost.hold - const Duration(seconds: 1));
      expect(_popup, findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await _gone(tester);
      expect(_popup, findsNothing);
      expect(state.levelUps.current, isNull);
      await _unmount(tester, state);
    });

    testWidgets('at a table it waits for the hand\'s end to be seen first', (
      tester,
    ) async {
      final state = _atLevelOne()
        ..screen = Screen.table
        ..handleState(seenTurnRoom());
      await _mount(tester, state, home: const TableScreen());
      _levelUp(state);
      await tester.pump();
      await tester.pump(
        LevelUpHost.tableDelay - const Duration(milliseconds: 200),
      );
      expect(_popup, findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      await _arrive(tester);
      expect(_popup, findsOneWidget);
      expect(_text(tester, 'level-up-rate-now'), '19.71%');
      expect(tester.takeException(), isNull);
      // A tap outside it — on the Chaal key under it — only puts it away.
      final handNo = state.room!.handNo;
      await tester.tapAt(
        tester.getBottomRight(find.byType(TableScreen)) - const Offset(90, 30),
      );
      await _gone(tester);
      expect(_popup, findsNothing);
      expect(state.room!.handNo, handNo);
      await _unmount(tester, state);
    });

    testWidgets('a second level up while it is up changes its words in place', (
      tester,
    ) async {
      final state = _atLevelOne();
      await _mount(tester, state);
      _levelUp(state);
      await _arrive(tester);
      state.handlePlayerLevel(_standing(_lv(3, 260)));
      await _arrive(tester);
      expect(_popup, findsOneWidget);
      expect(_text(tester, 'level-up-level'), 'Level 3 · Beginner');
      expect(_text(tester, 'level-up-rate-before'), '20%');
      expect(_text(tester, 'level-up-rate-now'), '19.43%');
      await _unmount(tester, state);
    });

    testWidgets('a signed-out account takes its popup with it', (tester) async {
      final state = _atLevelOne();
      await _mount(tester, state);
      _levelUp(state);
      await _arrive(tester);
      state.levelUps.clear();
      await _gone(tester);
      expect(_popup, findsNothing);
      await _unmount(tester, state);
    });

    testWidgets('under a Royal badge it names the badge and draws no rates', (
      tester,
    ) async {
      final state = levelState(level: _lv(1, 95), badges: _royal(), taxBps: 0);
      await _mount(tester, state);
      state.handlePlayerLevel(
        _standing(
          _lv(2, 115, claimed: {'WIN_TRAIL': 1}),
          badges: _royal(),
          taxBps: 0,
        ),
      );
      await _arrive(tester);
      expect(
        _text(tester, 'level-up-headline'),
        'Your Royal Ace badge already keeps your winning tax at 0%.',
      );
      expect(find.byKey(const ValueKey('level-up-rate-now')), findsNothing);
      expect(
        _text(tester, 'level-up-detail'),
        'This level\'s own rate is 19.71%, down from 20%.',
      );
      await _unmount(tester, state);
    });

    testWidgets('in the app as main.dart builds it, and Back puts it away '
        'before it asks to quit', (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _atLevelOne();
      final feedback = await silentFeedback();
      addTearDown(feedback.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GameState>.value(value: state),
            ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
          ],
          child: const KingTeenPattiApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LobbyScreen), findsOneWidget);
      _levelUp(state);
      await _arrive(tester);
      expect(_popup, findsOneWidget);
      await tester.binding.handlePopRoute();
      await _gone(tester);
      expect(_popup, findsNothing);
      expect(state.levelUps.current, isNull);
      // Back went to the popup alone: nothing asks to quit the game.
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(Dialog), findsNothing);
      await _unmount(tester, state);
    });
  });

  // Its sound (owner, 2 Oct 2026: "play this sound when congrats pop up comes
  // and when pop up closed, stop this sound").
  group('its sound', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('the recording is in the bundle', () {
      expect(FeedbackSettings.congratsClip, 'sound/Congrats.mp3');
      final file = File('assets/${FeedbackSettings.congratsClip}');
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(100 * 1024));
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('assets/sound/'),
      );
      expect(FeedbackSettings.congratsVolume, inInclusiveRange(0.6, 1.0));
    });

    group('the settings', () {
      test('play it once when asked, and stop it when told', () async {
        final f = _Heard();
        addTearDown(f.dispose);
        f.congrats();
        await pumpEventQueue();
        expect(f.heard, [_cheer]);
        expect(f.congratsOn, isTrue);

        f.stopCongrats();
        f.stopCongrats(); // said again: nothing more to stop
        await pumpEventQueue();
        expect(f.heard, [_cheer, 'cheer stop']);
        expect(f.congratsOn, isFalse);
      });

      test('stop nothing that was never started', () async {
        final f = _Heard();
        addTearDown(f.dispose);
        f.stopCongrats();
        await pumpEventQueue();
        expect(f.heard, isEmpty);
      });

      test('keep it behind the Sound switch', () async {
        final f = _Heard();
        addTearDown(f.dispose);
        await f.setSound(false);
        f.congrats();
        f.stopCongrats();
        await pumpEventQueue();
        expect(f.heard, isEmpty);

        // The switch turned off while it plays stops it there.
        await f.setSound(true);
        f.congrats();
        await f.setSound(false);
        await pumpEventQueue();
        expect(f.cheer, [_cheer, 'cheer stop']);
        expect(f.congratsOn, isFalse);
      });

      test('start it again when asked while it plays', () async {
        final f = _Heard();
        addTearDown(f.dispose);
        f.congrats();
        f.congrats();
        f.stopCongrats();
        await pumpEventQueue();
        expect(f.heard, [_cheer, _cheer, 'cheer stop']);
      });

      test('do what was asked in the order it was asked', () async {
        final f = _Heard();
        addTearDown(f.dispose);
        for (var i = 0; i < 3; i++) {
          f.congrats();
          f.stopCongrats();
        }
        await pumpEventQueue();
        expect(f.heard, [
          _cheer,
          'cheer stop',
          _cheer,
          'cheer stop',
          _cheer,
          'cheer stop',
        ]);
      });

      test('the lobby\'s music waits under it and carries on after', () async {
        final f = _Heard();
        addTearDown(f.dispose);
        f.lobbyMusic(playing: true);
        f.congrats();
        await pumpEventQueue();
        expect(f.music, ['music start', 'music pause']);
        expect(f.cheer, [_cheer]);
        expect(f.musicPlaying, isFalse);

        f.stopCongrats();
        await pumpEventQueue();
        expect(f.music, ['music start', 'music pause', 'music resume']);
        expect(f.cheer, [_cheer, 'cheer stop']);
        expect(f.musicPlaying, isTrue);
      });

      test('at a table there is no music to hold or to bring back', () async {
        final f = _Heard();
        addTearDown(f.dispose);
        f.congrats();
        f.stopCongrats();
        await pumpEventQueue();
        expect(f.heard, [_cheer, 'cheer stop']);
      });

      test('a lobby reached while it plays starts its music once it has '
          'stopped', () async {
        final f = _Heard();
        addTearDown(f.dispose);
        f.congrats();
        f.lobbyMusic(playing: true);
        await pumpEventQueue();
        expect(f.music, isEmpty);
        f.stopCongrats();
        await pumpEventQueue();
        expect(f.music, ['music start']);
      });

      test('the app leaving the front under it never brings the music back '
          'for a moment, whichever is told first', () async {
        // The popup's host is told before the music's keeper…
        final f = _Heard();
        addTearDown(f.dispose);
        f.lobbyMusic(playing: true);
        f.congrats();
        f.stopCongrats(resumeMusic: false);
        f.holdMusic(held: true);
        await pumpEventQueue();
        expect(f.cheer, [_cheer, 'cheer stop']);
        expect(f.music, ['music start', 'music pause']);
        // …and it carries on when the app is back.
        f.holdMusic(held: false);
        await pumpEventQueue();
        expect(f.music, ['music start', 'music pause', 'music resume']);

        // …or after it.
        final g = _Heard();
        addTearDown(g.dispose);
        g.lobbyMusic(playing: true);
        g.congrats();
        g.holdMusic(held: true);
        g.stopCongrats(resumeMusic: false);
        await pumpEventQueue();
        expect(g.cheer, [_cheer, 'cheer stop']);
        expect(g.music, ['music start', 'music pause']);
        g.holdMusic(held: false);
        await pumpEventQueue();
        expect(g.music, ['music start', 'music pause', 'music resume']);
      });

      test('music left for a table while it plays is stopped, not brought '
          'back', () async {
        final f = _Heard();
        addTearDown(f.dispose);
        f.lobbyMusic(playing: true);
        f.congrats();
        f.lobbyMusic(playing: false);
        f.stopCongrats();
        await pumpEventQueue();
        expect(f.music, ['music start', 'music pause', 'music stop']);
        expect(f.cheer, [_cheer, 'cheer stop']);
      });
    });

    testWidgets('it starts as the popup appears, plays while it stays, and '
        'Continue stops it at once', (tester) async {
      final heard = _Heard();
      final state = _atLevelOne();
      await _mount(tester, state, sounds: heard);
      expect(heard.cheer, isEmpty);
      _levelUp(state);
      await _arrive(tester);
      expect(_popup, findsOneWidget);
      expect(heard.cheer, [_cheer]);
      await tester.pump(const Duration(seconds: 4));
      expect(heard.cheer, [_cheer]);
      await tester.tap(find.byKey(const ValueKey('level-up-continue')));
      // Stopped as it is closed, before it has faded out.
      await tester.pump();
      expect(heard.cheer, [_cheer, 'cheer stop']);
      expect(_popup, findsOneWidget);
      await _gone(tester);
      expect(_popup, findsNothing);
      expect(heard.cheer, [_cheer, 'cheer stop']);
      await _unmount(tester, state);
    });

    testWidgets('a tap outside the popup stops it', (tester) async {
      final heard = _Heard();
      final state = _atLevelOne();
      await _mount(tester, state, sounds: heard);
      _levelUp(state);
      await _arrive(tester);
      await tester.tapAt(const Offset(24, 24));
      await _gone(tester);
      expect(_popup, findsNothing);
      expect(heard.cheer, [_cheer, 'cheer stop']);
      await _unmount(tester, state);
    });

    testWidgets('the popup going by itself stops it', (tester) async {
      final heard = _Heard();
      final state = _atLevelOne();
      await _mount(tester, state, sounds: heard);
      _levelUp(state);
      await _arrive(tester);
      await tester.pump(LevelUpHost.hold - const Duration(seconds: 1));
      expect(heard.cheer, [_cheer]);
      await tester.pump(const Duration(seconds: 1));
      await _gone(tester);
      expect(_popup, findsNothing);
      expect(heard.cheer, [_cheer, 'cheer stop']);
      await _unmount(tester, state);
    });

    testWidgets('a signed-out account takes the sound with its popup', (
      tester,
    ) async {
      final heard = _Heard();
      final state = _atLevelOne();
      await _mount(tester, state, sounds: heard);
      _levelUp(state);
      await _arrive(tester);
      state.levelUps.clear();
      await _gone(tester);
      expect(heard.cheer, [_cheer, 'cheer stop']);
      await _unmount(tester, state);
    });

    testWidgets('at a table it waits with the popup: nothing is heard before '
        'the popup is seen', (tester) async {
      final heard = _Heard();
      final state = _atLevelOne()
        ..screen = Screen.table
        ..handleState(seenTurnRoom());
      await _mount(tester, state, home: const TableScreen(), sounds: heard);
      _levelUp(state);
      await tester.pump();
      await tester.pump(
        LevelUpHost.tableDelay - const Duration(milliseconds: 200),
      );
      expect(_popup, findsNothing);
      expect(heard.cheer, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      await _arrive(tester);
      expect(_popup, findsOneWidget);
      expect(heard.cheer, [_cheer]);
      await tester.tap(find.byKey(const ValueKey('level-up-continue')));
      await _gone(tester);
      expect(heard.cheer, [_cheer, 'cheer stop']);
      // No lobby, so no music was held or brought back.
      expect(heard.music, isEmpty);
      await _unmount(tester, state);
    });

    testWidgets('a level up put away before the popup has appeared is never '
        'heard', (tester) async {
      final heard = _Heard();
      final state = _atLevelOne()
        ..screen = Screen.table
        ..handleState(seenTurnRoom());
      await _mount(tester, state, home: const TableScreen(), sounds: heard);
      _levelUp(state);
      await tester.pump(const Duration(milliseconds: 500));
      state.levelUps.clear();
      await tester.pump(LevelUpHost.tableDelay);
      await _gone(tester);
      expect(_popup, findsNothing);
      expect(heard.cheer, isEmpty);
      await _unmount(tester, state);
    });

    testWidgets('a second level up while the popup is up starts it again', (
      tester,
    ) async {
      final heard = _Heard();
      final state = _atLevelOne();
      await _mount(tester, state, sounds: heard);
      _levelUp(state);
      await _arrive(tester);
      await tester.pump(const Duration(seconds: 3));
      state.handlePlayerLevel(_standing(_lv(3, 260)));
      await _arrive(tester);
      expect(_text(tester, 'level-up-level'), 'Level 3 · Beginner');
      expect(heard.cheer, [_cheer, _cheer]);
      await tester.tap(find.byKey(const ValueKey('level-up-continue')));
      await _gone(tester);
      expect(heard.cheer, [_cheer, _cheer, 'cheer stop']);
      await _unmount(tester, state);
    });

    testWidgets('with the Sound switch off the popup is silent', (
      tester,
    ) async {
      final heard = _Heard();
      await heard.setSound(false);
      final state = _atLevelOne();
      await _mount(tester, state, sounds: heard);
      _levelUp(state);
      await _arrive(tester);
      expect(_popup, findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('level-up-continue')));
      await _gone(tester);
      expect(heard.heard, isEmpty);
      await _unmount(tester, state);
    });

    testWidgets('the app leaving the front stops it, and back in front the '
        'popup stays silent', (tester) async {
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final heard = _Heard();
      final state = _atLevelOne();
      await _mount(tester, state, sounds: heard);
      _levelUp(state);
      await _arrive(tester);
      // A shade or a system dialog over the app is not leaving it.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(heard.cheer, [_cheer]);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(heard.cheer, [_cheer, 'cheer stop']);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(_popup, findsOneWidget);
      expect(heard.cheer, [_cheer, 'cheer stop']);
      // Put away now, there is nothing left to stop.
      await tester.tap(find.byKey(const ValueKey('level-up-continue')));
      await _gone(tester);
      expect(heard.cheer, [_cheer, 'cheer stop']);
      await _unmount(tester, state);
    });

    testWidgets('a screen taken down with the popup up takes the sound with '
        'it', (tester) async {
      final heard = _Heard();
      final state = _atLevelOne();
      await _mount(tester, state, sounds: heard);
      _levelUp(state);
      await _arrive(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(heard.cheer, [_cheer, 'cheer stop']);
      await tester.pump(const Duration(seconds: 20));
      state.dispose();
    });

    testWidgets('in the app as main.dart builds it the lobby\'s music waits '
        'under it, and Back stops it and brings the music back', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _atLevelOne();
      final heard = _Heard();
      addTearDown(heard.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GameState>.value(value: state),
            ChangeNotifierProvider<FeedbackSettings>.value(value: heard),
          ],
          child: const KingTeenPattiApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(LobbyScreen), findsOneWidget);
      expect(heard.music, ['music start']);
      _levelUp(state);
      await _arrive(tester);
      expect(_popup, findsOneWidget);
      expect(heard.cheer, [_cheer]);
      expect(heard.music, ['music start', 'music pause']);
      await tester.binding.handlePopRoute();
      await _gone(tester);
      expect(_popup, findsNothing);
      expect(heard.cheer, [_cheer, 'cheer stop']);
      expect(heard.music, ['music start', 'music pause', 'music resume']);
      await _unmount(tester, state);
    });

    testWidgets('in the app, leaving the front under the popup stops it and '
        'keeps the lobby\'s music held until the app is back', (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final state = _atLevelOne();
      final heard = _Heard();
      addTearDown(heard.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GameState>.value(value: state),
            ChangeNotifierProvider<FeedbackSettings>.value(value: heard),
          ],
          child: const KingTeenPattiApp(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      _levelUp(state);
      await _arrive(tester);
      expect(heard.cheer, [_cheer]);
      expect(heard.music, ['music start', 'music pause']);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(heard.cheer, [_cheer, 'cheer stop']);
      // Not a note of the music while the app is behind.
      expect(heard.music, ['music start', 'music pause']);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      // Back in front: the music carries on, the popup — still up — is
      // silent.
      expect(_popup, findsOneWidget);
      expect(heard.cheer, [_cheer, 'cheer stop']);
      expect(heard.music, ['music start', 'music pause', 'music resume']);
      await _unmount(tester, state);
    });
  });

  // The popup whole at every phone size, at both text sizes, in every
  // language, by night and by day: on screen, nothing thrown, no word cut.
  group('fits', () {
    const screens = [
      Size(592, 360),
      Size(640, 360),
      Size(844, 390),
      Size(915, 412),
      Size(1280, 800),
    ];
    for (final badged in [false, true]) {
      for (final lang in AppLang.values) {
        testWidgets('${badged ? 'under a badge' : 'a lower tax'} in '
            '${lang.englishName}', (tester) async {
          for (final screen in screens) {
            for (final scale in const [1.0, 1.25]) {
              for (final dark in [true, false]) {
                final where =
                    '${lang.englishName} $screen x$scale '
                    '${dark ? 'dark' : 'light'}';
                // The longest level name on the ladder, high up it.
                final state = levelState(
                  level: _lv(43, 809992),
                  lang: lang,
                  badges: badged ? _royal() : null,
                  taxBps: badged ? 0 : null,
                );
                await _mount(
                  tester,
                  state,
                  screen: screen,
                  scale: scale,
                  dark: dark,
                );
                state.handlePlayerLevel(
                  _standing(
                    _lv(44, 810000, claimed: {'WIN_PURE_SEQUENCE': 1}),
                    badges: badged ? _royal() : null,
                    taxBps: badged ? 0 : null,
                  ),
                );
                await _arrive(tester);
                expect(tester.takeException(), isNull, reason: where);
                final card = tester.getRect(_popup);
                expect(card.left, greaterThanOrEqualTo(0), reason: where);
                expect(card.top, greaterThanOrEqualTo(0), reason: where);
                expect(
                  card.right,
                  lessThanOrEqualTo(screen.width),
                  reason: where,
                );
                expect(
                  card.bottom,
                  lessThanOrEqualTo(screen.height),
                  reason: where,
                );
                // Every line whole and inside the card; the Continue key on
                // screen.
                for (final p in tester.renderObjectList<RenderParagraph>(
                  find.descendant(of: _popup, matching: find.byType(RichText)),
                )) {
                  final line = p.text.toPlainText();
                  expect(
                    p.didExceedMaxLines,
                    isFalse,
                    reason: '$where: "$line" cut',
                  );
                  final box = p.localToGlobal(Offset.zero) & p.size;
                  expect(
                    box.right,
                    lessThanOrEqualTo(card.right + 0.5),
                    reason: '$where: "$line"',
                  );
                }
                final key = tester.getRect(
                  find.byKey(const ValueKey('level-up-continue')),
                );
                expect(
                  key.bottom,
                  lessThanOrEqualTo(screen.height),
                  reason: where,
                );
                expect(key.height, greaterThanOrEqualTo(44), reason: where);
                await _unmount(tester, state);
              }
            }
          }
        });
      }
    }
  });
}
