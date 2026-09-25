/// The table shelf (owner, 15 Sep 2026): the cloths a player lays on their own
/// table, sold on the store's Tables tab and drawn under the felt.
///
/// A table picture is a pair — a pale file for the light theme and a deep one
/// for the dark, since the ink on the table follows the theme — so a tile
/// shows both at once, split down the middle, and the felt draws whichever
/// the theme wants ([TablePictureGround]). Everything a locked tile does — the price
/// tag, the unlock question, the offer of a wallet's shelf — is the picture
/// shelf's, shared rather than copied, so the two can never disagree.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../net/picture_cache.dart';
import '../settings/feedback_settings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'chip_store.dart';
import 'drifting_chips.dart';
import 'glass_components.dart';
import 'glass_panels.dart';
import 'picture_shelf.dart';
import 'table_ground.dart' show TableGround;

/// One picture drawn to fill a box, from [PictureCache].
///
/// The seat's [Avatar] draws into a circle with its own two fallbacks; a table
/// picture fills a rectangle and, when it cannot be had, shows NOTHING — the
/// table as it comes is the right answer to a cloth that will not load, not a
/// placeholder over the whole felt. A picture already in memory paints on the
/// first frame.
class CachedPictureBox extends StatefulWidget {
  const CachedPictureBox({
    super.key,
    required this.url,
    this.format,
    this.animate = false,
  });

  /// Absolute. The caller has made a server-relative path loadable.
  final String url;

  /// 'IMAGE' | 'SVG' | 'LOTTIE' | 'RIVE' when known; null lets the bytes say.
  final String? format;

  /// Whether a Lottie plays. A cloth under a whole table repaints every seat
  /// over it, so a moving one is opted into, never on by default.
  final bool animate;

  @override
  State<CachedPictureBox> createState() => _CachedPictureBoxState();
}

/// How a picture fills a box it does not match. A canvas near enough square
/// covers the box, cropped at the sides or the top and bottom — Lines
/// Background (1:1), Background Pattern (3:2) and Circle Background Pattern
/// (16:9, a scene of three circles whose middle one the square keeps whole)
/// lose nothing that matters. A banner or a column is fitted whole: Welcome
/// is one word on a 428×123 canvas (owner, 16 Sep 2026), and cropped to the
/// square it was two letters. The line is [TablePictureGround.bannerAspect],
/// 2:1 since 24 Sep 2026 (1.6:1 before, which would have made the 16:9 scene
/// a strip). The art decides, not the box; a file whose canvas is unknown
/// covers.
BoxFit pictureFitFor(double? aspect) =>
    aspect != null &&
        (aspect > TablePictureGround.bannerAspect ||
            aspect < 1 / TablePictureGround.bannerAspect)
    ? BoxFit.contain
    : BoxFit.cover;

/// How long a picture fetch that failed waits before its [attempt]th retry:
/// 4 s, 8 s, 16 s, then every 30 s. A phone that was offline for a moment, or
/// a host that would not hand the file out just then, gets another go without
/// hammering it — and without the felt staying bare for the whole sitting.
Duration pictureRetryDelay(int attempt) =>
    Duration(seconds: math.min(30, 4 << math.min(attempt, 3)));

class _CachedPictureBoxState extends State<CachedPictureBox> {
  Uint8List? _bytes;

