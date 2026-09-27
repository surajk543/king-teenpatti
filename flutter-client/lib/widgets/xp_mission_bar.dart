// The bar that says a daily XP mission is done (owner, 27 Sep 2026: "whenever
// xp mission completed, show top notification bar for 5 seconds showing this
// is completed and xp increased").
//
// [XpMissionHost] stands above the app's Navigator (main.dart's builder, as
// the toasts' Scaffold does), so the bar is seen on the lobby and on both
// felts, over any sheet, drawer or dialog. It slides down from the top edge,
// inside the safe area, stays [XpMissionHost.hold], and slides away; a tap
// sends it away early. Missions arriving together wait their turn — one bar at
// a time, never two on top of each other ([XpMissions]).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../state/xp_missions.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import '../theme/theme_colors.dart';
import 'premium_surface.dart';
import 'table_tax.dart' show xpSourceName, levelStrut;

/// Shows [GameState.xpMissions], one bar at a time, at the top of the screen.
class XpMissionHost extends StatefulWidget {
  const XpMissionHost({super.key});

  /// How long a bar stays once it is down (the owner's five seconds).
  static const Duration hold = Duration(seconds: 5);

  /// Its way down, its way back up, and the breath between two bars.
  static const Duration slideIn = Duration(milliseconds: 360);
  static const Duration slideOut = Duration(milliseconds: 260);
  static const Duration between = Duration(milliseconds: 180);

  /// The widest a bar may be on a screen [width] wide (its safe width): a
  /// slim bar in the middle of the top edge, clear of the table's corners —
  /// its Shop key on the left and its wallet on the right — on every phone
  /// from 592dp up. The lobby's top bar has no gap in its middle: there, for
  /// its five seconds, the bar lies over the player's name and wallet pill
  /// (and, below about 700dp, the Shop key beside it), clear of the bonus chip
  /// on the left and the drawer keys on the right; a tap sends it away.
  /// A bar is only as wide as its words: this is the room a long one (a
  /// Bengali mission, "Supreme Overlord") may take before it wraps. The
  /// table's corners leave a centred bar 360dp at 592 and 400 at 640; the
  /// lobby's drawer keys start nearer the middle, and there it is narrower.
  /// table: 592 -> 355 | 640 -> 384 | 915 -> 440 | 1280 -> 440
  /// lobby: 592 -> 296 | 640 -> 320 | 915 -> 420 | 1280 -> 420
  static double maxWidthFor(double width, {bool lobby = false}) => lobby
      ? (width * 0.5).clamp(260.0, 420.0)
      : (width * 0.6).clamp(260.0, 440.0);

  /// How far below the top of the safe area the bar stands.
  static const double topGap = Space.xs;

  @override
  State<XpMissionHost> createState() => _XpMissionHostState();
}

