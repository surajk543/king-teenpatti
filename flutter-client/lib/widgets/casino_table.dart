/// The casino table the Teen Patti seats stand round (owner's brief, 24 Sep
/// 2026: "Transform the current gameplay screen from a mostly flat background
/// into a more recognizable premium casino table experience").
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';

/// Where the table stands on the felt: one stadium, fixed as shares of the
/// felt's own box.
///
/// Nothing on the felt moved for it. The seats, the cards, the pot and the
/// keys keep the places they were given before there was a table
/// (`seatPlaces`, the pot at 0.46 of the felt's height), and the table is
/// drawn to meet them: its far rail runs under the two top seats' pods, its
/// rounded ends under the side seats, its near rail under the viewer's pod
/// and hand, and the pot sits on the cloth a little towards the far side.
///
/// The far rail is at [top] — 0.24 of the felt's height — between the table's
/// own words: the category tag stands above it (at 0.075), off the table, and
/// the waiting line below it on the cloth (at 0.325).
@immutable
class TableGeometry {
  const TableGeometry._(this.felt, this.outer, this.rail);

  /// The table on a felt of [felt].
  factory TableGeometry.of(Size felt) {
    final w = felt.width;
    final h = felt.height;
    final box = Rect.fromLTRB(w * left, h * top, w * right, h * bottom);
    final outer = RRect.fromRectAndRadius(
      box,
      Radius.circular(box.shortestSide / 2),
    );
    return TableGeometry._(felt, outer, (h * railShare).clamp(9.0, 18.0));
  }

  /// The table's outer edge as shares of the felt: nearly its whole width,
  /// and from the far rail at [top] to a near rail a little above the floor,
  /// so the room shows under the table's front edge and the viewer's pod,
  /// which stands on the floor, overlaps it.
  static const double left = 0.012;
  static const double right = 0.988;
  static const double top = 0.24;
  static const double bottom = 0.945;

  /// The rail's thickness as a share of the felt's height, held to 9..18.
  /// 360 -> 12.2 | 411 -> 13.9 | 800 -> 18.0
  static const double railShare = 0.034;

  /// The felt the table was laid out on.
  final Size felt;

  /// The rail's outer edge: a stadium, its ends semicircles.
  final RRect outer;

  /// How thick the rail is.
  final double rail;

  /// The playing surface inside the rail.
  RRect get cloth => outer.deflate(rail);

  /// The far rail's outer edge.
  double get rimTop => outer.top;

  @override
  bool operator ==(Object other) =>
      other is TableGeometry &&
      other.felt == felt &&
      other.outer == outer &&
      other.rail == rail;

  @override
  int get hashCode => Object.hash(felt, outer, rail);
}

/// The table: a pearl or graphite rail with a thin champagne rim round the
/// game's own cloth, and the one soft shadow it casts on the floor.
///
/// Entirely static and painted once into its own layer, like the room's
/// ground under it: it repaints only when the felt changes size, the theme
/// changes colour or the table becomes another game's. Every soft edge is
/// either a gradient or a blurred rounded rectangle — the one blur Impeller
/// draws analytically — so the table costs nothing per frame whatever is
/// animating above it.
class CasinoTableSurface extends StatelessWidget {
  const CasinoTableSurface({
    super.key,
    required this.geometry,
    this.category,
    this.detailed = true,
  });

  final TableGeometry geometry;

  /// The game the table is laid for, by its wire category (owner, 25 Sep
  /// 2026: "keep different table color for seen, blind, variation
  /// gameplay"): the cloth is that game's own ([CasinoTableColors.clothFor]),
  /// in the colour its lobby card and its tag wear. A private table is its
  /// game's too. Null, or a game this build has no colour for, is the teal.
  final String? category;

  /// The decoration a short phone goes without (owner's brief: "Short phone:
  /// ... reduce decorative elements"): the line printed on the cloth and the
  /// glow round the rail. The table itself is the same.
  final bool detailed;

  @override
  Widget build(BuildContext context) {
    final colours = CasinoTableColors.of(context);
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          isComplex: true,
          willChange: false,
          painter: CasinoTablePainter(
            geometry: geometry,
            colours: colours,
            cloth: colours.clothFor(category),
            detailed: detailed,
          ),
        ),
      ),
    );
  }
}

/// Paints [CasinoTableSurface].
class CasinoTablePainter extends CustomPainter {
  const CasinoTablePainter({
    required this.geometry,
    required this.colours,
    required this.cloth,
    required this.detailed,
  });

