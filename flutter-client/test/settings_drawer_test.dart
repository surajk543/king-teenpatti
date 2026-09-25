// The lobby's Settings drawer after its polish (26 Sep 2026): a head that
// stays while the list scrolls, four named groups (Profile, Game experience,
// Appearance, Account), the number format as one row that opens in place,
// the switches on in gold, a neutral Sign out and one red Delete row, and the
// version at the foot — the environment beside it on a build that does not
// talk to production. Nothing it does changed: the number format, the
// switches, the appearance control, Sign out and Delete all still do exactly
// what they did, and the last two still ask first.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/avatar.dart';
import 'package:teenpatti/widgets/feedback_toggles.dart';
import 'package:teenpatti/widgets/glass_components.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

GameState _state(AppLang lang) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = Screen.lobby
    ..themeMode = ThemeMode.dark
    ..appVersion = '1.2.3 (10)'
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
      ],
    })
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 3245000,
    });
}

/// The lobby as the app mounts it, at [size] and text [scale], with the
/// Settings drawer open.
Future<GameState> _open(
  WidgetTester tester, {
  AppLang lang = AppLang.english,
  Size size = const Size(640, 360),
  double scale = 1.25,
  FeedbackSettings? feedback,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final state = _state(lang);
  final settings = feedback ?? FeedbackSettings();
  addTearDown(() async {
    state.dispose();
    if (feedback == null) settings.dispose();
  });
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: settings),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withScriptFallback(AppTheme.light(sound: false)),
        darkTheme: withScriptFallback(AppTheme.dark(sound: false)),
        themeMode: ThemeMode.dark,
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.25,
          child: GlassBudget(child: child!),
        ),
        home: const LobbyScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(find.byIcon(Icons.tune_rounded).first);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return state;
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// The drawer's scrolling list.
ScrollableState _list(WidgetTester tester) => tester.state<ScrollableState>(
  find
      .descendant(of: find.byType(Drawer), matching: find.byType(Scrollable))
      .first,
);

/// Every line of type on screen inside the drawer.
Iterable<RenderParagraph> _paragraphs(WidgetTester tester) => find
    .descendant(of: find.byType(Drawer), matching: find.byType(RichText))
    .evaluate()
    .map((e) => e.renderObject! as RenderParagraph);

String _upper(String s, AppLang lang) =>
    lang == AppLang.english ? s.toUpperCase() : s;

/// Something in the drawer, wherever the list has it — the top bar under the
/// drawer shows the same balance, and a row below the fold is built but
/// offstage to a default finder.
Finder _inDrawer(Finder f) =>
    find.descendant(of: find.byType(Drawer), matching: f, skipOffstage: false);
Finder _text(String words) => _inDrawer(find.text(words));
Finder _icon(IconData icon) => _inDrawer(find.byIcon(icon));

