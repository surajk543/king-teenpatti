// Every key in the lobby clicks (owner, 27 Sep 2026: "This Card click.mp3
// sound should be played when i click back button and any button in Lobby
// UI"): the owner's assets/sound/Card click.mp3 through lobbyClick →
// FeedbackSettings.cardClick, once per tap — the top bar, the foot, the rail's
// cards and back tile, a table card's corner keys, the private card's keys,
// the celebration's close key — and on a system Back the lobby takes. A
// padlocked table card and a disabled key stay quiet, a corner key never also
// clicks the card it stands on, the Sound switch silences all of it, and the
// door still sounds as a player sits.
//
// Heard through FeedbackSettings.playClip, the one place a clip reaches the
// audio plugin: cardClick and the Sound switch are the real ones.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/main.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/friends_screen.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/glass_components.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

/// Every clip the app asks the audio plugin for, in order — past the Sound
/// switch, which the real [FeedbackSettings] still applies.
class _Heard extends FeedbackSettings {
  final heard = <String>[];

  int get clicks =>
      heard.where((c) => c == FeedbackSettings.cardClickClip).length;

  @override
  Future<void> playClip(
    String asset, {
    required double volume,
    required int voice,
  }) async => heard.add(asset);
}

Map<String, Object?> _level() => {
  'level': 10,
  'title': 'Rising Star',
  'icon': '🌟',
  'xp': 4180,
  'taxBps': 1743,
  'next': {
    'level': 11,
    'title': 'Pro Player',
    'icon': '🏅',
    'minXp': 5200,
    'taxBps': 1714,
  },
};

GameState _state() {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = AppLang.english
    ..screen = Screen.lobby
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
        // Shut to a player of 3 Lakh: it wants 50 Crore.
        {'category': 'seen', 'bootAmount': 1000000, 'minChips': 500000000},
        {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
      ],
    })
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 300000,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
      'playerLevel': _level(),
    })
    ..luckyDraw = LuckyDrawState.fromJson({
      'draw': {
        'code': 'BEGINNER_LUCKY_DRAW',
        'name': 'Beginner Lucky Draw',
        'spinnerType': 'BEGINNER',
        'cooldownMs': 259200000,
      },
      'slots': [
        for (var n = 1; n <= 6; n++)
          {'slotNumber': n, 'rewardType': 'CHIPS', 'rewardValue': 100000 * n},
      ],
      'nextSpinAt': 0,
    });
}

/// The cards' entrances, the level's transition and the stakes' count-up.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _pumpLobby(
  WidgetTester tester,
  GameState state,
  FeedbackSettings sounds, {
  bool materialSound = false,
}) async {
  tester.view.physicalSize = const Size(891, 411);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: sounds),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(sound: materialSound),
        builder: (context, child) => GlassBudget(child: child!),
        home: const LobbyScreen(),
      ),
    ),
  );
  await _settle(tester);
}

/// Whatever a key opened — a dialog, a sheet, a page, a drawer — closed
/// again, so the next key is tapped on the lobby itself.
Future<void> _closeAll(WidgetTester tester, GameState state) async {
  await tester.pump(const Duration(milliseconds: 600));
  tester
      .state<NavigatorState>(find.byType(Navigator).first)
      .popUntil((route) => route.isFirst);
  state.lobbyScaffold.currentState?.closeEndDrawer();
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Counts Material's own platform tick (SystemSound.play), the second sound a
/// key would make beside the click if it kept its enableFeedback.
int Function() _countTicks(WidgetTester tester) {
  var ticks = 0;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'SystemSound.play') ticks++;
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return () => ticks;
}

