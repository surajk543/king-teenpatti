// The depth pass (owner, 28 Sep 2026: "Make the existing UI feel physically
// layered and naturally elevated ... nested elevation ... Improve depth, not
// decoration"): the one ladder every surface is lit and shadowed by
// (lib/theme/depth.dart), and the two promises that come with it — the light
// moves nothing, and a translucent surface's shadow never changes its colour.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/depth.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/glass_components.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

/// How far a shadow reaches below its surface: its drop and its blur.
double _reach(List<BoxShadow> shadows) =>
    shadows.fold(0, (r, s) => math.max(r, s.offset.dy + s.blurRadius));

/// The painter [SurfaceLight] found under [of], or null.
SurfaceLight? _lightUnder(WidgetTester tester, Finder of) {
  for (final paint in tester.widgetList<CustomPaint>(
    find.descendant(of: of, matching: find.byType(CustomPaint)),
  )) {
    if (paint.painter is SurfaceLight) return paint.painter! as SurfaceLight;
  }
  return null;
}

Widget _app(Widget child, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      theme: brightness == Brightness.dark
          ? AppTheme.dark(sound: false)
          : AppTheme.light(sound: false),
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  group('the ladder', () {
    test('each step casts a shadow that says how far it stands above what '
        'is directly under it: a raised key the least, an overlay the most, '
        'the room and a well nothing', () {
      for (final b in Brightness.values) {
        final d = Depth.forBrightness(b);
        expect(d.shadows(Elevation.ground), isEmpty, reason: b.name);
        expect(d.shadows(Elevation.well), isEmpty, reason: b.name);
        final raised = _reach(d.shadows(Elevation.raised));
        final card = _reach(d.shadows(Elevation.card));
        final overlay = _reach(d.shadows(Elevation.overlay));
        expect(raised, lessThan(card), reason: b.name);
        expect(card, lessThan(overlay), reason: b.name);
        // An overlay keeps the card's own pair and throws its reach beyond.
        expect(d.shadows(Elevation.overlay), [
          ...d.shadows(Elevation.card),
          ...d.overlayReach,
        ]);
        // Every shadow is the theme's own colour.
        for (final level in Elevation.values) {
          for (final s in d.shadows(level)) {
            expect(
              s.color.withValues(alpha: 1),
              AppTheme.shadowFor(b),
              reason: '${b.name} ${level.name}',
            );
          }
        }
      }
    });

    test(
      'a pane standing on the room casts exactly the shadow it always did',
      () {
        // AppTheme.glassShadow as it was before the ladder: 0.45/0.08 over 8dp,
        // 3 down, and 0.35/0.10 over 28dp, 12 down.
        for (final (b, contact, ambient) in [
          (Brightness.dark, 0.45, 0.35),
          (Brightness.light, 0.08, 0.10),
        ]) {
          final s = AppTheme.shadowFor(b);
          expect(AppTheme.glassShadow(b), [
            BoxShadow(
              color: s.withValues(alpha: contact),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
            BoxShadow(
              color: s.withValues(alpha: ambient),
              blurRadius: 28,
              offset: const Offset(0, 12),
            ),
          ]);
        }
      },
    );

    test('by night a surface is lit from above and shaded at its foot; by day '
        'its edge carries it and nothing washes its face', () {
      final night = Depth.forBrightness(Brightness.dark);
      final day = Depth.forBrightness(Brightness.light);
      for (final level in [
        Elevation.card,
        Elevation.raised,
        Elevation.overlay,
      ]) {
        final n = night.light(level);
        expect(n.rim.a, greaterThan(0), reason: level.name);
        expect(n.foot.a, greaterThan(0), reason: level.name);
        expect(n.recessed, isFalse);
        final d = day.light(level);
        expect(d.rim.a, greaterThan(0), reason: level.name);
        expect(d.top.a, 0, reason: 'by day, ${level.name}');
      }
      // A breath of light over a card's and a key's upper part by night — and
      // a breath only.
      for (final level in [Elevation.card, Elevation.raised]) {
        expect(night.light(level).top.a, inExclusiveRange(0, 0.08));
      }
      // No wash over the upper part of a whole dialog or sheet.
      expect(night.light(Elevation.overlay).top.a, 0);
    });

    test('a well is the light turned over: its top inside edge in shade and a '
        'lit lip at its foot', () {
      for (final b in Brightness.values) {
        final well = Depth.forBrightness(b).light(Elevation.well);
        expect(well.recessed, isTrue);
        expect(well.rim.withValues(alpha: 1), AppTheme.shadowFor(b));
        expect(well.foot.withValues(alpha: 1), Colors.white);
        expect(well.top.a, 0);
      }
    });

    testWidgets('the ladder cross-fades with the theme rather than snapping '
        'at its middle', (tester) async {
      double rimAt(DepthScheme d) => d.light(Elevation.raised).rim.a;
      final night = rimAt(Depth.forBrightness(Brightness.dark));
      final day = rimAt(Depth.forBrightness(Brightness.light));
      late double halfway;
      final base = AppTheme.dark(sound: false);
      await tester.pumpWidget(
        Theme(
          data: base.copyWith(
            extensions: [GlassColors.dark.lerp(GlassColors.light, 0.5)],
          ),
          child: Builder(
            builder: (context) {
              halfway = rimAt(Depth.of(context));
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(halfway, inExclusiveRange(night, day));
    });
  });

  group('the light moves nothing', () {
    testWidgets('a surface lit by DepthFace is exactly the size and place it '
        'was', (tester) async {
      const content = SizedBox(width: 120, height: 40);
      await tester.pumpWidget(
        _app(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              KeyedSubtree(key: ValueKey('plain'), child: content),
              DepthFace(key: ValueKey('lit'), radius: Radii.md, child: content),
            ],
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('lit'))),
        tester.getSize(find.byKey(const ValueKey('plain'))),
      );
    });

    testWidgets('a key is lit while it can be pressed and sits flush when it '
        'cannot', (tester) async {
      for (final live in [true, false]) {
        await tester.pumpWidget(
          _app(
            GlassButton(
              key: const ValueKey('key'),
              label: 'Join',
              onPressed: live ? () {} : null,
            ),
          ),
        );
        final light = _lightUnder(tester, find.byKey(const ValueKey('key')));
        if (live) {
          expect(light, isNotNull);
          expect(light!.light.rim.a, greaterThan(0));
        } else {
          expect(light, isNull, reason: 'a dead key sits flush');
        }
      }
      // The flat half of a dialog's pair stays flat.
      await tester.pumpWidget(
        _app(
          GlassButton(
            key: const ValueKey('flat'),
            label: 'Stay',
            style: GlassButtonStyle.text,
            onPressed: () {},
          ),
        ),
      );
      expect(_lightUnder(tester, find.byKey(const ValueKey('flat'))), isNull);
    });

    testWidgets('a dialog, a drawer and a sheet stand at the top of the '
        'ladder, a capsule one step up, a pane on the room at card height', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PremiumGlassPanel(
                key: ValueKey('pane'),
                padding: EdgeInsets.all(8),
                child: SizedBox(width: 60, height: 20),
              ),
              PremiumGlassPanel(
                key: ValueKey('overlay'),
                depth: Elevation.overlay,
                padding: EdgeInsets.all(8),
                child: SizedBox(width: 60, height: 20),
              ),
            ],
          ),
        ),
      );
      // The overlay throws its reach round itself (outside its body only);
      // the pane casts its own pair as it always has, and no reach.
      OuterShadow? reachOf(String key) {
        for (final paint in tester.widgetList<CustomPaint>(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(CustomPaint),
          ),
        )) {
          final painter = paint.painter;
          if (painter is OuterShadow) return painter;
        }
        return null;
      }

      expect(reachOf('pane'), isNull);
      final reach = reachOf('overlay');
      expect(reach, isNotNull);
      expect(reach!.shadows, Depth.forBrightness(Brightness.dark).overlayReach);
    });
  });

  testWidgets('a translucent surface casts round itself and never under '
      'itself: its own colour is what it was', (tester) async {
    // The binding draws every shadow as a solid block unless told not to;
    // this one is looked at, so it is drawn soft, and put back before the
    // binding checks its painting switches.
    debugDisableShadows = false;
    try {
      const pill = Size(120, 44);
      final fill = Colors.white.withValues(alpha: 0.30);
      final key = GlobalKey();
      Future<ui.Image> shoot(bool shadowed) async {
        final surface = DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
          child: SizedBox.fromSize(size: pill),
        );
        await tester.pumpWidget(
          _app(
            RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: const Color(0xFF808080),
                child: Padding(
                  padding: const EdgeInsets.all(30),
                  child: shadowed
                      ? DepthShadow(radius: Radii.pill, child: surface)
                      : surface,
                ),
              ),
            ),
          ),
        );
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        return (await tester.runAsync(() => boundary.toImage()))!;
      }

      Future<Color> at(ui.Image image, Offset p) async {
        final bytes = (await tester.runAsync(
          () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
        ))!;
        final i = (p.dy.toInt() * image.width + p.dx.toInt()) * 4;
        return Color.fromARGB(
          255,
          bytes.getUint8(i),
          bytes.getUint8(i + 1),
          bytes.getUint8(i + 2),
        );
      }

      final plain = await shoot(false);
      final lifted = await shoot(true);
      // The middle of the pill, and just under its foot.
      final middle = Offset(30 + pill.width / 2, 30 + pill.height / 2);
      final under = Offset(30 + pill.width / 2, 30 + pill.height + 4);
      expect(await at(lifted, middle), await at(plain, middle));
      final shade = (await at(lifted, under)).computeLuminance();
      final room = (await at(plain, under)).computeLuminance();
      expect(
        shade,
        lessThan(room),
        reason: 'the room under its foot is shaded',
      );
      plain.dispose();
      lifted.dispose();
    } finally {
      debugDisableShadows = true;
    }
  });
}
