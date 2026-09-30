import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../screens/reward_programs_screen.dart'
    show rewardPrizeIcon, rewardPrizeLabel, rewardPrizeShort;
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/depth.dart';
import '../widgets/fireworks.dart';
import '../widgets/game_loader.dart';
import '../widgets/glass_components.dart';
import '../widgets/premium_surface.dart';

// The weekly login popup (owner, 30 Sep 2026: "Use this animation which
// shows up everyday in case of weekly login and put the prize in blue boxes,
// it should pop after login and if user has claimed it should not show when
// user start the app, otherwise show it").
//
// The owner's `assets/animations/WeekLy.json` is a desk calendar: a
// light-grey card with six binder rings, and seven blue boxes — four on the
// top row, three on the bottom — that pop in one after another over the
// first 1.5 s (each from nothing to 110% and down to size), hold, and pop out
// again by the end (the file is a 3 s loop), with five sparkles fading in and
// out round it. 600 x 250 units, 30 fps, 90 frames; no 3D, no expressions,
// no images (the §12.3 traps), so the phones play exactly what the preview
// shows. It has no text and no numbers: the seven boxes are the seven days
// of the WEEKLY login streak, Day 1 to Day 7 in reading order, and the
// prize of each day is DRAWN OVER ITS BOX by Flutter — its mark and its
// figure — from the geometry the file lays the boxes out by
// ([WeeklyCalendarGeometry]), so the prize and the box cannot drift apart.
//
// It plays ONCE, to the frame where every box is in and still
// ([WeeklyCalendarGeometry.holdFrame]), and holds there: the file's pop-out
// would take the prizes' boxes away every three seconds. Each prize pops in
// with its own box, on the box's own frame. The file's white solid (the whole
// canvas) is hidden — the popup lays the card on its own glass — and its one
// darker box (the third, the designer's "today") is drawn the same blue as
// the other six, since today is whichever box the server says; today's box
// wears a gold ring and its prize gold, a collected day a green tick, a day
// not reached its box faded.

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

  /// The window of the canvas the popup shows: the calendar card, the
  /// light-grey ground behind it and the two inner sparkles, centred on the
  /// card; the outer sparkles, at the corners of the canvas, are let go so
  /// the boxes are half again as large on a phone.
  static const Rect window = Rect.fromLTRB(80, 55, 520, 236);

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

  /// The file's white solid, hidden: the popup has a ground of its own.
  static const String solidLayer = 'Sólido Blanco 4';

  /// The file's ground behind the card — a light-grey skyline on the white
  /// solid — which on the dark theme is drawn in a charcoal a step lighter
  /// than the panel, so it stays the faint shape it was meant to be.
  static const String groundLayer = 'fondo/calendario contornos';
  static const Color groundDark = Color(0xFF23262B);

  /// The blue every box is drawn in (the file's own, on six of them).
  static const Color boxBlue = Color(0xFF2786F5);

  /// Day [day]'s box, in canvas units.
  static Rect boxOf(int day) => Rect.fromCenter(
    center: boxCentres[day - 1],
    width: boxSide,
    height: boxSide,
  );

  /// The moment day [day]'s box begins to pop, as a fraction of the file.
  static double popStartOf(int day) => boxPops[day - 1].$1 / frames;

  /// How long day [day]'s pop takes.
  static Duration popLengthOf(int day) {
    final (start, rest) = boxPops[day - 1];
    return Duration(milliseconds: ((rest - start) * 1000 / frameRate).round());
  }
}

/// The calendar with the seven prizes in its boxes, sized to [size] (the
/// window's aspect, 510:181), for the program [state] — a WEEKLY login
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

  /// The delegates the file is drawn with: the white solid hidden, every box
  /// the same blue (the file's third box is darker, the designer's "today"),
  /// and by night the ground behind the card in charcoal.
  static LottieDelegates delegates(Brightness brightness) => LottieDelegates(
    values: [
      ValueDelegate.transformOpacity(const [
        WeeklyCalendarGeometry.solidLayer,
      ], value: 0),
      for (final layer in WeeklyCalendarGeometry.boxLayers)
        ValueDelegate.color([
          layer,
          '**',
        ], value: WeeklyCalendarGeometry.boxBlue),
      if (brightness == Brightness.dark)
        ValueDelegate.color(const [
          WeeklyCalendarGeometry.groundLayer,
          '**',
        ], value: WeeklyCalendarGeometry.groundDark),
    ],
  );

  @override
  State<WeeklyCalendar> createState() => _WeeklyCalendarState();
}

