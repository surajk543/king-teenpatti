/// The table's host: an illustrated casino host standing behind the far rail,
/// and the few quiet movements she makes (owner's brief, 24 Sep 2026: "an
/// elegant female dealer/host ... a visual host rather than a playable
/// character").
///
/// Three pieces, each usable alone:
///
/// * [DealerState] and [dealerStateFor] — what she is doing, read from what
///   the table already shows. Nothing here decides anything about the game.
/// * [DealerArt] — the artwork contract: ONE SVG whose top-level groups are
///   her layers, so a commissioned illustration replaces the file and nothing
///   else.
/// * [DealerHost] — the widget: her layers, rendered once into images and
///   moved by one ticker.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/theme_colors.dart';

// ------------------------------------------------------------------- states

/// What the host is doing.
enum DealerState {
  /// Nothing needs her: she breathes and, now and then, blinks.
  idle,

  /// A new hand has begun: a small nod as she squares the deck.
  newHand,

  /// The cards are in the air: her right hand deals.
  dealing,

  /// The viewer is on turn: she turns to them, and the light behind her and
  /// on the near rail warms.
  yourTurn,

  /// A hand has been won: a short lift, a brighter light and a few sparks.
  win,
}

/// The host's timings, in one place.
abstract final class DealerTiming {
  /// How long a new hand's nod lasts before she deals.
  static const Duration newHand = Duration(milliseconds: 450);

  /// How long a change of state takes to blend into the next, so she never
  /// snaps from one pose to another.
  static const Duration blend = Duration(milliseconds: 280);

  /// The win's lift and sparks; she holds a warm light after it for as long
  /// as the celebration lasts.
  static const Duration win = Duration(milliseconds: 1600);
}

/// What the host does, from what the table shows — read-only, and in this
/// order of precedence:
///
/// * [DealerState.win] while a hand's result is being celebrated;
/// * [DealerState.newHand] for [DealerTiming.newHand] after the hand number
///   changes at the same table ([sinceNewHand]);
/// * [DealerState.dealing] from then until the deal's cards have landed
///   ([dealLength], zero when no cards are flown — the first hand after
///   sitting down at a fresh table, as `DealFlights` has it);
/// * [DealerState.yourTurn] while the viewer is on turn;
/// * [DealerState.idle] otherwise.
///
/// The deal itself starts with the new hand: its first cards leave her hands
/// while she nods, which is what a dealer does.
DealerState dealerStateFor({
  required bool celebrating,
  required bool myTurn,
  Duration? sinceNewHand,
  Duration dealLength = Duration.zero,
}) {
  if (celebrating) return DealerState.win;
  if (sinceNewHand != null && !sinceNewHand.isNegative) {
    if (sinceNewHand < DealerTiming.newHand) return DealerState.newHand;
    if (sinceNewHand < dealLength) return DealerState.dealing;
  }
  if (myTurn) return DealerState.yourTurn;
  return DealerState.idle;
}

// ------------------------------------------------------------------ artwork

/// The host's artwork contract: one SVG file, split into layers by its
/// top-level groups.
///
/// **To replace her** (a commissioned illustration, say), export an SVG and
/// point [defaultAsset] — or [DealerHost.asset] — at it. What the file must
/// say:
///
/// * `viewBox` on the root element: the canvas. Leave room above her head
///   and at her sides for the lift, the tilt and the sparks.
/// * `data-rim-y` on the root element: the height, in viewBox units, of the
///   table's far rail — everything below it stands behind the table and is
///   never seen. Absent, it is [defaultRimShare] of the canvas down.
/// * Her layers as top-level `<g id="…">` groups, in paint order, drawn in
///   place on the one canvas: [hairBack], [body], [armRight], [armLeft],
///   [head], [eyes] and [card]. Each may carry `data-pivot="x y"`, the point
///   it turns about in viewBox units (the neck for the head, an elbow for an
///   arm, the eye line for the eyes). Any other `host-…` group is drawn with
///   the body; a missing layer simply does not move. A file with no `host-…`
///   group at all is drawn whole as [body]: she then breathes, lifts and
///   glows but does not turn her head or deal.
/// * `<defs>` (gradients, clip paths) are shared by every layer.
/// * Only what `flutter_svg` draws: paths and shapes, linear and radial
///   gradients, clip paths, opacity. No filters or blurs; a raster is
///   embedded as a data-URI `<image>`.
///
/// She is fitted into the slot the table gives her standing on its bottom
/// edge, which is where [DealerHost] puts `data-rim-y`; a canvas of another
/// shape than [boxAspect] is fitted whole inside it.
abstract final class DealerArt {
  /// The artwork the table uses: an original illustration made for this game
  /// (24 Sep 2026), drawn by hand in `flutter_svg`'s subset.
  static const String defaultAsset = 'assets/dealer/host.svg';

