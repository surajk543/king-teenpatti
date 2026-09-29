/// The hand-result card animations (owner's brief, 29 Sep 2026): the cards
/// that made a winning hand light up where they lie, by what the server says
/// they made — a Pair's two cards pulse, a Color's three catch a light in the
/// table's colour, a Sequence rises card after card, a Pure Sequence settles
/// into a gold edge, a Trail bursts. The numbers are
/// `theme/hand_result_motion.dart`'s; this file draws them.
///
/// One system, three pieces:
///
/// * [HandResultScope] — the felt's word on which result is being celebrated
///   ([HandResultCue]): whose hand, what it made, which of its cards made it,
///   and the celebration's own clock. Only the Teen Patti felt provides one.
/// * [HandResultGroup] — round one seat's cards. Where the cue is that seat's
///   it times the result off the clock ([HandResultProgress]) and draws the
///   hand's own light behind the cards (a Trail's radial light and sparks).
/// * [HandResultCard] — round each card. Where its card is one of the hand's,
///   it lifts it and lights it; everywhere else it paints the card and
///   nothing more.
///
/// Nothing here owns a controller, a timer or a ticker: the celebration's
/// clock (table_screen's `_Party`, the one the fireworks, the WINNER ribbon
/// and the pot's flight run on) is the only clock, so the cards light up with
/// the ribbon's strike, a rebuilt seat takes the animation up where the clock
/// is rather than starting again, and the next deal — which drops the
/// celebration — takes the light with it. Every part is moved by its render
/// object with nothing rebuilt, and repaints only while its figures change:
/// once the cards have settled nothing is drawn again.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../settings/feedback_settings.dart';
import '../theme/app_theme.dart';
import '../theme/hand_result_motion.dart';
import 'playing_card.dart';

/// The cards of a revealed hand that made what the server named it, each
/// with its place among them, left to right: every COUNTED card — the three
/// dealt, or under 5-Card the three the server lists in [best] — and for a
/// Pair only the two of those that pair.
///
/// Locating the pair inside a result the server has already named is not
/// evaluating the hand: the server said "Pair" (and so that exactly two of
/// the counted cards share a rank); this finds which two, reading each card
/// as it was COUNTED — [playsAs] where a wild card stood in for another, so a
/// seven and a wild two playing as a seven are the pair. Nothing here ranks,
/// compares or names a hand. A Pair whose two cards cannot be found (a
/// malformed payload) lights nothing.
///
/// Keys are the dealt codes — [cards]' — which is what every seat's cards
/// are built from, whatever face a wild card shows.
Map<String, int> handResultCards({
  required HandResultLevel level,
  required List<String> cards,
  List<String> playsAs = const [],
  List<String> best = const [],
}) {
  final counted = <int>[
    for (var i = 0; i < cards.length; i++)
      if (best.isEmpty || best.contains(cards[i])) i,
  ];
  if (level != HandResultLevel.pair) {
    return {for (final (order, i) in counted.indexed) cards[i]: order};
  }
  String rankAt(int i) {
    final code = playsAs.length == cards.length ? playsAs[i] : cards[i];
    return code.length < 2
        ? ''
        : code.substring(0, code.length - 1).toUpperCase();
  }

  final byRank = <String, List<int>>{};
  for (final i in counted) {
    final rank = rankAt(i);
    if (rank.isNotEmpty) (byRank[rank] ??= []).add(i);
  }
  final pair = byRank.values.where((same) => same.length == 2).firstOrNull;
  if (pair == null) return const {};
  return {for (final (order, i) in pair.indexed) cards[i]: order};
}

/// The result a table is celebrating, for its cards to light up by: whose
/// hand ([userId]), what it made ([level]), which of its cards made it
/// ([cards]: dealt code → place among them), and when — [startAt] into the
/// celebration's [clock], which runs 0 to 1 over [total].
@immutable
class HandResultCue {
  const HandResultCue({
    required this.key,
    required this.userId,
    required this.level,
    required this.cards,
    required this.clock,
    required this.total,
    required this.startAt,
    this.category = '',
    this.bootAmount = 0,
  });

  /// The result's identity — the table, the hand and its winner — so an
  /// animation can never be carried from one hand into the next.
  final String key;
  final String userId;
  final HandResultLevel level;
  final Map<String, int> cards;
  final Animation<double> clock;
  final Duration total;
  final Duration startAt;

  /// The table's game and stake, for its colour ([AppTheme.paletteFor]).
  final String category;
  final int bootAmount;

