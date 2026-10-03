// The store's shelf navigation (owner, 27 Sep 2026: "I do NOT want the user
// to horizontally scroll the main store navigation ... The complete primary
// navigation must remain discoverable without horizontal scrolling").
//
// The shelf keys used to share the header's row with the title, the balance
// and the close key, as circles in a strip that scrolled where they did not
// fit — on a 640dp phone some shelves were a swipe away and nothing said so.
// They now stand in a row of their own under the header, every key on screen,
// wrapping into balanced rows only where the words cannot stand in one. Nine
// keys since the Cards shelf (owner, 3 Oct 2026): on a 592dp phone at the
// 1.25 text ceiling the English words keep one row by giving up the air
// beside them, never by shrinking.
//
// Laid out for real with Inter and the phone's Noto fonts for the Indic
// scripts (script_fonts.dart), at the landscape sizes the game is checked on,
// both text scales, all five languages, both themes, and in the lobby and at a
// table. A RenderFlex overflow fails a test by itself.
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/card_back_shelf.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/emoji_shelf.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_picture_shelf.dart';

import 'card_background_fixtures.dart';
import 'script_fonts.dart';

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

final _nav = _private('_StoreTabs');
final _chipCards = _private('_PackCard');

/// The shelf keys, one InkWell each, in header order.
Finder get _keys => find.descendant(of: _nav, matching: find.byType(InkWell));

/// The store's sheet: the glass panel the navigation stands in.
Finder get _sheet =>
    find.ancestor(of: _nav, matching: find.byType(PremiumGlassPanel)).first;

/// Every balance a shelf can head with.
final _balances = find.byWidgetPredicate(
  (w) =>
      w is ChipBalance ||
      w is DiamondBalance ||
      w is HammerBalance ||
      w is PictureWalletBalances ||
      w is MissileWalletBalances,
);

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
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      // A wallet as wide as a balance gets: 99,999 Crore.
      'chips': 999990000000,
      'diamond': 1250,
      'hammer': 4500,
      'missile': 320,
    });
}

/// A catalogue with the picture shelves' longest cases: rentals (a term
/// under the name), names that take two lines, and enough of them for a
/// second row — on the lobby's shelf and the table's animated one.
List<ProfilePicture> _pictures() {
  ProfilePicture pic(
    int id,
    String name, {
    String format = 'SVG',
    String currency = PictureCurrency.coin,
    String type = 'PREMIUM',
    int cost = 1000,
    int days = 30,
    bool owned = false,
  }) => ProfilePicture(
    id: id,
    name: name,
    url: '',
    assetFormat: format,
    currency: currency,
    type: type,
    cost: type == 'FREE' ? 0 : cost,
    durationDays: days,
    durationHours: 0,
    owned: owned,
    expiresAt: 0,
  );
  return [
    pic(1, 'Bear', type: 'FREE', owned: true, days: 0),
    pic(2, 'Orange Ballerina', cost: 500000000, days: 50),
    pic(3, 'Swirling Dots', currency: PictureCurrency.hammer, cost: 300),
    pic(4, 'Jolly King', currency: PictureCurrency.diamond, cost: 5),
    pic(5, 'Butterfly Flapping', cost: 25000),
    pic(6, 'Wolf', cost: 1000000, days: 7),
    for (final (i, name) in const [
      'Speech Bubble',
      'Hammer Time',
      'Missile Launch',
      'Chip Shuffle',
      'Lovestruck Cat',
      'Waving Tiger Cub',
      'Sporty Avocado',
      'Galloping Horse',
    ].indexed)
      pic(
        10 + i,
        name,
        format: 'LOTTIE',
        currency: i.isEven ? PictureCurrency.hammer : PictureCurrency.diamond,
        cost: 25,
        days: 100,
      ),
  ];
}

List<TablePicture> _tablePictures() => [
  for (final (i, name) in const [
    'Lines Background',
    'Background Pattern',
    'Welcome',
    'Thank You',
    'Circle Background Pattern',
    'Royal Sapphire',
    'Emerald Lattice',
    'Midnight Gold',
  ].indexed)
    TablePicture(
      id: i + 1,
      name: name,
      dayUrl: '',
      nightUrl: '',
      assetFormat: 'LOTTIE',
      currency: PictureCurrency.coin,
      type: 'PREMIUM',
      cost: 3000000,
      durationDays: 7,
      owned: false,
      expiresAt: 0,
    ),
];

