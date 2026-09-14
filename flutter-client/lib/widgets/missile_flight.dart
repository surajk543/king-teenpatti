import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../state/hammer_strike.dart';
import '../state/missile_strike.dart';

/// `assets/animations/Missile.json` and `assets/animations/explosion.json`,
/// each parsed once for the life of the app.
///
/// **Missile.json** (Lottie 5.12.2, 1000x1000, 29.97 fps, frames 0–60): a
/// line-art rocket in coral and sky blue, nose up and to the right — its
/// forward axis is −45°, [forward] — with three blue exhaust dashes behind the
/// nozzle. The rocket layer flies in from off the canvas at the bottom left and
/// comes to rest in the middle by frame 54; frames 0 to about 20 show nothing.
/// The dashes pulse 100% → 85% → 100% over eight frames. That pulse was a
/// `loopOut()` expression, which the phone players do not run (CLAUDE.md
/// §12.3) — on a phone the dashes stopped at frame 9, while the rocket was
/// still off the canvas — so the file ships with the loop written out as
/// keyframes by `tools/lottie/bake_loop_expressions.py`. No 3D, no other
/// expressions.
///
/// **explosion.json** (Lottie 5.5.8, 134x87, 25 fps, 11 frames): a flipbook of
/// nine shape layers, one per frame, in a precomp — a star-burst at the bottom
/// middle that blooms into a cloud and blows away as smoke. No images, no
/// expressions, no 3D.
abstract final class MissileArt {
  static const missileAsset = 'assets/animations/Missile.json';
  static const explosionAsset = 'assets/animations/explosion.json';

  static LottieComposition? _missile;
  static LottieComposition? _explosion;
  static Future<void>? _loading;

  /// The parsed files, once [load] has finished; null before, or if one failed.
  static LottieComposition? get missile => _missile;
  static LottieComposition? get explosion => _explosion;

  /// Reads and parses both files the first time it is asked for. A failure is
  /// remembered as nothing, and the next call tries again — the volley still
  /// jolts the pods it hits without them.
  static Future<void> load() => _loading ??= Future.wait([
    AssetLottie(missileAsset).load().then((c) => _missile = c),
    AssetLottie(explosionAsset).load().then((c) => _explosion = c),
  ]).then<void>((_) {}, onError: (Object _) => _loading = null);

  /// The rocket's forward axis, tail to nose, in the drawing: up and to the
  /// right, in radians.
  static const double forward = -math.pi / 4;

  /// The frames the rocket is drawn at while it flies: at rest in the middle
  /// of its canvas, through one whole pulse of its exhaust (8 frames, so the
  /// loop has no seam).
  static const double flyFrom = 52;
  static const double flyFrames = 8;

  /// The file's own frame rate, for pacing that pulse.
  static const double fps = 29.97;

  /// Where a frame of the rocket rests, for the key's glyph when it is not
  /// moving: in the middle, exhaust out.
  static const double restFrame = 57;

  /// Where the key's glyph loops from while the key can be used: the rocket
  /// half in from its corner. Before it the canvas is empty, and a loop of the
  /// whole file left the key blank for a third of every cycle.
  static const double glyphLoopFrom = 30;

  /// Where the blast starts in the explosion's canvas, as a share of it: the
  /// bottom middle, where frame 0's star-burst is. The canvas is placed so this
  /// point is a little below the middle of the pod, and the cloud rises over it.
  static const Offset blastOrigin = Offset(0.5, 0.72);
}

/// A missile volley crossing the felt (owner, 14 Sep 2026).
///
/// One missile leaves the firer's pod for each other player still in the hand,
/// all together with a light stagger, each on its own curve with ease-in-out,
/// turned to face the way it is travelling and trailing a little smoke. Each
/// explodes on the pod it reaches. The pods' own jolt is [PodImpact], fed by
/// [MissileImpactClock].
///
/// Everything here is painted by one [CustomPainter] that repaints from
/// [clock], so a frame of the volley rebuilds no widget at all: the rocket and
/// the blast are the parsed compositions drawn at the frames the clock asks
/// for, never Lottie widgets being rebuilt.
class MissileFlight extends StatefulWidget {
  const MissileFlight({
    super.key,
    required this.clock,
    required this.count,
    required this.from,
    required this.targets,
    required this.podWidth,
  });

