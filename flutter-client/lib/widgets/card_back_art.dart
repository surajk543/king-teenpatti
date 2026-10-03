/// The card backs players wear (owner, 3 Oct 2026: "Add a table
/// cards_background which users can buy just like user can buy
/// profile_pictures, cards background images are stored in r2 storage in
/// cards folder"), as a card draws them.
///
/// Every back but the bundled Royal Fox ([PlayingCard.backAsset]) is a
/// product shot in the private R2 bucket — a 1024x1024 JPEG, the card on a
/// dark ground — and its row says where the card is in it ([CardCrop]). The
/// bytes come from [PictureCache], which signs the location and keeps the
/// file on the phone; they are decoded ONCE and the card cut out of the
/// picture, and only the card is kept, as a [ui.Image] that every card
/// showing that back shares ([CardBackImages]); each card draws it stretched
/// to its own 5:7 ([CardBackImage], [paintCardBack]). The deal's flying cards
/// draw from the same images.
///
/// At a table the Royal Fox is what a card shows while a back is coming,
/// when one cannot be had, and for nobody's choice (null): a card there is
/// never blank and never a broken picture. The store, which SELLS a back,
/// shows the plain back while it comes instead ([CardBackImage.standIn]) —
/// never another back in the place of the one on sale.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/dtos.dart';
import '../net/picture_cache.dart';
import 'playing_card.dart';

/// A card back's picture, decoded and ready to draw: the card itself, edge to
/// edge — [CardBackImages] keeps only the card, cut out of its product shot
/// (the Royal Fox is all card already).
///
/// The image of one handed out by [CardBackImages] belongs to the cache:
/// draw it in the code that was handed it (a picture recorded then keeps it
/// alive however long it is shown), or [ui.Image.clone] it to keep it, and
/// dispose the clone. [CardBackImage] keeps a clone of its own.
@immutable
class CardBackPicture {
  const CardBackPicture(this.image);

  final ui.Image image;

  /// Draws the card stretched over [dest] — cut to the card's 5:7, so it is
  /// not distorted — recoloured by [tint] as [PlayingCard.tint] recolours a
  /// back ([BlendMode.color]: the tint's hue, the picture's own light and
  /// shade). Not clipped: the caller cuts the card's corner ([paintCardBack]
  /// does).
  void paint(Canvas canvas, Rect dest, {Color? tint}) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
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
      other is CardBackPicture && identical(other.image, image);

  @override
  int get hashCode => identityHashCode(image);
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

/// The card backs decoded so far, one [ui.Image] per back however many cards
/// show it — five seats of three cards in one back cost one decode.
///
/// Only the CARD is kept (review, 3 Oct 2026: the thirteen product shots kept
/// whole, their cards 720 pixels tall, came to 42 MB — about half of it the
/// dark ground round the cards — and twelve places held fewer than the
/// catalogue). A picture is decoded at the size that makes its card
/// [decodeHeight] pixels tall, never larger than the file holds; the card is
/// cut out of it to whole pixels ([cardPixels]); and the rest is let go at
/// once — about two thirds of a megabyte a back. At most [capacity] are
/// kept, the one drawn least recently going first, and all of them are let
/// go when the system says memory is short ([CardBackMemoryWatch]) and when a
/// session ends ([release]): every card on screen keeps its own handle on its
/// back, so nothing showing is lost — a card built after that decodes its
/// back again, from the phone.
///
/// Null asks for the bundled Royal Fox, decoded the same way (it is all
/// card) — for a painter that draws backs itself ([shown], [resolve]); a
/// [CardBackImage] draws the Royal Fox through the asset image the splash
/// screen precaches.
///
/// **In tests**: decoding is real work the fake clock of a widget test never
/// finishes, so decode in `tester.runAsync` (`load`) before the widget is
/// built, and call [debugClear] in `tearDown`. A location in the private
/// bucket is not fetched while nothing can sign it ([canFetch]): an
/// unprimed back in a test draws the Royal Fox and starts no download.
abstract final class CardBackImages {
  /// How tall a back's card is kept, in pixels: a little more than the
  /// tallest card a phone draws it at — the card in the unlock question, 123
  /// dp on a 411dp phone, 431 pixels at 3.5x; the viewer's own hand about
  /// 400 at most — so the art is sharp wherever the table, the store or a
  /// question shows it.
  static const int decodeHeight = 480;

