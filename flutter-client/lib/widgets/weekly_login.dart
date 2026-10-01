import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../screens/reward_programs_screen.dart'
    show
        rewardPrizeIcon,
        rewardPrizeInk,
        rewardPrizeLabel,
        rewardPrizeShort,
        rewardProgramHint;
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/depth.dart';
import '../widgets/fireworks.dart';
import '../widgets/game_loader.dart';
import '../widgets/level_accent.dart';
import '../widgets/lucky_spin_key.dart' show LuckyGoldKey;
import '../widgets/premium_surface.dart';
import '../widgets/table_tax.dart' show LevelCloseKey;

// The weekly login popup (owner, 30 Sep 2026: "Use this animation which
// shows up everyday in case of weekly login and put the prize in blue boxes,
// it should pop after login and if user has claimed it should not show when
// user start the app, otherwise show it"; then "Calender size should be big
// and it should play animation where all box one by one come up and then
// rewards on them boxes"; then the polish brief the same evening — "Premium
// King Teen Patti Reward Vault", not "generic calendar popup": the lobby's
// glass, its gold, its depth ladder, the card restyled out of its white, the
// day cards claimed / current / upcoming / locked / final, the right panel
// a reward hierarchy).
//
// The owner's `assets/animations/WeekLy.json` is a desk calendar: a card
// with six binder rings, and seven boxes — four on the top row, three on the
// bottom — that pop in one after another over the first two seconds (each
// from nothing to 110% and down to size), hold, and pop out again by the end
// (the file is a 3 s loop), with a grey skyline behind the card and five
// sparkles round it. 600 x 250 units, 30 fps, 90 frames; no 3D, no
// expressions, no images (the §12.3 traps), so the phones play exactly what
// the preview shows. It has no text and no numbers: the seven boxes are the
// seven days of the WEEKLY login streak, Day 1 to Day 7 in reading order,
// and the prize of each day is DRAWN OVER ITS BOX by Flutter — a card of the
// lobby's glass with its mark and its figure — from the geometry the file
// lays the boxes out by ([WeeklyCalendarGeometry]), so the prize and the box
// cannot drift apart.
//
// The file is restyled as it plays, never edited (ValueDelegates): its white
// solid, its sparkles and its skyline hidden; its card's white body, grey
// header band and ring holes in the theme's own glass tones — charcoal by
// night, warm off-white by day; its outline and its rings thinner and
// softer; and each box in its day's colour — gold for a day collected or
// today's, the blind table's cyan for the next day, dark glass for the days
// beyond, gold over purple for the seventh — so the pop-in already reads as
// the card that then lands on it.
//
// The sequence is the owner's: the boxes come up one by one (the file's own
// pop-ins, played ONCE to the frame every box is in and still,
// [WeeklyCalendarGeometry.holdFrame], and held there — the file's pop-out
// would take the boxes away every three seconds), and only THEN the prizes
// land on them, one after another ([WeeklyCalendar.revealStagger] apart,
// each with the boxes' own overshoot). The popup shows the card as large as
// the screen allows: the file cropped to the card, taking the panel's whole
// height on the left, the words and the key on the right. The prize's
// figure is the largest thing on its card (owner, 30 Sep 2026: "Make Text
// size bigger of reward money which u show in calender"), every size on a
// card a share of the box's side.
//
// Opened inside a Blind or Variation level the popup takes that level's
// colour as the lobby's two drawers do (owner, 30 Sep 2026: "In day mode,
// when i click "Rewards" button after going into blind catalogue, then daily
// Streak background color should be changed acc to card color, same with
// when i go in variation catalogue"; [LevelAccent], which the lobby lays over
// the overlay with the level on screen): the panel's wash, its edge, the
// light behind it and the calendar card's glass in the level's hue — ice
// and sapphire inside Blind, lavender and violet inside Variation — and the
// house gold at the front and inside Seen, where [LevelAccent.of] is null
// and nothing changes. The day cards keep their own colours everywhere: gold
// is what a collected day and today's mean, whatever the room.

/// Where the file lays its calendar out, in the file's own units — read off
/// the layers (`test/weekly_login_test.dart` holds them to the file).
class WeeklyCalendarGeometry {
  const WeeklyCalendarGeometry._();

  /// The asset.
  static const asset = 'assets/animations/WeekLy.json';

  /// The file's canvas.
  static const Size canvas = Size(600, 250);

  /// The file's frame rate and length.
  static const double frameRate = 30;
  static const int frames = 90;

  /// The window of the canvas the popup shows: the calendar card (its rings
  /// from 63 down to its foot at 232, its sides at 195.6 and 404.4) and a
  /// hair of the ground round it, so the card is as large as the popup is.
  static const Rect window = Rect.fromLTRB(188, 58, 412, 236);

  /// The frame the animation is held at: every box in and at rest (the last
  /// lands at frame 59), before the first begins to leave (frame 73).
  static const int holdFrame = 66;

  /// A box's side, and its corner radius.
  static const double boxSide = 34.95;
  static const double boxRadius = 2.92;

  /// The seven boxes' centres, Day 1 to Day 7 in reading order: four across
  /// the top row, three across the bottom. Each is its layer's position
  /// carried through its group's, at the layer's resting scale.
  static const List<Offset> boxCentres = [
    Offset(237.127, 138.868),
    Offset(283.936, 138.868),
    Offset(330.746, 138.868),
    Offset(377.556, 138.868),
    Offset(253.810, 193.659),
    Offset(299.999, 191.657),
    Offset(348.786, 192.324),
  ];

  /// The layer each day's box is, in the same order.
  static const List<String> boxLayers = [
    '1/calendario contornos',
    '7/calendario contornos',
    'dia/calendario contornos',
    '5/calendario contornos',
    '2/calendario contornos',
    '3/calendario contornos',
    '3/calendario contornos 2',
  ];

