// Fixtures for the level screen (the lobby's level key's popup, 27 Sep 2026):
// the owner's ladder, badges and daily XP exactly as `GET /api/levels` sends
// them, a player's standing at any level, and the lobby mounted with the
// fonts a phone draws the screen in. Not a test file: level_screen_test and
// level_shots import it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

int get nowMs => DateTime.now().millisecondsSinceEpoch;

const int hourMs = 3600 * 1000;
const int dayMs = 24 * hourMs;

/// The owner's fifty levels as the server seeds them (V1.0.1: 20% at Level 1
/// to 6% at Level 50): level, the XP that reaches it, title, mark, rate.
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

/// The owner's Royal badges: code, name, days, rupees.
const List<(String, String, int, int)> ownersRoyal = [
  ('ROYAL_ACE', 'Royal Ace', 7, 499),
  ('ROYAL_KING', 'Royal King', 15, 999),
  ('ROYAL_MASTER', 'Royal Master', 30, 1799),
  ('ROYAL_EMPEROR', 'Royal Emperor', 45, 2499),
  ('ROYAL_LEGEND', 'Royal Legend', 60, 3299),
  ('ROYAL_KING_OF_KINGS', 'Royal King of Kings', 90, 4499),
];

/// The owner's daily XP: code, name, mark, kind, minutes or hand, XP.
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

/// Every source's code.
List<String> get allSourceCodes => [for (final s in ownersSources) s.$1];

/// The owner's one-time missions (28 Sep 2026) as the server seeds them:
/// code, title, mark, kind, target, scope, XP — the XP a tenth of the first
/// figures (owner, the same day: "reduce the XP Granted value"), and no Poker
/// mission (owner, the same day: "Remove Poker and texas related one time XP
/// from DB, we don't need").
const List<(String, String, String, String, int, String?, int)>
ownersMissions = [
  ('FIRST_HAND', 'First Hand', '🎴', 'HANDS_PLAYED', 1, null, 5),
  ('FIRST_WIN', 'First Win', '🏆', 'HANDS_WON', 1, null, 10),
  ('GETTING_STARTED', 'Getting Started', '🚀', 'HANDS_PLAYED', 10, null, 15),
  ('FIRST_5_WINS', 'First 5 Wins', '🥇', 'HANDS_WON', 5, null, 30),
  ('CARD_PLAYER', 'Card Player', '♠️', 'HANDS_PLAYED', 50, null, 50),
  ('WINNING_STREAK', 'Winning Streak', '⚡', 'HANDS_WON', 10, null, 75),
  (
    'VARIATION_EXPLORER',
    'Variation Explorer',
    '🔀',
    'HANDS_PLAYED',
    1,
    'variation',
    10,
  ),
  ('GAME_EXPLORER', 'Game Explorer', '🧭', 'CATEGORIES_PLAYED', 5, null, 50),
];

/// One mission as `user.playerLevel.missions[]` carries it: [progress] of
/// [target], completed (with the XP it gave) where [completed].
Map<String, Object?> missionAt(
  String code,
  int progress,
  int target, {
  bool completed = false,
  int xpAwarded = 0,
}) => {
  'code': code,
  'type': 'ONE_TIME',
  'progress': progress,
  'target': target,
  'completed': completed,
  if (completed) 'completedAt': nowMs - hourMs,
  if (completed && xpAwarded > 0) 'xpAwarded': xpAwarded,
};

String badgeUrl(String code) => 'https://drive.test/badges/$code.json';

/// The whole ladder as `GET /api/levels` sends it; [levels] replaces the
/// owner's titles (a long name). [withMissions] adds the one-time missions
/// (a server of 28 Sep 2026 or later); without, it is a server from before
/// them.
Map<String, Object?> ladderJson({
  List<(int, int, String, String, int)> levels = ownersLevels,
  bool withMissions = false,
}) => {
  'levels': [
    for (final (level, minXp, title, icon, taxBps) in levels)
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
      'assetUrl': badgeUrl('REGULAR'),
      'assetFormat': 'LOTTIE',
    },
    for (final (code, title, days, rupees) in ownersRoyal)
      {
        'code': code,
        'title': title,
        'icon': '',
        'taxBps': 0,
        'validityDays': days,
        'isDefault': false,
        'priceInr': rupees,
        'assetUrl': badgeUrl(code),
        'assetFormat': 'LOTTIE',
      },
  ],
  'xpSources': [
    for (final (code, name, icon, kind, minutes, hand, xp) in ownersSources)
      {
        'code': code,
        'name': name,
        'icon': icon,
        'kind': kind,
        if (withMissions) 'type': 'DAILY',
        'playMinutes': ?minutes,
        'hand': ?hand,
        'xp': xp,
        'times': 1,
      },
  ],
  if (withMissions)
    'missions': [
      for (final (code, name, icon, kind, target, scope, xp) in ownersMissions)
        {
          'code': code,
          'name': name,
          'icon': icon,
          'kind': kind,
          'type': 'ONE_TIME',
          'target': target,
          'scope': ?scope,
          'xp': xp,
          'times': 1,
        },
    ],
  'dailyCap': null,
  'windowMs': 86400000,
};

LevelLadder ladder({
  List<(int, int, String, String, int)> levels = ownersLevels,
  bool withMissions = false,
}) =>
    LevelLadder.maybe(ladderJson(levels: levels, withMissions: withMissions))!;