  /// How many decoded backs are kept: every back on sale (thirteen — owner,
  /// 3 Oct 2026: eight, and that evening the five Flower backs), the Royal
  /// Fox and room to spare, about ten megabytes in all — so one visit to the
  /// Cards shelf decodes each back once. A catalogue grown past it costs only
  /// a decode from the phone's disk the next time the shelf is opened.
  static const int capacity = 16;

  /// The Royal Fox's place in the cache: no back's location is an asset.
  static const _Key _foxKey = (
    url: 'asset:${PlayingCard.backAsset}',
    crop: null,
  );

  /// Decoded backs by key ([_keyOf]), least recently drawn first.
  static final LinkedHashMap<_Key, ui.Image> _images =
      LinkedHashMap<_Key, ui.Image>();

  /// Decodes running, by key, with the zone each was started in.
  static final Map<_Key, ({Zone zone, Future<void> done})> _decoding = {};

  /// Bumped by [debugClear], so a decode that finishes after it is dropped.
  static int _generation = 0;

  static final _Arrivals _arrivals = _Arrivals();

  /// Fires whenever a picture has been decoded (or put by a test), so a
  /// card still showing the Royal Fox can look again ([peek]) — whoever
  /// asked for it.
  static Listenable get changes => _arrivals;

  /// A back is its picture AND its crop: the same picture cut another way is
  /// another card (a row's crop measured again, a seat restored with the old
  /// one).
  static _Key _keyOf(CardBackArt? art) =>
      art == null ? _foxKey : (url: art.url, crop: art.crop);

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

  /// The whole pixels of a picture [width] by [height] that are card: its
  /// [crop], each edge rounded INTO the card — a crop is measured to the
  /// card's own edge, and a pixel half over it is half dark ground. At least
  /// one pixel each way, inside the picture.
  @visibleForTesting
  static Rect cardPixels(int width, int height, CardCrop crop) {
    // A hair of slack, so an edge that lands on a pixel's own edge is not
    // taken a whole pixel in by the rounding in multiplying two decimals.
    const slack = 1e-6;
    final r = crop.rectIn(width.toDouble(), height.toDouble());
    (double, double) span(double from, double to, int size) {
      final start = math.max(0.0, (from - slack).ceilToDouble());
      final end = math.min(size.toDouble(), (to + slack).floorToDouble());
      if (end > start) return (start, end);
      // Under a pixel (a tiny file): the pixel it lies in.
      final only = math.min(size - 1.0, math.max(0.0, from.floorToDouble()));
      return (only, only + 1);
    }

    final (left, right) = span(r.left, r.right, width);
    final (top, bottom) = span(r.top, r.bottom, height);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// [art]'s card if it has been decoded, or null. Synchronous, so a card
  /// that has been seen before paints its back on its first frame. Null asks
  /// for the Royal Fox's.
  static CardBackPicture? peek(CardBackArt? art) {
    final key = _keyOf(art);
    final image = _images.remove(key);
    if (image == null) return null;
    _images[key] = image; // drawn most recently now
    return CardBackPicture(image);
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

  /// [art]'s card, decoded if it has not been: from [PictureCache] — the
  /// phone's memory, its disk, or a download through a signed URL — or, for
  /// null, the bundled Royal Fox. Null when it cannot be had now (offline,
  /// a file that is not a picture, nothing to sign it); asked again, it
  /// tries again — a failure is not remembered.
  ///
  /// Every card asking for one back at once shares one decode — within a
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
      final Uint8List bytes;
      if (art == null) {
        final data = await rootBundle.load(PlayingCard.backAsset);
        bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } else {
        final got = await PictureCache.load(art.url);
        if (got == null || got.isEmpty) return null;
        bytes = got;
      }
      final crop = art?.crop;
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      // The buffer is the codec's from here: instantiateImageCodecWithSize
      // disposes it.
      final codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: (width, height) => decodeSizeFor(width, height, crop),
      );
      final frame = await _firstFrame(codec);
      if (crop == null) return frame;
      try {
        return await _cut(frame, crop);
      } finally {
        // The picture round the card: let go the moment the card is out.
        frame.dispose();
      }
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

  /// The card in [frame] ([cardPixels] of [crop]) as an image of its own,
  /// pixel for pixel. Rendered to a finished image ([ui.Picture.toImage]),
  /// never to one made with `toImageSync`: on the Skia engine that one keeps
  /// its recording to draw it again should the GPU's context be lost, and
  /// with it the whole picture this cut exists to let go of.
  static Future<ui.Image> _cut(ui.Image frame, CardCrop crop) async {
    final source = cardPixels(frame.width, frame.height, crop);
    final width = source.width.round();
    final height = source.height.round();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      frame,
      source,
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      // Whole pixels onto whole pixels: a copy, with nothing to smooth.
      Paint()..filterQuality = FilterQuality.none,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  }

  static void _put(_Key key, ui.Image image) {
    _images.remove(key)?.dispose();
    _images[key] = image;
    while (_images.length > capacity) {
      _images.remove(_images.keys.first)?.dispose();
    }
    _arrivals.arrived();
  }

  /// Lets go of every back decoded so far: when the system says memory is
  /// short ([CardBackMemoryWatch]), as Flutter empties its own image cache
  /// then, and when a session ends (GameState). Safe whenever: every card on
  /// screen and every render of the deal holds its own handle, and a card
  /// built after this decodes its back again — from the phone's memory or
  /// disk, not the network. Decodes running still land.
  static void release() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
  }

