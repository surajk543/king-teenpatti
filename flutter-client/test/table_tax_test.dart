// The winning tax (owner, 26–27 Sep 2026): at a table that taxes its winners
// the winner of each hand pays a share of their winnings — the rate their
// LEVEL sets, 20% at Level 1 falling to 6% at Level 50, or lower where a badge
// they hold brings it down (the Royal badges to 0%; the fixtures' Gold is one
// an owner gives by hand, at 5%), which XP never reaches. The server decides
// and takes all of it; the app names it.
//
// Held here: the wire read tolerantly (absent keys are no tax, no level); a
// rate in basis points read as a player reads it; the pill on the two taxing
// lobby cards only, with the VIEWER's rate, moving no other line of the card;
// the ⓘ popup's rows and the rules' one sentence; the pill under the felt's
// tag at two to five places, clear of every seat and corner, and its popup
// (level, XP, today, rate, next level — or the top, or a badge's rate); the
// winner's ribbon saying the tax and the stack landing on the pot less the
// tax, never above it; the player's level replaced live, with a level-up
// toast; the Stats drawer's level and today's XP; and every one of those at
// 640x360 with text x1.25 in all five languages, in both themes, with nothing
// cut and nothing overflowing.
import 'dart:async';

import 'dart:convert';
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
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/state/missile_strike.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/game_card.dart';
import 'package:teenpatti/widgets/game_loader.dart';
import 'package:teenpatti/widgets/level_art.dart';
import 'package:teenpatti/widgets/level_screen.dart';
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
  'taxBps': 1743,
  'next': {
    'level': 11,
    'title': 'Pro Player',
    'icon': '🏅',
    'minXp': 5200,
    'taxBps': 1714,
  },
  'today': {'xp': 23, 'cap': 50, 'resetsAt': _now + 5 * 3600 * 1000},
  // The daily XP's window (owner, 27 Sep 2026): the first fifteen minutes and
  // a pair already earned, five hours to the reset.
  'daily': {
    'claimed': {'PLAY_15_MIN': 1, 'WIN_PAIR': 1},
    'resetsAt': _now + 5 * 3600 * 1000,
  },
};

/// Level 10's art as the server sends it (the owner's Lottie, 29 Sep 2026).
const String _level10Art = 'https://drive.test/levels/10.json';

/// [_level10] with its art.
Map<String, Object?> _level10WithArt() => {
  ..._level10(),
  'assetUrl': _level10Art,
  'assetFormat': 'LOTTIE',
};

/// A player at Level 1, twelve XP in.
Map<String, Object?> _level1() => {
  'level': 1,
  'title': 'Newbie',
  'icon': '🌱',
  'xp': 12,
  'taxBps': 2000,
  'next': {
    'level': 2,
    'title': 'Rookie',
    'icon': '🔰',
    'minXp': 100,
    'taxBps': 1971,
  },
  'today': {'xp': 12, 'cap': 50, 'resetsAt': _now + 3600 * 1000},
};

/// Regular, every player's by default, for life at 20% (owner, 27 Sep 2026:
/// "By default every user will hold this Regular badge 20 percent tax …
/// validaity life time, do not show this badge in store, its price zero").
Map<String, Object?> _regular() => {
  'code': 'REGULAR',
  'title': 'Regular',
  'icon': '',
  'taxBps': 2000,
  'expiresAt': 0,
  'isDefault': true,
  'assetUrl': 'https://drive.test/badges/REGULAR.json',
  'assetFormat': 'LOTTIE',
};

/// A Royal badge bought through support: Royal King, 0%, its Lottie, twelve
/// days left.
Map<String, Object?> _royalKing() => {
  'code': 'ROYAL_KING',
  'title': 'Royal King',
  'icon': '',
  'taxBps': 0,
  'expiresAt': _now + 12 * 24 * 3600 * 1000 + 60 * 1000,
  'assetUrl': 'https://drive.test/badges/ROYAL_KING.json',
  'assetFormat': 'LOTTIE',
};

/// A badge an owner added and gave by hand twenty days ago less a moment —
/// shown by its emoji, like any badge without art: 5%, ten days left.
Map<String, Object?> _goldBadge() => {
  'code': 'GOLD',
  'title': 'Gold',
  'icon': '🏅',
  'taxBps': 500,
  'expiresAt': _now + 10 * 24 * 3600 * 1000 + 60 * 1000,
};

/// The owner's fifty levels as the server seeds them (V1.0.1: the bracket of
/// 27 Sep 2026, 20% at Level 1 to 6% at Level 50) — the ladder `GET
/// /api/levels` sends.
const List<(int, int, String, String, int)> ownersLevels = [
  (1, 0, 'Newbie', '\u{1f331}', 2000),
  (2, 100, 'Rookie', '\u{1f530}', 1971),
  (3, 250, 'Beginner', '\u{2b50}', 1943),
  (4, 500, 'Player', '\u{1f3ae}', 1914),
  (5, 800, 'Regular', '\u{1f7e2}', 1886),
  (6, 1200, 'Challenger', '\u{2694}\u{fe0f}', 1857),
  (7, 1700, 'Skilled', '\u{1f3af}', 1829),
  (8, 2300, 'Contender', '\u{1f6e1}\u{fe0f}', 1800),
  (9, 3000, 'Fighter', '\u{2694}\u{fe0f}', 1771),
  (10, 4000, 'Rising Star', '\u{1f31f}', 1743),
  (11, 5200, 'Pro Player', '\u{1f3c5}', 1714),
  (12, 6700, 'Veteran', '\u{1f396}\u{fe0f}', 1686),
  (13, 8500, 'Expert', '\u{1f9e0}', 1657),
  (14, 10500, 'Specialist', '\u{1f4a0}', 1629),
  (15, 13000, 'Ace', '\u{1f0cf}', 1600),
  (16, 16000, 'Elite', '\u{1f48e}', 1571),
  (17, 20000, 'Master', '\u{1f451}', 1543),
  (18, 25000, 'Grand Master', '\u{1f451}\u{2694}\u{fe0f}', 1514),
  (19, 31000, 'Champion', '\u{1f3c6}', 1486),
  (20, 38000, 'High Roller', '\u{1f4b0}', 1457),
  (21, 46000, 'Royal', '\u{1f451}', 1429),
  (22, 55000, 'Royal Ace', '\u{1f0cf}\u{1f451}', 1400),
  (23, 65000, 'Royal Master', '\u{1f451}\u{1f48e}', 1371),
  (24, 76000, 'Supreme', '\u{1f531}', 1343),
  (25, 88000, 'Supreme Ace', '\u{1f531}\u{1f0cf}', 1314),
  (26, 102000, 'Legend', '\u{1f320}', 1286),
  (27, 118000, 'Legendary', '\u{2728}', 1257),
  (28, 136000, 'Grand Legend', '\u{1f31f}\u{1f451}', 1229),
  (29, 156000, 'Immortal', '\u{267e}\u{fe0f}', 1200),
  (30, 178000, 'Titan', '\u{26a1}', 1171),
  (31, 202000, 'Elite Titan', '\u{26a1}\u{1f48e}', 1143),
  (32, 228000, 'Royal Titan', '\u{26a1}\u{1f451}', 1114),
  (33, 256000, 'Emperor', '\u{1f451}', 1086),
  (34, 286000, 'Royal Emperor', '\u{1f451}\u{1f48e}', 1057),
  (35, 318000, 'Supreme Emperor', '\u{1f531}\u{1f451}', 1029),
  (36, 352000, 'King', '\u{1f451}', 1000),
  (37, 390000, 'Grand King', '\u{1f451}\u{1f3c6}', 971),
  (38, 432000, 'Royal King', '\u{1f451}\u{1f48e}', 943),
  (39, 478000, 'Supreme King', '\u{1f531}\u{1f451}', 914),
  (40, 528000, 'Master King', '\u{1f451}\u{2694}\u{fe0f}', 886),
  (41, 585000, 'Overlord', '\u{1f525}', 857),
  (42, 650000, 'Grand Overlord', '\u{1f525}\u{1f451}', 829),
  (43, 725000, 'Royal Overlord', '\u{1f525}\u{1f48e}', 800),
  (44, 810000, 'Supreme Overlord', '\u{1f525}\u{1f531}', 771),
  (45, 900000, 'Mythic', '\u{1f30c}', 743),
  (46, 1000000, 'Mythic King', '\u{1f30c}\u{1f451}', 714),
  (47, 1150000, 'Immortal King', '\u{267e}\u{fe0f}\u{1f451}', 686),
  (48, 1350000, 'Legendary King', '\u{1f31f}\u{1f451}', 657),
  (49, 1600000, 'Supreme Legend', '\u{1f531}\u{1f31f}', 629),
  (50, 2000000, 'King of Kings', '\u{1f451}\u{1f451}', 600),
];

