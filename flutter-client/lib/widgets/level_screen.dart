import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import '../theme/theme_colors.dart';
import 'chip_store.dart';
import 'edge_fade.dart';
import 'glass_components.dart';
import 'premium_surface.dart';
import 'table_chrome.dart';
import 'table_tax.dart';

// The level screen (owner, 27 Sep 2026: the lobby's level key's popup,
// polished — "UI/UX only"): the same three tabs the key opened before — My
// level, Daily XP, All levels — with a hero for the level and the winning tax
// it sets, an XP bar that fills once, the badges as cards with their Lotties,
// the daily XP as a play-time track and a grid of winning hands, and the whole
// ladder with the viewer's rung lit and scrolled to. Everything on it is the
// server's: the level, XP and rate from the account, the ladder, the badges
// and the daily sources from `GET /api/levels`, what today's window has
// earned from its claims. Nothing here decides a level, a rate or an award.
//
// The table's tax pill opens the same content in two panes
// ([showWinningTaxInfo], table_tax.dart), which stays as the owner restored it
// ("only change was in Lobby").

/// How long the tabs' underline takes to slide to the tab tapped, and the
/// content to change under it.
const Duration levelTabSlide = Duration(milliseconds: 220);

/// A badge grant running out within this long is flagged "Expires in …".
const Duration badgeExpiresSoon = Duration(hours: 24);

/// The level screen's panel never stands taller than this, on a tablet.
const double levelScreenMaxHeight = 620;

/// The screen's quiet ink: [AppTheme.inkLowOn]'s alpha by day, a step
/// firmer by night — the screen's small print stands on its sunk wells, a
/// shade lighter than the drawers' glass the table's quiet tier was measured
/// on, where 0.46 of white fell under 4.5:1.
Color levelQuietInk(ThemeData theme) => theme.colorScheme.onSurface.withValues(
  alpha: theme.brightness == Brightness.dark
      ? 0.58
      : AppTheme.inkLowOn(theme.brightness),
);

/// [TableType.metadata] in [levelQuietInk] unless told otherwise.
TextStyle levelQuiet(ThemeData theme, {Color? colour, bool figures = false}) =>
    TableType.metadata(
      theme,
      colour: colour ?? levelQuietInk(theme),
      figures: figures,
    );

/// One day's claims as the screen reads them: what each source has been
/// earned in the running window, none where the window has run out.
class DailyClaims {
  DailyClaims(this.ladder, this.level, DateTime now)
    : _daily = level?.daily,
      running = level?.daily?.leftAt(now) != null;

  final LevelLadder ladder;
  final PlayerLevel? level;
  final XpDaily? _daily;

  /// Whether a 24-hour window is running: it opens at the player's first
  /// completed hand, and until it does nothing has been earned.
  final bool running;

  int claimsOf(LadderSource source) =>
      running ? math.min(_daily!.claimsOf(source.code), source.times) : 0;

  bool earned(LadderSource source) => claimsOf(source) >= source.times;

  /// The XP the window has earned: the server's own figure where it keeps a
  /// cap, else each source's XP as many times as it has been earned.
  int get xp {
    final today = level?.today;
    if (today != null) return today.xp;
    var sum = 0;
    for (final s in ladder.sources) {
      sum += claimsOf(s) * s.xp;
    }
    return sum;
  }

  /// The most one window can earn.
  int get max => level?.today?.cap ?? ladder.dailyMax;

  /// Every source earned as many times as it can be: nothing more today.
  bool get complete =>
      running && ladder.sources.isNotEmpty && ladder.sources.every(earned);
}

/// The lowest rate a badge of the catalogue brings its holder's down to —
/// what the Royal badges offer (0% as seeded) — or null until the catalogue
/// is read, or where no badge but the default sets one.
int? royalRateOf(LevelLadder? ladder) {
  int? least;
  for (final b in ladder?.badges ?? const <LadderBadge>[]) {
    final rate = b.taxBps;
    if (b.isDefault || rate == null) continue;
    if (least == null || rate < least) least = rate;
  }
  return least;
}

/// Where a held badge's grant stands at a moment.
enum GrantState { lifetime, running, soon, expired }

/// A held badge's grant and the words for it, at [now].
(GrantState, String) grantOf(Strings t, PlayerBadge badge, DateTime now) {
  if (badge.expiresAt <= 0) return (GrantState.lifetime, t.badgeLifetime);
  final left = badge.leftAt(now);
  if (left == null) return (GrantState.expired, t.badgeExpired);
  if (left < badgeExpiresSoon) {
    // Hours and minutes, as a phone's clock says it ("2h 14m"): near its end
    // the grant is counted closely.
    final h = left.inHours;
    final m = math.max(h == 0 ? 1 : 0, left.inMinutes % 60);
    final time = h > 0
        ? '$h${t.unitHourShort} $m${t.unitMinuteShort}'
        : '$m${t.unitMinuteShort}';
    return (GrantState.soon, t.badgeExpiresIn(time));
  }
  // Further off, days and hours ("29d 14h left", brief §21) — however long
  // the grant: a Royal King of Kings bought today reads "89d 23h left", never
  // an end date. (The table's popup and the store keep [badgeLeftOf].)
  return (
    GrantState.running,
    t.timeLeft(
      '${left.inDays}${t.unitDayShort} '
      '${left.inHours % 24}${t.unitHourShort}',
    ),
  );
}

/// The rate the viewer pays and the badge that sets it (null: their level),
/// at [now]. While every badge the account was read with is still running
/// that is the server's figure ([User.paysTaxBps], [User.rateBadge]). Once one
/// runs out while the screen is open — the server has stopped counting it,
/// but the account on the phone has not been read again yet — it is the same
/// rule over the badges still running: the lowest of the level's rate and
/// theirs, the badge named only where it is below the level's. The screen
/// asks for the account again at that moment ([LevelScreen]); this only keeps
/// the hero from contradicting the card that says Expired meanwhile.
(int?, PlayerBadge?) standingAt(User? user, int? seatBps, DateTime now) {
  if (user == null) return (seatBps, null);
  bool lapsed(PlayerBadge b) => b.expiresAt > 0 && b.leftAt(now) == null;
  if (!user.badges.any(lapsed)) {
    return (seatBps ?? user.paysTaxBps, user.rateBadge);
  }
  final level = user.playerLevel?.taxBps;
  PlayerBadge? best;
  for (final b in user.badges) {
    final rate = b.taxBps;
    if (rate == null || lapsed(b)) continue;
    if (best == null || rate < best.taxBps!) best = b;
  }
  if (best != null && (level == null || best.taxBps! < level)) {
    return (best.taxBps, best);
  }
  return (level ?? best?.taxBps, null);
}

/// The level screen: the lobby's level key's popup.
class LevelScreen extends StatefulWidget {
  const LevelScreen({super.key, this.initialTab = LevelInfoTab.mine});

  final LevelInfoTab initialTab;

  /// From this content width the title, the tabs and the close key stand on
  /// one line; under it the tabs take a line of their own.
  static const double oneLineFrom = 560;

  @override
  State<LevelScreen> createState() => _LevelScreenState();
}

class _LevelScreenState extends State<LevelScreen> {
  late LevelInfoTab _tab = widget.initialTab;

  /// +1 when the tab tapped is to the right of the last, -1 to the left: the
  /// way the content slides.
  int _dir = 1;