  /// Puts [image] in as [art]'s decoded card (null: the Royal Fox's), as if
  /// it had been decoded and cut — for tests that draw a known picture. The
  /// cache owns it from here.
  @visibleForTesting
  static void debugPut(CardBackArt? art, ui.Image image) =>
      _put(_keyOf(art), image);

  /// How many backs are held decoded, for tests.
  @visibleForTesting
  static int get debugCount => _images.length;

  /// Forgets every decoded back and every decode running, for tests: call it
  /// in `tearDown`, or a decode left running under one test's fake clock can
  /// be waited on by the next.
  @visibleForTesting
  static void debugClear() {
    _generation++;
    release();
    _decoding.clear();
  }
}

/// A back in [CardBackImages]: its picture's location and the card's crop in
/// it.
typedef _Key = ({String url, CardCrop? crop});

/// Lets go of the decoded card backs ([CardBackImages.release]) when the
/// system says memory is short — the moment Flutter empties its own image
/// cache (review, 3 Oct 2026). Registered once, by main().
class CardBackMemoryWatch with WidgetsBindingObserver {
  const CardBackMemoryWatch();

  @override
  void didHaveMemoryPressure() => CardBackImages.release();
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
/// The bundled Royal Fox ([PlayingCard.backAsset]) is drawn for null and —
/// at a table, where a card always shows a back — while [art]'s picture is
/// coming and when it cannot be had ([standIn]); it is tried again on the
/// picture boxes' clock. A back seen before paints on the first frame
/// ([CardBackImages.peek]); a new one swaps in when it arrives, from any
/// card's asking; a card whose back CHANGES keeps the one it had until the
/// new one is ready.
///
/// [height] sizes the card (it is `height * PlayingCard.aspect` wide); left
/// null, the largest card that fits the space it is given is drawn, centred.
class CardBackImage extends StatefulWidget {
  const CardBackImage({
    super.key,
    this.art,
    this.height,
    this.tint,
    this.standIn = true,
    this.loading,
  });

  /// The back to show; null for the Royal Fox.
  final CardBackArt? art;
  final double? height;
  final Color? tint;

