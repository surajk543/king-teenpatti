// What the screen paints over a box, by the order it really paints in — not
// by a model of which seat comes after which (the fifth look at the emoji
// placement, 29 Sep 2026: a line a later seat said after an emoji had landed
// covered it, where the model of what a seat paints had no words yet).
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where [box] stands on the screen: the box round its four corners, however
/// it is transformed (a card leaning in its fan, a bubble followed from
/// another layer).
Rect screenRectOf(RenderBox box) {
  final corners = [
    Offset.zero,
    box.size.topRight(Offset.zero),
    box.size.bottomLeft(Offset.zero),
    box.size.bottomRight(Offset.zero),
  ].map(box.localToGlobal);
  return Rect.fromLTRB(
    corners.map((c) => c.dx).reduce((a, b) => a < b ? a : b),
    corners.map((c) => c.dy).reduce((a, b) => a < b ? a : b),
    corners.map((c) => c.dx).reduce((a, b) => a > b ? a : b),
    corners.map((c) => c.dy).reduce((a, b) => a > b ? a : b),
  );
}

/// For each of [boxes], everything the screen paints AFTER it — later in the
/// render tree's paint order, so drawn over it — that puts paint more than
/// [slack] inside its edge: a word, a filled, outlined or shadowed shape, a
/// picture, a painter, an animation. Each named by the widgets that drew it
/// and where it stands; found in one walk of the screen. Nothing under a
/// subtree that paints nothing (an opacity of 0, an offstage child) counts,
/// nor anything inside one of [boxes], nor anything under [skipping] — what
/// the caller knows is drawn over everything on purpose.
Map<RenderBox, List<String>> drawnOverEach(
  WidgetTester tester,
  Iterable<RenderBox> boxes, {
  double slack = 1,
  Iterable<RenderObject> skipping = const [],
}) {
  final skip = skipping.toSet();
  final targets = {for (final b in boxes) b: screenRectOf(b).deflate(slack)};
  final found = {for (final b in targets.keys) b: <String>[]};
  // The boxes already painted: whatever comes after is drawn over them.
  final passed = <RenderBox>[];
  void visit(RenderObject r) {
    if (r is RenderBox && targets.containsKey(r)) {
      passed.add(r);
      return;
    }
    if (skip.contains(r) || _paintsNothing(r)) return;
    if (passed.isNotEmpty && r is RenderBox && r.hasSize && _paints(r)) {
      final at = screenRectOf(r);
      for (final target in passed) {
        if (at.overlaps(targets[target]!)) {
          found[target]!.add('${_describe(r)} $at');
        }
      }
    }
    r.visitChildren(visit);
  }

  for (final view in tester.binding.renderViews) {
    visit(view);
  }
  return found;
}

/// Where [r] is, as a subtree, known to paint nothing at all.
bool _paintsNothing(RenderObject r) => switch (r) {
  RenderOpacity(:final opacity) => opacity == 0,
  RenderAnimatedOpacity(:final opacity) => opacity.value == 0,
  RenderOffstage(:final offstage) => offstage,
  _ => false,
};

/// Whether [r] itself puts paint on the screen.
bool _paints(RenderBox r) => switch (r) {
  RenderParagraph() => r.text.toPlainText().trim().isNotEmpty,
  RenderDecoratedBox(:final decoration) => _decorationPaints(decoration),
  RenderPhysicalModel() => r.color.a > 0 || r.elevation > 0,
  RenderPhysicalShape() => r.color.a > 0 || r.elevation > 0,
  RenderCustomPaint() => r.painter != null || r.foregroundPainter != null,
  RenderImage() => r.image != null,
  _ => switch (r.runtimeType.toString()) {
    '_RenderColoredBox' || 'RenderEditable' => true,
    final type =>
      type.contains('Lottie') ||
          type.contains('Picture') ||
          type.contains('VectorGraphic'),
  },
};

bool _decorationPaints(Decoration decoration) => switch (decoration) {
  BoxDecoration(
    :final color,
    :final gradient,
    :final image,
    :final border,
    :final boxShadow,
  ) =>
    (color != null && color.a > 0) ||
        gradient != null ||
        image != null ||
        border != null ||
        (boxShadow?.isNotEmpty ?? false),
  ShapeDecoration(
    :final color,
    :final gradient,
    :final image,
    :final shadows,
  ) =>
    (color != null && color.a > 0) ||
        gradient != null ||
        image != null ||
        (shadows?.isNotEmpty ?? false),
  _ => true,
};

/// The widgets that drew [r], from the nearest out: its own, then up to two
/// that say where it is — a private widget of the app, a keyed one.
String _describe(RenderObject r) {
  final creator = r.debugCreator;
  if (creator is! DebugCreator) return r.runtimeType.toString();
  final names = <String>[creator.element.widget.runtimeType.toString()];
  creator.element.visitAncestorElements((e) {
    final widget = e.widget;
    final type = widget.runtimeType.toString();
    final key = widget.key;
    if (key is ValueKey<String>) {
      names.add("'${key.value}'");
    } else if (type.startsWith('_') || type == 'SeatPod') {
      names.add(type);
    }
    return names.length < 4;
  });
  return names.join(' in ');
}
