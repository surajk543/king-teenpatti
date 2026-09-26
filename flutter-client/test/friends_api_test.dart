// Friends V1's eight routes on the client (owner, 26 Sep 2026): each one's
// method, path, token and body exactly as the contract has them, its answer
// read, and every refusal surfacing as the server's code — the request id of
// a `request_already_received` with it.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teenpatti/models/friends.dart';
import 'package:teenpatti/net/api_client.dart';

import 'friends_fixture.dart';

const _base = 'http://api.test';

/// Runs [call] against a server that answers [answer], and hands back the
/// one request it made with the result.
Future<(http.Request, T)> _ask<T>(
  Future<T> Function(ApiClient api) call,
  http.Response answer,
) async {
  late http.Request sent;
  final client = MockClient((request) async {
    sent = request;
    return answer;
  });
  final result = await http.runWithClient(
    () => call(ApiClient(_base)),
    () => client,
  );
  return (sent, result);
}

/// What [call] is refused with when the server answers [answer].
Future<ApiException> _refused(
  Future<Object?> Function(ApiClient api) call,
  http.Response answer,
) async {
  final client = MockClient((_) async => answer);
  try {
    await http.runWithClient(() => call(ApiClient(_base)), () => client);
  } on ApiException catch (e) {
    return e;
  }
  fail('the call was not refused');
}

