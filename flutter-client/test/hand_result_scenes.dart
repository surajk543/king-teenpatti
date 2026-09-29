// The end of a Teen Patti hand won with each kind of hand, as the server
// tells it — the reveal, the result and the settled table, the reveals
// carrying `category` as the Go server sends it — for the hand-result
// animations' tests (hand_result_test.dart) and pictures
// (hand_result_shots.dart). Not a test file.
import 'package:flutter/foundation.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/state/game_state.dart';

const resultIds = ['u0', 'u1', 'u2', 'u3', 'u4'];
const resultNames = ['Priya', 'Ravi', 'Meera', 'Arjun', 'Kavya'];

/// A hand the server has named: its cards, its name and its category
/// (HIGH_CARD 0 … TRAIL 5), and on a variation table the wild cards, the
/// hand as counted and, under 5-Card, the three that played.
typedef ResultHand = ({
  List<String> cards,
  String name,
  int category,
  List<String> wild,
  List<String> playsAs,
  List<String> best,
});

ResultHand hand(
  List<String> cards,
  String name,
  int category, {
  List<String> wild = const [],
  List<String> playsAs = const [],
  List<String> best = const [],
}) => (
  cards: cards,
  name: name,
  category: category,
  wild: wild,
  playsAs: playsAs,
  best: best,
);

/// The owner's five hands (29 Sep 2026), and a High Card.
final pairHand = hand(['7s', '7h', 'Kc'], 'Pair', 1);
final colorHand = hand(['2s', '6s', '9s'], 'Color', 2);
final sequenceHand = hand(['4s', '5h', '6c'], 'Sequence', 3);
final pureSequenceHand = hand(['4s', '5s', '6s'], 'Pure Sequence', 4);
final trailHand = hand(['As', 'Ah', 'Ad'], 'Trail', 5);
final highCardHand = hand(['Kd', '9c', '2h'], 'High Card', 0);

/// Every level's hand, weakest first, with its name for the pictures.
final resultHands = <String, ResultHand>{
  'pair': pairHand,
  'color': colorHand,
  'sequence': sequenceHand,
  'pure-sequence': pureSequenceHand,
  'trail': trailHand,
};

/// The other hand shown down: high cards none of the hands above hold.
final beatenHand = hand(['Qc', '8d', '3h'], 'High Card', 0);

int get _now => DateTime.now().millisecondsSinceEpoch;

/// The table at [handNo]: [places] seats, the viewer (u0) in seat 0, the
/// players in [inHand] still in the hand and everyone else packed. [cards]
/// is the viewer's own hand (face up: they have looked).
RoomState resultRoom({
  int handNo = 7,
  int places = 5,
  String state = 'betting',
  List<String> inHand = const ['u0', 'u3'],
  Map<String, String> status = const {},
  List<String> cards = const ['Qc', '8d', '3h'],
  int cardCount = 3,
  int pot = 13400,
  String category = 'seen',
  bool blind = false,
}) {
  String statusOf(String id) =>
      status[id] ?? (inHand.contains(id) ? 'active' : 'packed');
  return RoomState.fromJson({
    'roomId': 'r1',
    'code': 'ABCD2345',
    'category': category,
    'chipsHidden': category != 'seen',
    'state': state,
    'handNo': handNo,
    'dealerSeat': 1,
    'maxPlayers': places,
    'minPlayers': 2,
    'bootAmount': 200,
    'turnTimeoutMs': 25000,
    'startsAt': 0,
    'pot': pot,
    'maxPot': category == 'seen' ? 2000000 : 0,
    'stake': 400,
    'turn': {'seatIndex': -1, 'userId': null, 'deadline': 0},
    'you': {
      'seatIndex': 0,
      'chips': 245000,
      'status': statusOf('u0'),
      'isBlind': blind,
      'blindMovesLeft': blind ? 4 : 0,
      'contributed': 3400,
      'missedTurns': 0,
      'maxMissedTurns': 3,
      'cards': blind ? const <String>[] : cards,
      'canMissile': false,
    },
    'seats': [
      for (var i = 0; i < places; i++)
        {
          'seatIndex': i,
          'userId': resultIds[i],
          'displayName': resultNames[i],
          'avatarUrl': null,
          'chips': category == 'seen' || i == 0 ? 500000 : null,
          'status': statusOf(resultIds[i]),
          'isBlind': blind,
          'lastBet': 800,
          'lastAction': statusOf(resultIds[i]) == 'packed' ? 'pack' : 'chaal',
          'contributed': 3400,
          'connected': true,
          'cardCount': cardCount,
        },
    ],
  });
}

Reveal _reveal(String id, ResultHand h, {required bool won}) =>
    Reveal.fromJson({
      'userId': id,
      'seatIndex': resultIds.indexOf(id),
      'displayName': resultNames[resultIds.indexOf(id)],
      'cards': h.cards,
      'handName': h.name,
      'category': h.category,
      'won': won,
      if (h.wild.isNotEmpty) 'wild': h.wild,
      if (h.playsAs.isNotEmpty) 'playsAs': h.playsAs,
      if (h.best.isNotEmpty) 'best': h.best,
    });

List<Reveal> _reveals(String winner, ResultHand won, String loser) => [
  _reveal(winner, won, won: true),
  _reveal(loser, beatenHand, won: false),
];

/// `game:showdown`: the two hands, turned over. No winner yet.
ShowdownNews resultReveal(String winner, ResultHand won, {String? loser}) => (
  reveals: _reveals(winner, won, loser ?? (winner == 'u0' ? 'u3' : 'u0')),
  result: '',
  winnerId: null,
  winnerName: '',
  pot: 0,
  nextHandAt: 0,
  reason: 'show',
);

/// `game:handEnded`: who took the pot, and when the next hand is due.
ShowdownNews resultEnded(
  String winner,
  ResultHand won, {
  String? loser,
  int nextInMs = 6000,
}) {
  final name = resultNames[resultIds.indexOf(winner)];
  return (
    reveals: _reveals(winner, won, loser ?? (winner == 'u0' ? 'u3' : 'u0')),
    result: '$name won 13400',
    winnerId: winner,
    winnerName: name,
    pot: 13400,
    nextHandAt: _now + nextInMs,
    reason: 'show',
  );
}

/// The table once the pot is paid: the winner `won`, the other hand `lost`.
RoomState resultSettled(
  String winner, {
  String? loser,
  int places = 5,
  List<String> cards = const ['Qc', '8d', '3h'],
  int cardCount = 3,
  String category = 'seen',
}) {
  final beaten = loser ?? (winner == 'u0' ? 'u3' : 'u0');
  return resultRoom(
    state: 'waiting',
    places: places,
    inHand: [winner, beaten],
    status: {winner: 'won', beaten: 'lost'},
    cards: cards,
    cardCount: cardCount,
    pot: 0,
    category: category,
  );
}

/// The next hand, dealt: every seat in, blind, nobody's cards showing.
RoomState resultNextDeal({int places = 5}) => resultRoom(
  handNo: 8,
  places: places,
  blind: true,
  inHand: resultIds.take(places).toList(),
  pot: 200 * places,
);

/// A GameState seated as Priya (u0) at a table of [places].
GameState resultState({AppLang lang = AppLang.english, int places = 5}) {
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
      'chips': 245000,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
    })
    ..screen = Screen.table;
  state.config = state.config.copyWith(maxPlayers: places);
  return state;
}
