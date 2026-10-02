// The popup that congratulates a player on a new level (owner, 2 Oct 2026:
// "Use this animation to COngrats Player once his level upgraded , show a pop
// in UI, and Tell in pop up that something like that now you will pay less
// tax and how much less tax u pay tell that in pop up").
//
// [LevelUpHost] stands above the app's Navigator (main.dart's builder, beside
// the XP mission bar), so the popup is seen on the lobby and on both felts,
// over any sheet, drawer or dialog. It shows [GameState.levelUps]: the
// owner's `Congrats!.json` beside the level reached, the winning tax paid
// before and now, and how much less that is. It goes with its Continue key, a
// tap outside it, Back, or by itself after [LevelUpHost.hold] — a level up
// lands at a hand's end, and a popup must never keep a player from the next
// hand.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/game_state.dart';
import '../state/level_up.dart';
import '../theme/app_theme.dart';
import '../theme/depth.dart';
import '../theme/theme_colors.dart';
import 'glass_components.dart';
import 'level_art.dart';
import 'lucky_spin_key.dart' show LuckyGoldKey;
import 'premium_surface.dart';
import 'table_tax.dart' show badgeTitleOf;

/// The words of one level up, in the player's language — the popup draws
/// them, and a screen reader hears them as one sentence ([spoken]).
@immutable
class LevelUpLines {
  const LevelUpLines({
    required this.kicker,
    required this.level,
    required this.reached,
    this.headline,
    this.before,
    this.now,
    this.detail,
  });

  /// "Level up".
  final String kicker;

  /// "Level 2 · Rookie".
  final String level;

  /// "You reached Level 2 · Rookie".
  final String reached;

  /// "You now pay less winning tax" — or, where a badge already keeps the
  /// rate lower than the level's, "Your Royal Ace badge already keeps your
  /// winning tax at 0%."; null when the level up says nothing about the tax.
  final String? headline;

  /// The rate paid before and the rate paid now ("20%", "19.71%"): only when
  /// the level up lowered it.
  final String? before;
  final String? now;

  /// "You pay 0.29% less than before" — or, under a badge, "This level's own
  /// rate is 19.71%, down from 20%."
  final String? detail;

  /// Whether the two rates are drawn (the level up lowered what is paid).
  bool get hasRates => before != null && now != null;

  /// Everything the popup says, as a screen reader hears it.
  String get spoken => [
    kicker,
    reached,
    ?headline,
    if (hasRates) '$before → $now',
    ?detail,
  ].join('. ');

  static LevelUpLines of(Strings t, LevelUpNews news) {
    final level = t.levelName(news.to.level, news.to.title);
    String? headline, before, now, detail;
    final badge = news.rateBadge;
    if (news.paysLess) {
      headline = t.levelUpPaysLess;
      before = formatTaxRate(news.paidBefore);
      now = formatTaxRate(news.paidNow);
      detail = t.levelUpSaved(formatTaxRate(news.savedBps));
    } else if (badge != null) {
      headline = t.levelUpBadgeKeeps(
        badgeTitleOf(badge),
        formatTaxRate(news.paidNow),
      );
      if (news.levelRateFell) {
        detail = t.levelUpLevelRate(
          formatTaxRate(news.to.taxBps),
          formatTaxRate(news.from.taxBps),
        );
      }
    }
    return LevelUpLines(
      kicker: t.levelUpKicker,
      level: level,
      reached: t.levelUpReached(level),
      headline: headline,
      before: before,
      now: now,
      detail: detail,
    );
  }
}

/// The owner's `Congrats!.json`: the word over bursts of stars and rings of
/// sparks, 1000 units square, 2.9 s, looping while the popup is up.
///
/// By day it plays in its own colours. By night its word and its rings — navy
/// and indigo, which vanish on the dark popup — are drawn in the app's gold;
/// the stars keep theirs. The file is never edited: the two are told apart by
/// their layers' names ([wordPath], [ringsPath]).
class CongratsArt extends StatelessWidget {
  const CongratsArt({super.key, required this.side});

  final double side;

  static const String asset = 'assets/animations/Congrats!.json';

  /// The three text layers that write "Congrats!", one over another.
  static const List<String> wordPath = ['C'];

  /// Everything under the five ring layers: their dotted strokes.
  static const List<String> ringsPath = ['B', '**'];

  static final LottieDelegates _night = LottieDelegates(
    values: [
      ValueDelegate.color(wordPath, value: AppTheme.goldOnDark),
      ValueDelegate.strokeColor(ringsPath, value: AppTheme.goldBright),
    ],
  );

