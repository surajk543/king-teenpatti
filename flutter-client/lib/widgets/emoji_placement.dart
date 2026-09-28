import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../state/game_state.dart';
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

/// Keeps the emojis a felt is playing apart (owner, 28 Sep 2026: "when two
/// players send emoji in any game table then their emoji should not overlap,
/// if overlap then change the direction so that it does not overlap"), and —
/// whatever order they are sent in — each on the felt, under nothing drawn
/// after it, still for as long as it plays, and at its sender's own pod.
///
/// Mixed into both felts' States — the Teen Patti `_Felt` and the poker
/// `_PokerFelt` — which say where their Stack, their pods, their seats, what
/// covers their seats and where the viewer's hand may stand are
/// ([emojiStage], [emojiPods], [emojiSeats], [emojiCoversOver],
/// [emojiHandZone]), key each [SeatPod]'s emoji with [emojiKeyAt], build it
/// at [emojiPlaceOf], and call [followEmojis] from `build`.
///
/// **The paint order it assumes, which both felts keep**: the seats round the
/// rim in view order, then the viewer's, then whatever [emojiCoversOver]
/// names — the viewer's own hand, which each felt draws after every seat, and
/// the controls its screen stands over the felt. An emoji is drawn in its
/// seat's own layer (SeatPod), so any seat painted after its own, the part of
/// its own seat that stands beside its pod (the head seat's cards, drawn after
/// the pod), and anything over every seat would be drawn over it: a place
/// that meets any of those is no place. (The review found the viewer's moved
/// emoji three quarters under their own cards, and its other side under
/// Missile and Pack. Drawing it over the hand instead would have hidden the
/// viewer's cards; it goes where nothing is drawn over it.)
///
/// **Why a place is always found.** The second review of 28 Sep 2026 sent all
/// five emojis 300 ms apart in all 120 orders and found two meeting in half
/// of them: with no place left, the viewer's fell back to its own and met the
/// upper-left seat's. Now no emoji is ever put over ANOTHER seat's pod — in
/// its own place or any other — so every pod is always free of every emoji
/// but its own seat's, and the last of every seat's places is ON its own pod
/// ([EmojiPlace.pod], [SeatPod.emojiOnPod]), fitted inside it. Pods meet
/// neither each other, nor the viewer's hand, nor the corner keys (SeatRing;
/// the poker felt's five places likewise), so that place meets no emoji and
/// lies under nothing. It is the last resort: it covers the sender's own
/// picture and name for the few seconds it plays — at five places, the
/// viewer's when the upper-left seat's emoji came first, since beside the
/// viewer's pod is the hand on one side and Missile and Pack on the other.
mixin EmojiPlacement<T extends StatefulWidget> on State<T> {
  /// The felt's Stack, which everything is measured against.
  GlobalKey get emojiStage;

  /// Each place's pod (its plaque), in view order: what an emoji points at,
  /// what no other seat's emoji may cover, and where its last resort is.
  List<GlobalKey> get emojiPods;

  /// Each place's whole seat as the felt paints it — the [SeatPod]: pod,
  /// cards, bet — in view order. Its widget says where that seat's own
  /// emojis play ([SeatPod.emojiHome]).
  List<GlobalKey> get emojiSeats;

  /// What the felt paints over every seat and the screen stands over the
  /// felt, in the felt's coordinates: the viewer's hand as it stands and the
  /// corner controls. [rectOf] measures a key's box there, wherever in the
  /// screen it is; null when it is not laid out.
  Iterable<Rect> emojiCoversOver(Rect? Function(GlobalKey key) rectOf);

  /// Where the viewer's hand may stand, not only where it stands now — from
  /// its left edge to the felt's right and from under the pot to the felt's
  /// foot — in the felt's coordinates; null before the first layout. Between
  /// hands the hand is empty, and a deal a moment later would lay its cards
  /// over an emoji the empty hand had let stand there, so no emoji is MOVED
  /// into it. (A seat's own place stays where it is: the right-hand seats'
  /// reach into this zone, above the keys, and never under the cards.)
  Rect? get emojiHandZone;

  /// One key per place, naming the emoji bubble playing there, wherever it
  /// stands — so the felt can see where it landed.
  final List<GlobalKey> emojiKeys = List.generate(
    SeatRing.maxSeats,
    (i) => GlobalKey(debugLabel: 'emoji $i'),
  );

  /// The emoji each player is sending as the felt last saw it — the line
  /// itself, so a second one queued behind it counts as new — and where each
  /// plays. A player missing from [_emojiPlaces] has an emoji that has not
  /// been placed yet: it is drawn in its bubble's own place for one frame, at
  /// the start of its pop-in (fully transparent), measured, and moved if that
  /// place will not do.
  final Map<String, ChatMessage> _emojiSeen = {};
  final Map<String, EmojiPlace> _emojiPlaces = {};
  bool _emojiPlacing = false;

  /// Where [userId]'s emoji plays.
  EmojiPlace emojiPlaceOf(String? userId) =>
      _emojiPlaces[userId] ?? EmojiPlace.column;

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
        _emojiPlaces.remove(id);
      }
    }
    var fresh = false;
    for (final MapEntry(key: id, value: line) in shown.entries) {
      if (identical(_emojiSeen[id], line)) continue;
      _emojiSeen[id] = line;
      _emojiPlaces.remove(id);
      fresh = true;
    }
    if (!fresh || _emojiPlacing) return;
    _emojiPlacing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _placeEmojis());
  }

  /// Gives every emoji that has just arrived a place.
  ///
  /// The ones already playing keep where they are; the new ones are placed in
  /// the order they were sent (the server's stamp, the same on every phone),
  /// each taking the first of its seat's places that stays on the felt, meets
  /// no emoji placed before it, lies over no other seat's pod and under
  /// nothing painted after its seat (the class doc):
  ///
  /// * the bubble's own place ([SeatPod.emojiHome]) — the common case, and
  ///   the place a player's emojis are known by;
  /// * for a seat round the rim, beside the pod towards the middle of the
  ///   table, above it, and beside it on the other side; for the viewer,
  ///   beside the pod on the left, then on the right. Moved there, an emoji
  ///   also keeps out of where the viewer's hand may stand ([emojiHandZone])
  ///   and out of every other seat's own place, whether an emoji plays in it
  ///   now or not: that is where that seat's emojis play, and one of this
  ///   seat's standing there would be read as that seat's. (The first fix
  ///   also slid the bubble along above the pod. At five places that put the
  ///   viewer's in the left-hand seat's own place; kept out of other seats'
  ///   places, a slid bubble found room on none of the phones tried, so it
  ///   went.)
  /// * and last, on its own pod ([EmojiPlace.pod]), which is always free.
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
    final zone = emojiHandZone;

    final placed = <Rect>[];
    final fresh = <({String id, int view, int at})>[];
    for (final MapEntry(key: id, value: line) in _emojiSeen.entries) {
      final view = seats.indexWhere((seat) => seat?.userId == id);
      if (view < 0 || view >= emojiKeys.length) continue;
      if (_emojiPlaces.containsKey(id)) {
        if (rectOf(emojiKeys[view]) case final rect?) placed.add(rect);
      } else {
        fresh.add((id: id, view: view, at: line.at));
      }
    }
    if (fresh.isEmpty) return;
    fresh.sort(
      (a, b) => a.at != b.at ? a.at.compareTo(b.at) : a.view.compareTo(b.view),
    );

    final bounds = (Offset.zero & stage.size).inflate(1);
    bool onFelt(Rect r) =>
        bounds.contains(r.topLeft) && bounds.contains(r.bottomRight);
    bool meetsNone(Rect r) =>
        !placed.any((p) => p.deflate(2).overlaps(r.deflate(2)));
    bool offPods(Rect r, int view) => !pods.entries.any(
      (e) => e.key != view && e.value.deflate(2).overlaps(r.deflate(2)),
    );
    bool under(Rect r, Iterable<Rect> over) =>
        over.any((c) => c.overlaps(r.deflate(1)));

    // The rim in view order, then the viewer's: a seat drawn later than
    // [view]'s has a greater rank.
    int rank(int view) => view == 0 ? emojiSeats.length : view;
    List<Rect> paintedOver(int view) {
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

    // Where [view]'s own emojis play, from its SeatPod and the bubble's size;
    // null for an empty place, or one not laid out.
    Rect? homeOf(int view, Size bubble) {
      if (view >= seats.length || seats[view] == null) return null;
      final widget = emojiSeats[view].currentWidget;
      final seat = seatBoxes[view];
      final pod = pods[view];
      if (widget is! SeatPod || seat == null || pod == null) return null;
      return widget.emojiHome(seat: seat, pod: pod, bubble: bubble);
    }

    final next = <String, EmojiPlace>{};
    for (final f in fresh) {
      final own = rectOf(emojiKeys[f.view]);
      final pod = pods[f.view];
      if (own == null || pod == null) {
        next[f.id] = EmojiPlace.column;
        continue;
      }
      final covers = paintedOver(f.view);
      // Every other seat's own place, where its emojis can play.
      final homes = [
        for (final view in pods.keys)
          if (view != f.view)
            if (homeOf(view, own.size) case final home?
                when onFelt(home) && offPods(home, view))
              home,
      ];
      bool movable(Rect r) =>
          onFelt(r) &&
          meetsNone(r) &&
          offPods(r, f.view) &&
          !under(r, covers) &&
          !(zone != null && zone.overlaps(r.deflate(1))) &&
          !homes.any((h) => h.deflate(2).overlaps(r.deflate(2)));

      // The bubble in its own place hangs a pointer from its top or foot;
      // beside the pod the same bubble lies on its side, the pointer out of
      // the edge nearest the pod, and above it stands on its pointer.
      final gap = TableSpace.seat(pod.width);
      final across = own.height;
      final tall = own.width;
      final left = Rect.fromLTWH(
        pod.left - gap - across,
        pod.center.dy - tall / 2,
        across,
        tall,
      );
      final right = Rect.fromLTWH(
        pod.right + gap,
        pod.center.dy - tall / 2,
        across,
        tall,
      );
      final above = Rect.fromLTWH(
        pod.center.dx - own.width / 2,
        pod.top - gap - own.height,
        own.width,
        own.height,
      );

      // Towards the middle of the table first: the seats on the left open to
      // the right, as their words do.
      final towardsRight = pod.center.dx < stage.size.width / 2;
      final moved = <(EmojiPlace, Rect)>[
        if (f.view == 0) ...[
          (EmojiPlace.left, left),
          (EmojiPlace.right, right),
        ] else ...[
          towardsRight ? (EmojiPlace.right, right) : (EmojiPlace.left, left),
          (EmojiPlace.above, above),
          towardsRight ? (EmojiPlace.left, left) : (EmojiPlace.right, right),
        ],
      ];

      // Its own place, if it is clear; else the first place it may move to;
      // else its pod, which is always free (the class doc).
      final (place, at) =
          onFelt(own) &&
              meetsNone(own) &&
              offPods(own, f.view) &&
              !under(own, covers)
          ? (EmojiPlace.column, own)
          : moved.where((o) => movable(o.$2)).firstOrNull ??
                (EmojiPlace.pod, SeatPod.emojiOnPod(pod));
      next[f.id] = place;
      placed.add(at);
    }
    final moves = next.values.any((p) => p != EmojiPlace.column);
    if (moves) {
      setState(() => _emojiPlaces.addAll(next));
    } else {
      _emojiPlaces.addAll(next);
    }
  }
}