  /// The viewer's own rung and the badges' heading on the All levels tab.
  /// Fresh keys each time the tab is entered, so the ladder leaving and the
  /// ladder arriving never share one mid-slide.
  GlobalKey _you = GlobalKey();
  GlobalKey _badges = GlobalKey();
  bool _placed = false;

  /// Whether the ladder has been scrolled past the badges' own heading: the
  /// column heads over it then name the badges, and the key over them leads
  /// back up to the levels. A notifier, so a scroll rebuilds the heads alone.
  final ValueNotifier<bool> _inBadges = ValueNotifier(false);

  @override
  void dispose() {
    _inBadges.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Read afresh once the screen is up, so an owner's edit shows the next
    // time it is looked at — after the frame, so the read's notice does not
    // ask for a rebuild in the middle of this one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<GameState>().loadLevelLadder();
    });
  }

  void _select(LevelInfoTab tab) {
    if (tab == _tab) return;
    setState(() {
      _dir = tab.index > _tab.index ? 1 : -1;
      _tab = tab;
      if (tab == LevelInfoTab.ladder) {
        _you = GlobalKey();
        _badges = GlobalKey();
        _placed = false;
        _inBadges.value = false;
      }
    });
  }

  /// Brings the viewer's rung into view the first time the ladder is built.
  void _placeYou() {
    if (_placed || !mounted) return;
    final row = _you.currentContext;
    if (row == null) return;
    _placed = true;
    Scrollable.ensureVisible(row, alignment: 0.35);
  }

  /// Where the badges' heading has scrolled up out of the ladder's view —
  /// the scroll offset at which the first badge stands at the top — or null
  /// before the heading is laid out.
  double? _badgesTop() {
    final head = _badges.currentContext?.findRenderObject();
    if (head is! RenderBox || !head.attached || !head.hasSize) return null;
    final viewport = RenderAbstractViewport.maybeOf(head);
    if (viewport == null) return null;
    return viewport.getOffsetToReveal(head, 0).offset + head.size.height;
  }

  bool _onLadderScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    final top = _badgesTop();
    if (top != null) _inBadges.value = n.metrics.pixels >= top - 1;
    return false;
  }

  /// Down to the badges: the first of them at the top, their heading passed
  /// under the column heads, which then name them.
  void _jumpToBadges() {
    final context = _badges.currentContext;
    final top = _badgesTop();
    if (context == null || top == null) return;
    final position = Scrollable.of(context).position;
    position.animateTo(
      math.min(top, position.maxScrollExtent),
      duration: Motion.slow,
      curve: Curves.easeOutCubic,
    );
  }

  /// Back up to the levels: the viewer's own rung, where they have one.
  void _jumpToLevels() {
    final row = _you.currentContext;
    if (row != null) {
      Scrollable.ensureVisible(
        row,
        alignment: 0.35,
        duration: Motion.slow,
        curve: Curves.easeOutCubic,
      );
      return;
    }
    final head = _badges.currentContext;
    if (head == null) return;
    Scrollable.of(
      head,
    ).position.animateTo(0, duration: Motion.slow, curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    context.select<GameState, Object>(levelViewOf);
    final state = context.read<GameState>();
    final t = state.t;
    final size = MediaQuery.sizeOf(context);
    final width = math.min(size.width - 2 * Space.lg, WinningTaxInfo.maxWidth);
    final height = math.min(Dim.dialogMaxH(size.height), levelScreenMaxHeight);
    final theme = Theme.of(context);

    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.military_tech_rounded,
          size: 20,
          color: goldInk(theme.brightness),
        ),
        const SizedBox(width: Space.sm),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              t.yourLevelTitle,
              key: const ValueKey('level-screen-title'),
              maxLines: 1,
              style: TableType.modalTitle(theme),
            ),
          ),
        ),
      ],
    );
    final tabs = LevelTabs(
      value: _tab,
      labels: {
        LevelInfoTab.mine: t.levelTabMine,
        LevelInfoTab.daily: t.xpDailyTitle,
        LevelInfoTab.ladder: t.allLevelsTitle,
      },
      onChanged: _select,
    );
    final close = LevelCloseKey(
      tooltip: t.close,
      onTap: () => Navigator.pop(context),
    );

    if (_tab == LevelInfoTab.ladder) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _placeYou());
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(Space.lg),
      child: SizedBox(
        width: width,
        height: height,
        child: PremiumGlassPanel(
          mode: GlassMode.auto,
          priority: 20,
          radius: Radii.lg,
          padding: const EdgeInsets.fromLTRB(
            Space.lg,
            Space.xs,
            Space.sm,
            Space.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, box) {
                  if (box.maxWidth >= LevelScreen.oneLineFrom) {
                    return Row(
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: box.maxWidth * 0.28,
                          ),
                          child: title,
                        ),
                        const SizedBox(width: Space.lg),
                        Expanded(child: tabs),
                        const SizedBox(width: Space.sm),
                        close,
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: title,
                            ),
                          ),
                          close,
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: Space.xs),
                        child: tabs,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: Space.sm),
              Expanded(
                child: AnimatedSwitcher(
                  duration: levelTabSlide,
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [...previous, ?current],
                  ),
                  transitionBuilder: (child, animation) {
                    final incoming = child.key == _paneKey(_tab);
                    final from = Offset(0.035 * _dir * (incoming ? 1 : -1), 0);
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(
                        position: Tween(
                          begin: from,
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      ),
                    );
                  },
                  child: _LevelPane(
                    key: _paneKey(_tab),
                    onScroll: _tab == LevelInfoTab.ladder
                        ? _onLadderScroll
                        : null,
                    fixed:
                        _tab == LevelInfoTab.ladder && state.levelLadder != null
                        ? ValueListenableBuilder<bool>(
                            valueListenable: _inBadges,
                            builder: (context, inBadges, _) => _LadderHead(
                              inBadges: inBadges,
                              onJump: inBadges ? _jumpToLevels : _jumpToBadges,
                            ),
                          )
                        : null,
                    children: switch (_tab) {
                      LevelInfoTab.mine => _mine(context, state),
                      LevelInfoTab.daily => _daily(context, state),
                      LevelInfoTab.ladder => _ladder(context, state),
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static ValueKey<String> _paneKey(LevelInfoTab tab) => ValueKey(switch (tab) {
    LevelInfoTab.mine => 'winning-tax-standing',
    LevelInfoTab.daily => 'winning-tax-daily',
    LevelInfoTab.ladder => 'winning-tax-ladder',
  });

  // ---------------------------------------------------------------- My level

  List<Widget> _mine(BuildContext context, GameState state) {
    final t = state.t;
    final user = state.user;
    final level = user?.playerLevel;
    final seatBps = state.myTaxBps;
    final rateBadge = user?.rateBadge;
    final floor = taxFloorOf(state);
    final badges = user?.badges ?? const <PlayerBadge>[];
    final onlyRegular = badges.every((b) => b.isDefault);
    // The hint names the lowest rate a badge of the catalogue sets (0% as
    // seeded) — never a figure of its own — and waits for the catalogue.
    final royal = royalRateOf(state.levelLadder);
    final pays = seatBps ?? user?.paysTaxBps;
    final hint = onlyRegular && royal != null && (pays == null || royal < pays);

    return [
      if (level != null)
        // The rate follows the clock: a badge that runs out while the screen
        // is open stops setting it the moment its card says Expired.
        LevelClock<(int?, PlayerBadge?)>(
          key: const ValueKey('level-hero-clock'),
          read: (now) {
            _askAgain(state, user, now);
            return standingAt(user, seatBps, now);
          },
          builder: (context, standing) => LevelHero(
            level: level,
            rate: standing.$1,
            setBy: switch (standing.$2) {
              final badge? => t.rateSetByBadge(badgeTitleOf(badge)),
              null => t.rateSetByLevel,
            },
          ),
        ),
      if (level != null) ...[
        const SizedBox(height: Space.sm),
        LevelXpCard(level: level, ladder: state.levelLadder),
      ],
      if (badges.isNotEmpty) ...[
        LevelSection(t.yourBadgesTitle),
        LevelGrid(
          minTile: 230,
          children: [
            for (final badge in badges)
              HeldBadgeCard(
                key: ValueKey('my-badge-${badge.code}'),
                badge: badge,
                setsRate: rateBadge?.code == badge.code,
              ),
          ],
        ),
      ],
      if (hint) ...[
        const SizedBox(height: Space.sm),
        RoyalBadgeHint(rate: royal),
      ],
      LevelSection(t.levelHowTax),
      LevelCard(
        key: const ValueKey('level-tax-notes'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Fact(Icons.emoji_events_outlined, t.taxNoteWinner),
            _Fact(Icons.calculate_outlined, t.taxNoteNet),
            if (floor > 0)
              _Fact(
                Icons.savings_outlined,
                t.winningTaxFrom(formatChips(floor)),
                key: const ValueKey('winning-tax-from'),
              ),
            _Fact(Icons.trending_down_rounded, t.winningTaxFalls),
            _Fact(Icons.workspace_premium_outlined, t.taxNoteBadge),
            _Fact(Icons.low_priority_rounded, t.winningTaxLowest),
          ],
        ),
      ),
    ];
  }

  /// Account re-reads asked for, one per grant: a badge that runs out while
  /// the screen is open has the account read again, so the server's own
  /// figure replaces what the phone worked out for the moment.
  final Set<String> _asked = {};

  void _askAgain(GameState state, User? user, DateTime now) {
    if (user == null) return;
    final lapsed = [
      for (final b in user.badges)
        if (b.expiresAt > 0 && b.leftAt(now) == null)
          '${b.code}@${b.expiresAt}',
    ];
    if (lapsed.isEmpty || _asked.containsAll(lapsed)) return;
    _asked.addAll(lapsed);
    // After the frame: the read can arrive while the screen is building.
    Future.microtask(state.refreshUser);
  }

  // ---------------------------------------------------------------- Daily XP

  List<Widget> _daily(BuildContext context, GameState state) {
    final ladder = state.levelLadder;
    if (ladder == null) return _unread(context, state);
    final level = state.user?.playerLevel;
    // Whether the window is still running follows the clock: one that ends
    // while the tab is open clears its ticks and its XP and says the day
    // starts with the next hand, as the server now counts it.
    return [
      LevelClock<bool>(
        key: const ValueKey('daily-window'),
        read: (now) => level?.daily?.leftAt(now) != null,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _dailyBody(
            context,
            state,
            ladder,
            DailyClaims(ladder, level, DateTime.now()),
          ),
        ),
      ),
    ];
  }

  List<Widget> _dailyBody(
    BuildContext context,
    GameState state,
    LevelLadder ladder,
    DailyClaims claims,
  ) {
    final t = state.t;
    final theme = Theme.of(context);
    final level = claims.level;
    final play = [
      for (final s in ladder.sources)
        if (s.kind == LadderSource.kindPlayTime && s.playMinutes != null) s,
    ]..sort((a, b) => a.playMinutes!.compareTo(b.playMinutes!));
    final hands = [
      for (final s in ladder.sources)
        if (s.kind == LadderSource.kindWinHand && !play.contains(s)) s,
    ];
    // A kind this build has no heading of its own for is still listed, under
    // a plain one — never filed as a winning hand it is not.
    final others = [
      for (final s in ladder.sources)
        if (!play.contains(s) && !hands.contains(s)) s,
    ];
    final hours = math.max(1, (ladder.windowMs / 3600000).round());
    Widget tiles(List<LadderSource> sources) => LevelGrid(
      minTile: 180,
      children: [
        for (final s in sources)
          HandSourceTile(
            key: ValueKey('xp-source-${s.code}'),
            source: s,
            name: xpSourceName(t, s),
            claims: claims.claimsOf(s),
          ),
      ],
    );

    return [
      DailySummary(
        claims: claims,
        resetsAt: claims.running ? level!.daily!.resetsAt : 0,
      ),
      if (play.isNotEmpty) ...[
        LevelSection(t.xpPlayTimeTitle, mark: play.first.icon),
        PlayTrack(sources: play, claims: claims),
        _Note(t.xpPlayTimeNote),
      ],
      if (hands.isNotEmpty) ...[
        LevelSection(t.xpWinHandsTitle, mark: '🏆'),
        tiles(hands),
        const SizedBox(height: Space.xs),
        _Note(t.xpWinHandsNote),
      ],
      if (others.isNotEmpty) ...[LevelSection(t.xpOtherTitle), tiles(others)],
      const SizedBox(height: Space.sm),
      Text(t.xpListResets(hours), style: levelQuiet(theme)),
      if (ladder.dailyCap > 0)
        Text(t.xpDailyCap(ladder.dailyCap, hours), style: levelQuiet(theme)),
      Text(t.xpNeverExpires, style: levelQuiet(theme)),
    ];
  }

  // -------------------------------------------------------------- All levels

  List<Widget> _ladder(BuildContext context, GameState state) {
    final t = state.t;
    final ladder = state.levelLadder;
    if (ladder == null) return _unread(context, state);
    final theme = Theme.of(context);
    final user = state.user;
    final mine = user?.playerLevel?.level;
    final held = {
      for (final b in user?.badges ?? const <PlayerBadge>[]) b.code: b,
    };
    return [
      for (final level in ladder.levels)
        LevelRow(
          key: level.level == mine ? _you : ValueKey('ladder-${level.level}'),
          level: level,
          mine: mine,
        ),
      if (ladder.badges.isNotEmpty) ...[
        // No column name of its own: the heads over the ladder say Tax.
        LevelSection(t.badgesTitle, key: _badges),
        for (final badge in ladder.badges)
          CatalogueBadgeRow(
            key: ValueKey('ladder-badge-${badge.code}'),
            badge: badge,
            held: badge.isDefault ? null : held[badge.code],
          ),
        const SizedBox(height: Space.xs),
        Text(t.badgesBesideLevel, style: levelQuiet(theme)),
      ],
    ];
  }

  /// A tab whose content is the ladder's, before it has been read: a
  /// spinner, or — where it cannot be read — a line and Try again.
  List<Widget> _unread(BuildContext context, GameState state) {
    final theme = Theme.of(context);
    final t = state.t;
    return [
      const SizedBox(height: Space.xl),
      if (state.levelLadderFailed && !state.levelLadderLoading) ...[
        Text(
          t.levelsUnavailable,
          textAlign: TextAlign.center,
          style: levelQuiet(theme),
        ),
        const SizedBox(height: Space.sm),
        Center(
          child: TextButton(
            key: const ValueKey('winning-tax-retry'),
            onPressed: state.loadLevelLadder,
            child: Text(t.luckyRetry),
          ),
        ),
      ] else
        const Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
    ];
  }
}

