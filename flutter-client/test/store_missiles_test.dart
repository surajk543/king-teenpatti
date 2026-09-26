// The store's Missiles shelf (owner, 14 Sep 2026): the four trades priced in
// diamonds, the tab on the store in the lobby and at a table, the question
// before a trade, and the Diamonds shelf offered to a player who cannot pay.
// The header's fit with the fifth tab is checked shelf by shelf, screen by
// screen and language by language in store_hammers_test.dart.
//
// Since 24 Sep 2026 the shelf heads with the player's missiles beside the
// diamonds a pack is traded for (owner: "In store when user click on Missile
// tab, then it should also show the user current missile count just like it
// is showing diamond count") — the two in one dark panel, missiles first, as
// the Pictures shelf pairs diamonds and hammers. The second half checks that
// on the tightest phone at the largest text in every language, as the wallet
// changes under an open store, for the row-or-stacked rule at three screens,
// and for the width the header counts, which a trade must never change under
// the finger.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

User _user({required int diamonds, required int missiles}) => User.fromJson({
  'id': 'u1',
  'provider': 'guest',
  'displayName': 'Ravi',
  'chips': 1250000000,
  'diamond': diamonds,
  'hammer': 20,
  'missile': missiles,
});

GameState _state({
  Screen screen = Screen.lobby,
  AppLang lang = AppLang.english,
  int diamonds = 120,
  int missiles = 1,
}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = screen
    ..user = _user(diamonds: diamonds, missiles: missiles);
}

/// The figure on the missiles balance inside the shelf's panel, and nowhere
/// else in the store.
Finder _missilesShown(String figure) => find.descendant(
  of: find.descendant(
    of: find.byType(MissileWalletBalances),
    matching: find.byType(MissileBalance),
  ),
  matching: find.text(figure),
);

/// The figure on the diamonds balance inside the shelf's panel.
Finder _diamondsShown(String figure) => find.descendant(
  of: find.descendant(
    of: find.byType(MissileWalletBalances),
    matching: find.byType(DiamondBalance),
  ),
  matching: find.text(figure),
);

