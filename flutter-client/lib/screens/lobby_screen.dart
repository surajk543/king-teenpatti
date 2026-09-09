import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../settings/feedback_settings.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar.dart';
import '../widgets/buy_chips.dart';
import '../widgets/feedback_toggles.dart';
import '../widgets/drifting_chips.dart';
import '../widgets/fireworks.dart';
import '../widgets/glass_panels.dart';
import '../widgets/poker_chip.dart';
import '../widgets/premium_surface.dart';
import '../widgets/rules_sheet.dart';
import '../widgets/table_ground.dart';

/// The lobby: every choice is a card on one horizontal rail, so a phone held in
/// landscape never has to scroll down — swipe sideways instead.
///
/// The rail is a shelf of four *products*, not a stack of panels: each table is
/// a solid lit object in its own colour (gold, sapphire, royal purple) and the
/// private room is the emerald fourth. Glass is spent only on what covers the
/// shelf — the two drawers, the delete dialog, the picture sheet — and never on
/// the cards themselves, which would flatten three identities into one charcoal
/// rectangle repeated three times.
///
/// Nothing here blurs while the player is only looking: the drifting chips
/// repaint the whole background continuously, and a `BackdropFilter` over a
/// backdrop that is dirty every frame is a blur every frame.
/// Champagne reads as gold on charcoal and as mud on parchment, so every gold
/// figure in the lobby routes through here rather than naming a constant.
///
/// `onCloth` is the exception the table cards need: their ground is baize,
/// which is dark in BOTH schemes, so the deep gold picked for a pale panel
/// goes dim on them.
Color _goldInk(Brightness b, {bool onCloth = false}) =>
    b == Brightness.dark || onCloth ? AppTheme.goldBright : AppTheme.goldDeep;

