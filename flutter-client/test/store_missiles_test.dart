// The store's Missiles shelf (owner, 14 Sep 2026): the four trades priced in
// diamonds, the tab on the store in the lobby and at a table, the question
// before a trade, and the Diamonds shelf offered to a player who cannot pay.
// The header's fit with the fifth tab is checked shelf by shelf, screen by
// screen and language by language in store_hammers_test.dart.
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

Future<void> _openStore(
  WidgetTester tester, {
  required GameState state,
  required FeedbackSettings feedback,
  required StoreTab tab,
  Size screen = const Size(891, 411),
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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

Future<void> _close(
  WidgetTester tester,
  GameState state,
  FeedbackSettings f,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
  state.dispose();
  f.dispose();
}

GameState _state({
  Screen screen = Screen.lobby,
  int diamonds = 120,
  int missiles = 1,
}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = AppLang.english
    ..screen = screen
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 1250000000,
      'diamond': diamonds,
      'hammer': 20,
      'missile': missiles,
    });
}

void main() {
  setUpAll(_loadInter);

  testWidgets('the missile shelf trades the four packs for diamonds', (
    tester,
  ) async {
    final state = _state();
    final feedback = FeedbackSettings();
    await _openStore(
      tester,
      state: state,
      feedback: feedback,
      tab: StoreTab.missiles,
    );

    expect(find.text('Missile Store'), findsOneWidget);
    expect(
      find.text('Trade diamonds: 10 diamonds = 1 missile.'),
      findsOneWidget,
    );
    // The header heads with the diamonds there are to trade.
    expect(
      find.descendant(
        of: find.byType(DiamondBalance),
        matching: find.text('120'),
      ),
      findsOneWidget,
    );
    // Priced in diamonds — a gem and a count — and never in rupees.
    expect(find.textContaining('₹'), findsNothing);
    // Each pack's own figures (owner, 14 Sep 2026): no longer a flat rate.
    for (final text in [
      '1', // 1 missile for 10 diamonds
      '5', '48', // 5 missiles for 48 diamonds
      '90', // 10 missiles for 90 diamonds
      '20', '170', // 20 missiles for 170 diamonds
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    // 10 twice: the single missile's price, and the 10-missile pack.
    expect(find.text('10'), findsNWidgets(2));
    // Packs from earlier price lists are gone from the shelf.
    for (final gone in ['6', '13', '25', '30', '50', '100']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    // A single missile is named in the singular, on its plate and under its
    // figure.
    expect(find.text('MISSILES'), findsNWidgets(3));
    expect(find.text('MISSILE'), findsOneWidget);
    expect(find.text('Missile'), findsOneWidget);

    await _close(tester, state, feedback);
  });

  for (final screen in [Screen.lobby, Screen.table]) {
    for (final size in [const Size(640, 360), const Size(1280, 800)]) {
      final name = '${size.width.toInt()}x${size.height.toInt()}';
      testWidgets('the ${screen.name} store at $name has a Missiles tab', (
        tester,
      ) async {
        final state = _state(screen: screen);
        final feedback = FeedbackSettings();
        await _openStore(
          tester,
          state: state,
          feedback: feedback,
          tab: StoreTab.chips,
          screen: size,
        );
        expect(find.text('Chip Store'), findsOneWidget);

        // The tab's own glyph: the Premium Packages on the Chips shelf mark
        // their missiles with the same one.
        final tab = find.ancestor(
          of: find.descendant(
            of: find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_StoreTabs',
            ),
            matching: find.byIcon(missileIcon),
          ),
          matching: find.byType(InkWell),
        );
        expect(tab, findsOneWidget);
        await tester.tap(tab);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(find.text('Missile Store'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await _close(tester, state, feedback);
      });
    }
  }

  testWidgets('a trade is asked first, with both wallets in view', (
    tester,
  ) async {
    final state = _state(diamonds: 60, missiles: 3);
    final feedback = FeedbackSettings();
    await _openStore(
      tester,
      state: state,
      feedback: feedback,
      tab: StoreTab.missiles,
    );

    // The 5-missile pack, by its price.
    await tester.tap(find.text('48'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Trade diamonds?'), findsOneWidget);
    expect(find.text('Trade 48 diamonds for 5 missiles?'), findsOneWidget);
    expect(find.text('Trade'), findsOneWidget);
    // What the player holds, under the question.
    expect(find.text('60'), findsWidgets);
    expect(find.text('3'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Trade diamonds?'), findsNothing);
    expect(find.text('Missile Store'), findsOneWidget);
    expect(state.tradingMissiles, isNull);

    // The one-missile pack, by its figure: asked in the singular.
    await tester.tap(find.text('1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Trade 10 diamonds for 1 missile?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Trade diamonds?'), findsNothing);
    expect(state.tradingMissiles, isNull);

    await _close(tester, state, feedback);
  });

  testWidgets('a pack the player cannot pay for offers the Diamonds shelf', (
    tester,
  ) async {
    final state = _state(diamonds: 3);
    final feedback = FeedbackSettings();
    await _openStore(
      tester,
      state: state,
      feedback: feedback,
      tab: StoreTab.missiles,
    );

    // The cheapest pack — 1 missile for 10 diamonds — by its figure.
    await tester.tap(find.text('1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Trade diamonds?'), findsNothing);
    expect(find.text('Not enough diamonds'), findsOneWidget);
    expect(
      find.text('This trade needs 10 diamonds. Get more diamonds?'),
      findsOneWidget,
    );

    await tester.tap(find.text('Get diamonds'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Diamond Store'), findsOneWidget);
    expect(find.text('Missile Store'), findsNothing);

    await _close(tester, state, feedback);
  });
}
