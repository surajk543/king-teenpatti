// The badge on the player's picture (owner, 29 Sep 2026: "Remove the badge
// and level symbol and tax text from card, seen card, variation, all card,
// instead add a badge on profile pic top right lobby" — and "In settings
// profile also u need to add badge"): the badge that brings the player's
// winning tax lowest (User.shownBadge), in its own art, on the top-right rim
// of the top bar's picture and of the Settings drawer's.
//
// Pinned here: no lobby card carries a badge, a level mark or a rate any more
// (the Seen, Blind and Variation cards, their table cards, and with Poker
// shown the engines' and poker games' cards); which badge the picture wears
// and nothing without one; a badge bought while the lobby is open; the one-
// second tick never rebuilding its Lottie; taps going to the picture; what a
// screen reader hears in all five languages; the Settings drawer's picture;
// and, at 592x360, 640x360, 891x411 and 1280x800, x1.0 and x1.25, both themes,
// the badge on the picture's top-right, on screen, clear of the name, and the
// name's box exactly what it is without a badge.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/config/features.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/avatar_badge.dart';
import 'package:teenpatti/widgets/game_card.dart';
import 'package:teenpatti/widgets/table_tax.dart';

import 'level_fixtures.dart';

final _badge = find.byKey(const ValueKey('avatar-badge'));

/// The menu: the three Teen Patti games, every table taxing its winners, and
/// for the switch's sake poker.
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

Map<String, Object?> _user(List<Map<String, Object?>> badges) => {
  'id': 'u0',
  'provider': 'guest',
  'displayName': 'Guest0E00B',
  'chips': 324500,
  'playerLevel': levelAt(10, xp: 4180),
  'badges': badges,
};

GameState _state({
  List<Map<String, Object?>>? badges,
  AppLang lang = AppLang.english,
  bool poker = false,
}) {
  final state = levelState(level: levelAt(10, xp: 4180), lang: lang)
    ..config = _menu(poker: poker);
  state.user = User.fromJson(_user(badges ?? [regularBadge()]));
  return state;
}

/// The art's box; the emblem the player sees is its middle.
Rect _art(WidgetTester tester, [Finder? which]) =>
    tester.getRect(which ?? _badge.first);

Rect _emblem(Rect art) =>
    art.deflate(art.width * (1 - AvatarBadge.emblemShare) / 2);

/// The picture's box: the Stack the badge is laid over.
Rect _picture(WidgetTester tester, Finder badge) => tester.getRect(
  find.ancestor(of: badge, matching: find.byType(Stack)).first,
);

void _notify(GameState state) {
  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
  state.notifyListeners();
}