  /// Her layers' group ids.
  static const String hairBack = 'host-hair-back';
  static const String body = 'host-body';
  static const String armRight = 'host-arm-right';
  static const String armLeft = 'host-arm-left';
  static const String head = 'host-head';
  static const String eyes = 'host-eyes';
  static const String card = 'host-card';

  /// Where the rail meets her when the file does not say, as a share of the
  /// canvas down from its top.
  static const double defaultRimShare = 0.83;

  /// The slot's width for each unit of its height: the default artwork's
  /// canvas above its rim line.
  static const double boxAspect = 0.8;

  static final Map<String, DealerArtwork> _loaded = {};
  static final Map<String, Future<DealerArtwork>> _loading = {};

  /// The artwork at [asset] if it has already loaded, so a table opened
  /// again draws her in its first frame rather than a frame after.
  static DealerArtwork? loaded(String asset) => _loaded[asset];

  /// The artwork at [asset], parsed and drawn into pictures once for the
  /// life of the app. A file that fails to load is not kept, so a later
  /// table tries again.
  static Future<DealerArtwork> load(String asset, {AssetBundle? bundle}) {
    final done = _loaded[asset];
    if (done != null) return SynchronousFuture(done);
    return _loading.putIfAbsent(asset, () async {
      try {
        final source = await (bundle ?? rootBundle).loadString(asset);
        final art = parseDealerArt(source);
        for (final layer in art.layers) {
          layer.picture = await vg.loadPicture(
            SvgStringLoader(layer.svg),
            null,
          );
        }
        _loaded[asset] = art;
        return art;
      } finally {
        _loading.remove(asset);
      }
    });
  }

  /// Drops every loaded artwork (tests).
  @visibleForTesting
  static void clearCache() {
    _loaded.clear();
    _loading.clear();
  }
}

/// A host artwork, split into the layers she is animated by.
class DealerArtwork {
  DealerArtwork({
    required this.viewBox,
    required this.rimY,
    required this.layers,
  });

  /// The canvas, in the file's own units.
  final Rect viewBox;

  /// The height the table's far rail meets her at.
  final double rimY;

  /// Her layers, in paint order.
  final List<DealerLayer> layers;

  /// The canvas above the rim: what is ever seen of her.
  Rect get visible => Rect.fromLTRB(
    viewBox.left,
    viewBox.top,
    viewBox.right,
    rimY.clamp(viewBox.top + 1, viewBox.bottom),
  );

  DealerLayer? layer(String id) {
    for (final l in layers) {
      if (l.id == id) return l;
    }
    return null;
  }
}

/// One layer of the host: a standalone SVG of that group alone on the whole
/// canvas, and the point it turns about.
class DealerLayer {
  DealerLayer({required this.id, required this.svg, this.pivot});

  final String id;
  final String svg;
  final Offset? pivot;

  /// The layer drawn, once it has loaded.
  PictureInfo? picture;
}

final RegExp _svgOpen = RegExp(r'<svg\b[^>]*>');
final RegExp _defs = RegExp(r'<defs\b[\s\S]*?</defs>');
final RegExp _layerOpen = RegExp(
  r'<g\b[^>]*\bid\s*=\s*"(host-[A-Za-z0-9_-]+)"[^>]*>',
);
final RegExp _groupTag = RegExp(r'<(/?)g\b[^>]*?(/?)>');

