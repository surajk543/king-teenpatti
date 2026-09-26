// The store's Emojis shelf (owner, 26 Sep 2026: "user can buy emoji which
// will be animation, just like we have added the feature of profile picture
// … this emoji can buy from store also").
//
// Every tile says what the emoji is to the player — Owned, or the padlock
// and the price — with the emoji playing in its well and its term under its
// name, exactly as the picture shelves' tiles do. A locked one asks first,
// with the emoji large and its price in its wallet's word; a chip-priced one
// tapped at a table is refused on the spot; a short hammer or diamond wallet
// is offered that wallet's shelf; the shelf is on sale in the lobby and at a
// table; and at 640x360, text x1.25, in all five languages, in the lobby and
// at a table, every word stays inside its tile. The Lotties are tiny inline
// files primed into the picture cache: nothing is fetched.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/emoji_art.dart';
import 'package:teenpatti/widgets/emoji_shelf.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

/// A Lottie as small as one can be: a spinning disc, one layer.
final Uint8List _lottie = Uint8List.fromList(
  utf8.encode(
    '{"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"e","ddd":0,'
    '"assets":[],"layers":[{"ddd":0,"ind":1,"ty":4,"nm":"d","sr":1,'
    '"ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[50,50,0]},'
    '"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},"ao":0,'
    '"shapes":[{"ty":"gr","nm":"g","it":[{"ty":"el","nm":"c",'
    '"p":{"a":0,"k":[0,0]},"s":{"a":0,"k":[60,60]}},{"ty":"fl","nm":"f",'
    '"c":{"a":0,"k":[1,0.8,0,1]},"o":{"a":0,"k":100}},{"ty":"tr",'
    '"p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},'
    '"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}],"ip":0,"op":30,"st":0,"bm":0}]}',
  ),
);

String _url(int id) => 'https://cdn.test/emojis/$id.json';

int _in({int days = 0, int hours = 0}) => DateTime.now()
    .add(Duration(days: days, hours: hours))
    .millisecondsSinceEpoch;

EmojiItem _emoji(
  int id,
  String name, {
  String currency = PictureCurrency.coin,
  String type = 'PREMIUM',
  int cost = 0,
  int days = 0,
  bool owned = false,
  int expiresAt = 0,
}) => EmojiItem(
  id: id,
  name: name,
  url: _url(id),
  currency: currency,
  type: type,
  cost: cost,
  durationDays: days,
  owned: owned,
  expiresAt: expiresAt,
);

/// Every state a tile can be in, the dearest chip price among them.
List<EmojiItem> _emojis() => [
  _emoji(1, 'Wave', type: 'FREE', owned: true),
  _emoji(
    2,
    'Laughing',
    currency: PictureCurrency.diamond,
    cost: 5,
    days: 10,
    owned: true,
    expiresAt: _in(days: 6, hours: 3),
  ),
  _emoji(3, 'Heart Eyes', cost: 1000000000, days: 100),
  _emoji(4, 'Party Popper', currency: PictureCurrency.hammer, cost: 30),
  _emoji(
    5,
    'Crying With Laughter',
    currency: PictureCurrency.diamond,
    cost: 5,
    days: 30,
  ),
  _emoji(6, 'Thumbs Up', cost: 50000),
];

GameState _state({
  AppLang lang = AppLang.english,
  Screen screen = Screen.lobby,
  int hammers = 45,
  int diamonds = 9,
  List<EmojiItem>? emojis,
}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = screen
    ..emojis = emojis ?? _emojis()
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 20740000,
      'diamond': diamonds,
      'hammer': hammers,
      'missile': 1,
    });
}