  /// 0 to 1 over [MissileTiming.total] for [count] missiles, from the moment
  /// the volley began.
  final Animation<double> clock;

  /// How many missiles the volley has, including any whose pod could not be
  /// found: it sets the timing, which [targets] alone would not.
  final int count;

  /// The firer's pod, in this widget's coordinates.
  final Rect from;

  /// The pods hit, each with its place in the volley.
  final List<({Rect rect, int index})> targets;

  /// What the felt sizes everything from.
  final double podWidth;

  @override
  State<MissileFlight> createState() => _MissileFlightState();
}

class _MissileFlightState extends State<MissileFlight> {
  LottieDrawable? _missile;
  LottieDrawable? _explosion;

  @override
  void initState() {
    super.initState();
    _take();
    if (_missile == null || _explosion == null) {
      // The felt warms the files when the table opens, so this is only the
      // volley that beat it there: the jolts still land on time.
      unawaited(
        MissileArt.load().then((_) {
          if (mounted) setState(_take);
        }),
      );
    }
  }

  void _take() {
    final missile = MissileArt.missile;
    final explosion = MissileArt.explosion;
    // Every frame the clock asks for, not the files' own rates.
    if (missile != null && _missile == null) {
      _missile = LottieDrawable(missile, frameRate: FrameRate.max);
    }
    if (explosion != null && _explosion == null) {
      _explosion = LottieDrawable(explosion, frameRate: FrameRate.max);
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: MissilePainter(
            clock: widget.clock,
            count: widget.count,
            missile: _missile,
            explosion: _explosion,
            from: widget.from,
            targets: widget.targets,
            podWidth: widget.podWidth,
          ),
        ),
      ),
    );
  }
}

/// Paints one frame of a volley. Public for its geometry, which the tests read.
class MissilePainter extends CustomPainter {
  MissilePainter({
    required this.clock,
    required this.count,
    required this.missile,
    required this.explosion,
    required this.from,
    required this.targets,
    required this.podWidth,
  }) : super(repaint: clock);

  final Animation<double> clock;
  final int count;
  final LottieDrawable? missile;
  final LottieDrawable? explosion;
  final Rect from;
  final List<({Rect rect, int index})> targets;
  final double podWidth;

  static final double _flightMs = MissileTiming.flight.inMilliseconds
      .toDouble();
  static final double _staggerMs = MissileTiming.stagger.inMilliseconds
      .toDouble();
  static final double _blastMs = MissileTiming.explosion.inMilliseconds
      .toDouble();

  /// The rocket's canvas side. The drawing fills most of the diagonal.
  double get _side => podWidth * 0.8;

  /// The explosion's canvas, about 1.4 pod widths across, at the drawing's
  /// own proportions.
  Size get _blastSize {
    final width = podWidth * 1.4;
    final art = explosion?.composition.bounds;
    final aspect = art == null || art.width <= 0
        ? 87 / 134
        : art.height / art.width;
    return Size(width, width * aspect);
  }

  /// The curve's middle control point for a flight from [a] to [b], bowed out
  /// by a share of the distance: up, for a flight that is mostly sideways,
  /// and out towards the nearer side of the felt, for one that is mostly up or
  /// down — and kept inside the felt, so no missile flies off it.
  static Offset control(
    Offset a,
    Offset b, {
    required Size stage,
    required double podWidth,
    required int index,
  }) {
    final chord = b - a;
    final length = chord.distance;
    final mid = Offset.lerp(a, b, 0.5)!;
    if (length < 1) return mid;
    var normal = Offset(-chord.dy, chord.dx) / length;
    final bool flip;
    if (chord.dx.abs() >= chord.dy.abs()) {
      // Mostly sideways: arc up over the table, the way a thing thrown flies.
      // Bowed away from the middle instead, a flight from the viewer's pod to
      // the right-hand seat dipped across the viewer's own cards.
      flip = normal.dy > 0;
    } else {
      // Mostly up or down: bow out towards the nearer side of the felt, so a
      // volley from one pod fans out instead of crossing over itself.
      final outward = mid.dx - stage.width / 2;
      flip = outward.abs() < 1e-6 ? index.isOdd : normal.dx * outward < 0;
    }
    if (flip) normal = -normal;
    final bow = (length * 0.26).clamp(podWidth * 0.35, podWidth * 1.5);
    final c = mid + normal * bow;
    final inset = podWidth * 0.35;
    return Offset(
      c.dx.clamp(inset, math.max(inset, stage.width - inset)).toDouble(),
      c.dy.clamp(inset, math.max(inset, stage.height - inset)).toDouble(),
    );
  }

