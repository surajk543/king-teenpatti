import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../state/hammer_strike.dart';
import '../theme/app_theme.dart';

/// `assets/animations/Hammer.json`, parsed once for the life of the app.
///
/// What the file holds (Lottie 5.6.8, 1080x1080, 30 fps, frames 0–60, "39
/// Hammer"): one shape layer — a claw hammer, grip bottom-left, head top-right,
/// its striking face turned down — with a single 2D rotation track about the
/// grip. No 3D orientation (`or`/`rx`/`ry`) and no expressions, so a phone
/// plays exactly what the LottieFiles preview shows (CLAUDE.md §12.3). The
/// track rests to frame 10, winds up to −25° by 30, strikes to +27° at 35,
/// recoils to −25° at 40, strikes again at 45 and settles by 60. The table uses
/// the wind-up while the hammer flies, the first strike as it lands, and a
/// little of the recoil as it leaves.
abstract final class HammerArt {
  static const asset = 'assets/animations/Hammer.json';

  static LottieComposition? _composition;
  static Future<LottieComposition?>? _loading;

  /// The parsed file, once [load] has finished; null before, or if it failed.
  static LottieComposition? get composition => _composition;

  /// Reads and parses the file the first time it is asked for, and hands every
  /// later caller the same result. A failure is remembered as nothing, and
  /// the next call tries again — the strike still shakes the pod without it.
  static Future<LottieComposition?> load() =>
      _loading ??= AssetLottie(asset).load().then<LottieComposition?>(
        (composition) => _composition = composition,
        onError: (Object _) {
          _loading = null;
          return null;
        },
      );

  /// The frames the table plays (see the class comment).
  static const double windUpFrom = 10;
  static const double windUpTo = 30;
  static const double strikeFrame = 35;
  static const double recoilFrame = 38;

  /// Where the striking face meets what it hits at [strikeFrame], as a share
  /// of the canvas. The hammer is placed by this point, so it is the face —
  /// not the middle of the picture — that lands on the pod.
  static const Offset face = Offset(0.80, 0.70);

  /// How far above [face] the drawing reaches at the top of the wind-up, as a
  /// share of the canvas: the claw's tip at frame 30.
  static const double reachAbove = 0.56;

  /// The hammer's forward axis, grip to head, while it winds up: up and to
  /// the right, in radians.
  static const double forward = -58 * math.pi / 180;
}

/// A Force Sideshow's hammer crossing the felt (owner, 14 Sep 2026).
///
/// It leaves the pod of the player who forced the sideshow, flies an arc to
/// the pod it was forced on — turned to face the way it is travelling, winding
/// up as it goes — swings down onto that pod, and goes, leaving a ring and a
/// spray of sparks where it hit. The pod's own jolt is [PodImpact].
///
/// Everything here is painted by one [CustomPainter] that repaints from
/// [clock], so a frame of the flight rebuilds no widget at all: the hammer is
/// the parsed composition drawn at the frame the clock asks for, never a
/// Lottie widget being rebuilt, and never a second parse of the file.
class HammerFlight extends StatefulWidget {
  const HammerFlight({
    super.key,
    required this.clock,
    required this.from,
    required this.target,
    required this.podWidth,
  });

  /// 0 to 1 over [HammerTiming.total], from the moment the strike began.
  final Animation<double> clock;

  /// The asker's pod, in this widget's coordinates.
  final Rect from;

  /// The pod that is hit, in this widget's coordinates.
  final Rect target;

  /// What the felt sizes everything from; the hammer is a little wider.
  final double podWidth;

  @override
  State<HammerFlight> createState() => _HammerFlightState();
}

class _HammerFlightState extends State<HammerFlight> {
  LottieDrawable? _drawable;

  @override
  void initState() {
    super.initState();
    final composition = HammerArt.composition;
    if (composition != null) {
      _drawable = _drawableFor(composition);
    } else {
      // The felt warms the file when the table opens, so this is only the
      // strike that beat it there: the ring and the jolt still land on time.
      unawaited(
        HammerArt.load().then((composition) {
          if (!mounted || composition == null) return;
          setState(() => _drawable = _drawableFor(composition));
        }),
      );
    }
  }

  /// Every frame the clock asks for, not the file's 30 a second: the swing is
  /// only five frames long and would step visibly at its own rate.
  static LottieDrawable _drawableFor(LottieComposition composition) =>
      LottieDrawable(composition, frameRate: FrameRate.max);

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _HammerPainter(
            clock: widget.clock,
            drawable: _drawable,
            from: widget.from,
            target: widget.target,
            podWidth: widget.podWidth,
          ),
        ),
      ),
    );
  }
}

