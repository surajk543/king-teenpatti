// The Chips shelf heads with the player's chips (owner, 24 Sep 2026: "In store
// when user click on Coins tab, then it is not showing users current coin on
// top, just like we show for hammer") — in the pill and the place the Hammers
// shelf shows their hammers. Checked on the tightest phone at the largest
// text in every language, as the wallet changes under an open store, and at a
// table, where the seat's stack is the figure rather than the wallet.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

/// Opens the store on [tab] over an empty screen, as store_hammers_test does,
/// and returns once it has settled.
Future<void> _openStore(
  WidgetTester tester, {
  required GameState state,
  required FeedbackSettings feedback,
  required StoreTab tab,
}) async {
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
  unawaited(showChipStore(host, opensOn: tab));
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _closeStore(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

User _user({required int chips}) => User.fromJson({
  'id': 'u1',
  'provider': 'guest',
  'displayName': 'Ravi',
  'chips': chips,
  'diamond': 100,
  'hammer': 250,
});

GameState _state({
  Screen screen = Screen.lobby,
  AppLang lang = AppLang.english,
  int chips = 207400,
}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = screen
    ..user = _user(chips: chips);
}

Map<String, dynamic> _seat(int index) => {
  'seatIndex': index,
  'userId': 'u$index',
  'displayName': 'Player $index',
  'avatarUrl': null,
  'chips': 12500000,
  'status': 'active',
  'isBlind': false,
  'lastBet': 1600,
  'lastAction': 'raise',
  'contributed': 5800,
  'connected': true,
  'cardCount': 3,
};

/// A seen table mid-hand with the viewer holding [chips] on their seat.
RoomState _table({required int chips}) => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': 'seen',
  'chipsHidden': false,
  'state': 'betting',
  'handNo': 4,
  'dealerSeat': 2,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 29000,
  'maxPot': 2000000,
  'stake': 800,
  'you': {
    'seatIndex': 0,
    'chips': chips,
    'status': 'active',
    'isBlind': false,
    'blindMovesLeft': 0,
    'contributed': 5800,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': ['As', 'Kd', 'Qh'],
  },
  'seats': [for (var i = 0; i < 5; i++) _seat(i)],
});

/// The figure on the chips pill, and nowhere else in the store.
Finder _chipsShown(String figure) =>
    find.descendant(of: find.byType(ChipBalance), matching: find.text(figure));

void main() {
  setUpAll(_loadInter);

  for (final lang in AppLang.values) {
    testWidgets(
      'on a 640x360 phone at the largest text in ${lang.englishName}, the '
      'Chips shelf heads with the chips and the Hammers shelf still with '
      'the hammers',
      (tester) async {
        tester.view.physicalSize = const Size(640, 360);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.25;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final state = _state(lang: lang);
        final feedback = FeedbackSettings();
        addTearDown(state.dispose);
        addTearDown(feedback.dispose);

        await _openStore(
          tester,
          state: state,
          feedback: feedback,
          tab: StoreTab.chips,
        );
        // 2,07,400 chips, written as the lobby bar writes them.
        expect(_chipsShown('2.07 Lakh'), findsOneWidget);
        expect(find.byType(HammerBalance), findsNothing);
        // A header that no longer fits reports a RenderFlex overflow.
        expect(tester.takeException(), isNull);

        // The Hammers key: the tab strip's 18dp hammer, not the small ones on
        // the Premium Packages' cards. The strip may be cut and scrolling on
        // this phone, so bring it in first.
        final hammersKey = find.byWidgetPredicate(
          (w) => w is Icon && w.icon == Icons.hardware && w.size == 18,
        );
        expect(hammersKey, findsOneWidget);
        await tester.ensureVisible(hammersKey);
        await tester.tap(hammersKey);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(
          find.descendant(
            of: find.byType(HammerBalance),
            matching: find.text('250'),
          ),
          findsOneWidget,
        );
        expect(find.byType(ChipBalance), findsNothing);
        expect(tester.takeException(), isNull);

        await _closeStore(tester);
      },
    );
  }

  testWidgets('the chips on the shelf follow the wallet while it is open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _state();
    final feedback = FeedbackSettings();
    addTearDown(state.dispose);
    addTearDown(feedback.dispose);

    await _openStore(
      tester,
      state: state,
      feedback: feedback,
      tab: StoreTab.chips,
    );
    expect(_chipsShown('2.07 Lakh'), findsOneWidget);

    // A pack lands: the account comes back from the server with more.
    state.user = _user(chips: 5000000);
    state.notifyListeners();
    await tester.pump();
    expect(_chipsShown('50 Lakh'), findsOneWidget);
    expect(_chipsShown('2.07 Lakh'), findsNothing);

    await _closeStore(tester);
  });

  testWidgets('at a table the shelf heads with the seat, not the wallet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    // The wallet says 2,07,400; the seat, which is where a pack bought at
    // the table lands and what the drawer's "Your chips" shows, 1,50,000.
    final state = _state(screen: Screen.table)..room = _table(chips: 150000);
    final feedback = FeedbackSettings();
    addTearDown(state.dispose);
    addTearDown(feedback.dispose);

    await _openStore(
      tester,
      state: state,
      feedback: feedback,
      tab: StoreTab.chips,
    );
    expect(_chipsShown('1.5 Lakh'), findsOneWidget);
    expect(_chipsShown('2.07 Lakh'), findsNothing);
    expect(tester.takeException(), isNull);

    await _closeStore(tester);
  });
}