  static Offset along(Offset a, Offset c, Offset b, double t) {
    final u = 1 - t;
    return a * (u * u) + c * (2 * u * t) + b * (t * t);
  }

  static Offset tangent(Offset a, Offset c, Offset b, double t) =>
      (c - a) * (2 * (1 - t)) + (b - c) * (2 * t);

  /// How far along its curve the missile at [index] is at [ms] into the
  /// volley, eased: null before it launches or once it has landed.
  static double? progressAt(double ms, int index) {
    final t = (ms - index * _staggerMs) / _flightMs;
    if (t < 0 || t >= 1) return null;
    return Curves.easeInOut.transform(t);
  }

  /// The angle to turn the drawing by so its nose points along [direction].
  static double headingFor(Offset direction) =>
      direction.direction - MissileArt.forward;

  @override
  void paint(Canvas canvas, Size size) {
    final value = clock.value;
    if (value <= 0 || value >= 1) return;
    final ms = value * MissileTiming.total(count).inMilliseconds;
    final a = from.center;

    // Smoke first, rockets over it, and the blasts over everything.
    for (final target in targets) {
      final b = target.rect.center;
      final c = control(
        a,
        b,
        stage: size,
        podWidth: podWidth,
        index: target.index,
      );
      final t = (ms - target.index * _staggerMs) / _flightMs;
      if (t > 0 && t < 1) _paintTrail(canvas, a, c, b, t);
    }
    for (final target in targets) {
      final b = target.rect.center;
      final c = control(
        a,
        b,
        stage: size,
        podWidth: podWidth,
        index: target.index,
      );
      _paintMissile(canvas, a, c, b, ms, target.index);
    }
    for (final target in targets) {
      final sinceHit =
          ms - MissileTiming.impact(target.index).inMilliseconds.toDouble();
      if (sinceHit >= 0 && sinceHit < _blastMs) {
        _paintBlast(canvas, target.rect, sinceHit);
      }
    }
  }

  void _paintMissile(
    Canvas canvas,
    Offset a,
    Offset c,
    Offset b,
    double ms,
    int index,
  ) {
    final art = missile;
    final launched = ms - index * _staggerMs;
    final eased = progressAt(ms, index);
    if (art == null || eased == null) return;

    final at = along(a, c, b, eased);
    final direction = tangent(a, c, b, eased);
    final angle = headingFor(
      direction.distanceSquared < 1e-6 ? b - a : direction,
    );

    // The exhaust pulses at the file's own pace, round one seamless loop.
    final composition = art.composition;
    final frame =
        MissileArt.flyFrom +
        (launched / 1000 * MissileArt.fps) % MissileArt.flyFrames;
    art.setProgress(
      ((frame - composition.startFrame) / composition.durationFrames).clamp(
        0.0,
        1.0,
      ),
    );

    // It pops out of the firer's pod, and shrinks a touch into the hit.
    final appear = Curves.easeOutBack.transform((launched / 160).clamp(0, 1));
    final arrive = ((launched - _flightMs + 120) / 120).clamp(0.0, 1.0);
    final scale = (0.4 + 0.6 * appear) * (1 - 0.15 * arrive);
    final opacity = (launched / 80).clamp(0.0, 1.0);
    if (opacity <= 0) return;

    final side = _side;
    canvas
      ..save()
      ..translate(at.dx, at.dy)
      ..rotate(angle)
      ..scale(scale)
      ..translate(-side / 2, -side / 2);
    final box = Rect.fromLTWH(0, 0, side, side);
    final fading = opacity < 1;
    if (fading) {
      canvas.saveLayer(
        box,
        Paint()..color = Colors.white.withValues(alpha: opacity),
      );
    }
    art.draw(canvas, box, fit: BoxFit.contain);
    if (fading) canvas.restore();
    canvas.restore();
  }

