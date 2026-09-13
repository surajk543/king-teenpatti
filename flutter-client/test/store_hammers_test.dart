// The store with its fourth shelf (owner, 13 Sep 2026): Chips | Diamonds |
// Hammers | Pictures, in the lobby and at a table.
//
// Every shelf is opened on the three screens the game is checked on, in all
// five languages, at the 1.25 text ceiling — the widest the tab words ever get.
// A header that no longer fits reports a RenderFlex overflow, which fails the
// test by itself; the hammer shelf is also checked for what it sells.
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

/// Opens the store on [tab] over an empty screen, and returns once it has
/// settled.
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
        // As main.dart builds it: the blur budget, and the transparent
        // Scaffold round the Navigator that every sheet's toasts and menus
        // stand on.
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
  // The sheet's entrance, and the packs set out one stagger apart.
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _closeStore(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

GameState _state({required Screen screen, required AppLang lang}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = screen
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 1250000000,
      'diamond': 100,
      'hammer': 250,
    });
}

void main() {
  setUpAll(_loadInter);

  const screens = [Size(640, 360), Size(891, 411), Size(1280, 800)];
  for (final screen in screens) {
    final name = '${screen.width.toInt()}x${screen.height.toInt()}';
    for (final lang in AppLang.values) {
      for (final atTable in [false, true]) {
        testWidgets(
          'at $name in ${lang.englishName}${atTable ? ' at a table' : ''}, '
          'every shelf fits its header at the largest text',
          (tester) async {
            tester.view.physicalSize = screen;
            tester.view.devicePixelRatio = 1;
            tester.platformDispatcher.textScaleFactorTestValue = 1.25;
            addTearDown(tester.view.reset);
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
            final state = _state(
              screen: atTable ? Screen.table : Screen.lobby,
              lang: lang,
            );
            final feedback = FeedbackSettings();

            for (final tab in StoreTab.values) {
              await _openStore(
                tester,
                state: state,
                feedback: feedback,
                tab: tab,
              );
              // Each shelf heads with its own wallet, where it has one.
              expect(
                find.byType(HammerBalance),
                tab == StoreTab.hammers ? findsOneWidget : findsNothing,
                reason: '$name ${lang.code} $tab',
              );
              await _closeStore(tester);
            }

            state.dispose();
            feedback.dispose();
          },
        );
      }
    }
  }

  testWidgets('the hammer shelf sells the four packs with their marks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(891, 411);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = _state(screen: Screen.lobby, lang: AppLang.english);
    final feedback = FeedbackSettings();

    await _openStore(
      tester,
      state: state,
      feedback: feedback,
      tab: StoreTab.hammers,
    );

    expect(find.text('Hammer Store'), findsOneWidget);
    // The header's balance is the player's count.
    expect(
      find.descendant(
        of: find.byType(HammerBalance),
        matching: find.text('250'),
      ),
      findsOneWidget,
    );
    // Play is not available in a test, so each card shows its list price.
    for (final price in ['₹300', '₹699', '₹1,299', '₹2,999']) {
      expect(find.text(price), findsOneWidget, reason: price);
    }
    for (final count in ['20', '50', '100']) {
      expect(find.text(count), findsOneWidget, reason: count);
    }
    expect(find.text('⭐ POPULAR'), findsOneWidget);
    expect(find.text('🔥 BEST VALUE'), findsOneWidget);
    // The two unmarked packs carry the shelf's name on their plate.
    expect(find.text('HAMMERS'), findsNWidgets(2));

    await _closeStore(tester);
    state.dispose();
    feedback.dispose();
  });
}