/// Which panel the right-hand drawer is currently showing. A Scaffold has only
/// one end drawer, and both of these belong on that side.
enum _EndPanel { stats, settings }

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  _EndPanel _panel = _EndPanel.stats;

  void _open(BuildContext context, _EndPanel panel) {
    setState(() => _panel = panel);
    Scaffold.of(context).openEndDrawer();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final user = state.user;
    // The rail is rebuilt whenever the server changes what it offers, so the
    // entrance animation is keyed off the card's place in the row.
    var slot = 0;
    Widget entering(Widget child) => _Entrance(index: slot++, child: child);

    return Scaffold(
      key: state.lobbyScaffold,
      // The ground paints the page; the Scaffold's own flat surface would sit
      // between the two and cancel the vignette.
      backgroundColor: Colors.transparent,
      endDrawer: _panel == _EndPanel.stats
          ? const _StatsDrawer()
          : const _SettingsDrawer(),
      body: LobbyGround(
        child: SafeArea(
          child: Stack(
            children: [
              // A few chips drifting slowly up behind everything: the room has a
              // life of its own before the player touches anything.
              const Positioned.fill(
                child: IgnorePointer(child: DriftingChips()),
              ),
              Column(
                children: [
                  _TopBar(user: user, onOpen: _open),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final h = MediaQuery.sizeOf(context).height;
                        // The cards are square, so their height sets their
                        // width; on a tablet an uncapped card grows until two
                        // of them fill the screen. The rail is derived from the
                        // card plus its own padding rather than the other way
                        // round, so the card is never squeezed by the rail:
                        // h=360 -> 259.2 | h=411 -> 295.9 | h=800 -> 400.0.
                        final side = math.min(
                          math.max(box.maxHeight - Space.xl, 0),
                          Dim.lobbyCardSide(h),
                        );

                        return Center(
                          child: SizedBox(
                            height: side + Space.xl,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding: const EdgeInsets.fromLTRB(
                                Space.xl,
                                Space.md,
                                Space.xl,
                                Space.md,
                              ),
                              children: [
                                // The server decides which rooms exist and in
                                // what order; this only draws the list it sent.
                                for (final table in state.config.tables)
                                  entering(_TableCard(table: table)),
                                entering(const _PrivateCard()),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
              // Requirement 27: the milestone sits opposite the four-hour bonus,
              // which lives in the top rail's own reserved slot. Both live in
              // the bottom-right corner, stacked rather than in a row: side by
              // side they would run off a narrow screen, and the rail of tables
              // scrolls underneath them.
              const Positioned(
                bottom: Space.md,
                right: Space.md,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _MilestoneChip(),
                    SizedBox(height: Space.md),
                    BuyChipsButton(),
                  ],
                ),
              ),
              // Sits last so it covers the chips and the rail. Collecting a
              // reward is the one moment in the lobby worth interrupting for.
              const _RewardCelebration(),
            ],
          ),
        ),
      ),
    );
  }
}

/// The banner for a collected reward: fireworks, a spinning chip, the amount,
/// and when the next one is due.
///
/// It replaced a one-line toast that said "Not ready yet" on success, because
/// the client read the amount from a field the server does not send. Since the
/// grant is real and irreversible, it deserves to be unmistakable — a player
/// who is not sure whether their tap worked will tap again.
class _RewardCelebration extends StatefulWidget {
  const _RewardCelebration();

  @override
  State<_RewardCelebration> createState() => _RewardCelebrationState();
}

class _RewardCelebrationState extends State<_RewardCelebration>
    with SingleTickerProviderStateMixin {
  /// Built in initState, not lazily in the field initialiser.
  ///
  /// `build` returns a `SizedBox.shrink()` whenever no reward is showing —
  /// which is nearly always — so a lazy `late final` here would never be
  /// initialised, and then `dispose()` would run its initialiser while this
  /// element was being torn down. Constructing an AnimationController needs a
  /// TickerMode lookup, and that lookup is illegal on a deactivated element:
  /// the same crash that `_Blink` in seat_pod.dart was fixed for.
  late final AnimationController _in;

  /// Which reward the current entrance animation belongs to, so a second
  /// collection re-runs it instead of appearing already finished.
  int? _shownFor;

  @override
  void initState() {
    super.initState();
    _in = AnimationController(vsync: this, duration: Motion.arrive);
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final state = context.watch<GameState>();
    final won = state.rewardWon;
    final t = state.t;

    if (won == null) {
      _shownFor = null;
      return const SizedBox.shrink();
    }
    if (_shownFor != won.amount) {
      _shownFor = won.amount;
      _in.forward(from: 0);
    }

    final size = MediaQuery.sizeOf(context);
    // Height is the scarce axis, so the panel's own padding and its hero chip
    // are measured off it, not off a literal that only fits a tall phone.
    // h=360 -> 19.8 / 30.6 / 57.6 | 411 -> 22.6 / 34.9 / 65.8 | 800 -> 28 / 44 / 68.
    final padV = (size.height * 0.055).clamp(16.0, 28.0);
    final padH = (size.height * 0.085).clamp(24.0, 44.0);
    final chip = (size.height * 0.16).clamp(40.0, 68.0);

    final blurb = switch (won.kind) {
      'bonus' => t.rewardComeBack,
      'purchase' => t.rewardPurchased,
      _ => t.rewardMilestoneAgain,
    };

    return Positioned.fill(
      child: GestureDetector(
        onTap: state.dismissReward,
        child: ColoredBox(
          color: theme.colorScheme.scrim.withValues(alpha: 0.70),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Seeded on the amount so the burst pattern is fixed while the
              // banner is up and different for the next reward.
              Fireworks(seed: won.amount, bursts: 7),
              Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: Dim.dialogW(size.width),
                  ),
                  child: AnimatedBuilder(
                    animation: _in,
                    builder: (context, child) {
                      final e = Motion.settle.transform(_in.value);
                      return Opacity(
                        opacity: Curves.easeOut.transform(_in.value),
                        child: Transform.scale(
                          scale: 0.82 + 0.18 * e,
                          child: child,
                        ),
                      );
                    },
                    // The one place a bloom is honest in the lobby: the game
                    // has just moved money.
                    child: PremiumSurface(
                      accent: AppTheme.gold,
                      radius: Radii.lg,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(padH, padV, padH, padV),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SpinningChip(
                              colour: AppTheme.gold,
                              size: chip,
                              turn: const Duration(milliseconds: 900),
                              rest: const Duration(milliseconds: 260),
                            ),
                            const SizedBox(height: Space.lg),
                            Text(
                              t.rewardCollected,
                              textAlign: TextAlign.center,
                              style: AppTheme.label(text.titleMedium!),
                            ),
                            const SizedBox(height: Space.sm),
                            Text(
                              '+ ${formatChips(won.amount)}',
                              style: AppTheme.money(
                                text.headlineMedium!,
                                colour: _goldInk(theme.brightness),
                              ),
                            ),
                            const SizedBox(height: Space.md),
                            Text(
                              blurb,
                              textAlign: TextAlign.center,
                              style: text.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: AppTheme.inkMed,
                                ),
                              ),
                            ),
                            const SizedBox(height: Space.lg),
                            FilledButton(
                              onPressed: state.dismissReward,
                              child: Text(t.tapToClose),
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
      ),
    );
  }
}

/// The ledge the lobby hangs from: the player, their balance, the four-hour
/// bonus and the three panels they can open.
///
/// It is a shelf rather than a floating row — a body that fades downwards and
/// one hairline along its foot — so the rail of cards visibly hangs beneath
/// something instead of drifting under loose text.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.user, required this.onOpen});

  final User? user;
  final void Function(BuildContext, _EndPanel) onOpen;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final brightness = theme.brightness;
    final h = MediaQuery.sizeOf(context).height;

    final pad = Dim.topRailPad(h);
    // Derived from the tallest thing inside it — the avatar with its pip, or a
    // legal touch target, whichever is larger — never the other way round:
    // h=360 -> max(54.0, 56.2) = 56.2 | 411 -> max(61.1, 58.0) = 61.1
    // | 800 -> max(72.0, 64.0) = 72.0. The content box is therefore 44.0 /
    // 47.2 / 52.0, and every control in the row is at least 44dp.
    final railH = math.max(Dim.topRailH(h), Dim.minTouch + 2 * pad);
    final avatarD = Dim.avatarD(h);

    return SizedBox(
      height: railH,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppTheme.panelBase(brightness).withValues(alpha: 0.55),
              AppTheme.panelBase(brightness).withValues(alpha: 0),
            ],
          ),
          border: Border(
            bottom: BorderSide(
              color: AppTheme.hairlineColour(brightness),
              width: Dim.hairline,
            ),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            final slotW = Dim.bonusSlotW(box.maxWidth);
            // The provider tag folds on what the row actually has left, not on
            // the screen width: 640 -> 448 (fold) | 891 -> 623.7 | 1280 -> 980.
            final tight = Breaks.isTightBar(box.maxWidth - slotW);

            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: Space.md,
                vertical: pad,
              ),
              child: Row(
                children: [
                  // Requirement 26 keeps its corner, but as a real slot rather
                  // than a 240dp pad in this bar and a literal 12dp offset in
                  // the Stack — two numbers that used to break each other.
                  SizedBox(
                    width: slotW - Space.md,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _BonusChip(maxWidth: slotW - Space.md),
                    ),
                  ),
                  Tooltip(
                    message: state.t.yourPicture,
                    child: SizedBox(
                      width: math.max(Dim.minTouch, avatarD),
                      child: InkWell(
                        // Material's own click, gated on the player's Sound switch —
                        // otherwise a silenced game would still tick on every tap.
                        enableFeedback: context.select<FeedbackSettings, bool>(
                          (f) => f.sound,
                        ),
                        customBorder: const CircleBorder(),
                        onTap: () => _openPicturePicker(context),
                        child: Center(
                          child: _AvatarWithPip(
                            url: state.avatarUrl,
                            fallback: user?.displayName ?? '',
                            diameter: avatarD,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Flexible(
                    child: Text(
                      user?.displayName ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // A player's own name, in whatever script they wrote it.
                      style: AppTheme.label(text.titleMedium!),
                    ),
                  ),
                  if (user != null && !tight) ...[
                    const SizedBox(width: Space.md),
                    _ProviderPill(provider: user!.provider),
                  ],
                  const Spacer(),
                  // The balance counts to its new value rather than snapping, so
                  // a reward landing is something you see happen.
                  RepaintBoundary(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PokerChip(colour: AppTheme.gold, size: 18),
                        const SizedBox(width: Space.sm),
                        TweenAnimationBuilder<double>(
                          tween: Tween(end: (user?.chips ?? 0).toDouble()),
                          duration: const Duration(milliseconds: 650),
                          curve: Motion.standard,
                          builder: (context, value, _) => Text(
                            formatChips(value.round()),
                            style: AppTheme.money(
                              text.titleMedium!,
                              colour: _goldInk(brightness),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  _BarActions(onOpen: onOpen),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The player's picture with the edit mark tucked into its own corner.
///
/// The mark sits inside the portrait's box rather than hanging off it, so the
/// avatar's footprint stays exactly [diameter] and the top rail's arithmetic
/// holds at every height.
class _AvatarWithPip extends StatelessWidget {
  const _AvatarWithPip({
    required this.url,
    required this.fallback,
    required this.diameter,
  });

  final String? url;
  final String fallback;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final pip = diameter * 0.34;

    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        Avatar(
          url: url,
          fallback: fallback,
          // Avatar's ring grows outwards, so the picture gives the ring back.
          radius: diameter / 2 - 1.5,
        ),
        Container(
          width: pip,
          height: pip,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.plaque(brightness),
            border: Border.all(
              color: AppTheme.hairlineColour(brightness, live: true),
              width: Dim.hairline,
            ),
          ),
          child: Icon(
            Icons.edit,
            size: pip * 0.56,
            color: _goldInk(brightness),
          ),
        ),
      ],
    );
  }
}

/// Which account the player signed in with. Metadata, not a control, so it is a
/// hairline micro-pill rather than a filled Material chip.
class _ProviderPill extends StatelessWidget {
  const _ProviderPill({required this.provider});

  /// One of the server's provider names — ASCII the client owns, which is why
  /// tracked capitals are safe here and never on a name or a translation.
  final String provider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.xs),
        border: Border.all(
          color: AppTheme.hairlineColour(theme.brightness),
          width: Dim.hairline,
        ),
      ),
      child: Text(
        provider.toUpperCase(),
        style: AppTheme.smallCaps(
          theme.textTheme.labelSmall!,
          tracking: 1.2,
          colour: theme.colorScheme.onSurface.withValues(
            alpha: AppTheme.inkLow,
          ),
        ),
      ),
    );
  }
}

/// The three panels the top rail can open, as one segmented control.
///
/// Grouped because they are one class of thing — places to go — and separated
/// from the balance beside them, which is the only gold in the bar. Sign out is
/// dropped to the quietest ink in the group: it is destructive and it should
/// not compete with the two informational buttons it sits next to.
class _BarActions extends StatelessWidget {
  const _BarActions({required this.onOpen});

  final void Function(BuildContext, _EndPanel) onOpen;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final hairline = AppTheme.hairlineColour(brightness);

    Widget key(String tip, IconData icon, VoidCallback onTap, double alpha) =>
        Tooltip(
          message: tip,
          child: SizedBox(
            width: Dim.minTouch,
            height: Dim.minTouch,
            child: InkWell(
              // Material's own click, gated on the player's Sound switch —
              // otherwise a silenced game would still tick on every tap.
              enableFeedback: context.select<FeedbackSettings, bool>(
                (f) => f.sound,
              ),
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: Icon(
                icon,
                size: 19,
                color: scheme.onSurface.withValues(alpha: alpha),
              ),
            ),
          ),
        );

    final divider = Container(
      width: Dim.hairline,
      height: Dim.minTouch * 0.44,
      color: hairline,
    );

    return Material(
      type: MaterialType.transparency,
      child: Container(
        height: Dim.minTouch,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.pill),
          color: AppTheme.plaque(
            brightness,
          ).withValues(alpha: brightness == Brightness.dark ? 0.42 : 0.55),
          border: Border.all(color: hairline, width: Dim.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            key(
              state.t.yourRecord,
              Icons.insights_outlined,
              () => onOpen(context, _EndPanel.stats),
              AppTheme.inkMed,
            ),
            divider,
            key(
              state.t.settings,
              Icons.tune_rounded,
              () => onOpen(context, _EndPanel.settings),
              AppTheme.inkMed,
            ),
            divider,
            key(state.t.signOut, Icons.logout_rounded, state.signOut, 0.42),
          ],
        ),
      ),
    );
  }
}

/// One boot table. Requirement 28: square, and lit by a sweep that runs corner
/// to corner without stopping — the one piece of motion on the card itself.
///
/// A solid lit object, not glass. Three tables that differ only in a hairline's
/// hue are three charcoal rectangles; these differ in the colour of the plate,
/// the crest bled into the corner, the wash through the body and the two-tone
/// rim, so the room a player lands in is recognisably the card they tapped.
class _TableCard extends StatelessWidget {
  const _TableCard({required this.table});

  /// The room as the server described it — stake, category and the rules the
  /// card states, all from the one source.
  final LobbyTable table;

  String get category => table.category;
  int get boot => table.bootAmount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final brightness = theme.brightness;
    final state = context.watch<GameState>();
    final t = state.t;
    final blind = category == TableCategory.blind;
    // Each table has a colour of its own — gold, sapphire, royal purple — and
    // the room the card leads to is painted in the same one.
    final palette = AppTheme.paletteFor(
      scheme,
      category: category,
      bootAmount: boot,
    );
    final accent = palette.accent;

    // Requirement 30: the cheapest blind table is for smaller stacks. The card
    // says so and refuses the tap, rather than letting the player find out from
    // the server after they have tried.
    final capped = state.cappedOut(boot, category);

    final card = Padding(
      padding: const EdgeInsets.only(right: Space.lg),
      child: AspectRatio(
        aspectRatio: 1,
        child: _Pressable(
          onTap: capped
              ? () {}
              : () {
                  // The door, then the room.
                  context.read<FeedbackSettings>().enterTable();
                  context.read<GameState>().quickJoin(boot, category);
                },
          child: LayoutBuilder(
            builder: (context, box) {
              // The card is square, so every figure on it is a fraction of one
              // number. Verified against the rail's own three sizes — the card
              // side at h=360 / 411 / 800 is 259.2 / 295.9 / 400.0 — the column
              // below asks for 212.6 / 239.5 / 269.1 of the 239.2 / 267.9 /
              // 372.0 it has, so the Spacer above the call to action always has
              // room to give and the card can never overflow.
              final s = box.maxHeight;
              final compact = s < 280;
              final pad = compact ? Space.md : Space.lg;
              final gap = (s * 0.038).clamp(8.0, 20.0);
              final plateH = (s * 0.108).clamp(24.0, 34.0);
              final bootSize = (s * 0.115).clamp(22.0, 40.0);
              final factH = (s * 0.072).clamp(17.0, 24.0);
              final ctaH = (s * 0.125).clamp(28.0, 38.0);
              final blurbSize = (s * 0.047).clamp(11.5, 15.0);

              return PremiumSurface(
                accent: capped ? scheme.outlineVariant : accent,
                glint: !capped,
                tint: capped ? null : palette.tint,
                // The card is a swatch of the room it opens: the same baize,
                // mixed by the same function, so tapping the purple card lands
                // you on purple cloth. A capped table keeps the flat panel —
                // it is not a room you can enter.
                cloth: capped ? null : accent,
                // The card wears the table's own rim instead of the house
                // bevel, and blooms for nothing: a bloom is reserved for the
                // moment the game does something.
                bevel: 0,
                bloom: 0,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Align(
                          alignment: const Alignment(1.5, -0.95),
                          child: Icon(
                            palette.icon,
                            size: s * 0.66,
                            color: accent.withValues(
                              alpha: capped
                                  ? 0.04
                                  : (brightness == Brightness.dark
                                        ? 0.10
                                        : 0.08),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.all(pad),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _CategoryBadge(
                            label: blind ? t.blind : t.seen,
                            palette: palette,
                            height: plateH,
                            // The two cards at the same stake sit side by side,
                            // so their badges are offset rather than pulsing
                            // together.
                            delay: Duration(milliseconds: blind ? 900 : 0),
                          ),
                          SizedBox(height: gap),
                          // Counts up on first paint, so the stake lands rather
                          // than simply being there.
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              LivelyChipStack(
                                size: bootSize * 0.62,
                                colours: [accent, palette.rimLow],
                              ),
                              const SizedBox(width: Space.md),
                              Expanded(
                                child: RepaintBoundary(
                                  child: TweenAnimationBuilder<double>(
                                    tween: Tween(end: boot.toDouble()),
                                    duration: const Duration(milliseconds: 700),
                                    curve: Motion.standard,
                                    builder: (context, value, _) => FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerLeft,
                                      child: Text(
                                        formatChips(value.round()),
                                        style: AppTheme.money(
                                          text.displaySmall!,
                                          fontSize: bootSize,
                                          colour: _goldInk(
                                            brightness,
                                            onCloth: !capped,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Text(
                            t.boot,
                            style: AppTheme.label(
                              text.labelSmall!,
                              colour: capped
                                  ? scheme.onSurface.withValues(
                                      alpha: AppTheme.inkLow,
                                    )
                                  : AppTheme.onFelt(
                                      brightness,
                                      alpha: AppTheme.inkLow,
                                    ),
                            ),
                          ),
                          SizedBox(height: gap),
                          Text(
                            blind ? t.onlyYourChips : t.everyoneChips,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              fontSize: blurbSize,
                              color: capped
                                  ? scheme.onSurface.withValues(
                                      alpha: AppTheme.inkMed,
                                    )
                                  : AppTheme.onFelt(brightness),
                            ),
                          ),
                          SizedBox(height: gap),

                          // What the room actually plays like, stated before the
                          // player sits down rather than discovered at the table.
                          _CardFact(
                            icon: Icons.visibility_off_rounded,
                            accent: accent,
                            label: t.maxBlindsLabel,
                            value: '${table.maxBlindMoves}',
                            height: factH,
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: Space.xs,
                            ),
                            child: Container(
                              height: Dim.hairline,
                              color: capped
                                  ? AppTheme.hairlineColour(brightness)
                                  : AppTheme.onFelt(brightness, alpha: 0.16),
                            ),
                          ),
                          _CardFact(
                            icon: Icons.savings_rounded,
                            accent: accent,
                            label: t.potLimitLabel,
                            height: factH,
                            value: table.potUncapped
                                ? t.potUnlimited
                                : formatChips(table.maxPot),
                            // An uncapped pot is the headline on a blind table,
                            // so it is the one fact drawn in the table's colour.
                            highlight: table.potUncapped,
                          ),

                          // Takes up whatever is left over, and nothing when
                          // there is nothing left over.
                          const Spacer(),
                          _SitCapsule(
                            label: t.tapToSit,
                            height: ctaH,
                            enabled: !capped,
                          ),
                        ],
                      ),
                    ),
                    // The felt's own trick, applied to a container: a rim lit
                    // along the top and shaded along the foot reads as a
                    // physical edge, and it is the one thing that keeps three
                    // cards from being one card in three hues.
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: 1.5,
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: palette.rimHigh.withValues(
                            alpha: capped ? 0.12 : 0.42,
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      height: 2,
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: palette.rimLow.withValues(
                            alpha: capped ? 0.16 : 0.50,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );

    if (!capped) return card;

    // Faded back and captioned. Translucent rather than opaque, so the stake is
    // still readable — a player should be able to see the table they are being
    // kept out of — and reserved rather than alarmed: being under the entry cap
    // is a rule of the room, not a mistake the player made.
    return Stack(
      children: [
        Opacity(opacity: 0.42, child: card),
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.only(right: Space.lg),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Space.lg),
                child: PremiumGlassPanel(
                  mode: GlassMode.tinted,
                  radius: Radii.md,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.lg,
                    vertical: Space.md,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.lock_outline_rounded,
                        size: 20,
                        color: scheme.onSurface.withValues(
                          alpha: AppTheme.inkMed,
                        ),
                      ),
                      const SizedBox(height: Space.sm),
                      Text(
                        t.cappedTitle,
                        textAlign: TextAlign.center,
                        style: AppTheme.label(text.titleSmall!),
                      ),
                      const SizedBox(height: Space.xs),
                      Text(
                        t.cappedBody.replaceFirst(
                          '{cap}',
                          formatChips(state.config.entryCapMaxChips),
                        ),
                        textAlign: TextAlign.center,
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurface.withValues(
                            alpha: AppTheme.inkMed,
                          ),
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
    );
  }
}

/// The card's one call to action, at its foot.
///
/// A hairline capsule rather than a line of coloured text: it is the only
/// action on the card and it used to read as a caption. It is not a button of
/// its own — the whole card is the target — so it carries no ink response and
/// is not held to a touch-target height.
class _SitCapsule extends StatelessWidget {
  const _SitCapsule({
    required this.label,
    required this.height,
    required this.enabled,
  });

  final String label;
  final double height;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = enabled
        ? _goldInk(theme.brightness)
        : theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkLow);

    return Container(
      height: height,
      // Full width: it is the card's foot rail, and a capsule that hugs its
      // own label reads as a caption again.
      width: double.infinity,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(
          color: AppTheme.hairlineColour(theme.brightness, live: enabled),
          width: Dim.hairline,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.label(
                theme.textTheme.labelMedium!,
                fontSize: (height * 0.36).clamp(11.0, 14.0),
                colour: ink,
              ),
            ),
          ),
          const SizedBox(width: Space.sm),
          Icon(Icons.arrow_forward_rounded, size: height * 0.44, color: ink),
        ],
      ),
    );
  }
}

/// One line of small print on a lobby card: an icon, what it is, and what it
/// is set to.
///
/// The icon carries the meaning at a glance and the value is what the eye
/// lands on, so the label between them is deliberately the quietest part. The
/// tinted icon tile it used to sit in is gone: two rounded squares of accent
/// were the fussiest pixels on the card and they competed with the plate.
class _CardFact extends StatelessWidget {
  const _CardFact({
    required this.icon,
    required this.accent,
    required this.label,
    required this.value,
    required this.height,
    this.highlight = false,
  });

  final IconData icon;
  final Color accent;
  final String label;
  final String value;

  /// The row's own box, so two rows and the rule between them are a known
  /// height on the card's column. 259.2 -> 18.7 | 295.9 -> 21.3 | 400 -> 24.0,
  /// against text that measures 15.6 / 17.8 / 18.9.
  final double height;

  /// Draws the value in the table's own colour, for the fact worth noticing.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final size = (height * 0.62).clamp(10.5, 14.0);

    return SizedBox(
      height: height,
      child: Row(
        children: [
          Icon(
            icon,
            size: height * 0.80,
            color: AppTheme.onFelt(theme.brightness, alpha: AppTheme.inkLow),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(
                fontSize: size,
                color: AppTheme.onFelt(theme.brightness),
              ),
            ),
          ),
          const SizedBox(width: Space.sm),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.money(
              text.labelLarge!,
              fontSize: size,
              colour: highlight
                  ? accent
                  : AppTheme.onFelt(theme.brightness, alpha: AppTheme.inkHigh),
            ),
          ),
        ],
      ),
    );
  }
}

/// The BLIND / SEEN plate on a lobby card.
///
/// Two things move: the chip turns over every few seconds, and a soft band of
/// light crosses the plate. It is what tells the two kinds of table apart at a
/// glance, so it is the one part of the card worth drawing the eye to —
/// everything else on the card stays still.
///
/// The label is a translated string, so it is set in its natural case: tracked
/// capitals are `toUpperCase()` plus letter-spacing, and `toUpperCase()` does
/// nothing at all to Devanagari, Bengali, Gujarati or Gurmukhi.
class _CategoryBadge extends StatefulWidget {
  const _CategoryBadge({
    required this.label,
    required this.palette,
    required this.height,
    this.delay = Duration.zero,
  });

  final String label;
  final TablePalette palette;
  final double height;

  /// Offsets this badge against the others on screen, so a row of cards does
  /// not pulse in unison — which reads as a glitch rather than a shine.
  final Duration delay;

  @override
  State<_CategoryBadge> createState() => _CategoryBadgeState();
}

class _CategoryBadgeState extends State<_CategoryBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sheen = AnimationController(
    vsync: this,
    duration: Motion.breath,
  );

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(widget.delay, () {
      if (mounted) _sheen.repeat();
    });
  }

  @override
  void dispose() {
    _sheen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final palette = widget.palette;
    final h = widget.height;
    final radius = BorderRadius.circular(Radii.sm);

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _sheen,
        builder: (context, _) {
          // One pass of light per cycle, over the first third of it; the rest
          // of the cycle the badge simply sits there.
          final pass = (_sheen.value * 3).clamp(0.0, 1.0);
          // A glow that breathes with the same beat, so the badge lifts off
          // the card as the light crosses it.
          final glow = math.sin(pass * math.pi);

          // The band crosses the whole plate rather than the letters alone.
          // Lightening the glyphs themselves fades them instead of polishing
          // them: they are dark type on a pale chip, so the light has to pass
          // over them, not through them.
          final centre = -0.3 + pass * 1.6;

          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: palette.accent.withValues(alpha: 0.30 * glow),
                  blurRadius: 12 + 8 * glow,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                children: [
                  Container(
                    height: h,
                    padding: EdgeInsets.symmetric(horizontal: h * 0.30),
                    color: palette.container,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SpinningChip(
                          colour: palette.accent,
                          size: h * 0.58,
                          delay: widget.delay,
                        ),
                        SizedBox(width: h * 0.24),
                        Flexible(
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.label(
                              theme.textTheme.labelLarge!,
                              fontSize: (h * 0.40).clamp(10.0, 14.0),
                              colour: palette.onContainer,
                              weight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withValues(alpha: 0),
                              Colors.white.withValues(
                                alpha: dark ? 0.26 : 0.40,
                              ),
                              Colors.white.withValues(alpha: 0),
                            ],
                            stops: [
                              (centre - 0.22).clamp(0.0, 1.0),
                              centre.clamp(0.0, 1.0),
                              (centre + 0.22).clamp(0.0, 1.0),
                            ],
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
    );
  }
}

/// The fourth card on the rail: a room only the player's own friends can find.
///
/// Built from the same lit surface and the same square footprint as the three
/// tables, in the house emerald rather than a table's colour, so the rail has
/// one rhythm and four identities rather than three products and a form.
class _PrivateCard extends StatefulWidget {
  const _PrivateCard();

  @override
  State<_PrivateCard> createState() => _PrivateCardState();
}

class _PrivateCardState extends State<_PrivateCard> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final brightness = theme.brightness;
    final cap = state.config.privateMaxPot;
    final accent = scheme.primary;

    return Padding(
      padding: const EdgeInsets.only(right: Space.lg),
      child: AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(
          builder: (context, box) {
            // The same three sizes as a table card. The column's fixed rows
            // total 182.3 / 185.1 / 193.0 against 239.2 / 267.9 / 372.0 of
            // content box, and the two Spacers split what is left, so the code
            // field and the keys always sit on the card's foot.
            final s = box.maxHeight;
            final compact = s < 280;
            final pad = compact ? Space.md : Space.lg;
            final gap = (s * 0.038).clamp(8.0, 20.0);

            return PremiumSurface(
              accent: accent,
              tint: brightness == Brightness.dark ? 0.10 : 0.09,
              bevel: 0,
              bloom: 0,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Align(
                        alignment: const Alignment(1.5, -0.95),
                        child: Icon(
                          Icons.vpn_key_rounded,
                          size: s * 0.66,
                          color: accent.withValues(
                            alpha: brightness == Brightness.dark ? 0.10 : 0.08,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.all(pad),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.lock_outline_rounded,
                              size: 18,
                              color: accent,
                            ),
                            const SizedBox(width: Space.sm),
                            Flexible(
                              child: Text(
                                state.t.privateTable,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTheme.label(text.titleSmall!),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: gap),
                        Text(
                          'Boot ${formatChips(state.config.privateBoot)}'
                          '${cap > 0 ? ', max win ${formatChips(cap)}' : ''}.'
                          ' Share the code to fill the seats.',
                          maxLines: compact ? 2 : 3,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurface.withValues(
                              alpha: AppTheme.inkMed,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          state.t.orJoinCode,
                          style: AppTheme.label(
                            text.labelSmall!,
                            colour: scheme.onSurface.withValues(
                              alpha: AppTheme.inkLow,
                            ),
                          ),
                        ),
                        const SizedBox(height: Space.xs),
                        SizedBox(
                          height: Dim.minTouch,
                          child: TextField(
                            controller: _code,
                            maxLength: 6,
                            textAlign: TextAlign.center,
                            textCapitalization: TextCapitalization.characters,
                            // Tabular, tracked and centred: a room code is read
                            // out loud and typed in, never scanned as a word.
                            style: AppTheme.money(
                              text.titleMedium!,
                              colour: _goldInk(brightness),
                            ).copyWith(letterSpacing: 6),
                            decoration: InputDecoration(
                              hintText: state.t.tableCode,
                              counterText: '',
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: Space.md,
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        SizedBox(height: gap),
                        Row(
                          children: [
                            Expanded(
                              child: SizedBox(
                                height: Dim.minTouch,
                                child: FilledButton(
                                  onPressed: state.createPrivate,
                                  child: Text(
                                    state.t.create,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: Space.md),
                            Expanded(
                              child: SizedBox(
                                height: Dim.minTouch,
                                child: OutlinedButton(
                                  onPressed: () => state.joinByCode(_code.text),
                                  child: Text(
                                    state.t.join,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 1.5,
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: Color.lerp(
                          accent,
                          Colors.white,
                          0.18,
                        )!.withValues(alpha: 0.42),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: 2,
                    child: IgnorePointer(
                      child: ColoredBox(
                        color: Color.lerp(
                          accent,
                          Colors.black,
                          0.34,
                        )!.withValues(alpha: 0.50),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Requirement 21: the picture is chosen from the top bar, and the server
/// refuses the change once the player is seated at a table.
Future<void> _openPicturePicker(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final text = theme.textTheme;
      final size = MediaQuery.sizeOf(sheetContext);
      // The sheet does not scroll, so the strip shrinks on a short screen
      // rather than growing: h=360 -> 79.2 | 411 -> 90.4 | 800 -> 108.0, and a
      // choice's outer circle is 2r + the ring and gap = 60.9 / 68.5 / 80.4.
      final strip = Dim.pickerH(size.height);
      final headR = (size.height * 0.055).clamp(18.0, 26.0);

      return Consumer<GameState>(
        builder: (context, state, _) {
          final user = state.user;

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.md,
                0,
                Space.md,
                Space.md,
              ),
              child: PremiumGlassPanel(
                mode: GlassMode.auto,
                priority: 20,
                radius: Radii.lg,
                padding: const EdgeInsets.fromLTRB(
                  Space.xl,
                  Space.md,
                  Space.xl,
                  Space.lg,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(Radii.pill),
                          color: AppTheme.hairlineColour(
                            theme.brightness,
                            live: true,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.md),
                    Row(
                      children: [
                        Avatar(
                          url: state.avatarUrl,
                          fallback: user?.displayName ?? '',
                          radius: headR,
                        ),
                        const SizedBox(width: Space.lg),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                state.t.yourPicture,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTheme.label(text.titleSmall!),
                              ),
                              Text(
                                user == null ||
                                        (user.avatarChoice ?? '').isEmpty
                                    ? 'Using your ${user?.provider ?? 'guest'} picture.'
                                    : state.t.pictureLocked,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: AppTheme.inkMed,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.md),
                    SizedBox(
                      height: strip,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final p in state.pictures)
                            _PictureChoice(
                              picture: p,
                              side: strip,
                              selected: user?.avatarChoice == p.id,
                              onTap: () => state.chooseAvatar(p.id),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.md),
                    // The button is always here, so a guest can see that using
                    // their own photo is something the game does — it just needs
                    // a Google or Facebook account. Hiding it would make the
                    // feature invisible to exactly the people who have not found
                    // it yet.
                    Builder(
                      builder: (context) {
                        final hasPhoto =
                            (user?.providerAvatarUrl ?? '').isNotEmpty;
                        final guest = (user?.provider ?? 'guest') == 'guest';
                        final enabled = hasPhoto && !guest;

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: enabled
                                  ? () => state.chooseAvatar(null)
                                  : null,
                              icon: const Icon(
                                Icons.account_circle_outlined,
                                size: 18,
                              ),
                              label: Text(state.t.useSocialPicture),
                            ),
                            if (!enabled) ...[
                              const SizedBox(height: Space.xs),
                              Text(
                                state.t.guestNoSocial,
                                style: text.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: AppTheme.inkLow,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
}

class _PictureChoice extends StatelessWidget {
  const _PictureChoice({
    required this.picture,
    required this.side,
    required this.selected,
    required this.onTap,
  });

  final ProfilePicture picture;

  /// The strip's height. Both states are laid out in a box this wide so the
  /// row does not shuffle sideways when the selection moves.
  final double side;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final url = context.read<GameState>().absoluteUrl(picture.url);
    // Avatar's ring and gap grow outwards, so the picture gives them back and
    // the outer circle is the same in both states.
    final radius = side * 0.34;

    return Padding(
      padding: const EdgeInsets.only(right: Space.md),
      child: InkWell(
        // Material's own click, gated on the player's Sound switch —
        // otherwise a silenced game would still tick on every tap.
        enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: side,
          child: Center(
            child: AnimatedSwitcher(
              duration: Motion.base,
              child: selected
                  ? Avatar(
                      key: const ValueKey(true),
                      url: url,
                      fallback: picture.id,
                      radius: radius,
                      ring: AppTheme.goldBright,
                      ringWidth: 2.5,
                      ringGap: 2,
                    )
                  : Avatar(
                      key: const ValueKey(false),
                      url: url,
                      fallback: picture.id,
                      radius: radius + 3,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The shell both right-hand panels share.
///
/// Not [GlassDrawerPanel]: that one aligns its body to the start edge, which is
/// right for a left drawer and would put these panels on the opposite side of
/// the screen from the edge they slide in on.
class _LobbyDrawer extends StatelessWidget {
  const _LobbyDrawer({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;

    return Drawer(
      backgroundColor: Colors.transparent,
      elevation: 0,
      // 640 -> 260.0 | 891 -> 356.4 | 1280 -> 380.0.
      width: Dim.drawerW(w),
      child: Padding(
        padding: const EdgeInsets.all(Space.sm),
        child: PremiumGlassPanel(
          mode: GlassMode.auto,
          priority: 10,
          radius: Radii.lg,
          padding: EdgeInsets.zero,
          child: SafeArea(
            // Landscape leaves very little height, so this scrolls rather than
            // overflowing — which is what was clipping the name off the top.
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: Space.md),
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}

/// A drawer's title row: a mark, what the panel is, and the way out.
class _DrawerHead extends StatelessWidget {
  const _DrawerHead({
    required this.leading,
    required this.title,
    this.subtitle,
  });

  final Widget leading;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final caption = subtitle;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.sm, Space.md),
      child: Row(
        children: [
          leading,
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.label(text.titleSmall!),
                ),
                if (caption != null)
                  Text(
                    caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(
                        alpha: AppTheme.inkLow,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: Dim.minTouch,
            height: Dim.minTouch,
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// The one rule inside a drawer. Groups are separated by this and by nothing
/// else — a divider under every row is what made the old panels read as a list
/// of settings rather than a panel.
class _DrawerRule extends StatelessWidget {
  const _DrawerRule({this.space = Space.md});

  final double space;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(Space.lg, space, Space.lg, space),
    child: Container(
      height: Dim.hairline,
      color: AppTheme.hairlineColour(Theme.of(context).brightness),
    ),
  );
}

/// One figure in the record: what it counts on the left, the number on the
/// right, tabular so six of them line up.
class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.sm,
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: scheme.onSurface.withValues(alpha: AppTheme.inkLow),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium?.copyWith(
                color: scheme.onSurface.withValues(alpha: AppTheme.inkMed),
              ),
            ),
          ),
          const SizedBox(width: Space.md),
          Text(
            value,
            style: AppTheme.money(
              text.labelLarge!,
              colour: _goldInk(theme.brightness),
            ),
          ),
        ],
      ),
    );
  }
}

/// A row in a drawer that does something. No fill and no tinted tile: a drawer
/// full of filled rows reads as a list of buttons, and only one of these is
/// ever the thing the player came in for.
class _DrawerAction extends StatelessWidget {
  const _DrawerAction({
    required this.leading,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.danger = false,
  });

  final Widget leading;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  /// Quietened rather than shouted: the two destructive rows sit next to each
  /// other and a filled red row is exactly what a mis-tap looks for.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final caption = subtitle;
    final ink = danger
        ? theme.colorScheme.error.withValues(alpha: 0.86)
        : theme.colorScheme.onSurface;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        // Material's own click, gated on the player's Sound switch —
        // otherwise a silenced game would still tick on every tap.
        enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Dim.minTouch),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.lg,
              vertical: Space.sm,
            ),
            child: Row(
              children: [
                IconTheme.merge(
                  data: IconThemeData(
                    size: 18,
                    color: danger
                        ? ink
                        : theme.colorScheme.onSurface.withValues(
                            alpha: AppTheme.inkLow,
                          ),
                  ),
                  child: leading,
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.label(
                          text.bodyMedium!,
                          colour: ink,
                          weight: FontWeight.w500,
                        ),
                      ),
                      if (caption != null)
                        Text(
                          caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withValues(
                              alpha: AppTheme.inkLow,
                            ),
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
    );
  }
}

/// The player's record, opened from the top rail. It is a drawer rather than a
/// card on the rail because it is something you look up, not something you
/// choose between.
class _StatsDrawer extends StatelessWidget {
  const _StatsDrawer();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final user = state.user;
    final t = state.t;
    final theme = Theme.of(context);

    final rows = <(IconData, String, String)>[
      (
        Icons.style_outlined,
        t.handsPlayed,
        formatChips(user?.handsPlayed ?? 0),
      ),
      (Icons.emoji_events_outlined, t.won, formatChips(user?.handsWon ?? 0)),
      (Icons.trending_down, t.lost, formatChips(user?.handsLost ?? 0)),
      (Icons.exit_to_app, t.leftMidHand, formatChips(user?.handsLeftMid ?? 0)),
      (
        Icons.savings_outlined,
        t.totalWinnings,
        formatChips(user?.totalWinnings ?? 0),
      ),
      (
        Icons.local_fire_department_outlined,
        t.biggestPot,
        formatChips(user?.biggestPot ?? 0),
      ),
    ];

    return _LobbyDrawer(
      children: [
        _DrawerHead(
          leading: Avatar(
            url: state.avatarUrl,
            fallback: user?.displayName ?? '',
            radius: 16,
          ),
          title: user?.displayName ?? '',
          subtitle: t.yourRecord,
        ),
        const _DrawerRule(space: 0),
        const SizedBox(height: Space.sm),
        for (var i = 0; i < rows.length; i++) ...[
          // The four counts of hands are one group; the two money figures are
          // another, and the rule between them is the only one in the list.
          if (i == 4) const _DrawerRule(),
          _Entrance(
            index: i,
            axis: Axis.vertical,
            child: _StatRow(
              icon: rows[i].$1,
              label: rows[i].$2,
              value: rows[i].$3,
            ),
          ),
        ],
        const _DrawerRule(),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
          child: Text(
            t.playedNote,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(
                alpha: AppTheme.inkLow,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The player's own balance written in one system, as a preview.
///
/// Their balance rather than a made-up figure: the point of the setting is how
/// their own money will read, and a sample they recognise answers that at a
/// glance.
String _sampleIn(NumberSystem system, GameState state) {
  final was = chipNumberSystem;
  chipNumberSystem = system;
  final text = formatChips(state.user?.chips ?? 1250000);
  chipNumberSystem = was;
  return text;
}

/// One choice of number format: an icon, its name, and what the player's own
/// balance looks like under it.
class _NumberOption extends StatelessWidget {
  const _NumberOption({
    required this.icon,
    required this.label,
    required this.sample,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String sample;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final brightness = theme.brightness;
    final ink = selected
        ? _goldInk(brightness)
        : scheme.onSurface.withValues(alpha: AppTheme.inkLow);

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        // Material's own click, gated on the player's Sound switch —
        // otherwise a silenced game would still tick on every tap.
        enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.base,
          curve: Motion.standard,
          constraints: const BoxConstraints(minHeight: Dim.minTouch),
          padding: const EdgeInsets.symmetric(
            horizontal: Space.md,
            vertical: Space.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.md),
            color: AppTheme.plaque(
              brightness,
            ).withValues(alpha: selected ? 0.55 : 0.28),
            border: Border.all(
              color: AppTheme.hairlineColour(brightness, live: selected),
              width: Dim.hairline,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: ink),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.label(
                        text.bodyMedium!,
                        weight: selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    Text(
                      sample,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.money(
                        text.labelMedium!,
                        colour: selected
                            ? _goldInk(brightness)
                            : scheme.onSurface.withValues(
                                alpha: AppTheme.inkLow,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedScale(
                duration: Motion.base,
                curve: Motion.settle,
                scale: selected ? 1 : 0,
                child: Icon(
                  Icons.check_circle_rounded,
                  size: 18,
                  color: _goldInk(brightness),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsDrawer extends StatefulWidget {
  const _SettingsDrawer();

  @override
  State<_SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends State<_SettingsDrawer> {
  /// Asks twice-over before deleting, and reports a refusal rather than
  /// swallowing it — the server says no while the player is seated, and a
  /// button that silently does nothing is worse than one that explains.
  Future<void> _confirmDelete(BuildContext context, GameState state) async {
    final t = state.t;
    final theme = Theme.of(context);
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => GlassDialog(
        padding: const EdgeInsets.all(Space.xl),
        title: Row(
          children: [
            Icon(
              Icons.delete_forever_outlined,
              size: 20,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                t.deleteAccountTitle,
                style: AppTheme.label(theme.textTheme.titleSmall!),
              ),
            ),
          ],
        ),
        content: Text(
          t.deleteAccountBody,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(
              alpha: AppTheme.inkMed,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(t.deleteAccountConfirm),
          ),
        ],
      ),
    );
    if (go != true) return;
    final refusal = await state.deleteAccount();
    if (!context.mounted) return;
    if (refusal != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        NoticeToast.snackBar(context, message: refusal, tone: NoticeTone.bad),
      );
      return;
    }
    // Deletion put the app back on the login screen; the drawer is over it.
    Navigator.pop(context);
  }

  late final TextEditingController _name;
  String? _nameError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
      text: context.read<GameState>().user?.displayName ?? '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Requirement 29: renaming happens here, in the lobby. The server has the
  /// final word on what a name may be, so its complaint is what gets shown
  /// rather than a second copy of the rules living in the client.
  Future<void> _save(GameState state) async {
    setState(() {
      _saving = true;
      _nameError = null;
    });

    final error = await state.renameTo(_name.text);
    if (!mounted) return;

    setState(() {
      _saving = false;
      _nameError = error;
    });

    if (error == null) {
      _name.text = state.user?.displayName ?? _name.text;
      state.say(state.t.nameSaved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final t = state.t;

    return _LobbyDrawer(
      children: [
        _DrawerHead(
          leading: Icon(
            Icons.tune_rounded,
            size: 20,
            color: _goldInk(theme.brightness),
          ),
          title: t.settings,
        ),
        const _DrawerRule(space: 0),
        const SizedBox(height: Space.md),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xs),
          child: TextField(
            controller: _name,
            maxLength: 24,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: t.displayName,
              prefixIcon: const Icon(Icons.badge_outlined, size: 18),
              counterText: '',
              isDense: true,
              errorText: _nameError,
              suffixIcon: _saving
                  ? const Padding(
                      padding: EdgeInsets.all(Space.md),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      tooltip: t.save,
                      icon: const Icon(Icons.check_rounded, size: 18),
                      onPressed: () => _save(state),
                    ),
            ),
            onSubmitted: (_) => _save(state),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.lg, 0),
          child: DropdownButtonFormField<AppLang>(
            initialValue: state.lang,
            decoration: InputDecoration(
              labelText: t.language,
              prefixIcon: const Icon(Icons.translate, size: 18),
              isDense: true,
            ),
            // Each language names itself, which is the only label a player
            // who does not read the current one can act on.
            items: [
              for (final l in AppLang.values)
                DropdownMenuItem(
                  value: l,
                  child: Text(
                    l == AppLang.english
                        ? l.nativeName
                        : '${l.nativeName}  ·  ${l.englishName}',
                  ),
                ),
            ],
            onChanged: (l) => l == null ? null : state.setLanguage(l),
          ),
        ),
        const _DrawerRule(),
        // Requirement 34: lakh and crore, or million and billion. Each option
        // previews itself with the same figure, so the choice is made by
        // looking rather than by knowing what the words mean.
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.tag,
                    size: 16,
                    color: scheme.onSurface.withValues(alpha: AppTheme.inkLow),
                  ),
                  const SizedBox(width: Space.sm),
                  Flexible(
                    child: Text(
                      t.numberSystem,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.label(
                        text.labelMedium!,
                        colour: scheme.onSurface.withValues(
                          alpha: AppTheme.inkLow,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.sm),
              for (final option in NumberSystem.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.sm),
                  child: _NumberOption(
                    icon: option == NumberSystem.indian
                        ? Icons.currency_rupee
                        : Icons.public,
                    label: option == NumberSystem.indian
                        ? t.numberIndian
                        : t.numberInternational,
                    // The same stack written both ways.
                    sample: _sampleIn(option, state),
                    selected: state.numbers == option,
                    onTap: () => state.setNumberSystem(option),
                  ),
                ),
            ],
          ),
        ),
        const _DrawerRule(space: Space.sm),
        _DrawerAction(
          leading: const Icon(Icons.menu_book_outlined),
          title: t.rules,
          subtitle: t.rulesTitle,
          onTap: () {
            Navigator.pop(context);
            showRules(context);
          },
        ),
        // Sound and vibration, as switches rather than actions: they have a
        // state the player should be able to read at a glance, which a row
        // that merely reacts to a tap does not show.
        const FeedbackToggles(),
        _DrawerAction(
          leading: AnimatedSwitcher(
            duration: Motion.slow,
            transitionBuilder: (child, anim) => RotationTransition(
              turns: Tween(begin: 0.6, end: 1.0).animate(anim),
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: Icon(
              state.themeMode == ThemeMode.dark
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
              key: ValueKey(state.themeMode),
            ),
          ),
          title: state.themeMode == ThemeMode.dark ? t.dayMode : t.nightMode,
          onTap: state.toggleTheme,
        ),
        // The two irreversible rows are pushed below a full rule and drawn in
        // one quiet red, because they sit next to each other and only one of
        // them can be undone. Google Play requires an in-app route to account
        // deletion, and this game creates an account on first launch, so every
        // player has one to delete.
        // Google's User Data policy wants the privacy policy reachable from
        // inside the app, not only from the Play listing. It opens in the
        // browser rather than a webview so the player can see the address they
        // are being shown.
        _DrawerAction(
          leading: const Icon(Icons.privacy_tip_outlined),
          title: t.privacyPolicy,
          onTap: () => launchUrl(
            Uri.parse('https://api.sungamestudio.com/privacy/'),
            mode: LaunchMode.externalApplication,
          ),
        ),
        const _DrawerRule(space: Space.lg),
        _DrawerAction(
          leading: const Icon(Icons.logout_rounded),
          title: t.signOut,
          danger: true,
          onTap: state.signOut,
        ),
        _DrawerAction(
          leading: const Icon(Icons.delete_forever_outlined),
          title: t.deleteAccount,
          danger: true,
          onTap: () => _confirmDelete(context, state),
        ),
        const _DrawerRule(),
        // Which build this is, for anyone reporting what they saw.
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.sm),
          child: Text(
            '${t.appVersion}  ${state.appVersion.isEmpty ? '…' : state.appVersion}',
            style: AppTheme.money(
              text.labelSmall!,
              colour: scheme.onSurface.withValues(alpha: AppTheme.inkLow),
              weight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

/// Fades and lifts a widget in, staggered by its place in the row, so the
/// lobby assembles itself instead of appearing all at once.
class _Entrance extends StatefulWidget {
  const _Entrance({
    required this.index,
    required this.child,
    this.axis = Axis.horizontal,
  });

  final int index;
  final Widget child;
  final Axis axis;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.enter,
  );

  @override
  void initState() {
    super.initState();
    // Capped, so a long rail does not take a noticeable age to finish.
    final delay = Duration(
      milliseconds: (widget.index * Motion.stagger.inMilliseconds).clamp(
        0,
        560,
      ),
    );
    Future<void>.delayed(delay, () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _c, curve: Motion.emphasized);
    final from = widget.axis == Axis.horizontal
        ? const Offset(0.14, 0)
        : const Offset(0, 0.25);

    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(begin: from, end: Offset.zero).animate(curved),
        child: widget.child,
      ),
    );
  }
}

/// Presses in slightly when touched, so a tap on a big card still feels like a
/// button.
class _Pressable extends StatefulWidget {
  const _Pressable({required this.child, required this.onTap});

  final Widget child;
  final VoidCallback onTap;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: Motion.instant,
        curve: Motion.standard,
        child: widget.child,
      ),
    );
  }
}

class _BonusChip extends StatelessWidget {
  const _BonusChip({this.maxWidth});

  /// The slot the top rail keeps for it. A long translated subtitle used to
  /// grow this pill under the bar; here it ellipsises instead.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final r = state.user?.rewards;
    if (r == null) return const SizedBox.shrink();

    final ready = r.bonusReady;
    return _CornerChip(
      icon: Icons.hourglass_bottom,
      leadingBuilder: (fg) => _Hourglass(colour: fg, running: !ready),
      title: state.t.fourHourBonus,
      subtitle: ready
          ? '${state.t.collect} ${formatChips(r.bonusReward)}'
          : formatCountdown(r.untilBonus),
      enabled: ready,
      maxWidth: maxWidth,
      onTap: () => state.claimReward('bonus'),
    );
  }
}

/// The bonus chip's hourglass, turning while the bonus recharges.
///
/// One cycle is: sand at the top, sand run through, then the glass is flipped
/// a half turn. Because the flip ends where the next cycle begins — a
/// "drained" glass upside down is a "full" one — the loop closes without a
/// jump, and the glass never has to be swapped mid-rotation.
///
/// When the bonus is ready it stops turning and breathes instead. A countdown
/// that has finished should not still look like it is counting; the movement
/// changes from "waiting" to "come and take it".
///
/// Drawn rather than typed: at 18dp the Material glyph is the cheapest mark in
/// the lobby, and the sand cannot fall out of a glyph.
class _Hourglass extends StatefulWidget {
  const _Hourglass({required this.colour, required this.running});

  final Color colour;
  final bool running;

  @override
  State<_Hourglass> createState() => _HourglassState();
}

class _HourglassState extends State<_Hourglass>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.breath,
  )..repeat();

  static const double _size = 18;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          if (!widget.running) {
            // Ready: a slow breath, no rotation, and a full glass.
            final breath = 1 + 0.12 * math.sin(t * 2 * math.pi);
            return Transform.scale(
              scale: breath,
              child: CustomPaint(
                size: const Size.square(_size),
                painter: _HourglassPainter(colour: widget.colour, drained: 0),
              ),
            );
          }
          // Upright for the first 72% of the cycle while the sand runs, then a
          // half turn over the last 28%.
          const flipFrom = 0.72;
          final angle = t < flipFrom
              ? 0.0
              : math.pi *
                    Motion.travel.transform((t - flipFrom) / (1 - flipFrom));

          return Transform.rotate(
            angle: angle,
            child: CustomPaint(
              size: const Size.square(_size),
              painter: _HourglassPainter(
                colour: widget.colour,
                drained: (t / flipFrom).clamp(0.0, 1.0),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HourglassPainter extends CustomPainter {
  const _HourglassPainter({required this.colour, required this.drained});

  final Color colour;

  /// How much of the sand has fallen, 0 (full) to 1 (run through).
  final double drained;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final frame = Paint()
      ..color = colour.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.075
      ..strokeJoin = StrokeJoin.round;
    final sand = Paint()..color = colour;

    const top = 0.16;
    const waist = 0.50;
    const foot = 0.84;
    const halfW = 0.30;

    Offset p(double x, double y) => Offset(x * s, y * s);

    // The two bulbs, drawn as one outline that meets at the waist.
    final glass = Path()
      ..moveTo(p(0.5 - halfW, top).dx, p(0, top).dy)
      ..lineTo(p(0.5 + halfW, top).dx, p(0, top).dy)
      ..lineTo(p(0.5, waist).dx, p(0, waist).dy)
      ..lineTo(p(0.5 + halfW, foot).dx, p(0, foot).dy)
      ..lineTo(p(0.5 - halfW, foot).dx, p(0, foot).dy)
      ..lineTo(p(0.5, waist).dx, p(0, waist).dy)
      ..close();
    canvas.drawPath(glass, frame);
    // The caps, so the glass reads as an object and not as a bow tie.
    canvas.drawLine(
      p(0.5 - halfW - 0.06, top),
      p(0.5 + halfW + 0.06, top),
      frame,
    );
    canvas.drawLine(
      p(0.5 - halfW - 0.06, foot),
      p(0.5 + halfW + 0.06, foot),
      frame,
    );

    // What is left in the upper bulb: a triangle whose apex stays at the waist.
    final level = top + (waist - top) * drained;
    if (drained < 0.995) {
      final w = halfW * (waist - level) / (waist - top);
      canvas.drawPath(
        Path()
          ..moveTo(p(0.5 - w, level).dx, p(0, level).dy)
          ..lineTo(p(0.5 + w, level).dx, p(0, level).dy)
          ..lineTo(p(0.5, waist).dx, p(0, waist).dy)
          ..close(),
        sand,
      );
    }

    // And the pile it has made below.
    if (drained > 0.005) {
      final pileTop = foot - (foot - waist) * drained;
      final w = halfW * (pileTop - waist) / (foot - waist);
      canvas.drawPath(
        Path()
          ..moveTo(p(0.5 - w, pileTop).dx, p(0, pileTop).dy)
          ..lineTo(p(0.5 + w, pileTop).dx, p(0, pileTop).dy)
          ..lineTo(p(0.5 + halfW, foot).dx, p(0, foot).dy)
          ..lineTo(p(0.5 - halfW, foot).dx, p(0, foot).dy)
          ..close(),
        sand,
      );
    }
  }

  @override
  bool shouldRepaint(_HourglassPainter old) =>
      old.colour != colour || old.drained != drained;
}

class _MilestoneChip extends StatelessWidget {
  const _MilestoneChip();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final r = state.user?.rewards;
    if (r == null) return const SizedBox.shrink();

    return _CornerChip(
      icon: Icons.emoji_events_outlined,
      title: state.t.milestone,
      subtitle: r.milestoneAvailable
          ? '${state.t.collect} ${formatChips(r.milestoneReward)}'
          : '${r.handsToNextMilestone} ${state.t.handsToGo}',
      enabled: r.milestoneAvailable,
      onTap: () => state.claimReward('milestone'),
    );
  }
}

/// A reward, waiting to be taken.
///
/// Both states carry the same body; what changes is the edge and the glow. A
/// claimable chip is legible from the corner of the eye instead of needing two
/// container colours compared side by side, and a chip that is still counting
/// down stops looking like a button that does nothing.
class _CornerChip extends StatelessWidget {
  const _CornerChip({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
    this.leadingBuilder,
    this.maxWidth,
  });

  final IconData icon;

  /// Replaces the plain [icon] when a chip wants a moving one. It is a builder
  /// rather than a widget because the foreground colour is decided here, from
  /// whether the chip is enabled.
  final Widget Function(Color colour)? leadingBuilder;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  /// A finite cap so the two lines can ellipsise. Without one this pill sizes
  /// to its longest translation and runs off the screen.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final brightness = theme.brightness;
    final gold = _goldInk(brightness);
    final fg = enabled
        ? gold
        : theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkMed);
    final cap = maxWidth ?? Dim.bonusSlotW(MediaQuery.sizeOf(context).width);

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: cap),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Radii.pill),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: gold.withValues(alpha: 0.16),
                    blurRadius: 16,
                    spreadRadius: -2,
                  ),
                ]
              : null,
        ),
        child: GlassCapsule(
          live: enabled,
          // Both states are the same size, so a chip becoming claimable does
          // not shove the row it is in.
          minHeight: Dim.minTouch,
          onTap: enabled ? onTap : null,
          padding: const EdgeInsets.symmetric(
            horizontal: Space.lg,
            vertical: Space.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              leadingBuilder?.call(fg) ?? Icon(icon, size: 18, color: fg),
              const SizedBox(width: Space.md),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.label(
                        text.labelSmall!,
                        colour: theme.colorScheme.onSurface.withValues(
                          alpha: AppTheme.inkLow,
                        ),
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.money(text.labelLarge!, colour: fg),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
