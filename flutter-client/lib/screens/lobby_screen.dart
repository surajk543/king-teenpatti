import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/server_config.dart';
import '../settings/feedback_settings.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import '../widgets/game_card.dart';
import '../widgets/avatar.dart';
import '../widgets/buy_chips.dart';
import '../widgets/chip_shuffle.dart';
import '../widgets/feedback_toggles.dart';
import '../widgets/drifting_chips.dart';
import '../widgets/edge_fade.dart';
import '../widgets/fireworks.dart';
import '../widgets/glass_components.dart';
import '../widgets/glass_panels.dart';
import '../widgets/picture_shelf.dart';
import '../widgets/poker_chip.dart';
import '../widgets/premium_surface.dart';
import '../widgets/rules_sheet.dart';
import '../widgets/table_ground.dart';
import 'lucky_draw_screen.dart';

/// The lobby: every choice is a card on one horizontal rail, so a phone held in
/// landscape never has to scroll down — swipe sideways instead.
///
/// The rail is a shelf of *products*, not a stack of panels: each card is the
/// same neutral card ([GameCard]) lit in its game mode's colour — gold for
/// seen, sapphire for blind, violet for variation, the poker family's teal,
/// and the private room's emerald last (owner, 24 Sep 2026) — spent on a light
/// behind it, the top of its edge, its chips and its key, never on the whole
/// card. Glass is spent only on what covers the shelf — the two drawers and
/// the picture sheet, which blur, and the top bar and its pills, which are
/// tinted panes.
///
/// Nothing here blurs while the player is only looking: the drifting chips
/// repaint the whole background continuously, and a `BackdropFilter` over a
/// backdrop that is dirty every frame is a blur every frame.
/// Gold as money is written in the lobby — a rich gold by night, a deep one by
/// day ([AppTheme.goldInk]) — so every gold figure routes through here rather
/// than naming a constant.
Color _goldInk(Brightness b) => AppTheme.goldInk(b);

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

    // Three levels in the one rail (owner, 23 Sep 2026: "give two cards: Teen
    // Patti and Poker"). The front of the lobby is the ENGINES the server
    // offers a table in — Teen Patti, Poker — and the private card; going into
    // one shows its CATEGORIES (Seen, Blind, Variation; the four poker games)
    // behind a tile that leads back, and going into one of those shows its
    // TABLES behind another. The server decides which rooms exist; the lobby
    // decides how a player meets them.
    //
    // The level shown is the one the state holds only while the menu still
    // offers it: a menu written straight into `config` never strands the
    // player at an empty rail.
    final scheme = Theme.of(context).colorScheme;
    final engines = state.lobbyEngines;
    final engine = engines.contains(state.lobbyEngine)
        ? state.lobbyEngine
        : null;
    final categories = engine == null
        ? const <String>[]
        : state.lobbyCategoriesIn(engine);
    final category = categories.contains(state.lobbyCategory)
        ? state.lobbyCategory
        : null;
    // The open level's colour, let into the room as its ambient light (owner,
    // 24 Sep 2026: "the glow should feel like ambient lighting behind the
    // UI"): nothing at the front, where every mode stands side by side; the
    // engine's inside an engine; the category's inside a category.
    final roomLight = category != null
        ? _categoryPalette(scheme, category).accent
        : engine != null
        ? _enginePalette(scheme, engine).accent
        : null;

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
      body: _RoomLight(
        colour: roomLight,
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
                          // The level's cards (see engine / category above).
                          final List<Widget> cards;
                          if (engine == null) {
                            cards = [
                              for (final name in engines)
                                entering(_EngineCard(engine: name)),
                              // Last, as it always was: a private table is
                              // not one of the server's games but a door of
                              // its own, and it stays on the front.
                              entering(
                                _PrivateCard(
                                  key: _privateCard,
                                  codeFocus: _codeFocus,
                                  codeFieldKey: _codeField,
                                ),
                              ),
                            ];
                          } else if (category == null) {
                            cards = [
                              entering(
                                _BackTile(
                                  here: _engineName(
                                    state.t,
                                    engine,
                                    serverName: state.lobbyEngineServerName(
                                      engine,
                                    ),
                                  ),
                                  back: state.t.backToCategories,
                                  accent: _enginePalette(scheme, engine).accent,
                                ),
                              ),
                              for (final name in categories)
                                entering(
                                  _CategoryCard(engine: engine, category: name),
                                ),
                            ];
                          } else {
                            cards = [
                              entering(
                                _BackTile(
                                  here: _categoryName(
                                    state.t,
                                    category,
                                    serverName: state.lobbyServerName(category),
                                  ),
                                  // Where Back goes: this category's engine.
                                  back: _engineName(
                                    state.t,
                                    engine,
                                    serverName: state.lobbyEngineServerName(
                                      engine,
                                    ),
                                  ),
                                  accent: _categoryPalette(
                                    scheme,
                                    category,
                                  ).accent,
                                ),
                              ),
                              // The tables this player can sit at, then the
                              // ones shut to their stack
                              // (GameState.lobbyTablesIn).
                              for (final table in state.lobbyTablesIn(
                                category,
                                engine: engine,
                              ))
                                entering(_TableCard(table: table)),
                            ];
                          }
                          // The cards are square, so their height sets their
                          // width; on a tablet an uncapped card grows until two
                          // of them fill the screen. The rail is derived from the
                          // card plus its own padding rather than the other way
                          // round, so the card is never squeezed by the rail.
                          // The card's ceiling is h=360 -> 259.2 | h=411 -> 295.9
                          // | h=800 -> 400.0; with the chip's band off the height
                          // the two phones get about 227 and 270.
                          final fit = math.min(
                            math.max(box.maxHeight - Space.xl, 0.0),
                            Dim.lobbyCardSide(h),
                          );
                          // ...and then no larger than lets the rail stop on
                          // whole cards and a glimpse of the next
                          // (lobbyRailSide). Every level inside an engine is
                          // sized as if it held four cards, so the categories
                          // and the tables behind them stay one size on a
                          // phone rather than changing with each level's
                          // count.
                          final backTile = engine != null;
                          final side = lobbyRailSide(
                            fit: fit,
                            width: box.maxWidth,
                            cards: backTile
                                ? math.max(cards.length - 1, 4)
                                : cards.length,
                            backTile: backTile,
                          );
                          final level = [?engine, ?category].join(':');
                          final rail = Center(
                            // A level whose cards are another size than the
                            // last one's eases to it while the two cross-fade,
                            // rather than jumping.
                            child: TweenAnimationBuilder<double>(
                              tween: Tween(end: side),
                              duration: Motion.base,
                              curve: Motion.standard,
                              builder: (context, shown, child) => SizedBox(
                                height: shown + Space.xl,
                                child: child,
                              ),
                              // Each level is a ListView of its own, so a
                              // category opens at its first table rather than
                              // wherever the categories were scrolled to, and
                              // its cards make their entrance as the lobby's
                              // did. Keyed on the level and on nothing that
                              // ticks: GameState notifies every second, and a
                              // key that changed with it would restart this
                              // fade once a second.
                              child: AnimatedSwitcher(
                                duration: Motion.base,
                                switchInCurve: Motion.standard,
                                switchOutCurve: Motion.standard,
                                child: ListView(
                                  // 'lobby-rail:' at the front,
                                  // 'lobby-rail:teen_patti' inside an engine,
                                  // 'lobby-rail:teen_patti:blind' inside a
                                  // category.
                                  key: ValueKey('lobby-rail:$level'),
                                  scrollDirection: Axis.horizontal,
                                  // Holds its place while the cards change
                                  // size under it (_KeepsPlacePhysics).
                                  physics: const _KeepsPlacePhysics(),
                                  // Each card carries its own gap on its
                                  // right (Space.lg), so the rail's end
                                  // leaves only what makes the last card stop
                                  // as far from the edge as the first starts.
                                  padding: const EdgeInsets.fromLTRB(
                                    Space.xl,
                                    Space.md,
                                    Space.xl - Space.lg,
                                    Space.md,
                                  ),
                                  children: cards,
                                ),
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
              // The daily bonus in the bottom-left corner (owner, 14 Sep 2026),
              // a key that counts down its 24 hours and collects when they are
              // up; the 4-hour bonus keeps its chip in the top bar. The Lucky
              // Draw stands beside it (owner, 24 Sep 2026). Keyed as one row so
              // a lobby toast can stand clear of both (lobbyNoticeArea).
              Positioned(
                bottom: Space.md,
                left: Space.md,
                child: Row(
                  key: _dailyChip,
                  mainAxisSize: MainAxisSize.min,
                  children: const [_DailyBonusChip(), _LuckyDrawChip()],
                ),
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

/// The lobby's room, lit in the open level's colour ([colour]; none at the
/// front) through the lamp's pool — the ambient light the brief asks for, a
/// room-wide wash too faint to read as a colour until a level is entered.
///
/// The light moves over half a second rather than cutting: into a level it
/// rises in that level's colour, back out it fades in the colour it had, so
/// the change says where the player is without flashing at them.
class _RoomLight extends StatefulWidget {
  const _RoomLight({required this.colour, required this.child});

  final Color? colour;
  final Widget child;

  @override
  State<_RoomLight> createState() => _RoomLightState();
}

class _RoomLightState extends State<_RoomLight> {
  /// The last colour the room was lit in, which is what fades when the light
  /// goes out — a fade through another hue would tint the room on the way.
  late Color _last = widget.colour ?? AppTheme.gold;

  @override
  void didUpdateWidget(_RoomLight oldWidget) {
    super.didUpdateWidget(oldWidget);
    final colour = widget.colour;
    if (colour != null) _last = colour;
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<Color?>(
    tween: ColorTween(end: widget.colour ?? _last.withValues(alpha: 0)),
    duration: Motion.arrive,
    curve: Motion.standard,
    builder: (context, light, child) {
      final a = light?.a ?? 0;
      final dark = Theme.of(context).brightness == Brightness.dark;
      return LobbyGround(
        accent: a == 0 ? null : light!.withValues(alpha: 1),
        // By night the room can carry more of it than by day (owner, 24 Sep
        // 2026): a tenth at the lamp by night, and by day — where the final
        // pass asked for the tint to be all but gone — about 4%.
        accentStrength: (dark ? 2.0 : 1.2) * a,
        child: child!,
      );
    },
    child: widget.child,
  );
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

/// The width of the tile that leads back a level, beside cards of [side]: a
/// quarter of a card, and never less than a finger and its margins.
double _backTileWidth(double side) =>
    math.max(Dim.minTouch + Space.xl, side * 0.26);

/// The least of a card the rail stops on when it cannot stop on whole cards
/// alone: enough to show its edge and the start of its badge, a glimpse of
/// what comes next.
const double _peekMin = 0.15;

/// The most of a card the rail may stop on without showing it whole. Past
/// about half, a card reads as one the layout meant to show and then cut —
/// the owner's "Only your own chips are vis…", "Entry Up…", "Tap to sit
/// down…" (24 Sep 2026) was a table card two-thirds on screen.
const double _peekMax = 0.6;

/// The smallest side the rail gives up its cards' size for. Below it a table
/// card's words have to shrink to fit, and a clean edge is not worth that.
const double _sideMin = 196;

/// The side of the lobby's square cards on a rail [width] wide that holds
/// [cards] of them — after the tile that leads back a level when [backTile] —
/// from [fit], the side the rail's height allows.
///
/// At [fit] the first card that does not fit whole shows however much of
/// itself the phone's width happens to leave: a sliver on one phone, all but
/// its last few dp on the next. So the side is the largest, no more than
/// [fit], at which every card before that one stands whole and [Space.xl]
/// clear of the edge, and that one shows between [_peekMin] and [_peekMax] of
/// itself — or there is no such card, every one of them whole. The cards give
/// up no more size than it takes, and never go below [_sideMin]: a rail that
/// would need smaller cards than that keeps [fit], and the glimpse it had.
@visibleForTesting
double lobbyRailSide({
  required double fit,
  required double width,
  required int cards,
  required bool backTile,
}) {
  bool stopsClean(double side) {
    var left = Space.xl + (backTile ? _backTileWidth(side) + Space.lg : 0.0);
    for (var i = 0; i < cards; i++, left += side + Space.lg) {
      // Whole, and as far from the edge as the rail's first card starts.
      if (left + side + Space.xl <= width) continue;
      final shown = width - left;
      return shown >= side * _peekMin && shown <= side * _peekMax;
    }
    return true;
  }

  for (var side = fit; side >= math.min(fit, _sideMin); side -= 0.5) {
    if (stopsClean(side)) return side;
  }
  return fit;
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
      'daily' => t.rewardComeBackDaily,
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
                final slotW = Dim.bonusSlotW(box.maxWidth);
                // The provider tag folds on what the row actually has left,
                // not on the screen width. It matters more now that the Shop
                // key shares this bar: on a 640dp screen the tag was rendering
                // as "GUE…", which tells nobody anything — better absent than
                // truncated.
                final tight = Breaks.isTightBar(box.maxWidth - slotW);
                final gap = tight ? Space.sm : Space.md;

                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: Space.md,
                    vertical: pad,
                  ),
                  child: Row(
                    children: [
                      // Requirement 26 keeps its corner: the 4-hour bonus. The
                      // chip takes its own width, capped at the slot the rail
                      // used to reserve, and the picture follows straight after
                      // it (owner, 13 Sep 2026): the reserved slot left a gap
                      // there that the name needed. The daily bonus is the chip
                      // in the lobby's bottom-left corner (14 Sep 2026).
                      _BonusChip(maxWidth: slotW - Space.md),
                      // The groups sit a step closer on a tight bar, where
                      // every dp is a letter of the name.
                      SizedBox(width: gap),
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
                      SizedBox(width: gap),
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
                              const SizedBox(width: Space.sm),
                              // The wallets in a pill of their own, with the
                              // Shop against its right end (owner, 24 Sep 2026:
                              // "visually separate … the currency"): what the
                              // player holds and the way to more of it read as
                              // one group, apart from who they are.
                              //
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
                              //
                              // The pill's own margin counts against the cap,
                              // which is a little wider than it was for it
                              // (0.53 of the room on a tight bar, from 0.5).
                              // With the tight bar's closer steps that keeps
                              // both the figures and the name the size they
                              // were on a 640dp phone before the pill.
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth:
                                      room.maxWidth * (tight ? 0.53 : 0.65),
                                ),
                                child: _WalletPill(
                                  margin: gap,
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
                                                  colour: hammerInkOn(
                                                    brightness,
                                                  ),
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
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
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

/// The top bar's wallets in one pill: the chips over the diamonds, hammers
/// and missiles, in the same glass as the pill of keys at the bar's end
/// ([_BarActions]) — its fill and its hairline — so the bar reads as groups
/// rather than as loose figures. It hugs its figures: as wide as they are, as
/// tall as a key.
class _WalletPill extends StatelessWidget {
  const _WalletPill({required this.child, this.margin = Space.md});

  final Widget child;

  /// The space either side of the figures, inside the pill.
  final double margin;

  @override
  Widget build(BuildContext context) {
    final glass = GlassColors.of(context);
    return SizedBox(
      height: Dim.minTouch,
      child: CustomPaint(
        foregroundPainter: GlassHairline(
          radius: Radii.pill,
          colors: [glass.borderTop, glass.borderBottom],
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.pill),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [glass.fillStrong, glass.fill],
            ),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: margin),
            child: Center(widthFactor: 1, child: child),
          ),
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
    this.ringed = false,
  });

  final String? url;
  final String fallback;
  final double diameter;

  /// A thin gold ring round the picture, a band of ground inside it — the
  /// Settings drawer's portrait (settings polish, 26 Sep 2026), in the store's
  /// words for the worn picture, only finer. Never the top bar's, whose rail
  /// is measured from this footprint and wears the plain hairline.
  final bool ringed;

  static const double _ringWidth = 2;
  static const double _ringGap = 2;

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
          // Avatar's ring grows outwards, so the picture gives the ring (and
          // any band inside it) back, and the footprint stays [diameter].
          radius: ringed
              ? diameter / 2 - _ringWidth - _ringGap
              : diameter / 2 - 1.5,
          ring: ringed
              ? (brightness == Brightness.dark
                    ? AppTheme.goldBright
                    : AppTheme.gold)
              : null,
          ringWidth: ringed ? _ringWidth : 1.5,
          ringGap: ringed ? _ringGap : 0,
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

/// What an engine's front card is called.
///
/// Teen Patti and Poker in the player's own language. An engine this build
/// has never heard of — one the server's taxonomy added after it (owner,
/// 23 Sep 2026) — goes by [serverName], the server's own label for it
/// ([GameState.lobbyEngineServerName]), and failing that by its code.
String _engineName(Strings t, String engine, {String? serverName}) =>
    switch (engine) {
      TableEngine.teenPatti => t.teenPatti,
      TableEngine.poker => t.poker,
      _ => serverName ?? engine,
    };

/// The name a category card goes by: the word on its tables' badges.
///
/// Every category this build knows is named in the player's own language — a
/// poker game by its own name. One it does not know goes by [serverName], the
/// server's own label for it ([GameState.lobbyServerName]), and failing that
/// by its code: never as Seen, beside a Seen card it is not.
String _categoryName(Strings t, String category, {String? serverName}) {
  if (TableCategory.isPoker(category)) return t.pokerVariantName(category);
  return switch (category) {
    TableCategory.seen => t.seen,
    TableCategory.blind => t.blind,
    TableCategory.variation => t.variation,
    // A poker table with no category of its own, filed under its engine's
    // name (GameState.lobbyCategoryOf).
    TableCategory.pokerFamily => t.poker,
    _ => serverName ?? category,
  };
}

/// What a table's own card and its info popup call it: a poker game by its
/// own name, a Teen Patti table by its category — and a table of a category
/// this build has never heard of by the server's name for that category, or
/// as seen where the server names none, as before the taxonomy existed.
String _tableName(GameState state, LobbyTable table) {
  final t = state.t;
  if (table.isPoker) return t.pokerVariantName(table.category);
  return switch (table.category) {
    TableCategory.seen => t.seen,
    TableCategory.blind => t.blind,
    TableCategory.variation => t.variation,
    _ => state.lobbyServerName(table.category) ?? t.seen,
  };
}

/// The one line on an engine's front card: the games inside it. An engine
/// this build does not know is described by the server's names for its
/// categories, which is all there is to say about it.
String _engineBlurb(GameState state, String engine) {
  final t = state.t;
  return switch (engine) {
    TableEngine.teenPatti => t.teenPattiTableNote,
    TableEngine.poker => t.pokerTableNote,
    _ => [
      for (final category in state.lobbyCategoriesIn(engine))
        _categoryName(t, category, serverName: state.lobbyServerName(category)),
    ].join(', '),
  };
}

/// The one line that says what a category's tables are like — the line each
/// of its table cards carries: whose chips show, or what a variation table
/// does, or how a poker game is played. Empty for a category of an engine this
/// build does not know, where it has nothing true to say.
String _categoryBlurb(Strings t, String engine, String category) {
  if (engine == TableEngine.poker || TableCategory.isPoker(category)) {
    final note = t.pokerVariantNote(category);
    // Every poker room keeps the stacks to their owners (owner, 19 Sep 2026).
    return note.isNotEmpty ? note : t.onlyYourChips;
  }
  if (engine != TableEngine.teenPatti) return '';
  return switch (category) {
    TableCategory.blind => t.onlyYourChips,
    TableCategory.variation => t.variationTableNote,
    _ => t.everyoneChips,
  };
}

/// A category's colour, which every one of its tables wears — gold, sapphire,
/// violet, and the poker family's teal for each of its four games.
TablePalette _categoryPalette(ColorScheme scheme, String category) =>
    AppTheme.paletteFor(scheme, category: category, bootAmount: 200);

/// An engine's colour. Poker keeps the family's teal, which every one of its
/// games and tables wears; Teen Patti wears the seen table's gold — its first
/// category, the table every player has seen, and the house's own champagne.
/// An engine this build does not know is drawn as Teen Patti is, as an unknown
/// category is drawn as seen.
TablePalette _enginePalette(ColorScheme scheme, String engine) =>
    AppTheme.paletteFor(
      scheme,
      category: engine == TableEngine.poker
          ? TableCategory.pokerFamily
          : TableCategory.seen,
      bootAmount: 200,
    );

/// One of the lobby's engines — Teen Patti, Poker (owner, 23 Sep 2026).
///
/// A [_GroupCard] over every table the engine has, naming the games inside
/// it; its key opens them ([GameState.openLobbyEngine]).
class _EngineCard extends StatelessWidget {
  const _EngineCard({required this.engine});

  final String engine;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    return _GroupCard(
      name: _engineName(
        t,
        engine,
        serverName: state.lobbyEngineServerName(engine),
      ),
      blurb: _engineBlurb(state, engine),
      palette: _enginePalette(Theme.of(context).colorScheme, engine),
      tables: state.lobbyTablesOf(engine),
      action: t.viewGames,
      shuffle: true,
      onOpen: () => context.read<GameState>().openLobbyEngine(engine),
    );
  }
}

/// One of an engine's categories — Seen, Blind, Variation inside Teen Patti
/// (owner, 18 Sep 2026); 3-Card Poker, 5-Card Draw, Texas Hold'em and Omaha
/// inside Poker (owner, 23 Sep 2026).
///
/// A [_GroupCard] over that category's tables, in the category's colour and
/// with the line each of its table cards carries; its key opens them
/// ([GameState.openLobbyCategory]).
class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.engine, required this.category});

  final String engine;
  final String category;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    return _GroupCard(
      name: _categoryName(
        t,
        category,
        serverName: state.lobbyServerName(category),
      ),
      blurb: _categoryBlurb(t, engine, category),
      palette: _categoryPalette(Theme.of(context).colorScheme, category),
      tables: state.lobbyTablesIn(category, engine: engine),
      action: t.viewTables,
      onOpen: () =>
          context.read<GameState>().openLobbyCategory(category, engine: engine),
    );
  }
}

/// A card that opens a group of tables: an engine on the front, a category
/// inside an engine.
///
/// The same square [GameCard] as a [_TableCard], lit in the group's colour,
/// so every level of the lobby is visibly the same place. It states what a
/// player needs to choose between groups and nothing a table card will say
/// better: its name (the largest words on it), what is inside (one line), the
/// stakes it runs from and to, how many tables it has, and how many of them
/// this player's stack can sit at today. The whole card is the key.
///
/// A group whose every table is shut to the player is NOT padlocked. Its
/// tables are where the padlocks are, each saying what it would take to sit
/// there; a locked group would hide exactly that.
class _GroupCard extends StatelessWidget {
  const _GroupCard({
    required this.name,
    required this.blurb,
    required this.palette,
    required this.tables,
    required this.action,
    required this.onOpen,
    this.shuffle = false,
  });

  /// The card's title, already in the player's language.
  final String name;

  /// Its one line; left out when empty.
  final String blurb;

  final TablePalette palette;

  /// Every table behind the card, as the facts count them.
  final List<LobbyTable> tables;

  /// What the key at its foot says: "View games", "View tables".
  final String action;

  final VoidCallback onOpen;

  /// Whether the coin beside the title is the chip shuffle — an engine's card
  /// on the front (owner, 23 Sep 2026) — rather than the settling pile a
  /// category's card keeps.
  final bool shuffle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final glass = GlassColors.of(context);
    final state = context.watch<GameState>();
    final t = state.t;
    final accent = palette.accent;

    final open = tables.where((table) => !state.tableShut(table)).length;
    final boots = [for (final table in tables) table.bootAmount]..sort();
    final bootRange = boots.isEmpty
        ? '—'
        : boots.first == boots.last
        ? formatChips(boots.first)
        : '${formatChips(boots.first)} – ${formatChips(boots.last)}';

    return Padding(
      padding: const EdgeInsets.only(right: Space.lg),
      child: AspectRatio(
        aspectRatio: 1,
        child: Semantics(
          button: true,
          label: '$name. $action',
          child: _Pressable(
            onTap: () {
              tapHaptic(context);
              onOpen();
            },
            child: LayoutBuilder(
              builder: (context, box) {
                // The table card's own proportions, so the two kinds of card
                // are one family. This column is shorter than that one — a
                // name, a line, three facts against a badge, a stake, a line
                // and three facts — so wherever a table card fits, this does.
                final s = box.maxHeight;
                final m = _CardMetrics(s);

                return GameCard(
                  accent: accent,
                  padding: EdgeInsets.all(m.pad),
                  child: LayoutBuilder(
                    builder: (context, inner) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Allowed the height the key leaves and no more, and
                        // scaled down rather than overflowing past it — the
                        // table card's own guard, for the same reason:
                        // Devanagari stands taller than Latin.
                        CardColumn(
                          maxHeight: math.max(
                            0.0,
                            inner.maxHeight - m.ctaH - m.ctaGap,
                          ),
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                if (shuffle)
                                  // Twelve chips, each as wide as the
                                  // coin it replaces, in that coin's
                                  // colours. The pile is what shows
                                  // should the file fail to load.
                                  ChipShuffle(
                                    colour: accent,
                                    size: ChipShuffle.sizeForChip(
                                      m.titleSize * 0.62,
                                    ),
                                    fallback: LivelyChipStack(
                                      size: m.titleSize * 0.62,
                                      colours: [accent, palette.rimLow],
                                    ),
                                  )
                                else
                                  LivelyChipStack(
                                    size: m.titleSize * 0.62,
                                    colours: [accent, palette.rimLow],
                                  ),
                                SizedBox(width: m.markGap),
                                // The card's name in the room's own
                                // ink, not gold: gold is what money is
                                // written in, and the mode's colour is
                                // already in the chips beside it.
                                Expanded(
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      name,
                                      maxLines: 1,
                                      style: AppTheme.label(
                                        text.displaySmall!,
                                        colour: glass.textDisplay,
                                        weight: FontWeight.w700,
                                      ).copyWith(fontSize: m.titleSize),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (blurb.isNotEmpty) ...[
                              CardGap(m.gap),
                              // Allowed a third line rather than cut
                              // short: a long translation at a large
                              // text size wraps, and the column above
                              // the key scales down to hold it.
                              Text(
                                blurb,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(
                                  fontSize: m.blurbSize,
                                  color: glass.textBody,
                                ),
                              ),
                            ],
                            CardGap(m.gap),
                            _CardFact(
                              icon: Icons.toll_rounded,
                              palette: palette,
                              label: t.boot,
                              value: bootRange,
                              height: m.groupFactH,
                              // Stakes are money, and money is gold.
                              money: true,
                            ),
                            _FactRule(space: m.groupRuleSpace),
                            _CardFact(
                              icon: Icons.table_restaurant_rounded,
                              palette: palette,
                              label: t.tablesLabel,
                              value: '${tables.length}',
                              height: m.groupFactH,
                            ),
                            _FactRule(space: m.groupRuleSpace),
                            _CardFact(
                              icon: Icons.lock_open_rounded,
                              palette: palette,
                              label: t.openToYouLabel,
                              value: '$open',
                              height: m.groupFactH,
                              // Every table open is the good news; none
                              // open is said quietly.
                              highlight: open > 0 && open == tables.length,
                              quiet: open == 0,
                            ),
                          ],
                        ),
                        const Spacer(),
                        _SitCapsule(
                          label: action,
                          height: m.ctaH,
                          enabled: true,
                          palette: palette,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Every size on a lobby card, from the one number a square card has: its
/// side, [s].
///
/// One set for the group cards, the table cards and the private card, so they
/// are one family — the same margin, the same facts, the same key at the
/// foot. Type and the boxes that hold it follow the side, clamped at both
/// ends so a phone keeps its words legible and a tablet does not turn them
/// into a poster: s is 227 on a 640x360 phone, 246 inside an engine on a
/// 915x412 one (270 on its front) and 354-400 on a tablet. The space between
/// things does not follow the side in fractions: it steps along the cards' 4dp
/// grid ([CardSpace]) with the card's size — compact below 240, regular to
/// 320, roomy above — so every card of one size is spaced alike (owner's
/// final pass, 24 Sep 2026: "consistent 4/8/12/16/20/24/32").
class _CardMetrics {
  _CardMetrics(this.s);

  final double s;

  /// A 360dp-high phone's card, where every row is counted.
  bool get _compact => s < 240;

  /// A tablet's.
  bool get _roomy => s >= 320;

  /// The card's inner margin: 12 | 16 | 20.
  double get pad => _compact
      ? CardSpace.s12
      : _roomy
      ? CardSpace.s20
      : CardSpace.s16;

  /// Between two blocks of a card — its head, its line, its facts: 8 | 8 |
  /// 12.
  double get gap => _roomy ? CardSpace.s12 : CardSpace.s8;

  /// From a table card's badge down to its boot, which it heads: 4, and 8 on
  /// a tablet.
  double get headGap => _roomy ? CardSpace.s8 : CardSpace.s4;

  /// From a mark — the chips, the padlock — to the words beside it: 12, and
  /// 16 on a tablet. A name set close against its chips read as crowded.
  double get markGap => _roomy ? CardSpace.s16 : CardSpace.s12;

  /// The least air kept above the key at the foot (a Spacer gives it whatever
  /// else the column leaves): 4 | 8 | 16. A phone's card keeps only the grid's
  /// smallest step, which a card with room never sees: it matters on a poker
  /// table's card, whose four or five facts already fill it, and every dp
  /// kept there is one its words do not have to shrink by.
  double get ctaGap => _compact
      ? CardSpace.s4
      : _roomy
      ? CardSpace.s16
      : CardSpace.s8;

  /// Either side of the rule between two of a table card's facts: 4 | 4 | 8.
  double get ruleSpace => _roomy ? CardSpace.s8 : CardSpace.s4;

  /// A group card's rules: roomier where the card has the height, as its rows
  /// are (groupFactH): 4 | 8 | 12.
  double get groupRuleSpace => _compact
      ? CardSpace.s4
      : _roomy
      ? CardSpace.s12
      : CardSpace.s8;

  /// A group card's name, the largest words on it. 227 -> 25.4 | 270 -> 30.2
  /// | 400 -> 38.
  double get titleSize => (s * 0.112).clamp(22.0, 38.0);

  /// The boot on a table card: the figure a player chooses a table by, the
  /// largest on the card and no longer the loudest thing in the room (it was
  /// s x 0.14, 32-38dp on a phone). 227 -> 24.5 | 246 -> 26.6 | 270 -> 29.2 |
  /// 354 -> 36.
  double get bootSize => (s * 0.108).clamp(22.0, 36.0);

  /// A table card's badge, what kind of table it is. 227 -> 22.7 | 246 ->
  /// 24.6 | 354 -> 34.
  double get plateH => (s * 0.1).clamp(22.0, 34.0);

  /// A fact row's box. 227 -> 15.4 | 246 -> 16.7 | 354 -> 24.1. Its words
  /// are never clipped by it (_CardFact).
  double get factH => (s * 0.068).clamp(15.0, 26.0);

  /// A group card's fact rows, roomier than a table card's: it states three
  /// facts where a table card states them under a badge and a stake, so it
  /// has the height to let them breathe. 227 -> 18.5 | 270 -> 22.
  double get groupFactH => factH * 1.2;

  /// The one line of prose, set below everything the eye comes for.
  /// 227 -> 11.5 | 246 -> 11.8 | 270 -> 13 | 354 -> 15. A 640dp phone keeps
  /// the half point: at 12 the variation card's line wrapped.
  double get blurbSize => (s * 0.048).clamp(11.5, 15.0);

  /// The key at the foot. 227 -> 28.4 | 246 -> 30.8 | 354 -> 42.
  double get ctaH => (s * 0.125).clamp(28.0, 42.0);
}

/// The hairline between two facts: the card's own edge colour, so the facts
/// read as rows of one table rather than as gilded lines. On a card its air
/// gives way before the card's words shrink ([CardRule]).
class _FactRule extends StatelessWidget {
  const _FactRule({required this.space});

  final double space;

  @override
  Widget build(BuildContext context) =>
      CardRule(space: space, colour: GlassColors.of(context).cardBorder);
}

/// The way back one level: a slim tile of the same card at the head of an
/// engine's or a category's rail, naming where the player is ([here]) over a
/// short bar in that level's colour — the one mark of which level is open —
/// and, under it, where the tile goes back to ([back]): every game from
/// inside an engine, the engine from inside one of its categories. The system
/// Back key does the same (main.dart's `_BackGuard`).
///
/// A tile in the rail rather than a bar above it: the rail's height is what
/// the square cards are cut from, and on a 360dp phone there is none to spare.
/// It stays lighter than the cards beside it — no light behind it, a neutral
/// key, the level's colour spent on one bar (owner, 24 Sep 2026: "do not make
/// the navigation visually heavier than the game cards").
class _BackTile extends StatelessWidget {
  const _BackTile({
    required this.here,
    required this.back,
    required this.accent,
  });

  /// The level being shown, already in the player's language.
  final String here;

  /// The level Back leads to.
  final String back;

  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final glass = GlassColors.of(context);

    return Padding(
      padding: const EdgeInsets.only(right: Space.lg),
      child: LayoutBuilder(
        builder: (context, box) {
          // A quarter of a card, and never less than a finger and its margins
          // — the width the rail sizes its cards around (lobbyRailSide).
          final width = _backTileWidth(box.maxHeight);
          final disc = math.min(width - Space.xl, Dim.minTouch);
          return SizedBox(
            width: width,
            child: Semantics(
              button: true,
              label: back,
              child: _Pressable(
                onTap: () {
                  tapHaptic(context);
                  context.read<GameState>().closeLobbyLevel();
                },
                child: GameCard(
                  accent: accent,
                  lit: false,
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.sm,
                    vertical: Space.md,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // The key itself: a neutral well, so it reads as the
                      // way out and not as one more thing in the level's
                      // colour.
                      Container(
                        width: disc,
                        height: disc,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: glass.wellFill,
                          border: Border.all(color: glass.cardBorder),
                        ),
                        child: Icon(
                          Icons.arrow_back_rounded,
                          size: disc * 0.5,
                          color: glass.textDisplay,
                        ),
                      ),
                      const SizedBox(height: Space.lg),
                      // Where the player is. A name of two words or more
                      // stands on two lines: "Texas Hold'em" on one line was
                      // scaled to a third of its size to fit the tile, and
                      // read smaller than the muted line under it.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          _onTwoLines(here),
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          style: AppTheme.label(
                            text.labelLarge!,
                            colour: glass.textDisplay,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: Space.sm),
                      // The open level, marked in its own colour.
                      Container(
                        width: Space.xl,
                        height: 3,
                        decoration: BoxDecoration(
                          color: accent,
                          borderRadius: BorderRadius.circular(Radii.pill),
                        ),
                      ),
                      const SizedBox(height: Space.sm),
                      // Where Back leaves for.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          back,
                          maxLines: 1,
                          style: text.labelSmall?.copyWith(
                            color: glass.cardMuted,
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
      ),
    );
  }
}

/// [name] broken at the space nearest its middle, so its two lines are as
/// even as its words allow; a single word is left whole.
String _onTwoLines(String name) {
  final words = name.trim();
  var best = -1;
  for (var i = 0; i < words.length; i++) {
    if (words[i] != ' ') continue;
    if (best < 0 ||
        (words.length - 2 * i).abs() < (words.length - 2 * best).abs()) {
      best = i;
    }
  }
  if (best < 0) return words;
  return '${words.substring(0, best).trimRight()}\n'
      '${words.substring(best + 1).trimLeft()}';
}

/// One boot table. Requirement 28: square, and lit by a sweep that runs across
/// its badge — the one piece of motion on the card itself.
///
/// Read top to bottom in the order a player chooses by (owner, 24 Sep 2026):
/// what kind of table (the badge), the boot — the largest figure on the card,
/// in gold, over its name — what the table is like, its terms, and the key.
/// The mode's colour marks the badge, the chips, the facts' glyphs, the light
/// behind the card and its key, so the room a player lands in is recognisably
/// the card they tapped without the card itself being painted.
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
    final glass = GlassColors.of(context);
    final state = context.watch<GameState>();
    final t = state.t;
    final blind = category == TableCategory.blind;
    // A third category, not "the one that is not blind": a variation table
    // bets as a seen table does and keeps stacks hidden as a blind one does
    // (owner, 18 Sep 2026), and it is a card of its own with its own name and
    // its own line about what happens there.
    final variation = category == TableCategory.variation;
    // A poker table is a different game altogether: its badge names the game
    // (Texas Hold'em, Omaha, 5-Card Draw, 3-Card Poker), its blurb says how
    // that game is played, and its facts are the blinds or the ante, the
    // buy-in and the cards each player is dealt — there are no blind moves
    // and no pot limit to state.
    final poker = table.isPoker;
    // Each mode has a colour of its own — gold, sapphire, violet, teal — and
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
              // number, its side (_CardMetrics). The column above the call to
              // action is allowed the height the key leaves and scales down
              // past it rather than overflowing, so the card can never stripe
              // itself; at 1.0 text on the phones it is sized for, it fits.
              final m = _CardMetrics(box.maxHeight);
              // The two corner keys stand over the card's top-right corner
              // (withInfo, below): their discs reach 40dp in from the card's
              // edge and 84dp down from its top, which the margin covers in
              // part. Nothing in the column starts beside them without
              // stopping a step short of them.
              final keys = Size(
                _cornerKeysReach.width + CardSpace.s8 - m.pad,
                _cornerKeysReach.height - m.pad,
              );

              // Glass, not the table's cloth (owner's decision, 11 Sep 2026): the
              // lobby sits on the same obsidian / frosted-ice ground as every
              // other covering surface, and the stake, the badge and the chips
              // carry the table's colour instead of a whole painted card. A
              // table shut to the player keeps its card and loses its light.
              return GameCard(
                accent: accent,
                lit: !shut,
                padding: EdgeInsets.all(m.pad),
                child: LayoutBuilder(
                  builder: (context, inner) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Everything above the call to action is allowed the
                      // height the capsule leaves and no more, and scales
                      // down rather than overflowing past it. The rows are
                      // sized from the card, but their text is set in the
                      // player's script, and Devanagari stands taller than
                      // Latin: the shut BLIND 10 Lakh card on a 640dp phone
                      // ran 0.665px past its foot in Hindi and striped its
                      // key. Wherever it fits the scale is 1 and nothing
                      // moves; where it does not, it still spans the card,
                      // and at any scale it stops short of the corner keys
                      // (CardColumn).
                      CardColumn(
                        maxHeight: math.max(
                          0.0,
                          inner.maxHeight - m.ctaH - m.ctaGap,
                        ),
                        keepClear: keys,
                        children: [
                          _CategoryBadge(
                            label: _tableName(state, table),
                            palette: palette,
                            height: m.plateH,
                            // The two cards at the same stake sit side
                            // by side, so their badges are offset
                            // rather than pulsing together. The
                            // variation card takes the beat between
                            // them.
                            delay: Duration(
                              milliseconds: blind
                                  ? 900
                                  : variation
                                  ? 450
                                  : poker
                                  ? 300
                                  : 0,
                            ),
                          ),
                          CardGap(m.headGap),
                          // The boot is what a player chooses a table
                          // by, so it is the largest figure on the card
                          // (owner, 24 Sep 2026: "make it visually
                          // prominent"), in gold, over its name — and
                          // then, in the final pass, "prominent but not
                          // dominating": a step under a group card's
                          // name (_CardMetrics.bootSize), where it had
                          // stood twice the height of every other word
                          // on the card. It counts up on first paint,
                          // so the stake lands rather than simply being
                          // there.
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              LivelyChipStack(
                                size: m.bootSize * 0.56,
                                colours: [accent, palette.rimLow],
                              ),
                              SizedBox(width: m.markGap),
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
                                          fontSize: m.bootSize,
                                          colour: _goldInk(brightness),
                                        ).copyWith(height: 1.0),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          // Its name under it, set small and tracked
                          // as a caption where the script allows —
                          // BOOT in English; tracking pulls Indic
                          // vowel signs off their letters, so the
                          // other languages keep their own case and
                          // spacing.
                          // Under the figure by a hair more than its
                          // line, which its comma hangs below.
                          Padding(
                            padding: EdgeInsets.only(
                              left: m.bootSize * 0.56 + m.markGap,
                              top: CardSpace.s4,
                            ),
                            child: Text(
                              state.lang == AppLang.english
                                  ? t.boot.toUpperCase()
                                  : t.boot,
                              style:
                                  AppTheme.label(
                                    text.labelSmall!,
                                    colour: glass.cardMuted,
                                  ).copyWith(
                                    height: 1.0,
                                    letterSpacing: state.lang == AppLang.english
                                        ? 1.4
                                        : 0,
                                  ),
                            ),
                          ),
                          CardGap(m.gap),
                          // One blurb line a card, so every card
                          // keeps the same rhythm down to its key: a
                          // variation card says what makes it
                          // different rather than the chips line —
                          // with both lines the Entry row sat against
                          // the key, and the smallest phone scaled the
                          // whole column down to fit. Always the
                          // body's ink, under the figure and the facts
                          // (owner's final pass: "body descriptions
                          // clearly secondary"); the variation and
                          // poker lines, which say how the game
                          // differs, a half-step heavier. A third line
                          // rather than a cut-off one when a long
                          // translation wraps at a large text size.
                          Text(
                            poker
                                ? t.pokerVariantNote(category)
                                : variation
                                ? t.variationTableNote
                                : blind
                                ? t.onlyYourChips
                                : t.everyoneChips,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              fontSize: m.blurbSize,
                              fontWeight: variation || poker
                                  ? FontWeight.w500
                                  : null,
                              color: glass.textBody,
                            ),
                          ),
                          CardGap(m.gap),

                          // What the room actually plays like, stated
                          // before the player sits down rather than
                          // discovered at the table. A poker table
                          // states its own terms.
                          if (poker) ...[
                            for (final fact in _pokerFacts(
                              t,
                              table,
                            ).indexed) ...[
                              if (fact.$1 > 0) _FactRule(space: m.ruleSpace),
                              _CardFact(
                                icon: fact.$2.icon,
                                palette: palette,
                                label: fact.$2.label,
                                value: fact.$2.value,
                                height: m.factH,
                                highlight: fact.$2.highlight,
                              ),
                            ],
                          ] else ...[
                            _CardFact(
                              icon: Icons.visibility_off_rounded,
                              palette: palette,
                              label: t.maxBlindsLabel,
                              value: '${table.maxBlindMoves}',
                              height: m.factH,
                            ),
                            _FactRule(space: m.ruleSpace),
                            _CardFact(
                              icon: Icons.savings_rounded,
                              palette: palette,
                              label: t.potLimitLabel,
                              height: m.factH,
                              value: table.potUncapped
                                  ? t.potUnlimited
                                  : formatChips(table.maxPot),
                              // An uncapped pot is the headline on a
                              // blind table, so it is the one fact
                              // drawn in the table's colour.
                              highlight: table.potUncapped,
                              money: !table.potUncapped,
                            ),
                          ],
                          _FactRule(space: m.ruleSpace),
                          _CardFact(
                            icon: Icons.account_balance_wallet_rounded,
                            palette: palette,
                            label: t.entryLabel,
                            value: entryValue,
                            height: m.factH,
                            // A floor is the fact that makes a table
                            // aspirational, so it is worth the colour.
                            highlight: table.minChips > 0,
                          ),
                        ],
                      ),
                      // Takes up whatever is left over, and nothing when
                      // there is nothing left over.
                      const Spacer(),
                      _SitCapsule(
                        label: t.tapToSit,
                        height: m.ctaH,
                        enabled: !shut,
                        palette: palette,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    // The info key rides over the card's top-right corner, above everything —
    // the shut card's fade and its caption included, because a table a player
    // is being kept out of is the one whose terms they most want to read.
    Widget withInfo(Widget body) => Stack(
      children: [
        body,
        Positioned(
          top: Space.xs,
          // Inside the card, which ends Space.lg short of its slot.
          right: Space.lg + Space.xs,
          // Two keys, one over the other, so each keeps a full 44dp target
          // and neither reaches the badge: what the table IS, and how it
          // PLAYS.
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CardCornerKey(
                icon: Icons.info_outline_rounded,
                label: state.t.tableInfoTitle,
                palette: palette,
                onTap: () => _showTableInfo(
                  context,
                  table: table,
                  entryValue: entryValue,
                ),
              ),
              _CardCornerKey(
                icon: Icons.menu_book_outlined,
                label: state.t.tableRulesKey,
                palette: palette,
                onTap: () => showRules(context, table: table),
              ),
            ],
          ),
        ),
      ],
    );

    if (!shut) return withInfo(card);

    // Faded back and captioned. Translucent rather than opaque, so the stake is
    // still readable — a player should be able to see the table they are being
    // kept out of — and reserved rather than alarmed: being under the entry cap
    // is a rule of the room, not a mistake the player made.
    return withInfo(
      Stack(
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
                    // The card's own body, so the notice reads as solid over
                    // the faded card rather than as a hole in it.
                    surface: GlassSurface.card,
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
      ),
    );
  }
}

/// One fact on a poker table's card or in its info popup.
typedef _PokerFact = ({
  IconData icon,
  String label,
  String value,
  bool highlight,
});

/// What a poker table's card states in place of blind moves and a pot limit:
/// the blinds ("100 / 200") or the ante, the buy-in and the cards dealt to
/// each player — and, on 5-Card Draw alone, how many may be exchanged. Every
/// figure is the server's own menu entry.
List<_PokerFact> _pokerFacts(Strings t, LobbyTable table) => [
  if (table.smallBlind > 0 || table.bigBlind > 0)
    (
      icon: Icons.toll_rounded,
      label: t.blindsLabel,
      value:
          '${formatChips(table.smallBlind)} / '
          '${formatChips(table.bigBlind > 0 ? table.bigBlind : table.bootAmount)}',
      highlight: false,
    )
  else
    (
      icon: Icons.toll_rounded,
      label: t.anteLabel,
      value: formatChips(table.ante > 0 ? table.ante : table.bootAmount),
      highlight: false,
    ),
  (
    icon: Icons.login_rounded,
    label: t.buyInLabel,
    value: table.minBuyIn > 0
        ? t.buyInFrom(formatChips(table.minBuyIn))
        : t.entryOpen,
    // The buy-in is what makes a table one to play towards.
    highlight: table.minBuyIn > 0,
  ),
  if (table.holeCards > 0)
    (
      icon: Icons.style_rounded,
      label: t.holeCardsLabel,
      value: '${table.holeCards}',
      highlight: false,
    ),
  if (table.maxDiscards > 0)
    (
      icon: Icons.swap_horiz_rounded,
      label: t.maxDiscardsLabel,
      value: '${table.maxDiscards}',
      highlight: false,
    ),
];

/// The disc a [_CardCornerKey] draws inside its 44dp target.
const double _cornerDisc = 28;

/// How far a table card's two corner keys reach into it — their discs, from
/// the card's right edge and from its top: the pair stands [Space.xs] in from
/// both (the withInfo Stack in [_TableCard]), one 44dp target over the other.
const Size _cornerKeysReach = Size(
  Space.xs + (Dim.minTouch + _cornerDisc) / 2,
  Space.xs + 2 * Dim.minTouch - (Dim.minTouch - _cornerDisc) / 2,
);

/// A key on a table card's top-right corner. There are two, one over the other
/// (owner, 18 Sep 2026): **ⓘ** — "every table give an info icon on the right top
/// side; on clicking it, it will open a pop up showing table info … it tells all
/// info" — and the **rules** key under it — "one more icon on the card; clicking
/// it shows the rules according to the table he selected".
///
/// Each is a key of its own inside a card that is itself one big key: the inner
/// tap wins the gesture arena, so touching one opens its popup and never sits
/// the player down. A full 44dp target around a small glyph.
class _CardCornerKey extends StatelessWidget {
  const _CardCornerKey({
    required this.icon,
    required this.label,
    required this.palette,
    required this.onTap,
  });

  final IconData icon;

  /// What the key is called, for a screen reader and for tests.
  final String label;
  final TablePalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = palette.accent;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          tapHaptic(context);
          onTap();
        },
        child: SizedBox.square(
          dimension: Dim.minTouch,
          child: Center(
            // A small key in the mode's colour, quieter than the card's own
            // key at its foot: a glyph in the accent on a whisper of it.
            child: Container(
              width: _cornerDisc,
              height: _cornerDisc,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: dark ? 0.10 : 0.06),
                border: Border.all(
                  color: accent.withValues(alpha: dark ? 0.34 : 0.30),
                ),
              ),
              child: Icon(icon, size: 16, color: palette.ink),
            ),
          ),
        ),
      ),
    );
  }
}

/// Everything the server says about one table, in a popup over the lobby.
///
/// Every figure is the menu's own ([LobbyTable], [GameConfig]) — the numbers
/// the door enforces — so the popup cannot promise terms the table does not
/// keep. It closes itself if the player is taken to a table while it is open
/// (main.dart's `_TableRoutes` pops what was opened over a screen that went).
Future<void> _showTableInfo(
  BuildContext context, {
  required LobbyTable table,
  required String entryValue,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: AppTheme.ink900.withValues(alpha: 0.55),
    builder: (context) =>
        _TableInfoDialog(table: table, entryValue: entryValue),
  );
}

class _TableInfoDialog extends StatelessWidget {
  const _TableInfoDialog({required this.table, required this.entryValue});

  final LobbyTable table;
  final String entryValue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final glass = GlassColors.of(context);
    final state = context.watch<GameState>();
    final t = state.t;
    final category = GameState.lobbyCategoryOf(table);
    final palette = AppTheme.paletteFor(
      theme.colorScheme,
      category: table.category,
      bootAmount: table.bootAmount,
    );
    final accent = palette.accent;
    final chips = state.user?.chips ?? 0;
    final shut = state.tableShut(table);
    final players = state.config.maxPlayers == 0 ? 5 : state.config.maxPlayers;
    // The table's own clock where the catalogue names it — a poker room's is
    // not the Teen Patti one — else the table-wide figure, as before.
    final ownTurnMs = table.turnTimeoutMs ?? 0;
    final turnMs = ownTurnMs > 0 ? ownTurnMs : state.config.turnTimeoutMs;
    final turnSeconds = (turnMs / 1000).round();

    // Only a seen table shows every stack. Blind, variation and every poker
    // room (owner, 19 Sep 2026) keep them to their owners.
    final poker = table.isPoker;
    final chipsShown = category == TableCategory.seen && !poker
        ? t.everyoneChips
        : t.onlyYourChips;
    // What the popup calls the table: what its own card's badge calls it.
    final name = _tableName(state, table);

    // Whether this player can sit, and if not, what it would take.
    final String standing;
    if (!shut) {
      standing = chips >= table.bootAmount ? t.canSitHere : '';
    } else if (table.tooPoor(chips)) {
      standing = t.lockedBody.replaceFirst(
        '{min}',
        formatChips(table.minChips),
      );
    } else {
      standing = t.cappedBody.replaceFirst(
        '{cap}',
        formatChips(
          table.maxChips > 0 ? table.maxChips : state.config.entryCapMaxChips,
        ),
      );
    }

    Widget fact(
      IconData icon,
      String label,
      String value, {
      bool bold = false,
    }) => _CardFact(
      icon: icon,
      palette: palette,
      label: label,
      value: value,
      height: 26,
      highlight: bold,
    );
    Widget rule() => const _FactRule(space: Space.xs);

    final facts = <Widget>[
      fact(Icons.style_rounded, t.categoryLabel, name),
      // A poker table's own terms — the blinds or the ante, the buy-in, the
      // cards dealt — in place of the boot, the blind moves and the pot limit
      // it does not have.
      if (poker) ...[
        for (final row in _pokerFacts(t, table))
          fact(row.icon, row.label, row.value, bold: row.highlight),
      ] else ...[
        fact(Icons.toll_rounded, t.boot, formatChips(table.bootAmount)),
      ],
      fact(
        Icons.account_balance_wallet_rounded,
        t.entryLabel,
        entryValue,
        bold: table.minChips > 0,
      ),
      if (!poker) ...[
        fact(
          Icons.visibility_off_rounded,
          t.maxBlindsLabel,
          '${table.maxBlindMoves}',
        ),
        fact(
          Icons.savings_rounded,
          t.potLimitLabel,
          table.potUncapped ? t.potUnlimited : formatChips(table.maxPot),
          bold: table.potUncapped,
        ),
      ],
      fact(Icons.groups_rounded, t.playersLabel, t.playersUpTo(players)),
      if (turnSeconds > 0)
        fact(Icons.timer_outlined, t.turnTimeLabel, t.secondsEach(turnSeconds)),
      fact(Icons.account_balance_rounded, t.yourChipsLabel, formatChips(chips)),
    ];

    return GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      maxWidth: 420,
      title: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 20, color: accent),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              '${t.tableInfoTitle} · $name ${formatChips(table.bootAmount)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.label(text.titleMedium ?? const TextStyle()),
            ),
          ),
          PressScale(
            child: IconButton(
              tooltip: t.close,
              icon: const Icon(Icons.close_rounded, size: 20),
              onPressed: () => Navigator.pop(context),
              style: IconButton.styleFrom(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                minimumSize: const Size.square(Dim.minTouch),
              ),
            ),
          ),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // What happens at this kind of table, then who sees whose chips.
          if (category == TableCategory.variation || poker) ...[
            Text(
              poker ? t.pokerVariantNote(table.category) : t.variationTableNote,
              style: text.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: glass.textDisplay,
              ),
            ),
            const SizedBox(height: Space.xxs),
          ],
          Text(
            chipsShown,
            style: text.bodySmall?.copyWith(color: glass.textBody),
          ),
          const SizedBox(height: Space.md),
          for (final (i, row) in facts.indexed) ...[if (i > 0) rule(), row],
          if (standing.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            PremiumGlassPanel(
              mode: GlassMode.tinted,
              radius: Radii.sm,
              elevated: false,
              padding: const EdgeInsets.all(Space.md),
              child: Row(
                children: [
                  Icon(
                    shut
                        ? (table.tooPoor(chips)
                              ? Icons.trending_up_rounded
                              : Icons.lock_outline_rounded)
                        : Icons.check_circle_outline_rounded,
                    size: 18,
                    color: shut ? glass.textMuted : accent,
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Text(
                      standing,
                      style: text.bodySmall?.copyWith(color: glass.textBody),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The card's one call to action, at its foot.
///
/// A capsule of glass laid on the card rather than a line of coloured text:
/// it is the only action on the card and it used to read as a caption. It is
/// not a button of its own — the whole card is the target — so it carries no
/// ink response and is not held to a touch-target height.
///
/// Neutral glass with the mode's accent in its edge, a breath of it in its
/// fill and on its arrow (owner, 24 Sep 2026: "SEEN gold border/highlight;
/// BLIND cyan…; do NOT make buttons excessively bright"): clearly the thing to
/// press, never a block of colour. The label stays in the card's own ink, the
/// most legible thing on it. A shut table's key is a quiet outline.
class _SitCapsule extends StatelessWidget {
  const _SitCapsule({
    required this.label,
    required this.height,
    required this.enabled,
    required this.palette,
  });

  final String label;
  final double height;
  final bool enabled;
  final TablePalette palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = palette.accent;
    final ink = enabled
        ? glass.textDisplay
        : theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkLow);

    return Container(
      height: height,
      // Full width: it is the card's foot rail, and a capsule that hugs its
      // own label reads as a caption again.
      width: double.infinity,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: CardSpace.s12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.pill),
        // A pane laid on the card, lit from above, with the mode's colour
        // washed through it: stronger by night, where glass on charcoal
        // otherwise reads as nothing, a breath by day (turned down in the
        // owner's final pass: "keep the hues, reduce the tint").
        gradient: enabled
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.alphaBlend(
                    accent.withValues(alpha: dark ? 0.14 : 0.06),
                    dark ? Colors.white.withValues(alpha: 0.08) : Colors.white,
                  ),
                  Color.alphaBlend(
                    accent.withValues(alpha: dark ? 0.07 : 0.03),
                    dark
                        ? Colors.white.withValues(alpha: 0.03)
                        : const Color(0xFFF7F8FA),
                  ),
                ],
              )
            : null,
        border: Border.all(
          color: enabled
              ? accent.withValues(alpha: dark ? 0.48 : 0.50)
              : glass.cardBorder,
          width: enabled ? 1.2 : Dim.hairline,
        ),
        // Lifted a little off the card, and no further: a shadow is what says
        // "press me" without a colour having to shout it.
        boxShadow: enabled
            ? [
                BoxShadow(
                  color: AppTheme.shadowFor(
                    theme.brightness,
                  ).withValues(alpha: dark ? 0.30 : 0.08),
                  offset: const Offset(0, 2),
                  blurRadius: 6,
                  spreadRadius: -1,
                ),
              ]
            : null,
      ),
      // Shrunk to the key when a translation will not fit it, never cut
      // short: "Tap to sit down" is what the whole card is for.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: AppTheme.label(
                theme.textTheme.labelMedium!,
                fontSize: (height * 0.40).clamp(12.0, 15.0),
                colour: ink,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: CardSpace.s8),
            Icon(
              Icons.arrow_forward_rounded,
              size: (height * 0.46).clamp(14.0, 19.0),
              color: enabled ? palette.ink : ink,
            ),
          ],
        ),
      ),
    );
  }
}

/// One line of small print on a lobby card: an icon, what it is, and what it
/// is set to.
///
/// The icon carries the meaning at a glance, in the mode's colour, and the
/// value is what the eye lands on — money in gold, a notable fact in the
/// mode's colour, the rest in the card's strongest ink — so the label between
/// them is deliberately the quietest part.
class _CardFact extends StatelessWidget {
  const _CardFact({
    required this.icon,
    required this.palette,
    required this.label,
    required this.value,
    required this.height,
    this.highlight = false,
    this.money = false,
    this.quiet = false,
  });

  final IconData icon;
  final TablePalette palette;
  final String label;
  final String value;

  /// The row's own box, so two rows and the rule between them are a known
  /// height on the card's column: 15.4 on a 640x360 phone's card, 16.7 on a
  /// 915x412 one's, 24-26 on a tablet's.
  final double height;

  /// Draws the value in the mode's own colour, for the fact worth noticing.
  final bool highlight;

  /// Draws the value in gold: a stake, a buy-in — money.
  final bool money;

  /// Draws the value in the quiet ink: a count of nothing.
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final glass = GlassColors.of(context);
    final size = (height * 0.66).clamp(11.0, 15.0);
    final valueInk = highlight
        ? palette.ink
        : money
        ? _goldInk(theme.brightness)
        : quiet
        ? glass.cardMuted
        : glass.textDisplay;
    // The row is never shorter than its words' own glyphs, which at a large
    // text size stood taller than the box; the card's column scales down to
    // hold the taller rows instead of clipping their tops and tails.
    final glyphs = MediaQuery.textScalerOf(context).scale(size) * 1.2;

    return SizedBox(
      height: math.max(height, glyphs),
      child: Row(
        children: [
          Icon(
            icon,
            size: (height * 0.78).clamp(13.0, 19.0),
            color: palette.ink.withValues(alpha: 0.80),
          ),
          const SizedBox(width: CardSpace.s8),
          // What the fact is, shrunk to the room the value leaves rather
          // than cut ("bo…" beside "200 – 10 Lakh" at a large text size): the
          // value is what the eye comes for, so it keeps its size. Set on the
          // value's line height, so the two sit on one baseline and the label
          // is never shrunk for height the row does not have.
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                style: text.bodySmall?.copyWith(
                  fontSize: size,
                  height: text.labelLarge?.height,
                  color: glass.textBody,
                ),
              ),
            ),
          ),
          const SizedBox(width: CardSpace.s8),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.money(
              text.labelLarge!,
              fontSize: size,
              colour: valueInk,
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
              // A glow that rises with the light and is gone between passes:
              // restrained, so a rail of badges never reads as flashing.
              boxShadow: [
                BoxShadow(
                  color: palette.accent.withValues(alpha: 0.16 * glow),
                  blurRadius: 10 + 6 * glow,
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
                          // What kind of table this is — the first thing on
                          // the card a player reads, so never under 11dp
                          // (it was 10 on a 640dp phone's card).
                          child: Text(
                            widget.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTheme.label(
                              theme.textTheme.labelLarge!,
                              fontSize: (h * 0.44).clamp(11.0, 15.0),
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
                                alpha: dark ? 0.20 : 0.34,
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

/// The last card on the front of the rail, after the engines: a room only
/// the player's own friends can find.
///
/// Built from the same card and the same square footprint as the others, in
/// the house emerald rather than a game's colour (owner, 24 Sep 2026:
/// "PRIVATE TABLE: Emerald / Green"), so the rail has one rhythm and several
/// identities rather than products and a form.
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
    final text = theme.textTheme;
    final brightness = theme.brightness;
    final glass = GlassColors.of(context);
    final cap = state.config.privateMaxPot;
    final palette = AppTheme.privatePalette(theme.colorScheme);

    return Padding(
      padding: const EdgeInsets.only(right: Space.lg),
      child: AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(
          builder: (context, box) {
            // The same sizes as a table card. The code field and the keys
            // stand together on the card's foot, a field and the key that
            // joins with it; the name and its line hold the top, and scale
            // down rather than run past the field when a large text size
            // makes them taller than the room the foot leaves (at 1.3x on a
            // 640dp phone the line wanted a third row it was denied, and was
            // cut off mid-sentence).
            final m = _CardMetrics(box.maxHeight);

            return GameCard(
              accent: palette.accent,
              padding: EdgeInsets.all(m.pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: CardColumn(
                        children: [
                          Row(
                            children: [
                              _ModeMark(palette: palette, size: m.plateH),
                              SizedBox(width: m.markGap),
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    state.t.privateTable,
                                    maxLines: 1,
                                    style: AppTheme.label(
                                      text.titleLarge!,
                                      colour: glass.textDisplay,
                                      weight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          CardGap(m.gap),
                          Text(
                            'Boot ${formatChips(state.config.privateBoot)}'
                            '${cap > 0 ? ', max win ${formatChips(cap)}' : ''}.'
                            ' Share the code to fill the seats.',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              fontSize: m.blurbSize,
                              color: glass.textBody,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: m.gap),
                  Text(
                    state.t.orJoinCode,
                    style: AppTheme.label(
                      text.labelSmall!,
                      colour: glass.cardMuted,
                    ),
                  ),
                  const SizedBox(height: CardSpace.s4),
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
                            (_, value) =>
                                value.copyWith(text: value.text.toUpperCase()),
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
                          // the hint read "ट ब ल क ो ड"; over the English
                          // hint the code's full 6dp ran it past the field
                          // at a large text size ("TABLE C…"), so the hint
                          // keeps a lighter tracking of its own.
                          hintStyle: TextStyle(
                            letterSpacing: state.lang == AppLang.english
                                ? 2
                                : 0,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: m.gap),
                  Row(
                    children: [
                      // The card's primary action, in its own emerald: the
                      // key's edge and a breath of it through the glass, as
                      // every card's key has its mode's (owner, 24 Sep
                      // 2026) — not the solid mint slab it was, the one
                      // bright block on the rail.
                      Expanded(
                        child: SizedBox(
                          height: Dim.minTouch,
                          child: GlassButton(
                            style: GlassButtonStyle.glass,
                            onPressed: state.createPrivate,
                            buttonStyle: _accentKeyStyle(palette, brightness),
                            child: _CardKeyLabel(state.t.create),
                          ),
                        ),
                      ),
                      const SizedBox(width: CardSpace.s8),
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
                            buttonStyle: _cardKeyStyle,
                            child: _CardKeyLabel(state.t.join),
                          ),
                        ),
                      ),
                    ],
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

/// A mode's mark on a card: its glyph in the mode's ink, in a disc of its
/// colour — the private card's padlock, where a game card has its chips.
class _ModeMark extends StatelessWidget {
  const _ModeMark({required this.palette, required this.size});

  final TablePalette palette;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: palette.accent.withValues(alpha: dark ? 0.12 : 0.07),
        border: Border.all(
          color: palette.accent.withValues(alpha: dark ? 0.38 : 0.32),
        ),
      ),
      child: Icon(palette.icon, size: size * 0.56, color: palette.ink),
    );
  }
}

/// The private card's two keys stand side by side in half a card: Material's
/// 24dp of padding a side left "তৈরি করুন" (Bengali, Create) no room on a
/// 640dp phone, and it was cut to "তৈরি ..." (24 Sep 2026, owner's "fix all
/// bugs"; release review B2). A key keeps a small margin and its word whole.
const _cardKeyStyle = ButtonStyle(
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Space.sm)),
);

/// [_cardKeyStyle] for a card's primary key: glass with the mode's accent in
/// its edge and washed through its fill — stronger by night, where tinted
/// glass on charcoal is otherwise nothing — and the card's own ink on it.
ButtonStyle _accentKeyStyle(TablePalette palette, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final accent = palette.accent;
  final glass = dark ? GlassColors.dark : GlassColors.light;
  return _cardKeyStyle.copyWith(
    backgroundColor: WidgetStatePropertyAll(
      Color.alphaBlend(
        accent.withValues(alpha: dark ? 0.16 : 0.07),
        dark ? Colors.white.withValues(alpha: 0.06) : Colors.white,
      ),
    ),
    side: WidgetStatePropertyAll(
      BorderSide(
        color: accent.withValues(alpha: dark ? 0.58 : 0.55),
        width: 1.2,
      ),
    ),
    foregroundColor: WidgetStatePropertyAll(glass.textDisplay),
    overlayColor: WidgetStatePropertyAll(accent.withValues(alpha: 0.12)),
  );
}

/// A private-card key's word, whole: shrunk to the key when it must be, never
/// cut off.
class _CardKeyLabel extends StatelessWidget {
  const _CardKeyLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(text, maxLines: 1, softWrap: false),
  );
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
  final order = ValueNotifier<PictureSort>(PictureSort.lowToHigh);

  // The grid follows both through ONE merged listenable, made here. A
  // Listenable.merge built in the sheet's builder is a new object on every
  // rebuild, so the grid re-subscribed each time — and the lobby's one-second
  // tick rebuilds the sheet while it animates out, after the notifiers are
  // disposed below: a red screen on closing the picker (14 Sep 2026).
  final shelfAndOrder = Listenable.merge([shelf, order]);

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
                      // wallet — chips, hammers or diamonds — and, on the right,
                      // which way its prices run (owner, 14 Sep 2026). Pinned
                      // above the grid rather than scrolling with it, and it
                      // stands in for the headings the tiers used to carry — one
                      // shelf is on show at a time.
                      Row(
                        children: [
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
                          const Spacer(),
                          ValueListenableBuilder<PictureSort>(
                            valueListenable: order,
                            builder: (context, current, _) => PictureSortMenu(
                              value: current,
                              onChanged: (s) {
                                order.value = s;
                                if (scroller.hasClients) scroller.jumpTo(0);
                              },
                            ),
                          ),
                          // In line with the grid's edge, clear of its scrollbar.
                          const SizedBox(width: Space.md),
                        ],
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
                              child: ListenableBuilder(
                                listenable: shelfAndOrder,
                                builder: (context, _) => pictureShelf(
                                  context: context,
                                  state: state,
                                  filter: shelf.value,
                                  sort: order.value,
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
  order.dispose();
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

/// The shell both right-hand panels share: a head that stays put and, under
/// it, a list that scrolls (the settings polish, 26 Sep 2026: "fixed header,
/// scrollable settings content, stable close button"). The head used to be the
/// list's first row and scrolled away with it, and the way out went with it.
///
/// Not [GlassDrawerPanel]: that one aligns its body to the start edge, which is
/// right for a left drawer and would put these panels on the opposite side of
/// the screen from the edge they slide in on.
class _LobbyDrawer extends StatelessWidget {
  const _LobbyDrawer({required this.head, required this.children});

  /// The title, which does not scroll.
  final Widget head;

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
          behind: const _DrawerBody(),
          child: SafeArea(
            // Landscape leaves very little height, so the list scrolls rather
            // than overflowing — which is what was clipping the name off the
            // top. It also stops short of the keyboard: the lobby is not
            // resized for it, so the list shrinks instead and scrolls a
            // focused field (the display name) into what is left, under the
            // head, which stays.
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  head,
                  const _DrawerRule(space: 0),
                  Expanded(
                    // Faded at an edge only while there is more beyond it, so
                    // a row the head's rule cuts through reads as "there is
                    // more" rather than as clipped by accident.
                    child: EdgeFade(
                      extent: Space.lg,
                      child: ListView(
                        padding: const EdgeInsets.only(
                          top: Space.xs,
                          bottom: Space.lg,
                        ),
                        children: children,
                      ),
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

/// What the two drawers are made of, laid over their glass (the settings
/// polish, 26 Sep 2026): by night the lobby cards' own charcoal
/// ([GlassColors.cardFill]) — not the near-black the bare glass was over the
/// dimmed room, which the drawer all but disappeared into — and by day the
/// warm pearl the table's room is ([TableGround.pearl]) rather than the grey
/// milk-glass over the dimmed room made, which was the drawer's whole colour.
///
/// Mostly opaque, so the glass under it shows as a breath of frost rather
/// than as the room. Lerped on the ground's own lightness rather than chosen
/// by brightness, so the appearance control inside the drawer cross-fades it
/// with everything else instead of snapping it halfway through.
class _DrawerBody extends StatelessWidget {
  const _DrawerBody();

  static final double _nightGround = GlassColors.dark.ground.computeLuminance();
  static final double _dayGround = GlassColors.light.ground.computeLuminance();

  /// How far the theme's cross-fade has come from obsidian (0) to ice (1),
  /// read off the ground colour, which lerps with the rest of the theme.
  static double dayOf(GlassColors glass) =>
      ((glass.ground.computeLuminance() - _nightGround) /
              (_dayGround - _nightGround))
          .clamp(0.0, 1.0);

  /// A warm stone well under the pearl.
  static final Color _stoneWell = Color.alphaBlend(
    TableGround.pearlEdge.withValues(alpha: 0.55),
    TableGround.pearl,
  );

  /// The fill of what is sunk into the drawer — the two fields and the
  /// appearance control: the theme's own well by night, and by day a warm
  /// stone rather than the theme's cool slate, which read grey-blue on the
  /// pearl.
  static Color well(GlassColors glass) =>
      Color.lerp(glass.wellFill, _stoneWell, dayOf(glass)) ?? glass.wellFill;

  @override
  Widget build(BuildContext context) {
    final glass = GlassColors.of(context);
    final day = dayOf(glass);
    final pearl = TableGround.pearl;
    final stone = Color.lerp(pearl, TableGround.pearlEdge, 0.4)!;
    Color at(Color night, Color dayColour) =>
        Color.lerp(night, dayColour, day) ?? night;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            at(GlassColors.dark.cardFill, pearl.withValues(alpha: 0.94)),
            at(GlassColors.dark.cardFillEnd, stone.withValues(alpha: 0.96)),
          ],
        ),
      ),
    );
  }
}

/// A drawer's title row: a mark, what the panel is, a line under it, and the
/// way out. Kept short on purpose: in a landscape drawer every line the head
/// takes is a line the list does not get.
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
    // While the keyboard is up the line under the title steps aside, as the
    // table's chat drawer drops its title while typing: a landscape keyboard
    // leaves the list a band barely taller than the field being typed in.
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.md,
        Space.xs,
        Space.md,
      ),
      child: Row(
        children: [
          leading,
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
                    text.titleMedium!,
                    weight: FontWeight.w700,
                  ),
                ),
                if (caption != null)
                  AnimatedSize(
                    duration: Motion.base,
                    curve: Motion.standard,
                    alignment: Alignment.topLeft,
                    child: typing
                        ? const SizedBox(width: double.infinity)
                        : Text(
                            caption,
                            // Two lines rather than one cut short: the drawer
                            // is 260dp on a 640dp phone, and the line is a
                            // sentence.
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              color: GlassColors.of(context).cardMuted,
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
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
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

/// The Settings drawer's mark: its glyph in a gold-lit disc the size of the
/// Stats drawer's portrait, so the two heads stand alike — the lobby's reward
/// chips wear the same disc while their reward can be taken.
class _HeadMark extends StatelessWidget {
  const _HeadMark({required this.icon});

  final IconData icon;

  /// The Stats drawer's portrait is radius 16.
  static const double size = 32;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.gold.withValues(alpha: dark ? 0.16 : 0.12),
        border: Border.all(
          color: AppTheme.gold.withValues(alpha: dark ? 0.45 : 0.50),
          width: Dim.hairline,
        ),
      ),
      child: Icon(icon, size: 18, color: _goldInk(brightness)),
    );
  }
}

/// The name over one group of settings — PROFILE, GAME EXPERIENCE, APPEARANCE,
/// ACCOUNT (settings polish, 26 Sep 2026): small and quiet, so it orders the
/// drawer without competing with what it heads. Tracked capitals in English
/// only: spread over Devanagari or Gurmukhi, tracking pulls the vowel signs
/// off their letters, so the other scripts keep their own shape.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label, {required this.english, this.first = false});

  final String label;
  final bool english;

  /// The first group's name sits closer under the head.
  final bool first;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _SettingsGroup.inset + Space.xs,
        first ? Space.md : Space.xl,
        _SettingsGroup.inset,
        Space.sm,
      ),
      child: Semantics(
        header: true,
        child: Text(
          english ? label.toUpperCase() : label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.label(
            text.labelSmall!,
            colour: GlassColors.of(context).cardMuted,
          ).copyWith(letterSpacing: english ? 1.2 : 0),
        ),
      ),
    );
  }
}

/// One group of settings rows on a very light pane of its own, the rows parted
/// by an inset hairline (settings polish, 26 Sep 2026: "clean rows with subtle
/// separators or very light containers" — one pane a group, never a card a
/// setting). [danger] edges the pane in a restrained red, for the one row
/// that cannot be undone; its body stays the other groups' own, so the drawer
/// has one red word in it rather than a red box.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children, this.danger = false});

  final List<Widget> children;
  final bool danger;

  /// How far a group stands in from the drawer's edge — the drawer's margin,
  /// which the fields and the appearance control keep too.
  static const double inset = Space.lg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final error = theme.colorScheme.error;
    // A breath lighter than the drawer by night, and a clear white over the
    // pearl by day: the rows' own surface, a step above the drawer's.
    final fill = dark ? glass.fill : glass.fillStrong;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: inset),
      child: Material(
        color: fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          side: BorderSide(
            color: danger
                ? error.withValues(alpha: dark ? 0.26 : 0.22)
                : glass.cardBorder,
            width: Dim.hairline,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const _GroupDivider(),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// The hairline between two rows of a group, starting where their words do.
class _GroupDivider extends StatelessWidget {
  const _GroupDivider();

  /// A row's glyph and the gap after it: the words start here.
  static const double _indent = Space.md + _DrawerAction.glyph + Space.md;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: _indent),
    child: Container(
      height: Dim.hairline,
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
    ),
  );
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

/// A row in a settings group that does something: a glyph, its name, and
/// whatever it ends in. No fill of its own — the group is the surface — and
/// the group's own ink says it was pressed.
///
/// Neutral unless [danger]: Sign out is a row like any other (settings polish,
/// 26 Sep 2026: "visible but not aggressive"), and Delete my account — the one
/// thing here that cannot be undone — is the one red row, in a group of its
/// own.
class _DrawerAction extends StatelessWidget {
  const _DrawerAction({
    required this.icon,
    required this.title,
    required this.onTap,
    this.danger = false,
    this.trailing,
  });

  /// A row's glyph, the same size in every row of the drawer.
  static const double glyph = 20;

  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool danger;

  /// A mark after the name: where the row goes, if it goes somewhere else.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = danger ? scheme.error : scheme.onSurface;
    final end = trailing;

    return InkWell(
      // Material's own click, gated on the player's Sound switch —
      // otherwise a silenced game would still tick on every tap.
      enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
      onTap: () {
        tapHaptic(context);
        onTap();
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: FeedbackSwitchStyle.groupedRowHeight,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.md,
            vertical: Space.xs,
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: glyph,
                color: danger ? ink : ink.withValues(alpha: AppTheme.inkMed),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.label(
                    theme.textTheme.bodyMedium!,
                    colour: ink,
                    weight: FontWeight.w500,
                  ),
                ),
              ),
              if (end != null) ...[const SizedBox(width: Space.sm), end],
            ],
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
      head: _DrawerHead(
        leading: Avatar(
          url: state.avatarUrl,
          fallback: user?.displayName ?? '',
          radius: _HeadMark.size / 2,
          animate: true,
        ),
        title: user?.displayName ?? '',
        subtitle: t.yourRecord,
      ),
      children: [
        const SizedBox(height: Space.xs),
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

/// A number system's name and its units — "Indian  ·  Lakh, Crore" — on one
/// line where they fit, and otherwise the name over its units with the dot
/// dropped (settings polish, 26 Sep 2026). Left to wrap by itself, a 260dp
/// drawer broke the line after the dot, or inside the units ("Indian · Lakh,"
/// over "Crore"). A label with no dot is written as it is.
class _SystemName extends StatelessWidget {
  const _SystemName(
    this.label, {
    required this.nameStyle,
    required this.unitsStyle,
  });

  final String label;
  final TextStyle nameStyle;
  final TextStyle unitsStyle;

  @override
  Widget build(BuildContext context) {
    final cut = label.indexOf('·');
    if (cut < 0) {
      return Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: nameStyle,
      );
    }
    final name = label.substring(0, cut).trim();
    final units = label.substring(cut + 1).trim();
    final line = TextSpan(
      children: [
        TextSpan(text: '$name  ·  ', style: nameStyle),
        TextSpan(text: units, style: unitsStyle),
      ],
    );

    return LayoutBuilder(
      builder: (context, box) {
        final painter = TextPainter(
          text: line,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout(maxWidth: box.maxWidth);
        final fits = !painter.didExceedMaxLines;
        painter.dispose();
        if (fits) return Text.rich(line, maxLines: 1);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: nameStyle,
            ),
            Text(
              units,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: unitsStyle,
            ),
          ],
        );
      },
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
        : scheme.onSurface.withValues(alpha: AppTheme.inkMed);

    // A tile inside the number format's group: the chosen one in the store's
    // own words for a chosen thing — a wash of gold under a champagne edge,
    // as its shelf keys wear (settings polish, 26 Sep 2026) — and the other
    // on the resting card edge.
    return PressScale(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          // Material's own click, gated on the player's Sound switch —
          // otherwise a silenced game would still tick on every tap.
          enableFeedback: context.select<FeedbackSettings, bool>(
            (f) => f.sound,
          ),
          borderRadius: BorderRadius.circular(Radii.sm),
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
              borderRadius: BorderRadius.circular(Radii.sm),
              color: selected
                  ? AppTheme.gold.withValues(alpha: dark ? 0.14 : 0.10)
                  : Colors.transparent,
              border: Border.all(
                color: selected
                    ? (dark
                          ? AppTheme.goldBright.withValues(alpha: 0.55)
                          : AppTheme.hairlineColour(brightness, live: true))
                    : glass.cardBorder,
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
                      // Never cut short (QA 14 Sep 2026: "International ·
                      // Millio…"): on one line where it fits, the name over
                      // its units where it does not.
                      _SystemName(
                        label,
                        nameStyle: AppTheme.label(
                          text.bodyMedium!,
                          weight: selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                        unitsStyle: AppTheme.label(
                          text.labelMedium!,
                          colour: scheme.onSurface.withValues(
                            alpha: AppTheme.inkMed,
                          ),
                          weight: FontWeight.w500,
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
                              : glass.cardMuted,
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
  /// Asks twice-over before deleting, and reports a refusal rather than
  /// swallowing it — the server says no while the player is seated, and a
  /// button that silently does nothing is worse than one that explains.
  ///
  /// The caller closes the drawer first, as the sign-out row does, so this
  /// never pops a route of its own: on success deletion has already put the
  /// app back on the login screen.
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
    }
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

  /// Whether the number format's two choices stand open under its row.
  bool _numbersOpen = false;

  /// Requirement 34: lakh and crore, or million and billion — one row that
  /// says which is on and how the player's own money reads under it, opening
  /// in place onto the two choices, each previewing itself with the same
  /// figure (settings polish, 26 Sep 2026). The two tiles used to stand open
  /// under a heading, the tallest thing in the drawer for a choice a player
  /// makes once. Choosing is exactly what it was, and closes the row again.
  Widget _numberFormat(GameState state) {
    final t = state.t;
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final scheme = theme.colorScheme;
    final glass = GlassColors.of(context);
    final open = _numbersOpen;
    final current = state.numbers;

    String name(NumberSystem system) =>
        system == NumberSystem.indian ? t.numberIndian : t.numberInternational;

    final row = Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        // Material's own click, gated on the player's Sound switch —
        // otherwise a silenced game would still tick on every tap.
        enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
        onTap: () {
          tapHaptic(context);
          setState(() => _numbersOpen = !open);
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: FeedbackSwitchStyle.groupedRowHeight,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.md,
              vertical: Space.sm,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.tag,
                  size: _DrawerAction.glyph,
                  color: scheme.onSurface.withValues(alpha: AppTheme.inkMed),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        t.numberSystem,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.label(
                          text.bodyMedium!,
                          colour: scheme.onSurface,
                          weight: FontWeight.w500,
                        ),
                      ),
                      // What is on, in the accent a chosen thing wears, and
                      // the player's own money as it reads under it. Gone
                      // while the choices are open: each of them says it.
                      if (!open) ...[
                        const SizedBox(height: Space.xxs),
                        _SystemName(
                          name(current),
                          nameStyle: AppTheme.label(
                            text.labelMedium!,
                            colour: _goldInk(theme.brightness),
                          ),
                          unitsStyle: AppTheme.label(
                            text.labelMedium!,
                            colour: _goldInk(theme.brightness),
                            weight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          _sampleIn(current, state),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.money(
                            text.labelMedium!,
                            colour: glass.cardMuted,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: Space.sm),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: Motion.base,
                  curve: Motion.standard,
                  child: Icon(
                    Icons.expand_more_rounded,
                    size: 22,
                    color: glass.cardMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return AnimatedSize(
      duration: Motion.base,
      curve: Motion.standard,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row,
          if (open)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.md,
                0,
                Space.md,
                Space.md,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, option) in NumberSystem.values.indexed) ...[
                    if (i > 0) const SizedBox(height: Space.sm),
                    _NumberOption(
                      icon: option == NumberSystem.indian
                          ? Icons.currency_rupee
                          : Icons.public,
                      label: name(option),
                      // The same stack written both ways.
                      sample: _sampleIn(option, state),
                      selected: current == option,
                      onTap: () {
                        setState(() => _numbersOpen = false);
                        state.setNumberSystem(option);
                      },
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final glass = GlassColors.of(context);
    final t = state.t;
    final english = state.lang == AppLang.english;
    // What is typed in the name field and what is chosen in the language
    // field, in one style, so the two read as the pair they are: the
    // dropdown took the theme's titleMedium, a size and a weight above the
    // name beside it.
    final fieldText = text.bodyLarge?.copyWith(color: scheme.onSurface);
    // Everything sunk into the drawer is filled alike: the two fields and the
    // appearance control.
    final well = _DrawerBody.well(glass);
    final environment = versionEnvironmentTag();

    return _LobbyDrawer(
      head: _DrawerHead(
        leading: const _HeadMark(icon: Icons.tune_rounded),
        title: t.settings,
        subtitle: t.settingsSubtitle,
      ),
      children: [
        // PROFILE: who you are at the table — the picture, the name and the
        // language — as one block, headed and spaced as one.
        _SectionLabel(t.settingsProfile, english: english, first: true),
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
        // the same control in two places rather than as two different ones;
        // the thin gold ring is this copy's alone.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _SettingsGroup.inset),
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
                  padding: const EdgeInsets.symmetric(vertical: Space.xs),
                  child: Column(
                    children: [
                      _AvatarWithPip(
                        url: state.avatarUrl,
                        fallback: state.user?.displayName ?? '',
                        diameter: 72,
                        ringed: true,
                      ),
                      const SizedBox(height: Space.sm),
                      Text(
                        _wornPictureName(state) ?? t.yourPicture,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: AppTheme.label(
                          text.titleSmall ?? const TextStyle(),
                        ),
                      ),
                      Text(
                        t.tapToChangePicture,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall?.copyWith(color: glass.cardMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: Space.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _SettingsGroup.inset),
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
              style: fieldText,
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
              // The server's complaint wraps: InputDecoration keeps an error
              // to one line unless told otherwise, and in the drawer's width
              // "Letters, numbers and spaces only." was cut to "Letters,
              // numbers and spaces ..." (24 Sep 2026, owner's "fix all bugs";
              // release review B4).
              decoration: InputDecoration(
                isDense: true,
                errorText: _nameError,
                errorMaxLines: 4,
                fillColor: well,
              ),
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
        const SizedBox(height: Space.sm),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _SettingsGroup.inset),
          child: DropdownButtonFormField<AppLang>(
            initialValue: state.lang,
            // The field takes the width it is given and its longest item
            // ellipsises inside it, instead of the row sizing itself to the
            // longest name and running 17dp past the drawer's edge — which is
            // what it did once the type became Inter, which is wider than the
            // font this slot was measured against.
            isExpanded: true,
            style: fieldText,
            decoration: InputDecoration(
              labelText: t.language,
              prefixIcon: const Icon(Icons.translate, size: 18),
              isDense: true,
              fillColor: well,
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
        // GAME EXPERIENCE: how money reads, and how the game sounds and feels
        // — one group, the rows parted by hairlines.
        _SectionLabel(t.settingsGameExperience, english: english),
        _SettingsGroup(
          children: [
            _numberFormat(state),
            // Sound and vibration, as switches rather than actions: they have
            // a state the player should be able to read at a glance, which a
            // row that merely reacts to a tap does not show.
            const FeedbackToggles(grouped: true, divider: _GroupDivider()),
          ],
        ),
        // No Rules row here (owner, 23 Sep 2026: "remove the rules button from
        // setting drawer"): the rules are read where they apply — each table
        // card's rulebook key in the lobby, and the table's own menu once
        // seated.
        //
        // APPEARANCE: System, Dark or Light as one segmented control. The
        // switcher reads and writes the theme mode itself.
        _SectionLabel(t.appearance, english: english),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _SettingsGroup.inset),
          child: GlassThemeSwitcher(track: well),
        ),
        // ACCOUNT. Google's User Data policy wants the privacy policy
        // reachable from inside the app, not only from the Play listing. It
        // opens in the browser rather than a webview so the player can see the
        // address they are being shown — which its trailing mark says.
        _SectionLabel(t.settingsAccount, english: english),
        _SettingsGroup(
          children: [
            _DrawerAction(
              icon: Icons.privacy_tip_outlined,
              title: t.privacyPolicy,
              trailing: Icon(
                Icons.open_in_new_rounded,
                size: 16,
                color: glass.cardMuted,
              ),
              onTap: () => launchUrl(
                // The studio's page, the one the Play listing names — not the
                // backend's copy, so every build shows the same policy.
                Uri.parse(ServerConfig.privacyUrl),
                mode: LaunchMode.externalApplication,
              ),
            ),
            _DrawerAction(
              icon: Icons.logout_rounded,
              title: t.signOut,
              onTap: () {
                // The drawer closes first, as it does before the picture
                // picker, so the question is not stacked over an open drawer.
                Navigator.pop(context);
                _confirmSignOut(context, state);
              },
            ),
          ],
        ),
        // The one row that cannot be undone, apart from the rest and the one
        // red thing in the drawer. Google Play requires an in-app route to
        // account deletion, and this game creates an account on first launch,
        // so every player has one to delete.
        const SizedBox(height: Space.md),
        _SettingsGroup(
          danger: true,
          children: [
            _DrawerAction(
              icon: Icons.delete_forever_outlined,
              title: t.deleteAccount,
              danger: true,
              onTap: () {
                Navigator.pop(context);
                _confirmDelete(context, state);
              },
            ),
          ],
        ),
        // Which build this is, for anyone reporting what they saw: small,
        // quiet and centred at the end of the list, with the environment
        // after it — quieter still — on a build that does not talk to
        // production.
        Padding(
          padding: const EdgeInsets.fromLTRB(
            _SettingsGroup.inset,
            Space.xl,
            _SettingsGroup.inset,
            0,
          ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text:
                      '${t.appVersion}  '
                      '${state.appVersion.isEmpty ? '…' : state.appVersion}',
                ),
                if (environment != null)
                  TextSpan(
                    text: '  ·  $environment',
                    style: TextStyle(
                      color: glass.cardMuted.withValues(
                        alpha: glass.cardMuted.a * 0.72,
                      ),
                    ),
                  ),
              ],
            ),
            textAlign: TextAlign.center,
            style: AppTheme.money(
              text.labelSmall!,
              colour: glass.cardMuted,
              weight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

/// What the settings drawer's footer names after the version: the environment
/// a build that does not talk to production talks to, so a tester can tell
/// which server it is — and nothing on a production build, where a player has
/// no use for it.
@visibleForTesting
String? versionEnvironmentTag({bool? production, String? environment}) =>
    (production ?? ServerConfig.isProduction)
    ? null
    : (environment ?? ServerConfig.environment);

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
      // Ready, it shows what it pays behind a coin rather than the word
      // Collect (owner, 24 Sep 2026).
      subtitle: ready ? null : formatCountdown(r.untilBonus, state.t),
      reward: ready ? (chips: r.bonusReward, hammers: 0) : null,
      enabled: ready,
      maxWidth: maxWidth,
      onTap: () => state.claimReward('bonus'),
      onWaitTap: () => openBonusDetails(context, 'bonus'),
    );
  }
}

/// The daily bonus (owner, 14 Sep 2026): 1 lakh chips and a hammer every 24
/// hours, in the lobby's bottom-left corner, beside the 4-hour [_BonusChip] in
/// the top bar. A gift rather than the hourglass, so the two read as two
/// rewards at a glance. Absent when the server offers no daily bonus.
class _DailyBonusChip extends StatelessWidget {
  const _DailyBonusChip();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final r = state.user?.rewards;
    if (r == null || !r.hasDaily) return const SizedBox.shrink();

    final ready = r.dailyReady;
    return _CornerChip(
      icon: Icons.redeem,
      title: state.t.dailyBonus,
      // Ready, it shows the lakh behind a coin and the hammer as the hammer,
      // with no word (owner, 24 Sep 2026): "Collect 1,00,000 +1 Hammer" was
      // cut to "Collect 100,000 +..." on a 640dp phone, and the glyphs are
      // what let the whole reward fit.
      subtitle: ready ? null : formatCountdown(r.untilDaily, state.t),
      reward: ready ? (chips: r.dailyReward, hammers: r.dailyHammers) : null,
      // A cap of its own, a tenth over the top bar's slot: it pays two
      // currencies to the 4-hour chip's one, and the foot has the room.
      maxWidth: Dim.dailyBonusW(MediaQuery.sizeOf(context).width),
      enabled: ready,
      onTap: () => state.claimReward('daily'),
      onWaitTap: () => openBonusDetails(context, 'daily'),
    );
  }
}

/// The Lucky Draw (owner, 24 Sep 2026), beside the daily bonus: a small wheel
/// that turns now and then while a spin is due, and the time left while the
/// wheel recharges. Either way a tap opens the draw ([showLuckyDraw]) — its
/// prizes are worth a look while the wait runs. Absent when the server offers
/// no draw (none open, or a server that predates it).
class _LuckyDrawChip extends StatelessWidget {
  const _LuckyDrawChip();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final draw = state.luckyDraw;
    if (state.user == null) return const SizedBox.shrink();
    if (draw == null) {
      // While the first read of the draw is out, the key's room is kept,
      // unseen: a toast raised at sign-in is placed the moment it appears
      // (lobbyNoticeArea), and it used to lie over the key that arrived a
      // moment after it.
      if (!state.luckyDrawLoading) return const SizedBox.shrink();
      return Visibility.maintain(
        visible: false,
        child: Padding(
          padding: const EdgeInsets.only(left: Space.sm),
          child: _CornerChip(
            icon: Icons.casino_rounded,
            title: state.t.luckyDrawChip,
            subtitle: state.t.luckySpinReady,
            enabled: false,
            onTap: () {},
          ),
        ),
      );
    }
    final now = DateTime.now();
    final due = draw.readyAt(now);
    return Padding(
      key: const ValueKey('lucky-draw-chip'),
      padding: const EdgeInsets.only(left: Space.sm),
      child: _CornerChip(
        icon: Icons.casino_rounded,
        leadingBuilder: (fg) => LuckyWheelGlyph(colour: fg, turning: due),
        title: state.t.luckyDrawChip,
        subtitle: due
            ? state.t.luckySpinReady
            : formatSpinClock(draw.untilNext(now)),
        enabled: due,
        onTap: () => showLuckyDraw(context),
        onWaitTap: () => showLuckyDraw(context),
      ),
    );
  }
}

/// A bonus tapped while it is still counting down (owner, 14 Sep 2026): what it
/// pays — its chips, and the daily bonus's hammer — and how long is left,
/// ticking with the lobby's one-second clock. If the wait runs out while it is
/// open it offers Collect, which closes it first so the celebration has the
/// screen.
///
/// [kind] is the reward's name on the wire, `bonus` or `daily`, as
/// [GameState.claimReward] takes it.
Future<void> openBonusDetails(BuildContext context, String kind) =>
    showDialog<void>(
      context: context,
      builder: (context) => _BonusDetails(kind: kind),
    );

class _BonusDetails extends StatelessWidget {
  const _BonusDetails({required this.kind});

  final String kind;

  @override
  Widget build(BuildContext context) {
    // Watched, so the countdown moves with the lobby's one-second tick.
    final state = context.watch<GameState>();
    final t = state.t;
    final r = state.user?.rewards;
    if (r == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final text = theme.textTheme;
    final onSurface = theme.colorScheme.onSurface;
    final quiet = onSurface.withValues(alpha: AppTheme.inkLow);
    final gold = _goldInk(theme.brightness);
    final hammerInk = hammerInkOn(theme.brightness);

    final daily = kind == 'daily';
    final ready = daily ? r.dailyReady : r.bonusReady;
    final chips = daily ? r.dailyReward : r.bonusReward;
    final hammers = daily ? r.dailyHammers : 0;

    return GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: Row(
        children: [
          // The chip's own mark, so the popup reads as that chip opened up.
          if (daily)
            Icon(Icons.redeem, size: 20, color: gold)
          else
            _Hourglass(colour: gold, running: !ready),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              daily ? t.dailyBonus : t.fourHourBonus,
              style: AppTheme.label(text.titleMedium ?? const TextStyle()),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            t.bonusYouGet,
            textAlign: TextAlign.center,
            style: AppTheme.label(text.labelMedium!, colour: quiet),
          ),
          const SizedBox(height: Space.sm),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Space.lg,
            runSpacing: Space.xs,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const PokerChip(colour: AppTheme.gold, size: 26),
                  const SizedBox(width: Space.sm),
                  Text(
                    formatChips(chips),
                    style: AppTheme.money(text.headlineSmall!, colour: gold),
                  ),
                ],
              ),
              if (hammers > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.hardware, size: 22, color: hammerInk),
                    const SizedBox(width: Space.xs),
                    Text(
                      t.plusHammers(hammers),
                      style: AppTheme.money(
                        text.titleMedium!,
                        colour: hammerInk,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: Space.lg),
          Text(
            ready ? t.bonusReadyNow : t.bonusNextIn,
            textAlign: TextAlign.center,
            style: AppTheme.label(
              text.labelMedium!,
              colour: ready ? gold : quiet,
            ),
          ),
          if (!ready) ...[
            const SizedBox(height: Space.xs),
            Text(
              formatCountdown(daily ? r.untilDaily : r.untilBonus, t),
              textAlign: TextAlign.center,
              style: AppTheme.money(text.headlineMedium!, colour: onSurface),
            ),
          ],
          const SizedBox(height: Space.md),
          Text(
            daily ? t.bonusEveryDay : t.bonusEveryFourHours,
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(
              color: onSurface.withValues(alpha: AppTheme.inkMed),
            ),
          ),
        ],
      ),
      actions: [
        GlassButton(
          style: GlassButtonStyle.text,
          label: t.close,
          onPressed: () => Navigator.pop(context),
        ),
        if (ready)
          GlassButton(
            style: GlassButtonStyle.primary,
            label: t.collect,
            onPressed: () {
              Navigator.pop(context);
              state.claimReward(kind);
            },
          ),
      ],
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
final _dailyChip = GlobalKey(debugLabel: 'bonus chip');

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
  final bonus = _dailyChip.currentContext?.findRenderObject();
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

/// What a reward pays, for a [_CornerChip]'s second line once it is ready.
typedef _RewardPay = ({int chips, int hammers});

/// A corner chip's mark in a disc of its own: a gift, a trophy, an hourglass.
/// Gold-lit while the reward can be taken, a quiet well while it is coming,
/// so the chip's state reads from the corner of the eye before its words do.
class _ChipMark extends StatelessWidget {
  const _ChipMark({required this.ready, required this.child});

  final bool ready;
  final Widget child;

  /// Room for the 18dp hourglass and a margin, well inside the 44dp pill.
  static const double _size = 28;

  @override
  Widget build(BuildContext context) {
    final glass = GlassColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: _size,
      height: _size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: ready
            ? AppTheme.gold.withValues(alpha: dark ? 0.16 : 0.12)
            : glass.wellFill,
        border: Border.all(
          color: ready
              ? AppTheme.gold.withValues(alpha: dark ? 0.45 : 0.50)
              : glass.cardBorder,
        ),
      ),
      child: child,
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
    required this.enabled,
    required this.onTap,
    this.subtitle,
    this.reward,
    this.leadingBuilder,
    this.maxWidth,
    this.onWaitTap,
  }) : assert(
         (subtitle == null) != (reward == null),
         'a chip has one second line: words, or what the reward pays',
       );

  final IconData icon;

  /// Replaces the plain [icon] when a chip wants a moving one. It is a builder
  /// rather than a widget because the foreground colour is decided here, from
  /// whether the chip is enabled.
  final Widget Function(Color colour)? leadingBuilder;
  final String title;

  /// The second line in words: the countdown, the hands to go, or the
  /// milestone's "Collect 25,000". Exactly one of this and [reward] is given.
  final String? subtitle;

  /// The second line as what the reward pays — the wallet's own glyphs and the
  /// figures, no word: a coin before the chips, and after them "+1" and the
  /// hammer (owner, 24 Sep 2026: "In daily Bonus button instead of showing
  /// text 'collect' show coins icon and instead of text 'Hammer' show icon.
  /// Same in case of 4 Hour Bonus show coin icon instead of collect text").
  /// "Collect 1,00,000 +1 Hammer" ellipsised on a 640dp phone; drawn this way
  /// the whole reward fits in the same slot. The glyphs are the top bar's — a
  /// [PokerChip] beside the balance, [Icons.hardware] beside the hammers — so
  /// the chip reads as paying the currencies the bar counts, each in the ink
  /// the bar gives it (the coin's gold, the hammer's copper), not the chip's
  /// foreground — a champagne coin was not the wallet's coin (review, 24 Sep
  /// 2026).
  final _RewardPay? reward;

  final bool enabled;
  final VoidCallback onTap;

  /// What a tap does while the chip is not [enabled] — the two bonuses open
  /// their popup with the reward and the time left (owner, 14 Sep 2026). Null
  /// leaves a chip that is still counting down deaf to the finger, as the
  /// milestone's is.
  final VoidCallback? onWaitTap;

  /// A finite cap so the two lines can ellipsise. Without one this pill sizes
  /// to its longest translation and runs off the screen.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final brightness = theme.brightness;
    final glass = GlassColors.of(context);
    final dark = brightness == Brightness.dark;
    final gold = _goldInk(brightness);
    // The mark and the second line: gold while the reward can be taken, the
    // card's own ink while it is still coming — the chip's news is whether
    // it is ready, and that is what the colour says.
    final fg = enabled ? gold : glass.textBody;
    final cap = maxWidth ?? Dim.bonusSlotW(MediaQuery.sizeOf(context).width);
    final money = AppTheme.money(
      text.labelLarge!,
      colour: enabled ? gold : glass.textDisplay,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: cap),
      // Presses in while a tap does something: taking the reward, or opening a
      // bonus's popup. A chip with neither (the milestone, still counting
      // hands) stays still under the finger, which says it is not a key yet.
      child: PressScale(
        enabled: enabled || onWaitTap != null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.pill),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: AppTheme.gold.withValues(
                        alpha: dark ? 0.18 : 0.14,
                      ),
                      blurRadius: 16,
                      spreadRadius: -2,
                    ),
                  ]
                : null,
          ),
          child: GlassCapsule(
            // The card the lobby's cards are made of: the chips stand on the
            // same ground and are the same kind of thing.
            surface: GlassSurface.card,
            live: enabled,
            // Both states are the same size, so a chip becoming claimable does
            // not shove the row it is in.
            minHeight: Dim.minTouch,
            onTap: enabled ? onTap : onWaitTap,
            // The mark sits in the pill's own round end, as far from the rim
            // as it is from the top and the foot.
            padding: const EdgeInsets.fromLTRB(
              Space.sm,
              Space.xs,
              Space.lg,
              Space.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ChipMark(
                  ready: enabled,
                  child:
                      leadingBuilder?.call(fg) ??
                      Icon(icon, size: 16, color: fg),
                ),
                const SizedBox(width: Space.sm),
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
                          colour: glass.cardMuted,
                        ),
                      ),
                      if (reward == null)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: money,
                        )
                      else
                        _rewardLine(context, reward!, fg, money),
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

  /// `[coin] 1,00,000  +1 [hammer]`; the hammer and its count only when the
  /// reward carries one. Each glyph is the size of the figure's type, so it
  /// scales with the text and stays under its line: the row is exactly as
  /// tall as the countdown's one line, and the chip does not grow when it
  /// becomes claimable. A row rather than a paragraph with the glyphs inline,
  /// because a placeholder that opens a paragraph is centred on a line that
  /// has no text metrics yet and pushes the line 2dp taller. The figure alone
  /// is flexible, so a slot too narrow cuts it to "…" and never overflows.
  static Widget _rewardLine(
    BuildContext context,
    _RewardPay pay,
    Color fg,
    TextStyle style,
  ) {
    final glyph = MediaQuery.textScalerOf(context).scale(style.fontSize!);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The wallet's own coin — the top bar's gold, not the chip's champagne
        // ink — so the chip reads as paying the currency the bar counts.
        PokerChip(colour: AppTheme.gold, size: glyph),
        const SizedBox(width: Space.xs),
        Flexible(
          child: Text(
            formatChips(pay.chips),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        if (pay.hammers > 0) ...[
          const SizedBox(width: Space.sm),
          Text('+${pay.hammers}', maxLines: 1, style: style),
          const SizedBox(width: Space.xxs),
          // And the hammer in its own copper, as the bar and the popup draw it.
          Icon(
            Icons.hardware,
            size: glyph,
            color: hammerInkOn(Theme.of(context).brightness),
          ),
        ],
      ],
    );
  }
}
