/// The hand-result card animations' numbers (owner's brief, 29 Sep 2026:
/// "premium HAND-RESULT CARD ANIMATIONS … visual feedback ONLY when a
/// player's final hand result is known"), in one place: which hands earn one,
/// how long each runs, how far a card rises, how much light it catches, and
/// how the two themes take it.
///
/// Five levels, rising with the hand's rarity and saying so through
/// restraint — a Pair is noticed, a Trail is a moment:
///
/// | level          | name                 | what it does                                         |
/// |----------------|----------------------|------------------------------------------------------|
/// | Pair           | Small Pulse (1/5)    | the pair alone rises 1.00 → 1.03 → 1.00              |
/// | Color          | Colored Sweep (2/5)  | one light, in the table's colour, crosses the three  |
/// | Sequence       | Card Sweep (3/5)     | card 1 → 2 → 3, each rising and lit in turn          |
/// | Pure Sequence  | Stronger Glow (4/5)  | a lift, a sweep, then a soft gold edge that settles  |
/// | Trail          | Premium Burst (5/5)  | lift, sweep, a short spark burst, a radial light     |
///
/// Everything here is data: the widgets (`widgets/hand_result.dart`) read a
/// [HandResultProfile] and draw what it says, so a level is tuned by editing
/// its row and nothing else. The widgets never pick a number of their own.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The five hands a result animation is played for, weakest first. A High
/// Card has none: there is nothing among its cards to point at.
enum HandResultLevel {
  pair,
  color,
  sequence,
  pureSequence,
  trail;

  /// The level the server's hand [category] earns — its HandCategory, as a
  /// reveal carries it (`category`: HIGH_CARD 0, PAIR 1, COLOR 2, SEQUENCE 3,
  /// PURE_SEQUENCE 4, TRAIL 5) — or null for a High Card and for anything
  /// outside the ranking. The server decided it; this only reads the number.
  static HandResultLevel? fromCategory(int category) => switch (category) {
    1 => pair,
    2 => color,
    3 => sequence,
    4 => pureSequence,
    5 => trail,
    _ => null,
  };

  /// The same, from the server's English wire name (`handName`), for a reveal
  /// that carries no `category` — a fixture, or a payload from before it.
  /// Exactly the server's names; anything else is null.
  static HandResultLevel? fromHandName(String name) => switch (name) {
    'Pair' => pair,
    'Color' => color,
    'Sequence' => sequence,
    'Pure Sequence' => pureSequence,
    'Trail' => trail,
    _ => null,
  };
}

/// Where the light that crosses the cards takes its colour from.
enum HandResultSweepTint {
  /// Warm light — the stock catching the table's lamp ([HandResultLight.sweep]).
  light,

  /// The table's own colour ([TablePalette.accent]): gold at a Seen table,
  /// sapphire at a Blind one, violet at a Variation one — the Color's
  /// "Colored Sweep", never a new neon.
  accent,
}

/// What one card of a result looks like at one moment: how far it has risen,
/// the light on and around it. [rest] is a card nothing is happening to.
@immutable
class HandResultCardEffect {
  const HandResultCardEffect({
    this.scale = 1,
    this.lift = 0,
    this.raise = 0,
    this.glow = 0,
    this.sweep = 0,
    this.sweepAt = 0,
    this.sweepWidth = 0,
    this.sweepAcross = false,
  });

  static const rest = HandResultCardEffect();

  /// The card's size, about its foot: 1 at rest, [HandResultProfile.peakScale]
  /// at the top of its rise.
  final double scale;

  /// How far the card has risen off its place, in logical pixels, up the
  /// card's own length.
  final double lift;

  /// How far off the cloth the card stands, 0 to 1: the soft shadow under a
  /// lifted card, at its place.
  final double raise;

  /// The gold light round the card's edge, 0 to 1 of the theme's strength.
  final double glow;

  /// The band of light crossing the card's face, 0 to 1 of the theme's
  /// strength, centred [sweepAt] across the card (0 its left edge, 1 its
  /// right) and [sweepWidth] of the card's width wide.
  final double sweep;
  final double sweepAt;
  final double sweepWidth;

