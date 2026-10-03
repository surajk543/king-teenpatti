// The store's Cards shelf (owner, 3 Oct 2026: "Add a table cards_background
// which users can buy just like user can buy profile_pictures … add one more
// tab Cards in Store which user can buy … keep the price of all cards 5
// Hammers validaity 10 days").
//
// The ninth key, after Tables, in the lobby and at a table; the bundled Royal
// Fox first — the player's for nothing, "In use" while nothing else is
// chosen, a tap putting it back on — then the eight backs in the catalogue's
// own order, each drawing its own back; every tile saying what the back is to
// the player (In use, Owned with the time left, or the padlock and 5 hammers
// with "10 days"); a locked back asking first with the card large and its
// price named; a purchase putting it on; a hammer wallet too short — here or
// at the server — offered the Hammers shelf; one purchase at a time; a
// chip-priced back refused at a table on the spot; a poker room told its felt
// keeps the standard back; and at 640x360, text x1.25, in all five languages
// and both themes, in the lobby and at a table, every word inside its tile,
// the first row whole and the next in view. The backs are miniatures primed
// into the picture cache (card_background_fixtures.dart): nothing is fetched.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/card_back_art.dart';
import 'package:teenpatti/widgets/card_back_shelf.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/game_loader.dart';
import 'package:teenpatti/widgets/glass_components.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'card_background_fixtures.dart';
import 'script_fonts.dart';

/// Every new key, with the placeholders its text must keep.
const _keys = <String, List<String>>{
  'storeTabCards': [],
  'storeCardsTitle': [],
  'storeCardsBlurb': [],
  'cardBackDefaultHint': [],
  'cardInUse': [],
  'cardOwned': [],
  'unlockCardTitle': [],
  'unlockCardBody': ['{name}', '{price}'],
  'unlockCardRentBody': ['{name}', '{price}', '{time}'],
  'cardChipsLobbyOnly': [],
  'cardsPokerNote': [],
};

int _in({int days = 0, int hours = 0}) => DateTime.now()
    .add(Duration(days: days, hours: hours))
    .millisecondsSinceEpoch;

final _tiger = seededCard('Royal Tiger');
final _hunter = seededCard('Dragon Hunter');
final _demon = seededCard('Brutal Demon');

/// Royal Tiger chosen and owned with eight and a half days left, Dragon
/// Hunter owned with five hours, the other six locked.
Map<int, int> _owned() => {
  _tiger.id: _in(days: 8, hours: 12),
  _hunter.id: _in(hours: 5),
};

GameState _state({
  AppLang lang = AppLang.english,
  Screen screen = Screen.lobby,
  SeededCard? chosen,
  Map<int, int>? owned,
  List<CardBackground>? cards,
  int hammer = 20,
  int diamond = 9,
  int chips = 500000,
}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = screen
    ..user = User.fromJson(
      cardAccountJson(
        card: chosen,
        hammer: hammer,
        diamond: diamond,
        chips: chips,
      ),
    )
    ..cardBackgrounds = cards ?? seededCatalogue(owned: owned ?? _owned());
}