String? _attr(String tag, String name) => RegExp(
  '(?:^|\\s)${RegExp.escape(name)}\\s*=\\s*"([^"]*)"',
).firstMatch(tag)?.group(1);

List<double> _numbers(String text) => [
  for (final part in text.trim().split(RegExp(r'[\s,]+')))
    if (part.isNotEmpty) double.parse(part),
];

/// Splits a host SVG into her layers (see [DealerArt] for what the file must
/// say). Pure, for tests.
DealerArtwork parseDealerArt(String source) {
  final root = _svgOpen.firstMatch(source);
  if (root == null) {
    throw const FormatException('dealer art: no <svg> element');
  }
  final rootTag = root.group(0)!;

  final Rect viewBox;
  final box = _attr(rootTag, 'viewBox');
  if (box != null) {
    final n = _numbers(box);
    if (n.length != 4 || n[2] <= 0 || n[3] <= 0) {
      throw FormatException('dealer art: bad viewBox "$box"');
    }
    viewBox = Rect.fromLTWH(n[0], n[1], n[2], n[3]);
  } else {
    final w = double.tryParse(_attr(rootTag, 'width') ?? '');
    final h = double.tryParse(_attr(rootTag, 'height') ?? '');
    if (w == null || h == null || w <= 0 || h <= 0) {
      throw const FormatException('dealer art: no viewBox and no size');
    }
    viewBox = Rect.fromLTWH(0, 0, w, h);
  }
  final rimY =
      double.tryParse(_attr(rootTag, 'data-rim-y') ?? '') ??
      viewBox.top + viewBox.height * DealerArt.defaultRimShare;

  // Each layer is the whole canvas with only its own group on it, so every
  // layer lands exactly where it was drawn. The namespaces come along, for an
  // `<image xlink:href>`.
  final namespaces = RegExp(
    r'''\sxmlns(?::[\w-]+)?\s*=\s*"[^"]*"''',
  ).allMatches(rootTag).map((m) => m.group(0)!).join();
  final open =
      '<svg$namespaces viewBox="${viewBox.left} ${viewBox.top} '
      '${viewBox.width} ${viewBox.height}" width="${viewBox.width}" '
      'height="${viewBox.height}">';
  final fixedOpen = namespaces.contains('xmlns=')
      ? open
      : open.replaceFirst('<svg', '<svg xmlns="http://www.w3.org/2000/svg"');
  final defs = _defs.allMatches(source).map((m) => m.group(0)!).join();

  final end = source.lastIndexOf('</svg>');
  final body = source.substring(root.end, end < 0 ? source.length : end);

  final layers = <DealerLayer>[];
  var cursor = 0;
  for (final start in _layerOpen.allMatches(body)) {
    if (start.start < cursor) continue; // inside a layer already taken
    var depth = 1;
    var close = -1;
    for (final tag in _groupTag.allMatches(body, start.end)) {
      if (tag.group(1) == '/') {
        depth--;
        if (depth == 0) {
          close = tag.end;
          break;
        }
      } else if (tag.group(2) != '/') {
        depth++;
      }
    }
    if (close < 0) {
      throw FormatException('dealer art: <g id="${start.group(1)}"> unclosed');
    }
    final pivot = _attr(start.group(0)!, 'data-pivot');
    final p = pivot == null ? null : _numbers(pivot);
    layers.add(
      DealerLayer(
        id: start.group(1)!,
        svg: '$fixedOpen$defs${body.substring(start.start, close)}</svg>',
        pivot: p != null && p.length == 2 ? Offset(p[0], p[1]) : null,
      ),
    );
    cursor = close;
  }

  // A flat illustration: the whole drawing is her body.
  if (layers.isEmpty) {
    layers.add(
      DealerLayer(
        id: DealerArt.body,
        svg: '$fixedOpen$defs${body.replaceAll(_defs, '')}</svg>',
      ),
    );
  }
  return DealerArtwork(viewBox: viewBox, rimY: rimY, layers: layers);
}

// -------------------------------------------------------------------- poses

