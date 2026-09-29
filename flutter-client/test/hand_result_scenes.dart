// The viewer's own look at a Teen Patti hand, as the server tells it — the
// hand dealt with the viewer blind, then their cards face up (the answer to
// their tap on See cards, or the reveal the fourth blind bet forces), and at a
// Variation table the server's own `you.hand` once the variation is chosen —
// and the end of a hand shown down, for the hand-result animations' tests
// (hand_result_test.dart) and pictures (hand_result_shots.dart). Not a test
// file.
import 'package:flutter/foundation.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/state/game_state.dart';

const resultIds = ['u0', 'u1', 'u2', 'u3', 'u4'];
const resultNames = ['Priya', 'Ravi', 'Meera', 'Arjun', 'Kavya'];

/// A hand: its cards, its name and its category as the server ranks it
/// (HIGH_CARD 0 … TRAIL 5), and on a variation table the wild cards, the hand
/// as counted and, under 5-Card, the three that played.
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

/// Every hand the viewer may look at, High Card included.
final lookHands = <String, ResultHand>{
  'high-card': highCardHand,
  ...resultHands,
};

/// The cards of [h] that its look lights: the pair of a Pair, all three of a
/// Color, a Sequence, a Pure Sequence or a Trail, none of a High Card.
List<String> litOf(ResultHand h) => switch (h.category) {
  0 => const [],
  1 => h.cards.take(2).toList(),
  _ => h.cards,
};

/// The other hand shown down: high cards none of the hands above hold.
final beatenHand = hand(['Qc', '8d', '3h'], 'High Card', 0);

int get _now => DateTime.now().millisecondsSinceEpoch;

/// The viewer's own `you.hand` as the server sends it at a Variation table
/// once they have looked and the variation is chosen: what [h] made, its wild
/// cards, the hand as counted and the three that count. While [picking] (a
/// 5-Card choice owed) it names nothing, as the server's does not.
Map<String, dynamic> ownHandOf(
  ResultHand h, {
  bool picking = false,
  String pickedBy = '',
}) => picking
    ? {
        'handName': '',
        'category': 0,
        'wild': const <String>[],
        'playsAs': h.cards,
        'best': const <String>[],
        'picking': true,
        'pickDeadline': _now + 8000,
        'pickTimeoutMs': 8000,
      }
    : {
        'handName': h.name,
        'category': h.category,
        'wild': h.wild,
        'playsAs': h.playsAs.isEmpty ? h.cards : h.playsAs,
        'best': h.best.isEmpty ? h.cards : h.best,
        if (pickedBy.isNotEmpty) 'pickedBy': pickedBy,
        if (pickedBy.isNotEmpty) 'bestPossible': h.best,
      };

/// A Variation table's `variation` block: the window open (no [selected]) or
/// [selected] by its chooser (Meera, seat 2), with [turnUp] for Joker and
/// Hukam.
Map<String, dynamic> variationBlock({
  String? selected,
  String selectedBy = 'PLAYER',
  String? turnUp,
}) => {
  'selecting': selected == null,
  'userId': 'u2',
  'displayName': 'Meera',
  'seatIndex': 2,
  'startedAt': _now,
  'deadline': _now + 10000,
  'timeoutMs': 10000,
  'options': Variation.all,
  'selected': selected,
  'selectedBy': selected == null ? null : selectedBy,
  'turnUp': ?turnUp,
  'cardsPerPlayer': selected == Variation.fiveCard ? 5 : 3,
};

/// The table at [handNo]: [places] seats, the viewer (u0) in seat 0, the
/// players in [inHand] still in the hand and everyone else packed. [cards]
/// is the viewer's own hand, face up unless [blind]; [ownHand] their
/// `you.hand` and [variation] the table's variation block at a Variation
/// table.
RoomState resultRoom({
  String roomId = 'r1',
  int handNo = 7,
  int places = 5,
  String state = 'betting',
  List<String> inHand = const ['u0', 'u3'],
  Map<String, String> status = const {},
  List<String> cards = const ['Qc', '8d', '3h'],
  int cardCount = 3,
  int pot = 13400,
  String category = 'seen',
  bool isPrivate = false,
  bool blind = false,
  int blindMovesLeft = 0,
  Map<String, dynamic>? ownHand,
  Map<String, dynamic>? variation,
}) {
  String statusOf(String id) =>
      status[id] ?? (inHand.contains(id) ? 'active' : 'packed');
  return RoomState.fromJson({
    'roomId': roomId,
    'code': 'ABCD2345',
    'isPrivate': isPrivate,
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
    'variation': ?variation,
    'you': {
      'seatIndex': 0,
      'chips': 245000,
      'status': statusOf('u0'),
      'isBlind': blind,
      'blindMovesLeft': blind ? (blindMovesLeft == 0 ? 4 : blindMovesLeft) : 0,
      'contributed': 3400,
      'missedTurns': 0,
      'maxMissedTurns': 3,
      'cards': blind ? const <String>[] : cards,
      'hand': ?ownHand,
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

List<Reveal> _reveals(
  String winner,
  ResultHand won,
  String loser,
  ResultHand beaten,
) => [_reveal(winner, won, won: true), _reveal(loser, beaten, won: false)];

/// `game:showdown`: the two hands, turned over. No winner yet.
ShowdownNews resultReveal(
  String winner,
  ResultHand won, {
  String? loser,
  ResultHand? beaten,
  String reason = 'show',
}) => (
  reveals: _reveals(
    winner,
    won,
    loser ?? (winner == 'u0' ? 'u3' : 'u0'),
    beaten ?? beatenHand,
  ),
  result: '',
  winnerId: null,
  winnerName: '',
  pot: 0,
  nextHandAt: 0,
  reason: reason,
);

/// `game:handEnded`: who took the pot, and when the next hand is due.
ShowdownNews resultEnded(
  String winner,
  ResultHand won, {
  String? loser,
  ResultHand? beaten,
  int nextInMs = 6000,
  String reason = 'show',
}) {
  final name = resultNames[resultIds.indexOf(winner)];
  return (
    reveals: _reveals(
      winner,
      won,
      loser ?? (winner == 'u0' ? 'u3' : 'u0'),
      beaten ?? beatenHand,
    ),
    result: '$name won 13400',
    winnerId: winner,
    winnerName: name,
    pot: 13400,
    nextHandAt: _now + nextInMs,
    reason: reason,
  );
}

/// The table once the pot is paid: the winner `won`, the other hand `lost`;
/// the viewer's own cards face up unless they played the hand [blind].
RoomState resultSettled(
  String winner, {
  String? loser,
  int places = 5,
  List<String> cards = const ['Qc', '8d', '3h'],
  int cardCount = 3,
  String category = 'seen',
  bool blind = false,
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
    blind: blind,
  );
}

/// The next hand, dealt: every seat in, blind, nobody's cards showing.
RoomState resultNextDeal({int places = 5, String category = 'seen'}) =>
    resultRoom(
      handNo: 8,
      places: places,
      blind: true,
      inHand: resultIds.take(places).toList(),
      pot: 200 * places,
      category: category,
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