  /// The cue for a showdown's winner, from their [reveal] as the server sent
  /// it: its `category` (else its `handName`) decides the level, its cards,
  /// `playsAs` and `best` which of them light up. Null when there is nothing
  /// to light — no reveal (everyone else packed: the table never saw the
  /// hand), a High Card, a Pair whose pair cannot be found — and on a MUFLIS
  /// hand, where the table ranks hands the other way round and a Trail is
  /// the worst hand there is: lighting a hand by how rare it is would
  /// celebrate the very thing that made it weak.
  static HandResultCue? forWinner({
    required String key,
    required Reveal? reveal,
    required Animation<double> clock,
    required Duration total,
    required Duration startAt,
    String category = '',
    int bootAmount = 0,
    String? variation,
  }) {
    if (reveal == null || variation == Variation.muflis) return null;
    final level = reveal.category >= 0
        ? HandResultLevel.fromCategory(reveal.category)
        : HandResultLevel.fromHandName(reveal.handName);
    if (level == null) return null;
    final cards = handResultCards(
      level: level,
      cards: reveal.cards,
      playsAs: reveal.playsAs,
      best: reveal.best,
    );
    if (cards.isEmpty) return null;
    return HandResultCue(
      key: key,
      userId: reveal.userId,
      level: level,
      cards: cards,
      clock: clock,
      total: total,
      startAt: startAt,
      category: category,
      bootAmount: bootAmount,
    );
  }

  /// Whether [other] is this same result on this same clock — what a seat
  /// keeps its timing across, however often the felt builds a new cue.
  bool sameResult(HandResultCue? other) =>
      other != null &&
      other.key == key &&
      other.userId == userId &&
      other.level == level &&
      identical(other.clock, clock) &&
      other.total == total &&
      other.startAt == startAt;

  @override
  bool operator ==(Object other) =>
      other is HandResultCue &&
      sameResult(other) &&
      other.category == category &&
      other.bootAmount == bootAmount &&
      mapEquals(other.cards, cards);

  @override
  int get hashCode => Object.hash(key, userId, level, startAt, total);
}

/// The felt's cue ([HandResultCue]) for every seat under it; null while no
/// result is being celebrated.
class HandResultScope extends InheritedWidget {
  const HandResultScope({super.key, required this.cue, required super.child});

  final HandResultCue? cue;

  static HandResultCue? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HandResultScope>()?.cue;

  @override
  bool updateShouldNotify(HandResultScope oldWidget) => oldWidget.cue != cue;
}

/// How far a result's animation has got, 0 to 1 over its [duration], read
/// off the celebration's [clock] (0 to 1 over [total]) from [startAt] — the
/// moment the result lands. It tells its listeners only when that figure
/// moves, so the cards stop repainting the frame they settle, however long
/// the celebration's clock runs on; and it listens to the clock only while
/// something listens to it. A [duration] of nothing is a result shown
/// settled: 0 until [startAt], 1 from it — never before the ribbon strikes.
class HandResultProgress extends Animation<double>
    with
        AnimationLazyListenerMixin,
        AnimationLocalListenersMixin,
        AnimationLocalStatusListenersMixin {
  HandResultProgress({
    required this.clock,
    required this.total,
    required this.startAt,
    required this.duration,
  }) {
    _last = value;
  }

  final Animation<double> clock;
  final Duration total;
  final Duration startAt;
  final Duration duration;

  late double _last;

  @override
  double get value {
    // A clock that has run out has shown everything it was going to.
    if (clock.status == AnimationStatus.completed) return 1;
    final since = clock.value * total.inMicroseconds - startAt.inMicroseconds;
    final length = duration.inMicroseconds;
    if (length <= 0) return since >= 0 ? 1 : 0;
    return (since / length).clamp(0.0, 1.0);
  }

  @override
  AnimationStatus get status => _statusOf(value);

  static AnimationStatus _statusOf(double v) => v <= 0
      ? AnimationStatus.dismissed
      : v >= 1
      ? AnimationStatus.completed
      : AnimationStatus.forward;

  void _tick() {
    final now = value;
    if (now == _last) return;
    final was = _statusOf(_last);
    _last = now;
    notifyListeners();
    final status = _statusOf(now);
    if (status != was) notifyStatusListeners(status);
  }

  void _clockStatus(AnimationStatus _) => _tick();

  @override
  void didStartListening() {
    _last = value;
    clock
      ..addListener(_tick)
      ..addStatusListener(_clockStatus);
  }

  @override
  void didStopListening() {
    clock
      ..removeListener(_tick)
      ..removeStatusListener(_clockStatus);
  }
}

/// The results this phone has played, each with the clock it played on
/// (by identity), so a result is never played twice: a celebration still on
/// show when the felt is built again (and its clock with it) finds its
/// cards settled rather than lighting up from the start. A seat rebuilt on
/// the SAME clock is not "elsewhere" and takes the animation up where the
/// clock is. The last [keep] results only; a result's key names its table,
/// hand and winner, so no two hands share one.
abstract final class HandResultMemory {
  static const int keep = 16;

  static final Map<String, int> _played = {};

  /// Whether [cue]'s result has been played on a clock other than its own.
  static bool playedElsewhere(HandResultCue cue) {
    final clock = _played[cue.key];
    return clock != null && clock != identityHashCode(cue.clock);
  }

