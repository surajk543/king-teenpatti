// Can the player SEE every emoji that is playing? (owner, 29 Sep 2026: "In
// game table, i still see error that if i send emoji sometimes it is getting
// hidden, test properly all scenarios, when it is my turn then send emoji,
// when it is not my turn then send emoji, when there 2,3,4 players in table
// then send emoji, test emoji end to end").
//
// A harness, measured by PIXELS, over the real TableScreen (and the poker
// felt) laid out for real — Inter and the Material icons loaded, shadows on —
// at the phone sizes the table is checked on.
//
// HOW AN EMOJI IS SEEN. Every sender's emoji is a Lottie of one flat,
// saturated colour filling its whole canvas, a different hue for each seat
// (u0 magenta, u1 cyan, u2 green, u3 blue, u4 yellow). The screen is captured
// (a RepaintBoundary at the root, `toImage` inside `runAsync`) once before the
// case's emojis are sent — the baseline — and again while they play. A pixel
// of an emoji's art square counts as SEEN when, while it plays, it has that
// sender's hue (within 14°, saturation ≥ 0.5, value ≥ 0.3) and did not have
// it in the baseline. The art's VISIBLE FRACTION is the seen pixels over the
// whole art square (1dp in from its edge, where the square is antialiased),
// a part of it off the screen counting as unseen.
//
// Why the art and not the bubble's skin: the skin is ink900 at 0.82, which
// over the dark room is within a few levels of the room itself — a skin-based
// measure cannot tell "over the room" from "under an opaque key" there — and
// the art is what the player has to see. Why a hue and not "the pixel
// changed": the hue survives a translucent layer (a drawer's or a picker's
// scrim dims an emoji; it does not hide it), tells two overlapping emojis
// apart (each pixel is one sender's or neither's), and ignores everything
// else on the table that animates between the two captures (the lamp, the
// turn ring, the pot's breath). The baseline guards the one weakness left: a
// thing on the table that already had that hue there.
//
// THE THRESHOLD: an emoji is VISIBLE when at least 70% of its art is seen.
// Calibrated in "the measure" below: a lone emoji over the open felt measures
// 100%, the same under a 50% black box 100%, an opaque box over its left half
// 50%, over all of it 0% — and the one case known hidden on master, the
// viewer's own emoji moved beside their pod after another seat's, measures
// 9–21% (a sliver beside the card fan). 70% is well clear of both: a bubble
// whose corner is clipped by a key's edge still passes, one whose middle is
// under a card fan fails. An emoji seen under 97% but at least 70% passes and
// is listed at the end as partly covered, with what covers it; one seen but
// drawn under 60% of its colour's strength (the seen pixels' brightest
// channel: 100% for the flat colour at full opacity, 50% under the half-black
// box) passes and is listed as faint — a seat out of the hand (packed, lost,
// waiting) is drawn at 0.45 opacity (0.62 by day), its emoji with it.
//
// OVERLAP: two emojis overlap when their bubbles (the 'seat-emoji' widgets)
// meet by more than 2dp each way — the felt's own test when it places them.
//
// WHAT COVERS IT: every widget that paints after the emoji's bubble (element
// pre-order, which is paint order for the Stacks and the Scaffold the table
// is built of) is a candidate — every card and whose it is, each seat's pod,
// bet badge and column, each other emoji, every key (Shop, wallet, Missile,
// Pack, the action cluster, the rail), the pickers, the sideshow prompt, the
// missed-turn notice, the drawers, toasts, the hammer, the missiles, the
// celebration. At each unseen pixel the one on top there is blamed (first
// among things with a box of their own, then the seats' whole columns, then
// the felt-sized overlays, then the sender's own seat, whose later parts paint
// over its emoji), and the one blamed most is reported as the likely
// occluder, with its rect and share.
//
// THE MATRIX: table sizes 2, 3, 4, 5; my turn, someone else's turn, between
// hands (waiting, starting), the showdown's celebration (theirs, mine), a
// missed turn's notice (after one miss, and the last warning on my turn); the
// variation window (me choosing: the picker; someone else: the "is selecting"
// line), a sideshow asked of me (the prompt), a Force Sideshow's hammer (mine,
// between two others), a missile (mine, another's), a deal in flight, the
// 5-Card picker, the menu and player drawers (hidden under an open drawer is
// by design: reported, not failed), and the poker felt; senders me alone,
// each seat alone, me with each seat in both orders, and everyone within 5 s
// (me first, me last, me in the middle); at 592x360 x1.25, 640x360 x1.0 and
// x1.25, 732x412, 844x390 x1.25, 891x411, 915x412 x1.25, and both themes on
// a subset. Every value of every axis meets the others' defaults (5 places,
// someone else's turn, 640x360 x1.25, dark), plus the risky pairs (the head
// seat with me, the overlays, on the narrowest and widest phones). And END TO
// END: the viewer's emoji sent from the table's emoji key (the drawer, a tap,
// `chat:emoji` out, the drawer shut) and echoed back as the server does, at
// every table size, on turn and off, alone and after everyone else's. A test
// fails naming every hidden or overlapping emoji, its fraction, its rect and
// the likely occluder; the whole run's findings are printed at the end.
//
//   flutter test test/emoji_visibility_test.dart           (about 3.5 minutes)
//   (optional) --dart-define=EMOJI_REPORT=/abs/report.json  every look, as JSON
//   (optional) --dart-define=EMOJI_SHOTS=/abs/dir           a PNG of every
//              moment where an emoji is not wholly seen or overlaps another
//   (optional) --dart-define=EMOJI_ONLY=<substring of test names>
//   (optional) --dart-define=ICON_FONT=<path>/MaterialIcons-Regular.otf
//              (else it is found under FLUTTER_ROOT, which `flutter test` sets)
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/emoji_art.dart';
import 'package:teenpatti/widgets/emoji_shelf.dart';
import 'package:teenpatti/widgets/hammer_flight.dart';
import 'package:teenpatti/widgets/missed_turns_notice.dart';
import 'package:teenpatti/widgets/missile_flight.dart';
import 'package:teenpatti/widgets/player_drawer.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/table_chrome.dart';
import 'package:teenpatti/widgets/variation_prompt.dart';

import 'table_scenes.dart';

// ------------------------------------------------------------------ settings

/// The share of an emoji's art that must be seen for it to count as visible.
const _visibleAtLeast = 0.70;

/// Below this share an emoji that still counts as visible is reported as
/// partly covered (information only): a lone emoji over the open felt
/// measures 0.99 or more.
const _partlyBelow = 0.97;

/// Below this strength a visible emoji is reported as faint (information
/// only): drawn at full opacity its flat colour measures 1.0; a seat out of
/// the hand is drawn at 0.45 (0.62 by day), and so is its emoji.
const _faintBelow = 0.6;

const _reportPath = String.fromEnvironment('EMOJI_REPORT');
const _only = String.fromEnvironment('EMOJI_ONLY');
const _shotsDir = String.fromEnvironment('EMOJI_SHOTS');

// ---------------------------------------------------------------- the emojis

const _names = ['Priya', 'Ravi', 'Meera', 'Arjun', 'Vikramaditya'];

/// Each sender's hue, and the flat colour of their emoji's whole canvas.
const _hues = <String, double>{
  'u0': 300,
  'u1': 180,
  'u2': 120,
  'u3': 240,
  'u4': 60,
};
const _rgb = <String, List<int>>{
  'u0': [1, 0, 1],
  'u1': [0, 1, 1],
  'u2': [0, 1, 0],
  'u3': [0, 0, 1],
  'u4': [1, 1, 0],
};

String _url(String id) => 'https://cdn.test/emoji-matrix/$id.json';

/// A Lottie whose one layer is a rectangle filling its 100x100 canvas in
/// [rgb]: fitted whole into the art square, it paints every pixel of it.
Uint8List _flatLottie(List<int> rgb) => Uint8List.fromList(
  utf8.encode(
    '{"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"e","ddd":0,'
    '"assets":[],"layers":[{"ddd":0,"ind":1,"ty":4,"nm":"d","sr":1,'
    '"ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[50,50,0]},'
    '"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},"ao":0,'
    '"shapes":[{"ty":"gr","nm":"g","it":[{"ty":"rc","nm":"r",'
    '"p":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0}},'
    '{"ty":"fl","nm":"f","c":{"a":0,"k":[${rgb.join(',')},1]},'
    '"o":{"a":0,"k":100}},{"ty":"tr","p":{"a":0,"k":[0,0]},'
    '"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},"r":{"a":0,"k":0},'
    '"o":{"a":0,"k":100}}]}],"ip":0,"op":30,"st":0,"bm":0}]}',
  ),
);

String _nameOf(String id) => _names[int.parse(id.substring(1))];