  final TableGeometry geometry;
  final CasinoTableColors colours;

  /// The cloth inside the rail: the game's own.
  final TableCloth cloth;
  final bool detailed;

  @override
  void paint(Canvas canvas, Size size) {
    final c = colours;
    final outer = geometry.outer;
    final surface = geometry.cloth;
    final box = outer.outerRect;
    final h = box.height;

    // The table's shadow on the floor: a soft one a little below it, and a
    // tight one where it stands (owner's brief, 25 Sep 2026: "subtle layered
    // depth: outer shadow ...") — the second is what sets it down rather than
    // floating it.
    canvas.drawRRect(
      outer.shift(Offset(0, h * 0.035)),
      Paint()
        ..color = c.shadow
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, c.shadowBlur),
    );
    canvas.drawRRect(
      outer.shift(Offset(0, h * 0.008)),
      Paint()
        ..color = c.shadow.withValues(alpha: c.shadow.a * 0.55)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, c.shadowBlur * 0.22),
    );

    // By night, a controlled cyan light round the rail's edge.
    if (detailed && c.glow.a > 0) {
      canvas.drawRRect(
        outer.inflate(1.5),
        Paint()
          ..color = c.glow
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }

    // The rail: lit from above, and brighter again along its upper half,
    // which is what rounds it into a lip rather than a flat band.
    canvas.drawRRect(
      outer,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [c.railTop, c.railBottom],
        ).createShader(box),
    );
    canvas.drawDRRect(
      outer,
      surface,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [c.railSheen, c.railSheen.withValues(alpha: 0)],
          stops: const [0, 0.55],
        ).createShader(box),
    );

    // The rim: one thin line of champagne round the outer edge.
    canvas.drawRRect(
      outer.deflate(0.8),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [c.rim, c.rimLow],
        ).createShader(box),
    );

    // The cloth: lit a little above its middle, where the lamp hangs, and
    // falling towards its edge — an ellipse of light, not a circle, so the
    // two ends of a wide table darken as its sides do.
    final clothBox = surface.outerRect;
    canvas.drawRRect(
      surface,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.2),
          radius: 0.62,
          colors: [cloth.centre, cloth.edge],
          stops: const [0.1, 1],
          transform: StretchedGradient(clothBox.width / clothBox.height * 0.78),
        ).createShader(clothBox),
    );

    // The rail's lip throws a little shadow onto the top of the cloth.
    canvas.save();
    canvas.clipRRect(surface);
    final lip = Rect.fromLTRB(
      clothBox.left,
      clothBox.top,
      clothBox.right,
      clothBox.top + h * 0.08,
    );
    canvas.drawRect(
      lip,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [cloth.lip, cloth.lip.withValues(alpha: 0)],
        ).createShader(lip),
    );
    // And a very subtle inner shadow all the way round the cloth's edge, as a
    // rail standing a little proud of it throws: a blurred band outside the
    // cloth, of which only the soft inner half falls on it.
    canvas.drawRRect(
      surface.inflate(geometry.rail * 0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = geometry.rail
        ..color = cloth.lip.withValues(alpha: cloth.lip.a * 0.6)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, geometry.rail * 0.45),
    );
    canvas.restore();

    // The seam where the rail meets the cloth.
    canvas.drawRRect(
      surface,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = Dim.hairline
        ..color = c.seam,
    );

    // The inner rim: a thread of the rim's champagne on the rail's inner
    // edge, just outside the seam, which is what makes the rail read as a
    // moulding with two edges rather than a band.
    canvas.drawRRect(
      surface.inflate(1.2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = c.rim.withValues(alpha: c.rim.a * 0.42),
    );

    // The line printed on the cloth a step inside the rail: the one mark a
    // real table carries, and the first thing a short phone does without.
    if (detailed) {
      canvas.drawRRect(
        surface.deflate(h * 0.075),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = Dim.hairline
          ..color = cloth.line,
      );
    }
  }

  @override
  bool shouldRepaint(CasinoTablePainter old) =>
      old.geometry != geometry ||
      old.colours != colours ||
      old.cloth != cloth ||
      old.detailed != detailed;
}

/// Stretches a radial gradient sideways about its box's centre, so a circle
/// of light becomes an ellipse the shape of the table.
class StretchedGradient extends GradientTransform {
  const StretchedGradient(this.sx);

  /// How much wider than tall the light is.
  final double sx;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final c = bounds.center;
    return Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(sx, 1, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
  }
}

