// The badge on the lobby's game cards (owner, 27 Sep 2026: "On Lobby in top
// right of card show the badge with minimum tax user holding" — "show badge
// only on seen, blind and variation card"): the badge that brings the
// player's winning tax lowest (User.shownBadge), its own art over its own
// rate, at the right end of the Seen, Blind and Variation cards' name line.
//
// Pinned here: which cards carry it (the three, never the private card, an
// engine's card or a poker game's); which badge (the lowest rate held, the
// first on a tie) and what it says; nothing without a badge; a tap on it is a
// tap on the card; the one-second tick never rebuilds it; what a screen
// reader hears in all five languages; and, with the phone's Noto fonts, the
// badge inside its card's top-right corner and clear of the card's name at
// 592x360, 640x360, 891x411 and 1280x800, x1.0 and x1.25, in all five
// languages and both themes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/config/features.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/game_card.dart';
import 'package:teenpatti/widgets/lobby_card_badge.dart';
import 'package:teenpatti/widgets/table_tax.dart';

import 'level_fixtures.dart';

final _badge = find.byType(LobbyCardBadge);
final _drawn = find.byKey(const ValueKey('lobby-card-badge'));

/// The menu: the three Teen Patti games and, for the switch's sake, poker.
GameConfig _menu({bool poker = false}) => GameConfig.fromJson({
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'tables': [
    for (final (category, boot) in const [
      ('seen', 200),
      ('blind', 200),
      ('blind', 5000),
      ('variation', 50000),
    ])
      {
        'category': category,
        'bootAmount': boot,
        'winnerTax': true,
        'winnerTaxMinWinnings': 5000000,
      },
    if (poker) {'category': 'texas_holdem', 'bootAmount': 50000},
  ],
});

GameState _state({
  List<Map<String, Object?>>? badges,
  AppLang lang = AppLang.english,
  bool poker = false,
}) {
  final level = levelAt(10, xp: 4180);
  final state = levelState(level: level, lang: lang)
    ..config = _menu(poker: poker);
  state.user = User.fromJson({
    'id': 'u0',
    'provider': 'guest',
    'displayName': 'Guest0E00B',
    'chips': 324500,
    'playerLevel': level,
    'badges': badges ?? [regularBadge()],
  });
  return state;
}

/// The card a finder's widget stands on.
Rect _cardOf(WidgetTester tester, Finder f) =>
    tester.getRect(find.ancestor(of: f, matching: find.byType(GameCard)).first);

/// The rate each drawn badge says.
List<String> _rates(WidgetTester tester) => [
  for (final e
      in find
          .descendant(
            of: _drawn,
            matching: find.byWidgetPredicate(
              (w) => w is Text && (w.data ?? '').endsWith('%'),
            ),
          )
          .evaluate())
    (e.widget as Text).data!,
];