// ------------------------------------------------------------------- the tabs

/// The level screen's three tabs: a glyph and a word each, the one showing
/// in gold and the others quiet, over one hairline, with a gold underline
/// that slides to the tab tapped ([levelTabSlide], easing out, no bounce).
/// Each tab is a full [Dim.minTouch] target; a word runs smaller rather than
/// being cut where a language runs long.
class LevelTabs extends StatelessWidget {
  const LevelTabs({
    super.key,
    required this.value,
    required this.labels,
    required this.onChanged,
  });

  final LevelInfoTab value;
  final Map<LevelInfoTab, String> labels;
  final ValueChanged<LevelInfoTab> onChanged;

  static const Map<LevelInfoTab, IconData> icons = {
    LevelInfoTab.mine: Icons.military_tech_rounded,
    LevelInfoTab.daily: Icons.bolt_rounded,
    LevelInfoTab.ladder: Icons.format_list_numbered_rounded,
  };

  /// The underline's thickness.
  static const double line = 2.5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final gold = goldInk(theme.brightness);
    final quiet = levelQuietInk(theme);
    const tabs = LevelInfoTab.values;
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth / tabs.length;
        final inset = math.min(Space.lg, w * 0.14);
        return SizedBox(
          height: Dim.minTouch,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: Dim.hairline,
                child: ColoredBox(
                  color: scheme.onSurface.withValues(alpha: 0.10),
                ),
              ),
              AnimatedPositioned(
                key: const ValueKey('level-tab-indicator'),
                duration: levelTabSlide,
                curve: Curves.easeOutCubic,
                left: value.index * w + inset,
                width: w - 2 * inset,
                bottom: 0,
                height: line,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: gold,
                    borderRadius: BorderRadius.circular(line),
                    boxShadow: [
                      BoxShadow(
                        color: gold.withValues(alpha: 0.45),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
              ),
              Row(
                children: [
                  for (final tab in tabs)
                    Expanded(
                      child: _Tab(
                        key: ValueKey('level-tab-${tab.name}'),
                        icon: icons[tab]!,
                        label: labels[tab] ?? '',
                        selected: tab == value,
                        colour: tab == value ? gold : quiet,
                        onTap: () {
                          if (tab == value) return;
                          tapHaptic(context);
                          onChanged(tab);
                        },
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.colour,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color colour;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      // The node keeps the tab's tap: excluding the InkWell's semantics
      // would otherwise leave a screen reader a tab it cannot press.
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: colour),
          duration: levelTabSlide,
          curve: Curves.easeOut,
          builder: (context, ink, _) => Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.xs,
              0,
              Space.xs,
              LevelTabs.line,
            ),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 16, color: ink),
                    const SizedBox(width: Space.xs),
                    Text(
                      label,
                      maxLines: 1,
                      style: TableType.label(
                        theme,
                        colour: ink,
                        weight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ the pane

/// One tab's content in a scroll of its own, faded at an edge while there is
/// more beyond it; [fixed] stands over the scroll (the ladder's column
/// heads).
class _LevelPane extends StatelessWidget {
  const _LevelPane({
    super.key,
    required this.children,
    this.fixed,
    this.onScroll,
  });

  final List<Widget> children;
  final Widget? fixed;

  /// Told of the scroll's every move (the ladder's heads follow it).
  final bool Function(ScrollNotification)? onScroll;

  @override
  Widget build(BuildContext context) {
    Widget scroll = EdgeFade(
      child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.only(right: Space.sm, bottom: Space.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
    if (onScroll case final onScroll?) {
      scroll = NotificationListener<ScrollNotification>(
        onNotification: onScroll,
        child: scroll,
      );
    }
    final head = fixed;
    if (head == null) return scroll;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: Space.sm),
          child: head,
        ),
        Expanded(child: scroll),
      ],
    );
  }
}

/// A block of the screen: the theme's sunk well, a hairline edge — gold
/// where [accent] says — and rounded corners.
class LevelCard extends StatelessWidget {
  const LevelCard({
    super.key,
    required this.child,
    this.accent,
    this.accentStrength = 1,
    this.padding = const EdgeInsets.all(Space.md),
  });

  final Widget child;
  final Color? accent;

  /// How much of [accent] the card wears: 1 for one lit (held, the rate's
  /// setter), less for a faint edge (a Royal badge of the catalogue).
  final double accentStrength;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final glass = GlassColors.of(context);
    final a = accent;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: a == null
            ? glass.wellFill
            : Color.alphaBlend(
                a.withValues(alpha: 0.08 * accentStrength),
                glass.wellFill,
              ),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: a == null
              ? glass.cardBorder
              : a.withValues(alpha: 0.55 * accentStrength),
        ),
      ),
      child: child,
    );
  }
}

