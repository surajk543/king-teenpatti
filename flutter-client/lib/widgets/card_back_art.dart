/// The card backs players wear (owner, 3 Oct 2026: "Add a table
/// cards_background which users can buy just like user can buy
/// profile_pictures, cards background images are stored in r2 storage in
/// cards folder"), as a card draws them.
///
/// Every back but the bundled Royal Fox ([PlayingCard.backAsset]) is a
/// product shot in the private R2 bucket — a 1024x1024 JPEG, the card on a
/// dark ground — and its row says where the card is in it ([CardCrop]). The
/// bytes come from [PictureCache], which signs the location and keeps the
/// file on the phone; they are decoded ONCE into a [ui.Image] that every
/// card showing that back shares ([CardBackImages]), and each card draws the
/// card's rectangle of it stretched to its own 5:7 ([CardBackImage],
/// [paintCardBack]). The deal's flying cards draw from the same images.
///
/// The Royal Fox is what every card shows while a back is coming, when one
/// cannot be had, and for nobody's choice (null): a card is never blank and
/// never a broken picture.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/dtos.dart';
import '../net/picture_cache.dart';
import 'playing_card.dart';

/// A card back's picture, decoded and ready to draw: the [image] and the
/// rectangle of it that is the card ([source]), in the image's own pixels.
///
/// The image of one handed out by [CardBackImages] belongs to the cache:
/// draw it in the code that was handed it (a picture recorded then keeps it
/// alive however long it is shown), or [ui.Image.clone] it to keep it, and
/// dispose the clone. [CardBackImage] keeps a clone of its own.
@immutable
class CardBackPicture {
  const CardBackPicture({required this.image, required this.source});

  final ui.Image image;

  /// The card in [image]: its crop, or the whole image where the picture is
  /// all card (the Royal Fox).
  final Rect source;

