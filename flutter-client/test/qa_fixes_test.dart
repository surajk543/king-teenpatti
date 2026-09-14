// Regressions from the four-device QA run of 14 Sep 2026: a table snapshot
// that arrives after a kick, the decline notice, the seen chaal between turns,
// the translated countdown, and the strings those fixes added.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/state/game_state.dart';

/// A table of three, the viewer (u0) in seat 0. [you] false leaves the
/// viewer's own seat out of the snapshot, as a table they are no longer at
/// sends it.
RoomState _room({bool you = true, bool blind = false}) => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': blind ? 'blind' : 'seen',
  'chipsHidden': false,
  'state': 'betting',
  'handNo': 7,
  'dealerSeat': 1,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 1200,
  'maxPot': 2000000,
  'stake': 400,
  'turn': {'seatIndex': 1, 'userId': 'u1', 'deadline': 0},
  if (you)
    'you': {
      'seatIndex': 0,
      'chips': 200000,
      'status': 'active',
      'isBlind': blind,
      'blindMovesLeft': blind ? 4 : 0,
      'contributed': 400,
      'missedTurns': 0,
      'maxMissedTurns': 3,
      'cards': blind ? const [] : const ['As', 'Kd', '4c'],
    },
  'seats': [
    for (var i = 0; i < 3; i++)
      {
        'seatIndex': i,
        'userId': 'u$i',
        'displayName': 'Player $i',
        'avatarUrl': null,
        'chips': 200000,
        'status': 'active',
        'isBlind': blind,
        'lastBet': 400,
        'lastAction': 'chaal',
        'contributed': 400,
        'connected': true,
        'cardCount': 3,
      },
  ],
});

GameState _newState() {
  // Play is never started here; the override only keeps the purchase plugin
  // from registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  state.user = User.fromJson({
    'id': 'u0',
    'provider': 'guest',
    'displayName': 'Player 0',
    'chips': 200000,
    'diamond': 1,
    'hammer': 20,
  });
  return state;
}

void main() {
  test('a snapshot without the viewer\'s seat does not put a table back on '
      'screen after a kick', () {
    final state = _newState()..screen = Screen.lobby;
    state.handleState(_room(you: false));
    expect(state.screen, Screen.lobby);
    expect(state.room, isNull);

    // A table the player is at still comes up as before.
    state.handleState(_room());
    expect(state.screen, Screen.table);
    expect(state.room?.roomId, 'r1');
  });

  test('a declined sideshow is news to the asker, not to the one who '
      'declined', () {
    final asked = _newState()..room = _room();
    asked.handleSideshowDone((
      fromUserId: 'u1',
      toUserId: 'u0',
      accepted: false,
      reason: SideshowReason.declined,
      packedUserId: null,
    ));
    expect(asked.notice, isNull);

    final asker = _newState()..room = _room();
    asker.handleSideshowDone((
      fromUserId: 'u0',
      toUserId: 'u1',
      accepted: false,
      reason: SideshowReason.declined,
      packedUserId: null,
    ));
    expect(asker.notice, asker.t.sideshowDeclined);

    // A request the asked player let lapse is still theirs to hear about.
    final lapsed = _newState()..room = _room();
    lapsed.handleSideshowDone((
      fromUserId: 'u1',
      toUserId: 'u0',
      accepted: false,
      reason: SideshowReason.timeout,
      packedUserId: null,
    ));
    expect(lapsed.notice, lapsed.t.sideshowTimedOut);
  });

  test('between turns the chaal key shows a seen player twice the blind '
      'stake', () {
    final seen = _newState()..room = _room();
    expect(seen.options, isNull);
    expect(seen.betAmount, 800);

    final blind = _newState()..room = _room(blind: true);
    expect(blind.betAmount, 400);
  });

  test('the countdown speaks the player\'s language', () {
    const d = Duration(hours: 3, minutes: 54, seconds: 9);
    expect(formatCountdown(d), '3h 54m 9s');
    expect(formatCountdown(d, const Strings(AppLang.english)), '3h 54m 9s');
    final hindi = formatCountdown(d, const Strings(AppLang.hindi));
    expect(hindi, isNot(contains('h')));
    expect(hindi, startsWith('3'));
    expect(
      formatCountdown(
        const Duration(seconds: 42),
        const Strings(AppLang.hindi),
      ),
      '42${const Strings(AppLang.hindi).unitSecondShort}',
    );
  });

  test('every string the QA fixes added exists in all five languages', () {
    for (final lang in AppLang.values) {
      final t = Strings(lang);
      for (final value in [
        t.signOutQ,
        t.signOutBody,
        t.providerGuest,
        t.unitHourShort,
        t.unitMinuteShort,
        t.unitSecondShort,
        t.handToGo,
        t.forceSideshowTooLate,
      ]) {
        expect(value.trim(), isNotEmpty, reason: lang.code);
        expect(value, isNot(contains('_')), reason: '${lang.code}: $value');
      }
    }
  });
}