/// A section's heading: its mark, its name in gold, and — for the ladder's
/// badges — the rate column's name at the right.
class LevelSection extends StatelessWidget {
  const LevelSection(this.text, {super.key, this.mark = '', this.column});

  final String text;
  final String mark;
  final String? column;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = TableType.label(
      theme,
      colour: goldInk(theme.brightness),
      weight: FontWeight.w700,
    );
    return Padding(
      padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
      child: Row(
        children: [
          if (mark.isNotEmpty) ...[
            Text(mark, strutStyle: levelStrut(style), style: style),
            const SizedBox(width: Space.xs),
          ],
          Expanded(child: Text(text, maxLines: 2, style: style)),
          if (column case final column?) Text(column, style: levelQuiet(theme)),
        ],
      ),
    );
  }
}

/// A quiet line of the screen.
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.xs, bottom: Space.xxs),
    child: Text(text, style: levelQuiet(Theme.of(context))),
  );
}

/// One line of "How winning tax works": a quiet glyph and the sentence.
class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.text, {super.key});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: goldInk(theme.brightness)),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              text,
              style: TableType.info(
                theme,
                colour: theme.colorScheme.onSurface.withValues(
                  alpha: AppTheme.inkMed,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cards laid out in as many equal columns as fit at [minTile] wide — one on
/// a narrow pane, two or three on a wide one — rows [Space.sm] apart.
class LevelGrid extends StatelessWidget {
  const LevelGrid({super.key, required this.minTile, required this.children});

  final double minTile;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final columns = math.max(
        1,
        math.min(3, ((box.maxWidth + Space.sm) / (minTile + Space.sm)).floor()),
      );
      final w = (box.maxWidth - Space.sm * (columns - 1)) / columns;
      return Wrap(
        spacing: Space.sm,
        runSpacing: Space.sm,
        children: [
          for (final child in children) SizedBox(width: w, child: child),
        ],
      );
    },
  );
}

/// A line with something at each end: [lead] takes what [trail] leaves, and
/// [trail] — never wider than [trailShare] of the line — stands at its right
/// end, however short it is.
class LevelSplit extends StatelessWidget {
  const LevelSplit({
    super.key,
    required this.lead,
    required this.trail,
    this.trailShare = 0.5,
  });

  final Widget lead;
  final Widget trail;
  final double trailShare;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Row(
      children: [
        Expanded(child: lead),
        const SizedBox(width: Space.md),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: box.maxWidth * trailShare),
          child: trail,
        ),
      ],
    ),
  );
}

/// A small capsule of words: a tag on a card or a rung.
class LevelTag extends StatelessWidget {
  const LevelTag(
    this.text, {
    super.key,
    required this.colour,
    this.solid = false,
  });

  final String text;
  final Color colour;