  /// Notes that [cue]'s result is being played on its clock.
  static void remember(HandResultCue cue) {
    _played
      ..remove(cue.key)
      ..[cue.key] = identityHashCode(cue.clock);
    while (_played.length > keep) {
      _played.remove(_played.keys.first);
    }
  }

  /// Forgets every result, for tests that play the same hand afresh.
  @visibleForTesting
  static void reset() => _played.clear();
}

/// The level's sound hook, once per result as its cards light up
/// ([FeedbackSettings.handResult]); nothing where there are no sounds in
/// scope (a bare widget test, a tool).
void handResultSound(BuildContext context, HandResultLevel level) {
  try {
    Provider.of<FeedbackSettings>(context, listen: false).handResult(level);
  } on ProviderNotFoundException {
    // No sounds in scope.
  }
}

/// One seat's cards, for the result animation: laid round the cards as the
/// seat already draws them, the same whatever is happening (the cards under
/// it are never rebuilt for it). Where the felt's cue ([HandResultScope]) is
/// [userId]'s hand, it times the animation and draws the hand's own light
/// behind the cards; each card lights itself ([HandResultCard]).
class HandResultGroup extends StatefulWidget {
  const HandResultGroup({
    super.key,
    required this.userId,
    required this.headroom,
    required this.child,
  });

  /// Whose cards these are.
  final String? userId;

  /// How far above this box the space is free, in logical pixels: the gap to
  /// whatever stands over the hand — the viewer's own bet badge
  /// (`TableSpace.hand`), a rim seat's pod (`TableSpace.seat`). Nothing the
  /// result draws — a risen card, its edge light, a Trail's radial light and
  /// sparks — crosses it, less [HandResultShape.clearance] (review, 29 Sep
  /// 2026). It holds the whole hand's rise, so the hand rises as one.
  final double headroom;

  final Widget child;

  @override
  State<HandResultGroup> createState() => HandResultGroupState();
}

class HandResultGroupState extends State<HandResultGroup> {
  HandResultCue? _cue;
  Animation<double>? _progress;
  HandResultProfile? _profile;

  /// The result this seat is showing, if it is showing one.
  @visibleForTesting
  HandResultCue? get cue => _cue;

  /// The row it is being played by (the reduced one under reduced motion).
  @visibleForTesting
  HandResultProfile? get profile => _profile;

  /// How far it has got, 0 to 1.
  @visibleForTesting
  double get progress => _progress?.value ?? 0;

  /// The box of everything the hand's own light (a Trail's radial light and
  /// sparks) painted in its last frame, in global coordinates; null when it
  /// painted none. Debug builds only.
  @visibleForTesting
  Rect? get debugLightBounds {
    final boundary = context.findRenderObject();
    final burst = boundary is RenderProxyBox ? boundary.child : null;
    final bounds = burst is _RenderHandResultBurst
        ? burst.debugLightBounds
        : null;
    return bounds == null
        ? null
        : MatrixUtils.transformRect(burst!.getTransformTo(null), bounds);
  }

  /// Keeps the seat on the result it is showing: the same result on the same
  /// clock keeps its timing (and so never starts again), anything else starts
  /// from where its own clock is.
  void _bind(HandResultCue? cue) {
    final held = _cue;
    if (cue == null ? held == null : cue.sameResult(held)) {
      _cue = cue;
      return;
    }
    _progress?.removeListener(_announce);
    _cue = cue;
    _progress = null;
    if (cue == null) return;
    // A result this phone has already played on another clock — the felt
    // built again round a celebration still on show — is shown settled,
    // never played a second time; and settled from the moment its own clock
    // says the result lands, not while the cards are still turning.
    if (HandResultMemory.playedElsewhere(cue)) {
      _progress = HandResultProgress(
        clock: cue.clock,
        total: cue.total,
        startAt: cue.startAt,
        duration: Duration.zero,
      );
      return;
    }
    HandResultMemory.remember(cue);
    final progress = _progress = HandResultProgress(
      clock: cue.clock,
      total: cue.total,
      startAt: cue.startAt,
      duration: HandResultProfile.of(cue.level).duration,
    );
    // Heard once, as the cards light up — never late: a seat that meets a
    // result already under way (rebuilt, reconnected) is not announced.
    if (progress.value <= 0) progress.addListener(_announce);
  }

  void _announce() {
    final progress = _progress;
    final cue = _cue;
    if (progress == null || cue == null || progress.value <= 0) return;
    progress.removeListener(_announce);
    handResultSound(context, cue.level);
  }

