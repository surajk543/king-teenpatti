// A tap on a lobby card is heard (owner, 26 Sep 2026: "this sound should be
// played when user click on card" — the lobby's cards):
// assets/sound/Card click.mp3, played by FeedbackSettings.cardClick() when an
// engine card (Teen Patti, Poker), a category card (Seen, Blind, Variation)
// or a table the player may sit at is tapped. Sitting down keeps its door as
// well; a padlocked table card goes nowhere and stays quiet.
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

/// Every sound the lobby asks for, in order.
class _Heard extends FeedbackSettings {
  final heard = <String>[];

  @override
  void cardClick() => heard.add('click');

  @override
  void enterTable() => heard.add('door');
}

GameState _state() {
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
    });
}

/// The cards' entrances, the level's transition and the stakes' count-up.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('an engine, a category and a table card click; a padlocked '
      'table stays quiet', (tester) async {
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
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.dark(sound: false),
          builder: (context, child) => GlassBudget(child: child!),
          home: const LobbyScreen(),
        ),
      ),
    );
    await _settle(tester);
    final t = state.t;

    // The Teen Patti card, into its games.
    await tester.tap(find.text(t.viewGames).first);
    await _settle(tester);
    expect(state.lobbyEngine, isNotNull);
    expect(sounds.heard, ['click']);

    // The Seen card, into its tables.
    await tester.tap(find.text(t.viewTables).first);
    await _settle(tester);
    expect(state.lobbyCategory, 'seen');
    expect(sounds.heard, ['click', 'click']);

    // A padlocked table: nothing happens, nothing is heard.
    final shut = find.text(t.lockedTitle);
    await tester.ensureVisible(shut);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(shut, warnIfMissed: false);
    await tester.pump();
    expect(sounds.heard, ['click', 'click']);

    // A table the player may sit at: the click, and the door as they sit.
    final open = find.text(t.tapToSit).first;
    await tester.ensureVisible(open);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(open);
    await tester.pump();
    expect(sounds.heard, ['click', 'click', 'click', 'door']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    state.dispose();
  });

  test("the owner's click is bundled where the lobby plays it from", () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    expect(FeedbackSettings.cardClickClip, 'sound/Card click.mp3');
    final clip = await rootBundle.load(
      'assets/${FeedbackSettings.cardClickClip}',
    );
    expect(clip.lengthInBytes, greaterThan(5000));
  });
}