class _HammerPainter extends CustomPainter {
  _HammerPainter({
    required this.clock,
    required this.drawable,
    required this.from,
    required this.target,
    required this.podWidth,
  }) : super(repaint: clock);

  final Animation<double> clock;
  final LottieDrawable? drawable;
  final Rect from;
  final Rect target;
  final double podWidth;

  static final double _flightMs = HammerTiming.flight.inMilliseconds.toDouble();
  static final double _impactMs = HammerTiming.impact.inMilliseconds.toDouble();
  static final double _totalMs = HammerTiming.total.inMilliseconds.toDouble();

  /// The hammer leaves between these two moments, after the recoil.
  static const double _leaveFromMs = 1060;
  static const double _leaveMs = 280;

  /// The hammer's canvas side.
  double get _side => podWidth * 1.3;

  /// Where the face lands: a little above the middle of the pod, where the
  /// picture is — but never so high that the wind-up's claw leaves the top of
  /// the screen, which on a phone's top row it otherwise would.
  Offset get _hitAt => Offset(
    target.center.dx,
    math.max(
      target.center.dy - target.height * 0.12,
      _side * HammerArt.reachAbove + 2,
    ),
  );

  /// The arc's middle control point. It rises between the two pods, like a
  /// throw; where the top of the felt leaves no room for that (two seats on
  /// the top row) it bows down across the table instead.
  Offset _control(Offset a, Offset b) {
    final mid = Offset.lerp(a, b, 0.5)!;
    final lift = ((b - a).distance * 0.32)
        .clamp(podWidth * 0.5, podWidth * 1.8)
        .toDouble();
    // A quadratic's midpoint is (a + 2c + b) / 4; keep the hammer, which
    // reaches [HammerArt.reachAbove] above its face, below the top edge.
    final ceiling = _side * HammerArt.reachAbove + 4;
    final highest = (4 * ceiling - a.dy - b.dy) / 2;
    final raised = math.max(mid.dy - lift, highest);
    if (mid.dy - raised >= lift * 0.4) return Offset(mid.dx, raised);
    return Offset(mid.dx, mid.dy + lift * 0.6);
  }

  static Offset _along(Offset a, Offset c, Offset b, double t) {
    final u = 1 - t;
    return a * (u * u) + c * (2 * u * t) + b * (t * t);
  }

  static Offset _tangent(Offset a, Offset c, Offset b, double t) =>
      (c - a) * (2 * (1 - t)) + (b - c) * (2 * t);

  /// [angle] brought into (−π, π], so easing it to 0 turns the short way.
  static double _wrap(double angle) {
    var a = angle % (2 * math.pi);
    if (a > math.pi) a -= 2 * math.pi;
    return a;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final value = clock.value;
    if (value <= 0 || value >= 1) return;
    final ms = value * _totalMs;

    final a = from.center;
    final b = _hitAt;
    final c = _control(a, b);
    // Thrown from the left, the hammer comes down with its grip to the left,
    // as drawn; thrown from the right, it is mirrored, so the grip is always
    // on the side it came from and the head always swings down onto the pod.
    final mirrored = b.dx < a.dx;

    if (ms >= _impactMs) _paintRing(canvas, ms - _impactMs);
    if (ms < _flightMs) _paintTrail(canvas, size, a, c, b, ms / _flightMs);
    _paintHammer(canvas, size, a, c, b, ms, mirrored);
    if (ms >= _impactMs) _paintSparks(canvas, b, ms - _impactMs);
  }

  /// How far into the flight the hammer has turned from head-first into the
  /// pose it strikes from: 0 for the first half, easing to 1 on arrival.
  static double _settleAt(double flight) =>
      Curves.easeInOut.transform(((flight - 0.45) / 0.55).clamp(0.0, 1.0));

  /// Where the face is drawn at [along] of the arc, kept far enough inside the
  /// felt that the whole hammer is on screen.
  ///
  /// Turned head-first the drawing can reach [_flyingReach] of its canvas from
  /// the face in any direction — the handle trails behind it — so a flight
  /// between the two top seats, which is the whole width of the top of a
  /// phone, used to carry the handle off the top edge. As the hammer turns
  /// upright the floor eases down to what the strike pose needs, which is
  /// exactly where [_hitAt] already stands, and the sideways clamp lets go:
  /// the upright pose keeps its handle on the side it came from, so it never
  /// leaves the felt, and the face lands on the pod with no jump.
  Offset _faceAt(Size size, Offset a, Offset c, Offset b, double along) {
    final at = _along(a, c, b, along);
    final settle = _settleAt(along);
    final side = _side;
    final reach = side * _lerp(_flyingReach, HammerArt.reachAbove, settle);
    final y = math.max(at.dy, reach + 2);
    final room = size.width - 2 * reach;
    final x = room <= 0
        ? size.width / 2
        : at.dx.clamp(reach, size.width - reach).toDouble();
    return Offset(_lerp(x, at.dx, settle), y);
  }

