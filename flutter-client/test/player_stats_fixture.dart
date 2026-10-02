// The records player stats v2 reads (owner, 27 Sep 2026), and the state and
// the app each of the record's three places is mounted with, for
// player_stats_test.dart and the pictures (player_stats_shots.dart). Not a
// test file: they import it.
//
// Every figure differs from every other, so a figure on screen says which
// view it came from; and another player's profile carries two chip figures
// in every game, which the app must never read.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'friends_fixture.dart';
import 'script_fonts.dart';

/// One game's record as the server writes it. [winnings] and [biggest] are
/// the two chip figures, which the player's own account carries and another
/// player's profile never should.
Map<String, dynamic> statsGameJson({
  required int played,
  required int won,
  required int lost,
  int left = 0,
  double winRate = 0,
  int? winnings,
  int? biggest,
  int? tax,
  Map<String, int>? hands,
  List<Map<String, dynamic>>? variations,
}) => {
  'handsPlayed': played,
  'handsWon': won,
  'handsLost': lost,
  'handsLeft': left,
  'winRate': winRate,
  'totalWinnings': ?winnings,
  'biggestPot': ?biggest,
  'totalTaxPaid': ?tax,
  'hands': ?hands,
  'variations': ?variations,
};

Map<String, int> handsJson(
  int trail,
  int pure,
  int sequence,
  int color,
  int pair,
  int high,
) => {
  'trail': trail,
  'pureSequence': pure,
  'sequence': sequence,
  'color': color,
  'pair': pair,
  'highCard': high,
};

Map<String, dynamic> variationJson(String name, int played, int won) => {
  'variation': name,
  'handsPlayed': played,
  'handsWon': won,
};

/// The seven variations in the server's order, each with a hand or more.
final allVariationsJson = [
  variationJson('MUFLIS', 120, 50),
  variationJson('AK47', 97, 36),
  variationJson('JOKER', 61, 22),
  variationJson('HUKAM', 43, 15),
  variationJson('LOWEST_JOKER', 31, 12),
  variationJson('HIGHEST_JOKER', 17, 8),
  variationJson('FIVE_CARD', 11, 7),
];

/// The three games, every figure different from every other, so a figure on
/// screen says which view it came from. With [chips] the two chip figures
/// too — the own account's shape.
Map<String, dynamic> gamesJson({bool chips = true}) => {
  'teenPatti': statsGameJson(
    played: 912,
    won: 401,
    lost: 473,
    left: 38,
    winRate: 43.97,
    winnings: chips ? 5400000 : null,
    biggest: chips ? 812000 : null,
    hands: handsJson(3, 5, 29, 47, 153, 661),
  ),
  'variation': statsGameJson(
    played: 380,
    won: 150,
    lost: 209,
    left: 21,
    winRate: 39.47,
    winnings: chips ? 3900000 : null,
    biggest: chips ? 1250000 : null,
    hands: handsJson(24, 9, 33, 41, 91, 182),
    variations: allVariationsJson,
  ),
  'poker': statsGameJson(
    played: 206,
    won: 59,
    lost: 131,
    left: 16,
    winRate: 28.64,
    winnings: chips ? 576500 : null,
    biggest: chips ? 402000 : null,
  ),
};

/// The player's own account, as `/api/auth/me` answers it: the totals the
/// user object always carried, and the three games.
Map<String, dynamic> meWithStatsJson({String name = 'Ravi'}) => {
  'id': myId,
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
  'totalWinnings': 9876500,
  'biggestPot': 1250000,
  'stats': gamesJson(),
};

/// The chip figures the server sends on the player's OWN account — and, to
/// prove the app never shows one, on another player's profile too.
const strayWinnings = 7654321;
const strayBiggest = 3456789;

/// Another player's profile `stats`: the totals, and the three games — with
/// two chip figures slipped into every game, which must never be read.
Map<String, dynamic> theirStatsJson() {
  final games = gamesJson(chips: false);
  for (final game in games.values) {
    (game as Map<String, dynamic>)
      ..['totalWinnings'] = strayWinnings
      ..['biggestPot'] = strayBiggest;
  }
  return {
    'handsPlayed': 1498,
    'handsWon': 610,
    'handsLost': 813,
    'handsLeft': 75,
    'winRate': 40.72,
    'categories': games,
  };
}