/// One moment of the host: how far each layer has moved from where it was
/// drawn. Lengths are in the artwork's units, angles in radians (positive
/// turns clockwise on screen).
@immutable
class DealerPose {
  const DealerPose({
    this.breath = 0,
    this.lift = 0,
    this.headTilt = 0,
    this.headNod = 0,
    this.lookX = 0,
    this.lookY = 0,
    this.lid = 1,
    this.armRight = 0,
    this.armLeft = 0,
    this.card = 0,
    this.cardTurn = 0,
    this.halo = 0,
    this.haloTurn = 0,
    this.haloWin = 0,
    this.sparkle = -1,
  });

  /// Her breath, -1..1: the chest rises and falls about the waist.
  final double breath;

  /// How far she is lifted, up.
  final double lift;

  /// Her head's tilt about the neck, and how far it dips.
  final double headTilt;
  final double headNod;

  /// Where her eyes are looking, from straight ahead.
  final double lookX;
  final double lookY;

  /// How open her eyes are: 1 open, about 0.1 in a blink.
  final double lid;

  /// Each forearm's turn about its elbow. The right hand (the viewer's left)
  /// rises as its angle goes negative, the left as its angle goes positive.
  final double armRight;
  final double armLeft;

  /// How much of the card in her right hand shows (0..1), and its turn.
  final double card;
  final double cardTurn;

  /// The light behind her: at rest, on the viewer's turn and at a win, each
  /// 0..1 over the theme's colours.
  final double halo;
  final double haloTurn;
  final double haloWin;

  /// The win's sparks, 0..1 through their flight, or below 0 for none.
  final double sparkle;

  DealerPose lerp(DealerPose b, double t) {
    double l(double x, double y) => x + (y - x) * t;
    return DealerPose(
      breath: l(breath, b.breath),
      lift: l(lift, b.lift),
      headTilt: l(headTilt, b.headTilt),
      headNod: l(headNod, b.headNod),
      lookX: l(lookX, b.lookX),
      lookY: l(lookY, b.lookY),
      lid: l(lid, b.lid),
      armRight: l(armRight, b.armRight),
      armLeft: l(armLeft, b.armLeft),
      card: l(card, b.card),
      cardTurn: l(cardTurn, b.cardTurn),
      halo: l(halo, b.halo),
      haloTurn: l(haloTurn, b.haloTurn),
      haloWin: l(haloWin, b.haloWin),
      // The sparks belong to the win alone; they never fade in from another
      // state.
      sparkle: t < 1 && b.sparkle >= 0 && sparkle < 0 ? -1 : b.sparkle,
    );
  }
}

double _wave(double seconds, double period) =>
    math.sin(2 * math.pi * seconds / period);

/// 0 → 1 → 0 over [p] in 0..1.
double _bump(double p) => math.sin(math.pi * p.clamp(0.0, 1.0));

