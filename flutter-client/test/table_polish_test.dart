// The table polish (owner's brief, 24 Sep 2026): one type scale for the whole
// table, a console whose keys are not all equal — Chaal primary, Sideshow and
// Force Sideshow secondary, Pack destructive, a dead key plainly dead — drawers
// and dialogs that dim the room without drowning it, a chat that mutes the
// table's own lines and signs players in ink rather than their colour, lists
// that fade at an edge only while there is more beyond it, and the table's
// states laid out at 640x360 with text at x1.25 in all five languages with
// nothing striped and every key on the screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/table_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/edge_fade.dart';
import 'package:teenpatti/widgets/glass_panels.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/table_chrome.dart';
import 'package:teenpatti/widgets/table_ground.dart';

import 'table_scenes.dart';

/// The table mounted in [scene] at [size] with text at [textScale], settled.
Future<GameState> _mount(
  WidgetTester tester,
  TableScene scene, {
  Size size = const Size(640, 360),
  double textScale = 1.25,
  AppLang lang = AppLang.english,
  bool dark = true,
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
  final act = scene.act;
  if (act != null) {
    await act(tester, state);
    await tester.pump(const Duration(milliseconds: 700));
  }
  return state;
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

TableScene _scene(String prefix) =>
    tableScenes.firstWhere((s) => s.name.startsWith(prefix));

/// WCAG's contrast ratio between two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return la > lb ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05);
}

Finder _key(String label) =>
    find.byWidgetPredicate((w) => w is MachinedKey && w.label == label);

KeyPulse _pulseOf(WidgetTester tester, Finder key) => tester.widget<KeyPulse>(
  find.descendant(of: key, matching: find.byType(KeyPulse)),
);

/// The key's own fade: its outermost Opacity.
double _fadeOf(WidgetTester tester, Finder key) => tester
    .widget<Opacity>(
      find.descendant(of: key, matching: find.byType(Opacity)).first,
    )
    .opacity;

/// Whether the key wears the struck-gold face the primary key alone wears.
bool _gilded(WidgetTester tester, Finder key) => find
    .descendant(
      of: key,
      matching: find.byWidgetPredicate(
        (w) =>
            w is Ink &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).gradient == AppTheme.goldFace,
      ),
    )
    .evaluate()
    .isNotEmpty;

/// The style a key writes its name in (a two-word name stacked on two lines
/// is written with the break in it).
TextStyle _nameStyle(WidgetTester tester, Finder key, String label) {
  final stacked = find.descendant(
    of: key,
    matching: find.text(label.replaceFirst(' ', '\n')),
  );
  final plain = find.descendant(of: key, matching: find.text(label));
  return tester
      .widget<Text>(plain.evaluate().isNotEmpty ? plain : stacked)
      .style!;
}