  @override
  void dispose() {
    _progress?.removeListener(_announce);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final userId = widget.userId;
    final offered = HandResultScope.of(context);
    _bind(
      offered != null && userId != null && offered.userId == userId
          ? offered
          : null,
    );
    final cue = _cue;
    final theme = Theme.of(context);
    var accent = AppTheme.gold;
    HandResultProfile? profile;
    if (cue != null) {
      final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      profile = reduced
          ? HandResultProfile.reducedOf(cue.level)
          : HandResultProfile.of(cue.level);
      accent = AppTheme.paletteFor(
        theme.colorScheme,
        category: cue.category,
        bootAmount: cue.bootAmount,
      ).accent;
    }
    _profile = profile;
    final light = HandResultLight.of(theme.brightness);
    final progress = profile == null ? null : _progress;
    final bursts =
        profile != null && (profile.sparks > 0 || profile.radialGlow > 0);
    return _HandResultGroupData(
      progress: progress,
      profile: profile,
      cards: cue?.cards ?? const {},
      light: light,
      accent: accent,
      headroom: widget.headroom,
      // In a layer of its own: while the cards move, only this seat's cards
      // are drawn again.
      child: RepaintBoundary(
        child: _HandResultBurst(
          progress: bursts ? progress : null,
          profile: bursts ? profile : null,
          light: light,
          seed: cue?.key.hashCode ?? 0,
          headroom: widget.headroom,
          child: widget.child,
        ),
      ),
    );
  }
}

/// What a [HandResultGroup] tells the cards under it.
class _HandResultGroupData extends InheritedWidget {
  const _HandResultGroupData({
    required this.progress,
    required this.profile,
    required this.cards,
    required this.light,
    required this.accent,
    required this.headroom,
    required super.child,
  });

  final Animation<double>? progress;
  final HandResultProfile? profile;
  final Map<String, int> cards;
  final HandResultLight light;
  final Color accent;
  final double headroom;

  static _HandResultGroupData? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_HandResultGroupData>();

  @override
  bool updateShouldNotify(_HandResultGroupData old) =>
      !identical(old.progress, progress) ||
      !identical(old.profile, profile) ||
      !mapEquals(old.cards, cards) ||
      !identical(old.light, light) ||
      old.accent != accent ||
      old.headroom != headroom;
}

/// One card, for the result animation ([HandResultGroup]): the card as it
/// was, unless it is one of the cards that made the winning hand — then,
/// while the result plays, it rises and grows about its middle, catches the
/// light and takes a gold edge, as its level's row says, and never further
/// than its hand has room for ([HandResultGroup.headroom]).
///
/// Always this one render object round the card, lit or not, so a card is
/// never rebuilt (its flip, its wild turn) when a result arrives or goes.
class HandResultCard extends SingleChildRenderObjectWidget {
  const HandResultCard({
    super.key,
    required this.code,
    required this.cardHeight,
    super.child,
  });

  /// The card's dealt code, or null for a card face down.
  final String? code;
  final double cardHeight;

  @override
  RenderHandResultCard createRenderObject(BuildContext context) {
    final card = RenderHandResultCard();
    _configure(context, card);
    return card;
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderHandResultCard renderObject,
  ) => _configure(context, renderObject);

  void _configure(BuildContext context, RenderHandResultCard card) {
    final group = _HandResultGroupData.maybeOf(context);
    final code = this.code;
    final order = code == null || group == null ? null : group.cards[code];
    final lit =
        order != null && group!.progress != null && group.profile != null;
    card
      ..progress = lit ? group.progress : null
      ..profile = lit ? group.profile : null
      ..order = order ?? 0
      ..count = group?.cards.length ?? 0
      ..cardHeight = cardHeight
      ..light = group?.light ?? HandResultLight.dark
      ..accent = group?.accent ?? AppTheme.gold
      ..headroom = group?.headroom ?? double.infinity;
  }
}

/// The card's render object: it paints the card, and while its result plays
/// the soft shadow of a lifted card, the card risen and grown about its
/// middle, the gold light round its edge and the band of light across its
/// face. All of it moved here, frame by frame, with nothing rebuilt and
/// nothing laid out again.
class RenderHandResultCard extends RenderProxyBox {
  RenderHandResultCard();

  /// How many frames have painted a lit card since the count was last reset
  /// — how the tests see that a settled card is painted no more. Counted in
  /// debug builds only.
  @visibleForTesting
  static int debugLitPaints = 0;

  /// How far this card's edge light reached when it was last painted: the
  /// box of the halo's visible light (its blur counted to
  /// [HandResultShape.haloReachSigmas]) in the frame its face is drawn in —
  /// the child's, risen and grown — or null when it painted none. Recorded
  /// in debug builds only, for the tests that hold it under what stands over
  /// the hand.
  @visibleForTesting
  Rect? debugLightBounds;