  /// Draws the card's rectangle of [image] stretched over [dest] — the
  /// crop is cut to the card's 5:7, so it is not distorted — recoloured by
  /// [tint] as [PlayingCard.tint] recolours a back ([BlendMode.color]: the
  /// tint's hue, the picture's own light and shade). Not clipped: the
  /// caller cuts the card's corner ([paintCardBack] does).
  void paint(Canvas canvas, Rect dest, {Color? tint}) {
    canvas.drawImageRect(
      image,
      source,
      dest,
      Paint()
        // Drawn at a fraction of its size on every card: smoothed, so the
        // art does not shimmer as the card moves.
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true
        ..colorFilter = tint == null
            ? null
            : ColorFilter.mode(tint, BlendMode.color),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CardBackPicture &&
      identical(other.image, image) &&
      other.source == source;

  @override
  int get hashCode => Object.hash(identityHashCode(image), source);
}

/// Prints the back of a card into [card] on [canvas], as a face-down
/// [PlayingCard] shows it: the back's black ground, [picture]'s card
/// stretched over it under the card's rounded corner, recoloured by [tint]
/// (a SEEN back's green), and the stock's finish over all of it — the top
/// edge's light and the gold cut edge ([CardStockPainter]). With no
/// [picture] (one not decoded yet) the black ground stands in.
///
/// For a painter that draws backs itself — the deal's flying cards — so
/// they are printed exactly as the cards they land as.
void paintCardBack(
  Canvas canvas,
  Rect card, {
  CardBackPicture? picture,
  Color? tint,
}) {
  final height = card.height;
  final rounded = RRect.fromRectAndRadius(
    card,
    Radius.circular(height * PlayingCard.cornerShare),
  );
  canvas
    ..save()
    ..clipRRect(rounded)
    ..drawRect(card, Paint()..color = PlayingCard.backGround);
  picture?.paint(canvas, card, tint: tint);
  canvas
    ..restore()
    ..save()
    ..translate(card.left, card.top);
  CardStockPainter(height: height, face: false).paint(canvas, card.size);
  canvas.restore();
}

/// Tells [CardBackImages]' listeners that a picture has come in.
class _Arrivals extends ChangeNotifier {
  void arrived() => notifyListeners();
}

/// The card backs decoded so far, one [ui.Image] per picture however many
/// cards show it — five seats of three cards in one back cost one decode.
///
/// A back's picture is decoded so that its CARD is [decodeHeight] pixels
/// tall, never larger than the file holds: sharp on the largest card a phone
/// draws (about 400 pixels tall), and about three megabytes a picture. At
/// most [capacity] are kept; the one drawn least recently goes first.
///
/// Null asks for the bundled Royal Fox, decoded once the same way — for a
/// painter that draws backs itself ([shown], [resolve]); a [CardBackImage]
/// draws the Royal Fox through the asset image the splash screen
/// precaches.
///
/// **In tests**: decoding is real work the fake clock of a widget test never
/// finishes, so decode in `tester.runAsync` (`load`) before the widget is
/// built, and call [debugClear] in `tearDown`. A location in the private
/// bucket is not fetched while nothing can sign it ([canFetch]): an
/// unprimed back in a test draws the Royal Fox and starts no download.
abstract final class CardBackImages {
  /// How tall the card in a picture is decoded, in pixels: nearly twice the
  /// tallest card a phone's table draws (the viewer's own hand, about 400
  /// pixels on a 3.5x screen), as the bundled Royal Fox is kept at 840, so
  /// the art is sharp at any size the table, the store or a question shows.
  static const int decodeHeight = 720;

  /// How many decoded pictures are kept — the eight backs on sale, the Royal
  /// Fox and room to spare.
  static const int capacity = 12;

  static const String _defaultKey = 'asset:${PlayingCard.backAsset}';

  /// Decoded pictures by key ([_keyOf]), least recently drawn first.
  static final LinkedHashMap<String, ui.Image> _images =
      LinkedHashMap<String, ui.Image>();

  /// Decodes running, by key, with the zone each was started in.
  static final Map<String, ({Zone zone, Future<void> done})> _decoding = {};

  /// Bumped by [debugClear], so a decode that finishes after it is dropped.
  static int _generation = 0;

  static final _Arrivals _arrivals = _Arrivals();

  /// Fires whenever a picture has been decoded (or put by a test), so a
  /// card still showing the Royal Fox can look again ([peek]) — whoever
  /// asked for it.
  static Listenable get changes => _arrivals;

  static String _keyOf(CardBackArt? art) => art == null ? _defaultKey : art.url;

  /// The card's rectangle in [image], decoded for [art]: its crop, or the
  /// whole image.
  static Rect sourceOf(CardBackArt? art, ui.Image image) {
    final w = image.width.toDouble();
    final h = image.height.toDouble();
    return art?.crop?.rectIn(w, h) ?? Rect.fromLTWH(0, 0, w, h);
  }

  /// The size a picture [width] by [height] pixels is decoded at, its card
  /// [crop] taking [decodeHeight] pixels of it (the whole picture when null):
  /// smaller in proportion, never larger than the file.
  @visibleForTesting
  static ui.TargetImageSize decodeSizeFor(
    int width,
    int height,
    CardCrop? crop,
  ) {
    final card = height * (crop?.h ?? 1);
    if (card <= decodeHeight) return const ui.TargetImageSize();
    final scale = decodeHeight / card;
    return ui.TargetImageSize(
      width: math.max(1, (width * scale).round()),
      height: math.max(1, (height * scale).round()),
    );
  }

  /// [art]'s picture if it has been decoded, or null. Synchronous, so a
  /// card that has been seen before paints its back on its first frame.
  /// Null asks for the Royal Fox's.
  static CardBackPicture? peek(CardBackArt? art) {
    final key = _keyOf(art);
    final image = _images.remove(key);
    if (image == null) return null;
    _images[key] = image; // drawn most recently now
    return CardBackPicture(image: image, source: sourceOf(art, image));
  }

  /// What a card of [art] shows now: its picture, else the Royal Fox's
  /// once decoded, else null (draw the black ground).
  static CardBackPicture? shown(CardBackArt? art) =>
      peek(art) ?? (art == null ? null : peek(null));

  /// Whether [art]'s picture can be had at all: it names one, and it is in
  /// memory, or downloadable — a location in the private bucket only when
  /// something can sign it ([PictureCache.signer], which a session wires at
  /// start and a test leaves unset).
  static bool canFetch(CardBackArt art) {
    if (art.url.isEmpty) return false;
    if (PictureCache.peek(art.url) != null) return true;
    return !isAssetLocation(art.url) || PictureCache.signer != null;
  }

  /// [art]'s picture, decoded if it has not been: from [PictureCache] — the
  /// phone's memory, its disk, or a download through a signed URL — or, for
  /// null, the bundled Royal Fox. Null when it cannot be had now (offline,
  /// a file that is not a picture, nothing to sign it); asked again, it
  /// tries again — a failure is not remembered.
  ///
  /// Every card asking for one picture at once shares one decode — within a
  /// zone: a decode started under a test's fake clock never finishes outside
  /// it, so a load from another zone does not wait on one.
  static Future<CardBackPicture?> load(CardBackArt? art) async {
    final ready = peek(art);
    if (ready != null) return ready;
    if (art != null && !canFetch(art)) return null;
    final key = _keyOf(art);
    final running = _decoding[key];
    if (running != null && identical(running.zone, Zone.current)) {
      await running.done;
    } else {
      final generation = _generation;
      final done = _decode(art).then((image) {
        if (image == null) return;
        if (generation != _generation) {
          image.dispose();
          return;
        }
        _put(key, image);
      });
      _decoding[key] = (zone: Zone.current, done: done);
      // A block body, as PictureCache.load's: whenComplete awaits whatever
      // its callback returns, and an arrow would return what the map gave
      // back.
      unawaited(
        done.whenComplete(() {
          if (identical(_decoding[key]?.done, done)) _decoding.remove(key);
        }),
      );
      await done;
    }
    return peek(art);
  }

  /// [art]'s picture, or the Royal Fox's where it cannot be had — what a
  /// painter that draws backs itself waits for. Null only when the Royal
  /// Fox cannot be decoded either.
  static Future<CardBackPicture?> resolve(CardBackArt? art) async =>
      await load(art) ?? (art == null ? null : await load(null));

  static Future<ui.Image?> _decode(CardBackArt? art) async {
    try {
      if (art == null) {
        final data = await rootBundle.load(PlayingCard.backAsset);
        final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
        return await _firstFrame(codec);
      }
      final bytes = await PictureCache.load(art.url);
      if (bytes == null || bytes.isEmpty) return null;
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      // The buffer is the codec's from here: instantiateImageCodecWithSize
      // disposes it.
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) =>
            decodeSizeFor(width, height, art.crop),
      );
      return await _firstFrame(codec);
    } catch (_) {
      // Not a picture (a page, a Lottie, a truncated file) or no bundle:
      // the Royal Fox stands in, and the next ask tries again.
      return null;
    }
  }