class _WeeklyCalendarState extends State<WeeklyCalendar>
    with SingleTickerProviderStateMixin {
  /// The file's clock: 0 is its first frame, 1 its last. Run once from the
  /// start to [WeeklyCalendarGeometry.holdFrame] and left there.
  late final AnimationController _clock;

  /// Built once per theme: a new [LottieDelegates] never compares equal to
  /// the last, and would have every key path resolved again on each build.
  LottieDelegates? _delegates;
  Brightness? _delegatesFor;

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
    unawaited(
      _clock.animateTo(
        WeeklyCalendarGeometry.holdFrame / WeeklyCalendarGeometry.frames,
        duration: Duration(
          milliseconds:
              (WeeklyCalendarGeometry.holdFrame *
                      1000 /
                      WeeklyCalendarGeometry.frameRate)
                  .round(),
        ),
        curve: Curves.linear,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_delegatesFor != brightness) {
      _delegatesFor = brightness;
      _delegates = WeeklyCalendar.delegates(brightness);
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final scale = size.width / WeeklyCalendarGeometry.window.width;
    final window = WeeklyCalendarGeometry.window;
    final canvas = WeeklyCalendarGeometry.canvas;
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
            for (var day = 1; day <= 7; day++)
              _PrizeInBox(
                day: day,
                rect: WeeklyCalendar.boxRectIn(size, day),
                state: widget.state,
                collected: widget.collected == day,
                clock: _clock,
              ),
          ],
        ),
      ),
    );
  }
}

/// Where a day stands: collected (this run), today's — still to collect —,
/// or not reached.
enum _BoxState { collected, today, locked }

/// One day's prize laid over its box, popping in with the box: the day's
/// number above the box, the prize's mark and figure inside it, a tick when
/// collected, a gold ring for today, faded when not reached.
class _PrizeInBox extends StatelessWidget {
  const _PrizeInBox({
    required this.day,
    required this.rect,
    required this.state,
    required this.collected,
    required this.clock,
  });

  final int day;
  final Rect rect;
  final RewardProgramState state;
  final bool collected;
  final Animation<double> clock;

