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
/// [emojiHandZone]), hand each [SeatPod] its [emojiKeyAt], [emojiLinkAt],
/// [speechKeyAt] and [emojiPinOf], call [followEmojis] from `build`, and put
/// [emojiLayer] in their Stack after every seat and before the viewer's own
/// hand.
///
/// **What is drawn over what.** Every emoji is drawn in the felt's emoji
/// layer ([emojiLayer], [SeatEmoji]): over every seat — its pod, its column,
/// the words it is saying, now or later — and under what each felt draws
/// after it, the viewer's own hand, and under the controls its screen stands
/// over the felt ([emojiCoversOver]). Until 29 Sep 2026 each emoji was drawn
/// in its own seat's layer, under every seat painted after that one, and a
/// line such a seat said after the emoji had landed covered it: the viewer's
/// quick message over 20 to 43dp of Ravi's emoji, Vikramaditya's words over
/// Arjun's (the fifth look at the placement). A place is chosen against what
/// is there, and nothing had yet been said there. The layer draws an emoji
/// where the placement put it and nowhere else; where that is is chosen as it
/// always was: clear of everything a seat painted after its sender's paints
/// or may come to paint, and of the hand and the controls, which are drawn
/// over the layer. (The review found the viewer's moved emoji three quarters
/// under their own cards, and its other side under Missile and Pack. Drawing
/// it over the hand instead would have hidden the viewer's cards; it goes
/// where nothing is drawn over it.)
///
/// **Why a place is always found.** The second review of 28 Sep 2026 sent all
/// five emojis 300 ms apart in all 120 orders and found two meeting in half
/// of them: with no place left, the viewer's fell back to its own and met the
/// upper-left seat's. No emoji is ever put over ANOTHER seat's pod — in its
/// own place or any other — and the last of every seat's places is ON its own
/// pod ([EmojiPlace.pod], [SeatPod.emojiOnPod]), fitted inside it. Pods meet
/// neither each other, nor the viewer's hand, nor the corner keys (SeatRing;
/// the poker felt's five places likewise), so that place meets no emoji and
/// lies under nothing. It is the last resort: it covers the sender's own
/// picture and name for the few seconds it plays — at five places, the
/// viewer's when the upper-left seat's emoji came first, since beside the
/// viewer's pod is the hand on one side and Missile and Pack on the other.
///
/// **Why they stay where they land.** A placed emoji is PINNED ([EmojiPin]):
/// it is drawn at a fixed offset from the one point the felt holds its seat
/// still by ([SeatPod.emojiAnchor]), which the seat marks with its
/// [LayerLink], so nothing a seat's column does moves it. The third review
/// (29 Sep 2026) watched the seats move under emojis placed once: at the deal
/// of a table whose seats held no cards every rim seat's column grew a row of
/// cards and, placed by its middle, rose; the viewer's status line came and
/// went over their pod; and the emojis moved with them, the viewer's onto
/// Meera's in every order. The seats themselves now hold still (a rim seat's
/// rows under its pod stand at their tallest whatever they hold; the viewer's
/// own place stands over their POD, not their column), and each place is
/// chosen against the most room each seat can still take while it plays — a
/// pod's turn ring and winner's rule, the status line over the viewer's pod,
/// the words a later seat is saying ([SeatPod.podReach],
/// [SeatPod.emojiCovers]) — and the viewer's hand where it comes to rest
/// ([emojiCoversOver]). And after every build while an emoji plays the
/// placement looks again: an emoji that has come to lie where it may not — a
/// player sitting down in an empty chair, a column the rules above did not
/// foresee — is placed again, the earliest sent keeping their places. That is
/// the one way an emoji moves while it plays. Words said after an emoji has
/// landed move nothing: they are drawn under it.
mixin EmojiPlacement<T extends StatefulWidget> on State<T> {
  /// The felt's Stack, which everything is measured against.
  GlobalKey get emojiStage;

  /// Each place's pod (its plaque), in view order: what an emoji points at,
  /// what no other seat's emoji may cover, and where its last resort is.
  List<GlobalKey> get emojiPods;

  /// Each place's whole seat as the felt paints it — the [SeatPod]: pod,
  /// cards, bet — in view order. Its widget says where that seat's own
  /// emojis play ([SeatPod.emojiHome]), how the felt holds it
  /// ([SeatPod.emojiAnchor]) and how far it may still grow
  /// ([SeatPod.emojiCovers]).
  List<GlobalKey> get emojiSeats;

  /// What the felt paints over every seat and the screen stands over the
  /// felt, in the felt's coordinates: the viewer's hand where it comes to
  /// rest (a hand whose lift is gliding is reckoned where the glide ends,
  /// not where this frame has it) and the corner controls. [rectOf] measures
  /// a key's box there, wherever in the screen it is; null when it is not
  /// laid out.
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
  /// stands.
  final List<GlobalKey> emojiKeys = List.generate(
    SeatRing.maxSeats,
    (i) => GlobalKey(debugLabel: 'emoji $i'),
  );

  /// One key per place, naming what that seat is saying while it says it.
  final List<GlobalKey> speechKeys = List.generate(
    SeatRing.maxSeats,
    (i) => GlobalKey(debugLabel: 'speech $i'),
  );

  /// One link per place: the seat there marks where it stands with it
  /// ([SeatPod.emojiLink]), and its emoji is drawn against that mark in the
  /// emoji layer ([emojiLayer]).
  final List<LayerLink> emojiLinks = List.generate(
    SeatRing.maxSeats,
    (_) => LayerLink(),
  );

  /// The emoji each player is sending as the felt last saw it — the line
  /// itself, so a second one queued behind it counts as new — and where each
  /// is pinned. A player missing from [_emojiPins] has an emoji that has not
  /// been placed yet: it is not drawn until it is, after the frame it arrives
  /// in has laid the seats out, and then where it is to play.
  final Map<String, ChatMessage> _emojiSeen = {};
  final Map<String, EmojiPin> _emojiPins = {};
  bool _emojiPlacing = false;

  /// Where [userId]'s emoji is pinned; null until it has been placed.
  EmojiPin? emojiPinOf(String? userId) => _emojiPins[userId];

  /// The key for the emoji at place [view].
  GlobalKey? emojiKeyAt(int view) =>
      view >= 0 && view < emojiKeys.length ? emojiKeys[view] : null;

  /// The key for the words said at place [view].
  GlobalKey? speechKeyAt(int view) =>
      view >= 0 && view < speechKeys.length ? speechKeys[view] : null;

  /// The link the seat at place [view] marks where it stands with.
  LayerLink? emojiLinkAt(int view) =>
      view >= 0 && view < emojiLinks.length ? emojiLinks[view] : null;

  /// The felt's emoji layer: every emoji [seats] are playing and the felt
  /// has placed, drawn where it was placed ([SeatEmoji]) — keyed by
  /// [layerKey]. It covers the felt and takes no touch. It goes in the
  /// felt's Stack after every seat and before the viewer's own hand (the
  /// class doc).
  Widget emojiLayer(Iterable<SeatPod> seats, {required Key layerKey}) =>
      Positioned.fill(
        key: layerKey,
        child: IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (final seat in seats)
                if (SeatEmoji.shows(seat))
                  Positioned(
                    key: ValueKey('emoji-of-${seat.seat!.userId}'),
                    left: 0,
                    top: 0,
                    child: SeatEmoji(seat: seat),
                  ),
            ],
          ),
        ),
      );

  /// Keeps the felt on the emojis [GameState] is playing: one that has gone
  /// forgets its pin, and a new one — a player's first, or the next one
  /// queued behind it — is placed after this frame, once the seats have been
  /// laid out. While any plays, the ones already pinned are looked at again
  /// after the frame too (the class doc).
  void followEmojis(Map<String, ChatMessage> shown) {
    for (final id in _emojiSeen.keys.toList()) {
      if (!shown.containsKey(id)) {
        _emojiSeen.remove(id);
        _emojiPins.remove(id);
      }
    }
    for (final MapEntry(key: id, value: line) in shown.entries) {
      if (identical(_emojiSeen[id], line)) continue;
      _emojiSeen[id] = line;
      _emojiPins.remove(id);
    }
    if (_emojiSeen.isEmpty || _emojiPlacing) return;
    _emojiPlacing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _placeEmojis());
  }

  /// Gives every emoji that has just arrived a place, and one again to every
  /// emoji already playing whose place will no longer do.
  ///
  /// The ones already pinned are looked at first, in the order they were
  /// sent (the server's stamp, the same on every phone): each keeps its pin
  /// while it stays on the felt, meets no emoji kept before it, lies over no
  /// other seat's pod and clear of everything painted after its seat as they
  /// all stand now. Any that does not is placed again, and then the new ones,
  /// in the order sent, each taking the first of its seat's places that stays
  /// on the felt, meets no emoji kept or placed before it, and — against the
  /// most room every seat can still take while it plays — lies over no other
  /// seat's pod and clear of everything painted after its seat (the class
  /// doc: what later seats paint, the emoji layer is drawn over, and the
  /// viewer's hand and the controls over it):
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
    if (!mounted || _emojiSeen.isEmpty) return;
    final stage = emojiStage.currentContext?.findRenderObject();
    if (stage is! RenderBox || !stage.attached || !stage.hasSize) return;
    final game = context.read<GameState>();
    final seats = game.seatsInViewOrder();
    final t = game.t;

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
    final speech = measure(speechKeys);
    final overAll = emojiCoversOver(rectOf).toList();
    final zone = emojiHandZone;

    SeatPod? seatAt(int view) => switch (emojiSeats[view].currentWidget) {
      final SeatPod pod => pod,
      _ => null,
    };

    // What each seat paints now, and the most room each pod and each seat
    // can take while the emojis play.
    List<Rect> coversOf(int view, Rect seat, {required bool reach}) {
      final widget = seatAt(view);
      final pod = pods[view];
      if (widget == null || pod == null) return [seat];
      return widget.emojiCovers(
        context,
        seat: seat,
        pod: pod,
        t: t,
        reach: reach,
      );
    }

    final seatNow = {
      for (final MapEntry(key: view, value: seat) in seatBoxes.entries)
        view: coversOf(view, seat, reach: false),
    };
    final seatReach = {
      for (final MapEntry(key: view, value: seat) in seatBoxes.entries)
        view: coversOf(view, seat, reach: true),
    };
    final podReach = {
      for (final MapEntry(key: view, value: pod) in pods.entries)
        view: seatAt(view)?.podReach(pod) ?? pod,
    };

    final settled = <({String id, int view, int at})>[];
    final fresh = <({String id, int view, int at})>[];
    for (final MapEntry(key: id, value: line) in _emojiSeen.entries) {
      final view = seats.indexWhere((seat) => seat?.userId == id);
      if (view < 0 || view >= emojiKeys.length) continue;
      (_emojiPins.containsKey(id) ? settled : fresh).add((
        id: id,
        view: view,
        at: line.at,
      ));
    }
    int byTime(
      ({String id, int view, int at}) a,
      ({String id, int view, int at}) b,
    ) => a.at != b.at ? a.at.compareTo(b.at) : a.view.compareTo(b.view);
    settled.sort(byTime);
    fresh.sort(byTime);

    final bounds = (Offset.zero & stage.size).inflate(1);
    bool onFelt(Rect r) =>
        bounds.contains(r.topLeft) && bounds.contains(r.bottomRight);
    final placed = <Rect>[];
    bool meetsNone(Rect r) =>
        !placed.any((p) => p.deflate(2).overlaps(r.deflate(2)));
    bool offPods(Rect r, int view, Map<int, Rect> of) => !of.entries.any(
      (e) => e.key != view && e.value.deflate(2).overlaps(r.deflate(2)),
    );
    // Whether anything of [over] lies more than [slack] inside [r]'s edge.
    // What stands there as a place is chosen is held to 1dp. What may
    // only come later while the emoji plays — a turn's ring round a pod, a
    // winner's rule, a status line, a hand come to rest — is let reach 2dp
    // into the bubble's edge, as it is where an emoji already playing is
    // kept: a bubble's corners and a pod's are rounded, so nothing is drawn
    // on anything there. (At 592x360 x1.25 on a seen table, in the app's
    // own face, the viewer's turn ring would reach 1.1dp into the corner of
    // Ravi's own place, and a lone emoji of his played on his pod.)
    bool under(Rect r, Iterable<Rect> over, {double slack = 1}) =>
        over.any((c) => c.overlaps(r.deflate(slack)));

    // The rim in view order, then the viewer's: a seat drawn later than
    // [view]'s has a greater rank.
    int rank(int view) => view == 0 ? emojiSeats.length : view;
    // What [view]'s emoji is kept clear of: the seats painted after its seat
    // as [boxes] has them, and — when placing — the words they are saying;
    // whatever of the seat's own box stands beside its pod (the head seat's
    // cards and bet, SeatPod.beside); and everything drawn over every seat
    // and over the emoji layer.
    List<Rect> paintedOver(
      int view,
      Map<int, List<Rect>> boxes, {
      bool speaking = false,
    }) {
      final pod = pods[view];
      final seat = seatBoxes[view];
      return [
        for (final MapEntry(key: other, value: painted) in boxes.entries)
          if (rank(other) > rank(view)) ...painted,
        if (speaking)
          for (final MapEntry(key: other, value: words) in speech.entries)
            if (rank(other) > rank(view)) words,
        if (pod != null && seat != null) ...[
          if (seat.right - pod.right > 0.5)
            Rect.fromLTRB(pod.right, seat.top, seat.right, seat.bottom),
          if (pod.left - seat.left > 0.5)
            Rect.fromLTRB(seat.left, seat.top, pod.left, seat.bottom),
        ],
        ...overAll,
      ];
    }

    // Where [view]'s own emojis play, for a bubble [bubble] big; null for an
    // empty place, or one not laid out.
    Rect? homeOf(int view, Size bubble) {
      if (view >= seats.length || seats[view] == null) return null;
      final widget = seatAt(view);
      final seat = seatBoxes[view];
      final pod = pods[view];
      if (widget == null || seat == null || pod == null) return null;
      return widget.emojiHome(seat: seat, pod: pod, bubble: bubble);
    }

    // The ones pinned: kept where they are while nothing lies over them.
    final next = Map<String, EmojiPin>.of(_emojiPins);
    final unpinned = <({String id, int view, int at})>[];
    for (final e in settled) {
      final widget = seatAt(e.view);
      final seat = seatBoxes[e.view];
      final pin = _emojiPins[e.id]!;
      if (widget == null || seat == null) continue;
      final at = (widget.emojiAnchor(seat) + pin.offset) & pin.size;
      if (onFelt(at) &&
          meetsNone(at) &&
          offPods(at, e.view, pods) &&
          !under(at, paintedOver(e.view, seatNow), slack: 2)) {
        placed.add(at);
      } else {
        unpinned.add(e);
      }
    }

    // Then the ones that must move, and the new ones.
    for (final f in [...unpinned, ...fresh]) {
      final widget = seatAt(f.view);
      final seat = seatBoxes[f.view];
      final pod = pods[f.view];
      if (widget == null || seat == null || pod == null) {
        next.remove(f.id);
        continue;
      }
      final bubble = SeatPod.emojiBubbleSize(widget.width);
      final own = widget.emojiHome(seat: seat, pod: pod, bubble: bubble);
      // What is there now, and what may come there while this emoji plays.
      final coversNow = paintedOver(f.view, seatNow, speaking: true);
      final coversLater = paintedOver(f.view, seatReach);
      // Every other seat's own place, where its emojis can play.
      final homes = [
        for (final view in pods.keys)
          if (view != f.view)
            if (homeOf(view, bubble) case final home?
                when onFelt(home) && offPods(home, view, podReach))
              home,
      ];
      bool fits(Rect r) =>
          onFelt(r) &&
          meetsNone(r) &&
          offPods(r, f.view, podReach) &&
          !under(r, coversNow) &&
          !under(r, coversLater, slack: 2);
      bool movable(Rect r) =>
          fits(r) &&
          !(zone != null && zone.overlaps(r.deflate(1))) &&
          !homes.any((h) => h.deflate(2).overlaps(r.deflate(2)));

      // The bubble in its own place hangs a pointer from its top or foot;
      // beside the pod the same bubble lies on its side, the pointer out of
      // the edge nearest the pod, and above it stands on its pointer.
      final gap = TableSpace.seat(widget.width);
      final across = bubble.height;
      final tall = bubble.width;
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
        pod.center.dx - bubble.width / 2,
        pod.top - gap - bubble.height,
        bubble.width,
        bubble.height,
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
      final (place, at) = fits(own)
          ? (EmojiPlace.column, own)
          : moved.where((o) => movable(o.$2)).firstOrNull ??
                (EmojiPlace.pod, SeatPod.emojiOnPod(pod));
      next[f.id] = EmojiPin(
        place,
        at.topLeft - widget.emojiAnchor(seat),
        at.size,
      );
      placed.add(at);
    }

    final changed =
        next.length != _emojiPins.length ||
        next.entries.any((e) => _emojiPins[e.key] != e.value);
    if (changed) {
      setState(() {
        _emojiPins
          ..clear()
          ..addAll(next);
      });
    }
  }
}