/// The server's stamp on each line: rising, so the felt places them in the
/// order they were sent.
var _stamp = 1790000000000;

ChatMessage _emojiLine(String id) {
  _stamp += 1000;
  return ChatMessage.fromJson({
    'userId': id,
    'displayName': _nameOf(id),
    'text': 'Emoji',
    'at': _stamp,
    'emoji': {
      'id': int.parse(id.substring(1)) + 1,
      'name': 'Emoji of ${_nameOf(id)}',
      'url': _url(id),
      'assetFormat': 'LOTTIE',
    },
  });
}

// --------------------------------------------------------------- the rooms

int get _now => DateTime.now().millisecondsSinceEpoch;

/// "Somebody else" at a table of [n] places: the head seat at two and four
/// places, the right-hand end at three, the top-left seat at five.
int _other(int n) => n == 2 ? 1 : 2;

Map<String, dynamic> _seat(
  int i, {
  String status = 'active',
  bool blind = true,
  int lastBet = 400,
  int contributed = 1400,
  int? chips,
  String lastAction = 'chaal',
  int cardCount = 3,
}) => {
  'seatIndex': i,
  'userId': 'u$i',
  'displayName': _names[i],
  'avatarUrl': null,
  'chips': chips,
  'status': status,
  'isBlind': blind,
  'lastBet': lastBet,
  'lastAction': lastAction,
  'contributed': contributed,
  'connected': true,
  'cardCount': cardCount,
};

const _stacks = [245000, 1820000, 96000, 12500000, 530000];

/// Every seat of [n] at a table whose other stacks are hidden (blind,
/// variation) or public (seen).
List<Map<String, dynamic>> _seats(
  int n, {
  bool public = false,
  String status = 'active',
  int lastBet = 400,
  int contributed = 1400,
  int cardCount = 3,
  Set<int> seen = const {2, 4},
  Map<int, String> statusOf = const {},
}) => [
  for (var i = 0; i < n; i++)
    _seat(
      i,
      chips: i == 0 || public ? _stacks[i] : null,
      blind: !seen.contains(i),
      status: statusOf[i] ?? status,
      lastBet: lastBet,
      contributed: contributed,
      cardCount: cardCount,
      lastAction: statusOf[i] == 'packed' ? 'pack' : 'chaal',
    ),
];

Map<String, dynamic> _you({
  String status = 'active',
  bool blind = true,
  List<String> cards = const [],
  int blindMovesLeft = 3,
  Map<String, dynamic>? options,
  bool canMissile = false,
  int chips = 245000,
  int missed = 0,
}) => {
  'seatIndex': 0,
  'chips': chips,
  'status': status,
  'isBlind': blind,
  'blindMovesLeft': blindMovesLeft,
  'contributed': 1400,
  'missedTurns': missed,
  'maxMissedTurns': 3,
  'cards': cards,
  'canMissile': canMissile,
  'taxBps': 2000,
  'options': ?options,
};

RoomState _room(
  int n, {
  String category = 'blind',
  String state = 'betting',
  int handNo = 7,
  int pot = 6800,
  int stake = 400,
  int maxPot = 0,
  int? turnSeat,
  required List<Map<String, dynamic>> seats,
  required Map<String, dynamic> you,
  Map<String, dynamic>? sideshow,
  Map<String, dynamic>? variation,
  int? startsAt,
}) => RoomState.fromJson({
  'roomId': 'r$n',
  'code': 'ABCD2345',
  'isPrivate': false,
  'category': category,
  'chipsHidden': category != 'seen',
  'state': state,
  'handNo': handNo,
  'dealerSeat': n - 1,
  'maxPlayers': n,
  'minPlayers': 2,
  'bootAmount': category == 'variation' ? 50000 : 200,
  'turnTimeoutMs': 25000,
  'startsAt': startsAt ?? 0,
  'pot': pot,
  'maxPot': maxPot,
  'stake': stake,
  'turn': turnSeat == null
      ? {'seatIndex': -1, 'userId': null, 'deadline': 0}
      : {
          'seatIndex': turnSeat,
          'userId': 'u$turnSeat',
          'deadline': _now + 20000,
        },
  'you': you,
  'seats': seats,
  'sideshow': ?sideshow,
  'variation': ?variation,
  // Every public Teen Patti table taxes its winners: the pill is under the tag.
  'winnerTax': true,
  'winnerTaxMinWinnings': 5000000,
});

Map<String, dynamic> _options({
  required int n,
  bool canSee = false,
  List<int> steps = const [800, 1600],
}) => {
  'canSee': canSee,
  'canPack': true,
  'canSideshow': n >= 3 && !canSee,
  'canForceSideshow': n >= 3 && !canSee,
  'sideshowWith': _names[n - 1],
  'raiseSteps': steps,
  'chips': 245000,
  'currentStake': 400,
};

/// My turn at a seen table, my cards face up and every key on the console
/// lit: Chaal primary, Sideshow and Force Sideshow, Missile, Pack.
RoomState _myTurn(int n, int h) => _room(
  n,
  category: 'seen',
  maxPot: 2000000,
  handNo: h,
  turnSeat: 0,
  seats: _seats(n, public: true, seen: {0, 2, 4}),
  you: _you(
    blind: false,
    cards: const ['As', 'Kd', 'Qh'],
    blindMovesLeft: 0,
    canMissile: n >= 3,
    options: _options(n: n),
  ),
);

/// Somebody else's turn at a blind table, my cards face down.
RoomState _otherTurn(int n, int h) =>
    _room(n, handNo: h, turnSeat: _other(n), seats: _seats(n), you: _you());

/// Between hands: every seat waiting for the next deal, or ([starting]) the
/// deal counting down.
RoomState _between(int n, int h, {required bool starting}) => _room(
  n,
  state: starting ? 'starting' : 'waiting',
  handNo: h,
  pot: 0,
  stake: 200,
  startsAt: starting ? _now + 4000 : null,
  seats: _seats(
    n,
    status: 'waiting',
    lastBet: 0,
    contributed: 0,
    cardCount: 0,
    seen: const {},
  ),
  you: _you(status: 'waiting'),
);

/// A seen hand shown down: [winner] took it, the others shown or packed.
RoomState _showdownRoom(int n, int h, int winner) => _room(
  n,
  category: 'seen',
  state: 'showdown',
  maxPot: 2000000,
  handNo: h,
  pot: 14200,
  seats: _seats(
    n,
    public: true,
    seen: {for (var i = 0; i < n; i++) i},
    statusOf: {for (var i = 0; i < n; i++) i: i == winner ? 'won' : 'lost'},
  ),
  you: _you(
    status: winner == 0 ? 'won' : 'lost',
    blind: false,
    cards: const ['7s', '7d', 'Kc'],
    blindMovesLeft: 0,
  ),
);

const _handsShown = [
  ['7s', '7d', 'Kc'],
  ['9h', '8h', '2c'],
  ['Qs', 'Js', 'Ts'],
  ['5d', '5c', 'Ah'],
  ['Kh', '4h', '2h'],
];

ShowdownNews _showdownNews(int n, int winner) => (
  reveals: [
    for (var i = 0; i < n; i++)
      Reveal.fromJson({
        'userId': 'u$i',
        'displayName': _names[i],
        'cards': _handsShown[i],
        'handName': i == winner ? 'Pure Sequence' : 'High Card',
        'won': i == winner,
      }),
  ],
  result: 'show',
  winnerId: 'u$winner',
  winnerName: _names[winner],
  pot: 14200,
  nextHandAt: _now + 60000,
  reason: 'show',
);

/// After [missed] missed turns: packed by the clock with somebody else on
/// turn, or ([myTurn]) on turn again, every key lit.
RoomState _missedRoom(
  int n,
  int h, {
  required int missed,
  required bool myTurn,
}) => _room(
  n,
  handNo: h,
  turnSeat: myTurn ? 0 : _other(n),
  seats: _seats(n, statusOf: myTurn ? const {} : const {0: 'packed'}),
  you: myTurn
      ? _you(
          canMissile: n >= 3,
          missed: missed,
          options: _options(n: n, canSee: true, steps: const [400, 800]),
        )
      : _you(status: 'packed', missed: missed),
);

/// The variation window, [chooser] choosing — the picker over the upper felt
/// when it is me, the "is selecting" line when it is not.
RoomState _variationRoom(int n, int h, int chooser) => _room(
  n,
  category: 'variation',
  handNo: h,
  stake: 50000,
  pot: 50000 * n,
  seats: _seats(n, lastBet: 0, contributed: 50000, seen: const {}),
  you: _you(chips: 1250000),
  variation: {
    'selecting': true,
    'userId': 'u$chooser',
    'displayName': _names[chooser],
    'seatIndex': chooser,
    'startedAt': _now - 2000,
    'deadline': _now + 60000,
    'timeoutMs': 10000,
    'options': const [
      'MUFLIS',
      'AK47',
      'JOKER',
      'HUKAM',
      'LOWEST_JOKER',
      'HIGHEST_JOKER',
      'FIVE_CARD',
    ],
  },
);