  /// The retry armed after a failed fetch, and how many have failed in a row.
  Timer? _retry;
  int _failures = 0;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant CachedPictureBox old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.format != widget.format) {
      _retry?.cancel();
      _failures = 0;
      _bytes = null;
      _resolve();
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  void _resolve() {
    if (widget.format == 'RIVE') return;
    final ready = PictureCache.peek(widget.url);
    if (ready != null) {
      _bytes = ready;
      return;
    }
    final wanted = widget.url;
    PictureCache.load(wanted).then((bytes) {
      if (!mounted || wanted != widget.url) return;
      if (bytes == null) {
        // Nothing came (offline, or a page in place of the file, which the
        // cache refuses): try again later rather than staying blank for
        // good — the box never retried until 23 Sep 2026.
        _retry = Timer(pictureRetryDelay(_failures++), () {
          if (mounted && wanted == widget.url) _resolve();
        });
        return;
      }
      _failures = 0;
      setState(() => _bytes = bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) return const SizedBox.expand();
    const nothing = SizedBox.expand();
    return switch (pictureKindOf(widget.format, bytes)) {
      PictureKind.lottie => Lottie.memory(
        bytes,
        fit: pictureFitFor(lottieCanvasAspect(bytes)),
        animate: widget.animate,
        repeat: widget.animate,
        errorBuilder: (_, _, _) => nothing,
      ),
      PictureKind.svg => SvgPicture.memory(
        bytes,
        fit: BoxFit.cover,
        placeholderBuilder: (_) => nothing,
        errorBuilder: (_, _, _) => nothing,
      ),
      PictureKind.unsupported => nothing,
      PictureKind.bitmap => Image.memory(
        bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => nothing,
      ),
    };
  }
}

/// The laid table picture as the table draws it: a small square centred on
/// the pot (owner, 15 Sep 2026 — first the whole room in place of the
/// flowing chips, then "at the centre of the pot, small, square"), in the file
/// the theme wants, over [TableGround]'s floor, which shows through a
/// transparent canvas. The caller sizes the square; nothing is drawn when no
/// picture is laid.
///
/// Its own repaint boundary: it changes only when the player changes it or
/// flips the theme, and the cross-fade between the two is the only motion it
/// ever makes — unless the picture is a Lottie, which plays.
///
/// Drawn at reduced strength (owner: "with opacity reduced") and with no edge
/// (owner: "not in a box — part of the background"): a radial fade takes the
/// picture from [backdropStrength] at its middle to nothing at its rim, so it
/// dissolves into the floor around the pot rather than sitting on it as a
/// tile. The mask is a `dstIn` [ShaderMask] over the square alone — an
/// offscreen pass the size of the square, not of the screen, which is what
/// makes it affordable under a playing Lottie.
///
/// A BANNER is the exception (23 Sep 2026, found on TP_Tall): a canvas wider
/// than [bannerAspect] fitted whole into the square is a thin strip exactly
/// where the pot plinth sits, and Welcome (428×123) showed as one stroke
/// peeking out from under "1,600". Such a picture is drawn across the
/// square's width in the band just above the plinth ([bannerLift]), faded at
/// its two ends instead of radially, so the whole word reads and the plinth
/// covers none of it. The aspect is read off the file's head once its bytes
/// are in the cache ([lottieCanvasAspect]; an SVG or a bitmap covers the
/// square and never takes this path).
class TablePictureGround extends StatefulWidget {
  const TablePictureGround({
    super.key,
    required this.url,
    this.format,
    this.strength = backdropStrength,
  });

  /// How much of the picture shows at its middle: 1 is the picture as drawn.
  /// 0.55 at first; 0.7, then 0.85 on 16 Sep 2026 (owner, twice: "increase
  /// the opacity a little bit of the table background animation", then "a
  /// little bit more").
  static const double backdropStrength = 0.85;

  /// Where the fade begins, as a fraction of the square's half-side: the
  /// middle is at full [strength] to here, then falls to nothing at the rim.
  static const double featherFrom = 0.35;

  /// A canvas wider than this is a banner, drawn above the plinth rather than
  /// under it. The same line [pictureFitFor] draws between covering the
  /// square and fitting the picture whole. 2:1 (24 Sep 2026; 1.6:1 before):
  /// a 16:9 canvas is a scene that crops to the square — Circle Background
  /// Pattern — while Welcome, at 3.5:1, is the banner this exists for.
  static const double bannerAspect = 2.0;

  /// Where a banner's middle sits in the square: -1 is the square's top edge,
  /// 0 its centre (the pot). -0.45 puts Welcome's whole word between the
  /// status line and the plinth's top edge on every phone the app is laid out
  /// for, the plinth's height being about a tenth of the felt's.
  static const double bannerLift = -0.45;

  /// The absolute URL to draw, or null for the table as it comes.
  final String? url;
  final String? format;

  /// See [backdropStrength].
  final double strength;

  @override
  State<TablePictureGround> createState() => _TablePictureGroundState();
}

class _TablePictureGroundState extends State<TablePictureGround> {
  /// The canvas's width over its height, once the file's head has been read;
  /// null until then, and for a file that does not say.
  double? _aspect;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  @override
  void didUpdateWidget(covariant TablePictureGround old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.format != widget.format) {
      _aspect = null;
      _measure();
    }
  }

  /// Reads the canvas off the cached bytes: at once when they are in memory,
  /// else when the fetch [CachedPictureBox] shares lands. A fetch that fails
  /// leaves the square, which is what the box draws then too — nothing.
  void _measure() {
    final url = widget.url;
    if (url == null || widget.format != 'LOTTIE') return;
    final ready = PictureCache.peek(url);
    if (ready != null) {
      _aspect = lottieCanvasAspect(ready);
      return;
    }
    PictureCache.load(url).then((bytes) {
      if (!mounted || url != widget.url || bytes == null) return;
      final aspect = lottieCanvasAspect(bytes);
      if (aspect != _aspect) setState(() => _aspect = aspect);
    });
  }

  @override
  Widget build(BuildContext context) {
    final link = widget.url;
    final strength = widget.strength.clamp(0.0, 1.0);
    final aspect = _aspect;
    final banner = aspect != null && aspect > TablePictureGround.bannerAspect;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: Motion.base,
        child: link == null
            ? const SizedBox.expand(key: ValueKey('bare'))
            : banner
            ? Align(
                key: ValueKey('$link:banner'),
                alignment: const Alignment(0, TablePictureGround.bannerLift),
                child: AspectRatio(
                  aspectRatio: aspect,
                  child: ShaderMask(
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (rect) => LinearGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0),
                        Colors.white.withValues(alpha: strength),
                        Colors.white.withValues(alpha: strength),
                        Colors.white.withValues(alpha: 0),
                      ],
                      stops: const [0, 0.18, 0.82, 1],
                    ).createShader(rect),
                    child: CachedPictureBox(
                      url: link,
                      format: widget.format,
                      animate: true,
                    ),
                  ),
                ),
              )
            : ShaderMask(
                key: ValueKey(link),
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => RadialGradient(
                  // Out to the rim of the inscribed circle: the corners of
                  // the square are past it and fully clear, so nothing
                  // straight-edged is ever drawn.
                  radius: 0.5,
                  colors: [
                    Colors.white.withValues(alpha: strength),
                    Colors.white.withValues(alpha: 0),
                  ],
                  stops: const [TablePictureGround.featherFrom, 1],
                ).createShader(rect),
                // A Lottie plays: the motion is what it was bought for.
                child: CachedPictureBox(
                  url: link,
                  format: widget.format,
                  animate: true,
                ),
              ),
      ),
    );
  }
}

