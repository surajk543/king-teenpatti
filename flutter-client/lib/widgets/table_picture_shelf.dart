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
/// Background (1:1) and Background Pattern (3:2) lose nothing that matters. A
/// banner or a column is fitted whole: Welcome is one word on a 428×123
/// canvas (owner, 16 Sep 2026), and cropped to the square it was two letters.
/// The art decides, not the box; a file whose canvas is unknown covers.
BoxFit pictureFitFor(double? aspect) =>
    aspect != null && (aspect > 1.6 || aspect < 1 / 1.6) ? BoxFit.contain : BoxFit.cover;

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
class TablePictureGround extends StatelessWidget {
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

  /// The absolute URL to draw, or null for the table as it comes.
  final String? url;
  final String? format;

  /// See [backdropStrength].
  final double strength;

  @override
  Widget build(BuildContext context) {
    final link = url;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: Motion.base,
        child: link == null
            ? const SizedBox.expand(key: ValueKey('bare'))
            : ShaderMask(
                key: ValueKey(link),
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => RadialGradient(
                  // Out to the rim of the inscribed circle: the corners of
                  // the square are past it and fully clear, so nothing
                  // straight-edged is ever drawn.
                  radius: 0.5,
                  colors: [
                    Colors.white.withValues(alpha: strength.clamp(0.0, 1.0)),
                    Colors.white.withValues(alpha: 0),
                  ],
                  stops: const [featherFrom, 1],
                ).createShader(rect),
                // A Lottie plays: the motion is what it was bought for.
                child: CachedPictureBox(url: link, format: format, animate: true),
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
class _SplitGround extends StatelessWidget {
  const _SplitGround();

  @override
  Widget build(BuildContext context) => const Row(
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
        // The real thing, at the strength the table draws it.
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
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: Space.md,
      runSpacing: Space.md,
      children: [
        TablePictureChoice.flowingChips(
          width: width,
          selected: laid == null,
          onTap: () => state.chooseTablePicture(null),
        ),
        for (final p in pictures)
          TablePictureChoice(
            picture: p,
            width: width,
            selected: laid == p.id,
            busy: state.buyingTablePicture == p.id,
            // A locked table asks to be bought; an owned one is laid. There is
            // no "already unlocked" stop here as the face shelf has: the tile
            // carries the time left, and laying a table costs nothing.
            onTap: () => p.locked
                ? unlockTablePicture(context, p, openStore: openStore)
                : state.chooseTablePicture(p.id),
          ),
      ],
    ),
  );
}

/// One tile of the Tables shelf: the split preview, the name, and the tag
/// that says what tapping it does — a price, the time left, or that it is the
/// one in use.
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.read<GameState>();
    final t = state.t;
    final p = picture;
    final locked = p?.locked ?? false;
    // The tile is a table: wider than tall, the felt's own proportions.
    final previewH = width * 0.56;
    final ring = selected
        ? AppTheme.goldBright
        : (p != null && !p.free && !locked)
        ? theme.colorScheme.primary
        : AppTheme.hairlineColour(theme.brightness);

    final Widget preview = p == null
        ? _DefaultPreview(radius: Radii.md - 2)
        : TablePicturePreview(
            dayUrl: state.absoluteUrl(p.dayUrl) ?? '',
            nightUrl: state.absoluteUrl(p.nightUrl) ?? '',
            format: p.assetFormat,
            radius: Radii.md - 2,
          );

    return PressScale(
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
              Container(
                height: previewH,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.md),
                  border: Border.all(color: ring, width: selected ? 2.5 : 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.shadowFor(theme.brightness).withValues(
                        alpha: theme.brightness == Brightness.dark ? 0.45 : 0.16,
                      ),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
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
              const SizedBox(height: Space.xs),
              if (!busy && selected)
                _InUseTag(label: t.tableInUse)
              else if (!busy && p != null && locked)
                PriceTag(
                  cost: p.cost,
                  currency: p.currency,
                  days: p.rented ? p.durationDays : null,
                  hours: p.durationHours,
                )
              else if (!busy && p != null && !p.free)
                UnlockedTag(expiresAt: p.expiresAt),
              if (!busy && (selected || (p != null && (locked || !p.free))))
                const SizedBox(height: Space.xxs),
              Text(
                p?.name ?? t.tableDefault,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  height: 1.1,
                  color: theme.colorScheme.onSurface.withValues(
                    alpha: selected ? AppTheme.inkHigh : AppTheme.inkMed,
                  ),
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              if (p == null)
                Text(
                  t.tableDefaultHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9,
                    height: 1.1,
                    color: theme.colorScheme.onSurface.withValues(
                      alpha: AppTheme.inkLow,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The mark on the tile whose picture is on the table now, in the price tag's
/// shape so the eye reads the swap.
class _InUseTag extends StatelessWidget {
  const _InUseTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.xs,
        vertical: Space.xxs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        color: AppTheme.gold.withValues(alpha: 0.18),
        border: Border.all(color: AppTheme.goldBright.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_rounded, size: 9, color: AppTheme.goldBright),
          const SizedBox(width: 2),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppTheme.goldBright,
              fontWeight: FontWeight.w700,
              fontSize: 9,
              height: 1.1,
            ),
          ),
        ],
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

  if (state.screen == Screen.table && picture.currency == PictureCurrency.coin) {
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
    height: (MediaQuery.sizeOf(context).height * 0.42).clamp(160.0, 300.0) * 0.56,
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