  /// The frame each day's box begins to pop in, and the frame it is at rest.
  static const List<(int, int)> boxPops = [
    (0, 13),
    (6, 19),
    (12, 29),
    (22, 35),
    (46, 59),
    (40, 53),
    (34, 47),
  ];

  /// The frame the last box is at rest: the prizes follow it.
  static int get boxesIn =>
      boxPops.map((p) => p.$2).reduce((a, b) => a > b ? a : b);

  /// The file's white solid, hidden: the popup has a ground of its own.
  static const String solidLayer = 'Sólido Blanco 4';

  /// The file's sparkles, hidden: cut by the window they would be stray
  /// strokes at its edges.
  static const String sparklesLayer = 'estrellas';

  /// The file's ground behind the card — a light-grey skyline on the white
  /// solid — hidden: what the window keeps of it is a stray block at the
  /// card's sides.
  static const String groundLayer = 'fondo/calendario contornos';

  /// The card itself: its outline in seven stroked groups, six rings (a
  /// stroke each) over six holes (a white fill each), the header band and
  /// the body — every one restyled by name.
  static const String cardLayer = 'calendario/calendario contornos';
  static const List<String> outlineGroups = [
    'Grupo 1',
    'Grupo 2',
    'Grupo 3',
    'Grupo 4',
    'Grupo 5',
    'Grupo 6',
    'Grupo 7',
  ];
  static const List<String> ringGroups = [
    'Grupo 8',
    'Grupo 10',
    'Grupo 12',
    'Grupo 14',
    'Grupo 16',
    'Grupo 18',
  ];
  static const List<String> holeGroups = [
    'Grupo 9',
    'Grupo 11',
    'Grupo 13',
    'Grupo 15',
    'Grupo 17',
    'Grupo 19',
  ];
  static const String headerGroup = 'Grupo 20';
  static const String bodyGroup = 'Grupo 21';

  /// Day [day]'s box, in canvas units.
  static Rect boxOf(int day) => Rect.fromCenter(
    center: boxCentres[day - 1],
    width: boxSide,
    height: boxSide,
  );
}

/// Where a day stands on the calendar: collected in this run; today's, still
/// to collect; the next day, which the player can earn tomorrow; a day
/// beyond that; or the seventh, the week's own reward, while it is neither
/// collected nor today's.
enum WeeklyDayState { claimed, current, next, locked, finalDay }

/// Which state day [day] is in for the program [s] ([collected] the day just
/// collected, which the state may not say yet). Collected and collectable
/// are the server's word wherever it sends one (`rewards[].state`); a day is
/// drawn as today's to collect only while the server says a claim can be
/// made ([RewardProgramState.canClaimToday]).
WeeklyDayState weeklyDayStateOf(
  RewardProgramState s,
  int day, {
  int? collected,
}) {
  if (collected == day) return WeeklyDayState.claimed;
  final server = s.rewardFor(day)?.state;
  if (server == RewardDayState.claimed ||
      (server == null && day <= s.claimedDays)) {
    return WeeklyDayState.claimed;
  }
  if (server == RewardDayState.available ||
      (server == null && day == s.currentDay && s.canClaimToday)) {
    return WeeklyDayState.current;
  }
  if (day == 7) return WeeklyDayState.finalDay;
  if (s.isActive && day == s.currentDay + 1) return WeeklyDayState.next;
  return WeeklyDayState.locked;
}

/// The colours the calendar is drawn in, one set a theme: the card's glass
/// tones the file is restyled to, and each day state's box.
class WeeklyCardColours {
  const WeeklyCardColours({
    required this.body,
    required this.header,
    required this.outline,
    required this.ring,
    required this.upcoming,
    required this.lockedBox,
    required this.finalBox,
  });

  /// By night: charcoal glass, a step above the panel.
  static const dark = WeeklyCardColours(
    body: Color(0xFF1B1E24),
    header: Color(0xFF24282F),
    outline: Color(0xFF3B4048),
    ring: Color(0xFF6F7580),
    upcoming: Color(0xFF1F4653),
    lockedBox: Color(0xFF262A31),
    finalBox: Color(0xFF4A3A6E),
  );

  /// By day: warm off-white glass, never the file's flat white.
  static const light = WeeklyCardColours(
    body: Color(0xFFF7F3EB),
    header: Color(0xFFECE5D8),
    outline: Color(0xFFC9C1B2),
    ring: Color(0xFFA39B8C),
    upcoming: Color(0xFFCDE6EC),
    lockedBox: Color(0xFFE3DDD2),
    finalBox: Color(0xFFD9CCEF),
  );

  /// The theme's set — and inside a Blind or Variation level ([level]) the
  /// card's glass turned to the level's hue at its own lightness, as the
  /// drawers' pearl and charcoal are ([LevelColours.inHue]); the boxes'
  /// colours are the days' own and stay.
  static WeeklyCardColours of(Brightness b, [LevelColours? level]) {
    final house = b == Brightness.dark ? dark : light;
    if (level == null) return house;
    return WeeklyCardColours(
      body: level.inHue(house.body),
      header: level.inHue(house.header),
      outline: level.inHue(house.outline),
      ring: level.inHue(house.ring),
      upcoming: house.upcoming,
      lockedBox: house.lockedBox,
      finalBox: house.finalBox,
    );
  }

  final Color body;
  final Color header;
  final Color outline;
  final Color ring;
  final Color upcoming;
  final Color lockedBox;
  final Color finalBox;

