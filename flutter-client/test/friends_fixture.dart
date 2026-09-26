// A fake Friends server and the wire shapes it answers with, for the Friends
// suites (owner, 26 Sep 2026). Not a test file: suites import it.
//
// Every route of the contract, over an in-memory graph: GET /api/friends and
// /api/friends/requests, a lookup and a profile by Player ID, a request sent,
// accepted or rejected, and a friend removed. Every request is kept in [sent],
// so a suite can count what the app asked for and when.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';

const friendsServer = 'http://127.0.0.1:9';

/// The viewer's own Player ID in every fixture.
const myId = '3f0c9c1e-5d47-4a8e-9a57-0b9a5d3a7c21';

Map<String, dynamic> cardJson(String userId, String name, {String? url}) => {
  'userId': userId,
  'displayName': name,
  'profilePicture': {'id': null, 'url': url},
};

Map<String, dynamic> friendJson(
  String userId,
  String name, {
  String status = 'OFFLINE',
  String? game,
  String? variant,
  int since = 1758844800000,
}) => {
  ...cardJson(userId, name),
  'status': status,
  'online': status != 'OFFLINE',
  'playing': status == 'PLAYING',
  'game': ?game,
  'variant': ?variant,
  'friendsSince': since,
};

Map<String, dynamic> requestJson(int id, String userId, String name) => {
  'requestId': id,
  'player': cardJson(userId, name),
  'createdAt': 1758844800000 + id,
};

Map<String, dynamic> statsJson({
  int played = 120,
  int won = 61,
  int lost = 52,
  int left = 7,
  double winRate = 50.83,
}) => {
  'handsPlayed': played,
  'handsWon': won,
  'handsLost': lost,
  'handsLeft': left,
  'winRate': winRate,
};

/// What a signed-in account reads as: the app's user object, wallet and all —
/// the Friends pages must show none of it.
Map<String, dynamic> meJson({String name = 'Guest0E00B'}) => {
  'id': myId,
  'provider': 'guest',
  'displayName': name,
  'chips': 324500,
  'diamond': 9,
  'hammer': 20,
  'missile': 1,
  'rewards': {
    'milestoneAvailable': false,
    'milestoneReward': 25000,
    'handsToNextMilestone': 25,
    'bonusReward': 10000,
    'bonusReadyAt': DateTime.now()
        .add(const Duration(hours: 3, minutes: 12))
        .millisecondsSinceEpoch,
    'bonusAvailable': false,
    'dailyReward': 100000,
    'dailyHammers': 1,
    'dailyReadyAt': 0,
    'dailyAvailable': true,
  },
};

/// A signed-in GameState on the lobby, talking to [friendsServer].
GameState signedInState({AppLang lang = AppLang.english}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: friendsServer);
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = Screen.lobby
    ..debugToken = 'tok'
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
      ],
    })
    ..user = User.fromJson(meJson());
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response refusal(String code, int status, {Object? requestId}) => _json({
  'error': code,
  'message': 'refused: $code',
  'requestId': ?requestId,
}, status);

/// The fake server. Its graph is public so a test can shape it; [sent] is
/// every request it was asked.
class FakeFriendsServer {
  FakeFriendsServer({
    List<Map<String, dynamic>>? friends,
    List<Map<String, dynamic>>? incoming,
    List<Map<String, dynamic>>? outgoing,
  }) : friends = friends ?? [],
       incoming = incoming ?? [],
       outgoing = outgoing ?? [];

  final List<Map<String, dynamic>> friends;
  final List<Map<String, dynamic>> incoming;
  final List<Map<String, dynamic>> outgoing;

  /// Players a lookup finds, by Player ID: their card, and what they are to
  /// the viewer (`friendStatus`, `requestId`).
  final Map<String, Map<String, dynamic>> players = {};

  /// Profiles by Player ID, as `GET /api/players/{id}/profile` answers.
  final Map<String, Map<String, dynamic>> profiles = {};

  final List<http.Request> sent = [];

  /// Every list read answers 500 while this is true.
  bool failLists = false;

  /// Every route answers 404 `not_found`: a server from before Friends.
  bool unsupported = false;

  /// The refusal a request sent is answered with, if any.
  http.Response? sendRefusal;

  /// The refusal an accept or reject is answered with, if any.
  http.Response? answerRefusal;

  /// Holds every answer of [holdPath] until it completes.
  String? holdPath;
  Completer<void>? hold;

  int _nextRequestId = 900;

  MockClient get client => MockClient(_handle);

  /// How many [method] requests went to [path].
  int count(String method, String path) =>
      sent.where((r) => r.method == method && r.url.path == path).length;

