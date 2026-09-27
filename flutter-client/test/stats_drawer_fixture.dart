// The accounts the lobby's Stats drawer is shown with (the owner's brief,
// 27 Sep 2026), for stats_drawer_test.dart and the pictures
// (stats_drawer_shots.dart). Not a test file: they import it.
//
// Every figure differs from every other, so a figure on screen says which
// scope it came from; the chip figures are the brief's large ones — 10.5
// Crore, 1.25 Crore, 99.9 Lakh — so the pictures and the tests see the widest
// values the drawer has to fit.
import 'package:flutter/foundation.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';

import 'player_stats_fixture.dart';

/// The level the owner's screenshot shows: "Level 1 · 🌱 Newbie · 23 XP".
Map<String, dynamic> newbieLevelJson() => {
  'level': 1,
  'title': 'Newbie',
  'icon': '🌱',
  'xp': 23,
  'taxBps': 2000,
};

Map<String, dynamic> regularBadgeJson() => {
  'code': 'REGULAR',
  'title': 'Regular',
  'taxBps': 2000,
  'isDefault': true,
};

/// The three games of [guestWithStatsJson]: Teen Patti's and Variation's
/// hands held, Variation's five variations (the owner's screenshot's, with
/// larger figures), and a poker record the drawer must never show.
Map<String, dynamic> drawerGamesJson() => {
  'teenPatti': statsGameJson(
    played: 912,
    won: 401,
    lost: 473,
    left: 38,
    winRate: 43.97,
    winnings: 9990000,
    biggest: 812000,
    hands: handsJson(3, 5, 29, 47, 153, 661),
  ),
  'variation': statsGameJson(
    played: 380,
    won: 150,
    lost: 209,
    left: 21,
    winRate: 39.47,
    winnings: 94434000,
    biggest: 12500000,
    hands: handsJson(24, 9, 33, 41, 91, 182),
    variations: [
      variationJson('MUFLIS', 120, 50),
      variationJson('AK47', 97, 36),
      variationJson('JOKER', 61, 22),
      variationJson('HUKAM', 43, 15),
      variationJson('FIVE_CARD', 11, 7),
    ],
  ),
  'poker': statsGameJson(
    played: 206,
    won: 59,
    lost: 131,
    left: 16,
    winRate: 28.64,
    winnings: 576500,
    biggest: 402000,
  ),
};

/// Guest23AF1's account, as `/api/auth/me` answers it: the six totals the
/// user object carries — 10.5 Crore won in all, a 1.25 Crore biggest pot —
/// the three games, the level and the Regular badge.
Map<String, dynamic> guestWithStatsJson({String name = 'Guest23AF1'}) => {
  'id': 'u-guest',
  'provider': 'guest',
  'displayName': name,
  'chips': 3245000,
  'diamond': 9,
  'hammer': 20,
  'missile': 1,
  'handsPlayed': 1498,
  'handsWon': 610,
  'handsLost': 813,
  'handsLeftMid': 75,
  'totalWinnings': 105000500,
  'biggestPot': 12500000,
  'stats': drawerGamesJson(),
  'playerLevel': newbieLevelJson(),
  'badges': [regularBadgeJson()],
};

/// A player who has not finished a hand: no figure and no game sent at all.
Map<String, dynamic> newAccountJson() => {
  'id': 'u-new',
  'provider': 'guest',
  'displayName': 'Guest0E00B',
  'chips': 1000000,
  'playerLevel': {...newbieLevelJson(), 'xp': 0},
  'badges': [regularBadgeJson()],
};

/// Signed in with [me], on the lobby.
GameState statsDrawerState({
  AppLang lang = AppLang.english,
  Map<String, dynamic>? me,
}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a test.
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
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
        {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
      ],
    })
    ..user = User.fromJson(me ?? guestWithStatsJson());
}

/// A player of years: hand results and variations in four, five and six
/// figures — "18,182" High Cards beside "Pure Sequence" in a 300dp drawer at
/// text x1.25 is where a count used to squeeze its hand's name into an
/// ellipsis — and all seven variations.
Map<String, dynamic> bigCountsJson() => {
  ...guestWithStatsJson(),
  'handsPlayed': 1234567,
  'handsWon': 456789,
  'handsLost': 777778,
  'handsLeftMid': 12345,
  'stats': {
    'teenPatti': statsGameJson(
      played: 912345,
      won: 401234,
      lost: 473456,
      left: 9876,
      winRate: 43.98,
      winnings: 999000000,
      biggest: 81200000,
      hands: handsJson(12034, 13090, 120330, 130410, 190910, 181820),
    ),
    'variation': statsGameJson(
      played: 38012,
      won: 15034,
      lost: 20911,
      left: 2067,
      winRate: 39.55,
      winnings: 944340000,
      biggest: 125000000,
      hands: handsJson(1204, 1309, 2033, 3041, 9091, 18182),
      variations: [
        variationJson('MUFLIS', 12034, 5012),
        variationJson('AK47', 9734, 3645),
        variationJson('JOKER', 61209, 22341),
        variationJson('HUKAM', 43120, 15098),
        variationJson('LOWEST_JOKER', 31022, 12001),
        variationJson('HIGHEST_JOKER', 28033, 11007),
        variationJson('FIVE_CARD', 11234, 7123),
      ],
    ),
  },
};