/// My right-hand neighbour, on turn, has asked me for a sideshow: the prompt
/// with Accept and Decline is up for me.
RoomState _sideshowToMe(int n, int h) => _room(
  n,
  category: 'seen',
  maxPot: 2000000,
  handNo: h,
  turnSeat: n - 1,
  seats: _seats(n, public: true, seen: {for (var i = 0; i < n; i++) i}),
  you: _you(blind: false, cards: const ['Jc', 'Jd', '4s'], blindMovesLeft: 0),
  sideshow: {
    'fromUserId': 'u${n - 1}',
    'fromSeat': n - 1,
    'toUserId': 'u0',
    'toSeat': 0,
    'expiresAt': _now + 60000,
  },
);

/// A seen hand with [turn] on turn and [packed] out of it — the table a
/// Force Sideshow or a missile is played at.
RoomState _seenOnTurn(int n, int h, int turn, {Set<int> packed = const {}}) =>
    _room(
      n,
      category: 'seen',
      maxPot: 2000000,
      handNo: h,
      turnSeat: turn,
      seats: _seats(
        n,
        public: true,
        seen: {for (var i = 0; i < n; i++) i},
        statusOf: {for (final i in packed) i: 'packed'},
      ),
      you: _you(
        status: packed.contains(0) ? 'packed' : 'active',
        blind: false,
        cards: const ['Jc', 'Jd', '4s'],
        blindMovesLeft: 0,
      ),
    );

// ---------------------------------------------------------------- the phases

typedef _Trigger =
    Future<void> Function(WidgetTester tester, GameState state, int n, int h);

/// A state of the table an emoji is sent into: the room entered before each
/// case, what then happens after the emojis are sent ([trigger]), and when
/// after that the screen is looked at ([moments]).
class _Phase {
  const _Phase(
    this.label, {
    required this.room,
    this.minPlaces = 2,
    this.freshHand = false,
    this.trigger,
    this.moments = const [('', Duration.zero)],
    this.cleanup,
    this.excused = const {},
  });

  final String label;
  final RoomState Function(int n, int h) room;
  final int minPlaces;

  /// A new hand for every case — a showdown, a hammer or a missile is played
  /// once per hand.
  final bool freshHand;
  final _Trigger? trigger;
  final List<(String, Duration)> moments;
  final _Trigger? cleanup;

  /// Occluders that hide an emoji by design (an open drawer): reported, not
  /// failed.
  final Set<String> excused;
}

Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  await tester.pump();
  await tester.pump(d);
}

final _myTurnPhase = _Phase('my turn', room: _myTurn);
final _otherTurnPhase = _Phase('someone else\'s turn', room: _otherTurn);

final _phases = <String, _Phase>{
  'my turn': _myTurnPhase,
  'other turn': _otherTurnPhase,
  'waiting': _Phase(
    'between hands, waiting',
    room: (n, h) => _between(n, h, starting: false),
  ),
  'starting': _Phase(
    'between hands, the deal counting down',
    room: (n, h) => _between(n, h, starting: true),
  ),
  'showdown other': _Phase(
    'the showdown\'s celebration, someone else won',
    room: _otherTurn,
    freshHand: true,
    trigger: (tester, state, n, h) async {
      state
        ..handleState(_showdownRoom(n, h, _other(n)))
        ..handleShowdown(_showdownNews(n, _other(n)));
    },
    moments: const [
      ('fireworks', Duration(milliseconds: 900)),
      ('pot crossing', Duration(milliseconds: 2200)),
    ],
  ),
  'showdown mine': _Phase(
    'the showdown\'s celebration, I won',
    room: _otherTurn,
    freshHand: true,
    trigger: (tester, state, n, h) async {
      state
        ..handleState(_showdownRoom(n, h, 0))
        ..handleShowdown(_showdownNews(n, 0));
    },
    moments: const [
      ('fireworks', Duration(milliseconds: 900)),
      ('pot crossing', Duration(milliseconds: 2200)),
    ],
  ),
  'missed': _Phase(
    'I missed a turn (the notice up), someone else on turn',
    room: (n, h) => _missedRoom(n, h, missed: 0, myTurn: false),
    trigger: (tester, state, n, h) async =>
        state.handleState(_missedRoom(n, h, missed: 1, myTurn: false)),
    moments: const [('notice up', Duration(milliseconds: 500))],
  ),
  'missed last': _Phase(
    'my turn after two missed (the last warning up)',
    room: (n, h) => _missedRoom(n, h, missed: 0, myTurn: true),
    trigger: (tester, state, n, h) async =>
        state.handleState(_missedRoom(n, h, missed: 2, myTurn: true)),
    moments: const [('warning up', Duration(milliseconds: 500))],
  ),
  'variation mine': _Phase(
    'the variation window, me choosing (the picker up)',
    room: (n, h) => _variationRoom(n, h, 0),
  ),
  'variation other': _Phase(
    'the variation window, someone else choosing',
    room: (n, h) => _variationRoom(n, h, _other(n)),
  ),
  'sideshow to me': _Phase(
    'a sideshow asked of me (the prompt up)',
    room: _sideshowToMe,
    minPlaces: 3,
  ),
  'hammer mine': _Phase(
    'my Force Sideshow\'s hammer on my right-hand neighbour',
    room: (n, h) => _seenOnTurn(n, h, 0),
    minPlaces: 3,
    freshHand: true,
    trigger: (tester, state, n, h) async {
      state
        ..handleSideshowDone((
          fromUserId: 'u0',
          toUserId: 'u${n - 1}',
          accepted: true,
          reason: SideshowReason.forced,
          packedUserId: 'u${n - 1}',
        ))
        ..handleState(_seenOnTurn(n, h, 0, packed: {n - 1}));
    },
    moments: const [
      ('hammer in flight', Duration(milliseconds: 450)),
      ('hammer lands', Duration(milliseconds: 900)),
    ],
  ),
  'hammer others': _Phase(
    'a Force Sideshow\'s hammer between two others',
    room: (n, h) => _seenOnTurn(n, h, 2),
    minPlaces: 3,
    freshHand: true,
    trigger: (tester, state, n, h) async {
      state
        ..handleSideshowDone((
          fromUserId: 'u2',
          toUserId: 'u1',
          accepted: true,
          reason: SideshowReason.forced,
          packedUserId: 'u1',
        ))
        ..handleState(_seenOnTurn(n, h, 2, packed: {1}));
    },
    moments: const [
      ('hammer in flight', Duration(milliseconds: 450)),
      ('hammer lands', Duration(milliseconds: 900)),
    ],
  ),
  'missile mine': _Phase(
    'my missile volley',
    room: (n, h) => _seenOnTurn(n, h, 0),
    minPlaces: 3,
    freshHand: true,
    trigger: (tester, state, n, h) async => state.handleTableAction((
      userId: 'u0',
      action: GameAction.missile,
      reason: null,
    )),
    moments: const [
      ('missiles in the air', Duration(milliseconds: 700)),
      ('explosions', Duration(milliseconds: 1500)),
    ],
  ),
  'missile other': _Phase(
    'another player\'s missile volley',
    room: (n, h) => _seenOnTurn(n, h, _other(n)),
    minPlaces: 3,
    freshHand: true,
    trigger: (tester, state, n, h) async => state.handleTableAction((
      userId: 'u${_other(n)}',
      action: GameAction.missile,
      reason: null,
    )),
    moments: const [
      ('missiles in the air', Duration(milliseconds: 700)),
      ('explosions', Duration(milliseconds: 1500)),
    ],
  ),
  'dealing': _Phase(
    'the next hand being dealt',
    room: _otherTurn,
    freshHand: true,
    trigger: (tester, state, n, h) async =>
        state.handleState(_otherTurn(n, h + 1)),
    moments: const [
      ('cards in the air', Duration(milliseconds: 450)),
      ('dealt', Duration(milliseconds: 1400)),
    ],
  ),
  'five card pick': _Phase(
    'a 5-Card hand, me choosing my three (the picker up)',
    room: (n, h) => fiveCardRoom(choosing: true),
  ),
  'menu drawer': _Phase(
    'the menu drawer open',
    room: _otherTurn,
    trigger: (tester, state, n, h) async {
      state.tableScaffold.currentState!.openDrawer();
    },
    moments: const [('drawer open', Duration(milliseconds: 700))],
    cleanup: (tester, state, n, h) async {
      state.tableScaffold.currentState!.closeDrawer();
      await _pumpFor(tester, const Duration(milliseconds: 700));
    },
    excused: const {'a drawer'},
  ),
  'player drawer': _Phase(
    'the player drawer open on another seat',
    room: _otherTurn,
    trigger: (tester, state, n, h) async {
      final pod = find.descendant(
        of: _podOf('u${_other(n)}'),
        matching: find.byType(GestureDetector),
      );
      await tester.tap(pod.first, warnIfMissed: false);
    },
    moments: const [('drawer open', Duration(milliseconds: 700))],
    cleanup: (tester, state, n, h) async {
      state.tableScaffold.currentState!.closeEndDrawer();
      await _pumpFor(tester, const Duration(milliseconds: 700));
    },
    excused: const {'a drawer'},
  ),
  'poker my turn': _Phase(
    'the poker felt, my turn',
    room: (n, h) => pokerRoom(),
  ),
  'poker other turn': _Phase(
    'the poker felt, someone else\'s turn',
    room: (n, h) => pokerMissedRoom(missed: 0),
  ),
};