  /// Whether the light is ONE light crossing the whole hand (a Color, a Pure
  /// Sequence, a Trail) rather than one on this card alone (a Sequence).
  /// Then [sweepAt] is how far across the HAND it has come, 0 to 1, and the
  /// card finds where that falls on its own face from where it lies in the
  /// hand — so on the viewer's overlapping fan the light is on two cards at
  /// once where they overlap, as one light would be.
  final bool sweepAcross;

  /// Whether the card is moved at all.
  bool get moves => scale != 1 || lift != 0;

  /// Whether anything at all is drawn for it.
  bool get paints => moves || raise > 0 || glow > 0 || sweep > 0;

  @override
  bool operator ==(Object other) =>
      other is HandResultCardEffect &&
      other.scale == scale &&
      other.lift == lift &&
      other.raise == raise &&
      other.glow == glow &&
      other.sweep == sweep &&
      other.sweepAt == sweepAt &&
      other.sweepWidth == sweepWidth &&
      other.sweepAcross == sweepAcross;

  @override
  int get hashCode => Object.hash(
    scale,
    lift,
    raise,
    glow,
    sweep,
    sweepAt,
    sweepWidth,
    sweepAcross,
  );

  @override
  String toString() =>
      'HandResultCardEffect(scale: ${scale.toStringAsFixed(4)}, '
      'lift: ${lift.toStringAsFixed(2)}, glow: ${glow.toStringAsFixed(3)}, '
      'sweep: ${sweep.toStringAsFixed(3)} at ${sweepAt.toStringAsFixed(2)})';
}

/// What the whole hand's light does at one moment — the Trail's alone: the
/// radial light behind the cards and the spark burst from them.
@immutable
class HandResultBurstEffect {
  const HandResultBurstEffect({
    this.radial = 0,
    this.radialScale = 1,
    this.sparkTime = -1,
  });

  static const rest = HandResultBurstEffect();

  /// The radial light behind the cards, 0 to 1 of the theme's strength, and
  /// how far it has spread (1 = the cards' own extent).
  final double radial;
  final double radialScale;

  /// How long ago the spark burst began, in milliseconds; negative before it
  /// has, and once every spark has gone it is past
  /// [HandResultProfile.sparksDone].
  final double sparkTime;

  @override
  bool operator ==(Object other) =>
      other is HandResultBurstEffect &&
      other.radial == radial &&
      other.radialScale == radialScale &&
      other.sparkTime == sparkTime;

  @override
  int get hashCode => Object.hash(radial, radialScale, sparkTime);
}

/// One level's animation: how long it runs and what each part of it does,
/// every figure in one row ([of]).
///
/// Time is a share of [duration], from 0 (the result lands — the WINNER
/// ribbon strikes) to 1 (the cards have settled). A card's own motion runs in
/// a window of that: the whole of it, or, where [stagger] is set, one after
/// another — card k from `k * stagger` for [cardSpan].
@immutable
class HandResultProfile {
  const HandResultProfile({
    required this.level,
    required this.duration,
    required this.peakScale,
    required this.liftShare,
    this.liftFloor = liftMin,
    this.riseTo = 0.4,
    this.holdTo = 0.4,
    this.riseCurve = Curves.easeOut,
    this.fallCurve = Curves.easeInOut,
    this.stagger = 0,
    this.cardSpan = 1,
    this.sweep = 0,
    this.sweepTint = HandResultSweepTint.light,
    this.sweepPerCard = false,
    this.sweepFrom = 0,
    this.sweepTo = 1,
    this.sweepWidth = 0.5,
    this.glow = 0,
    this.glowFollowsLift = false,
    this.glowFrom = 0,
    this.glowPeakAt = 0.5,
    this.restGlow = 0,
    this.sparks = 0,
    this.sparkLife = Duration.zero,
    this.burstAt = 0,
    this.radialGlow = 0,
    this.radialFrom = 0,
    this.radialPeakAt = 0.5,
    this.restRadial = 0,
  });

  final HandResultLevel level;

  /// From the result landing to the cards at rest.
  final Duration duration;

  /// The card's size at the top of its rise (1.00 → [peakScale] → 1.00).
  final double peakScale;

  /// How far it rises, as a share of the card's height, held between
  /// [liftFloor] and [liftMax] logical pixels: 3–6 px on the viewer's own
  /// cards, 2–3 on a rim seat's smaller ones.
  final double liftShare;

  /// The least it rises, in logical pixels, however small the card: a rim
  /// seat's 40dp card would otherwise rise a pixel and a half, which reads as
  /// nothing. [liftMin]; none under reduced motion.
  final double liftFloor;

