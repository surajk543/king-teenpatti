// The Premium Packages (owner, 14 Sep 2026): chips, missiles and hammers in
// one Play purchase, sold under their own heading on the store's Chips shelf
// in the lobby and at a table.
//
// The shelf is laid out for real, with Inter loaded, on the three screens the
// game is checked on, in all five languages, at the normal text scale and the
// 1.25 ceiling, in Indian and international numbering. A RenderFlex overflow
// fails a test by itself; the cards are also measured, so the widest figure —
// "2,500 Crore 👑", "25 Billion 👑" — is seen to sit inside its card.
//
// The ₹49,999 and ₹99,999 packages were dropped on 22 Sep 2026 (owner), so the
// shelf is four cards and the two marks moved down to the dearest pair left.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

Map<String, dynamic> _user({int chips = 1250000000}) => {
  'id': 'u1',
  'provider': 'guest',
  'displayName': 'Ravi',
  'chips': chips,
  'diamond': 100,
  'hammer': 250,
  'missile': 50,
};

GameState _state({
  Screen screen = Screen.lobby,
  AppLang lang = AppLang.english,
}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = screen
    ..user = User.fromJson(_user());
}

/// What `GameState` hands [formatChips] for [lang] in [system].
void _publishNumbers(AppLang lang, NumberSystem system) {
  final t = Strings(lang);
  chipNumberSystem = system;
  chipUnits = (
    lakh: t.unitLakh,
    crore: t.unitCrore,
    million: t.unitMillion,
    billion: t.unitBillion,
  );
}

void _resetNumbers() => _publishNumbers(AppLang.english, NumberSystem.indian);