// ------------------------------------------------------------ the senders

class _Case {
  const _Case(this.label, this.senders);
  final String label;
  final List<String> senders;
}

List<String> _ids(int n) => [for (var i = 0; i < n; i++) 'u$i'];

List<_Case> _solo(int n) => [
  const _Case('me alone', ['u0']),
  for (final id in _ids(n).skip(1)) _Case('${_nameOf(id)} alone', [id]),
];

List<_Case> _pairs(int n) => [
  for (final id in _ids(n).skip(1)) ...[
    _Case('me then ${_nameOf(id)}', ['u0', id]),
    _Case('${_nameOf(id)} then me', [id, 'u0']),
  ],
];

/// Everyone within 5 s: me first, me last, and (at three places or more)
/// from the far end with me in the middle.
List<_Case> _everyone(int n) {
  final others = _ids(n).skip(1).toList();
  final cases = [
    _Case('everyone, me first', ['u0', ...others]),
    _Case('everyone, me last', [...others, 'u0']),
    if (n >= 3)
      _Case('everyone, me in the middle', [
        ...others.reversed.take(n ~/ 2),
        'u0',
        ...others.reversed.skip(n ~/ 2),
      ]),
  ];
  // At two places "everyone" is a pair, which the pairs already cover.
  return n == 2 ? cases.take(2).toList() : cases;
}

// ------------------------------------------------------------ the screens

class _Screen {
  const _Screen(this.w, this.h, this.scale);
  final double w, h, scale;
  Size get size => Size(w, h);
  String get label => '${w.toInt()}x${h.toInt()} x$scale';
}

const _home = _Screen(640, 360, 1.25);
const _screens = [
  _Screen(592, 360, 1.25),
  _Screen(640, 360, 1.0),
  _home,
  _Screen(732, 412, 1.0),
  _Screen(844, 390, 1.25),
  _Screen(891, 411, 1.0),
  _Screen(915, 412, 1.25),
];

// ------------------------------------------------------------ the pixels

class _Frame {
  _Frame(this.image, this.bytes, this.w, this.h);
  final ui.Image image;
  final ByteData bytes;
  final int w, h;

  /// The pixel's strongest channel, 0..255: how bright a flat colour is.
  int valueAt(int x, int y) {
    final i = (y * w + x) * 4;
    return math.max(
      bytes.getUint8(i),
      math.max(bytes.getUint8(i + 1), bytes.getUint8(i + 2)),
    );
  }

  bool hasHue(int x, int y, double hue) {
    final i = (y * w + x) * 4;
    return _hued(
      bytes.getUint8(i),
      bytes.getUint8(i + 1),
      bytes.getUint8(i + 2),
      hue,
    );
  }

  int diff(_Frame other, int x, int y) {
    final i = (y * w + x) * 4;
    var most = 0;
    for (var c = 0; c < 3; c++) {
      most = math.max(
        most,
        (bytes.getUint8(i + c) - other.bytes.getUint8(i + c)).abs(),
      );
    }
    return most;
  }
}

/// Whether r,g,b is [hue] within 14°, saturation ≥ 0.5 and value ≥ 0.3.
bool _hued(int r, int g, int b, double hue) {
  final mx = math.max(r, math.max(g, b));
  final mn = math.min(r, math.min(g, b));
  if (mx < 77) return false;
  final d = mx - mn;
  if (d < 0.5 * mx) return false;
  final double h;
  if (mx == r) {
    h = 60 * (((g - b) / d) % 6);
  } else if (mx == g) {
    h = 60 * ((b - r) / d + 2);
  } else {
    h = 60 * ((r - g) / d + 4);
  }
  var gap = (h - hue).abs() % 360;
  if (gap > 180) gap = 360 - gap;
  return gap <= 14;
}

// ------------------------------------------------------------ the widgets

Finder _podOf(String id) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == id);

Finder _bubbleOf(String id) => find.descendant(
  of: _podOf(id),
  matching: find.byKey(const ValueKey('seat-emoji')),
);

/// The axis-aligned bounds of [e]'s box on the screen, all four corners
/// transformed (a fanned card is rotated).
Rect? _boundsOf(Element e) {
  final box = e.renderObject;
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  final s = box.size;
  final corners = [
    box.localToGlobal(Offset.zero),
    box.localToGlobal(Offset(s.width, 0)),
    box.localToGlobal(Offset(0, s.height)),
    box.localToGlobal(Offset(s.width, s.height)),
  ];
  return Rect.fromLTRB(
    corners.map((c) => c.dx).reduce(math.min),
    corners.map((c) => c.dy).reduce(math.min),
    corners.map((c) => c.dx).reduce(math.max),
    corners.map((c) => c.dy).reduce(math.max),
  );
}

/// Something drawn on the screen that could be over an emoji.
class _Cover {
  _Cover(this.name, this.element, {this.rank = 1});
  final String name;
  final Element element;

  /// 1: a thing with its own box; 2: a seat's whole column (mostly empty);
  /// 3: an overlay the size of the felt, whose drawing is somewhere in it.
  final int rank;

  /// Measured only when an emoji is not seen and something must be blamed.
  late final Rect? rect = _boundsOf(element);
}

/// Where the walk is: whose seat, whether in the viewer's own hand, inside
/// which emoji's bubble, inside the sideshow prompt.
class _Where {
  const _Where({
    this.pod,
    this.podWidget,
    this.ownHand = false,
    this.bubble,
    this.sideshow = false,
    this.picker = false,
  });
  final String? pod;
  final SeatPod? podWidget;
  final bool ownHand;
  final String? bubble;
  final bool sideshow;

  /// Inside the 5-Card picker, whose own cards are the viewer's five.
  final bool picker;

  _Where copy({
    String? pod,
    SeatPod? podWidget,
    bool? ownHand,
    String? bubble,
    bool? sideshow,
    bool? picker,
  }) => _Where(
    pod: pod ?? this.pod,
    podWidget: podWidget ?? this.podWidget,
    ownHand: ownHand ?? this.ownHand,
    bubble: bubble ?? this.bubble,
    sideshow: sideshow ?? this.sideshow,
    picker: picker ?? this.picker,
  );

  /// Whose a thing found here is, for its name.
  String get owner => picker
      ? 'the 5-Card picker\'s'
      : ownHand
      ? 'my own'
      : pod == null
      ? 'the table\'s'
      : pod!.isEmpty
      ? 'an empty seat\'s'
      : pod == 'u0'
      ? 'my'
      : '${_nameOf(pod!)}\'s';
}

const _keyedCovers = <String, (String, int)>{
  'pot': ('the pot', 1),
  'tag': ('the category tag', 1),
  'winning-tax': ('the winning-tax pill', 1),
  'status': ('the status line', 1),
  'missed-turns-pocket': ('the missed-turn pocket', 1),
  'pick-verdict': ('the 5-Card verdict', 1),
  'celebration': ('the winner\'s celebration (fireworks, pot flight)', 3),
  'test-cover': ('the test\'s box', 1),
};

/// Everything one look needs, from ONE walk of the element tree (a finder
/// walks it again for every question): every element's place in paint order
/// — pre-order, which for the Stacks and the Scaffold the table is made of
/// paints a later element over an earlier one that is not its ancestor —,
/// each seat's emoji bubble, art and place, and every candidate cover.
class _Scan {
  _Scan() {
    WidgetsBinding.instance.rootElement!.visitChildren(
      (e) => _visit(e, const _Where()),
    );
  }

  final order = <Element, int>{};
  final end = <Element, int>{};
  final bubbles = <String, Element>{};
  final arts = <String, Element>{};
  final places = <String, EmojiPlace>{};
  final pods = <String, Element>{};

  /// Each seat's own fade: a seat out of the hand (packed, lost, waiting) is
  /// drawn at under full opacity, its whole column — and its emoji — with it.
  final fades = <String, double>{};
  final covers = <_Cover>[];
  final _plaques = <String>{};
  var _next = 0;

