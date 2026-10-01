// The welcome rewards popup (owner, 30 Sep 2026: "WHen user login with new
// account it should show first consent pop up "before you play", then after
// show pop up Welcome Rewards which user must select confirm otherwise not
// able to proceed then Weekly Login pop up").
//
// These hold the popup to listing exactly what the account was given, in
// the player's language; the order — the no-winnings statement, then this,
// then the weekly login popup — with the app as main.dart builds it; Confirm
// as the one way past it (a tap outside does nothing, Back offers to quit);
// and a 640x360 and a 592x360 phone at text x1.25 in all five languages and
// both themes with no word cut. The sign-in leaving the grant for it is
// test/welcome_grant_test.dart's.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/main.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/reward_programs_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/welcome_rewards.dart';

import 'reward_fixtures.dart';

/// The owner's full welcome: every wallet, a picture, a table picture and
/// two emojis — eight rows.
WelcomeGrant _full() => WelcomeGrant.fromJson(const {
  'chips': 500000,
  'diamonds': 5,
  'hammers': 10,
  'missiles': 1,
  'pictures': [
    {
      'id': 7,
      'name': 'Lovestruck Cat',
      'url': 'https://example.test/cat.json',
      'assetFormat': 'LOTTIE',
      'currency': 'HAMMER',
      'type': 'PREMIUM',
      'cost': 50,
      'durationDays': 50,
      'owned': true,
    },
  ],
  'tablePictures': [
    {
      'id': 3,
      'name': 'Circle Background Pattern',
      'dayUrl': 'https://example.test/circle.json',
      'nightUrl': 'https://example.test/circle.json',
      'assetFormat': 'LOTTIE',
      'currency': 'COIN',
      'type': 'PREMIUM',
      'cost': 300000,
      'durationDays': 7,
      'owned': true,
    },
  ],
  'emojis': [
    {
      'id': 5,
      'name': 'Clapping Hands',
      'url': 'https://example.test/clap.json',
      'assetFormat': 'LOTTIE',
      'currency': 'HAMMER',
      'type': 'PREMIUM',
      'cost': 5,
      'durationDays': 30,
      'owned': true,
    },
    {
      'id': 9,
      'name': 'Face Blowing a Kiss',
      'url': 'https://example.test/kiss.json',
      'assetFormat': 'LOTTIE',
      'currency': 'HAMMER',
      'type': 'PREMIUM',
      'cost': 5,
      'durationDays': 30,
      'owned': true,
    },
  ],
})!;

/// The seed's welcome: the four wallets.
WelcomeGrant _seeded() => WelcomeGrant.fromJson(const {
  'chips': 500000,
  'diamonds': 5,
  'hammers': 10,
  'missiles': 1,
})!;

/// A weekly login streak with today still to collect.
Map<String, Object?> _due() => {
  'programs': [streakJson(day: 3, claimedToday: false), calendarJson()],
};

Finder get _layer => find.byKey(const ValueKey('welcome-rewards'));
Finder get _panel => find.byKey(const ValueKey('welcome-rewards-panel'));
Finder get _confirm => find.byKey(const ValueKey('welcome-rewards-confirm'));
Finder get _consent => find.byKey(const ValueKey('consent-gate'));
Finder get _weekly => find.byKey(const ValueKey('reward-offer-overlay'));
Finder _item(int i) => find.byKey(ValueKey('welcome-rewards-item-$i'));

/// The words of row [i].
String _itemText(WidgetTester tester, int i) => tester
    .widget<Text>(find.descendant(of: _item(i), matching: find.byType(Text)))
    .data!;

