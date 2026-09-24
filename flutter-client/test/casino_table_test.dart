// The casino table the Teen Patti seats stand round (owner's brief, 24 Sep
// 2026: "a large oval/rounded casino table surface ... LIGHT MODE:
// pearl/ivory outer table; subtle emerald/teal or champagne playing surface;
// thin premium gold/champagne rim ... DARK MODE: dark graphite outer table;
// deep emerald/black playing surface; subtle gold rim ... Do NOT use the
// old-fashioned red casino table aesthetic"): its colours in both themes, the
// table's words still legible on it, where it stands against the seats that
// were there before it, and what paints over it.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/casino_table.dart';
import 'package:teenpatti/widgets/drifting_chips.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'table_scenes.dart';

TableScene _scene(String prefix) =>
    tableScenes.firstWhere((s) => s.name.startsWith(prefix));

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

/// [ink] laid over [ground], as the eye sees it.
Color _over(Color ink, Color ground) => Color.alphaBlend(ink, ground);

double _hue(Color c) => HSVColor.fromColor(c).hue;

Future<GameState> _mount(
  WidgetTester tester,
  TableScene scene, {
  Size size = const Size(891, 411),
  double textScale = 1.0,
  bool dark = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = sceneState(scene);
  await tester.pumpWidget(
    tableApp(
      state: state,
      feedback: feedback,
      theme: dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
    ),
  );
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 900));
  return state;
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