  void _visit(Element e, _Where at) {
    order[e] = _next++;
    final w = e.widget;
    final key = w.key;
    var here = at;
    if (w is SeatPod) {
      final id = w.seat?.userId;
      here = here.copy(pod: id ?? '', podWidget: w);
      if (id != null) {
        places[id] = w.emojiPlace;
        pods[id] = e;
        covers.add(_Cover('${here.owner} seat column', e, rank: 2));
      }
    }
    if (key == const ValueKey('own-hand')) here = here.copy(ownHand: true);
    if (w is CardPickPrompt) here = here.copy(picker: true);
    if (key == const ValueKey('sideshow-prompt')) {
      here = here.copy(sideshow: true);
    }
    if (key is ValueKey<String> && _keyedCovers.containsKey(key.value)) {
      final (name, rank) = _keyedCovers[key.value]!;
      covers.add(_Cover(name, e, rank: rank));
    }
    final pod = here.pod;
    final podWidget = here.podWidget;
    if (podWidget != null && pod != null && pod.isNotEmpty) {
      final plaque = podWidget.podKey != null
          ? key == podWidget.podKey
          : w is GestureDetector;
      if (plaque && _plaques.add(pod)) {
        covers.add(_Cover('${here.owner} pod', e));
      }
    }
    var bubbleOwner = false;
    if (key == const ValueKey('seat-emoji') && pod != null && pod.isNotEmpty) {
      bubbles[pod] = e;
      covers.add(_Cover('${here.owner} emoji', e));
      here = here.copy(bubble: pod);
      bubbleOwner = true;
    }
    if (w is EmojiArt && here.bubble != null) arts[here.bubble!] = e;
    if (w is AnimatedOpacity && pod != null && pod.isNotEmpty) {
      fades.putIfAbsent(pod, () => w.opacity);
    }
    final name = switch (w) {
      PlayingCard() => '${here.owner} cards',
      SeatBet() => '${here.owner} bet badge',
      MachinedKey(:final label) => 'the "${label.replaceAll('\n', ' ')}" key',
      StepperKey() => 'a bet stepper key',
      ShopButton() => 'the Shop key',
      TableWallet() => 'the wallet pill',
      RailKey(:final tooltip) => 'the rail key "$tooltip"',
      VariationPrompt() => 'the variation picker',
      CardPickPrompt() => 'the 5-Card picker',
      MissedTurnsNotice() => 'the missed-turn notice',
      Plate() when here.sideshow => 'the sideshow prompt',
      Drawer() || DrawerSlot() || PlayerDrawer() => 'a drawer',
      SnackBar() => 'a toast',
      _ => null,
    };
    if (name != null) covers.add(_Cover(name, e));
    if (w is HammerFlight) covers.add(_Cover('the hammer', e, rank: 3));
    if (w is MissileFlight) {
      covers.add(_Cover('the missile volley', e, rank: 3));
    }
    e.visitChildren((child) => _visit(child, here));
    if (bubbleOwner) end[e] = _next - 1;
  }
}

// ------------------------------------------------------------ one look

/// One emoji, looked at once.
class _Look {
  _Look({
    required this.test,
    required this.caseLabel,
    required this.moment,
    required this.sender,
    required this.place,
    required this.art,
    required this.bubble,
    required this.visible,
    required this.bubbleChanged,
    this.strength = 0,
    this.fade = 1,
    this.occluder,
    this.occluderRect,
    this.occluderShare = 0,
    this.alsoUnder = const [],
    this.missing = false,
  });

  final String test, caseLabel, moment, sender, place;
  final Rect? art, bubble;
  final double visible, bubbleChanged;

  /// How brightly the seen part of the art is drawn, 0..1 — 1 for a flat
  /// colour at full strength; a translucent layer over it, or its seat's own
  /// fade, brings it down.
  final double strength;

  /// The opacity the sender's seat is drawn at (1 unless it is out of the
  /// hand), which the emoji inherits.
  final double fade;

  bool get faint => !hidden && strength < _faintBelow;
  final String? occluder;
  final Rect? occluderRect;
  final double occluderShare;
  final List<String> alsoUnder;
  final bool missing;
  final overlaps = <String>[];
  bool excused = false;

  bool get hidden => missing || visible < _visibleAtLeast;

  String get who => '${_nameOf(sender)} ($sender)';

  String describe() {
    final at = moment.isEmpty ? '' : ' @ $moment';
    if (missing) return '$caseLabel$at: ${_nameOf(sender)}\'s emoji not drawn';
    final cover = occluder == null
        ? ''
        : '; under $occluder ${_r(occluderRect)} '
              '(${(occluderShare * 100).round()}% of the unseen part)'
              '${alsoUnder.isEmpty ? '' : ', also ${alsoUnder.join(', ')}'}';
    return '$caseLabel$at: $who emoji (${place.split('.').last}) '
        '${(visible * 100).toStringAsFixed(0)}% visible, art ${_r(art)}, '
        'bubble ${_r(bubble)}$cover'
        '${overlaps.isEmpty ? '' : '; overlaps ${overlaps.join(', ')}'}';
  }

  Map<String, dynamic> toJson() => {
    'test': test,
    'case': caseLabel,
    'moment': moment,
    'sender': sender,
    'place': place.split('.').last,
    'art': _rj(art),
    'bubble': _rj(bubble),
    'visible': double.parse(visible.toStringAsFixed(3)),
    'bubbleChanged': double.parse(bubbleChanged.toStringAsFixed(3)),
    'strength': double.parse(strength.toStringAsFixed(3)),
    'seatFade': fade,
    'hidden': hidden,
    'excused': excused,
    'occluder': occluder,
    'occluderRect': _rj(occluderRect),
    'occluderShare': double.parse(occluderShare.toStringAsFixed(3)),
    'alsoUnder': alsoUnder,
    'overlaps': overlaps,
    'missing': missing,
  };
}

String _r(Rect? r) => r == null
    ? '-'
    : '(${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)} '
          '${r.width.toStringAsFixed(0)}x${r.height.toStringAsFixed(0)})';

List<double>? _rj(Rect? r) => r == null
    ? null
    : [
        for (final v in [r.left, r.top, r.width, r.height])
          double.parse(v.toStringAsFixed(1)),
      ];