  _BoxState get standing {
    if (collected || day <= state.claimedDays) return _BoxState.collected;
    if (day == state.currentDay && !state.claimedToday) return _BoxState.today;
    return _BoxState.locked;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final t = context.read<GameState>().t;
    final prize = state.rewardFor(day)?.prize;
    final standing = this.standing;
    final gold = AppTheme.goldInk(b);
    // The prize pops with its box: from the box's first frame to the frame
    // it rests, with the box's own overshoot.
    final popStart = WeeklyCalendarGeometry.popStartOf(day);
    final popEnd =
        popStart +
        WeeklyCalendarGeometry.popLengthOf(day).inMilliseconds /
            (WeeklyCalendarGeometry.frames *
                1000 /
                WeeklyCalendarGeometry.frameRate);
    final pop = Interval(
      popStart,
      popEnd.clamp(popStart + 0.01, 1.0),
      curve: Motion.settle,
    );
    // The day's number stands above the box, in the row between the rings
    // (or the row above) and the box; the tick and the lock in the box's
    // top-right corner. The prize is white on the blue.
    final labelH = rect.height * 0.38;
    final side = rect.width;
    const ink = Colors.white;
    final figure = prize == null ? '' : rewardPrizeShort(prize);
    final words = [
      t.rewardDay(day),
      prize == null ? t.rewardNothing : rewardPrizeLabel(t, prize),
      switch (standing) {
        _BoxState.collected => t.rewardTileClaimed,
        _BoxState.today => t.rewardToday,
        _BoxState.locked => t.rewardTileLocked,
      },
    ].join(', ');

    return Positioned(
      left: rect.left,
      top: rect.top - labelH,
      width: side,
      height: rect.height + labelH,
      child: Semantics(
        key: ValueKey('weekly-box-$day'),
        label: words,
        child: ExcludeSemantics(
          child: AnimatedBuilder(
            animation: clock,
            builder: (context, child) => Transform.scale(
              scale: pop.transform(clock.value),
              alignment: Alignment.bottomCenter,
              child: child,
            ),
            child: Opacity(
              opacity: standing == _BoxState.locked ? 0.62 : 1,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    height: labelH,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        t.rewardDay(day),
                        maxLines: 1,
                        style: AppTheme.label(
                          theme.textTheme.labelSmall!,
                          colour: standing == _BoxState.today
                              ? gold
                              : const Color(0xFF484848),
                          weight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: side,
                    height: rect.height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Today's ring on the box's edge, and a soft gold
                        // band round the outside of it — a band, not a
                        // shadow: a shadow under a clear box tints the blue.
                        if (standing == _BoxState.today) ...[
                          Positioned(
                            left: -side * 0.14,
                            top: -side * 0.14,
                            right: -side * 0.14,
                            bottom: -side * 0.14,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                    side * 0.22,
                                  ),
                                  border: Border.all(
                                    color: AppTheme.gold.withValues(
                                      alpha: 0.32,
                                    ),
                                    width: side * 0.14,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  WeeklyCalendarGeometry.boxRadius *
                                      side /
                                      WeeklyCalendarGeometry.boxSide *
                                      1.6,
                                ),
                                border: Border.all(
                                  color: AppTheme.gold,
                                  width: (side * 0.06).clamp(1.5, 3),
                                ),
                              ),
                            ),
                          ),
                        ],
                        Positioned.fill(
                          child: Padding(
                            padding: EdgeInsets.all(side * 0.08),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    prize == null
                                        ? Icons.remove_rounded
                                        : rewardPrizeIcon(prize),
                                    size: 16,
                                    color: ink,
                                  ),
                                  if (figure.isNotEmpty)
                                    Text(
                                      figure,
                                      maxLines: 1,
                                      style: AppTheme.money(
                                        theme.textTheme.labelSmall!,
                                        colour: ink,
                                      ).copyWith(fontSize: 9.5),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        if (standing == _BoxState.collected)
                          Positioned(
                            top: -side * 0.14,
                            right: -side * 0.14,
                            child: Container(
                              width: side * 0.4,
                              height: side * 0.4,
                              decoration: BoxDecoration(
                                color: const Color(0xFF2E7D32),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 1.2,
                                ),
                              ),
                              child: Icon(
                                Icons.check_rounded,
                                size: side * 0.28,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        if (standing == _BoxState.locked)
                          Positioned(
                            top: side * 0.04,
                            right: side * 0.04,
                            child: Icon(
                              Icons.lock_rounded,
                              size: side * 0.2,
                              color: Colors.white.withValues(alpha: 0.85),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The popup over the lobby: the calendar and its prizes, today's reward
/// named, and the key that collects it — then what was collected, and
/// Close. Shown by the lobby while [GameState.weeklyLoginOffer] stands.
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

  @override
  State<_WeeklyLoginScrim> createState() => _WeeklyLoginScrimState();
}

class _WeeklyLoginScrimState extends State<_WeeklyLoginScrim>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in;

  /// What the claim gave, once it has: the popup then shows it and offers
  /// Close. Null until then; an empty list is a claim that gave nothing
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
    final todayPrize = shown.rewardFor(shown.currentDay)?.prize;
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkLowOn(b),
    );
    final size = MediaQuery.sizeOf(context);
    final short = Breaks.isShort(size.height);
    final done = claimedNow || shown.claimedToday;

    final header = Row(
      children: [
        Icon(
          Icons.calendar_month_rounded,
          size: 22,
          color: AppTheme.goldInk(b),
        ),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Text(
            t.rewardProgramName(shown.program.code, shown.program.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.label(
              (short ? text.titleSmall : text.titleMedium)!,
              weight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: Space.sm),
        Text(
          shown.claimedDays > 0
              ? t.streakDays(shown.claimedDays)
              : t.streakStart,
          key: const ValueKey('weekly-login-headline'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.money(text.titleSmall!, colour: AppTheme.goldInk(b)),
        ),
        const SizedBox(width: Space.xs),
        IconButton(
          key: const ValueKey('weekly-login-close'),
          tooltip: t.close,
          onPressed: state.dismissWeeklyLogin,
          icon: const Icon(Icons.close_rounded, size: 20),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            minimumSize: const Size.square(Dim.minTouch),
          ),
        ),
      ],
    );

    // The foot: today's prize and Collect; once collected, what was given
    // and Close.
    final Widget foot;
    if (!done) {
      foot = Row(
        children: [
          // Today's prize — or, after a claim that could not be made, what
          // went wrong, in the same line so the panel keeps its height.
          Expanded(
            child: _note != null
                ? Text(
                    _note!,
                    key: const ValueKey('weekly-login-note'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  )
                : Text(
                    todayPrize == null
                        ? t.rewardStreakHint
                        : t.todaysReward(rewardPrizeLabel(t, todayPrize)),
                    key: const ValueKey('weekly-login-today'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(color: quiet),
                  ),
          ),
          const SizedBox(width: Space.md),
          GlassButton(
            key: const ValueKey('weekly-login-collect'),
            style: GlassButtonStyle.primary,
            click: true,
            onPressed: _claiming ? null : _collect,
            child: _claiming
                ? const GameLoaderRing(size: 18)
                : Text(t.rewardsCollect),
          ),
        ],
      );
    } else {
      final lines = <String>[
        if (mine != null && mine.isNotEmpty)
          mine.map((g) => _line(t, g)).join(' · ')
        else
          t.rewardsCollected,
        if (others != null && others.isNotEmpty)
          t.rewardsAlso(others.map((g) => _line(t, g)).join(' · ')),
      ];
      foot = Row(
        children: [
          Icon(
            Icons.check_circle_rounded,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              lines.join('\n'),
              key: const ValueKey('weekly-login-collected'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.money(
                text.bodySmall!,
                colour: AppTheme.goldInk(b),
              ),
            ),
          ),
          const SizedBox(width: Space.md),
          GlassButton(
            key: const ValueKey('weekly-login-done'),
            style: GlassButtonStyle.primary,
            click: true,
            onPressed: state.dismissWeeklyLogin,
            label: t.tapToClose,
          ),
        ],
      );
    }

    return GestureDetector(
      key: const ValueKey('weekly-login-scrim'),
      behavior: HitTestBehavior.opaque,
      onTap: state.dismissWeeklyLogin,
      child: ColoredBox(
        color: theme.colorScheme.scrim.withValues(alpha: 0.70),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (claimedNow && (mine?.isNotEmpty ?? false))
              Fireworks(seed: mine!.first.claimedAt, bursts: 6),
            SafeArea(
              child: Center(
                child: LayoutBuilder(
                  builder: (context, box) {
                    // The calendar takes the width left after the panel's
                    // sides, held to the height left after the header and
                    // the foot.
                    final panelW = (box.maxWidth - 2 * Space.md).clamp(
                      280.0,
                      620.0,
                    );
                    final padH = short ? Space.md : Space.lg;
                    final padV = short ? Space.sm : Space.md;
                    final headerH =
                        (short ? 30.0 : 34.0) *
                        MediaQuery.textScalerOf(context).scale(1);
                    final footH =
                        (short ? 42.0 : 46.0) *
                        MediaQuery.textScalerOf(context).scale(1);
                    final roomH =
                        box.maxHeight -
                        2 * Space.md -
                        2 * padV -
                        headerH -
                        footH -
                        2 * Space.sm;
                    var calW = panelW - 2 * padH;
                    if (WeeklyCalendar.sizeFor(calW).height > roomH) {
                      calW = WeeklyCalendar.widthFor(roomH).clamp(200.0, calW);
                    }
                    final calSize = WeeklyCalendar.sizeFor(calW);
                    return GestureDetector(
                      // A tap on the panel is the panel's, not the scrim's.
                      onTap: () {},
                      child: AnimatedBuilder(
                        animation: _in,
                        builder: (context, child) {
                          final e = Motion.settle.transform(_in.value);
                          return Opacity(
                            opacity: Curves.easeOut.transform(_in.value),
                            child: Transform.scale(
                              scale: 0.86 + 0.14 * e,
                              child: child,
                            ),
                          );
                        },
                        child: SizedBox(
                          width: panelW,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: dark ? null : AppTheme.panelBase(b),
                              borderRadius: BorderRadius.circular(Radii.lg),
                            ),
                            child: PremiumGlassPanel(
                              mode: GlassMode.auto,
                              priority: 30,
                              depth: Elevation.overlay,
                              radius: Radii.lg,
                              surface: dark
                                  ? GlassSurface.pane
                                  : GlassSurface.card,
                              tint: dark ? null : AppTheme.gold,
                              edge: AppTheme.gold.withValues(
                                alpha: dark ? 0.42 : 0.6,
                              ),
                              padding: EdgeInsets.fromLTRB(
                                padH,
                                padV,
                                padH,
                                padV,
                              ),
                              child: Column(
                                key: const ValueKey('weekly-login-panel'),
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  header,
                                  const SizedBox(height: Space.sm),
                                  Center(
                                    child: WeeklyCalendar(
                                      key: const ValueKey('weekly-calendar'),
                                      state: shown,
                                      size: calSize,
                                      collected:
                                          claimedNow &&
                                              (mine?.isNotEmpty ?? false)
                                          ? mine!.first.day
                                          : null,
                                    ),
                                  ),
                                  const SizedBox(height: Space.sm),
                                  foot,
                                ],
                              ),
                            ),
                          ),
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

  /// "+ 20,000 chips" for a wallet, an item by its name, "(already yours)"
  /// after an item the player had.
  static String _line(Strings t, RewardGrant g) {
    final label = rewardPrizeLabel(t, g.prize);
    final line = g.prize.isWallet ? '+ $label' : label;
    return g.alreadyOwned ? '$line (${t.rewardAlreadyOwned})' : line;
  }
}