Future<void> _tearDown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('every key in the top bar and the foot clicks once per tap', (
    tester,
  ) async {
    final state = _state();
    final sounds = _Heard();
    addTearDown(sounds.dispose);
    await _pumpLobby(tester, state, sounds);
    final t = state.t;

    // One tap on each key, and exactly one click each: the picture, Shop,
    // Settings, the Lucky Draw, the level, the record and Friends (the
    // bar's Sign out key went on 30 Sep 2026, and the record's key came
    // down to the foot).
    final keys = <String, Finder>{
      'the picture': find.byTooltip(t.yourPicture),
      'Shop': find.byType(ShopButton),
      'Settings': find.byTooltip(t.settings),
      'the Lucky Draw': find.text(t.luckyDrawChip),
      'the level key': find.byKey(const ValueKey('level-key')),
      'the record': find.byTooltip(t.yourRecord),
      'Friends': find.byType(FriendsKey),
    };
    for (final MapEntry(key: name, value: finder) in keys.entries) {
      expect(finder, findsOneWidget, reason: name);
      final before = sounds.clicks;
      await tester.tap(finder);
      await tester.pump();
      expect(sounds.clicks, before + 1, reason: '$name clicks once');
      await _closeAll(tester, state);
    }
    expect(sounds.clicks, keys.length);
    // Nothing but the clicks: a click is the only sound a key makes here.
    expect(sounds.heard.toSet(), {FeedbackSettings.cardClickClip});

    await _tearDown(tester, state);
  });

  testWidgets(
    'the rail: cards, the back tile, a corner key without its card, the '
    'private keys; a padlocked card and a disabled key stay quiet',
    (tester) async {
      final state = _state();
      final sounds = _Heard();
      addTearDown(sounds.dispose);
      await _pumpLobby(tester, state, sounds);
      final t = state.t;

      Future<void> tap(Finder finder, {required int clicks}) async {
        await tester.ensureVisible(finder);
        await tester.pump(const Duration(milliseconds: 400));
        final before = sounds.clicks;
        await tester.tap(finder, warnIfMissed: false);
        await tester.pump();
        expect(sounds.clicks, before + clicks);
      }

      // The private card, on the front: Join is dead until the code is whole,
      // and a dead key is silent; Create clicks, and Join with a whole code.
      await tap(find.text(t.join), clicks: 0);
      await tap(find.text(t.create), clicks: 1);
      await tester.enterText(find.byType(TextField), 'ABCD1234');
      await tester.pump();
      await tap(find.text(t.join), clicks: 1);
      FocusManager.instance.primaryFocus?.unfocus();
      await _settle(tester);

      // The Seen card, into its tables.
      await tap(find.text(t.viewTables).first, clicks: 1);
      await _settle(tester);
      expect(state.lobbyCategory, 'seen');

      // A table card's corner keys: each its own click, once, and the card
      // under it neither clicks nor opens (no door, no seat).
      await tap(find.byKey(const ValueKey('info-wave')).first, clicks: 1);
      await _closeAll(tester, state);
      await tap(find.byKey(const ValueKey('rule-book')).first, clicks: 1);
      await _closeAll(tester, state);
      expect(sounds.heard, isNot(contains('sfx/door.wav')));

      // A padlocked table: nothing happens, nothing is heard.
      await tap(find.text(t.lockedTitle), clicks: 0);

      // A table the player may sit at: one click, and the door as before.
      final door = sounds.heard.length;
      await tap(find.text(t.tapToSit).first, clicks: 1);
      expect(sounds.heard.sublist(door), [
        FeedbackSettings.cardClickClip,
        'sfx/door.wav',
      ]);

      // The back tile, back to the front.
      await tap(find.byKey(const ValueKey('back-mark')), clicks: 1);
      await _settle(tester);
      expect(state.lobbyCategory, isNull);

      await _tearDown(tester, state);
    },
  );

  testWidgets('the celebration closes with a click, and no Material tick', (
    tester,
  ) async {
    final ticks = _countTicks(tester);
    // A chip pack just bought in the lobby.
    final state = _state()
      ..rewardWon = (kind: 'purchase', amount: 100000, missiles: 0, hammers: 0);
    final sounds = _Heard();
    addTearDown(sounds.dispose);
    await _pumpLobby(tester, state, sounds, materialSound: true);

    final before = sounds.clicks;
    final tick = ticks();
    await tester.tap(find.text(state.t.tapToClose));
    await tester.pump();
    expect(sounds.clicks, before + 1);
    expect(ticks(), tick);
    expect(state.rewardWon, isNull);

    await _tearDown(tester, state);
  });

  testWidgets('with the Sound switch off no key in the lobby clicks', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'soundOn': false});
    final state = _state();
    final sounds = _Heard();
    addTearDown(sounds.dispose);
    await sounds.load();
    expect(sounds.sound, isFalse);
    await _pumpLobby(tester, state, sounds);
    final t = state.t;

    for (final finder in [
      find.byTooltip(t.yourPicture),
      find.byType(ShopButton),
      find.byTooltip(t.settings),
      find.text(t.luckyDrawChip),
      find.byType(FriendsKey),
      find.byKey(const ValueKey('level-key')),
    ]) {
      await tester.tap(finder);
      await tester.pump();
      await _closeAll(tester, state);
    }
    await tester.tap(find.text(t.create));
    await tester.pump();
    await tester.tap(find.text(t.viewTables).first);
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('info-wave')).first);
    await _closeAll(tester, state);
    await tester.tap(find.byKey(const ValueKey('back-mark')));
    await _settle(tester);

    expect(sounds.heard, isEmpty);
    await _tearDown(tester, state);
  });

  testWidgets(
    'the system Back clicks as it closes a level, a drawer, or asks to '
    'quit; the quit question\'s own keys do not; not under the consent panel '
    'or the resume veil',
    (tester) async {
      tester.view.physicalSize = const Size(891, 411);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = _state();
      final sounds = _Heard();
      addTearDown(sounds.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<GameState>.value(value: state),
            ChangeNotifierProvider<FeedbackSettings>.value(value: sounds),
          ],
          child: const KingTeenPattiApp(),
        ),
      );
      await _settle(tester);
      final t = state.t;

      Future<void> back() async {
        await tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .maybePop();
        await _settle(tester);
      }

      // Into Seen (the card's click), then Back up a level: one click.
      await tester.tap(find.text(t.viewTables).first);
      await _settle(tester);
      expect(state.lobbyCategory, 'seen');
      expect(sounds.clicks, 1);
      await back();
      expect(state.lobbyCategory, isNull);
      expect(sounds.clicks, 2);

      // The Settings drawer (its key's click), then Back closes it: one.
      await tester.tap(find.byTooltip(t.settings));
      await _settle(tester);
      expect(state.lobbyScaffold.currentState!.isEndDrawerOpen, isTrue);
      expect(sounds.clicks, 3);
      await back();
      expect(state.lobbyScaffold.currentState!.isEndDrawerOpen, isFalse);
      expect(sounds.clicks, 4);

      // At the front Back asks to quit, and clicks as it does; the question's
      // own keys are the dialog's, not the lobby's.
      await back();
      expect(find.text(t.quitGameQ), findsOneWidget);
      expect(sounds.clicks, 5);
      await tester.tap(find.text(t.cancel));
      await _settle(tester);
      expect(find.text(t.quitGameQ), findsNothing);
      expect(sounds.clicks, 5);

      // Under a cold start's resume veil the player sees the veil, not the
      // lobby: Back asks to quit without the lobby's click.
      state.resuming = true;
      await back();
      expect(find.text(t.quitGameQ), findsOneWidget);
      expect(sounds.clicks, 5);
      await tester.tap(find.text(t.cancel));
      await _settle(tester);
      state.resuming = false;

      // Under the no-winnings panel Back is the panel's quit question, not
      // the lobby's.
      state.consentPending = true;
      await back();
      expect(find.text(t.quitGameQ), findsOneWidget);
      expect(sounds.clicks, 5);
      await tester.tap(find.text(t.cancel));
      await _settle(tester);

      await _tearDown(tester, state);
    },
  );

  testWidgets(
    'one sound a tap: no key that clicks also plays Material\'s tick, with '
    'the theme\'s own feedback on',
    (tester) async {
      final ticks = _countTicks(tester);
      final state = _state();
      final sounds = _Heard();
      addTearDown(sounds.dispose);
      await _pumpLobby(tester, state, sounds, materialSound: true);
      final t = state.t;

      Future<void> once(String name, Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pump(const Duration(milliseconds: 400));
        final clicks = sounds.clicks;
        final tick = ticks();
        await tester.tap(finder, warnIfMissed: false);
        await tester.pump();
        expect(sounds.clicks, clicks + 1, reason: '$name clicks once');
        expect(ticks(), tick, reason: '$name plays no Material tick');
      }

      // The top bar and the foot (the celebration's close key has a test of
      // its own).
      for (final MapEntry(key: name, value: finder) in {
        'the picture': find.byTooltip(t.yourPicture),
        'Shop': find.byType(ShopButton),
        'Settings': find.byTooltip(t.settings),
        'the Lucky Draw': find.text(t.luckyDrawChip),
        'the level key': find.byKey(const ValueKey('level-key')),
        'the record': find.byTooltip(t.yourRecord),
        'Friends': find.byType(FriendsKey),
      }.entries) {
        await once(name, finder);
        await _closeAll(tester, state);
      }

      // The private card's keys, the rail's cards, a corner key, the back
      // tile.
      await once('Create', find.text(t.create));
      await tester.enterText(find.byType(TextField), 'ABCD1234');
      await tester.pump();
      await once('Join', find.text(t.join));
      FocusManager.instance.primaryFocus?.unfocus();
      await _settle(tester);
      await once('the Seen card', find.text(t.viewTables).first);
      await _settle(tester);
      await once('ⓘ', find.byKey(const ValueKey('info-wave')).first);
      await _closeAll(tester, state);
      await once(
        'the rules key',
        find.byKey(const ValueKey('rule-book')).first,
      );
      await _closeAll(tester, state);
      await once('the back tile', find.byKey(const ValueKey('back-mark')));
      await _settle(tester);

      // The detector hears a tick where one is made: a plain button of the
      // same theme, outside the lobby's keys.
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(sound: true),
          home: Scaffold(
            body: Center(
              child: TextButton(onPressed: () {}, child: const Text('tick')),
            ),
          ),
        ),
      );
      final before = ticks();
      await tester.tap(find.text('tick'));
      await tester.pump();
      expect(ticks(), before + 1);

      await _tearDown(tester, state);
    },
  );

  testWidgets(
    'in and straight back out: a tap on the back tile while the front is '
    'still leaving throws nothing',
    (tester) async {
      final state = _state();
      final sounds = _Heard();
      addTearDown(sounds.dispose);
      await _pumpLobby(tester, state, sounds);

      // Seen, then at once the same spot, where the back tile is coming in
      // over the leaving front: five taps 30 ms apart.
      final spot = tester.getCenter(find.text(state.t.viewTables).first);
      for (var i = 0; i < 5; i++) {
        await tester.tapAt(spot);
        await tester.pump(const Duration(milliseconds: 30));
      }
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(sounds.clicks, greaterThanOrEqualTo(2));

      // And the private card on the front still measures and takes a code.
      if (state.lobbyCategory != null) {
        state.closeLobbyLevel();
        await _settle(tester);
      }
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'ABCD1234');
      await _settle(tester);
      expect(tester.takeException(), isNull);
      FocusManager.instance.primaryFocus?.unfocus();
      await _settle(tester);

      await _tearDown(tester, state);
    },
  );

  testWidgets('the table\'s Shop key keeps its own feel: no lobby click', (
    tester,
  ) async {
    final state = _state();
    final sounds = _Heard();
    addTearDown(sounds.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<GameState>.value(value: state),
          ChangeNotifierProvider<FeedbackSettings>.value(value: sounds),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(sound: false),
          builder: (context, child) => GlassBudget(child: child!),
          home: const Scaffold(body: Center(child: ShopButton())),
        ),
      ),
    );
    await tester.tap(find.byType(ShopButton));
    await tester.pump();
    expect(sounds.clicks, 0);
    await _closeAll(tester, state);
    await _tearDown(tester, state);
  });

  testWidgets('lobbyClick with no sounds in scope does nothing', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox.shrink();
        },
      ),
    );
    expect(() => lobbyClick(context), returnsNormally);
  });

  test('the Sound switch decides before a clip reaches the plugin', () async {
    SharedPreferences.setMockInitialValues({'soundOn': false});
    final sounds = _Heard();
    await sounds.load();
    sounds.cardClick();
    expect(sounds.heard, isEmpty);
    await sounds.setSound(true);
    sounds.cardClick();
    // The switch's own tick as it comes on, then the click.
    expect(sounds.heard, ['sfx/tick.wav', FeedbackSettings.cardClickClip]);
    sounds.dispose();
  });
}
