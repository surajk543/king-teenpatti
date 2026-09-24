import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../theme/app_theme.dart';

/// Fades a scrolling list out at an edge for as long as there is more of it
/// beyond that edge — and only then (table polish, 24 Sep 2026: "the current
/// design intentionally allows adjacent cards to partially appear … make the
/// clipping intentional and polished"). A line cut in half by the edge of a
/// drawer or a sheet read as clipped by accident; faded, it reads as "there is
/// more this way", and the first and last lines are never dimmed when the list
/// is at its end.
///
/// Wraps the scrollable itself (the list's own notifications are the ones it
/// reads, depth 0) and works either way round and on either axis: a reversed
/// list, like the chat, fades at the top while there is older conversation
/// above. The tree under it is the same whatever it shows — the mask only
/// changes its gradient — so the list keeps its scroll position and state.
class EdgeFade extends StatefulWidget {
  const EdgeFade({super.key, required this.child, this.extent = Space.xl});

  /// The scrollable to fade.
  final Widget child;

  /// How far in from an edge the fade reaches.
  final double extent;

  @override
  State<EdgeFade> createState() => EdgeFadeState();
}

/// Public so a test can ask what is faded ([fadesStart], [fadesEnd]); nothing
/// else needs it.
class EdgeFadeState extends State<EdgeFade> {
  /// More beyond the visual start (top, or left) and the visual end.
  bool _start = false;
  bool _end = false;
  Axis _axis = Axis.vertical;

  /// Whether the list is faded at its visual start (top, or left) — that is,
  /// whether there is more of it beyond that edge.
  bool get fadesStart => _start;

  /// Whether the list is faded at its visual end (bottom, or right).
  bool get fadesEnd => _end;

  bool _read(ScrollMetrics metrics, int depth) {
    if (depth != 0) return false;
    final reversed =
        metrics.axisDirection == AxisDirection.up ||
        metrics.axisDirection == AxisDirection.left;
    final before = metrics.extentBefore > 0.5;
    final after = metrics.extentAfter > 0.5;
    final start = reversed ? after : before;
    final end = reversed ? before : after;
    final axis = axisDirectionToAxis(metrics.axisDirection);
    if (start == _start && end == _end && axis == _axis) return false;
    void apply() {
      if (!mounted) return;
      setState(() {
        _start = start;
        _end = end;
        _axis = axis;
      });
    }

    // A notification can arrive while the frame is being laid out, where
    // setState is not allowed; then it waits for the frame to finish.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    const solid = Color(0xFF000000);
    const clear = Color(0x00000000);
    final vertical = _axis == Axis.vertical;

    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final length = vertical ? rect.height : rect.width;
        final reach = length <= 0
            ? 0.0
            : (widget.extent / length).clamp(0.0, 0.5).toDouble();
        return LinearGradient(
          begin: vertical ? Alignment.topCenter : Alignment.centerLeft,
          end: vertical ? Alignment.bottomCenter : Alignment.centerRight,
          colors: [_start ? clear : solid, solid, solid, _end ? clear : solid],
          stops: [0, reach, 1 - reach, 1],
        ).createShader(rect);
      },
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) => _read(n.metrics, n.depth),
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) => _read(n.metrics, n.depth),
          child: widget.child,
        ),
      ),
    );
  }
}
