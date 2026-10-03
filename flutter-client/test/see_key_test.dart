// The key over the viewer's blind hand says "SEE" and nothing more (owner,
// 3 Oct 2026: "instead of showing See cards text, only show text 'See'"):
// the cards it turns stand right under it. A screen reader still hears the
// fuller words — "See cards" — and the blind moves left.
//
// Held here: the word in all five languages, set in the key's capitals; what
// a screen reader hears; a tap still the look; and at 640x360, text x1.25, in
// every language and both themes, the word whole on the key at its full size.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/see_cards_button.dart';

import 'script_fonts.dart';
import 'table_scenes.dart';

/// A socket that records the moves sent instead of sending them.
class _Recorder extends GameConnection {
  _Recorder() : super('http://127.0.0.1:9');

  final moves = <String>[];

  @override
  void act(String action, {int? amount}) => moves.add(action);
}

/// The key's word in each language, as the owner's request reads.
const _words = {
  AppLang.english: 'See',
  AppLang.hindi: 'देखें',
  AppLang.bengali: 'দেখুন',
  AppLang.gujarati: 'જુઓ',
  AppLang.punjabi: 'ਵੇਖੋ',
};

/// Priya (u0), seated at a blind table and still blind, somebody else on
/// turn — "SEE" stands over her cards.
GameState _state(_Recorder socket, AppLang lang) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9', connection: socket);
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Priya',
      'chips': 245000,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
    })
    ..screen = Screen.table
    ..handleState(opponentTurnRoom());
}