  Animation<double>? _progress;
  set progress(Animation<double>? value) {
    if (identical(value, _progress)) return;
    if (attached) _progress?.removeListener(markNeedsPaint);
    _progress = value;
    if (attached) _progress?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  HandResultProfile? _profile;
  set profile(HandResultProfile? value) {
    if (identical(value, _profile)) return;
    _profile = value;
    markNeedsPaint();
  }

  int _order = 0;
  set order(int value) {
    if (value == _order) return;
    _order = value;
    markNeedsPaint();
  }

  int _count = 0;
  set count(int value) {
    if (value == _count) return;
    _count = value;
    markNeedsPaint();
  }

  double _cardHeight = 0;
  set cardHeight(double value) {
    if (value == _cardHeight) return;
    _cardHeight = value;
    markNeedsPaint();
  }

  HandResultLight _light = HandResultLight.dark;
  set light(HandResultLight value) {
    if (identical(value, _light)) return;
    _light = value;
    markNeedsPaint();
  }

  Color _accent = AppTheme.gold;
  set accent(Color value) {
    if (value == _accent) return;
    _accent = value;
    markNeedsPaint();
  }

  /// The free space over the hand ([HandResultGroup.headroom]).
  double _headroom = double.infinity;
  set headroom(double value) {
    if (value == _headroom) return;
    _headroom = value;
    markNeedsPaint();
  }

  /// Whether this card is one of the hand's while its result is on.
  bool get lit => _progress != null && _profile != null;

  /// What the card looks like now: its level's row at this moment, its rise
  /// held to the room its hand has ([_RenderHandResultBurst.litRoom]).
  HandResultCardEffect get effect {
    final progress = _progress;
    final profile = _profile;
    if (progress == null || profile == null) return HandResultCardEffect.rest;
    final raw = profile.cardAt(
      progress.value,
      order: _order,
      count: _count,
      cardHeight: _cardHeight > 0 ? _cardHeight : size.height,
    );
    final hand = _hand;
    if (!raw.moves || hand == null || !_headroom.isFinite || !hasSize) {
      return raw;
    }
    return raw.within(hand.litRoom() / _restPlace(hand).perPixel, size.height);
  }

  /// Where this card lies in [hand] at rest: how far its top may rise before
  /// it meets what stands over the hand, in the HAND's pixels — the hand's
  /// headroom and the way down from the hand's top to this card's highest
  /// corner, less [HandResultShape.clearance] — and how many of the hand's
  /// pixels one of its own is up its length (the fan's middle card is grown,
  /// a 5-Card hand sets two aside smaller). Read through every transform
  /// between them but this card's own, so it is where the card rests.
  ({double room, double perPixel}) _restPlace(RenderBox hand) {
    final toHand = getTransformTo(hand);
    Offset at(double x, double y) =>
        MatrixUtils.transformPoint(toHand, Offset(x, y));
    final top = math.min(at(0, 0).dy, at(size.width, 0).dy);
    final length =
        (at(size.width / 2, size.height) - at(size.width / 2, 0)).distance;
    return (
      room: top + _headroom - HandResultShape.clearance,
      perPixel: size.height > 0 && length > 0 ? length / size.height : 1,
    );
  }

  /// How far the top of this card's edge light must be drawn down, in the
  /// pixels its face is drawn in, so that [light] — the box its halo's light
  /// would reach, in that frame — stays under what stands over its hand:
  /// read through every transform to the hand, the card's lean and its own
  /// rise included, so a leaning card's raised corner is held too. None where
  /// there is room, or no hand.
  double _haloDrop(HandResultCardEffect e, Rect light) {
    final hand = _hand;
    if (hand == null || !_headroom.isFinite || !hasSize) return 0;
    final toHand = getTransformTo(hand)..multiply(_transformOf(e));
    double yAt(double x, double y) =>
        MatrixUtils.transformPoint(toHand, Offset(x, y)).dy;
    final ceiling = HandResultShape.clearance - _headroom;
    final top = math.min(
      yAt(light.left, light.top),
      yAt(light.right, light.top),
    );
    if (top >= ceiling) return 0;
    // How far down the hand the light's top goes for a pixel down the card.
    final perPixel =
        yAt(light.left, light.top + 1) - yAt(light.left, light.top);
    return perPixel > 0 ? (ceiling - top) / perPixel : 0;
  }

  /// Risen and grown about the card's middle: half its growth goes upwards,
  /// and its lift keeps its foot from sinking ([HandResultCardEffect.within]).
  Matrix4 _transformOf(HandResultCardEffect e) {
    final middle = size.center(Offset.zero);
    return Matrix4.translationValues(middle.dx, middle.dy - e.lift, 0)
      ..scaleByDouble(e.scale, e.scale, 1, 1)
      ..translateByDouble(-middle.dx, -middle.dy, 0, 1);
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _progress?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final e = effect;
    assert(() {
      debugLightBounds = null;
      return true;
    }());
    if (!e.paints) {
      layer = null;
      context.paintChild(child, offset);
      return;
    }
    assert(() {
      debugLitPaints++;
      return true;
    }());
    final radius = Radius.circular(size.height * PlayingCard.cornerShare);
    // Its halo's top drawn down into the card as far as it must, so its light
    // never reaches what stands over the hand; the sides and foot keep theirs,
    // and the card's lit edge keeps its top edge lit.
    final spread = size.height * HandResultShape.haloSpread;
    final blur = size.height * HandResultShape.haloBlur;
    final haloDrop = e.glow > 0
        ? _haloDrop(
            e,
            (Offset.zero & size).inflate(
              spread + blur * HandResultShape.haloReachSigmas,
            ),
          )
        : 0.0;

    // The shadow a lifted card leaves on the cloth, where it lay.
    if (e.raise > 0) {
      final spot = (offset & size)
          .deflate(size.width * HandResultShape.shadowInset)
          .shift(Offset(0, size.height * HandResultShape.shadowDrop));
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(spot, radius),
        Paint()
          ..color = _light.shadow.withValues(
            alpha: _light.shadowStrength * e.raise,
          )
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            size.height * HandResultShape.shadowBlur,
          ),
      );
    }

