// The missed-turn warning (requirement 31; owner, 27 Sep 2026: "warn before
// the kick"). A turn clock running out packs the player (poker: checks where
// free, else folds; stands pat on the draw) and counts a missed turn; at the
// table's allowance (3) they are shown out. Until now the app said nothing on
// the table — the count reached only a vibration. The warning is drawn from
// the server's own count in the player's snapshot (`you.missedTurns` of
// `you.maxMissedTurns`), in the status slot of both felts: after a miss
// "You missed your turn — auto-packed" over "Missed turns: 1 of 3", one miss
// short of the kick "Last warning" over "One more missed turn and you leave
// the table", and nothing once the count is back to 0.
//
// Pinned here: the words in all five languages; the warning following the
// count 1 → 2 → 0 on the Teen Patti felt and on the poker felt (a clock fold
// said as a fold, a clock check as a miss); and, with the phone's Noto fonts,
// the plate inside the screen, clear of every key, card, seat, the pot and
// the winning tax's pill, and nothing on it cut short — at 640x360 x1.25 in
// all five languages and both themes, and at every phone size from 592x360 to
// 915x412, x1.0 and x1.25, in every language, at tables of two to five places
// and on the poker felt.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/missed_turns_notice.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/table_chrome.dart';
import 'package:teenpatti/widgets/table_tax.dart';

import 'level_fixtures.dart';
import 'script_fonts.dart';
import 'table_scenes.dart';

You _you(int missed, {int max = 3}) => You.fromJson({
  'seatIndex': 0,
  'chips': 1000,
  'status': 'active',
  'isBlind': true,
  'blindMovesLeft': 3,
  'contributed': 0,
  'missedTurns': missed,
  'maxMissedTurns': max,
  'cards': const <String>[],
});

Future<GameState> _mount(
  WidgetTester tester,
  RoomState room, {
  AppLang lang = AppLang.english,
  bool dark = true,
  double textScale = 1.25,
  Size size = const Size(640, 360),
  int places = 5,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state =
      sceneState(
          TableScene('missed', (s) {
            s.config = s.config.copyWith(maxPlayers: places);
            s.handleState(room);
          }),
          lang: lang,
        )
        // A titled player: the winning tax's pill under the tag at its tallest,
        // two lines, as every public Teen Patti table shows it.
        ..user = playerUser(level: levelAt(12), taxBps: 1657);
  await tester.pumpWidget(
    tableApp(
      state: state,
      feedback: feedback,
      theme: withScriptFallback(
        dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
      ),
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

Future<void> _show(WidgetTester tester, GameState state, RoomState room) async {
  state.handleState(room);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Finder get _notice => find.byType(MissedTurnsNotice);

/// The notice's plate as it is painted.
Rect _plate(WidgetTester tester) => tester.getRect(
  find.descendant(of: _notice, matching: find.byType(Plate)).first,
);

/// Everything on the felt the warning must never cover: the console's keys,
/// every card on the table, the pot's plinth.
List<(String, Rect)> _mustClear(WidgetTester tester) => [
  for (final e in find.byType(MachinedKey).evaluate())
    (
      'key ${(e.widget as MachinedKey).label}',
      tester.getRect(find.byWidget(e.widget)),
    ),
  for (final e in find.byType(StepperKey).evaluate())
    ('stepper', tester.getRect(find.byWidget(e.widget))),
  for (final e in find.byType(SeatPod).evaluate())
    (
      'seat of ${(e.widget as SeatPod).seat?.displayName}',
      tester.getRect(find.byWidget(e.widget)),
    ),
  for (final e in find.byType(WinningTaxTag).evaluate())
    ('winning tax', tester.getRect(find.byWidget(e.widget))),
  for (final e in find.byType(PlayingCard).evaluate())
    ('card', tester.getRect(find.byWidget(e.widget))),
  for (final e
      in find
          .byWidgetPredicate(
            (w) =>
                w.runtimeType.toString() == '_Pot' ||
                w.runtimeType.toString() == '_Pots',
          )
          .evaluate())
    ('pot', tester.getRect(find.byWidget(e.widget))),
];

void _expectClear(WidgetTester tester, String where) {
  final plate = _plate(tester);
  final screen = Offset.zero & tester.view.physicalSize;
  expect(
    screen.contains(plate.topLeft) &&
        screen.contains(plate.bottomRight - const Offset(0.01, 0.01)),
    isTrue,
    reason: '$where: the plate $plate is on the screen',
  );
  for (final (name, rect) in _mustClear(tester)) {
    final overlap = plate.intersect(rect);
    expect(
      overlap.width <= 0.5 || overlap.height <= 0.5,
      isTrue,
      reason: '$where: the plate $plate covers the $name at $rect',
    );
  }
  // Nothing on it cut short: a line that needs a third is laid out wider and
  // the plate scaled down instead (MissedTurnsNotice.wrapWidthFor).
  for (final key in const ['missed-turns-title', 'missed-turns-detail']) {
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(RichText),
      ),
    );
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: '$where: the $key is cut short',
    );
  }
}

String _title(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('missed-turns-title'))).data!;
String _detail(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('missed-turns-detail')))
    .data!;

