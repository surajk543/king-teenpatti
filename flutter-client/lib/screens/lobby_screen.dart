import 'dart:async';
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
import '../theme/depth.dart';
import '../theme/table_theme.dart';
import '../theme/theme_colors.dart';
import '../widgets/game_card.dart';
import '../widgets/avatar.dart';
import '../widgets/buy_chips.dart';
import '../widgets/chip_shuffle.dart';
import '../widgets/feedback_toggles.dart';
import '../widgets/drifting_chips.dart';
import '../widgets/edge_fade.dart';
import '../widgets/fireworks.dart';
import '../widgets/game_loader.dart';
import '../widgets/glass_components.dart';
import '../widgets/avatar_badge.dart';
import '../widgets/back_mark.dart';
import '../widgets/card_coins.dart';
import '../widgets/entry_wallet.dart';
import '../widgets/glass_panels.dart';
import '../widgets/info_wave.dart';
import '../widgets/level_accent.dart';
import '../widgets/lobby_level_bar.dart';
import '../widgets/open_lock.dart';
import '../widgets/own_record.dart';
import '../widgets/picture_shelf.dart';
import '../widgets/player_profile.dart';
import '../widgets/pot_piggy.dart';
import '../widgets/rule_book.dart';
import '../widgets/poker_chip.dart';
import '../widgets/premium_surface.dart';
import '../widgets/rules_sheet.dart';
import '../widgets/table_ground.dart';
import '../widgets/table_tax.dart';
import '../widgets/weekly_login.dart';
import 'friends_screen.dart';
import 'lucky_draw_screen.dart';
import 'reward_programs_screen.dart';

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

  /// The rail's level as last drawn ('' the front, 'teen_patti' inside an
  /// engine, 'teen_patti:seen' inside a category), which way the last change
  /// of level went, and whether one has happened since the lobby appeared —
  /// what [_railTransition] and the cards' [_Entrance] read.
  String? _shownLevel;
  bool _levelForward = true;
  bool _levelChanged = false;

  /// How far a level slides as it gives way, as a share of the rail's width.
  static const double _railShift = 0.06;

  static int _levelDepth(String level) =>
      level.isEmpty ? 0 : ':'.allMatches(level).length + 1;

  /// How one level of the rail gives way to the next: ONE movement along the
  /// rail's own axis (owner, 26 Sep 2026: "when I click the Teen Patti card and
  /// go to Seen, that transition is not smooth"). Going in, the new level comes
  /// in from the right while the old one leaves to the left, and Back mirrors
  /// it. The old level is gone in the first 30% of the time and the new one
  /// fades in over the rest, so the two never stand over each other (a
  /// fade-through, where the old cross-fade left the rail empty while the new
  /// cards waited out their stagger), and the new level's cards come in WITH
  /// it rather than one after another ([_Entrance.settled]); the lobby's first
  /// appearance keeps its stagger. The rail moves as one layer
  /// (RepaintBoundary), so a frame of the transition only moves and fades it.
  ///
  /// Given to the switcher as a fresh closure every build on purpose: a
  /// switcher re-wraps its children only when its builder changes, and that is
  /// what turns the leaving level's transition, built when it came in, into a
  /// leaving one at the moment the level changes.
  Widget _railTransition(Widget child, Animation<double> animation) {
    final incoming = child.key == ValueKey('lobby-rail:$_shownLevel');
    final away =
        (_levelForward ? 1.0 : -1.0) * (incoming ? 1.0 : -1.0) * _railShift;
    return FadeTransition(
      opacity: animation.drive(
        CurveTween(
          curve: incoming
              ? const Interval(0.3, 1, curve: Curves.easeOut)
              : const Interval(0.7, 1, curve: Curves.easeIn),
        ),
      ),
      child: SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: Offset(away, 0),
            end: Offset.zero,
          ).chain(CurveTween(curve: Motion.emphasized)),
        ),
        child: RepaintBoundary(child: child),
      ),
    );
  }

  /// The private card's code field. Owned here because the rail is what has
  /// to move while it has focus: the lobby is not resized for the keyboard, so
  /// the rail lifts itself instead, and only for that one field.
  final _codeFocus = FocusNode();

  /// On the code field's box, so the lift can be measured against the field
  /// itself rather than guessed from the card's layout.
  ///
  /// This key and the card's below are made afresh each time the rail comes
  /// back to the front ([build]). The level that is leaving stays in the tree
  /// through its transition. A player who goes in and straight back out
  /// again (a tap on Seen, then one on the back tile that has just appeared
  /// under the finger) would otherwise put two front levels in the tree, each
  /// with a private card under the same GlobalKey, and the framework would
  /// throw "Duplicate GlobalKey". The new keys belong to the level coming in,
  /// which is the only one [_codeFieldInCard] needs to measure.
  var _codeField = GlobalKey();

  /// On the private card, the box the code field is measured against.
  var _privateCard = GlobalKey();

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
    // The record is read fresh as it opens: a finished hand's counters reach
    // the server's database up to STATS_FLUSH_MS after the hand (Player stats
    // v2), later than the read the lobby made when the table closed.
    if (panel == _EndPanel.stats) {
      unawaited(context.read<GameState>().refreshUser());
    }
    Scaffold.of(context).openEndDrawer();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final user = state.user;
    // The rail is rebuilt whenever the server changes what it offers, so the
    // entrance animation is keyed off the card's place in the row.
    var slot = 0;
    Widget entering(Widget child) =>
        _Entrance(index: slot++, settled: _levelChanged, child: child);

    // The foot's height — the Lucky Draw chip's two lines at the current text
    // scale, or a legal touch target for the round keys in the other corner,
    // whichever is taller: the rail keeps a band this tall clear at its foot,
    // so the cards end above the foot instead of running under it.
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
    // A build without the Poker family (AppFeatures.poker, off by default;
    // owner, 27 Sep 2026: "In UI only show three cards seen, blind,
    // variation") has one engine left to show, and its CATEGORIES stand on
    // the front instead (GameState.lobbyFrontEngine): Seen, Blind, Variation,
    // then the private card, and a category's tables behind a tile that leads
    // back to them.
    //
    // The level shown is the one the state holds only while the menu still
    // offers it: a menu written straight into `config` never strands the
    // player at an empty rail.
    final scheme = Theme.of(context).colorScheme;
    final engines = state.lobbyEngines;
    final frontEngine = state.lobbyFrontEngine;
    final engine = engines.contains(state.lobbyEngine)
        ? state.lobbyEngine
        : null;
    final categories = engine == null
        ? (frontEngine == null
              ? const <String>[]
              : state.lobbyCategoriesIn(frontEngine))
        : state.lobbyCategoriesIn(engine);
    final category = categories.contains(state.lobbyCategory)
        ? state.lobbyCategory
        : null;
    // Which way the rail moves when the level changes: deeper is forward, Back
    // is backward (_railTransition). The first level drawn is the lobby's own
    // entrance, with its stagger.
    final level = [?engine, ?category].join(':');
    if (_shownLevel == null) {
      _shownLevel = level;
    } else if (level != _shownLevel) {
      _levelForward = _levelDepth(level) >= _levelDepth(_shownLevel!);
      _shownLevel = level;
      _levelChanged = true;
      // Back at the front: the private card coming in takes keys of its own,
      // while any front level still leaving keeps the old ones.
      if (level.isEmpty) {
        _codeField = GlobalKey();
        _privateCard = GlobalKey();
      }
    }
    // The open level's colour, let into the room as its ambient light (owner,
    // 24 Sep 2026: "the glow should feel like ambient lighting behind the
    // UI"): nothing at the front, where every mode stands side by side; the
    // engine's inside an engine; the category's inside a category.
    final roomLight = category != null
        ? _categoryPalette(scheme, category).accent
        : engine != null
        ? _enginePalette(scheme, engine).accent
        : null;
    // The same level, as the palette the two drawers take in place of the
    // house gold (owner, 30 Sep 2026: the Settings drawer's shade "should
    // change acc to card type colour") — LevelAccent answers null for the
    // gold levels, so the front, Seen and Teen Patti draw what they did.
    final drawerPalette =
        category ??
        (engine == null
            ? null
            : engine == TableEngine.poker
            ? TableCategory.pokerFamily
            : TableCategory.seen);

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
      endDrawer: LevelAccent(
        palette: drawerPalette,
        child: _panel == _EndPanel.stats
            ? const _StatsDrawer()
            : const _SettingsDrawer(),
      ),
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
                    // The foot's band stays clear under the rail. Floated over
                    // it, a corner chip covered the lower half of Join and
                    // "Tap to sit down" and took the taps aimed at them.
                    child: Padding(
                      padding: EdgeInsets.only(bottom: band),
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final h = MediaQuery.sizeOf(context).height;
                          // The level's cards (see engine / category above).
                          final List<Widget> cards;
                          if (engine == null) {
                            cards = [
                              if (frontEngine == null)
                                for (final name in engines)
                                  entering(_EngineCard(engine: name))
                              else
                                for (final name in categories)
                                  entering(
                                    _CategoryCard(
                                      engine: frontEngine,
                                      category: name,
                                    ),
                                  ),
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
                                  // Where Back goes: this category's engine,
                                  // or every game where its categories are
                                  // the front.
                                  back: engine == frontEngine
                                      ? state.t.backToCategories
                                      : _engineName(
                                          state.t,
                                          engine,
                                          serverName: state
                                              .lobbyEngineServerName(engine),
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
                          // count. Where the categories ARE the front (no
                          // Poker family), the front and a category's tables
                          // are sized together, each stopping cleanly at the
                          // other's side, so opening Blind does not shrink
                          // the cards.
                          final backTile = engine != null;
                          final ({int cards, bool backTile})? sizedWith =
                              frontEngine == null
                              ? null
                              : engine == null
                              ? (cards: 4, backTile: true)
                              : engine == frontEngine
                              ? (cards: categories.length + 1, backTile: false)
                              : null;
                          final side = lobbyRailSide(
                            fit: fit,
                            width: box.maxWidth,
                            cards: backTile
                                ? math.max(cards.length - 1, 4)
                                : cards.length,
                            backTile: backTile,
                            also: sizedWith,
                          );
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
                                duration: Motion.slow,
                                transitionBuilder: (child, animation) =>
                                    _railTransition(child, animation),
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
              // The Lucky Draw in the bottom-left corner (owner, 24 Sep 2026),
              // and beside it the reward programs' chip (30 Sep 2026: the
              // login streaks and calendar rewards), where the daily bonus
              // stood until the owner took the lobby's three rewards away
              // (30 Sep 2026: "Remove 24-hour daily reward, 4-hour bonus, and
              // milestone reward"). Keyed so a lobby toast can stand clear of
              // both (lobbyNoticeArea).
              Positioned(
                bottom: Space.md,
                left: Space.md,
                child: Row(
                  key: _luckyChip,
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: const [_LuckyDrawChip(), _RewardsChip()],
                ),
              ),
              // The level key and Friends in the bottom-right corner, where
              // the milestone chip stood until 30 Sep 2026. The rail of tables
              // stops short of the foot (`band`), so no card's keys run under
              // either corner.
              //
              // Friends (owner, 26 Sep 2026) is a round key, the requests
              // waiting counted on it. The brief put it among the top bar's
              // keys, but there a fourth key takes its width from the player's
              // name; the foot has room for a key and keeps the name whole.
              Positioned(
                bottom: Space.md,
                right: Space.md,
                child: Row(
                  // Keyed so a lobby toast can stand clear of the keys, and
                  // knows when a page covers the lobby (lobbyNoticeArea).
                  key: _footKeys,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    // The level key (owner, 27 Sep 2026: "Add one icon in
                    // lobby so that user can see his level"): the player's
                    // level on it, and the level popup behind it.
                    LevelKey(),
                    FriendsKey(),
                  ],
                ),
              ),
              // The weekly login popup (30 Sep 2026): the owner's calendar
              // with the week's prizes in its boxes, up after sign-in while
              // today's is still to collect.
              const WeeklyLoginOverlay(),
              // Sits last so it covers the foot and the rail. A wallet filling
              // is the one moment in the lobby worth interrupting for.
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
///
/// [also] is a second level the side must stop cleanly for as well, so that
/// two levels a player moves between directly are drawn at one size: where
/// Teen Patti's categories are the front (the default build, no Poker
/// family), the front and a category's tables. Where no side at or above
/// [_sideMin] suits both, both keep [fit] — the same size still.
@visibleForTesting
double lobbyRailSide({
  required double fit,
  required double width,
  required int cards,
  required bool backTile,
  ({int cards, bool backTile})? also,
}) {
  bool stopsClean(double side, int cards, bool backTile) {
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
    if (stopsClean(side, cards, backTile) &&
        (also == null || stopsClean(side, also.cards, also.backTile))) {
      return side;
    }
  }
  return fit;
}

/// The banner for what just landed in a wallet in the lobby — a chip, diamond
/// or hammer pack, a Premium Package, a missile trade: fireworks, the wallet's
/// mark, the amount and a line on what it is for.
///
/// It was made for the lobby's rewards (removed 30 Sep 2026) and replaced a
/// one-line toast. Since the grant is real and irreversible, it deserves to be
/// unmistakable — a player who is not sure whether their tap worked will tap
/// again.
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
    // A reward program's claim (30 Sep 2026: the login streaks and calendar
    // rewards) is celebrated here too, listing what the server says it gave.
    final grants = state.rewardsGranted;
    final won = grants != null ? null : state.rewardWon;
    final t = state.t;

    if (won == null && grants == null) {
      _shownFor = null;
      return const SizedBox.shrink();
    }
    final shownKey = won?.amount ?? _grantsKey(grants!);
    if (_shownFor != shownKey) {
      _shownFor = shownKey;
      _in.forward(from: 0);
    }
    final VoidCallback dismiss = grants != null
        ? state.dismissRewardsGranted
        : state.dismissReward;

    final size = MediaQuery.sizeOf(context);
    // Height is the scarce axis, so the panel's own padding and its hero chip
    // are measured off it, not off a literal that only fits a tall phone.
    // h=360 -> 19.8 / 30.6 / 57.6 | 411 -> 22.6 / 34.9 / 65.8 | 800 -> 28 / 44 / 68.
    final padV = (size.height * 0.055).clamp(16.0, 28.0);
    final padH = (size.height * 0.085).clamp(24.0, 44.0);
    // A Premium Package has a line more to show — the missiles and hammers
    // under its chips — and on a 360dp phone at the 1.25 text ceiling that
    // line is paid for by a smaller hero chip and a tighter gap under it.
    final premium = won?.kind == 'premium';
    // A hammer pack has that line too, for its hammers.
    final wallets = premium || (won?.hammers ?? 0) > 0;
    final chip = (size.height * 0.16).clamp(40.0, 68.0) * (wallets ? 0.75 : 1);

    final blurb = switch (won?.kind) {
      'premium' => t.rewardPremiumPurchased,
      'diamonds' => t.rewardDiamondsPurchased,
      'hammers' => t.rewardHammersPurchased,
      'missiles' => t.rewardMissilesTraded(won?.amount ?? 0),
      _ => t.rewardPurchased,
    };
    // The ink of the soft wallet that filled, or null for chips — which keep
    // the spinning chip and the gold.
    final softInk = switch (won?.kind) {
      'diamonds' => diamondInkOn(theme.brightness),
      'hammers' => hammerInkOn(theme.brightness),
      'missiles' => missileInkOn(theme.brightness),
      _ => null,
    };
    final softIcon = switch (won?.kind) {
      'hammers' => Icons.hardware,
      'missiles' => missileIcon,
      _ => Icons.diamond,
    };

    return Positioned.fill(
      child: GestureDetector(
        onTap: dismiss,
        child: ColoredBox(
          color: theme.colorScheme.scrim.withValues(alpha: 0.70),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Seeded on the amount so the burst pattern is fixed while the
              // banner is up and different for the next reward.
              Fireworks(seed: shownKey, bursts: 7),
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
                        child: grants != null
                            ? _GrantsSummary(
                                grants: grants,
                                t: t,
                                heroSize: chip,
                                onClose: dismiss,
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // A gem for diamonds, a hammer for hammers, the
                                  // spinning chip for chips: the hero says which
                                  // wallet just filled.
                                  softInk != null
                                      ? Icon(
                                          softIcon,
                                          size: chip,
                                          color: softInk,
                                        )
                                      : SpinningChip(
                                          colour: AppTheme.gold,
                                          size: chip,
                                          turn: const Duration(
                                            milliseconds: 900,
                                          ),
                                          rest: const Duration(
                                            milliseconds: 260,
                                          ),
                                        ),
                                  SizedBox(
                                    height: wallets ? Space.md : Space.lg,
                                  ),
                                  Text(
                                    t.rewardCollected,
                                    textAlign: TextAlign.center,
                                    style: AppTheme.label(text.titleMedium!),
                                  ),
                                  const SizedBox(height: Space.sm),
                                  Text(
                                    '+ ${formatChips(won!.amount)}',
                                    style: AppTheme.money(
                                      text.headlineMedium!,
                                      colour:
                                          softInk ?? _goldInk(theme.brightness),
                                    ),
                                  ),
                                  // A Premium Package's chips are the headline; the
                                  // missiles and hammers that came with them follow,
                                  // each in its wallet's mark and ink.
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
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: AppTheme.inkMed),
                                    ),
                                  ),
                                  const SizedBox(height: Space.lg),
                                  GlassButton(
                                    style: GlassButtonStyle.primary,
                                    onPressed: dismiss,
                                    click: true,
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

  /// A key for one claim's grants, so a second claim's celebration re-runs
  /// the entrance: the first grant's moment, which the server stamps.
  static int _grantsKey(List<RewardGrant> grants) =>
      grants.length * 1000003 + grants.first.claimedAt % 1000003;
}

/// The celebration's content after a reward program's claim: a gift over
/// "Daily rewards collected!", one line per reward the server gave — its mark
/// in its wallet's ink, "+ 10,000 chips", "Clapping Hands emoji" — and the
/// programs and days they came from. Set down to fit the screen: the list
/// scrolls before anything is cut.
class _GrantsSummary extends StatelessWidget {
  const _GrantsSummary({
    required this.grants,
    required this.t,
    required this.heroSize,
    required this.onClose,
  });

  final List<RewardGrant> grants;
  final Strings t;
  final double heroSize;
  final VoidCallback onClose;

  /// "+ 10,000 chips" for a wallet, an item by its name, "(already yours)"
  /// after an item the player had.
  String _line(RewardGrant g) {
    final label = rewardPrizeLabel(t, g.prize);
    final line = g.prize.isWallet ? '+ $label' : label;
    return g.alreadyOwned ? '$line (${t.rewardAlreadyOwned})' : line;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final b = theme.brightness;
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkMed,
    );
    final origins = grants
        .map(
          (g) =>
              '${t.rewardProgramName(g.programCode, g.programName)} · '
              '${t.rewardDay(g.day)}',
        )
        .join('   ');
    final size = MediaQuery.sizeOf(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: size.height * 0.82),
      child: Column(
        key: const ValueKey('rewards-celebration'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.card_giftcard_rounded,
            size: heroSize * 0.8,
            color: _goldInk(b),
          ),
          const SizedBox(height: Space.md),
          Text(
            t.rewardsCollectedTitle,
            textAlign: TextAlign.center,
            style: AppTheme.label(text.titleMedium!),
          ),
          const SizedBox(height: Space.sm),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final g in grants)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.xxs),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            rewardPrizeIcon(g.prize),
                            size: 20,
                            color: rewardPrizeInk(g.prize, b),
                          ),
                          const SizedBox(width: Space.xs),
                          Flexible(
                            child: Text(
                              _line(g),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTheme.money(
                                text.titleSmall!,
                                colour: rewardPrizeInk(g.prize, b),
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
          const SizedBox(height: Space.sm),
          Text(
            origins,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(color: quiet),
          ),
          const SizedBox(height: Space.lg),
          GlassButton(
            style: GlassButtonStyle.primary,
            onPressed: onClose,
            click: true,
            label: t.tapToClose,
          ),
        ],
      ),
    );
  }
}

/// The ledge the lobby hangs from: the player, their balance, the Shop and the
/// three panels they can open.
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
    // h=360 -> max(71.0, 56.2) = 71.0 | 411 -> max(80.5, 58.0) = 80.5
    // | 800 -> max(98.0, 64.0) = 98.0. The content box is therefore 58.7 /
    // 66.5 / 78.0, and every control in the row is at least 44dp. The
    // picture alone stands past it, into half of the pad under it
    // (Dim.avatarD), with a whole pad above it.
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
                // The provider tag folds on what the row actually has, not on
                // the screen width. It matters more now that the Shop key
                // shares this bar: on a 640dp screen the tag was rendering as
                // "GUE…", which tells nobody anything — better absent than
                // truncated. Until 30 Sep 2026 the row was what the 4-hour
                // bonus's slot left (Dim.cornerChipW, 0.3 of the bar); the
                // owner took the bonus away, and the row is the whole bar.
                final tight = Breaks.isTightBar(box.maxWidth);
                final gap = tight ? Space.sm : Space.md;

                return Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: Space.md,
                    vertical: pad,
                  ),
                  child: Row(
                    children: [
                      // The picture opens the bar. The 4-hour bonus stood
                      // before it (requirement 26) until the owner took the
                      // lobby's rewards away (30 Sep 2026), and the name has
                      // the room it took.
                      Tooltip(
                        message: state.t.yourPicture,
                        child: SizedBox(
                          width: math.max(Dim.minTouch, avatarD),
                          child: PressScale(
                            child: InkWell(
                              // The owner's lobby click in place of
                              // Material's tick (owner, 27 Sep 2026).
                              enableFeedback: false,
                              customBorder: const CircleBorder(),
                              onTap: () {
                                lobbyClick(context);
                                openPicturePicker(context);
                              },
                              // Taller than the row's content box by half
                              // a pad (Dim.avatarD, 30 Sep 2026): its top on
                              // the box's, a whole pad under the bar's edge
                              // (owner: "Keep some space above the profile
                              // picture"), and half a pad into the foot's.
                              child: OverflowBox(
                                alignment: Alignment.topCenter,
                                maxWidth: avatarD,
                                maxHeight: avatarD,
                                child: _AvatarWithPip(
                                  url: state.avatarUrl,
                                  fallback: user?.displayName ?? '',
                                  diameter: avatarD,
                                  // The picture grew on 30 Sep 2026; its
                                  // badge and edit mark did not (owner:
                                  // "don't increase size of badge").
                                  markDiameter: Dim.avatarMarkD(h),
                                  // The badge the player holds, on the
                                  // picture's top-right (owner, 29 Sep
                                  // 2026), where the game cards carried it.
                                  badge: true,
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
                              //
                              // Under the name, the player's level and the XP
                              // to the next one (owner, 27 Sep 2026: "In the
                              // Lobby on Top show current level of player and
                              // xp progress bar for next level"). A line under
                              // the name rather than anything beside it or round
                              // the picture: it takes no width from the name or
                              // the wallets, the figure reads in words where a
                              // ring could not carry it, and a tap anywhere on
                              // the name block opens the level screen. The
                              // provider tag keeps its line only where the three
                              // lines fit the bar's height — the level is the
                              // news, the tag a footnote the player knows.
                              Expanded(
                                child: _NameBlock(
                                  user: user,
                                  tight: tight,
                                  maxHeight: room.maxHeight,
                                  spill: pad,
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
                              // snapping, so a purchase landing is something you
                              // see happen. Past its cap it scales down (FittedBox),
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
                      // milestone chip (since removed) for the same corner.
                      // Icon-only on a tight bar, so the name keeps its letters.
                      ShopButton(compact: tight, click: true),
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

/// The top bar's name block: the player's name, their level and XP under it
/// ([LobbyLevelBar]) and, where the bar is tall and wide enough for a third
/// line, the provider tag. The name is laid out exactly as before — the same
/// width, the same style — so the level costs it no letter. A tap on the
/// block opens the level screen.
class _NameBlock extends StatelessWidget {
  const _NameBlock({
    required this.user,
    required this.tight,
    required this.maxHeight,
    required this.spill,
  });

  final User? user;

  /// A tight bar has no provider tag, as before.
  final bool tight;

  /// The bar's content height, which the lines must fit.
  final double maxHeight;

  /// The bar's own vertical padding, which the block may reach into rather
  /// than overflow where a tall script's name and the level line together
  /// stand a hair taller than the content box.
  final double spill;

  /// The gap between the name and the level line.
  static const double levelGap = 1;

  static double _lineHeight(
    BuildContext context,
    String text,
    TextStyle style,
    TextScaler scaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text.isEmpty ? ' ' : text,
        style: DefaultTextStyle.of(context).style.merge(style),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final h = painter.height;
    painter.dispose();
    return h;
  }

  @override
  Widget build(BuildContext context) {
    final user = this.user;
    final theme = Theme.of(context);
    final nameStyle = AppTheme.label(theme.textTheme.titleMedium!);
    final hasLevel = user?.playerLevel != null;
    final name = Text(
      user?.displayName ?? '',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      // A player's own name, in whatever script they wrote it.
      style: nameStyle,
    );

    var showTag = user != null && !tight;
    if (showTag && hasLevel) {
      // Measured in the fonts the phone draws them in: a mixed-script line
      // is taller than either font's own (§12.3).
      final scaler = MediaQuery.textScalerOf(context);
      final lang = context.select<GameState, AppLang>((s) => s.lang);
      final english = lang == AppLang.english;
      final tag = _ProviderPill.nameFor(lang, user.provider);
      final lines =
          _lineHeight(context, user.displayName, nameStyle, scaler) +
          _lineHeight(
            context,
            english ? tag.toUpperCase() : tag,
            _ProviderPill.styleFor(theme, english: english, compact: true),
            scaler,
          ) +
          levelGap +
          LobbyLevelBar.heightFor(scaler);
      showTag = lines <= maxHeight;
    }

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        name,
        if (showTag) _ProviderPill(provider: user!.provider, compact: true),
        if (hasLevel) ...[
          const SizedBox(height: levelGap),
          const LobbyLevelBar(),
        ],
      ],
    );
    if (!hasLevel) return column;
    return OverflowBox(
      maxHeight: maxHeight + 2 * spill,
      child: GestureDetector(
        key: const ValueKey('lobby-name-block'),
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTap: () => openLobbyLevel(context),
        child: PressScale(child: column),
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
      // One step off the room, as the bar's chips are (the depth ladder's
      // raised step) — cast round the glass, never under it, so the pill
      // keeps its own colour.
      child: DepthShadow(
        radius: Radii.pill,
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
            child: DepthFace(
              radius: Radii.pill,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: margin),
                child: Center(widthFactor: 1, child: child),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A wallet figure in the top bar, counting to its new value rather than
/// snapping to it, so a purchase or a prize landing is something you see
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
/// holds at every height. So does the badge ([badge]): painted over the
/// picture's top-right rim, it takes no layout.
class _AvatarWithPip extends StatelessWidget {
  const _AvatarWithPip({
    required this.url,
    required this.fallback,
    required this.diameter,
    this.markDiameter,
    this.ringed = false,
    this.badge = false,
  });

  final String? url;
  final String fallback;
  final double diameter;

  /// The picture the badge and the edit mark are sized from, when not the
  /// picture itself: the top bar's picture grew on 30 Sep 2026 and its marks
  /// kept their size (Dim.avatarMarkD). Their place is still the picture's.
  final double? markDiameter;

  /// A thin gold ring round the picture, a band of ground inside it — the
  /// Settings drawer's portrait (settings polish, 26 Sep 2026), in the store's
  /// words for the worn picture, only finer. Never the top bar's, whose rail
  /// is measured from this footprint and wears the plain hairline. Ring and
  /// pencil take the level's colour inside a Blind or Variation level
  /// ([LevelAccent]), which only the drawer's copy stands in.
  final bool ringed;

  /// The badge the player holds on the picture's top-right ([AvatarBadge]) —
  /// the top bar's picture and the Settings drawer's (owner, 29 Sep 2026:
  /// "add a badge on profile pic top right lobby", "In settings profile also
  /// u need to add badge").
  final bool badge;

  static const double _ringWidth = 2;
  static const double _ringGap = 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final glass = GlassColors.of(context);
    final level = LevelAccent.of(context);
    final marks = markDiameter ?? diameter;
    final pip = marks * 0.34;
    final art = AvatarBadge.sizeFor(marks);
    final centre = AvatarBadge.centreFor(diameter);

    return Stack(
      alignment: Alignment.bottomRight,
      // The badge's canvas reaches past the picture's box; only its emblem,
      // on the rim, shows.
      clipBehavior: Clip.none,
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
              ? (level?.fill ??
                    (brightness == Brightness.dark
                        ? AppTheme.goldBright
                        : AppTheme.gold))
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
              color:
                  level?.hairline(live: true) ??
                  AppTheme.hairlineColour(brightness, live: true),
              width: Dim.hairline,
            ),
          ),
          child: Icon(
            Icons.edit,
            size: pip * 0.56,
            color: level?.ink ?? _goldInk(brightness),
          ),
        ),
        // Over the picture and its edit mark, and never in the way of a tap:
        // a tap on the badge is a tap on the picture.
        if (badge)
          Positioned(
            left: centre.dx - art / 2,
            top: centre.dy - art / 2,
            width: art,
            height: art,
            child: IgnorePointer(child: AvatarBadge(size: art)),
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

  /// The provider as the tag names it: a guest in the player's language, a
  /// provider by its brand name.
  static String nameFor(AppLang lang, String provider) => provider == 'guest'
      ? Strings(lang).providerGuest
      : provider.isEmpty
      ? ''
      : '${provider[0].toUpperCase()}${provider.substring(1)}';

  /// The tag's type — which the top bar also measures ([_NameBlock]).
  static TextStyle styleFor(
    ThemeData theme, {
    required bool english,
    required bool compact,
  }) => AppTheme.smallCaps(
    theme.textTheme.labelSmall!,
    tracking: english ? (compact ? 0.9 : 1.2) : 0,
    colour: theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkLow),
  ).copyWith(fontSize: compact ? 9 : null, height: compact ? 1.1 : null);

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
    final name = nameFor(lang, provider);
    final label = Text(
      english ? name.toUpperCase() : name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: styleFor(theme, english: english, compact: compact),
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
                // The owner's lobby click in place of Material's tick (owner,
                // 27 Sep 2026), then the caller's own callback: the light
                // haptic comes from the PressScale above, which fires it on
                // release.
                enableFeedback: false,
                onTap: () {
                  lobbyClick(context);
                  onTap();
                },
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
      // One step off the room, as the wallet pill beside it, cast round the
      // glass and never under it.
      child: DepthShadow(
        radius: Radii.pill,
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
            child: DepthFace(
              radius: Radii.pill,
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
              lobbyClick(context);
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
                                  // The owner's coins in the card's
                                  // colour (29 Sep 2026), a little taller
                                  // than the name's capitals (owner, 30 Sep
                                  // 2026: "increase the animated coin
                                  // size"; they stood as tall as the
                                  // two-chip pile they replaced, 0.76 of the
                                  // name's size). The pile is 0.8 of its
                                  // width tall, so it stays inside the
                                  // name's line and the row does not grow.
                                  CardCoins(
                                    size: m.titleSize * 1.1,
                                    fallbackInk: palette.ink,
                                    tint: accent,
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
                              // Twice the card's gap between the name and
                              // its line (owner, 30 Sep 2026: "add some
                              // space between 'Seen' and 'Everyone's chips
                              // visible'"): 16dp, 24dp on a roomy card. A
                              // tight card gives it up before any words
                              // shrink (CardColumn). An engine card's
                              // (Teen Patti, Poker — the shuffling chips)
                              // keeps the one gap: it has the most to hold.
                              CardGap(shuffle ? m.gap : m.gap * 2),
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
                              // The owner's lock Lottie in the icon's box
                              // (29 Sep 2026), still and faded when none is
                              // open, as the "0" beside it is said quietly.
                              glyph: (size, ink) => OpenLock(
                                size: size,
                                fallbackInk: ink,
                                tint: palette.accent,
                                quiet: open == 0,
                              ),
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
/// inside an engine, the engine from inside one of its categories — or every
/// game again where the categories stand on the front, as they do in a build
/// without the Poker family (GameState.lobbyFrontEngine). The system Back key
/// does the same (main.dart's `_BackGuard`).
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
                  lobbyClick(context);
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
                      // colour — and in it the owner's back key (30 Sep
                      // 2026), whose own ring is the well's edge, in the
                      // card's display ink ([BackMark]).
                      Container(
                        width: disc,
                        height: disc,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: glass.wellFill,
                        ),
                        child: BackMark(
                          size: disc,
                          fallbackInk: glass.textDisplay,
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
    // keeps stacks hidden as a blind one does (owner, 18 Sep 2026) — and since
    // 28 Sep 2026 bets as one too, a public one raising as far as the chips
    // go (it bet as a seen table did until then) — has no pot limit, and is a
    // card of its own with its own name and its own line about what happens
    // there.
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
                  // The card's click, the door, then the room.
                  lobbyClick(context);
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
              // The boot's name under it, set small and tracked as a caption
              // where the script allows — BOOT in English; tracking pulls
              // Indic vowel signs off their letters, so the other languages
              // keep their own case and spacing.
              final caption = Padding(
                padding: EdgeInsets.only(
                  left: m.bootSize * 0.56 + m.markGap,
                  top: CardSpace.s4,
                ),
                child: Text(
                  state.lang == AppLang.english ? t.boot.toUpperCase() : t.boot,
                  style:
                      AppTheme.label(
                        text.labelSmall!,
                        colour: glass.cardMuted,
                      ).copyWith(
                        height: 1.0,
                        letterSpacing: state.lang == AppLang.english ? 1.4 : 0,
                      ),
                ),
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
                          // Under the figure by a hair more than its
                          // line, which its comma hangs below. (The "20%
                          // TAX" pill that hung on this line went on 27 Sep
                          // 2026 — owner: "remove the text 20% Tax" — and
                          // the corner that took its place, the level's
                          // mark, the badge and the rate, on 29 Sep: the
                          // badge is on the top bar's picture now.)
                          caption,
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
                          // translation wraps at a large text size. A
                          // seen or blind table has none (owner, 29 Sep
                          // 2026: "Everyone's chips are visible" off the
                          // 200 and 50,000 tables, then "Only your own
                          // chips are visible" off the 200, 5,000,
                          // 50,000 and 20 Lakh ones): its category card,
                          // the ⓘ popup and the rules still say it.
                          if (poker || variation) ...[
                            Text(
                              poker
                                  ? t.pokerVariantNote(category)
                                  : t.variationTableNote,
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
                          ],

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
                              // The owner's piggy bank Lottie in the icon's
                              // box (29 Sep 2026), still on a table the
                              // player cannot sit at.
                              glyph: (size, ink) => PotPiggy(
                                size: size,
                                fallbackInk: ink,
                                tint: palette.accent,
                                still: shut,
                              ),
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
                            // The owner's wallet Lottie in the icon's box
                            // (29 Sep 2026), standing still on a table the
                            // player cannot sit at.
                            glyph: (size, ink) => EntryWallet(
                              size: size,
                              fallbackInk: ink,
                              tint: palette.accent,
                              still: shut,
                            ),
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
                // The owner's info Lottie in the card's colour (29 Sep
                // 2026), its waves rippling to the disc's hairline.
                glyph: InfoWave(
                  size: _cornerDisc - 2,
                  fallbackInk: palette.ink,
                  tint: palette.accent,
                ),
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
                // The owner's rule book Lottie in the card's colour (29 Sep
                // 2026), its whole hop inside the key's disc.
                glyph: RuleBook(
                  size: _ruleBookSize,
                  fallbackInk: palette.ink,
                  tint: palette.accent,
                ),
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

/// The rules key's book: the 16dp glyph it replaced, grown to what the book's
/// whole hop needs to read, still inside the disc.
const double _ruleBookSize = 22;

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
    this.glyph,
  });

  final IconData icon;

  /// Drawn in the disc in place of [icon]: the rules key's book.
  final Widget? glyph;

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
        // Its own click, and only its own: the key wins the tap over the card
        // it stands on, so the card underneath neither opens nor clicks.
        onTap: () {
          tapHaptic(context);
          lobbyClick(context);
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
              child: Center(
                child: glyph ?? Icon(icon, size: 16, color: palette.ink),
              ),
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
    final level = state.user?.playerLevel;
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
      // A table that taxes its winners (owner, 26 Sep 2026): the rate THIS
      // player would pay here — the lower of their level's and their
      // badges' — and their level.
      if (table.taxesWinner) ...[
        _CardFact(
          icon: winningTaxIcon,
          palette: palette,
          label: t.winningTaxLabel,
          value: switch (state.user?.paysTaxBps) {
            final bps? => formatTaxRate(bps),
            null => '—',
          },
          height: 26,
          ink: TableInk.taxOn(theme.brightness),
        ),
        if (level != null)
          _CardFact(
            icon: Icons.military_tech_rounded,
            palette: palette,
            label: t.yourLevelLabel,
            value: levelNameOf(t, level),
            height: 26,
            fixedLine: true,
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
          // Where the table taxes its winners from a floor (owner, 27 Sep
          // 2026: "30 lakh is the limit on winning amount"): said once, under
          // the chips line, rather than squeezed into the rate's row.
          if (table.taxesWinner && table.winnerTaxMinWinnings > 0)
            Text(
              t.winningTaxFrom(formatChips(table.winnerTaxMinWinnings)),
              key: const ValueKey('table-info-tax-from'),
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
      // A key standing on its card: its top edge lit and its foot in shade
      // while it can be pressed (the depth ladder's raised step), flush with
      // the card when it cannot.
      child: DepthFace(
        radius: Radii.pill,
        strength: enabled ? 1 : 0,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: CardSpace.s12),
          child: Center(
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
          ),
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
    this.ink,
    this.fixedLine = false,
    this.glyph,
  });

  final IconData icon;

  /// Drawn in place of [icon], in the icon's box ([size] square) — the "Open
  /// to you" row's lock Lottie, the "Entry" row's wallet, the "Pot limit"
  /// row's piggy bank; [ink] is the icon's colour, for its fallback.
  final Widget Function(double size, Color ink)? glyph;

  final TablePalette palette;
  final String label;
  final String value;

  /// The value's own ink, over [highlight], [money] and [quiet]: the winning
  /// tax's amber ([TableInk.taxOn]).
  final Color? ink;

  /// Holds the value to its style's own line height: a value with a level's
  /// colour-emoji mark in it would otherwise stand taller than the row.
  final bool fixedLine;

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
    final valueInk =
        ink ??
        (highlight
            ? palette.ink
            : money
            ? _goldInk(theme.brightness)
            : quiet
            ? glass.cardMuted
            : glass.textDisplay);
    // The row is never shorter than its words' own glyphs, which at a large
    // text size stood taller than the box; the card's column scales down to
    // hold the taller rows instead of clipping their tops and tails.
    final glyphs = MediaQuery.textScalerOf(context).scale(size) * 1.2;
    final markSize = (height * 0.78).clamp(13.0, 19.0);
    final markInk = palette.ink.withValues(alpha: 0.80);
    final valueStyle = AppTheme.money(
      text.labelLarge!,
      fontSize: size,
      colour: valueInk,
    );

    return SizedBox(
      height: math.max(height, glyphs),
      child: Row(
        children: [
          if (glyph case final draw?)
            draw(markSize, markInk)
          else
            Icon(icon, size: markSize, color: markInk),
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
            strutStyle: fixedLine ? levelStrut(valueStyle) : null,
            style: valueStyle,
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
                        // The owner's coins in the card's colour (29 Sep
                        // 2026), where the spinning chip was — as large as
                        // the badge holds (owner, 30 Sep 2026: "increase the
                        // animated coin size"; 0.72 before): the pile is 0.8
                        // of its width tall, 0.75 of the badge, and the badge
                        // clips anything taller.
                        CardCoins(
                          size: h * 0.94,
                          fallbackInk: palette.ink,
                          tint: palette.accent,
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
                            click: true,
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
                            click: true,
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
                  depth: Elevation.overlay,
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
                          // The way back to the Google photo is its own tile,
                          // first on the All shelf (owner, 28 Sep 2026), where it
                          // is seen; an unlabelled icon here was not.
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
                                  f: shelfCount(state, f),
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
  const _LobbyDrawer({required this.head, required this.children, this.width});

  /// The title, which does not scroll.
  final Widget head;

  final List<Widget> children;

  /// The panel's width for the screen's [width]: [Dim.drawerW] unless the
  /// panel says otherwise (the Stats drawer, whose record stands three cards
  /// across).
  final double Function(double width)? width;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;

    return Drawer(
      backgroundColor: Colors.transparent,
      elevation: 0,
      // 640 -> 260.0 | 891 -> 356.4 | 1280 -> 380.0.
      width: (width ?? Dim.drawerW)(w),
      child: Padding(
        padding: const EdgeInsets.all(Space.sm),
        child: PremiumGlassPanel(
          mode: GlassMode.auto,
          priority: 10,
          depth: Elevation.overlay,
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
///
/// Inside a Blind or Variation level both are laid in that level's hue
/// ([LevelAccent], owner, 30 Sep 2026): Seen's cream is the gold's, and a
/// Blind drawer over a sapphire-lit room is ice, a Variation one lavender.
class _DrawerBody extends StatelessWidget {
  const _DrawerBody();

  /// How far the theme's cross-fade has come from obsidian (0) to ice (1),
  /// read off the ground colour, which lerps with the rest of the theme.
  static double dayOf(GlassColors glass) => glass.dayShare;

  /// A warm stone well under the pearl.
  static final Color _stoneWell = Color.alphaBlend(
    TableGround.pearlEdge.withValues(alpha: 0.55),
    TableGround.pearl,
  );

  /// The fill of what is sunk into the drawer — the two fields and the
  /// appearance control: the theme's own well by night, and by day a warm
  /// stone rather than the theme's cool slate, which read grey-blue on the
  /// pearl — in the level's hue inside a Blind or Variation level.
  static Color well(BuildContext context) {
    final glass = GlassColors.of(context);
    final level = LevelAccent.of(context);
    final stone = level == null
        ? _stoneWell
        : Color.alphaBlend(
            level.pearlEdge.withValues(alpha: 0.55),
            level.pearl,
          );
    return Color.lerp(glass.wellFill, stone, dayOf(glass)) ?? glass.wellFill;
  }

  @override
  Widget build(BuildContext context) {
    final glass = GlassColors.of(context);
    final level = LevelAccent.of(context);
    final day = dayOf(glass);
    final pearl = level?.pearl ?? TableGround.pearl;
    final stone = Color.lerp(
      pearl,
      level?.pearlEdge ?? TableGround.pearlEdge,
      0.4,
    )!;
    Color at(Color night, Color dayColour) =>
        Color.lerp(night, dayColour, day) ?? night;

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            at(
              level?.charcoal ?? GlassColors.dark.cardFill,
              pearl.withValues(alpha: 0.94),
            ),
            at(
              level?.charcoalEnd ?? GlassColors.dark.cardFillEnd,
              stone.withValues(alpha: 0.96),
            ),
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
/// Stats drawer's portrait, so the two heads stand alike — the Lucky Draw's
/// chip wears the same disc while a spin can be taken. Lit in the level's
/// colour inside a Blind or Variation level ([LevelAccent]).
class _HeadMark extends StatelessWidget {
  const _HeadMark({required this.icon});

  final IconData icon;

  /// The Stats drawer's portrait is radius 16.
  static const double size = 32;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;
    final level = LevelAccent.of(context);
    final light = level?.fill ?? AppTheme.gold;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: light.withValues(alpha: dark ? 0.16 : 0.12),
        border: Border.all(
          color: light.withValues(alpha: dark ? 0.45 : 0.50),
          width: Dim.hairline,
        ),
      ),
      child: Icon(icon, size: 18, color: level?.ink ?? _goldInk(brightness)),
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
      // A pane one step above the drawer (the depth ladder's raised step,
      // nested: the drawer's small shadow, not the room's), its top edge lit
      // and its foot in shade under its rows.
      child: DepthShadow(
        radius: Radii.md,
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
          child: DepthFace(
            radius: Radii.md,
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
      color:
          LevelAccent.of(context)?.hairline() ??
          AppTheme.hairlineColour(Theme.of(context).brightness),
    ),
  );
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
///
/// One continuous profile since the owner's brief of 27 Sep 2026 ("Do NOT use
/// tabs … Poker must NOT appear anywhere in this drawer"): who the player is
/// and their level at the head ([PlayerStatsHeader]), then their record
/// ([OwnRecord]) — PERFORMANCE with a small scope menu (All Games, Teen Patti,
/// Variations), HAND RESULTS and VARIATIONS PLAYED. The Friends page and a
/// table's player drawer still draw another player's record with
/// [PlayerStatsGrid], as they did.
///
/// It listens to the account and the language alone, not to the lobby's
/// one-second tick: the one line that counts down (today's XP, where the
/// server keeps a daily window) listens for itself.
class _StatsDrawer extends StatelessWidget {
  const _StatsDrawer();

  /// Wider than the Settings drawer: the record stands three cards across,
  /// and on a 592 or 640dp phone at text x1.25 [Dim.drawerW]'s 260dp left a
  /// card too narrow for a count and its name. 592 -> 300 | 640 -> 300 |
  /// 891 -> 409.9 | 1280 -> 420: under half a phone's width, and no wider
  /// than a comfortable column on a tablet.
  static double widthFor(double w) => (w * 0.46).clamp(300.0, 420.0);

  @override
  Widget build(BuildContext context) {
    final (user, lang) = context.select<GameState, (User?, AppLang)>(
      (s) => (s.user, s.lang),
    );
    final t = Strings(lang);

    return _LobbyDrawer(
      width: widthFor,
      head: PlayerStatsHeader(
        t: t,
        name: user?.displayName ?? '',
        // The account's picture, resolved as the top bar resolves it.
        avatarUrl: context.read<GameState>().avatarUrl,
        level: user?.playerLevel,
        badges: user?.badges ?? const [],
      ),
      children: [
        const SizedBox(height: Space.sm),
        _Entrance(
          index: 0,
          axis: Axis.vertical,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.lg),
            child: OwnRecord(
              key: const ValueKey('own-record'),
              t: t,
              user: user,
            ),
          ),
        ),
        const _DrawerRule(space: Space.lg),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
          // In the record's muted ink, which holds 5:1 on the day's pearl;
          // the theme's quiet ink it had measured 3:1 there.
          child: StatsFootnote(t.playedNote),
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
        // Measured a hair short of the room, so a line that only just fits
        // by this measure can never be clipped by the paragraph that draws it.
        final painter = TextPainter(
          text: line,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout(maxWidth: math.max(0, box.maxWidth - 1));
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
    // In the level's colour inside a Blind or Variation level.
    final level = LevelAccent.of(context);
    final chosen = level?.ink ?? _goldInk(brightness);
    final ink = selected
        ? chosen
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
                  ? (level?.fill ?? AppTheme.gold).withValues(
                      alpha: dark ? 0.14 : 0.10,
                    )
                  : Colors.transparent,
              border: Border.all(
                color: selected
                    ? (level?.chosenEdge ??
                          (dark
                              ? AppTheme.goldBright.withValues(alpha: 0.55)
                              : AppTheme.hairlineColour(
                                  brightness,
                                  live: true,
                                )))
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
                          colour: selected ? chosen : glass.cardMuted,
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
                    color: chosen,
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
    // The choice on, in the level's colour inside a Blind or Variation level.
    final chosenInk =
        LevelAccent.of(context)?.ink ?? _goldInk(theme.brightness);

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
                            colour: chosenInk,
                          ),
                          unitsStyle: AppTheme.label(
                            text.labelMedium!,
                            colour: chosenInk,
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
    final well = _DrawerBody.well(context);
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
                        // A quarter larger than its first 72dp (owner,
                        // 30 Sep 2026: "make it large more 25 percent, keep
                        // badge size same"): the badge and the pencil keep
                        // the 72dp picture's size, on the bigger rim.
                        diameter: 90,
                        markDiameter: 72,
                        ringed: true,
                        // The badge, as on the top bar's picture (owner,
                        // 29 Sep 2026: "In settings profile also u need to
                        // add badge").
                        badge: true,
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
                      child: GameLoaderRing(size: 18),
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
            // who does not read the current one can act on — with its English
            // name beside it in the list, where there is room.
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
            // The field itself names the language on in its own words alone:
            // with its English name too it was cut short in the drawer's
            // width at text x1.25 ("বাংলা  ·  Beng…").
            selectedItemBuilder: (context) => [
              for (final l in AppLang.values)
                Text(
                  l.nativeName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
    this.settled = false,
  });

  final int index;
  final Widget child;
  final Axis axis;

  /// Already in place: a card that arrives with a change of the lobby's level
  /// comes in with the level's own transition (_railTransition) instead of
  /// making an entrance of its own.
  final bool settled;

  @override
  State<_Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<_Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Motion.enter,
    value: widget.settled ? 1 : 0,
  );

  @override
  void initState() {
    super.initState();
    if (widget.settled) return;
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

/// The Lucky Draw (owner, 24 Sep 2026), in the lobby's bottom-left corner: a
/// small wheel that turns now and then while a spin is due, and the time left
/// while the wheel recharges. Either way a tap opens the draw ([showLuckyDraw])
/// — its prizes are worth a look while the wait runs. Absent when the server
/// offers no draw (none open, or a server that predates it).
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
        child: _CornerChip(
          icon: Icons.casino_rounded,
          title: state.t.luckyDrawChip,
          subtitle: state.t.luckySpinReady,
          enabled: false,
          onTap: () {},
        ),
      );
    }
    final now = DateTime.now();
    final due = draw.readyAt(now);
    return KeyedSubtree(
      key: const ValueKey('lucky-draw-chip'),
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

/// The reward programs (owner, 30 Sep 2026) beside the Lucky Draw in the
/// lobby's bottom-left corner: the login streaks and the calendar rewards
/// the server runs. Its second line is what stands — "Collect now" while a
/// program's today waits, else the longest login streak ("3 day streak"), or
/// "Collected today" — and a tap opens the rewards screen, claiming first
/// when something waits. Absent when the server describes no program (none
/// running, or a server that predates them).
///
/// It is also where the lobby CLAIMS: the moment the lobby is up — its
/// resume wait over, so a held seat is not asked at — today's rewards are
/// claimed once, and the celebration follows what the server says it gave.
/// A reconnect claims again from session:ready; the server grants once a
/// day whoever asks.
class _RewardsChip extends StatefulWidget {
  const _RewardsChip();

  @override
  State<_RewardsChip> createState() => _RewardsChipState();
}

class _RewardsChipState extends State<_RewardsChip> {
  bool _asked = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    if (state.user == null) return const SizedBox.shrink();
    if (!_asked && !state.resuming) {
      _asked = true;
      final gameState = context.read<GameState>();
      scheduleMicrotask(() => unawaited(gameState.loadRewardPrograms()));
    }
    final programs = state.rewardPrograms;
    if (programs == null || programs.isEmpty) {
      // While the first claim is out, the chip's room is kept, unseen, as the
      // Lucky Draw's is: a toast raised at sign-in is placed the moment it
      // appears (lobbyNoticeArea).
      if (!state.rewardClaimPending && !state.rewardProgramsLoading) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: const EdgeInsets.only(left: Space.sm),
        child: Visibility.maintain(
          visible: false,
          child: _CornerChip(
            icon: Icons.card_giftcard_rounded,
            title: t.rewardsChip,
            subtitle: t.rewardsCollect,
            enabled: false,
            onTap: () {},
          ),
        ),
      );
    }
    final due = programs.any((p) => !p.claimedToday);
    var streak = 0;
    for (final p in programs) {
      if (p.program.isStreak) streak = math.max(streak, p.claimedDays);
    }
    final subtitle = due
        ? t.rewardsCollect
        : streak > 0
        ? t.streakDays(streak)
        : t.rewardsCollected;
    // A tap: the weekly login popup while its day waits (the owner's
    // calendar, the same one that pops at sign-in), else the rewards screen.
    void open() {
      if (!context.read<GameState>().offerWeeklyLogin(again: true)) {
        showRewardPrograms(context);
      }
    }

    return Padding(
      padding: const EdgeInsets.only(left: Space.sm),
      child: KeyedSubtree(
        key: const ValueKey('rewards-chip'),
        child: _CornerChip(
          icon: Icons.card_giftcard_rounded,
          title: t.rewardsChip,
          subtitle: subtitle,
          enabled: due,
          onTap: open,
          onWaitTap: open,
        ),
      ),
    );
  }
}

/// On the foot's left-hand chips — the Lucky Draw and the rewards — so
/// [lobbyNoticeArea] can keep a toast off them.
///
/// Measured rather than worked out: each chip is as wide as its two lines of
/// text in the player's language, which nothing outside it knows.
final _luckyChip = GlobalKey(debugLabel: 'lucky draw chip');

/// On the row of round keys in the bottom-right corner — the level key and
/// Friends — for the same reason, and so [lobbyNoticeArea] can tell when a
/// page covers the lobby.
final _footKeys = GlobalKey(debugLabel: 'foot keys');

/// The narrowest a lobby toast is made to keep clear of the foot's round keys:
/// a toast squeezed any narrower between the foot's corners would break every
/// few words, so below this it stands where it always stood and may cover the
/// keys while it shows.
const double _toastFloor = 160;

/// Where a notice may stand in the lobby, in screen coordinates, or null for
/// the plain foot of the screen.
///
/// The lobby's foot holds the Lucky Draw chip in its left-hand corner and the
/// level and Friends keys in its right-hand one. The toast keeps its width and
/// its place at the foot and moves aside only as far as a corner needs,
/// narrowing only if the whole space between them is smaller than it — and it
/// keeps clear of the round keys only where that still leaves it [_toastFloor]
/// to stand in. With nothing laid out at the foot (no account yet) it is
/// centred.
///
/// Until 30 Sep 2026 the milestone chip stood in the right-hand corner and the
/// daily bonus beside the Lucky Draw, and the toast was measured between them;
/// the owner took the lobby's rewards away and the corners closed up.
///
/// While a page or a dialog stands over the lobby (the Friends page, the
/// store), the foot is covered and there is nothing at it to keep clear of:
/// the toast takes the plain foot. Kept between the chips under the page, the
/// Friends page's "Tall7 is no longer your friend." stood 156dp wide on a
/// 640dp phone and broke over three lines (26 Sep 2026).
Rect? lobbyNoticeArea(BuildContext context) {
  final foot = _footKeys.currentContext;
  final keys = foot?.findRenderObject();
  if (foot == null || keys is! RenderBox || !keys.attached || !keys.hasSize) {
    return null;
  }
  if (ModalRoute.isCurrentOf(foot) == false) return null;

  RenderBox? laidOut(RenderObject? box) =>
      box is RenderBox && box.attached && box.hasSize && !box.size.isEmpty
      ? box
      : null;
  final lucky = laidOut(_luckyChip.currentContext?.findRenderObject());
  final corner = laidOut(keys);
  // Nothing at the foot: the plain, centred foot.
  if (lucky == null && corner == null) return null;

  final size = MediaQuery.sizeOf(context);
  final safe = MediaQuery.paddingOf(context);
  final width = Dim.toastW(size.width);
  var start = safe.left + Space.md;
  if (lucky != null) {
    final luckyRight = lucky.localToGlobal(Offset(lucky.size.width, 0)).dx;
    if (luckyRight.isFinite) start = math.max(start, luckyRight + Space.sm);
  }
  var end = size.width - safe.right - Space.md;
  if (corner != null) {
    final clear = corner.localToGlobal(Offset.zero).dx - Space.sm;
    if (clear.isFinite && clear - start >= _toastFloor) {
      end = math.min(end, clear);
    }
  }
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

/// A corner chip's mark in a disc of its own: the Lucky Draw's wheel. Gold-lit
/// while a spin can be taken, a quiet well while it is coming, so the chip's
/// state reads from the corner of the eye before its words do.
class _ChipMark extends StatelessWidget {
  const _ChipMark({required this.ready, required this.child});

  final bool ready;
  final Widget child;

  /// Room for an 18dp mark and a margin, well inside the 44dp pill.
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

/// A pill in a corner of the lobby's foot — today the Lucky Draw's — with
/// its mark in a disc, a title and one line under it.
///
/// Both states carry the same body; what changes is the edge and the glow. A
/// chip that can be taken is legible from the corner of the eye instead of
/// needing two container colours compared side by side, and a chip that is
/// still counting down stops looking like a button that does nothing.
///
/// It was the lobby's reward chip — the 4-hour bonus, the daily bonus and the
/// milestone wore it — until the owner took those away (30 Sep 2026).
class _CornerChip extends StatelessWidget {
  const _CornerChip({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
    this.leadingBuilder,
    this.onWaitTap,
  });

  final IconData icon;

  /// Replaces the plain [icon] when a chip wants a moving one. It is a builder
  /// rather than a widget because the foreground colour is decided here, from
  /// whether the chip is enabled.
  final Widget Function(Color colour)? leadingBuilder;
  final String title;

  /// The second line: what is ready, or the time left.
  final String subtitle;

  final bool enabled;
  final VoidCallback onTap;

  /// What a tap does while the chip is not [enabled] — the Lucky Draw opens
  /// its wheel and the time left. Null leaves a chip that is still counting
  /// down deaf to the finger.
  final VoidCallback? onWaitTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final brightness = theme.brightness;
    final glass = GlassColors.of(context);
    final dark = brightness == Brightness.dark;
    final gold = _goldInk(brightness);
    // The mark and the second line: gold while it can be taken, the card's
    // own ink while it is still coming — the chip's news is whether it is
    // ready, and that is what the colour says.
    final fg = enabled ? gold : glass.textBody;
    // A finite cap so the two lines can ellipsise. Without one this pill sizes
    // to its longest translation and runs off the screen.
    final cap = Dim.cornerChipW(MediaQuery.sizeOf(context).width);
    final money = AppTheme.money(
      text.labelLarge!,
      colour: enabled ? gold : glass.textDisplay,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: cap),
      // Presses in while a tap does something. A chip with nothing to do
      // while it counts down stays still under the finger, which says it is
      // not a key yet.
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
            // The lobby's click (owner, 27 Sep 2026) on every tap that does
            // something; a chip with no tap stays silent.
            click: true,
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
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: money,
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
