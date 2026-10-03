// How a card back is drawn (owner, 3 Oct 2026: everybody at a table sees
// each player's own back on that player's face-down cards): the picture in
// the R2 bucket decoded once and shared by every card showing it, the card's
// crop of it stretched to the card, the SEEN tint, the stock's corner and
// edge — and the bundled Royal Fox for nobody's choice, while a back is
// coming, and when one cannot be had.
//
// Decoding is real work, so the pictures are decoded in plain tests or
// inside `tester.runAsync`, and the pixels a card paints are read back the
// same way. The pictures are the fixtures' miniatures: each back's card in
// its own colour on the dark ground, so a pixel says which back is drawn
// and whether any ground shows.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/card_back_art.dart';
import 'package:teenpatti/widgets/playing_card.dart';

import 'card_background_fixtures.dart';

/// Pixels read back from a picture.
class _Pixels {
  _Pixels(this.width, this.height, this.data);

  final int width;
  final int height;
  final ByteData data;

  Color at(num x, num y) {
    final i = (y.floor() * width + x.floor()) * 4;
    return Color.fromARGB(
      data.getUint8(i + 3),
      data.getUint8(i),
      data.getUint8(i + 1),
      data.getUint8(i + 2),
    );
  }
}

Future<_Pixels> _read(ui.Image image) async {
  final data = await image.toByteData();
  return _Pixels(image.width, image.height, data!);
}

/// What [key]'s repaint boundary paints, read back at one pixel a point.
Future<_Pixels> _grab(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final pixels = await _read(image);
    image.dispose();
    return pixels;
  }))!;
}

/// Whether [actual] is [expected] to within a few levels a channel.
Matcher _colour(Color expected, {double within = 0.06}) => predicate<Color>(
  (actual) =>
      (actual.r - expected.r).abs() <= within &&
      (actual.g - expected.g).abs() <= within &&
      (actual.b - expected.b).abs() <= within &&
      actual.a > 0.98,
  'the colour $expected',
);

/// A miniature put in the picture cache under [url], not decoded yet.
Future<void> _primeBytes(SeededCard card, {String? url}) async =>
    PictureCache.prime(
      url ?? card.url,
      await cardPicturePng(card.crop, card: card.colour),
    );

/// A back [height] tall, under a boundary [key] can read.
Widget _card(GlobalKey key, Widget card) => MaterialApp(
  home: Center(
    child: RepaintBoundary(key: key, child: card),
  ),
);