void main() {
  group('its colours', () {
    test('both themes carry the table, and it cross-fades with them', () {
      expect(
        AppTheme.light(sound: false).extension<CasinoTableColors>(),
        CasinoTableColors.light,
      );
      expect(
        AppTheme.dark(sound: false).extension<CasinoTableColors>(),
        CasinoTableColors.dark,
      );
      final half = CasinoTableColors.light.lerp(CasinoTableColors.dark, 0.5);
      expect(
        half.feltCentre,
        Color.lerp(
          CasinoTableColors.light.feltCentre,
          CasinoTableColors.dark.feltCentre,
          0.5,
        ),
      );
      expect(half.shadowBlur, closeTo(20, 1e-9));
    });

    test('by day: a pearl rail, a pale emerald cloth, a champagne rim', () {
      const c = CasinoTableColors.light;
      expect(c.railTop.computeLuminance(), greaterThan(0.85));
      expect(c.railBottom.computeLuminance(), greaterThan(0.65));
      for (final felt in [c.feltCentre, c.feltEdge]) {
        expect(felt.computeLuminance(), greaterThan(0.6));
        expect(_hue(felt), inInclusiveRange(140, 180), reason: '$felt');
      }
      expect(_hue(c.rim), inInclusiveRange(35, 50));
      // No glow on a pale floor: it reads as a smudge.
      expect(c.glow.a, 0);
    });

    test('by night: graphite, deep emerald, a subtler gold, a cyan glow', () {
      const c = CasinoTableColors.dark;
      expect(c.railTop.computeLuminance(), lessThan(0.05));
      for (final felt in [c.feltCentre, c.feltEdge]) {
        expect(felt.computeLuminance(), lessThan(0.05));
        expect(_hue(felt), inInclusiveRange(140, 180), reason: '$felt');
      }
      expect(_hue(c.rim), inInclusiveRange(35, 50));
      expect(c.rim.a, lessThan(CasinoTableColors.light.rim.a));
      expect(_hue(c.glow), inInclusiveRange(165, 185));
      expect(c.glow.a, lessThan(0.25));
    });

    test('never the red table', () {
      for (final c in [CasinoTableColors.light, CasinoTableColors.dark]) {
        for (final felt in [c.feltCentre, c.feltEdge]) {
          final h = _hue(felt);
          expect(h > 20 && h < 330, isTrue, reason: '$felt');
        }
      }
    });

    test('the table\'s words still read on the cloth', () {
      for (final (theme, c) in [
        (AppTheme.light(sound: false), CasinoTableColors.light),
        (AppTheme.dark(sound: false), CasinoTableColors.dark),
      ]) {
        final dark = theme.brightness == Brightness.dark;
        // The seat's status line and the waiting line, in the inks they
        // are written in (seat_pod.dart, table_screen.dart _Status).
        final status = theme.colorScheme.onSurface;
        final waiting = dark
            ? AppTheme.boneInk.withValues(alpha: 0.82)
            : AppTheme.inkOnLight.withValues(alpha: 0.78);
        for (final felt in [c.feltCentre, c.feltEdge]) {
          expect(
            _contrast(status, felt),
            greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness} status on $felt',
          );
          expect(
            _contrast(_over(waiting, felt), felt),
            greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness} waiting line on $felt',
          );
        }
        // And on the rail, where a top seat's words can land.
        for (final rail in [c.railTop, c.railBottom]) {
          expect(
            _contrast(status, rail),
            greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness} status on the rail',
          );
        }
      }
    });
  });

  group('its painter', () {
    Future<ui.Image> paint(WidgetTester tester, bool dark) async {
      const size = Size(600, 300);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: dark
              ? AppTheme.dark(sound: false)
              : AppTheme.light(sound: false),
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox.fromSize(
                size: size,
                child: CasinoTableSurface(
                  geometry: TableGeometry.of(size),
                  detailed: false,
                ),
              ),
            ),
          ),
        ),
      );
      late ui.Image image;
      await tester.runAsync(() async {
        image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
      });
      return image;
    }

    Future<Color> pixel(WidgetTester tester, ui.Image image, Offset at) async {
      late ByteData data;
      await tester.runAsync(() async {
        data = (await image.toByteData())!;
      });
      final i = (at.dy.round() * image.width + at.dx.round()) * 4;
      return Color.fromARGB(
        data.getUint8(i + 3),
        data.getUint8(i),
        data.getUint8(i + 1),
        data.getUint8(i + 2),
      );
    }

    for (final dark in [true, false]) {
      testWidgets('draws its own colours (${dark ? 'dark' : 'light'})', (
        tester,
      ) async {
        final c = dark ? CasinoTableColors.dark : CasinoTableColors.light;
        final image = await paint(tester, dark);
        final geometry = TableGeometry.of(const Size(600, 300));
        final cloth = geometry.cloth.outerRect;

        // The middle of the cloth is the cloth's own light.
        final middle = await pixel(tester, image, cloth.center);
        expect(middle.a, closeTo(1, 0.01));
        for (final (a, b) in [
          (middle.r, c.feltCentre.r),
          (middle.g, c.feltCentre.g),
          (middle.b, c.feltCentre.b),
        ]) {
          expect(a, closeTo(b, 0.08));
        }
        // The far rail between the rim and the cloth is the rail's colour,
        // pearl by day and graphite by night.
        final rail = await pixel(
          tester,
          image,
          Offset(300, geometry.outer.top + geometry.rail * 0.55),
        );
        expect(
          rail.computeLuminance(),
          dark ? lessThan(0.1) : greaterThan(0.7),
        );
        // Outside the table: nothing but the shadow's soft edge, far from it.
        final room = await pixel(tester, image, const Offset(2, 2));
        expect(room.a, lessThan(0.05));
        image.dispose();
      });
    }

    test('repaints only when the table or the theme changes', () {
      final g = TableGeometry.of(const Size(600, 300));
      final a = CasinoTablePainter(
        geometry: g,
        colours: CasinoTableColors.dark,
        detailed: true,
      );
      expect(
        a.shouldRepaint(
          CasinoTablePainter(
            geometry: TableGeometry.of(const Size(600, 300)),
            colours: CasinoTableColors.dark,
            detailed: true,
          ),
        ),
        isFalse,
      );
      expect(
        a.shouldRepaint(
          CasinoTablePainter(
            geometry: g,
            colours: CasinoTableColors.light,
            detailed: true,
          ),
        ),
        isTrue,
      );
    });
  });

  group('where it stands', () {
    test('a stadium across the felt, with a rail held to 9..18', () {
      final g = TableGeometry.of(const Size(569, 358));
      expect(g.outer.left, closeTo(569 * TableGeometry.left, 1e-9));
      expect(g.outer.right, closeTo(569 * TableGeometry.right, 1e-9));
      expect(g.rimTop, closeTo(358 * TableGeometry.top, 1e-9));
      expect(g.outer.bottom, closeTo(358 * TableGeometry.bottom, 1e-9));
      // Semicircle ends.
      expect(g.outer.tlRadiusX, closeTo(g.outer.height / 2, 1e-9));
      expect(g.rail, closeTo(358 * TableGeometry.railShare, 1e-9));
      expect(TableGeometry.of(const Size(200, 100)).rail, 9);
      expect(TableGeometry.of(const Size(1600, 900)).rail, 18);
    });

    for (final (size, scale) in [
      (const Size(640, 360), 1.25),
      (const Size(732, 412), 1.0),
      (const Size(915, 412), 1.25),
    ]) {
      testWidgets('it meets the seats where they were, at '
          '${size.width.toInt()}x${size.height.toInt()} x$scale', (
        tester,
      ) async {
        for (final dark in [true, false]) {
          final state = await _mount(
            tester,
            _scene('03'),
            size: size,
            textScale: scale,
            dark: dark,
          );
          final surface = find.byType(CasinoTableSurface);
          final felt = tester.getRect(surface);
          final g = tester.widget<CasinoTableSurface>(surface).geometry;
          final outer = g.outer.outerRect.shift(felt.topLeft);

          // The pot on the cloth.
          final pot = tester.getRect(
            find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Pot'),
          );
          expect(
            g.cloth.outerRect.shift(felt.topLeft).contains(pot.center),
            isTrue,
          );

          // Every seat's pod on the rail: the two top seats straddle the far
          // rail, the side seats its ends, and the viewer the near rail.
          final pods = find.byType(SeatPod);
          expect(pods, findsNWidgets(5));
          for (var i = 0; i < 5; i++) {
            final pod = tester.getRect(pods.at(i));
            expect(pod.overlaps(outer), isTrue, reason: 'seat $i');
            expect(
              outer.contains(pod.topLeft) &&
                  outer.contains(pod.topRight) &&
                  outer.contains(pod.bottomLeft) &&
                  outer.contains(pod.bottomRight),
              isFalse,
              reason: 'seat $i stands on the rail, not in the middle',
            );
          }
          // And the table inside the felt.
          expect(felt.contains(outer.topLeft), isTrue);
          expect(felt.bottom, greaterThanOrEqualTo(outer.bottom));
          await _unmount(tester, state);
        }
      });
    }
  });

  group('what paints over it', () {
    testWidgets('the paid table picture and everything on the felt are over '
        'the cloth; the room\'s chips drift under it', (tester) async {
      final state = await _mount(tester, _scene('01'));
      // Tree order is paint order among the felt's children.
      final order = [
        for (final e in find.byWidgetPredicate((w) => true).evaluate())
          e.widget.runtimeType.toString(),
      ];
      final table = order.indexOf('CasinoTableSurface');
      expect(table, isNonNegative);
      for (final above in [
        '_TableCentrepiece',
        '_CategoryTag',
        '_Pot',
        '_Status',
        'SeatPod',
        'TableAmbientEffects',
      ]) {
        expect(order.indexOf(above), greaterThan(table), reason: above);
      }
      // The host stands behind it, and the room's chips under everything.
      expect(order.indexOf('DealerHost'), lessThan(table));
      expect(find.byType(DriftingChips), findsOneWidget);
      expect(order.indexOf('DriftingChips'), lessThan(table));
      await _unmount(tester, state);
    });

    testWidgets('a short phone keeps the table and loses its trimmings', (
      tester,
    ) async {
      for (final (size, detailed) in [
        (const Size(640, 360), false),
        (const Size(891, 411), true),
      ]) {
        final state = await _mount(tester, _scene('01'), size: size);
        expect(
          tester
              .widget<CasinoTableSurface>(find.byType(CasinoTableSurface))
              .detailed,
          detailed,
          reason: '$size',
        );
        await _unmount(tester, state);
      }
    });

    testWidgets('the near rail warms on the viewer\'s turn only', (
      tester,
    ) async {
      for (final (prefix, turn) in [('01', false), ('03', true)]) {
        final state = await _mount(tester, _scene(prefix));
        expect(
          tester
              .widget<TableAmbientEffects>(find.byType(TableAmbientEffects))
              .yourTurn,
          turn,
          reason: prefix,
        );
        await _unmount(tester, state);
      }
    });
  });
}
