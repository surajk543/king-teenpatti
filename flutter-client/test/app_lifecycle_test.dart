// A locked or backgrounded phone keeps its way back (owner, 27 Sep 2026).
//
// The app used to ignore its lifecycle: a phone locked at a table kept its
// socket, so the server saw a connected player who never moved and idle-
// kicked them three turn clocks later with no resume offer. Now, paused while
// seated, the app closes its socket after [GameState.backgroundGrace] — the
// server's reconnect grace starts, and the seat is held or offered back — and
// connects again when it is resumed; the warm session:ready then puts the
// player back (the held seat's room:joined, or the resume offer).
//
// Pinned here: paused while seated → the socket closes after the delay, and
// not before; resumed within it → nothing at all; resumed after → one
// reconnect with the session's token; the lobby → nothing; `inactive` and
// `hidden` → nothing; a Play purchase in flight (its sheet open, or its
// receipt being banked) → the socket stays up for as long as it lasts, and
// closes on the next check once it is over; signed out while away → no
// reconnect.
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/state/game_state.dart';

import 'table_scenes.dart';

/// A socket that records what the lifecycle asks of it.
class _Socket extends GameConnection {
  _Socket() : super('http://127.0.0.1:9');

  final connects = <String>[];
  int disconnects = 0;

  @override
  void connect(String token) => connects.add(token);

  @override
  void disconnect() => disconnects++;
}

GameState _state(_Socket socket, {bool seated = true}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9', connection: socket);
  debugDefaultTargetPlatformOverride = null;
  state
    ..debugToken = 'token-1'
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Priya',
      'chips': 245000,
    });
  if (seated) {
    state
      ..screen = Screen.table
      ..handleState(opponentTurnRoom());
  } else {
    state.screen = Screen.lobby;
  }
  return state;
}

PurchaseDetails _purchase(String token, PurchaseStatus status) =>
    PurchaseDetails(
      purchaseID: token,
      productID: 'chips_small',
      verificationData: PurchaseVerificationData(
        localVerificationData: token,
        serverVerificationData: token,
        source: 'google_play',
      ),
      transactionDate: '0',
      status: status,
    );

/// Past the delay by a whisker.
final _past = GameState.backgroundGrace + const Duration(milliseconds: 1);

