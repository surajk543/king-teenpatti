// The chat drawer's order and the time on every chat line (owner, 27 Sep
// 2026: "when i click chat message icon the first tab should be quick
// message, then table chat, then block" and "also show timing in every chat
// message in table ui").
//
// The drawer is mounted for real, as the rail opens it, on the phones the
// table is laid out for (592x360, 640x360, 915x412) at text x1.0 and x1.25,
// in all five languages and both themes, in the fonts a phone draws the
// Indic scripts in (script_fonts.dart). Its time is read from the line's own
// stamp (ChatMessage.at, the server's), never from when the phone heard it,
// in the phone's 12- or 24-hour form.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/table_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

import 'script_fonts.dart';

final Uint8List _lottie = Uint8List.fromList(
  utf8.encode(
    '{"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"e","ddd":0,'
    '"assets":[],"layers":[{"ddd":0,"ind":1,"ty":4,"nm":"d","sr":1,'
    '"ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[50,50,0]},'
    '"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},"ao":0,'
    '"shapes":[{"ty":"gr","nm":"g","it":[{"ty":"el","nm":"c",'
    '"p":{"a":0,"k":[0,0]},"s":{"a":0,"k":[60,60]}},{"ty":"fl","nm":"f",'
    '"c":{"a":0,"k":[1,0.8,0,1]},"o":{"a":0,"k":100}},{"ty":"tr",'
    '"p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},'
    '"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}],"ip":0,"op":30,"st":0,"bm":0}]}',
  ),
);

const _emojiUrl = 'https://cdn.test/emojis/7.json';

/// [hour]:[minute] in the phone's local time, as the server's epoch ms.
int _at(int hour, int minute) =>
    DateTime(2026, 9, 27, hour, minute).millisecondsSinceEpoch;

Map<String, dynamic> _seat(int index, String id, String name) => {
  'seatIndex': index,
  'userId': id,
  'displayName': name,
  'chips': index == 0 ? 200000 : null,
  'status': 'active',
  'isBlind': true,
  'lastBet': 200,
  'lastAction': 'chaal',
  'contributed': 200,
  'connected': true,
  'cardCount': 3,
};

RoomState _room() => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': 'blind',
  'chipsHidden': true,
  'state': 'betting',
  'handNo': 2,
  'dealerSeat': 0,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 600,
  'maxPot': 0,
  'stake': 200,
  'you': {
    'seatIndex': 0,
    'chips': 200000,
    'status': 'active',
    'isBlind': true,
    'blindMovesLeft': 4,
    'contributed': 200,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': <String>[],
  },
  'seats': [
    _seat(0, 'me', 'You'),
    _seat(1, 'ravi', 'Ravi'),
    _seat(2, 'meera', 'Meera'),
  ],
});

ChatMessage _say(String? id, String name, String text, int at) =>
    ChatMessage.fromJson({
      'messageId': '$id-$text-$at',
      'userId': id,
      'displayName': name,
      'text': text,
      'at': at,
    });

ChatMessage _emoji(String id, String name, int at) => ChatMessage.fromJson({
  'messageId': '$id-emoji-$at',
  'userId': id,
  'displayName': name,
  'text': 'Laughing',
  'at': at,
  'emoji': {
    'id': 7,
    'name': 'Laughing',
    'url': _emojiUrl,
    'assetFormat': 'LOTTIE',
  },
});

GameState _newState({AppLang lang = AppLang.english}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..user = User.fromJson({
      'id': 'me',
      'provider': 'guest',
      'displayName': 'You',
      'chips': 200000,
    })
    ..room = _room()
    ..screen = Screen.table;
}

