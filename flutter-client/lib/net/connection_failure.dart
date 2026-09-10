import 'dart:async';
import 'dart:io';

/// One readable line for why a request never produced an answer.
///
/// The login screen used to answer every such failure with "Could not reach
/// the server. Is it running?" — true for a dead server and equally true for
/// a phone whose VPN intercepts HTTPS, whose DNS cannot resolve the host, or
/// which is behind a captive portal, and those need different fixes by
/// different people. On 10 Sep 2026 that one line sent a day of investigation
/// at a healthy server. This names the kind of failure instead; the exception
/// class is the fact, the sentence is what to do with it.
///
/// Pure: no I/O, no localisation, unit-tested in
/// test/connection_failure_test.dart.
String describeConnectionFailure(Object error, String serverUrl) {
  final host = Uri.tryParse(serverUrl)?.host ?? serverUrl;
  if (error is HandshakeException) {
    return 'This phone does not trust the certificate $host presented. '
        'A VPN, proxy or corporate Wi-Fi that inspects HTTPS does this: '
        'the browser trusts it, apps do not. Try mobile data.';
  }
  if (error is SocketException) {
    if (error.message.contains('Failed host lookup')) {
      return 'Could not look up $host (DNS). Try mobile data or another network.';
    }
    final reason = error.osError?.message ?? error.message;
    return 'Could not connect to $host: $reason.';
  }
  if (error is TimeoutException) {
    return '$host did not answer in time.';
  }
  if (error is FormatException) {
    return 'The answer from $host was not JSON. A captive portal or proxy '
        'answered instead of the game server.';
  }
  return '${error.runtimeType}: $error';
}
