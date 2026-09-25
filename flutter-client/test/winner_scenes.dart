// The end of a Teen Patti hand, as the server tells it: a show between the
// viewer and one opponent, the reveal, the result, the settled table and the
// next deal — for the celebration's tests (winner_flow_test.dart) and its
// pictures (winner_shots.dart). Not a test file.
import 'package:flutter/foundation.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/state/game_state.dart';

const winnerIds = ['u0', 'u1', 'u2', 'u3', 'u4'];
const winnerNames = ['Priya', 'Ravi', 'Meera', 'Arjun', 'Kavya'];

/// Every seat's stack before the hand's end, and what each put in.
const winnerStacks = [245000, 1820000, 96000, 530000, 12500000];
const winnerContributed = [3400, 1400, 2600, 3400, 1800];

/// The hands the show turns over: the viewer's pair of sevens, and Arjun's
/// run when he takes the pot or his nine-high when the viewer does.
const winnerCards = {
  'u0': ['7s', '7d', 'Kc'],
  'u3': ['Qs', 'Js', 'Ts'],
};
const _arjunBeaten = ['9h', '8h', '2c'];

List<String> _cardsOf(String id, String winner) =>
    id == 'u3' && winner != 'u3' ? _arjunBeaten : winnerCards[id]!;

String _handOf(String id, String winner) => id == 'u0'
    ? 'Pair'
    : winner == 'u3'
    ? 'Pure Sequence'
    : 'High Card';

/// The pot before the show is paid, and the show's price.
const winnerPotBefore = 12600;
const winnerShowCost = 800;
const winnerPot = winnerPotBefore + winnerShowCost;

int get _now => DateTime.now().millisecondsSinceEpoch;

/// The table at [handNo]: a seen table of five, the viewer (u0) in seat 0,
/// Ravi, Meera and Kavya packed, the viewer and Arjun still in. [status]
/// overrides a seat's status by user id, [chips] and [contributed] its stack
/// and its money in, [turn] who is on turn.
RoomState winnerRoom({
  int handNo = 7,
  String state = 'betting',
  String? turn = 'u0',
  int pot = winnerPotBefore,
  Map<String, String> status = const {},
  Map<String, int> chips = const {},
  Map<String, int> contributed = const {},
  bool blind = false,
  int cardCount = 3,
  String category = 'seen',
}) {
  String statusOf(String id) =>
      status[id] ??
      (const ['u1', 'u2', 'u4'].contains(id) ? 'packed' : 'active');
  int chipsOf(int i) => chips[winnerIds[i]] ?? winnerStacks[i];
  int inOf(int i) => contributed[winnerIds[i]] ?? winnerContributed[i];
  final onTurn = turn == 'u0' && state == 'betting';
  return RoomState.fromJson({
    'roomId': 'r1',
    'code': 'ABCD2345',
    'category': category,
    'chipsHidden': category != 'seen',
    'state': state,
    'handNo': handNo,
    'dealerSeat': 2,
    'maxPlayers': 5,
    'minPlayers': 2,
    'bootAmount': 200,
    'turnTimeoutMs': 25000,
    'startsAt': 0,
    'pot': pot,
    'maxPot': 2000000,
    'stake': 400,
    'turn': turn == null || state != 'betting'
        ? {'seatIndex': -1, 'userId': null, 'deadline': 0}
        : {
            'seatIndex': winnerIds.indexOf(turn),
            'userId': turn,
            'deadline': _now + 20000,
          },
    'you': {
      'seatIndex': 0,
      'chips': chipsOf(0),
      'status': statusOf('u0'),
      'isBlind': blind,
      'blindMovesLeft': 0,
      'contributed': inOf(0),
      'missedTurns': 0,
      'maxMissedTurns': 3,
      'cards': blind ? const <String>[] : winnerCards['u0'],
      'canMissile': false,
      if (onTurn)
        'options': {
          'canSee': false,
          'canPack': true,
          'canSideshow': false,
          'raiseSteps': [800, 1600],
          'show': winnerShowCost,
          'chips': chipsOf(0),
          'currentStake': 400,
        },
    },
    'seats': [
      for (final (i, id) in winnerIds.indexed)
        {
          'seatIndex': i,
          'userId': id,
          'displayName': winnerNames[i],
          'avatarUrl': null,
          'chips': category == 'seen' || i == 0 ? chipsOf(i) : null,
          'status': statusOf(id),
          'isBlind': blind,
          'lastBet': 800,
          'lastAction': statusOf(id) == 'packed' ? 'pack' : 'chaal',
          'contributed': inOf(i),
          'connected': true,
          'cardCount': cardCount,
        },
    ],
  });
}

