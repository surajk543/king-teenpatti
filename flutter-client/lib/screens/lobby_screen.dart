import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../settings/feedback_settings.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import '../widgets/glass_orb.dart';
import '../widgets/avatar.dart';
import '../widgets/buy_chips.dart';
import '../widgets/feedback_toggles.dart';
import '../widgets/drifting_chips.dart';
import '../widgets/fireworks.dart';
import '../widgets/glass_components.dart';
import '../widgets/glass_panels.dart';
import '../widgets/picture_shelf.dart';
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
/// shelf — the two drawers and the picture sheet, which blur, and the top bar,
/// its pill of keys and the two corner chips, which are tinted panes — and
/// never on the cards themselves, which would flatten three identities into one
/// charcoal rectangle repeated three times.
///
/// Nothing here blurs while the player is only looking: the drifting chips
/// repaint the whole background continuously, and a `BackdropFilter` over a
/// backdrop that is dirty every frame is a blur every frame.
/// Champagne reads as gold on charcoal and as mud on parchment, so every gold
/// figure in the lobby routes through here rather than naming a constant.
Color _goldInk(Brightness b) =>
    b == Brightness.dark ? AppTheme.goldBright : AppTheme.goldDeep;

/// Where a lobby card's orb sits, as a square in the card's own coordinates.
///
/// Only the first card may spill left: each card is painted after the one
/// before it, so an orb reaching left would lie on top of its neighbour rather
/// than behind it. Vertically it passes the card by no more than the rail's own
/// padding, or the rail would cut it off.
Rect _orbPlace(int index, double s) {
  final (cx, cy, d) = index == 0
      ? (0.10, 0.64, 0.74)
      : index.isOdd
      ? (0.88, 0.34, 0.74)
      : (0.90, 0.65, 0.76);
  return Rect.fromCenter(
    center: Offset(cx * s, cy * s),
    width: d * s,
    height: d * s,
  );
}

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

  /// The private card's code field. Owned here because the rail is what has
  /// to move while it has focus: the lobby is not resized for the keyboard, so
  /// the rail lifts itself instead, and only for that one field.
  final _codeFocus = FocusNode();

  /// On the code field's box, so the lift can be measured against the field
  /// itself rather than guessed from the card's layout.
  final _codeField = GlobalKey();

  /// On the private card, the box the code field is measured against.
  final _privateCard = GlobalKey();

  @override
  void dispose() {
    _codeFocus.dispose();
    super.dispose();
  }

  /// How far below the private card's top edge its code field starts, or null
  /// while either has no layout to measure.
  ///
  /// Measured against the card, never against the screen. The way to the
  /// screen runs through the rail's sliver, and once the card has scrolled out
  /// of view — kept alive only because its field still holds focus — the
  /// sliver paints it with a zero transform. The point came back NaN, the lift
  /// became NaN and stayed NaN, and the rail's Transform took the lobby down:
  /// the rail vanished under a flood of "invalid matrix" errors, and then the
  /// engine crashed. Where the card itself sits is known from the rail's own
  /// layout, so this distance inside it is all that is measured.
  double? _codeFieldInCard() {
    final field = _codeField.currentContext?.findRenderObject();
    final card = _privateCard.currentContext?.findRenderObject();
    if (field is! RenderBox ||
        card is! RenderBox ||
        !field.attached ||
        !field.hasSize ||
        !card.hasSize) {
      return null;
    }
    final dy = field.localToGlobal(Offset.zero, ancestor: card).dy;
    return dy.isFinite ? dy : null;
  }

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

    // The milestone chip's height, measured from the two lines it holds at the
    // current text scale: the rail keeps a band this tall clear at its foot,
    // so the cards end above the chip instead of running under it.
    final text = Theme.of(context).textTheme;
    final scaler = MediaQuery.textScalerOf(context);
    double line(TextStyle? style) =>
        (scaler.scale(style?.fontSize ?? 14) * (style?.height ?? 1.2))
            .ceilToDouble();
    final band =
        math.max(
          Dim.minTouch,
          line(text.labelSmall) + line(text.labelLarge) + 2 * Space.sm,
        ) +
        Space.xs;
    // The system inset under the lobby's SafeArea, read out here because the
    // SafeArea takes it out of the MediaQuery its children see.
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final screenH = MediaQuery.sizeOf(context).height;

    return Scaffold(
      key: state.lobbyScaffold,
      // The ground paints the page; the Scaffold's own flat surface would sit
      // between the two and cancel the vignette.
      backgroundColor: Colors.transparent,
      // Never resized for the keyboard, as the table is not. Resized, the body
      // squeezed the rail into a strip whose cards painted overflow stripes,
      // and the rail's scroll offset was clamped to the shrunken extent, so it
      // jumped back when the keyboard closed and left the private card a
      // sliver. The Settings drawer and the code field clear the keyboard
      // themselves.
      resizeToAvoidBottomInset: false,
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
                    // The milestone chip's band stays clear under the rail.
                    // Floated over it, the chip covered the lower half of Join
                    // and "Tap to sit down" and took the taps aimed at them.
                    child: Padding(
                      padding: EdgeInsets.only(bottom: band),
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final h = MediaQuery.sizeOf(context).height;
                          // The cards are square, so their height sets their
                          // width; on a tablet an uncapped card grows until two
                          // of them fill the screen. The rail is derived from the
                          // card plus its own padding rather than the other way
                          // round, so the card is never squeezed by the rail.
                          // The card's ceiling is h=360 -> 259.2 | h=411 -> 295.9
                          // | h=800 -> 400.0; with the chip's band off the height
                          // the two phones get about 231 and 273.
                          final side = math.min(
                            math.max(box.maxHeight - Space.xl, 0),
                            Dim.lobbyCardSide(h),
                          );

                          final rail = Center(
                            child: SizedBox(
                              height: side + Space.xl,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                // Holds its place while the cards change size
                                // under it (_KeepsPlacePhysics).
                                physics: const _KeepsPlacePhysics(),
                                padding: const EdgeInsets.fromLTRB(
                                  Space.xl,
                                  Space.md,
                                  Space.xl,
                                  Space.md,
                                ),
                                children: [
                                  // The server decides which rooms exist; the
                                  // lobby decides the order a player meets them
                                  // in. Seen first — it is where the game is
                                  // explained — then the tables they can sit at
                                  // today, then the ones shut to their stack,
                                  // and the private card last. Putting a
                                  // padlocked card between two open ones makes a
                                  // player scroll past a wall to find the room
                                  // they are actually allowed into; putting them
                                  // at the end turns the same cards into the
                                  // thing to play towards.
                                  for (final (i, table) in _orderedTables(
                                    state,
                                  ).indexed)
                                    entering(
                                      _TableCard(table: table, index: i),
                                    ),
                                  entering(
                                    _PrivateCard(
                                      key: _privateCard,
                                      codeFocus: _codeFocus,
                                      codeFieldKey: _codeField,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );

                          // While the code field has focus the rail rises far
                          // enough for the card's foot — the field and its
                          // keys — to clear the keyboard, which the lobby no
                          // longer makes room for by shrinking. Never so far
                          // that the field leaves the top of the screen: on a
                          // 360dp phone the keyboard leaves about 110dp, less
                          // than the field and the keys need together, and the
                          // field is what shows the code being typed (the
                          // keyboard's Enter joins).
                          return ListenableBuilder(
                            listenable: _codeFocus,
                            child: rail,
                            builder: (context, child) {
                              var lift = 0.0;
                              final fieldInCard = _codeFocus.hasFocus
                                  ? _codeFieldInCard()
                                  : null;
                              if (fieldInCard != null) {
                                final keyboard = MediaQuery.viewInsetsOf(
                                  context,
                                ).bottom;
                                // The card's foot, as a height above the
                                // bottom of the screen, and so its top and
                                // the field's, all at rest: the rail is
                                // centred in its box and the card fills the
                                // rail but for the list's padding. Worked out
                                // rather than measured, so the lift is never
                                // read back from a rail it has already moved.
                                final footClear =
                                    safeBottom +
                                    band +
                                    (box.maxHeight - side - Space.xl) / 2 +
                                    Space.md;
                                final fieldTop =
                                    screenH - footClear - side + fieldInCard;
                                lift = math.min(
                                  keyboard + Space.md - footClear,
                                  fieldTop - Space.md,
                                );
                              }
                              // Written so that NaN fails it as well: a
                              // non-finite offset in this Transform is what
                              // blanked the rail and crashed the engine.
                              if (!(lift > 0) || !lift.isFinite) lift = 0;
                              return Transform.translate(
                                offset: Offset(0, -lift),
                                child: child,
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
              // The daily bonus in the bottom-left corner (owner, 14 Sep 2026:
              // it was a chip leading the top bar), a key that counts down its
              // 24 hours and collects when they are up. Keyed so a lobby toast
              // can stand clear of it (lobbyNoticeArea).
              Positioned(
                bottom: Space.md,
                left: Space.md,
                child: _BonusChip(key: _bonusChip),
              ),
              // Requirement 27: the milestone sits in the bottom-right corner,
              // opposite the daily bonus. The rail of tables stops short of
              // both (`band`), so no card's keys run under either.
              Positioned(
                bottom: Space.md,
                right: Space.md,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  // Keyed so a lobby toast can stand clear of it
                  // (lobbyNoticeArea).
                  children: [_MilestoneChip(key: _milestoneChip)],
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

/// The rail's physics: the platform's own, except that the rail keeps its
/// place when its cards change size.
///
/// The cards are sized from the height the lobby has, and that height moves
/// with nobody touching the rail: while the soft keyboard opens or closes,
/// Android shows the navigation bar for a moment, the SafeArea takes its 24dp
/// off the bottom, and every card shrinks and grows back. The rail's end came
/// in with the cards, the offset was clamped to the nearer end, and nothing
/// put it back when they grew: a player at the private card who touched its
/// code field was left 120dp short of it, Join cut off at the screen's edge.
/// At rest the offset now keeps its share of the travel instead — the end
/// stays the end, the start the start, and a place in between returns exactly
/// where it was.
class _KeepsPlacePhysics extends ScrollPhysics {
  const _KeepsPlacePhysics({super.parent});

  @override
  _KeepsPlacePhysics applyTo(ScrollPhysics? ancestor) =>
      _KeepsPlacePhysics(parent: buildParent(ancestor));

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final oldTravel = oldPosition.maxScrollExtent - oldPosition.minScrollExtent;
    final newTravel = newPosition.maxScrollExtent - newPosition.minScrollExtent;
    final resized =
        oldPosition.minScrollExtent != newPosition.minScrollExtent ||
        oldPosition.maxScrollExtent != newPosition.maxScrollExtent;
    final inRange =
        oldPosition.pixels >= oldPosition.minScrollExtent &&
        oldPosition.pixels <= oldPosition.maxScrollExtent;
    // A drag or a fling owns the offset, and an overscroll is the platform's
    // to settle; this speaks only for a rail at rest.
    if (isScrolling ||
        velocity != 0 ||
        !resized ||
        !inRange ||
        oldTravel <= 0 ||
        newTravel < 0) {
      return super.adjustPositionForNewDimensions(
        oldPosition: oldPosition,
        newPosition: newPosition,
        isScrolling: isScrolling,
        velocity: velocity,
      );
    }
    // From the old metrics alone, so the layout pass that follows the
    // correction arrives at the same number and the rail settles at once.
    final share =
        (oldPosition.pixels - oldPosition.minScrollExtent) / oldTravel;
    return newPosition.minScrollExtent + share * newTravel;
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
    // A Premium Package has a line more to show — the missiles and hammers
    // under its chips — and on a 360dp phone at the 1.25 text ceiling that
    // line is paid for by a smaller hero chip and a tighter gap under it.
    final premium = won.kind == 'premium';
    // The daily bonus has that line too, for its hammer (owner, 14 Sep 2026).
    final wallets = premium || won.hammers > 0;
    final chip = (size.height * 0.16).clamp(40.0, 68.0) * (wallets ? 0.75 : 1);

    final blurb = switch (won.kind) {
      'bonus' => t.rewardComeBack,
      'purchase' => t.rewardPurchased,
      'premium' => t.rewardPremiumPurchased,
      'diamonds' => t.rewardDiamondsPurchased,
      'hammers' => t.rewardHammersPurchased,
      'missiles' => t.rewardMissilesTraded(won.amount),
      _ => t.rewardMilestoneAgain,
    };
    // The ink of the soft wallet that filled, or null for chips — which keep
    // the spinning chip and the gold.
    final softInk = switch (won.kind) {
      'diamonds' => diamondInkOn(theme.brightness),
      'hammers' => hammerInkOn(theme.brightness),
      'missiles' => missileInkOn(theme.brightness),
      _ => null,
    };
    final softIcon = switch (won.kind) {
      'hammers' => Icons.hardware,
      'missiles' => missileIcon,
      _ => Icons.diamond,
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
                            // A gem for diamonds, a hammer for hammers, the
                            // spinning chip for chips: the hero says which
                            // wallet just filled.
                            softInk != null
                                ? Icon(softIcon, size: chip, color: softInk)
                                : SpinningChip(
                                    colour: AppTheme.gold,
                                    size: chip,
                                    turn: const Duration(milliseconds: 900),
                                    rest: const Duration(milliseconds: 260),
                                  ),
                            SizedBox(height: wallets ? Space.md : Space.lg),
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
                                colour: softInk ?? _goldInk(theme.brightness),
                              ),
                            ),
                            // A Premium Package's chips are the headline; the
                            // missiles and hammers that came with them follow,
                            // each in its wallet's mark and ink — as the daily
                            // bonus's hammer does.
                            if (wallets) ...[
                              const SizedBox(height: Space.xs),
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: Space.lg,
                                runSpacing: Space.xs,
                                children: [
                                  for (final (icon, ink, label) in [
                                    if (premium)
                                      (
                                        missileIcon,
                                        missileInkOn(theme.brightness),
                                        t.plusMissiles(won.missiles),
                                      ),
                                    (
                                      Icons.hardware,
                                      hammerInkOn(theme.brightness),
                                      t.plusHammers(won.hammers),
                                    ),
                                  ])
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(icon, size: 20, color: ink),
                                        const SizedBox(width: Space.xs),
                                        Text(
                                          label,
                                          style: AppTheme.money(
                                            text.titleMedium!,
                                            colour: ink,
                                          ),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ],
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
                            GlassButton(
                              style: GlassButtonStyle.primary,
                              onPressed: state.dismissReward,
                              label: t.tapToClose,
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
/// It is a shelf rather than a floating row — a pane of tinted glass that fades
/// downwards, a sheen along its top and one hairline along its foot — so the
/// rail of cards visibly hangs beneath something instead of drifting under
/// loose text. Tinted, never blurred: the chips drift under it every frame.
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
    final glass = GlassColors.of(context);
    final dark = brightness == Brightness.dark;
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
          // The glass fill, strongest along the top and gone by the foot, so
          // the shelf reads as a pane laid over the room rather than a bar.
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [glass.fillStrong, glass.fill.withValues(alpha: 0)],
          ),
          border: Border(
            bottom: BorderSide(
              color: dark ? glass.borderTop : glass.borderBottom,
              width: Dim.hairline,
            ),
          ),
        ),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            // The sheen along the top edge every glass pane carries.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 2,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        glass.highlight.withValues(alpha: 0),
                        glass.highlight,
                        glass.highlight.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            LayoutBuilder(
              builder: (context, box) {
                // The provider tag folds on what the row actually has left,
                // not on the screen width. It matters more now that the Shop
                // key shares this bar: on a 640dp screen the tag was rendering
                // as "GUE…", which tells nobody anything — better absent than
                // truncated. The bar leads with the picture: the daily bonus
                // that sat before it moved to the lobby's bottom-left corner
                // (owner, 14 Sep 2026).
                final tight = Breaks.isTightBar(box.maxWidth);

                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: Space.md,
                    vertical: pad,
                  ),
                  child: Row(
                    children: [
                      Tooltip(
                        message: state.t.yourPicture,
                        child: SizedBox(
                          width: math.max(Dim.minTouch, avatarD),
                          child: PressScale(
                            child: InkWell(
                              // Material's own click, gated on the player's Sound
                              // switch — otherwise a silenced game would still
                              // tick on every tap.
                              enableFeedback: context
                                  .select<FeedbackSettings, bool>(
                                    (f) => f.sound,
                                  ),
                              customBorder: const CircleBorder(),
                              onTap: () => openPicturePicker(context),
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
                      ),
                      const SizedBox(width: Space.md),
                      // The name and the balance share what the fixed keys leave,
                      // and the balance is the one that knows its size: it takes
                      // its natural width, scaling down only past 65% of that (half
                      // on a tight bar), and the name gets everything else — so it
                      // ellipsises only once it has truly run out. As a Flexible
                      // beside a Spacer and a flex-4 balance the name was handed
                      // a sixth of the free space and cut to "Gu…" next to a gap.
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, room) => Row(
                            children: [
                              // The name over the provider tag rather than beside
                              // it. Side by side they competed for one line, and
                              // the tag — which says something the player already
                              // knows — was winning: the name ellipsised to "Gue…"
                              // on a Pixel while GUEST sat beside it at full width.
                              // Stacked, the name gets the room and the tag becomes
                              // the footnote it is.
                              Expanded(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      user?.displayName ?? '',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      // A player's own name, in whatever script
                                      // they wrote it.
                                      style: AppTheme.label(text.titleMedium!),
                                    ),
                                    if (user != null && !tight)
                                      _ProviderPill(
                                        provider: user!.provider,
                                        compact: true,
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: Space.md),
                              // The balance counts to its new value rather than
                              // snapping, so a reward landing is something you see
                              // happen. Past its cap it scales down (FittedBox),
                              // and it is full size wherever it fits.
                              //
                              // The chips on one line, the diamonds and hammers
                              // in small type under them (14 Sep 2026). All three
                              // in a row made the balance wider than the chips
                              // alone by two figures and two icons: on a 640dp
                              // phone, where it was already at its cap, the chip
                              // figure shrank to about half size (0.73 -> 0.54 of
                              // titleMedium for 1.99 Lakh), and on wider bars,
                              // where it was not, it took the extra width from
                              // the name. Stacked, the balance is only as wide as
                              // its chip line, so the name keeps every letter it
                              // had before hammers came to the bar.
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth:
                                      room.maxWidth * (tight ? 0.5 : 0.65),
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: RepaintBoundary(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            PokerChip(
                                              colour: AppTheme.gold,
                                              size: 18,
                                            ),
                                            const SizedBox(width: Space.sm),
                                            _CountUp(
                                              value: user?.chips ?? 0,
                                              format: formatChips,
                                              style: AppTheme.money(
                                                text.titleMedium!,
                                                colour: _goldInk(brightness),
                                              ),
                                            ),
                                          ],
                                        ),
                                        // The second and third wallets: diamonds
                                        // pay for what chips cannot and hammers
                                        // for a Force Sideshow (owner, 13 Sep
                                        // 2026), so a player sees both without
                                        // opening the store — the lobby is where
                                        // they decide whether to buy more before
                                        // sitting down. Each in its own ink.
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.diamond,
                                              size: 13,
                                              color: diamondInkOn(brightness),
                                            ),
                                            const SizedBox(width: Space.xxs),
                                            _CountUp(
                                              value: user?.diamond ?? 0,
                                              style: AppTheme.money(
                                                text.labelMedium!,
                                                colour: diamondInkOn(
                                                  brightness,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: Space.md),
                                            Icon(
                                              Icons.hardware,
                                              size: 13,
                                              color: hammerInkOn(brightness),
                                            ),
                                            const SizedBox(width: Space.xxs),
                                            _CountUp(
                                              value: user?.hammer ?? 0,
                                              style: AppTheme.money(
                                                text.labelMedium!,
                                                colour: hammerInkOn(brightness),
                                              ),
                                            ),
                                            // Missiles, which fire at the
                                            // table (owner, 14 Sep 2026).
                                            const SizedBox(width: Space.md),
                                            Icon(
                                              missileIcon,
                                              size: 13,
                                              color: missileInkOn(brightness),
                                            ),
                                            const SizedBox(width: Space.xxs),
                                            _CountUp(
                                              value: user?.missile ?? 0,
                                              style: AppTheme.money(
                                                text.labelMedium!,
                                                colour: missileInkOn(
                                                  brightness,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.md),
                      // The way to more chips, next to the count of them. It
                      // used to be a pill in the bottom-right corner, where it
                      // sat under the table rail and competed with the
                      // milestone chip for the same corner.
                      // Icon-only on a tight bar, so the name keeps its letters.
                      ShopButton(compact: tight),
                      const SizedBox(width: Space.md),
                      _BarActions(onOpen: onOpen),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// A wallet figure in the top bar, counting to its new value rather than
/// snapping to it, so a reward or a purchase landing is something you see
/// happen.
class _CountUp extends StatelessWidget {
  const _CountUp({required this.value, required this.style, this.format});

  final int value;
  final TextStyle style;

  /// How the figure is written; plain digits when null.
  final String Function(int)? format;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(end: value.toDouble()),
    duration: const Duration(milliseconds: 650),
    curve: Motion.standard,
    builder: (context, v, _) =>
        Text(format?.call(v.round()) ?? '${v.round()}', style: style),
  );
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
    final glass = GlassColors.of(context);
    final pip = diameter * 0.34;

    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        Avatar(
          url: url,
          fallback: fallback,
          // Avatar's ring grows outwards, so the picture gives the ring back.
          radius: diameter / 2 - 1.5,
          // The player's own picture plays where they see it in the lobby: an
          // animated one they paid for, frozen on its first frame in the one
          // place they look at it most, read as broken.
          animate: true,
        ),
        Container(
          width: pip,
          height: pip,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // The glass fill laid over the plaque: it sits on a photograph, so
            // a fill that let the picture through would lose the mark.
            color: Color.alphaBlend(
              glass.fillStrong,
              AppTheme.plaque(brightness),
            ),
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
/// hairline micro-pill of tinted glass rather than a filled Material chip.
class _ProviderPill extends StatelessWidget {
  const _ProviderPill({required this.provider, this.compact = false});

  /// One of the server's provider names — ASCII the client owns, which is why
  /// tracked capitals are safe here and never on a name or a translation.
  final String provider;

  /// Under the name in the top bar rather than beside it: smaller, and with
  /// the plaque dropped. Two stacked outlines under a name is a stack of
  /// boxes; at this size the tracked capitals are label enough on their own.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final dark = theme.brightness == Brightness.dark;

    // A guest is named in the player's language (it read "GUEST" in every
    // language, QA 14 Sep 2026); a provider keeps its brand name. Tracked
    // capitals in English only: spread over Devanagari or Gurmukhi they pull
    // the vowel signs off their letters.
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    final english = lang == AppLang.english;
    final name = provider == 'guest'
        ? Strings(lang).providerGuest
        : provider.isEmpty
        ? ''
        : '${provider[0].toUpperCase()}${provider.substring(1)}';
    final label = Text(
      english ? name.toUpperCase() : name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTheme.smallCaps(
        theme.textTheme.labelSmall!,
        tracking: english ? (compact ? 0.9 : 1.2) : 0,
        colour: theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkLow),
      ).copyWith(fontSize: compact ? 9 : null, height: compact ? 1.1 : null),
    );

    if (compact) return label;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.xs),
        color: glass.fill,
        border: Border.all(
          color: dark ? glass.borderTop : glass.borderBottom,
          width: Dim.hairline,
        ),
      ),
      child: label,
    );
  }
}

/// Signing out drops the player on the login screen, so it asks first, the way
/// quitting and leaving a table do. The top bar's key sits one tap from
/// Settings and used to sign a player out with no question at all (QA 14 Sep
/// 2026) — and a guest who then played on without typing a name came back
/// under a fresh guest name.
Future<void> _confirmSignOut(BuildContext context, GameState state) async {
  final theme = Theme.of(context);
  final t = state.t;
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: Row(
        children: [
          Icon(
            Icons.logout_rounded,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              t.signOutQ,
              style: AppTheme.label(
                theme.textTheme.titleMedium ?? const TextStyle(),
              ),
            ),
          ),
        ],
      ),
      content: Text(
        t.signOutBody,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkMed),
        ),
      ),
      actions: [
        GlassButton(
          style: GlassButtonStyle.text,
          label: t.cancel,
          onPressed: () => Navigator.pop(context, false),
        ),
        GlassButton(
          style: GlassButtonStyle.primary,
          label: t.signOut,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    ),
  );
  if (yes == true) await state.signOut();
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
    final glass = GlassColors.of(context);
    final dark = theme.brightness == Brightness.dark;

    Widget key(String tip, IconData icon, VoidCallback onTap, double alpha) =>
        Tooltip(
          message: tip,
          child: SizedBox(
            width: Dim.minTouch,
            height: Dim.minTouch,
            child: PressScale(
              child: InkWell(
                // Material's own click, gated on the player's Sound switch —
                // otherwise a silenced game would still tick on every tap.
                enableFeedback: context.select<FeedbackSettings, bool>(
                  (f) => f.sound,
                ),
                // The caller's own callback, unchanged: the light haptic comes
                // from the PressScale above, which fires it on release.
                onTap: onTap,
                customBorder: const CircleBorder(),
                child: Icon(
                  icon,
                  size: 19,
                  color: scheme.onSurface.withValues(alpha: alpha),
                ),
              ),
            ),
          ),
        );

    final divider = Container(
      width: Dim.hairline,
      height: Dim.minTouch * 0.44,
      color: dark ? glass.borderTop : glass.borderBottom,
    );

    // A pill of tinted glass: the fill, the 1px top-to-bottom hairline and no
    // blur — the chips drift under it.
    return Material(
      type: MaterialType.transparency,
      child: CustomPaint(
        foregroundPainter: GlassHairline(
          radius: Radii.pill,
          colors: [glass.borderTop, glass.borderBottom],
        ),
        child: Container(
          height: Dim.minTouch,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.pill),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [glass.fillStrong, glass.fill],
            ),
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
              key(
                state.t.signOut,
                Icons.logout_rounded,
                () => _confirmSignOut(context, state),
                0.42,
              ),
            ],
          ),
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
/// The menu in the order the lobby shows it: seen, then joinable, then shut.
///
/// Bucketed rather than sorted because Dart's List.sort is not stable, and
/// within each group the server's own order is the one to keep — it decides
/// which stake comes before which.
List<LobbyTable> _orderedTables(GameState state) {
  final seen = <LobbyTable>[];
  final open = <LobbyTable>[];
  final shut = <LobbyTable>[];
  for (final table in state.config.tables) {
    if (table.category == TableCategory.seen) {
      seen.add(table);
    } else if (state.tableShut(table)) {
      shut.add(table);
    } else {
      open.add(table);
    }
  }
  return [...seen, ...open, ...shut];
}

class _TableCard extends StatelessWidget {
  const _TableCard({required this.table, required this.index});

  /// The room as the server described it — stake, category and the rules the
  /// card states, all from the one source.
  final LobbyTable table;

  /// Where the card sits in the rail, which decides where its orb sits.
  final int index;

  String get category => table.category;
  int get boot => table.bootAmount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final brightness = theme.brightness;
    final glass = GlassColors.of(context);
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

    // The blind ladder is banded by stack: a table can be shut because the
    // player has outgrown it or because they have not grown into it yet. The
    // numbers come from the server with the menu, so the card cannot state
    // terms the door does not enforce — and the door is what enforces them;
    // refusing the tap here only saves the player a pointless round trip.
    //
    // cappedOut is kept as a second source for the oldest rule (requirement
    // 30's ENTRY_CAP_*), so a server that sends no band still shuts the
    // cheapest blind table to a big stack.
    final chips = state.user?.chips ?? 0;
    // Shut, and which way: a stack under the floor gets the rising arrow and
    // something to aim at, anything else gets the padlock.
    final locked = table.tooPoor(chips);
    final shut = state.tableShut(table);

    // What the door asks for, stated on every card — including the ones that
    // ask for nothing, because "open to all" is itself worth knowing when the
    // card beside it is not.
    // A server that predates the band sends none, and the only limit it knows
    // is the old ENTRY_CAP_* one. Reading that here keeps the card honest in
    // the window between shipping this build and deploying that server —
    // otherwise the cheapest blind table would be refused by cappedOut while
    // its own card said "Open to all".
    final int ceiling = table.maxChips > 0
        ? table.maxChips
        : (state.cappedOut(boot, category) ? state.config.entryCapMaxChips : 0);
    final String entryValue;
    if (ceiling > 0) {
      entryValue = t.entryUpTo.replaceFirst('{cap}', formatChips(ceiling));
    } else if (table.minChips > 0) {
      entryValue = t.entryFrom.replaceFirst(
        '{min}',
        formatChips(table.minChips),
      );
    } else {
      entryValue = t.entryOpen;
    }

    final card = Padding(
      padding: const EdgeInsets.only(right: Space.lg),
      child: AspectRatio(
        aspectRatio: 1,
        child: _Pressable(
          onTap: shut
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

              // Glass, not the table's cloth (owner's decision, 11 Sep 2026): the
              // lobby sits on the same obsidian / frosted-ice ground as every
              // other covering surface, and the stake, the badge and the chips
              // carry the table's colour instead of a whole painted card.
              // Tinted rather than blurred: the drifting chips behind the rail
              // move every frame, and a live blur there would be three
              // full-card blurs per frame on the one GlassBudget lease.
              final colours = orbColours(accent);
              final orb = _orbPlace(index, s);
              final dark = brightness == Brightness.dark;
              final panel = PremiumGlassPanel(
                mode: GlassMode.tinted,
                padding: EdgeInsets.zero,
                // Frosted: the theme's panel lifted toward white, the grey a
                // dark room turns behind real glass.
                tint: shut ? null : Colors.white,
                behind: shut
                    ? null
                    : Stack(
                        children: [
                          Positioned.fromRect(
                            rect: orb,
                            child: GlassOrb(
                              colours: colours,
                              size: orb.width,
                              soft: true,
                              opacity: dark ? 0.62 : 0.46,
                            ),
                          ),
                        ],
                      ),
                child: Stack(
                  children: [
                    Padding(
                      padding: EdgeInsets.all(pad),
                      child: LayoutBuilder(
                        builder: (context, inner) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Everything above the call to action is allowed
                            // the height the capsule leaves and no more, and
                            // scales down rather than overflowing past it. The
                            // rows are sized from the card, but their text is
                            // set in the player's script, and Devanagari
                            // stands taller than Latin: the shut BLIND 10 Lakh
                            // card on a 640dp phone ran 0.665px past its foot
                            // in Hindi and striped its key. Wherever it fits
                            // the scale is 1 and nothing moves.
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: math.max(
                                  0.0,
                                  inner.maxHeight - ctaH,
                                ),
                              ),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.topLeft,
                                child: SizedBox(
                                  width: inner.maxWidth,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _CategoryBadge(
                                        label: blind ? t.blind : t.seen,
                                        palette: palette,
                                        height: plateH,
                                        // The two cards at the same stake sit side by side,
                                        // so their badges are offset rather than pulsing
                                        // together.
                                        delay: Duration(
                                          milliseconds: blind ? 900 : 0,
                                        ),
                                      ),
                                      SizedBox(height: gap),
                                      // Counts up on first paint, so the stake lands rather
                                      // than simply being there.
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          LivelyChipStack(
                                            size: bootSize * 0.62,
                                            colours: [accent, palette.rimLow],
                                          ),
                                          const SizedBox(width: Space.md),
                                          Expanded(
                                            child: RepaintBoundary(
                                              child: TweenAnimationBuilder<double>(
                                                tween: Tween(
                                                  end: boot.toDouble(),
                                                ),
                                                duration: const Duration(
                                                  milliseconds: 700,
                                                ),
                                                curve: Motion.standard,
                                                builder: (context, value, _) =>
                                                    FittedBox(
                                                      fit: BoxFit.scaleDown,
                                                      alignment:
                                                          Alignment.centerLeft,
                                                      child: Text(
                                                        formatChips(
                                                          value.round(),
                                                        ),
                                                        style: AppTheme.money(
                                                          text.displaySmall!,
                                                          fontSize: bootSize,
                                                          colour: _goldInk(
                                                            brightness,
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
                                          colour: glass.textMuted,
                                        ),
                                      ),
                                      SizedBox(height: gap),
                                      Text(
                                        blind
                                            ? t.onlyYourChips
                                            : t.everyoneChips,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: text.bodySmall?.copyWith(
                                          fontSize: blurbSize,
                                          color: glass.textBody,
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
                                          color: AppTheme.hairlineColour(
                                            brightness,
                                          ),
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
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: Space.xs,
                                        ),
                                        child: Container(
                                          height: Dim.hairline,
                                          color: AppTheme.hairlineColour(
                                            brightness,
                                          ),
                                        ),
                                      ),
                                      _CardFact(
                                        icon: Icons
                                            .account_balance_wallet_rounded,
                                        accent: accent,
                                        label: t.entryLabel,
                                        value: entryValue,
                                        height: factH,
                                        // A floor is the fact that makes a table
                                        // aspirational, so it is worth the colour.
                                        highlight: table.minChips > 0,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            // Takes up whatever is left over, and nothing when
                            // there is nothing left over.
                            const Spacer(),
                            _SitCapsule(
                              label: t.tapToSit,
                              height: ctaH,
                              enabled: !shut,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );

              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // The sharp orb, behind the card. Its softened twin is in the
                  // glass's `behind` slot at the same place.
                  if (!shut)
                    Positioned.fromRect(
                      rect: orb,
                      child: IgnorePointer(
                        child: GlassOrb(
                          colours: colours,
                          size: orb.width,
                          opacity: dark ? 1.0 : 0.9,
                        ),
                      ),
                    ),
                  panel,
                ],
              );
            },
          ),
        ),
      ),
    );

    if (!shut) return card;

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
                        locked
                            ? Icons.trending_up_rounded
                            : Icons.lock_outline_rounded,
                        size: 20,
                        color: scheme.onSurface.withValues(
                          alpha: AppTheme.inkMed,
                        ),
                      ),
                      const SizedBox(height: Space.sm),
                      Text(
                        locked ? t.lockedTitle : t.cappedTitle,
                        textAlign: TextAlign.center,
                        style: AppTheme.label(text.titleSmall!),
                      ),
                      const SizedBox(height: Space.xs),
                      Text(
                        locked
                            ? t.lockedBody.replaceFirst(
                                '{min}',
                                formatChips(table.minChips),
                              )
                            : t.cappedBody.replaceFirst(
                                '{cap}',
                                formatChips(
                                  table.maxChips > 0
                                      ? table.maxChips
                                      : state.config.entryCapMaxChips,
                                ),
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
    // Near-white rather than gold once there is a lit pane behind it: gold on
    // glass on a brown card is three warm layers deep and the label was the
    // one losing. Gold stays everywhere else on the card, so this reads as the
    // action rather than as another value.
    final ink = enabled
        ? GlassColors.of(context).textDisplay
        : theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkLow);

    return Container(
      height: height,
      // Full width: it is the card's foot rail, and a capsule that hugs its
      // own label reads as a caption again.
      width: double.infinity,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        // A pane of glass laid on the card, not an outline drawn on it.
        //
        // This was a hairline border around transparency, and on a dark card
        // that is very close to nothing: the one thing on the card you are
        // meant to press looked like a caption, and looked disabled next to
        // the enabled-looking rows above it. Filling it lifts it off the card
        // without introducing a fourth solid colour into a lobby that already
        // carries three.
        gradient: enabled
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.20),
                  Colors.white.withValues(alpha: 0.07),
                ],
              )
            : null,
        border: Border.all(
          color: enabled
              ? Colors.white.withValues(alpha: 0.34)
              : AppTheme.hairlineColour(theme.brightness, live: false),
          width: enabled ? 1.2 : Dim.hairline,
        ),
        // The lit top edge the felt and the card rims both use, so the capsule
        // belongs to the same room as everything around it.
        boxShadow: enabled
            ? [
                BoxShadow(
                  color: Colors.white.withValues(alpha: 0.16),
                  offset: const Offset(0, -0.5),
                  blurRadius: 0,
                  spreadRadius: -0.5,
                ),
                BoxShadow(
                  color: AppTheme.ink900.withValues(alpha: 0.30),
                  offset: const Offset(0, 2),
                  blurRadius: 8,
                  spreadRadius: -2,
                ),
              ]
            : null,
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
            color: GlassColors.of(context).textMuted,
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(
                fontSize: size,
                color: GlassColors.of(context).textBody,
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
              colour: highlight ? accent : GlassColors.of(context).textDisplay,
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
  const _PrivateCard({
    super.key,
    required this.codeFocus,
    required this.codeFieldKey,
  });

  /// The code field's focus, which the lobby watches to lift the rail over the
  /// keyboard while a code is being typed.
  final FocusNode codeFocus;

  /// On the code field's box, so the lobby can measure where the field sits.
  final GlobalKey codeFieldKey;

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

            final colours = orbColours(accent);
            final orb = _orbPlace(state.config.tables.length, s);
            final dark = brightness == Brightness.dark;
            final panel = PremiumGlassPanel(
              mode: GlassMode.tinted,
              padding: EdgeInsets.zero,
              tint: Colors.white,
              behind: Stack(
                children: [
                  Positioned.fromRect(
                    rect: orb,
                    child: GlassOrb(
                      colours: colours,
                      size: orb.width,
                      soft: true,
                      opacity: dark ? 0.62 : 0.46,
                    ),
                  ),
                ],
              ),
              child: Stack(
                children: [
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
                          key: widget.codeFieldKey,
                          height: Dim.minTouch,
                          // Back, or Settings or the Shop closing over the
                          // lobby, must not raise the keyboard again: that
                          // lifted the rail over the top bar, and a swipe at
                          // the rail typed into the code.
                          child: KeyboardFocusGuard(
                            child: GlassTextField(
                              controller: _code,
                              focusNode: widget.codeFocus,
                              // Exactly the server's code: 8 letters or digits,
                              // upper-cased as they are typed and nothing else
                              // let in, so a space or a dash never reaches a join.
                              maxLength: tableCodeLength,
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp('[A-Za-z0-9]'),
                                ),
                                TextInputFormatter.withFunction(
                                  (_, value) => value.copyWith(
                                    text: value.text.toUpperCase(),
                                  ),
                                ),
                              ],
                              // Rebuilds the card, so Join lights up at 8.
                              onChanged: (_) => setState(() {}),
                              onSubmitted: (value) {
                                if (isValidTableCode(value)) {
                                  state.joinByCode(value);
                                }
                              },
                              textAlign: TextAlign.center,
                              textCapitalization: TextCapitalization.characters,
                              // Tabular, tracked and centred: a room code is read
                              // out loud and typed in, never scanned as a word.
                              style: AppTheme.money(
                                text.titleMedium!,
                                colour: _goldInk(brightness),
                              ).copyWith(letterSpacing: 6),
                              hintText: state.t.tableCode,
                              counterText: '',
                              decoration: InputDecoration(
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: Space.md,
                                ),
                                // The tracking is for the code's own letters and
                                // digits. Spread over Devanagari or Gurmukhi it
                                // pulls the vowel signs off their letters, and
                                // the hint read "ट ब ल क ो ड".
                                hintStyle: state.lang == AppLang.english
                                    ? null
                                    : const TextStyle(letterSpacing: 0),
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
                                child: GlassButton(
                                  style: GlassButtonStyle.primary,
                                  onPressed: state.createPrivate,
                                  label: state.t.create,
                                ),
                              ),
                            ),
                            const SizedBox(width: Space.md),
                            Expanded(
                              child: SizedBox(
                                height: Dim.minTouch,
                                child: GlassButton(
                                  style: GlassButtonStyle.glass,
                                  // Held until the code is whole: 8 letters
                                  // or digits, the only shape the server takes.
                                  onPressed: isValidTableCode(_code.text)
                                      ? () => state.joinByCode(_code.text)
                                      : null,
                                  label: state.t.join,
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

            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fromRect(
                  rect: orb,
                  child: IgnorePointer(
                    child: GlassOrb(
                      colours: colours,
                      size: orb.width,
                      opacity: dark ? 1.0 : 0.9,
                    ),
                  ),
                ),
                panel,
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Requirement 21: the picture is chosen from the top bar. Since 13 Sep 2026 it
/// may be changed at a table too, where it goes straight onto the seat.
///
/// Public so its header can be laid out under test on the screens the game is
/// checked on.
Future<void> openPicturePicker(BuildContext context) async {
  // Owned by the caller, not the builder: the sheet's body is inside a
  // Consumer and rebuilds on every state change, and a controller made in
  // there would be a new one each time — the Scrollbar would lose its
  // position the moment a purchase landed.
  final scroller = ScrollController();

  // Which shelf the menu has open, owned here for the same reason. It opens on
  // All, so the whole catalogue — and the tick on the picture being worn — is
  // in view before anybody narrows it.
  final shelf = ValueNotifier<PictureFilter>(PictureFilter.all);

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (sheetContext) {
      final theme = Theme.of(sheetContext);
      final text = theme.textTheme;
      final size = MediaQuery.sizeOf(sheetContext);
      // A tile's circle. Bigger than it was: these are the faces the player is
      // choosing between, and at 30dp they were thumbnails with labels stacked
      // on them. The grid scrolls, so height is the cheap axis to spend —
      // 43.2 at 891x411, and seven still fit across.
      final tileR = (size.height * 0.105).clamp(32.0, 52.0);
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
              // Bounded, so the sheet cannot grow past the screen when the
              // catalogue does. Everything above and below the grid is pinned;
              // only the pictures scroll.
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: size.height * 0.88),
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
                            animate: true,
                          ),
                          const SizedBox(width: Space.lg),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  // Whose picture this is, by name (owner,
                                  // 14 Sep 2026; it read "Your picture").
                                  // The generic line stays for a sheet
                                  // opened with no name to show.
                                  user == null || user.displayName.isEmpty
                                      ? state.t.yourPicture
                                      : user.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTheme.label(text.titleSmall!),
                                ),
                                Text(
                                  user == null || user.activePictureId == null
                                      ? 'Using your ${user?.provider ?? 'guest'} picture.'
                                      : state.t.pictureChangeAnytime,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: AppTheme.inkMed),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // What premium pictures are paid from besides chips —
                          // diamonds and, since the animated ones were re-priced
                          // (owner, 14 Sep 2026), hammers. Styled like the price
                          // tags below, so the balances and the prices read as
                          // one set at a glance.
                          // Day or night, switched from the top of the menu
                          // (owner, 14 Sep 2026): the pictures are chosen by
                          // how they look, and they look different on each.
                          const DayNightSwitch(),
                          const SizedBox(width: Space.sm),
                          PictureWalletBalances(
                            diamonds: user?.diamond ?? 0,
                            hammers: user?.hammer ?? 0,
                          ),
                          const SizedBox(width: Space.md),
                          // "Use my own photo", as an icon in the header rather
                          // than a labelled button under the grid: the sheet is
                          // short in landscape and every fixed row above or below
                          // the pictures comes straight out of the scrolling
                          // area. The words survive as the tooltip, which is also
                          // where a guest finds out WHY it is greyed out —
                          // without that, a disabled icon says nothing at all.
                          Builder(
                            builder: (context) {
                              final hasPhoto =
                                  (user?.providerAvatarUrl ?? '').isNotEmpty;
                              final guest =
                                  (user?.provider ?? 'guest') == 'guest';
                              final enabled = hasPhoto && !guest;

                              return Tooltip(
                                message: enabled
                                    ? state.t.useSocialPicture
                                    : state.t.guestNoSocial,
                                child: IconButton(
                                  onPressed: enabled
                                      ? () => state.chooseAvatar(null)
                                      : null,
                                  iconSize: 22,
                                  visualDensity: VisualDensity.compact,
                                  tooltip: null,
                                  icon: const Icon(
                                    Icons.account_circle_outlined,
                                  ),
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: AppTheme.inkMed,
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.md),
                      // Which shelf: everything, or the premium pictures of one
                      // wallet — chips, hammers or diamonds. Pinned above the
                      // grid rather than scrolling with it, and it stands in for
                      // the headings the tiers used to carry — one shelf is on
                      // show at a time.
                      ValueListenableBuilder<PictureFilter>(
                        valueListenable: shelf,
                        builder: (context, current, _) => PictureFilterMenu(
                          value: current,
                          counts: {
                            for (final f in PictureFilter.menu)
                              f: state.pictures.where(f.holds).length,
                          },
                          onChanged: (f) {
                            shelf.value = f;
                            if (scroller.hasClients) scroller.jumpTo(0);
                          },
                        ),
                      ),
                      const SizedBox(height: Space.sm),
                      // The shelf's pictures, scrolling vertically. Flexible
                      // rather than a fixed height: the grid takes what the sheet
                      // has left after the header and the menu, so it is the part
                      // that shrinks on a short screen.
                      Flexible(
                        // The bar is always visible — it is the only thing that
                        // says there is more below the fold — but wearing the
                        // app's champagne rather than Material's primary, which
                        // on this glass reads as a highlighter down the edge.
                        child: ScrollbarTheme(
                          data: ScrollbarThemeData(
                            thickness: const WidgetStatePropertyAll(4),
                            radius: const Radius.circular(Radii.pill),
                            thumbColor: WidgetStatePropertyAll(
                              AppTheme.hairlineColour(
                                theme.brightness,
                                live: true,
                              ),
                            ),
                          ),
                          child: Scrollbar(
                            controller: scroller,
                            thumbVisibility: true,
                            child: SingleChildScrollView(
                              controller: scroller,
                              padding: const EdgeInsets.only(right: Space.md),
                              child: ValueListenableBuilder<PictureFilter>(
                                valueListenable: shelf,
                                builder: (context, current, _) => pictureShelf(
                                  context: context,
                                  state: state,
                                  filter: current,
                                  radius: tileR,
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
            ),
          );
        },
      );
    },
  );

  scroller.dispose();
  shelf.dispose();
}

/// The name of the picture the player is wearing, or null when they are on
/// their provider photo (or the catalogue has not arrived yet).
String? _wornPictureName(GameState state) {
  final id = state.user?.activePictureId;
  if (id == null) return null;
  for (final p in state.pictures) {
    if (p.id == id) return p.name;
  }
  return null;
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
            // It also stops short of the keyboard: the lobby is not resized
            // for it, so the list shrinks instead and scrolls a focused field
            // (the display name) into what is left.
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: Space.lg),
                children: children,
              ),
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
            child: PressScale(
              child: IconButton(
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.close_rounded, size: 20),
                onPressed: () => Navigator.pop(context),
              ),
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

    return PressScale(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          // Material's own click, gated on the player's Sound switch —
          // otherwise a silenced game would still tick on every tap.
          enableFeedback: context.select<FeedbackSettings, bool>(
            (f) => f.sound,
          ),
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
            animate: true,
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
  // The player's own balance while it reads differently in the two systems.
  // At a lakh or less both print the same digits, so the choice showed
  // "90,000 / 90,000" or "0 / 0" (QA 14 Sep 2026); a sum that shows the
  // difference stands in.
  final chips = state.user?.chips ?? 0;
  final text = formatChips(chips > 100000 ? chips : 12500000);
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
    final glass = GlassColors.of(context);
    final dark = brightness == Brightness.dark;
    final ink = selected
        ? _goldInk(brightness)
        : scheme.onSurface.withValues(alpha: AppTheme.inkLow);

    // A tile of tinted glass inside the drawer's pane: the stronger fill and
    // the live gold hairline mark the chosen one; the other wears the resting
    // glass edge.
    return PressScale(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          // Material's own click, gated on the player's Sound switch —
          // otherwise a silenced game would still tick on every tap.
          enableFeedback: context.select<FeedbackSettings, bool>(
            (f) => f.sound,
          ),
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
              color: selected ? glass.fillStrong : glass.fill,
              border: Border.all(
                color: selected
                    ? AppTheme.hairlineColour(brightness, live: true)
                    : (dark ? glass.borderTop : glass.borderBottom),
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
                        // Two lines rather than one cut short: a 640dp drawer
                        // showed "International · Millio…" (QA 14 Sep 2026).
                        maxLines: 2,
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
        // The picture leads the drawer, above the name, because it is the
        // louder half of the same decision — who you are at the table. The top
        // bar's avatar opens the same sheet; this is the copy for anyone who
        // went looking in Settings, which is where a player looks for anything
        // about their own account.
        //
        // Shown big rather than as a row: it is the only thing in this drawer
        // that is a picture, and at row scale it read as an icon next to a
        // label instead of as the face everyone at the table will see. The
        // pencil is the same pip the top bar's avatar wears, so the two read as
        // the same control in two places rather than as two different ones.
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 0),
          child: PressScale(
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                enableFeedback: context.select<FeedbackSettings, bool>(
                  (f) => f.sound,
                ),
                borderRadius: BorderRadius.circular(Radii.md),
                onTap: () {
                  // Close the drawer first: the picker is a modal sheet, and
                  // leaving the drawer open behind it stacks two overlays that
                  // dismiss in an order nobody expects.
                  Navigator.pop(context);
                  openPicturePicker(context);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Space.sm),
                  child: Column(
                    children: [
                      _AvatarWithPip(
                        url: state.avatarUrl,
                        fallback: state.user?.displayName ?? '',
                        diameter: 72,
                      ),
                      const SizedBox(height: Space.sm),
                      Text(
                        _wornPictureName(state) ?? t.yourPicture,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.label(
                          text.titleSmall ?? const TextStyle(),
                        ),
                      ),
                      const SizedBox(height: Space.xxs),
                      Text(
                        t.tapToChangePicture,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
        const _DrawerRule(space: Space.sm),
        const SizedBox(height: Space.xs),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.xs),
          // Let go when Back puts the keyboard away, so the selection handle
          // does not stay standing under a field nobody is typing in.
          child: KeyboardFocusGuard(
            child: GlassTextField(
              controller: _name,
              maxLength: 24,
              textInputAction: TextInputAction.done,
              labelText: t.displayName,
              prefixIcon: const Icon(Icons.badge_outlined, size: 18),
              counterText: '',
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
                      // A suffix icon cannot take a PressScale — scaling inside
                      // the field's box clips — so the key gets the light
                      // haptic on its callback instead.
                      onPressed: () {
                        tapHaptic(context);
                        _save(state);
                      },
                    ),
              decoration: InputDecoration(isDense: true, errorText: _nameError),
              // The server's complaint is about the name that was sent. Once
              // the player edits it, that complaint no longer describes what
              // is in the field, so it goes rather than staying red over a
              // name that may already be fine.
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
              onSubmitted: (_) => _save(state),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.lg, 0),
          child: DropdownButtonFormField<AppLang>(
            initialValue: state.lang,
            // The field takes the width it is given and its longest item
            // ellipsises inside it, instead of the row sizing itself to the
            // longest name and running 17dp past the drawer's edge — which is
            // what it did once the type became Inter, which is wider than the
            // font this slot was measured against.
            isExpanded: true,
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
        // Appearance: System, Dark or Light as one segmented glass control,
        // headed the same way as the number system above it. The switcher
        // reads and writes the theme mode itself.
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.lg, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.palette_outlined,
                    size: 16,
                    color: scheme.onSurface.withValues(alpha: AppTheme.inkLow),
                  ),
                  const SizedBox(width: Space.sm),
                  Flexible(
                    child: Text(
                      t.appearance,
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
              const GlassThemeSwitcher(),
            ],
          ),
        ),
        const _DrawerRule(),
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
          onTap: () {
            // The drawer closes first, as it does before the picture picker,
            // so the question is not stacked over an open drawer.
            Navigator.pop(context);
            _confirmSignOut(context, state);
          },
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
  const _BonusChip({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final r = state.user?.rewards;
    if (r == null) return const SizedBox.shrink();

    final ready = r.bonusReady;
    return _CornerChip(
      icon: Icons.hourglass_bottom,
      leadingBuilder: (fg) => _Hourglass(colour: fg, running: !ready),
      title: state.t.dailyBonus,
      subtitle: ready
          ? [
              state.t.collect,
              formatChips(r.bonusReward),
              if (r.bonusHammers > 0) state.t.plusHammers(r.bonusHammers),
            ].join(' ')
          : formatCountdown(r.untilBonus, state.t),
      enabled: ready,
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

/// On the milestone chip, so [lobbyNoticeArea] can keep a toast off it.
///
/// Measured rather than worked out: the chip is as wide as its two lines of
/// text in the player's language, which nothing outside it knows.
final _milestoneChip = GlobalKey(debugLabel: 'milestone chip');

/// On the daily bonus key in the opposite corner, for the same reason.
final _bonusChip = GlobalKey(debugLabel: 'bonus chip');

/// Where a notice may stand in the lobby, in screen coordinates, or null for
/// the plain foot of the screen.
///
/// The lobby's foot is empty but for the milestone chip in its right-hand
/// corner and, since 14 Sep 2026, the daily bonus in its left-hand one, and a
/// toast centred on a 640dp phone ran 5dp over the milestone chip's rim. The
/// toast keeps its width and its place at the foot and moves aside only as far
/// as a chip needs, narrowing only if the whole space between them is smaller
/// than it. With no chip laid out (no account yet) it is centred.
///
/// Read through the screen's fade-in, the chip measures a little nearer the
/// middle than it comes to rest, which can only move the toast further off it.
Rect? lobbyNoticeArea(BuildContext context) {
  final chip = _milestoneChip.currentContext?.findRenderObject();
  if (chip is! RenderBox ||
      !chip.attached ||
      !chip.hasSize ||
      chip.size.isEmpty) {
    return null;
  }
  final chipLeft = chip.localToGlobal(Offset.zero).dx;
  if (!chipLeft.isFinite) return null;

  final size = MediaQuery.sizeOf(context);
  final safe = MediaQuery.paddingOf(context);
  final width = Dim.toastW(size.width);
  var start = safe.left + Space.md;
  final bonus = _bonusChip.currentContext?.findRenderObject();
  if (bonus is RenderBox &&
      bonus.attached &&
      bonus.hasSize &&
      !bonus.size.isEmpty) {
    final bonusRight = bonus.localToGlobal(Offset(bonus.size.width, 0)).dx;
    if (bonusRight.isFinite) start = math.max(start, bonusRight + Space.sm);
  }
  final end = chipLeft - Space.sm;
  var left = (size.width - width) / 2;
  var right = left + width;
  if (right > end) {
    right = end;
    left = math.max(start, end - width);
  }
  if (left < start) {
    left = start;
    right = math.min(end, start + width);
  }
  if (right <= left) return null;
  // Topped at the top of the screen, so the toast is never scaled down to fit:
  // unlike the table's, this one has room to grow upward.
  return Rect.fromLTRB(left, safe.top, right, size.height - Space.md);
}

class _MilestoneChip extends StatelessWidget {
  const _MilestoneChip({super.key});

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
          : '${r.handsToNextMilestone} ${r.handsToNextMilestone == 1 ? state.t.handToGo : state.t.handsToGo}',
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final brightness = theme.brightness;
    final gold = _goldInk(brightness);
    final fg = enabled
        ? gold
        : theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkMed);
    // A finite cap so the two lines can ellipsise. Without one this pill sizes
    // to its longest translation and runs off the screen.
    final cap = Dim.bonusSlotW(MediaQuery.sizeOf(context).width);

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: cap),
      // Presses in only while it can be taken; a chip still counting down
      // stays still under the finger, which is what says it is not a key yet.
      child: PressScale(
        enabled: enabled,
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
      ),
    );
  }
}