Future<GameState> _mount(
  WidgetTester tester,
  _Recorder socket, {
  Size size = const Size(891, 411),
  double scale = 1,
  bool dark = true,
  AppLang lang = AppLang.english,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final state = _state(socket, lang);
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

final Finder _key = find.byType(SeeCardsButton);

void main() {
  // Where async is real (CLAUDE.md §12.3).
  setUpAll(loadScriptFonts);

  test('the key\'s word is "See" in every language, and "See cards" stays '
      'for a screen reader', () {
    final english = Strings(AppLang.english);
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      expect(t.see, _words[lang], reason: lang.code);
      expect(t.ownEntry('see'), isNotNull, reason: '${lang.code}: translated');
      expect(t.ownEntry('seeCards'), isNotNull, reason: lang.code);
      expect(t.see, isNot(t.seeCards), reason: lang.code);
      if (lang != AppLang.english) {
        expect(t.see, isNot(english.see), reason: lang.code);
      }
    }
    expect(english.see.toUpperCase(), 'SEE');
    expect(english.seeCards, 'See cards');
  });

  testWidgets('the key over the blind hand says SEE, a screen reader hears '
      '"See cards" and the blind moves left, and a tap is the look', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final socket = _Recorder();
    final state = await _mount(tester, socket);
    final t = state.t;

    expect(_key, findsOneWidget);
    expect(
      find.descendant(of: _key, matching: find.text('SEE')),
      findsOneWidget,
    );
    expect(find.text('SEE CARDS'), findsNothing);
    expect(find.text(t.seeCards), findsNothing);
    expect(find.text(t.seeCards.toUpperCase()), findsNothing);

    final button = tester.widget<SeeCardsButton>(_key);
    expect(button.label, t.see);
    expect(button.semanticsLabel, t.seeCards);
    expect(button.blindLeft, 3);
    expect(button.blindMax, isNotNull);
    expect(
      find.bySemanticsLabel(
        '${t.seeCards}, ${t.blindMovesLabel} 3/${button.blindMax}',
      ),
      findsOneWidget,
    );
    // Nothing reads the short word on its own.
    expect(find.bySemanticsLabel(RegExp(r'^SEE$|^See$')), findsNothing);

    await tester.tap(find.text('SEE'));
    await tester.pump();
    expect(socket.moves, ['see']);

    semantics.dispose();
    await _unmount(tester, state);
  });

  testWidgets('without the blind count a screen reader still hears the '
      'fuller words, and with no fuller words, the word itself', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    Future<void> show(SeeCardsButton key) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(sound: false),
        home: Scaffold(body: Center(child: key)),
      ),
    );
    await show(
      SeeCardsButton(
        label: 'See',
        semanticsLabel: 'See cards',
        onPressed: () {},
        width: 140,
        height: 46,
      ),
    );
    expect(find.text('SEE'), findsOneWidget);
    expect(find.bySemanticsLabel('See cards'), findsOneWidget);
    await show(
      SeeCardsButton(label: 'See', onPressed: () {}, width: 140, height: 46),
    );
    expect(find.bySemanticsLabel('See'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('the pill hugs its word, drawn a fifth shorter than its tap '
      'box, and a tap on the box over it is still the look, once', (
    tester,
  ) async {
    final socket = _Recorder();
    final state = await _mount(tester, socket);
    final box = tester.getRect(_key);
    final pill = tester.getRect(
      find.descendant(of: _key, matching: find.byType(DecoratedBox)).first,
    );
    // The box takes the tap, at the brief's 40–48dp; the pill is drawn in
    // its middle (owner, 3 Oct 2026: "reduce the size of see button").
    expect(box.height, inInclusiveRange(40.0, 48.0));
    expect(
      pill.height,
      moreOrLessEquals(box.height * SeeCardsButton.pillShare, epsilon: 0.01),
    );
    expect(pill.center.dy, moreOrLessEquals(box.center.dy, epsilon: 0.01));
    expect(pill.width, box.width);
    // About half the 151dp "SEE CARDS" took on this phone, and still a pill.
    expect(box.width, lessThan(100.0));
    expect(box.width, greaterThanOrEqualTo(pill.height * 2.2 - 0.01));
    expect(box.width, lessThanOrEqualTo(SeeCardsButton.maxWidth));
    // A tap in the margin over the pill sees, and only once.
    expect(box.top + 1.5, lessThan(pill.top));
    await tester.tapAt(Offset(box.center.dx, box.top + 1.5));
    await tester.pump();
    expect(socket.moves, ['see']);
    await _unmount(tester, state);
  });

  group('640x360 at x1.25, every language', () {
    for (final lang in AppLang.values) {
      for (final dark in [true, false]) {
        testWidgets('${lang.code} ${dark ? 'dark' : 'light'}: the word whole '
            'on the key, at its full size', (tester) async {
          if (!haveScriptFonts()) {
            markTestSkipped('the Noto fonts are not on this machine');
            return;
          }
          final socket = _Recorder();
          final state = await _mount(
            tester,
            socket,
            size: const Size(640, 360),
            scale: 1.25,
            dark: dark,
            lang: lang,
          );
          final word = _words[lang]!.toUpperCase();
          final text = find.descendant(of: _key, matching: find.text(word));
          expect(text, findsOneWidget, reason: '${lang.code}: $word');
          expect(tester.takeException(), isNull);

          // Inside the pill, never past its ends.
          final pill = tester.getRect(_key);
          final shown = tester.getRect(text);
          expect(pill.contains(shown.topLeft), isTrue, reason: '$shown');
          expect(pill.contains(shown.bottomRight), isTrue, reason: '$shown');
          // Set at its own size: the key's fitting box has nothing to shrink.
          final fitted = find.descendant(
            of: _key,
            matching: find.byType(FittedBox),
          );
          final column = tester.renderObject<RenderBox>(
            find.descendant(of: fitted, matching: find.byType(Column)).first,
          );
          final box = tester.getSize(fitted);
          expect(box.width, moreOrLessEquals(column.size.width, epsilon: 0.01));
          expect(
            box.height,
            moreOrLessEquals(column.size.height, epsilon: 0.01),
          );
          // One line, nothing cut.
          final paragraph = tester.renderObject<RenderParagraph>(text);
          expect(paragraph.didExceedMaxLines, isFalse);
          await _unmount(tester, state);
        });
      }
    }
  });
}