class _XpMissionHostState extends State<XpMissionHost>
    with TickerProviderStateMixin {
  // Made in initState, never lazily: a late controller first read in
  // dispose() builds itself against a deactivated element and takes the
  // teardown with it (CLAUDE.md §12.3) — and a host that never showed a bar
  // reads them first there.
  late final AnimationController _slide;

  /// Drains from the moment the bar sets off until it leaves: the thin gold
  /// line along its foot.
  late final AnimationController _life;

  @override
  void initState() {
    super.initState();
    _slide = AnimationController(
      vsync: this,
      duration: XpMissionHost.slideIn,
      reverseDuration: XpMissionHost.slideOut,
    );
    _life = AnimationController(
      vsync: this,
      duration: XpMissionHost.slideIn + XpMissionHost.hold,
    );
  }

  XpMissions? _missions;
  XpMissionNews? _showing;
  bool _leaving = false;
  Timer? _hold;
  Timer? _gap;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final missions = context.read<GameState>().xpMissions;
    if (!identical(missions, _missions)) {
      _missions?.removeListener(_changed);
      _missions = missions..addListener(_changed);
      _changed();
    }
  }

  void _changed() {
    if (!mounted) return;
    final missions = _missions!;
    final showing = _showing;
    if (showing != null) {
      // Cleared under it (a sign-out): it goes now.
      if (!missions.queue.any((n) => n.id == showing.id)) _leave();
      return;
    }
    if (_gap != null) return;
    final next = missions.current;
    if (next == null) return;
    setState(() => _showing = next);
    _leaving = false;
    _slide.forward(from: 0);
    _life.forward(from: 0);
    _hold?.cancel();
    _hold = Timer(XpMissionHost.slideIn + XpMissionHost.hold, _leave);
  }

  void _leave() {
    final showing = _showing;
    if (showing == null || _leaving || !mounted) return;
    _leaving = true;
    _hold?.cancel();
    _hold = null;
    _slide.reverse().whenComplete(() {
      if (!mounted || !identical(_showing, showing)) return;
      setState(() => _showing = null);
      _leaving = false;
      _gap = Timer(XpMissionHost.between, () {
        _gap = null;
        if (!mounted) return;
        final missions = _missions!;
        if (missions.queue.any((n) => n.id == showing.id)) {
          missions.shown(showing.id); // notifies: _changed shows the next
        } else {
          _changed();
        }
      });
    });
  }

  @override
  void dispose() {
    _missions?.removeListener(_changed);
    _hold?.cancel();
    _gap?.cancel();
    _slide.dispose();
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lobby = context.select<GameState, bool>(
      (s) => s.screen != Screen.table,
    );
    final news = _showing;
    if (news == null) return const SizedBox.shrink();
    final media = MediaQuery.of(context);
    final safe = media.padding;
    final width = media.size.width - safe.left - safe.right;
    final slide = CurvedAnimation(
      parent: _slide,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(
          top: safe.top + XpMissionHost.topGap,
          left: safe.left + Space.sm,
          right: safe.right + Space.sm,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: XpMissionHost.maxWidthFor(width, lobby: lobby),
          ),
          child: FadeTransition(
            opacity: slide,
            child: SlideTransition(
              position: Tween(
                begin: const Offset(0, -1.4),
                end: Offset.zero,
              ).animate(slide),
              child: XpMissionBar(
                key: ValueKey('xp-mission-${news.id}'),
                news: news,
                life: _life,
                onDismiss: _leave,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One completed mission, drawn: its mark, "Win by Pair completed", the XP it
/// gave in gold beside the player's XP now ("24 / 100 XP"), and — when the
/// award lifted them a level — "Level up! 🔰 Level 2 · Rookie" under it, with
/// "Winning tax now 19.71%" when the level changed the rate they pay.
///
/// The mission and the level up are never set smaller or cut short: a name
/// too long for the bar (a Bengali mission at 592dp and text x1.25, a level
/// such as "Supreme Overlord") takes a second line instead.
class XpMissionBar extends StatelessWidget {
  const XpMissionBar({
    super.key,
    required this.news,
    required this.onDismiss,
    this.life,
  });

  final XpMissionNews news;
  final VoidCallback onDismiss;

  /// 0 → 1 over the bar's five seconds; null draws no line.
  final Animation<double>? life;

  /// The lines as they read, for the bar and for a screen reader.
  static ({
    String mark,
    String title,
    String? gained,
    String? total,
    String? levelUp,
    String? taxNow,
  })
  linesFor(Strings t, XpMissionNews news, LevelLadder? ladder) {
    final source = news.sourceIn(ladder);
    final name = source == null ? t.xpMissionFallback : xpSourceName(t, source);
    final xp = news.xpIn(ladder);
    final total = news.total;
    final goal = news.goal;
    final level = news.levelUp;
    final taxBps = news.levelUpTaxBps;
    return (
      mark: source?.icon ?? '',
      title: t.xpMissionDone(name),
      gained: xp == null || xp <= 0 ? null : t.xpGained(formatChips(xp)),
      total: total == null
          ? null
          : goal == null
          ? '${formatChips(total)} XP'
          : t.xpOf(formatChips(total), formatChips(goal)),
      levelUp: level == null
          ? null
          : t.levelUpOnly(
              [
                if (level.icon.isNotEmpty) level.icon,
                t.levelName(level.level, level.title),
              ].join(' '),
            ),
      taxNow: level == null || taxBps == null
          ? null
          : t.xpBarTaxNow(formatTaxRate(taxBps)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    // The language and the ladder, never `t` itself: GameState makes a new
    // Strings on every read, and a select on it would rebuild the bar with
    // every one-second tick.
    final (lang, ladder) = context.select<GameState, (AppLang, LevelLadder?)>(
      (s) => (s.lang, s.levelLadder),
    );
    final t = Strings(lang);
    final lines = linesFor(t, news, ladder);
    final gold = AppTheme.goldInk(theme.brightness);
    final text = theme.textTheme;

    final titleStyle = AppTheme.label(
      text.bodyMedium!,
      colour: glass.textDisplay,
      weight: FontWeight.w700,
    );
    final totalStyle = TableType.metadata(theme, colour: glass.cardMuted);
    final levelStyle = AppTheme.label(
      text.bodySmall!,
      colour: gold,
      weight: FontWeight.w700,
    );

    final announcement = [
      lines.title,
      ?lines.gained,
      ?lines.total,
      ?lines.levelUp,
      ?lines.taxNow,
    ].join('. ');

    return Semantics(
      container: true,
      liveRegion: true,
      label: announcement,
      onTapHint: t.close,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onDismiss,
        // An opaque body under the card's glass: the bar is read over a
        // busy table, and the name of a seat behind it must not show through
        // its words.
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: glass.cardFill.withValues(alpha: 1),
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: PremiumGlassPanel(
            key: const ValueKey('xp-mission-bar'),
            surface: GlassSurface.card,
            live: true,
            radius: Radii.md,
            padding: EdgeInsets.zero,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.sm,
                    Space.xs + 1,
                    Space.md,
                    Space.xs + 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _MissionMark(mark: lines.mark, gold: gold),
                      const SizedBox(width: Space.sm),
                      Flexible(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Words(
                              lines.title,
                              key: const ValueKey('xp-mission-title'),
                              style: titleStyle,
                            ),
                            if (lines.gained != null ||
                                lines.total != null) ...[
                              const SizedBox(height: 1),
                              _OneLineRow(
                                children: [
                                  if (lines.gained != null)
                                    _GainedPill(
                                      lines.gained!,
                                      gold: gold,
                                      base: text.bodySmall!,
                                    ),
                                  if (lines.gained != null &&
                                      lines.total != null)
                                    const SizedBox(width: Space.xs),
                                  if (lines.total != null)
                                    Text(
                                      lines.total!,
                                      key: const ValueKey('xp-mission-total'),
                                      maxLines: 1,
                                      softWrap: false,
                                      style: totalStyle,
                                    ),
                                ],
                              ),
                            ],
                            if (lines.levelUp != null) ...[
                              const SizedBox(height: 1),
                              _Words(
                                lines.levelUp!,
                                key: const ValueKey('xp-mission-level-up'),
                                style: levelStyle,
                                strut: true,
                              ),
                            ],
                            if (lines.taxNow != null)
                              Text(
                                lines.taxNow!,
                                key: const ValueKey('xp-mission-tax-now'),
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.fade,
                                style: totalStyle,
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (life != null)
                  Positioned(
                    left: Space.md,
                    right: Space.md,
                    bottom: 0,
                    height: 2,
                    child: _LifeLine(life: life!, colour: gold),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The mission's name or the level up: at its own size always, on a second
/// line where one is too short for it — never set smaller, never cut (a
/// FittedBox shrank "Level up! 🔥🔱 Level 44 · Supreme Overlord" to two-thirds
/// on a 592dp phone at text x1.25).
class _Words extends StatelessWidget {
  const _Words(this.text, {super.key, required this.style, this.strut = false});

  /// Two lines hold the longest of them at the narrowest bar (296dp) and
  /// the largest text (x1.25), in every language.
  static const int maxLines = 2;

  final String text;
  final TextStyle style;
  final bool strut;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
    style: style,
    strutStyle: strut ? levelStrut(style) : null,
  );
}

class _OneLineRow extends StatelessWidget {
  const _OneLineRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: Row(mainAxisSize: MainAxisSize.min, children: children),
  );
}

/// The mission's mark (its emoji, "👥") in a gold-ringed disc, with a green
/// tick on its corner: done.
class _MissionMark extends StatelessWidget {
  const _MissionMark({required this.mark, required this.gold});

  final String mark;
  final Color gold;

  static const double size = 30;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return SizedBox(
      width: size + 3,
      height: size + 3,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  AppTheme.gold.withValues(alpha: dark ? 0.30 : 0.22),
                  AppTheme.gold.withValues(alpha: dark ? 0.10 : 0.08),
                ],
              ),
              border: Border.all(
                color: gold.withValues(alpha: 0.75),
                width: 1.2,
              ),
            ),
            child: mark.isEmpty
                ? Icon(Icons.bolt_rounded, size: 18, color: gold)
                : Text(
                    mark,
                    textScaler: TextScaler.noScaling,
                    // The theme's style, for its font fallback: the mark
                    // is a colour emoji the phone draws from its own font.
                    style: theme.textTheme.bodyMedium!.copyWith(
                      fontSize: 16,
                      height: 1.1,
                    ),
                  ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.primary,
                border: Border.all(
                  color: GlassColors.of(context).cardFill.withValues(alpha: 1),
                  width: 1.5,
                ),
              ),
              child: Icon(
                Icons.check_rounded,
                size: 10,
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "+1 XP" on a gold wash: what the mission gave.
class _GainedPill extends StatelessWidget {
  const _GainedPill(this.label, {required this.gold, required this.base});

  final String label;
  final Color gold;
  final TextStyle base;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey('xp-mission-gained'),
    decoration: BoxDecoration(
      color: AppTheme.gold.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(Radii.pill),
      border: Border.all(color: gold.withValues(alpha: 0.55), width: 1),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 1),
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        style: AppTheme.money(base, colour: gold, weight: FontWeight.w800),
      ),
    ),
  );
}

/// The bar's five seconds, draining along its foot.
class _LifeLine extends StatelessWidget {
  const _LifeLine({required this.life, required this.colour});

  final Animation<double> life;
  final Color colour;

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(child: CustomPaint(painter: _LifePainter(life, colour)));
}

class _LifePainter extends CustomPainter {
  _LifePainter(this.life, this.colour) : super(repaint: life);

  final Animation<double> life;
  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final left = 1 - life.value.clamp(0.0, 1.0);
    if (left <= 0) return;
    final w = size.width * left;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH((size.width - w) / 2, 0, w, size.height),
      Radius.circular(size.height / 2),
    );
    canvas.drawRRect(rect, Paint()..color = colour.withValues(alpha: 0.7));
  }

  @override
  bool shouldRepaint(_LifePainter old) =>
      old.life != life || old.colour != colour;
}