  /// The box the file pops in for a day in [state]: the tone the card that
  /// lands on it is built on.
  Color boxOf(WeeklyDayState state) => switch (state) {
    WeeklyDayState.claimed || WeeklyDayState.current => AppTheme.gold,
    WeeklyDayState.next => upcoming,
    WeeklyDayState.locked => lockedBox,
    WeeklyDayState.finalDay => finalBox,
  };
}

/// The calendar with the seven prizes in its boxes, sized to [size] (the
/// window's aspect, 224:178), for the program [state] — a WEEKLY login
/// streak. [collected] marks the day the player has just collected, which
/// the state may not say yet.
class WeeklyCalendar extends StatefulWidget {
  const WeeklyCalendar({
    super.key,
    required this.state,
    required this.size,
    this.collected,
  });

  final RewardProgramState state;
  final Size size;
  final int? collected;

  /// How long the file's pop-ins take: from its first frame to [holdFrame].
  static Duration get boxesLength => Duration(
    milliseconds:
        (WeeklyCalendarGeometry.holdFrame *
                1000 /
                WeeklyCalendarGeometry.frameRate)
            .round(),
  );

  /// The prizes land one after another, this far apart, each taking
  /// [revealPop], once the boxes are in.
  static const Duration revealStagger = Duration(milliseconds: 110);
  static const Duration revealPop = Duration(milliseconds: 340);

  /// How long the prizes take, all seven.
  static Duration get revealLength => revealStagger * 6 + revealPop;

  /// The whole sequence: the boxes, then the prizes.
  static Duration get sequenceLength => boxesLength + revealLength;

  /// Today's card breathes its glow this slowly.
  static const Duration pulse = Duration(milliseconds: 1700);

  /// The size the window takes at [width].
  static Size sizeFor(double width) => Size(
    width,
    width *
        WeeklyCalendarGeometry.window.height /
        WeeklyCalendarGeometry.window.width,
  );

  /// The widest the calendar is drawn at [height].
  static double widthFor(double height) =>
      height *
      WeeklyCalendarGeometry.window.width /
      WeeklyCalendarGeometry.window.height;

  /// Where day [day]'s box lands inside a calendar of [size].
  static Rect boxRectIn(Size size, int day) {
    final scale = size.width / WeeklyCalendarGeometry.window.width;
    final box = WeeklyCalendarGeometry.boxOf(day);
    final window = WeeklyCalendarGeometry.window;
    return Rect.fromLTWH(
      (box.left - window.left) * scale,
      (box.top - window.top) * scale,
      box.width * scale,
      box.height * scale,
    );
  }

  /// The delegates the file is drawn with for [state] on a [brightness]:
  /// the white solid, the sparkles and the ground hidden; the card in the
  /// theme's glass tones — in the open level's hue where one stands
  /// ([level]) — its outline and rings thinner and softer; every box in its
  /// day's colour.
  static LottieDelegates delegates(
    Brightness brightness,
    RewardProgramState state, {
    int? collected,
    LevelColours? level,
  }) {
    final c = WeeklyCardColours.of(brightness, level);
    const card = WeeklyCalendarGeometry.cardLayer;
    return LottieDelegates(
      values: [
        for (final layer in const [
          WeeklyCalendarGeometry.solidLayer,
          WeeklyCalendarGeometry.sparklesLayer,
          WeeklyCalendarGeometry.groundLayer,
        ])
          ValueDelegate.transformOpacity([layer], value: 0),
        for (final group in WeeklyCalendarGeometry.outlineGroups) ...[
          ValueDelegate.strokeColor([card, group, '**'], value: c.outline),
          ValueDelegate.strokeWidth([card, group, '**'], value: 1.2),
        ],
        for (final group in WeeklyCalendarGeometry.ringGroups) ...[
          ValueDelegate.strokeColor([card, group, '**'], value: c.ring),
          ValueDelegate.strokeWidth([card, group, '**'], value: 2),
        ],
        for (final group in WeeklyCalendarGeometry.holeGroups)
          ValueDelegate.color([card, group, '**'], value: c.header),
        ValueDelegate.color([
          card,
          WeeklyCalendarGeometry.headerGroup,
          '**',
        ], value: c.header),
        ValueDelegate.color([
          card,
          WeeklyCalendarGeometry.bodyGroup,
          '**',
        ], value: c.body),
        for (var day = 1; day <= 7; day++)
          ValueDelegate.color(
            [WeeklyCalendarGeometry.boxLayers[day - 1], '**'],
            value: c.boxOf(weeklyDayStateOf(state, day, collected: collected)),
          ),
      ],
    );
  }

  @override
  State<WeeklyCalendar> createState() => _WeeklyCalendarState();
}

