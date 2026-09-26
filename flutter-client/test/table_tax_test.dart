// The winning tax (owner, 26 Sep 2026): at the Blind and Variation tables at
// 10 Lakh the winner of each hand pays a share of the whole pot — the rate
// their LEVEL sets, 20% at Level 1 falling to 10% at Level 50, and 4% for the
// VIP tier, which is set by hand and never reached by XP. The server decides
// and takes all of it; the app names it.
//
// Held here: the wire read tolerantly (absent keys are no tax, no level); a
// rate in basis points read as a player reads it; the pill on the two taxing
// lobby cards only, with the VIEWER's rate, moving no other line of the card;
// the ⓘ popup's rows and the rules' one sentence; the pill under the felt's
// tag at two to five places, clear of every seat and corner, and its popup
// (level, XP, today, rate, next level — or the top, or VIP with no XP); the
// winner's ribbon saying the tax and the stack landing on the pot less the
// tax, never above it; the player's level replaced live, with a level-up
// toast; the Stats drawer's level and today's XP; and every one of those at
// 640x360 with text x1.25 in all five languages, in both themes, with nothing
// cut and nothing overflowing.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/missile_strike.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/game_card.dart';
import 'package:teenpatti/widgets/missile_flight.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/table_chrome.dart';
import 'package:teenpatti/widgets/table_tax.dart';

import 'script_fonts.dart';
import 'table_scenes.dart' show silentFeedback, tableApp;
import 'winner_scenes.dart';

// ------------------------------------------------------------------ fixtures

int get _now => DateTime.now().millisecondsSinceEpoch;

/// The player at Level 10 with 23 of today's 50 XP and five hours left of
/// the day's window.
Map<String, Object?> _level10() => {
  'level': 10,
  'title': 'Rising Star',
  'icon': '🌟',
  'xp': 4180,
  'taxBps': 1816,
  'vip': false,
  'next': {
    'level': 11,
    'title': 'Pro Player',
    'icon': '🏅',
    'minXp': 5200,
    'taxBps': 1796,
  },
  'today': {'xp': 23, 'cap': 50, 'resetsAt': _now + 5 * 3600 * 1000},
};

/// The VIP tier: set by hand, no next level.
Map<String, Object?> _vip() => {
  'level': 51,
  'title': 'VIP',
  'icon': '💎👑',
  'xp': 4180,
  'taxBps': 400,
  'vip': true,
  'today': {'xp': 12, 'cap': 50, 'resetsAt': _now + 3600 * 1000},
};

/// The top of the ladder: nothing further for XP to reach.
Map<String, Object?> _top() => {
  'level': 50,
  'title': 'King of Kings',
  'icon': '👑👑',
  'xp': 2150000,
  'taxBps': 1000,
  'vip': false,
  'today': {'xp': 50, 'cap': 50, 'resetsAt': _now + 3600 * 1000},
};

/// The Teen Patti menu with the two taxing tables, as the server sends it.
List<Map<String, Object>> _menu({bool tax = true}) => [
  {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
  {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
  {'category': 'blind', 'bootAmount': 5000, 'maxChips': 50000000},
  {'category': 'blind', 'bootAmount': 50000, 'maxChips': 1000000000},
  {
    'category': 'blind',
    'bootAmount': 1000000,
    'minChips': 500000000,
    'winnerTax': tax,
  },
  {'category': 'variation', 'bootAmount': 50000, 'maxChips': 1000000000},
  {
    'category': 'variation',
    'bootAmount': 1000000,
    'minChips': 500000000,
    'winnerTax': tax,
  },
];

User _user({Map<String, Object?>? level, int chips = 600000000}) =>
    User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Priya',
      'chips': chips,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
      'playerLevel': ?level,
    });

GameState _lobbyState({
  AppLang lang = AppLang.english,
  Map<String, Object?>? level,
  bool tax = true,
}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = Screen.lobby
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': _menu(tax: tax),
    })
    ..user = _user(level: level ?? _level10());
}

/// A hand at a taxing table of [places] places — Blind 10 Lakh unless
/// [category] says otherwise — the viewer blind, nobody on turn.
RoomState _taxRoom({
  int places = 5,
  String category = 'blind',
  bool winnerTax = true,
  int? taxBps = 1816,
}) => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': category,
  'chipsHidden': true,
  'state': 'betting',
  'handNo': 3,
  'dealerSeat': 1,
  'maxPlayers': places,
  'minPlayers': 2,
  'bootAmount': 1000000,
  'turnTimeoutMs': 25000,
  'pot': 5000000,
  'maxPot': 0,
  'stake': 1000000,
  'turn': {'seatIndex': -1, 'userId': null, 'deadline': 0},
  if (winnerTax) 'winnerTax': true,
  'you': {
    'seatIndex': 0,
    'chips': 900000000,
    'status': 'active',
    'isBlind': true,
    'blindMovesLeft': 3,
    'contributed': 1000000,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': const <String>[],
    'taxBps': ?taxBps,
  },
  'seats': [
    for (var i = 0; i < places; i++)
      {
        'seatIndex': i,
        'userId': 'u$i',
        'displayName': ['Priya', 'Ravi', 'Meera', 'Arjun', 'Kavya'][i],
        'chips': i == 0 ? 900000000 : null,
        'status': 'active',
        'isBlind': true,
        'lastBet': 1000000,
        'lastAction': 'chaal',
        'contributed': 1000000,
        'connected': true,
        'cardCount': 3,
      },
  ],
});

