/// What the viewer's own three cards make, read on the phone for ONE purpose:
/// which animation their own cards play the moment they look at them (owner,
/// 29 Sep 2026: "Animation should be played on UI side, no backend change …
/// when user click on see card, then acc to rank of card play animation").
///
/// At a Seen or Blind table the server says nothing about the viewer's own
/// hand until the showdown, so this reads the three card codes into the
/// server's six categories exactly as the Go server's `Evaluate` sorts them:
/// three of a rank a Trail; a run — three consecutive ranks, or A-2-3, the ace
/// played low (A-K-Q is a run too; K-A-2 never wraps) — a Pure Sequence when
/// the three share a suit and a Sequence when they do not; three of a suit a
/// Color; two of a rank a Pair; anything else a High Card. Suits decide
/// nothing else.
///
/// It is NOT a ranking and must never become one: it never compares two
/// hands, never names a hand on screen, never lights another player's cards
/// and never decides anything — the server decides every result, and every
/// hand name the table shows is the one the server sent. A Variation table
/// never uses it (wild cards and Muflis change what a hand is; the server's
/// own `you.hand` says what it made there). `test/own_look_test.dart` holds it
/// to the server's category for every one of the 22,100 three-card hands, and
/// `test/review_reveal_naming_test.dart` to being used by the see-cards
/// animation alone (`table_screen.dart` `_FeltState._ownLook`).
library;

/// What three cards make: [category], the server's HandCategory number —
/// HIGH_CARD 0, PAIR 1, COLOR 2, SEQUENCE 3, PURE_SEQUENCE 4, TRAIL 5 — and
/// [lit], which of the three (by their place in the list, ascending) make it:
/// the two of a Pair, all three of a Color, a Sequence, a Pure Sequence or a
/// Trail, none of a High Card.
typedef OwnLook = ({int category, List<int> lit});

/// What the three card [codes] make ([OwnLook]), or null when they are not
/// three readable wire codes ("As", "Td", "7c").
OwnLook? ownLook(List<String> codes) {
  if (codes.length != 3) return null;
  final ranks = <int>[];
  final suits = <String>{};
  for (final code in codes) {
    if (code.length != 2) return null;
    final rank = _rankOf[code[0]];
    if (rank == null || !'shdc'.contains(code[1])) return null;
    ranks.add(rank);
    suits.add(code[1]);
  }
  const all = [0, 1, 2];
  final [a, b, c] = ranks;
  if (a == b && b == c) return (category: 5, lit: all);
  final sorted = [...ranks]..sort((x, y) => y - x);
  final [high, mid, low] = sorted;
  final run =
      (high == 14 && mid == 3 && low == 2) ||
      (high - mid == 1 && mid - low == 1);
  final oneSuit = suits.length == 1;
  if (run) return (category: oneSuit ? 4 : 3, lit: all);
  if (oneSuit) return (category: 2, lit: all);
  if (a == b) return (category: 1, lit: const [0, 1]);
  if (a == c) return (category: 1, lit: const [0, 2]);
  if (b == c) return (category: 1, lit: const [1, 2]);
  return (category: 0, lit: const []);
}

/// A wire code's rank letter, as the server's deck spells it: 2 … 9, T, J, Q,
/// K, A (the ace high, 14).
const _rankOf = {
  '2': 2,
  '3': 3,
  '4': 4,
  '5': 5,
  '6': 6,
  '7': 7,
  '8': 8,
  '9': 9,
  'T': 10,
  'J': 11,
  'Q': 12,
  'K': 13,
  'A': 14,
};