class _WeeklyCalendarState extends State<WeeklyCalendar>
    with TickerProviderStateMixin {
  /// The file's clock: 0 is its first frame, 1 its last. Run once from the
  /// start to [WeeklyCalendarGeometry.holdFrame] and left there.
  late final AnimationController _clock;

  /// The prizes' clock, run once after the boxes are in: 0 is none shown, 1
  /// every prize on its box.
  late final AnimationController _reveal;

  /// Today's glow, breathing.
  late final AnimationController _pulse;

  /// Built once per theme, level and standing: a new [LottieDelegates] never
  /// compares equal to the last, and would have every key path resolved
  /// again on each build.
  LottieDelegates? _delegates;
  (Brightness, Color?, int, int, bool, int?)? _delegatesFor;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds:
            (WeeklyCalendarGeometry.frames *
                    1000 /
                    WeeklyCalendarGeometry.frameRate)
                .round(),
      ),
    );
    _reveal = AnimationController(
      vsync: this,
      duration: WeeklyCalendar.revealLength,
    );
    _pulse = AnimationController(vsync: this, duration: WeeklyCalendar.pulse)
      ..repeat(reverse: true);
    // The boxes first, one by one, then the prizes.
    unawaited(
      _clock
          .animateTo(
            WeeklyCalendarGeometry.holdFrame / WeeklyCalendarGeometry.frames,
            duration: WeeklyCalendar.boxesLength,
            curve: Curves.linear,
          )
          .then((_) {
            if (mounted) _reveal.forward();
          }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshDelegates();
  }

  @override
  void didUpdateWidget(WeeklyCalendar old) {
    super.didUpdateWidget(old);
    _refreshDelegates();
  }

  void _refreshDelegates() {
    final s = widget.state;
    // The open level's colour, where the lobby has laid one over the popup.
    final level = LevelAccent.of(context);
    final key = (
      Theme.of(context).brightness,
      level?.fill,
      s.claimedDays,
      s.currentDay,
      s.claimedToday,
      widget.collected,
    );
    if (_delegatesFor == key) return;
    _delegatesFor = key;
    _delegates = WeeklyCalendar.delegates(
      key.$1,
      s,
      collected: widget.collected,
      level: level,
    );
  }

  @override
  void dispose() {
    _clock.dispose();
    _reveal.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final scale = size.width / WeeklyCalendarGeometry.window.width;
    final window = WeeklyCalendarGeometry.window;
    final canvas = WeeklyCalendarGeometry.canvas;
    final rects = [
      for (var day = 1; day <= 7; day++) WeeklyCalendar.boxRectIn(size, day),
    ];
    return SizedBox.fromSize(
      size: size,
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // The whole canvas, drawn past the box so the window fills it.
            Positioned(
              left: -window.left * scale,
              top: -window.top * scale,
              width: canvas.width * scale,
              height: canvas.height * scale,
              child: RepaintBoundary(
                child: Lottie.asset(
                  WeeklyCalendarGeometry.asset,
                  controller: _clock,
                  delegates: _delegates,
                  fit: BoxFit.fill,
                  frameRate: FrameRate.max,
                ),
              ),
            ),
            // The thread from day to day, under the cards: gold as far as
            // the run has come, faint beyond.
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _reveal,
                  builder: (context, _) => CustomPaint(
                    painter: _ProgressThread(
                      rects: rects,
                      state: widget.state,
                      collected: widget.collected,
                      shown: Curves.easeOut.transform(_reveal.value),
                      brightness: Theme.of(context).brightness,
                    ),
                  ),
                ),
              ),
            ),
            for (var day = 1; day <= 7; day++)
              _DayCard(
                day: day,
                rect: rects[day - 1],
                state: widget.state,
                collected: widget.collected == day,
                reveal: _reveal,
                pulse: _pulse,
              ),
          ],
        ),
      ),
    );
  }
}

/// The thread between the days of each row.
class _ProgressThread extends CustomPainter {
  const _ProgressThread({
    required this.rects,
    required this.state,
    required this.collected,
    required this.shown,
    required this.brightness,
  });

  final List<Rect> rects;
  final RewardProgramState state;
  final int? collected;
  final double shown;
  final Brightness brightness;