void _setScreen(WidgetTester tester, Size size, {double scale = 1.0}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// An empty screen as main.dart builds one — the blur budget and the
/// transparent Scaffold round the Navigator — and the store opened on it.
Future<void> _openStore(
  WidgetTester tester,
  GameState state,
  FeedbackSettings feedback, {
  bool dark = true,
  StoreTab tab = StoreTab.cards,
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
        theme: withScriptFallback(
          dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
        ),
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
  await _settle(tester);
}

/// A sheet or a dialog set out, every tile arrived.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
}

/// Lets a fake server's answers through, as many round trips as a purchase
/// makes.
Future<void> _answers(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Future<void> _close(
  WidgetTester tester,
  GameState state,
  FeedbackSettings feedback,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
  state.dispose();
  feedback.dispose();
}

/// The tile showing [name].
Finder _tile(String name) => find
    .ancestor(of: find.text(name), matching: find.byType(CardBackChoice))
    .first;

/// Taps the tile showing [name], scrolled into view first: a second row
/// stands below the sheet's fold, where a tap would miss it.
Future<void> _tapTile(WidgetTester tester, String name) async {
  await tester.ensureVisible(_tile(name));
  await tester.pump();
  await tester.tap(_tile(name));
}

ShelfBadge _badgeOf(WidgetTester tester, Finder tile) =>
    tester.widget<ShelfBadge>(
      find.descendant(of: tile, matching: find.byType(ShelfBadge)),
    );

/// The small print under a tile's name, or null for none.
ShelfDetail? _detailOf(WidgetTester tester, Finder tile) {
  final detail = find.descendant(of: tile, matching: find.byType(ShelfDetail));
  return detail.evaluate().isEmpty ? null : tester.widget<ShelfDetail>(detail);
}

/// The frame round a tile's card: its line's colour and weight.
Border _frameOf(WidgetTester tester, Finder tile) {
  final frame = tester.widget<AnimatedContainer>(
    find.descendant(of: tile, matching: find.byType(AnimatedContainer)),
  );
  return (frame.decoration! as BoxDecoration).border! as Border;
}

/// Whether [tile] takes a tap: its InkWell and its press agree.
bool _live(WidgetTester tester, Finder tile) {
  final presses = tester
      .widget<PressScale>(
        find.descendant(of: tile, matching: find.byType(PressScale)).first,
      )
      .enabled;
  final taps =
      tester
          .widget<InkWell>(
            find.descendant(of: tile, matching: find.byType(InkWell)).first,
          )
          .onTap !=
      null;
  expect(presses, taps);
  return taps;
}

bool _inside(Rect outer, Rect inner) =>
    outer.inflate(0.5).contains(inner.topLeft) &&
    outer.inflate(0.5).contains(inner.bottomRight);

/// A fake server for the card-back routes and the reads a purchase makes
/// after them: the account as [account] says, the catalogue as [catalogue]
/// says, each request written down in [calls] (with its body for a POST).
MockClient _server({
  required List<String> calls,
  required Map<String, dynamic> Function() account,
  required Map<String, dynamic> Function() catalogue,
  Future<http.Response> Function(http.Request request)? buy,
  Future<void>? hold,
}) => MockClient((request) async {
  final path = request.url.path;
  calls.add(
    '${request.method} $path'
    '${request.method == 'POST' ? ' ${request.body}' : ''}',
  );
  switch (path) {
    case '/api/card-backgrounds/buy':
      if (hold != null) await hold;
      if (buy != null) return buy(request);
      return http.Response(
        jsonEncode({
          'user': account(),
          'cardBackground': (catalogue()['cardBackgrounds'] as List)
              .cast<Map<String, dynamic>>()
              .firstWhere(
                (c) =>
                    c['id'] ==
                    (jsonDecode(request.body) as Map)['cardBackgroundId'],
              ),
          'charged': true,
          'spent': 5,
        }),
        200,
      );
    case '/api/card-backgrounds/use':
      return http.Response(jsonEncode({'user': account()}), 200);
    case '/api/card-backgrounds':
      return http.Response(jsonEncode(catalogue()), 200);
    case '/api/auth/me':
      return http.Response(jsonEncode({'user': account()}), 200);
    case '/api/profiles':
      return http.Response(jsonEncode({'profiles': <Object>[]}), 200);
    case '/api/table-pictures':
      return http.Response(jsonEncode({'tablePictures': <Object>[]}), 200);
    case '/api/emojis':
      return http.Response(jsonEncode({'emojis': <Object>[]}), 200);
  }
  return http.Response(jsonEncode({'error': 'not_found'}), 404);
});

void main() {
  const english = Strings(AppLang.english);

  setUpAll(loadScriptFonts);
  tearDown(forgetCardBacks);

  for (final lang in AppLang.values) {
    test('every card-back word is written in ${lang.englishName}', () {
      final t = Strings(lang);
      for (final MapEntry(key: key, value: placeholders) in _keys.entries) {
        final own = t.ownEntry(key);
        expect(own, isNotNull, reason: '${lang.code} has no "$key"');
        expect(own!.trim(), isNotEmpty, reason: '${lang.code} "$key"');
        for (final placeholder in placeholders) {
          expect(own, contains(placeholder), reason: '${lang.code} "$key"');
        }
        if (lang != AppLang.english) {
          expect(
            own,
            isNot(english.ownEntry(key)),
            reason: '${lang.code} "$key" is the English left in place',
          );
        }
      }
    });
  }

  test('the shelf stands the catalogue in its own order after the Royal Fox, '
      'the server\'s among equals', () {
    final rows = [
      for (final (i, card) in seededCards.reversed.indexed)
        CardBackground.fromJson({
          ...cardBackgroundJson(card),
          // Two backs with one place: they keep the order they came in.
          'sortOrder': card.name == 'Royal Lion' ? 30 : card.sortOrder,
          'name': '${card.name} #$i',
        }),
    ];
    expect(
      [for (final c in cardShelfOrder(rows)) c.id],
      [
        1, 2, // Brutal Demon, Demon Hell
        4, 3, // Royal Lion came before Dragon Hunter, both at 30
        5, 6, 7, 8,
      ],
    );
    expect(cardShelfOrder(const []), isEmpty);
  });

  test('the unlock question names the price in its wallet, and the term', () {
    final tiger = seededCatalogue().firstWhere((c) => c.id == _tiger.id);
    expect(
      unlockCardBody(english, tiger),
      'Royal Tiger costs 5 hammers and is yours for 10 days. '
      'Unlock it and use it now?',
    );
    CardBackground priced(String currency, int cost, {int days = 10}) =>
        CardBackground.fromJson(
          cardBackgroundJson(
            _tiger,
            currency: currency,
            cost: cost,
            durationDays: days,
          ),
        );
    expect(
      unlockCardBody(english, priced('HAMMER', 1, days: 0)),
      'Royal Tiger costs 1 hammer. Unlock it and use it now?',
    );
    expect(
      unlockCardBody(english, priced('DIAMOND', 5)),
      startsWith('Royal Tiger costs 5 diamonds and is yours for 10 days.'),
    );
    expect(
      unlockCardBody(english, priced('COIN', 150000, days: 0)),
      'Royal Tiger costs ${formatChips(150000)} chips. '
      'Unlock it and use it now?',
    );
  });

  testWidgets('the Cards key stands after Tables and opens the shelf, its '
      'title, its line and the two wallets, in the lobby and at a table', (
    tester,
  ) async {
    _setScreen(tester, const Size(891, 411));
    expect(
      StoreTab.values.indexOf(StoreTab.cards),
      StoreTab.values.indexOf(StoreTab.tables) + 1,
    );
    for (final screen in [Screen.lobby, Screen.table]) {
      final state = _state(screen: screen, chosen: _tiger);
      final feedback = FeedbackSettings();
      await _openStore(tester, state, feedback, tab: StoreTab.chips);
      final key = find.byKey(const ValueKey('store-tab-cards'));
      expect(key, findsOneWidget, reason: screen.name);
      expect(
        find.descendant(of: key, matching: find.text(english.storeTabCards)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: key, matching: find.byIcon(Icons.style_rounded)),
        findsOneWidget,
      );
      expect(find.byType(CardBackChoice), findsNothing);
      await tester.tap(key);
      await _settle(tester);
      expect(find.text(english.storeCardsTitle), findsOneWidget);
      expect(find.text(english.storeCardsBlurb), findsOneWidget);
      // Priced in the pictures' wallets, so it heads as their shelves do.
      expect(find.byType(PictureWalletBalances), findsOneWidget);
      expect(
        find.byType(CardBackChoice),
        findsNWidgets(1 + seededCards.length),
      );
      expect(tester.widget<InkWell>(key).onTap, isNull, reason: 'it is on');
      expect(tester.takeException(), isNull);
      await _close(tester, state, feedback);
    }
  });

  testWidgets('the Royal Fox leads, then the eight in the catalogue\'s order, '
      'each card drawing its own back cut to the card', (tester) async {
    _setScreen(tester, const Size(891, 411));
    await primeCardBacks(tester, seededCards);
    final state = _state(chosen: _tiger);
    final feedback = FeedbackSettings();
    await _openStore(tester, state, feedback);

    final tiles = [
      for (final e in find.byType(CardBackChoice).evaluate())
        e.widget as CardBackChoice,
    ];
    expect(tiles.first.card, isNull, reason: 'the Royal Fox first');
    expect(
      [for (final t in tiles.skip(1)) t.card!.id],
      [for (final c in seededCards) c.id],
    );
    expect(find.text(royalFoxName), findsOneWidget);
    // Each tile's card wears its own back: the Royal Fox none (the bundled
    // art), every other the row's picture and crop.
    final arts = [
      for (final e in find.byType(CardBackImage).evaluate())
        (e.widget as CardBackImage).art,
    ];
    expect(arts.first, isNull);
    expect(arts.skip(1).toList(), [for (final c in seededCards) c.art]);

    // Drawn: the middle of every card is its back's own colour — the crop
    // stretched to the card, not the dark ground round it.
    const ratio = 2.0;
    final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
    final image = (await tester.runAsync(
      () =>
          layer.toImage(const Rect.fromLTWH(0, 0, 891, 411), pixelRatio: ratio),
    ))!;
    final bytes = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    Color at(Offset p) {
      final x = (p.dx * ratio).round();
      final y = (p.dy * ratio).round();
      final i = (y * image.width + x) * 4;
      return Color.fromARGB(
        255,
        bytes.getUint8(i),
        bytes.getUint8(i + 1),
        bytes.getUint8(i + 2),
      );
    }

    final cards = find.byType(CardBackImage);
    for (final (i, card) in seededCards.indexed) {
      final rect = tester.getRect(cards.at(i + 1));
      // Only the cards wholly in view: the next row may be under the fade.
      if (rect.bottom > 300) continue;
      final shown = at(rect.center);
      expect(
        (shown.r - card.colour.r).abs() +
            (shown.g - card.colour.g).abs() +
            (shown.b - card.colour.b).abs(),
        lessThan(0.06),
        reason: '${card.name}: $shown',
      );
      // And at the card's edge, inside its corner, still the card.
      final edge = at(Offset(rect.left + 2, rect.center.dy));
      expect(
        edge.computeLuminance(),
        greaterThan(cardGround.computeLuminance() + 0.02),
        reason: '${card.name}: the dark ground shows at the edge',
      );
    }
    image.dispose();
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('every tile says what its back is to the player, in a word, a '
      'glyph and its frame', (tester) async {
    _setScreen(tester, const Size(891, 411));
    final state = _state(chosen: _tiger);
    final feedback = FeedbackSettings();
    await _openStore(tester, state, feedback, dark: false);
    final theme = Theme.of(tester.element(find.byType(CardBackChoice).first));

    // The Royal Fox: always the player's, and said what it is — no clock.
    final fox = _tile(royalFoxName);
    expect(_badgeOf(tester, fox).kind, ShelfBadgeKind.owned);
    expect(_badgeOf(tester, fox).label, english.cardOwned);
    expect(_detailOf(tester, fox)!.text, english.cardBackDefaultHint);
    expect(_detailOf(tester, fox)!.time, isFalse);
    expect(_frameOf(tester, fox).top.color, shelfOwnedLine(theme));

    // The back on the player's cards: struck gold "In use", the time left.
    final tiger = _tile('Royal Tiger');
    expect(_badgeOf(tester, tiger).kind, ShelfBadgeKind.equipped);
    expect(_badgeOf(tester, tiger).label, 'In use');
    expect(
      find.descendant(of: tiger, matching: find.byIcon(Icons.check_rounded)),
      findsOneWidget,
    );
    expect(_detailOf(tester, tiger)!.text, '9d left');
    expect(_frameOf(tester, tiger).top.color, shelfGoldOn(theme.brightness));
    expect(
      _frameOf(tester, tiger).top.width,
      greaterThan(_frameOf(tester, fox).top.width),
    );

    // Owned and waiting: "Owned", its hours left.
    final hunter = _tile('Dragon Hunter');
    expect(_badgeOf(tester, hunter).kind, ShelfBadgeKind.owned);
    expect(_badgeOf(tester, hunter).label, 'Owned');
    expect(_detailOf(tester, hunter)!.text, '5h left');

    // Locked: the padlock, the hammer and 5 — the owner's price — and the
    // term, 10 days, as the small print; the hairline round the card.
    for (final card in seededCards.where(
      (c) => c.id != _tiger.id && c.id != _hunter.id,
    )) {
      final tile = _tile(card.name);
      expect(
        _badgeOf(tester, tile).kind,
        ShelfBadgeKind.locked,
        reason: card.name,
      );
      expect(
        find.descendant(of: tile, matching: find.byType(PriceTag)),
        findsOneWidget,
      );
      for (final glyph in [Icons.lock_rounded, Icons.hardware]) {
        expect(
          find.descendant(of: tile, matching: find.byIcon(glyph)),
          findsOneWidget,
          reason: '${card.name} $glyph',
        );
      }
      expect(
        find.descendant(of: tile, matching: find.text('5')),
        findsOneWidget,
      );
      expect(_detailOf(tester, tile)!.text, '10 days', reason: card.name);
      expect(
        _frameOf(tester, tile).top.color,
        AppTheme.hairlineColour(theme.brightness),
      );
    }
    // A screen reader hears the price in its wallet's word.
    expect(
      _badgeOf(tester, _tile('Brutal Demon')).semanticsLabel,
      '${english.unlock}, ${english.priceIn('HAMMER', '5')}',
    );
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('with no back chosen the Royal Fox is the one in use', (
    tester,
  ) async {
    _setScreen(tester, const Size(891, 411));
    final state = _state();
    final feedback = FeedbackSettings();
    await _openStore(tester, state, feedback);
    final fox = _tile(royalFoxName);
    expect(_badgeOf(tester, fox).kind, ShelfBadgeKind.equipped);
    expect(_badgeOf(tester, fox).label, english.cardInUse);
    expect(_badgeOf(tester, _tile('Royal Tiger')).kind, ShelfBadgeKind.owned);
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('a locked back asks first, with the card large and its price, '
      'and Cancel buys nothing', (tester) async {
    _setScreen(tester, const Size(891, 411));
    await primeCardBacks(tester, [_demon]);
    final state = _state(chosen: _tiger);
    state.debugToken = 'tok';
    final feedback = FeedbackSettings();
    await _openStore(tester, state, feedback);
    final demon = state.cardBackgrounds.firstWhere((c) => c.id == _demon.id);

    await _tapTile(tester, 'Brutal Demon');
    await _settle(tester);
    expect(find.text(english.unlockCardTitle), findsOneWidget);
    expect(find.text(unlockCardBody(english, demon)), findsOneWidget);
    // The card itself, large, over the question.
    final big = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(CardBackImage),
    );
    expect(big, findsOneWidget);
    expect(tester.widget<CardBackImage>(big).art, _demon.art);
    expect(tester.getSize(big).height, greaterThanOrEqualTo(110));
    // And what it costs, in the wallet that pays: 5, never the 20 hammers
    // the player holds.
    final price = find.descendant(
      of: find.byKey(const ValueKey('unlock-price')),
      matching: find.byType(HammerBalance),
    );
    expect(tester.widget<HammerBalance>(price).count, 5);

    await tester.tap(find.text(english.cancel));
    await _settle(tester);
    expect(find.text(english.unlockCardTitle), findsNothing);
    expect(state.buyingCardBackground, isNull);
    expect(_badgeOf(tester, _tile('Brutal Demon')).kind, ShelfBadgeKind.locked);
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('Unlock buys the back and puts it on: 5 hammers gone, the tile '
      'In use, and the card stands still while it turns', (tester) async {
    _setScreen(tester, const Size(891, 411));
    await primeCardBacks(tester, seededCards);
    final state = _state(chosen: _tiger);
    state.debugToken = 'tok';
    final feedback = FeedbackSettings();
    await _openStore(tester, state, feedback);
    final calls = <String>[];
    var bought = false;
    final server = _server(
      calls: calls,
      account: () => cardAccountJson(
        card: bought ? _demon : _tiger,
        hammer: bought ? 15 : 20,
      ),
      catalogue: () => cardCatalogueJson(
        owned: {..._owned(), if (bought) _demon.id: _in(days: 10)},
      ),
      buy: (request) async {
        bought = true;
        return http.Response(
          jsonEncode({
            'user': cardAccountJson(card: _tiger, hammer: 15),
            'cardBackground': cardBackgroundJson(
              _demon,
              owned: true,
              expiresAt: _in(days: 10),
            ),
            'charged': true,
            'spent': 5,
          }),
          200,
        );
      },
    );
    final card = find.descendant(
      of: _tile('Brutal Demon'),
      matching: find.byType(CardBackImage),
    );
    // Where the card stands once in view, as the tap will leave it.
    await tester.ensureVisible(_tile('Brutal Demon'));
    await tester.pump();
    final before = tester.getRect(card);

    await http.runWithClient(() async {
      await _tapTile(tester, 'Brutal Demon');
      await _settle(tester);
    }, () => server);
    await tester.tap(find.text(english.unlock));
    await _answers(tester);

    expect(
      calls.first,
      'POST /api/card-backgrounds/buy {"cardBackgroundId":1}',
    );
    expect(
      calls,
      contains('POST /api/card-backgrounds/use {"cardBackgroundId":1}'),
    );
    expect(
      calls.indexOf('POST /api/card-backgrounds/use {"cardBackgroundId":1}'),
      greaterThan(0),
    );
    expect(state.user!.hammer, 15);
    expect(state.user!.activeCardBackgroundId, _demon.id);
    expect(state.buyingCardBackground, isNull);
    await tester.pump(const Duration(seconds: 1));
    final demon = _tile('Brutal Demon');
    expect(_badgeOf(tester, demon).kind, ShelfBadgeKind.equipped);
    expect(_detailOf(tester, demon)!.text, '10d left');
    expect(_badgeOf(tester, _tile('Royal Tiger')).kind, ShelfBadgeKind.owned);
    // The frame's line grew; the card did not move.
    expect(tester.getRect(card), before);
    // The header's hammers follow the wallet.
    expect(
      tester
          .widget<HammerBalance>(
            find.descendant(
              of: find.byType(PictureWalletBalances),
              matching: find.byType(HammerBalance),
            ),
          )
          .count,
      15,
    );
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('short of hammers, the Hammers shelf is offered with the card, '
      'and its key moves the store there', (tester) async {
    _setScreen(tester, const Size(891, 411));
    final state = _state(chosen: _tiger, hammer: 3);
    state.debugToken = 'tok';
    final feedback = FeedbackSettings();
    await _openStore(tester, state, feedback);

    await _tapTile(tester, 'Brutal Demon');
    await _settle(tester);
    // No question: the offer, the card it was for, its price and the wallet.
    expect(find.text(english.unlockCardTitle), findsNothing);
    expect(find.text(english.notEnoughHammersTitle), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(CardBackOnOffer),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<HammerBalance>(
            find.descendant(
              of: find.byKey(const ValueKey('unlock-price')),
              matching: find.byType(HammerBalance),
            ),
          )
          .count,
      5,
    );
    expect(
      tester
          .widget<HammerBalance>(
            find.descendant(
              of: find.byKey(const ValueKey('unlock-balance')),
              matching: find.byType(HammerBalance),
            ),
          )
          .count,
      3,
    );
    await tester.tap(find.text(english.getHammers));
    await _settle(tester);
    expect(find.text(english.storeHammersTitle), findsOneWidget);
    expect(find.byType(CardBackChoice), findsNothing);
    expect(state.buyingCardBackground, isNull);
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('a shortage only the server knows is the same offer', (
    tester,
  ) async {
    _setScreen(tester, const Size(891, 411));
    final state = _state(chosen: _tiger);
    state.debugToken = 'tok';
    final feedback = FeedbackSettings();
    await _openStore(tester, state, feedback);
    final calls = <String>[];
    final server = _server(
      calls: calls,
      // The phone said 20; the server knows of 2.
      account: () => cardAccountJson(card: _tiger, hammer: 2),
      catalogue: () => cardCatalogueJson(owned: _owned()),
      buy: (_) async => http.Response(
        jsonEncode({
          'error': 'picture_chips',
          'message': 'You need 5 hammers to unlock this card back.',
        }),
        409,
      ),
    );
    await http.runWithClient(() async {
      await _tapTile(tester, 'Brutal Demon');
      await _settle(tester);
    }, () => server);
    await tester.tap(find.text(english.unlock));
    await _answers(tester);
    expect(calls.first, startsWith('POST /api/card-backgrounds/buy'));
    expect(
      calls,
      isNot(contains(startsWith('POST /api/card-backgrounds/use'))),
    );
    expect(find.text(english.notEnoughHammersTitle), findsOneWidget);
    expect(state.user!.hammer, 2, reason: 'the wallet read again');
    expect(state.notice, isNull, reason: 'the offer says it, not a toast');
    await tester.tap(find.text(english.cancel));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('one purchase at a time: the ring on the card being bought and '
      'every tile dead until the answer', (tester) async {
    _setScreen(tester, const Size(891, 411));
    await primeCardBacks(tester, seededCards);
    final state = _state(chosen: _tiger);
    state.debugToken = 'tok';
    final feedback = FeedbackSettings();
    await _openStore(tester, state, feedback);
    final answer = Completer<void>();
    final calls = <String>[];
    var bought = false;
    final server = _server(
      calls: calls,
      account: () =>
          cardAccountJson(card: bought ? _demon : _tiger, hammer: 15),
      catalogue: () => cardCatalogueJson(
        owned: {..._owned(), if (bought) _demon.id: _in(days: 10)},
      ),
      hold: answer.future.then((_) => bought = true),
    );

    await http.runWithClient(() async {
      await _tapTile(tester, 'Brutal Demon');
      await _settle(tester);
    }, () => server);
    await tester.tap(find.text(english.unlock));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls, ['POST /api/card-backgrounds/buy {"cardBackgroundId":1}']);
    expect(state.buyingCardBackground, _demon.id);

    // The ring on the card being bought, and no other.
    expect(
      find.descendant(
        of: _tile('Brutal Demon'),
        matching: find.byType(GameLoaderRing),
      ),
      findsOneWidget,
    );
    expect(find.byType(GameLoaderRing), findsOneWidget);
    // Every tile dead: a locked one would start a second purchase, an owned
    // one would put a back on under the one being bought.
    for (final name in [
      royalFoxName,
      'Brutal Demon',
      'Demon Hell',
      'Dragon Hunter',
      'Royal Tiger',
    ]) {
      expect(_live(tester, _tile(name)), isFalse, reason: name);
    }
    // A tap meanwhile asks nothing and sends nothing.
    await tester.tap(_tile('Demon Hell'), warnIfMissed: false);
    await _settle(tester);
    expect(find.text(english.unlockCardTitle), findsNothing);
    expect(calls, hasLength(1));

    // The answer: the ring gone, the back on, every tile live again.
    answer.complete();
    await _answers(tester);
    expect(state.buyingCardBackground, isNull);
    expect(find.byType(GameLoaderRing), findsNothing);
    expect(
      _badgeOf(tester, _tile('Brutal Demon')).kind,
      ShelfBadgeKind.equipped,
    );
    for (final name in [royalFoxName, 'Demon Hell', 'Dragon Hunter']) {
      expect(_live(tester, _tile(name)), isTrue, reason: name);
    }
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('an owned back goes on with one tap, and the Royal Fox tile '
      'takes it off', (tester) async {
    _setScreen(tester, const Size(891, 411));
    await primeCardBacks(tester, seededCards);
    final state = _state(chosen: _tiger);
    state.debugToken = 'tok';
    final feedback = FeedbackSettings();
    await _openStore(tester, state, feedback);
    final calls = <String>[];
    SeededCard? wearing = _tiger;
    final server = _server(
      calls: calls,
      account: () => cardAccountJson(card: wearing),
      catalogue: () => cardCatalogueJson(owned: _owned()),
    );

    // The one already on: a tap sends nothing.
    await http.runWithClient(() async {
      await _tapTile(tester, 'Royal Tiger');
      await _answers(tester);
    }, () => server);
    expect(calls, isEmpty);

    wearing = _hunter;
    await http.runWithClient(() async {
      await _tapTile(tester, 'Dragon Hunter');
      await _answers(tester);
    }, () => server);
    expect(
      calls.first,
      'POST /api/card-backgrounds/use {"cardBackgroundId":3}',
    );
    expect(find.text(english.unlockCardTitle), findsNothing, reason: 'no ask');
    expect(
      _badgeOf(tester, _tile('Dragon Hunter')).kind,
      ShelfBadgeKind.equipped,
    );
    expect(_badgeOf(tester, _tile('Royal Tiger')).kind, ShelfBadgeKind.owned);

    calls.clear();
    wearing = null;
    await http.runWithClient(() async {
      await _tapTile(tester, royalFoxName);
      await _answers(tester);
    }, () => server);
    expect(
      calls.first,
      'POST /api/card-backgrounds/use {"cardBackgroundId":null}',
    );
    expect(state.user!.cardBackground, isNull);
    expect(_badgeOf(tester, _tile(royalFoxName)).kind, ShelfBadgeKind.equipped);
    expect(_badgeOf(tester, _tile('Dragon Hunter')).kind, ShelfBadgeKind.owned);

    // And on the Royal Fox already, its tap sends nothing.
    calls.clear();
    await http.runWithClient(() async {
      await _tapTile(tester, royalFoxName);
      await _answers(tester);
    }, () => server);
    expect(calls, isEmpty);
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('opening the Cards shelf reads the catalogue again: a back that '
      'ran out shows its price', (tester) async {
    _setScreen(tester, const Size(891, 411));
    await primeCardBacks(tester, seededCards);
    // The phone still thinks Dragon Hunter is owned; the server knows it ran
    // out an hour ago.
    final state = _state(chosen: _tiger);
    final feedback = FeedbackSettings();
    final calls = <String>[];
    final server = _server(
      calls: calls,
      account: () => cardAccountJson(card: _tiger),
      catalogue: () =>
          cardCatalogueJson(owned: {_tiger.id: _in(days: 8, hours: 12)}),
    );
    await http.runWithClient(
      () => _openStore(tester, state, feedback),
      () => server,
    );
    await _answers(tester);
    expect(calls, contains('GET /api/card-backgrounds'));
    expect(
      _badgeOf(tester, _tile('Dragon Hunter')).kind,
      ShelfBadgeKind.locked,
    );
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('at a table the shelf sells a hammer back, and refuses a '
      'chip-priced one on the spot', (tester) async {
    _setScreen(tester, const Size(891, 411));
    final cards = [
      ...seededCatalogue(owned: _owned()),
      CardBackground.fromJson({
        ...cardBackgroundJson(
          seededCard('Royal Lion'),
          currency: 'COIN',
          cost: 150000,
        ),
        'id': 99,
        'name': 'Gold Leaf',
        'sortOrder': 90,
      }),
    ];
    final state = _state(screen: Screen.table, chosen: _tiger, cards: cards);
    final feedback = FeedbackSettings();
    await _openStore(tester, state, feedback);

    await _tapTile(tester, 'Gold Leaf');
    await _settle(tester);
    expect(find.text(english.unlockCardTitle), findsNothing);
    expect(state.notice, english.cardChipsLobbyOnly);

    await _tapTile(tester, 'Brutal Demon');
    await _settle(tester);
    expect(find.text(english.unlockCardTitle), findsOneWidget);
    await tester.tap(find.text(english.cancel));
    await _settle(tester);
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('at a poker room the shelf says the felt keeps the standard '
      'back, and says it again when one is put on', (tester) async {
    _setScreen(tester, const Size(891, 411));
    await primeCardBacks(tester, seededCards);
    final state = _state(screen: Screen.table, chosen: _tiger)
      ..room = RoomState.fromJson(
        cardRoomJson(
          seats: [cardSeatJson(seatIndex: 0, userId: 'me')],
          game: 'poker',
          category: 'texas_holdem',
        ),
      );
    state.debugToken = 'tok';
    expect(state.room!.isPoker, isTrue);
    final feedback = FeedbackSettings();
    await _openStore(tester, state, feedback);
    expect(find.text(english.cardsPokerNote), findsOneWidget);
    expect(find.text(english.storeCardsBlurb), findsNothing);

    final calls = <String>[];
    final server = _server(
      calls: calls,
      account: () => cardAccountJson(card: _hunter),
      catalogue: () => cardCatalogueJson(owned: _owned()),
    );
    await http.runWithClient(() async {
      await _tapTile(tester, 'Dragon Hunter');
      await _answers(tester);
    }, () => server);
    expect(state.user!.activeCardBackgroundId, _hunter.id);
    expect(state.notice, english.cardsPokerNote);
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  // The tightest phone the game is checked on at the largest text, in every
  // language and both themes, in the lobby and at a table: every word inside
  // its tile and uncut, every badge one height and never squeezed, and the
  // first row whole with the next in view.
  for (final lang in AppLang.values) {
    testWidgets('at 640x360, text x1.25, in ${lang.englishName}, every tile '
        'holds its words, and a row and a glimpse of the next stand in the '
        'shelf', (tester) async {
      if (!haveScriptFonts()) {
        markTestSkipped('the Noto script fonts are not installed');
        return;
      }
      _setScreen(tester, const Size(640, 360), scale: 1.25);
      for (final screen in [Screen.lobby, Screen.table]) {
        for (final dark in [true, false]) {
          final why = '${lang.code} ${screen.name} ${dark ? 'dark' : 'light'}';
          // A wallet as wide as a balance gets — 99,999 Crore, four-figure
          // diamonds and hammers — so the header is as tall as it grows and
          // the shelf as short.
          final state = _state(
            lang: lang,
            screen: screen,
            chosen: _tiger,
            chips: 999990000000,
            diamond: 1250,
            hammer: 4500,
          );
          final feedback = FeedbackSettings();
          await _openStore(tester, state, feedback, dark: dark);

          final tiles = find.byType(CardBackChoice);
          expect(tiles, findsNWidgets(1 + seededCards.length), reason: why);
          final body = tester.getRect(
            find.ancestor(of: tiles.first, matching: find.byType(Scrollable)),
          );
          final heights = <double>{};
          final rects = <Rect>[];
          for (var i = 0; i < tiles.evaluate().length; i++) {
            final tile = tiles.at(i);
            final rect = tester.getRect(tile);
            rects.add(rect);
            for (final text
                in find
                    .descendant(of: tile, matching: find.byType(RichText))
                    .evaluate()) {
              final paragraph = text.renderObject! as RenderParagraph;
              final words = paragraph.text.toPlainText();
              final r = tester.getRect(
                find.byElementPredicate((e) => e == text),
              );
              expect(_inside(rect, r), isTrue, reason: '$why: "$words" leaves');
              expect(
                paragraph.didExceedMaxLines,
                isFalse,
                reason: '$why: "$words" is cut',
              );
            }
            final badge = find.descendant(
              of: tile,
              matching: find.byType(ShelfBadge),
            );
            heights.add(
              (tester.getSize(badge).height * 100).roundToDouble() / 100,
            );
            final fitted = tester.renderObject<RenderFittedBox>(
              find.descendant(of: badge, matching: find.byType(FittedBox)),
            );
            expect(
              fitted.size.width / fitted.child!.size.width,
              greaterThanOrEqualTo(0.85),
              reason: '$why: a badge squeezed',
            );
          }
          expect(heights, hasLength(1), reason: '$why: badges $heights');
          // The first row whole, inside the shelf, and the next in view.
          final top = rects.first.top;
          final row = [
            for (final r in rects)
              if ((r.top - top).abs() < 1) r,
          ];
          expect(row.length, greaterThan(1), reason: why);
          for (final r in row) {
            expect(_inside(body, r), isTrue, reason: '$why: $r not in $body');
          }
          final rowBottom = row.map((r) => r.bottom).reduce(math.max);
          final next = rects.where((r) => r.top > rowBottom - 1).toList();
          expect(next, isNotEmpty, reason: why);
          expect(
            next.first.top,
            lessThan(body.bottom - 8),
            reason: '$why: nothing of the next row shows',
          );
          // The card never under the least it is drawn at.
          expect(
            tester.widget<CardBackChoice>(tiles.first).cardHeight,
            greaterThanOrEqualTo(CardBackChoice.minCardHeight),
          );
          expect(tester.takeException(), isNull, reason: why);
          await _close(tester, state, feedback);
        }
      }
    });
  }

  test('a card stands taller where the shelf has room, never past the cap', () {
    // Sizing is measured from the words, so the arithmetic is held here: the
    // tile is the card, its frame and the words; the card the shelf's room
    // less a row's spacing and the glimpse.
    expect(CardBackChoice.widthFor(56), CardBackChoice.minWidth);
    expect(
      CardBackChoice.widthFor(160),
      (160 * 240 / 336 + 2 * Space.xl).floorToDouble(),
    );
    expect(CardBackChoice.frameOutset, 4.5);
  });
}
