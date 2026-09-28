import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'theme_colors.dart';

/// Where a surface stands in the app's nested elevation (owner, 28 Sep 2026:
/// "Make the existing UI feel physically layered and naturally elevated using
/// depth, luminance separation, soft ambient shadows, subtle inner highlights,
/// translucent surfaces and nested elevation ... Improve depth, not
/// decoration").
///
/// One ladder for every surface in the app, from the room up: a [well] is sunk
/// into what it sits on; a [card] stands on the room or on a pane; a [raised]
/// control stands one step above whatever it sits on — a key on a card, a
/// tile in a sheet, a chip on the ground; an [overlay] floats over the whole
/// room. The ladder is NESTED: a surface's shadow says how far it stands above
/// the surface directly under it, never above the screen, so a key on a card
/// on the ground casts the key's small shadow on the card, and the card its
/// own on the ground. That is why [raised] casts the smallest shadow and
/// [overlay] the largest.
///
/// Every level is told apart three ways, the same in both themes and applied
/// the same way everywhere ([Depth]):
///
///  * a soft ambient shadow and a tight contact shadow under it, in the
///    theme's own shadow colour ([AppTheme.shadowFor]) — cast round a
///    translucent surface and never under it ([OuterShadow]), so a shadow
///    never shows through glass and changes the colour of the surface itself;
///  * light along its top edge, just inside its hairline, fading down its
///    sides into the corners, and a shade along its foot — the edge of a
///    thing with thickness ([SurfaceLight]);
///  * by night, a breath more light over its upper part than its lower
///    (luminance separation): on obsidian a shadow cannot show, and a surface
///    that is lit from above is what reads as standing up out of the dark.
///
/// A [well] is the same inverted: a shade along its top inside edge, a lit lip
/// along its foot, and no shadow at all.
enum Elevation {
  /// The room itself: lit by its lamp, never shadowed.
  ground,

  /// Sunk into the surface it sits on: a track, a figure's tray.
  well,

  /// A surface standing on the room, or on a pane: a lobby card, a seat pod,
  /// a store card, a pane that is not laid over the room.
  card,

  /// One step above whatever it sits on: a key, a chip, a pill, a tile in a
  /// sheet.
  raised,

  /// Laid over the whole room: a dialog, a drawer, a sheet, a toast.
  overlay,
}

/// The numbers of one [Elevation] in one theme.
@immutable
class _Lift {
  const _Lift({
    this.contact = 0,
    this.contactBlur = 0,
    this.contactY = 0,
    this.ambient = 0,
    this.ambientBlur = 0,
    this.ambientY = 0,
    this.ambientSpread = 0,
    this.rim = 0,
    this.top = 0,
    this.foot = 0,
  });

  /// The contact shadow: alpha, blur, drop.
  final double contact;
  final double contactBlur;
  final double contactY;

  /// The ambient shadow: alpha, blur, drop and spread (negative, so it pools
  /// under the surface rather than haloing round it).
  final double ambient;
  final double ambientBlur;
  final double ambientY;
  final double ambientSpread;

  /// The alphas of the light along the top edge, of the light over the upper
  /// part, and of the shade along the foot. For a well the top edge is a
  /// shade and the foot a lit lip.
  final double rim;
  final double top;
  final double foot;

  static _Lift lerp(_Lift a, _Lift b, double t) {
    double l(double x, double y) => lerpDouble(x, y, t)!;
    return _Lift(
      contact: l(a.contact, b.contact),
      contactBlur: l(a.contactBlur, b.contactBlur),
      contactY: l(a.contactY, b.contactY),
      ambient: l(a.ambient, b.ambient),
      ambientBlur: l(a.ambientBlur, b.ambientBlur),
      ambientY: l(a.ambientY, b.ambientY),
      ambientSpread: l(a.ambientSpread, b.ambientSpread),
      rim: l(a.rim, b.rim),
      top: l(a.top, b.top),
      foot: l(a.foot, b.foot),
    );
  }
}