  /// Where in a card's window it reaches the top of its rise, how long it
  /// holds there, and the curves up and back down.
  final double riseTo;
  final double holdTo;
  final Curve riseCurve;
  final Curve fallCurve;

  /// Card after card (the Sequence): how far apart their windows start, and
  /// how long each one is, both as shares of [duration]. 0 moves them
  /// together.
  final double stagger;
  final double cardSpan;

  /// The light crossing the cards: its strength (0 = none), its colour, and
  /// whether it crosses each card in that card's own window
  /// ([sweepPerCard]) or the whole hand once, first card to last, between
  /// [sweepFrom] and [sweepTo]. [sweepWidth] is the band's width as a share
  /// of a card's.
  final double sweep;
  final HandResultSweepTint sweepTint;
  final bool sweepPerCard;
  final double sweepFrom;
  final double sweepTo;
  final double sweepWidth;

  /// The gold light at the cards' edges: its strength at its peak, and either
  /// following each card's rise ([glowFollowsLift]) or rising from
  /// [glowFrom] to [glowPeakAt] and settling to [restGlow], where it stays
  /// until the next deal — a still light, painted once.
  final double glow;
  final bool glowFollowsLift;
  final double glowFrom;
  final double glowPeakAt;
  final double restGlow;

  /// The spark burst: how many, how long each lives, and when (a share of
  /// [duration]) it begins.
  final int sparks;
  final Duration sparkLife;
  final double burstAt;

  /// The radial light behind the cards: its strength at its peak, when it
  /// begins, when it peaks, and what is left of it once settled.
  final double radialGlow;
  final double radialFrom;
  final double radialPeakAt;
  final double restRadial;

  /// The most and the least any card rises, in logical pixels (the brief's
  /// "2–6 px").
  static const double liftMax = 6;
  static const double liftMin = 2;

  /// How late a spark may leave after the burst begins, as a share of its
  /// life, so the burst is a burst and not one ring.
  static const double sparkSpread = 0.14;

  /// Reduced motion keeps this share of the movement …
  static const double reducedMotion = 0.3;

  /// … and marks the cards that made the hand with at least this much edge
  /// light, since there is no movement left to point at them with.
  static const double reducedMark = 0.24;

  /// "Small Pulse": the pair together, up and back down (brief: 1.00 → 1.03
  /// → 1.00, ~250–350 ms, ease-out/in-out; no glow, no particles).
  static const pair = HandResultProfile(
    level: HandResultLevel.pair,
    duration: Duration(milliseconds: 320),
    peakScale: 1.03,
    liftShare: 0.035,
    riseTo: 0.42,
    holdTo: 0.42,
  );

  /// "Colored Sweep": a fast light in the table's colour across the three,
  /// one side of the hand to the other, over a small lift (~450–600 ms).
  static const color = HandResultProfile(
    level: HandResultLevel.color,
    duration: Duration(milliseconds: 540),
    peakScale: 1.03,
    liftShare: 0.035,
    riseTo: 0.3,
    holdTo: 0.62,
    sweep: 0.42,
    sweepTint: HandResultSweepTint.accent,
    sweepFrom: 0.06,
    sweepTo: 0.9,
    sweepWidth: 0.6,
  );

  /// "Card Sweep": card 1 → 2 → 3, overlapping, each rising a little and
  /// catching the light in turn; the hand stays together (~550–700 ms).
  static const sequence = HandResultProfile(
    level: HandResultLevel.sequence,
    duration: Duration(milliseconds: 660),
    peakScale: 1.03,
    liftShare: 0.045,
    riseTo: 0.38,
    holdTo: 0.5,
    stagger: 0.2,
    cardSpan: 0.6,
    sweep: 0.32,
    sweepPerCard: true,
    sweepWidth: 0.55,
    glow: 0.22,
    glowFollowsLift: true,
  );

  /// "Stronger Card Glow": a lift, a light across the hand, then a soft gold
  /// edge that settles and stays (~700–900 ms).
  static const pureSequence = HandResultProfile(
    level: HandResultLevel.pureSequence,
    duration: Duration(milliseconds: 840),
    peakScale: 1.035,
    liftShare: 0.055,
    riseTo: 0.28,
    holdTo: 0.6,
    sweep: 0.42,
    sweepFrom: 0.14,
    sweepTo: 0.62,
    sweepWidth: 0.5,
    glow: 0.62,
    glowFrom: 0.36,
    glowPeakAt: 0.72,
    restGlow: 0.3,
  );