void main() {
  group('the type scale', () {
    for (final dark in [true, false]) {
      final name = dark ? 'dark' : 'light';
      test('every role has its size and weight ($name)', () {
        final theme = dark
            ? AppTheme.dark(sound: false)
            : AppTheme.light(sound: false);
        const c = Colors.white;

        void role(TextStyle s, double size, FontWeight weight, String what) {
          expect(s.fontSize, closeTo(size, 1e-9), reason: '$what size');
          expect(s.fontWeight, weight, reason: '$what weight');
        }

        role(TableType.pot(theme), 20, FontWeight.w700, 'pot');
        role(TableType.modalTitle(theme), 17, FontWeight.w600, 'modal title');
        role(TableType.system(theme, colour: c), 15, FontWeight.w600, 'system');
        role(
          TableType.system(theme, colour: c, strong: true),
          15,
          FontWeight.w700,
          'strong system',
        );
        role(TableType.item(theme), 15, FontWeight.w600, 'item');
        role(TableType.chips(theme), 15, FontWeight.w700, 'chips');
        role(
          TableType.primaryAction(theme),
          14,
          FontWeight.w700,
          'primary action',
        );
        role(
          TableType.secondaryAction(theme),
          13.5,
          FontWeight.w600,
          'secondary action',
        );
        role(TableType.info(theme), 13.5, FontWeight.w500, 'info');
        role(TableType.modalBody(theme), 13.5, FontWeight.w400, 'modal body');
        role(TableType.chatText(theme), 13.5, FontWeight.w400, 'chat text');
        role(
          TableType.chatName(theme, colour: c),
          13.5,
          FontWeight.w700,
          'chat name',
        );
        role(TableType.boot(theme), 12, FontWeight.w700, 'boot');
        role(TableType.label(theme), 12, FontWeight.w600, 'label');
        role(
          TableType.actionDetail(theme, primary: true),
          12,
          FontWeight.w700,
          'primary detail',
        );
        role(
          TableType.actionDetail(theme),
          12,
          FontWeight.w600,
          'secondary detail',
        );
        role(TableType.metadata(theme), 12, FontWeight.w500, 'metadata');
        role(TableType.count(theme, colour: c), 12, FontWeight.w700, 'count');
        role(
          TableType.count(theme, colour: c, small: true),
          10.5,
          FontWeight.w700,
          'small count',
        );
        role(
          TableType.caps(theme, colour: c),
          10.5 * 0.94,
          FontWeight.w600,
          'caps',
        );
        role(
          TableType.handName(theme, colour: c),
          12 * 0.94,
          FontWeight.w600,
          'hand name',
        );
      });
    }

    test('the ladder runs pot, title, system, primary, secondary, label', () {
      final theme = AppTheme.dark(sound: false);
      const c = Colors.white;
      final ladder = [
        TableType.pot(theme),
        TableType.modalTitle(theme),
        TableType.system(theme, colour: c),
        TableType.primaryAction(theme),
        TableType.secondaryAction(theme),
        TableType.label(theme),
        TableType.caps(theme, colour: c),
      ].map((s) => s.fontSize!).toList();
      for (var i = 1; i < ladder.length; i++) {
        expect(ladder[i], lessThan(ladder[i - 1]), reason: 'step $i');
      }
      // The primary key's name outweighs every other key's.
      expect(
        TableType.primaryAction(theme).fontWeight!.value,
        greaterThan(TableType.secondaryAction(theme).fontWeight!.value),
      );
    });

    test('every figure is set in tabular figures', () {
      final theme = AppTheme.light(sound: false);
      const c = Colors.black;
      final seat = TableType.seat(theme, 100);
      for (final s in [
        TableType.pot(theme),
        TableType.chips(theme),
        TableType.count(theme, colour: c),
        TableType.actionDetail(theme),
        TableType.metadata(theme, figures: true),
        seat.stack(colour: c),
        seat.bet(colour: c),
        seat.inPot(colour: c, figure: true),
      ]) {
        expect(s.fontFeatures, contains(const FontFeature.tabularFigures()));
      }
    });

    test('the quiet tier is the surface ink at its low alpha', () {
      for (final theme in [
        AppTheme.dark(sound: false),
        AppTheme.light(sound: false),
      ]) {
        final ink = TableType.metadata(theme).color!;
        final expected = theme.colorScheme.onSurface.withValues(
          alpha: AppTheme.inkLowOn(theme.brightness),
        );
        expect(ink.a, closeTo(expected.a, 1e-6));
        expect(ink.r, closeTo(expected.r, 1e-6));
      }
    });

    test('a seat scales from its pod, over a floor, in one order', () {
      final theme = AppTheme.dark(sound: false);
      const c = Colors.white;

      // The smallest pod: every role on its floor.
      final small = TableType.seat(theme, 60);
      expect(small.name().fontSize, 10);
      expect(small.you(colour: c).fontSize, 10);
      expect(small.tag(colour: c).fontSize, 10);
      expect(small.handName(colour: c).fontSize, 9);
      expect(small.status(colour: c).fontSize, 9);
      expect(small.stack(colour: c).fontSize, 11.5);
      expect(small.bet(colour: c).fontSize, 10);
      expect(small.inPot(colour: c).fontSize, 8.5);
      expect(small.speech(colour: c).fontSize, 12);

      // The largest: the shares.
      final large = TableType.seat(theme, 140);
      expect(large.name().fontSize, closeTo(17.5, 1e-9));
      expect(large.tag(colour: c).fontSize, closeTo(14.7, 1e-9));
      expect(large.status(colour: c).fontSize, closeTo(13.3, 1e-9));
      expect(large.stack(colour: c).fontSize, closeTo(17.5, 1e-9));
      expect(large.speech(colour: c).fontSize, closeTo(18.9, 1e-9));
      expect(
        large.winner(big: true, weight: FontWeight.w800).fontSize,
        closeTo(24.5, 1e-9),
      );

      // Every width in between keeps the order: speech over name and stack,
      // name over what they are doing, that over the status line; the stack
      // over the bet over In Pot.
      for (var w = 60.0; w <= 140; w += 5) {
        final s = TableType.seat(theme, w);
        final name = s.name().fontSize!;
        final stack = s.stack(colour: c).fontSize!;
        final tag = s.tag(colour: c).fontSize!;
        final status = s.status(colour: c).fontSize!;
        final bet = s.bet(colour: c).fontSize!;
        final inPot = s.inPot(colour: c).fontSize!;
        expect(s.speech(colour: c).fontSize!, greaterThanOrEqualTo(name));
        expect(s.speech(colour: c).fontSize!, greaterThanOrEqualTo(stack));
        expect(name, greaterThanOrEqualTo(tag), reason: 'at $w');
        expect(tag, greaterThanOrEqualTo(status), reason: 'at $w');
        expect(stack, greaterThanOrEqualTo(bet), reason: 'at $w');
        expect(bet, greaterThanOrEqualTo(inPot), reason: 'at $w');
        // In Pot is the quietest words on a seat, and smaller than the bet
        // it sits beside (25 Sep 2026).
        expect(inPot, lessThan(bet), reason: 'at $w');
        expect(inPot, lessThanOrEqualTo(status), reason: 'at $w');
      }
    });

    // Owner's brief, 25 Sep 2026: "Reduce the visual prominence of the In Pot
    // label. Use smaller typography and lighter contrast" — lighter, not
    // illegible.
    test('In Pot is quieter and still reads on every cloth', () {
      for (final theme in [
        AppTheme.dark(sound: false),
        AppTheme.light(sound: false),
      ]) {
        final b = theme.brightness;
        final seat = TableType.seat(theme, 100);
        final label = seat.inPot().color!;
        final figure = seat.inPot(figure: true).color!;
        // The metadata tier's ink by day, a step firmer by night; the figure a
        // step firmer again, and quieter than the table's own ink.
        expect(label.a, closeTo(SeatType.inPotLabelAlpha(b), 1e-6));
        expect(figure.a, closeTo(SeatType.inPotFigureAlpha(b), 1e-6));
        expect(figure.a, greaterThan(label.a));
        expect(SeatType.inPotPlate, lessThan(1));
        final colours = theme.extension<CasinoTableColors>()!;
        for (final cloth in [
          colours.cloth,
          for (final game in AppTheme.clothGames) colours.clothFor(game),
        ]) {
          for (final felt in [cloth.centre, cloth.edge]) {
            final capsule = Color.alphaBlend(
              AppTheme.plaque(b).withValues(alpha: SeatType.inPotPlate),
              felt,
            );
            for (final ink in [label, figure]) {
              expect(
                _contrast(Color.alphaBlend(ink, capsule), capsule),
                greaterThanOrEqualTo(4.5),
                reason: '$b $ink on $felt',
              );
            }
          }
        }
      }
    });
  });

  group('spacing, scrims and the ambient light', () {
    test('the table drawers are a step wider than the app drawer', () {
      expect(TableSpace.drawerW(640), closeTo(281.6, 1e-9));
      expect(TableSpace.drawerW(500), 280);
      expect(TableSpace.drawerW(915), 400);
      expect(TableSpace.drawerW(1280), 400);
      for (var w = 560.0; w <= 1400; w += 40) {
        expect(TableSpace.drawerW(w), greaterThanOrEqualTo(Dim.drawerW(w)));
      }
      expect(TableSpace.rowHeight, greaterThanOrEqualTo(Dim.minTouch));
      expect(TableSpace.rowIcon, lessThanOrEqualTo(TableSpace.rowIconSlot));
    });

    test('the scrims dim the room in its own ink, under Material black', () {
      const material = 0.54;
      for (final (scrim, alpha) in [
        (TableScrim.drawer, 0.40),
        (TableScrim.dialog, 0.45),
      ]) {
        expect(scrim.a, closeTo(alpha, 0.005));
        expect(scrim.a, lessThan(material));
        expect(scrim.withValues(alpha: 1), AppTheme.ink900);
      }
      // The pickers' scrim clears before the viewer's own hand.
      expect(TableScrim.picker.stops, [0, 0.58, 0.72]);
      expect(TableScrim.picker.colors.last.a, 0);
    });

    test('the ambient light sits under the game', () {
      for (final b in Brightness.values) {
        expect(TableAmbient.orbOutside(b), lessThanOrEqualTo(0.5));
        expect(TableAmbient.orbInside(b), lessThan(TableAmbient.orbOutside(b)));
      }
      expect(
        TableAmbient.orbOutside(Brightness.light),
        lessThan(TableAmbient.orbOutside(Brightness.dark)),
      );
      expect(TableAmbient.roomChips, lessThan(2.6));
      expect(TableAmbient.orbSize, lessThan(0.8));
      expect(TableAmbient.orbSpill, lessThan(0.15));
      // A breath slow enough to read as a glow, not a flicker.
      expect(
        TableAmbient.turnBreath,
        greaterThan(const Duration(milliseconds: 1000)),
      );
    });

    test('words on a plate or a fill read in both themes', () {
      // The PACKED plate is charcoal in both themes: its red is the dark
      // scheme's error, and reads on charcoal.
      expect(TableInk.alarm, AppTheme.dark(sound: false).colorScheme.error);
      for (final ground in [AppTheme.ink900, AppTheme.ink800]) {
        expect(_contrast(TableInk.alarm, ground), greaterThanOrEqualTo(4.5));
      }
      // A solid key's word takes whichever of charcoal and white reads better.
      for (final theme in [
        AppTheme.dark(sound: false),
        AppTheme.light(sound: false),
      ]) {
        for (final fill in [theme.colorScheme.error, AppTheme.gold]) {
          expect(
            _contrast(inkOnFill(fill), fill),
            greaterThanOrEqualTo(4.5),
            reason: '$fill (${theme.brightness})',
          );
        }
      }
      expect(inkOnFill(AppTheme.gold), AppTheme.ink900);
    });
  });

  group('the console', () {
    testWidgets('on the viewer\'s turn the keys are not all equal', (
      tester,
    ) async {
      final state = await _mount(tester, _scene('03'));
      final t = state.t;
      final scheme = Theme.of(
        tester.element(find.byType(MachinedKey).first),
      ).colorScheme;

      // PRIMARY: Chaal, struck gold, the one key that breathes.
      final chaal = _key(t.chaal);
      expect(tester.widget<MachinedKey>(chaal).primary, isTrue);
      expect(_gilded(tester, chaal), isTrue);
      expect(_pulseOf(tester, chaal).alive, isTrue);
      expect(_pulseOf(tester, chaal).breathe, isTrue);

      // SECONDARY: Sideshow and Force Sideshow — the plaque, a still glow
      // while on offer.
      for (final label in [t.sideshow, t.forceSideshow]) {
        final key = _key(label);
        final widget = tester.widget<MachinedKey>(key);
        expect(widget.primary, isFalse, reason: label);
        expect(widget.role, KeyRole.secondary, reason: label);
        expect(_gilded(tester, key), isFalse, reason: label);
        expect(_pulseOf(tester, key).alive, isTrue, reason: label);
        expect(_pulseOf(tester, key).breathe, isFalse, reason: label);
        expect(_fadeOf(tester, key), 1, reason: label);
      }

      // SPECIAL: Missile — its own coral, a still glow of it while on offer,
      // never gold and never breathing (25 Sep 2026).
      final missile = _key(t.missile);
      expect(tester.widget<MachinedKey>(missile).role, KeyRole.special);
      expect(_gilded(tester, missile), isFalse);
      expect(_pulseOf(tester, missile).alive, isTrue);
      expect(_pulseOf(tester, missile).breathe, isFalse);
      expect(
        _pulseOf(tester, missile).colour,
        missileInkOn(Theme.of(tester.element(missile)).brightness),
      );
      expect(_fadeOf(tester, missile), 1);

      // DESTRUCTIVE: Pack, in the error ink, and never beckoning.
      final pack = _key(t.pack);
      expect(tester.widget<MachinedKey>(pack).role, KeyRole.destructive);
      expect(_gilded(tester, pack), isFalse);
      expect(_pulseOf(tester, pack).alive, isFalse);
      expect(_nameStyle(tester, pack, t.pack).color, scheme.error);
      expect(_fadeOf(tester, pack), 1);

      // One gold key on the console, and its name the loudest.
      final gilded = [
        for (var i = 0; i < find.byType(MachinedKey).evaluate().length; i++)
          if (_gilded(tester, find.byType(MachinedKey).at(i))) i,
      ];
      expect(gilded, hasLength(1));
      final primary = _nameStyle(tester, chaal, t.chaal);
      final secondary = _nameStyle(tester, _key(t.sideshow), t.sideshow);
      expect(primary.fontSize, greaterThan(secondary.fontSize!));
      expect(
        primary.fontWeight!.value,
        greaterThan(secondary.fontWeight!.value),
      );
      // Charcoal on the gold, in both halves of the key.
      expect(primary.color, AppTheme.ink900);

      await _unmount(tester, state);
    });

    // "Disabled actions must be visibly disabled but still readable" (owner's
    // brief, 25 Sep 2026): a dead key's name, faded with its plaque, still
    // holds 3:1 against it on the room in both themes.
    test('a dead key is plainly off and still reads', () {
      expect(deadKeyOpacity, inInclusiveRange(0.45, 0.6));
      for (final theme in [
        AppTheme.dark(sound: false),
        AppTheme.light(sound: false),
      ]) {
        final b = theme.brightness;
        final room = b == Brightness.dark
            ? AppTheme.ground(b)
            : TableGround.pearl;
        final face = Color.alphaBlend(
          AppTheme.panelBase(b).withValues(alpha: deadKeyOpacity),
          room,
        );
        final name = Color.alphaBlend(
          theme.colorScheme.onSurface.withValues(alpha: deadKeyOpacity),
          face,
        );
        expect(_contrast(name, face), greaterThanOrEqualTo(3), reason: '$b');
      }
    });

    testWidgets('the YOU card glows at three quarters of a rim seat', (
      tester,
    ) async {
      // The viewer on turn, and — at the next scene — a rim seat on turn.
      for (final (prefix, mine) in [('03', true), ('01', false)]) {
        final state = await _mount(tester, _scene(prefix));
        final ring = tester.widget(
          find.byWidgetPredicate(
            (w) =>
                w.runtimeType.toString() == '_TurnRing' &&
                (w as dynamic).active == true,
          ),
        );
        expect(
          (ring as dynamic).glow,
          mine ? TableAmbient.mineGlow : 1.0,
          reason: prefix,
        );
        await _unmount(tester, state);
      }
      expect(TableAmbient.mineGlow, inInclusiveRange(0.7, 0.8));
    });

    testWidgets('off turn every key is plainly dead', (tester) async {
      final state = await _mount(tester, _scene('01'));
      final t = state.t;

      for (final label in [
        t.chaal,
        t.sideshow,
        t.forceSideshow,
        t.pack,
        t.missile,
      ]) {
        final key = _key(label);
        expect(tester.widget<MachinedKey>(key).onPressed, isNull);
        expect(_fadeOf(tester, key), deadKeyOpacity, reason: label);
        expect(_pulseOf(tester, key).alive, isFalse, reason: label);
        expect(_gilded(tester, key), isFalse, reason: label);
      }
      // The steppers fade with them.
      final steppers = find.byType(StepperKey);
      expect(steppers, findsNWidgets(2));
      for (var i = 0; i < 2; i++) {
        expect(_fadeOf(tester, steppers.at(i)), deadKeyOpacity);
      }

      await _unmount(tester, state);
    });

    testWidgets('the seat on turn is the one ring on the felt', (tester) async {
      for (final prefix in ['01', '03']) {
        final state = await _mount(tester, _scene(prefix));
        final rings = find.byWidgetPredicate(
          (w) =>
              w.runtimeType.toString() == '_TurnRing' &&
              (w as dynamic).active == true,
        );
        expect(rings, findsOneWidget, reason: prefix);
        await _unmount(tester, state);
      }
    });

    testWidgets('the poker felt shares the chrome: Fold is destructive', (
      tester,
    ) async {
      final state = await _mount(tester, _scene('15'));
      final fold = _key(state.t.fold);
      expect(tester.widget<MachinedKey>(fold).role, KeyRole.destructive);
      expect(_pulseOf(tester, fold).alive, isFalse);
      // Its Check or Call key is the gold one.
      expect(_gilded(tester, _key(state.t.call)), isTrue);
      expect(find.byType(TopCorner), findsNWidgets(2));

      await _unmount(tester, state);
    });
  });

  group('drawers, dialogs and the chat', () {
    testWidgets('the menu drawer is the table drawer\'s width, on its scrim', (
      tester,
    ) async {
      final state = await _mount(tester, _scene('10'));
      final t = state.t;
      final theme = Theme.of(tester.element(find.byType(TableDrawer)));

      // The panel aligns a box of its width inside the drawer's slot.
      expect(
        tester
            .getSize(
              find
                  .descendant(
                    of: find.byType(GlassDrawerPanel),
                    matching: find.byType(SizedBox),
                  )
                  .first,
            )
            .width,
        closeTo(TableSpace.drawerW(640), 0.01),
      );
      expect(
        tester
            .widget<Scaffold>(find.byKey(state.tableScaffold))
            .drawerScrimColor,
        TableScrim.drawer,
      );

      // Leaving costs, and says so in the error ink; a row that only reports
      // is quieter than one that does something.
      final leave = tester.widget<Text>(find.text(t.leaveTable));
      expect(leave.style!.color, theme.colorScheme.error);
      final chips = tester.widget<Text>(find.text(t.yourChips));
      expect(chips.style!.fontSize, TableType.info(theme).fontSize);
      expect(chips.style!.fontSize, lessThan(leave.style!.fontSize!));
      expect(chips.style!.color!.a, closeTo(AppTheme.inkMed, 0.01));
      // Every row stands at least the row's height.
      for (final row in find.byType(MenuRow).evaluate()) {
        expect(
          (row.renderObject! as RenderBox).size.height,
          greaterThanOrEqualTo(TableSpace.rowHeight),
        );
      }

      await _unmount(tester, state);
    });

    testWidgets(
      'Leave table asks in a destructive dialog over the table scrim',
      (tester) async {
        for (final dark in [true, false]) {
          final state = await _mount(tester, _scene('14'), dark: dark);
          final t = state.t;
          final scheme = Theme.of(
            tester.element(find.text(t.leave)),
          ).colorScheme;

          final barriers = tester.widgetList<ModalBarrier>(
            find.byType(ModalBarrier),
          );
          expect(barriers.map((b) => b.color), contains(TableScrim.dialog));
          final go = tester.widget<FilledButton>(
            find.ancestor(
              of: find.text(t.leave),
              matching: find.byType(FilledButton),
            ),
          );
          final fill = go.style!.backgroundColor!.resolve({})!;
          expect(fill, scheme.error);
          // Its word reads on the red in both themes (white on the dark
          // theme's salmon was 2.8:1).
          expect(
            _contrast(go.style!.foregroundColor!.resolve({})!, fill),
            greaterThanOrEqualTo(4.5),
            reason: dark ? 'dark' : 'light',
          );
          // Staying is the quiet, flat half of the pair, in neutral ink.
          final stay = tester.widget<TextButton>(
            find.ancestor(
              of: find.text(t.stay),
              matching: find.byType(TextButton),
            ),
          );
          expect(stay.style!.foregroundColor!.resolve({}), scheme.onSurface);

          await _unmount(tester, state);
        }
      },
    );

    testWidgets('the chat mutes the table\'s lines and signs players in ink', (
      tester,
    ) async {
      final state = await _mount(tester, _scene('11'));
      final theme = Theme.of(tester.element(find.byType(ChatDrawer)));
      final scheme = theme.colorScheme;

      final chatList = find.descendant(
        of: find.byType(ChatDrawer),
        matching: find.byType(ListView),
      );
      EdgeFadeState fade() => tester.state<EdgeFadeState>(
        find.ancestor(of: chatList, matching: find.byType(EdgeFade)),
      );

      // Every line on screen: the table's own, and each player's signature.
      final tableLines = <String>{};
      final signatures = <String, TextSpan>{};
      void read() {
        final system = find.byType(ChatSystemLine);
        for (var i = 0; i < system.evaluate().length; i++) {
          final text = tester.widget<Text>(
            find.descendant(of: system.at(i), matching: find.byType(Text)),
          );
          expect(text.textAlign, TextAlign.center);
          expect(text.style!.color, TableType.metadata(theme).color);
          tableLines.add(text.data!);
        }
        for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
          final span = rich.text;
          if (span is! TextSpan) continue;
          for (final child in span.children ?? const <InlineSpan>[]) {
            if (child is! TextSpan) continue;
            final said = child.text;
            if (said != null && said.endsWith(': ')) signatures[said] = child;
          }
        }
      }

      // The newest lines, at the foot. A reversed list builds only what is on
      // screen, and it is faded at the top while older conversation is above.
      read();
      final fits = !fade().fadesStart;
      expect(fade().fadesEnd, isFalse);
      // Then back through the conversation to its oldest line, a step at a
      // time, reading every line as it comes on screen.
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: chatList, matching: find.byType(Scrollable)),
          )
          .position;
      while (position.pixels < position.maxScrollExtent) {
        position.jumpTo(
          (position.pixels + 40).clamp(0.0, position.maxScrollExtent),
        );
        await tester.pump();
        await tester.pump();
        read();
      }
      if (!fits) {
        // At the head the fade has moved to the foot.
        expect(fade().fadesStart, isFalse);
        expect(fade().fadesEnd, isTrue);
      }

      expect(tableLines, {
        'Vikramaditya joined the table',
        'Kavya left the table',
      });
      // A player is signed in the full ink, not their seat's colour; the
      // viewer in gold; and the table never signs a line of its own.
      for (final who in ['Ravi', 'Meera', 'Arjun', 'Vikramaditya']) {
        final name = signatures['$who: '];
        expect(name, isNotNull, reason: who);
        expect(name!.style!.color, scheme.onSurface, reason: who);
        expect(name.style!.fontWeight, FontWeight.w700, reason: who);
      }
      expect(signatures['You: ']!.style!.color, goldInk(theme.brightness));
      expect(signatures.containsKey('Table: '), isFalse);

      await _unmount(tester, state);
    });
  });

  group('EdgeFade', () {
    Widget list({
      required int count,
      ScrollController? controller,
      bool reverse = false,
      Axis axis = Axis.vertical,
    }) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: 300,
          height: 300,
          child: EdgeFade(
            child: ListView.builder(
              controller: controller,
              reverse: reverse,
              scrollDirection: axis,
              itemCount: count,
              itemBuilder: (_, i) =>
                  SizedBox.square(dimension: 40, child: Text('$i')),
            ),
          ),
        ),
      ),
    );

    EdgeFadeState fade(WidgetTester tester) =>
        tester.state<EdgeFadeState>(find.byType(EdgeFade));

    testWidgets('a list that fits is never faded', (tester) async {
      await tester.pumpWidget(list(count: 5));
      await tester.pump();
      expect(fade(tester).fadesStart, isFalse);
      expect(fade(tester).fadesEnd, isFalse);
    });

    testWidgets('a long list fades only where there is more', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(list(count: 50, controller: controller));
      await tester.pump();
      expect(fade(tester).fadesStart, isFalse);
      expect(fade(tester).fadesEnd, isTrue);

      controller.jumpTo(600);
      await tester.pump();
      await tester.pump();
      expect(fade(tester).fadesStart, isTrue);
      expect(fade(tester).fadesEnd, isTrue);

      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();
      expect(fade(tester).fadesStart, isTrue);
      expect(fade(tester).fadesEnd, isFalse);
      // One mask throughout, so the list kept its place under it.
      expect(find.byType(ShaderMask), findsOneWidget);
      expect(controller.offset, controller.position.maxScrollExtent);
    });

    testWidgets(
      'a reversed list fades at the top while older lines are above',
      (tester) async {
        await tester.pumpWidget(list(count: 50, reverse: true));
        await tester.pump();
        expect(fade(tester).fadesStart, isTrue);
        expect(fade(tester).fadesEnd, isFalse);
      },
    );

    testWidgets('a strip fades at its right while there is more', (
      tester,
    ) async {
      await tester.pumpWidget(list(count: 50, axis: Axis.horizontal));
      await tester.pump();
      expect(fade(tester).fadesStart, isFalse);
      expect(fade(tester).fadesEnd, isTrue);
    });
  });

  group('640x360 at text x1.25', () {
    // The table's own scenes; the store is the lobby's sheet too and has its
    // own layout suites.
    final scenes = tableScenes.where((s) => !s.name.startsWith('16')).toList();
    for (final lang in AppLang.values) {
      testWidgets(
        'every state lays out in ${lang.name} with the keys on the screen',
        (tester) async {
          const screen = Rect.fromLTWH(0, 0, 640, 360);
          for (final scene in scenes) {
            final state = await _mount(tester, scene, lang: lang);
            expect(
              tester.takeException(),
              isNull,
              reason: '${scene.name} in ${lang.name}',
            );

            final keys = find.byType(MachinedKey);
            final rects = [
              for (var i = 0; i < keys.evaluate().length; i++)
                tester.getRect(keys.at(i)),
            ];
            for (final r in rects) {
              expect(
                screen.inflate(0.5).contains(r.topLeft) &&
                    screen.inflate(0.5).contains(r.bottomRight),
                isTrue,
                reason: '${scene.name}: a key at $r is off the screen',
              );
              expect(r.height, greaterThanOrEqualTo(Dim.minTouch));
            }
            for (var i = 0; i < rects.length; i++) {
              for (var j = i + 1; j < rects.length; j++) {
                final o = rects[i].intersect(rects[j]);
                expect(
                  o.width <= 0.5 || o.height <= 0.5,
                  isTrue,
                  reason: '${scene.name}: keys $i and $j overlap',
                );
              }
            }
            await _unmount(tester, state);
          }
        },
      );
    }
  });
}