  static Future<ui.Image> _firstFrame(ui.Codec codec) async {
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  }

  static void _put(String key, ui.Image image) {
    _images.remove(key)?.dispose();
    _images[key] = image;
    while (_images.length > capacity) {
      _images.remove(_images.keys.first)?.dispose();
    }
    _arrivals.arrived();
  }

  /// Puts [image] in as [art]'s decoded picture (null: the Royal Fox's), as
  /// if it had been decoded — for tests that draw a known picture. The
  /// cache owns it from here.
  @visibleForTesting
  static void debugPut(CardBackArt? art, ui.Image image) =>
      _put(_keyOf(art), image);

  /// How many pictures are held decoded, for tests.
  @visibleForTesting
  static int get debugCount => _images.length;

  /// Forgets every decoded picture and every decode running, for tests:
  /// call it in `tearDown`, or a decode left running under one test's fake
  /// clock can be waited on by the next.
  @visibleForTesting
  static void debugClear() {
    _generation++;
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _decoding.clear();
  }
}

/// How long a back that could not be had waits before its [attempt]th
/// retry: 4 s, 8 s, 16 s, then every 30 s — the picture boxes' own clock
/// (table_picture_shelf's `pictureRetryDelay`), so a phone that was offline
/// for a moment gets its backs without hammering the server.
Duration _retryDelay(int attempt) =>
    Duration(seconds: math.min(30, 4 << math.min(attempt, 3)));

/// The printed back of a card (owner, 3 Oct 2026: everybody at a table sees
/// each player's own back on that player's face-down cards): [art]'s
/// picture, cropped to the card and stretched to its 5:7, on the same stock
/// as a face — cut to the card's corner, with the stock's top-edge light and
/// gold edge laid over it ([CardStockPainter]). [tint] recolours the
/// picture, keeping its light and dark: a SEEN opponent's backs are their
/// back in green.
///
/// The bundled Royal Fox ([PlayingCard.backAsset]) is drawn for null, while
/// [art]'s picture is coming, and when it cannot be had — tried again on the
/// picture boxes' clock. A back seen before paints on the first frame
/// ([CardBackImages.peek]); a new one swaps in when it arrives, from any
/// card's asking; a card whose back CHANGES keeps the one it had until the
/// new one is ready.
///
/// [height] sizes the card (it is `height * PlayingCard.aspect` wide); left
/// null, the largest card that fits the space it is given is drawn, centred.
class CardBackImage extends StatefulWidget {
  const CardBackImage({super.key, this.art, this.height, this.tint});

  /// The back to show; null for the Royal Fox.
  final CardBackArt? art;
  final double? height;
  final Color? tint;

  @override
  State<CardBackImage> createState() => _CardBackImageState();
}

class _CardBackImageState extends State<CardBackImage> {
  /// The back being shown and this card's own handle on its picture, or
  /// both null while the Royal Fox is.
  CardBackArt? _shown;
  ui.Image? _image;