/// A player at [level] of the owner's ladder with [xp] (the level's own
/// threshold plus [into] by default), the daily window's [claimed] sources
/// and [resetsIn] to its reset — no window at all where [resetsIn] is null.
Map<String, Object?> levelAt(
  int level, {
  int? xp,
  int into = 0,
  List<String> claimed = const [],
  Duration? resetsIn = const Duration(hours: 23, minutes: 45, seconds: 19),
  List<(int, int, String, String, int)> levels = ownersLevels,
  List<Map<String, Object?>> missions = const [],
}) {
  final (n, minXp, title, icon, taxBps) = levels[level - 1];
  final next = level < levels.length ? levels[level] : null;
  return {
    'level': n,
    'title': title,
    'icon': icon,
    'xp': xp ?? minXp + into,
    'taxBps': taxBps,
    if (next != null)
      'next': {
        'level': next.$1,
        'title': next.$3,
        'icon': next.$4,
        'minXp': next.$2,
        'taxBps': next.$5,
      },
    if (resetsIn != null)
      'daily': {
        'claimed': {for (final c in claimed) c: 1},
        'resetsAt': nowMs + resetsIn.inMilliseconds,
      },
    if (missions.isNotEmpty) 'missions': missions,
  };
}

/// Regular, every player's for life at 20%.
Map<String, Object?> regularBadge() => {
  'code': 'REGULAR',
  'title': 'Regular',
  'icon': '',
  'taxBps': 2000,
  'expiresAt': 0,
  'isDefault': true,
  'assetUrl': badgeUrl('REGULAR'),
  'assetFormat': 'LOTTIE',
};

/// A Royal badge held until [left] from now.
Map<String, Object?> royalBadge(String code, Duration left, {String? title}) =>
    {
      'code': code,
      'title':
          title ??
          ownersRoyal
              .firstWhere((r) => r.$1 == code, orElse: () => (code, code, 0, 0))
              .$2,
      'icon': '',
      'taxBps': 0,
      'expiresAt': nowMs + left.inMilliseconds,
      'assetUrl': badgeUrl(code),
      'assetFormat': 'LOTTIE',
    };

User playerUser({
  required Map<String, Object?> level,
  List<Map<String, Object?>>? badges,
  int? taxBps,
}) => User.fromJson({
  'id': 'u0',
  'provider': 'guest',
  'displayName': 'Priya',
  'chips': 600000000,
  'diamond': 9,
  'hammer': 20,
  'missile': 1,
  'playerLevel': level,
  'badges': badges ?? [regularBadge()],
  'taxBps': ?taxBps,
});

/// The lobby's game state for a player at [level], the ladder read.
GameState levelState({
  required Map<String, Object?> level,
  List<Map<String, Object?>>? badges,
  int? taxBps,
  AppLang lang = AppLang.english,
  LevelLadder? ladderRead,
  bool withLadder = true,
}) {
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
      'tables': [
        {
          'category': 'seen',
          'bootAmount': 200,
          'winnerTax': true,
          'winnerTaxMinWinnings': 5000000,
        },
        {
          'category': 'blind',
          'bootAmount': 200,
          'winnerTax': true,
          'winnerTaxMinWinnings': 5000000,
        },
      ],
    })
    ..levelLadder = withLadder ? (ladderRead ?? ladder()) : null
    ..user = playerUser(level: level, badges: badges, taxBps: taxBps);
}

/// A Lottie as small as one can be — a gold disc — standing in for every
/// badge's animation, so no test reaches the network for one.
final Uint8List standInLottie = Uint8List.fromList(
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

/// Every badge's Lottie answered from memory: [real] maps a code to the
/// owner's own file where the pictures want it, else the stand-in.
void primeBadges([Map<String, Uint8List> real = const {}]) {
  for (final code in [
    'REGULAR',
    for (final r in ownersRoyal) r.$1,
    'ROYAL_SUPREME_LONG',
  ]) {
    PictureCache.prime(badgeUrl(code), real[code] ?? standInLottie);
  }
}

// ------------------------------------------------------------------ fonts

const emojiFontPath = '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf';
const emojiFamily = 'Noto Color Emoji';

/// Inter, the Indic scripts' Noto fonts and the colour emoji (the level
/// marks); [icons] the Material icons where a picture wants them drawn.
Future<void> loadLevelFonts({String icons = ''}) async {
  await loadScriptFonts();
  final emoji = File(emojiFontPath);
  if (emoji.existsSync()) {
    final loader = FontLoader(emojiFamily)
      ..addFont(Future.value(ByteData.sublistView(emoji.readAsBytesSync())));
    await loader.load();
  }
  final iconFont = File(icons);
  if (icons.isNotEmpty && iconFont.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(iconFont.readAsBytesSync())));
    await loader.load();
  }
}

ThemeData levelTheme({bool dark = true}) {
  final base = dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamilyFallback: [...scriptFonts.keys, emojiFamily],
    ),
  );
}

/// The lobby at [screen] and text [scale], wrapped in [wrap] (a picture's
/// repaint boundary).
Future<FeedbackSettings> pumpLevelLobby(
  WidgetTester tester,
  GameState state, {
  Size screen = const Size(891, 411),
  double scale = 1.0,
  bool dark = true,
  Widget Function(Widget child)? wrap,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  final app = MultiProvider(
    providers: [
      ChangeNotifierProvider<GameState>.value(value: state),
      ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: levelTheme(dark: dark),
      builder: (context, child) => GlassBudget(child: child!),
      home: const LobbyScreen(),
    ),
  );
  await tester.pumpWidget(wrap == null ? app : wrap(app));
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
  return feedback;
}

/// Opens the level screen from the lobby's level key and lets it settle.
Future<void> openLevelScreen(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('level-key')));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 800));
}

/// Shows [tab] and lets the slide finish.
Future<void> showLevelTab(WidgetTester tester, String tab) async {
  await tester.tap(find.byKey(ValueKey('level-tab-$tab')));
  await tester.pump(const Duration(milliseconds: 120));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 800));
}

Future<void> unmountLevel(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}