/// Looks at every emoji in [senders] on [during], against [baseline].
List<_Look> _lookAt({
  required String test,
  required String caseLabel,
  required String moment,
  required List<String> senders,
  required _Frame baseline,
  required _Frame during,
}) {
  final scan = _Scan();
  final looks = <_Look>[];
  for (final id in senders) {
    final bubbleEl = scan.bubbles[id];
    final artEl = scan.arts[id];
    final art = artEl == null ? null : _boundsOf(artEl);
    final bubble = bubbleEl == null ? null : _boundsOf(bubbleEl);
    if (bubbleEl == null || art == null || bubble == null) {
      looks.add(
        _Look(
          test: test,
          caseLabel: caseLabel,
          moment: moment,
          sender: id,
          place: '-',
          art: null,
          bubble: null,
          visible: 0,
          bubbleChanged: 0,
          missing: true,
        ),
      );
      continue;
    }
    final place = scan.places[id]?.name ?? '-';
    final hue = _hues[id]!;

    // The art's pixels, 1dp in from its antialiased edge.
    final inner = art.deflate(1);
    var total = 0, seen = 0, offScreen = 0, brightness = 0;
    final unseen = <(int, int)>[];
    for (var y = inner.top.ceil(); y < inner.bottom.floor(); y++) {
      for (var x = inner.left.ceil(); x < inner.right.floor(); x++) {
        total++;
        if (x < 0 || y < 0 || x >= during.w || y >= during.h) {
          offScreen++;
          continue;
        }
        if (during.hasHue(x, y, hue) && !baseline.hasHue(x, y, hue)) {
          seen++;
          brightness += during.valueAt(x, y);
        } else {
          unseen.add((x, y));
        }
      }
    }
    final visible = total == 0 ? 0.0 : seen / total;

    // How much of the whole bubble changed since the baseline (for the
    // report; the skin is near the room's own colour at night).
    var bubbleTotal = 0, bubbleDiff = 0;
    for (var y = bubble.top.ceil(); y < bubble.bottom.floor(); y++) {
      for (var x = bubble.left.ceil(); x < bubble.right.floor(); x++) {
        if (x < 0 || y < 0 || x >= during.w || y >= during.h) continue;
        bubbleTotal++;
        if (during.diff(baseline, x, y) > 16) bubbleDiff++;
      }
    }

    // What paints over it, where it was not seen — asked of a partly covered
    // emoji too, for the report. At each unseen pixel the cover that paints
    // LAST among those whose box holds it is the one on top there: first
    // among the things with a box of their own, then the seats' whole
    // columns, then the overlays the size of the felt.
    String? occluder;
    Rect? occluderRect;
    var share = 0.0;
    final also = <String>[];
    if (visible < _partlyBelow) {
      final mine = scan.order[bubbleEl]!;
      final last = scan.end[bubbleEl] ?? mine;
      final above =
          [
            for (final c in scan.covers)
              if ((scan.order[c.element] ?? -1) > last &&
                  (c.rect?.overlaps(art) ?? false))
                c,
          ]..sort(
            (a, b) => scan.order[b.element]!.compareTo(scan.order[a.element]!),
          );
      // Failing all of those, the sender's own seat: its column paints what
      // follows the emoji in it (the head seat's cards, bet and In Pot beside
      // its pod; the rest of a column under a pod it stands above or beside)
      // over the emoji, and those parts are not candidates of their own.
      final ownSeat = scan.pods[id];
      final own = ownSeat == null
          ? null
          : _Cover(
              '${id == 'u0' ? 'my' : '${_nameOf(id)}\'s'} own seat (its cards, '
              'stack or In Pot, painted after its emoji)',
              ownSeat,
            );
      final hits = <String, int>{};
      final rects = <String, Rect>{};
      for (final (x, y) in unseen) {
        final p = Offset(x + 0.5, y + 0.5);
        _Cover? top;
        for (final rank in const [1, 2, 3]) {
          top = above
              .where((c) => c.rank == rank && c.rect!.contains(p))
              .firstOrNull;
          if (top != null) break;
        }
        if (top == null && (own?.rect?.contains(p) ?? false)) top = own;
        if (top == null) continue;
        hits[top.name] = (hits[top.name] ?? 0) + 1;
        rects[top.name] = rects[top.name] == null
            ? top.rect!
            : rects[top.name]!.expandToInclude(top.rect!);
      }
      final onScreen = unseen.length;
      final ranked = hits.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (ranked.isNotEmpty &&
          (offScreen == 0 || ranked.first.value >= offScreen)) {
        final best = ranked.first;
        occluder = best.key;
        occluderRect = rects[best.key];
        share = best.value / (onScreen + offScreen);
        also.addAll([
          for (final e in ranked.skip(1))
            if (e.value >= 0.1 * (onScreen + offScreen))
              '${e.key} (${(100 * e.value / (onScreen + offScreen)).round()}%)',
        ]);
      } else if (offScreen > 0) {
        occluder = 'the edge of the screen';
        share = offScreen / (onScreen + offScreen);
      } else {
        occluder =
            'nothing found above it (clipped, or under a layer '
            'with no box of its own)';
      }
    }
    looks.add(
      _Look(
        test: test,
        caseLabel: caseLabel,
        moment: moment,
        sender: id,
        place: place,
        art: art,
        bubble: bubble,
        visible: visible,
        bubbleChanged: bubbleTotal == 0 ? 0 : bubbleDiff / bubbleTotal,
        strength: seen == 0 ? 0 : brightness / seen / 255,
        fade: scan.fades[id] ?? 1,
        occluder: occluder,
        occluderRect: occluderRect,
        occluderShare: share,
        alsoUnder: also,
      ),
    );
  }
  // Emojis meeting each other, by their bubbles.
  for (var i = 0; i < looks.length; i++) {
    for (var j = i + 1; j < looks.length; j++) {
      final a = looks[i].bubble, b = looks[j].bubble;
      if (a == null || b == null) continue;
      if (a.deflate(2).overlaps(b.deflate(2))) {
        final meet = a.intersect(b);
        looks[i].overlaps.add('${looks[j].who} by ${_r(meet)}');
        looks[j].overlaps.add('${looks[i].who} by ${_r(meet)}');
      }
    }
  }
  return looks;
}

// ------------------------------------------------------------ the table

final _cover = ValueNotifier<(Rect, Color)?>(null);

class _Table {
  _Table(this.tester, this.state, this.boundary);
  final WidgetTester tester;
  final GameState state;
  final GlobalKey boundary;

  Future<_Frame> grab() async {
    final frame = await tester.runAsync(() async {
      final b =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await b.toImage();
      final data = await image.toByteData();
      return _Frame(image, data!, image.width, image.height);
    });
    return frame!;
  }

  Future<void> dispose(_Frame frame) async =>
      tester.runAsync(() async => frame.image.dispose());

  /// Writes [frame] to EMOJI_SHOTS as a PNG named after [what].
  Future<void> save(_Frame frame, String what) async {
    final file = what
        .replaceAll(RegExp(r'[^A-Za-z0-9.]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    await tester.runAsync(() async {
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      File(
        '$_shotsDir/${file.length > 180 ? file.substring(0, 180) : file}.png',
      ).writeAsBytesSync(png!.buffer.asUint8List());
    });
  }

  /// Lets anything loading from disk (the card backs, the fireworks, the
  /// hammer and missile art) finish, as a phone would long before a hand.
  Future<void> settle(Duration d) async {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(d);
  }
}