  /// The retry armed after a back could not be had, and how many have
  /// failed in a row.
  Timer? _retry;
  int _failures = 0;

  /// Same picture, same crop: the id a row carries does not change a back.
  static bool _samePicture(CardBackArt? a, CardBackArt? b) =>
      a?.url == b?.url && a?.crop == b?.crop;

  @override
  void initState() {
    super.initState();
    CardBackImages.changes.addListener(_arrived);
    _resolve();
  }

  @override
  void didUpdateWidget(covariant CardBackImage old) {
    super.didUpdateWidget(old);
    if (_samePicture(old.art, widget.art)) return;
    _retry?.cancel();
    _retry = null;
    _failures = 0;
    _resolve();
  }

  @override
  void dispose() {
    CardBackImages.changes.removeListener(_arrived);
    _retry?.cancel();
    _image?.dispose();
    super.dispose();
  }

  /// Shows [art] with [image] — this card's own clone of it — or the Royal
  /// Fox for nulls, letting go of the picture shown before.
  void _show(CardBackArt? art, ui.Image? image) {
    _image?.dispose();
    _image = image?.clone();
    _shown = image == null ? null : art;
  }

  /// Puts up the back asked for: at once when it is decoded, else the Royal
  /// Fox — or the back already shown, when it is another that the card is
  /// changing from — while it is fetched and decoded.
  void _resolve() {
    final art = widget.art;
    if (art == null) {
      _show(null, null);
      return;
    }
    final ready = CardBackImages.peek(art);
    if (ready != null) {
      _show(art, ready.image);
      return;
    }
    final wanted = art;
    unawaited(
      CardBackImages.load(wanted).then((_) {
        if (!mounted || !_samePicture(widget.art, wanted)) return;
        final picture = CardBackImages.peek(wanted);
        if (picture != null) {
          if (!_samePicture(_shown, wanted)) {
            setState(() => _show(wanted, picture.image));
          }
          _failures = 0;
          return;
        }
        // Not to be had: the Royal Fox rather than somebody else's back,
        // and another try later — unless nothing could ever fetch it.
        if (_shown != null) setState(() => _show(null, null));
        if (!CardBackImages.canFetch(wanted)) return;
        _retry?.cancel();
        _retry = Timer(_retryDelay(_failures++), () {
          if (mounted && _samePicture(widget.art, wanted)) {
            setState(_resolve);
          }
        });
      }),
    );
  }

  /// A picture has been decoded somewhere: this card's, if it was waiting
  /// for it.
  void _arrived() {
    final art = widget.art;
    if (art == null || _samePicture(_shown, art)) return;
    final picture = CardBackImages.peek(art);
    if (picture == null) return;
    _retry?.cancel();
    _retry = null;
    _failures = 0;
    setState(() => _show(art, picture.image));
  }

  @override
  Widget build(BuildContext context) {
    final height = widget.height;
    if (height != null) return _back(height);
    return LayoutBuilder(
      builder: (context, constraints) {
        final fit = math.min(
          constraints.maxHeight,
          constraints.maxWidth / PlayingCard.aspect,
        );
        return Center(child: _back(fit.isFinite ? fit : 96));
      },
    );
  }

  Widget _back(double h) {
    final w = h * PlayingCard.aspect;
    final tint = widget.tint;
    final image = _image;
    final art = _shown;
    final Widget picture = image != null && art != null
        ? CustomPaint(
            size: Size(w, h),
            painter: _CardBackPainter(
              picture: CardBackPicture(
                image: image,
                source: CardBackImages.sourceOf(art, image),
              ),
              tint: tint,
            ),
          )
        : Image.asset(
            PlayingCard.backAsset,
            fit: BoxFit.cover,
            width: w,
            height: h,
            color: tint,
            colorBlendMode: tint == null ? null : BlendMode.color,
            // Drawn at a fraction of its size on every card: smoothed, so
            // its gold filigree does not shimmer as the card moves.
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            excludeFromSemantics: true,
          );
    return CustomPaint(
      foregroundPainter: CardStockPainter(height: h, face: false),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(h * PlayingCard.cornerShare),
        child: ColoredBox(color: PlayingCard.backGround, child: picture),
      ),
    );
  }
}

/// [CardBackImage]'s picture, once decoded: the card's rectangle of it over
/// the whole box.
class _CardBackPainter extends CustomPainter {
  const _CardBackPainter({required this.picture, this.tint});

  final CardBackPicture picture;
  final Color? tint;

  @override
  void paint(Canvas canvas, Size size) =>
      picture.paint(canvas, Offset.zero & size, tint: tint);

  @override
  bool shouldRepaint(_CardBackPainter old) =>
      old.picture != picture || old.tint != tint;
}