  /// How the file is recoloured for [brightness]: nothing by day.
  static LottieDelegates? delegatesFor(Brightness brightness) =>
      brightness == Brightness.dark ? _night : null;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return SizedBox(
      width: side,
      height: side,
      child: Lottie.asset(
        asset,
        width: side,
        height: side,
        fit: BoxFit.contain,
        repeat: true,
        animate: !MediaQuery.disableAnimationsOf(context),
        delegates: delegatesFor(brightness),
        // A file that will not draw leaves a party mark, never a hole.
        errorBuilder: (context, error, stackTrace) => Icon(
          Icons.celebration_rounded,
          size: side * 0.5,
          color: AppTheme.goldInk(brightness),
        ),
      ),
    );
  }
}

/// Shows [GameState.levelUps] in the middle of the screen, above everything.
class LevelUpHost extends StatefulWidget {
  const LevelUpHost({super.key});

  /// How long the popup stays when nobody puts it away.
  static const Duration hold = Duration(seconds: 9);

  /// At a table the popup waits this long before it appears: a level up lands
  /// with a hand's end, and the cards turned over and the winner's
  /// celebration are seen first.
  static const Duration tableDelay = Duration(milliseconds: 2200);

  /// Its way in and its way out.
  static const Duration enter = Motion.enter;
  static const Duration leave = Motion.base;

  @override
  State<LevelUpHost> createState() => _LevelUpHostState();
}

