// The two picture shelves' tiles (the store polish, 26 Sep 2026: "EQUIPPED …
// OWNED … LOCKED / PURCHASABLE: 🔒 Price, duration if applicable", "IN USE",
// never by colour alone).
//
// Every tile of the store's Pictures shelf, the lobby's picture picker and
// the Tables shelf carries ONE badge — a tick and "Equipped" on the picture
// being worn, "In use" on the table picture laid, "Owned" on everything the
// player can put on now, or a padlock, the wallet's glyph (hammers and
// diamonds) and the price — and the small print under its name: a rental's
// term, or the time left on one the player holds. Every badge on a shelf is
// one height; the grid keeps its columns down to its last row; a badge that
// changes kind (a picture just bought) crosses over to the new one; and at
// 640x360, text x1.25, in all five languages, every word stays inside its
// tile. A RenderFlex overflow fails a test by itself.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/avatar.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_picture_shelf.dart';

import 'script_fonts.dart';

int _in({int days = 0, int hours = 0, int minutes = 0}) => DateTime.now()
    .add(Duration(days: days, hours: hours, minutes: minutes))
    .millisecondsSinceEpoch;

ProfilePicture _picture(
  int id,
  String name, {
  String currency = PictureCurrency.coin,
  String type = 'PREMIUM',
  int cost = 0,
  int days = 0,
  int hours = 0,
  bool owned = false,
  int expiresAt = 0,
}) => ProfilePicture(
  id: id,
  name: name,
  // No address, so a tile draws the initial and nothing is fetched.
  url: '',
  assetFormat: 'SVG',
  currency: currency,
  type: type,
  cost: cost,
  durationDays: days,
  durationHours: hours,
  owned: owned,
  expiresAt: expiresAt,
);

/// Every state a picture tile can be in, with the longest price the catalogue
/// has (100 Crore) on a one-word name, and a three-word name.
List<ProfilePicture> _pictures() => [
  _picture(1, 'Bear', type: 'FREE', owned: true),
  // Worn: a rental with days left.
  _picture(
    2,
    'Lion',
    cost: 20000,
    days: 10,
    owned: true,
    expiresAt: _in(days: 6, hours: 4),
  ),
  _picture(3, 'Tiger', cost: 500000, owned: true),
  _picture(
    4,
    'Love Sheep',
    cost: 1000000,
    hours: 1,
    owned: true,
    expiresAt: _in(minutes: 42),
  ),
  _picture(5, 'Fox', cost: 25000),
  _picture(6, 'Butterfly', cost: 1000000000, days: 100),
  _picture(
    7,
    'Orange Ballerina',
    currency: PictureCurrency.hammer,
    cost: 10,
    days: 100,
  ),
  _picture(
    8,
    'Panda',
    currency: PictureCurrency.hammer,
    cost: 30,
    days: 30,
    owned: true,
    expiresAt: _in(days: 12),
  ),
  _picture(
    9,
    'Jolly King',
    currency: PictureCurrency.diamond,
    cost: 5,
    days: 100,
  ),
  _picture(
    10,
    'Waving Tiger Cub',
    currency: PictureCurrency.diamond,
    cost: 3,
    days: 100,
  ),
];

String _pic(String file) => 'https://pictures.test/$file';

TablePicture _table(
  int id,
  String name, {
  String currency = PictureCurrency.coin,
  int cost = 100000,
  int days = 7,
  bool owned = false,
  int expiresAt = 0,
}) => TablePicture(
  id: id,
  name: name,
  dayUrl: _pic('t$id-day.svg'),
  nightUrl: _pic('t$id-night.svg'),
  assetFormat: 'SVG',
  currency: currency,
  type: 'PREMIUM',
  cost: cost,
  durationDays: days,
  owned: owned,
  expiresAt: expiresAt,
);

/// The table shelf: one laid (id 1), one owned and waiting, and locked ones
/// in each wallet, the owner's longest name among them.
List<TablePicture> _tables() => [
  _table(
    1,
    'Background Pattern',
    cost: 500000,
    owned: true,
    expiresAt: _in(days: 5, hours: 3),
  ),
  _table(2, 'Welcome', cost: 150000, owned: true, expiresAt: _in(hours: 7)),
  _table(3, 'Circle Background Pattern', cost: 300000),
  _table(4, 'Thank You', cost: 3000000),
  _table(
    5,
    'Royal Purple',
    currency: PictureCurrency.hammer,
    cost: 30,
    days: 30,
  ),
  _table(
    6,
    'Sunset Marble',
    currency: PictureCurrency.diamond,
    cost: 5,
    days: 100,
  ),
];