    void lit(PaintingContext context, Offset offset) {
      final card = RRect.fromRectAndRadius(offset & size, radius);
      final glow = (e.glow * _light.glowStrength).clamp(0.0, 1.0);
      if (glow > 0) {
        // Soft, behind the card: only its edge shows past the stock.
        final halo = card.inflate(spread);
        final shape = Rect.fromLTRB(
          halo.left,
          math.min(halo.top + haloDrop, halo.center.dy),
          halo.right,
          halo.bottom,
        );
        context.canvas.drawRRect(
          RRect.fromRectAndRadius(shape, halo.tlRadius),
          Paint()
            ..color = _light.glow.withValues(
              alpha: glow * HandResultShape.haloStrength,
            )
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
        );
        assert(() {
          debugLightBounds = shape
              .inflate(blur * HandResultShape.haloReachSigmas)
              .shift(-offset);
          return true;
        }());
      }
      context.paintChild(child, offset);
      final canvas = context.canvas;
      if (e.sweep > 0) _paintSweep(canvas, card, e);
      if (glow > 0) {
        // And the edge itself lit, a hairline over the stock's own gold cut.
        canvas.drawRRect(
          card.deflate(0.5),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(
              HandResultShape.edgeMin,
              size.height * HandResultShape.edgeWidth,
            )
            ..color = _light.glow.withValues(alpha: glow),
        );
      }
    }

    if (!e.moves) {
      layer = null;
      lit(context, offset);
      return;
    }
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transformOf(e),
      lit,
      oldLayer: layer is TransformLayer ? layer! as TransformLayer : null,
    );
  }

  /// The hand's own box — its [HandResultGroup]'s — which a light crossing
  /// the whole hand crosses, and which it rises within; null for a card in no
  /// group.
  _RenderHandResultBurst? get _hand {
    for (var node = parent; node != null; node = node.parent) {
      if (node is _RenderHandResultBurst) return node;
    }
    return null;
  }

  /// Where the band of light [e] carries falls on this card's face, 0 its left
  /// edge and 1 its right. A light crossing the whole hand
  /// ([HandResultCardEffect.sweepAcross]) is placed by where this card lies
  /// in its hand, measured as the hand is laid out now — so on an overlapping
  /// fan it lies across two cards at once, one light, as it should; a card in
  /// no hand takes its neighbours to lie side by side.
  @visibleForTesting
  double sweepOnFace(HandResultCardEffect e) {
    if (!e.sweepAcross) return e.sweepAt;
    final hand = _hand;
    if (hand != null && hand.hasSize && hasSize && attached) {
      final toHand = getTransformTo(hand);
      final mid = size.height / 2;
      final left = MatrixUtils.transformPoint(toHand, Offset(0, mid)).dx;
      final right = MatrixUtils.transformPoint(
        toHand,
        Offset(size.width, mid),
      ).dx;
      final width = right - left;
      if (width > 0) {
        final band = width * e.sweepWidth;
        final x = -band + (hand.size.width + 2 * band) * e.sweepAt;
        return (x - left) / width;
      }
    }
    return HandResultProfile.acrossSideBySide(
      progress: e.sweepAt,
      count: _count,
      order: _order,
      width: e.sweepWidth,
    );
  }

  /// A band of light across the face, leaning like a lamp's reflection,
  /// clipped to the card: the card keeps its colours, and every rank and pip
  /// stays readable through it.
  void _paintSweep(Canvas canvas, RRect card, HandResultCardEffect e) {
    final profile = _profile;
    if (profile == null) return;
    // The table's colour as LIGHT: lifted towards the stock's own highlight,
    // so the band brightens the face it crosses rather than staining it.
    final colour = profile.sweepTint == HandResultSweepTint.accent
        ? Color.lerp(
            _accent,
            AppTheme.cardFaceHigh,
            HandResultShape.accentLift,
          )!
        : _light.sweep;
    final alpha = (e.sweep * _light.sweepStrength).clamp(0.0, 1.0);
    final band = Rect.fromCenter(
      center: Offset.zero,
      width: card.width * e.sweepWidth,
      height: card.height * HandResultShape.bandLength,
    );
    canvas
      ..save()
      ..clipRRect(card)
      ..translate(card.left + sweepOnFace(e) * card.width, card.center.dy)
      ..rotate(HandResultShape.bandLean)
      ..drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
            colors: [
              colour.withValues(alpha: 0),
              colour.withValues(alpha: alpha),
              colour.withValues(alpha: 0),
            ],
          ).createShader(band),
      )
      ..restore();
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final e = effect;
    if (!e.moves) return super.hitTestChildren(result, position: position);
    return result.addWithPaintTransform(
      transform: _transformOf(e),
      position: position,
      hitTest: (result, position) =>
          super.hitTestChildren(result, position: position),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final e = effect;
    if (e.moves) transform.multiply(_transformOf(e));
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(FlagProperty('lit', value: lit, ifTrue: 'lit'))
      ..add(DiagnosticsProperty<HandResultCardEffect>('effect', effect));
  }
}