/// The host's pose in [state], [inState] seconds after it began, at [clock]
/// seconds on the room's clock (which paces the breath and the blinks).
/// [still] freezes everything that loops — the breath, the blinks, the sways
/// — for a player who has asked the phone for less motion. Pure, for tests.
DealerPose dealerPose(
  DealerState state, {
  required double inState,
  required double clock,
  bool still = false,
}) {
  final breath = still ? 0.0 : _wave(clock, 4.2);
  // A blink every few seconds, on an uneven beat so it never reads as a
  // metronome: 150 ms, closing and opening.
  var lid = 1.0;
  if (!still) {
    const beats = [4.3, 5.9, 3.7, 6.6];
    const cycle = 4.3 + 5.9 + 3.7 + 6.6;
    var t = clock % cycle;
    for (final beat in beats) {
      if (t < beat) break;
      t -= beat;
    }
    if (t < 0.15) lid = 1 - 0.88 * _bump(t / 0.15);
  }
  final sway = still ? 0.0 : _wave(clock, 11);

  switch (state) {
    case DealerState.idle:
      return DealerPose(
        breath: breath,
        lid: lid,
        headTilt: -0.012 + 0.009 * sway,
      );
    case DealerState.newHand:
      final p = (inState / (DealerTiming.newHand.inMilliseconds / 1000)).clamp(
        0.0,
        1.0,
      );
      final nod = _bump(p);
      return DealerPose(
        breath: breath,
        lid: lid,
        headTilt: -0.012,
        headNod: 1.6 * nod,
        lookY: 0.4 * nod,
        armRight: 0.05 * nod,
        armLeft: -0.05 * nod,
        card: p,
        halo: 0.5 * nod,
      );
    case DealerState.dealing:
      // A deal's rhythm: the right hand lifts and flicks about twice a
      // second, the card riding in it, her eyes on the table.
      final f = (inState * 2.1) % 1;
      final flick = 0.5 - 0.5 * math.cos(2 * math.pi * f);
      return DealerPose(
        breath: breath,
        lid: lid,
        headTilt: -0.02,
        headNod: 0.9,
        lookX: -0.25,
        lookY: 0.55,
        armRight: -0.03 - 0.11 * flick,
        armLeft: 0.015,
        card: 1,
        cardTurn: -0.35 * flick,
        halo: 0.25,
      );
    case DealerState.yourTurn:
      // Turned to the viewer, who sits to her right (the bottom left of the
      // screen): her head leans that way, her eyes follow, and the light
      // behind her warms on a slow pulse.
      final pulse = still ? 0.0 : _wave(clock, 2.4);
      return DealerPose(
        breath: breath,
        lid: lid,
        headTilt: -0.05 + 0.006 * sway,
        headNod: 0.5,
        lookX: -0.75,
        lookY: 0.35,
        halo: 0.4,
        haloTurn: 0.8 + 0.2 * pulse,
      );
    case DealerState.win:
      final lift = _bump(inState / 0.7);
      final clap = _bump(inState / 0.5);
      final fade = (inState / (DealerTiming.win.inMilliseconds / 1000)).clamp(
        0.0,
        1.0,
      );
      return DealerPose(
        breath: breath,
        lid: lid,
        lift: 2.4 * lift,
        headTilt: 0.035 * _bump(inState / 0.9),
        armRight: -0.09 * clap,
        armLeft: 0.09 * clap,
        halo: 0.6,
        haloWin: 1 - 0.45 * fade,
        sparkle: fade < 1 ? fade : -1,
      );
  }
}

// ------------------------------------------------------------------ layout

/// Whether the table shows its host. On unless a build says otherwise
/// (`--dart-define=DEALER_HOST=false`), which leaves the table exactly as it
/// is with nobody behind it.
const bool dealerHostEnabled = bool.fromEnvironment(
  'DEALER_HOST',
  defaultValue: true,
);

/// The rules the host's box is sized by (owner's brief: "approximately
/// 15–20% of screen height ... never cover player cards; never cover action
/// buttons ... Gameplay always has priority over decoration").
abstract final class DealerSlot {
  /// The air she keeps from the tag over her head and from the widest speech
  /// bubble either top seat can open.
  static const double margin = 6;

  /// Below this height she is not drawn at all: her face would be a few
  /// pixels across, and decoration goes first.
  static const double minHeight = 36;

  /// The most of the screen's height her box may take — on a tablet, where
  /// the gap over the table is larger than a host should be.
  static const double maxShare = 0.16;
}

/// The box the host stands in, in the felt's coordinates: centred on a felt
/// [feltWidth] wide, standing on the table's far rail at [rimTop], its top no
/// higher than [top] (the foot of the category tag) and its sides inside
/// [left]..[right] (what the top seats and their widest speech bubbles leave
/// free) — as tall as that allows, up to [DealerSlot.maxShare] of
/// [screenHeight]. Null when the box would be under [DealerSlot.minHeight]:
/// on a phone that short the table has no room to spare for her. Pure, for
/// tests.
Rect? dealerSlot({
  required double feltWidth,
  required double top,
  required double rimTop,
  required double left,
  required double right,
  required double screenHeight,
}) {
  final cx = feltWidth / 2;
  final halfFree = math.min(cx - left, right - cx) - DealerSlot.margin;
  var height = math.min(
    rimTop - top - DealerSlot.margin,
    screenHeight * DealerSlot.maxShare,
  );
  height = math.min(height, 2 * halfFree / DealerArt.boxAspect);
  if (!height.isFinite || height < DealerSlot.minHeight) return null;
  final width = height * DealerArt.boxAspect;
  return Rect.fromLTWH(cx - width / 2, rimTop - height, width, height);
}