ThemeData statsTheme(Brightness b) => withScriptFallback(
  b == Brightness.dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false),
);

Widget statsApp(
  GameState state,
  FeedbackSettings feedback,
  Widget home, {
  Brightness brightness = Brightness.dark,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<GameState>.value(value: state),
    ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: statsTheme(Brightness.light),
    darkTheme: statsTheme(Brightness.dark),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    // As the app mounts it: the text scale clamped to its ceiling, and the
    // one glass budget.
    builder: (context, child) => MediaQuery.withClampedTextScaling(
      minScaleFactor: 0.9,
      maxScaleFactor: 1.25,
      child: GlassBudget(child: child!),
    ),
    home: home,
  ),
);

/// Signed in as Ravi, on the lobby, with [me] for an account.
GameState statsLobbyState({
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
      ],
    })
    ..user = User.fromJson(me ?? meWithStatsJson());
}

/// Meera's profile, as the server answers it: a friend, playing, with
/// [theirStatsJson].
FakeFriendsServer statsProfileServer() {
  final server = populatedServer();
  server.profiles['u-meera'] = {
    ...cardJson('u-meera', 'Meera'),
    'friendStatus': 'FRIENDS',
    'presence': {
      'status': 'PLAYING',
      'online': true,
      'playing': true,
      'game': 'TEEN_PATTI',
      'variant': 'VARIATION',
    },
    'stats': theirStatsJson(),
  };
  return server;
}

const statsSeatNames = {
  'u0': 'Priya',
  'u1': 'Ravi',
  'u2': 'Meera',
  'u3': 'Arjun',
  'u4': 'Vikramaditya',
};

Map<String, dynamic> _seat(int i) => {
  'seatIndex': i,
  'userId': 'u$i',
  'displayName': statsSeatNames['u$i'],
  'avatarUrl': null,
  'chips': 1820000,
  'status': 'active',
  'isBlind': false,
  'lastBet': 400,
  'lastAction': 'chaal',
  'contributed': 1400,
  'connected': true,
  'cardCount': 3,
};

/// A seen table, the viewer (Priya, u0) at seat 0 and four others round it.
RoomState statsTableRoom() => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'isPrivate': false,
  'category': 'seen',
  'chipsHidden': false,
  'state': 'betting',
  'handNo': 7,
  'dealerSeat': 3,
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 6800,
  'maxPot': 2000000,
  'stake': 400,
  'turn': {
    'seatIndex': 2,
    'userId': 'u2',
    'deadline': DateTime.now().millisecondsSinceEpoch + 20000,
  },
  'you': {
    'seatIndex': 0,
    'chips': 1820000,
    'status': 'active',
    'isBlind': false,
    'blindMovesLeft': 0,
    'contributed': 1400,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': ['As', 'Kd', 'Qh'],
  },
  'seats': [for (var i = 0; i < 5; i++) _seat(i)],
});

/// The table's players, as the viewer stands to them: Ravi nobody yet,
/// Arjun asking the viewer — each with [theirStatsJson].
FakeFriendsServer statsTableServer() {
  final server = FakeFriendsServer(incoming: [requestJson(41, 'u3', 'Arjun')]);
  server.profiles['u1'] = {
    ...cardJson('u1', 'Ravi'),
    'friendStatus': 'NONE',
    'stats': theirStatsJson(),
  };
  server.profiles['u3'] = {
    ...cardJson('u3', 'Arjun'),
    'friendStatus': 'PENDING_RECEIVED',
    'requestId': 41,
    'stats': theirStatsJson(),
  };
  return server;
}

/// Priya (u0), signed in, about to sit down at [statsTableRoom] — which
/// the caller hands the state, as the table opens.
GameState statsTableState({AppLang lang = AppLang.english}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: friendsServer);
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..debugToken = 'tok'
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Priya',
      'chips': 1820000,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
    })
    ..screen = Screen.lobby;
}