GameState _tableState({
  RoomState? room,
  Map<String, Object?>? level,
  AppLang lang = AppLang.english,
  int places = 5,
}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  state
    ..lang = lang
    ..user = _user(level: level ?? _level10(), chips: 900000000)
    ..screen = Screen.table
    ..config = GameConfig.fallback.copyWith(maxPlayers: places)
    ..handleState(room ?? _taxRoom(places: places));
  return state;
}

// --------------------------------------------------------------- fonts

/// The colour emoji a phone draws a level's mark (🌟, 💎👑) from; without it
/// the test engine draws each as an empty box of the wrong width.
const _emojiFont = '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf';
const _emojiFamily = 'Noto Color Emoji';

Future<void> _loadFonts() async {
  await loadScriptFonts();
  final emoji = File(_emojiFont);
  if (emoji.existsSync()) {
    final loader = FontLoader(_emojiFamily)
      ..addFont(Future.value(ByteData.sublistView(emoji.readAsBytesSync())));
    await loader.load();
  }
}

/// The theme with a phone's fallbacks: the Indic scripts' Noto fonts and the
/// colour emoji.
ThemeData _theme({bool dark = true}) {
  final base = dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamilyFallback: [...scriptFonts.keys, _emojiFamily],
    ),
  );
}

// ------------------------------------------------------------- mounting

Finder _private(String type) => find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == type,
  skipOffstage: false,
);

