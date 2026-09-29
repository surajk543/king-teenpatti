// The phone's one reading of a hand (lib/models/own_look.dart): what the
// viewer's own three cards make at a Seen or Blind table, for the animation
// their cards play the moment they look at them — and for nothing else
// (test/review_reveal_naming_test.dart holds it to that). It must agree with
// the server's ranking for every hand there is, so it is pinned here to the Go
// server's `internal/game.Evaluate` over all 22,100 three-card hands.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/own_look.dart';

/// The deck in the server's order (go-server internal/game/deck.go NewDeck):
/// suits s, h, d, c, each 2 … 9, T, J, Q, K, A.
const _suits = ['s', 'h', 'd', 'c'];
const _ranks = [
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  'T',
  'J',
  'Q',
  'K',
  'A',
];
final _deck = [
  for (final s in _suits)
    for (final r in _ranks) '$r$s',
];

/// The server's categories, by number.
const _names = [
  'High Card',
  'Pair',
  'Color',
  'Sequence',
  'Pure Sequence',
  'Trail',
];

/// The fingerprint of the server's answer for every three-card hand: sha256
/// of the lines "c1,c2,c3=category\n" (category the HandCategory number,
/// HIGH_CARD 0 … TRAIL 5) for every i < j < k over [_deck] in order.
///
/// Produced from the server itself on 29 Sep 2026 by a scratch Go program
/// kept outside the repository (a module named
/// github.com/surajk543/king-teenpatti/go-server/scratchfp so it may import
/// the internal package, `replace`d onto go-server/): it walked
/// `game.NewDeck()` with three nested loops, called
/// `game.Evaluate([]game.Card{a, b, c}, game.EvaluateOptions{})` and wrote
/// `fmt.Fprintf(&b, "%s,%s,%s=%d\n", a.Code(), b.Code(), c.Code(),
/// int(h.Category))`, then `sha256.Sum256`. Re-derived the same way by the
/// change that added this test. A change to either ranking that moves any
/// hand's category changes it.
const _serverFingerprint =
    '4a8c379884f24c1bf1113aaa8b856293bdd018995be73e95d469d748850dd6f2';

void main() {
  test('every one of the 22,100 hands reads as the server ranks it', () {
    final lines = StringBuffer();
    final counts = List<int>.filled(6, 0);
    var hands = 0;
    for (var i = 0; i < _deck.length; i++) {
      for (var j = i + 1; j < _deck.length; j++) {
        for (var k = j + 1; k < _deck.length; k++) {
          final cards = [_deck[i], _deck[j], _deck[k]];
          final look = ownLook(cards)!;
          lines.write('${cards.join(',')}=${look.category}\n');
          counts[look.category]++;
          hands++;
        }
      }
    }
    expect(hands, 22100);
    expect(
      sha256.convert(utf8.encode(lines.toString())).toString(),
      _serverFingerprint,
    );
    expect(
      {for (final (c, n) in counts.indexed) _names[c]: n},
      {
        'High Card': 16440,
        'Pair': 3744,
        'Color': 1096,
        'Sequence': 720,
        'Pure Sequence': 48,
        'Trail': 52,
      },
    );
  });

  test('every hand lights exactly the cards that make it', () {
    for (var i = 0; i < _deck.length; i++) {
      for (var j = i + 1; j < _deck.length; j++) {
        for (var k = j + 1; k < _deck.length; k++) {
          final cards = [_deck[i], _deck[j], _deck[k]];
          final look = ownLook(cards)!;
          final lit = look.lit;
          expect(lit, orderedEquals([...lit]..sort()), reason: '$cards');
          switch (look.category) {
            case 0:
              expect(lit, isEmpty, reason: '$cards');
            case 1:
              expect(lit, hasLength(2), reason: '$cards');
              expect(cards[lit[0]][0], cards[lit[1]][0], reason: '$cards');
            default:
              expect(lit, [0, 1, 2], reason: '$cards');
          }
        }
      }
    }
  });

  group('the edges', () {
    int category(List<String> cards) => ownLook(cards)!.category;

    test('the ace plays low in A-2-3 and high in A-K-Q', () {
      expect(category(['As', '2h', '3d']), 3);
      expect(category(['3c', 'Ah', '2d']), 3);
      expect(category(['As', 'Kh', 'Qd']), 3);
      expect(category(['Qd', 'As', 'Kh']), 3);
    });

    test('Q-K-A of one suit is a Pure Sequence, 2-3-4 a Sequence', () {
      expect(category(['Qh', 'Kh', 'Ah']), 4);
      expect(category(['As', '2s', '3s']), 4);
      expect(category(['2s', '3h', '4d']), 3);
      expect(category(['4c', '2c', '3c']), 4);
    });

    test('K-A-2 never wraps round: a High Card, or a Color of one suit', () {
      expect(category(['Ks', 'Ah', '2d']), 0);
      expect(category(['Kd', 'Ad', '2d']), 2);
      expect(category(['Qs', 'Kh', '2d']), 0);
    });

    test('a pair of aces with a king is a Pair, lighting the two aces', () {
      final look = ownLook(['As', 'Kd', 'Ah'])!;
      expect(look.category, 1);
      expect(look.lit, [0, 2]);
      expect(ownLook(['Kd', 'As', 'Ah'])!.lit, [1, 2]);
      expect(ownLook(['As', 'Ah', 'Kd'])!.lit, [0, 1]);
    });

    test('a trail of twos is a Trail, whatever the order', () {
      expect(ownLook(['2s', '2h', '2d'])!.category, 5);
      expect(ownLook(['2s', '2h', '2d'])!.lit, [0, 1, 2]);
      expect(category(['2c', '2d', '2s']), 5);
    });

    test('suits decide nothing but a Color and a Pure Sequence', () {
      expect(category(['2s', '6s', '9s']), 2);
      expect(category(['2s', '6h', '9s']), 0);
      expect(category(['7s', '7h', '7c']), 5);
      expect(category(['7s', '7h', 'Kh']), 1);
    });

    test('anything that is not three wire codes reads as nothing', () {
      expect(ownLook(const []), isNull);
      expect(ownLook(['As', 'Kd']), isNull);
      expect(ownLook(['As', 'Kd', 'Qh', 'Jc']), isNull);
      expect(ownLook(['As', 'Kd', '1h']), isNull);
      expect(ownLook(['As', 'Kd', 'Qx']), isNull);
      expect(ownLook(['As', 'Kd', '10h']), isNull);
      expect(ownLook(['as', 'Kd', 'Qh']), isNull);
    });
  });
}