http.Response _ok(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

void main() {
  test('GET /api/players/{playerId} finds a player, escaping the id', () async {
    final (sent, found) = await _ask(
      (api) => api.findPlayer('tok', '  u-ravi/1 '),
      _ok({
        'player': cardJson('u-ravi', 'Ravi'),
        'friendStatus': 'PENDING_RECEIVED',
        'requestId': 41,
      }),
    );
    expect(sent.method, 'GET');
    expect(sent.url.toString(), '$_base/api/players/u-ravi%2F1');
    expect(sent.headers['Authorization'], 'Bearer tok');
    expect(found.player.displayName, 'Ravi');
    expect(found.friendStatus, FriendStatus.pendingReceived);
    expect(found.requestId, '41');
  });

  test('a lookup refused says why, by code', () async {
    final missing = await _refused(
      (api) => api.findPlayer('tok', 'nobody'),
      refusal('player_not_found', 404),
    );
    expect(missing, isA<FriendRefusal>());
    expect(missing.code, 'player_not_found');
    expect(missing.status, 404);
    final bad = await _refused(
      (api) => api.findPlayer('tok', 'x'),
      refusal('invalid_player_id', 400),
    );
    expect(bad.code, 'invalid_player_id');
    expect(bad.status, 400);
  });

  test('GET /api/players/{playerId}/profile reads a profile', () async {
    final (sent, profile) = await _ask(
      (api) => api.playerProfile('tok', 'u-meera'),
      _ok({
        'profile': {
          ...cardJson('u-meera', 'Meera'),
          'friendStatus': 'FRIENDS',
          'presence': {'status': 'ONLINE', 'online': true, 'playing': false},
          'stats': statsJson(),
        },
      }),
    );
    expect(sent.method, 'GET');
    expect(sent.url.path, '/api/players/u-meera/profile');
    expect(sent.headers['Authorization'], 'Bearer tok');
    expect(profile.friendStatus, FriendStatus.friends);
    expect(profile.presence?.isOnline, isTrue);
    expect(profile.stats.winRate, 50.83);
  });

  test('GET /api/friends reads the list', () async {
    final (sent, friends) = await _ask(
      (api) => api.friends('tok'),
      _ok({
        'friends': [
          friendJson(
            'u-meera',
            'Meera',
            status: 'PLAYING',
            game: 'POKER',
            variant: 'OMAHA',
          ),
          friendJson('u-kavya', 'Kavya'),
          {'displayName': 'no id'},
        ],
      }),
    );
    expect(sent.method, 'GET');
    expect(sent.url.path, '/api/friends');
    expect(sent.headers['Authorization'], 'Bearer tok');
    expect(friends.map((f) => f.userId), ['u-meera', 'u-kavya']);
    expect(friends.first.presence.variant, 'OMAHA');
  });

  test('GET /api/friends/requests reads both ways', () async {
    final (sent, requests) = await _ask(
      (api) => api.friendRequests('tok'),
      _ok({
        'incoming': [requestJson(41, 'u-ravi', 'Ravi')],
        'outgoing': [requestJson(43, 'u-dev', 'Dev')],
      }),
    );
    expect(sent.method, 'GET');
    expect(sent.url.path, '/api/friends/requests');
    expect(sent.headers['Authorization'], 'Bearer tok');
    expect(requests.incoming.single.player.displayName, 'Ravi');
    expect(requests.outgoing.single.requestId, '43');
  });

  test('POST /api/friends/requests sends {userId} and reads the 201', () async {
    final (sent, answer) = await _ask(
      (api) => api.sendFriendRequest('tok', ' u-ravi '),
      _ok({'requestId': 900, 'friendStatus': 'PENDING_SENT'}, 201),
    );
    expect(sent.method, 'POST');
    expect(sent.url.path, '/api/friends/requests');
    expect(sent.headers['Authorization'], 'Bearer tok');
    expect(jsonDecode(sent.body), {'userId': 'u-ravi'});
    expect(answer.requestId, '900');
    expect(answer.friendStatus, FriendStatus.pendingSent);
  });

  test('a request refused carries its code, and the other player\'s request '
      'when they asked first', () async {
    final received = await _refused(
      (api) => api.sendFriendRequest('tok', 'u-ravi'),
      refusal('request_already_received', 409, requestId: 41),
    );
    expect(received, isA<FriendRefusal>());
    expect(received.code, 'request_already_received');
    expect((received as FriendRefusal).requestId, '41');
    for (final (code, status) in [
      ('invalid_player_id', 400),
      ('self_request', 400),
      ('player_not_found', 404),
      ('already_friends', 409),
      ('request_already_sent', 409),
    ]) {
      final e = await _refused(
        (api) => api.sendFriendRequest('tok', 'u-ravi'),
        refusal(code, status),
      );
      expect(e.code, code);
      expect(e.status, status);
      expect((e as FriendRefusal).requestId, isNull);
    }
  });

  test('POST /api/friends/requests/{id}/accept reads the new friend', () async {
    final (sent, friend) = await _ask(
      (api) => api.acceptFriendRequest('tok', '41'),
      _ok({'friend': friendJson('u-ravi', 'Ravi', status: 'ONLINE')}),
    );
    expect(sent.method, 'POST');
    expect(sent.url.path, '/api/friends/requests/41/accept');
    expect(sent.headers['Authorization'], 'Bearer tok');
    expect(friend.userId, 'u-ravi');
    expect(friend.presence.isOnline, isTrue);
    for (final (code, status) in [
      ('request_not_found', 404),
      ('request_not_pending', 409),
    ]) {
      final e = await _refused(
        (api) => api.acceptFriendRequest('tok', '41'),
        refusal(code, status),
      );
      expect(e.code, code);
      expect(e.status, status);
    }
  });

  test('POST /api/friends/requests/{id}/reject', () async {
    final (sent, answer) = await _ask(
      (api) => api.rejectFriendRequest('tok', '42'),
      _ok({'requestId': 42, 'status': 'REJECTED'}),
    );
    expect(sent.method, 'POST');
    expect(sent.url.path, '/api/friends/requests/42/reject');
    expect(sent.headers['Authorization'], 'Bearer tok');
    expect(answer.requestId, '42');
    expect(answer.status, 'REJECTED');
    final e = await _refused(
      (api) => api.rejectFriendRequest('tok', '42'),
      refusal('request_not_pending', 409),
    );
    expect(e.code, 'request_not_pending');
  });

  test('DELETE /api/friends/{friendUserId}', () async {
    final (sent, removed) = await _ask(
      (api) => api.removeFriend('tok', 'u-meera'),
      _ok({'removed': true}),
    );
    expect(sent.method, 'DELETE');
    expect(sent.url.path, '/api/friends/u-meera');
    expect(sent.headers['Authorization'], 'Bearer tok');
    expect(removed, isTrue);
    final e = await _refused(
      (api) => api.removeFriend('tok', 'u-meera'),
      refusal('not_friends', 404),
    );
    expect(e.code, 'not_friends');
    expect(e.status, 404);
  });

  test('the limiter\'s refusal comes through by its code', () async {
    final e = await _refused(
      (api) => api.sendFriendRequest('tok', 'u-ravi'),
      _ok({'error': 'rate_limited'}, 429),
    );
    expect(e.code, 'rate_limited');
    expect(e.status, 429);
  });
}