/// A table picture as its tile shows it: the day file on the left half and
/// the night file on the right, one seam between them, so a player sees both
/// looks of the cloth before paying for either. Each half lies on the ground
/// its theme draws the game on — pale on the left, dark on the right — so a
/// picture with a transparent canvas previews as it will look, whatever
/// theme the store is open in.
class TablePicturePreview extends StatelessWidget {
  const TablePicturePreview({
    super.key,
    required this.dayUrl,
    required this.nightUrl,
    this.format,
    this.radius = Radii.md,
  });

  /// Absolute URLs.
  final String dayUrl;
  final String nightUrl;
  final String? format;
  final double radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth;
        final h = box.maxHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            const _SplitGround(),
            CachedPictureBox(url: dayUrl, format: format, animate: true),
            // The night file, drawn at the full size of the tile and clipped
            // to its right half, so the two halves are the same picture at
            // the same scale rather than two pictures squeezed side by side.
            Positioned(
              left: w / 2,
              top: 0,
              width: w / 2,
              height: h,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerRight,
                  minWidth: w,
                  maxWidth: w,
                  minHeight: h,
                  maxHeight: h,
                  child: CachedPictureBox(
                    url: nightUrl,
                    format: format,
                    animate: true,
                  ),
                ),
              ),
            ),
            Positioned(
              left: w / 2 - 0.5,
              top: 0,
              bottom: 0,
              width: 1,
              child: ColoredBox(color: Colors.white.withValues(alpha: 0.45)),
            ),
            // Which half is which, for the first time anyone sees one.
            Positioned(
              left: Space.xs,
              top: Space.xs,
              child: Icon(
                Icons.light_mode_rounded,
                size: 12,
                color: AppTheme.ink900.withValues(alpha: 0.55),
              ),
            ),
            Positioned(
              right: Space.xs,
              top: Space.xs,
              child: Icon(
                Icons.dark_mode_rounded,
                size: 12,
                color: Colors.white.withValues(alpha: 0.75),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// The two themes' grounds side by side — the light theme's pale floor on the
/// left, the dark theme's obsidian on the right — under every tile.
///
/// The row STRETCHES its halves: a childless DecoratedBox has no height of
/// its own, and with the default cross-axis alignment both grounds laid out
/// at zero height and painted nothing, so every tile's day half sat on the
/// store's own backdrop — dark in the dark theme, where black day art
/// (Lines Background, the sun glyph) all but vanished (found on the emulator,
/// 23 Sep 2026; test/table_pictures_test.dart holds the two halves to the
/// tile's height).
class _SplitGround extends StatelessWidget {
  const _SplitGround();

  @override
  Widget build(BuildContext context) => const Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppTheme.bone100, AppTheme.bone200],
            ),
          ),
        ),
      ),
      Expanded(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF0D0E12), Color(0xFF08080A)],
            ),
          ),
        ),
      ),
    ],
  );
}