  @override
  void paint(Canvas canvas, Size size) {
    if (shown <= 0) return;
    final dark = brightness == Brightness.dark;
    final faint = (dark ? Colors.white : Colors.black).withValues(
      alpha: (dark ? 0.12 : 0.10) * shown,
    );
    final gold = AppTheme.gold.withValues(alpha: 0.7 * shown);
    final width = (rects.first.width * 0.045).clamp(1.5, 3.0);
    for (final (a, b) in const [(1, 2), (2, 3), (3, 4), (5, 6), (6, 7)]) {
      final from = rects[a - 1];
      final to = rects[b - 1];
      // Both days in the run: gold.
      final done =
          weeklyDayStateOf(state, b, collected: collected) ==
          WeeklyDayState.claimed;
      final paint = Paint()
        ..color = done ? gold : faint
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(from.right + width, from.center.dy),
        Offset(to.left - width, to.center.dy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ProgressThread old) =>
      old.shown != shown ||
      old.brightness != brightness ||
      old.collected != collected ||
      old.state != state ||
      old.rects != rects;
}

/// One day's card, laid over its box and landing on it in its turn once the
/// boxes are in: the day's number, the prize's mark and figure; struck gold
/// with a small success badge when collected, today's ringed in gold with a
/// breathing glow and a touch larger, the next day in cyan glass with its
/// prize in plain view, the days beyond in dark glass with a small lock, the
/// seventh gold over purple and named FINAL.
class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.day,
    required this.rect,
    required this.state,
    required this.collected,
    required this.reveal,
    required this.pulse,
  });

  final int day;
  final Rect rect;
  final RewardProgramState state;
  final bool collected;
  final Animation<double> reveal;
  final Animation<double> pulse;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final t = context.read<GameState>().t;
    final prize = state.rewardFor(day)?.prize;
    final standing = weeklyDayStateOf(
      state,
      day,
      collected: collected ? day : null,
    );
    // Its turn on the prizes' clock: in day order, with the boxes' own
    // overshoot.
    final total = WeeklyCalendar.revealLength.inMilliseconds;
    final start =
        WeeklyCalendar.revealStagger.inMilliseconds * (day - 1) / total;
    final end = start + WeeklyCalendar.revealPop.inMilliseconds / total;
    final pop = Interval(start, math.min(end, 1.0), curve: Motion.settle);

    final side = rect.width;
    final radius = (side * 0.16).clamp(6.0, 12.0);
    // Every size on the card a share of its side, the prize's figure the
    // largest (owner: "Make Text size bigger of reward money"): the day's
    // label small, the mark under it, the figure under that — a column that
    // fits the box at every screen here, and is set down whole where the
    // phone's text size would have it overflow.
    final labelSize = (side * 0.135).clamp(7.0, 11.0);
    final markSize = (side * 0.27).clamp(13.0, 22.0);
    final figureSize = (side * 0.235).clamp(11.0, 19.0);
    final words = [
      t.rewardDay(day),
      prize == null ? t.rewardNothing : rewardPrizeLabel(t, prize),
      switch (standing) {
        WeeklyDayState.claimed => t.rewardTileClaimed,
        WeeklyDayState.current => t.rewardToday,
        WeeklyDayState.next ||
        WeeklyDayState.locked ||
        WeeklyDayState.finalDay => t.rewardTileLocked,
      },
    ].join(', ');

    // The card's face: a gradient, a thin edge, the ladder's shadow where it
    // stands proud; the dark days flat.
    final cyan = theme.colorScheme.tertiary;
    final (
      List<Color> fill,
      Color edge,
      double edgeW,
      List<BoxShadow> shadow,
    ) = switch (standing) {
      WeeklyDayState.claimed => (
        const [Color(0xFFE6C264), Color(0xFFC49A1A), Color(0xFFA37A0C)],
        AppTheme.goldBright.withValues(alpha: 0.75),
        1.0,
        Depth.shadows(b, Elevation.raised),
      ),
      WeeklyDayState.current => (
        dark
            ? const [Color(0xFF34302A), Color(0xFF221F1A)]
            : const [Color(0xFFFFF6DE), Color(0xFFF3E4B8)],
        AppTheme.gold,
        (side * 0.045).clamp(1.5, 2.5),
        Depth.shadows(b, Elevation.raised),
      ),
      WeeklyDayState.next => (
        dark
            ? [cyan.withValues(alpha: 0.42), cyan.withValues(alpha: 0.2)]
            : [cyan.withValues(alpha: 0.28), cyan.withValues(alpha: 0.14)],
        cyan.withValues(alpha: dark ? 0.7 : 0.55),
        1.0,
        const <BoxShadow>[],
      ),
      WeeklyDayState.locked => (
        dark
            ? [
                Colors.white.withValues(alpha: 0.08),
                Colors.white.withValues(alpha: 0.03),
              ]
            : [
                Colors.black.withValues(alpha: 0.06),
                Colors.black.withValues(alpha: 0.03),
              ],
        (dark ? Colors.white : Colors.black).withValues(
          alpha: dark ? 0.12 : 0.10,
        ),
        1.0,
        const <BoxShadow>[],
      ),
      WeeklyDayState.finalDay => (
        dark
            ? const [Color(0xFF5B3FA0), Color(0xFF3E2C6E), Color(0xFF6B5A16)]
            : const [Color(0xFFE6DAF8), Color(0xFFD8C6F2), Color(0xFFF1E1A6)],
        AppTheme.gold.withValues(alpha: 0.8),
        1.2,
        Depth.shadows(b, Elevation.raised),
      ),
    };
    final onGold = standing == WeeklyDayState.claimed;
    final ink = onGold
        ? AppTheme.ink900
        : standing == WeeklyDayState.finalDay && !dark
        ? const Color(0xFF3A2A5E)
        : dark
        ? Colors.white
        : const Color(0xFF1D1B18);
    final muted = standing == WeeklyDayState.locked ? 0.55 : 1.0;
    final label =
        standing == WeeklyDayState.finalDay ||
            (day == 7 && standing != WeeklyDayState.claimed)
        ? t.weeklyFinal
        : t.rewardDay(day).toUpperCase();
    final labelInk = standing == WeeklyDayState.current
        ? AppTheme.goldInk(b)
        : day == 7 && standing != WeeklyDayState.claimed
        ? (dark ? AppTheme.goldBright : AppTheme.goldDeep)
        : ink.withValues(alpha: onGold ? 0.75 : 0.62);

    Widget face = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: fill,
        ),
        border: Border.all(color: edge, width: edgeW),
        boxShadow: shadow,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // A thin light along the top edge: the ladder's lift.
          Positioned(
            left: side * 0.12,
            right: side * 0.12,
            top: edgeW,
            height: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(
                  alpha: standing == WeeklyDayState.locked ? 0.06 : 0.28,
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                side * 0.07,
                side * 0.09,
                side * 0.07,
                side * 0.07,
              ),
              child: Opacity(
                opacity: muted,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        style: AppTheme.label(
                          theme.textTheme.labelSmall!,
                          colour: labelInk,
                          weight: FontWeight.w700,
                        ).copyWith(fontSize: labelSize, letterSpacing: 0.9),
                      ),
                      SizedBox(height: side * 0.03),
                      Icon(
                        prize == null
                            ? Icons.remove_rounded
                            : rewardPrizeIcon(prize),
                        size: markSize,
                        color: onGold
                            ? ink
                            : rewardPrizeInk(
                                prize ??
                                    const RewardPrize(kind: RewardKind.none),
                                b,
                              ),
                      ),
                      Text(
                        prize == null ? '' : rewardPrizeShort(prize),
                        key: ValueKey('weekly-figure-$day'),
                        maxLines: 1,
                        style: AppTheme.money(
                          theme.textTheme.labelSmall!,
                          colour: ink,
                          weight: FontWeight.w700,
                        ).copyWith(fontSize: figureSize, height: 1.15),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (standing == WeeklyDayState.claimed)
            Positioned(
              top: -side * 0.08,
              right: -side * 0.08,
              child: _SuccessBadge(size: (side * 0.26).clamp(12.0, 17.0)),
            ),
          if (standing == WeeklyDayState.locked)
            Positioned(
              top: -side * 0.05,
              right: -side * 0.05,
              child: Icon(
                Icons.lock_rounded,
                size: (side * 0.2).clamp(9.0, 13.0),
                color: ink.withValues(alpha: 0.45),
              ),
            ),
        ],
      ),
    );

    if (standing == WeeklyDayState.current) {
      // Today: a touch larger, and a gold glow breathing round it — a band
      // outside the card, never a shadow under a clear one.
      face = AnimatedBuilder(
        animation: pulse,
        builder: (context, child) {
          final glow = 0.18 + 0.2 * Curves.easeInOut.transform(pulse.value);
          return Transform.scale(
            scale: 1.04,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: -side * 0.12,
                  top: -side * 0.12,
                  right: -side * 0.12,
                  bottom: -side * 0.12,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(
                          radius + side * 0.1,
                        ),
                        border: Border.all(
                          color: AppTheme.gold.withValues(alpha: glow),
                          width: side * 0.12,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(child: child!),
              ],
            ),
          );
        },
        child: face,
      );
    } else if (standing == WeeklyDayState.finalDay) {
      // The seventh day: a still, soft gold light round it.
      face = Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -side * 0.1,
            top: -side * 0.1,
            right: -side * 0.1,
            bottom: -side * 0.1,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius + side * 0.08),
                  border: Border.all(
                    color: AppTheme.gold.withValues(alpha: 0.16),
                    width: side * 0.1,
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(child: face),
        ],
      );
    }

    return Positioned.fromRect(
      rect: rect,
      child: Semantics(
        key: ValueKey('weekly-box-$day'),
        label: words,
        child: ExcludeSemantics(
          child: AnimatedBuilder(
            animation: reveal,
            builder: (context, child) => Transform.scale(
              scale: pop.transform(reveal.value),
              alignment: Alignment.center,
              child: child,
            ),
            child: face,
          ),
        ),
      ),
    );
  }
}

