// The table counting down to a deal (29 Sep 2026), built from room:state JSON
// as the server sends it. Not a test file: test/start_countdown_test.dart lays
// these rooms out and test/countdown_shots.dart pictures them.
import 'dart:io';

import 'package:lottie/lottie.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart' show ShowdownNews;

import 'table_scenes.dart' show pokerRoomJson;
import 'package:teenpatti/state/start_countdown.dart';
import 'package:teenpatti/widgets/start_countdown.dart';

const countdownIds = ['u0', 'u1', 'u2', 'u3', 'u4'];
const _names = ['Priya', 'Ravi', 'Meera', 'Arjun', 'Vikramaditya'];

/// The phone's clock the tests keep: a fixed instant they move by hand.
int countdownNow = 1_790_000_000_000;

/// Sets [StartCountdown.clock] to [countdownNow] and returns how to put it
/// back, for a `tearDown`.
void Function() holdCountdownClock() {
  final before = StartCountdown.clock;
  StartCountdown.clock = () => countdownNow;
  return () => StartCountdown.clock = before;
}

/// The owner's countdown, cut and parsed here where async is real, and handed
/// to the art as a value (CLAUDE.md §12.3: never a future made in one test's
/// zone and awaited in another).
void loadCountdownArt() {
  final bytes = File(StartCountdownArt.asset).readAsBytesSync();
  StartCountdownArt.debugComposition = LottieComposition.parseJsonBytes(
    StartCountdownArt.threeTwoOne(bytes),
  );
}

Map<String, dynamic> _seat(
  int i, {
  String status = 'waiting',
  int? chips,
  bool afterHand = false,
}) => {
  'seatIndex': i,
  'userId': countdownIds[i],
  'displayName': _names[i],
  'avatarUrl': null,
  'chips': chips,
  'status': status,
  'isBlind': !afterHand,
  'lastBet': afterHand ? 400 : 0,
  'lastAction': afterHand ? 'chaal' : null,
  'contributed': afterHand ? 1200 : 0,
  'connected': true,
  'cardCount': afterHand ? 3 : 0,
};

/// The hands shown down at the end of the hand before the countdown
/// ([countingDownRoom]'s `afterHand`): the viewer's won, every other seat's
/// beaten and face up, dimmed as a loser's is.
const _shown = [
  ['As', 'Ad', 'Kc'],
  ['Qs', 'Jd', '9c'],
  ['8h', '8d', '3s'],
  ['Kh', '7h', '2h'],
  ['6c', '5d', '4s'],
];

/// The showdown that ended the hand before the countdown: [players] hands,
/// the viewer's the winner, the next deal at [nextHandAt] (the phone's clock).
ShowdownNews countdownShowdown({required int players, int nextHandAt = 0}) => (
  reveals: [
    for (var i = 0; i < players; i++)
      Reveal.fromJson({
        'userId': countdownIds[i],
        'displayName': _names[i],
        'cards': _shown[i],
        'handName': i == 0 ? 'Pair' : 'High Card',
        'won': i == 0,
      }),
  ],
  result: '',
  winnerId: countdownIds[0],
  winnerName: _names[0],
  pot: 1200 * players,
  nextHandAt: nextHandAt,
  reason: 'show',
);

/// A table of [players] counting down: the deal [leftMs] away as the server
/// says it, at [startsAt] on its own clock. [category] picks the game's
/// cloth; [isPrivate] a private table of it. Before its first deal every
/// other seat is waiting (dimmed); [afterHand], the last hand is still on
/// show — the viewer won it, every other seat lost with its cards face up
/// (dimmed too) and its bet beside them ([countdownShowdown]).
RoomState countingDownRoom({
  required int leftMs,
  int? startsAt,
  String category = 'blind',
  bool isPrivate = false,
  int players = 5,
  int maxPlayers = 5,
  String state = 'starting',
  int handNo = 7,
  bool withStartsIn = true,
  int unfundedDeadline = 0,
  int missedTurns = 0,
  String roomId = 'r1',
  bool afterHand = false,
}) => RoomState.fromJson({
  'roomId': roomId,
  'code': 'ABCD2345',
  'isPrivate': isPrivate,
  'category': category,
  'chipsHidden': category != 'seen',
  'state': state,
  'handNo': handNo,
  'dealerSeat': 3,
  'maxPlayers': maxPlayers,
  'minPlayers': 2,
  'bootAmount': category == 'variation' ? 50000 : 200,
  'turnTimeoutMs': 25000,
  'startsAt': state == 'starting' ? (startsAt ?? countdownNow + leftMs) : null,
  if (state == 'starting' && withStartsIn) 'startsInMs': leftMs,
  'pot': 0,
  'maxPot': 0,
  'stake': 200,
  'turn': null,
  'you': {
    'seatIndex': 0,
    'chips': 245000,
    'status': afterHand ? 'won' : 'waiting',
    'isBlind': !afterHand,
    'contributed': afterHand ? 1200 : 0,
    'missedTurns': missedTurns,
    'maxMissedTurns': 3,
    'cards': afterHand ? _shown[0] : <String>[],
    if (unfundedDeadline > 0) 'unfundedDeadline': unfundedDeadline,
  },
  'seats': [
    for (var i = 0; i < maxPlayers; i++)
      if (i < players)
        _seat(
          i,
          chips: i == 0 || category == 'seen' ? 245000 : null,
          status: afterHand ? (i == 0 ? 'won' : 'lost') : 'waiting',
          afterHand: afterHand,
        )
      else
        {'seatIndex': i, 'status': 'empty'},
  ],
  if (category != 'poker') 'winnerTax': !isPrivate,
  if (!isPrivate) 'winnerTaxMinWinnings': 5000000,
});