  Future<http.Response> _handle(http.Request r) async {
    sent.add(r);
    final path = r.url.path;
    if (holdPath == path && hold != null) await hold!.future;
    if (unsupported) {
      return _json({
        'error': 'not_found',
        'message': 'Cannot ${r.method} $path',
      }, 404);
    }
    final segments = r.url.pathSegments;
    if (r.method == 'GET' && path == '/api/friends') {
      if (failLists) return _json({'error': 'internal'}, 500);
      return _json({'friends': friends});
    }
    if (r.method == 'GET' && path == '/api/friends/requests') {
      if (failLists) return _json({'error': 'internal'}, 500);
      return _json({'incoming': incoming, 'outgoing': outgoing});
    }
    if (r.method == 'GET' &&
        segments.length >= 3 &&
        segments[0] == 'api' &&
        segments[1] == 'players') {
      final id = segments[2];
      if (segments.length == 4 && segments[3] == 'profile') {
        final profile = profiles[id];
        if (profile == null) return refusal('player_not_found', 404);
        return _json({'profile': profile});
      }
      final player = players[id];
      if (player == null) return refusal('player_not_found', 404);
      return _json(player);
    }
    if (r.method == 'POST' && path == '/api/friends/requests') {
      final refused = sendRefusal;
      if (refused != null) return refused;
      final id = _nextRequestId++;
      final userId = (jsonDecode(r.body) as Map)['userId'] as String;
      final player = players[userId];
      if (player != null) {
        players[userId] = {
          ...player,
          'friendStatus': 'PENDING_SENT',
          'requestId': id,
        };
      }
      return _json({'requestId': id, 'friendStatus': 'PENDING_SENT'}, 201);
    }
    if (r.method == 'POST' &&
        segments.length == 5 &&
        segments[2] == 'requests') {
      final refused = answerRefusal;
      if (refused != null) return refused;
      final id = int.tryParse(segments[3]);
      final i = incoming.indexWhere((e) => e['requestId'] == id);
      if (i < 0) return refusal('request_not_found', 404);
      final request = incoming.removeAt(i);
      if (segments[4] == 'accept') {
        final player = request['player'] as Map<String, dynamic>;
        final friend = friendJson(
          player['userId'] as String,
          player['displayName'] as String,
          status: 'ONLINE',
        );
        friends.add(friend);
        return _json({'friend': friend});
      }
      return _json({'requestId': id, 'status': 'REJECTED'});
    }
    if (r.method == 'DELETE' && segments.length == 3) {
      final i = friends.indexWhere((e) => e['userId'] == segments[2]);
      if (i < 0) return refusal('not_friends', 404);
      friends.removeAt(i);
      return _json({'removed': true});
    }
    return _json({'error': 'not_found', 'message': 'Cannot $path'}, 404);
  }
}

/// A graph with two requests waiting and three friends: one playing Teen
/// Patti Seen, one online, one offline.
FakeFriendsServer populatedServer() {
  final server = FakeFriendsServer(
    friends: [
      friendJson('u-kavya', 'Kavya'),
      friendJson('u-arjun', 'Arjun', status: 'ONLINE'),
      friendJson(
        'u-meera',
        'Meera',
        status: 'PLAYING',
        game: 'TEEN_PATTI',
        variant: 'SEEN',
      ),
    ],
    incoming: [
      requestJson(41, 'u-ravi', 'Ravi'),
      requestJson(42, 'u-isha', 'Isha'),
    ],
    outgoing: [requestJson(43, 'u-dev', 'Dev')],
  );
  server.profiles['u-meera'] = {
    ...cardJson('u-meera', 'Meera'),
    'friendStatus': 'FRIENDS',
    'presence': {
      'status': 'PLAYING',
      'online': true,
      'playing': true,
      'game': 'TEEN_PATTI',
      'variant': 'SEEN',
    },
    'stats': statsJson(),
  };
  server.profiles['u-kavya'] = {
    ...cardJson('u-kavya', 'Kavya'),
    'friendStatus': 'FRIENDS',
    'presence': {'status': 'OFFLINE', 'online': false, 'playing': false},
    'stats': statsJson(played: 10, won: 4, lost: 6, left: 0, winRate: 40),
  };
  server.profiles['u-ravi'] = {
    ...cardJson('u-ravi', 'Ravi'),
    'friendStatus': 'PENDING_RECEIVED',
    'requestId': 41,
    'stats': statsJson(played: 0, won: 0, lost: 0, left: 0, winRate: 0),
  };
  return server;
}
