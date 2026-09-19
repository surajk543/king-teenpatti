// The poker family on the wire, as the DTOs read it: a poker room's snapshot
// with its `poker` block and poker options, a poker table's menu entry, and
// — just as important — a Teen Patti snapshot carrying none of it.
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';

const _pokerOptions = <String, dynamic>{
  'street': 'flop',
  'fold': true,
  'check': false,
  'call': true,
  'callAmount': 200,
  'bet': false,
  'minBet': 0,
  'maxBet': 0,
  'raise': true,
  'minRaise': 600,
  'maxRaise': 20200,
  'allIn': true,
  'allInAmount': 20000,
  'play': false,
  'playAmount': 0,
  'draw': false,
  'maxDiscards': 0,
};

Map<String, dynamic> _snapshot({
  Map<String, dynamic>? options,
  Map<String, dynamic>? result,
  Map<String, dynamic>? dealer,
}) => {
  'roomId': 'p1',
  'code': 'ABCD2345',
  'isPrivate': false,
  'category': 'texas_holdem',
  'game': 'poker',
  'chipsHidden': false,
  'state': 'betting',
  'handNo': 7,
  'dealerSeat': 2,
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': null,
  'pot': 2000,
  'turn': {'seatIndex': 0, 'userId': 'u0', 'deadline': 1000},
  'you': {
    'seatIndex': 0,
    'chips': 20000,
    'status': 'active',
    'cards': ['Ks', 'Kd'],
    'contributed': 400,
    'streetBet': 200,
    'allIn': false,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'options': ?options,
    'hand': {
      'category': 3,
      'handName': 'Three of a Kind',
      'cards': ['Ks', 'Kd'],
      'best': ['Ks', 'Kd', 'Kc', 'Ah', '9c'],
    },
  },
  'seats': [
    {
      'seatIndex': 0,
      'userId': 'u0',
      'displayName': 'Me',
      'chips': 20000,
      'status': 'active',
      'connected': true,
      'cardCount': 2,
      'contributed': 400,
      'streetBet': 200,
      'allIn': false,
      'lastAction': 'call',
      'dealer': false,
    },
    {
      'seatIndex': 1,
      'userId': 'u1',
      'displayName': 'Short',
      'chips': 0,
      'status': 'active',
      'connected': true,
      'cardCount': 2,
      'contributed': 1000,
      'streetBet': 0,
      'allIn': true,
      'lastAction': 'allIn',
      'dealer': false,
    },
    {
      'seatIndex': 2,
      'userId': 'u2',
      'displayName': 'Button',
      'chips': 5000,
      'status': 'packed',
      'connected': true,
      'cardCount': 2,
      'contributed': 200,
      'streetBet': 0,
      'allIn': false,
      'lastAction': 'fold',
      'dealer': true,
    },
    {'seatIndex': 3, 'status': 'empty'},
    {'seatIndex': 4, 'status': 'empty'},
  ],
  'poker': {
    'variant': 'texas_holdem',
    'street': 'flop',
    'community': ['Ah', '7d', '9c'],
    'pots': [
      {
        'amount': 1600,
        'eligible': [0, 1, 2],
      },
      {
        'amount': 400,
        'eligible': [0, 2],
      },
    ],
    'currentBet': 400,
    'minRaise': 200,
    'smallBlind': 100,
    'bigBlind': 200,
    'ante': 0,
    'holeCards': 2,
    'maxDiscards': 0,
    'minBuyIn': 2000,
    'dealer': ?dealer,
    'result': ?result,
  },
};

const _result = <String, dynamic>{
  'handId': 'h7',
  'reason': 'showdown',
  'community': ['Ah', '7d', '9c', '2s', 'Kc'],
  'pots': [
    {
      'amount': 1600,
      'eligible': [0, 1, 2],
      'winners': [
        {'userId': 'u0', 'seatIndex': 0, 'amount': 1600, 'handName': 'Three of a Kind'},
      ],
    },
    {
      'amount': 400,
      'eligible': [0, 2],
      'winners': [
        {'userId': 'u0', 'seatIndex': 0, 'amount': 400, 'handName': 'Three of a Kind'},
      ],
    },
  ],
  'reveals': [
    {
      'userId': 'u0',
      'seatIndex': 0,
      'cards': ['Ks', 'Kd'],
      'best': ['Ks', 'Kd', 'Kc', 'Ah', '9c'],
      'handName': 'Three of a Kind',
      'category': 3,
      'won': 2000,
    },
    {
      'userId': 'u1',
      'seatIndex': 1,
      'cards': ['Ad', '7c'],
      'best': ['Ad', 'Ah', '7c', '7d', 'Kc'],
      'handName': 'Two Pair',
      'category': 2,
      'won': 0,
    },
  ],
};

