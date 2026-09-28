import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import 'seat_pod.dart';
import 'seat_ring.dart';

/// The controls a table screen stands over its felt's corners — the Shop
/// key, the wallet, and the keys at the foot on either side — keyed so the
/// felt can measure them: an emoji moved beside a pod is never put where one
/// of them would be drawn over it ([EmojiPlacement]).
///
/// Owned by the table screen's State, which keys the controls with it and
/// hands it to its felt; both felts (Teen Patti and poker) have one.
class FeltCovers {
  final GlobalKey shop = GlobalKey(debugLabel: 'felt cover: shop');
  final GlobalKey wallet = GlobalKey(debugLabel: 'felt cover: wallet');
  final GlobalKey footLeft = GlobalKey(debugLabel: 'felt cover: foot left');
  final GlobalKey footRight = GlobalKey(debugLabel: 'felt cover: foot right');

  List<GlobalKey> get all => [shop, wallet, footLeft, footRight];
}

/// Where one emoji plays: its [EmojiPlace], and for [EmojiPlace.above] how
/// far sideways from straight above the pod it stands ([SeatPod.emojiShift]).
typedef EmojiSpot = ({EmojiPlace place, double shift});

/// Keeps the emojis a felt is playing apart (owner, 28 Sep 2026: "when two
/// players send emoji in any game table then their emoji should not overlap,
/// if overlap then change the direction so that it does not overlap"), and
/// never under anything drawn after them (the review of 28 Sep 2026).
///
/// Mixed into both felts' States — the Teen Patti `_Felt` and the poker
/// `_PokerFelt` — which say where their Stack, their pods, their seats and
/// what covers their seats are ([emojiStage], [emojiPods], [emojiSeats],
/// [emojiCoversOver]), key each [SeatPod]'s emoji with [emojiKeyAt], build it
/// at [emojiPlaceOf] / [emojiShiftOf], and call [followEmojis] from `build`.
///
/// **The paint order it assumes, which both felts keep**: the seats round the
/// rim in view order, then the viewer's, then whatever [emojiCoversOver]
/// names — the viewer's own hand, which each felt draws after every seat, and
/// the controls its screen stands over the felt. An emoji moved beside or
/// above its pod is drawn in that pod's own layer (SeatPod's Stack), so any
/// seat painted after its own, the part of its own seat that stands beside
/// its pod (the head seat's cards, drawn after the pod), and anything over
/// every seat would be drawn over it: a place that meets any of those is no
/// place. (The review found the viewer's moved emoji three quarters under
/// their own cards, and its other side under Missile and Pack. Drawing it
/// over the hand instead would have hidden the viewer's cards; it goes where
/// nothing is drawn over it.)
mixin EmojiPlacement<T extends StatefulWidget> on State<T> {
  /// The felt's Stack, which everything is measured against.
  GlobalKey get emojiStage;

  /// Each place's pod (its plaque), in view order: what an emoji points at,
  /// and what another seat's emoji would rather not cover.
  List<GlobalKey> get emojiPods;

  /// Each place's whole seat as the felt paints it — the [SeatPod]: pod,
  /// cards, bet — in view order.
  List<GlobalKey> get emojiSeats;

  /// What the felt paints over every seat and the screen stands over the
  /// felt, in the felt's coordinates. [rectOf] measures a key's box there,
  /// wherever in the screen it is; null when it is not laid out.
  Iterable<Rect> emojiCoversOver(Rect? Function(GlobalKey key) rectOf);

  /// One key per place, naming the emoji bubble playing there, wherever it
  /// stands — so the felt can see where it landed.
  final List<GlobalKey> emojiKeys = List.generate(
    SeatRing.maxSeats,
    (i) => GlobalKey(debugLabel: 'emoji $i'),
  );

  /// The emoji each player is sending as the felt last saw it — the line
  /// itself, so a second one queued behind it counts as new — and where each
  /// plays. A player missing from [_emojiSpots] has an emoji that has not
  /// been placed yet: it is drawn in its bubble's own place for one frame, at
  /// the start of its pop-in (fully transparent), measured, and moved if it
  /// meets another.
  final Map<String, ChatMessage> _emojiSeen = {};
  final Map<String, EmojiSpot> _emojiSpots = {};
  bool _emojiPlacing = false;

  /// Where [userId]'s emoji plays.
  EmojiPlace emojiPlaceOf(String? userId) =>
      _emojiSpots[userId]?.place ?? EmojiPlace.column;

  /// How far sideways [userId]'s emoji stands, above its pod.
  double emojiShiftOf(String? userId) => _emojiSpots[userId]?.shift ?? 0;

  /// The key for the emoji at place [view].
  GlobalKey? emojiKeyAt(int view) =>
      view >= 0 && view < emojiKeys.length ? emojiKeys[view] : null;

  /// Keeps the felt on the emojis [GameState] is playing: one that has gone
  /// forgets its place, and a new one — a player's first, or the next one
  /// queued behind it — is placed after this frame, once it has been laid out
  /// where its bubble would be.
  void followEmojis(Map<String, ChatMessage> shown) {
    for (final id in _emojiSeen.keys.toList()) {
      if (!shown.containsKey(id)) {
        _emojiSeen.remove(id);
        _emojiSpots.remove(id);
      }
    }
    var fresh = false;
    for (final MapEntry(key: id, value: line) in shown.entries) {
      if (identical(_emojiSeen[id], line)) continue;
      _emojiSeen[id] = line;
      _emojiSpots.remove(id);
      fresh = true;
    }
    if (!fresh || _emojiPlacing) return;
    _emojiPlacing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _placeEmojis());
  }

  /// Gives every emoji that has just arrived a place where it meets no emoji
  /// already playing, and where nothing drawn after it covers it.
  ///
  /// The ones already playing keep where they are; the new ones are placed in
  /// the order they were sent (the server's stamp, the same on every phone),
  /// each taking the first of its seat's places that stays on the felt, meets
  /// none placed before it and lies under nothing painted after its seat (the
  /// class doc; a place under something is no place, however clear):
  ///
  /// * the bubble's own place, which it has whatever the rest of the felt
  ///   paints — so it is only asked to meet no emoji;
  /// * for a seat round the rim, beside the pod towards the middle of the
  ///   table, above it, and beside it on the other side;
  /// * for the viewer, beside the pod on the left, then on the right. The
  ///   right is where their own hand stands or will (the felt names that
  ///   whole zone, not only the cards dealt), so it is never taken; the left
  ///   is under Missile and Pack, or off the felt, on every phone;
  /// * and last, for every seat, above the pod slid sideways by as little as
  ///   puts it a step clear of what is in the way, never so far that it stops
  ///   standing over some of the pod — its pointer leans down to the pod
  ///   ([SeatPod.emojiShift]). This is where the viewer's goes when the emoji
  ///   of the seat whose column stands over their pod (the upper-left seat,
  ///   at five places) is already playing.
  ///
  /// A place that would cover another player's pod — one painted before this
  /// seat, since one painted after it covers the place — is taken only when
  /// every place clear of the pods meets an emoji or lies under something.
  /// Where nothing fits, the bubble's own place.
  void _placeEmojis() {
    _emojiPlacing = false;
    if (!mounted) return;
    final stage = emojiStage.currentContext?.findRenderObject();
    if (stage is! RenderBox || !stage.attached || !stage.hasSize) return;
    final seats = context.read<GameState>().seatsInViewOrder();

    // Through the screen, not up the tree: the controls over the felt are not
    // under its Stack.
    Rect? rectOf(GlobalKey key) {
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return null;
      return Rect.fromPoints(
        stage.globalToLocal(box.localToGlobal(Offset.zero)),
        stage.globalToLocal(
          box.localToGlobal(box.size.bottomRight(Offset.zero)),
        ),
      );
    }

    Map<int, Rect> measure(List<GlobalKey> keys) => {
      for (var view = 0; view < keys.length; view++) view: ?rectOf(keys[view]),
    };
    final pods = measure(emojiPods);
    final seatBoxes = measure(emojiSeats);
    final overAll = emojiCoversOver(rectOf).toList();

    final placed = <Rect>[];
    final fresh = <({String id, int view, int at})>[];
    for (final MapEntry(key: id, value: line) in _emojiSeen.entries) {
      final view = seats.indexWhere((seat) => seat?.userId == id);
      if (view < 0 || view >= emojiKeys.length) continue;
      if (_emojiSpots.containsKey(id)) {
        if (rectOf(emojiKeys[view]) case final rect?) placed.add(rect);
      } else {
        fresh.add((id: id, view: view, at: line.at));
      }
    }
    if (fresh.isEmpty) return;
    fresh.sort(
      (a, b) => a.at != b.at ? a.at.compareTo(b.at) : a.view.compareTo(b.view),
    );

    final felt = Offset.zero & stage.size;
    final bounds = felt.inflate(1);
    bool clear(Rect r) =>
        bounds.contains(r.topLeft) &&
        bounds.contains(r.bottomRight) &&
        !placed.any((p) => p.deflate(2).overlaps(r.deflate(2)));
    bool offPods(Rect r, int view) => !pods.entries.any(
      (e) => e.key != view && e.value.deflate(2).overlaps(r.deflate(2)),
    );

    // The rim in view order, then the viewer's: a seat drawn later than
    // [view]'s has a greater rank.
    int rank(int view) => view == 0 ? emojiSeats.length : view;
    List<Rect> coversOf(int view) {
      final pod = pods[view];
      final seat = seatBoxes[view];
      return [
        for (final MapEntry(key: other, value: box) in seatBoxes.entries)
          if (rank(other) > rank(view)) box,
        // Whatever of the seat's own box stands beside its pod is drawn after
        // it: the head seat's cards and bet (SeatPod.beside).
        if (pod != null && seat != null) ...[
          if (seat.right - pod.right > 0.5)
            Rect.fromLTRB(pod.right, seat.top, seat.right, seat.bottom),
          if (pod.left - seat.left > 0.5)
            Rect.fromLTRB(seat.left, seat.top, pod.left, seat.bottom),
        ],
        ...overAll,
      ];
    }

    final next = <String, EmojiSpot>{};
    for (final f in fresh) {
      final own = rectOf(emojiKeys[f.view]);
      final pod = pods[f.view];
      if (own == null || pod == null) {
        next[f.id] = (place: EmojiPlace.column, shift: 0);
        continue;
      }
      final covers = coversOf(f.view);
      bool uncovered(Rect r) => !covers.any((c) => c.overlaps(r.deflate(1)));

      // The bubble in its own place hangs a pointer from its top or foot;
      // beside the pod the same bubble lies on its side, the pointer out of
      // the edge nearest the pod.
      final gap = TableSpace.seat(pod.width);
      final across = own.height;
      final tall = own.width;
      final beside = (
        left: Rect.fromLTWH(
          pod.left - gap - across,
          pod.center.dy - tall / 2,
          across,
          tall,
        ),
        right: Rect.fromLTWH(
          pod.right + gap,
          pod.center.dy - tall / 2,
          across,
          tall,
        ),
      );
      Rect above(double shift) => Rect.fromLTWH(
        pod.center.dx - own.width / 2 + shift,
        pod.top - gap - own.height,
        own.width,
        own.height,
      );

      // Above the pod, slid sideways: as little as puts the bubble a step
      // clear of each thing in its way (an emoji, something drawn over the
      // seat, another player's pod) or back on the felt, nearest first — and
      // never so far that it stops standing over some of the pod.
      final home = above(0);
      final lo = pod.left - home.right;
      final hi = pod.right - home.left;
      final others = [
        for (final MapEntry(key: view, value: r) in pods.entries)
          if (view != f.view) r,
      ];
      final shifts =
          <double>{
              for (final r in [...placed, ...covers, ...others])
                if (r.top < home.bottom && r.bottom > home.top) ...[
                  r.left - Space.xs - home.right,
                  r.right + Space.xs - home.left,
                ],
              felt.left - home.left,
              felt.right - home.right,
            }.where((s) => s != 0 && s >= lo && s <= hi).toList()
            ..sort((a, b) => a.abs().compareTo(b.abs()));
      final slid = [for (final s in shifts) (EmojiPlace.above, s, above(s))];

      // Towards the middle of the table first: the seats on the left open to
      // the right, as their words do.
      final towardsRight = pod.center.dx < stage.size.width / 2;
      final options = <(EmojiPlace, double, Rect)>[
        (EmojiPlace.column, 0, own),
        if (f.view == 0) ...[
          (EmojiPlace.left, 0, beside.left),
          (EmojiPlace.right, 0, beside.right),
        ] else ...[
          towardsRight
              ? (EmojiPlace.right, 0, beside.right)
              : (EmojiPlace.left, 0, beside.left),
          (EmojiPlace.above, 0, home),
          towardsRight
              ? (EmojiPlace.left, 0, beside.left)
              : (EmojiPlace.right, 0, beside.right),
        ],
        ...slid,
      ];
      // Its own place is only asked to meet no emoji (the doc above).
      bool fits((EmojiPlace, double, Rect) o) =>
          clear(o.$3) && (o.$1 == EmojiPlace.column || uncovered(o.$3));
      final choice =
          options.where((o) => fits(o) && offPods(o.$3, f.view)).firstOrNull ??
          options.where(fits).firstOrNull ??
          options.first;
      next[f.id] = (place: choice.$1, shift: choice.$2);
      placed.add(choice.$3);
    }
    final moves = next.values.any((s) => s.place != EmojiPlace.column);
    if (moves) {
      setState(() => _emojiSpots.addAll(next));
    } else {
      _emojiSpots.addAll(next);
    }
  }
}
