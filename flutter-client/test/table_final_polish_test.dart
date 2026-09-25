// The final table polish (owner's brief, 26 Sep 2026: "a FINAL GAMEPLAY UI
// POLISH PASS ... POLISH, DON'T REDESIGN").
//
// The hierarchy: Chaal primary — its faintest breath outshines every other
// lit key's still glow; the pot secondary — its plinth hugs its figure rather
// than laying a slab across the table wider than the Chaal key; the viewer's
// own bet supporting — a step over a rim seat's, quieter than Chaal's name,
// and gone once they have packed, as a rim seat's is. Pack keeps its red at
// the strength every live edge has. The seat on turn is found at a glance by
// day as by night: its ring's edge is the app's light-ground gold on the pale
// table, where champagne all but vanished. A sideshow the viewer has asked for
// still names who it is with while it waits, and its thread runs on the cloth,
// under every seat and every word.
//
// Run in Inter, as the phone draws the table: the test font sets every glyph
// a full em wide, which would push a real pot's figure past its plinth.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/table_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/casino_table.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/table_chrome.dart';
import 'package:teenpatti/widgets/table_ground.dart';

import 'table_scenes.dart';

/// The table mounted in [scene] at [size] with text at [textScale], settled.
Future<GameState> _mount(
  WidgetTester tester,
  TableScene scene, {
  Size size = const Size(640, 360),
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

TableScene _scene(String prefix) =>
    tableScenes.firstWhere((s) => s.name.startsWith(prefix));

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

Finder _key(String label) =>
    find.byWidgetPredicate((w) => w is MachinedKey && w.label == label);

/// WCAG's contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

/// The key's own fade: its outermost Opacity.
double _fadeOf(WidgetTester tester, Finder key) => tester
    .widget<Opacity>(
      find.descendant(of: key, matching: find.byType(Opacity)).first,
    )
    .opacity;

/// The strength of a key's glow right now: the alpha of the halo its
/// [KeyPulse] draws, 0 when it draws none.
double _glowOf(WidgetTester tester, Finder key) {
  final box = tester.widget<DecoratedBox>(
    find
        .descendant(
          of: find.descendant(of: key, matching: find.byType(KeyPulse)),
          matching: find.byType(DecoratedBox),
        )
        .first,
  );
  final shadows = (box.decoration as BoxDecoration).boxShadow;
  return shadows == null || shadows.isEmpty ? 0 : shadows.first.color.a;
}

/// The ring round the pod on turn (seat_pod.dart's private `_TurnRing`).
dynamic _activeRing(WidgetTester tester) => tester.widget(
  find.byWidgetPredicate(
    (w) =>
        w.runtimeType.toString() == '_TurnRing' &&
        (w as dynamic).active == true,
  ),
);

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter');
    for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
    }
    await inter.load();
  });

  group('the pot', () {
    testWidgets('its plinth hugs the figure rather than laying a bar across '
        'the table, and a pot of crores still fits its fifth', (tester) async {
      for (final size in const [
        Size(592, 360),
        Size(640, 360),
        Size(891, 411),
        Size(915, 412),
      ]) {
        for (final scale in [1.0, 1.25]) {
          final label = '${size.width.toInt()}x${size.height.toInt()} x$scale';
          final state = await _mount(
            tester,
            _scene('03'),
            size: size,
            textScale: scale,
          );
          final felt = tester.getRect(find.byType(CasinoTableSurface));
          final pot = tester.getRect(_private('_Pot'));
          final figure = find.descendant(
            of: _private('_Pot'),
            matching: find.byType(Text),
          );
          final drawn = tester.getRect(figure);
          // The figure at its own size, in the pot's own type: not shrunk.
          expect(
            drawn.width,
            closeTo(tester.renderObject<RenderBox>(figure).size.width, 0.5),
            reason: label,
          );
          expect(
            tester.widget<Text>(figure).style!.fontSize,
            TableType.pot(Theme.of(tester.element(figure))).fontSize,
          );
          // The plate is the pile, the figure and the plate's own padding:
          // narrower than the fifth of the felt it used to fill whatever it
          // held, and still in the middle of the table.
          expect(pot.width, lessThan(felt.width * 0.20), reason: label);
          expect(pot.center.dx, closeTo(felt.center.dx, 1), reason: label);
          expect(pot.contains(drawn.center), isTrue, reason: label);

          // A pot of crores: as wide as the fifth allows, and no wider — once
          // the flare of its chips landing (a brief 3.5% swell) has passed.
          // The flare waits for the chip to come down on the pile (26 Sep
          // 2026, BetFlights.landsAt), so it has passed 1.16 s after the bet
          // — here, where a frame is drawn only at the end of each pump, a
          // flare's 620 ms after the frame that follows the landing.
          state.handleState(seenTurnRoom(pot: 999999999));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 900));
          await tester.pump(const Duration(milliseconds: 800));
          expect(tester.takeException(), isNull, reason: label);
          final big = tester.getRect(_private('_Pot'));
          expect(
            big.width,
            lessThanOrEqualTo(felt.width * 0.20 + 0.5),
            reason: label,
          );
          expect(big.width, greaterThan(pot.width), reason: label);
          await _unmount(tester, state);
        }
      }
    });

    testWidgets('on a phone 891dp wide the plinth is no wider than the Chaal '
        'key, where it was half as wide again', (tester) async {
      final state = await _mount(
        tester,
        _scene('03'),
        size: const Size(891, 411),
      );
      final pot = tester.getRect(_private('_Pot'));
      final chaal = tester.getRect(_key(state.t.chaal));
      expect(pot.width, lessThanOrEqualTo(chaal.width));
      await _unmount(tester, state);
    });
  });

  group('the console', () {
    test('the primary key\'s faintest breath outshines every still glow', () {
      expect(KeyPulse.breathLow, greaterThan(KeyPulse.still));
      expect(KeyPulse.breathHigh, greaterThan(KeyPulse.breathLow));
      // No louder at its brightest than it ever was.
      expect(KeyPulse.breathHigh, lessThanOrEqualTo(0.40));
    });

    testWidgets('on the viewer\'s turn Chaal glows more than every other lit '
        'key at every moment of its breath', (tester) async {
      final state = await _mount(tester, _scene('03'));
      final t = state.t;
      for (var i = 0; i < 14; i++) {
        final chaal = _glowOf(tester, _key(t.chaal));
        expect(chaal, greaterThanOrEqualTo(KeyPulse.breathLow - 1e-6));
        for (final label in [t.sideshow, t.forceSideshow, t.missile]) {
          final glow = _glowOf(tester, _key(label));
          expect(glow, closeTo(KeyPulse.still, 1e-6), reason: label);
          expect(glow, lessThan(chaal), reason: '$label at frame $i');
        }
        // Pack never glows.
        expect(_glowOf(tester, _key(t.pack)), 0);
        await tester.pump(const Duration(milliseconds: 90));
      }
      await _unmount(tester, state);
    });

    testWidgets('Pack keeps its red, at the strength every live edge has', (
      tester,
    ) async {
      for (final dark in [true, false]) {
        final state = await _mount(tester, _scene('03'), dark: dark);
        final pack = _key(state.t.pack);
        final scheme = Theme.of(tester.element(pack)).colorScheme;
        final side = tester
            .widget<FilledButton>(
              find.descendant(of: pack, matching: find.byType(FilledButton)),
            )
            .style!
            .side!
            .resolve(const <WidgetState>{})!;
        expect(
          side.color,
          scheme.error.withValues(
            alpha: dark ? AppTheme.hairlineLive : AppTheme.hairlineLiveLight,
          ),
        );
        await _unmount(tester, state);
      }
    });

    testWidgets('a sideshow the viewer has asked for still names who it is '
        'with while it waits, on a dead key', (tester) async {
      final state = await _mount(tester, _scene('35'));
      final sideshow = _key(state.t.sideshow);
      final key = tester.widget<MachinedKey>(sideshow);
      expect(key.amount, 'Vikramaditya');
      expect(key.onPressed, isNull);
      expect(_fadeOf(tester, sideshow), deadKeyOpacity);
      // Every other move waits with it.
      expect(tester.widget<MachinedKey>(_key(state.t.chaal)).onPressed, isNull);
      await _unmount(tester, state);

      // Nothing asked and nothing to ask: no name.
      final other = await _mount(tester, _scene('01'));
      expect(tester.widget<MachinedKey>(_key(other.t.sideshow)).amount, isNull);
      await _unmount(tester, other);
    });
  });

  group('the seats', () {
    // The seat on turn, found at a glance by day as by night. Measured at the
    // bottom of the ring's breath, on the grounds a seat's ring stands over.
    testWidgets('the turn ring\'s edge reads on every ground a seat stands '
        'on, even at the bottom of its breath', (tester) async {
      for (final dark in [true, false]) {
        final state = await _mount(tester, _scene('01'), dark: dark);
        final ring = _activeRing(tester);
        final edge = ring.edge as Color;
        final halo = ring.colour as Color;
        final theme = Theme.of(tester.element(find.byType(SeatPod).first));
        final b = theme.brightness;
        final colours = theme.extension<CasinoTableColors>()!;
        final cloths = [
          for (final cloth in [
            colours.cloth,
            for (final game in AppTheme.clothGames) colours.clothFor(game),
          ]) ...[cloth.centre, cloth.edge],
        ];
        final floor = TableAmbient.turnEdgeFloor(b);
        double against(Color ink, Color ground) => _contrast(
          Color.alphaBlend(ink.withValues(alpha: floor), ground),
          ground,
        );

        if (dark) {
          // By night the edge is the beat itself, as it always was, and
          // reads on every ground.
          expect(edge, halo);
          for (final ground in [
            AppTheme.ground(b),
            colours.railTop,
            colours.railBottom,
            ...cloths,
          ]) {
            expect(
              against(edge, ground),
              greaterThanOrEqualTo(3),
              reason: '$ground',
            );
          }
        } else {
          // By day it is the gold the app writes with on a light ground, not
          // the halo's champagne.
          expect(edge, isNot(halo));
          // 3:1 on the room and the rail the pods stand on ...
          for (final ground in [TableGround.pearl, colours.railTop]) {
            expect(
              against(edge, ground),
              greaterThanOrEqualTo(3),
              reason: '$ground',
            );
          }
          // ... and 2:1 or more on every cloth and the rail's foot, where the
          // champagne edge was 1.0 to 1.3:1.
          for (final ground in [colours.railBottom, ...cloths]) {
            expect(
              against(edge, ground),
              greaterThanOrEqualTo(2),
              reason: '$ground',
            );
          }
        }
        await _unmount(tester, state);
      }
    });

    testWidgets('the viewer\'s bet stands over their cards only while they are '
        'in the hand, as a rim seat\'s does', (tester) async {
      for (final (prefix, shown) in [
        ('03', true), // on turn
        ('06', true), // a showdown they lost, while it is on show
        ('05', false), // packed: the PACKED plate says it
      ]) {
        final state = await _mount(tester, _scene(prefix));
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('own-hand-column')),
            matching: find.byType(SeatBet),
          ),
          shown ? findsOneWidget : findsNothing,
          reason: prefix,
        );
        await _unmount(tester, state);
      }
    });

    testWidgets('the viewer\'s bet is a step over a rim seat\'s and quieter '
        'than the Chaal key\'s name', (tester) async {
      for (final size in const [
        Size(592, 360),
        Size(640, 360),
        Size(891, 411),
        Size(915, 412),
      ]) {
        final state = await _mount(tester, _scene('03'), size: size);
        final mine = tester.widget<SeatBet>(
          find.byWidgetPredicate((w) => w is SeatBet && w.totalFirst),
        );
        final rim = tester.widget<SeatBet>(
          find.byWidgetPredicate((w) => w is SeatBet && !w.totalFirst).first,
        );
        expect(mine.width, greaterThan(rim.width));
        final theme = Theme.of(tester.element(_key(state.t.chaal)));
        expect(
          TableType.seat(theme, mine.width).bet(colour: Colors.white).fontSize!,
          lessThan(TableType.primaryAction(theme).fontSize!),
          reason: '${size.width}',
        );
        await _unmount(tester, state);
      }
    });

    testWidgets('the sideshow\'s thread runs on the cloth, under every seat '
        'and every word', (tester) async {
      final state = await _mount(tester, _scene('35'));
      expect(_private('_SideshowLink'), findsOneWidget);
      // Tree order is paint order among the felt's children.
      final order = [
        for (final e in find.byWidgetPredicate((w) => true).evaluate())
          e.widget.runtimeType.toString(),
      ];
      final link = order.indexOf('_SideshowLink');
      expect(link, greaterThan(order.indexOf('CasinoTableSurface')));
      for (final above in [
        '_CategoryTag',
        '_Pot',
        '_Status',
        'SeatPod',
        'SeatBet',
        '_OwnHand',
      ]) {
        expect(order.indexOf(above), greaterThan(link), reason: above);
      }
      await _unmount(tester, state);
    });
  });
}