/// The light a surface catches at one [Elevation]: the colour of its top
/// edge, of the light over its upper part, and of its foot, for
/// [SurfaceLight] to paint.
@immutable
class DepthLight {
  const DepthLight({
    required this.rim,
    required this.top,
    required this.foot,
    this.recessed = false,
  });

  /// Nothing at all: a surface the ladder leaves as it is.
  static const DepthLight none = DepthLight(
    rim: Color(0x00000000),
    top: Color(0x00000000),
    foot: Color(0x00000000),
  );

  /// Along the top edge, just inside the hairline: light on a surface that
  /// stands up, shade on a well.
  final Color rim;

  /// Over the upper part: a breath of light by night, nothing by day.
  final Color top;

  /// Along the foot, just inside the hairline: shade on a surface that stands
  /// up, a lit lip on a well.
  final Color foot;

  /// A well: its top edge is in shade and its foot catches the light.
  final bool recessed;

  bool get isNone => rim.a == 0 && top.a == 0 && foot.a == 0;

  DepthLight copyWith({Color? rim, Color? top, Color? foot}) => DepthLight(
    rim: rim ?? this.rim,
    top: top ?? this.top,
    foot: foot ?? this.foot,
    recessed: recessed,
  );

  /// The same light at [k] of its strength: a key pressed in catches less of
  /// it, and a saturated fill needs less of it to read.
  DepthLight scaled(double k) => k == 1
      ? this
      : DepthLight(
          rim: rim.withValues(alpha: rim.a * k),
          top: top.withValues(alpha: top.a * k),
          foot: foot.withValues(alpha: foot.a * k),
          recessed: recessed,
        );

  @override
  bool operator ==(Object other) =>
      other is DepthLight &&
      other.rim == rim &&
      other.top == top &&
      other.foot == foot &&
      other.recessed == recessed;

  @override
  int get hashCode => Object.hash(rim, top, foot, recessed);
}

/// The depth ladder's numbers, per theme — the one place every shadow, edge
/// light and foot shade in the chrome is read from, so a key, a card and a
/// dialog are lit by one lamp and stand at heights that agree.
///
/// Read through [of] where a widget has its theme's [GlassColors] (it
/// cross-fades with the theme's 420ms change, as the glass does), or
/// [forBrightness] for a surface that is dark in both themes (the plates and
/// the wallet on the cloth).
abstract final class Depth {
  /// By night: black shadows, which only show where the ground is not black —
  /// so the lit top edge and the light over the upper part carry most of it.
  static const Map<Elevation, _Lift> _night = {
    Elevation.ground: _Lift(),
    Elevation.well: _Lift(rim: 0.40, foot: 0.07),
    // The pane's own shadow, exactly as every glass panel has always cast it
    // ([AppTheme.glassShadow]), so no pane that stands on the room reads a
    // shade lighter or darker for the ladder.
    Elevation.card: _Lift(
      contact: 0.45,
      contactBlur: 8,
      contactY: 3,
      ambient: 0.35,
      ambientBlur: 28,
      ambientY: 12,
      rim: 0.09,
      top: 0.04,
      foot: 0.30,
    ),
    Elevation.raised: _Lift(
      contact: 0.55,
      contactBlur: 2,
      contactY: 1,
      ambient: 0.34,
      ambientBlur: 9,
      ambientY: 4,
      ambientSpread: -1,
      rim: 0.12,
      top: 0.05,
      foot: 0.34,
    ),
    // An overlay casts the card's shadow and, beyond it, a far soft one round
    // itself ([DepthScheme.overlayReach]): these are that reach's numbers.
    Elevation.overlay: _Lift(
      ambient: 0.50,
      ambientBlur: 48,
      ambientY: 22,
      ambientSpread: -6,
      rim: 0.12,
      foot: 0.30,
    ),
  };