// ------------------------------------------------------------------ widget

/// The host, standing on the bottom edge of the box she is given.
///
/// Her layers are loaded once for the app ([DealerArt.load]) and rendered
/// once into images at the size she is shown; after that a frame is a
/// handful of those images drawn at small offsets, so the one ticker that
/// moves her costs almost nothing, and her layer repaints alone
/// ([RepaintBoundary]). A player who asks the phone for less motion gets her
/// still ([MediaQueryData.disableAnimations]), turning only between states.
class DealerHost extends StatefulWidget {
  const DealerHost({
    super.key,
    required this.state,
    this.asset = DealerArt.defaultAsset,
  });

  final DealerState state;

  /// The artwork (see [DealerArt] for the contract a replacement meets).
  final String asset;

  @override
  State<DealerHost> createState() => _DealerHostState();
}

class _DealerHostState extends State<DealerHost>
    with SingleTickerProviderStateMixin {
  /// Made in initState, never lazily (CLAUDE.md §12.3).
  late final Ticker _ticker;

  /// The room's clock in seconds, which the painter listens to.
  final ValueNotifier<double> _clock = ValueNotifier(0);

  DealerArtwork? _art;

  /// When the artwork arrived on the room's clock, if it arrived after she
  /// was first built; she fades in over [_appear] from then.
  double? _arrivedAt;
  static const double _appear = 0.35;

  Map<String, ui.Image> _images = const {};
  Size _rasterSize = Size.zero;
  double _rasterScale = 0;

  DealerState _state = DealerState.idle;
  double _stateAt = 0;
  DealerPose _from = const DealerPose();

  /// Whether the phone asks for less motion, read in build: the painter asks
  /// for her pose during paint, where no inherited lookup may be made.
  bool _still = false;

  @override
  void initState() {
    super.initState();
    _state = widget.state;
    _ticker = createTicker((elapsed) {
      _clock.value = elapsed.inMicroseconds / 1e6;
    })..start();
    _load();
  }

  @override
  void didUpdateWidget(covariant DealerHost old) {
    super.didUpdateWidget(old);
    if (old.asset != widget.asset) _load();
    if (old.state != widget.state) {
      // Blend from wherever she is now into the new state.
      _from = _poseAt(_clock.value);
      _state = widget.state;
      _stateAt = _clock.value;
    }
  }

  Future<void> _load() async {
    final asset = widget.asset;
    // Already loaded: drawn in this very frame, with no await between.
    final ready = DealerArt.loaded(asset);
    if (ready != null) {
      _disposeImages();
      _art = ready;
      _arrivedAt = null;
      return;
    }
    try {
      final art = await DealerArt.load(asset);
      if (!mounted || asset != widget.asset) return;
      setState(() {
        _art = art;
        _disposeImages();
        // She arrived a moment after the table did: faded in, not popped.
        _arrivedAt = _clock.value;
      });
    } catch (_) {
      // No artwork, no host: the table stands without her.
    }
  }

  void _disposeImages() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images = const {};
    _rasterSize = Size.zero;
    _rasterScale = 0;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    _disposeImages();
    super.dispose();
  }

  /// Her pose now, blended in from the last state for [DealerTiming.blend].
  DealerPose _poseAt(double clock) {
    final inState = clock - _stateAt;
    final target = dealerPose(
      _state,
      inState: inState,
      clock: clock,
      still: _still,
    );
    final blend = DealerTiming.blend.inMicroseconds / 1e6;
    if (inState >= blend) return target;
    return _from.lerp(
      target,
      Curves.easeInOut.transform((inState / blend).clamp(0.0, 1.0)),
    );
  }

  /// How far she has faded in, 0..1, at [clock].
  double _appearAt(double clock) {
    final at = _arrivedAt;
    if (at == null) return 1;
    return ((clock - at) / _appear).clamp(0.0, 1.0);
  }

  /// The layers as images, drawn at [scale] device pixels to one unit of the
  /// artwork, once per size.
  void _raster(DealerArtwork art, Size size, double scale) {
    if (_rasterSize == size && _rasterScale == scale && _images.isNotEmpty) {
      return;
    }
    _disposeImages();
    final images = <String, ui.Image>{};
    for (final layer in art.layers) {
      final info = layer.picture;
      if (info == null) continue;
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..scale(scale)
        ..drawPicture(info.picture);
      final picture = recorder.endRecording();
      images[layer.id] = picture.toImageSync(
        math.max(1, (art.viewBox.width * scale).ceil()),
        math.max(1, (art.viewBox.height * scale).ceil()),
      );
      picture.dispose();
    }
    _images = images;
    _rasterSize = size;
    _rasterScale = scale;
  }

  @override
  Widget build(BuildContext context) {
    final art = _art;
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        if (art == null || !size.isFinite || size.isEmpty) {
          return const SizedBox.expand();
        }
        final visible = art.visible;
        // Fitted whole, standing on the box's bottom edge.
        final unit = math.min(
          size.width / visible.width,
          size.height / visible.height,
        );
        _raster(art, size, unit * MediaQuery.devicePixelRatioOf(context));
        return RepaintBoundary(
          child: CustomPaint(
            size: size,
            painter: _DealerPainter(
              clock: _clock,
              pose: _poseAt,
              appear: _appearAt,
              art: art,
              images: _images,
              unit: unit,
              colours: CasinoTableColors.of(context),
            ),
          ),
        );
      },
    );
  }
}