void _setScreen(WidgetTester tester, Size size, {double scale = 1.0}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

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

Future<(GameState, FeedbackSettings)> _openEmojis(
  WidgetTester tester, {
  Size size = const Size(891, 411),
  double scale = 1.0,
  AppLang lang = AppLang.english,
  Screen screen = Screen.lobby,
  int hammers = 45,
  List<EmojiItem>? emojis,
  bool dark = true,
}) async {
  _setScreen(tester, size, scale: scale);
  final state = _state(
    lang: lang,
    screen: screen,
    hammers: hammers,
    emojis: emojis,
  );
  final feedback = FeedbackSettings();
  final host = await _host(tester, state, feedback, dark: dark);
  unawaited(showChipStore(host, opensOn: StoreTab.emojis));
  await _settle(tester);
  return (state, feedback);
}

/// The tile showing [name].
Finder _tile(String name) => find
    .ancestor(of: find.text(name), matching: find.byType(EmojiChoice))
    .first;

ShelfBadge _badgeOf(WidgetTester tester, Finder tile) =>
    tester.widget<ShelfBadge>(
      find.descendant(of: tile, matching: find.byType(ShelfBadge)),
    );

String? _detailOf(WidgetTester tester, Finder tile) {
  final detail = find.descendant(of: tile, matching: find.byType(ShelfDetail));
  if (detail.evaluate().isEmpty) return null;
  return tester.widget<ShelfDetail>(detail).text;
}

void main() {
  setUpAll(() async {
    await loadScriptFonts();
    for (final e in _emojis()) {
      PictureCache.prime(_url(e.id), _lottie);
    }
  });
  tearDownAll(PictureCache.clearMemory);

  testWidgets('every tile says what the emoji is to the player, and plays', (
    tester,
  ) async {
    final (state, feedback) = await _openEmojis(tester);
    const t = Strings(AppLang.english);
    expect(tester.takeException(), isNull);

    // The shelf's own head: its title, and the pictures' two wallets.
    expect(find.text(t.storeEmojisTitle), findsWidgets);
    expect(find.text(t.storeEmojisBlurb), findsOneWidget);
    expect(find.byType(PictureWalletBalances), findsOneWidget);

    // Owned: free, and a rental still running with its time left.
    for (final name in ['Wave', 'Laughing']) {
      final tile = _tile(name);
      expect(_badgeOf(tester, tile).kind, ShelfBadgeKind.owned, reason: name);
      expect(_badgeOf(tester, tile).label, t.pictureOwned, reason: name);
    }
    expect(_detailOf(tester, _tile('Wave')), isNull);
    expect(_detailOf(tester, _tile('Laughing')), endsWith('left'));

    // Locked: the padlock and the price, in each wallet, and the term.
    for (final (name, cost) in [
      ('Heart Eyes', formatChips(1000000000)),
      ('Party Popper', '30'),
      ('Crying With Laughter', '5'),
      ('Thumbs Up', formatChips(50000)),
    ]) {
      final tile = _tile(name);
      expect(_badgeOf(tester, tile).kind, ShelfBadgeKind.locked, reason: name);
      expect(_badgeOf(tester, tile).label, cost, reason: name);
      expect(
        find.descendant(of: tile, matching: find.byIcon(Icons.lock_rounded)),
        findsOneWidget,
        reason: name,
      );
    }
    expect(_detailOf(tester, _tile('Heart Eyes')), t.rentalTerm(100, 0));
    expect(_detailOf(tester, _tile('Party Popper')), isNull);
    expect(
      find.descendant(
        of: _tile('Party Popper'),
        matching: find.byIcon(Icons.hardware),
      ),
      findsOneWidget,
    );

    // Each one plays, from the cache.
    for (final e in _emojis()) {
      final tile = _tile(e.name);
      final art = find.descendant(of: tile, matching: find.byType(EmojiArt));
      expect(art, findsOneWidget, reason: e.name);
      final lottie = find.descendant(of: art, matching: find.byType(Lottie));
      expect(lottie, findsOneWidget, reason: e.name);
      expect(tester.widget<Lottie>(lottie).animate, isTrue, reason: e.name);
    }

    // In the order the other shelves keep: free, chips, hammers, diamonds,
    // cheapest first.
    final order = [
      for (final e in find.byType(EmojiChoice).evaluate())
        (e.widget as EmojiChoice).emoji.name,
    ];
    expect(order, [
      'Wave',
      'Thumbs Up',
      'Heart Eyes',
      'Party Popper',
      'Laughing',
      'Crying With Laughter',
    ]);

    await _close(tester, state, feedback);
  });

  testWidgets('a locked emoji asks first, with the emoji large and its price', (
    tester,
  ) async {
    final (state, feedback) = await _openEmojis(tester);
    const t = Strings(AppLang.english);
    final crying = state.emojis.firstWhere((e) => e.id == 5);

    await tester.tap(_tile('Crying With Laughter'));
    await _settle(tester);

    expect(find.text(t.unlockEmojiTitle), findsOneWidget);
    expect(find.text(unlockEmojiBody(t, crying)), findsOneWidget);
    expect(
      unlockEmojiBody(t, crying),
      'Crying With Laughter costs 5 diamonds and is yours for 30 days. '
      'Unlock it now?',
    );
    // The emoji itself, large and playing, over the question.
    final big = find.byWidgetPredicate(
      (w) => w is EmojiArt && w.size >= 80 && w.url == _url(5),
    );
    expect(big, findsOneWidget);
    // And what the player holds of the wallet that pays.
    expect(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(DiamondBalance),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text(t.cancel));
    await _settle(tester);
    expect(find.text(t.unlockEmojiTitle), findsNothing);
    expect(state.buyingEmoji, isNull);
    expect(tester.takeException(), isNull);

    await _close(tester, state, feedback);
  });

  testWidgets('a chip-priced emoji at a table says lobby only and asks '
      'nothing; one bought with hammers still asks', (tester) async {
    final (state, feedback) = await _openEmojis(tester, screen: Screen.table);
    const t = Strings(AppLang.english);

    // The shelf is on sale at a table.
    expect(find.byType(EmojiChoice), findsNWidgets(_emojis().length));

    await tester.tap(_tile('Thumbs Up'));
    await _settle(tester);
    expect(find.text(t.unlockEmojiTitle), findsNothing);
    expect(state.notice, t.emojiChipsLobbyOnly);

    await tester.tap(_tile('Party Popper'));
    await _settle(tester);
    expect(find.text(t.unlockEmojiTitle), findsOneWidget);
    expect(
      find.text('Party Popper costs 30 hammers. Unlock it now?'),
      findsOneWidget,
    );
    await tester.tap(find.text(t.cancel));
    await _settle(tester);

    await _close(tester, state, feedback);
  });

  testWidgets('a short hammer wallet is offered the Hammers shelf, in place', (
    tester,
  ) async {
    final (state, feedback) = await _openEmojis(tester, hammers: 5);
    const t = Strings(AppLang.english);

    await tester.tap(_tile('Party Popper'));
    await _settle(tester);
    expect(find.text(t.unlockEmojiTitle), findsNothing);
    expect(find.text(t.notEnoughHammersTitle), findsOneWidget);
    expect(
      find.text(t.notEnoughHammersBody('Party Popper', 30)),
      findsOneWidget,
    );
    // The emoji they were after, large.
    expect(
      find.byWidgetPredicate(
        (w) => w is EmojiArt && w.size >= 80 && w.url == _url(4),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text(t.getHammers));
    await _settle(tester);
    // The same store, moved to its Hammers shelf.
    expect(find.text(t.storeHammersTitle), findsOneWidget);
    expect(find.byType(EmojiChoice), findsNothing);

    await _close(tester, state, feedback);
  });

  testWidgets('an owned emoji says where it is sent from', (tester) async {
    final (state, feedback) = await _openEmojis(tester);
    await tester.tap(_tile('Wave'));
    await _settle(tester);
    expect(state.notice, state.t.emojiOwnedNote);
    expect(find.byType(Dialog), findsNothing);
    await _close(tester, state, feedback);
  });

  testWidgets('an empty catalogue says so', (tester) async {
    final (state, feedback) = await _openEmojis(tester, emojis: const []);
    expect(find.text(state.t.emojiShelfEmpty), findsOneWidget);
    expect(find.byType(EmojiChoice), findsNothing);
    await _close(tester, state, feedback);
  });

  testWidgets('the Emojis key is in the strip, and opens its shelf', (
    tester,
  ) async {
    _setScreen(tester, const Size(1280, 800));
    final state = _state();
    final feedback = FeedbackSettings();
    final host = await _host(tester, state, feedback);
    unawaited(showChipStore(host));
    await _settle(tester);
    expect(find.byType(EmojiChoice), findsNothing);

    final key = find.byIcon(Icons.emoji_emotions_rounded);
    expect(key, findsOneWidget);
    await tester.tap(key);
    await _settle(tester);
    expect(find.byType(EmojiChoice), findsNWidgets(_emojis().length));
    await _close(tester, state, feedback);
  });

  // At the tightest phone and the text ceiling, in every language and both
  // places the store opens: no word leaves its tile, no name is cut past its
  // two lines, and no badge is squeezed to fit.
  for (final lang in AppLang.values) {
    for (final screen in [Screen.lobby, Screen.table]) {
      for (final dark in [true, false]) {
        testWidgets('640x360 at text x1.25 in ${lang.englishName} '
            '${screen == Screen.table ? 'at a table' : 'in the lobby'}'
            '${dark ? '' : ', light'}: every tile holds its words', (
          tester,
        ) async {
          if (!haveScriptFonts()) {
            markTestSkipped('the Noto script fonts are not installed');
            return;
          }
          final (state, feedback) = await _openEmojis(
            tester,
            size: const Size(640, 360),
            scale: 1.25,
            lang: lang,
            screen: screen,
            dark: dark,
          );
          final reason =
              '${lang.code} ${screen.name} ${dark ? 'dark' : 'light'}';
          expect(tester.takeException(), isNull, reason: reason);
          final tiles = find.byType(EmojiChoice);
          expect(tiles, findsWidgets, reason: reason);
          for (final tile in tiles.evaluate()) {
            final box = tile.renderObject! as RenderBox;
            final rect = box.localToGlobal(Offset.zero) & box.size;
            final tileFinder = find.byElementPredicate((e) => e == tile);
            for (final text
                in find
                    .descendant(of: tileFinder, matching: find.byType(RichText))
                    .evaluate()) {
              final paragraph = text.renderObject! as RenderParagraph;
              final r = tester.getRect(
                find.byElementPredicate((e) => e == text),
              );
              expect(
                r.left >= rect.left - 0.5 && r.right <= rect.right + 0.5,
                isTrue,
                reason:
                    '$reason: "${paragraph.text.toPlainText()}" runs out of '
                    'its tile ($r in $rect)',
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
            final fitted = tester.renderObject<RenderFittedBox>(
              find.descendant(of: badge, matching: find.byType(FittedBox)),
            );
            expect(
              fitted.size.width / fitted.child!.size.width,
              greaterThanOrEqualTo(0.85),
              reason: '$reason: a badge squeezed',
            );
          }
          await _close(tester, state, feedback);
        });
      }
    }
  }
}