/// Points well inside a 100x140 card, clear of its corner and its gold edge
/// and below the light on its top: each is the card's colour if, and only
/// if, the crop was drawn — the whole picture stretched would put the
/// ground under every one but the middle.
const _inside = <(double, double)>[
  (50, 70), // the middle
  (7, 70), // near the left edge
  (93, 70), // near the right edge
  (50, 36), // high, below the top's light
  (50, 133), // near the foot
  (8, 128), // the bottom-left, inside its corner
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PictureCache.debugUseDirectory(null);
    PictureCache.debugResetSigning();
    forgetCardBacks();
  });
  tearDown(() {
    forgetCardBacks();
    PictureCache.debugResetSigning();
  });

  final tiger = seededCard('Royal Tiger');
  final demon = seededCard('Brutal Demon');

  group('the cache', () {
    test('a picture is decoded with its card 720 pixels tall, never larger '
        'than the file', () {
      for (final card in seededCards) {
        final size = CardBackImages.decodeSizeFor(1024, 1024, card.crop);
        expect(size.width, size.height, reason: card.name);
        expect(
          size.height! * card.crop.h,
          closeTo(CardBackImages.decodeHeight, 1),
          reason: card.name,
        );
        expect(size.height, lessThan(1024), reason: card.name);
      }
      // A small picture stays the size it is.
      final small = CardBackImages.decodeSizeFor(128, 128, demon.crop);
      expect(small.width, isNull);
      expect(small.height, isNull);
      // All card: its own height is the card's.
      final whole = CardBackImages.decodeSizeFor(600, 840, null);
      expect(whole.height, 720);
      expect(whole.width, 514);
    });

    test('a back is decoded once, the card\'s rectangle its crop', () async {
      await _primeBytes(tiger);
      final a = CardBackImages.load(tiger.art);
      final b = CardBackImages.load(tiger.art);
      final first = (await a)!;
      final second = (await b)!;
      expect(identical(first.image, second.image), isTrue, reason: 'shared');
      expect(CardBackImages.debugCount, 1);
      expect(first.image.width, 128, reason: 'never larger than the file');
      expect(first.source, tiger.crop.rectIn(128, 128));
      expect(CardBackImages.peek(tiger.art), first);
      // The same picture under another crop is the same decode, cut anew.
      const other = CardCrop(x: 0, y: 0, w: 0.5, h: 0.7);
      final recut = CardBackImages.peek(
        CardBackArt(id: 7, url: tiger.url, crop: other),
      )!;
      expect(identical(recut.image, first.image), isTrue);
      expect(recut.source, other.rectIn(128, 128));
      // With no crop, the whole picture is the card.
      expect(
        CardBackImages.peek(CardBackArt(url: tiger.url))!.source,
        const Rect.fromLTWH(0, 0, 128, 128),
      );
    });

    test('a file that is not a picture is nothing — not remembered as '
        'nothing — and asked again', () async {
      PictureCache.prime(tiger.url, Uint8List.fromList(utf8Page));
      expect(await CardBackImages.load(tiger.art), isNull);
      expect(CardBackImages.debugCount, 0);
      await _primeBytes(tiger);
      expect(await CardBackImages.load(tiger.art), isNotNull);
    });

    test('a location nothing can sign is not fetched; one in memory, or '
        'one that can be signed, is', () async {
      expect(CardBackImages.canFetch(tiger.art), isFalse);
      expect(await CardBackImages.load(tiger.art), isNull);
      expect(CardBackImages.canFetch(const CardBackArt(url: '')), isFalse);
      expect(
        CardBackImages.canFetch(
          const CardBackArt(url: 'https://cdn.test/cards/plain.jpg'),
        ),
        isTrue,
        reason: 'not the private bucket: no signature needed',
      );
      PictureCache.signer = (locations) async => SignedAssets.none;
      expect(CardBackImages.canFetch(tiger.art), isTrue);
      PictureCache.debugResetSigning();
      await _primeBytes(tiger);
      expect(CardBackImages.canFetch(tiger.art), isTrue);
    });

    test('null is the Royal Fox, decoded from the app\'s own asset — and what '
        'shows where a back cannot be had', () async {
      expect(CardBackImages.shown(tiger.art), isNull, reason: 'nothing yet');
      final fox = (await CardBackImages.load(null))!;
      expect(fox.image.width / fox.image.height, closeTo(240 / 336, 0.002));
      expect(
        fox.source,
        Rect.fromLTWH(
          0,
          0,
          fox.image.width.toDouble(),
          fox.image.height.toDouble(),
        ),
      );
      expect(CardBackImages.shown(null), fox);
      expect(CardBackImages.shown(tiger.art), fox, reason: 'not decoded');
      expect(await CardBackImages.resolve(tiger.art), fox, reason: 'no signer');
      await _primeBytes(tiger);
      final mine = (await CardBackImages.resolve(tiger.art))!;
      expect(identical(mine.image, fox.image), isFalse);
      expect(CardBackImages.shown(tiger.art), mine);
    });

    test('at most twelve pictures are kept, the one drawn least recently '
        'going first', () async {
      CardBackArt art(int i) =>
          CardBackArt(id: i, url: 'https://cdn.test/cards/$i.png');
      for (var i = 0; i < CardBackImages.capacity; i++) {
        await _primeBytes(tiger, url: art(i).url);
        expect(await CardBackImages.load(art(i)), isNotNull);
      }
      expect(CardBackImages.debugCount, CardBackImages.capacity);
      // Drawn again, the first is kept; the second goes for the thirteenth.
      final firstImage = CardBackImages.peek(art(0))!.image;
      await _primeBytes(tiger, url: art(99).url);
      await CardBackImages.load(art(99));
      expect(CardBackImages.debugCount, CardBackImages.capacity);
      expect(CardBackImages.peek(art(0))?.image, same(firstImage));
      expect(CardBackImages.peek(art(1)), isNull);
      expect(CardBackImages.peek(art(99)), isNotNull);
    });

    test('a card back is printed as a face-down card shows it: inside the '
        'card\'s corner, the stock over it', () async {
      await _primeBytes(tiger);
      final picture = (await CardBackImages.load(tiger.art))!;
      const card = Rect.fromLTWH(10, 10, 100, 140);
      ui.Image draw(CardBackPicture? picture, {Color? tint}) {
        final recorder = ui.PictureRecorder();
        paintCardBack(Canvas(recorder), card, picture: picture, tint: tint);
        final recorded = recorder.endRecording();
        final image = recorded.toImageSync(120, 160);
        recorded.dispose();
        return image;
      }

      final printed = await _read(draw(picture));
      for (final (x, y) in _inside) {
        expect(
          printed.at(10 + x, 10 + y),
          _colour(tiger.colour),
          reason: '$x,$y',
        );
      }
      // Cut to the card's corner: nothing at the very corner, nor outside.
      expect(printed.at(10.5, 10.5).a, lessThan(0.5));
      expect(printed.at(5, 80).a, 0);
      // The gold edge round it, over the picture.
      expect(printed.at(60, 10.6), isNot(_colour(tiger.colour)));
      // With no picture, the back's black ground.
      expect(
        (await _read(draw(null))).at(60, 80),
        _colour(PlayingCard.backGround),
      );
      // The tint takes the picture to its hue.
      final seen = (await _read(
        draw(picture, tint: AppTheme.cardSeenBack),
      )).at(60, 80);
      expect(
        HSLColor.fromColor(seen).hue,
        closeTo(HSLColor.fromColor(AppTheme.cardSeenBack).hue, 12),
      );
    });
  });

  group('the widget', () {
    testWidgets('null is the Royal Fox: the asset, tinted when asked, on the '
        'gold-edged stock', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CardBackImage(height: 60),
                CardBackImage(height: 60, tint: AppTheme.cardSeenBack),
              ],
            ),
          ),
        ),
      );
      final backs = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(backs, hasLength(2));
      for (final back in backs) {
        expect((back.image as AssetImage).assetName, PlayingCard.backAsset);
        expect(back.fit, BoxFit.cover);
      }
      expect(backs.first.color, isNull);
      expect(backs.last.color, AppTheme.cardSeenBack);
      expect(backs.last.colorBlendMode, BlendMode.color);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is CustomPaint &&
              w.foregroundPainter is CardStockPainter &&
              !(w.foregroundPainter! as CardStockPainter).face,
        ),
        findsNWidgets(2),
      );
      expect(tester.getSize(find.byType(CardBackImage).first).height, 60);
    });

    testWidgets('a back already decoded is drawn on the first frame, its card '
        'edge to edge with no ground showing', (tester) async {
      await primeCardBacks(tester, [tiger]);
      final key = GlobalKey();
      await tester.pumpWidget(
        _card(key, CardBackImage(art: tiger.art, height: 140)),
      );
      expect(find.byType(Image), findsNothing, reason: 'not the Royal Fox');
      expect(tester.getSize(find.byKey(key)), const Size(100, 140));
      final pixels = await _grab(tester, key);
      for (final (x, y) in _inside) {
        expect(pixels.at(x, y), _colour(tiger.colour), reason: '$x,$y');
      }
    });

    testWidgets('the SEEN tint recolours the picture', (tester) async {
      await primeCardBacks(tester, [tiger]);
      final key = GlobalKey();
      await tester.pumpWidget(
        _card(
          key,
          CardBackImage(
            art: tiger.art,
            height: 140,
            tint: AppTheme.cardSeenBack,
          ),
        ),
      );
      final seen = (await _grab(tester, key)).at(50, 70);
      expect(seen, isNot(_colour(tiger.colour)));
      expect(
        HSLColor.fromColor(seen).hue,
        closeTo(HSLColor.fromColor(AppTheme.cardSeenBack).hue, 12),
      );
    });

    testWidgets('a back still coming shows the Royal Fox, then itself once '
        'it is decoded', (tester) async {
      await tester.runAsync(() => _primeBytes(tiger));
      final key = GlobalKey();
      await tester.pumpWidget(
        _card(key, CardBackImage(art: tiger.art, height: 140)),
      );
      expect(find.byType(Image), findsOneWidget, reason: 'the Royal Fox');
      // The card's own decode, given real time to run.
      for (var i = 0; i < 20 && find.byType(Image).evaluate().isNotEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.byType(Image), findsNothing);
      expect((await _grab(tester, key)).at(50, 70), _colour(tiger.colour));
    });

    testWidgets('a back decoded for another card swaps in by itself', (
      tester,
    ) async {
      // Nothing can sign its location yet, so this card gives up asking —
      final key = GlobalKey();
      await tester.pumpWidget(
        _card(key, CardBackImage(art: tiger.art, height: 140)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(Image), findsOneWidget, reason: 'the Royal Fox');
      // — and another (the deal, the store, a seat) has it decoded.
      await tester.runAsync(() async {
        await _primeBytes(tiger);
        await CardBackImages.load(tiger.art);
      });
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect((await _grab(tester, key)).at(50, 70), _colour(tiger.colour));
    });

    testWidgets('a back that cannot be had is the Royal Fox, and nothing is '
        'fetched or retried', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        _card(key, CardBackImage(art: tiger.art, height: 140)),
      );
      await tester.pump(const Duration(seconds: 40));
      expect(find.byType(Image), findsOneWidget);
      expect(CardBackImages.debugCount, 0);
      // The test framework fails on a timer left running: none is.
    });

    testWidgets('a card whose back changes keeps the one it had until the new '
        'one is ready; null is the Royal Fox at once', (tester) async {
      await primeCardBacks(tester, [tiger]);
      await tester.runAsync(() => _primeBytes(demon));
      final key = GlobalKey();
      Future<void> show(CardBackArt? art) =>
          tester.pumpWidget(_card(key, CardBackImage(art: art, height: 140)));
      await show(tiger.art);
      expect((await _grab(tester, key)).at(50, 70), _colour(tiger.colour));
      await show(demon.art);
      expect(
        (await _grab(tester, key)).at(50, 70),
        _colour(tiger.colour),
        reason: 'the old back until the new one is decoded',
      );
      await tester.runAsync(() => CardBackImages.load(demon.art));
      await tester.pump();
      expect((await _grab(tester, key)).at(50, 70), _colour(demon.colour));
      await show(null);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('left without a height, the largest card that fits is drawn, '
        'centred', (tester) async {
      const box = Key('box');
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: SizedBox(
              key: box,
              width: 300,
              height: 140,
              child: CardBackImage(),
            ),
          ),
        ),
      );
      final stock = find.byWidgetPredicate(
        (w) => w is CustomPaint && w.foregroundPainter is CardStockPainter,
      );
      expect(tester.getSize(stock), const Size(100, 140));
      expect(tester.getCenter(stock), tester.getCenter(find.byKey(box)));
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: SizedBox(width: 50, height: 400, child: CardBackImage()),
          ),
        ),
      );
      expect(tester.getSize(stock).width, closeTo(50, 0.01));
      expect(tester.getSize(stock).height, closeTo(70, 0.01));
    });
  });

  group('the card', () {
    testWidgets('a face-down card wears its holder\'s back, and turning it '
        'over shows the face', (tester) async {
      await primeCardBacks(tester, [tiger]);
      final key = GlobalKey();
      Future<void> card(String? code) => tester.pumpWidget(
        _card(key, PlayingCard(height: 140, back: tiger.art, code: code)),
      );
      await card(null);
      final back = tester.widget<CardBackImage>(find.byType(CardBackImage));
      expect(back.art, tiger.art);
      expect(back.height, 140);
      expect((await _grab(tester, key)).at(50, 70), _colour(tiger.colour));
      await card('As');
      await tester.pumpAndSettle();
      expect(find.byType(CardBackImage), findsNothing);
    });

    testWidgets('with no back it is the Royal Fox, and the SEEN tint reaches '
        'the holder\'s back', (tester) async {
      await primeCardBacks(tester, [tiger]);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const PlayingCard(height: 60),
                PlayingCard(
                  height: 60,
                  back: tiger.art,
                  tint: AppTheme.cardSeenBack,
                ),
              ],
            ),
          ),
        ),
      );
      final backs = tester
          .widgetList<CardBackImage>(find.byType(CardBackImage))
          .toList();
      expect(backs.map((b) => b.art).toList(), [null, tiger.art]);
      expect(backs.map((b) => b.tint).toList(), [null, AppTheme.cardSeenBack]);
      // The Royal Fox's card draws the asset; the holder's draws theirs.
      expect(find.byType(Image), findsOneWidget);
    });
  });
}

/// What a host serves in place of a file it will not hand out.
final utf8Page = '<!doctype html><title>Sign in</title>'.codeUnits;