  /// "Premium Burst": the cards rise with a strong, controlled light at their
  /// edges, a light crosses them, a short burst of sparks leaves from behind
  /// them and a radial light spreads, and the cards settle with a small light
  /// kept. No fireworks, no shake, nothing past the hand's own surroundings.
  static const trail = HandResultProfile(
    level: HandResultLevel.trail,
    duration: Duration(milliseconds: 1100),
    peakScale: 1.04,
    liftShare: 0.075,
    riseTo: 0.22,
    holdTo: 0.6,
    riseCurve: Curves.easeOutCubic,
    sweep: 0.48,
    sweepFrom: 0.14,
    sweepTo: 0.5,
    sweepWidth: 0.5,
    glow: 0.85,
    glowFrom: 0.02,
    glowPeakAt: 0.34,
    restGlow: 0.38,
    sparks: 16,
    sparkLife: Duration(milliseconds: 650),
    burstAt: 0.2,
    radialGlow: 0.5,
    radialFrom: 0.16,
    radialPeakAt: 0.48,
    restRadial: 0.1,
  );

  /// Every level's row, weakest first.
  static const all = [pair, color, sequence, pureSequence, trail];

  /// The row for [level].
  static HandResultProfile of(HandResultLevel level) => all[level.index];

  /// The row for [level] under reduced motion ([reduced]), made once.
  static HandResultProfile reducedOf(HandResultLevel level) =>
      _reducedRows[level.index];
  static final List<HandResultProfile> _reducedRows = [
    for (final row in all) row.reduced,
  ];

  /// This level for a player who has asked the phone for less motion
  /// (`MediaQuery.disableAnimationsOf`): [reducedMotion] of the rise, no
  /// light crossing the cards, no sparks and no radial light — and the cards
  /// that made the hand still marked, by an edge light that rises and settles
  /// in place of the movement.
  HandResultProfile get reduced => HandResultProfile(
    level: level,
    duration: duration,
    peakScale: 1 + (peakScale - 1) * reducedMotion,
    liftShare: liftShare * reducedMotion,
    liftFloor: 0,
    riseTo: 0.4,
    holdTo: 0.6,
    glow: math.max(glow * 0.5, reducedMark),
    glowPeakAt: 0.45,
    restGlow: restGlow * 0.6,
  );

  /// How long after the burst begins the last spark has gone, in ms.
  double get sparksDone =>
      sparkLife.inMicroseconds / 1000 * (1 + sparkSpread) + 1;

  /// A card's rise at [u] of its own window: 0 before and after, 1 at the
  /// top.
  double envelope(double u) {
    if (u <= 0 || u >= 1) return 0;
    if (u < riseTo) return riseCurve.transform(u / riseTo);
    if (u < holdTo) return 1;
    return 1 - fallCurve.transform((u - holdTo) / (1 - holdTo));
  }

  /// Where card [order] of [count] is in its own window at [t].
  double _cardTime(double t, int order) {
    if (stagger <= 0) return t;
    return ((t - order * stagger) / cardSpan).clamp(0.0, 1.0);
  }

  /// A light that rises from [from] to its peak at [peakAt] and settles to
  /// [rest] by the end: 0 to 1 of [peak].
  static double _rising(
    double t, {
    required double peak,
    required double from,
    required double peakAt,
    required double rest,
  }) {
    if (peak <= 0 || t <= from) return 0;
    if (t >= 1) return rest;
    if (t < peakAt) {
      return peak * Curves.easeOut.transform((t - from) / (peakAt - from));
    }
    final settle = Curves.easeInOut.transform((t - peakAt) / (1 - peakAt));
    return peak + (rest - peak) * settle;
  }