void main() {
  setUpAll(_loadInter);

  testWidgets('the missile shelf trades the four packs for diamonds', (
    tester,
  ) async {
    // Seven missiles: a count no pack's figure shares, so each figure below
    // is found once, on its card.
    final state = _state(missiles: 7);
    final feedback = FeedbackSettings();
    await _openStore(
      tester,
      state: state,
      feedback: feedback,
      tab: StoreTab.missiles,
    );

    expect(find.text('Missile Store'), findsOneWidget);
    expect(
      find.text('Trade diamonds: 15 diamonds = 1 missile.'),
      findsOneWidget,
    );
    // The header heads with the missiles held and the diamonds there are to
    // trade, in one panel (owner, 24 Sep 2026).
    expect(find.byType(MissileWalletBalances), findsOneWidget);
    expect(_missilesShown('7'), findsOneWidget);
    expect(_diamondsShown('120'), findsOneWidget);
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
      '1', '15', // 1 missile for 15 diamonds
      '5', '73', // 5 missiles for 73 diamonds
      '140', // 10 missiles for 140 diamonds
      '20', '220', // 20 missiles for 220 diamonds
    ]) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    // 10 once: the 10-missile pack (the single missile costs 15 since the
    // owner raised it on 14 Sep 2026).
    expect(find.text('10'), findsOneWidget);
    // Packs from earlier price lists are gone from the shelf.
    for (final gone in [
      '6',
      '13',
      '25',
      '30',
      '50',
      '100',
      '48',
      '90',
      '170',
    ]) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    // A single missile is named in the singular under its figure. No pack
    // on this shelf is marked, so none wears a badge (store polish, 26 Sep
    // 2026: a badge is for a pack the owner marked; the plates repeated the
    // wallet's name the line under the figure already gives).
    expect(find.text('MISSILES'), findsNothing);
    expect(find.text('MISSILE'), findsNothing);
    expect(find.text('Missiles'), findsNWidgets(3));
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
        expect(find.byType(MissileWalletBalances), findsNothing);

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
        // And the shelf heads with the missile held beside the diamonds.
        expect(_missilesShown('1'), findsOneWidget);
        expect(_diamondsShown('120'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await _close(tester, state, feedback);
      });
    }
  }

  testWidgets('a trade is asked first, with both wallets in view', (
    tester,
  ) async {
    final state = _state(diamonds: 80, missiles: 3);
    final feedback = FeedbackSettings();
    await _openStore(
      tester,
      state: state,
      feedback: feedback,
      tab: StoreTab.missiles,
    );
    final question = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_TradeDialog',
    );

    // The 5-missile pack, by its price.
    await tester.tap(find.text('73'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Trade diamonds?'), findsOneWidget);
    expect(find.text('Trade 73 diamonds for 5 missiles?'), findsOneWidget);
    expect(find.text('Trade'), findsOneWidget);
    // What the player holds, under the question — and, since 24 Sep 2026,
    // in the shelf's header behind it as well.
    expect(find.text('80'), findsWidgets);
    expect(
      find.descendant(of: question, matching: find.text('3')),
      findsOneWidget,
    );
    expect(_missilesShown('3'), findsOneWidget);
    expect(_diamondsShown('80'), findsOneWidget);

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
    expect(find.text('Trade 15 diamonds for 1 missile?'), findsOneWidget);
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
    // Seven missiles, so the single-missile pack's "1" is the only one.
    final state = _state(diamonds: 3, missiles: 7);
    final feedback = FeedbackSettings();
    await _openStore(
      tester,
      state: state,
      feedback: feedback,
      tab: StoreTab.missiles,
    );

    // The cheapest pack — 1 missile for 15 diamonds — by its figure.
    await tester.tap(find.text('1'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Trade diamonds?'), findsNothing);
    expect(find.text('Not enough diamonds'), findsOneWidget);
    expect(
      find.text('This trade needs 15 diamonds. Get more diamonds?'),
      findsOneWidget,
    );

    await tester.tap(find.text('Get diamonds'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Diamond Store'), findsOneWidget);
    expect(find.text('Missile Store'), findsNothing);
    // The Diamonds shelf heads with the diamonds alone, on their own pill.
    expect(find.byType(MissileWalletBalances), findsNothing);
    expect(find.byType(MissileBalance), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is DiamondBalance && w.framed),
      findsOneWidget,
    );

    await _close(tester, state, feedback);
  });

  // The missiles held on the shelf's header (owner, 24 Sep 2026).

  for (final lang in AppLang.values) {
    testWidgets(
      'on a 640x360 phone at the largest text in ${lang.englishName}, the '
      'Missiles shelf heads with the missiles held and the diamonds to trade',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.25;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final t = Strings(lang);
        final state = _state(lang: lang, diamonds: 100, missiles: 3);
        final feedback = FeedbackSettings();

        await _openStore(
          tester,
          state: state,
          feedback: feedback,
          tab: StoreTab.missiles,
          screen: const Size(640, 360),
        );
        // One panel: the diamonds the packs are paid in, then the missiles.
        expect(find.byType(MissileWalletBalances), findsOneWidget);
        expect(_missilesShown('3'), findsOneWidget);
        expect(_diamondsShown('100'), findsOneWidget);
        // Marked with the rocket the table's wallet and the lobby bar use.
        expect(
          find.descendant(
            of: find.byType(MissileWalletBalances),
            matching: find.byIcon(missileIcon),
          ),
          findsOneWidget,
        );
        // Diamonds first — above the missiles or to their left — the order
        // the table's wallet pill and the trade dialog over this shelf give
        // the two (review, 24 Sep 2026); the count is beside them, not
        // instead of them.
        final missiles = tester.getTopLeft(find.byType(MissileBalance));
        final diamonds = tester.getTopLeft(find.byType(DiamondBalance));
        expect(diamonds.dy < missiles.dy || diamonds.dx < missiles.dx, isTrue);
        expect(find.byType(HammerBalance), findsNothing);
        expect(find.byType(PictureWalletBalances), findsNothing);
        // The shelf's own blurb keeps its words beside the panel.
        expect(
          tester
              .renderObject<RenderParagraph>(find.text(t.storeMissilesBlurb))
              .didExceedMaxLines,
          isFalse,
        );
        // A header that no longer fits reports a RenderFlex overflow.
        expect(tester.takeException(), isNull);

        await _close(tester, state, feedback);
      },
    );
  }

  testWidgets('the missiles on the shelf follow the wallet while it is open', (
    tester,
  ) async {
    final state = _state(diamonds: 100, missiles: 3);
    final feedback = FeedbackSettings();
    await _openStore(
      tester,
      state: state,
      feedback: feedback,
      tab: StoreTab.missiles,
    );
    expect(_missilesShown('3'), findsOneWidget);
    expect(_diamondsShown('100'), findsOneWidget);

    // A trade lands: the account comes back from the server with five more
    // missiles and 73 fewer diamonds, and the store, which watches the state,
    // shows both at once.
    state.user = _user(diamonds: 27, missiles: 8);
    state.notifyListeners();
    await tester.pump();
    expect(_missilesShown('8'), findsOneWidget);
    expect(_missilesShown('3'), findsNothing);
    expect(_diamondsShown('27'), findsOneWidget);
    expect(_diamondsShown('100'), findsNothing);
    expect(tester.takeException(), isNull);

    await _close(tester, state, feedback);
  });

  for (final (size, scale, stacked) in const [
    (Size(1280, 800), 1.0, false),
    // One over the other at 891x411 since the seventh shelf (Emojis, owner
    // 26 Sep 2026) took a key's width from the header: beside the row the
    // widest blurb no longer keeps its one line there.
    (Size(891, 411), 1.0, true),
    (Size(640, 360), 1.25, true),
  ]) {
    final name = '${size.width.toInt()}x${size.height.toInt()}';
    testWidgets(
      'on the Missiles shelf at $name, text x$scale, the two wallets stand '
      '${stacked ? 'one over the other' : 'in a row'}, in the lobby and at a '
      'table',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final screen in [Screen.lobby, Screen.table]) {
          final state = _state(screen: screen, diamonds: 100, missiles: 3);
          final feedback = FeedbackSettings();
          await _openStore(
            tester,
            state: state,
            feedback: feedback,
            tab: StoreTab.missiles,
            screen: size,
          );

          final wallets = find.byType(MissileWalletBalances);
          expect(wallets, findsOneWidget, reason: screen.name);
          expect(
            tester.widget<MissileWalletBalances>(wallets).stacked,
            stacked,
            reason: screen.name,
          );
          expect(_missilesShown('3'), findsOneWidget, reason: screen.name);
          expect(_diamondsShown('100'), findsOneWidget, reason: screen.name);
          expect(tester.takeException(), isNull, reason: screen.name);

          await _close(tester, state, feedback);
        }
      },
    );
  }

  testWidgets(
    'the width the header counts for the pair is one width for any counts '
    'of up to three figures, stacked no wider than a row',
    (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(sound: false),
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      double width({
        required int missiles,
        required int diamonds,
        bool stacked = false,
      }) => MissileWalletBalances.width(
        context,
        missiles: missiles,
        diamonds: diamonds,
        stacked: stacked,
      );
      // A trade taking 100 diamonds to 27 and 3 missiles to 8 moves nothing
      // under the finger that made it.
      expect(
        width(missiles: 3, diamonds: 100),
        width(missiles: 8, diamonds: 27),
      );
      expect(
        width(missiles: 1, diamonds: 1),
        width(missiles: 999, diamonds: 999),
      );
      expect(
        width(missiles: 3, diamonds: 100, stacked: true),
        lessThan(width(missiles: 3, diamonds: 100)),
      );
      // The same panel as the Pictures shelf's, so the header's sum on every
      // shelf is what it was before the Missiles shelf gained its pair.
      expect(
        width(missiles: 3, diamonds: 100, stacked: true),
        PictureWalletBalances.width(
          context,
          diamonds: 100,
          hammers: 250,
          stacked: true,
        ),
      );
    },
  );
}