Future<void> _openStore(
  WidgetTester tester, {
  required GameState state,
  required FeedbackSettings feedback,
  StoreTab tab = StoreTab.chips,
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
  // The sheet's entrance, and the packs set out one stagger apart: the
  // premium cards follow the nine chip packs. A card's entrance starts on the
  // frame after its delay has run out, so two more frames let the last of
  // them finish rather than be measured 26dp below where it settles.
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _closeStore(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

final _premiumCards = _private('_PremiumPackCard');

void _setScreen(WidgetTester tester, Size size, {double scale = 1.0}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  setUpAll(_loadInter);
  tearDown(_resetNumbers);

  group('the premium packages', () {
    test("are the owner's four, cheapest first, with his figures", () {
      expect(
        [
          for (final p in premiumPacks)
            (p.productId, p.rupees, p.chips, p.missiles, p.hammers),
        ],
        [
          ('premium_1_9999', 9999, 6500000000, 1, 10),
          ('premium_2_14999', 14999, 10500000000, 2, 15),
          ('premium_3_19999', 19999, 15000000000, 4, 21),
          ('premium_4_29999', 29999, 25000000000, 6, 30),
        ],
      );
    });

    test('mark ⭐ on ₹19,999 and 👑 on ₹29,999, and nothing else', () {
      // The marks sat on ₹49,999 and ₹99,999 until those two packages left the
      // shelf on 22 Sep 2026; they moved down to the dearest pair that remains
      // rather than leaving the shelf with nothing marked.
      expect(
        [for (final p in premiumPacks) p.mark],
        [
          ShelfMark.none,
          ShelfMark.none,
          ShelfMark.popular,
          ShelfMark.crown,
        ],
      );
      expect(shelfMarkGlyph(ShelfMark.popular), '⭐');
      expect(shelfMarkGlyph(ShelfMark.bestValue), '🔥');
      expect(shelfMarkGlyph(ShelfMark.crown), '👑');
      for (final plain in [
        ShelfMark.none,
        ShelfMark.starter,
        ShelfMark.premium,
      ]) {
        expect(shelfMarkGlyph(plain), isNull, reason: '$plain');
      }
    });

    test('are written in Crore as the owner wrote them', () {
      _publishNumbers(AppLang.english, NumberSystem.indian);
      expect(
        [for (final p in premiumPacks) formatChips(p.chips)],
        [
          '650 Crore',
          '1,050 Crore',
          '1,500 Crore',
          '2,500 Crore',
        ],
      );
      _publishNumbers(AppLang.english, NumberSystem.international);
      expect(
        [for (final p in premiumPacks) formatChips(p.chips)],
        [
          '6.5 Billion',
          '10.5 Billion',
          '15 Billion',
          '25 Billion',
        ],
      );
    });

    test('share no product id with any other shelf', () {
      final ids = [
        ...chipPacks.map((p) => p.productId),
        ...premiumPacks.map((p) => p.productId),
        ...diamondPacks.map((p) => p.productId),
        ...hammerPacks.map((p) => p.productId),
        ...missilePacks.map((p) => p.packId),
      ];
      expect(ids.toSet(), hasLength(ids.length));
      for (final (i, p) in premiumPacks.indexed) {
        expect(p.productId, 'premium_${i + 1}_${p.rupees}');
      }
    });
  });

  group('POST /api/purchases/google', () {
    test(
      'sends the receipt and reads the missiles beside the hammers',
      () async {
        late http.Request sent;
        final client = MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({
              'user': _user(chips: 25001250000),
              'credited': true,
              'chips': 25000000000,
              'diamonds': 0,
              'hammers': 30,
              'missiles': 6,
              'balance': 25001250000,
            }),
            200,
          );
        });
        final r = await http.runWithClient(
          () => ApiClient(
            'http://api.test',
          ).redeemPurchase('tok', 'premium_4_29999', 'gplay-token'),
          () => client,
        );

        expect(sent.method, 'POST');
        expect(sent.url.toString(), 'http://api.test/api/purchases/google');
        expect(sent.headers['Authorization'], 'Bearer tok');
        expect(jsonDecode(sent.body), {
          'productId': 'premium_4_29999',
          'purchaseToken': 'gplay-token',
        });
        expect(r.credited, isTrue);
        expect(r.chips, 25000000000);
        expect(r.diamonds, 0);
        expect(r.hammers, 30);
        expect(r.missiles, 6);
        expect(r.balance, 25001250000);
        expect(r.user?.chips, 25001250000);
      },
    );

    test('an older server, or a chip pack, sends no missiles: 0', () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'user': _user(),
            'credited': false,
            'chips': 19200000,
            'balance': 1269200000,
          }),
          200,
        ),
      );
      final r = await http.runWithClient(
        () => ApiClient(
          'http://api.test',
        ).redeemPurchase('tok', 'chips_a_99', 'gplay-token'),
        () => client,
      );
      expect(r.credited, isFalse);
      expect(r.missiles, 0);
      expect(r.hammers, 0);
      expect(r.diamonds, 0);
      expect(r.chips, 19200000);
    });
  });

  group('a credited purchase', () {
    test('of a premium package is celebrated in the lobby with all three', () {
      final state = _state();
      state.announcePurchase(
        chips: 6500000000,
        diamonds: 0,
        hammers: 10,
        missiles: 1,
      );
      expect(state.rewardWon?.kind, 'premium');
      expect(state.rewardWon?.amount, 6500000000);
      expect(state.rewardWon?.missiles, 1);
      expect(state.rewardWon?.hammers, 10);
      expect(state.notice, isNull);
      state.dispose();
    });

    test('of a premium package at a table is a notice naming all three', () {
      for (final lang in AppLang.values) {
        final state = _state(screen: Screen.table, lang: lang);
        _publishNumbers(lang, NumberSystem.indian);
        final t = Strings(lang);
        state.announcePurchase(
          chips: 6500000000,
          diamonds: 0,
          hammers: 10,
          missiles: 1,
        );
        expect(state.rewardWon, isNull, reason: lang.code);
        expect(
          state.notice,
          t.premiumAdded('650 ${t.unitCrore}', 1, 10),
          reason: lang.code,
        );
        state.notice = null;
        state.announcePurchase(
          chips: 105000000000,
          diamonds: 0,
          hammers: 100,
          missiles: 50,
        );
        expect(
          state.notice,
          t.premiumAdded('10,500 ${t.unitCrore}', 50, 100),
          reason: lang.code,
        );
        state.dispose();
      }
      const english = Strings(AppLang.english);
      expect(
        english.premiumAdded('650 Crore', 1, 10),
        'Premium Package added: 650 Crore chips, 1 missile and 10 hammers',
      );
      expect(
        english.premiumAdded('10,500 Crore', 50, 100),
        'Premium Package added: 10,500 Crore chips, 50 missiles and 100 hammers',
      );
    });

    test('of a single wallet is celebrated as before', () {
      final state = _state();
      state.announcePurchase(
        chips: 19200000,
        diamonds: 0,
        hammers: 0,
        missiles: 0,
      );
      expect(state.rewardWon?.kind, 'purchase');
      expect(state.rewardWon?.amount, 19200000);
      state.announcePurchase(chips: 0, diamonds: 5, hammers: 0, missiles: 0);
      expect(state.rewardWon?.kind, 'diamonds');
      expect(state.rewardWon?.amount, 5);
      state.announcePurchase(chips: 0, diamonds: 0, hammers: 50, missiles: 0);
      expect(state.rewardWon?.kind, 'hammers');
      expect(state.rewardWon?.amount, 50);
      state.dispose();
    });
  });

  group('the celebration', () {
    for (final size in const [Size(640, 360), Size(891, 411)]) {
      for (final lang in AppLang.values) {
        final name = '${size.width.toInt()}x${size.height.toInt()}';
        testWidgets(
          'at $name in ${lang.englishName} shows the chips, the missiles and '
          'the hammers of a premium package',
          (tester) async {
            _setScreen(tester, size, scale: 1.25);
            _publishNumbers(lang, NumberSystem.indian);
            final t = Strings(lang);
            final feedback = FeedbackSettings();
            final state = _state(lang: lang);

            for (final (chips, missiles, hammers) in [
              (6500000000, 1, 10),
              (105000000000, 50, 100),
            ]) {
              state.announcePurchase(
                chips: chips,
                diamonds: 0,
                hammers: hammers,
                missiles: missiles,
              );
              await tester.pumpWidget(
                MultiProvider(
                  providers: [
                    ChangeNotifierProvider<GameState>.value(value: state),
                    ChangeNotifierProvider<FeedbackSettings>.value(
                      value: feedback,
                    ),
                  ],
                  child: MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: AppTheme.dark(sound: false),
                    builder: (context, child) => GlassBudget(child: child!),
                    home: const LobbyScreen(),
                  ),
                ),
              );
              await tester.pump(const Duration(seconds: 1));
              await tester.pump(const Duration(seconds: 1));

              expect(find.text(t.rewardCollected), findsOneWidget);
              expect(find.text('+ ${formatChips(chips)}'), findsOneWidget);
              expect(find.text(t.plusMissiles(missiles)), findsOneWidget);
              expect(find.text(t.plusHammers(hammers)), findsOneWidget);
              expect(find.text(t.rewardPremiumPurchased), findsOneWidget);
              expect(tester.takeException(), isNull);

              state.dismissReward();
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pump(const Duration(seconds: 1));
            }
            expect(
              const Strings(AppLang.english).plusMissiles(1),
              '+1 Missile',
            );

            state.dispose();
            feedback.dispose();
          },
        );
      }
    }
  });

  group('the Chips shelf', () {
    for (final screen in [Screen.lobby, Screen.table]) {
      testWidgets('in the ${screen.name} store sells the four packages under '
          'their heading', (tester) async {
        _setScreen(tester, const Size(891, 411));
        final state = _state(screen: screen);
        final feedback = FeedbackSettings();
        await _openStore(tester, state: state, feedback: feedback);

        expect(find.text('Chip Store'), findsOneWidget);
        expect(find.text('Premium Packages'), findsOneWidget);
        expect(_premiumCards, findsNWidgets(premiumPacks.length));
        // Every card carries the ribbon, and nothing else does.
        expect(find.text('PREMIUM PACKAGE'), findsNWidgets(premiumPacks.length));
        for (var i = 0; i < premiumPacks.length; i++) {
          expect(
            find.descendant(
              of: _premiumCards.at(i),
              matching: find.text('PREMIUM PACKAGE'),
            ),
            findsOneWidget,
          );
        }
        // Play is not available in a test, so each card shows its list price.
        for (final price in [
          '₹9,999',
          '₹14,999',
          '₹19,999',
          '₹29,999',
        ]) {
          expect(find.text(price), findsOneWidget, reason: price);
        }
        for (final (i, (figure, missiles, hammers)) in [
          ('650 Crore', '+1 Missile', '+10 Hammers'),
          ('1,050 Crore', '+2 Missiles', '+15 Hammers'),
          ('1,500 Crore', '+4 Missiles', '+21 Hammers'),
          ('2,500 Crore', '+6 Missiles', '+30 Hammers'),
        ].indexed) {
          for (final line in [figure, missiles, hammers]) {
            expect(
              find.descendant(
                of: _premiumCards.at(i),
                matching: find.text(line),
              ),
              findsOneWidget,
              reason: 'card $i: $line',
            );
          }
        }
        // Each line under the figure wears its wallet's mark.
        expect(
          find.descendant(
            of: _premiumCards.first,
            matching: find.byIcon(Icons.rocket_launch_rounded),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: _premiumCards.first,
            matching: find.byIcon(Icons.hardware),
          ),
          findsOneWidget,
        );

        // ⭐ and 👑 stand beside the figures of the last two, and only there.
        expect(find.text('⭐'), findsOneWidget);
        expect(find.text('👑'), findsOneWidget);
        for (final (i, glyph, figure) in [
          (2, '⭐', '1,500 Crore'),
          (3, '👑', '2,500 Crore'),
        ]) {
          final mark = tester.getRect(
            find.descendant(
              of: _premiumCards.at(i),
              matching: find.text(glyph),
            ),
          );
          final number = tester.getRect(
            find.descendant(
              of: _premiumCards.at(i),
              matching: find.text(figure),
            ),
          );
          expect(mark.left, greaterThanOrEqualTo(number.right), reason: glyph);
          expect(mark.left - number.right, lessThan(12), reason: glyph);
          expect(
            mark.center.dy,
            closeTo(number.center.dy, number.height / 2),
            reason: glyph,
          );
        }

        // The section sits under the nine chip packs, its heading between.
        final heading = tester.getRect(find.text('Premium Packages'));
        final lastChipPack = tester.getRect(_private('_PackCard').last);
        expect(heading.top, greaterThan(lastChipPack.bottom));
        expect(
          tester.getRect(_premiumCards.first).top,
          greaterThan(heading.bottom),
        );
        expect(tester.takeException(), isNull);

        await _closeStore(tester);
        state.dispose();
        feedback.dispose();
      });
    }

    const screens = [Size(640, 360), Size(891, 411), Size(1280, 800)];
    for (final size in screens) {
      for (final lang in AppLang.values) {
        for (final scale in [1.0, 1.25]) {
          for (final system in NumberSystem.values) {
            final name = '${size.width.toInt()}x${size.height.toInt()}';
            testWidgets(
              'at $name in ${lang.englishName}, text x$scale, ${system.name} '
              'numbering, every premium card holds its words',
              (tester) async {
                _setScreen(tester, size, scale: scale);
                _publishNumbers(lang, system);
                final t = Strings(lang);
                final state = _state(lang: lang);
                final feedback = FeedbackSettings();
                await _openStore(tester, state: state, feedback: feedback);

                // In Hindi the heading and the plate are the same words, so the
                // heading is looked for where it stands.
                expect(
                  find.descendant(
                    of: _private('_PremiumHeading'),
                    matching: find.text(t.premiumPackages),
                  ),
                  findsOneWidget,
                );
                expect(_premiumCards, findsNWidgets(premiumPacks.length));
                final failures = <String>[];
                for (final (i, p) in premiumPacks.indexed) {
                  final card = tester.getRect(_premiumCards.at(i));
                  final texts = find.descendant(
                    of: _premiumCards.at(i),
                    matching: find.byType(Text),
                  );
                  for (var k = 0; k < texts.evaluate().length; k++) {
                    final rect = tester.getRect(texts.at(k));
                    final words =
                        (texts.at(k).evaluate().single.widget as Text).data;
                    if (!card.inflate(0.5).contains(rect.topLeft) ||
                        !card.inflate(0.5).contains(rect.bottomRight)) {
                      failures.add('card $i "$words" $rect is outside $card');
                    }
                  }
                  // The figure is the offer: never shrunk past reading.
                  final figure = tester.getRect(
                    find.descendant(
                      of: _premiumCards.at(i),
                      matching: find.text(formatChips(p.chips)),
                    ),
                  );
                  if (figure.height < 16) {
                    failures.add(
                      'card $i "${formatChips(p.chips)}" is ${figure.height} tall',
                    );
                  }
                }
                expect(failures, isEmpty, reason: failures.join('\n'));
                expect(tester.takeException(), isNull);

                await _closeStore(tester);
                state.dispose();
                feedback.dispose();
              },
            );
          }
        }
      }
    }
  });
}