/// The hand's own light, behind its cards: a Trail's radial light and its
/// sparks. Nothing at all for every other level. Its box is the hand's, the
/// one its cards rise within ([HandResultGroup.headroom]).
class _HandResultBurst extends SingleChildRenderObjectWidget {
  const _HandResultBurst({
    required this.progress,
    required this.profile,
    required this.light,
    required this.seed,
    required this.headroom,
    super.child,
  });

  final Animation<double>? progress;
  final HandResultProfile? profile;
  final HandResultLight light;
  final int seed;
  final double headroom;

  @override
  _RenderHandResultBurst createRenderObject(BuildContext context) =>
      _RenderHandResultBurst()
        ..progress = progress
        ..profile = profile
        ..light = light
        ..seed = seed
        ..headroom = headroom;

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderHandResultBurst renderObject,
  ) => renderObject
    ..progress = progress
    ..profile = profile
    ..light = light
    ..seed = seed
    ..headroom = headroom;
}

/// One spark of a Trail's burst: which way it flies, how fast and how late,
/// how large, and which of the two golds.
typedef _Spark = ({
  double angle,
  double speed,
  double delay,
  double size,
  int colour,
});

class _RenderHandResultBurst extends RenderProxyBox {
  Animation<double>? _progress;
  set progress(Animation<double>? value) {
    if (identical(value, _progress)) return;
    if (attached) _progress?.removeListener(markNeedsPaint);
    _progress = value;
    if (attached) _progress?.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  HandResultProfile? _profile;
  set profile(HandResultProfile? value) {
    if (identical(value, _profile)) return;
    _profile = value;
    _sparks = null;
    markNeedsPaint();
  }

  HandResultLight _light = HandResultLight.dark;
  set light(HandResultLight value) {
    if (identical(value, _light)) return;
    _light = value;
    markNeedsPaint();
  }

  int _seed = 0;
  set seed(int value) {
    if (value == _seed) return;
    _seed = value;
    _sparks = null;
    markNeedsPaint();
  }

  /// The free space over the hand ([HandResultGroup.headroom]).
  double _headroom = double.infinity;
  set headroom(double value) {
    if (value == _headroom) return;
    _headroom = value;
    markNeedsPaint();
  }

  /// The box of everything the hand's own light last painted — the radial
  /// light's ellipse and every spark's streak — in its own frame, or null
  /// when it painted none. Recorded in debug builds only, for the tests.
  Rect? debugLightBounds;

  /// How far above the hand's top its light may reach, in its own pixels:
  /// the headroom less [HandResultShape.clearance].
  double get _roomAbove => _headroom - HandResultShape.clearance;

  /// The least room any lit card of this hand has over it
  /// ([RenderHandResultCard._restPlace]), in the hand's pixels: what the whole
  /// hand rises within, so it rises as one and its tightest card — the fan's
  /// proud middle card, under the viewer's bet badge — touches nothing.
  double litRoom() {
    var room = double.infinity;
    void visit(RenderObject node) {
      if (node is RenderHandResultCard) {
        if (node.lit && node.hasSize) {
          room = math.min(room, node._restPlace(this).room);
        }
        return;
      }
      node.visitChildren(visit);
    }

    visitChildren(visit);
    return room;
  }

  /// The burst's sparks, made once per result from its [seed], so every frame
  /// draws the same ones where they have got to.
  List<_Spark>? _sparks;
  List<_Spark> _sparksFor(int count) => _sparks ??= _makeSparks(count, _seed);

  static List<_Spark> _makeSparks(int count, int seed) {
    final random = math.Random(seed);
    return [
      for (var i = 0; i < count; i++)
        (
          angle:
              2 *
              math.pi *
              (i + HandResultShape.sparkJitter * random.nextDouble()) /
              count,
          speed:
              HandResultShape.sparkSpeedMin +
              HandResultShape.sparkSpeedRange * random.nextDouble(),
          delay: HandResultProfile.sparkSpread * random.nextDouble(),
          size:
              HandResultShape.sparkSizeMin +
              HandResultShape.sparkSizeRange * random.nextDouble(),
          colour: i.isEven ? 0 : 1,
        ),
    ];
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _progress?.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _progress?.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final progress = _progress;
    final profile = _profile;
    // What it paints, noted in debug builds only ([debugLightBounds]).
    Rect? painted;
    bool note(Rect r) {
      painted = painted?.expandToInclude(r) ?? r;
      return true;
    }

    if (progress != null && profile != null) {
      final e = profile.burstAtTime(progress.value);
      final canvas = context.canvas;
      final centre = (offset & size).center;
      final h = size.height;
      if (e.radial > 0) {
        // Kept under what stands over the hand: it gives way above and
        // keeps its reach at the sides and below.
        final bounds = HandResultShape.radialBounds(
          size,
          e.radialScale,
          ceiling: -_roomAbove,
        ).shift(offset);
        assert(note(bounds));
        final rx = bounds.width / 2;
        final ry = bounds.height / 2;
        final alpha = (e.radial * _light.radialStrength).clamp(0.0, 1.0);
        final disc = Rect.fromCircle(center: Offset.zero, radius: rx);
        canvas
          ..save()
          ..translate(bounds.center.dx, bounds.center.dy)
          ..scale(1, ry / rx)
          ..drawOval(
            disc,
            Paint()
              ..shader = RadialGradient(
                colors: [
                  _light.radial.withValues(alpha: alpha),
                  _light.radial.withValues(
                    alpha: alpha * HandResultShape.radialMidStrength,
                  ),
                  _light.radial.withValues(alpha: 0),
                ],
                stops: const [0, HandResultShape.radialMid, 1],
              ).createShader(disc),
          )
          ..restore();
      }
      final life = profile.sparkLife.inMicroseconds / 1000;
      if (profile.sparks > 0 &&
          e.sparkTime >= 0 &&
          e.sparkTime < profile.sparksDone &&
          life > 0) {
        final ax = size.width / 2;
        final ay = size.height / 2;
        Offset at(_Spark spark, double tau, double rise) {
          final out = Curves.easeOutCubic.transform(tau.clamp(0.0, 1.0));
          final reach = h * HandResultShape.sparkReach * spark.speed * out;
          final dx = math.cos(spark.angle);
          final dy = math.sin(spark.angle);
          const from = HandResultShape.sparkFrom;
          final along = from + (1 - from) * out;
          return centre +
              Offset(
                dx * (ax * along + reach),
                dy * (ay * along + reach * (dy < 0 ? rise : 1)),
              );
        }

        for (final spark in _sparksFor(profile.sparks)) {
          final tau = (e.sparkTime - spark.delay * life) / life;
          if (tau <= 0 || tau >= 1) continue;
          final fadeIn = math.min(1.0, tau / HandResultShape.sparkFadeIn);
          final fadeOut = math.pow(1 - tau, HandResultShape.sparkFadeOut);
          final alpha = (_light.sparkStrength * fadeIn * fadeOut)
              .clamp(0.0, 1.0)
              .toDouble();
          const tail = HandResultShape.sparkTail;
          final colour = _light.sparks[spark.colour % _light.sparks.length];
          final width = math.max(
            HandResultShape.edgeMin,
            h * HandResultShape.sparkWidth * spark.size,
          );
          // A spark that climbs climbs only as far as the room over the hand:
          // the rest of its flight is behind the cards, where it began.
          final rise = HandResultShape.sparkRiseFor(
            angle: spark.angle,
            reach: h * HandResultShape.sparkReach * spark.speed,
            halfHeight: ay,
            room: _roomAbove,
            head: width,
          );
          assert(
            note(
              Rect.fromPoints(
                at(spark, tau - tail, rise),
                at(spark, tau, rise),
              ).inflate(width / 2),
            ),
          );
          // A spark, not a dash: a faint tail behind a bright head.
          canvas
            ..drawLine(
              at(spark, tau - tail, rise),
              at(spark, tau - tail / 3, rise),
              Paint()
                ..strokeCap = StrokeCap.round
                ..strokeWidth = width * HandResultShape.sparkTailWidth
                ..color = colour.withValues(
                  alpha: alpha * HandResultShape.sparkTailStrength,
                ),
            )
            ..drawLine(
              at(spark, tau - tail / 3, rise),
              at(spark, tau, rise),
              Paint()
                ..strokeCap = StrokeCap.round
                ..strokeWidth = width
                ..color = colour.withValues(alpha: alpha),
            );
        }
      }
    }
    assert(() {
      debugLightBounds = painted?.shift(-offset);
      return true;
    }());
    final child = this.child;
    if (child != null) context.paintChild(child, offset);
  }
}