  /// Card [order] of the [count] that made the hand, at [t] (0 to 1 of
  /// [duration]), for a card [cardHeight] tall.
  HandResultCardEffect cardAt(
    double t, {
    required int order,
    required int count,
    required double cardHeight,
  }) {
    if (t <= 0) return HandResultCardEffect.rest;
    final u = _cardTime(t, order);
    final e = envelope(u);
    final lift = (liftShare * cardHeight).clamp(liftFloor, liftMax) * e;

    var sweepAlpha = 0.0;
    var sweepAt = 0.0;
    var across = false;
    if (sweep > 0 && t < 1) {
      // The band enters from before the card's left edge and leaves past its
      // right one, so it never pops on or off a face.
      if (sweepPerCard) {
        if (u > 0 && u < 1) {
          sweepAt =
              -sweepWidth + (1 + 2 * sweepWidth) * Motion.travel.transform(u);
          sweepAlpha = sweep;
        }
      } else if (t > sweepFrom && t < sweepTo) {
        // One light across the whole hand, first card to last: how far across
        // the hand it has come, which the card turns into where it falls on
        // its own face from where the card lies in the hand (see
        // [HandResultCardEffect.sweepAcross]).
        sweepAt = Motion.travel.transform(
          (t - sweepFrom) / (sweepTo - sweepFrom),
        );
        sweepAlpha = sweep;
        across = true;
      }
    }

    final glowNow = glowFollowsLift
        ? glow * e
        : _rising(
            t,
            peak: glow,
            from: glowFrom,
            peakAt: glowPeakAt,
            rest: restGlow,
          );

    return HandResultCardEffect(
      scale: 1 + (peakScale - 1) * e,
      lift: lift,
      raise: e,
      glow: glowNow,
      sweep: across || (sweepAt > -sweepWidth && sweepAt < 1 + sweepWidth)
          ? sweepAlpha
          : 0,
      sweepAt: sweepAt,
      sweepWidth: sweepWidth,
      sweepAcross: across,
    );
  }

  /// Where a light [progress] of the way across a hand of [count] cards falls
  /// on card [order]'s face (0 its left edge, 1 its right), for a hand whose
  /// cards lie side by side — what a card that cannot see where it lies in
  /// its hand assumes.
  static double acrossSideBySide({
    required double progress,
    required int count,
    required int order,
    required double width,
  }) => -width + (count + 2 * width) * progress - order;

  /// The hand's light as a whole — the radial light and the sparks — at [t].
  HandResultBurstEffect burstAtTime(double t) {
    if (t <= 0 || (radialGlow <= 0 && sparks <= 0)) {
      return HandResultBurstEffect.rest;
    }
    final radial = _rising(
      t,
      peak: radialGlow,
      from: radialFrom,
      peakAt: radialPeakAt,
      rest: restRadial,
    );
    final spread = t <= radialFrom
        ? 0.0
        : Curves.easeOutCubic.transform(
            ((t - radialFrom) / (1 - radialFrom)).clamp(0.0, 1.0),
          );
    final ms = duration.inMicroseconds / 1000;
    final sparkTime = sparks <= 0 || t >= 1 ? -1.0 : (t - burstAt) * ms;
    return HandResultBurstEffect(
      radial: radial,
      radialScale:
          HandResultShape.radialStart + HandResultShape.radialGrowth * spread,
      sparkTime: sparkTime,
    );
  }
}

/// Where the light is drawn on and round a card and a hand, the same for
/// every level — each figure a share of the card's (or the hand's) size, so
/// a rim seat's 40dp card and the viewer's 84dp one carry it alike.
abstract final class HandResultShape {
  /// The soft shadow a lifted card leaves where it lay: drawn in from its
  /// sides by [shadowInset] of its width, [shadowDrop] of its height below
  /// it, blurred by [shadowBlur] of its height.
  static const double shadowInset = 0.06;
  static const double shadowDrop = 0.05;
  static const double shadowBlur = 0.08;

  /// The gold light round a card: a halo behind it, [haloSpread] of its
  /// height past its edge and blurred by [haloBlur], at [haloStrength] of the
  /// light; and its edge itself lit, [edgeWidth] of its height wide and never
  /// under [edgeMin] logical pixels.
  static const double haloSpread = 0.03;
  static const double haloBlur = 0.07;
  static const double haloStrength = 0.9;
  static const double edgeWidth = 0.018;
  static const double edgeMin = 1;

  /// The band of light crossing a face: [bandLength] of the card's height
  /// long (past both ends at its lean) and leaning [bandLean] radians off
  /// the vertical, like a lamp's reflection. A Color's band, in the table's
  /// colour, is lifted [accentLift] of the way towards the stock's own
  /// highlight, so it brightens the face rather than staining it.
  static const double bandLength = 1.6;
  static const double bandLean = 0.32;
  static const double accentLift = 0.3;