  /// Struck gold with dark words, where the tag is the one thing on its card
  /// to see first ([colour] then only for the outlined kind).
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 1),
      // Solid is struck gold in both themes, the medal's number chip's face:
      // the light theme's deep gold under charcoal words measured 3.96:1,
      // where [AppTheme.goldFace]'s darkest stop holds 6.3:1.
      decoration: solid
          ? BoxDecoration(
              gradient: AppTheme.goldFace,
              borderRadius: BorderRadius.circular(Radii.pill),
              border: Border.all(
                color: AppTheme.goldDeep.withValues(alpha: 0.5),
              ),
            )
          : BoxDecoration(
              color: colour.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(Radii.pill),
              border: Border.all(color: colour.withValues(alpha: 0.55)),
            ),
      child: Text(
        text,
        maxLines: 1,
        style: TableType.label(
          theme,
          colour: solid ? AppTheme.ink900 : colour,
          weight: FontWeight.w700,
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- the hero

/// The level's medal: its mark in a struck-gold ring, its number on a gold
/// chip at the foot.
class LevelEmblem extends StatelessWidget {
  const LevelEmblem({super.key, required this.level, this.size = 60});

  final PlayerLevel level;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    return SizedBox(
      width: size,
      height: size + 8,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.topCenter,
        children: [
          Container(
            width: size,
            height: size,
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: AppTheme.goldFace,
              boxShadow: [
                BoxShadow(
                  color: AppTheme.gold.withValues(alpha: dark ? 0.30 : 0.18),
                  blurRadius: 14,
                ),
              ],
            ),
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dark ? AppTheme.ink900 : glass.cardFill,
              ),
              child: level.icon.isEmpty
                  ? Icon(
                      Icons.military_tech_rounded,
                      size: size * 0.5,
                      color: goldInk(theme.brightness),
                    )
                  // Half the medal tall, and wide enough for a mark of two
                  // emoji ("👑⚔️") to stand at nearly that height rather than
                  // be squeezed to half of it.
                  : SizedBox(
                      width: size * 0.78,
                      height: size * 0.5,
                      child: FittedBox(
                        child: Text(
                          level.icon,
                          style: const TextStyle(height: 1),
                        ),
                      ),
                    ),
            ),
          ),
          Positioned(
            bottom: 0,
            child: Container(
              key: const ValueKey('level-emblem-number'),
              padding: const EdgeInsets.symmetric(horizontal: Space.sm),
              decoration: BoxDecoration(
                gradient: AppTheme.goldFace,
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Text(
                '${level.level}',
                style: AppTheme.money(
                  theme.textTheme.labelMedium!,
                  colour: AppTheme.ink900,
                  weight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The top of My level: the medal, "Level 10" over the level's title — or
/// MAX LEVEL at the top of the ladder — and, at the right, the Winning Tax the
/// viewer pays and what sets it. Under [narrow] the tax stands under the
/// level instead of beside it.
class LevelHero extends StatelessWidget {
  const LevelHero({
    super.key,
    required this.level,
    required this.rate,
    required this.setBy,
  });

  final PlayerLevel level;

  /// The rate the viewer pays, in basis points; null where it is not known.
  final int? rate;

  /// What sets it: their level, or one of their badges.
  final String setBy;

  static const double narrow = 420;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final gold = goldInk(theme.brightness);
    final taxInk = TableInk.taxOn(theme.brightness);
    // A long title (an owner's "Supreme Overlord" and longer) a step
    // smaller, so it keeps to the hero rather than pushing the XP down.
    final titleStyle =
        (level.title.characters.length > 18
                ? theme.textTheme.titleMedium!
                : theme.textTheme.titleLarge!)
            .copyWith(fontWeight: FontWeight.w700, height: 1.2);
    final top = level.next == null;

    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          t.levelNumber(level.level),
          key: const ValueKey('level-hero-number'),
          maxLines: 1,
          style: TableType.label(theme, colour: gold, weight: FontWeight.w700),
        ),
        Text(
          level.title.isEmpty ? t.levelNumber(level.level) : level.title,
          key: const ValueKey('level-hero-title'),
          maxLines: 3,
          style: titleStyle,
        ),
        if (top) ...[
          const SizedBox(height: Space.xs),
          LevelTag(
            t.levelMax,
            key: const ValueKey('level-max'),
            colour: gold,
            solid: true,
          ),
        ],
      ],
    );

    final bps = rate;
    final tax = bps == null
        ? null
        : Semantics(
            label: '${t.winningTaxTitle} ${formatTaxRate(bps)}, $setBy',
            excludeSemantics: true,
            child: Column(
              key: const ValueKey('winning-tax-rate'),
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(winningTaxIcon, size: 14, color: taxInk),
                    const SizedBox(width: Space.xs),
                    Flexible(
                      child: Text(
                        t.winningTaxTitle,
                        maxLines: 2,
                        textAlign: TextAlign.end,
                        style: TableType.label(theme, colour: taxInk),
                      ),
                    ),
                  ],
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    formatTaxRate(bps),
                    maxLines: 1,
                    style: AppTheme.money(
                      theme.textTheme.headlineSmall!,
                      colour: taxInk,
                      weight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  setBy,
                  maxLines: 2,
                  textAlign: TextAlign.end,
                  style: levelQuiet(theme),
                ),
              ],
            ),
          );

    return Semantics(
      container: true,
      label: levelNameOf(t, level),
      child: LevelCard(
        key: const ValueKey('level-hero'),
        accent: gold,
        padding: const EdgeInsets.fromLTRB(
          Space.md,
          Space.md,
          Space.lg,
          Space.md,
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final head = Row(
              children: [
                LevelEmblem(level: level),
                const SizedBox(width: Space.md),
                Expanded(child: name),
              ],
            );
            if (tax == null) return head;
            if (box.maxWidth < narrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  head,
                  const SizedBox(height: Space.sm),
                  Align(alignment: Alignment.centerRight, child: tax),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: head),
                const SizedBox(width: Space.md),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: box.maxWidth * 0.4),
                  child: tax,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ the XP

/// A gold bar filling to [fraction] — once, as it first appears, and again
/// only when the figure itself changes; the lobby's one-second tick never
/// restarts it.
class LevelBar extends StatelessWidget {
  const LevelBar({super.key, required this.fraction, this.height = 8});

  final double fraction;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // The fill runs from the struck gold's foot to its light by night; by
    // day from the deep gold to the gold primary, whose light end would
    // vanish on the pale well. The track is the ink's, firm enough by day to
    // show where the bar ends.
    final fill = dark
        ? [AppTheme.goldFace.colors.last, AppTheme.goldOnDark]
        : [AppTheme.goldDeep, AppTheme.gold];
    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.pill),
      child: SizedBox(
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              key: const ValueKey('level-bar-track'),
              color: theme.colorScheme.onSurface.withValues(
                alpha: dark ? 0.16 : 0.14,
              ),
            ),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: fraction.clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, f, _) => FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: f,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: fill),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The XP card: "23 / 100 XP" and "77 XP to 🔰 Rookie" over the bar from this
/// level's threshold to the next's, and the next level with its rate — or,
/// at the top of the ladder, the XP alone over a full bar. The bar waits for
/// the ladder, which says where this level starts.
class LevelXpCard extends StatelessWidget {
  const LevelXpCard({super.key, required this.level, required this.ladder});

  final PlayerLevel level;
  final LevelLadder? ladder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final gold = goldInk(theme.brightness);
    final next = level.next;
    final figure = AppTheme.money(
      theme.textTheme.titleMedium!,
      colour: gold,
      weight: FontWeight.w700,
    );
    final quiet = levelQuiet(theme, figures: true);

    double? fraction;
    if (next == null) {
      fraction = 1;
    } else {
      final from = ladder?.levelOf(level.level)?.minXp;
      if (from != null && next.minXp > from) {
        fraction = (level.xp - from) / (next.minXp - from);
      }
    }

    return LevelCard(
      key: const ValueKey('level-xp'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LevelSplit(
            trailShare: 0.55,
            lead: Row(
              children: [
                Icon(Icons.bolt_rounded, size: 18, color: gold),
                const SizedBox(width: Space.xs),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      next == null
                          ? '${formatChips(level.xp)} XP'
                          : t.xpOf(
                              formatChips(level.xp),
                              formatChips(next.minXp),
                            ),
                      key: const ValueKey('level-xp-of'),
                      maxLines: 1,
                      style: figure,
                    ),
                  ),
                ),
              ],
            ),
            trail: Text(
              next == null
                  ? t.topLevelNote
                  : t.xpToNext(
                      formatChips(math.max(0, next.minXp - level.xp)),
                      levelTitle(next.icon, next.title),
                    ),
              key: const ValueKey('level-xp-to-next'),
              maxLines: 2,
              textAlign: TextAlign.end,
              strutStyle: levelStrut(quiet),
              style: quiet,
            ),
          ),
          const SizedBox(height: Space.sm),
          LevelBar(
            key: const ValueKey('winning-tax-progress'),
            fraction: fraction ?? 0,
          ),
          if (next != null) ...[
            const SizedBox(height: Space.sm),
            Text(
              t.levelNextLine(
                t.levelName(next.level, levelTitle(next.icon, next.title)),
                formatChips(next.minXp),
                formatTaxRate(next.taxBps),
              ),
              key: const ValueKey('level-next'),
              maxLines: 2,
              strutStyle: levelStrut(quiet),
              style: quiet,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- badges

/// A badge the viewer holds, as a card: its Lottie (or mark), its name, the
/// rate it brings theirs down to, and its grant — Lifetime, the time left,
/// "Expires in 5 hours" in the warning amber within a day of its end, and
/// "Expired", the card dimmed, when it runs out while the screen is open
/// (until the account is read again and it is gone). The one that sets the
/// viewer's rate is edged in gold and says so. Only the grant's words follow
/// the clock ([LevelClock]); the Lottie is never rebuilt by it.
class HeldBadgeCard extends StatelessWidget {
  const HeldBadgeCard({super.key, required this.badge, this.setsRate = false});

  final PlayerBadge badge;
  final bool setsRate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final gold = goldInk(theme.brightness);
    final taxInk = TableInk.taxOn(theme.brightness);
    final art = RepaintBoundary(
      child: BadgeArt.held(
        badge,
        key: ValueKey('badge-art-${badge.code}'),
        size: 44,
      ),
    );
    final rate = badge.taxBps;
    return LevelClock<(GrantState, String)>(
      read: (now) => grantOf(t, badge, now),
      builder: (context, grant) {
        final (state, words) = grant;
        final expired = state == GrantState.expired;
        final statusInk = switch (state) {
          GrantState.soon => taxInk,
          GrantState.expired => theme.colorScheme.error,
          _ => levelQuietInk(theme),
        };
        return AnimatedOpacity(
          opacity: expired ? 0.5 : 1,
          duration: Motion.base,
          child: LevelCard(
            accent: setsRate && !expired ? gold : null,
            padding: const EdgeInsets.all(Space.sm),
            child: Row(
              children: [
                art,
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Wrap(
                        spacing: Space.xs,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            badgeTitleOf(badge),
                            maxLines: 2,
                            strutStyle: levelStrut(TableType.item(theme)),
                            style: TableType.item(
                              theme,
                              weight: FontWeight.w700,
                            ),
                          ),
                          if (!expired)
                            LevelTag(
                              t.badgeActive,
                              key: ValueKey('badge-active-${badge.code}'),
                              colour: theme.colorScheme.primary,
                            ),
                        ],
                      ),
                      if (rate != null)
                        Text(
                          t.badgeTaxLine(formatTaxRate(rate)),
                          maxLines: 2,
                          style: TableType.label(theme, colour: gold),
                        ),
                      const SizedBox(height: Space.xxs),
                      Row(
                        children: [
                          Icon(
                            switch (state) {
                              GrantState.lifetime =>
                                Icons.all_inclusive_rounded,
                              GrantState.running => Icons.schedule_rounded,
                              GrantState.soon => Icons.warning_amber_rounded,
                              GrantState.expired => Icons.block_rounded,
                            },
                            size: 13,
                            color: statusInk,
                          ),
                          const SizedBox(width: Space.xs),
                          Flexible(
                            child: Text(
                              words,
                              key: ValueKey('badge-grant-${badge.code}'),
                              maxLines: 2,
                              style: levelQuiet(
                                theme,
                                colour: statusInk,
                                figures: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (setsRate && !expired) ...[
                        const SizedBox(height: Space.xs),
                        LevelTag(
                          t.badgeSetsRate,
                          key: ValueKey('badge-sets-rate-${badge.code}'),
                          colour: gold,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Under a player who holds only Regular: what a Royal badge does, and the
/// key to the store's Badges shelf, where each is asked for through support.
class RoyalBadgeHint extends StatelessWidget {
  const RoyalBadgeHint({super.key, required this.rate});

  /// The lowest rate the catalogue's badges set ([royalRateOf]).
  final int rate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final gold = goldInk(theme.brightness);
    return LevelCard(
      key: const ValueKey('royal-badge-hint'),
      padding: const EdgeInsets.fromLTRB(
        Space.md,
        Space.xs,
        Space.xs,
        Space.xs,
      ),
      child: Row(
        children: [
          Icon(Icons.workspace_premium_rounded, size: 20, color: gold),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              t.badgeRoyalHint(formatTaxRate(rate)),
              style: levelQuiet(theme),
            ),
          ),
          const SizedBox(width: Space.sm),
          TextButton(
            key: const ValueKey('royal-badge-store'),
            style: TextButton.styleFrom(
              foregroundColor: gold,
              minimumSize: const Size(Dim.minTouch, Dim.minTouch),
            ),
            onPressed: () {
              tapHaptic(context);
              showChipStore(context, opensOn: StoreTab.badges);
            },
            child: Text(t.badgeSeeStore, maxLines: 1),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------- daily XP

/// The Daily XP's head: what today's window has earned against the most it
/// can, over a bar, and the reset counting down at the right — or, before the
/// day's first hand, that the day starts with it. Every source earned, it
/// says Daily XP Complete in gold.
class DailySummary extends StatelessWidget {
  const DailySummary({super.key, required this.claims, required this.resetsAt});

  final DailyClaims claims;

  /// When the window resets, epoch ms; 0 while none is running.
  final int resetsAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final gold = goldInk(theme.brightness);
    final complete = claims.complete;
    final max = claims.max;
    final earned = math.min(claims.xp, max > 0 ? max : claims.xp);
    final reset = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          resetsAt > 0 ? Icons.timer_outlined : Icons.hourglass_empty_rounded,
          size: 14,
          color: levelQuietInk(theme),
        ),
        const SizedBox(width: Space.xs),
        Flexible(
          child: resetsAt > 0
              ? ResetsIn(
                  key: const ValueKey('daily-reset'),
                  resetsAt: resetsAt,
                  words: t.xpResetsInCap,
                  textAlign: TextAlign.end,
                )
              : Text(
                  t.xpWindowIdle,
                  key: const ValueKey('daily-idle'),
                  maxLines: 2,
                  textAlign: TextAlign.end,
                  style: levelQuiet(theme),
                ),
        ),
      ],
    );
    return LevelCard(
      key: const ValueKey('daily-summary'),
      accent: complete ? gold : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LevelSplit(
            trailShare: 0.55,
            lead: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.xpEarnedToday, maxLines: 1, style: levelQuiet(theme)),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    t.xpOf('$earned', '$max'),
                    key: const ValueKey('daily-xp-earned'),
                    maxLines: 1,
                    style: AppTheme.money(
                      theme.textTheme.titleMedium!,
                      colour: gold,
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            trail: reset,
          ),
          const SizedBox(height: Space.sm),
          LevelBar(
            key: const ValueKey('daily-bar'),
            fraction: max > 0 ? earned / max : 0,
          ),
          if (complete) ...[
            const SizedBox(height: Space.sm),
            Row(
              key: const ValueKey('daily-complete'),
              children: [
                Icon(Icons.verified_rounded, size: 18, color: gold),
                const SizedBox(width: Space.xs),
                Flexible(
                  child: Text(
                    t.xpDailyComplete,
                    maxLines: 2,
                    style: TableType.label(
                      theme,
                      colour: gold,
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            Text(t.xpDailyCompleteNote, style: levelQuiet(theme)),
          ],
        ],
      ),
    );
  }
}

/// The play-time milestones as a track: a node a milestone (15 · 60 · 120
/// min), the minutes and its XP under each, the track gold as far as the last
/// one reached. Each is earned once a window as the window's active play
/// reaches it — so every rung passed is earned, and they add up; the server
/// grants them, this only shows which it has.
class PlayTrack extends StatelessWidget {
  const PlayTrack({super.key, required this.sources, required this.claims});

  /// The PLAY_TIME sources, fewest minutes first.
  final List<LadderSource> sources;
  final DailyClaims claims;

  static const double node = 30;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final gold = goldInk(theme.brightness);
    final glass = GlassColors.of(context);
    final quiet = levelQuietInk(theme);
    final n = sources.length;
    var lastReached = -1;
    for (var i = 0; i < n; i++) {
      if (claims.earned(sources[i])) lastReached = i;
    }
    return LevelCard(
      key: const ValueKey('play-track'),
      padding: const EdgeInsets.symmetric(vertical: Space.md),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth / n;
          return Stack(
            children: [
              if (n > 1)
                Positioned(
                  top: node / 2 - 1.5,
                  left: w / 2,
                  width: w * (n - 1),
                  height: 3,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: quiet.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              if (n > 1 && lastReached > 0)
                Positioned(
                  top: node / 2 - 1.5,
                  left: w / 2,
                  width: w * lastReached,
                  height: 3,
                  child: DecoratedBox(
                    key: const ValueKey('play-track-fill'),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final source in sources)
                    Expanded(
                      child: _PlayNode(
                        key: ValueKey('play-milestone-${source.playMinutes}'),
                        source: source,
                        name: xpSourceName(t, source),
                        earned: claims.earned(source),
                        gold: gold,
                        well: glass.wellFill,
                        quiet: quiet,
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PlayNode extends StatelessWidget {
  const _PlayNode({
    super.key,
    required this.source,
    required this.name,
    required this.earned,
    required this.gold,
    required this.well,
    required this.quiet,
  });

  final LadderSource source;
  final String name;
  final bool earned;
  final Color gold;
  final Color well;
  final Color quiet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    return Semantics(
      label: '$name, +${source.xp} XP${earned ? ', ${t.xpEarned}' : ''}',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: PlayTrack.node,
            height: PlayTrack.node,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: earned
                  ? theme.colorScheme.primary
                  : Color.alphaBlend(well, theme.colorScheme.surface),
              border: Border.all(
                color: earned
                    ? theme.colorScheme.primary
                    : quiet.withValues(alpha: 0.6),
                width: 1.5,
              ),
            ),
            child: earned
                ? Icon(
                    Icons.check_rounded,
                    key: ValueKey('xp-earned-$name'),
                    size: 18,
                    color: theme.colorScheme.onPrimary,
                  )
                : Icon(Icons.schedule_rounded, size: 15, color: quiet),
          ),
          const SizedBox(height: Space.xs),
          Text(
            t.xpMinutes(source.playMinutes ?? 0),
            maxLines: 1,
            style: TableType.label(
              theme,
              colour: theme.colorScheme.onSurface.withValues(
                alpha: AppTheme.inkMed,
              ),
            ),
          ),
          Text(
            '+${source.xp} XP',
            maxLines: 1,
            style: TableType.chips(
              theme,
              colour: earned ? theme.colorScheme.primary : gold,
            ),
          ),
        ],
      ),
    );
  }
}

/// A daily source that is not play time — a winning hand ("👥 Win by Pair
/// +1 XP") — as a tile, ticked once earned in the window; one that can be
/// earned more than once a window says how many times so far ("1/3").
class HandSourceTile extends StatelessWidget {
  const HandSourceTile({
    super.key,
    required this.source,
    required this.name,
    required this.claims,
  });

  final LadderSource source;
  final String name;
  final int claims;

  bool get earned => claims >= source.times;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final gold = goldInk(theme.brightness);
    final nameStyle = TableType.info(
      theme,
      colour: theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkMed),
    );
    return Semantics(
      label: '$name, +${source.xp} XP${earned ? ', ${t.xpEarned}' : ''}',
      excludeSemantics: true,
      child: LevelCard(
        accent: earned ? theme.colorScheme.primary : null,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.sm,
          vertical: Space.sm,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: source.icon.isEmpty
                  ? Icon(Icons.bolt_rounded, size: 18, color: gold)
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        source.icon,
                        style: const TextStyle(fontSize: 20, height: 1),
                      ),
                    ),
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(name, maxLines: 3, style: nameStyle),
                  Row(
                    children: [
                      Text(
                        '+${source.xp} XP',
                        style: TableType.chips(
                          theme,
                          colour: earned ? theme.colorScheme.primary : gold,
                        ),
                      ),
                      if (source.times > 1) ...[
                        const SizedBox(width: Space.sm),
                        Text(
                          '${math.min(claims, source.times)}/${source.times}',
                          style: levelQuiet(theme, figures: true),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (earned)
              Icon(
                Icons.check_circle_rounded,
                key: ValueKey('xp-earned-$name'),
                size: 20,
                color: theme.colorScheme.primary,
              ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------ All levels

/// Over the ladder, standing still while it scrolls: the first column's
/// name — Level, or Badges once their own heading has scrolled up under it —
/// with a key beside it that jumps down to the badges (or back up to the
/// viewer's level), and Tax at the right, over every rate. The key is an
/// outlined capsule, set apart from the column names so it never reads as a
/// third one; its tap target is the full [Dim.minTouch], the capsule drawn
/// inside it.
class _LadderHead extends StatelessWidget {
  const _LadderHead({required this.inBadges, required this.onJump});

  final bool inBadges;
  final VoidCallback onJump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final gold = goldInk(theme.brightness);
    final quiet = levelQuiet(theme);
    final label = inBadges ? t.allLevelsTitle : t.badgesTitle;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: Space.sm),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                inBadges ? t.badgesTitle : t.levelColumn,
                key: const ValueKey('ladder-head-column'),
                maxLines: 1,
                style: inBadges
                    ? TableType.label(
                        theme,
                        colour: gold,
                        weight: FontWeight.w700,
                      )
                    : quiet,
              ),
            ),
          ),
          const SizedBox(width: Space.md),
          Semantics(
            button: true,
            label: label,
            excludeSemantics: true,
            onTap: onJump,
            child: InkWell(
              key: ValueKey(
                inBadges ? 'ladder-jump-levels' : 'ladder-jump-badges',
              ),
              onTap: () {
                tapHaptic(context);
                onJump();
              },
              borderRadius: BorderRadius.circular(Radii.pill),
              child: SizedBox(
                height: Dim.minTouch,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.sm,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: gold.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(Radii.pill),
                      border: Border.all(color: gold.withValues(alpha: 0.6)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          inBadges
                              ? Icons.arrow_upward_rounded
                              : Icons.arrow_downward_rounded,
                          size: 14,
                          color: gold,
                        ),
                        const SizedBox(width: Space.xs),
                        Text(
                          label,
                          maxLines: 1,
                          style: TableType.label(theme, colour: gold),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          Text(t.taxColumn, maxLines: 1, style: quiet),
          const SizedBox(width: Space.sm),
        ],
      ),
    );
  }
}

/// One rung of the ladder: its number on a disc (solid gold for the
/// viewer's, tinted for a rung they have passed), its mark and title with
/// the XP that reaches it, "You" or "Next" beside the name, and its rate.
class LevelRow extends StatelessWidget {
  const LevelRow({super.key, required this.level, required this.mine});

  final LadderLevel level;

  /// The viewer's level; null where it is not known.
  final int? mine;

  bool get you => level.level == mine;

  /// A rung's mark: set at one size, in a slot wide enough for two emoji
  /// side by side at it.
  static const double markSize = 16;
  static const double markWidth = 42;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final gold = goldInk(theme.brightness);
    final m = mine;
    final passed = m != null && level.level < m;
    final next = m != null && level.level == m + 1;
    final name = TableType.info(
      theme,
      colour: scheme.onSurface,
    ).copyWith(fontWeight: you ? FontWeight.w700 : FontWeight.w500);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 1.5),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xs,
      ),
      decoration: you
          ? BoxDecoration(
              color: gold.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: gold.withValues(alpha: 0.7)),
              boxShadow: [
                BoxShadow(color: gold.withValues(alpha: 0.18), blurRadius: 10),
              ],
            )
          : null,
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: you ? AppTheme.goldFace : null,
              color: you
                  ? null
                  : passed
                  ? gold.withValues(alpha: 0.16)
                  : null,
              border: you
                  ? null
                  : Border.all(
                      color: passed
                          ? gold.withValues(alpha: 0.5)
                          : scheme.onSurface.withValues(alpha: 0.18),
                    ),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '${level.level}',
                style: AppTheme.money(
                  theme.textTheme.labelMedium!,
                  colour: you
                      ? AppTheme.ink900
                      : passed
                      ? gold
                      : scheme.onSurface.withValues(alpha: AppTheme.inkMed),
                  weight: FontWeight.w700,
                ),
              ),
            ),
          ),
          const SizedBox(width: Space.sm),
          SizedBox(
            key: const ValueKey('ladder-mark'),
            width: LevelRow.markWidth,
            child: level.icon.isEmpty
                ? null
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      level.icon,
                      // A mark is an icon: one size on every rung, one emoji
                      // or two, and not grown with the text.
                      textScaler: TextScaler.noScaling,
                      style: const TextStyle(
                        fontSize: LevelRow.markSize,
                        height: 1,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: Space.xs,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(level.title, maxLines: 2, style: name),
                    if (you)
                      LevelTag(
                        t.levelYou,
                        key: const ValueKey('ladder-you'),
                        colour: gold,
                        solid: true,
                      )
                    else if (next)
                      LevelTag(
                        t.levelNextTag,
                        key: const ValueKey('ladder-next'),
                        colour: gold,
                      ),
                  ],
                ),
                Text(
                  '${formatChips(level.minXp)} XP',
                  maxLines: 1,
                  style: levelQuiet(theme, figures: true),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.sm),
          Text(
            formatTaxRate(level.taxBps),
            style: TableType.chips(
              theme,
              colour: you ? TableInk.taxOn(theme.brightness) : gold,
            ),
          ),
        ],
      ),
    );
  }
}

/// A badge of the catalogue: its Lottie (or mark), its name, who holds it,
/// how long a grant lasts and its price, and the rate it brings a holder's
/// down to — edged in gold, "Yours" and its time left where the viewer holds
/// it ([held]; never for Regular, which everybody does). A Royal badge — any
/// badge but the default — stands a step above Regular: its art on a struck
/// gold ring, a faint gold edge, and "Available" where the viewer does not
/// hold it (brief §20, §24). Its price stays the words the catalogue says.
class CatalogueBadgeRow extends StatelessWidget {
  const CatalogueBadgeRow({super.key, required this.badge, this.held});

  final LadderBadge badge;
  final PlayerBadge? held;

  /// The viewer holds it (the old popup's name for the same thing).
  bool get lit => held != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    final gold = goldInk(theme.brightness);
    final rate = badge.taxBps;
    final mine = held;
    final royal = !badge.isDefault;
    final art = RepaintBoundary(
      child: BadgeArt.of(badge, size: royal ? 34 : 38),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xs),
      child: LevelCard(
        accent: mine != null || royal ? gold : null,
        accentStrength: mine != null ? 1 : 0.45,
        padding: const EdgeInsets.all(Space.sm),
        child: Row(
          children: [
            if (royal)
              Container(
                key: ValueKey('ladder-badge-ring-${badge.code}'),
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: gold.withValues(alpha: 0.10),
                  border: Border.all(
                    color: gold.withValues(alpha: 0.75),
                    width: 1.5,
                  ),
                ),
                child: art,
              )
            else
              art,
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: Space.xs,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        levelTitle(badge.icon, badge.title),
                        maxLines: 2,
                        style: TableType.info(
                          theme,
                          colour: theme.colorScheme.onSurface,
                        ).copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (mine != null)
                        LevelTag(
                          t.badgeYours,
                          key: ValueKey('ladder-badge-yours-${badge.code}'),
                          colour: gold,
                          solid: true,
                        )
                      else if (royal)
                        LevelTag(
                          t.badgeAvailable,
                          key: ValueKey('ladder-badge-available-${badge.code}'),
                          colour: gold,
                        ),
                    ],
                  ),
                  Text(
                    ladderBadgeDetail(t, badge),
                    maxLines: 2,
                    style: levelQuiet(theme, figures: true),
                  ),
                  if (mine != null && mine.expiresAt > 0)
                    LevelClock<String>(
                      read: (now) => grantOf(t, mine, now).$2,
                      builder: (context, words) => Text(
                        words,
                        maxLines: 1,
                        style: levelQuiet(theme, colour: gold, figures: true),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: Space.sm),
            Text(
              rate == null ? '—' : formatTaxRate(rate),
              style: TableType.chips(theme, colour: gold),
            ),
          ],
        ),
      ),
    );
  }
}