/// The default background — the chips drifting across the room, which laying
/// no picture restores (owner, 15 Sep 2026: "give an option to restore the
/// default flowing chips background") — drawn as itself over the two themes'
/// grounds, split like every other tile.
class _DefaultPreview extends StatelessWidget {
  const _DefaultPreview({required this.radius});

  final double radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: Stack(
      fit: StackFit.expand,
      children: [
        const _SplitGround(),
        // The real thing, stronger than the room draws it now
        // (TableAmbient.roomChips), so a few chips still read on a tile.
        const IgnorePointer(child: DriftingChips(strength: 2.6)),
        Positioned(
          left: Space.xs,
          top: Space.xs,
          child: Icon(
            Icons.light_mode_rounded,
            size: 12,
            color: AppTheme.ink900.withValues(alpha: 0.55),
          ),
        ),
        Positioned(
          right: Space.xs,
          top: Space.xs,
          child: Icon(
            Icons.dark_mode_rounded,
            size: 12,
            color: Colors.white.withValues(alpha: 0.75),
          ),
        ),
      ],
    ),
  );
}

/// The order the shelf draws its tables in: the picture shelf's — free
/// first, then chips, hammers, diamonds, each wallet cheapest first, ties in
/// the catalogue's order.
List<TablePicture> tableShelfOrder(List<TablePicture> pictures) {
  int rank(TablePicture p) => p.free
      ? -1
      : switch (p.currency) {
          PictureCurrency.hammer => 1,
          PictureCurrency.diamond => 2,
          _ => 0,
        };
  final order = [for (var i = 0; i < pictures.length; i++) i]
    ..sort((i, k) {
      final a = pictures[i], b = pictures[k];
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      final byCost = a.cost.compareTo(b.cost);
      return byCost != 0 ? byCost : i.compareTo(k);
    });
  return [for (final i in order) pictures[i]];
}

/// The store's Tables shelf: the default background first — the flowing
/// chips, which a tap restores by laying no picture — then the catalogue.
///
/// [openStore] is how a shelf inside the store moves the store to the Hammers
/// or Diamonds shelf when a table's wallet is short, as the picture shelf
/// does.
Widget tablePictureShelf({
  required BuildContext context,
  required GameState state,
  required double width,
  ValueChanged<StoreTab>? openStore,
}) {
  final pictures = tableShelfOrder(state.tablePictures);
  final laid = state.user?.activeTablePictureId;
  return Padding(
    padding: const EdgeInsets.only(bottom: Space.md),
    child: ShelfGrid(
      tileWidth: width,
      children: [
        ShelfTileEntrance(
          key: const ValueKey('flowing-chips'),
          index: 0,
          child: TablePictureChoice.flowingChips(
            width: width,
            selected: laid == null,
            onTap: () => state.chooseTablePicture(null),
          ),
        ),
        for (final (i, p) in pictures.indexed)
          ShelfTileEntrance(
            key: ValueKey(p.id),
            index: i + 1,
            child: TablePictureChoice(
              picture: p,
              width: width,
              selected: laid == p.id,
              busy: state.buyingTablePicture == p.id,
              // A locked table asks to be bought; an owned one is laid. There
              // is no "already unlocked" stop here as the face shelf has: the
              // tile carries the time left, and laying a table costs nothing.
              onTap: () => p.locked
                  ? unlockTablePicture(context, p, openStore: openStore)
                  : state.chooseTablePicture(p.id),
            ),
          ),
      ],
    ),
  );
}