/// The owner's Royal badges (27 Sep 2026): code, name, days, rupees.
const List<(String, String, int, int)> ownersRoyal = [
  ('ROYAL_ACE', 'Royal Ace', 7, 499),
  ('ROYAL_KING', 'Royal King', 15, 999),
  ('ROYAL_MASTER', 'Royal Master', 30, 1799),
  ('ROYAL_EMPEROR', 'Royal Emperor', 45, 2499),
  ('ROYAL_LEGEND', 'Royal Legend', 60, 3299),
  ('ROYAL_KING_OF_KINGS', 'Royal King of Kings', 90, 4499),
];

/// The owner's daily XP (27 Sep 2026): code, name, mark, kind, the play
/// minutes or the hand, and the XP — 108 in all.
const List<(String, String, String, String, int?, String?, int)>
ownersSources = [
  ('PLAY_15_MIN', 'Play 15 active minutes', '🎮', 'PLAY_TIME', 15, null, 3),
  ('PLAY_60_MIN', 'Play 60 active minutes', '🎮', 'PLAY_TIME', 60, null, 20),
  ('PLAY_120_MIN', 'Play 120 active minutes', '🎮', 'PLAY_TIME', 120, null, 50),
  ('WIN_PAIR', 'Win by Pair', '👥', 'WIN_HAND', null, 'PAIR', 1),
  ('WIN_COLOR', 'Win by Color', '🎨', 'WIN_HAND', null, 'COLOR', 2),
  ('WIN_SEQUENCE', 'Win by Sequence', '🃏', 'WIN_HAND', null, 'SEQUENCE', 4),
  (
    'WIN_PURE_SEQUENCE',
    'Win by Pure Sequence',
    '💎',
    'WIN_HAND',
    null,
    'PURE_SEQUENCE',
    8,
  ),
  ('WIN_TRAIL', 'Win by Trail', '🔥', 'WIN_HAND', null, 'TRAIL', 20),
];

/// The whole ladder as `GET /api/levels` sends it.
Map<String, Object?> _ladderJson() => {
  'levels': [
    for (final (level, minXp, title, icon, taxBps) in ownersLevels)
      {
        'level': level,
        'title': title,
        'icon': icon,
        'minXp': minXp,
        'taxBps': taxBps,
      },
  ],
  'badges': [
    {
      'code': 'REGULAR',
      'title': 'Regular',
      'icon': '',
      'taxBps': 2000,
      'validityDays': 0,
      'isDefault': true,
      'priceInr': 0,
      'assetUrl': 'https://drive.test/badges/REGULAR.json',
      'assetFormat': 'LOTTIE',
    },
    // One an owner added and gives by hand: no price, so never in the store.
    {
      'code': 'GOLD',
      'title': 'Gold',
      'icon': '🏅',
      'taxBps': 500,
      'validityDays': 1825,
      'isDefault': false,
    },
    // The Royal badges the store lists (owner, 27 Sep 2026), each with its
    // Lottie, asked for through support.
    for (final (code, title, days, rupees) in ownersRoyal)
      {
        'code': code,
        'title': title,
        'icon': '',
        'taxBps': 0,
        'validityDays': days,
        'isDefault': false,
        'priceInr': rupees,
        'assetUrl': 'https://drive.test/badges/$code.json',
        'assetFormat': 'LOTTIE',
      },
  ],
  // The daily XP (owner, 27 Sep 2026), exactly as the server seeds it.
  'xpSources': [
    for (final (code, name, icon, kind, minutes, hand, xp) in ownersSources)
      {
        'code': code,
        'name': name,
        'icon': icon,
        'kind': kind,
        'playMinutes': ?minutes,
        'hand': ?hand,
        'xp': xp,
        'times': 1,
      },
  ],
  // No daily cap (owner, 27 Sep 2026: "Don't set any daily limit to xp").
  'dailyCap': null,
  'windowMs': 86400000,
};

LevelLadder _ladder() => LevelLadder.maybe(_ladderJson())!;

/// The top of the ladder: nothing further for XP to reach.
Map<String, Object?> _top() => {
  'level': 50,
  'title': 'King of Kings',
  'icon': '👑👑',
  'xp': 2150000,
  'taxBps': 600,
  'today': {'xp': 50, 'cap': 50, 'resetsAt': _now + 3600 * 1000},
};