void main() {
  testWidgets('paused while seated: the socket closes after the delay, '
      'not before', (tester) async {
    final socket = _Socket();
    final state = _state(socket);
    state.handleLifecycle(AppLifecycleState.inactive);
    state.handleLifecycle(AppLifecycleState.hidden);
    state.handleLifecycle(AppLifecycleState.paused);

    await tester.pump(
      GameState.backgroundGrace - const Duration(milliseconds: 10),
    );
    expect(socket.disconnects, 0, reason: 'not before the delay');
    expect(state.closedForBackground, isFalse);

    await tester.pump(const Duration(milliseconds: 20));
    expect(socket.disconnects, 1);
    expect(state.closedForBackground, isTrue);
    expect(state.offline, isTrue, reason: 'the reconnecting veil on return');
    expect(
      state.room,
      isNotNull,
      reason:
          'the table stays until the server '
          'says where the player stands',
    );

    // Nothing more while it stays in the background.
    await tester.pump(const Duration(minutes: 5));
    expect(socket.disconnects, 1);
    expect(socket.connects, isEmpty);
    state.dispose();
  });

  testWidgets('resumed within the delay: nothing happens at all', (
    tester,
  ) async {
    final socket = _Socket();
    final state = _state(socket);
    state.handleLifecycle(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 3));
    state.handleLifecycle(AppLifecycleState.hidden);
    state.handleLifecycle(AppLifecycleState.inactive);
    state.handleLifecycle(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 30));
    expect(socket.disconnects, 0);
    expect(socket.connects, isEmpty);
    expect(state.closedForBackground, isFalse);
    state.dispose();
  });

  testWidgets('resumed after the delay: one reconnect with the session', (
    tester,
  ) async {
    final socket = _Socket();
    final state = _state(socket);
    state.handleLifecycle(AppLifecycleState.paused);
    await tester.pump(_past);
    expect(socket.disconnects, 1);

    state.handleLifecycle(AppLifecycleState.inactive);
    expect(socket.connects, isEmpty, reason: 'inactive is not back yet');
    state.handleLifecycle(AppLifecycleState.resumed);
    expect(socket.connects, ['token-1']);
    expect(state.closedForBackground, isFalse);

    // A second resume (the platform repeats itself) connects nothing more.
    state.handleLifecycle(AppLifecycleState.resumed);
    expect(socket.connects, ['token-1']);
    state.dispose();
  });

  testWidgets('in the lobby: nothing, however long the phone is away', (
    tester,
  ) async {
    final socket = _Socket();
    final state = _state(socket, seated: false);
    state.handleLifecycle(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 2));
    state.handleLifecycle(AppLifecycleState.resumed);
    expect(socket.disconnects, 0);
    expect(socket.connects, isEmpty);
    state.dispose();
  });

  testWidgets('inactive alone — a shade, a system dialog — does nothing', (
    tester,
  ) async {
    final socket = _Socket();
    final state = _state(socket);
    state.handleLifecycle(AppLifecycleState.inactive);
    await tester.pump(const Duration(minutes: 1));
    state.handleLifecycle(AppLifecycleState.resumed);
    expect(socket.disconnects, 0);
    expect(socket.connects, isEmpty);
    state.dispose();
  });

  testWidgets('a Play purchase sheet open keeps the socket up', (tester) async {
    final socket = _Socket();
    final state = _state(socket);
    state.purchases.debugStartBuying();
    expect(state.purchaseInFlight, isTrue);
    state.handleLifecycle(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 40));
    expect(socket.disconnects, 0, reason: 'the sheet is still open');
    state.handleLifecycle(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 40));
    expect(socket.disconnects, 0);
    expect(socket.connects, isEmpty);
    state.dispose();
  });

  // A purchase Play reports as PENDING (a slow payment such as UPI) can stay
  // pending for days or be abandoned and never reported again; it must not
  // hold a seated phone's socket open, or putting the phone away brings back
  // the idle kick with no way back. Its receipt is banked over REST, which
  // needs no socket (verifier's finding, 27 Sep 2026).
  testWidgets('a pending purchase does not keep the socket up', (tester) async {
    final socket = _Socket();
    final state = _state(socket);
    state.purchasePending = true;
    state.handleLifecycle(AppLifecycleState.paused);
    await tester.pump(_past);
    expect(socket.disconnects, 1, reason: 'closed after the delay as usual');
    expect(state.purchasePending, isTrue, reason: 'the purchase itself waits');
    state.handleLifecycle(AppLifecycleState.resumed);
    expect(socket.connects, ['token-1']);
    state.dispose();
  });

  testWidgets('a pending purchase Play never completes does not hold the '
      'socket for the rest of the session', (tester) async {
    final socket = _Socket();
    final state = _state(socket);
    // Wired as GameState._startPurchases wires it (start() is not run here).
    state.purchases.onPending = () => state.purchasePending = true;
    await state.purchases.handle([_purchase('tok', PurchaseStatus.pending)]);
    expect(state.purchasePending, isTrue);
    // Abandoned: Play reports it cancelled, which clears nothing.
    await state.purchases.handle([_purchase('tok', PurchaseStatus.canceled)]);
    state.handleLifecycle(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 30));
    expect(socket.disconnects, 1);
    state.dispose();
  });

  testWidgets('the table left while the delay ran: nothing to close', (
    tester,
  ) async {
    final socket = _Socket();
    final state = _state(socket);
    state.handleLifecycle(AppLifecycleState.paused);
    state.room = null;
    await tester.pump(_past);
    expect(socket.disconnects, 0);
    state.dispose();
  });

  testWidgets('signed out while away: no reconnect', (tester) async {
    final socket = _Socket();
    final state = _state(socket);
    state.handleLifecycle(AppLifecycleState.paused);
    await tester.pump(_past);
    expect(socket.disconnects, 1);
    state.debugToken = null;
    state.handleLifecycle(AppLifecycleState.resumed);
    expect(socket.connects, isEmpty);
    state.dispose();
  });
}