  /// How far above the face the floor keeps the drawing while it flies, as a
  /// share of the canvas. 0.68 — the claw's tip at the top of the wind-up —
  /// still let the handle's end leave the top edge for three frames of a
  /// left-to-top-right flight on a 640dp phone (QA 14 Sep 2026), half-turned
  /// between head-first and upright; 0.95 covers the handle at that angle, and
  /// the floor still eases to [HammerArt.reachAbove] on arrival, so the face
  /// lands where it did.
  static const double _flyingReach = 0.95;

  void _paintHammer(
    Canvas canvas,
    Size size,
    Offset a,
    Offset c,
    Offset b,
    double ms,
    bool mirrored,
  ) {
    final art = drawable;
    if (art == null || ms >= _leaveFromMs + _leaveMs) return;

    final flight = (ms / _flightMs).clamp(0.0, 1.0);
    final along = Curves.easeInOutCubic.transform(flight);
    final at = _faceAt(size, a, c, b, along);

    // Head first along the arc for the first half of the flight, then easing
    // round into the pose it strikes from, which is the drawing's own.
    final tangent = _tangent(a, c, b, along);
    final travel = tangent.distanceSquared < 1e-6
        ? (b - a).direction
        : tangent.direction;
    final forward = mirrored ? math.pi - HammerArt.forward : HammerArt.forward;
    final settle = _settleAt(flight);
    final angle = _wrap(travel - forward) * (1 - settle);

    // The swing: wound up across the flight, down onto the pod by the impact,
    // then a short recoil as it leaves.
    final double frame;
    if (ms < _flightMs) {
      frame = _lerp(
        HammerArt.windUpFrom,
        HammerArt.windUpTo,
        Curves.easeInOut.transform(flight),
      );
    } else if (ms < _impactMs) {
      frame = _lerp(
        HammerArt.windUpTo,
        HammerArt.strikeFrame,
        Curves.easeInQuad.transform((ms - _flightMs) / (_impactMs - _flightMs)),
      );
    } else {
      frame = _lerp(
        HammerArt.strikeFrame,
        HammerArt.recoilFrame,
        Curves.easeOutCubic.transform(((ms - _impactMs) / 200).clamp(0.0, 1.0)),
      );
    }
    final composition = art.composition;
    art.setProgress(
      (frame - composition.startFrame) / composition.durationFrames,
    );

    // It pops out of the asker's pod, and lifts away and fades once it has
    // struck.
    final appear = Curves.easeOutBack.transform((ms / 160).clamp(0.0, 1.0));
    final leave = Curves.easeIn.transform(
      ((ms - _leaveFromMs) / _leaveMs).clamp(0.0, 1.0),
    );
    final scale = (0.45 + 0.55 * appear) * (1 - 0.2 * leave);
    final opacity = (ms / 90).clamp(0.0, 1.0) * (1 - leave);
    if (opacity <= 0) return;

    final side = _side;
    canvas
      ..save()
      ..translate(at.dx, at.dy - leave * podWidth * 0.2)
      ..rotate(angle)
      ..scale(mirrored ? -scale : scale, scale)
      ..translate(-HammerArt.face.dx * side, -HammerArt.face.dy * side);
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

  /// A short gold streak behind the head, so the throw reads as motion rather
  /// than as a picture sliding.
  void _paintTrail(
    Canvas canvas,
    Size size,
    Offset a,
    Offset c,
    Offset b,
    double flight,
  ) {
    final along = Curves.easeInOutCubic.transform(flight);
    const steps = 10;
    final span = 0.22;
    // Strongest mid-flight, where the hammer is fastest; nothing at the ends.
    final strength = math.sin(flight * math.pi);
    if (strength <= 0.02) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    // Along the path the face was actually drawn on, so the streak stays
    // behind the hammer where the felt's edge moved it.
    var previous = _faceAt(size, a, c, b, math.max(0.0, along - span));
    for (var i = 1; i <= steps; i++) {
      final t = math.max(0.0, along - span + span * i / steps);
      final point = _faceAt(size, a, c, b, t);
      final k = i / steps;
      paint
        ..strokeWidth = podWidth * 0.07 * k
        ..color = AppTheme.goldBright.withValues(alpha: 0.42 * k * strength);
      canvas.drawLine(previous, point, paint);
      previous = point;
    }
  }

  /// The pod's outline thrown outwards from the hit, with a flash behind it.
  void _paintRing(Canvas canvas, double sinceHit) {
    final radius = podWidth * 0.11;

    // A flash of light on the glass, gone in a fifth of a second.
    final flash = 1 - (sinceHit / 200).clamp(0.0, 1.0);
    if (flash > 0) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(target, Radius.circular(radius)),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.30 * flash)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, podWidth * 0.08),
      );
    }

    for (final (delay, colour, weight) in [
      (0.0, AppTheme.goldBright, 0.055),
      (70.0, Colors.white, 0.03),
    ]) {
      final u = ((sinceHit - delay) / 460).clamp(0.0, 1.0);
      if (u <= 0 || u >= 1) continue;
      final grow = Curves.easeOutCubic.transform(u);
      final spread = podWidth * 0.34 * grow;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          target.inflate(spread),
          Radius.circular(radius + spread),
        ),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = podWidth * weight * (1 - u) + 0.8
          ..color = colour.withValues(alpha: 0.9 * (1 - u)),
      );
    }
  }

  /// Sparks from the point the face struck.
  void _paintSparks(Canvas canvas, Offset at, double sinceHit) {
    final u = (sinceHit / 360).clamp(0.0, 1.0);
    if (u >= 1) return;
    final k = Curves.easeOutCubic.transform(u);
    const count = 10;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      final angle = -math.pi / 2 + (i + 0.5) * 2 * math.pi / count;
      final long = i.isEven;
      final inner = podWidth * (0.10 + (long ? 0.62 : 0.44) * k);
      final length = podWidth * (long ? 0.20 : 0.13) * (1 - k);
      final direction = Offset(math.cos(angle), math.sin(angle));
      paint
        ..strokeWidth = (long ? 2.6 : 1.8) * (1 - k) + 0.6
        ..color = (long ? AppTheme.goldBright : Colors.white).withValues(
          alpha: 1 - u,
        );
      canvas.drawLine(
        at + direction * inner,
        at + direction * (inner + length),
        paint,
      );
    }
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  bool shouldRepaint(covariant _HammerPainter old) =>
      old.clock != clock ||
      old.drawable != drawable ||
      old.from != from ||
      old.target != target ||
      old.podWidth != podWidth;
}