void main() {
  setUpAll(() async {
    await loadLevelFonts();
  });
  setUp(primeBadges);
  tearDown(() => AppFeatures.poker = false);
  tearDownAll(PictureCache.clearMemory);

  group('which cards', () {
    testWidgets('the Seen, Blind and Variation cards, and no other', (
      tester,
    ) async {
      final state = _state();
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      await tester.pump(const Duration(seconds: 1));
      expect(_drawn, findsNWidgets(3));
      for (final name in ['SEEN', 'BLIND', 'VARIATION']) {
        final title = find.text(name);
        expect(title, findsOneWidget, reason: name);
        final card = _cardOf(tester, title);
        final inCard = [
          for (final e in _drawn.evaluate())
            if (card.contains(tester.getCenter(find.byWidget(e.widget)))) e,
        ];
        expect(inCard, hasLength(1), reason: '$name carries one badge');
      }
      // The private card, at the end of the rail, carries none.
      final private = _cardOf(tester, find.text('Private table'));
      for (final e in _drawn.evaluate()) {
        expect(
          private.contains(tester.getCenter(find.byWidget(e.widget))),
          isFalse,
        );
      }
      await unmountLevel(tester, state);
    });

    testWidgets('with Poker shown: no badge on an engine\'s card or a poker '
        'game\'s, and the three inside Teen Patti still carry it', (
      tester,
    ) async {
      AppFeatures.poker = true;
      final state = _state(poker: true);
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      await tester.pump(const Duration(seconds: 1));
      // The front: Teen Patti and Poker.
      expect(_drawn, findsNothing);
      state.openLobbyEngine('poker');
      await tester.pump(const Duration(seconds: 1));
      expect(_drawn, findsNothing);
      state.openLobbyEngine('teen_patti');
      await tester.pump(const Duration(seconds: 1));
      expect(_drawn, findsNWidgets(3));
      await unmountLevel(tester, state);
    });
  });

  group('which badge', () {
    testWidgets('Regular at 20% for everybody', (tester) async {
      final state = _state();
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      await tester.pump(const Duration(seconds: 1));
      expect(_rates(tester), ['20%', '20%', '20%']);
      final art = tester.widgetList<BadgeArt>(
        find.descendant(of: _drawn, matching: find.byType(BadgeArt)),
      );
      expect(art.map((a) => a.assetUrl).toSet(), {badgeUrl('REGULAR')});
      await unmountLevel(tester, state);
    });

    testWidgets('the lowest rate held wins: a Royal badge at 0%', (
      tester,
    ) async {
      final state = _state(
        badges: [
          regularBadge(),
          royalBadge('ROYAL_KING', const Duration(days: 12)),
        ],
      );
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      await tester.pump(const Duration(seconds: 1));
      expect(_rates(tester), ['0%', '0%', '0%']);
      final art = tester.widgetList<BadgeArt>(
        find.descendant(of: _drawn, matching: find.byType(BadgeArt)),
      );
      expect(art.map((a) => a.assetUrl).toSet(), {badgeUrl('ROYAL_KING')});
      await unmountLevel(tester, state);
    });

    testWidgets('nothing where the player holds no badge', (tester) async {
      final state = _state(badges: const []);
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      await tester.pump(const Duration(seconds: 1));
      expect(_badge, findsNWidgets(3), reason: 'the slot is there');
      expect(_drawn, findsNothing, reason: 'and draws nothing');
      await unmountLevel(tester, state);
    });

    testWidgets('a badge bought while the lobby is open replaces it', (
      tester,
    ) async {
      final state = _state();
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      await tester.pump(const Duration(seconds: 1));
      expect(_rates(tester), ['20%', '20%', '20%']);
      state.user = User.fromJson({
        'id': 'u0',
        'provider': 'guest',
        'displayName': 'Guest0E00B',
        'chips': 324500,
        'playerLevel': levelAt(10, xp: 4180),
        'badges': [
          regularBadge(),
          royalBadge('ROYAL_ACE', const Duration(days: 7)),
        ],
      });
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      state.notifyListeners();
      await tester.pump(const Duration(seconds: 1));
      expect(_rates(tester), ['0%', '0%', '0%']);
      await unmountLevel(tester, state);
    });
  });

  testWidgets('a tap on the badge opens its card', (tester) async {
    final state = _state();
    await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(_drawn.first);
    await tester.pump(const Duration(seconds: 1));
    expect(state.lobbyCategory, 'seen');
    await unmountLevel(tester, state);
  });

  testWidgets('the one-second tick never rebuilds it or restarts its '
      'animation', (tester) async {
    final state = _state();
    await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
    await tester.pump(const Duration(seconds: 1));
    final art = find.descendant(of: _drawn, matching: find.byType(BadgeArt));
    // The widgets now — read before the ticks, since an element's widget is
    // whatever it holds at the moment it is read.
    final before = [for (final e in art.evaluate()) e.widget];
    final rebuilt = <Type>{};
    debugOnRebuildDirtyWidget = (element, _) =>
        rebuilt.add(element.widget.runtimeType);
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    for (var i = 0; i < 3; i++) {
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      state.notifyListeners();
      await tester.pump(const Duration(seconds: 1));
    }
    debugOnRebuildDirtyWidget = null;
    final after = [for (final e in art.evaluate()) e.widget];
    expect(after, hasLength(3));
    for (var i = 0; i < 3; i++) {
      expect(
        identical(before[i], after[i]),
        isTrue,
        reason: 'the same art: nothing below the badge was built again',
      );
    }
    expect(rebuilt.contains(BadgeArt), isFalse);
    expect(rebuilt.where((t) => t.toString().startsWith('Lottie')), isEmpty);
    await unmountLevel(tester, state);
  });

  test('what a screen reader hears, in every language', () {
    const english = 'Regular badge, 20% winning tax';
    expect(
      Strings(AppLang.english).cardBadgeSemantics('Regular', '20%'),
      english,
    );
    for (final lang in AppLang.values) {
      final said = Strings(lang).cardBadgeSemantics('Regular', '20%');
      expect(said, contains('Regular'), reason: lang.name);
      expect(said, contains('20%'), reason: lang.name);
      if (lang != AppLang.english) {
        expect(said, isNot(english), reason: '${lang.name} is translated');
      }
    }
  });

  group('the corner', () {
    for (final size in const [
      Size(592, 360),
      Size(640, 360),
      Size(891, 411),
      Size(1280, 800),
    ]) {
      for (final scale in [1.0, 1.25]) {
        testWidgets('inside its card, clear of the name — '
            '${size.width.toInt()}x${size.height.toInt()} x$scale, every '
            'language, both themes', (tester) async {
          for (final lang in AppLang.values) {
            for (final dark in [true, false]) {
              final where = '${lang.name} ${dark ? 'dark' : 'light'}';
              final state = _state(lang: lang);
              await pumpLevelLobby(
                tester,
                state,
                screen: size,
                scale: scale,
                dark: dark,
              );
              await tester.pump(const Duration(seconds: 1));
              expect(tester.takeException(), isNull, reason: where);
              final screen = Offset.zero & size;
              var seen = 0;
              for (final e in _drawn.evaluate()) {
                final badge = tester.getRect(find.byWidget(e.widget));
                // Off the rail's edge: nothing to check.
                if (!screen.contains(badge.center)) continue;
                seen++;
                final card = _cardOf(tester, find.byWidget(e.widget));
                expect(
                  card.contains(badge.topLeft) &&
                      card.contains(badge.bottomRight - const Offset(1, 1)),
                  isTrue,
                  reason: '$where: the badge $badge inside its card $card',
                );
                // In the card's top-right quarter.
                expect(badge.left, greaterThan(card.center.dx), reason: where);
                expect(badge.bottom, lessThan(card.center.dy), reason: where);
                // Clear of the name beside it.
                for (final t
                    in find
                        .descendant(
                          of: find
                              .ancestor(
                                of: find.byWidget(e.widget),
                                matching: find.byType(Row),
                              )
                              .first,
                          matching: find.byType(RichText),
                        )
                        .evaluate()) {
                  final text = tester.getRect(find.byWidget(t.widget));
                  if (badge.contains(text.center)) continue; // its own rate
                  final overlap = text.intersect(badge);
                  expect(
                    overlap.width <= 0.5 || overlap.height <= 0.5,
                    isTrue,
                    reason: '$where: the name $text under the badge $badge',
                  );
                }
              }
              expect(seen, greaterThan(0), reason: '$where: none on screen');
              await unmountLevel(tester, state);
            }
          }
        });
      }
    }
  });
}