void main() {
  setUpAll(loadScriptFonts);

  group('the words', () {
    test('follow the count, and say nothing without one', () {
      final t = Strings(AppLang.english);
      expect(missedTurnsWarning(null, t), isNull);
      expect(missedTurnsWarning(_you(0), t), isNull);
      // A table that never shows anybody out has nothing to warn of.
      expect(missedTurnsWarning(_you(2, max: 0), t), isNull);

      final first = missedTurnsWarning(_you(1), t)!;
      expect(first.title, 'You missed your turn — auto-packed');
      expect(first.detail, 'Missed turns: 1 of 3');
      expect(first.last, isFalse);

      final last = missedTurnsWarning(_you(2), t)!;
      expect(last.title, 'Last warning');
      expect(last.detail, 'One more missed turn and you leave the table');
      expect(last.last, isTrue);

      // A longer allowance counts on until one short of it.
      expect(
        missedTurnsWarning(_you(3, max: 5), t)!.detail,
        'Missed turns: 3 of 5',
      );
      expect(missedTurnsWarning(_you(4, max: 5), t)!.last, isTrue);

      // Poker: the clock's check or stand-pat packs nothing.
      expect(
        missedTurnsWarning(_you(1), t, poker: true)!.title,
        'You missed your turn',
      );
      expect(
        missedTurnsWarning(_you(1), t, poker: true, folded: true)!.title,
        t.pokerTimedOut,
      );
      expect(missedTurnsWarning(_you(2), t, poker: true)!.last, isTrue);
    });

    test('are in every language, each its own', () {
      final english = Strings(AppLang.english);
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        final lines = [
          t.autoPacked,
          t.missedYourTurn,
          t.missedTurnsCount(1, 3),
          t.lastWarning,
          t.missOneMore,
        ];
        for (final line in lines) {
          expect(line.trim(), isNotEmpty, reason: '$lang');
        }
        expect(
          t.missedTurnsCount(1, 3),
          allOf(contains('1'), contains('3')),
          reason: '$lang',
        );
        if (lang != AppLang.english) {
          expect(t.autoPacked, isNot(english.autoPacked), reason: '$lang');
          expect(
            t.missedYourTurn,
            isNot(english.missedYourTurn),
            reason: '$lang',
          );
          expect(t.missOneMore, isNot(english.missOneMore), reason: '$lang');
          expect(
            t.missedTurnsCount(1, 3),
            isNot(english.missedTurnsCount(1, 3)),
            reason: '$lang',
          );
        }
      }
    });

    test('the idle kick says "in a row" in English, as the others do', () {
      expect(
        Strings(AppLang.english).kickedIdle(3),
        'You left the table after 3 missed turns in a row.',
      );
    });
  });

  group('the Teen Patti felt', () {
    testWidgets('the warning follows the count 1 → 2 → 0', (tester) async {
      final state = await _mount(tester, missedTurnsRoom(), textScale: 1);
      final t = state.t;
      expect(_notice, findsOneWidget);
      expect(_title(tester), t.autoPacked);
      expect(_detail(tester), t.missedTurnsCount(1, 3));

      await _show(
        tester,
        state,
        missedTurnsRoom(missed: 2, myTurn: true, handNo: 8),
      );
      expect(_notice, findsOneWidget);
      expect(_title(tester), t.lastWarning);
      expect(_detail(tester), t.missOneMore);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('missed-turns-title')))
            .style!
            .color,
        MissedTurnsNotice.titleInk(true),
      );

      // They played: the server's count is 0 again, and the warning goes.
      await _show(tester, state, opponentTurnRoom(handNo: 8));
      expect(_notice, findsNothing);
      await _unmount(tester, state);
    });

    for (final dark in [true, false]) {
      for (final lang in AppLang.values) {
        testWidgets('clear of the keys, the cards and the pot — ${lang.name}, '
            '${dark ? 'dark' : 'light'}, 640x360 x1.25', (tester) async {
          final state = await _mount(
            tester,
            missedTurnsRoom(),
            lang: lang,
            dark: dark,
          );
          expect(_notice, findsOneWidget);
          expect(find.byType(WinningTaxTag), findsOneWidget);
          _expectClear(tester, 'miss 1');
          await _show(
            tester,
            state,
            missedTurnsRoom(missed: 2, myTurn: true, handNo: 8),
          );
          expect(_notice, findsOneWidget);
          expect(_title(tester), state.t.lastWarning);
          _expectClear(tester, 'last warning, on turn');
          expect(tester.takeException(), isNull);
          await _unmount(tester, state);
        });
      }
    }
  });

  // Every table the ring lays out (two to five places — the head seat's
  // pocket right of the pot at two and four, 27 Sep 2026) and the poker felt,
  // in every language at every phone size, the phone's Noto fonts loaded:
  // the plate stays clear of every seat — the head seat's pod and the ring
  // round it on turn included — every key, card, the pot and the tax pill,
  // and nothing on it is cut short. The themes lay the table out alike (the
  // 640x360 groups above run both).
  group('every table, language and phone size', () {
    for (final size in const [
      Size(592, 360),
      Size(640, 360),
      Size(732, 412),
      Size(844, 390),
      Size(891, 411),
      Size(915, 412),
    ]) {
      for (final scale in const [1.0, 1.25]) {
        for (final lang in AppLang.values) {
          final tag =
              '${size.width.toInt()}x${size.height.toInt()} x$scale '
              '${lang.name}';
          testWidgets('clear at $tag', (tester) async {
            for (final places in const [2, 3, 4, 5]) {
              for (final (missed, myTurn) in const [(1, false), (2, true)]) {
                final state = await _mount(
                  tester,
                  missedTurnsRoom(
                    missed: missed,
                    myTurn: myTurn,
                    places: places,
                  ),
                  lang: lang,
                  size: size,
                  textScale: scale,
                  places: places,
                );
                expect(_notice, findsOneWidget);
                _expectClear(
                  tester,
                  '$tag, $places places, miss $missed'
                  '${myTurn ? ', on turn' : ''}',
                );
                expect(tester.takeException(), isNull);
                await _unmount(tester, state);
              }
            }
            for (final room in [
              pokerMissedRoom(),
              pokerMissedRoom(missed: 2, myTurn: true),
              pokerMissedRoom(missed: 2, folded: true),
            ]) {
              final state = await _mount(
                tester,
                room,
                lang: lang,
                size: size,
                textScale: scale,
              );
              expect(_notice, findsOneWidget);
              _expectClear(
                tester,
                '$tag, poker, miss ${room.you?.missedTurns}',
              );
              expect(tester.takeException(), isNull);
              await _unmount(tester, state);
            }
          });
        }
      }
    }
  });

  group('the poker felt', () {
    testWidgets('a clock check is a miss, a clock fold says so, and the count '
        'clears', (tester) async {
      final state = await _mount(tester, pokerMissedRoom(), textScale: 1);
      final t = state.t;
      expect(_notice, findsOneWidget);
      expect(_title(tester), t.missedYourTurn);
      expect(_detail(tester), t.missedTurnsCount(1, 3));

      // Folded by the clock this hand: said as the fold it was.
      await _show(tester, state, pokerMissedRoom(folded: true));
      state.handlePokerAction((
        userId: 'u0',
        seatIndex: 0,
        action: PokerAction.fold,
        amount: 0,
        street: 'flop',
        reason: 'timeout',
      ));
      await tester.pump(const Duration(milliseconds: 600));
      expect(_title(tester), t.pokerTimedOut);

      await _show(tester, state, pokerMissedRoom(missed: 2, myTurn: true));
      expect(_title(tester), t.lastWarning);
      expect(_detail(tester), t.missOneMore);

      await _show(tester, state, pokerRoom());
      expect(_notice, findsNothing);
      await _unmount(tester, state);
    });

    for (final dark in [true, false]) {
      for (final lang in AppLang.values) {
        testWidgets('clear of the keys, the cards and the pots — ${lang.name}, '
            '${dark ? 'dark' : 'light'}, 640x360 x1.25', (tester) async {
          final state = await _mount(
            tester,
            pokerMissedRoom(),
            lang: lang,
            dark: dark,
          );
          expect(_notice, findsOneWidget);
          _expectClear(tester, 'miss 1');
          await _show(tester, state, pokerMissedRoom(missed: 2, myTurn: true));
          expect(_notice, findsOneWidget);
          _expectClear(tester, 'last warning, on turn');
          expect(tester.takeException(), isNull);
          await _unmount(tester, state);
        });
      }
    }
  });
}