  /// By day: the light theme's slate shadows, soft and a little longer, which
  /// is what lifts a white surface off a pale room; white light along the top
  /// edge (it shows on every surface that is not pure white) and no light over
  /// the upper part, which would only wash the surface out.
  static const Map<Elevation, _Lift> _day = {
    Elevation.ground: _Lift(),
    Elevation.well: _Lift(rim: 0.09, foot: 0.80),
    Elevation.card: _Lift(
      contact: 0.08,
      contactBlur: 8,
      contactY: 3,
      ambient: 0.10,
      ambientBlur: 28,
      ambientY: 12,
      rim: 0.85,
      foot: 0.05,
    ),
    Elevation.raised: _Lift(
      contact: 0.12,
      contactBlur: 2,
      contactY: 1,
      ambient: 0.10,
      ambientBlur: 8,
      ambientY: 3,
      ambientSpread: -1,
      rim: 0.90,
      foot: 0.07,
    ),
    Elevation.overlay: _Lift(
      ambient: 0.16,
      ambientBlur: 48,
      ambientY: 22,
      ambientSpread: -6,
      rim: 0.90,
      foot: 0.06,
    ),
  };

  /// The ladder for the theme in scope, cross-faded with it.
  static DepthScheme of(BuildContext context) =>
      DepthScheme._(GlassColors.of(context).dayShare);

  /// The ladder for a surface of one [brightness] whatever the theme.
  static DepthScheme forBrightness(Brightness brightness) =>
      DepthScheme._(brightness == Brightness.light ? 1 : 0);

  /// Shorthand for `forBrightness(b).shadows(level)`.
  static List<BoxShadow> shadows(Brightness b, Elevation level) =>
      forBrightness(b).shadows(level);
}

/// [Depth]'s numbers at one point of the theme's cross-fade from obsidian (0)
/// to frosted ice (1).
@immutable
class DepthScheme {
  const DepthScheme._(this.day);

  /// How far from obsidian (0) to frosted ice (1).
  final double day;

  _Lift _lift(Elevation level) =>
      _Lift.lerp(Depth._night[level]!, Depth._day[level]!, day.clamp(0.0, 1.0));

  Color get _shadow =>
      Color.lerp(
        AppTheme.shadowFor(Brightness.dark),
        AppTheme.shadowFor(Brightness.light),
        day.clamp(0.0, 1.0),
      ) ??
      AppTheme.shadowFor(Brightness.dark);

  /// What a surface at [level] casts: its contact shadow and the ambient one
  /// under it — for an overlay, the card's pair and, beyond it, its
  /// [overlayReach]. None for the room and for a well.
  ///
  /// A translucent surface casts through [OuterShadow], which keeps the
  /// shadow off the surface's own body: under glass or a veil of colour a
  /// shadow painted beneath would show through and darken the surface itself
  /// — a change of its colour, not of its depth.
  List<BoxShadow> shadows(Elevation level) => switch (level) {
    Elevation.overlay => [..._pair(Elevation.card), ...overlayReach],
    _ => _pair(level),
  };

  /// The far, soft shadow an overlay throws round itself beyond the card's
  /// own ([Elevation.overlay]): what lifts a dialog or a sheet off the room
  /// it is laid over, painted outside its body ([OuterShadow]).
  List<BoxShadow> get overlayReach => _pair(Elevation.overlay);

  List<BoxShadow> _pair(Elevation level) {
    final l = _lift(level);
    if (l.contact <= 0 && l.ambient <= 0) return const [];
    final s = _shadow;
    return [
      if (l.contact > 0)
        BoxShadow(
          color: s.withValues(alpha: l.contact),
          blurRadius: l.contactBlur,
          offset: Offset(0, l.contactY),
        ),
      if (l.ambient > 0)
        BoxShadow(
          color: s.withValues(alpha: l.ambient),
          blurRadius: l.ambientBlur,
          spreadRadius: l.ambientSpread,
          offset: Offset(0, l.ambientY),
        ),
    ];
  }

  /// The light a surface at [level] catches ([SurfaceLight]).
  DepthLight light(Elevation level) {
    final l = _lift(level);
    const white = Color(0xFFFFFFFF);
    final s = _shadow;
    if (level == Elevation.well) {
      return DepthLight(
        rim: s.withValues(alpha: l.rim),
        top: const Color(0x00000000),
        foot: white.withValues(alpha: l.foot),
        recessed: true,
      );
    }
    return DepthLight(
      rim: white.withValues(alpha: l.rim),
      top: white.withValues(alpha: l.top),
      foot: s.withValues(alpha: l.foot),
    );
  }
}

