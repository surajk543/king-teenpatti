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
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/casino_table.dart';
import 'package:teenpatti/widgets/drifting_chips.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/variation_prompt.dart';

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

Finder _private(String name) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == name);

Future<GameState> _mount(
  WidgetTester tester,
  TableScene scene, {
  Size size = const Size(891, 411),
  double textScale = 1.0,
  bool dark = true,
  AppLang lang = AppLang.english,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = sceneState(scene, lang: lang);
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
    final lightTheme = AppTheme.light(sound: false);
    final darkTheme = AppTheme.dark(sound: false);
    CasinoTableColors of(ThemeData theme) =>
        theme.extension<CasinoTableColors>()!;

    /// Every cloth a theme can lay: the fallback and each game's own.
    List<TableCloth> everyCloth(CasinoTableColors c) => [
      c.cloth,
      for (final game in AppTheme.clothGames) c.clothFor(game),
    ];

    test('both themes carry the table, and it cross-fades with them', () {
      for (final theme in [lightTheme, darkTheme]) {
        expect(of(theme), AppTheme.tableColours(theme.colorScheme));
      }
      final light = of(lightTheme);
      final dark = of(darkTheme);
      final half = light.lerp(dark, 0.5);
      expect(
        half.cloth.centre,
        Color.lerp(light.cloth.centre, dark.cloth.centre, 0.5),
      );
      // Each game's cloth crosses into its own cloth in the other theme.
      for (final game in AppTheme.clothGames) {
        expect(
          half.clothFor(game).centre,
          Color.lerp(
            light.clothFor(game).centre,
            dark.clothFor(game).centre,
            0.5,
          ),
          reason: game,
        );
      }
      expect(half.shadowBlur, closeTo(20, 1e-9));
    });

    test('by day: a pearl rail, pale cloths, a champagne rim', () {
      final c = of(lightTheme);
      expect(c.railTop.computeLuminance(), greaterThan(0.85));
      expect(c.railBottom.computeLuminance(), greaterThan(0.65));
      for (final cloth in everyCloth(c)) {
        for (final felt in [cloth.centre, cloth.edge]) {
          expect(felt.computeLuminance(), greaterThan(0.4), reason: '$felt');
        }
      }
      for (final felt in [c.cloth.centre, c.cloth.edge]) {
        expect(_hue(felt), inInclusiveRange(140, 190), reason: '$felt');
      }
      expect(_hue(c.rim), inInclusiveRange(35, 50));
      // No glow on a pale floor: it reads as a smudge.
      expect(c.glow.a, 0);
    });

    test('by night: graphite, deep cloths, a subtler gold, a cyan glow', () {
      final c = of(darkTheme);
      expect(c.railTop.computeLuminance(), lessThan(0.05));
      for (final cloth in everyCloth(c)) {
        for (final felt in [cloth.centre, cloth.edge]) {
          expect(felt.computeLuminance(), lessThan(0.05), reason: '$felt');
        }
      }
      for (final felt in [c.cloth.centre, c.cloth.edge]) {
        expect(_hue(felt), inInclusiveRange(140, 190), reason: '$felt');
      }
      expect(_hue(c.rim), inInclusiveRange(35, 50));
      expect(c.rim.a, lessThan(of(lightTheme).rim.a));
      expect(_hue(c.glow), inInclusiveRange(165, 185));
      expect(c.glow.a, lessThan(0.25));
    });

    test('never the red table', () {
      for (final theme in [lightTheme, darkTheme]) {
        for (final cloth in everyCloth(of(theme))) {
          for (final felt in [cloth.centre, cloth.edge]) {
            final h = _hue(felt);
            expect(h > 20 && h < 330, isTrue, reason: '$felt');
          }
        }
      }
    });

    // Owner, 25 Sep 2026: "keep different table color for seen, blind,
    // variation gameplay".
    test('each game lays its own cloth, in its own colour', () {
      for (final theme in [lightTheme, darkTheme]) {
        final c = of(theme);
        final cloths = [for (final g in AppTheme.clothGames) c.clothFor(g)];
        expect(cloths.toSet(), hasLength(AppTheme.clothGames.length));
        for (final cloth in cloths) {
          expect(cloth, isNot(c.cloth));
        }
        for (final game in AppTheme.clothGames) {
          final accent = AppTheme.paletteFor(
            theme.colorScheme,
            category: game,
            bootAmount: 0,
          ).accent;
          final want = HSLColor.fromColor(accent).hue;
          final got = HSLColor.fromColor(c.clothFor(game).centre).hue;
          final off = ((got - want + 540) % 360) - 180;
          // The hue of the game's lobby card and table tag; by night a
          // yellow leans a few degrees to amber.
          expect(off.abs(), lessThan(10), reason: '${theme.brightness} $game');
        }
      }
    });

    test('a game with no colour of its own lays the table\'s own cloth', () {
      for (final theme in [lightTheme, darkTheme]) {
        final c = of(theme);
        for (final game in [null, 'three_card_poker', 'texas_holdem', 'x']) {
          expect(c.clothFor(game), c.cloth, reason: '$game');
        }
      }
      // A theme built without the table's extension still has a table.
      expect(
        CasinoTableColors.dark.clothFor('seen'),
        CasinoTableColors.dark.cloth,
      );
    });

    test('the table\'s words still read on every cloth', () {
      for (final theme in [lightTheme, darkTheme]) {
        final c = of(theme);
        final dark = theme.brightness == Brightness.dark;
        // The seat's status line and the waiting line, in the inks they
        // are written in (seat_pod.dart, table_screen.dart _Status).
        final status = theme.colorScheme.onSurface;
        final waiting = dark
            ? AppTheme.boneInk.withValues(alpha: 0.82)
            : AppTheme.inkOnLight.withValues(alpha: 0.78);
        for (final cloth in everyCloth(c)) {
          for (final felt in [cloth.centre, cloth.edge]) {
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
    Future<ui.Image> paint(
      WidgetTester tester,
      bool dark, {
      String? category,
    }) async {
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
                  category: category,
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
        final theme = dark
            ? AppTheme.dark(sound: false)
            : AppTheme.light(sound: false);
        final c = theme.extension<CasinoTableColors>()!;
        final geometry = TableGeometry.of(const Size(600, 300));
        final cloth = geometry.cloth.outerRect;
        for (final category in [null, ...AppTheme.clothGames]) {
          final image = await paint(tester, dark, category: category);
          final want = c.clothFor(category).centre;

          // The middle of the cloth is the game's own cloth, lit.
          final middle = await pixel(tester, image, cloth.center);
          expect(middle.a, closeTo(1, 0.01));
          for (final (a, b) in [
            (middle.r, want.r),
            (middle.g, want.g),
            (middle.b, want.b),
          ]) {
            expect(a, closeTo(b, 0.08), reason: '$category');
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
          // Outside the table: nothing but the shadow's soft edge, far from
          // it.
          final room = await pixel(tester, image, const Offset(2, 2));
          expect(room.a, lessThan(0.05));
          image.dispose();
        }
      });
    }

    test('repaints only when the table, its cloth or the theme changes', () {
      final g = TableGeometry.of(const Size(600, 300));
      const dark = CasinoTableColors.dark;
      final a = CasinoTablePainter(
        geometry: g,
        colours: dark,
        cloth: dark.cloth,
        detailed: true,
      );
      expect(
        a.shouldRepaint(
          CasinoTablePainter(
            geometry: TableGeometry.of(const Size(600, 300)),
            colours: dark,
            cloth: dark.cloth,
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
            cloth: dark.cloth,
            detailed: true,
          ),
        ),
        isTrue,
      );
      expect(
        a.shouldRepaint(
          CasinoTablePainter(
            geometry: g,
            colours: dark,
            cloth: TableCloth.tinted(AppTheme.gold, Brightness.dark),
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

    // The waiting line took the perch the pot gave up, just under the top of
    // the felt; with a table there, it stood across the far rail's inner
    // edge. It stands on the cloth now (25 Sep 2026), and so do the two-line
    // notices that share its slot — the taller of them is who the table is
    // waiting on while a variation is chosen — without coming down onto the
    // pot.
    for (final size in const [
      Size(640, 360),
      Size(732, 412),
      Size(844, 390),
      Size(891, 411),
      Size(915, 412),
    ]) {
      testWidgets('the waiting line stands on the cloth, over the pot, at '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        for (final scale in [1.0, 1.25]) {
          for (final lang in [AppLang.english, AppLang.hindi]) {
            for (final prefix in ['09', '19']) {
              final state = await _mount(
                tester,
                _scene(prefix),
                size: size,
                textScale: scale,
                lang: lang,
              );
              final why = '$prefix x$scale ${lang.name}';
              final surface = find.byType(CasinoTableSurface);
              final felt = tester.getRect(surface);
              final g = tester.widget<CasinoTableSurface>(surface).geometry;
              final clothTop = felt.top + g.rimTop + g.rail;
              final line = prefix == '09'
                  ? tester.getRect(
                      find
                          .descendant(
                            of: _private('_Status'),
                            matching: find.byType(Text),
                          )
                          .first,
                    )
                  : tester.getRect(find.byType(VariationSelectingLine));
              final pot = tester.getRect(_private('_Pot'));
              expect(line.top, greaterThanOrEqualTo(clothTop), reason: why);
              expect(
                pot.top - line.bottom,
                greaterThanOrEqualTo(Space.md),
                reason: why,
              );
              await _unmount(tester, state);
            }
          }
        }
      });
    }
  });

  group('which cloth it lays', () {
    for (final (prefix, scene, category) in [
      ('01', _scene('01'), 'blind'),
      ('20', _scene('20'), 'seen'),
      ('22', _scene('22'), 'variation'),
      (
        'private',
        TableScene(
          'private-seen',
          (s) => s.handleState(seenOpponentTurnRoom(isPrivate: true)),
        ),
        'seen',
      ),
    ]) {
      testWidgets('a $category table ($prefix) lays the $category cloth', (
        tester,
      ) async {
        for (final dark in [true, false]) {
          final state = await _mount(tester, scene, dark: dark);
          final surface = find.byType(CasinoTableSurface);
          expect(tester.widget<CasinoTableSurface>(surface).category, category);
          final painter =
              tester
                      .widget<CustomPaint>(
                        find.descendant(
                          of: surface,
                          matching: find.byType(CustomPaint),
                        ),
                      )
                      .painter
                  as CasinoTablePainter;
          final colours =
              (dark
                      ? AppTheme.dark(sound: false)
                      : AppTheme.light(sound: false))
                  .extension<CasinoTableColors>()!;
          expect(painter.cloth, colours.clothFor(category));
          expect(painter.cloth, isNot(colours.cloth));
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
      // The room's chips drift under everything.
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

    testWidgets('the table never repaints while the room around it moves', (
      tester,
    ) async {
      final state = await _mount(tester, _scene('03'));
      RenderRepaintBoundary boundaryIn(Type type) =>
          tester.renderObject<RenderRepaintBoundary>(
            find
                .descendant(
                  of: find.byType(type),
                  matching: find.byType(RepaintBoundary),
                )
                .first,
          );
      final table = boundaryIn(CasinoTableSurface);
      final light = boundaryIn(TableAmbientEffects);
      // What each layer holds: a boundary that repaints records a new picture
      // into its layer; one that does not keeps the picture it had.
      Layer? drawing(RenderRepaintBoundary b) => b.debugLayer!.firstChild;
      final tableBefore = drawing(table);
      expect(tableBefore, isA<PictureLayer>());
      // Half a second of the room: the lamp breathing on the cloth and the
      // near rail warming for the viewer's turn, the turn ring, the drifting
      // chips.
      var lightRepaints = 0;
      for (var i = 0; i < 30; i++) {
        final lightBefore = drawing(light);
        await tester.pump(const Duration(milliseconds: 16));
        if (!identical(drawing(light), lightBefore)) lightRepaints++;
      }
      expect(
        identical(drawing(table), tableBefore),
        isTrue,
        reason: 'the table is painted once and its picture reused',
      );
      // The light moves in its own layer, on top.
      expect(lightRepaints, greaterThan(20));
      await _unmount(tester, state);
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
