/// What the viewer's own three cards make, read on the phone for ONE purpose:
/// which animation their own cards play the moment they look at them (owner,
/// 29 Sep 2026: "Animation should be played on UI side, no backend change …
/// when user click on see card, then acc to rank of card play animation").
///
/// At a Seen or Blind table the server says nothing about the viewer's own
/// hand until the showdown, so this reads the three card codes exactly as the
/// server's `internal/game/handrank.go` `Evaluate` sorts them into its six
/// categories: three of a rank a Trail; a run (three consecutive ranks, or the
/// A-2-3 wheel — K-A-2 never wraps) a Pure Sequence when the suits agree and a
/// Sequence when they do not; three of a suit a Color; two of a rank a Pair;
/// anything else a High Card.
///
/// It is NOT a ranking and must never become one: it never compares two hands,
/// never names a hand on screen, never lights another player's cards and never
/// decides anything — the server decides every result. A Variation table never
/// uses it (wild cards and Muflis change what a hand is; the server's own
/// `you.hand` says what it made there). `test/own_look_test.dart` holds it to
/// the server's category for every one of the 22,100 three-card hands, and
/// `test/review_reveal_naming_test.dart` to being used by the see-cards
/// animation alone.
library;

/// The server's HandCategory number for the three card [codes] — HIGH_CARD 0,
/// PAIR 1, COLOR 2, SEQUENCE 3, PURE_SEQUENCE 4, TRAIL 5, as a reveal's
/// `category` carries it — or -1 when they are not three readable wire codes
/// ("As", "Td", "7c").
int ownLookCategory(List<String> codes) {
  if (codes.length != 3) return -1;
  final ranks = <int>[];
  final suits = <String>{};
  for (final code in codes) {
    if (code.length != 2) return -1;
    final rank = _rankOf[code[0]];
    if (rank == null || !'shdc'.contains(code[1])) return -1;
    ranks.add(rank);
    suits.add(code[1]);
  }
  ranks.sort((a, b) => b - a);
  final [high, mid, low] = ranks;
  final oneSuit = suits.length == 1;
  if (high == mid && mid == low) return 5;
  final run =
      (high == 14 && mid == 3 && low == 2) ||
      (high - mid == 1 && mid - low == 1);
  if (run) return oneSuit ? 4 : 3;
  if (oneSuit) return 2;
  if (high == mid || mid == low) return 1;
  return 0;
}

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