/// One tile of the Tables shelf (the store polish, 26 Sep 2026: "the preview
/// should be the primary focus"): the split preview, as wide as the tile and
/// framed by the one line that says its state in colour; under it the shelf's
/// badge — "In use" on the table's own picture, "Owned", or the padlock and
/// the price — the name, and the small print: a rental's term, the time left
/// on one, or what the default is. Built as the picture shelf's tile is, so
/// the two shelves read as one store.
class TablePictureChoice extends StatelessWidget {
  const TablePictureChoice({
    super.key,
    required TablePicture this.picture,
    required this.width,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  /// The tile for the default background, the flowing chips.
  const TablePictureChoice.flowingChips({
    super.key,
    required this.width,
    required this.selected,
    required this.onTap,
  }) : picture = null,
       busy = false;

  /// Null for the flowing-chips tile.
  final TablePicture? picture;
  final double width;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  /// The preview's height for a tile [width] wide: a table, wider than tall,
  /// the felt's own proportions.
  static double previewHeightFor(double width) => width * 0.56;

  /// The frame round the preview: its line, and the room between the line
  /// and the picture.
  static const double _frameGap = 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<GameState>();
    final t = state.t;
    final p = picture;
    final locked = p?.locked ?? false;
    final previewH = previewHeightFor(width);
    final gold = shelfGoldOn(theme.brightness);

    // The frame says what the badge says, in colour: gold round the table's
    // own picture, green round every one the player can lay now — the
    // default, a free one, one bought and still running — and the hairline
    // round the rest. The laid one's frame is heavier.
    final kind = locked
        ? ShelfBadgeKind.locked
        : selected
        ? ShelfBadgeKind.equipped
        : ShelfBadgeKind.owned;
    final (Color frame, double frameWidth) = switch (kind) {
      ShelfBadgeKind.equipped => (gold, 2.5),
      ShelfBadgeKind.owned => (shelfOwnedLine(theme), 1.5),
      ShelfBadgeKind.locked => (AppTheme.hairlineColour(theme.brightness), 1.5),
    };
    // The picture's corners run parallel to the frame's.
    final inner = Radii.md - frameWidth - _frameGap;

    final Widget preview = p == null
        ? _DefaultPreview(radius: inner)
        : TablePicturePreview(
            dayUrl: state.absoluteUrl(p.dayUrl) ?? '',
            nightUrl: state.absoluteUrl(p.nightUrl) ?? '',
            format: p.assetFormat,
            radius: inner,
          );

    final Widget badge = p != null && locked
        ? PriceTag(cost: p.cost, currency: p.currency)
        : ShelfBadge(
            kind: kind,
            label: selected ? t.tableInUse : t.pictureOwned,
          );
    // The small print: the default says what it is; a rental its term, or
    // what is left of it on the one the player holds.
    final String? detail = p == null
        ? t.tableDefaultHint
        : locked
        ? (p.rented ? t.rentalTerm(p.durationDays, p.durationHours) : null)
        : rentalTagLeft(t, p.expiresAt, DateTime.now());

    return PressScale(
      enabled: !busy,
      child: InkWell(
        enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: Motion.base,
                curve: Motion.standard,
                height: previewH,
                padding: const EdgeInsets.all(_frameGap),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border.all(color: frame, width: frameWidth),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.shadowFor(theme.brightness).withValues(
                        alpha: theme.brightness == Brightness.dark
                            ? 0.45
                            : 0.16,
                      ),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                    // The table's own picture stands in a soft gold light: a
                    // still one, as on the picture shelf.
                    if (selected) ...shelfGlow(gold, theme.brightness),
                  ],
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    preview,
                    if (busy)
                      Center(
                        child: SizedBox(
                          width: previewH * 0.4,
                          height: previewH * 0.4,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: Space.sm),
              ShelfBadgeSwitcher(kind: kind, child: badge),
              const SizedBox(height: Space.xs),
              // Two lines, as on the picture shelf: one cut "Circle
              // Background Pattern" to "Circle Background Patt…" on a 640dp
              // phone.
              Text(
                p?.name ?? t.tableDefault,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: shelfNameStyle(
                  theme,
                  theme.textTheme.labelMedium,
                  selected: selected,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: Space.xxs),
                ShelfDetail(text: detail, time: p != null),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The unlock question's sentence for a table: the price in its wallet's
/// word ([Strings.priceIn]) and, for a rental, the term.
String unlockTableBody(Strings t, TablePicture picture) {
  final cost = picture.pricedInHammers
      ? '${picture.cost}'
      : formatChips(picture.cost);
  final price = t.priceIn(picture.currency, cost);
  return picture.rented
      ? t.unlockTableRentBody(
          picture.name,
          price,
          t.rentalTerm(picture.durationDays, picture.durationHours),
        )
      : t.unlockTableBody(picture.name, price);
}

/// Asks before spending on a premium table picture, then buys and lays it —
/// [unlockPicture] for the table, with the same two answers before the
/// question: a chip-priced table tapped at a table is refused on the spot, and
/// one whose hammer or diamond wallet is short is offered that wallet's shelf.
Future<void> unlockTablePicture(
  BuildContext context,
  TablePicture picture, {
  ValueChanged<StoreTab>? openStore,
}) async {
  final state = context.read<GameState>();
  final t = state.t;
  final theme = Theme.of(context);

  if (state.screen == Screen.table &&
      picture.currency == PictureCurrency.coin) {
    state.say(t.tableChipsLobbyOnly);
    return;
  }
  final short = switch (picture.currency) {
    PictureCurrency.hammer => (state.user?.hammer ?? 0) < picture.cost,
    PictureCurrency.diamond => (state.user?.diamond ?? 0) < picture.cost,
    _ => false,
  };
  Widget offer() => SizedBox(
    width: (MediaQuery.sizeOf(context).height * 0.42).clamp(160.0, 300.0),
    height:
        (MediaQuery.sizeOf(context).height * 0.42).clamp(160.0, 300.0) * 0.56,
    child: TablePicturePreview(
      dayUrl: state.absoluteUrl(picture.dayUrl) ?? '',
      nightUrl: state.absoluteUrl(picture.nightUrl) ?? '',
      format: picture.assetFormat,
    ),
  );
  if (short) {
    await offerWalletShelf(
      context,
      name: picture.name,
      cost: picture.cost,
      currency: picture.currency,
      preview: offer(),
      openStore: openStore,
    );
    return;
  }
  final balance = walletBalanceFor(state, picture.currency);

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: Row(
        children: [
          Icon(Icons.lock_open, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              t.unlockTableTitle,
              style: AppTheme.label(
                theme.textTheme.titleMedium ?? const TextStyle(),
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          offer(),
          const SizedBox(height: Space.lg),
          Text(
            unlockTableBody(t, picture),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(
                alpha: AppTheme.inkMed,
              ),
            ),
          ),
          if (balance != null) ...[const SizedBox(height: Space.md), balance],
        ],
      ),
      actions: [
        GlassButton(
          style: GlassButtonStyle.text,
          label: t.cancel,
          onPressed: () => Navigator.pop(dialogContext, false),
        ),
        GlassButton(
          style: GlassButtonStyle.primary,
          label: t.unlock,
          onPressed: () => Navigator.pop(dialogContext, true),
        ),
      ],
    ),
  );

  if (confirmed != true) return;
  final result = await state.buyTablePicture(picture.id);
  if (result == PictureBuyResult.notEnough && context.mounted) {
    await offerWalletShelf(
      context,
      name: picture.name,
      cost: picture.cost,
      currency: picture.currency,
      preview: offer(),
      openStore: openStore,
    );
  }
}