List<EmojiItem> _emojiItems() => [
  for (final (i, name) in const [
    'Angry',
    'Dollar',
    'Crying',
    'Hi Face',
    'Clapping Hands',
    'Cowboy Hat Face',
    'Squinting Face with Tongue',
    'Face Blowing a Kiss',
    'Enraged Face',
    'Chill Face',
    'Sleeping',
    'Muscle',
  ].indexed)
    EmojiItem(
      id: i + 1,
      name: name,
      url: '',
      currency: PictureCurrency.hammer,
      type: 'PREMIUM',
      cost: 5,
      durationDays: 30,
      owned: i.isEven,
      expiresAt: i.isEven
          ? DateTime.now().add(const Duration(days: 20)).millisecondsSinceEpoch
          : 0,
    ),
];

/// The owner's six Royal badges (store_badges_test.dart).
LevelLadder _ladder() => LevelLadder.maybe({
  'levels': [
    {'level': 1, 'title': 'Newbie', 'icon': '', 'minXp': 0, 'taxBps': 2000},
  ],
  'badges': [
    for (final (code, title, days, rupees) in const [
      ('ROYAL_ACE', 'Royal Ace', 7, 499),
      ('ROYAL_KING', 'Royal King', 15, 999),
      ('ROYAL_MASTER', 'Royal Master', 30, 1799),
      ('ROYAL_EMPEROR', 'Royal Emperor', 45, 2499),
      ('ROYAL_LEGEND', 'Royal Legend', 60, 3299),
      ('ROYAL_KING_OF_KINGS', 'Royal King of Kings', 90, 4499),
    ])
      {
        'code': code,
        'title': title,
        'icon': '',
        'taxBps': 0,
        'validityDays': days,
        'isDefault': false,
        'priceInr': rupees,
        'assetUrl': '',
        'assetFormat': 'LOTTIE',
      },
  ],
  'xpSources': const <Object>[],
  'dailyCap': null,
  'windowMs': 86400000,
})!;