void main() {
  setUpAll(() async {
    await loadLevelFonts();
  });
  setUp(primeBadges);
  tearDown(() => AppFeatures.poker = false);
  tearDownAll(PictureCache.clearMemory);

  group('the cards', () {
    Finder onCards(Finder f) =>
        find.descendant(of: find.byType(GameCard), matching: f);

    Future<void> expectBare(WidgetTester tester, String where) async {
      expect(find.byType(GameCard), findsWidgets, reason: where);
      for (final key in const [
        'lobby-card-badge',
        'lobby-card-level',
        'lobby-card-badge-rate',
        'table-card-badge',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: '$where $key');
      }
      expect(onCards(find.byType(BadgeArt)), findsNothing, reason: where);
      expect(onCards(find.byType(WinningTaxPill)), findsNothing, reason: where);
      expect(
        onCards(find.textContaining('%')),
        findsNothing,
        reason: '$where: no rate',
      );
      expect(
        onCards(find.text(ownersLevels[9].$4)),
        findsNothing,
        reason: '$where: no level mark',
      );
    }

    testWidgets('Seen, Blind, Variation and every table card carry no '
        'badge, level mark or rate', (tester) async {
      final state = _state();
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      await expectBare(tester, 'the front');
      for (final category in const ['seen', 'blind', 'variation']) {
        state.openLobbyCategory(category);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        await expectBare(tester, category);
      }
      await unmountLevel(tester, state);
    });

    testWidgets('with Poker shown: nor the engines\' cards or a poker '
        'game\'s', (tester) async {
      AppFeatures.poker = true;
      final state = _state(poker: true);
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      await expectBare(tester, 'the engines');
      for (final engine in const ['teen_patti', 'poker']) {
        state.openLobbyEngine(engine);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        await expectBare(tester, engine);
      }
      await unmountLevel(tester, state);
    });
  });

  group('the top bar\'s picture', () {
    testWidgets('wears the badge that brings the rate lowest: Regular for '
        'everybody', (tester) async {
      final state = _state();
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      expect(_badge, findsOneWidget);
      final art = tester.widget<BadgeArt>(
        find.descendant(of: _badge, matching: find.byType(BadgeArt)),
      );
      expect(art.assetUrl, badgeUrl('REGULAR'));
      await unmountLevel(tester, state);
    });

    testWidgets('a Royal badge held: the Royal badge', (tester) async {
      final state = _state(
        badges: [
          regularBadge(),
          royalBadge('ROYAL_KING', const Duration(days: 12)),
        ],
      );
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      final art = tester.widget<BadgeArt>(
        find.descendant(of: _badge, matching: find.byType(BadgeArt)),
      );
      expect(art.assetUrl, badgeUrl('ROYAL_KING'));
      await unmountLevel(tester, state);
    });

    testWidgets('no badge: nothing on the picture, and the picture is still '
        'there', (tester) async {
      final state = _state(badges: const []);
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      expect(find.byType(AvatarBadge), findsOneWidget, reason: 'the slot');
      expect(_badge, findsNothing, reason: 'draws nothing');
      expect(find.byTooltip(state.t.yourPicture), findsOneWidget);
      await unmountLevel(tester, state);
    });

    testWidgets('a badge bought while the lobby is open replaces it', (
      tester,
    ) async {
      final state = _state();
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      state.user = User.fromJson(
        _user([
          regularBadge(),
          royalBadge('ROYAL_ACE', const Duration(days: 7)),
        ]),
      );
      _notify(state);
      await tester.pump(const Duration(seconds: 1));
      final art = tester.widget<BadgeArt>(
        find.descendant(of: _badge, matching: find.byType(BadgeArt)),
      );
      expect(art.assetUrl, badgeUrl('ROYAL_ACE'));
      await unmountLevel(tester, state);
    });

    testWidgets('the one-second tick never rebuilds it or its Lottie', (
      tester,
    ) async {
      final state = _state();
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      final art = find.descendant(of: _badge, matching: find.byType(BadgeArt));
      final before = art.evaluate().single.widget;
      final badge = _badge.evaluate().single;
      final rebuilt = <Type>{};
      // Only the badge's own subtree: an animating Lottie elsewhere in the
      // lobby (the category cards' lock) rebuilds itself every frame of its
      // own loop, which is the lottie package playing, not the tick.
      debugOnRebuildDirtyWidget = (element, _) {
        var underBadge = false;
        element.visitAncestorElements((ancestor) {
          underBadge = identical(ancestor, badge);
          return !underBadge;
        });
        if (underBadge) rebuilt.add(element.widget.runtimeType);
      };
      addTearDown(() => debugOnRebuildDirtyWidget = null);
      for (var i = 0; i < 3; i++) {
        _notify(state);
        await tester.pump(const Duration(seconds: 1));
      }
      debugOnRebuildDirtyWidget = null;
      expect(identical(art.evaluate().single.widget, before), isTrue);
      expect(rebuilt.contains(BadgeArt), isFalse);
      expect(rebuilt.where((t) => t.toString().startsWith('Lottie')), isEmpty);
      await unmountLevel(tester, state);
    });

    testWidgets('takes no taps: a tap on it is a tap on the picture', (
      tester,
    ) async {
      final state = _state();
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      final guard = tester.widget<IgnorePointer>(
        find.ancestor(of: _badge, matching: find.byType(IgnorePointer)).first,
      );
      expect(guard.ignoring, isTrue);
      await unmountLevel(tester, state);
    });

    testWidgets('a screen reader hears the badge', (tester) async {
      final state = _state();
      await pumpLevelLobby(tester, state, screen: const Size(1280, 800));
      final semantics = tester.ensureSemantics();
      expect(
        tester.getSemantics(_badge).label,
        contains(
          const Strings(AppLang.english).avatarBadgeSemantics('Regular'),
        ),
      );
      semantics.dispose();
      await unmountLevel(tester, state);
    });

    for (final size in const [
      Size(592, 360),
      Size(640, 360),
      Size(891, 411),
      Size(1280, 800),
    ]) {
      for (final scale in [1.0, 1.25]) {
        testWidgets('on the picture\'s top-right, on screen and clear of the '
            'name, which keeps its box — ${size.width.toInt()}x'
            '${size.height.toInt()} x$scale, English and Hindi, both themes', (
          tester,
        ) async {
          for (final lang in const [AppLang.english, AppLang.hindi]) {
            for (final dark in [true, false]) {
              final where = '${lang.name} ${dark ? 'dark' : 'light'}';
              // The name's box with no badge, then with one.
              final bare = _state(badges: const [], lang: lang);
              await pumpLevelLobby(
                tester,
                bare,
                screen: size,
                scale: scale,
                dark: dark,
              );
              final nameBare = tester.getRect(find.text('Guest0E00B'));
              await unmountLevel(tester, bare);

              final state = _state(lang: lang);
              await pumpLevelLobby(
                tester,
                state,
                screen: size,
                scale: scale,
                dark: dark,
              );
              expect(tester.takeException(), isNull, reason: where);
              final name = tester.getRect(find.text('Guest0E00B'));
              expect(name, nameBare, reason: '$where: the name keeps its box');

              final picture = _picture(tester, _badge);
              final art = _art(tester);
              final d = picture.width;
              final centre = AvatarBadge.centreFor(d);
              // The picture grew on 30 Sep 2026 (owner: "increase Profile
              // size but don't increase size of badge"): the picture is
              // Dim.avatarD, the badge still what the smaller picture wore.
              expect(d, closeTo(Dim.avatarD(size.height), 0.01), reason: where);
              expect(d, greaterThan(Dim.avatarMarkD(size.height) + 8));
              expect(
                art.width,
                closeTo(
                  AvatarBadge.sizeFor(Dim.avatarMarkD(size.height)),
                  0.01,
                ),
                reason: '$where: the badge kept its size',
              );
              expect(
                art.center.dx - picture.left,
                closeTo(centre.dx, 0.01),
                reason: where,
              );
              expect(
                art.center.dy - picture.top,
                closeTo(centre.dy, 0.01),
                reason: where,
              );
              // The top-right quarter of the picture.
              expect(art.center.dx, greaterThan(picture.center.dx));
              expect(art.center.dy, lessThan(picture.center.dy));
              final emblem = _emblem(art);
              expect(
                (Offset.zero & size).contains(emblem.topLeft) &&
                    (Offset.zero & size).contains(emblem.bottomRight),
                isTrue,
                reason: '$where: the emblem $emblem on screen',
              );
              final overlap = emblem.intersect(name);
              expect(
                overlap.width <= 0.5 || overlap.height <= 0.5,
                isTrue,
                reason: '$where: the emblem $emblem over the name $name',
              );
              await unmountLevel(tester, state);
            }
          }
        });
      }
    }
  });

  testWidgets('the Settings drawer\'s picture wears it too', (tester) async {
    final state = _state(
      badges: [
        regularBadge(),
        royalBadge('ROYAL_KING', const Duration(days: 12)),
      ],
    );
    await pumpLevelLobby(tester, state, screen: const Size(891, 411));
    await tester.tap(find.byIcon(Icons.tune_rounded).first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    // The top bar's, under the drawer, and the drawer's own.
    expect(_badge, findsNWidgets(2));
    final drawers = [for (final e in _badge.evaluate()) find.byWidget(e.widget)]
      ..sort((a, b) => _art(tester, b).width.compareTo(_art(tester, a).width));
    final drawer = drawers.first;
    final picture = _picture(tester, drawer);
    // A quarter larger than its first 72dp (30 Sep 2026), its badge the
    // 72dp picture's still.
    expect(picture.width, 90, reason: 'the drawer\'s 90dp portrait');
    final art = _art(tester, drawer);
    expect(art.width, closeTo(AvatarBadge.sizeFor(72), 0.01));
    final centre = AvatarBadge.centreFor(90);
    expect(art.center.dx - picture.left, closeTo(centre.dx, 0.01));
    expect(art.center.dy - picture.top, closeTo(centre.dy, 0.01));
    expect(
      tester
          .widget<BadgeArt>(
            find.descendant(of: drawer, matching: find.byType(BadgeArt)),
          )
          .assetUrl,
      badgeUrl('ROYAL_KING'),
    );
    await unmountLevel(tester, state);
  });

  test('what a screen reader hears, in every language', () {
    expect(
      const Strings(AppLang.english).avatarBadgeSemantics('Regular'),
      'Regular badge',
    );
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      expect(t.ownEntry('avatarBadgeSemantics'), isNotNull, reason: lang.name);
      final said = t.avatarBadgeSemantics('Regular');
      expect(said, contains('Regular'), reason: lang.name);
      expect(said, isNot(contains('%')), reason: '${lang.name}: no rate');
      if (lang != AppLang.english) {
        expect(said, isNot('Regular badge'), reason: '${lang.name} translated');
      }
    }
  });
}