  /// A Trail's radial light: out past the hand's box by [radialReachX] and
  /// [radialReachY] of the cards' height, growing from [radialStart] of that
  /// by [radialGrowth] as it spreads; [radialMidStrength] of its light left
  /// at [radialMid] of the way out.
  static const double radialReachX = 0.3;
  static const double radialReachY = 0.35;
  static const double radialStart = 0.8;
  static const double radialGrowth = 0.35;
  static const double radialMid = 0.55;
  static const double radialMidStrength = 0.45;

  /// A Trail's sparks. Each leaves from behind the cards, [sparkFrom] of the
  /// way out to the hand's edge, and flies past it by up to [sparkReach] of
  /// the cards' height — upwards, over the seat's own pod, only [sparkRise]
  /// of that. Its streak is [sparkTail] of its life long, [sparkWidth] of
  /// the cards' height wide (a tail [sparkTailWidth] as wide at
  /// [sparkTailStrength] of its light); it fades in over [sparkFadeIn] of its
  /// life and out along (1 − life)^[sparkFadeOut]. They leave evenly round
  /// the hand, each up to [sparkJitter] of a step off its place, at
  /// [sparkSpeedMin] to + [sparkSpeedRange] of the reach, in sizes from
  /// [sparkSizeMin] to + [sparkSizeRange].
  static const double sparkFrom = 0.5;
  static const double sparkReach = 0.45;
  static const double sparkRise = 0.7;
  static const double sparkTail = 0.09;
  static const double sparkWidth = 0.032;
  static const double sparkTailWidth = 0.6;
  static const double sparkTailStrength = 0.4;
  static const double sparkFadeIn = 0.12;
  static const double sparkFadeOut = 1.3;
  static const double sparkJitter = 0.6;
  static const double sparkSpeedMin = 0.75;
  static const double sparkSpeedRange = 0.45;
  static const double sparkSizeMin = 0.8;
  static const double sparkSizeRange = 0.45;
}

/// How the two themes take the light (brief: "Dark: glow and sweep slightly
/// more visible, background stays dark. Light: softer shadows, controlled
/// highlights, localized glow, cards never washed out"). Not one inverted
/// from the other: the day table's pale cloth wants a deeper gold at less
/// strength, the night's dark cloth a paler gold at more.
@immutable
class HandResultLight {
  const HandResultLight._({
    required this.brightness,
    required this.glow,
    required this.glowStrength,
    required this.sweep,
    required this.sweepStrength,
    required this.sparks,
    required this.sparkStrength,
    required this.radial,
    required this.radialStrength,
    required this.shadowStrength,
  });

  final Brightness brightness;

  /// The gold at the cards' edges, and how strong it is at full ([1]).
  final Color glow;
  final double glowStrength;

  /// The warm light crossing a face ([HandResultSweepTint.light]).
  final Color sweep;
  final double sweepStrength;

  /// The sparks' two golds, taken in turn.
  final List<Color> sparks;
  final double sparkStrength;

  /// The radial light behind a Trail.
  final Color radial;
  final double radialStrength;

  /// The shadow under a lifted card, at its highest.
  final double shadowStrength;

  /// The colour that shadow is drawn in ([AppTheme.shadowFor]).
  Color get shadow => AppTheme.shadowFor(brightness);

  static const dark = HandResultLight._(
    brightness: Brightness.dark,
    glow: AppTheme.goldOnDark,
    glowStrength: 1,
    sweep: AppTheme.goldBright,
    sweepStrength: 1,
    sparks: [AppTheme.goldBright, AppTheme.goldOnDark],
    sparkStrength: 1,
    radial: AppTheme.gold,
    radialStrength: 1,
    shadowStrength: 0.34,
  );

  static const light = HandResultLight._(
    brightness: Brightness.light,
    glow: AppTheme.gold,
    glowStrength: 0.72,
    sweep: AppTheme.goldBright,
    sweepStrength: 0.85,
    sparks: [AppTheme.gold, AppTheme.goldOnLight],
    sparkStrength: 0.9,
    radial: AppTheme.gold,
    radialStrength: 0.6,
    shadowStrength: 0.18,
  );

  static HandResultLight of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}