/// A Teen Patti menu in the server's shape, with two taxing tables — the 20
/// Lakh Blind and Variation ones — beside tables that do not tax.
List<Map<String, Object>> _menu({bool tax = true}) => [
  {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
  {'category': 'blind', 'bootAmount': 200, 'maxChips': 2000000},
  {'category': 'blind', 'bootAmount': 5000, 'maxChips': 200000000},
  {'category': 'blind', 'bootAmount': 50000, 'maxChips': 2000000000},
  {
    'category': 'blind',
    'bootAmount': 2000000,
    'minChips': 500000000,
    'winnerTax': tax,
  },
  {'category': 'variation', 'bootAmount': 50000, 'maxChips': 2000000000},
  {
    'category': 'variation',
    'bootAmount': 2000000,
    'minChips': 500000000,
    'winnerTax': tax,
  },
];

User _user({
  Map<String, Object?>? level,
  List<Object?>? badges,
  int? taxBps,
  int chips = 600000000,
}) => User.fromJson({
  'id': 'u0',
  'provider': 'guest',
  'displayName': 'Priya',
  'chips': chips,
  'diamond': 9,
  'hammer': 20,
  'missile': 1,
  'playerLevel': ?level,
  'badges': ?badges,
  'taxBps': ?taxBps,
});

GameState _lobbyState({
  AppLang lang = AppLang.english,
  Map<String, Object?>? level,
  List<Map<String, Object?>>? badges,
  int? taxBps,
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
    ..user = _user(
      level: level ?? _level10(),
      badges: badges ?? [_regular()],
      taxBps: taxBps,
    );
}

/// A hand at a taxing table of [places] places — Blind 20 Lakh unless
/// [category] says otherwise — the viewer blind, nobody on turn.
RoomState _taxRoom({
  int places = 5,
  String category = 'blind',
  bool winnerTax = true,
  int? taxBps = 1743,
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
  'bootAmount': 2000000,
  'turnTimeoutMs': 25000,
  'pot': 10000000,
  'maxPot': 0,
  'stake': 2000000,
  'turn': {'seatIndex': -1, 'userId': null, 'deadline': 0},
  if (winnerTax) 'winnerTax': true,
  if (winnerTax) 'winnerTaxMinWinnings': 5000000,
  'you': {
    'seatIndex': 0,
    'chips': 900000000,
    'status': 'active',
    'isBlind': true,
    'blindMovesLeft': 3,
    'contributed': 2000000,
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
        'lastBet': 2000000,
        'lastAction': 'chaal',
        'contributed': 2000000,
        'connected': true,
        'cardCount': 3,
      },
  ],
});

GameState _tableState({
  RoomState? room,
  Map<String, Object?>? level,
  List<Map<String, Object?>>? badges,
  int? taxBps,
  AppLang lang = AppLang.english,
  int places = 5,
  bool ladder = true,
}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  state
    ..lang = lang
    ..user = _user(
      level: level ?? _level10(),
      badges: badges ?? [_regular()],
      taxBps: taxBps,
      chips: 900000000,
    )
    ..screen = Screen.table
    ..config = GameConfig.fallback.copyWith(maxPlayers: places)
    ..levelLadder = ladder ? _ladder() : null
    ..handleState(room ?? _taxRoom(places: places));
  return state;
}

/// A Gold badge holder at Level 1: the level's 20%, the badge's 5%.
GameState _goldTable({AppLang lang = AppLang.english}) => _tableState(
  room: _taxRoom(taxBps: 500),
  level: _level1(),
  badges: [_regular(), _goldBadge()],
  taxBps: 500,
  lang: lang,
);

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

/// The 20 Lakh card's column on the rail: the one whose words name the stake.
Finder _twentyLakhColumn(WidgetTester tester, Strings t) {
  final boot = formatChips(2000000);
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
  throw StateError('no 20 Lakh card on the rail');
}

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
// the server takes 2,335 as winning tax at 17.43%.
const _before = 50000;
const _tax = 2335;
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
    state.handleHandTax((winnerId: 'u0', tax: _tax, taxBps: 1743));
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

/// A Lottie as small as one can be — a disc, one layer — standing in for
/// every badge's animation, so no test reaches the network for one.
final Uint8List _badgeLottie = Uint8List.fromList(
  utf8.encode(
    '{"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"b","ddd":0,'
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

/// The two-pane popup the pill opened until 27 Sep 2026 ([showWinningTaxInfo]),
/// kept and opened here directly: the pill opens the level screen now.
void _openTwoPanes(WidgetTester tester) =>
    unawaited(showWinningTaxInfo(tester.element(find.byType(WinningTaxTag))));

void main() {
  setUpAll(() async {
    await _loadFonts();
    // Where async is real: a future first awaited inside one test's fake
    // clock never completes in the next (CLAUDE.md §12.3).
    await FireworksArt.load();
    await MissileArt.load();
    for (final code in [
      'REGULAR',
      'ROYAL_KING',
      for (final (code, _, _, _) in ownersRoyal) code,
    ]) {
      PictureCache.prime('https://drive.test/badges/$code.json', _badgeLottie);
    }
    // Level 10's art (29 Sep 2026), for the pill's right emblem.
    PictureCache.prime(_level10Art, _badgeLottie);
  });
  tearDownAll(PictureCache.clearMemory);

  group('the wire', () {
    test('a menu entry says whether its table taxes the winner, and anything '
        'else reads as no tax', () {
      LobbyTable table(Map<String, Object?> extra) => LobbyTable.fromJson({
        'category': 'blind',
        'bootAmount': 2000000,
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
        ['blind:2000000', 'variation:2000000'],
      );
    });

    test('a room and a seat carry the tax, and absent keys are none', () {
      final room = _taxRoom();
      expect(room.winnerTax, isTrue);
      expect(room.taxesWinner, isTrue);
      expect(room.you!.taxBps, 1743);

      final plain = _taxRoom(winnerTax: false, taxBps: null);
      expect(plain.winnerTax, isFalse);
      expect(plain.you!.taxBps, isNull);

      // A rate no table could charge is no rate at all.
      for (final bad in [-1, 10001, '1743', null]) {
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

    test('the player level is read with its mark, its next level and '
        'today', () {
      final level = PlayerLevel.maybe(_level10())!;
      expect(level.level, 10);
      expect(level.title, 'Rising Star');
      expect(level.icon, '🌟');
      expect(level.xp, 4180);
      expect(level.taxBps, 1743);
      expect(level.next!.level, 11);
      expect(level.next!.icon, '🏅');
      expect(level.next!.minXp, 5200);
      expect(level.next!.taxBps, 1714);
      expect(level.today!.xp, 23);
      expect(level.today!.cap, 50);
      expect(level.today!.full, isFalse);

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

    test('the badges and the rate paid are read tolerantly, and the badge '
        'that sets the rate is the one below the level\'s', () {
      final user = _user(
        level: _level1(),
        badges: [
          _regular(),
          _goldBadge(),
          {'title': 'no code'},
          'GOLD',
          {'code': 'PLATINUM', 'title': 'Platinum', 'taxBps': 99999},
        ],
        taxBps: 500,
      );
      expect(user.badges.map((b) => b.code), ['REGULAR', 'GOLD', 'PLATINUM']);
      // Regular: 20%, for life, everybody's.
      expect(user.badges[0].taxBps, 2000);
      expect(user.badges[0].isDefault, isTrue);
      expect(user.badges[0].leftAt(DateTime.now()), isNull);
      expect(user.badges[1].isDefault, isFalse);
      expect(user.badges[1].taxBps, 500);
      expect(user.badges[1].leftAt(DateTime.now())!.inDays, 10);
      // A rate no table could charge is no rate at all.
      expect(user.badges[2].taxBps, isNull);
      expect(user.paysTaxBps, 500);
      expect(user.rateBadge!.code, 'GOLD');
      // The pill names the badge that brings the rate lowest: Gold here,
      // Regular where it is the only one.
      expect(user.shownBadge!.code, 'GOLD');
      expect(_user(badges: [_regular()]).shownBadge!.code, 'REGULAR');
      expect(_user().shownBadge, isNull);
      // The copies carry them.
      expect(user.withHammer(3).badges.length, 3);
      expect(user.withMissile(2).taxBps, 500);

      // Without the server's rate, the level's is what is paid; a badge no
      // lower than the level's sets nothing.
      final plain = _user(level: _level10(), badges: [_regular()]);
      expect(plain.paysTaxBps, 1743);
      expect(plain.rateBadge, isNull);
      final high = _user(
        level: {..._level10(), 'taxBps': 400},
        badges: [_goldBadge()],
        taxBps: 400,
      );
      expect(high.rateBadge, isNull);
      expect(_user().badges, isEmpty);
      expect(_user().paysTaxBps, isNull);

      // player:level: the standing whole, or nothing without a level.
      final standing = Standing.maybe({
        'playerLevel': _level10(),
        'badges': [_regular(), _goldBadge()],
        'taxBps': 500,
      })!;
      expect(standing.playerLevel.level, 10);
      expect(standing.badges.length, 2);
      expect(standing.taxBps, 500);
      expect(Standing.maybe({'badges': []}), isNull);
      expect(Standing.maybe(_level10()), isNull);
      final moved = plain.withStanding(standing);
      expect(moved.playerLevel!.level, 10);
      expect(moved.badges.map((b) => b.code), ['REGULAR', 'GOLD']);
      expect(moved.paysTaxBps, 500);
    });

    test('the ladder is read whole: fifty levels in order, the badges, the '
        'sources and the cap — and nothing without a level', () {
      final ladder = _ladder();
      expect(ladder.levels.length, 50);
      expect(ladder.levels.first.title, 'Newbie');
      expect(ladder.levels.first.taxBps, 2000);
      expect(ladder.levels.last.title, 'King of Kings');
      expect(ladder.levels.last.minXp, 2000000);
      expect(ladder.levels.last.taxBps, 600);
      expect(ladder.levelOf(10)!.minXp, 4000);
      expect(ladder.badges.map((b) => b.code), [
        'REGULAR',
        'GOLD',
        'ROYAL_ACE',
        'ROYAL_KING',
        'ROYAL_MASTER',
        'ROYAL_EMPEROR',
        'ROYAL_LEGEND',
        'ROYAL_KING_OF_KINGS',
      ]);
      expect(ladder.badges.first.isDefault, isTrue);
      expect(ladder.badges.first.listed, isFalse, reason: 'never in the store');
      expect(ladder.badges.first.assetFormat, 'LOTTIE');
      expect(ladder.badges.first.taxBps, 2000);
      expect(ladder.badges.first.priceInr, 0);
      expect(ladder.badges.first.buyable, isFalse);
      expect(ladder.badges[2].taxBps, 0);
      expect(ladder.badges[1].validityDays, 1825);
      expect(ladder.badges[1].priceInr, isNull);
      expect(ladder.badges[1].buyable, isFalse);
      expect(ladder.badges[1].listed, isFalse, reason: 'no price, not listed');
      // The Royal badges the store lists (owner, 27 Sep 2026): rupees and a
      // Lottie each, asked for through support.
      final kings = ladder.badges.last;
      expect(kings.title, 'Royal King of Kings');
      expect(kings.priceInr, 4499);
      expect(kings.validityDays, 90);
      expect(kings.listed, isTrue);
      expect(kings.buyable, isFalse);
      expect(kings.assetUrl, endsWith('ROYAL_KING_OF_KINGS.json'));
      // The daily sources, each with its kind and what it needs.
      expect(ladder.sources.length, 8);
      expect(ladder.sources.first.kind, LadderSource.kindPlayTime);
      expect(ladder.sources.first.playMinutes, 15);
      expect(ladder.sources.last.kind, LadderSource.kindWinHand);
      expect(ladder.sources.last.hand, 'TRAIL');
      expect(ladder.sources.last.icon, '🔥');
      expect(ladder.sources.last.times, 1);
      expect(ladder.dailyCap, 0);
      expect(ladder.windowMs, 86400000);
      // Out of order in, in order out; a rung with no threshold is dropped.
      final shuffled = LevelLadder.maybe({
        'levels': [
          {'level': 2, 'title': 'B', 'minXp': 100, 'taxBps': 1971},
          {'level': 1, 'title': 'A', 'minXp': 0, 'taxBps': 2000},
          {'level': 3, 'title': 'C', 'taxBps': 1943},
        ],
      })!;
      expect(shuffled.levels.map((l) => l.level), [1, 2]);
      expect(shuffled.badges, isEmpty);
      expect(LevelLadder.maybe({'levels': []}), isNull);
      expect(LevelLadder.maybe('ladder'), isNull);
    });

    test('a hand end says what its winner paid, and nothing where nothing was '
        'taken', () {
      final taken = handTaxOf({
        'winnerId': 'u3',
        'pot': 13400,
        'tax': 2335,
        'taxBps': 1743,
      });
      expect(taken.winnerId, 'u3');
      expect(taken.tax, 2335);
      expect(taken.taxBps, 1743);

      final none = handTaxOf({'winnerId': 'u3', 'pot': 13400});
      expect(none.tax, 0);
      expect(none.taxBps, 0);
      expect(handTaxOf({'tax': -5, 'taxBps': 1743}).tax, 0);
      expect(handTaxOf({'tax': '2335'}).tax, 0);
      expect(handTaxOf({'tax': 10, 'taxBps': 99999}).taxBps, 0);
    });

    test('a rate reads with two decimals, and a whole .00 is dropped', () {
      expect(formatTaxRate(2000), '20%');
      expect(formatTaxRate(1971), '19.71%');
      expect(formatTaxRate(1810), '18.10%');
      expect(formatTaxRate(1743), '17.43%');
      expect(formatTaxRate(600), '6%');
      expect(formatTaxRate(200), '2%');
      expect(formatTaxRate(5), '0.05%');
      expect(formatTaxRate(0), '0%');
    });
  });

  group('the words', () {
    const keys = [
      'taxPill',
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
      'ruleWinningTaxBadge',
      'winnerTaxLine',
      'levelUp',
      'levelUpOnly',
      'xpToday',
      'xpResetsIn',
      'todayLabel',
      'allLevelsTitle',
      'badgesTitle',
      'yourBadgesTitle',
      'taxColumn',
      'levelYou',
      'levelTaxLabel',
      'winningTaxLowest',
      'rateSetByLevel',
      'rateSetByBadge',
      'xpDailyTitle',
      'xpPlayMinutes',
      'xpWinBy',
      'xpListResets',
      'xpEarned',
      'xpDailyCap',
      'xpNeverExpires',
      'badgeEveryone',
      'badgeLasts',
      'badgeUntil',
      'badgeLifetime',
      'badgeFree',
      'badgeTaxLine',
      'badgeBought',
      'winningTaxFrom',
      'taxOnWinningsFrom',
      'storeTabBadges',
      'storeBadgesTitle',
      'storeBadgesBlurb',
      'badgeContactSupport',
      'badgeContactTitle',
      'badgeContactBody',
      'badgeMailSubject',
      'copyAddress',
      'addressCopied',
      'levelsUnavailable',
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

    test('name a level and a badge with their marks, and say the rule', () {
      final t = Strings(AppLang.english);
      final level = PlayerLevel.maybe(_level10())!;
      expect(levelNameOf(t, level), 'Level 10 · Rising Star');
      expect(levelLineOf(t, level), 'Level 10 · Rising Star · 4,180 XP');
      final gold = _user(badges: [_goldBadge()]).badges.single;
      expect(badgeTitleOf(gold), '🏅 Gold');
      // A month or more away, the day it ends; nearer, what is left.
      final end = DateTime(2031, 9, 26);
      expect(
        badgeLeftOf(t, const Duration(days: 1824), end),
        'Until 26/09/2031',
      );
      expect(badgeLeftOf(t, const Duration(days: 30), end), 'Until 26/09/2031');
      expect(
        badgeLeftOf(t, const Duration(days: 10, hours: 3), end),
        '10 days left',
      );
      expect(badgeLeftOf(t, const Duration(hours: 5), end), '5 hours left');
      expect(badgeLeftOf(t, const Duration(seconds: 20), end), '1 minute left');
      expect(badgeDateOf(DateTime(2027, 1, 5)), '05/01/2027');
      final sources = _ladder().sources;
      expect(sources.map((e) => xpSourceName(t, e)), [
        'Play 15 active minutes',
        'Play 60 active minutes',
        'Play 120 active minutes',
        'Win by Pair',
        'Win by Color',
        'Win by Sequence',
        'Win by Pure Sequence',
        'Win by Trail',
      ]);
      // The hand keeps its English name in every language, as the table's.
      expect(
        xpSourceName(Strings(AppLang.hindi), sources.last),
        'Trail से जीतें',
      );
      expect(_ladder().dailyMax, 108, reason: 'the owner\'s list, all of it');
      expect(t.winningTaxFrom('50 Lakh'), 'No tax on winnings under 50 Lakh.');
      expect(t.badgeLifetime, 'Lifetime');
      expect(
        xpSourceName(t, const LadderSource(code: 'NEW_ONE', xp: 3, name: 'x')),
        'x',
      );
      expect(t.xpDailyCap(50, 24), 'Up to 50 XP every 24 hours.');
      expect(t.badgeLasts(1825), 'Lasts 5 years');
      expect(t.badgeLasts(30), 'Lasts 30 days');
      expect(t.rateSetByBadge('🏅 Gold'), 'Set by your 🏅 Gold badge');
      expect(
        levelNameOf(t, PlayerLevel.maybe({..._level10(), 'icon': ''})!),
        'Level 10 · Rising Star',
      );
      expect(taxPillLabel(t, bps: 1743), '17.43% TAX');
      expect(taxPillLabel(t, bps: 0), '0% TAX');
      expect(taxPillLabel(t), 'TAX');
      // On what the winner won, the pot less their own chips (owner, 27 Sep
      // 2026), and — where the table has a floor — from it.
      expect(
        t.winningTaxRule('20%'),
        'The winner of each hand pays winning tax on what they win — the pot '
        'less their own chips — 20% at Level 1, less at every level up. A '
        'badge can lower it further.',
      );
      expect(
        t.winningTaxRule('20%', from: '50 Lakh'),
        endsWith(
          'A badge can lower it further. No tax on winnings under 50 '
          'Lakh.',
        ),
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
    // No card carries the player's standing any more (owner, 29 Sep 2026:
    // "Remove the badge and level symbol and tax text from card, seen card,
    // variation, all card"): not the "17.43% TAX" pill on the boot's line
    // (gone 27 Sep 2026), and not the corner that replaced it — the level's
    // mark, the badge and the rate. The badge is on the top bar's picture
    // (avatar_badge_test); the rate stays in the ⓘ popup and the level screen.
    Finder onCards(Finder f) => find.descendant(
      of: find.byType(GameCard, skipOffstage: false),
      matching: f,
    );

    testWidgets('carries no badge, level mark or rate, on a taxing table '
        'or not', (tester) async {
      final state = _lobbyState()..openLobbyCategory(TableCategory.blind);
      await _pumpLobby(tester, state);
      for (final category in [
        TableCategory.blind,
        TableCategory.variation,
        TableCategory.seen,
      ]) {
        state.openLobbyCategory(category);
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(GameCard), findsWidgets, reason: category);
        expect(
          find.byKey(const ValueKey('table-card-badge'), skipOffstage: false),
          findsNothing,
          reason: category,
        );
        expect(
          find.byType(WinningTaxPill, skipOffstage: false),
          findsNothing,
          reason: category,
        );
        expect(
          onCards(find.byType(BadgeArt, skipOffstage: false)),
          findsNothing,
          reason: category,
        );
        expect(
          onCards(find.textContaining('%', skipOffstage: false)),
          findsNothing,
          reason: category,
        );
        expect(
          onCards(find.text('🌟', skipOffstage: false)),
          findsNothing,
          reason: '$category: no level mark',
        );
      }
      await _unmount(tester, state);
    });

    for (final scale in [1.0, 1.25]) {
      testWidgets('nothing on the card is cut (x$scale)', (tester) async {
        for (final lang in AppLang.values) {
          for (final category in [
            TableCategory.blind,
            TableCategory.variation,
          ]) {
            final state = _lobbyState(lang: lang)..openLobbyCategory(category);
            await _pumpLobby(tester, state, scale: scale);
            final why = '${lang.code} $category x$scale';
            expect(tester.takeException(), isNull, reason: why);
            final column = _twentyLakhColumn(tester, state.t);
            expect(_cut(column), isEmpty, reason: why);
            await _unmount(tester, state);
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
          2000000,
          Icons.info_outline_rounded,
        );
        expect(find.text(t.winningTaxLabel), findsOneWidget);
        // In the popup, and on no card behind it.
        expect(
          find.descendant(
            of: find.byType(Dialog),
            matching: find.text('17.43%'),
          ),
          findsOneWidget,
        );
        expect(find.text(t.yourLevelLabel), findsOneWidget);
        expect(find.text('Level 10 · Rising Star'), findsOneWidget);
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
      final rule = t.winningTaxRule('20%');
      await _tapCornerKey(
        tester,
        TableCategory.variation,
        2000000,
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
    testWidgets('the pill: the badge\'s art, its name over the tax, and '
        'nothing of the level — not its title, not its art (owner, 29 Sep '
        '2026: "only show badge icon and badge name and tax")', (tester) async {
      final state = _tableState(level: _level10WithArt());
      await _pumpTable(tester, state);
      final tag = tester.widget<WinningTaxTag>(find.byType(WinningTaxTag));
      expect(tag.title, 'Regular');
      expect(tag.badge, isNull);
      expect(tag.tax, '17.43% TAX');
      expect(
        find.descendant(
          of: find.byType(WinningTaxTag),
          matching: find.byType(LevelArt),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(WinningTaxTag),
          matching: find.text('Rising Star'),
        ),
        findsNothing,
      );
      final badge = tester.getRect(
        find.byKey(const ValueKey('winning-tax-badge-art')),
      );
      final title = tester.getRect(
        find.byKey(const ValueKey('winning-tax-title')),
      );
      final rate = tester.getRect(
        find.byKey(const ValueKey('winning-tax-rate-words')),
      );
      expect(badge.right, lessThanOrEqualTo(title.left));
      expect(title.center.dy, lessThan(rate.center.dy));
      await _unmount(tester, state);
    });

    testWidgets('hangs the pill under the tag of a taxing table only', (
      tester,
    ) async {
      final state = _tableState();
      await _pumpTable(tester, state);
      expect(find.byType(WinningTaxTag), findsOneWidget);
      // The badge they hold, by name, over the rate the seat pays — the
      // level's title that led it went on 29 Sep 2026 (owner: "In gametable
      // in tax pill only show badge icon and badge name and tax"):
      // everyone's Regular, its Lottie playing beside the name ("it should
      // show the lottie animation near that badge").
      final tag = tester.widget<WinningTaxTag>(find.byType(WinningTaxTag));
      expect(tag.title, 'Regular');
      expect(tag.tax, '17.43% TAX');
      expect(tag.badge, isNull);
      expect(tag.badgeArt?.code, 'REGULAR');
      expect(
        find.byKey(const ValueKey('winning-tax-badge-art')),
        findsOneWidget,
      );
      // It is the pill's emblem (owner, 27 Sep 2026: "increase the badge icon
      // size which is shown in game table"): at its left, from the plate's
      // top edge to its bottom — both lines and the padding round them, more
      // than twice a line — with the title and the rate beside it.
      final plateOf = find.descendant(
        of: find.byType(WinningTaxTag),
        matching: find.byType(Plate),
      );
      final artRect = tester.getRect(
        find.byKey(const ValueKey('winning-tax-badge-art')),
      );
      final plateRect = tester.getRect(plateOf);
      final titleRect = tester.getRect(
        find.byKey(const ValueKey('winning-tax-title')),
      );
      final rateRect = tester.getRect(
        find.byKey(const ValueKey('winning-tax-rate-words')),
      );
      expect(artRect.height, closeTo(plateRect.height, 0.5));
      expect(artRect.height, greaterThan(2 * rateRect.height));
      expect(artRect.left - plateRect.left, lessThan(Space.xs));
      expect(titleRect.left, greaterThan(artRect.right));
      expect(rateRect.left, greaterThan(artRect.right));
      final felt = tester.element(find.byType(WinningTaxTag));
      final scale =
          artRect.height /
          WinningTaxTag.emblemSize(
            MediaQuery.textScalerOf(felt),
            Theme.of(felt),
            lines: 2,
          );
      expect(scale, lessThanOrEqualTo(1.0001));
      String words(String key) => tester
          .widget<RichText>(
            find.descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(RichText),
            ),
          )
          .text
          .toPlainText();
      // The badge's name over the rate.
      expect(words('winning-tax-title'), 'Regular');
      expect(words('winning-tax-rate-words'), '17.43% TAX');
      expect(
        tester.getCenter(find.byKey(const ValueKey('winning-tax-title'))).dy,
        lessThan(
          tester
              .getCenter(find.byKey(const ValueKey('winning-tax-rate-words')))
              .dy,
        ),
      );
      // No percent mark before a title: the badge's own art leads.
      expect(
        find.descendant(
          of: find.byType(WinningTaxTag),
          matching: find.byIcon(winningTaxIcon),
        ),
        findsNothing,
      );
      await _unmount(tester, state);

      final plain = _tableState(room: _taxRoom(winnerTax: false, taxBps: null));
      await _pumpTable(tester, plain);
      expect(find.byType(WinningTaxTag), findsNothing);
      await _unmount(tester, plain);

      // A Gold badge holder: the badge — Gold, the one that brings their
      // rate lowest, not Regular — and the badge's rate, which is what they
      // pay.
      final gold = _goldTable();
      await _pumpTable(tester, gold);
      final goldTag = tester.widget<WinningTaxTag>(find.byType(WinningTaxTag));
      expect(goldTag.title, '🏅 Gold');
      expect(goldTag.badge, isNull);
      // Gold is shown by its emoji, which its name already carries.
      expect(goldTag.badgeArt, isNull);
      expect(goldTag.tax, '5% TAX');
      // The emblem made the pill no taller: a pill with none stands as tall,
      // where neither is scaled down.
      if (scale > 0.9999) {
        expect(tester.getRect(plateOf).height, closeTo(plateRect.height, 0.5));
      }
      await _unmount(tester, gold);

      // A Royal King holder: the badge that brings the rate lowest, its
      // Lottie the pill's emblem, and the 0% it brings.
      final royal = _tableState(
        room: _taxRoom(taxBps: 0),
        level: _level1(),
        badges: [_regular(), _royalKing()],
        taxBps: 0,
      );
      await _pumpTable(tester, royal);
      final royalTag = tester.widget<WinningTaxTag>(find.byType(WinningTaxTag));
      expect(royalTag.title, 'Royal King');
      expect(royalTag.badgeArt?.code, 'ROYAL_KING');
      expect(royalTag.tax, '0% TAX');
      expect(
        find.byKey(const ValueKey('winning-tax-badge-art')),
        findsOneWidget,
      );
      await _unmount(tester, royal);

      // No badge known: the percent mark and the rate alone.
      final unknown = _tableState()..user = _user(chips: 900000000);
      await _pumpTable(tester, unknown);
      final bare = tester.widget<WinningTaxTag>(find.byType(WinningTaxTag));
      expect(bare.title, isNull);
      expect(bare.tax, '17.43% TAX');
      expect(
        find.descendant(
          of: find.byType(WinningTaxTag),
          matching: find.byIcon(winningTaxIcon),
        ),
        findsOneWidget,
      );
      await _unmount(tester, unknown);
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

    // Owner, 27 Sep 2026: "when i click the text on my level in gametable, it
    // should pop the same UI which it shows in Lobby about player level, daily
    // xp and levels".
    testWidgets('a tap on the pill opens the lobby\'s level screen: its three '
        'tabs, the rate the seat pays, and Close', (tester) async {
      final state = _tableState();
      final t = state.t;
      await _pumpTable(tester, state);
      await tester.tap(find.byType(WinningTaxTag));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.byType(LevelScreen), findsOneWidget);
      expect(find.byType(WinningTaxInfo), findsNothing);
      for (final tab in LevelInfoTab.values) {
        expect(find.byKey(ValueKey('level-tab-${tab.name}')), findsOneWidget);
      }
      expect(find.text(t.levelTabMine), findsOneWidget);
      // My level: the hero's rate is the one the seat pays.
      expect(find.text('17.43%'), findsWidgets);
      // Daily XP and All levels, as in the lobby.
      await tester.tap(find.byKey(const ValueKey('level-tab-daily')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Win by Trail', skipOffstage: false), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('level-tab-ladder')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      // Its round close key puts the table back.
      await tester.tap(find.byType(LevelCloseKey));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(LevelScreen), findsNothing);
      expect(find.byType(WinningTaxTag), findsOneWidget);
      await _unmount(tester, state);
    });

    testWidgets(
      'the two-pane popup (kept; opened by nothing on the felt '
      'since the pill opens the level screen): the rate and what sets it, the '
      'level, XP, today, the next level, the badges, how XP is earned — and '
      "every level, the viewer's lit and in view, then every badge",
      (tester) async {
        final state = _tableState();
        final t = state.t;
        await _pumpTable(tester, state);
        unawaited(
          showWinningTaxInfo(tester.element(find.byType(WinningTaxTag))),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        expect(find.byType(WinningTaxInfo), findsOneWidget);
        final standing = find.byKey(const ValueKey('winning-tax-standing'));
        final ladderPane = find.byKey(const ValueKey('winning-tax-ladder'));
        Finder inStanding(String text) => find.descendant(
          of: standing,
          matching: find.text(text, skipOffstage: false),
        );
        for (final text in [
          t.winningTaxOnlyWinner,
          t.winningTaxFalls,
          t.winningTaxLowest,
          t.rateSetByLevel,
          'Level 10 · Rising Star',
          '${t.levelTaxLabel} 17.43%',
          '4,180',
          '23 / 50 XP',
          'Level 11 · Pro Player',
          '5,200 XP · 17.14%',
          t.winningTaxFrom('50 Lakh'),
          t.yourBadgesTitle,
          'Regular',
          t.badgeLifetime,
          t.xpDailyTitle,
          'Play 15 active minutes',
          'Play 60 active minutes',
          'Play 120 active minutes',
          'Win by Pair',
          'Win by Color',
          'Win by Sequence',
          'Win by Pure Sequence',
          'Win by Trail',
          '+50 XP',
          t.xpListResets(24),
          t.xpNeverExpires,
        ]) {
          expect(inStanding(text), findsOneWidget, reason: text);
        }
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('winning-tax-rate')),
            matching: find.text('17.43%'),
          ),
          findsOneWidget,
        );
        expect(inStanding(t.topLevelNote), findsNothing);
        // 4,180 of the 4,000 → 5,200 between Level 10 and 11.
        expect(
          find.byKey(const ValueKey('winning-tax-progress')),
          findsOneWidget,
        );

        // The ladder: fifty rungs, the viewer's alone lit and brought into
        // view, then the four badges.
        final rows = tester
            .widgetList(_private('_LadderRow'))
            .map((w) => w as dynamic)
            .toList();
        expect(rows.length, 50);
        expect(
          [for (final r in rows) (r.level as LadderLevel).level],
          [for (var l = 1; l <= 50; l++) l],
        );
        final mine = [
          for (final r in rows)
            if (r.you == true) r,
        ];
        expect(mine.length, 1);
        expect((mine.single.level as LadderLevel).level, 10);
        // "You" beside the rung's name; the line under it is the rung's XP.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('ladder-you'), skipOffstage: false),
            matching: find.text(t.levelYou, skipOffstage: false),
          ),
          findsOneWidget,
        );
        expect(find.text('4,000 XP', skipOffstage: false), findsOneWidget);
        final mineRect = tester.getRect(
          find.byWidget(mine.single as Widget, skipOffstage: false),
        );
        final paneRect = tester.getRect(ladderPane);
        expect(
          paneRect.contains(mineRect.topCenter) &&
              paneRect.contains(mineRect.bottomCenter),
          isTrue,
          reason: 'the viewer\'s row $mineRect is in view in $paneRect',
        );
        for (final code in [
          'REGULAR',
          'GOLD',
          'ROYAL_ACE',
          'ROYAL_KING_OF_KINGS',
        ]) {
          expect(
            find.byKey(ValueKey('ladder-badge-$code'), skipOffstage: false),
            findsOneWidget,
          );
        }
        expect(
          find.descendant(
            of: ladderPane,
            matching: find.text(t.badgeLasts(1825), skipOffstage: false),
          ),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const ValueKey('winning-tax-close')));
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.byType(WinningTaxInfo), findsNothing);
        await _unmount(tester, state);
      },
    );

    testWidgets('a badge holder is told the badge sets the rate, with their '
        'level, their XP and their badges beside it', (tester) async {
      final state = _goldTable();
      final t = state.t;
      await _pumpTable(tester, state);
      _openTwoPanes(tester);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 100));
      final rate = find.byKey(const ValueKey('winning-tax-rate'));
      expect(
        find.descendant(of: rate, matching: find.text('5%')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rate,
          matching: find.text(t.rateSetByBadge('🏅 Gold')),
        ),
        findsOneWidget,
      );
      expect(find.text('Level 1 · Newbie'), findsOneWidget);
      expect(find.text('${t.levelTaxLabel} 20%'), findsOneWidget);
      // A badge is beside the level, never instead of it: XP as for anyone.
      expect(find.text(t.xpLabel), findsOneWidget);
      expect(find.text(t.nextLevelLabel), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('my-badge-GOLD')),
          matching: find.text('10 days left'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('my-badge-REGULAR')),
          matching: find.text(t.badgeLifetime),
        ),
        findsOneWidget,
      );
      // The badge they hold is lit in the catalogue; Regular, everyone's,
      // is not.
      bool lit(String code) =>
          (tester.widget(
                        find.byKey(
                          ValueKey('ladder-badge-$code'),
                          skipOffstage: false,
                        ),
                      )
                      as dynamic)
                  .lit
              as bool;
      expect(lit('GOLD'), isTrue);
      expect(lit('REGULAR'), isFalse);
      expect(lit('ROYAL_ACE'), isFalse);
      await _unmount(tester, state);
    });

    testWidgets('at the top of the ladder the popup says it is the top', (
      tester,
    ) async {
      final state = _tableState(room: _taxRoom(taxBps: 600), level: _top());
      final t = state.t;
      await _pumpTable(tester, state);
      _openTwoPanes(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Level 50 · King of Kings'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('winning-tax-rate')),
          matching: find.text('6%'),
        ),
        findsOneWidget,
      );
      expect(find.text(t.topLevelNote), findsOneWidget);
      expect(find.text(t.nextLevelLabel), findsNothing);
      expect(find.byKey(const ValueKey('winning-tax-progress')), findsNothing);
      expect(
        find.text(t.xpListResets(24), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text(t.xpDailyCap(50, 24), skipOffstage: false),
        findsNothing,
        reason: 'no daily cap, as seeded',
      );
      await _unmount(tester, state);

      // Where an owner sets a daily cap, the popup says it.
      final capped = _tableState(room: _taxRoom(taxBps: 600), level: _top())
        ..levelLadder = LevelLadder.maybe({..._ladderJson(), 'dailyCap': 50});
      await _pumpTable(tester, capped);
      _openTwoPanes(tester);
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        find.text(t.xpDailyCap(50, 24), skipOffstage: false),
        findsOneWidget,
      );
      await _unmount(tester, capped);
    });

    testWidgets('the daily XP list ticks what the window has earned, says when '
        'it resets, and the store badges show their prices', (tester) async {
      final state = _tableState();
      final t = state.t;
      await _pumpTable(tester, state);
      _openTwoPanes(tester);
      await tester.pump(const Duration(milliseconds: 500));
      // Earned in this window (owner, 27 Sep 2026: "1 time … After 24 hours
      // this will be reset"): the first fifteen minutes and a pair; the rest
      // still to earn.
      Finder earned(String name) =>
          find.byKey(ValueKey('xp-earned-$name'), skipOffstage: false);
      expect(earned('Play 15 active minutes'), findsOneWidget);
      expect(earned('Win by Pair'), findsOneWidget);
      for (final name in [
        'Play 60 active minutes',
        'Play 120 active minutes',
        'Win by Color',
        'Win by Sequence',
        'Win by Pure Sequence',
        'Win by Trail',
      ]) {
        expect(earned(name), findsNothing, reason: name);
      }
      // The reset beside the list's heading.
      expect(
        find.textContaining('resets in', skipOffstage: false),
        findsWidgets,
      );
      // The catalogue: Regular everyone's, for life, free; the store's
      // badges at their rupee prices.
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('ladder-badge-REGULAR'),
            skipOffstage: false,
          ),
          matching: find.text(
            '${t.badgeEveryone} · ${t.badgeLifetime} · ${t.badgeFree}',
            skipOffstage: false,
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('ladder-badge-ROYAL_KING'),
            skipOffstage: false,
          ),
          matching: find.text(
            '${t.badgeLasts(15)} · ₹999',
            skipOffstage: false,
          ),
        ),
        findsOneWidget,
      );
      await _unmount(tester, state);
    });

    testWidgets('with no ladder to show it says so and offers Try again; the '
        "viewer's standing still shows", (tester) async {
      final state = _tableState(ladder: false);
      final t = state.t;
      await _pumpTable(tester, state);
      _openTwoPanes(tester);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(state.levelLadder, isNull);
      expect(find.text(t.levelsUnavailable), findsOneWidget);
      expect(find.byKey(const ValueKey('winning-tax-retry')), findsOneWidget);
      expect(find.text('Level 10 · Rising Star'), findsOneWidget);
      expect(find.byType(GameLoader), findsNothing);
      await _unmount(tester, state);
    });
  });

  group('the hand end', () {
    testWidgets("the winner's ribbon says the tax, and the stack lands on the "
        'pot less the tax — never above it', (tester) async {
      final state = await _showdown(tester, taxed: true);
      expect(state.winnerTax, _tax);
      expect(state.winnerTaxBps, 1743);
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
      expect(line, 'Winning tax −2,335');
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
        ..handleHandTax((winnerId: 'u0', tax: _tax, taxBps: 1743))
        ..handleShowdown(winnerEnded('u0'));
      expect(state.winnerId, isNull, reason: 'held behind the volley');
      await tester.pump(
        MissileTiming.reveal(1) + const Duration(milliseconds: 50),
      );
      expect(state.winnerId, 'u0');
      expect(state.winnerTax, _tax);
      expect(state.winnerTaxBps, 1743);

      // The next deal forgets it.
      state.handleState(winnerRoom(handNo: 10));
      expect(state.winnerTax, 0);
      expect(state.winnerTaxBps, 0);
      await tester.pump(const Duration(seconds: 10));
      state.dispose();
    });
  });

  group('the level', () {
    /// Level 10 as player:level brings it, with [badges] and the rate paid.
    Standing standingAt10({List<Object?>? badges, int taxBps = 1743}) =>
        Standing.maybe({
          'playerLevel': _level10(),
          'badges': badges ?? [_regular()],
          'taxBps': taxBps,
        })!;

    test('player:level replaces the standing, and a level up says the rate '
        'it brings — or the level alone where a badge keeps it lower', () {
      final state = _lobbyState(
        level: {..._level10(), 'level': 9, 'taxBps': 1771},
      );
      state.handlePlayerLevel(standingAt10());
      expect(state.user!.playerLevel!.level, 10);
      expect(state.user!.paysTaxBps, 1743);
      expect(
        state.notice,
        'Level up! Level 10 · Rising Star — your winning tax is now '
        '17.43%.',
      );

      // More XP, the same level: the standing is replaced and nothing said.
      state.notice = null;
      state.handlePlayerLevel(
        Standing.maybe({
          'playerLevel': {..._level10(), 'xp': 4200},
          'badges': [_regular()],
          'taxBps': 1743,
        })!,
      );
      expect(state.user!.playerLevel!.xp, 4200);
      expect(state.notice, isNull);
      state.dispose();

      // A 5% badge keeps the rate at 5% through the level up.
      final gold = _lobbyState(
        level: {..._level10(), 'level': 9, 'taxBps': 1771},
        badges: [_regular(), _goldBadge()],
        taxBps: 500,
      );
      gold.handlePlayerLevel(
        standingAt10(badges: [_regular(), _goldBadge()], taxBps: 500),
      );
      expect(gold.notice, 'Level up! Level 10 · Rising Star');
      expect(gold.user!.badges.map((b) => b.code), ['REGULAR', 'GOLD']);
      // And a badge that runs out comes off with the next standing.
      gold.handlePlayerLevel(standingAt10());
      expect(gold.user!.badges.map((b) => b.code), ['REGULAR']);
      expect(gold.user!.paysTaxBps, 1743);
      gold.dispose();
    });

    for (final lang in AppLang.values) {
      test('the level-up toast reads in ${lang.englishName}', () {
        final state = _lobbyState(
          lang: lang,
          level: {..._level10(), 'level': 9, 'taxBps': 1771},
        );
        state.handlePlayerLevel(standingAt10());
        final t = Strings(lang);
        expect(
          state.notice,
          t.levelUp(t.levelName(10, 'Rising Star'), '17.43%'),
        );
        expect(state.notice, contains('17.43%'));
        state.dispose();
      });
    }

    testWidgets("the Stats drawer names the level, today's XP and the badges "
        'held', (tester) async {
      final state = _lobbyState();
      await _pumpLobby(tester, state);
      await tester.tap(find.byIcon(Icons.insights_outlined).first);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Level 10 · Rising Star · 4,180 XP'), findsOneWidget);
      final today = tester.widget<Text>(
        find.byKey(const ValueKey('stats-xp-today')),
      );
      expect(today.data, startsWith('Today 23 / 50 XP · resets in 4h 59m'));
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('stats-badges'))).data,
        'Regular',
      );
      await _unmount(tester, state);

      final gold = _lobbyState(
        level: _level1(),
        badges: [_regular(), _goldBadge()],
        taxBps: 500,
      );
      await _pumpLobby(tester, gold);
      await tester.tap(find.byIcon(Icons.insights_outlined).first);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Level 1 · Newbie · 12 XP'), findsOneWidget);
      expect(find.byKey(const ValueKey('stats-xp-today')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('stats-badges'))).data,
        'Regular · 🏅 Gold',
      );
      await _unmount(tester, gold);
    });
  });

  // The lobby's level key (owner, 27 Sep 2026: "Add one icon in lobby so that
  // user can see his level, and in that pop up add one tab also for daily xp,
  // one tab for ladder … for all levels with tax rate"); since 27 Sep 2026
  // the table's pill opens the same screen ("it should pop the same UI which
  // it shows in Lobby").
  group('the lobby level key', () {
    testWidgets('wears the level and opens it in three tabs: my level, the '
        'daily XP, and every level with its rate', (tester) async {
      final state = _lobbyState()..levelLadder = _ladder();
      final t = state.t;
      await _pumpLobby(tester, state, screen: const Size(891, 411));
      final key = find.byKey(const ValueKey('level-key'));
      expect(key, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('level-key-badge')),
          matching: find.text('10'),
        ),
        findsOneWidget,
      );
      await tester.tap(key);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(t.yourLevelTitle), findsOneWidget);
      for (final tab in ['mine', 'daily', 'oneTime', 'ladder']) {
        expect(find.byKey(ValueKey('level-tab-$tab')), findsOneWidget);
      }
      // My level: the rate and what sets it and the level — and neither the
      // daily list nor the ladder.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('winning-tax-rate')),
          matching: find.text('17.43%'),
        ),
        findsOneWidget,
      );
      // The level screen (27 Sep 2026) names the level on its hero — its
      // number over its title, the mark in the medal — where the old tab
      // wrote "Level 10 · 🌟 Rising Star" in one line.
      expect(find.text(t.levelNumber(10)), findsOneWidget);
      expect(find.text('Rising Star'), findsOneWidget);
      expect(
        find.text('Play 15 active minutes', skipOffstage: false),
        findsNothing,
      );
      expect(find.byType(LevelRow, skipOffstage: false), findsNothing);

      await tester.tap(find.byKey(const ValueKey('level-tab-daily')));
      await tester.pump(const Duration(milliseconds: 300));
      // The play-time milestones stand on a track by their minutes; the
      // winning hands by name.
      for (final minutes in [15, 60, 120]) {
        expect(
          find.byKey(ValueKey('play-milestone-$minutes'), skipOffstage: false),
          findsOneWidget,
        );
      }
      expect(find.text('Win by Trail', skipOffstage: false), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('xp-earned-Play 15 active minutes'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      expect(find.byType(LevelRow, skipOffstage: false), findsNothing);

      await tester.tap(find.byKey(const ValueKey('level-tab-ladder')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(LevelRow, skipOffstage: false).evaluate().length, 50);
      expect(
        find.byKey(const ValueKey('ladder-you'), skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('ladder-badge-ROYAL_ACE'),
          skipOffstage: false,
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('winning-tax-close')));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(WinningTaxInfo), findsNothing);
      await _unmount(tester, state);
    });

    testWidgets('the table\'s pill opens the same three tabs, not the two '
        'panes', (tester) async {
      final state = _tableState();
      await _pumpTable(tester, state);
      await tester.tap(find.byType(WinningTaxTag));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(LevelScreen), findsOneWidget);
      // Not the two panes, which stand both at once: the level screen holds
      // one tab's body at a time.
      expect(find.byType(WinningTaxInfo), findsNothing);
      for (final tab in LevelInfoTab.values) {
        expect(find.byKey(ValueKey('level-tab-${tab.name}')), findsOneWidget);
      }
      await _unmount(tester, state);
    });

    for (final lang in AppLang.values) {
      for (final dark in [true, false]) {
        testWidgets('from the table\'s pill, every tab fits a 640x360 phone at '
            'text x1.25 in ${lang.name}, ${dark ? 'dark' : 'light'}', (
          tester,
        ) async {
          final state = _tableState(lang: lang);
          await _pumpTable(
            tester,
            state,
            screen: const Size(640, 360),
            scale: 1.25,
            dark: dark,
          );
          await tester.tap(find.byType(WinningTaxTag));
          await tester.pump(const Duration(milliseconds: 500));
          expect(find.byType(LevelScreen), findsOneWidget);
          for (final tab in ['mine', 'daily', 'oneTime', 'ladder']) {
            await tester.tap(find.byKey(ValueKey('level-tab-$tab')));
            await tester.pump(const Duration(milliseconds: 300));
            expect(
              tester.takeException(),
              isNull,
              reason: '$tab in ${lang.name}',
            );
          }
          await _unmount(tester, state);
        });
      }
    }

    for (final lang in AppLang.values) {
      testWidgets('the key and every tab fit a 640x360 phone at text x1.25 '
          'in ${lang.name}', (tester) async {
        final state = _lobbyState(lang: lang)..levelLadder = _ladder();
        await _pumpLobby(tester, state, scale: 1.25);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byKey(const ValueKey('level-key')));
        await tester.pump(const Duration(milliseconds: 500));
        for (final tab in ['mine', 'daily', 'oneTime', 'ladder']) {
          await tester.tap(find.byKey(ValueKey('level-tab-$tab')));
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            tester.takeException(),
            isNull,
            reason: '$tab in ${lang.name}',
          );
        }
        await _unmount(tester, state);
      });
    }
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

          final column = _twentyLakhColumn(tester, t);
          expect(_cut(column), isEmpty);
          // No tax pill and no corner on the card (29 Sep 2026).
          expect(
            find.byType(WinningTaxPill, skipOffstage: false),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('table-card-badge'), skipOffstage: false),
            findsNothing,
          );

          // Its popup: the winning tax's rows whole (the popup's own title
          // runs to an ellipsis at this size in every language, as it did
          // before the tax).
          await _tapCornerKey(
            tester,
            TableCategory.variation,
            2000000,
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

        testWidgets('$label: a badge holder\'s pill and popup with nothing '
            'cut', (tester) async {
          final state = _goldTable(lang: lang);
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
          _openTwoPanes(tester);
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          expect(_cut(find.byType(WinningTaxInfo)), isEmpty, reason: label);
          expect(find.text(t.rateSetByBadge('🏅 Gold')), findsOneWidget);
          // Both panes stand side by side on a 640dp phone.
          final standing = tester.getRect(
            find.byKey(const ValueKey('winning-tax-standing')),
          );
          final ladder = tester.getRect(
            find.byKey(const ValueKey('winning-tax-ladder')),
          );
          expect(standing.right, lessThanOrEqualTo(ladder.left));
          expect(standing.width, greaterThan(200), reason: label);
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

          _openTwoPanes(tester);
          await tester.pump(const Duration(milliseconds: 500));
          expect(tester.takeException(), isNull);
          expect(_cut(find.byType(WinningTaxInfo)), isEmpty, reason: label);
          expect(find.text(t.levelName(11, 'Pro Player')), findsOneWidget);
          expect(
            find.text(t.nextLevelValue('5,200', '17.14%')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('winning-tax-close')));
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
