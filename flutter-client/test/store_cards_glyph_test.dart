// The store's Cards key shows the default back itself (owner, 3 Oct 2026:
// "show default card icon also in store"): the Royal Fox — the back the app
// ships (PlayingCard.backAsset) — as a tiny upright card, the card's corner
// cut and the stock's gold edge round it, standing in the box every other
// key's icon stands in, in its own colours whether the key is on or off. The
// Cards shelf heads with it too.
//
// Held here: the glyph is the bundled back and no icon; every other key
// keeps its icon; the card one size on and off and never tinted; the
// header's on the Cards shelf alone; and the nine keys still one row at every
// phone size store_nav_test checks, both text scales, all five languages, in
// the lobby and at a table.
import 'dart:async';
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
import 'package:teenpatti/widgets/card_back_art.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'card_background_fixtures.dart';
import 'script_fonts.dart';

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

final _nav = _private('_StoreTabs');

/// The shelf keys, one InkWell each, in header order.
Finder get _keys => find.descendant(of: _nav, matching: find.byType(InkWell));

Finder _key(StoreTab tab) => find.byKey(ValueKey('store-tab-${tab.name}'));

/// The bundled Royal Fox drawn as a picture, under [of].
Finder _royalFoxIn(Finder of) => find.descendant(
  of: of,
  matching: find.byWidgetPredicate(
    (w) =>
        w is Image &&
        w.image is AssetImage &&
        (w.image as AssetImage).assetName == PlayingCard.backAsset,
  ),
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
    ..user = User.fromJson(cardAccountJson())
    ..cardBackgrounds = seededCatalogue();
}

