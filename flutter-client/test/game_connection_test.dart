import 'package:flutter_test/flutter_test.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:teenpatti/net/game_connection.dart';

/// The connection options are what make a `session:redirect` work at all.
///
/// socket_io_client caches one `Manager` per scheme://host:port and, because
/// the server URL carries no path, hands that same Manager back for every
/// later `io()` call — built with the FIRST path and token it ever saw. A
/// redirect to `/w2/socket.io` would then reconnect on the old path, and a
/// sign-in as another account would reuse the first token. `forceNew` is the
/// one option that opts out of the cache, so these tests pin it, and check —
/// without opening a network connection (`autoConnect: false`) — that the
/// Manager a redirected connection gets really is built for the new path: the
/// engine derives its handshake URL from `Manager.options['path']`.
void main() {
  const url = 'https://api.example.test';

  io.Socket open(String token, {String? path}) => io.io(url, {
        ...GameConnection.buildOptions(token, path: path),
        'autoConnect': false,
      });

  group('GameConnection.buildOptions', () {
    test('carries the token, the worker path and forceNew', () {
      final options = GameConnection.buildOptions('tok', path: '/w2/socket.io');
      expect(options['forceNew'], isTrue, reason: 'opts out of the per-host Manager cache');
      expect(options['path'], '/w2/socket.io');
      expect(options['auth'], {'token': 'tok'});
      expect(options['transports'], ['websocket']);
      // enableReconnection() removes the key: on is the library's default.
      expect(options['reconnection'], isNot(false));
    });

    test('leaves the path unset for the server default', () {
      expect(GameConnection.buildOptions('tok').containsKey('path'), isFalse);
      expect(GameConnection.buildOptions('tok', path: '').containsKey('path'), isFalse);
    });
  });

  group('following a redirect', () {
    test('opens a fresh Manager on the new path with the same host', () {
      // Cold start on the remembered worker, then a redirect to another one.
      final first = open('tok', path: '/w1/socket.io');
      final second = open('tok', path: '/w2/socket.io');
      addTearDown(() {
        first.dispose();
        second.dispose();
      });

      expect(second.io, isNot(same(first.io)), reason: 'the cached Manager must not be reused');
      expect(first.io.options?['path'], '/w1/socket.io');
      expect(second.io.options?['path'], '/w2/socket.io',
          reason: 'the next handshake goes to /w2/socket.io/');
    });

    test('a fallback to the default path does not inherit the failed one', () {
      final pinned = open('tok', path: '/w3/socket.io');
      final fallback = open('tok');
      addTearDown(() {
        pinned.dispose();
        fallback.dispose();
      });

      expect(fallback.io, isNot(same(pinned.io)));
      expect(fallback.io.options?['path'], '/socket.io', reason: "the library's default path");
    });

    test('a new sign-in connects with its own token', () {
      final alice = open('alice-token');
      final bob = open('bob-token');
      addTearDown(() {
        alice.dispose();
        bob.dispose();
      });

      expect(bob.io, isNot(same(alice.io)));
      expect(bob.io.options?['auth'], {'token': 'bob-token'});
    });
  });
}