/// The compact success badge on a collected day: a check in a small gold
/// disc, popping in when the day is collected under the player's eyes.
class _SuccessBadge extends StatelessWidget {
  const _SuccessBadge({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Motion.base,
    curve: Motion.settle,
    builder: (context, v, child) => Transform.scale(scale: v, child: child),
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppTheme.goldBright,
        shape: BoxShape.circle,
        border: Border.all(color: AppTheme.ink900.withValues(alpha: 0.35)),
      ),
      child: Icon(
        Icons.check_rounded,
        size: size * 0.72,
        color: AppTheme.ink900,
      ),
    ),
  );
}

/// The popup over the lobby: the calendar, as large as the screen allows,
/// on the left; on the right the program's name, the streak, what the mode
/// means, today's reward, the next one and the key that collects — then
/// what was collected, and Continue. Shown by the lobby while
/// [GameState.weeklyLoginOffer] stands.
class WeeklyLoginOverlay extends StatelessWidget {
  const WeeklyLoginOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final offer = context.select<GameState, RewardProgramState?>(
      (s) => s.weeklyLoginOffer,
    );
    final resuming = context.select<GameState, bool>((s) => s.resuming);
    if (offer == null || resuming) return const SizedBox.shrink();
    return Positioned.fill(
      key: const ValueKey('weekly-login-overlay'),
      child: _WeeklyLoginScrim(offer: offer),
    );
  }
}

class _WeeklyLoginScrim extends StatefulWidget {
  const _WeeklyLoginScrim({required this.offer});

  final RewardProgramState offer;

  /// The most of the panel's width the calendar takes: the words need the
  /// rest.
  static const double calendarShare = 0.6;

  /// The panel at its widest.
  static const double widest = 840;

  @override
  State<_WeeklyLoginScrim> createState() => _WeeklyLoginScrimState();
}