Future<void> _open(
  WidgetTester tester, {
  required GameState state,
  required FeedbackSettings feedback,
  required Size screen,
  double scale = 1.0,
  bool dark = true,
  StoreTab tab = StoreTab.chips,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  late BuildContext host;
  final theme = dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withScriptFallback(theme),
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
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

/// The distinct tops the keys stand at: one a row.
List<double> _rowTops(WidgetTester tester) {
  final tops = <double>[];
  for (var i = 0; i < _keys.evaluate().length; i++) {
    final top = tester.getRect(_keys.at(i)).top;
    if (!tops.any((t) => (t - top).abs() < 1)) tops.add(top);
  }
  return tops..sort();
}

bool _inside(Rect outer, Rect inner) =>
    outer.inflate(0.5).contains(inner.topLeft) &&
    outer.inflate(0.5).contains(inner.bottomRight);

/// A horizontal scroll view that is not inside a vertical one — one that
/// could only be in the header or the navigation, since the body is a
/// vertical scroll view.
List<String> _horizontalScrollersOutsideTheBody(WidgetTester tester) => [
  for (final element in find.byType(Scrollable).evaluate())
    if (axisDirectionToAxis((element.widget as Scrollable).axisDirection) ==
            Axis.horizontal &&
        !find
            .ancestor(
              of: find.byElementPredicate((e) => e == element),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Scrollable &&
                    axisDirectionToAxis(w.axisDirection) == Axis.vertical,
              ),
            )
            .evaluate()
            .isNotEmpty)
      '${element.widget}',
];

void main() {
  setUpAll(loadScriptFonts);

  const sizes = [
    Size(592, 360),
    Size(640, 360),
    Size(732, 412),
    Size(844, 390),
    Size(915, 412),
    Size(1280, 800),
  ];

  // Every shelf's key on screen, inside the sheet, clear of the balance and
  // the close key, in one row, and each one switching its shelf when tapped.
  for (final size in sizes) {
    for (final scale in const [1.0, 1.25]) {
      for (final lang in AppLang.values) {
        final name =
            '${size.width.toInt()}x${size.height.toInt()} x$scale '
            '${lang.englishName}';
        testWidgets('at $name every shelf key is on screen, inside the sheet '
            'and switches its shelf, in both themes, lobby and table', (
          tester,
        ) async {
          if (!haveScriptFonts()) {
            markTestSkipped('the Noto script fonts are not installed');
            return;
          }
          for (final screen in [Screen.lobby, Screen.table]) {
            for (final dark in [true, false]) {
              final why = '$name ${screen.name} ${dark ? 'dark' : 'light'}';
              final state = _state(screen: screen, lang: lang);
              final feedback = FeedbackSettings();
              await _open(
                tester,
                state: state,
                feedback: feedback,
                screen: size,
                scale: scale,
                dark: dark,
              );
              final t = Strings(lang);
              expect(_keys, findsNWidgets(StoreTab.values.length), reason: why);
              // The table's picture key sells the animated shelf, and says so.
              expect(
                find.descendant(
                  of: _nav,
                  matching: find.text(
                    screen == Screen.table
                        ? t.storeTabAnimated
                        : t.storeTabPictures,
                  ),
                ),
                findsOneWidget,
                reason: why,
              );
              // Nothing scrolls sideways outside the products, and the keys
              // stand in no scroll view at all.
              expect(
                _horizontalScrollersOutsideTheBody(tester),
                isEmpty,
                reason: why,
              );
              expect(
                find.ancestor(of: _nav, matching: find.byType(Scrollable)),
                findsNothing,
                reason: why,
              );
              // Every word of these phones' languages stands in one row.
              expect(_rowTops(tester), hasLength(1), reason: why);

              final sheet = tester.getRect(_sheet);
              final close = tester.getRect(
                find.byIcon(Icons.close_rounded).first,
              );
              expect(_inside(sheet, close), isTrue, reason: '$why close');
              for (var i = 0; i < StoreTab.values.length; i++) {
                final tab = StoreTab.values[i];
                final key = find.byKey(ValueKey('store-tab-${tab.name}'));
                final rect = tester.getRect(key);
                expect(
                  _inside(sheet, rect),
                  isTrue,
                  reason: '$why $tab $rect outside $sheet',
                );
                expect(rect.height, greaterThanOrEqualTo(Dim.minTouch));
                expect(rect.width, greaterThanOrEqualTo(Dim.minTouch));
                // Its word whole: never ellipsised, never past its key.
                final word = find.descendant(
                  of: key,
                  matching: find.byType(Text),
                );
                final paragraph = tester.renderObject<RenderParagraph>(word);
                expect(paragraph.didExceedMaxLines, isFalse, reason: why);
                // The key's word is set with no clip or ellipsis, so its box
                // is always the key's and says nothing of the words: the
                // word's own width is what must fit (review, 27 Sep 2026).
                expect(
                  paragraph.getMaxIntrinsicWidth(double.infinity),
                  lessThanOrEqualTo(paragraph.size.width + 0.01),
                  reason: '$why $tab: its word is wider than its key',
                );
                expect(
                  _inside(rect, tester.getRect(word)),
                  isTrue,
                  reason: '$why $tab: its word leaves the key',
                );
                expect(
                  rect.overlaps(close),
                  isFalse,
                  reason: '$why $tab under the close key',
                );
                // Hittable: the tap lands on this key and switches the shelf.
                if (tester.widget<InkWell>(key).onTap != null) {
                  await tester.tap(key);
                  await tester.pump();
                  await tester.pump(const Duration(milliseconds: 600));
                }
                expect(
                  tester.widget<InkWell>(key).onTap,
                  isNull,
                  reason: '$why $tab did not come on',
                );
                // The balance, where the shelf has one, is never on a key.
                final keysNow = [
                  for (var k = 0; k < _keys.evaluate().length; k++)
                    tester.getRect(_keys.at(k)),
                ];
                for (var b = 0; b < _balances.evaluate().length; b++) {
                  final balance = tester.getRect(_balances.at(b));
                  expect(_inside(sheet, balance), isTrue, reason: why);
                  for (final k in keysNow) {
                    expect(
                      balance.overlaps(k),
                      isFalse,
                      reason: '$why $tab: the balance $balance meets $k',
                    );
                  }
                }
                expect(tester.takeException(), isNull, reason: '$why $tab');
              }
              await _unmount(tester);
              state.dispose();
              feedback.dispose();
            }
          }
        });
      }
    }
  }

  // Wide enough, one row — the navigation wraps only when it must.
  for (final lang in AppLang.values) {
    testWidgets('at 891x411 x1.0 in ${lang.englishName} the keys stand in one '
        'row of equal keys', (tester) async {
      if (!haveScriptFonts()) {
        markTestSkipped('the Noto script fonts are not installed');
        return;
      }
      final state = _state(lang: lang);
      final feedback = FeedbackSettings();
      await _open(
        tester,
        state: state,
        feedback: feedback,
        screen: const Size(891, 411),
      );
      expect(_rowTops(tester), hasLength(1));
      final widths = {
        for (var i = 0; i < _keys.evaluate().length; i++)
          tester.getSize(_keys.at(i)).width.round(),
      };
      expect(widths, hasLength(1), reason: 'keys of different widths');
      await _unmount(tester);
      state.dispose();
      feedback.dispose();
    });
  }

  // Too narrow for the nine words in one row: balanced rows, never a strip
  // that scrolls. The app is landscape-only, but the rule is the width's, not
  // the phone's; a narrow window proves it.
  testWidgets('where the words cannot stand in one row they wrap into '
      'balanced rows, every key on screen', (tester) async {
    final state = _state();
    final feedback = FeedbackSettings();
    await _open(
      tester,
      state: state,
      feedback: feedback,
      screen: const Size(480, 720),
      scale: 1.25,
    );
    final tops = _rowTops(tester);
    expect(tops, hasLength(2));
    final perRow = [
      for (final top in tops)
        [
          for (var i = 0; i < _keys.evaluate().length; i++)
            if ((tester.getRect(_keys.at(i)).top - top).abs() < 1) i,
        ].length,
    ];
    // Nine keys: the first row one key longer.
    expect(perRow, [5, 4]);
    final sheet = tester.getRect(_sheet);
    for (var i = 0; i < _keys.evaluate().length; i++) {
      expect(_inside(sheet, tester.getRect(_keys.at(i))), isTrue);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: _keys.at(i), matching: find.byType(Text)),
      );
      expect(
        paragraph.getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(paragraph.size.width + 0.01),
      );
    }
    expect(_horizontalScrollersOutsideTheBody(tester), isEmpty);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
    state.dispose();
    feedback.dispose();
  });

  // Nine English words at the 1.25 text ceiling on a 592dp phone stood 31dp
  // too wide for one row at the tight gap in the lobby, and 40dp at a table
  // ("Animated" for "Pictures"), once Cards joined them (3 Oct 2026). The
  // keys give up the air beside their words — never the words — before a
  // second row is let in, and only where they must: on a 640dp phone the
  // same words keep their usual air.
  testWidgets('on a 592dp phone at x1.25 the nine English keys keep one row by '
      'giving up the air beside their words, and only there', (tester) async {
    if (!haveScriptFonts()) {
      markTestSkipped('the Noto script fonts are not installed');
      return;
    }
    // Each side of a word: the rim, and the usual inset or the snug one.
    const rim = 1.5;
    const usualAir = rim + Space.xs;
    const snugAir = rim + Space.xxs;
    for (final screen in [Screen.lobby, Screen.table]) {
      for (final (size, snug) in const [
        (Size(592, 360), true),
        (Size(640, 360), false),
      ]) {
        final why = '${size.width.toInt()} ${screen.name}';
        final state = _state(screen: screen);
        final feedback = FeedbackSettings();
        await _open(
          tester,
          state: state,
          feedback: feedback,
          screen: size,
          scale: 1.25,
        );
        expect(_rowTops(tester), hasLength(1), reason: why);
        final keys = [
          for (var i = 0; i < _keys.evaluate().length; i++)
            tester.getRect(_keys.at(i)),
        ];
        expect(keys, hasLength(StoreTab.values.length), reason: why);
        // The air beside each key's word, and the widest word's.
        final air = <double>[];
        var widest = 0.0;
        var widestAir = 0.0;
        for (var i = 0; i < keys.length; i++) {
          final word = tester
              .renderObject<RenderParagraph>(
                find.descendant(of: _keys.at(i), matching: find.byType(Text)),
              )
              .getMaxIntrinsicWidth(double.infinity);
          final side = (keys[i].width - word) / 2;
          air.add(side);
          if (word > widest) {
            widest = word;
            widestAir = side;
          }
        }
        final gaps = {
          for (var i = 1; i < keys.length; i++)
            (keys[i].left - keys[i - 1].right).round(),
        };
        expect(gaps, hasLength(1), reason: '$why gaps $gaps');
        if (snug) {
          expect(air.reduce(math.min), greaterThanOrEqualTo(snugAir - 0.01));
          expect(widestAir, lessThan(usualAir), reason: why);
          expect(gaps.single, lessThanOrEqualTo(Space.xs), reason: why);
        } else {
          expect(air.reduce(math.min), greaterThanOrEqualTo(usualAir - 0.01));
        }
        expect(tester.takeException(), isNull, reason: why);
        await _unmount(tester);
        state.dispose();
        feedback.dispose();
      }
    }
  });

  // The products still have room: a whole row of cards and a glimpse of the
  // next, with the figures, badges and price keys whole, and as many columns
  // as the least card width allows.
  for (final (size, scale, columns) in const [
    (Size(592, 360), 1.0, 3),
    (Size(592, 360), 1.25, 3),
    (Size(640, 360), 1.0, 3),
    (Size(640, 360), 1.25, 3),
    (Size(732, 412), 1.0, 4),
    (Size(844, 390), 1.25, 4),
    (Size(891, 411), 1.0, 4),
    (Size(915, 412), 1.25, 4),
    (Size(1280, 800), 1.0, 5),
  ]) {
    final name = '${size.width.toInt()}x${size.height.toInt()} x$scale';
    for (final lang in const [AppLang.english, AppLang.hindi]) {
      testWidgets('at $name in ${lang.englishName} the Chips shelf shows a '
          'whole row of $columns cards and a glimpse of the next, every word '
          'whole', (tester) async {
        if (!haveScriptFonts()) {
          markTestSkipped('the Noto script fonts are not installed');
          return;
        }
        final state = _state(lang: lang);
        final feedback = FeedbackSettings();
        await _open(
          tester,
          state: state,
          feedback: feedback,
          screen: size,
          scale: scale,
        );
        final body = tester.getRect(
          find.ancestor(
            of: _chipCards.first,
            matching: find.byType(Scrollable),
          ),
        );
        final cards = [
          for (var i = 0; i < _chipCards.evaluate().length; i++)
            tester.getRect(_chipCards.at(i)),
        ];
        final firstRow = cards
            .where((c) => (c.top - cards.first.top).abs() < 1)
            .toList();
        expect(firstRow, hasLength(columns));
        for (final card in firstRow) {
          expect(_inside(body, card), isTrue, reason: '$card not in $body');
        }
        // The next row begins inside the body.
        final next = cards.firstWhere((c) => c.top > cards.first.bottom);
        expect(next.top, lessThan(body.bottom - 8));
        // Every word on a card is inside it and uncut; a figure stays a
        // figure, never shrunk into small print.
        for (var i = 0; i < firstRow.length; i++) {
          final card = _chipCards.at(i);
          final rect = tester.getRect(card);
          final texts = find.descendant(of: card, matching: find.byType(Text));
          for (var k = 0; k < texts.evaluate().length; k++) {
            final text = texts.at(k);
            expect(_inside(rect, tester.getRect(text)), isTrue);
            expect(
              tester.renderObject<RenderParagraph>(text).didExceedMaxLines,
              isFalse,
            );
          }
          final figure = find.descendant(
            of: card,
            matching: find.text(formatChips(chipPacks[i].chips)),
          );
          expect(
            tester.getRect(figure).height,
            greaterThanOrEqualTo(22),
            reason: '${chipPacks[i].chips} is set too small',
          );
          // The price key: a comfortable target, inside its card.
          final price = tester.getRect(
            find.descendant(of: card, matching: _private('_PriceButton')),
          );
          expect(price.height, greaterThanOrEqualTo(29.5));
          expect(_inside(rect, price), isTrue);
        }
        expect(tester.takeException(), isNull);
        await _unmount(tester);
        state.dispose();
        feedback.dispose();
      });
    }
  }

  // Every shelf, not the Chips shelf alone: the picture shelves stand the
  // worn picture's head over their tiles, and on a 360dp phone at the 1.25
  // text scale their first row of faces was cut through its names with
  // nothing of the next showing (review, 27 Sep 2026). A whole first row —
  // every word of it — and a glimpse of the next, on every shelf, in the
  // lobby and at a table, in all five languages.
  final tileOf = <StoreTab, Finder>{
    StoreTab.chips: _private('_StoreProductCard'),
    StoreTab.diamonds: _private('_StoreProductCard'),
    StoreTab.hammers: _private('_StoreProductCard'),
    StoreTab.missiles: _private('_StoreProductCard'),
    StoreTab.pictures: find.byType(PictureChoice),
    StoreTab.tables: find.byType(TablePictureChoice),
    StoreTab.cards: find.byType(CardBackChoice),
    StoreTab.emojis: find.byType(EmojiChoice),
    StoreTab.badges: _private('_BadgeCard'),
  };
  for (final (size, scale) in const [
    (Size(592, 360), 1.0),
    (Size(592, 360), 1.25),
    (Size(640, 360), 1.0),
    (Size(640, 360), 1.25),
    (Size(732, 412), 1.25),
    (Size(844, 390), 1.25),
    (Size(915, 412), 1.25),
    (Size(1280, 800), 1.25),
  ]) {
    final name = '${size.width.toInt()}x${size.height.toInt()} x$scale';
    for (final lang in AppLang.values) {
      testWidgets('at $name in ${lang.englishName} every shelf shows a whole '
          'row and a glimpse of the next, lobby and table', (tester) async {
        if (!haveScriptFonts()) {
          markTestSkipped('the Noto script fonts are not installed');
          return;
        }
        for (final screen in [Screen.lobby, Screen.table]) {
          for (final tab in StoreTab.values) {
            final why = '$name ${lang.englishName} ${screen.name} ${tab.name}';
            final state = _state(screen: screen, lang: lang)
              ..pictures = _pictures()
              ..tablePictures = _tablePictures()
              // The eight seeded backs: one owned with time left, the rest
              // locked with their term, every name the owner gave them.
              ..cardBackgrounds = seededCatalogue(
                owned: {
                  seededCard('Royal Tiger').id: DateTime.now()
                      .add(const Duration(days: 9))
                      .millisecondsSinceEpoch,
                },
              )
              ..emojis = _emojiItems()
              ..levelLadder = _ladder();
            final feedback = FeedbackSettings();
            await _open(
              tester,
              state: state,
              feedback: feedback,
              screen: size,
              scale: scale,
              tab: tab,
            );
            final tiles = tileOf[tab]!;
            final body = tester.getRect(
              find.ancestor(of: tiles.first, matching: find.byType(Scrollable)),
            );
            final rects = [
              for (var i = 0; i < tiles.evaluate().length; i++)
                tester.getRect(tiles.at(i)),
            ];
            final top = rects.first.top;
            final firstRow = [
              for (var i = 0; i < rects.length; i++)
                if ((rects[i].top - top).abs() < 1) i,
            ];
            final rowBottom = [
              for (final i in firstRow) rects[i].bottom,
            ].reduce(math.max);
            for (final i in firstRow) {
              final tile = tiles.at(i);
              expect(
                _inside(body, rects[i]),
                isTrue,
                reason: '$why ${rects[i]} not in $body',
              );
              final texts = find.descendant(
                of: tile,
                matching: find.byType(Text),
              );
              for (var k = 0; k < texts.evaluate().length; k++) {
                expect(
                  _inside(body, tester.getRect(texts.at(k))),
                  isTrue,
                  reason: '$why: a word of the first row below the fold',
                );
              }
            }
            // The next row begins inside the body.
            final next = rects.where((r) => r.top > rowBottom - 1);
            if (next.isNotEmpty) {
              expect(
                next.first.top,
                lessThan(body.bottom - 8),
                reason: '$why: nothing of the next row shows',
              );
            }
            expect(tester.takeException(), isNull, reason: why);
            await _unmount(tester);
            state.dispose();
            feedback.dispose();
          }
        }
      });
    }
  }

  testWidgets('the close key closes the store at 592x360 x1.25', (
    tester,
  ) async {
    final state = _state();
    final feedback = FeedbackSettings();
    await _open(
      tester,
      state: state,
      feedback: feedback,
      screen: const Size(592, 360),
      scale: 1.25,
    );
    expect(_nav, findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded).first);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(_nav, findsNothing);
    await _unmount(tester);
    state.dispose();
    feedback.dispose();
  });

  // Every key's word reads on its own face, the key that is on included: by
  // day its gold word stood on the gold wash laid straight over the grey
  // sheet, the hardest word on the row at about 2.5:1 (review, 27 Sep 2026).
  // Sampled from the rendered screen at three pixels a dp, so a stroke's
  // core is its ink, against the face just above the word.
  for (final dark in [true, false]) {
    testWidgets('every key\'s word reads at 4.5:1 or more on its face, '
        '${dark ? 'by night' : 'by day'}, on and off', (tester) async {
      final state = _state();
      final feedback = FeedbackSettings();
      await _open(
        tester,
        state: state,
        feedback: feedback,
        screen: const Size(640, 360),
        dark: dark,
      );
      const ratio = 3.0;
      final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
      final image = (await tester.runAsync(
        () => layer.toImage(
          const Rect.fromLTWH(0, 0, 640, 360),
          pixelRatio: ratio,
        ),
      ))!;
      final bytes = (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      Color at(int x, int y) {
        final i = (y * image.width + x) * 4;
        return Color.fromARGB(
          255,
          bytes.getUint8(i),
          bytes.getUint8(i + 1),
          bytes.getUint8(i + 2),
        );
      }

      double contrast(Color a, Color b) {
        final la = a.computeLuminance();
        final lb = b.computeLuminance();
        return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
      }

      for (final tab in StoreTab.values) {
        final word = find.descendant(
          of: find.byKey(ValueKey('store-tab-${tab.name}')),
          matching: find.byType(Text),
        );
        final rect = tester.getRect(word);
        final left = (rect.left * ratio).ceil();
        final right = (rect.right * ratio).floor();
        final top = (rect.top * ratio).ceil();
        final bottom = (rect.bottom * ratio).floor();
        // The face: the commonest colour of the line box's top row, above
        // the capitals.
        final counts = <int, int>{};
        final colours = <int, Color>{};
        for (var x = left; x < right; x++) {
          final c = at(x, top);
          final key = c.toARGB32() & 0xFCFCFC;
          counts[key] = (counts[key] ?? 0) + 1;
          colours[key] = c;
        }
        final face =
            colours[counts.entries
                .reduce((a, b) => a.value >= b.value ? a : b)
                .key]!;
        var best = 1.0;
        for (var y = top; y < bottom; y++) {
          for (var x = left; x < right; x++) {
            best = math.max(best, contrast(at(x, y), face));
          }
        }
        expect(
          best,
          greaterThanOrEqualTo(4.5),
          reason:
              '${dark ? 'night' : 'day'} ${tab.name}: '
              '${best.toStringAsFixed(2)}:1 on $face',
        );
      }
      image.dispose();
      await _unmount(tester);
      state.dispose();
      feedback.dispose();
    });
  }

  testWidgets('the key that is on is lit in gold, full size, and the others '
      'drawn down; the change takes 200-250ms', (tester) async {
    final state = _state();
    final feedback = FeedbackSettings();
    await _open(
      tester,
      state: state,
      feedback: feedback,
      screen: const Size(640, 360),
    );
    AnimatedScale face(StoreTab tab) => tester.widget<AnimatedScale>(
      find.descendant(
        of: find.byKey(ValueKey('store-tab-${tab.name}')),
        matching: find.byType(AnimatedScale),
      ),
    );
    AnimatedContainer box(StoreTab tab) => tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byKey(ValueKey('store-tab-${tab.name}')),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(face(StoreTab.chips).scale, 1);
    expect(face(StoreTab.diamonds).scale, lessThan(1));
    final on = box(StoreTab.chips).decoration! as BoxDecoration;
    final off = box(StoreTab.diamonds).decoration! as BoxDecoration;
    // A glow round the one that is on, none round the others — not even a
    // transparent one, which would still be painted blurred.
    expect(on.boxShadow!.single.color.a, greaterThan(0));
    expect(off.boxShadow, isEmpty);
    // A stronger rim.
    expect(
      (on.border! as Border).top.color.a,
      greaterThan((off.border! as Border).top.color.a),
    );
    final ms = box(StoreTab.chips).duration.inMilliseconds;
    expect(ms, inInclusiveRange(200, 250));
    expect(face(StoreTab.chips).duration.inMilliseconds, ms);
    await _unmount(tester);
    state.dispose();
    feedback.dispose();
  });
}