/// Where the win's sparks start round her head and shoulders, in the default
/// artwork's units, and when each sets off (a share of the flight).
const List<(double, double, double)> _sparks = [
  (72, 44, 0.00),
  (130, 38, 0.08),
  (60, 92, 0.16),
  (142, 86, 0.05),
  (84, 22, 0.22),
  (118, 20, 0.13),
  (150, 128, 0.27),
];

class _DealerPainter extends CustomPainter {
  _DealerPainter({
    required ValueNotifier<double> clock,
    required this.pose,
    required this.appear,
    required this.art,
    required this.images,
    required this.unit,
    required this.colours,
  }) : _clock = clock,
       super(repaint: clock);

  final ValueNotifier<double> _clock;
  final DealerPose Function(double clock) pose;
  final double Function(double clock) appear;
  final DealerArtwork art;
  final Map<String, ui.Image> images;
  final double unit;
  final CasinoTableColors colours;

  static const Offset _fallbackPivot = Offset(100, 120);

  @override
  void paint(Canvas canvas, Size size) {
    final p = pose(_clock.value);
    final visible = art.visible;
    final vb = art.viewBox;
    final shown = appear(_clock.value);
    if (shown <= 0) return;

    // Nothing of her below the rail, and nothing past her own box. Faded in
    // as a whole — through one layer, for the moment it takes — so her
    // overlapping parts never show through each other.
    if (shown < 1) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = Color.fromRGBO(0, 0, 0, shown),
      );
    } else {
      canvas.save();
    }
    canvas.clipRect(Offset.zero & size);
    // The artwork's units, standing on the box's bottom edge and centred.
    canvas.translate(
      (size.width - visible.width * unit) / 2,
      size.height - visible.height * unit,
    );
    canvas.scale(unit);
    canvas.translate(-vb.left, -vb.top);

    _halo(canvas, p);

    // Her body breathes about her waist and lifts; everything is carried on
    // it.
    final bodyPivot =
        art.layer(DealerArt.body)?.pivot ?? Offset(vb.center.dx, art.rimY);
    canvas.translate(0, -p.lift);
    _about(
      canvas,
      bodyPivot,
      scaleX: 1 + 0.0035 * p.breath,
      scaleY: 1 + 0.009 * p.breath,
    );

    final head = art.layer(DealerArt.head)?.pivot ?? _fallbackPivot;
    final armR = art.layer(DealerArt.armRight)?.pivot ?? _fallbackPivot;

    for (final layer in art.layers) {
      final image = images[layer.id];
      if (image == null) continue;
      canvas.save();
      switch (layer.id) {
        case DealerArt.hairBack:
        case DealerArt.head:
          _headTransform(canvas, head, p);
        case DealerArt.eyes:
          _headTransform(canvas, head, p);
          final eyes = layer.pivot ?? head;
          canvas.translate(p.lookX, p.lookY);
          _about(canvas, eyes, scaleY: p.lid.clamp(0.08, 1.0));
        case DealerArt.armRight:
          _about(canvas, layer.pivot ?? armR, angle: p.armRight);
        case DealerArt.armLeft:
          _about(canvas, layer.pivot ?? _fallbackPivot, angle: p.armLeft);
        case DealerArt.card:
          if (p.card <= 0.01) {
            canvas.restore();
            continue;
          }
          _about(canvas, armR, angle: p.armRight);
          _about(canvas, layer.pivot ?? armR, angle: p.cardTurn);
      }
      final alpha = layer.id == DealerArt.card ? p.card.clamp(0.0, 1.0) : 1.0;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        vb,
        Paint()
          ..filterQuality = FilterQuality.medium
          ..color = Color.fromRGBO(0, 0, 0, alpha),
      );
      canvas.restore();
    }

    if (p.sparkle >= 0) _drawSparks(canvas, p.sparkle);
    canvas.restore();
  }

  /// The head's tilt about the neck and its nod.
  static void _headTransform(Canvas canvas, Offset pivot, DealerPose p) {
    canvas.translate(0, p.headNod);
    _about(canvas, pivot, angle: p.headTilt);
  }

  /// Turns and scales the canvas about [pivot].
  static void _about(
    Canvas canvas,
    Offset pivot, {
    double angle = 0,
    double scaleX = 1,
    double scaleY = 1,
  }) {
    canvas.translate(pivot.dx, pivot.dy);
    if (angle != 0) canvas.rotate(angle);
    if (scaleX != 1 || scaleY != 1) canvas.scale(scaleX, scaleY);
    canvas.translate(-pivot.dx, -pivot.dy);
  }

  /// The light behind her: a soft pool round her head and shoulders in the
  /// theme's colours, warming on the viewer's turn and brightest at a win.
  void _halo(Canvas canvas, DealerPose p) {
    final vb = art.viewBox;
    // Inside her own box, so the light fades to nothing before its edge.
    final centre = Offset(vb.center.dx, vb.top + vb.height * 0.36);
    final radius = vb.width * 0.5;
    final rest = colours.hostHalo;
    var core = Color.lerp(
      rest.withValues(alpha: rest.a * (0.7 + 0.3 * p.halo)),
      colours.hostHaloTurn,
      p.haloTurn.clamp(0.0, 1.0),
    )!;
    core = Color.lerp(core, colours.hostHaloWin, p.haloWin.clamp(0.0, 1.0))!;
    final rect = Rect.fromCircle(center: centre, radius: radius);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            core,
            colours.hostHaloOuter,
            colours.hostHaloOuter.withValues(alpha: 0),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
  }

  /// Small four-pointed sparks rising round her head and shoulders.
  void _drawSparks(Canvas canvas, double t) {
    for (final (x, y, delay) in _sparks) {
      final life = ((t - delay) / (1 - delay)).clamp(0.0, 1.0);
      if (life <= 0 || life >= 1) continue;
      final r = 4.2 * _bump(life);
      final at = Offset(x, y - 10 * life);
      final paint = Paint()
        ..color = colours.sparkle.withValues(alpha: 0.95 * _bump(life));
      final star = Path()
        ..moveTo(at.dx, at.dy - r)
        ..quadraticBezierTo(at.dx, at.dy, at.dx + r, at.dy)
        ..quadraticBezierTo(at.dx, at.dy, at.dx, at.dy + r)
        ..quadraticBezierTo(at.dx, at.dy, at.dx - r, at.dy)
        ..quadraticBezierTo(at.dx, at.dy, at.dx, at.dy - r)
        ..close();
      canvas.drawPath(star, paint);
    }
  }

  @override
  bool shouldRepaint(_DealerPainter old) =>
      old._clock != _clock ||
      old.art != art ||
      !identical(old.images, images) ||
      old.unit != unit ||
      old.colours != colours ||
      old.pose != pose ||
      old.appear != appear;
}