class _WeeklyLoginScrimState extends State<_WeeklyLoginScrim>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in;

  /// What the claim gave, once it has: the popup then shows it and offers
  /// Continue. Null until then; an empty list is a claim that gave nothing
  /// (the day was collected elsewhere meanwhile).
  List<RewardGrant>? _granted;
  bool _claiming = false;
  String? _note;

  @override
  void initState() {
    super.initState();
    _in = AnimationController(vsync: this, duration: Motion.enter)..forward();
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  Future<void> _collect() async {
    if (_claiming) return;
    setState(() {
      _claiming = true;
      _note = null;
    });
    final state = context.read<GameState>();
    final granted = await state.claimRewardPrograms(celebrate: false);
    if (!mounted) return;
    setState(() {
      _claiming = false;
      if (granted == null) {
        _note = state.t.rewardLoadFailed;
      } else {
        _granted = granted;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final dark = b == Brightness.dark;
    final state = context.read<GameState>();
    final t = state.t;
    // The open level's colour where the lobby has laid one over the popup
    // (Blind, Variation); the house gold elsewhere.
    final level = LevelAccent.of(context);
    final accent = level?.fill ?? AppTheme.gold;
    // The programs as they stand now — the claim's answer replaces them —
    // so the calendar shows the day collected the moment it is.
    final program = context.select<GameState, RewardProgramState?>(
      (s) => s.rewardPrograms?.cast<RewardProgramState?>().firstWhere(
        (p) => p!.program.code == widget.offer.program.code,
        orElse: () => null,
      ),
    );
    final shown = program ?? widget.offer;
    final granted = _granted;
    final claimedNow = granted != null;
    final mine = granted
        ?.where((g) => g.programCode == shown.program.code)
        .toList();
    final others = granted
        ?.where((g) => g.programCode != shown.program.code)
        .toList();
    final collectedDay = claimedNow && (mine?.isNotEmpty ?? false)
        ? mine!.first.day
        : null;
    final todayPrize = shown.rewardFor(shown.currentDay)?.prize;
    // Tomorrow's, for the anticipation; none past the week.
    final nextDay = shown.currentDay + 1;
    final nextPrize = nextDay <= shown.periodDays
        ? shown.rewardFor(nextDay)?.prize
        : null;
    final gold = AppTheme.goldInk(b);
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkLowOn(b),
    );
    final size = MediaQuery.sizeOf(context);
    final short = Breaks.isShort(size.height);
    final done = claimedNow || shown.claimedToday;
    final headingStyle = AppTheme.label(
      text.labelSmall!,
      colour: quiet,
      weight: FontWeight.w600,
    ).copyWith(letterSpacing: 1.2);

    // The words. Each line gives way (fewer lines) before the column could
    // overflow the calendar's height.
    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text(
              t
                  .rewardProgramName(shown.program.code, shown.program.name)
                  .toUpperCase(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.label(
                (short ? text.titleSmall : text.titleMedium)!,
                weight: FontWeight.w600,
              ).copyWith(letterSpacing: 1.1),
            ),
          ),
        ),
        const SizedBox(width: Space.xs),
        KeyedSubtree(
          key: const ValueKey('weekly-login-close'),
          child: LevelCloseKey(
            tooltip: t.close,
            onTap: state.dismissWeeklyLogin,
          ),
        ),
      ],
    );
    final streak = Row(
      children: [
        Icon(Icons.local_fire_department_rounded, size: 20, color: gold),
        const SizedBox(width: Space.xs),
        // Set down to its column rather than cut: "START YOUR STREAK TODAY"
        // is wider than a 640dp phone's column, and it is the line a new
        // player meets first.
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              (shown.claimedDays > 0
                      ? t.streakDays(shown.claimedDays)
                      : t.streakStart)
                  .toUpperCase(),
              key: const ValueKey('weekly-login-headline'),
              maxLines: 1,
              style: AppTheme.money(
                (short ? text.titleMedium : text.titleLarge)!,
                colour: gold,
              ).copyWith(letterSpacing: 0.6),
            ),
          ),
        ),
      ],
    );
    final hint = Text(
      rewardProgramHint(t, shown.program),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: text.bodySmall?.copyWith(color: quiet),
    );

    // Today's reward: the strongest thing on the right. Before the tap,
    // what it is; after, what was given, with a check.
    final Widget hero;
    if (!done) {
      hero = _RewardLine(
        keyed: const ValueKey('weekly-login-today'),
        prize: todayPrize,
        text: todayPrize == null
            ? t.rewardNothing
            : rewardPrizeLabel(t, todayPrize).toUpperCase(),
        note: _note,
        large: true,
      );
    } else {
      final lines = <String>[
        if (mine != null && mine.isNotEmpty)
          mine.map((g) => '+ ${_line(t, g)}'.toUpperCase()).join(' · ')
        else
          t.rewardsCollected.toUpperCase(),
        if (others != null && others.isNotEmpty)
          t.rewardsAlso(others.map((g) => _line(t, g)).join(' · ')),
      ];
      hero = _RewardLine(
        keyed: const ValueKey('weekly-login-collected'),
        prize: mine != null && mine.isNotEmpty ? mine.first.prize : todayPrize,
        text: lines.join('\n'),
        collected: true,
        large: true,
      );
    }
    final next = nextPrize == null || nextPrize.isNothing
        ? null
        : _RewardLine(
            keyed: const ValueKey('weekly-login-next'),
            prize: nextPrize,
            text: rewardPrizeLabel(t, nextPrize).toUpperCase(),
          );
    // Collect only while the server says today can be collected: a cycle
    // that broke, or ended, meanwhile is put away with Continue instead.
    final key = done || !shown.canClaimToday
        ? LuckyGoldKey(
            key: const ValueKey('weekly-login-done'),
            label: t.continueKey,
            onTap: state.dismissWeeklyLogin,
            expand: true,
          )
        : LuckyGoldKey(
            key: const ValueKey('weekly-login-collect'),
            label: t.rewardsCollect,
            onTap: _claiming ? () {} : _collect,
            glyph: _claiming ? const GameLoaderRing(size: 16) : null,
            expand: true,
          );

    return GestureDetector(
      key: const ValueKey('weekly-login-scrim'),
      behavior: HitTestBehavior.opaque,
      onTap: state.dismissWeeklyLogin,
      child: ColoredBox(
        color: theme.colorScheme.scrim.withValues(alpha: dark ? 0.66 : 0.5),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (claimedNow && (mine?.isNotEmpty ?? false))
              Fireworks(seed: mine!.first.claimedAt, bursts: 6),
            SafeArea(
              child: Center(
                child: LayoutBuilder(
                  builder: (context, box) {
                    // The calendar takes the panel's whole height, and no
                    // more than its share of the width; the words the rest.
                    final panelW = (box.maxWidth - 2 * Space.md).clamp(
                      280.0,
                      _WeeklyLoginScrim.widest,
                    );
                    final padH = short ? Space.md : Space.lg;
                    final padV = short ? Space.sm : Space.md;
                    final innerW = panelW - 2 * padH;
                    final innerH = box.maxHeight - 2 * Space.md - 2 * padV;
                    // A narrow panel (a 592dp phone) gives the words a
                    // little more of the width.
                    final share = innerW >= 600
                        ? _WeeklyLoginScrim.calendarShare
                        : _WeeklyLoginScrim.calendarShare - 0.05;
                    final calW = math.min(
                      WeeklyCalendar.widthFor(innerH),
                      innerW * share - Space.md,
                    );
                    final calSize = WeeklyCalendar.sizeFor(calW);
                    return GestureDetector(
                      // A tap on the panel is the panel's, not the scrim's.
                      onTap: () {},
                      child: AnimatedBuilder(
                        animation: _in,
                        builder: (context, child) {
                          final e = Motion.standard.transform(_in.value);
                          return Opacity(
                            opacity: e,
                            child: Transform.translate(
                              offset: Offset(0, 16 * (1 - e)),
                              child: child,
                            ),
                          );
                        },
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            // A soft gold light behind the panel — the
                            // lobby's ambient glow, not a shadow.
                            Positioned(
                              left: -28,
                              right: -28,
                              top: -20,
                              bottom: -36,
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                      Radii.xl + 24,
                                    ),
                                    gradient: RadialGradient(
                                      radius: 0.85,
                                      colors: [
                                        accent.withValues(
                                          alpha: dark ? 0.11 : 0.14,
                                        ),
                                        accent.withValues(alpha: 0),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: panelW,
                              child: DecoratedBox(
                                key: const ValueKey('weekly-login-base'),
                                decoration: BoxDecoration(
                                  // By day a solid ground under the card's
                                  // glass: the house white, or the level's
                                  // pearl — Blind's ice, Variation's
                                  // lavender.
                                  color: dark
                                      ? null
                                      : level?.pearl ?? AppTheme.panelBase(b),
                                  borderRadius: BorderRadius.circular(Radii.xl),
                                ),
                                child: PremiumGlassPanel(
                                  mode: GlassMode.auto,
                                  priority: 30,
                                  depth: Elevation.overlay,
                                  radius: Radii.xl,
                                  surface: dark
                                      ? GlassSurface.pane
                                      : GlassSurface.card,
                                  // Washed in the level's colour where one
                                  // stands; by day in the house gold
                                  // otherwise, by night the plain pane.
                                  tint: dark ? level?.fill : accent,
                                  edge: accent.withValues(
                                    alpha: dark ? 0.3 : 0.42,
                                  ),
                                  padding: EdgeInsets.fromLTRB(
                                    padH,
                                    padV,
                                    padH,
                                    padV,
                                  ),
                                  // As tall as the calendar, or as the
                                  // words need, up to the screen: the
                                  // calendar stands centred in a taller
                                  // panel, and only past the screen's
                                  // height do the words give way.
                                  child: ConstrainedBox(
                                    key: const ValueKey('weekly-login-panel'),
                                    constraints: BoxConstraints(
                                      minHeight: calSize.height,
                                      maxHeight: math.max(
                                        calSize.height,
                                        innerH,
                                      ),
                                    ),
                                    child: IntrinsicHeight(
                                      child: Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Center(
                                            child: WeeklyCalendar(
                                              key: const ValueKey(
                                                'weekly-calendar',
                                              ),
                                              state: shown,
                                              size: calSize,
                                              collected: collectedDay,
                                            ),
                                          ),
                                          const SizedBox(width: Space.lg),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                head,
                                                const SizedBox(
                                                  height: Space.xs,
                                                ),
                                                streak,
                                                const SizedBox(
                                                  height: Space.xs,
                                                ),
                                                // The one line that gives way, and only past the screen's height:
                                                // weighted so the intrinsic height counts it near whole.
                                                Flexible(flex: 9, child: hint),
                                                const Spacer(),
                                                Text(
                                                  t.todaysRewardTitle
                                                      .toUpperCase(),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: headingStyle,
                                                ),
                                                const SizedBox(
                                                  height: Space.xs,
                                                ),
                                                hero,
                                                if (next != null) ...[
                                                  const SizedBox(
                                                    height: Space.sm,
                                                  ),
                                                  Text(
                                                    t.rewardNext.toUpperCase(),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: headingStyle,
                                                  ),
                                                  const SizedBox(
                                                    height: Space.xxs,
                                                  ),
                                                  next,
                                                ],
                                                const SizedBox(
                                                  height: Space.sm,
                                                ),
                                                key,
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "20,000 chips" for a wallet, an item by its name, "(already yours)"
  /// after an item the player had.
  static String _line(Strings t, RewardGrant g) {
    final label = rewardPrizeLabel(t, g.prize);
    return g.alreadyOwned ? '$label (${t.rewardAlreadyOwned})' : label;
  }
}

/// A reward named on the right panel: its mark in its wallet's ink beside
/// its words — large and gold for today's (with a check once collected), a
/// line for the next.
class _RewardLine extends StatelessWidget {
  const _RewardLine({
    required this.keyed,
    required this.prize,
    required this.text,
    this.note,
    this.collected = false,
    this.large = false,
  });

  final Key keyed;
  final RewardPrize? prize;
  final String text;

  /// After a claim that could not be made: what went wrong, in the reward's
  /// place, so the panel keeps its height.
  final String? note;
  final bool collected;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final text = theme.textTheme;
    final gold = AppTheme.goldInk(b);
    final ink = prize == null
        ? theme.colorScheme.onSurface
        : rewardPrizeInk(prize!, b);
    if (note != null) {
      return Text(
        note!,
        key: const ValueKey('weekly-login-note'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: text.bodySmall?.copyWith(color: theme.colorScheme.error),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: large ? 3 : 1),
          child: collected
              ? Icon(
                  Icons.check_circle_rounded,
                  size: large ? 20 : 16,
                  color: gold,
                )
              : Icon(
                  prize == null
                      ? Icons.card_giftcard_rounded
                      : rewardPrizeIcon(prize!),
                  size: large ? 22 : 16,
                  color: ink,
                ),
        ),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Text(
            this.text,
            key: keyed,
            maxLines: large ? 3 : 1,
            overflow: TextOverflow.ellipsis,
            style: large
                ? AppTheme.money(
                    text.titleMedium!,
                    colour: gold,
                  ).copyWith(letterSpacing: 0.4)
                : AppTheme.label(
                    text.bodySmall!,
                    colour: theme.colorScheme.onSurface,
                    weight: FontWeight.w600,
                  ).copyWith(letterSpacing: 0.6),
          ),
        ),
      ],
    );
  }
}