  /// Whether the Royal Fox stands in for [art] while its picture is not here
  /// — still coming, or not to be had: the table's way (the default), where
  /// a card always shows a back.
  ///
  /// False is the store's (review, 3 Oct 2026): a tile or a question that
  /// SELLS [art] must never show another back in its place — "Brutal Demon
  /// · 5 hammers" over the Royal Fox, which is the shelf's first tile, sold
  /// the fox. There the plain back stands in, its black ground on the stock,
  /// with [loading] over it while the picture can still come.
  final bool standIn;

  /// What stands over the plain back that stands in for [art] (`standIn:
  /// false`) while its picture can still come ([CardBackImages.canFetch]):
  /// the game's ring, on a shelf tile and in a question. Nothing once the
  /// picture cannot be had, and nothing while it shows.
  final Widget? loading;

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
  /// Fox or the plain back ([CardBackImage.standIn]) — or the back already
  /// shown, when it is another that the card is changing from — while it is
  /// fetched and decoded.
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
        // Not to be had: the Royal Fox (or the plain back) rather than
        // somebody else's back, and another try later — unless nothing could
        // ever fetch it.
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
    final wanted = widget.art;
    final Widget picture;
    if (image != null && _shown != null) {
      picture = CustomPaint(
        size: Size(w, h),
        painter: _CardBackPainter(picture: CardBackPicture(image), tint: tint),
      );
    } else if (wanted != null && !widget.standIn) {
      // The store's stand-in: the plain back — never another back in the
      // place of the one on sale — under its ring while the picture can
      // still come.
      final loading = widget.loading;
      picture = SizedBox(
        width: w,
        height: h,
        child: loading != null && CardBackImages.canFetch(wanted)
            ? Center(child: loading)
            : null,
      );
    } else {
      picture = _royalFoxPicture(h, tint: tint);
    }
    return _onBackStock(h, picture);
  }
}

/// The bundled Royal Fox's picture for a card [height] tall, as wide as the
/// card, recoloured by [tint] as any back is ([BlendMode.color]).
Widget _royalFoxPicture(double height, {Color? tint}) => Image.asset(
  PlayingCard.backAsset,
  fit: BoxFit.cover,
  width: height * PlayingCard.aspect,
  height: height,
  color: tint,
  colorBlendMode: tint == null ? null : BlendMode.color,
  // Drawn at a fraction of its size on every card: smoothed, so its gold
  // filigree does not shimmer as the card moves.
  filterQuality: FilterQuality.medium,
  gaplessPlayback: true,
  excludeFromSemantics: true,
);

/// [picture] printed on a back's stock, for a card [height] tall: the back's
/// black ground under it, cut to the card's corner, and the stock's finish
/// over it — the top edge's light and the gold cut edge
/// ([CardStockPainter]).
Widget _onBackStock(double height, Widget picture) => CustomPaint(
  foregroundPainter: CardStockPainter(height: height, face: false),
  child: ClipRRect(
    borderRadius: BorderRadius.circular(height * PlayingCard.cornerShare),
    child: ColoredBox(color: PlayingCard.backGround, child: picture),
  ),
);

/// The Royal Fox — the bundled default back — as a glyph (owner, 3 Oct 2026:
/// "show default card icon also in store"): a tiny upright card printed as
/// every face-down card is, its corner cut and its gold edge round it,
/// standing in a square [size] on a side — the box an [Icon] of [size]
/// takes, so it stands where one would, as the store's Cards key and the
/// Cards shelf's header show it. The card is [size] tall and
/// [PlayingCard.aspect] as wide, centred.
///
/// Drawn as itself whatever is round it: never tinted, so a key that lights
/// up and dims shows the same card on and off.
class RoyalFoxGlyph extends StatelessWidget {
  const RoyalFoxGlyph({super.key, required this.size});

  /// The square's side, and the card's height.
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Center(child: _onBackStock(size, _royalFoxPicture(size))),
  );
}

/// [CardBackImage]'s picture, once decoded: the card stretched over the whole
/// box.
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