/// The panel alone, over a lobby-coloured ground, in [brightness].
Future<GameState> _pumpPanel(
  WidgetTester tester, {
  required WelcomeGrant grant,
  AppLang lang = AppLang.english,
  Brightness brightness = Brightness.dark,
}) async {
  final state = rewardState(lang: lang)..welcomePending = grant;
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    rewardApp(
      state,
      feedback,
      const Scaffold(body: WelcomeRewardsPanel()),
      brightness: brightness,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return state;
}

/// The whole app as main.dart builds it, at the lobby, with [state].
Future<void> _pumpApp(WidgetTester tester, GameState state) async {
  final feedback = FeedbackSettings();
  await feedback.load();
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
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadRewardFonts);

  group('the rows', () {
    test('are the grant in the order the summary names it', () {
      final rows = WelcomeRewardsPanel.prizesOf(_full());
      expect(rows.map((p) => p.kind), [
        RewardKind.chips,
        RewardKind.diamond,
        RewardKind.hammer,
        RewardKind.missile,
        RewardKind.profilePicture,
        RewardKind.tablePicture,
        RewardKind.emoji,
        RewardKind.emoji,
      ]);
      expect(rows[0].amount, 500000);
      expect(rows[1].amount, 5);
      expect(rows[2].amount, 10);
      expect(rows[3].amount, 1);
      expect(rows[4].itemName, 'Lovestruck Cat');
      expect(rows[5].itemName, 'Circle Background Pattern');
      expect(rows[6].itemName, 'Clapping Hands');
      expect(rows[7].itemName, 'Face Blowing a Kiss');
      // A wallet given nothing has no row; a grant of nothing none at all.
      expect(
        WelcomeRewardsPanel.prizesOf(
          const WelcomeGrant(chips: 1000, missiles: 2),
        ).map((p) => p.kind),
        [RewardKind.chips, RewardKind.missile],
      );
      expect(WelcomeRewardsPanel.prizesOf(const WelcomeGrant()), isEmpty);
    });

    test('the three strings exist in all five languages', () {
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        for (final s in [
          t.welcomeRewardsTitle,
          t.welcomeRewardsLead,
          t.welcomeConfirm,
        ]) {
          expect(s.trim(), isNotEmpty, reason: lang.code);
          expect(s, isNot(contains('{')), reason: '${lang.code}: $s');
        }
      }
      expect(const Strings(AppLang.english).welcomeConfirm, 'Confirm');
      expect(
        const Strings(AppLang.english).welcomeRewardsLead,
        'Added to your account:',
      );
    });

    testWidgets('list exactly what the account was given, in the player\'s '
        'language, under the title and over Confirm', (tester) async {
      await setRewardView(tester);
      final state = await _pumpPanel(
        tester,
        grant: _full(),
        lang: AppLang.hindi,
      );
      final t = state.t;
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('welcome-rewards-title')))
            .data,
        t.welcomeRewardsTitle,
      );
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('welcome-rewards-lead')))
            .data,
        t.welcomeRewardsLead,
      );
      final rows = WelcomeRewardsPanel.prizesOf(_full());
      for (var i = 0; i < rows.length; i++) {
        expect(_item(i), findsOneWidget, reason: 'row $i');
        expect(_itemText(tester, i), rewardPrizeLabel(t, rows[i]));
      }
      expect(_item(8), findsNothing);
      expect(_itemText(tester, 0), '5 Lakh चिप्स');
      expect(_itemText(tester, 4), contains('Lovestruck Cat'));
      // Confirm, and no other key.
      expect(_confirm, findsOneWidget);
      expect(find.text(t.welcomeConfirm), findsOneWidget);
      expect(find.text(t.close), findsNothing);
      // The title above the rows, Confirm below them.
      final title = tester.getRect(
        find.byKey(const ValueKey('welcome-rewards-title')),
      );
      final last = tester.getRect(_item(7));
      final confirm = tester.getRect(_confirm);
      expect(title.bottom, lessThanOrEqualTo(tester.getRect(_item(0)).top));
      expect(last.bottom, lessThanOrEqualTo(confirm.top));
      // What a screen reader hears of the list: the grant in one line.
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel(welcomeNotice(t, _full())!), findsOneWidget);
      handle.dispose();
      await unmountReward(tester, state);
    });

    testWidgets('a full grant\'s wallet rows stand two to a line on a phone '
        'and its items one under another, whole across; the seed\'s four '
        'wallets two to a line; three rows one under another', (tester) async {
      await setRewardView(tester);
      var state = await _pumpPanel(tester, grant: _full());
      Rect at(int i) => tester.getRect(_item(i));
      expect((at(0).top - at(1).top).abs(), lessThan(1));
      expect(at(1).left, greaterThan(at(0).right));
      expect(at(2).top, greaterThan(at(0).bottom - 1));
      expect((at(2).left - at(0).left).abs(), lessThan(1));
      // The picture, the table picture and the emojis each on a line of
      // their own, the card's whole width.
      for (var i = 4; i < 8; i++) {
        expect(at(i).top, greaterThan(at(i - 1).bottom - 1), reason: '$i');
        expect((at(i).left - at(0).left).abs(), lessThan(1), reason: '$i');
        expect(at(i).width, greaterThan(at(0).width * 1.9), reason: '$i');
      }
      await unmountReward(tester, state);

      // The seed's four wallets: two lines.
      state = await _pumpPanel(tester, grant: _seeded());
      expect((at(0).top - at(1).top).abs(), lessThan(1));
      expect(at(1).left, greaterThan(at(0).right));
      expect(at(2).top, greaterThan(at(0).bottom - 1));
      expect((at(2).top - at(3).top).abs(), lessThan(1));
      expect(at(3).left, greaterThan(at(2).right));
      await unmountReward(tester, state);

      // Three rows or fewer: one under another, the whole width.
      state = await _pumpPanel(
        tester,
        grant: const WelcomeGrant(chips: 500000, hammers: 10, missiles: 1),
      );
      for (var i = 1; i < 3; i++) {
        expect(at(i).top, greaterThan(at(i - 1).bottom - 1), reason: '$i');
        expect((at(i).left - at(0).left).abs(), lessThan(1), reason: '$i');
        expect((at(i).width - at(0).width).abs(), lessThan(1), reason: '$i');
      }
      expect(at(0).width, greaterThan(at(0).height * 4));
      await unmountReward(tester, state);
    });

    testWidgets('a grant of nothing is a plain welcome with no rows', (
      tester,
    ) async {
      await setRewardView(tester);
      final state = await _pumpPanel(tester, grant: const WelcomeGrant());
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('welcome-rewards-lead')))
            .data,
        state.t.welcomePlain,
      );
      expect(_item(0), findsNothing);
      expect(_confirm, findsOneWidget);
      await unmountReward(tester, state);
    });
  });

  group('the order', () {
    testWidgets('a new account meets "Before you play", then the welcome '
        'rewards, and the weekly login popup only once those are confirmed', (
      tester,
    ) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        // A new account: its consent not yet given, its grant not yet
        // confirmed, and a weekly login due.
        final state = rewardState(consented: false)..welcomePending = _full();
        await _pumpApp(tester, state);
        expect(find.byType(LobbyScreen), findsOneWidget);
        // The statement first; the popup and the weekly login wait.
        expect(state.consentPending, isTrue);
        expect(_consent, findsOneWidget);
        expect(_layer, findsNothing);
        expect(_weekly, findsNothing);
        // The weekly login is due — read while the statement stood — and
        // yet not offered.
        expect(state.rewardOffersDue, isNotEmpty);
        expect(state.rewardOffer, isNull);

        // "I confirm": the welcome rewards, and still no weekly login.
        await tester.tap(find.text(state.t.consentAccept));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(_consent, findsNothing);
        expect(_layer, findsOneWidget);
        expect(_panel, findsOneWidget);
        expect(_weekly, findsNothing);
        expect(state.rewardOffer, isNull);
        expect(state.welcomePending, isNotNull);

        // A tap outside changes nothing: the lobby under it takes no tap.
        await tester.tapAt(const Offset(4, 4));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(_layer, findsOneWidget);
        expect(state.welcomePending, isNotNull);
        expect(state.lobbyScaffold.currentState?.isEndDrawerOpen, isNot(true));

        // Back offers to quit, as under the statement, and never gets past.
        await tester
            .state<NavigatorState>(find.byType(Navigator).first)
            .maybePop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text(state.t.quitGameQ), findsOneWidget);
        expect(_layer, findsOneWidget);
        await tester.tap(find.text(state.t.cancel));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text(state.t.quitGameQ), findsNothing);
        expect(_layer, findsOneWidget);
        expect(state.welcomePending, isNotNull);

        // Confirm: the popup goes, and the weekly login comes.
        await tester.tap(_confirm);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(state.welcomePending, isNull);
        expect(_layer, findsNothing);
        expect(state.rewardOffer, isNotNull);
        expect(_weekly, findsOneWidget);
        // Nothing was claimed by any of it.
        expect(sent.where((r) => r.method == 'POST'), isEmpty);
        await unmountReward(tester, state);
      }, () => fakeRewards(sent: sent, programs: _due()));
    });

    testWidgets('a returning account, with nothing pending, sees only the '
        'weekly login', (tester) async {
      await setRewardView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState();
        await _pumpApp(tester, state);
        expect(_consent, findsNothing);
        expect(_layer, findsNothing);
        expect(_weekly, findsOneWidget);
        await unmountReward(tester, state);
      }, () => fakeRewards(sent: sent, programs: _due()));
    });

    test('the weekly login is not offered while the welcome waits, and is '
        'the moment it is confirmed', () async {
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = rewardState()..welcomePending = _seeded();
        // The consent's read lands.
        await pumpEventQueue();
        await state.loadRewardPrograms();
        expect(state.rewardOffersDue, isNotEmpty);
        expect(state.offerRewards(), isFalse);
        expect(state.rewardOffer, isNull);
        state.confirmWelcome();
        expect(state.welcomePending, isNull);
        expect(state.rewardOffer, isNotNull);
        // Signing out forgets both.
        await state.signOut();
        expect(state.welcomePending, isNull);
        expect(state.rewardOffer, isNull);
        state.dispose();
      }, () => fakeRewards(sent: sent, programs: _due()));
    });
  });

  for (final screen in const [Size(640, 360), Size(592, 360)]) {
    for (final lang in AppLang.values) {
      testWidgets(
        'fits a ${screen.width.toInt()}x${screen.height.toInt()} phone at '
        'text x1.25 in ${lang.name}, both themes, no word cut, Confirm '
        'reachable',
        (tester) async {
          await setRewardView(tester, screen: screen, textScale: 1.25);
          for (final brightness in Brightness.values) {
            final state = await _pumpPanel(
              tester,
              grant: _full(),
              lang: lang,
              brightness: brightness,
            );
            final reason = '${lang.name} ${brightness.name}';
            expect(tester.takeException(), isNull, reason: reason);
            final view = Offset.zero & screen;
            final panel = tester.getRect(_panel);
            expect(panel.width, lessThanOrEqualTo(view.width), reason: reason);
            expect(panel.left, greaterThanOrEqualTo(0), reason: reason);
            expect(panel.right, lessThanOrEqualTo(view.width), reason: reason);
            expectRewardWhole(tester, _panel, reason);
            for (var i = 0; i < 8; i++) {
              expect(_item(i), findsOneWidget, reason: '$reason row $i');
            }
            // Confirm at the foot — brought on screen where the card
            // scrolls — whole and a full target.
            await tester.ensureVisible(_confirm);
            await tester.pump();
            final confirm = tester.getRect(_confirm);
            expect(
              view.contains(confirm.topLeft) &&
                  view.contains(confirm.bottomRight - const Offset(1, 1)),
              isTrue,
              reason: '$reason $confirm',
            );
            expect(confirm.height, greaterThanOrEqualTo(44), reason: reason);
            expectRewardWhole(tester, _confirm, reason);
            await unmountReward(tester, state);
          }
        },
      );
    }
  }

  // Nothing here pumps the lobby's chips past the state: every path above
  // unmounts before disposing.
  tearDown(() => SharedPreferences.setMockInitialValues({}));
}