/// A conversation in [lang]: every kind of line the log holds — the table's
/// own, another player's (one long enough to wrap), the viewer's, an emoji —
/// each at its own time of day, oldest first.
void _conversation(GameState state, AppLang lang) {
  final said = Strings(lang).quickMessages;
  state.chat
    ..add(_say(null, 'Table', 'Meera joined the table', _at(0, 15)))
    ..add(_say('ravi', 'Ravi', said[0], _at(9, 5)))
    ..add(_say('me', 'You', said[1], _at(12, 40)))
    ..add(_emoji('meera', 'Meera', _at(13, 1)))
    ..add(
      _say('meera', 'Meera', '${said[2]} ${said[3]} ${said[4]}', _at(15, 7)),
    )
    ..add(_say(null, 'Table', 'Kavya left the table', _at(22, 58)))
    ..add(_say('ravi', 'Ravi', said[5], _at(23, 59)));
}

Future<void> _pumpDrawer(
  WidgetTester tester,
  GameState state, {
  Size size = const Size(640, 360),
  double scale = 1.25,
  bool dark = true,
  bool use24h = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  final theme = dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withScriptFallback(theme),
        // The phone's 24-hour setting, as MediaQuery carries it from the
        // platform.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: use24h),
          child: GlassBudget(child: child!),
        ),
        home: const Scaffold(
          backgroundColor: Colors.transparent,
          body: ChatDrawer(),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _toChat(WidgetTester tester, Strings t) async {
  await tester.tap(find.text(t.tableChat));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _teardown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

/// Every time on screen, by what it says.
List<String> _times(WidgetTester tester) => tester
    .widgetList<Text>(find.byKey(const ValueKey('chat-time')))
    .map((t) => t.data!)
    .toList();

String _label(int at, {required bool use24h}) => chatTimeLabel(
  at,
  localizations: const DefaultMaterialLocalizations(),
  use24h: use24h,
);

RenderParagraph _paragraphOf(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(of: text, matching: find.byType(RichText)),
    );

/// Whether [p] drew every word it was given: not cut at a line limit, and
/// no line wider than its box.
bool _whole(RenderParagraph p) =>
    !p.didExceedMaxLines &&
    p.size.width + 0.5 >=
        math.min(
          p.getMaxIntrinsicWidth(double.infinity),
          p.constraints.maxWidth,
        );

void main() {
  setUpAll(() async {
    await loadScriptFonts();
    PictureCache.prime(_emojiUrl, _lottie);
  });
  tearDownAll(PictureCache.clearMemory);

  test('a time reads as the phone reads it, in 12 or 24 hours', () {
    const l10n = DefaultMaterialLocalizations();
    String at(int h, int m, bool use24h) =>
        chatTimeLabel(_at(h, m), localizations: l10n, use24h: use24h);
    expect(at(9, 5, false), '9:05 AM');
    expect(at(9, 5, true), '09:05');
    expect(at(15, 40, false), '3:40 PM');
    expect(at(15, 40, true), '15:40');
    expect(at(0, 15, false), '12:15 AM');
    expect(at(0, 15, true), '00:15');
    expect(at(12, 0, false), '12:00 PM');
    expect(at(23, 59, true), '23:59');
  });

  for (final lang in AppLang.values) {
    testWidgets(
      'in ${lang.englishName} the drawer opens on Quick messages, then Table '
      'chat, then the block key',
      (tester) async {
        final t = Strings(lang);
        final state = _newState(lang: lang);
        await _pumpDrawer(tester, state);

        // It opens on the quick messages: their boxes are up, their tab lit.
        expect(find.byType(QuickLine), findsWidgets);
        expect(find.byType(ChatPlayers), findsNothing);
        final tabs = tester.widgetList<ChatTab>(find.byType(ChatTab)).toList();
        expect(tabs.map((tab) => tab.label), [
          t.quickMessagesTitle,
          t.tableChat,
        ]);
        expect(tabs.first.selected, isTrue);
        expect(tabs.last.selected, isFalse);

        // Left to right: Quick messages, Table chat, Block, close.
        final quick = tester.getRect(find.byType(ChatTab).first);
        final chat = tester.getRect(find.byType(ChatTab).last);
        final block = tester.getRect(find.byTooltip(t.blockPlayersTitle));
        final close = tester.getRect(find.byIcon(Icons.close_rounded));
        expect(quick.right, lessThanOrEqualTo(chat.left));
        expect(chat.right, lessThanOrEqualTo(block.left));
        expect(block.right, lessThanOrEqualTo(close.left));
        expect(quick.top, closeTo(chat.top, 0.5));
        expect(quick.height, closeTo(chat.height, 0.5));
        expect(tester.takeException(), isNull);

        await _teardown(tester, state);
      },
    );
  }

  testWidgets('the new lines stay counted, on the Table chat tab, until that '
      'tab shows them', (tester) async {
    const t = Strings(AppLang.english);
    final state = _newState();
    state
      ..handleChat(_say('ravi', 'Ravi', 'hello', _at(10, 1)))
      ..handleChat(_say('meera', 'Meera', 'hi', _at(10, 2)));
    expect(state.unreadChat, 2);
    await _pumpDrawer(tester, state);
    await tester.pump(const Duration(milliseconds: 300));

    Badge badge() =>
        tester.widget<Badge>(find.byKey(const ValueKey('chat-tab-unread')));
    // On the quick messages the conversation is unseen: still counted, and
    // the count is on its tab.
    expect(state.unreadChat, 2);
    expect(badge().isLabelVisible, isTrue);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('chat-tab-unread')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );

    await _toChat(tester, t);
    await tester.pump();
    expect(state.unreadChat, 0);
    expect(badge().isLabelVisible, isFalse);

    // A line that arrives while the conversation is up is read as it lands.
    state.handleChat(_say('ravi', 'Ravi', 'again', _at(10, 3)));
    await tester.pump();
    await tester.pump();
    expect(state.unreadChat, 0);
    expect(tester.takeException(), isNull);

    await _teardown(tester, state);
  });

  for (final use24h in [false, true]) {
    testWidgets(
      'every line shows the time it was sent, from its own stamp, on a '
      '${use24h ? 24 : 12}-hour phone',
      (tester) async {
        const t = Strings(AppLang.english);
        final state = _newState();
        state.chat
          ..add(_say(null, 'Table', 'Meera joined the table', _at(0, 15)))
          ..add(_say('ravi', 'Ravi', 'good luck', _at(9, 5)))
          ..add(_say('me', 'You', 'thanks', _at(12, 40)))
          ..add(_emoji('meera', 'Meera', _at(15, 7)));
        await _pumpDrawer(tester, state, scale: 1, use24h: use24h);
        await _toChat(tester, t);

        // Oldest first on screen is the foot of a reversed list read upwards;
        // the set is what matters: one time per line, each its line's own.
        expect(_times(tester).toSet(), {
          for (final at in [_at(0, 15), _at(9, 5), _at(12, 40), _at(15, 7)])
            _label(at, use24h: use24h),
        });
        expect(_times(tester), hasLength(4));
        expect(
          _times(tester),
          contains(use24h ? '15:07' : '3:07 PM'),
          reason: 'the emoji line',
        );

        // The table's own line carries its time too, inside the line.
        expect(
          find.descendant(
            of: find.byType(ChatSystemLine),
            matching: find.text(_label(_at(0, 15), use24h: use24h)),
          ),
          findsOneWidget,
        );
        // The emoji's time stands level with the emoji.
        final emoji = tester.getRect(find.byKey(const ValueKey('chat-emoji')));
        final emojiTime = tester.getRect(
          find.text(_label(_at(15, 7), use24h: use24h)),
        );
        expect(emojiTime.center.dy, closeTo(emoji.center.dy, 2));
        // The time is the quiet tier, in tabular figures.
        final theme = Theme.of(tester.element(find.byType(ChatDrawer)));
        final style = tester
            .widget<Text>(find.byKey(const ValueKey('chat-time')).first)
            .style!;
        // The quiet tier's size and weight, a step firmer by night.
        expect(style.color, ChatTime.style(theme).color);
        expect(
          style.color,
          theme.colorScheme.onSurface.withValues(
            alpha: ChatTime.inkAlpha(theme.brightness),
          ),
        );
        expect(style.fontSize, TableType.metadata(theme).fontSize);
        expect(style.fontWeight, TableType.metadata(theme).fontWeight);
        expect(
          style.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );
        expect(tester.takeException(), isNull);

        await _teardown(tester, state);
      },
    );
  }

  testWidgets('a line the phone heard now still shows when it was SENT', (
    tester,
  ) async {
    const t = Strings(AppLang.english);
    final state = _newState();
    final sent = DateTime.now().subtract(const Duration(hours: 5));
    state.handleChat(
      _say('ravi', 'Ravi', 'from history', sent.millisecondsSinceEpoch),
    );
    await _pumpDrawer(tester, state, scale: 1);
    await _toChat(tester, t);
    expect(_times(tester), [
      _label(sent.millisecondsSinceEpoch, use24h: false),
    ]);
    await _teardown(tester, state);
  });

  testWidgets('a line with no stamp shows no time and keeps its column', (
    tester,
  ) async {
    const t = Strings(AppLang.english);
    final state = _newState();
    state.chat
      ..add(_say('ravi', 'Ravi', 'no stamp', 0))
      ..add(_say('meera', 'Meera', 'stamped', _at(9, 5)));
    await _pumpDrawer(tester, state, scale: 1);
    await _toChat(tester, t);
    expect(_times(tester), [_label(_at(9, 5), use24h: false)]);
    expect(find.textContaining('1970'), findsNothing);
    await _teardown(tester, state);
  });

  const sizes = [Size(592, 360), Size(640, 360), Size(915, 412)];

  test('the time holds 4.5:1 on the drawer glass in both themes', () {
    // The drawer's fill as the rendered table shows it behind the time (the
    // reviewer's samples of chat-chat_640x360_*_x1.25.png): (23,26,27) by
    // night, (207,210,211) by day.
    double luminance(Color c) => c.computeLuminance();
    double contrast(Color a, Color b) {
      final (hi, lo) = luminance(a) > luminance(b)
          ? (luminance(a), luminance(b))
          : (luminance(b), luminance(a));
      return (hi + 0.05) / (lo + 0.05);
    }

    for (final (theme, ground) in [
      (AppTheme.dark(sound: false), const Color(0xFF171A1B)),
      (AppTheme.light(sound: false), const Color(0xFFCFD2D3)),
    ]) {
      final ink = ChatTime.style(theme).color!;
      final drawn = Color.alphaBlend(ink, ground);
      expect(
        contrast(drawn, ground),
        greaterThanOrEqualTo(4.5),
        reason: '${theme.brightness}',
      );
    }
    // The night ink is firmer than the quiet tier's, the day ink the tier's.
    expect(ChatTime.inkAlpha(Brightness.dark), greaterThan(AppTheme.inkLow));
    expect(
      ChatTime.inkAlpha(Brightness.light),
      AppTheme.inkLowOn(Brightness.light),
    );
  });

  // Names as long as players' names get: a guest's default, one word, two,
  // and the 24 letters a display name may hold, with and without a space.
  const longNames = [
    'Guest0E00B',
    'Vikramaditya',
    'Priyanka Sharma',
    'Ravindranath Tagore',
    'Ravindranath Chattopadhy',
    'Vikramadityachakravartty',
  ];
  for (final use24h in [false, true]) {
    testWidgets(
      'no name on an emoji line, and no line the table wrote, is cut to make '
      'room for its time (${use24h ? 24 : 12}-hour)',
      (tester) async {
        const t = Strings(AppLang.english);
        for (final size in sizes) {
          for (final scale in [1.0, 1.25]) {
            for (final name in longNames) {
              final what =
                  '$name ${size.width.toInt()}x${size.height.toInt()} x$scale';
              final state = _newState();
              state.chat
                ..add(
                  _say(null, 'Table', '$name joined the table', _at(22, 58)),
                )
                ..add(_emoji('p', name, _at(12, 58)));
              await _pumpDrawer(
                tester,
                state,
                size: size,
                scale: scale,
                use24h: use24h,
              );
              await _toChat(tester, t);
              expect(tester.takeException(), isNull, reason: what);

              // The emoji line: the name whole, the emoji and the time clear
              // of it and of each other, the time level with the emoji.
              final nameFinder = find.text('$name:');
              expect(nameFinder, findsOneWidget, reason: what);
              expect(
                _whole(_paragraphOf(tester, nameFinder)),
                isTrue,
                reason: '$what: the name is cut',
              );
              final nameRect = tester.getRect(nameFinder);
              final emoji = tester.getRect(
                find.byKey(const ValueKey('chat-emoji')),
              );
              final systemTime = find.descendant(
                of: find.byType(ChatSystemLine),
                matching: find.byKey(const ValueKey('chat-time')),
              );
              final time = tester.getRect(
                find.text(_label(_at(12, 58), use24h: use24h)),
              );
              expect(nameRect.overlaps(time), isFalse, reason: what);
              expect(nameRect.overlaps(emoji), isFalse, reason: what);
              expect(emoji.overlaps(time), isFalse, reason: what);
              expect(time.center.dy, closeTo(emoji.center.dy, 2), reason: what);
              // One column: the emoji line's time ends where the table's does.
              expect(
                time.right,
                closeTo(tester.getRect(systemTime).right, 0.5),
                reason: what,
              );

              // The table's own line: every word of it, beside its time.
              final words = find.descendant(
                of: find.byType(ChatSystemLine),
                matching: find.byWidgetPredicate(
                  (w) => w is Text && w.key != const ValueKey('chat-time'),
                ),
              );
              final p = _paragraphOf(tester, words);
              expect(
                p.didExceedMaxLines,
                isFalse,
                reason: '$what: the joined line is cut',
              );
              expect(
                tester.getRect(words).overlaps(tester.getRect(systemTime)),
                isFalse,
                reason: what,
              );
              await _teardown(tester, state);
            }
          }
        }
      },
    );
  }

  // The layout, everywhere it has to hold.
  for (final lang in AppLang.values) {
    testWidgets(
      'in ${lang.englishName} every timed line fits at 592x360, 640x360 and '
      '915x412, x1.0 and x1.25, both themes, 12 and 24 hours',
      (tester) async {
        if (!haveScriptFonts()) {
          markTestSkipped('the Noto script fonts are not installed');
          return;
        }
        final t = Strings(lang);
        for (final size in sizes) {
          for (final scale in [1.0, 1.25]) {
            for (final dark in [true, false]) {
              for (final use24h in [false, true]) {
                final what =
                    '${lang.code} ${size.width.toInt()}x'
                    '${size.height.toInt()} x$scale '
                    '${dark ? 'dark' : 'light'} ${use24h ? 24 : 12}h';
                final state = _newState(lang: lang);
                _conversation(state, lang);
                await _pumpDrawer(
                  tester,
                  state,
                  size: size,
                  scale: scale,
                  dark: dark,
                  use24h: use24h,
                );
                // The quick messages, where it opens, then the conversation.
                expect(tester.takeException(), isNull, reason: what);
                await _toChat(tester, t);
                expect(tester.takeException(), isNull, reason: what);

                final drawer = tester.getRect(find.byType(ChatDrawer));
                final times = find.byKey(const ValueKey('chat-time'));
                expect(
                  times.evaluate().length,
                  greaterThanOrEqualTo(3),
                  reason: what,
                );
                // One column: every time the same width, ending at one edge,
                // inside the drawer, and whole.
                final rects = [
                  for (var i = 0; i < times.evaluate().length; i++)
                    tester.getRect(times.at(i)),
                ];
                for (final (i, r) in rects.indexed) {
                  expect(
                    r.right,
                    closeTo(rects.first.right, 0.5),
                    reason: what,
                  );
                  expect(
                    r.width,
                    closeTo(rects.first.width, 0.5),
                    reason: what,
                  );
                  expect(
                    r.right,
                    lessThanOrEqualTo(drawer.right),
                    reason: what,
                  );
                  final p = _paragraphOf(tester, times.at(i));
                  expect(_whole(p), isTrue, reason: '$what time $i');
                  expect(
                    p.getMaxIntrinsicWidth(double.infinity),
                    lessThanOrEqualTo(p.size.width + 0.5),
                    reason: '$what time $i',
                  );
                }
                final column = rects.first.left;

                // Every player's line keeps the whole measure and wraps whole;
                // its time stands at the right of its LAST line, level with
                // it, clear of its last word.
                final lines = find.descendant(
                  of: find.byType(ChatDrawer),
                  matching: find.byWidgetPredicate(
                    (w) =>
                        w is RichText &&
                        w.text.toPlainText().contains(': ') &&
                        w.text is TextSpan &&
                        (w.text as TextSpan).children != null,
                  ),
                );
                expect(lines.evaluate(), isNotEmpty, reason: what);
                for (var i = 0; i < lines.evaluate().length; i++) {
                  final rect = tester.getRect(lines.at(i));
                  final p = tester.renderObject<RenderParagraph>(lines.at(i));
                  expect(p.didExceedMaxLines, isFalse, reason: what);
                  expect(rect.left, greaterThanOrEqualTo(drawer.left));
                  expect(
                    rect.right,
                    lessThanOrEqualTo(column + rects.first.width),
                  );
                  // Its time: the one whose foot is this line's foot.
                  final mine = rects.where(
                    (r) =>
                        r.bottom <= rect.bottom + 3 &&
                        r.bottom >= rect.bottom - 8 &&
                        r.top >= rect.top - 1,
                  );
                  expect(mine, hasLength(1), reason: '$what line $i');
                  final time = mine.single;
                  // The words, the blank that ends them left out.
                  final words =
                      (lines.at(i).evaluate().single.widget as RichText).text
                          .toPlainText();
                  final boxes = p.getBoxesForSelection(
                    TextSelection(
                      baseOffset: 0,
                      extentOffset: words.length - 1,
                    ),
                  );
                  // The paragraph's last line: the words that reach it (none, when
                  // the blank took a line of its own) must end before the time.
                  final foot = p.size.height;
                  for (final box in boxes.where((b) => b.bottom > foot - 2)) {
                    expect(
                      rect.left + box.right,
                      lessThanOrEqualTo(time.left - Space.sm + 0.5),
                      reason: '$what line $i: the last word runs into the time',
                    );
                  }
                  // Level: the time's foot within its last line's box.
                  expect(
                    time.bottom,
                    lessThanOrEqualTo(rect.top + foot + 3),
                    reason: '$what line $i',
                  );
                  expect(
                    time.top,
                    greaterThanOrEqualTo(rect.top + foot - 30 * scale),
                    reason: '$what line $i',
                  );
                }
                // The table's own lines, whole beside the column too.
                final system = find.byType(ChatSystemLine);
                for (var i = 0; i < system.evaluate().length; i++) {
                  final words = find.descendant(
                    of: system.at(i),
                    matching: find.byWidgetPredicate(
                      (w) => w is Text && w.key != const ValueKey('chat-time'),
                    ),
                  );
                  final p = _paragraphOf(tester, words);
                  expect(p.didExceedMaxLines, isFalse, reason: what);
                  expect(
                    tester.getRect(words).right,
                    lessThanOrEqualTo(column - Space.sm + 0.5),
                    reason: what,
                  );
                }
                expect(tester.takeException(), isNull, reason: what);
                await _teardown(tester, state);
              }
            }
          }
        }
      },
    );
  }
}