class _LevelUpHostState extends State<LevelUpHost>
    with SingleTickerProviderStateMixin {
  // Made in initState, never lazily (CLAUDE.md §12.3): a host that never
  // showed a popup would first read it in dispose().
  late final AnimationController _entry;
  late final CurvedAnimation _fade;
  late final Animation<double> _scale;
  late final CurvedAnimation _settle;

  LevelUps? _levelUps;
  LevelUpNews? _showing;
  Timer? _wait;
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    _entry = AnimationController(
      vsync: this,
      duration: LevelUpHost.enter,
      reverseDuration: LevelUpHost.leave,
    );
    _fade = CurvedAnimation(parent: _entry, curve: Motion.standard);
    _settle = CurvedAnimation(parent: _entry, curve: Motion.settle);
    _scale = Tween<double>(begin: 0.92, end: 1).animate(_settle);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final levelUps = context.read<GameState>().levelUps;
    if (!identical(levelUps, _levelUps)) {
      _levelUps?.removeListener(_changed);
      _levelUps = levelUps..addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    _levelUps?.removeListener(_changed);
    _wait?.cancel();
    _hold?.cancel();
    _fade.dispose();
    _settle.dispose();
    _entry.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final next = _levelUps!.current;
    if (next == null) {
      _wait?.cancel();
      _wait = null;
      _hold?.cancel();
      if (_showing != null) _leave();
      return;
    }
    final showing = _showing;
    if (showing != null) {
      if (showing.id == next.id) return;
      // A second level up while the popup is up: the same popup now tells the
      // whole climb, and its time starts again.
      setState(() => _showing = next);
      _entry.forward();
      _armHold(next);
      return;
    }
    // Already waiting to appear: it will show whatever is current then.
    if (_wait != null) return;
    if (context.read<GameState>().screen == Screen.table) {
      _wait = Timer(LevelUpHost.tableDelay, _show);
    } else {
      _show();
    }
  }

  void _show() {
    _wait = null;
    if (!mounted) return;
    final news = _levelUps!.current;
    if (news == null) return;
    setState(() => _showing = news);
    _entry.forward(from: 0);
    _armHold(news);
  }

  void _armHold(LevelUpNews news) {
    _hold?.cancel();
    _hold = Timer(LevelUpHost.hold, () => _levelUps?.dismiss(news.id));
  }

  void _leave() {
    _entry.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() => _showing = null);
      // One raised while this one was leaving shows now.
      if (_levelUps?.current != null) _changed();
    });
  }

  void _dismiss() {
    final showing = _showing;
    if (showing != null) _levelUps?.dismiss(showing.id);
  }

  @override
  Widget build(BuildContext context) {
    final news = _showing;
    if (news == null) return const SizedBox.shrink();
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    final brightness = Theme.of(context).brightness;
    return FadeTransition(
      opacity: _fade,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // A tap anywhere outside the card puts the popup away — and goes no
          // further: it must never also press a key of the game under it.
          ExcludeSemantics(
            child: GestureDetector(
              key: const ValueKey('level-up-scrim'),
              behavior: HitTestBehavior.opaque,
              onTap: _dismiss,
              child: ColoredBox(
                color: AppTheme.ground(brightness).withValues(alpha: 0.72),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: ScaleTransition(
                scale: _scale,
                child: LevelUpCard(
                  key: const ValueKey('level-up-popup'),
                  news: news,
                  t: Strings(lang),
                  onContinue: _dismiss,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The popup itself: the congratulation at the left, the level and what it
/// does to the winning tax at the right, over one gold key. On a screen too
/// narrow for the two side by side the art stands over the words.
class LevelUpCard extends StatelessWidget {
  const LevelUpCard({
    super.key,
    required this.news,
    required this.t,
    required this.onContinue,
  });

  final LevelUpNews news;
  final Strings t;
  final VoidCallback onContinue;

  /// The card's width on a screen [width] wide.
  static double widthFor(double width) =>
      (width - 2 * Space.xl).clamp(280.0, 600.0);

  /// The side of the congratulation's square on a screen [size].
  static double artSideFor(Size size) =>
      (size.height * 0.44).clamp(104.0, 190.0);

  /// Below this width the art stands over the words.
  static const double stackBelow = 480;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final brightness = theme.brightness;
    final size = MediaQuery.sizeOf(context);
    final lines = LevelUpLines.of(t, news);
    final gold = AppTheme.goldInk(brightness);
    final english = t.lang == AppLang.english;
    final stacked = size.width < stackBelow;
    final artSide = artSideFor(size);

    final words = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          english ? lines.kicker.toUpperCase() : lines.kicker,
          key: const ValueKey('level-up-kicker'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.label(
            theme.textTheme.labelSmall ?? const TextStyle(),
            colour: gold,
            weight: FontWeight.w700,
          ).copyWith(letterSpacing: english ? 1.2 : null),
        ),
        const SizedBox(height: Space.xs),
        Row(
          children: [
            LevelArt.of(
              news.to,
              key: const ValueKey('level-up-level-art'),
              size: 30,
            ),
            if (news.to.assetUrl.isNotEmpty) const SizedBox(width: Space.sm),
            Flexible(
              child: Text(
                lines.level,
                key: const ValueKey('level-up-level'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.label(
                  theme.textTheme.titleLarge ?? const TextStyle(),
                  colour: glass.textDisplay,
                  weight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        if (lines.headline case final headline?) ...[
          const SizedBox(height: Space.md),
          Text(
            headline,
            key: const ValueKey('level-up-headline'),
            style: theme.textTheme.bodyMedium?.copyWith(color: glass.textBody),
          ),
        ],
        if (lines.hasRates) ...[
          const SizedBox(height: Space.xs),
          // The two rates on one line: the old one struck through, the new
          // one the largest figure of the popup, in gold. Set smaller rather
          // than cut where the card is narrow.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  lines.before!,
                  key: const ValueKey('level-up-rate-before'),
                  style:
                      AppTheme.money(
                        theme.textTheme.titleMedium ?? const TextStyle(),
                        colour: glass.textMuted,
                        weight: FontWeight.w600,
                      ).copyWith(
                        decoration: TextDecoration.lineThrough,
                        decorationColor: glass.textMuted,
                      ),
                ),
                const SizedBox(width: Space.sm),
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 18,
                  color: glass.textMuted,
                ),
                const SizedBox(width: Space.sm),
                Text(
                  lines.now!,
                  key: const ValueKey('level-up-rate-now'),
                  style: AppTheme.money(
                    theme.textTheme.headlineSmall ?? const TextStyle(),
                    colour: gold,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (lines.detail case final detail?) ...[
          const SizedBox(height: Space.xs),
          Text(
            detail,
            key: const ValueKey('level-up-detail'),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: lines.hasRates ? glass.textDisplay : glass.textBody,
              fontWeight: lines.hasRates ? FontWeight.w600 : null,
            ),
          ),
        ],
        const SizedBox(height: Space.lg),
        LuckyGoldKey(
          key: const ValueKey('level-up-continue'),
          label: t.continueKey,
          onTap: onContinue,
          expand: true,
        ),
      ],
    );

    final art = CongratsArt(key: const ValueKey('level-up-art'), side: artSide);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: widthFor(size.width),
        maxHeight: Dim.dialogMaxH(size.height),
      ),
      // This layer has no Scaffold above it.
      child: Material(
        type: MaterialType.transparency,
        child: Semantics(
          container: true,
          liveRegion: true,
          label: lines.spoken,
          child: GlassCard(
            mode: GlassMode.auto,
            priority: 30,
            depth: Elevation.overlay,
            radius: Radii.lg,
            live: true,
            padding: const EdgeInsets.all(Space.lg),
            child: SingleChildScrollView(
              child: stacked
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        art,
                        const SizedBox(height: Space.sm),
                        words,
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        art,
                        const SizedBox(width: Space.lg),
                        Expanded(child: words),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