/// The jolt a pod takes when the hammer lands on it: knocked down and
/// squashed, then shaken back into place over [HammerTiming.shake].
///
/// Always in the tree, whether or not a strike is running, so the pod under
/// it keeps its state (its turn ring, its playing picture) when one starts and
/// when one ends. The child sits on its own layer, so a frame of the jolt moves
/// that layer and repaints nothing inside it.
class PodImpact extends StatelessWidget {
  const PodImpact({
    super.key,
    required this.clock,
    required this.width,
    required this.child,
  });

  /// The strike's clock while this pod is the one being hit; null otherwise.
  final Animation<double>? clock;

  /// The pod's width, which the jolt is measured in.
  final double width;
  final Widget child;

  /// Where the pod is at [t] (0 to 1 over [HammerTiming.total]): still until
  /// the impact, then a damped shake.
  static Matrix4 jolt(double t, double width) {
    final u =
        (t - HammerTiming.share(HammerTiming.impact)) /
        HammerTiming.share(HammerTiming.shake);
    if (u <= 0 || u >= 1) return Matrix4.identity();
    final damp = math.exp(-4 * u) * (1 - u);
    final dx = width * 0.05 * damp * math.sin(u * math.pi * 7);
    final dy = width * 0.06 * damp * math.cos(u * math.pi * 4.5);
    final squash = 1 - 0.10 * damp * math.cos(u * math.pi * 3);
    final tilt = 0.05 * damp * math.sin(u * math.pi * 5);
    return Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..rotateZ(tilt)
      ..scaleByDouble(squash, squash, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    final clock = this.clock;
    return AnimatedBuilder(
      animation: clock ?? kAlwaysDismissedAnimation,
      child: RepaintBoundary(child: child),
      builder: (context, child) => Transform(
        alignment: Alignment.center,
        transform: clock == null
            ? Matrix4.identity()
            : jolt(clock.value, width),
        child: child,
      ),
    );
  }
}
