// Every session's socket speaks for that session's account (24 Sep 2026,
// owner's "fix all bugs"; release review B7).
//
// After Delete account → Play as Guest a "Service not available" toast stood
// over the new account's consent panel, with nothing in the server's log but
// "account created". socket_io_client caches one Manager per host and keeps
// its '/' Socket in it, and `io.io()` handed that SAME socket back on the
// next connect — reconnecting it with the auth it was first built with. So
// the new guest's socket presented the deleted account's token, the server
// refused it (connect_error unknown_user), the refusal reached the toast as
// "Could not reach the table: …" (read as "Service not available"), and the
// new account had no live connection at all. A sign-out followed by a sign-in
// as somebody else in the same run of the app did the same with a token that
// still worked: the socket signed in as the PREVIOUS account.
//
// GameConnection now asks for a new connection every time, so each connect
// carries its own token, and an error from a socket that is no longer the
// current one never reaches the player.
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/net/game_connection.dart';

void main() {
  test('a second connect presents its own token on a socket of its own', () {
    // Nothing listens on port 9: the sockets try, fail and are dropped.
    final conn = GameConnection('http://127.0.0.1:9');
    addTearDown(conn.dispose);

    conn.connect('token-of-the-deleted-account');
    final first = conn.debugSocket!;
    expect(first.auth, {'token': 'token-of-the-deleted-account'});

    // Delete account (or sign out), then a new sign-in.
    conn.disconnect();
    conn.connect('token-of-the-new-guest');
    final second = conn.debugSocket!;

    expect(identical(first, second), isFalse);
    expect(second.auth, {'token': 'token-of-the-new-guest'});
  });

  test('a reconnect on the same token is a fresh socket too', () {
    final conn = GameConnection('http://127.0.0.1:9');
    addTearDown(conn.dispose);
    conn.connect('t');
    final first = conn.debugSocket!;
    conn.connect('t');
    expect(identical(first, conn.debugSocket), isFalse);
    expect(conn.debugSocket!.auth, {'token': 't'});
  });
}
