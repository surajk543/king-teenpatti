// A sign-in that never got an answer names the kind of failure, so a report
// from a phone reads "certificate not trusted" or "DNS" instead of the one
// line every cause used to share — "Could not reach the server. Is it
// running?" — which on 10 Sep 2026 sent a day of investigation at a healthy
// server.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/net/connection_failure.dart';

void main() {
  const server = 'https://api.sungamestudio.com';

  test("a TLS handshake failure blames the phone's trust store", () {
    final s = describeConnectionFailure(
      const HandshakeException('Handshake error in client'),
      server,
    );
    expect(s, contains('certificate'));
    expect(s, contains('api.sungamestudio.com'));
  });

  test('a failed host lookup is named as DNS', () {
    final s = describeConnectionFailure(
      const SocketException("Failed host lookup: 'api.sungamestudio.com'"),
      server,
    );
    expect(s, contains('look up'));
    expect(s, contains('api.sungamestudio.com'));
  });

  test('a refused connection carries the OS reason', () {
    final s = describeConnectionFailure(
      const SocketException(
        'Connection failed',
        osError: OSError('Connection refused', 111),
      ),
      server,
    );
    expect(s, contains('Connection refused'));
  });

  test('a timeout says so', () {
    expect(
      describeConnectionFailure(TimeoutException('no answer'), server),
      contains('did not answer'),
    );
  });

  test('a non-JSON answer points at a proxy or captive portal', () {
    expect(
      describeConnectionFailure(
        const FormatException('Unexpected character'),
        server,
      ),
      contains('not JSON'),
    );
  });

  test('anything else keeps its type so it can be searched for', () {
    expect(
      describeConnectionFailure(StateError('boom'), server),
      contains('StateError'),
    );
  });
}