/// The viewer pays for the show: their bet goes into the pot.
RoomState winnerShowPaid() => winnerRoom(
  turn: null,
  pot: winnerPot,
  chips: {'u0': winnerStacks[0] - winnerShowCost},
  contributed: {'u0': winnerContributed[0] + winnerShowCost},
);

Reveal _reveal(String id, String winner) => Reveal.fromJson({
  'userId': id,
  'seatIndex': winnerIds.indexOf(id),
  'displayName': winnerNames[winnerIds.indexOf(id)],
  'cards': _cardsOf(id, winner),
  'handName': _handOf(id, winner),
  'won': id == winner,
});

/// `game:showdown`: the two hands, turned over. No winner yet — the server
/// names the winner in `game:handEnded`, a moment later.
ShowdownNews winnerReveal(String winner) => (
  reveals: [for (final id in winnerCards.keys) _reveal(id, winner)],
  result: '',
  winnerId: null,
  winnerName: '',
  pot: 0,
  nextHandAt: 0,
  reason: 'show',
);

/// `game:handEnded`: who took the pot, and when the next hand is due.
ShowdownNews winnerEnded(
  String winner, {
  int nextInMs = 4000,
  bool revealed = true,
}) {
  final name = winnerNames[winnerIds.indexOf(winner)];
  return (
    reveals: revealed
        ? [for (final id in winnerCards.keys) _reveal(id, winner)]
        : const [],
    result: '$name won $winnerPot',
    winnerId: winner,
    winnerName: name,
    pot: winnerPot,
    nextHandAt: _now + nextInMs,
    reason: revealed ? 'show' : 'last_standing',
  );
}

/// The table as the server leaves it once the pot is paid: the winner `won`
/// with the pot on their stack, the other hand shown down `lost`, nobody on
/// turn and nothing in the pot.
RoomState winnerSettled(String winner, {bool revealed = true}) {
  final loser = winner == 'u0' ? 'u3' : 'u0';
  final w = winnerIds.indexOf(winner);
  final paid = w == 0 ? winnerStacks[0] - winnerShowCost : winnerStacks[w];
  return winnerRoom(
    state: 'waiting',
    turn: null,
    pot: 0,
    status: {winner: 'won', loser: revealed ? 'lost' : 'packed'},
    chips: {'u0': winnerStacks[0] - winnerShowCost, winner: paid + winnerPot},
    contributed: {'u0': winnerContributed[0] + winnerShowCost},
  );
}

/// The next hand, dealt: every seat in, blind, each boot in the pot.
RoomState winnerNextDeal(String winner) {
  final w = winnerIds.indexOf(winner);
  return winnerRoom(
    handNo: 8,
    turn: 'u1',
    pot: 1000,
    blind: true,
    status: {for (final id in winnerIds) id: 'active'},
    chips: {
      for (final (i, id) in winnerIds.indexed)
        id:
            (i == 0 ? winnerStacks[0] - winnerShowCost : winnerStacks[i]) +
            (i == w ? winnerPot : 0) -
            200,
    },
    contributed: {for (final id in winnerIds) id: 200},
  );
}

/// The whole end of the hand in the order the server sends it, applied in
/// one go: the show paid, the reveal, the result and the settled table.
void playShowdown(GameState state, String winner) {
  state
    ..handleState(winnerShowPaid())
    ..handleShowdown(winnerReveal(winner))
    ..handleShowdown(winnerEnded(winner))
    ..handleState(winnerSettled(winner));
}

/// A GameState seated as Priya (u0) at the table before the show.
GameState winnerState({AppLang lang = AppLang.english}) {
  // Play is never started here; the override only keeps the purchase plugin
  // from registering an Android billing client in a test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  state
    ..lang = lang
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Priya',
      'chips': winnerStacks[0],
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
    })
    ..screen = Screen.table
    ..handleState(winnerRoom());
  return state;
}