/// The edge light and the upper light of a rounded surface, as [Depth] gives
/// them ([DepthLight]): painted over the surface's body and under what is on
/// it, inside its hairline.
///
/// The top edge is lit where the room's light falls on it and the light runs
/// down its sides only as far as its corners turn — so a capsule is lit along
/// its upper half and shaded along its lower, a card along its top and a
/// little way down — which is what makes an outline read as the edge of a
/// thing with thickness rather than as a stroked line. Static: nothing here
/// moves, and [shouldRepaint] compares every input.
class SurfaceLight extends CustomPainter {
  const SurfaceLight({
    required this.radius,
    required this.light,
    this.inset = Dim.hairline,
  });

  /// The surface's corner radius; a capsule may pass [Radii.pill].
  final double radius;

  final DepthLight light;

  /// How far inside the surface's edge its edge light runs: inside the
  /// hairline, so the two read as one bevelled edge.
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || light.isNone) return;
    final rect = Offset.zero & size;
    final r = math.min(radius, size.shortestSide / 2);
    final body = RRect.fromRectAndRadius(rect, Radius.circular(r));

    // The light over the upper part: from the top edge to just below the
    // middle, where it is gone. Filled through the surface's own shape, so no
    // clip is needed.
    if (light.top.a > 0) {
      canvas.drawRRect(
        body,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: const Alignment(0, 0.1),
            colors: [light.top, light.top.withValues(alpha: 0)],
          ).createShader(rect),
      );
    }

    // The edge: one line just inside the hairline, lit at the top and shaded
    // at the foot, each fading down (or up) its sides as far as the corner
    // turns — half the height on a capsule, never less than 6dp.
    final d = inset + 0.5;
    final edge = rect.deflate(d);
    if (edge.isEmpty) return;
    final line = RRect.fromRectAndRadius(
      edge,
      Radius.circular(math.max(0, r - d)),
    );
    final reach = (math.max(r, 6.0) / size.height).clamp(0.0, 0.5);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    if (light.rim.a > 0) {
      canvas.drawRRect(
        line,
        stroke
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [light.rim, light.rim.withValues(alpha: 0)],
            stops: [0, reach],
          ).createShader(rect),
      );
    }
    if (light.foot.a > 0) {
      canvas.drawRRect(
        line,
        stroke
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [light.foot.withValues(alpha: 0), light.foot],
            stops: [1 - reach, 1],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(SurfaceLight old) =>
      old.radius != radius || old.light != light || old.inset != inset;
}

/// [shadows] cast by a rounded surface, painted OUTSIDE its shape only
/// ([Depth]): the room around it is shaded and the surface's own body is not.
///
/// For a translucent surface — glass, a veil of colour, a pill of the room's
/// ink — a [BoxDecoration.boxShadow] is painted under the whole box and shows
/// through its body, darkening the surface itself (and, under a blur, the
/// blur samples it). Painted before the surface ([CustomPaint.painter]),
/// clipped to what lies outside it; static, and [shouldRepaint] compares
/// every input.
class OuterShadow extends CustomPainter {
  const OuterShadow({required this.radius, required this.shadows});

  /// The surface's corner radius; a capsule may pass [Radii.pill].
  final double radius;

  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || shadows.isEmpty) return;
    final rect = Offset.zero & size;
    final r = math.min(radius, size.shortestSide / 2);
    final body = RRect.fromRectAndRadius(rect, Radius.circular(r));
    var reach = 0.0;
    for (final s in shadows) {
      reach = math.max(
        reach,
        s.blurRadius * 2 + s.spreadRadius.abs() + s.offset.distance,
      );
    }
    canvas.save();
    canvas.clipPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rect.inflate(reach + 1))
        ..addRRect(body),
    );
    for (final s in shadows) {
      canvas.drawRRect(
        body.shift(s.offset).inflate(s.spreadRadius),
        s.toPaint(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(OuterShadow old) =>
      old.radius != radius || !listEquals(old.shadows, shadows);
}