/// An empty screen as main.dart builds one, and the store opened on it.
Future<void> _open(
  WidgetTester tester, {
  required GameState state,
  required FeedbackSettings feedback,
  Size screen = const Size(891, 411),
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

void main() {
  setUpAll(loadScriptFonts);

  testWidgets('the glyph is the bundled Royal Fox as a tiny upright card: '
      'the box an icon takes, the card\'s corner, the stock\'s edge, never '
      'tinted', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: RoyalFoxGlyph(size: 18)),
      ),
    );
    final glyph = find.byType(RoyalFoxGlyph);
    expect(tester.getSize(glyph), const Size(18, 18));
    final picture = _royalFoxIn(glyph);
    expect(picture, findsOneWidget);
    final image = tester.widget<Image>(picture);
    expect(image.color, isNull, reason: 'drawn as itself');
    expect(image.colorBlendMode, isNull);
    // Upright: as tall as the box, a card's 5:7 wide, in its middle.
    final card = tester.getRect(picture);
    expect(card.height, moreOrLessEquals(18, epsilon: 0.01));
    expect(
      card.width,
      moreOrLessEquals(18 * PlayingCard.aspect, epsilon: 0.01),
    );
    expect(card.center.dx, moreOrLessEquals(tester.getCenter(glyph).dx));
    // The card's corner, cut as every card's is.
    final clip = tester.widget<ClipRRect>(
      find.descendant(of: glyph, matching: find.byType(ClipRRect)),
    );
    expect(
      clip.borderRadius,
      BorderRadius.circular(18 * PlayingCard.cornerShare),
    );
    // The stock's finish over it: a back's, gold edge and all.
    final stock = tester
        .widgetList<CustomPaint>(
          find.descendant(of: glyph, matching: find.byType(CustomPaint)),
        )
        .map((p) => p.foregroundPainter)
        .whereType<CardStockPainter>()
        .single;
    expect(stock.height, 18);
    expect(stock.face, isFalse);
    // Nothing on the screen reader's side: it is a picture of a key's word.
    expect(image.excludeFromSemantics, isTrue);
  });

  testWidgets('drawn, the glyph is the Royal Fox\'s own art inside the '
      'card\'s cut corner', (tester) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: boundary,
            child: const RoyalFoxGlyph(size: 140),
          ),
        ),
      ),
    );
    final context = tester.element(find.byType(RoyalFoxGlyph));
    await tester.runAsync(
      () => precacheImage(const AssetImage(PlayingCard.backAsset), context),
    );
    await tester.pump();
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final (pixels, width) = (await tester.runAsync(() async {
      final shot = await render.toImage();
      final data = await shot.toByteData(format: ui.ImageByteFormat.rawRgba);
      final w = shot.width;
      shot.dispose();
      return (data!, w);
    }))!;
    Color at(int x, int y) {
      final i = (y * width + x) * 4;
      return Color.fromARGB(
        pixels.getUint8(i + 3),
        pixels.getUint8(i),
        pixels.getUint8(i + 1),
        pixels.getUint8(i + 2),
      );
    }

    // The card stands in the middle of its square, 100 wide and 140 tall:
    // outside it, nothing; at its very corner, the cut; inside it, the art.
    final left = ((140 - 140 * PlayingCard.aspect) / 2).ceil();
    expect(at(2, 70).a, 0, reason: 'beside the card: nothing');
    expect(at(left, 0).a, lessThan(0.5), reason: 'the card\'s corner is cut');
    final middle = at(70, 70);
    expect(middle.a, 1, reason: 'the card is solid');
    final colours = {
      for (final (x, y) in const [(70, 70), (55, 35), (85, 105), (60, 120)])
        at(x, y).toARGB32(),
    };
    expect(colours.length, greaterThan(1), reason: 'art, not a flat colour');
  });

  for (final screen in [Screen.lobby, Screen.table]) {
    testWidgets('${screen.name}: the Cards key shows the Royal Fox where '
        'every other key shows its icon, one size on and off and never '
        'tinted, and the Cards shelf heads with it', (tester) async {
      final state = _state(screen: screen);
      final feedback = FeedbackSettings();
      await _open(tester, state: state, feedback: feedback);

      final cards = _key(StoreTab.cards);
      expect(cards, findsOneWidget);
      expect(
        find.descendant(of: cards, matching: find.byType(RoyalFoxGlyph)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: cards, matching: find.byType(Icon)),
        findsNothing,
      );
      expect(_royalFoxIn(cards), findsOneWidget);
      // Every other key keeps its icon, and none shows the card.
      Size? iconBox;
      for (final tab in StoreTab.values) {
        if (tab == StoreTab.cards) continue;
        final key = _key(tab);
        final icon = find.descendant(of: key, matching: find.byType(Icon));
        expect(icon, findsOneWidget, reason: tab.name);
        expect(
          find.descendant(of: key, matching: find.byType(RoyalFoxGlyph)),
          findsNothing,
          reason: tab.name,
        );
        iconBox ??= tester.getSize(icon);
      }
      // In the box the icons stand in, where they stand in their keys.
      final glyph = find.descendant(
        of: cards,
        matching: find.byType(RoyalFoxGlyph),
      );
      expect(tester.getSize(glyph), iconBox);
      final tables = find.descendant(
        of: _key(StoreTab.tables),
        matching: find.byType(Icon),
      );
      Offset inKey(Finder of, StoreTab tab) =>
          tester.getTopLeft(of) - tester.getTopLeft(_key(tab));
      // Both keys are off, so drawn at one scale: the glyph sits at the
      // same height in its key as the icon in its own, and in the middle.
      expect(
        inKey(glyph, StoreTab.cards).dy,
        moreOrLessEquals(inKey(tables, StoreTab.tables).dy, epsilon: 0.01),
      );
      expect(
        tester.getCenter(glyph).dx,
        moreOrLessEquals(tester.getCenter(cards).dx, epsilon: 0.5),
      );
      final off = tester.getSize(_royalFoxIn(cards));
      expect(tester.widget<Image>(_royalFoxIn(cards)).color, isNull);
      // Nothing but the key shows it while another shelf is open.
      expect(find.byType(RoyalFoxGlyph), findsOneWidget);

      // On: the same card, untinted — and the header's glyph is it too.
      await tester.tap(cards);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.getSize(_royalFoxIn(cards)), off);
      expect(tester.widget<Image>(_royalFoxIn(cards)).color, isNull);
      final glyphs = tester
          .widgetList<RoyalFoxGlyph>(find.byType(RoyalFoxGlyph))
          .toList();
      expect(glyphs, hasLength(2), reason: 'the key\'s and the header\'s');
      final header = find.byWidgetPredicate(
        (w) => w is RoyalFoxGlyph && w.size == 22,
      );
      expect(header, findsOneWidget);
      expect(
        find.descendant(of: _nav, matching: header),
        findsNothing,
        reason: 'the header\'s stands above the keys',
      );
      expect(tester.getSize(header), const Size(22, 22));
      expect(
        tester.getRect(header).bottom,
        lessThanOrEqualTo(tester.getRect(cards).top),
      );
      expect(tester.takeException(), isNull);

      // Back on Chips, the header's poker chip again.
      await tester.tap(_key(StoreTab.chips));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(RoyalFoxGlyph), findsOneWidget);
      await _close(tester, state, feedback);
    });
  }

  // The nine keys still stand in one row, the Royal Fox inside its key, at
  // every size store_nav_test checks.
  for (final size in const [
    Size(592, 360),
    Size(640, 360),
    Size(732, 412),
    Size(844, 390),
    Size(915, 412),
    Size(1280, 800),
  ]) {
    for (final scale in const [1.0, 1.25]) {
      final name = '${size.width.toInt()}x${size.height.toInt()} x$scale';
      testWidgets('at $name the nine keys keep one row, the Royal Fox inside '
          'the Cards key, in every language, lobby and table', (tester) async {
        if (!haveScriptFonts()) {
          markTestSkipped('the Noto script fonts are not installed');
          return;
        }
        for (final lang in AppLang.values) {
          for (final screen in [Screen.lobby, Screen.table]) {
            final why = '$name ${lang.englishName} ${screen.name}';
            final state = _state(screen: screen, lang: lang);
            final feedback = FeedbackSettings();
            await _open(
              tester,
              state: state,
              feedback: feedback,
              screen: size,
              scale: scale,
            );
            expect(_keys, findsNWidgets(StoreTab.values.length), reason: why);
            final tops = <double>{
              for (var i = 0; i < _keys.evaluate().length; i++)
                tester.getRect(_keys.at(i)).top.roundToDouble(),
            };
            expect(tops, hasLength(1), reason: '$why: one row');
            final key = tester.getRect(_key(StoreTab.cards));
            final card = tester.getRect(_royalFoxIn(_key(StoreTab.cards)));
            expect(
              key.inflate(0.5).contains(card.topLeft) &&
                  key.inflate(0.5).contains(card.bottomRight),
              isTrue,
              reason: '$why: $card in $key',
            );
            // And the keys inside the sheet.
            final sheet = tester.getRect(
              find
                  .ancestor(of: _nav, matching: find.byType(PremiumGlassPanel))
                  .first,
            );
            for (var i = 0; i < _keys.evaluate().length; i++) {
              final rect = tester.getRect(_keys.at(i));
              expect(
                sheet.inflate(0.5).contains(rect.topLeft) &&
                    sheet.inflate(0.5).contains(rect.bottomRight),
                isTrue,
                reason: '$why: key $i $rect outside $sheet',
              );
            }
            expect(tester.takeException(), isNull, reason: why);
            await _close(tester, state, feedback);
          }
        }
      });
    }
  }
}