/// Scrolls the drawer's list until [f] is in view: down until the list has
/// built it (a row far below the fold is not built at all), then onto it.
Future<void> _reveal(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      f,
      80,
      scrollable: find
          .descendant(
            of: find.byType(Drawer),
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(f);
  await tester.pump(const Duration(milliseconds: 300));
}

/// A tap, and the frames after it.
Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Scrolls the drawer's list from its top to its end a viewport at a time,
/// and hands back every word it showed; [each] looks at every stop.
Future<Set<String>> _walk(WidgetTester tester, {void Function()? each}) async {
  final seen = <String>{};
  final position = _list(tester).position;
  position.jumpTo(0);
  await tester.pump();
  while (true) {
    await tester.pump(const Duration(milliseconds: 300));
    for (final p in _paragraphs(tester)) {
      seen.add(p.text.toPlainText());
    }
    each?.call();
    if (position.pixels >= position.maxScrollExtent) break;
    position.jumpTo(
      (position.pixels + position.viewportDimension * 0.6).clamp(
        0,
        position.maxScrollExtent,
      ),
    );
  }
  return seen;
}

void main() {
  setUpAll(loadScriptFonts);
  setUp(() => SharedPreferences.setMockInitialValues({'soundOn': true}));

  for (final lang in AppLang.values) {
    testWidgets('at 640x360 at text x1.25 the drawer in ${lang.englishName} '
        'lays out whole: every group and row, nothing cut short, and the '
        'head still standing at the end of the list', (tester) async {
      final state = await _open(tester, lang: lang);
      final t = state.t;

      final title = find.text(t.settings);
      expect(title, findsOneWidget);
      expect(find.text(t.settingsSubtitle), findsOneWidget);
      final head = tester.getRect(title);

      final cut = <String>[];
      final seen = await _walk(
        tester,
        each: () {
          for (final p in _paragraphs(tester)) {
            if (p.didExceedMaxLines) cut.add(p.text.toPlainText());
          }
        },
      );
      expect(cut, isEmpty, reason: '${lang.code}: cut short');
      expect(tester.takeException(), isNull);

      for (final words in [
        _upper(t.settingsProfile, lang),
        _upper(t.settingsGameExperience, lang),
        _upper(t.appearance, lang),
        _upper(t.settingsAccount, lang),
        t.yourPicture,
        t.tapToChangePicture,
        t.displayName,
        t.language,
        t.numberSystem,
        '32.45 Lakh',
        t.soundLabel,
        t.vibrationLabel,
        t.privacyPolicy,
        t.signOut,
        t.deleteAccount,
      ]) {
        expect(
          seen.any((s) => s.contains(words)),
          isTrue,
          reason: '${lang.code}: "$words" never shown',
        );
      }
      expect(
        seen.any((s) => s.startsWith(t.appVersion) && s.contains('1.2.3')),
        isTrue,
        reason: '${lang.code}: no version line',
      );
      // The appearance control is there, words or icons.
      expect(find.byType(GlassThemeSwitcher), findsOneWidget);

      // Scrolled to the end, the head is where it was.
      expect(tester.getRect(title), head);
      expect(find.byTooltip('Close'), findsOneWidget);
      await _close(tester);
    });
  }

  testWidgets('the number format is one row that says what is on, opens in '
      'place onto the two choices and closes on a choice', (tester) async {
    final state = await _open(tester);
    final t = state.t;
    final row = _text(t.numberSystem);
    await _reveal(tester, row);

    // Closed: the choice and the player's own money under it, and no choice
    // tiles.
    expect(_text('32.45 Lakh'), findsOneWidget);
    expect(_text('3.25 Million'), findsNothing);
    expect(_icon(Icons.public), findsNothing);
    expect(_icon(Icons.currency_rupee), findsNothing);
    expect(
      tester.getSemantics(row),
      isSemantics(isButton: true, hasExpandedState: true),
    );

    await _tap(tester, row);
    // Open: each choice previews itself with the same figure.
    expect(_icon(Icons.currency_rupee), findsOneWidget);
    expect(_icon(Icons.public), findsOneWidget);
    expect(_text('32.45 Lakh'), findsOneWidget);
    expect(_text('3.25 Million'), findsOneWidget);
    expect(state.numbers, NumberSystem.indian);
    expect(tester.getSemantics(row), isSemantics(isExpanded: true));

    await _reveal(tester, _icon(Icons.public));
    await _tap(tester, _icon(Icons.public));
    expect(state.numbers, NumberSystem.international);
    // Closed again, on the new choice.
    expect(_icon(Icons.public), findsNothing);
    expect(_icon(Icons.currency_rupee), findsNothing);
    expect(_text('3.25 Million'), findsOneWidget);
    expect(_text('32.45 Lakh'), findsNothing);
    expect(tester.takeException(), isNull);

    // Back to Indian the same way, which also sets back the global the
    // formatter reads for the tests after this one.
    await _reveal(tester, row);
    await _tap(tester, row);
    await _reveal(tester, _icon(Icons.currency_rupee));
    await _tap(tester, _icon(Icons.currency_rupee));
    expect(state.numbers, NumberSystem.indian);
    expect(_text('32.45 Lakh'), findsOneWidget);
    await _close(tester);
  });

  testWidgets('the switches still switch, and are gold when on', (
    tester,
  ) async {
    final feedback = FeedbackSettings();
    addTearDown(feedback.dispose);
    final state = await _open(tester, feedback: feedback);
    final t = state.t;
    await _reveal(tester, _text(t.vibrationLabel));

    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches, hasLength(2));
    for (final s in switches) {
      expect(
        s.trackColor!.resolve({WidgetState.selected}),
        FeedbackSwitchStyle.trackOn(Brightness.dark),
      );
      expect(
        s.thumbColor!.resolve({WidgetState.selected}),
        FeedbackSwitchStyle.thumbOn(Brightness.dark),
      );
      // Off still reads: the outline is there.
      expect(s.trackOutlineColor!.resolve({})!.a, greaterThan(0.5));
    }

    // A tap anywhere on the row, and a tap on the thumb itself.
    expect(feedback.sound, isTrue);
    await _reveal(tester, _text(t.soundLabel));
    await _tap(tester, _text(t.soundLabel));
    expect(feedback.sound, isFalse);
    expect(feedback.vibrate, isTrue);
    await _reveal(tester, find.byType(Switch).last);
    await _tap(tester, find.byType(Switch).last);
    expect(feedback.vibrate, isFalse);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('the appearance control still sets the theme', (tester) async {
    final state = await _open(tester, scale: 1.0);
    final t = state.t;
    await _reveal(tester, _text(t.themeLight));
    await _tap(tester, _text(t.themeLight));
    expect(state.themeMode, ThemeMode.light);
    await _tap(tester, _text(t.themeSystem));
    expect(state.themeMode, ThemeMode.system);
    await _tap(tester, _text(t.themeDark));
    expect(state.themeMode, ThemeMode.dark);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('Sign out and Delete my account still ask first', (tester) async {
    final state = await _open(tester);
    final t = state.t;

    await _reveal(tester, _text(t.signOut));
    await _tap(tester, _text(t.signOut));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(t.signOutQ), findsOneWidget);
    await _tap(tester, find.text(t.cancel));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(t.signOutQ), findsNothing);
    expect(state.user, isNotNull);

    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await _reveal(tester, _text(t.deleteAccount));
    await _tap(tester, _text(t.deleteAccount));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(t.deleteAccountTitle), findsOneWidget);
    await _tap(tester, find.text(t.cancel));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(t.deleteAccountTitle), findsNothing);
    expect(state.user, isNotNull);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });

  testWidgets('Sign out is a row like any other, and Delete the one red one', (
    tester,
  ) async {
    final state = await _open(tester);
    final t = state.t;
    await _reveal(tester, _text(t.deleteAccount));
    final scheme = Theme.of(tester.element(_text(t.signOut))).colorScheme;
    Color? ink(String words) =>
        tester.renderObject<RenderParagraph>(_text(words)).text.style?.color;
    expect(ink(t.signOut), isNot(scheme.error));
    expect(ink(t.privacyPolicy), ink(t.signOut));
    expect(ink(t.deleteAccount), scheme.error);
    await _close(tester);
  });

  testWidgets('with the keyboard up the name field stands between the head '
      'and the keyboard, and the line under the title steps aside', (
    tester,
  ) async {
    final state = await _open(tester);
    final t = state.t;
    final field = _inDrawer(find.byType(TextField));
    await tester.tap(field);
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 190);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final box = tester.getRect(field);
    final head = tester.getRect(find.text(t.settings));
    expect(box.top, greaterThan(head.bottom));
    expect(box.bottom, lessThanOrEqualTo(360 - 190.0));
    expect(find.text(t.settingsSubtitle), findsNothing);
    expect(tester.takeException(), isNull);

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(t.settingsSubtitle), findsOneWidget);
    await _close(tester);
  });

  testWidgets('the gold ring is the drawer portrait\'s alone', (tester) async {
    await _open(tester);
    final ringed = find.byWidgetPredicate(
      (w) => w is Avatar && w.ringGap > 0,
      skipOffstage: false,
    );
    expect(ringed, findsOneWidget);
    expect(_inDrawer(ringed), findsOneWidget);
    expect(
      tester.widget<Avatar>(ringed).ring,
      AppTheme.goldBright,
      reason: 'the dark theme\'s ring',
    );
    // The top bar's portrait, under the drawer, keeps its hairline.
    expect(
      find.byWidgetPredicate(
        (w) => w is Avatar && w.ringGap == 0 && w.radius > 20,
        skipOffstage: false,
      ),
      findsWidgets,
    );
    await _close(tester);
  });

  test('the version names its environment only off production', () {
    expect(versionEnvironmentTag(production: true), isNull);
    expect(
      versionEnvironmentTag(production: true, environment: 'production'),
      isNull,
    );
    expect(
      versionEnvironmentTag(production: false, environment: 'preprod'),
      'preprod',
    );
    expect(
      versionEnvironmentTag(production: false, environment: 'local'),
      'local',
    );
  });

  testWidgets('a build that is not production shows its environment, '
      'quieter than the version', (tester) async {
    // The test build is preprod (ServerConfig's default).
    final state = await _open(tester);
    final version = _inDrawer(find.textContaining(state.t.appVersion));
    await _reveal(tester, version);
    // The paragraph's span is the Text's own style over the span it was
    // given: the version, then the environment.
    final line = tester.renderObject<RenderParagraph>(version).text as TextSpan;
    expect(line.toPlainText(), contains('1.2.3 (10)'));
    expect(line.toPlainText(), contains('preprod'));
    final given = line.children!.single as TextSpan;
    final environment = given.children!.last as TextSpan;
    expect(environment.text, contains('preprod'));
    expect(environment.style!.color!.a, lessThan(line.style!.color!.a));
    await _close(tester);
  });

  test('the new words are written in all five languages', () {
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final key in const [
        'settingsSubtitle',
        'settingsProfile',
        'settingsGameExperience',
        'settingsAccount',
      ]) {
        expect(t.ownEntry(key), isNotNull, reason: '${lang.code}: $key');
        expect(t.ownEntry(key)!.trim(), isNotEmpty);
      }
      expect(t.settingsSubtitle, isNot(contains('_')));
    }
    expect(
      const Strings(AppLang.english).settingsSubtitle,
      'Personalize your game experience',
    );
  });

  testWidgets('the Stats drawer shares the head: it stays while its record '
      'scrolls, and no figure\'s name is cut short', (tester) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final state = _state(AppLang.english);
    final feedback = FeedbackSettings();
    addTearDown(() {
      state.dispose();
      feedback.dispose();
    });
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GameState>.value(value: state),
          ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: withScriptFallback(AppTheme.dark(sound: false)),
          builder: (context, child) => GlassBudget(child: child!),
          home: const LobbyScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byIcon(Icons.insights_outlined).first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final name = find.descendant(
      of: find.byType(Drawer),
      matching: find.text('Ravi'),
    );
    final head = tester.getRect(name);
    final cut = <String>[];
    await _walk(
      tester,
      each: () {
        for (final p in _paragraphs(tester)) {
          if (p.didExceedMaxLines) cut.add(p.text.toPlainText());
        }
      },
    );
    expect(cut, isEmpty);
    expect(tester.getRect(name), head);
    expect(tester.takeException(), isNull);
    await _close(tester);
  });
}