void main() {
  group('the categories', () {
    test('know the four poker games and the family they file under', () {
      for (final wire in TableCategory.pokerCategories) {
        expect(TableCategory.isPoker(wire), isTrue, reason: wire);
      }
      for (final other in const ['seen', 'blind', 'variation', 'poker', '']) {
        expect(TableCategory.isPoker(other), isFalse, reason: other);
      }
      expect(PokerVariant.usesBlinds(PokerVariant.texasHoldem), isTrue);
      expect(PokerVariant.usesBlinds(PokerVariant.omaha), isTrue);
      expect(PokerVariant.usesBlinds(PokerVariant.fiveCardDraw), isFalse);
      expect(PokerVariant.usesBlinds(PokerVariant.threeCardPoker), isFalse);
      expect(PokerVariant.hasBoard(PokerVariant.omaha), isTrue);
      expect(PokerVariant.hasBoard(PokerVariant.fiveCardDraw), isFalse);
    });
  });

  group('a menu entry', () {
    test('for a poker table carries its blinds or ante, buy-in and cards', () {
      final holdem = LobbyTable.fromJson({
        'category': 'texas_holdem',
        'bootAmount': 200,
        'maxPot': 0,
        'maxBlindMoves': 0,
        'minChips': 2000,
        'game': 'poker',
        'smallBlind': 100,
        'bigBlind': 200,
        'minBuyIn': 2000,
        'holeCards': 2,
      });
      expect(holdem.isPoker, isTrue);
      expect(holdem.game, 'poker');
      expect(holdem.smallBlind, 100);
      expect(holdem.bigBlind, 200);
      expect(holdem.ante, 0);
      expect(holdem.minBuyIn, 2000);
      expect(holdem.holeCards, 2);
      expect(holdem.maxDiscards, 0);
      expect(holdem.admits(2000), isTrue);
      expect(holdem.admits(1999), isFalse, reason: 'minChips is the buy-in');

      final draw = LobbyTable.fromJson({
        'category': 'five_card_draw',
        'bootAmount': 200,
        'game': 'poker',
        'ante': 200,
        'minBuyIn': 2000,
        'holeCards': 5,
        'maxDiscards': 3,
      });
      expect(draw.ante, 200);
      expect(draw.maxDiscards, 3);
      expect(draw.holeCards, 5);
    });

    test('for a Teen Patti table reads as no poker at all', () {
      final seen = LobbyTable.fromJson({
        'category': 'seen',
        'bootAmount': 200,
        'maxPot': 2000000,
        'maxBlindMoves': 4,
      });
      expect(seen.isPoker, isFalse);
      expect(seen.game, '');
      expect(seen.smallBlind, 0);
      expect(seen.bigBlind, 0);
      expect(seen.ante, 0);
      expect(seen.minBuyIn, 0);
      expect(seen.holeCards, 0);
      expect(seen.maxDiscards, 0);
    });

    test('with a poker category and no game key is still a poker table', () {
      final t = LobbyTable.fromJson({'category': 'omaha', 'bootAmount': 200});
      expect(t.isPoker, isTrue);
    });
  });

  group('a poker snapshot', () {
    test('is a poker room with its block, its seats and its options', () {
      final room = RoomState.fromJson(_snapshot(options: _pokerOptions));
      expect(room.isPoker, isTrue);
      expect(room.game, 'poker');
      expect(room.category, 'texas_holdem');
      expect(room.chipsHidden, isFalse);
      expect(room.variation, isNull);
      expect(room.sideshow, isNull);

      final p = room.poker!;
      expect(p.variant, 'texas_holdem');
      expect(p.street, 'flop');
      expect(p.community, ['Ah', '7d', '9c']);
      expect(p.pots.map((pot) => pot.amount), [1600, 400]);
      expect(p.pots[1].eligible, [0, 2]);
      expect(p.pots[0].winners, isEmpty);
      expect(p.potTotal, 2000);
      expect(p.currentBet, 400);
      expect(p.minRaise, 200);
      expect(p.smallBlind, 100);
      expect(p.bigBlind, 200);
      expect(p.ante, 0);
      expect(p.holeCards, 2);
      expect(p.maxDiscards, 0);
      expect(p.minBuyIn, 2000);
      expect(p.dealer, isNull);
      expect(p.result, isNull);
      expect(p.usesBlinds, isTrue);
      expect(p.hasBoard, isTrue);

      // The seats: this street's bet, the all-in flag and the button.
      expect(room.seats[0].streetBet, 200);
      expect(room.seats[1].allIn, isTrue);
      expect(room.seats[1].chips, 0, reason: 'a poker stack is never null');
      expect(room.seats[2].dealer, isTrue);
      expect(room.seats[2].status, SeatState.packed);
      expect(room.seats[3].occupied, isFalse);

      // The viewer: hole cards, this street's bet, the hand so far, and the
      // moves — read as poker options and never as a Teen Patti ladder.
      final you = room.you!;
      expect(you.cards, ['Ks', 'Kd']);
      expect(you.streetBet, 200);
      expect(you.allIn, isFalse);
      expect(you.hand!.handName, 'Three of a Kind');
      expect(you.hand!.best, ['Ks', 'Kd', 'Kc', 'Ah', '9c']);
      expect(you.options, isNull);
      final o = you.pokerOptions!;
      expect(o.street, 'flop');
      expect(o.fold, isTrue);
      expect(o.check, isFalse);
      expect(o.call, isTrue);
      expect(o.callAmount, 200);
      expect(o.bet, isFalse);
      expect(o.raise, isTrue);
      expect(o.minRaise, 600);
      expect(o.maxRaise, 20200);
      expect(o.play, isFalse);
      expect(o.draw, isFalse);
    });

    test('off turn carries no options of either kind', () {
      final room = RoomState.fromJson(_snapshot());
      expect(room.you!.options, isNull);
      expect(room.you!.pokerOptions, isNull);
    });

    test('with a result names the winners, the reveals and the board', () {
      final room = RoomState.fromJson(_snapshot(result: _result));
      final r = room.poker!.result!;
      expect(r.handId, 'h7');
      expect(r.reason, 'showdown');
      expect(r.community, hasLength(5));
      expect(r.pots, hasLength(2));
      expect(r.pots[0].winners.single.userId, 'u0');
      expect(r.pots[0].winners.single.handName, 'Three of a Kind');
      // Every winner once, across every pot.
      expect(r.winners.map((w) => w.userId), ['u0']);
      expect(r.wonBy('u0'), 2000);
      expect(r.wonBy('u1'), 0);
      expect(r.wonBy(null), 0);
      expect(r.revealOf('u1')!.handName, 'Two Pair');
      expect(r.revealOf('u1')!.won, 0);
      expect(r.revealOf('u1')!.outcome, isNull);
      expect(r.revealOf('u9'), isNull);
      expect(r.dealer, isNull);
    });

    test('for 3-Card Poker carries the dealer and each outcome', () {
      final room = RoomState.fromJson(
        _snapshot(
          dealer: {'cardCount': 3, 'cards': <String>[]},
          result: {
            'handId': 'h8',
            'reason': 'dealer',
            'community': <String>[],
            'pots': <Map<String, dynamic>>[],
            'reveals': [
              {
                'userId': 'u0',
                'seatIndex': 0,
                'cards': ['Ks', 'Kd', '4c'],
                'best': ['Ks', 'Kd', '4c'],
                'handName': 'Pair',
                'category': 1,
                'won': 400,
                'outcome': 'win',
              },
            ],
            'dealer': {
              'cardCount': 3,
              'cards': ['Qh', '8d', '3c'],
              'handName': 'High Card',
              'category': 0,
              'qualified': true,
            },
          },
        ),
      );
      final p = room.poker!;
      expect(p.dealer!.cardCount, 3);
      expect(p.dealer!.cards, isEmpty, reason: 'face down until the reveal');
      expect(p.dealer!.qualified, isNull);
      final r = p.result!;
      expect(r.dealer!.cards, ['Qh', '8d', '3c']);
      expect(r.dealer!.qualified, isTrue);
      expect(r.dealer!.handName, 'High Card');
      expect(r.revealOf('u0')!.outcome, PokerOutcome.win);
      expect(r.winners, isEmpty, reason: 'the house pays; there are no pots');
    });

    test("the dealer to draw is taken from whichever block has it", () {
      const live = PokerDealer(
        cardCount: 3,
        cards: [],
        handName: '',
        category: 0,
        qualified: null,
      );
      const revealed = PokerDealer(
        cardCount: 0, // ResultView.Dealer is a DealerReveal: it has no count
        cards: ['Qh', '8d', '3c'],
        handName: 'High Card',
        category: 0,
        qualified: true,
      );

      // During the hand: three backs, nothing named.
      final playing = PokerDealer.shown(live: live)!;
      expect(playing.cardCount, 3);
      expect(playing.cards, isEmpty);
      expect(playing.qualified, isNull);

      // At the reveal, with the hand still live: both blocks agree.
      final turning = PokerDealer.shown(live: revealed, finished: revealed)!;
      expect(turning.cards, ['Qh', '8d', '3c']);
      expect(turning.qualified, isTrue);

      // SETTLED: the server empties `poker.dealer` once `t.hand` is nil, and
      // the whole reveal is in `poker.result.dealer`. Taking the live block
      // alone here drew three backs under "High Card · Dealer qualifies"
      // (Pixel 7 Pro, 19 Sep 2026).
      const emptied = PokerDealer(
        cardCount: 0,
        cards: [],
        handName: '',
        category: 0,
        qualified: null,
      );
      final settled = PokerDealer.shown(live: emptied, finished: revealed)!;
      expect(settled.cards, ['Qh', '8d', '3c']);
      expect(settled.cardCount, 3, reason: 'counted from the cards');
      expect(settled.handName, 'High Card');
      expect(settled.qualified, isTrue);

      // And a game with no dealer at all stays that way.
      expect(PokerDealer.shown(), isNull);
    });

    test('reads garbage as nothing rather than throwing', () {
      final room = RoomState.fromJson({
        'roomId': 'p2',
        'game': 'poker',
        'category': 'omaha',
        'you': {
          'seatIndex': 0,
          'options': {'street': 7, 'fold': 'yes', 'callAmount': 'lots'},
        },
        'seats': [
          {'seatIndex': 0, 'streetBet': 'x', 'allIn': 'x', 'dealer': 1},
        ],
        'poker': {
          'variant': 'omaha',
          'community': 'Ah',
          'pots': [
            'not a pot',
            {'amount': '1', 'eligible': 'all'},
          ],
          'dealer': 'house',
          'result': 4,
        },
      });
      expect(room.isPoker, isTrue);
      final p = room.poker!;
      expect(p.community, isEmpty);
      expect(p.pots, hasLength(1));
      expect(p.pots[0].amount, 0);
      expect(p.pots[0].eligible, isEmpty);
      expect(p.dealer, isNull);
      expect(p.result, isNull);
      final o = room.you!.pokerOptions!;
      expect(o.street, '');
      expect(o.fold, isFalse);
      expect(o.callAmount, 0);
      expect(room.seats[0].streetBet, 0);
      expect(room.seats[0].allIn, isFalse);
      expect(room.seats[0].dealer, isFalse);
    });
  });

  group('a Teen Patti snapshot', () {
    test('carries no poker, and its ladder is still a ladder', () {
      final room = RoomState.fromJson({
        'roomId': 'r1',
        'code': 'ABCD2345',
        'category': 'seen',
        'chipsHidden': false,
        'state': 'betting',
        'handNo': 3,
        'you': {
          'seatIndex': 0,
          'chips': 1000,
          'status': 'active',
          'isBlind': false,
          'options': {
            'canSee': false,
            'canPack': true,
            'canSideshow': false,
            'raiseSteps': [400, 800],
            'show': null,
            'chips': 1000,
            'currentStake': 200,
          },
        },
        'seats': [
          {
            'seatIndex': 0,
            'userId': 'u0',
            'displayName': 'Me',
            'chips': 1000,
            'status': 'active',
            'isBlind': false,
            'lastBet': 400,
            'contributed': 600,
            'connected': true,
            'cardCount': 3,
          },
        ],
      });
      expect(room.isPoker, isFalse);
      expect(room.game, '');
      expect(room.poker, isNull);
      expect(room.you!.options, isNotNull);
      expect(room.you!.options!.raiseSteps, [400, 800]);
      expect(room.you!.options!.canPack, isTrue);
      expect(room.you!.pokerOptions, isNull);
      expect(room.you!.streetBet, 0);
      expect(room.you!.allIn, isFalse);
      expect(room.seats[0].streetBet, 0);
      expect(room.seats[0].allIn, isFalse);
      expect(room.seats[0].dealer, isFalse);
    });

    test('a ladder with no poker key is never read as poker options', () {
      expect(PokerOptions.isPokerMap({'raiseSteps': [400]}), isFalse);
      expect(PokerOptions.isPokerMap({'canPack': true}), isFalse);
      expect(PokerOptions.isPokerMap({'street': 'flop'}), isTrue);
      expect(PokerOptions.isPokerMap({'fold': false}), isTrue);
    });
  });
}