Rect _onScreen(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

Future<void> _pumpLobby(
  WidgetTester tester,
  GameState state, {
  Size screen = const Size(640, 360),
  double scale = 1.0,
  bool dark = true,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _theme(dark: dark),
        builder: (context, child) => GlassBudget(child: child!),
        home: const LobbyScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _pumpTable(
  WidgetTester tester,
  GameState state, {
  Size screen = const Size(891, 411),
  double scale = 1.0,
  bool dark = true,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    tableApp(
      state: state,
      feedback: feedback,
      theme: _theme(dark: dark),
    ),
  );
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 900));
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

/// Every paragraph under [of] that ran out of lines, by its words.
List<String> _cut(Finder of) => [
  for (final e
      in find
          .descendant(
            of: of,
            matching: find.byType(RichText, skipOffstage: false),
          )
          .evaluate())
    if ((e.renderObject! as RenderParagraph).didExceedMaxLines)
      (e.widget as RichText).text.toPlainText(),
];

/// The 10 Lakh card's column on the rail: the one whose words name the stake.
Finder _tenLakhColumn(WidgetTester tester, Strings t) {
  final boot = formatChips(1000000);
  for (final e in find.byType(CardColumn, skipOffstage: false).evaluate()) {
    final words = [
      for (final p
          in find
              .descendant(
                of: find.byWidget(e.widget, skipOffstage: false),
                matching: find.byType(RichText, skipOffstage: false),
              )
              .evaluate())
        (p.widget as RichText).text.toPlainText(),
    ];
    if (words.contains(boot)) return find.byWidget(e.widget);
  }
  throw StateError('no 10 Lakh card on the rail');
}

/// The rects of every line of words in [column], by the words — an icon's
/// glyph is not a line of words.
Map<String, Rect> _lines(Finder column) => {
  for (final e
      in find
          .descendant(
            of: column,
            matching: find.byType(RichText, skipOffstage: false),
          )
          .evaluate())
    if (e.findAncestorWidgetOfExactType<Icon>() == null)
      (e.widget as RichText).text.toPlainText(): _onScreen(
        e.renderObject! as RenderBox,
      ),
};

/// The lobby card of the [category] table at [boot].
Finder _card(String category, int boot) => find.byWidgetPredicate(
  (w) =>
      w.runtimeType.toString() == '_TableCard' &&
      (w as dynamic).table.category == category &&
      (w as dynamic).table.bootAmount == boot,
  skipOffstage: false,
);

/// Taps [icon] — a card's ⓘ or rules key — on that card.
Future<void> _tapCornerKey(
  WidgetTester tester,
  String category,
  int boot,
  IconData icon,
) async {
  final key = find.descendant(
    of: _card(category, boot),
    matching: find.byIcon(icon, skipOffstage: false),
  );
  await tester.ensureVisible(key);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(key);
  await tester.pump(const Duration(milliseconds: 500));
}

/// The discs of every table card's corner keys, on screen.
List<Rect> _cornerDiscs() => [
  for (final key in _private('_CardCornerKey').evaluate())
    if (key.renderObject case final RenderBox box when box.hasSize)
      _onScreen(box).deflate((Dim.minTouch - 28) / 2),
];

/// The felt pill's plate, on screen.
Rect _feltPill(WidgetTester tester) => tester.getRect(
  find.descendant(of: find.byType(WinningTaxTag), matching: find.byType(Plate)),
);

/// The category tag's plate, on screen.
Rect _tagPlate(WidgetTester tester) => tester.getRect(
  find
      .descendant(of: _private('_CategoryTag'), matching: find.byType(Plate))
      .first,
);

// ---------------------------------------------------------- the hand end

// The viewer (u0) pays for the show and takes the pot: 13,400, of which
// the server takes 2,433 as winning tax at 18.16%.
const _before = 50000;
const _tax = 2433;
const _settled = _before + winnerPot - _tax;

int _number(String figure) =>
    int.parse(figure.replaceAll(RegExp(r'[^0-9]'), ''));
final _figure = RegExp(r'^[0-9][0-9,.]*( Lakh| Crore)?$');

Finder _pod(String userId) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId);

String _stack(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(of: _pod('u0'), matching: find.byType(Text)),
    )
    .map((t) => t.data ?? '')
    .firstWhere(_figure.hasMatch);

Future<GameState> _showdown(
  WidgetTester tester, {
  required bool taxed,
  AppLang lang = AppLang.english,
  Size screen = const Size(891, 411),
  double scale = 1.0,
  bool dark = true,
}) async {
  final state = winnerState(lang: lang)
    ..handleState(winnerRoom(chips: {'u0': _before + winnerShowCost}));
  await _pumpTable(tester, state, screen: screen, scale: scale, dark: dark);
  state
    ..handleState(
      winnerRoom(
        turn: null,
        pot: winnerPot,
        chips: {'u0': _before},
        contributed: {'u0': winnerContributed[0] + winnerShowCost},
      ),
    )
    ..handleShowdown(winnerReveal('u0'));
  await tester.pump(const Duration(milliseconds: 16));
  if (taxed) {
    state.handleHandTax((winnerId: 'u0', tax: _tax, taxBps: 1816));
  }
  state
    ..handleShowdown(winnerEnded('u0'))
    ..handleState(
      winnerRoom(
        state: 'waiting',
        turn: null,
        pot: 0,
        status: {'u0': 'won', 'u3': 'lost'},
        chips: {'u0': taxed ? _settled : _before + winnerPot},
        contributed: {'u0': winnerContributed[0] + winnerShowCost},
      ),
    );
  await tester.pump(const Duration(milliseconds: 16));
  return state;
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    // Where async is real: a future first awaited inside one test's fake
    // clock never completes in the next (CLAUDE.md §12.3).
    await FireworksArt.load();
    await MissileArt.load();
  });

  group('the wire', () {
    test('a menu entry says whether its table taxes the winner, and anything '
        'else reads as no tax', () {
      LobbyTable table(Map<String, Object?> extra) => LobbyTable.fromJson({
        'category': 'blind',
        'bootAmount': 1000000,
        ...extra,
      });
      expect(table({'winnerTax': true}).taxesWinner, isTrue);
      expect(table({}).winnerTax, isFalse);
      expect(table({'winnerTax': 'true'}).winnerTax, isFalse);
      expect(table({'winnerTax': 1}).winnerTax, isFalse);
      // A poker table never taxes, whatever its entry says.
      final poker = LobbyTable.fromJson({
        'category': 'texas_holdem',
        'bootAmount': 50000,
        'game': 'poker',
        'winnerTax': true,
      });
      expect(poker.winnerTax, isTrue);
      expect(poker.taxesWinner, isFalse);
      // The catalogue's body carries it the same way.
      final config = GameConfig.fromCatalogue({
        'version': 'v1',
        'maxPlayers': 5,
        'tables': _menu(),
        'privateTables': const <Object>[],
      })!;
      expect(
        [
          for (final t in config.tables)
            if (t.taxesWinner) '${t.category}:${t.bootAmount}',
        ],
        ['blind:1000000', 'variation:1000000'],
      );
    });

    test('a room and a seat carry the tax, and absent keys are none', () {
      final room = _taxRoom();
      expect(room.winnerTax, isTrue);
      expect(room.taxesWinner, isTrue);
      expect(room.you!.taxBps, 1816);

      final plain = _taxRoom(winnerTax: false, taxBps: null);
      expect(plain.winnerTax, isFalse);
      expect(plain.you!.taxBps, isNull);

      // A rate no table could charge is no rate at all.
      for (final bad in [-1, 10001, '1816', null]) {
        final you = You.fromJson({'seatIndex': 0, 'taxBps': bad});
        expect(you.taxBps, isNull, reason: '$bad');
      }
      expect(You.fromJson({'taxBps': 0}).taxBps, 0);
      expect(You.fromJson({'taxBps': 10000}).taxBps, 10000);

      // Never at a poker room.
      final poker = RoomState.fromJson({
        'roomId': 'p1',
        'category': 'texas_holdem',
        'game': 'poker',
        'winnerTax': true,
      });
      expect(poker.taxesWinner, isFalse);
    });

    test('the player level is read with its mark, its next level and today, '
        'and a VIP has no next level', () {
      final level = PlayerLevel.maybe(_level10())!;
      expect(level.level, 10);
      expect(level.title, 'Rising Star');
      expect(level.icon, '🌟');
      expect(level.xp, 4180);
      expect(level.taxBps, 1816);
      expect(level.vip, isFalse);
      expect(level.next!.level, 11);
      expect(level.next!.icon, '🏅');
      expect(level.next!.minXp, 5200);
      expect(level.next!.taxBps, 1796);
      expect(level.today!.xp, 23);
      expect(level.today!.cap, 50);
      expect(level.today!.full, isFalse);

      // VIP: never a rung XP climbs to or from, whatever came with it.
      final vip = PlayerLevel.maybe({
        ..._vip(),
        'next': {'level': 52, 'title': 'x', 'minXp': 1, 'taxBps': 100},
      })!;
      expect(vip.vip, isTrue);
      expect(vip.next, isNull);

      // No mark is the title alone; an unusable level is no level.
      expect(PlayerLevel.maybe({..._level10(), 'icon': null})!.icon, '');
      expect(PlayerLevel.maybe({..._level10(), 'level': 0}), isNull);
      expect(PlayerLevel.maybe({..._level10(), 'taxBps': 20000}), isNull);
      expect(PlayerLevel.maybe('level 10'), isNull);
      expect(PlayerLevel.maybe({..._level10(), 'next': 'x'})!.next, isNull);
      expect(PlayerLevel.maybe({..._level10(), 'today': null})!.today, isNull);
      expect(
        PlayerLevel.maybe({
          ..._level10(),
          'today': {'xp': 3, 'cap': 0},
        })!.today,
        isNull,
      );

      // The account carries it, and keeps it through its copies.
      final user = _user(level: _level10());
      expect(user.playerLevel!.level, 10);
      expect(user.withHammer(3).playerLevel!.level, 10);
      expect(user.withMissile(2).playerLevel!.level, 10);
      expect(_user().playerLevel, isNull);
      expect(
        User.fromJson({'id': 'u0', 'displayName': 'x'}).playerLevel,
        isNull,
      );
    });

    test('a hand end says what its winner paid, and nothing where nothing was '
        'taken', () {
      final taken = handTaxOf({
        'winnerId': 'u3',
        'pot': 13400,
        'tax': 2433,
        'taxBps': 1816,
      });
      expect(taken.winnerId, 'u3');
      expect(taken.tax, 2433);
      expect(taken.taxBps, 1816);

      final none = handTaxOf({'winnerId': 'u3', 'pot': 13400});
      expect(none.tax, 0);
      expect(none.taxBps, 0);
      expect(handTaxOf({'tax': -5, 'taxBps': 1816}).tax, 0);
      expect(handTaxOf({'tax': '2433'}).tax, 0);
      expect(handTaxOf({'tax': 10, 'taxBps': 99999}).taxBps, 0);
    });

    test('a rate reads with two decimals, and a whole .00 is dropped', () {
      expect(formatTaxRate(2000), '20%');
      expect(formatTaxRate(1980), '19.80%');
      expect(formatTaxRate(1959), '19.59%');
      expect(formatTaxRate(1816), '18.16%');
      expect(formatTaxRate(400), '4%');
      expect(formatTaxRate(1000), '10%');
      expect(formatTaxRate(5), '0.05%');
      expect(formatTaxRate(0), '0%');
    });
  });

  group('the words', () {
    const keys = [
      'taxPill',
      'taxPillVip',
      'taxPillNoRate',
      'winningTaxTitle',
      'winningTaxLabel',
      'yourLevelLabel',
      'xpLabel',
      'yourRateLabel',
      'nextLevelLabel',
      'levelName',
      'levelLine',
      'nextLevelValue',
      'topLevelNote',
      'winningTaxOnlyWinner',
      'winningTaxFalls',
      'ruleWinningTax',
      'ruleWinningTaxVip',
      'winnerTaxLine',
      'levelUp',
      'xpToday',
      'xpResetsIn',
      'todayLabel',
    ];

    test('are in all five languages, each with its figures', () {
      final english = Strings(AppLang.english);
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        for (final key in keys) {
          final own = t.ownEntry(key);
          expect(own, isNotNull, reason: '${lang.code}: $key');
          // Every placeholder the English carries, the translation carries.
          for (final m in RegExp(
            r'\{\w+\}',
          ).allMatches(english.ownEntry(key)!)) {
            expect(own, contains(m.group(0)), reason: '${lang.code}: $key');
          }
        }
      }
    });

    test('name a level with its mark, and a VIP by the tier alone', () {
      final t = Strings(AppLang.english);
      final level = PlayerLevel.maybe(_level10())!;
      final vip = PlayerLevel.maybe(_vip())!;
      expect(levelNameOf(t, level), 'Level 10 · 🌟 Rising Star');
      expect(levelLineOf(t, level), 'Level 10 · 🌟 Rising Star · 4,180 XP');
      expect(levelNameOf(t, vip), '💎👑 VIP');
      expect(levelLineOf(t, vip), '💎👑 VIP');
      expect(
        levelNameOf(t, PlayerLevel.maybe({..._level10(), 'icon': ''})!),
        'Level 10 · Rising Star',
      );
      expect(taxPillLabel(t, bps: 1816), '18.16% TAX');
      expect(taxPillLabel(t, bps: 400, vip: true), '4% TAX · VIP');
      expect(taxPillLabel(t), 'TAX');
      expect(
        t.winningTaxRule('20%', '4%'),
        'The winner of each hand pays a share of the pot as winning tax — '
        '20% at Level 1, less at every level up. VIP players pay 4%.',
      );
      final today = level.today!;
      final line = xpTodayOf(t, today, DateTime.now());
      expect(line, startsWith('Today 23 / 50 XP · resets in 4h 59m'));
      // No window running: the day's XP alone.
      expect(
        xpTodayOf(t, const XpToday(xp: 0, cap: 50), DateTime.now()),
        'Today 0 / 50 XP',
      );
    });
  });

  group('the lobby card', () {
    testWidgets('carries the pill on the two taxing tables only, with the '
        "viewer's own rate", (tester) async {
      final state = _lobbyState()..openLobbyCategory(TableCategory.blind);
      await _pumpLobby(tester, state);
      final pills = find.byType(WinningTaxPill, skipOffstage: false);
      expect(pills, findsOneWidget);
      expect(tester.widget<WinningTaxPill>(pills).label, '18.16% TAX');
      // On the 10 Lakh card, not on the cheaper three.
      final column = _tenLakhColumn(tester, state.t);
      expect(find.descendant(of: column, matching: pills), findsOneWidget);

      state.openLobbyCategory(TableCategory.variation);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(WinningTaxPill, skipOffstage: false), findsOneWidget);

      // The seen table does not tax.
      state.openLobbyCategory(TableCategory.seen);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(WinningTaxPill, skipOffstage: false), findsNothing);
      await _unmount(tester, state);
    });

    testWidgets('says a VIP\'s rate and VIP; an unknown level says TAX alone', (
      tester,
    ) async {
      final vip = _lobbyState(level: _vip())
        ..openLobbyCategory(TableCategory.blind);
      await _pumpLobby(tester, vip);
      expect(
        tester
            .widget<WinningTaxPill>(
              find.byType(WinningTaxPill, skipOffstage: false),
            )
            .label,
        '4% TAX · VIP',
      );
      await _unmount(tester, vip);

      final unknown = _lobbyState()
        ..user = _user().withPlayerLevel(null)
        ..openLobbyCategory(TableCategory.blind);
      await _pumpLobby(tester, unknown);
      expect(
        tester
            .widget<WinningTaxPill>(
              find.byType(WinningTaxPill, skipOffstage: false),
            )
            .label,
        'TAX',
      );
      await _unmount(tester, unknown);
    });

    for (final scale in [1.0, 1.25]) {
      testWidgets('moves no other line of the card (x$scale)', (tester) async {
        for (final lang in AppLang.values) {
          for (final category in [
            TableCategory.blind,
            TableCategory.variation,
          ]) {
            Future<Map<String, Rect>> linesWith({required bool tax}) async {
              final state = _lobbyState(lang: lang, tax: tax)
                ..openLobbyCategory(category);
              await _pumpLobby(tester, state, scale: scale);
              final lines = _lines(_tenLakhColumn(tester, state.t));
              await _unmount(tester, state);
              return lines;
            }

            final plain = await linesWith(tax: false);
            final taxed = await linesWith(tax: true);
            for (final MapEntry(key: words, value: rect) in plain.entries) {
              final now = taxed[words];
              expect(now, isNotNull, reason: '${lang.code} $category "$words"');
              expect(
                (now!.topLeft - rect.topLeft).distance < 0.01 &&
                    (now.width - rect.width).abs() < 0.01 &&
                    (now.height - rect.height).abs() < 0.01,
                isTrue,
                reason: '${lang.code} $category "$words": $rect -> $now',
              );
            }
            // And the one line it added is the pill's.
            expect(
              taxed.keys.toSet().difference(plain.keys.toSet()),
              {Strings(lang).taxPill('18.16%')},
              reason: '${lang.code} $category',
            );
          }
        }
      });
    }

    testWidgets(
      'its ⓘ popup names the winning tax and the level that sets it',
      (tester) async {
        final state = _lobbyState()..openLobbyCategory(TableCategory.blind);
        final t = state.t;
        await _pumpLobby(tester, state);
        await _tapCornerKey(
          tester,
          TableCategory.blind,
          1000000,
          Icons.info_outline_rounded,
        );
        expect(find.text(t.winningTaxLabel), findsOneWidget);
        expect(find.text('18.16%'), findsOneWidget);
        expect(find.text(t.yourLevelLabel), findsOneWidget);
        expect(find.text('Level 10 · 🌟 Rising Star'), findsOneWidget);
        await tester.tap(find.byTooltip(t.close));
        await tester.pump(const Duration(milliseconds: 500));

        // An untaxed table's popup says nothing of it.
        await _tapCornerKey(
          tester,
          TableCategory.blind,
          200,
          Icons.info_outline_rounded,
        );
        expect(find.text(t.winningTaxLabel), findsNothing);
        expect(find.text(t.yourLevelLabel), findsNothing);
        await tester.tap(find.byTooltip(t.close));
        await tester.pump(const Duration(milliseconds: 500));
        await _unmount(tester, state);
      },
    );

    testWidgets("its rules say the tax in one sentence; an untaxed table's do "
        'not', (tester) async {
      final state = _lobbyState()..openLobbyCategory(TableCategory.variation);
      final t = state.t;
      await _pumpLobby(tester, state);
      final rule = t.winningTaxRule('20%', '4%');
      await _tapCornerKey(
        tester,
        TableCategory.variation,
        1000000,
        Icons.menu_book_outlined,
      );
      expect(find.text(rule), findsOneWidget);
      await tester.tap(find.byTooltip(t.close));
      await tester.pump(const Duration(milliseconds: 500));

      await _tapCornerKey(
        tester,
        TableCategory.variation,
        50000,
        Icons.menu_book_outlined,
      );
      expect(find.text(rule), findsNothing);
      await tester.tap(find.byTooltip(t.close));
      await tester.pump(const Duration(milliseconds: 500));
      await _unmount(tester, state);
    });
  });

  group('the felt', () {
    testWidgets('hangs the pill under the tag of a taxing table only', (
      tester,
    ) async {
      final state = _tableState();
      await _pumpTable(tester, state);
      expect(find.byType(WinningTaxTag), findsOneWidget);
      expect(
        tester.widget<WinningTaxTag>(find.byType(WinningTaxTag)).label,
        '18.16% TAX',
      );
      await _unmount(tester, state);

      final plain = _tableState(room: _taxRoom(winnerTax: false, taxBps: null));
      await _pumpTable(tester, plain);
      expect(find.byType(WinningTaxTag), findsNothing);
      await _unmount(tester, plain);

      // A VIP's seat: their rate and VIP.
      final vip = _tableState(room: _taxRoom(taxBps: 400), level: _vip());
      await _pumpTable(tester, vip);
      expect(
        tester.widget<WinningTaxTag>(find.byType(WinningTaxTag)).label,
        '4% TAX · VIP',
      );
      await _unmount(tester, vip);
    });

    const screens = [
      Size(640, 360),
      Size(592, 360),
      Size(732, 412),
      Size(844, 390),
      Size(891, 411),
      Size(915, 412),
      Size(1280, 800),
    ];
    for (final screen in screens) {
      for (final scale in [1.0, 1.25]) {
        final label =
            '${screen.width.toInt()}x${screen.height.toInt()} x$scale';
        testWidgets('under the tag at two to five places, clear of every seat '
            'and corner, at $label', (tester) async {
          final problems = <String>[];
          for (var n = 2; n <= 5; n++) {
            final state = _tableState(places: n);
            await _pumpTable(tester, state, screen: screen, scale: scale);
            expect(tester.takeException(), isNull, reason: '$label $n');
            final pill = _feltPill(tester);
            final tag = _tagPlate(tester);
            final slot = tester.getRect(_private('_CategoryTag'));
            // Under the tag, on its middle, in its slot: it moves with it.
            if ((pill.center.dx - tag.center.dx).abs() > 1) {
              problems.add('$label $n: pill $pill off the tag $tag');
            }
            if (pill.top < tag.bottom) {
              problems.add('$label $n: pill $pill over the tag $tag');
            }
            if (pill.left < slot.left - 0.5 || pill.right > slot.right + 0.5) {
              problems.add('$label $n: pill $pill out of the slot $slot');
            }
            final others = <String, Rect>{
              for (var i = 0; i < n; i++)
                'seat $i': tester.getRect(find.byType(SeatPod).at(i)),
              'pot': tester.getRect(_private('_Pot')),
              'shop key': tester.getRect(find.byType(ShopButton)),
              'wallet': tester.getRect(find.byType(WalletPill)),
            };
            others.forEach((what, rect) {
              final o = pill.intersect(rect);
              if (o.width > 0.5 && o.height > 0.5) {
                problems.add('$label $n: pill $pill over $what $rect');
              }
            });
            await _unmount(tester, state);
          }
          expect(problems, isEmpty);
        });
      }
    }

    testWidgets('a tap opens the popup: who pays, the level, XP, today, the '
        'rate and the next level', (tester) async {
      final state = _tableState();
      final t = state.t;
      await _pumpTable(tester, state);
      await tester.tap(find.byType(WinningTaxTag));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(WinningTaxInfo), findsOneWidget);
      expect(find.text(t.winningTaxOnlyWinner), findsOneWidget);
      expect(find.text(t.winningTaxFalls), findsOneWidget);
      expect(find.text('Level 10 · 🌟 Rising Star'), findsOneWidget);
      expect(find.text('4,180'), findsOneWidget);
      expect(find.text('23 / 50 XP'), findsOneWidget);
      expect(find.text('18.16%'), findsOneWidget);
      expect(find.text('Level 11 · 🏅 Pro Player'), findsOneWidget);
      expect(find.text('5,200 XP · 17.96%'), findsOneWidget);
      expect(find.text(t.topLevelNote), findsNothing);
      await tester.tap(find.text(t.close));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(WinningTaxInfo), findsNothing);
      await _unmount(tester, state);
    });

    testWidgets('a VIP is shown the tier and the rate, and nothing of XP', (
      tester,
    ) async {
      final state = _tableState(room: _taxRoom(taxBps: 400), level: _vip());
      final t = state.t;
      await _pumpTable(tester, state);
      await tester.tap(find.byType(WinningTaxTag));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('💎👑 VIP'), findsOneWidget);
      expect(find.text('4%'), findsOneWidget);
      expect(find.text(t.xpLabel), findsNothing);
      expect(find.text(t.todayLabel), findsNothing);
      expect(find.text(t.nextLevelLabel), findsNothing);
      expect(find.text(t.winningTaxFalls), findsNothing);
      expect(find.text(t.topLevelNote), findsNothing);
      expect(find.textContaining('XP'), findsNothing);
      await _unmount(tester, state);
    });

    testWidgets('at the top of the ladder the popup says it is the top', (
      tester,
    ) async {
      final state = _tableState(room: _taxRoom(taxBps: 1000), level: _top());
      final t = state.t;
      await _pumpTable(tester, state);
      await tester.tap(find.byType(WinningTaxTag));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Level 50 · 👑👑 King of Kings'), findsOneWidget);
      expect(find.text('10%'), findsOneWidget);
      expect(find.text(t.topLevelNote), findsOneWidget);
      expect(find.text(t.nextLevelLabel), findsNothing);
      await _unmount(tester, state);
    });
  });

  group('the hand end', () {
    testWidgets("the winner's ribbon says the tax, and the stack lands on the "
        'pot less the tax — never above it', (tester) async {
      final state = await _showdown(tester, taxed: true);
      expect(state.winnerTax, _tax);
      expect(state.winnerTaxBps, 1816);
      expect(state.winnerLanded, winnerPot - _tax);

      final stacks = <int>[];
      for (var at = 0; at < 2600; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        stacks.add(_number(_stack(tester)));
      }
      // What it was until the chips land, then only up, to the settled
      // stack — the pot less the tax — and never past it.
      expect(stacks.first, _before);
      for (var i = 1; i < stacks.length; i++) {
        expect(stacks[i], greaterThanOrEqualTo(stacks[i - 1]), reason: '$i');
        expect(stacks[i], lessThanOrEqualTo(_settled), reason: '$i');
      }
      expect(stacks.last, _settled);

      final line = state.t.winnerTaxLine(formatChips(_tax));
      expect(line, 'Winning tax −2,433');
      expect(
        find.descendant(of: _pod('u0'), matching: find.text(line)),
        findsOneWidget,
      );
      await _unmount(tester, state);
    });

    testWidgets('no tax line where none was taken, and the whole pot lands', (
      tester,
    ) async {
      final state = await _showdown(tester, taxed: false);
      expect(state.winnerTax, 0);
      for (var at = 0; at < 2600; at += 16) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(_number(_stack(tester)), _before + winnerPot);
      expect(find.textContaining('Winning tax'), findsNothing);
      await _unmount(tester, state);
    });

    testWidgets('a tax is taken up by the news naming its winner, waits with '
        'it behind a missile, and is forgotten with the hand', (tester) async {
      final state = winnerState();
      // Another winner's tax is not this one's.
      state
        ..handleHandTax((winnerId: 'u3', tax: 99, taxBps: 2000))
        ..handleShowdown(winnerEnded('u0'));
      expect(state.winnerTax, 0);

      // Behind a missile volley the result waits, and its tax with it.
      state
        ..handleState(winnerNextDeal('u0'))
        ..handleState(winnerRoom(handNo: 9));
      expect(state.winnerTax, 0);
      state.handleTableAction((
        userId: 'u0',
        action: GameAction.missile,
        reason: null,
      ));
      expect(state.missileStrike, isNotNull);
      state
        ..handleHandTax((winnerId: 'u0', tax: _tax, taxBps: 1816))
        ..handleShowdown(winnerEnded('u0'));
      expect(state.winnerId, isNull, reason: 'held behind the volley');
      await tester.pump(
        MissileTiming.reveal(1) + const Duration(milliseconds: 50),
      );
      expect(state.winnerId, 'u0');
      expect(state.winnerTax, _tax);
      expect(state.winnerTaxBps, 1816);

      // The next deal forgets it.
      state.handleState(winnerRoom(handNo: 10));
      expect(state.winnerTax, 0);
      expect(state.winnerTaxBps, 0);
      await tester.pump(const Duration(seconds: 10));
      state.dispose();
    });
  });

  group('the level', () {
    test(
      'player:level replaces the level and says a level up, never for VIP',
      () {
        final state = _lobbyState(level: {..._level10(), 'level': 9});
        state.handlePlayerLevel(PlayerLevel.maybe(_level10())!);
        expect(state.user!.playerLevel!.level, 10);
        expect(
          state.notice,
          'Level up! 🌟 Level 10 · Rising Star — your winning tax is now '
          '18.16%.',
        );

        // More XP, the same level: the level is replaced and nothing is said.
        state.notice = null;
        state.handlePlayerLevel(
          PlayerLevel.maybe({..._level10(), 'xp': 4200})!,
        );
        expect(state.user!.playerLevel!.xp, 4200);
        expect(state.notice, isNull);

        // VIP is set by hand: no toast into it, or out of it.
        state.handlePlayerLevel(PlayerLevel.maybe(_vip())!);
        expect(state.user!.playerLevel!.vip, isTrue);
        expect(state.notice, isNull);
        state.handlePlayerLevel(PlayerLevel.maybe(_level10())!);
        expect(state.notice, isNull);
        state.dispose();
      },
    );

    for (final lang in AppLang.values) {
      test('the level-up toast reads in ${lang.englishName}', () {
        final state = _lobbyState(
          lang: lang,
          level: {..._level10(), 'level': 9},
        );
        state.handlePlayerLevel(PlayerLevel.maybe(_level10())!);
        final t = Strings(lang);
        expect(
          state.notice,
          t.levelUp('🌟 ${t.levelName(10, 'Rising Star')}', '18.16%'),
        );
        expect(state.notice, contains('18.16%'));
        state.dispose();
      });
    }

    testWidgets("the Stats drawer names the level and today's XP; a VIP's the "
        'tier alone', (tester) async {
      final state = _lobbyState();
      await _pumpLobby(tester, state);
      await tester.tap(find.byIcon(Icons.insights_outlined).first);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Level 10 · 🌟 Rising Star · 4,180 XP'), findsOneWidget);
      final today = tester.widget<Text>(
        find.byKey(const ValueKey('stats-xp-today')),
      );
      expect(today.data, startsWith('Today 23 / 50 XP · resets in 4h 59m'));
      await _unmount(tester, state);

      final vip = _lobbyState(level: _vip());
      await _pumpLobby(tester, vip);
      await tester.tap(find.byIcon(Icons.insights_outlined).first);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('💎👑 VIP'), findsOneWidget);
      expect(find.byKey(const ValueKey('stats-xp-today')), findsNothing);
      await _unmount(tester, vip);
    });
  });

  group('at 640x360, text x1.25', () {
    for (final lang in AppLang.values) {
      for (final dark in [true, false]) {
        final label = '${lang.code}, ${dark ? 'dark' : 'light'}';
        testWidgets('$label: the lobby card, its popup and the Stats drawer '
            'with nothing cut', (tester) async {
          final state = _lobbyState(lang: lang)
            ..openLobbyCategory(TableCategory.variation);
          final t = state.t;
          await _pumpLobby(tester, state, scale: 1.25, dark: dark);
          expect(tester.takeException(), isNull);

          final column = _tenLakhColumn(tester, t);
          expect(_cut(column), isEmpty);
          // The pill whole on its line, clear of the corner keys, hardly
          // scaled; the column not scaled below its usual.
          final pill = find.byType(WinningTaxPill, skipOffstage: false);
          final fitted = tester.renderObject<RenderFittedBox>(
            find
                .descendant(
                  of: find.byType(WinningTaxBeside, skipOffstage: false),
                  matching: find.byType(FittedBox, skipOffstage: false),
                )
                .first,
          );
          final scale = fitted.size.width / fitted.child!.size.width;
          expect(scale, greaterThan(0.8), reason: '$label: pill at $scale');
          final pillRect = _onScreen(tester.renderObject<RenderBox>(pill));
          for (final disc in _cornerDiscs()) {
            expect(pillRect.overlaps(disc), isFalse, reason: label);
          }
          final card = _onScreen(
            tester.renderObject<RenderBox>(
              find.ancestor(of: column, matching: find.byType(GameCard)).first,
            ),
          );
          expect(card.contains(pillRect.topLeft), isTrue);
          expect(card.contains(pillRect.bottomRight), isTrue);

          // Its popup: the winning tax's rows whole (the popup's own title
          // runs to an ellipsis at this size in every language, as it did
          // before the tax).
          await _tapCornerKey(
            tester,
            TableCategory.variation,
            1000000,
            Icons.info_outline_rounded,
          );
          expect(tester.takeException(), isNull);
          for (final row in [t.winningTaxLabel, t.yourLevelLabel]) {
            final fact = find.ancestor(
              of: find.text(row),
              matching: find.byType(Row),
            );
            expect(_cut(fact.first), isEmpty, reason: '$label: $row');
          }
          expect(
            find.text(levelNameOf(t, state.user!.playerLevel!)),
            findsOneWidget,
          );
          await tester.tap(find.byTooltip(t.close));
          await tester.pump(const Duration(milliseconds: 500));

          // The Stats drawer.
          await tester.tap(find.byIcon(Icons.insights_outlined).first);
          await tester.pump(const Duration(milliseconds: 600));
          expect(tester.takeException(), isNull);
          expect(_cut(find.byKey(const ValueKey('stats-level'))), isEmpty);
          await _unmount(tester, state);
        });

        testWidgets('$label: the felt pill, its popup and the tax on the '
            'ribbon with nothing cut', (tester) async {
          final state = _tableState(lang: lang);
          final t = state.t;
          await _pumpTable(
            tester,
            state,
            screen: const Size(640, 360),
            scale: 1.25,
            dark: dark,
          );
          expect(tester.takeException(), isNull);
          expect(_cut(find.byType(WinningTaxTag)), isEmpty);
          final pill = _feltPill(tester);
          expect(pill.top, greaterThanOrEqualTo(_tagPlate(tester).bottom));

          await tester.tap(find.byType(WinningTaxTag));
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull);
          expect(_cut(find.byType(WinningTaxInfo)), isEmpty, reason: label);
          expect(find.text(t.levelName(11, '🏅 Pro Player')), findsOneWidget);
          expect(
            find.text(t.nextLevelValue('5,200', '17.96%')),
            findsOneWidget,
          );
          await tester.tap(find.text(t.close));
          await tester.pump(const Duration(milliseconds: 500));
          await _unmount(tester, state);

          // The winner's ribbon, through the celebration.
          final won = await _showdown(
            tester,
            taxed: true,
            lang: lang,
            screen: const Size(640, 360),
            scale: 1.25,
            dark: dark,
          );
          for (var at = 0; at < 2600; at += 200) {
            await tester.pump(const Duration(milliseconds: 200));
            expect(tester.takeException(), isNull, reason: '$label t=$at');
          }
          final line = find.descendant(
            of: _pod('u0'),
            matching: find.text(won.t.winnerTaxLine(formatChips(_tax))),
          );
          expect(line, findsOneWidget);
          // On the pod, whole.
          final podRect = tester.getRect(_pod('u0'));
          final lineRect = tester.getRect(line);
          expect(podRect.inflate(1).contains(lineRect.topLeft), isTrue);
          expect(podRect.inflate(1).contains(lineRect.bottomRight), isTrue);
          expect(_cut(_pod('u0')), isEmpty);
          expect(_number(_stack(tester)), _settled);
          await _unmount(tester, won);
        });
      }
    }
  });
}