/// A table preview's files, primed so no tile fetches anything.
void _primeTables() {
  final svg = Uint8List.fromList(
    utf8.encode(
      '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="9">'
      '<rect width="16" height="9" fill="#2a4a6a"/></svg>',
    ),
  );
  for (final t in _tables()) {
    PictureCache.prime(t.dayUrl, svg);
    PictureCache.prime(t.nightUrl, svg);
  }
}

GameState _state({
  AppLang lang = AppLang.english,
  Screen screen = Screen.lobby,
  bool tableLaid = true,
}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = screen
    ..pictures = _pictures()
    ..tablePictures = _tables()
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 20740000,
      'diamond': 9,
      'hammer': 45,
      'missile': 1,
      'activePictureId': 2,
      'tablePicture': tableLaid
          ? {
              'id': 1,
              'dayUrl': _pic('t1-day.svg'),
              'nightUrl': _pic('t1-night.svg'),
              'assetFormat': 'SVG',
              'currency': 'COIN',
              'cost': 500000,
            }
          : null,
    });
}

void _setScreen(WidgetTester tester, Size size, {double scale = 1.0}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// An empty screen as main.dart builds one — the blur budget and the
/// transparent Scaffold round the Navigator.
Future<BuildContext> _host(
  WidgetTester tester,
  GameState state,
  FeedbackSettings feedback, {
  bool dark = true,
}) async {
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
  return host;
}

/// A sheet or the store, set out, every tile arrived.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
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

/// The one tile of [type] showing [name].
Finder _tile(String name, Type type) =>
    find.ancestor(of: find.text(name), matching: find.byType(type)).first;

ShelfBadge _badgeOf(WidgetTester tester, Finder tile) =>
    tester.widget<ShelfBadge>(
      find.descendant(of: tile, matching: find.byType(ShelfBadge)),
    );

/// The small print under a tile's name, or null for none.
String? _detailOf(WidgetTester tester, Finder tile) {
  final detail = find.descendant(of: tile, matching: find.byType(ShelfDetail));
  if (detail.evaluate().isEmpty) return null;
  return tester.widget<ShelfDetail>(detail).text;
}

Finder _inBadge(Finder tile, Finder matching) => find.descendant(
  of: find.descendant(of: tile, matching: find.byType(ShelfBadge)),
  matching: matching,
);

/// Every tile's words inside its tile, every badge one height and never
/// scaled below 85% to fit, and every name within its two lines.
void _expectTilesHold(WidgetTester tester, Type type, String reason) {
  final tiles = find.byType(type);
  expect(tiles, findsWidgets, reason: reason);
  final heights = <double>{};
  for (final tile in tiles.evaluate()) {
    final box = tile.renderObject! as RenderBox;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final tileFinder = find.byElementPredicate((e) => e == tile);
    for (final text
        in find
            .descendant(of: tileFinder, matching: find.byType(RichText))
            .evaluate()) {
      final paragraph = text.renderObject! as RenderParagraph;
      final r = tester.getRect(find.byElementPredicate((e) => e == text));
      expect(
        r.left >= rect.left - 0.5 && r.right <= rect.right + 0.5,
        isTrue,
        reason:
            '$reason: "${paragraph.text.toPlainText()}" runs out of its '
            'tile ($r in $rect)',
      );
      expect(
        paragraph.didExceedMaxLines,
        isFalse,
        reason: '$reason: "${paragraph.text.toPlainText()}" is cut',
      );
    }
    final badge = find.descendant(
      of: tileFinder,
      matching: find.byType(ShelfBadge),
    );
    heights.add(tester.getSize(badge).height);
    final fitted = tester.renderObject<RenderFittedBox>(
      find.descendant(of: badge, matching: find.byType(FittedBox)),
    );
    final scale = fitted.size.width / fitted.child!.size.width;
    expect(
      scale,
      greaterThanOrEqualTo(0.85),
      reason: '$reason: a badge squeezed to $scale',
    );
  }
  expect(
    heights.reduce((a, b) => a > b ? a : b) -
        heights.reduce((a, b) => a < b ? a : b),
    lessThan(0.5),
    reason: '$reason: badges of different heights $heights',
  );
}

void main() {
  setUpAll(() async {
    await loadScriptFonts();
    _primeTables();
  });
  tearDownAll(PictureCache.clearMemory);

  test('the badge words are written in all five languages', () {
    const english = Strings(AppLang.english);
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final key in ['pictureEquipped', 'pictureOwned', 'tableInUse']) {
        final own = t.ownEntry(key);
        expect(own, isNotNull, reason: '${lang.code} has no "$key"');
        expect(own!.trim(), isNotEmpty, reason: '${lang.code} "$key"');
        if (lang != AppLang.english) {
          expect(
            own,
            isNot(english.ownEntry(key)),
            reason: '${lang.code} "$key" is the English left in place',
          );
        }
      }
    }
    expect(english.pictureEquipped, 'Equipped');
    expect(english.pictureOwned, 'Owned');
  });

  testWidgets('the Pictures shelf says what every picture is to the player', (
    tester,
  ) async {
    _setScreen(tester, const Size(891, 411));
    final state = _state();
    final feedback = FeedbackSettings();
    final host = await _host(tester, state, feedback);
    unawaited(showChipStore(host, opensOn: StoreTab.pictures));
    await _settle(tester);
    const t = Strings(AppLang.english);

    // Worn: the struck-gold badge, and the time left on the rental.
    final lion = _tile('Lion', PictureChoice);
    expect(_badgeOf(tester, lion).kind, ShelfBadgeKind.equipped);
    expect(_badgeOf(tester, lion).label, 'Equipped');
    expect(_inBadge(lion, find.byIcon(Icons.check_rounded)), findsOneWidget);
    expect(_detailOf(tester, lion), endsWith('left'));

    // Owned: free, bought for good, and rentals still running.
    for (final name in ['Bear', 'Tiger', 'Love Sheep', 'Panda']) {
      final tile = _tile(name, PictureChoice);
      expect(_badgeOf(tester, tile).kind, ShelfBadgeKind.owned, reason: name);
      expect(_badgeOf(tester, tile).label, 'Owned', reason: name);
      expect(
        _inBadge(tile, find.byIcon(Icons.check_rounded)),
        findsOneWidget,
        reason: name,
      );
    }
    expect(_detailOf(tester, _tile('Bear', PictureChoice)), isNull);
    expect(_detailOf(tester, _tile('Tiger', PictureChoice)), isNull);
    expect(_detailOf(tester, _tile('Love Sheep', PictureChoice)), '42m left');
    expect(_detailOf(tester, _tile('Panda', PictureChoice)), '12d left');

    // Locked: a padlock on every price, the wallet's glyph beside a hammer or
    // diamond price, and the term as the small print.
    for (final (name, price, wallet, term) in [
      ('Fox', formatChips(25000), null, null),
      ('Butterfly', formatChips(1000000000), null, '100 days'),
      ('Orange Ballerina', '10', Icons.hardware, '100 days'),
      ('Jolly King', '5', Icons.diamond, '100 days'),
    ]) {
      final tile = _tile(name, PictureChoice);
      expect(_badgeOf(tester, tile).kind, ShelfBadgeKind.locked, reason: name);
      expect(
        find.descendant(of: tile, matching: find.byType(PriceTag)),
        findsOneWidget,
        reason: name,
      );
      expect(_inBadge(tile, find.byIcon(Icons.lock_rounded)), findsOneWidget);
      expect(_inBadge(tile, find.text(price)), findsOneWidget, reason: name);
      for (final glyph in [Icons.hardware, Icons.diamond]) {
        expect(
          _inBadge(tile, find.byIcon(glyph)),
          glyph == wallet ? findsOneWidget : findsNothing,
          reason: '$name $glyph',
        );
      }
      expect(_detailOf(tester, tile), term, reason: name);
    }
    // A screen reader hears the price in its wallet's word.
    expect(
      _badgeOf(tester, _tile('Jolly King', PictureChoice)).semanticsLabel,
      '${t.unlock}, ${t.priceIn('DIAMOND', '5')}',
    );

    // The ring says the same in colour: gold round the worn picture, the
    // owned line round the rest the player can wear, the hairline round a
    // locked one.
    Avatar ring(String name) => tester.widget<Avatar>(
      find.descendant(
        of: _tile(name, PictureChoice),
        matching: find.byType(Avatar),
      ),
    );
    final theme = Theme.of(tester.element(lion));
    expect(ring('Lion').ring, shelfGoldOn(theme.brightness));
    expect(ring('Bear').ring, shelfOwnedLine(theme));
    expect(ring('Tiger').ring, shelfOwnedLine(theme));
    expect(ring('Fox').ring, isNull);

    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('the Tables shelf says what every table is to the player', (
    tester,
  ) async {
    _setScreen(tester, const Size(891, 411));
    final state = _state();
    final feedback = FeedbackSettings();
    final host = await _host(tester, state, feedback, dark: false);
    unawaited(showChipStore(host, opensOn: StoreTab.tables));
    await _settle(tester);

    // The Flowing chips: always the player's, and said what it is.
    final chips = _tile('Flowing chips', TablePictureChoice);
    expect(_badgeOf(tester, chips).kind, ShelfBadgeKind.owned);
    expect(_detailOf(tester, chips), 'The default background');

    final laid = _tile('Background Pattern', TablePictureChoice);
    expect(_badgeOf(tester, laid).kind, ShelfBadgeKind.equipped);
    expect(_badgeOf(tester, laid).label, 'In use');
    expect(_detailOf(tester, laid), '6d left');

    final welcome = _tile('Welcome', TablePictureChoice);
    expect(_badgeOf(tester, welcome).kind, ShelfBadgeKind.owned);
    expect(_detailOf(tester, welcome), '7h left');

    for (final (name, price, wallet, term) in [
      ('Circle Background Pattern', formatChips(300000), null, '7 days'),
      ('Royal Purple', '30', Icons.hardware, '30 days'),
      ('Sunset Marble', '5', Icons.diamond, '100 days'),
    ]) {
      final tile = _tile(name, TablePictureChoice);
      expect(_badgeOf(tester, tile).kind, ShelfBadgeKind.locked, reason: name);
      expect(_inBadge(tile, find.byIcon(Icons.lock_rounded)), findsOneWidget);
      expect(_inBadge(tile, find.text(price)), findsOneWidget, reason: name);
      if (wallet != null) {
        expect(_inBadge(tile, find.byIcon(wallet)), findsOneWidget);
      }
      expect(_detailOf(tester, tile), term, reason: name);
    }
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets(
    'with no picture laid, the Flowing chips tile is the one in use',
    (tester) async {
      _setScreen(tester, const Size(891, 411));
      final state = _state(tableLaid: false);
      final feedback = FeedbackSettings();
      final host = await _host(tester, state, feedback);
      unawaited(showChipStore(host, opensOn: StoreTab.tables));
      await _settle(tester);

      final chips = _tile('Flowing chips', TablePictureChoice);
      expect(_badgeOf(tester, chips).kind, ShelfBadgeKind.equipped);
      expect(_badgeOf(tester, chips).label, 'In use');
      expect(
        _badgeOf(tester, _tile('Background Pattern', TablePictureChoice)).kind,
        ShelfBadgeKind.owned,
      );
      expect(tester.takeException(), isNull);
      await _close(tester, state, feedback);
    },
  );

  testWidgets('the grid keeps its columns to the last row, centred', (
    tester,
  ) async {
    _setScreen(tester, const Size(891, 411));
    final state = _state();
    final feedback = FeedbackSettings();
    final host = await _host(tester, state, feedback);
    unawaited(showChipStore(host, opensOn: StoreTab.pictures));
    await _settle(tester);

    final lefts = [
      for (final e in find.byType(PictureChoice).evaluate())
        (e.renderObject! as RenderBox).localToGlobal(Offset.zero),
    ];
    final columns = {for (final o in lefts) o.dx.round()};
    final rows = {for (final o in lefts) o.dy.round()};
    expect(rows.length, greaterThan(1), reason: 'the shelf wraps');
    // Every tile stands in one of the first row's columns, the last row's
    // included; a centred Wrap set a short last row between them.
    final firstRow = {
      for (final o in lefts)
        if (o.dy.round() == rows.reduce((a, b) => a < b ? a : b)) o.dx.round(),
    };
    expect(columns, firstRow);
    // And the block of columns is centred in the shelf.
    final grid = tester.getRect(find.byType(ShelfGrid));
    final block = tester.getRect(find.byType(Wrap).last);
    expect(
      ((block.left - grid.left) - (grid.right - block.right)).abs(),
      lessThan(1.5),
    );
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  testWidgets('a tile arrives once, and a bought picture turns into Equipped', (
    tester,
  ) async {
    _setScreen(tester, const Size(891, 411));
    final state = _state();
    final feedback = FeedbackSettings();
    final host = await _host(tester, state, feedback);
    unawaited(showChipStore(host, opensOn: StoreTab.pictures));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // Each tile's own fade: the first beneath its entrance, above the fades
    // of its picture's and its badge's switchers.
    List<double> opacities() => [
      for (final e in find.byType(ShelfTileEntrance).evaluate())
        tester
            .widget<FadeTransition>(
              find
                  .descendant(
                    of: find.byElementPredicate((x) => x == e),
                    matching: find.byType(FadeTransition),
                  )
                  .first,
            )
            .opacity
            .value,
    ];
    // On their way in, a beat apart: the first has started, the seventh has
    // not.
    expect(opacities().first, greaterThan(0));
    expect(opacities()[6], 0);
    await tester.pump(const Duration(seconds: 2));
    expect(opacities().every((o) => o == 1), isTrue);

    // The player buys Fox and wears it: the catalogue is read again, and the
    // tile's badge crosses from the price to Equipped. Nothing arrives again.
    state
      ..pictures = [
        for (final p in state.pictures)
          p.id == 5 ? _picture(5, 'Fox', cost: 25000, owned: true) : p,
      ]
      ..user = User.fromJson({
        'id': 'u1',
        'provider': 'guest',
        'displayName': 'Ravi',
        'chips': 20715000,
        'activePictureId': 5,
      })
      ..markChatRead();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final fox = _tile('Fox', PictureChoice);
    // Mid-way the two badges are both on the tile, crossing.
    expect(
      find.descendant(of: fox, matching: find.byType(ShelfBadge)),
      findsNWidgets(2),
    );
    expect(opacities().every((o) => o == 1), isTrue);
    await tester.pump(const Duration(seconds: 1));
    expect(_badgeOf(tester, fox).kind, ShelfBadgeKind.equipped);
    expect(
      _badgeOf(tester, _tile('Lion', PictureChoice)).kind,
      ShelfBadgeKind.owned,
    );
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });

  for (final lang in AppLang.values) {
    testWidgets('at 640x360, text x1.25, in ${lang.englishName}, every tile '
        'keeps its words inside it', (tester) async {
      if (!haveScriptFonts()) {
        markTestSkipped('the Noto script fonts are not installed');
        return;
      }
      _setScreen(tester, const Size(640, 360), scale: 1.25);
      for (final (surface, open) in [
        (
          'store Pictures',
          (BuildContext c) => showChipStore(c, opensOn: StoreTab.pictures),
        ),
        (
          'store Tables',
          (BuildContext c) => showChipStore(c, opensOn: StoreTab.tables),
        ),
        ('picker', openPicturePicker),
      ]) {
        for (final dark in [true, false]) {
          final state = _state(lang: lang);
          final feedback = FeedbackSettings();
          final host = await _host(tester, state, feedback, dark: dark);
          unawaited(open(host));
          await _settle(tester);
          final reason = '${lang.code} $surface ${dark ? 'dark' : 'light'}';
          _expectTilesHold(
            tester,
            surface == 'store Tables' ? TablePictureChoice : PictureChoice,
            reason,
          );
          expect(tester.takeException(), isNull, reason: reason);
          await _close(tester, state, feedback);
        }
      }
    });
  }

  testWidgets('at a table the Animated shelf carries the same badges', (
    tester,
  ) async {
    _setScreen(tester, const Size(640, 360), scale: 1.25);
    final state = _state(screen: Screen.table)
      ..pictures = [
        for (final p in _pictures())
          ProfilePicture(
            id: p.id,
            name: p.name,
            url: p.url,
            assetFormat: 'LOTTIE',
            currency: p.currency,
            type: p.type,
            cost: p.cost,
            durationDays: p.durationDays,
            durationHours: p.durationHours,
            owned: p.owned,
            expiresAt: p.expiresAt,
          ),
      ];
    final feedback = FeedbackSettings();
    final host = await _host(tester, state, feedback);
    unawaited(showChipStore(host, opensOn: StoreTab.pictures));
    await _settle(tester);
    // The animated shelf holds the premium pictures alone: no free Bear.
    expect(find.text('Bear'), findsNothing);
    expect(
      _badgeOf(tester, _tile('Lion', PictureChoice)).kind,
      ShelfBadgeKind.equipped,
    );
    _expectTilesHold(tester, PictureChoice, 'at a table');
    expect(tester.takeException(), isNull);
    await _close(tester, state, feedback);
  });
}