/// The light that moves on the table: the overhead lamp's pool, breathing
/// slowly on the cloth, and — on the viewer's turn — a warm light on the near
/// rail in front of their seat (owner's brief: "YOUR_TURN: ... subtle
/// table/dealer glow").
///
/// One controller for both, the lamp's breath, which the table had before
/// there was a table (it was `_AmbientLamp`, a pool over the bare felt). It
/// repaints its own layer every frame for the life of the room, as the lamp
/// always did, and nothing else: the table under it is a separate, static
/// layer. Plain `srcOver` fills and no blend modes, so no offscreen pass.
class TableAmbientEffects extends StatefulWidget {
  const TableAmbientEffects({
    super.key,
    required this.geometry,
    required this.yourTurn,
    required this.viewerX,
  });

  final TableGeometry geometry;

  /// Whether it is the viewer's turn.
  final bool yourTurn;

  /// Where the viewer sits along the near rail, in the felt's coordinates.
  final double viewerX;

  @override
  State<TableAmbientEffects> createState() => _TableAmbientEffectsState();
}

class _TableAmbientEffectsState extends State<TableAmbientEffects>
    with TickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: Motion.breath,
  );

  /// The turn light's fade in and out.
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: Motion.slow,
    value: widget.yourTurn ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    // Read in initState, never first in dispose (CLAUDE.md §12.3).
    _breath.repeat(reverse: true);
    _turn.value = widget.yourTurn ? 1 : 0;
  }

  @override
  void didUpdateWidget(covariant TableAmbientEffects old) {
    super.didUpdateWidget(old);
    if (old.yourTurn != widget.yourTurn) {
      widget.yourTurn ? _turn.forward() : _turn.reverse();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        painter: _AmbientPainter(
          breath: _breath,
          turn: _turn,
          geometry: widget.geometry,
          colours: CasinoTableColors.of(context),
          viewerX: widget.viewerX,
        ),
      ),
    ),
  );
}

class _AmbientPainter extends CustomPainter {
  _AmbientPainter({
    required this.breath,
    required this.turn,
    required this.geometry,
    required this.colours,
    required this.viewerX,
  }) : super(repaint: Listenable.merge([breath, turn]));

  final Animation<double> breath;
  final Animation<double> turn;
  final TableGeometry geometry;
  final CasinoTableColors colours;
  final double viewerX;

  @override
  void paint(Canvas canvas, Size size) {
    final c = colours;
    final cloth = geometry.cloth;
    final clothBox = cloth.outerRect;
    final v = Motion.breathe.transform(breath.value);

    // The lamp's pool on the cloth: over the pot and the far side of the
    // table, breathing a little.
    final lamp = c.lampAlpha * (0.85 + 0.3 * v);
    final pool = Rect.fromCenter(
      center: Offset(clothBox.center.dx, clothBox.top + clothBox.height * 0.34),
      width: clothBox.width * 0.72,
      height: clothBox.height * 1.1,
    );
    canvas.save();
    canvas.clipRRect(cloth);
    canvas.drawRect(
      pool,
      Paint()
        ..shader = RadialGradient(
          colors: [
            c.lamp.withValues(alpha: lamp),
            c.lamp.withValues(alpha: lamp * 0.4),
            c.lamp.withValues(alpha: 0),
          ],
          stops: const [0, 0.45, 1],
          transform: StretchedGradient(pool.width / pool.height),
        ).createShader(pool),
    );
    canvas.restore();

    // The viewer's turn: a warm light on the near rail in front of them.
    final t = Curves.easeOut.transform(turn.value);
    if (t <= 0) return;
    final outer = geometry.outer;
    final glow = Rect.fromCenter(
      center: Offset(viewerX, outer.bottom - geometry.rail),
      width: outer.width * 0.46,
      height: outer.height * 0.5,
    );
    canvas.save();
    canvas.clipRRect(outer);
    canvas.drawRect(
      glow,
      Paint()
        ..shader = RadialGradient(
          colors: [
            c.turnGlow.withValues(alpha: 0.30 * t * (0.8 + 0.2 * v)),
            c.turnGlow.withValues(alpha: 0),
          ],
          transform: StretchedGradient(glow.width / glow.height),
        ).createShader(glow),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AmbientPainter old) =>
      old.breath != breath ||
      old.turn != turn ||
      old.geometry != geometry ||
      old.colours != colours ||
      old.viewerX != viewerX;
}