/// The same table dealt: the hand the countdown ended in.
RoomState dealtRoom({String category = 'blind', int handNo = 8}) =>
    RoomState.fromJson({
      'roomId': 'r1',
      'code': 'ABCD2345',
      'isPrivate': false,
      'category': category,
      'chipsHidden': category != 'seen',
      'state': 'betting',
      'handNo': handNo,
      'dealerSeat': 4,
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'startsAt': null,
      'pot': 1000,
      'maxPot': 0,
      'stake': 200,
      'turn': {
        'seatIndex': 1,
        'userId': 'u1',
        'deadline': countdownNow + 25000,
      },
      'you': {
        'seatIndex': 0,
        'chips': 244800,
        'status': 'active',
        'isBlind': true,
        'contributed': 200,
        'missedTurns': 0,
        'maxMissedTurns': 3,
        'cards': <String>[],
      },
      'seats': [
        for (var i = 0; i < 5; i++)
          {
            ..._seat(i, status: 'active', chips: i == 0 ? 244800 : null),
            'contributed': 200,
            'lastBet': 200,
            'lastAction': 'boot',
            'cardCount': 3,
          },
      ],
    });

/// The viewer, Priya, holding a level: the winning tax's pill over the
/// countdown is two lines then, its tallest.
User countdownViewer() => User.fromJson({
  'id': 'u0',
  'provider': 'guest',
  'displayName': 'Priya',
  'chips': 245000,
  'diamond': 9,
  'hammer': 20,
  'missile': 1,
  'playerLevel': {
    'level': 10,
    'title': 'Rising Star',
    'icon': '🌟',
    'xp': 4180,
    'taxBps': 1743,
  },
  'taxBps': 1743,
});

/// A Texas Hold'em room counting down, [leftMs] to the deal, as the server
/// sends it between hands (`poker.street` empty): before its first hand —
/// every seat waiting, nothing bet, no card anywhere — or [afterHand], the
/// last hand's result still on the felt with every seat's cards and bets (the
/// countdown then stands in the pocket right of the pot).
RoomState countingDownPokerRoom({required int leftMs, bool afterHand = false}) {
  final json = pokerRoomJson()
    ..['state'] = 'starting'
    ..['turn'] = null
    ..['pot'] = 0
    ..['startsAt'] = countdownNow + leftMs
    ..['startsInMs'] = leftMs;
  final you = (json['you'] as Map<String, dynamic>)
    ..remove('options')
    ..['cards'] = <String>[];
  final poker = json['poker'] as Map<String, dynamic>
    ..['street'] = ''
    ..['community'] = <String>[]
    ..['pots'] = <Object>[]
    ..['currentBet'] = 0;
  if (!afterHand) {
    you
      ..['status'] = 'waiting'
      ..['contributed'] = 0
      ..['streetBet'] = 0;
    for (final seat in json['seats'] as List) {
      (seat as Map<String, dynamic>)
        ..['status'] = 'waiting'
        ..['cardCount'] = 0
        ..['contributed'] = 0
        ..['streetBet'] = 0
        ..remove('lastAction');
    }
  } else {
    poker['result'] = {
      'handId': 'h3',
      'reason': 'last_standing',
      'pots': [
        {
          'amount': 2000,
          'eligible': [0, 1],
          'winners': [
            {'userId': 'u1', 'seatIndex': 1, 'amount': 2000},
          ],
        },
      ],
      'reveals': <Object>[],
      'community': ['Ah', '7d', '9c'],
    };
  }
  return RoomState.fromJson(json);
}