/// A widget test with shadows drawn soft, as a phone draws them (the test
/// binding draws every shadow as a solid block unless told not to, which
/// would ring the bubbles and keys in black), put back before the binding
/// checks it.
void _testTable(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(name, (tester) async {
      debugDisableShadows = false;
      try {
        await body(tester);
      } finally {
        debugDisableShadows = true;
      }
    });

Future<_Table> _mount(
  WidgetTester tester, {
  required int places,
  required RoomState room,
  required _Screen screen,
  required bool dark,
  GameConnection? connection,
}) async {
  tester.view.physicalSize = screen.size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = screen.scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  // Seated as Priya (u0), as table_scenes.dart's sceneState seats her, with
  // her own emoji owned for the emoji key and, where given, a socket that
  // records what she sends.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(
    serverUrl: 'http://127.0.0.1:9',
    connection: connection,
  );
  debugDefaultTargetPlatformOverride = null;
  state
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Priya',
      'chips': 245000,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
    })
    ..emojis = [
      EmojiItem(id: 1, name: 'Emoji of Priya', url: _url('u0'), owned: true),
    ]
    ..screen = Screen.table
    ..config = state.config.copyWith(maxPlayers: places)
    ..handleState(room);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: Stack(
        textDirection: TextDirection.ltr,
        children: [
          tableApp(
            state: state,
            feedback: feedback,
            theme: dark
                ? AppTheme.dark(sound: false)
                : AppTheme.light(sound: false),
          ),
          ValueListenableBuilder<(Rect, Color)?>(
            valueListenable: _cover,
            builder: (context, cover, _) => cover == null
                ? const SizedBox.shrink()
                : Positioned.fromRect(
                    rect: cover.$1,
                    child: ColoredBox(
                      key: const ValueKey('test-cover'),
                      color: cover.$2,
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
  final table = _Table(tester, state, key);
  await table.settle(const Duration(milliseconds: 900));
  await table.settle(const Duration(milliseconds: 900));
  return table;
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  _cover.value = null;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

/// Sends [senders]' emojis 350ms apart, and lets the last one land.
Future<void> _send(_Table t, List<String> senders) async {
  for (var i = 0; i < senders.length; i++) {
    t.state.handleChat(_emojiLine(senders[i]));
    await t.tester.pump();
    await t.tester.pump();
    await t.tester.pump(
      Duration(milliseconds: i == senders.length - 1 ? 450 : 350),
    );
  }
}

// ------------------------------------------------------------ the run

final _allLooks = <_Look>[];
final _calibration = <String, double>{};
var _testsRun = 0;
var _casesRun = 0;

/// Captures the screen now and looks at every emoji [senders] sent, against
/// [baseline]: records each look for the report, adds what is hidden (unless
/// by an [excused] cover) or overlapping to [problems], and — with
/// EMOJI_SHOTS set — pictures a moment where anything is not wholly seen.
Future<void> _judge(
  _Table table, {
  required String test,
  required String caseLabel,
  required String moment,
  required List<String> senders,
  required _Frame baseline,
  required Set<String> excused,
  required List<String> problems,
}) async {
  final during = await table.grab();
  final looks = _lookAt(
    test: test,
    caseLabel: caseLabel,
    moment: moment,
    senders: senders,
    baseline: baseline,
    during: during,
  );
  var worth = false;
  for (final look in looks) {
    look.excused =
        look.hidden &&
        !look.missing &&
        look.overlaps.isEmpty &&
        excused.contains(look.occluder);
    _allLooks.add(look);
    if ((look.hidden || look.overlaps.isNotEmpty) && !look.excused) {
      problems.add(look.describe());
    }
    if (look.visible < _partlyBelow || look.overlaps.isNotEmpty) worth = true;
  }
  if (worth && _shotsDir.isNotEmpty) {
    await table.save(during, '${test.split(' — ').first} $caseLabel $moment');
  }
  await table.dispose(during);
}

void _expectNone(List<String> problems) => expect(
  problems,
  isEmpty,
  reason:
      '\n${problems.length} emoji(s) hidden (under '
      '${(_visibleAtLeast * 100).round()}% of the art seen) or '
      'overlapping:\n  ${problems.join('\n  ')}\n',
);

/// A socket that records the emojis the viewer sends instead of sending them.
class _Recorder extends GameConnection {
  _Recorder() : super('http://127.0.0.1:9');

  final sent = <int>[];

  @override
  void sendEmoji(int emojiId) => sent.add(emojiId);
}

/// End to end, as a player does it: the viewer opens the table's emoji key,
/// taps their emoji — `chat:emoji` goes out and the drawer shuts — and the
/// server's echo (`chat:message` with the emoji) comes back to every phone,
/// theirs included; with [othersFirst], everybody else's emoji is already
/// playing when they do. The chat's cooldown runs on the wall clock, so one
/// send from the key per test.
void _endToEnd({
  required int places,
  required _Phase phase,
  required bool othersFirst,
  _Screen screen = _home,
}) {
  final what = othersFirst
      ? 'everyone else, then me from the emoji key'
      : 'me alone from the emoji key';
  final name =
      '$places places, ${phase.label}, ${screen.label} dark — end to end, '
      '$what: every emoji visible, none overlap';
  if (_only.isNotEmpty && !name.contains(_only)) return;
  _testTable(name, (tester) async {
    _testsRun++;
    _casesRun++;
    final socket = _Recorder();
    final table = await _mount(
      tester,
      places: places,
      room: phase.room(places, 20),
      screen: screen,
      dark: true,
      connection: socket,
    );
    final baseline = await table.grab();
    final others = _ids(places).skip(1).toList();
    if (othersFirst) await _send(table, others);
    await tester.tap(find.byKey(const ValueKey('rail-emoji')));
    await _pumpFor(tester, const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('emoji-send-1')));
    await _pumpFor(tester, const Duration(milliseconds: 400));
    expect(socket.sent, [1], reason: 'chat:emoji went out with her emoji');
    expect(find.byType(EmojiDrawer), findsNothing, reason: 'the drawer shut');
    await _send(table, ['u0']);
    final problems = <String>[];
    await _judge(
      table,
      test: name,
      caseLabel: what,
      moment: '',
      senders: [if (othersFirst) ...others, 'u0'],
      baseline: baseline,
      excused: const {},
      problems: problems,
    );
    await table.dispose(baseline);
    await tester.pump(GameState.chatCooldown);
    expect(tester.takeException(), isNull);
    await _unmount(tester, table.state);
    _expectNone(problems);
  });
}

/// One test: [phase] at [places] places on [screen], the [cases] played one
/// after the other, each once its emojis are sent, and every moment the phase
/// names looked at. Fails naming every emoji hidden or overlapping another.
void _scenario({
  required int places,
  required _Phase phase,
  required List<_Case> cases,
  required String casesLabel,
  _Screen screen = _home,
  bool dark = true,
}) {
  final theme = dark ? 'dark' : 'light';
  final name =
      '$places places, ${phase.label}, ${screen.label} $theme — '
      '$casesLabel: every emoji visible, none overlap';
  if (_only.isNotEmpty && !name.contains(_only)) return;
  _testTable(name, (tester) async {
    _testsRun++;
    var hand = 20;
    final table = await _mount(
      tester,
      places: places,
      room: phase.room(places, hand),
      screen: screen,
      dark: dark,
    );
    final problems = <String>[];
    for (final c in cases) {
      _casesRun++;
      if (phase.freshHand) hand += 2;
      table.state.handleState(phase.room(places, hand));
      await _pumpFor(
        tester,
        Duration(milliseconds: phase.freshHand ? 1600 : 300),
      );
      final baseline = await table.grab();
      await _send(table, c.senders);
      if (phase.trigger case final trigger?) {
        await trigger(tester, table.state, places, hand);
        await tester.pump();
      }
      var at = Duration.zero;
      for (final (moment, offset) in phase.moments) {
        if (offset > at) await tester.pump(offset - at);
        at = offset;
        await _judge(
          table,
          test: name,
          caseLabel: c.label,
          moment: moment,
          senders: c.senders,
          baseline: baseline,
          excused: phase.excused,
          problems: problems,
        );
      }
      await table.dispose(baseline);
      if (phase.cleanup case final cleanup?) {
        await cleanup(tester, table.state, places, hand);
      }
      // Every emoji of this case plays out before the next is sent.
      await tester.pump(GameState.emojiBubbleFor);
      await tester.pump(const Duration(milliseconds: 600));
    }
    expect(tester.takeException(), isNull);
    await _unmount(tester, table.state);
    _expectNone(problems);
  });
}

void _printReport() {
  bool problem(_Look l) => (l.hidden || l.overlaps.isNotEmpty) && !l.excused;
  final bad = _allLooks.where(problem).toList();
  final excused = _allLooks.where((l) => l.excused).toList();
  final partly = _allLooks
      .where((l) => !problem(l) && !l.excused && l.visible < _partlyBelow)
      .toList();
  final out = StringBuffer()
    ..writeln()
    ..writeln('=' * 78)
    ..writeln(
      'EMOJI VISIBILITY: $_testsRun tests, $_casesRun cases, '
      '${_allLooks.length} emoji looks; visible = at least '
      '${(_visibleAtLeast * 100).round()}% of the art seen',
    );
  if (_calibration.isNotEmpty) {
    final values = [
      for (final e in _calibration.entries)
        '${e.key} ${(e.value * 100).toStringAsFixed(1)}%',
    ];
    out.writeln('calibration: ${values.join(', ')}');
  }
  // What hides them, counted once per test, case and emoji.
  final byCover = <String, Set<String>>{};
  for (final l in bad) {
    final cause = l.missing
        ? 'not drawn'
        : l.hidden
        ? l.occluder ?? '?'
        : 'overlapping another emoji';
    byCover
        .putIfAbsent(cause, () => {})
        .add('${l.test}|${l.caseLabel}|${l.sender}');
  }
  out.writeln(
    'hidden or overlapping: ${bad.length} looks in '
    '${bad.map((l) => l.test).toSet().length} tests; by likely cause '
    '(each test, case and emoji once):',
  );
  final causes = byCover.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  for (final e in causes) {
    out.writeln('  ${e.value.length.toString().padLeft(4)} x ${e.key}');
  }
  String? last;
  for (final l in bad) {
    if (l.test != last) {
      out.writeln('- ${l.test}');
      last = l.test;
    }
    out.writeln('    ${l.describe()}');
  }
  if (partly.isNotEmpty) {
    final least = partly.map((l) => l.visible).reduce(math.min);
    out.writeln(
      'partly covered but visible (information, not failed): '
      '${partly.length} looks, the least ${(least * 100).round()}% seen; by '
      'what covers them:',
    );
    final partlyBy = <String, int>{};
    for (final l in partly) {
      final cause = l.occluder ?? '?';
      partlyBy[cause] = (partlyBy[cause] ?? 0) + 1;
    }
    final sorted = partlyBy.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted) {
      out.writeln('  ${e.value.toString().padLeft(4)} x ${e.key}');
    }
  }
  final faint = _allLooks.where((l) => l.faint && !l.excused).toList();
  if (faint.isNotEmpty) {
    final seatFaded = faint.where((l) => l.fade < 1).toList();
    out.writeln(
      'faint but visible (information, not failed): ${faint.length} looks '
      'drawn under ${(_faintBelow * 100).round()}% strength — '
      '${seatFaded.length} from a seat drawn faded (out of the hand: its '
      'emoji inherits the seat\'s opacity), the rest under a scrim; e.g.:',
    );
    final shown = <String>{};
    for (final l in faint) {
      final head = l.test.split(' — ').first;
      if (!shown.add('$head ${l.sender}') || shown.length > 8) continue;
      out.writeln(
        '    $head: ${l.who} at ${(l.strength * 100).round()}% strength'
        '${l.fade < 1 ? ', seat opacity ${l.fade}' : ''}',
      );
    }
  }
  if (excused.isNotEmpty) {
    out.writeln(
      'under an open drawer (by design, not failed): ${excused.length} looks',
    );
  }
  out.writeln('=' * 78);
  stdout.write(out);
  if (_reportPath.isNotEmpty) {
    File(_reportPath).writeAsStringSync(
      const JsonEncoder.withIndent(
        ' ',
      ).convert([for (final l in _allLooks) l.toJson()]),
    );
  }
}

Future<void> _loadFonts() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
  const given = String.fromEnvironment('ICON_FONT');
  final root = Platform.environment['FLUTTER_ROOT'];
  for (final path in [
    if (given.isNotEmpty) given,
    if (root != null)
      '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await loader.load();
    break;
  }
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    for (final MapEntry(key: id, value: rgb) in _rgb.entries) {
      PictureCache.prime(_url(id), _flatLottie(rgb));
    }
  });
  tearDownAll(() {
    _printReport();
    PictureCache.clearMemory();
  });

  // ------------------------------------------------------- the calibration
  group('the measure', () {
    Future<(_Table, _Frame)> meera(WidgetTester tester) async {
      final table = await _mount(
        tester,
        places: 5,
        room: _otherTurn(5, 7),
        screen: _home,
        dark: true,
      );
      final baseline = await table.grab();
      await _send(table, ['u2']);
      return (table, baseline);
    }

    Future<_Look> look(_Table t, _Frame baseline, String label) async {
      final l = _lookAt(
        test: 'calibration',
        caseLabel: 'Meera alone',
        moment: '',
        senders: ['u2'],
        baseline: baseline,
        during: await t.grab(),
      ).single;
      _calibration[label] = l.visible;
      return l;
    }

    _testTable('a lone emoji over the open felt measures wholly visible', (
      tester,
    ) async {
      final (table, baseline) = await meera(tester);
      final l = await look(table, baseline, 'alone on the felt');
      expect(l.visible, greaterThan(0.97), reason: l.describe());
      expect(l.strength, greaterThan(0.95), reason: 'drawn at full strength');
      await _unmount(tester, table.state);
    });

    _testTable('dimmed under a half-black box it measures visible, and faint', (
      tester,
    ) async {
      final (table, baseline) = await meera(tester);
      final art = tester.getRect(
        find.descendant(of: _bubbleOf('u2'), matching: find.byType(EmojiArt)),
      );
      _cover.value = (art.inflate(4), Colors.black.withValues(alpha: 0.5));
      await tester.pump();
      final l = await look(table, baseline, 'under a 50% black box');
      expect(l.visible, greaterThan(0.97), reason: l.describe());
      expect(l.strength, inInclusiveRange(0.4, 0.6), reason: 'and reads faint');
      expect(l.faint, isTrue);
      await _unmount(tester, table.state);
    });

    _testTable('an opaque box over its left half measures half visible', (
      tester,
    ) async {
      final (table, baseline) = await meera(tester);
      final art = tester.getRect(
        find.descendant(of: _bubbleOf('u2'), matching: find.byType(EmojiArt)),
      );
      _cover.value = (
        Rect.fromLTRB(art.left - 4, art.top - 4, art.center.dx, art.bottom + 4),
        Colors.black,
      );
      await tester.pump();
      final l = await look(table, baseline, 'left half under an opaque box');
      expect(l.visible, inInclusiveRange(0.45, 0.55), reason: l.describe());
      await _unmount(tester, table.state);
    });

    _testTable('an opaque box over all of it measures hidden, and is named', (
      tester,
    ) async {
      final (table, baseline) = await meera(tester);
      final art = tester.getRect(
        find.descendant(of: _bubbleOf('u2'), matching: find.byType(EmojiArt)),
      );
      _cover.value = (art.inflate(4), Colors.black);
      await tester.pump();
      final l = await look(table, baseline, 'all under an opaque box');
      expect(l.visible, lessThan(0.02), reason: l.describe());
      expect(l.occluder, 'the test\'s box');
      await _unmount(tester, table.state);
    });
  });

  // ---------------------------------------------- senders × table sizes × turn
  // At the home screen: every sender alone, me with each seat in both orders,
  // everyone within 5 s — at 2, 3, 4 and 5 places, on my turn and off it.
  for (final places in [2, 3, 4, 5]) {
    for (final phase in [_myTurnPhase, _otherTurnPhase]) {
      _scenario(
        places: places,
        phase: phase,
        cases: _solo(places),
        casesLabel: 'me alone, each seat alone',
      );
      _scenario(
        places: places,
        phase: phase,
        cases: _pairs(places),
        casesLabel: 'me then each seat, each seat then me',
      );
      if (places > 2) {
        _scenario(
          places: places,
          phase: phase,
          cases: _everyone(places),
          casesLabel:
              'everyone within 5 s: me first, me last, me in the middle',
        );
      }
    }
  }

  // ------------------------------------------- table states and overlays
  // Each at every table size it can happen at: me alone, each seat alone,
  // and everyone, me first and me last.
  for (final key in [
    'waiting',
    'starting',
    'showdown other',
    'showdown mine',
    'missed',
    'missed last',
    'variation mine',
    'variation other',
    'sideshow to me',
    'hammer mine',
    'hammer others',
    'missile mine',
    'missile other',
    'dealing',
  ]) {
    final phase = _phases[key]!;
    for (final places in [2, 3, 4, 5]) {
      if (places < phase.minPlaces) continue;
      _scenario(
        places: places,
        phase: phase,
        cases: [..._solo(places), ..._everyone(places).take(2)],
        casesLabel: 'me alone, each seat alone, everyone (me first, me last)',
      );
    }
  }
  for (final key in ['five card pick', 'menu drawer', 'player drawer']) {
    _scenario(
      places: 5,
      phase: _phases[key]!,
      cases: [..._solo(5), ..._everyone(5).take(2)],
      casesLabel: 'me alone, each seat alone, everyone (me first, me last)',
    );
  }

  // ----------------------------------------------------------- the screens
  for (final screen in _screens) {
    if (screen == _home) continue;
    for (final places in [2, 3, 4, 5]) {
      for (final phase in [_myTurnPhase, _otherTurnPhase]) {
        _scenario(
          places: places,
          phase: phase,
          screen: screen,
          cases: [
            const _Case('me alone', ['u0']),
            ..._everyone(places),
          ],
          casesLabel: places == 2
              ? 'me alone, me then the head seat, the head seat then me'
              : 'me alone, everyone (me first, me last, me in the middle)',
        );
      }
    }
  }

  // ------------------------------------------------------------ the themes
  for (final screen in const [_home, _Screen(891, 411, 1.0)]) {
    for (final places in [2, 4, 5]) {
      for (final phase in [_myTurnPhase, _otherTurnPhase]) {
        _scenario(
          places: places,
          phase: phase,
          screen: screen,
          dark: false,
          cases: [..._solo(places), ..._everyone(places).take(2)],
          casesLabel: 'me alone, each seat alone, everyone (me first, me last)',
        );
      }
    }
  }

  // ------------------------------------------------------- the risky pairs
  // The head seat (two and four places) with me, on the narrowest and the
  // widest phone; the overlays that cover the felt on both.
  for (final screen in const [
    _Screen(592, 360, 1.25),
    _Screen(915, 412, 1.25),
  ]) {
    for (final places in [2, 4]) {
      for (final phase in [_myTurnPhase, _otherTurnPhase]) {
        _scenario(
          places: places,
          phase: phase,
          screen: screen,
          cases: _pairs(places),
          casesLabel: 'me then each seat, each seat then me',
        );
      }
    }
    for (final key in [
      'variation mine',
      'sideshow to me',
      'missed last',
      'showdown mine',
    ]) {
      for (final places in [3, 5]) {
        _scenario(
          places: places,
          phase: _phases[key]!,
          screen: screen,
          cases: [..._solo(places), ..._everyone(places).take(2)],
          casesLabel: 'me alone, each seat alone, everyone (me first, me last)',
        );
      }
    }
  }

  // --------------------------------------------------------- the poker felt
  for (final key in ['poker my turn', 'poker other turn']) {
    final phase = _phases[key]!;
    _scenario(
      places: 5,
      phase: phase,
      cases: _solo(5),
      casesLabel: 'me alone, each seat alone',
    );
    _scenario(
      places: 5,
      phase: phase,
      cases: _pairs(5),
      casesLabel: 'me then each seat, each seat then me',
    );
    for (final screen in const [
      _Screen(592, 360, 1.25),
      _home,
      _Screen(915, 412, 1.25),
    ]) {
      _scenario(
        places: 5,
        phase: phase,
        screen: screen,
        cases: _everyone(5),
        casesLabel: 'everyone within 5 s: me first, me last, me in the middle',
      );
    }
  }

  // ------------------------------------------------------------ end to end
  // Sent from the table's emoji key and echoed back, at every table size, on
  // my turn and off it, alone and after everybody else's.
  for (final places in [2, 3, 4, 5]) {
    for (final phase in [_myTurnPhase, _otherTurnPhase]) {
      for (final othersFirst in [false, true]) {
        _endToEnd(places: places, phase: phase, othersFirst: othersFirst);
      }
    }
  }
  _endToEnd(places: 5, phase: _phases['poker my turn']!, othersFirst: true);
}