  /// A thin smoke trail behind the rocket: strongest mid-flight, where it is
  /// fastest, and gone at both ends.
  void _paintTrail(Canvas canvas, Offset a, Offset c, Offset b, double t) {
    final strength = math.sin(t * math.pi);
    if (strength <= 0.02) return;
    final head = Curves.easeInOut.transform(t);
    const span = 0.2;
    const steps = 9;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    var previous = along(a, c, b, math.max(0.0, head - span));
    for (var i = 1; i <= steps; i++) {
      final point = along(
        a,
        c,
        b,
        math.max(0.0, head - span + span * i / steps),
      );
      final k = i / steps;
      paint
        ..strokeWidth = podWidth * 0.06 * k
        ..color = Color.lerp(
          const Color(0xFFFFE2B8),
          const Color(0xFFFF9A8E),
          k,
        )!.withValues(alpha: 0.40 * k * strength);
      canvas.drawLine(previous, point, paint);
      previous = point;
    }
  }

  void _paintBlast(Canvas canvas, Rect pod, double sinceHit) {
    final u = (sinceHit / _blastMs).clamp(0.0, 1.0);

    // A flash on the glass as it lands, gone in a sixth of a second.
    final flash = 1 - (sinceHit / 160).clamp(0.0, 1.0);
    if (flash > 0) {
      canvas.drawCircle(
        pod.center,
        podWidth * (0.35 + 0.25 * (1 - flash)),
        Paint()
          ..color = const Color(0xFFFFE9C2).withValues(alpha: 0.45 * flash)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, podWidth * 0.12),
      );
    }

    final art = explosion;
    if (art == null) return;
    final composition = art.composition;
    art.setProgress(u * (1 - 1e-6));
    final size = _blastSize;
    final origin = MissileArt.blastOrigin;
    final box = Rect.fromLTWH(
      pod.center.dx - size.width * origin.dx,
      pod.center.dy + podWidth * 0.08 - size.height * origin.dy,
      size.width,
      size.height,
    );
    // Its smoke fades out over the last fifth, so it never cuts.
    final fade = 1 - ((u - 0.8) / 0.2).clamp(0.0, 1.0);
    if (fade < 1) {
      canvas.saveLayer(
        box.inflate(2),
        Paint()..color = Colors.white.withValues(alpha: fade),
      );
    }
    art.draw(canvas, box, fit: BoxFit.fill);
    if (fade < 1) canvas.restore();
    assert(composition.durationFrames > 0);
  }

  @override
  bool shouldRepaint(covariant MissilePainter old) =>
      old.clock != clock ||
      old.count != count ||
      old.missile != missile ||
      old.explosion != explosion ||
      old.from != from ||
      old.targets != targets ||
      old.podWidth != podWidth;
}

/// A pod's jolt on a missile's timeline, for [PodImpact], which counts on a
/// Force Sideshow's: the volley's clock mapped so that the missile at [index]
/// landing is the moment [PodImpact] takes for the hammer's.
class MissileImpactClock extends Animation<double>
    with AnimationWithParentMixin<double> {
  MissileImpactClock({
    required this.parent,
    required this.index,
    required this.count,
  });

  @override
  final Animation<double> parent;

  /// This pod's place in the volley.
  final int index;

  /// How many missiles the volley has.
  final int count;

  @override
  double get value {
    final ms = parent.value * MissileTiming.total(count).inMilliseconds;
    final sinceHit = ms - MissileTiming.impact(index).inMilliseconds;
    final t =
        (HammerTiming.impact.inMilliseconds + sinceHit) /
        HammerTiming.total.inMilliseconds;
    return t.clamp(0.0, 1.0);
  }
}
