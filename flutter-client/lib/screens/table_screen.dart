import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../net/picture_cache.dart';
import '../state/game_state.dart';
import '../state/hammer_strike.dart';
import '../state/missile_strike.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import '../widgets/buy_chips.dart';
import '../widgets/casino_table.dart';
import '../widgets/chip_store.dart';
import '../widgets/deal_flight.dart';
import '../widgets/drifting_chips.dart';
import '../widgets/glass_components.dart';
import '../widgets/glass_panels.dart';
import '../widgets/hand_fan.dart';
import '../widgets/hammer_flight.dart';
import '../widgets/missile_flight.dart';
import '../widgets/picture_shelf.dart';
import '../widgets/playing_card.dart';
import '../widgets/poker_chip.dart';
import '../widgets/pot_flight.dart';
import '../widgets/premium_surface.dart';
import '../widgets/seat_pod.dart';
import '../widgets/seat_ring.dart';
import '../widgets/table_chrome.dart';
import '../widgets/variation_prompt.dart';
import '../widgets/wild_transform.dart';
import 'poker_table_screen.dart';
import '../widgets/table_picture_shelf.dart';

/// The game room: an emerald table in a champagne rail, standing in a charcoal
/// room under one overhead lamp, with the players around it, the pot in the
/// middle, the viewer's own hand at the bottom, and one console of controls.
///
/// The viewer always sits at the bottom and the table turns around them.
///
/// Two rules hold the whole screen together.
///
/// **Nothing on this screen blurs.** A `BackdropFilter` does not cache: it
/// re-reads and re-blurs its backdrop on every frame that backdrop repaints,
/// and this backdrop — a breathing lamp, chips in flight, five pods — is dirty
/// forever. The rail and the console are [GlassMode.tinted], which is the same
/// fill, sheen, hairline and shadow with no filter, and a blur of smooth
/// emerald baize produces smooth emerald baize. The two drawers ask the
/// [GlassBudget] for the one transient blur it allows; everything on the cloth
/// is a solid [Plate].
///
/// **Anything that sits on the cloth is a dark plate with light ink, in both
/// brightnesses**, because the cloth is dark emerald in both. Only the chrome
/// standing on the ground — the rail, the console, the drawers — follows the
/// theme.
class TableScreen extends StatefulWidget {
  const TableScreen({super.key});

  @override
  State<TableScreen> createState() => _TableScreenState();
}

class _TableScreenState extends State<TableScreen> {
  /// The menu and the chat (with its quick messages tab) share one drawer
  /// rather than being a drawer and a sheet: both are "the panel behind the
  /// left edge", and a Scaffold has only one of those. Which one is showing is
  /// decided before it opens — and one drawer is also what lets the back
  /// gesture close any of them (`_BackGuard` asks only `isDrawerOpen`).
  ///
  /// At rest it is always the menu ([_drawerGone]): the rail's keys choose a
  /// panel as they open the drawer, but a swipe in from the left edge chooses
  /// nothing and finds whatever is there.
  LeftPanel _panel = LeftPanel.menu;

  /// Opening is driven from the rail, which sits inside this Scaffold, so the
  /// state is reached by key rather than by looking up an ancestor. The key
  /// lives on the game state so the back gesture can close the drawer too.
  GlobalKey<ScaffoldState> get _scaffold =>
      context.read<GameState>().tableScaffold;

  void _open(LeftPanel panel) {
    // Only the chat shows the conversation, so only the chat clears its
    // badge. It always opens on the conversation, even though its quick
    // messages tab sends into it without showing it.
    if (panel == LeftPanel.chat) context.read<GameState>().markChatRead();
    setState(() => _panel = panel);
    _scaffold.currentState?.openDrawer();
  }

  /// Puts the menu back behind the edge once the drawer has finished closing.
  ///
  /// Left as it was, a swipe in from the edge after the chat would show the
  /// conversation without clearing its badge, a tab away from quick messages
  /// where one stray tap talks to the whole table. The menu sends nothing and
  /// reads nothing, so it is what a swipe should find.
  ///
  /// `Scaffold.onDrawerChanged` cannot do this: it fires as the close starts,
  /// with the panel still on screen, and swapping it there would flash the
  /// menu across the slide-out. [DrawerSlot] reports the end instead. It is
  /// told while the tree is being finalised, where setState is not allowed,
  /// hence the hop to after the frame — which still lands before any later
  /// touch, because input is handled between frames.
  void _drawerGone() {
    if (_panel == LeftPanel.menu) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _panel = LeftPanel.menu);
    });
  }

  @override
  Widget build(BuildContext context) {
    // A poker room is a different game on the same chrome: its own screen,
    // mounted in place of this body. `select` on a bool that changes only
    // with the table, so the once-a-second tick never reaches the Scaffold.
    if (context.select<GameState, bool>((s) => s.room?.isPoker == true)) {
      return const PokerTableScreen();
    }
    // This widget subscribes to nothing itself: the game state ticks once a
    // second for the reward countdown, and rebuilding the Scaffold tears an
    // open drawer down with it. Everything inside subscribes for itself.
    return Scaffold(
      key: _scaffold,
      // The table is a fixed landscape layout that fills the screen. Letting
      // the soft keyboard shrink it squeezed the rail and the chat panel until
      // both painted overflow stripes; the chat drawer lifts its own composer
      // over the keyboard (`viewInsets`), which is the only thing that needs
      // to move.
      resizeToAvoidBottomInset: false,
      // The room dimmed behind the drawer, not blacked out: the table's own
      // scrim (TableScrim.drawer), where Material's black at 0.54 turned the
      // light theme's room to grey mud.
      drawerScrimColor: TableScrim.drawer,
      drawer: DrawerSlot(
        onGone: _drawerGone,
        child: switch (_panel) {
          LeftPanel.menu => const TableDrawer(),
          LeftPanel.chat => const ChatDrawer(),
        },
      ),
      body: Stack(
        children: [
          // The room the table stands in — charcoal floor, one warm pool where
          // the lamp hangs, corners closed by a vignette. It is painted behind
          // the cutout as well as inside it, so the screen has no seam.
          const Positioned.fill(child: RoomGround()),
          const TurnBuzzer(),
          // Chips crossing the room the table sits in, from whichever
          // direction each one runs. They live in the margin around the felt —
          // the only part of this screen with nothing in it — so the room reads
          // as somewhere a game is happening rather than as a blank ground.
          // Behind everything and untouchable — and only while no table
          // picture is laid: a bought picture (_TableCentrepiece, behind the
          // pot) takes their place, and the store's "Flowing chips" tile
          // brings them back (owner, 15 Sep 2026).
          const Positioned.fill(child: IgnorePointer(child: _RoomBackdrop())),
          SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      _SideRail(onOpen: _open),
                      const Expanded(child: _Felt()),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // The store, as the same Shop key the lobby's top bar carries and in
          // the same place — the top-left corner, clear of the felt (owner,
          // 13 Sep 2026; it replaces the gold `+` that headed the rail). It
          // opens the same store, on its Chips shelf; its picture key sells
          // the animated shelf alone here, bought with diamonds and worn on
          // the seat at once.
          const TopCorner(left: true, child: ShopButton()),
          // Diamonds and hammers, in the corner opposite the Shop key and on
          // its line (owner, 13 Sep 2026): what the player can still spend at
          // this table that is not chips. In the room rather than on the felt,
          // like the Shop key, and outside every seat's column (TableWallet).
          const TopCorner(left: false, child: TableWallet()),
          // The keys, floating over the bottom-right of the table instead of
          // sitting in a bar across the foot of it. Owner's decision,
          // 10 Sep 2026: the bar was a sixth of a landscape screen reserved
          // for six controls, and the table wanted the room.
          const Positioned(
            right: 0,
            bottom: 0,
            child: SafeArea(child: WhileOnline(child: _ActionCluster())),
          ),
          // Pack sits in the opposite corner from everything else, which is
          // the point: folding is the one action you never want under a thumb
          // reaching for Chaal. The Missile key stands on it (owner, 14 Sep
          // 2026) — the other move that is pressed once and ends the hand,
          // kept away from the keys pressed every turn.
          const Positioned(
            left: 0,
            bottom: 0,
            child: SafeArea(
              child: WhileOnline(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [_MissileKey(), _PackKey()],
                ),
              ),
            ),
          ),
          const Positioned.fill(child: SafeArea(child: Reconnecting())),
        ],
      ),
    );
  }
}

/// What drifts across the room behind the felt: the chips, while the table
/// shows no picture, and nothing once it does — the picture the table shows
/// ([_TableCentrepiece]) is its background then (owner, 15 Sep 2026: "remove
/// the flowing coins, we have applied the one we bought"). The table shows
/// the server's pick among everyone seated, so the chips come back when the
/// last player with a picture takes it off or leaves.
///
/// `select`, as [RoomGround] does: the screen's own build watches nothing,
/// and this rebuilds only when the table's picture comes or goes.
class _RoomBackdrop extends StatelessWidget {
  const _RoomBackdrop();

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final (url, format) = context.select<GameState, (String?, String?)>(
      (s) => (s.tablePictureUrl(brightness), s.shownTablePicture?.assetFormat),
    );
    return _ChipsUntilDrawable(url: url, format: format);
  }
}

/// The drifting chips until — and unless — the table's picture can actually
/// be drawn (23 Sep 2026): on the server's word alone the room went bare the
/// moment a picture was laid, and a file the phone could not fetch just then
/// (offline for a moment, a host answering with a page, a RIVE row no runtime
/// draws) left the felt empty for the whole sitting. The chips now stay until
/// the file for this theme is in hand, and come back if it never is; a failed
/// fetch is tried again on [pictureRetryDelay]'s clock, through the same
/// cache [CachedPictureBox] reads, so the two agree.
class _ChipsUntilDrawable extends StatefulWidget {
  const _ChipsUntilDrawable({required this.url, required this.format});

  /// The file the felt wants for this theme, or null for the table as it comes.
  final String? url;
  final String? format;

  @override
  State<_ChipsUntilDrawable> createState() => _ChipsUntilDrawableState();
}

class _ChipsUntilDrawableState extends State<_ChipsUntilDrawable> {
  /// The url whose bytes are in hand, when it is the one wanted.
  String? _drawable;
  Timer? _retry;
  int _failures = 0;

  @override
  void initState() {
    super.initState();
    _check(sync: true);
  }

  @override
  void didUpdateWidget(covariant _ChipsUntilDrawable old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.format != widget.format) {
      _retry?.cancel();
      _failures = 0;
      _check(sync: true);
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  /// Settles [_drawable] for the url wanted now. [sync] is true from a
  /// lifecycle method, where the field is set straight (build follows anyway);
  /// a late answer sets state.
  void _check({bool sync = false}) {
    final url = widget.url;
    if (url == null || widget.format == 'RIVE') return;
    if (PictureCache.peek(url) != null) {
      if (sync) {
        _drawable = url;
      } else if (_drawable != url) {
        setState(() => _drawable = url);
      }
      return;
    }
    PictureCache.load(url).then((bytes) {
      if (!mounted || url != widget.url) return;
      if (bytes == null) {
        _retry = Timer(pictureRetryDelay(_failures++), () {
          if (mounted && url == widget.url) _check();
        });
        return;
      }
      _failures = 0;
      setState(() => _drawable = url);
    });
  }

  @override
  Widget build(BuildContext context) {
    final shown = widget.url != null && _drawable == widget.url;
    return shown
        ? const SizedBox.shrink()
        : const DriftingChips(strength: TableAmbient.roomChips);
  }
}

/// The picture the table shows — the server's pick among the pictures its
/// players have laid, the same for everyone at it — as a square centred on
/// the pot (owner, 15 Sep 2026: "at the centre of the pot, small, square"):
/// the day file on the light theme, the night file on the dark, fading out
/// towards its rim, and nothing when the table shows none. The pot's plinth
/// paints over its middle.
///
/// `select`, as [RoomGround] does, so the felt's per-move rebuilds never
/// rebuild the picture: only the shown pair or the theme does.
class _TableCentrepiece extends StatelessWidget {
  const _TableCentrepiece({required this.side});

  /// The square's side, from the felt's own box.
  final double side;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final (url, format) = context.select<GameState, (String?, String?)>(
      (s) => (s.tablePictureUrl(brightness), s.shownTablePicture?.assetFormat),
    );
    if (url == null) return SizedBox(width: side, height: side);
    return SizedBox(
      width: side,
      height: side,
      child: RepaintBoundary(
        child: TablePictureGround(url: url, format: format),
      ),
    );
  }
}

/// Force Sideshow, from the key to the server (owner, 13 Sep 2026).
///
/// Asked first: a hammer is bought with real money, and a forced sideshow can
/// pack the player who forced it. A player with no hammers is not asked that —
/// they are offered the store's Hammers shelf instead, which is the only
/// answer that helps. The server has the last word on both, and when its count
/// turns out to be 0 after all the same offer follows.
Future<void> _forceSideshow(BuildContext context, GameState state) async {
  final t = state.t;
  if (!state.hasHammer) {
    await _offerHammers(context, state);
    return;
  }

  final name = state.options?.sideshowWith ?? '';
  // Worth asking only while this turn can still force a sideshow on this same
  // neighbour. The turn clock keeps running under the question: it used to
  // stay up after the turn timed out and on into the next hand, still naming a
  // player it might no longer reach, and a late Force closed it with nothing
  // sent and nothing said (QA 14 Sep 2026).
  bool stillOpen(GameState s) =>
      s.canForceSideshow && (s.options?.sideshowWith ?? '') == name;
  final go = await showTableDialog<bool>(
    context: context,
    builder: (context) => _WhileStillOpen(
      open: stillOpen,
      child: GlassDialog(
        padding: const EdgeInsets.all(Space.xl),
        title: dialogTitle(context, Icons.hardware, t.forceSideshowTitle),
        content: dialogBody(
          context,
          t.forceSideshowBody(name),
          note: t.forceSideshowNote,
        ),
        actions: dialogActions(context, stay: t.cancel, go: t.force),
      ),
    ),
  );
  if (!context.mounted) return;
  // Closed because the move went, or confirmed a moment after it did: nothing
  // is sent, so no hammer is spent — and the player is told so rather than
  // left wondering why Force did nothing. A Cancel is not answered.
  if (!stillOpen(state)) {
    if (go != false) state.say(t.forceSideshowTooLate);
    return;
  }
  if (go != true) return;
  final result = await state.forceSideshow();
  if (result == ForceSideshowResult.noHammers && context.mounted) {
    await _offerHammers(context, state);
  }
}

/// Keeps a dialog up only while [open] holds, and closes it the frame it stops
/// holding — for a question about a move the table can take away while it is
/// on screen.
class _WhileStillOpen extends StatefulWidget {
  const _WhileStillOpen({required this.open, required this.child});

  final bool Function(GameState) open;
  final Widget child;

  @override
  State<_WhileStillOpen> createState() => _WhileStillOpenState();
}

class _WhileStillOpenState extends State<_WhileStillOpen> {
  bool _closing = false;

  @override
  Widget build(BuildContext context) {
    final open = context.select<GameState, bool>(widget.open);
    if (!open && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Only while this dialog is still the one on top. A dialog already on
        // its way out — Fire or Cancel tapped a moment before the move was
        // taken away, which is exactly what firing does, since the answer
        // ends the hand — has left the navigator's history but is still
        // mounted for its exit animation, and a pop from here would take the
        // screen underneath with it: the table went black on the phone that
        // fired a missile (14 Sep 2026).
        if (ModalRoute.of(context)?.isCurrent ?? false) {
          Navigator.of(context).pop();
        }
      });
    }
    return widget.child;
  }
}

/// The store's Hammers shelf, offered to a player whose wallet is empty.
Future<void> _offerHammers(BuildContext context, GameState state) async {
  final t = state.t;
  final shop = await showTableDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: dialogTitle(context, Icons.hardware, t.noHammersTitle),
      content: dialogBody(context, t.noHammersBody),
      actions: dialogActions(context, stay: t.cancel, go: t.getHammers),
    ),
  );
  if (shop != true || !context.mounted) return;
  await showChipStore(context, opensOn: StoreTab.hammers);
}

/// A missile, from the key to the server (owner, 14 Sep 2026).
///
/// Asked first: a missile ends the hand for everyone still in it, and a tie
/// goes against the player who fired. A player with no missiles is not asked
/// that — they are offered the store's Missiles shelf instead. The server has
/// the last word on both, and when its count turns out to be 0 after all the
/// same offer follows.
Future<void> _fireMissile(BuildContext context, GameState state) async {
  final t = state.t;
  if (!state.hasMissile) {
    await _offerMissiles(context, state);
    return;
  }

  // Worth asking only while the turn can still fire it: the turn clock keeps
  // running under the question, as it does under Force Sideshow's.
  bool stillOpen(GameState s) => s.canMissile;
  final go = await showTableDialog<bool>(
    context: context,
    builder: (context) => _WhileStillOpen(
      open: stillOpen,
      child: GlassDialog(
        padding: const EdgeInsets.all(Space.xl),
        title: dialogTitle(context, missileIcon, t.fireMissileTitle),
        content: dialogBody(
          context,
          t.fireMissileBody,
          note: t.fireMissileNote,
        ),
        actions: dialogActions(context, stay: t.cancel, go: t.fire),
      ),
    ),
  );
  if (!context.mounted) return;
  // Closed because the turn went, or confirmed a moment after it did: nothing
  // is sent and nothing is spent, and the player is told so. A Cancel is not
  // answered.
  if (!stillOpen(state)) {
    if (go != false) state.say(t.missileTooLate);
    return;
  }
  if (go != true) return;
  final result = await state.fireMissile();
  if (result == MissileResult.noMissiles && context.mounted) {
    await _offerMissiles(context, state);
  }
}

/// The store's Missiles shelf, offered to a player whose wallet is empty.
Future<void> _offerMissiles(BuildContext context, GameState state) async {
  final t = state.t;
  final shop = await showTableDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: dialogTitle(context, missileIcon, t.noMissilesTitle),
      content: dialogBody(context, t.noMissilesBody),
      actions: dialogActions(context, stay: t.cancel, go: t.getMissiles),
    ),
  );
  if (shop != true || !context.mounted) return;
  await showChipStore(context, opensOn: StoreTab.missiles);
}

class _Felt extends StatefulWidget {
  const _Felt();

  /// Where each seat sits on the felt: the [SeatRing] for this table's number
  /// of places, laid round the casino table the felt is drawing (owner's
  /// table polish brief, 25 Sep 2026: "a responsive seat-positioning system
  /// based on the table bounds"). A pure function of the seat count, the
  /// table and the pod's width — never of who is sitting where, so a player
  /// joining or leaving moves nobody.
  ///
  /// What the places have to clear is recorded on [SeatRing]; what they were
  /// tuned against before there was a ring, and still hold to, is: the upper
  /// pair's "In Pot" lines and the viewer's reversed status line running
  /// together when the two columns stood 0.075 of the width apart (widened on
  /// 10 Sep 2026); the viewer's hand, fanned to the right of their pod,
  /// running under the key cluster when the viewer stood at 0.375; and a
  /// column hung by its MIDDLE growing both ways, so the height it has to
  /// clear is the tallest state it can reach (a revealed hand), not the common
  /// one.
  static SeatRing _ring(GameState state, Size screen, double w, double h) =>
      SeatRing.forFelt(
        seats: state.config.maxPlayers,
        screen: screen,
        felt: Size(w, h),
      );

  /// Where the middle of the pot is, as a fraction of the felt's height.
  ///
  /// One number, read by the plinth, by the chips flying into it and by the
  /// pot leaving for the winner. They used to be three different numbers —
  /// 0.30, 0.26 and 0.26 — so a bet landed a little above the pile it was
  /// joining.
  /// The pot sits in the middle of the cloth, which is where a pot is.
  ///
  /// It used to ride high at 0.27, above the middle, leaving the centre of the
  /// table empty during a hand — the one place every player is already looking.
  static const double _potDy = 0.46;

  /// The waiting / starting line takes the perch the pot gave up. It only ever
  /// speaks when no hand is running, so it can have the high ground: on the
  /// cloth, just inside the casino table's far rail (which ends at 0.274 of
  /// the height on a phone). At 0.28 it straddled the rail's inner edge;
  /// since 25 Sep 2026 the one-line waiting line stands 14–16dp inside it and
  /// the two-line notices that share its slot (who is choosing a variation or
  /// their cards, which variation was chosen) clear it too, at every phone
  /// size and text scale, and still stand 15dp or more above the pot
  /// (test/casino_table_test.dart).
  static const double _statusDy = 0.325;

  /// Where the middle of the category tag is, as a fraction of the felt's
  /// height. A name rather than a literal because the table's notices stand
  /// under it too ([tableNoticeArea]).
  static const double _tagDy = 0.075;

  /// Where a seat sits on the felt, given its index as the server numbers it.
  ///
  /// The table is drawn from the viewer's chair, so a server index has to be
  /// rotated into view order first — the viewer is always view seat 0, at the
  /// bottom, and that one stands on the floor rather than being centred.
  static Offset _seatCentre(
    GameState state,
    Size screen,
    int seatIndex,
    double w,
    double h,
    double podW,
  ) {
    final total = state.config.maxPlayers == 0 ? 5 : state.config.maxPlayers;
    final mine = state.room?.you?.seatIndex ?? 0;
    final view = (seatIndex - mine + total * 2) % total;
    return _ring(state, screen, w, h).centreOf(view, floorY: h * 0.84);
  }

  @override
  State<_Felt> createState() => _FeltState();
}

/// The felt's state: a Force Sideshow's hammer, a missile volley, and where
/// the pods they fly between actually stand.
class _FeltState extends State<_Felt> with TickerProviderStateMixin {
  static const _potDy = _Felt._potDy;
  static const _statusDy = _Felt._statusDy;
  static const _tagDy = _Felt._tagDy;
  Offset _seatCentre(
    GameState state,
    int seatIndex,
    double w,
    double h,
    double podW,
  ) => _Felt._seatCentre(
    state,
    MediaQuery.sizeOf(context),
    seatIndex,
    w,
    h,
    podW,
  );

  /// One key per place, naming that place's pod. A column's middle is known
  /// from the [SeatRing], but where the pod sits in it depends on everything
  /// under it — cards, a hand name, a bet — so the hammer is aimed at the pod
  /// as it was actually laid out, not at a guess.
  final List<GlobalKey> _podKeys = List.generate(
    SeatRing.maxSeats,
    (i) => GlobalKey(debugLabel: 'pod $i'),
  );

  /// The felt's Stack, which the pods are measured against and the hammer is
  /// drawn in.
  final GlobalKey _stageKey = GlobalKey(debugLabel: 'felt');

  /// The strike's clock, 0 to 1 over [HammerTiming.total]. Created by the
  /// first strike, never in advance and never by [dispose] (CLAUDE.md §12.3).
  AnimationController? _hammer;

  /// The strike being followed, by [HammerStrike.key].
  String? _strikeKey;

  /// Where the current hammer flies from and to, once the pods have been
  /// measured; null when there is nothing in the air.
  ({Rect from, Rect to, int targetView})? _flight;

  /// A missile volley's clock, 0 to 1 over [MissileTiming.total]. Created by
  /// the first volley, never in advance and never by [dispose].
  AnimationController? _missile;

  /// The volley being followed, by [MissileStrike.key].
  String? _volleyKey;

  /// Where the current volley flies from and to, once the pods have been
  /// measured; null when there is nothing in the air.
  ({Rect from, List<({Rect rect, int index})> targets, int count})? _volley;

  /// Each pod the volley hits, by view index, with its jolt's clock.
  Map<int, Animation<double>> _volleyJolts = const {};

  /// When the missile aimed at the viewer lands, as a share of the volley's
  /// clock; null when none is, or once its buzz has gone.
  double? _buzzAt;

  @override
  void initState() {
    super.initState();
    // Parsed while the table opens, so the first hammer or missile is not the
    // thing that waits for it.
    unawaited(HammerArt.load());
    unawaited(MissileArt.load());
  }

  @override
  void dispose() {
    _hammer?.dispose();
    _missile?.dispose();
    super.dispose();
  }

  /// Keeps the felt on the volley [GameState] is showing, as [_follow] does
  /// for the hammer.
  void _followMissile(MissileStrike? strike) {
    if (strike?.key == _volleyKey) return;
    _volleyKey = strike?.key;
    _volley = null;
    _volleyJolts = const {};
    _buzzAt = null;
    _missile?.stop();
    if (strike == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _launchVolley(strike));
  }

  void _launchVolley(MissileStrike strike) {
    if (!mounted || strike.key != _volleyKey) return;
    final total = MissileTiming.total(strike.count);
    // The volley's timers began when the event arrived; the frames start where
    // those timers already are, so the cards turn over as the last one lands.
    final start =
        DateTime.now().difference(strike.startedAt).inMicroseconds /
        total.inMicroseconds;
    if (start >= 1) return;
    final stage = _stageKey.currentContext?.findRenderObject();
    if (stage is! RenderBox || !stage.hasSize) return;

    final state = context.read<GameState>();
    final seats = state.seatsInViewOrder();
    int viewOf(String userId) =>
        seats.indexWhere((seat) => seat?.userId == userId);
    Rect? podAt(int view) {
      if (view < 0 || view >= _podKeys.length) return null;
      final box = _podKeys[view].currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return null;
      return box.localToGlobal(Offset.zero, ancestor: stage) & box.size;
    }

    final from = podAt(viewOf(strike.fromUserId));
    // The firer already gone from the felt: nothing to fire from. The reveal
    // still waits for the last impact on GameState's timers.
    if (from == null) return;
    final targets = <({Rect rect, int index})>[];
    final views = <int, int>{};
    for (final (index, userId) in strike.targetUserIds.indexed) {
      final view = viewOf(userId);
      final rect = podAt(view);
      if (rect == null) continue;
      targets.add((rect: rect, index: index));
      views[view] = index;
    }
    if (targets.isEmpty) return;

    final clock = _missile ??= AnimationController(vsync: this)
      ..addListener(_buzzIfHit);
    clock.duration = total;
    final mine = strike.indexOf(state.user?.id);
    final buzzAt = mine < 0
        ? null
        : MissileTiming.share(MissileTiming.impact(mine), strike.count);
    setState(() {
      _volley = (from: from, targets: targets, count: strike.count);
      _volleyJolts = {
        for (final MapEntry(key: view, value: index) in views.entries)
          view: MissileImpactClock(
            parent: clock,
            index: index,
            count: strike.count,
          ),
      };
      // A volley joined after the viewer was already hit does not buzz late.
      _buzzAt = buzzAt != null && buzzAt > start ? buzzAt : null;
    });
    clock.forward(from: start.clamp(0.0, 1.0));
  }

  /// A light buzz as the missile aimed at the viewer lands, gated on the
  /// player's Vibration switch like every other haptic in the game.
  void _buzzIfHit() {
    final at = _buzzAt;
    final clock = _missile;
    if (at == null || clock == null || clock.value < at) return;
    _buzzAt = null;
    if (mounted) tapHaptic(context);
  }

  /// Keeps the felt on the strike [GameState] is showing: a new one is launched
  /// after this frame, when the pods have been laid out and can be measured;
  /// one that has gone (the hand ended, the player left) is dropped at once.
  void _follow(HammerStrike? strike) {
    if (strike?.key == _strikeKey) return;
    _strikeKey = strike?.key;
    _flight = null;
    // Stopped, not reset: resetting would notify the hit pod's jolt in the
    // middle of this build. With no flight nothing listens to it any more.
    _hammer?.stop();
    if (strike == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _launch(strike));
  }

  void _launch(HammerStrike strike) {
    if (!mounted || strike.key != _strikeKey) return;
    // The strike's timers began when the event arrived; the frames start where
    // those timers already are, so the cards turn over as the hammer lands.
    final start = HammerTiming.share(
      DateTime.now().difference(strike.startedAt),
    );
    if (start >= 1) return;
    final stage = _stageKey.currentContext?.findRenderObject();
    if (stage is! RenderBox || !stage.hasSize) return;

    final seats = context.read<GameState>().seatsInViewOrder();
    int viewOf(String userId) =>
        seats.indexWhere((seat) => seat?.userId == userId);
    Rect? podAt(int view) {
      if (view < 0 || view >= _podKeys.length) return null;
      final box = _podKeys[view].currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) return null;
      return box.localToGlobal(Offset.zero, ancestor: stage) & box.size;
    }

    final targetView = viewOf(strike.toUserId);
    final from = podAt(viewOf(strike.fromUserId));
    final to = podAt(targetView);
    // Either player already gone from the felt: nothing to throw between. The
    // reveal and the fold still wait for the impact on GameState's timers.
    if (from == null || to == null) return;

    final clock = _hammer ??= AnimationController(
      vsync: this,
      duration: HammerTiming.total,
    );
    setState(() => _flight = (from: from, to: to, targetView: targetView));
    clock.forward(from: start.clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    _follow(state.hammerStrike);
    _followMissile(state.missileStrike);

    final room = state.room;
    if (room == null) return const Center(child: CircularProgressIndicator());

    final seats = state.seatsInViewOrder();
    // The viewer's own showdown reveal, if the hand got that far.
    final myReveal = state.showdown
        .where((r) => r.userId == state.user?.id)
        .firstOrNull;
    // A sideshow names the hand that won it and nothing else. Both hands still
    // turn over where they sit, but a ranking over the loser's read as if that
    // were the result. The reveal itself says who was packed, so the label is
    // right from the first frame rather than after the snapshot that packs them.
    // A Force Sideshow's hands stay face down until its hammer has landed.
    final sideshow = state.shownSideshowReveal;
    bool wonSideshow(String? userId) =>
        userId != null &&
        sideshow?.packedUserId != null &&
        sideshow!.packedUserId != userId;
    final myPeek = sideshow?.hands
        .where((h) => h.userId == state.user?.id)
        .firstOrNull;
    // On a variation table the hand is named as soon as it CAN be — the player
    // has looked and the variation is chosen (`you.hand`) — because with wild
    // cards in it the name is not something three faces tell you. Held back
    // until the wild cards have turned, so the name arrives as the answer to
    // what the player has just watched.
    final liveHandName = room.you?.hand?.handName;
    final ownHandName =
        myReveal?.handName ??
        (wonSideshow(myPeek?.userId) ? myPeek?.handName : null) ??
        (liveHandName == null || liveHandName.isEmpty ? null : liveHandName);
    final ownHandNameIsLive =
        myReveal == null && !wonSideshow(myPeek?.userId) && ownHandName != null;
    final turnSeat = room.turn?.seatIndex;
    final progress = state.turnProgress;
    final pad = Dim.feltPad(MediaQuery.sizeOf(context).width);

    bool onTurn(Seat? s) =>
        s != null &&
        room.state == TableState.betting &&
        s.seatIndex == turnSeat;

    // Which seat took the pot, if they are still sitting there.
    int? winnerSeat;
    for (final seat in room.seats) {
      if (state.winnerId != null && seat.userId == state.winnerId) {
        winnerSeat = seat.seatIndex;
      }
    }

    // A hand is on the table until the celebration for it has finished, not
    // just until the server stops dealing — the seats keep their bets and
    // statuses through the winner's moment, and drop them with it.
    // A missile volley keeps it on the table too: the server has settled the
    // hand before the missiles land, and the bets and seats stay up until they
    // have.
    final handLive =
        room.state == TableState.betting ||
        room.state == TableState.showdown ||
        state.missileStrike != null ||
        state.showdown.isNotEmpty ||
        state.showdownResult.isNotEmpty;
    // The pot as the felt shows it: the one the missile was fired over until
    // the missiles have landed.
    final pot = state.heldPot ?? room.pot;

    return Padding(
      padding: EdgeInsets.fromLTRB(pad, Space.xxs, pad, 0),
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final h = box.maxHeight;

          // Everything on the table is a multiple of the pod width, which is
          // itself taken from the felt's own box rather than the screen's. The
          // screen this runs on is short and wide in logical pixels, so nothing
          // here may be a fixed size, and the width matters as much as the
          // height: the seats sit at fixed fractions across the felt, so a pod
          // sized purely off the height grows until neighbours collide and the
          // outer ones hang over the rim.
          final podW = Dim.podW(w, h);
          final handH = Dim.handH(h);

          // The table (owner's brief, 24 Sep 2026: "a large oval/rounded
          // casino table surface behind the gameplay elements"), laid out from
          // the LayoutBuilder's box, and the seats round it: the ring for this
          // table's number of places (SeatRing), from the same box.
          final table = TableGeometry.of(Size(w, h));
          final ring = _Felt._ring(state, MediaQuery.sizeOf(context), w, h);
          final me = ring.spots.first;

          Widget pod(SeatSpot spot) {
            final viewIndex = spot.view;
            final angle = spot.angle;
            final seated = viewIndex < seats.length ? seats[viewIndex] : null;
            // A Force Sideshow's loser has already been packed by the server
            // when the hammer sets off; their pod folds when it lands. A
            // missile's winner and losers are already settled when the volley
            // sets off; their pods say so when the last one lands.
            final s = state.seatAsShown(seated);
            // At a showdown the hand is drawn at the seat that played it, so
            // find this seat's reveal and hand it down. The server sends
            // reveals for the players still in the hand; everyone else keeps
            // their backs.
            final reveal = s == null
                ? null
                : state.showdown.where((r) => r.userId == s.userId).firstOrNull;
            // A sideshow turns the two hands face up where they are sitting,
            // exactly as a showdown does, instead of lifting them into a panel
            // over the middle of the table.
            //
            // Nothing here enforces the privacy of that: the server sends
            // `game:sideshowReveal` to those two sockets and nobody else
            // (CLAUDE.md §7.1), so on every other player's device
            // state.sideshowReveal is null and this resolves to backs. The
            // client could not leak a card it was never sent.
            final peek = s == null || reveal != null
                ? null
                : sideshow?.hands
                      .where((hand) => hand.userId == s.userId)
                      .firstOrNull;

            // While a variation window is open nobody is on turn, and the
            // one player the table is waiting for is the chooser: their pod
            // rings and fills against the window's clock, as a pod on turn
            // does against the turn's.
            final choosing =
                s != null &&
                room.state == TableState.betting &&
                state.variationSelecting &&
                s.userId == state.variation!.userId;

            return SeatPod(
              revealed: reveal?.cards ?? peek?.cards,
              // Which of those cards played as wild ones (a variation table),
              // and the hand as it was counted with them.
              wild: reveal?.wild ?? peek?.wild ?? const [],
              playsAs: reveal?.playsAs ?? peek?.playsAs ?? const [],
              // Which three of five were counted (5-Card only).
              best: reveal?.best ?? peek?.best ?? const [],
              revealedHand:
                  reveal?.handName ??
                  (wonSideshow(peek?.userId) ? peek?.handName : null),
              seat: s,
              // The orb leaks towards open felt: inwards from a seat at either
              // end of the table, outwards off the top edge from the seats
              // between. The viewer's stays inside their glass — the
              // missed-turns plate and their own cards leave it nowhere to go
              // (on TP_Small it lay under the plate).
              orbCorner: viewIndex == 0
                  ? OrbCorner.contained
                  : angle < 210
                  ? OrbCorner.topRight
                  : angle <= 270
                  ? OrbCorner.topLeft
                  : angle <= 330
                  ? OrbCorner.topRight
                  : OrbCorner.topLeft,
              isMe: s?.userId != null && s!.userId == state.user?.id,
              isDealer: s?.seatIndex == room.dealerSeat,
              onTurn: onTurn(s) || choosing,
              progress: choosing
                  ? state.variationProgress
                  : onTurn(s)
                  ? progress
                  : null,
              deadlineMs: choosing
                  ? state.variation!.deadline
                  : room.turn?.deadline ?? 0,
              totalMs: choosing
                  ? state.variation!.timeoutMs
                  : room.turnTimeoutMs,
              chipsHidden: room.chipsHidden,
              handLive: handLive,
              width: podW,
              avatarUrl: state.absoluteUrl(s?.avatarUrl),
              saying: s?.userId == null
                  ? null
                  : state.saidRecently[s!.userId]?.text,
              // A bubble opens towards the middle of the table: seats on the
              // left speak to the right, seats on the right to the left, and
              // the viewer's own words go up over their pod. The head seat's
              // opens over its own cards, to its right.
              bubbleSide: viewIndex == 0
                  ? BubbleSide.above
                  : angle <= 270
                  ? BubbleSide.right
                  : BubbleSide.left,
              // The bottom seat stacks upwards, or its chip runs off the felt.
              reversed: viewIndex == 0,
              // The head seat lays its cards and bet beside its pod, so the
              // pot keeps the middle of the table (SeatSpot.head).
              beside: spot.head,
              podKey: viewIndex < _podKeys.length ? _podKeys[viewIndex] : null,
              impact: _flight?.targetView == viewIndex
                  ? _hammer
                  : _volleyJolts[viewIndex],
            );
          }

          // Positioned by centre, so a seat stays put as its own column grows
          // and shrinks with the hand — but never past either edge, which is
          // what clipped the outermost seat on a narrow screen.
          Widget atPoint(Offset point, Widget child, {double? width}) {
            final box = width ?? podW;
            final left = (point.dx - box / 2)
                .clamp(0.0, math.max(0.0, w - box))
                .toDouble();

            return Positioned(
              left: left,
              top: point.dy,
              width: box,
              child: FractionalTranslation(
                translation: const Offset(0, -0.5),
                child: child,
              ),
            );
          }

          Widget at(Offset place, Widget child, {double? width}) =>
              atPoint(Offset(place.dx * w, place.dy * h), child, width: width);

          final potCentre = Offset(0.5 * w, _potDy * h);
          Offset seatCentre(int seatIndex) =>
              _seatCentre(state, seatIndex, w, h, podW);

          // The category tag over the far rail, or beside the head seat's pod
          // when a two- or four-place table seats somebody at the head.
          final tagSlot = ring.tagSlot(width: w * 0.30, centreY: _tagDy * h);
          // The waiting line under it, and under a head seat's pod when there
          // is one: its two-line notices (who is choosing) need the room.
          final headPod = ring.headPod;
          final statusY = headPod == null
              ? _statusDy * h
              : math.max(_statusDy * h, headPod.bottom + Space.sm + 20);

          return Stack(
            key: _stageKey,
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CasinoTableSurface(
                  geometry: table,
                  // The game's own cloth: gold for seen, blue for blind,
                  // violet for variation (25 Sep 2026).
                  category: room.category,
                  // A short phone keeps the table and loses its trimmings.
                  detailed: !Breaks.isShort(MediaQuery.sizeOf(context).height),
                ),
              ),
              // The overhead lamp breathing on the cloth, and the near rail
              // warming on the viewer's turn. Its own layer: it repaints every
              // frame for the life of the room, and the table beneath it
              // never does.
              Positioned.fill(
                child: TableAmbientEffects(
                  geometry: table,
                  yourTurn: state.myTurn && room.state == TableState.betting,
                  viewerX: me.anchor.dx + podW * 0.7,
                ),
              ),
              // Every bet is seen to travel: a chip leaves the seat that made
              // it and lands on the pot. Boundaried for the same reason.
              // The deal, drawn before the bets so a boot chip lands on a
              // seat that has already been given its cards.
              Positioned.fill(
                child: RepaintBoundary(
                  child: IgnorePointer(
                    child: DealFlights(
                      seats: room.seats,
                      roomId: room.roomId,
                      handNo: room.handNo,
                      centreOf: seatCentre,
                      deck: Offset(w / 2, h * 0.42),
                      cardHeight: (podW * 0.42).clamp(18.0, 46.0),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: RepaintBoundary(
                  child: IgnorePointer(
                    child: _BetFlights(
                      seats: room.seats,
                      handNo: room.handNo,
                      centreOf: seatCentre,
                      pot: potCentre,
                      size: (podW * 0.22).clamp(14.0, 26.0),
                    ),
                  ),
                ),
              ),
              // The table picture the player has laid: a square under the
              // pot, centred where the pot is, fading out towards its rim so
              // it reads as part of the ground (owner, 15 Sep 2026). Under the
              // tag and the plinth, over the flights, and sized off the felt's
              // short side; the fade is what lets it reach towards the seats
              // above without an edge arriving there.
              at(
                const Offset(0.5, _potDy),
                IgnorePointer(
                  child: _TableCentrepiece(side: math.min(w * 0.37, h * 0.53)),
                ),
                width: math.min(w * 0.37, h * 0.53),
              ),
              // The table's furniture first, the seats after it: a seat's
              // speech bubble or bet chip is a moment that matters more
              // than the tag or the pot label it might briefly cross, so
              // the seats paint on top.
              Positioned(
                left: tagSlot.left,
                top: tagSlot.center.dy,
                width: tagSlot.width,
                child: FractionalTranslation(
                  translation: const Offset(0, -0.5),
                  child: _CategoryTag(room: room),
                ),
              ),
              // Narrower than the tag above it, and narrower again since the
              // cloth went: with no table under it the plinth is the largest
              // solid object on the screen, and at a third of the felt it was
              // reading as the subject rather than as the score.
              at(
                const Offset(0.5, _potDy),
                _PotPulse(
                  pot: pot,
                  child: _Pot(
                    room: room,
                    pot: pot,
                    chipSize: (podW * 0.17).clamp(12.0, 20.0),
                  ),
                ),
                width: w * 0.20,
              ),
              atPoint(
                Offset(0.5 * w, statusY),
                _Status(room: room),
                // Narrower than it looks like it needs to be: at this height
                // the line sits between the two top seats, whose pods paint
                // over it, so a long line (the buy-chips countdown) has to
                // shrink into the gap instead of running under them.
                width: w * 0.28,
              ),

              // Every place round the rim, each column hung by its middle from
              // the ring — and the head seat, if the table has one, by the top
              // of its pod, its cards and bet beside it.
              for (final spot in ring.rim)
                if (spot.head)
                  Positioned(
                    left: ring.headLeft,
                    top: spot.anchor.dy,
                    width: ring.headUnitWidth,
                    // Loose inside the unit, so an empty chair is a pod wide
                    // and stands where the pod would.
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: pod(spot),
                    ),
                  )
                else
                  atPoint(spot.anchor, pod(spot)),

              // The viewer's pod and hand stand on the floor of the table
              // rather than being centred on a point: their columns are
              // different heights, so centring both left one hanging over the
              // rim and clipped by it. A shared bottom line keeps them inside
              // and flush with the edge.
              Positioned(
                left: me.anchor.dx - podW / 2,
                bottom: h - me.anchor.dy,
                width: podW,
                child: pod(me),
              ),
              // The viewer's own badge and total ride over their cards rather
              // than under their pod: the pod stands on the floor, so a stack
              // beneath it would run off the screen, and the space above the
              // hand is where they are already looking.
              //
              // One column with the hand, rather than a second Positioned at a
              // computed offset, so the readout centres itself over whatever
              // width the cards happen to take — three cards, or two after a
              // sideshow — instead of being pinned to their left edge.
              Positioned(
                left: me.anchor.dx + podW / 2 + Space.md,
                // A step above the floor the viewer's pod stands on, towards
                // the middle of the table (owner's brief, 25 Sep 2026: "Move
                // the current player's cards slightly upward").
                bottom: h - me.anchor.dy + TableSpace.handLift,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The viewer's own hand name at a showdown, over their
                    // cards, so the seat that matters most to them is not the
                    // one seat that has to work out what it won with — and
                    // after a sideshow they won, which it names the same way.
                    if (ownHandName != null) ...[
                      if (ownHandNameIsLive)
                        // Keyed on the hand, so the one-second tick cannot
                        // restart the wait.
                        _AfterTheTurn(
                          key: ValueKey('own-hand-name-${room.handNo}'),
                          // Nothing turns in a hand with no wild card, so
                          // there is nothing to wait for but the flip.
                          turns: room.you?.hand?.wild.isNotEmpty ?? false,
                          child: _OwnHandName(name: ownHandName),
                        )
                      else
                        _OwnHandName(name: ownHandName),
                      const SizedBox(height: Space.xxs),
                    ],
                    if (seats.isNotEmpty && seats[0] != null && handLive) ...[
                      // Scaled against a wider pod than the viewer actually
                      // has: this is their own bet, read every turn from the
                      // far end of a landscape screen, and it earns a size the
                      // rim seats' copies do not.
                      SeatBet(
                        seat: state.seatAsShown(seats[0])!,
                        width: podW * 1.22,
                        totalFirst: true,
                      ),
                      const SizedBox(height: Space.xs),
                    ],
                    // The showdown's copy of their own hand, so a player who
                    // paid for a show while still blind sees what they were
                    // holding: the server withholds `you.cards` until they
                    // look, and it never turns that off.
                    _OwnHand(
                      cardHeight: HandFan.cardHeightFor(handH),
                      revealed: myReveal?.cards,
                      wild: myReveal?.wild ?? myPeek?.wild ?? const [],
                      playsAs: myReveal?.playsAs ?? myPeek?.playsAs ?? const [],
                      best: myReveal?.best ?? myPeek?.best ?? const [],
                    ),
                  ],
                ),
              ),

              // A sideshow in progress, drawn for everyone: a line pulsing
              // between the two seats, so the rest of the table can see who
              // asked whom without seeing a single card.
              if (state.sideshow != null)
                Positioned.fill(
                  child: RepaintBoundary(
                    child: IgnorePointer(
                      child: _SideshowLink(
                        from: _seatCentre(
                          state,
                          state.sideshow!.fromSeat,
                          w,
                          h,
                          podW,
                        ),
                        to: _seatCentre(
                          state,
                          state.sideshow!.toSeat,
                          w,
                          h,
                          podW,
                        ),
                      ),
                    ),
                  ),
                ),

              // A forced sideshow is shown to everyone at the table at least
              // the way an ordinary one is — the same link between the two
              // players, with its comet running from the one who forced it —
              // from the throw until the loser folds. A forced one never has a
              // pending request, so without this a bystander would get nothing
              // but the hammer itself.
              if (_flight != null && state.hammerLinkShown)
                Positioned.fill(
                  child: RepaintBoundary(
                    child: IgnorePointer(
                      child: _SideshowLink(
                        from: _flight!.from.center,
                        to: _flight!.to.center,
                      ),
                    ),
                  ),
                ),

              // A Force Sideshow's hammer, thrown from one pod to the other
              // over everything else on the felt — the viewer's own hand
              // included. Everyone at the table sees it; nobody sees a card
              // they were not sent (the two hands come from the reveal, which
              // only the two players get).
              if (_flight != null && _hammer != null)
                Positioned.fill(
                  child: HammerFlight(
                    clock: _hammer!,
                    from: _flight!.from,
                    target: _flight!.to,
                    podWidth: podW,
                  ),
                ),

              // A missile volley: one missile from the firer's pod to every
              // other pod still in the hand, over everything on the felt — the
              // viewer's own hand included. Everyone at the table sees it; the
              // cards come with the showdown, which waits for the last impact.
              if (_volley != null && _missile != null)
                Positioned.fill(
                  child: MissileFlight(
                    clock: _missile!,
                    count: _volley!.count,
                    from: _volley!.from,
                    targets: _volley!.targets,
                    podWidth: podW,
                  ),
                ),

              // Only the player being asked gets the buttons.
              if (state.sideshowIsForMe)
                Positioned.fill(child: _SideshowPrompt(state: state)),

              // A variation table's picker, for the one player choosing. In
              // the Stack rather than a dialog, so it is gone with the very
              // snapshot that says the window has closed and no route is left
              // behind to pop (see VariationPrompt).
              //
              // The scrim dims the felt only, takes no touch, and fades out
              // above the foot: the chooser may look at their cards first, so
              // their hand and its "See cards" key stay lit and live. The
              // picker itself keeps to the top 64% of the felt for the same
              // reason — the viewer's column (hand, badge and floor margin)
              // is 0.235h + about 40dp, under 0.36h at every height there is.
              if (state.variationIsMine) ...[
                const Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(gradient: TableScrim.picker),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: h * 0.64,
                  child: VariationPrompt(
                    // One picker per window, so a key marked in one hand is
                    // not still marked in the next.
                    key: ValueKey('variation-${room.handNo}'),
                    title: state.t.variationChooseTitle,
                    options: state.variation!.options,
                    nameOf: state.t.variationName,
                    noteOf: state.t.variationNote,
                    deadlineMs: state.variation!.deadline,
                    totalMs: state.variation!.timeoutMs,
                    onSelect: state.selectVariation,
                  ),
                ),
              ],

              // 5-Card Teen Patti: the player's own five, to choose three of
              // (owner, 19 Sep 2026). Only ever their own hand, and only while
              // the server says a choice is owed.
              if (state.pickingCards) ...[
                const Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(gradient: TableScrim.picker),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: h * 0.64,
                  child: CardPickPrompt(
                    // One picker per hand, so cards marked in one are not
                    // still marked in the next.
                    key: ValueKey('pick-${room.handNo}'),
                    title: state.t.pickTitle,
                    hint: state.t.pickHint,
                    confirm: state.t.pickConfirm,
                    chosenLabel: state.t.pickConfirm,
                    cards: room.you?.cards ?? const [],
                    selected: state.pickSelection,
                    deadlineMs: room.you?.hand?.pickDeadline ?? 0,
                    totalMs: room.you?.hand?.pickTimeoutMs ?? 0,
                    onToggle: state.togglePickCard,
                    onConfirm: state.selectCards,
                  ),
                ),
              ],

              // And the verdict, for a few seconds after the three are settled.
              if (state.pickAnnounced != null)
                Positioned(
                  left: 0,
                  right: 0,
                  top: h * 0.10,
                  child: IgnorePointer(
                    child: PickVerdict(
                      wasBest: state.pickAnnounced!.wasBest,
                      byTimeout: state.pickAnnounced!.byTimeout,
                      played: state.pickAnnounced!.played,
                      best: state.pickAnnounced!.best,
                      title: state.pickAnnounced!.wasBest
                          ? state.t.pickWasBest
                          : state.t.pickNotBest,
                      playedLabel: state.t.pickYouPlayed,
                      bestLabel: state.t.pickTheBest,
                      timedOutNote: state.t.pickTimedOut,
                    ),
                  ),
                ),

              if (state.showdown.isNotEmpty || state.showdownResult.isNotEmpty)
                Positioned.fill(
                  child: _Showdown(
                    // Fractions of the felt, so the bursts land over the
                    // player who won rather than across the whole room.
                    winnerAt: winnerSeat == null
                        ? null
                        : Offset(
                            _seatCentre(state, winnerSeat, w, h, podW).dx / w,
                            _seatCentre(state, winnerSeat, w, h, podW).dy / h,
                          ),
                    // The pot going where it was won.
                    potFlight: winnerSeat == null || state.winnerPot <= 0
                        ? null
                        : PotFlight(
                            key: ValueKey(
                              'pot-${room.handNo}-${state.winnerId}',
                            ),
                            from: potCentre,
                            to: _seatCentre(state, winnerSeat, w, h, podW),
                            size: podW * 0.28,
                          ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Where a notice may stand at the table, in screen coordinates: the open felt
/// between the seats nearest the head of the table, under the category tag
/// (and under the head seat's pod, when a seat has the head) and over the pot.
///
/// The foot of the screen is the viewer's own pod, hand and keys, and a band
/// 40% of the width over the pot ran across the top seats' card fans and their
/// SEEN labels, hiding who had looked. Every seat's column is exactly a pod
/// wide and placed by the [SeatRing], so the gap between the top pair is
/// worked out here from the ring [_Felt] lays them out with rather than
/// guessed as a share of the screen: about 214dp wide on a Pixel 7 Pro, 150 on
/// a 640dp phone and 370 on a tablet, at five places. Nothing is drawn there
/// during a hand; between hands the waiting line stands in it, and a notice
/// may cover that for the moment it shows.
Rect tableNoticeArea(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final safe = MediaQuery.paddingOf(context);
  final scaler = MediaQuery.textScalerOf(context);
  final theme = Theme.of(context);

  // The felt's box as TableScreen lays it out: inside the SafeArea, right of
  // the rail, inside the felt's own padding (_Felt.build).
  final pad = Dim.feltPad(size.width);
  final feltLeft = safe.left + Dim.railW(size.width) + pad;
  final feltTop = safe.top + Space.xxs;
  final w = size.width - safe.right - pad - feltLeft;
  final h = size.height - safe.bottom - feltTop;
  final podW = Dim.podW(w, h);
  final ring = SeatRing.forFelt(
    seats: context.read<GameState>().config.maxPlayers,
    screen: size,
    felt: Size(w, h),
  );

  // Between the columns nearest the head on either side — each a pod wide
  // and centred on its place, as _Felt lays them — or the felt's own sides
  // when no seat stands on that side of the head.
  var left = podW / 2;
  var right = w - podW / 2;
  for (final spot in ring.rim.where((s) => !s.head)) {
    final columnLeft = spot.anchor.dx - podW / 2;
    if (spot.angle < 270) {
      left = math.max(left, columnLeft + podW);
    } else {
      right = math.min(right, columnLeft);
    }
  }
  left += feltLeft + Space.md;
  right += feltLeft - Space.md;

  // The tag and the pot are each one line of type on a plate: the line, the
  // plate's padding above and below it, and its hairline.
  double plate(TextStyle style) =>
      scaler.scale(style.fontSize ?? 14) * (style.height ?? 1.3) +
      2 * Space.xs +
      2 * Dim.hairline;
  final headPod = ring.headPod;
  final top = math.max(
    feltTop + _Felt._tagDy * h + plate(TableType.boot(theme)) / 2 + Space.sm,
    headPod == null ? 0.0 : feltTop + headPod.bottom + Space.sm,
  );
  final bottom =
      feltTop + _Felt._potDy * h - plate(TableType.pot(theme)) / 2 - Space.sm;

  var area = Rect.fromLTRB(left, top, right, bottom);
  // A screen too cramped for the gap still gets a toast that reads, centred
  // where the gap is; a wide one never gets a wider toast than the lobby's.
  final minW = 120.0;
  final maxW = Dim.toastW(size.width);
  if (!area.isFinite) {
    area = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: minW,
      height: Dim.minTouch,
    );
  }
  return Rect.fromCenter(
    center: area.center,
    width: area.width.clamp(minW, maxW).toDouble(),
    height: math.max(area.height, Dim.minTouch),
  );
}

/// The cloth and the rail around it.
///
/// Dark emerald baize, woven with two faint diagonals, darkening towards the
/// rim, inside a champagne rail that is bright along its top-left run and deep
/// along its bottom-right one — which is what makes the edge read as a physical
/// lip rather than a stroked oval. It is entirely static, so it is painted once
/// into its own layer and reused for as long as the room is open; the lamp that
/// breathes over it is a separate layer above.
class _FeltCloth extends StatefulWidget {
  const _FeltCloth({
    required this.palette,
    required this.radius,
    required this.child,
  });

  final TablePalette palette;
  final double radius;
  final Widget child;

  @override
  State<_FeltCloth> createState() => _FeltClothState();
}

class _FeltClothState extends State<_FeltCloth>
    with SingleTickerProviderStateMixin {
  // Twenty-two seconds edge to edge. Slow enough that it is never the thing a
  // player is looking at, which is the whole point of ambient movement.
  late final AnimationController _sheen = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 22),
  )..repeat();

  @override
  void dispose() {
    _sheen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = widget.palette;
    final radius = widget.radius;
    final child = widget.child;
    final brightness = Theme.of(context).brightness;
    final cloth = AppTheme.feltColours(brightness, accent: palette.accent);
    final corner = BorderRadius.circular(radius);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corner,
        // The table is the one object in the room allowed to bloom in its own
        // colour, so a purple room and a gold one differ even at the floor.
        boxShadow: AppTheme.controlShadow(
          brightness,
          elevation: 7,
          bloom: palette.accent,
        ),
      ),
      child: ClipRRect(
        borderRadius: corner,
        child: Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _sheen,
                builder: (context, _) => CustomPaint(
                  isComplex: true,
                  willChange: true,
                  painter: _ClothPainter(
                    core: cloth.core,
                    mid: cloth.mid,
                    rim: cloth.rim,
                    rimHigh: palette.rimHigh,
                    rimLow: palette.rimLow,
                    accent: palette.accent,
                    tint: palette.tint,
                    radius: radius,
                    phase: _sheen.value,
                  ),
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

class _ClothPainter extends CustomPainter {
  const _ClothPainter({
    required this.core,
    required this.mid,
    required this.rim,
    required this.rimHigh,
    required this.rimLow,
    required this.accent,
    required this.tint,
    required this.radius,
    required this.phase,
  });

  final Color core;
  final Color mid;
  final Color rim;
  final Color rimHigh;
  final Color rimLow;
  final Color accent;
  final double tint;
  final double radius;

  /// 0..1 around a very slow loop. Drives one faint band of light drifting
  /// across the cloth — the only thing moving on an idle table, and kept under
  /// 4% opacity so it reads as a room with a lamp in it rather than an effect.
  final double phase;

  /// The rail's thickness. Three device-independent pixels of metal, whatever
  /// the table's corner radius does.
  static const double _rail = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // The cloth: lit a little above the middle, where the lamp hangs, and
    // falling away to almost black at the rim.
    //
    // The opacity is not one number but a fall — clear in the middle, dense at
    // the edge. A single low alpha across the whole surface was tried first and
    // it fails: the pale ground bleeds evenly through and the table stops being
    // furniture and becomes a tint. Real glass does not do that. A glass table
    // is a window in the middle and a bevelled, nearly solid edge at the rim,
    // and reproducing that fall is what lets the centre go properly clear —
    // chips crossing the room read straight through it — while the rim still
    // holds an object on the floor.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.15),
          radius: 0.86,
          colors: [
            core.withValues(alpha: 0.40),
            mid.withValues(alpha: 0.63),
            rim.withValues(alpha: 0.90),
          ],
          stops: const [0, 0.58, 1],
        ).createShader(rect),
    );

    // The pane itself: one broad specular fall from the top left, the way light
    // sits on glass rather than soaks into cloth. This is what stops the
    // clearing above reading as thin paint — without a highlight the eye has
    // nothing to tell it there is a surface there at all.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.10),
            Colors.white.withValues(alpha: 0.028),
            Colors.transparent,
          ],
          stops: const [0, 0.32, 0.62],
        ).createShader(rect),
    );

    // The table's identity, as a wash rather than a dye: at 0.10-0.14 it is
    // visible on the royal table and almost not on the gold one, which is the
    // right emphasis.
    canvas.drawRect(
      rect,
      Paint()..color = accent.withValues(alpha: tint * 0.34),
    );

    // Weave. Two diagonals, one lit and one shadowed, at an alpha where the
    // eye reads texture rather than stripes.
    for (final (Alignment begin, Alignment end, Color line) in [
      (Alignment.topLeft, Alignment.bottomRight, const Color(0x09FFFFFF)),
      (Alignment.topRight, Alignment.bottomLeft, const Color(0x0B000000)),
    ]) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = LinearGradient(
            begin: begin,
            end: end,
            colors: [line, line.withValues(alpha: 0), line],
            tileMode: TileMode.repeated,
          ).createShader(const Rect.fromLTWH(0, 0, 7, 7)),
      );
    }

    // The rail, lit from the top left and deepening to the bottom right.
    final corner = Radius.circular(radius);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(_rail / 2), corner),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _rail
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [rimHigh, rimLow],
        ).createShader(rect),
    );

    // The hairline where the rail meets the cloth: the seam of the two.
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(_rail + 0.5), corner),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = Dim.hairline
        ..color = AppTheme.ink900.withValues(alpha: 0.45),
    );

    // One soft band of light travelling across the cloth, edge to edge, on a
    // loop slow enough that nobody watches it happen — they just notice the
    // table is not a still image. Clipped to the cloth and drawn before the
    // rail so it never crosses the metal.
    final travel = (phase * 2 - 1) * size.width * 1.4;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.transparent,
            Colors.white.withValues(alpha: 0.035),
            Colors.transparent,
          ],
          stops: const [0.34, 0.5, 0.66],
          transform: GradientTranslation(travel),
        ).createShader(rect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ClothPainter old) =>
      old.core != core ||
      old.mid != mid ||
      old.rim != rim ||
      old.rimHigh != rimHigh ||
      old.rimLow != rimLow ||
      old.accent != accent ||
      old.tint != tint ||
      old.radius != radius ||
      old.phase != phase;
}

/// Which kind of table this is, said plainly on the felt.
///
/// The room already takes its colour from the category, but colour alone asks
/// a player to remember what it means. This says it — and on a blind table
/// that matters, because it is the reason they cannot see anyone's stack.
class _CategoryTag extends StatelessWidget {
  const _CategoryTag({required this.room});
  final RoomState room;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<GameState>();
    final t = state.t;
    final blind = room.category == TableCategory.blind;
    final variation = room.category == TableCategory.variation;
    final palette = AppTheme.paletteFor(
      theme.colorScheme,
      category: room.category,
      bootAmount: room.bootAmount,
    );

    // The category and the stake together: "Blind · 5,000" names the table,
    // and the colour behind it is the table's own. The category word is
    // translated, so it keeps its natural case — tracked capitals are a no-op
    // on Devanagari and would only mismatch the tracking beside it.
    //
    // A variation table names the rules of the hand in place of the stake
    // once they are chosen, and keeps naming them through the showdown
    // ("Variation · Joker · 9"): they are what the hands on the table are
    // being read by. Its label comes in PARTS — the words, and under Hukam
    // the suit to paint — because a bare '♣' in this gold text was drawn by
    // Android's colour emoji font, black on the dark pill (owner, 24 Sep
    // 2026: "the icon on top is not visible properly"; VariationTagParts). A
    // seen or blind table's parts are its words alone, so its tag is the
    // text it always was.
    final label = variation
        ? variationTagParts(
            category: t.variation,
            boot: formatChips(room.bootAmount),
            selected: state.shownVariation,
            turnUp: state.shownTurnUp,
            nameOf: t.variationName,
          )
        : VariationTagParts(
            words:
                '${blind ? t.blind : t.seen} · ${formatChips(room.bootAmount)}',
          );
    final style = TableType.boot(theme);
    // The suit stands exactly as tall as the label's line — the font size,
    // scaled as the text is, by the line height — so it sits in the line
    // where the glyph did and never grows the tag: 13.8dp at labelMedium,
    // 17dp at the 1.25 text ceiling.
    final suit = label.suit;
    final markSize =
        MediaQuery.textScalerOf(context).scale(style.fontSize ?? 12) *
        (style.height ?? 1);

    return Center(
      child: Plate(
        accent: palette.accent.withValues(alpha: 0.45),
        padding: const EdgeInsets.fromLTRB(
          Space.md,
          Space.xs,
          Space.lg,
          Space.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The mark, not just the word: the eye and the crossed eye say
            // whether this player sees their own cards at all. The plate is
            // ink in both themes, and the light theme's accents are deep ones
            // for white cards — blind's sapphire is 2.5:1 on it, and since
            // 24 Sep 2026 every blind table wears it — so by day the mark is
            // the accent lifted toward white (6.8:1 for blind).
            Icon(
              palette.icon,
              size: 14,
              color: theme.brightness == Brightness.light
                  ? Color.lerp(palette.accent, Colors.white, 0.4)
                  : palette.accent,
            ),
            const SizedBox(width: Space.sm),
            Flexible(
              child: FittedBox(
                // It shrinks on a small screen rather than losing its stake
                // to an ellipsis; the suit shrinks with the words.
                fit: BoxFit.scaleDown,
                child: Text.rich(
                  TextSpan(
                    text: label.words,
                    children: [
                      if (suit != null) ...[
                        const TextSpan(text: ' · '),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: SuitMark(suit: suit, size: markSize),
                        ),
                      ],
                    ],
                  ),
                  maxLines: 1,
                  style: style,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How many bets this player may still make without looking at their cards,
/// as dots rather than a fraction: on a 25-second clock a row of dots is read
/// at a glance and "3/4" is read twice. It sits under "See cards" on the
/// player's own hand, where the choice it counts down to is made.
class _BlindDots extends StatelessWidget {
  const _BlindDots({required this.left, required this.max});

  final int left;
  final int max;

  @override
  Widget build(BuildContext context) {
    final t = context.watch<GameState>().t;
    // The last blind move is worth a warmer mark: the next bet after it turns
    // the cards face up whether the player looked or not.
    final lastOne = left <= 1;

    return Semantics(
      label: '${t.blindMovesLabel} $left/$max',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < max; i++)
            Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : Space.xs),
              child: _Pip(
                filled: i < left,
                colour: lastOne ? AppTheme.amber : AppTheme.goldBright,
              ),
            ),
        ],
      ),
    );
  }
}

/// One blind move, spent or unspent.
class _Pip extends StatelessWidget {
  const _Pip({required this.filled, required this.colour});

  final bool filled;
  final Color colour;

  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: filled ? colour : Colors.transparent,
      border: filled
          ? null
          : Border.all(color: AppTheme.ink400, width: Dim.hairline),
    ),
  );
}

/// The pot, on a plinth in the middle of the cloth.
class _Pot extends StatelessWidget {
  const _Pot({required this.room, required this.chipSize, required this.pot});

  final RoomState room;

  /// The figure to show: the table's pot, or the one a missile was fired over
  /// while its volley is still in the air.
  final int pot;

  /// The same figure the chips flying in are drawn at, so the pile and the
  /// chips landing on it are the same size.
  final double chipSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // No watch: `room` arrives as a field from _Felt, which does watch, so the
    // figure still moves with the pot. The watch here only ever fed the two
    // captions that are gone.

    return Plate(
      radius: Radii.lg,
      opacity: 0.52,
      elevation: 3,
      accent: AppTheme.goldBright.withValues(alpha: 0.22),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xs,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // No "POT" caption and no stake/boot line. A pile of chips with a
          // figure beside it in the middle of a card table is not ambiguous,
          // and the stake is already on the action key the player is about to
          // press. Both were labels explaining something the table says.
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // The pile grows as the pot does — a nudge upward each time chips
              // land, so the middle of the table is where the eye goes.
              _PotChips(pot: pot, size: chipSize),
              const SizedBox(width: Space.sm),
              Flexible(
                // Chips arriving in the pot is the thing players watch, so the
                // number travels to its new value instead of jumping. Tabular
                // figures are what stop it jittering sideways while it counts.
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: pot.toDouble()),
                  duration: const Duration(milliseconds: 550),
                  curve: Motion.standard,
                  builder: (context, value, _) => FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      formatChips(value.round()),
                      style: TableType.pot(theme),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The pile on the plinth. It lifts and settles whenever the pot changes, so
/// chips landing is something you see rather than only read.
class _PotChips extends StatefulWidget {
  const _PotChips({required this.pot, required this.size});

  final int pot;
  final double size;

  @override
  State<_PotChips> createState() => _PotChipsState();
}

class _PotChipsState extends State<_PotChips>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void didUpdateWidget(covariant _PotChips old) {
    super.didUpdateWidget(old);
    // Only on the way up: the pot resetting to zero at the hand's end is not
    // chips landing.
    if (widget.pot > old.pot) _c.forward(from: 0);
  }

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
        builder: (context, child) {
          // Up and back down, with a touch of overshoot on the way.
          final lift = math.sin(_c.value * math.pi);
          return Transform.translate(
            offset: Offset(0, -6 * lift),
            child: Transform.scale(scale: 1 + 0.12 * lift, child: child),
          );
        },
        child: ChipStack(
          size: widget.size,
          colours: const [
            AppTheme.goldDeep,
            AppTheme.ink500,
            AppTheme.gold,
            AppTheme.goldBright,
          ],
        ),
      ),
    );
  }
}

/// The one sentence on the table that costs money to miss.
class _Status extends StatelessWidget {
  const _Status({required this.room});
  final RoomState room;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);

    // The server has already moved on while a missile volley is in the air;
    // "Starting game" under it would say so before the missiles land.
    if (state.missileStrike != null) return const SizedBox.shrink();

    final text = switch (room.state) {
      TableState.waiting => '${state.t.waitingForPlayers} (${room.minPlayers})',
      TableState.starting => state.t.startingGame,
      // Nothing during a hand. Whose turn it is, is carried by the pulsing
      // ring on that player's pod — naming them in the middle of the table as
      // well says the same thing twice, and it said it in the one place the
      // eye is already looking for the pot.
      //
      // The waiting and starting lines stay: those explain why NOTHING is
      // happening, which no pod can show.
      _ => '',
    };

    // A seat the table is holding for a chip purchase outranks the rest: it
    // is the one line here with the player's own seat riding on it.
    final graceLeft = state.unfundedGraceLeft(DateTime.now());

    // A variation table has two things to say during a hand, in the slot that
    // is otherwise blank for it: who the table is waiting on while the window
    // is open — to everyone but the chooser, who has the picker instead — and,
    // for a few seconds after, what the hand is being played under. Without
    // the first the table simply looks frozen for ten seconds: nobody is on
    // turn, so no pod would be ringing.
    final window = state.variation;
    if (graceLeft == null &&
        window != null &&
        window.selecting &&
        !state.variationIsMine) {
      return VariationSelectingLine(
        text: state.t.variationSelectingBy(window.displayName),
        deadlineMs: window.deadline,
        totalMs: window.timeoutMs,
      );
    }
    // Someone is choosing which three of their five play, and the table is
    // on their turn: everyone else is told so rather than watching a seat do
    // nothing (owner, 19 Sep 2026). The chooser sees the picker instead.
    final choosing = state.someoneChoosingCards;
    if (graceLeft == null && choosing != null) {
      final hand = state.room?.you?.hand;
      return VariationSelectingLine(
        text: state.t.pickChoosing(choosing.displayName),
        // Everyone shares the chooser's clock; a viewer who is choosing too
        // has their own deadline, which is the one their picker counts down.
        deadlineMs: hand?.pickDeadline ?? 0,
        totalMs: hand?.pickTimeoutMs ?? 0,
      );
    }
    final chosen = state.variationAnnounced;
    if (graceLeft == null && chosen != null) {
      // Why the server chose, when it did — and the two causes are different
      // sentences. "Time ran out" is only true of the clock; a chooser who
      // walked away from the table did not run it out, and the players left
      // behind should be told what actually happened. The name comes from the
      // window's own block, which the snapshot keeps for the rest of the hand
      // (the seat is gone, so it cannot come from there).
      final chooser = state.variation?.displayName ?? '';
      final detail = switch (chosen.selectedBy) {
        VariationSelectedBy.timeout => state.t.variationAutoChosen,
        VariationSelectedBy.left =>
          chooser.isEmpty
              ? state.t.variationAutoChosen
              : state.t.variationLeftChosen(chooser),
        _ => null,
      };
      return VariationChosenLine(
        text: state.t.variationChosen(state.t.variationName(chosen.variation)),
        detail: detail,
      );
    }
    final line = graceLeft != null ? state.t.buyChipsToStay(graceLeft) : text;

    if (line.isEmpty) return const SizedBox.shrink();

    final mine = state.myTurn && room.state == TableState.betting;

    return AnimatedSwitcher(
      duration: Motion.base,
      switchInCurve: Motion.emphasized,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.14),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: FittedBox(
        // Keyed on the sentence, so one line cross-fades into the next rather
        // than snapping. A player's name is in it, so it keeps its own case.
        // The countdown keeps one key, so its ticking seconds do not
        // cross-fade the line every second.
        key: ValueKey(graceLeft != null ? 'unfunded-grace' : line),
        fit: BoxFit.scaleDown,
        child: Text(
          line,
          style:
              TableType.system(
                theme,
                colour: graceLeft != null
                    ? AppTheme.amber
                    : mine
                    ? AppTheme.goldBright
                    // The felt is pale on the light theme, and white text
                    // on it all but vanished ("Waiting for players", QA 14
                    // Sep 2026); dark ink there, as on every other light
                    // surface.
                    : theme.brightness == Brightness.dark
                    ? AppTheme.boneInk.withValues(alpha: 0.82)
                    : AppTheme.inkOnLight.withValues(alpha: 0.78),
                // A seat held for a purchase is the one line here with the
                // player's own seat riding on it, so it is the strong one.
                strong: graceLeft != null,
              ).copyWith(
                // The only glowing text in the app, on the only line that has a
                // clock attached to it.
                shadows: mine
                    ? [
                        Shadow(
                          color: AppTheme.goldBright.withValues(alpha: 0.22),
                          blurRadius: 6,
                        ),
                      ]
                    : null,
              ),
        ),
      ),
    );
  }
}

/// The viewer's own cards, resting on the cloth in a fan, with "See cards"
/// laid over them: looking at your hand is something you do to the cards, and
/// once you have looked the key has no reason to still be there.
///
/// **How many cards is the server's to say, never assumed** (owner, 18 Sep
/// 2026). Three on every table but one: under 5-Card every hand is topped up
/// to FIVE the moment that variation is chosen, and the best three of them are
/// played. Face up, the fan is `you.cards`, however many that is; face down it
/// is `variation.cardsPerPlayer` backs — three where there is no variation
/// block or the server predates the figure.
///
/// **One hand, not three cards** (premium-card brief, 25 Sep 2026): the fan
/// is [HandFan]'s — the middle card upright, raised and on top, the outer two
/// turned 4.5° out and tucked under it, 0.62 of a card apart, the card to
/// its right printing its index in its top-right corner so that no rank is
/// under another card. [PlayingCard] turns them over one after another, left to right.
///
/// **Five cards stand in the box three do.** On a 640dp phone the hand sits
/// between the viewer's pod and the action keys with nothing to spare, so the
/// box is always as wide as a five-card hand's run ([HandFan.widthFor]) and a
/// three-card hand is fanned tighter, centred in it; five cards stand 0.375 of
/// a card apart, the least that still clears each index once the fan's lean
/// has opened its top.
///
/// **What is being played is shown, not asked.** Once `you.hand.best` names
/// three of five, the server's choice is ACTED OUT (owner, 18 Sep 2026: "show
/// an animation that the two cards are low and then rearrange the cards that
/// bring the selected cards at top") — [_BestThreeStage]: the faces turn over
/// in the order held, then the two that do not count sink and are set back
/// ([SetBack]), then the fan is re-dealt so those two slide under to the left
/// and the three that count come to the front of the fan and rise. The server
/// chose them and the player chooses nothing.
class _OwnHand extends StatelessWidget {
  const _OwnHand({
    required this.cardHeight,
    this.revealed,
    this.wild = const [],
    this.playsAs = const [],
    this.best = const [],
  });

  /// The cards of a showdown's or a sideshow's five-card hand that counted,
  /// for when `you.hand` cannot say: the server drops that block the moment
  /// the hand ends, while the cards are still on the felt being compared.
  /// Empty on every three-card hand.
  final List<String> best;

  /// Which of the hand's cards played as wild ones, once a showdown or a
  /// sideshow has said so (a variation table). Empty until then: the viewer
  /// sees their own cards all hand, but which of them were wild is the
  /// server's to say, with the reveal.
  final List<String> wild;

  /// The hand as it was counted, from a showdown's or a sideshow's reveal —
  /// the stand-in for each wild card when `you.hand` cannot say (a player who
  /// paid for a show while still blind never had that block), so their own
  /// fan turns the way every rim seat's does (24 Sep 2026). Empty otherwise.
  final List<String> playsAs;
  final double cardHeight;

  /// The viewer's own cards as the showdown turned them over.
  ///
  /// Only ever needed by a player who paid for a show without looking first:
  /// `you.cards` stays empty while a seat is blind and the server does not
  /// un-blind the seat at the showdown, so their own hand would be the one
  /// hand on the table still face down — under a SEE button, at the moment
  /// they are being told they won with it.
  final List<String>? revealed;

  /// How far a card that counts stands proud of the fan, as a share of its
  /// height: the best three of five, once they are set out.
  static const double _lifted = 0.08;

  /// How far a card that does not count dips while it is being set aside,
  /// before the fan is re-dealt and it comes back to the cloth's line.
  static const double _sunk = 0.06;

  /// How far apart the cards that do NOT count stand once the fan is re-dealt,
  /// in card widths. Tight — they are out of the hand and only their rank has
  /// to read — so that the run they give up goes to the three that count: those
  /// stand 0.51 of a card apart instead of 0.375, which shows each one's middle
  /// pip as well as its corner (owner, 19 Sep 2026: "the front three cards'
  /// symbols are not visible properly"). The first and the last card stay
  /// where a five-card hand's are, so the fan's box is what it was.
  static const double _tucked = 0.24;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final you = state.room?.you;
    if (you == null) return const SizedBox.shrink();

    // Folded and beaten are different endings. A pack is struck out — dimmed,
    // under a PACKED plate. A hand beaten at a show was played to the end and
    // is on the table to be compared, so it stays face up and clear with its
    // name over it, like every other hand that showdown turned over. The
    // server marks only a showdown loser `lost`; a fold stays `packed`.
    // A Force Sideshow's loser folds when the hammer lands on them, not the
    // moment before it sets off when the server packed them.
    final held =
        you.status == SeatState.packed && state.foldHeldFor(state.user?.id);
    final packed = you.status == SeatState.packed && !held;
    final beaten = you.status == SeatState.lost;
    // The hand that just took the pot is still on the table while the
    // celebration runs. The server moves the winner's seat to `won` the moment
    // it settles, and reading that as "not playing any more" swept the
    // viewer's own cards off the felt at the exact moment they were being told
    // they had won with them — the rim seats already count `won` as in-hand
    // (seat_pod.dart `_inHand`), and this is the copy that did not.
    final inHand =
        you.status == SeatState.active || you.status == SeatState.won || held;
    // A packed hand stays on the table, face down and struck out, so the player
    // can see what they folded rather than having it vanish.
    if (!inHand && !packed && !beaten) {
      return const SizedBox.shrink();
    }

    final cards = you.cards.isNotEmpty ? you.cards : (revealed ?? const []);

    // Looking is allowed at any point, not only on your own turn: it costs
    // nothing and changes nothing for anyone else. Betting still waits for the
    // turn, which the console handles. Only while the hand is actually being
    // played, though: a hand already face up has nothing left to look at, and
    // a hand won by everyone else packing is over — the key would offer a move
    // the server can only refuse.
    final stillBlind =
        you.isBlind && you.status == SeatState.active && cards.isEmpty;
    // This table's blind allowance, from the menu entry the room was opened
    // from: a private table's template when the server lists them (the table
    // catalogue), else the lobby entry of the same pair; 4 when neither says.
    final room = state.room!;
    final maxBlind =
        state.config
            .entryFor(
              category: room.category,
              bootAmount: room.bootAmount,
              isPrivate: room.isPrivate,
            )
            ?.maxBlindMoves ??
        4;

    // How many cards to draw. Face up, what the server sent. Face down, what
    // the viewer's own seat is said to hold (`cardCount`, the figure the rim
    // pods draw from), and only then what the variation block says everybody
    // holds: the server drops that block the moment the hand ends while the
    // cards stay on the felt until the next deal, so a player who never looked
    // under 5-Card — winning because everyone else packed, or sitting out the
    // rest of a hand they folded — had their own fan fall from five backs to
    // three beside four seats still showing five. Held to 3..5: fewer than
    // three is a snapshot caught mid-change and drawn as the hand it is about
    // to be, and the felt has no room for a sixth.
    final seatCards =
        room.seats
            .where((s) => s.seatIndex == you.seatIndex)
            .firstOrNull
            ?.cardCount ??
        0;
    final count =
        (cards.isNotEmpty
                ? cards.length
                : seatCards > 0
                ? seatCards
                : state.variation?.cardsPerPlayer ?? 3)
            .clamp(3, 5);
    // The three that count, once there are more than three to choose from.
    final counted = (you.hand?.best.isNotEmpty ?? false)
        ? you.hand!.best
        : best;
    final picking =
        cards.length > 3 && counted.isNotEmpty && counted.length < cards.length;

    // The fan's own box (HandFan): as wide as a five-card hand's run and the
    // outer cards' lean, whatever this hand holds, so a top-up never moves
    // anything; the cards cast their shadows onto the cloth, so nothing here
    // may clip tightly to a card.
    final cardW = HandFan.cardWidthFor(cardHeight);
    final run = HandFan.runFor(count, cardW);
    final step = run / (count - 1);
    final start = HandFan.startFor(count, cardHeight);
    final width = HandFan.widthFor(cardHeight);
    final mid = (count - 1) / 2;

    return _BestThreeStage(
      picking: picking,
      handNo: state.room?.handNo ?? 0,
      builder: (context, stage) {
        // Which place in the fan each card holds. In the order held, until the
        // last stage re-deals them: the cards that do not count take the left
        // places, underneath, and the three that count take the right ones,
        // on top, each keeping its order.
        final sorting = picking && stage == _PickStage.arranged;
        final slotOf = List<int>.generate(count, (i) => i);
        if (sorting) {
          final aside = [
            for (var i = 0; i < count; i++)
              if (!counted.contains(cards[i])) i,
          ];
          final playing = [
            for (var i = 0; i < count; i++)
              if (counted.contains(cards[i])) i,
          ];
          for (final (slot, i) in [...aside, ...playing].indexed) {
            slotOf[i] = slot;
          }
        }
        // Painted from the outside in, so the card in the middle place is on
        // top (HandFan.paintOrder) — and once the fan is re-dealt, the cards
        // set aside first, left to right, under the three that count, whose
        // middle one is on top of them. Every card is keyed by the index it
        // was DEALT at, so a card that changes places keeps its state — its
        // flip, its wild turn — and slides rather than being rebuilt
        // somewhere else.
        final asideCount = sorting ? count - counted.length : 0;
        final slotRank = <int, int>{
          for (final (rank, slot) in [
            for (var a = 0; a < asideCount; a++) a,
            for (final c in HandFan.paintOrder(count - asideCount))
              asideCount + c,
          ].indexed)
            slot: rank,
        };
        final order = List<int>.generate(
          count,
          (i) => i,
        )..sort((a, b) => slotRank[slotOf[a]]!.compareTo(slotRank[slotOf[b]]!));
        // The place painted last: the card on top, whose face is whole.
        final topSlot = slotRank.entries
            .firstWhere((e) => e.value == count - 1)
            .key;
        // Where each place stands along the run. Even steps, until the fan is
        // re-dealt; then the set-aside cards are tucked close together and the
        // three that count share what is left, ending where the run ends.
        final wide = asideCount > 0 && counted.length > 1
            ? (run - asideCount * cardW * _tucked) / (counted.length - 1)
            : step;
        double placeOf(int slot) => !sorting || asideCount == 0
            ? slot * step
            : slot < asideCount
            ? slot * cardW * _tucked
            : asideCount * cardW * _tucked + (slot - asideCount) * wide;
        final setAside = picking && stage != _PickStage.held;

        return SizedBox(
          width: width,
          height: HandFan.heightFor(cardHeight),
          child: Stack(
            // A wild card's halo and sparks are painted past its own box
            // (WildTransform), and the cards' shadows already were.
            clipBehavior: Clip.none,
            children: [
              // The hand held a little off the cloth (owner's brief, 25 Sep
              // 2026: "clear separation, subtle elevation, subtle shadow"): one
              // soft shadow the width of the fan on the cloth beneath it, under
              // the cards' own. Not under a packed hand, which lies flat.
              if (!packed)
                Positioned(
                  left: start + cardW * 0.2,
                  width: run + cardW * 0.6,
                  bottom: cardHeight * 0.02,
                  height: cardHeight * 0.1,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(cardHeight),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.ink900.withValues(
                              alpha: theme.brightness == Brightness.dark
                                  ? 0.34
                                  : 0.16,
                            ),
                            blurRadius: cardHeight * 0.16,
                            spreadRadius: cardHeight * 0.02,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              for (final i in order)
                // Animated, so that when a hand is topped up to five the three
                // already held slide together to make room rather than jumping,
                // and the best three rise rather than snap. At rest it is the
                // plain Positioned it replaced.
                AnimatedPositioned(
                  key: ValueKey('own-card-${state.room?.handNo}-$i'),
                  duration: sorting ? Motion.arrive : Motion.slow,
                  curve: Motion.standard,
                  left: start + placeOf(slotOf[i]),
                  // The middle card sits a little proud of its neighbours — until
                  // the hand has three that count. Then the two that do not dip
                  // as they are set aside, and once the fan is re-dealt the three
                  // that do stand proud instead.
                  bottom: !setAside
                      ? (i == mid ? cardHeight * HandFan.proud : 0)
                      : counted.contains(cards[i])
                      ? (sorting ? cardHeight * _lifted : 0)
                      : (sorting ? 0 : -cardHeight * _sunk),
                  child: _Dealt(
                    key: ValueKey('${state.room?.handNo}-$i'),
                    // The two cards of a top-up arrive as the first two of a deal
                    // did, not after a pause for three cards that are not coming.
                    index: i < 3 ? i : i - 3,
                    // A card leans by where it stands along the run.
                    restAngle: HandFan.angleAt(placeOf(slotOf[i]), run),
                    // On a variation table a wild card turns into the card it
                    // played as, once the server says what that was — `you.hand`,
                    // sent to this player alone when they have looked and the
                    // variation is chosen. Everywhere else, and for every card
                    // that is not wild, this is the plain card it always was.
                    child: SetBack(
                      setBack: setAside && !counted.contains(cards[i]),
                      cardHeight: cardHeight,
                      child: WildTransform(
                        height: cardHeight,
                        code: i < cards.length ? cards[i] : null,
                        // The card on top covers its neighbours' inner
                        // edges, so a card to its right prints its index on
                        // its right; and the hand turns over left to right.
                        indexOnRight: HandFan.indexOnRight(slotOf[i], topSlot),
                        flipDelay: PlayingCard.flipStagger * i,
                        standIn: i >= cards.length
                            ? null
                            : you.hand != null
                            ? you.hand!.standInFor(cards[i], i)
                            : (playsAs.length == cards.length &&
                                      wild.contains(cards[i])
                                  ? playsAs[i]
                                  : null),
                        wild:
                            i < cards.length &&
                            (wild.contains(cards[i]) ||
                                (you.hand?.wild.contains(cards[i]) ?? false)),
                        index: i,
                        label: state.t.wildCard,
                        dimmed: packed,
                      ),
                    ),
                  ),
                ),
              if (packed)
                Positioned.fill(
                  child: Center(
                    child: Plate(
                      radius: Radii.sm,
                      opacity: 0.68,
                      // Charcoal in both themes, so the same red in both.
                      accent: TableInk.alarm.withValues(alpha: 0.45),
                      padding: EdgeInsets.symmetric(
                        horizontal: cardHeight * 0.18,
                        vertical: cardHeight * 0.07,
                      ),
                      child: Text(
                        state.t.packed,
                        style: TableType.system(
                          theme,
                          colour: TableInk.alarm,
                          strong: true,
                        ),
                      ),
                    ),
                  ),
                )
              else if (stillBlind)
                Positioned.fill(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: width - Space.md),
                      // The press feel only; the ghost styling under it is
                      // untouched, and the tap is still `state.see`, once.
                      child: PressScale(
                        child: FilledButton(
                          onPressed: () => state.see(),
                          style: FilledButton.styleFrom(
                            // A ghost key, so it no longer hides the artwork it is
                            // laid over.
                            minimumSize: Size(cardW * 1.6, Dim.minTouch),
                            backgroundColor: AppTheme.ink900.withValues(
                              alpha: 0.62,
                            ),
                            foregroundColor: AppTheme.goldBright,
                            side: BorderSide(
                              color: AppTheme.goldBright.withValues(
                                alpha: 0.55,
                              ),
                              width: 1.4,
                            ),
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            // The label, and under it the blind bets left: the
                            // count lives on the key that ends it rather than in a
                            // box of its own in the corner.
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  state.t.seeCards,
                                  maxLines: 1,
                                  // A move like any key's, laid over the cards
                                  // it turns; in gold, and a weight up, as the
                                  // one thing to do with a blind hand.
                                  style: TableType.secondaryAction(theme)
                                      .copyWith(
                                        color: AppTheme.goldBright,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                                const SizedBox(height: Space.xs),
                                _BlindDots(
                                  left: you.blindMovesLeft,
                                  max: maxBlind,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Where the acting-out of a five-card hand's best three has got to.
enum _PickStage {
  /// The order held, nothing singled out: the faces are still turning over.
  held,

  /// The two cards that do not count have sunk and are set back.
  aside,

  /// The fan is re-dealt: those two underneath on the left, the three that
  /// count on top on the right, raised.
  arranged,
}

/// Paces [_OwnHand]'s showing of the best three of five (owner, 18 Sep 2026).
///
/// It plays ONCE per hand, from the moment the hand first has three that count
/// — the tap on "See cards", or 5-Card being chosen for a player already
/// looking. A fan BUILT already knowing (a reconnect, a rebuilt table, the
/// showdown of a hand played blind) opens on the finished arrangement: the
/// animation explains a change, and there was none to see. A three-card hand
/// never leaves [_PickStage.held], which is what it always drew.
class _BestThreeStage extends StatefulWidget {
  const _BestThreeStage({
    required this.picking,
    required this.handNo,
    required this.builder,
  });

  final bool picking;
  final int handNo;
  final Widget Function(BuildContext context, _PickStage stage) builder;

  /// Long enough for the faces to turn over ([Motion.enter]) or a top-up to be
  /// dealt in before anything is set aside.
  static const Duration beforeAside = Duration(milliseconds: 650);

  /// How long the two set-aside cards are held low before the fan is re-dealt.
  static const Duration beforeArranged = Duration(milliseconds: 520);

  @override
  State<_BestThreeStage> createState() => _BestThreeStageState();
}

class _BestThreeStageState extends State<_BestThreeStage> {
  late _PickStage _stage = widget.picking
      ? _PickStage.arranged
      : _PickStage.held;
  Timer? _next;

  @override
  void didUpdateWidget(_BestThreeStage old) {
    super.didUpdateWidget(old);
    final newHand = widget.handNo != old.handNo;
    if (widget.picking && (!old.picking || newHand)) {
      _play();
    } else if (!widget.picking && _stage != _PickStage.held) {
      _next?.cancel();
      _stage = _PickStage.held;
    }
  }

  void _play() {
    _next?.cancel();
    _stage = _PickStage.held;
    _next = Timer(_BestThreeStage.beforeAside, () {
      if (!mounted) return;
      setState(() => _stage = _PickStage.aside);
      _next = Timer(_BestThreeStage.beforeArranged, () {
        if (mounted) setState(() => _stage = _PickStage.arranged);
      });
    });
  }

  @override
  void dispose() {
    _next?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _stage);
}

/// Tosses a card in from the middle of the table, staggered, so a hand looks
/// dealt onto cloth rather than switched on.
///
/// Dealt like a card (premium-card brief, 25 Sep 2026: "cards enter from the
/// deck; slight rotation; move into their final positions; small settling
/// animation"): it leaves the middle of the table turned a little and a touch
/// small, comes in over [_travel] of its time a little larger than life — in
/// the air, nearer the eye — turning into its place in the fan and just past
/// it, and in the rest sets down onto the cloth at its own size and lean.
/// Under half a second a card and [_beat] between them: the three cards of a
/// hand are down in 0.65 s.
class _Dealt extends StatefulWidget {
  const _Dealt({
    super.key,
    required this.index,
    required this.child,
    this.restAngle = 0,
  });

  final int index;
  final Widget child;

  /// Where this card comes to rest in the fan.
  final double restAngle;

  @override
  State<_Dealt> createState() => _DealtState();
}

/// One card's flight into the fan, and the beat between one card and the
/// next.
const Duration _landFor = Duration(milliseconds: 460);
const Duration _beat = Duration(milliseconds: 95);

/// The share of the flight spent travelling; the rest is the card setting
/// down.
const double _travel = 0.78;

class _DealtState extends State<_Dealt> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: _landFor,
  );

  /// In over the first part of the flight: it leaves the deck, not a fade.
  late final Animation<double> _fade = CurvedAnimation(
    parent: _c,
    curve: const Interval(0, 0.3),
  );

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(_beat * widget.index, () {
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
    // The resting angle is eased as well as the landing: a hand topped up
    // from three cards to five closes its fan, and the cards already held
    // should turn to their new places rather than flick to them. Built at its
    // end value, so a hand that never changes never moves.
    return FadeTransition(
      opacity: _fade,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: widget.restAngle),
        duration: Motion.slow,
        curve: Motion.standard,
        child: widget.child,
        builder: (context, rest, child) => AnimatedBuilder(
          animation: _c,
          child: child,
          builder: (context, child) {
            // One tree shape from the first frame to rest, so the card under
            // it (its flip, its wild turn) is never rebuilt when it lands.
            final v = _c.value;
            final travel = Curves.easeOutCubic.transform(
              (v / _travel).clamp(0.0, 1.0),
            );
            final settle = Curves.easeOut.transform(
              ((v - _travel) / (1 - _travel)).clamp(0.0, 1.0),
            );
            // Out of the middle of the table, up and to the left of the fan.
            const from = Offset(-0.5, -0.9);
            // A touch past its place, then back onto it.
            final past = rest + 0.035;
            final angle = v < _travel
                ? -0.2 + (past + 0.2) * travel
                : past + (rest - past) * settle;
            final scale = v < _travel
                ? 0.9 + 0.14 * travel
                : 1.04 - 0.04 * settle;
            return FractionalTranslation(
              translation: from * (1 - travel),
              child: Transform.scale(
                scale: scale,
                alignment: Alignment.bottomCenter,
                child: Transform.rotate(
                  angle: angle,
                  alignment: Alignment.bottomCenter,
                  child: child,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Requirement 14: every revealed hand, plus who won and for how much.
///
/// It sits over the table rather than replacing it. Covering the felt with a
/// near-opaque sheet reads as the game having stopped; the players, the pot and
/// the chips should all still be there while the hand is being settled.
class _Showdown extends StatelessWidget {
  const _Showdown({this.winnerAt, this.potFlight});

  /// Where the winner is sitting, as a fraction of the felt. Null when they
  /// have already left, in which case the fireworks go up over the table.
  final Offset? winnerAt;

  /// The chips crossing the table to them, drawn over the wash but under the
  /// headline — chips passing across the words would only make them harder to
  /// read, and the words are the point.
  final Widget? potFlight;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();

    final won = state.iWon;

    return Stack(
      children: [
        // No scrim (owner's decision, 10 Sep 2026). Dimming the table to point
        // at the winner also greys every other seat's revealed hand — the very
        // cards a player wants to compare against — and makes the app look
        // frozen for the length of the celebration. The winner is marked on
        // their own pod instead, which points without switching the lights off.
        Positioned.fill(
          child: _WinnerBurst(
            // Restarts on the next win rather than on every rebuild: the
            // screen repaints once a second for the reward clock, and a
            // celebration that began again each tick would never finish.
            hand: state.room?.handNo ?? 0,
            focus: winnerAt,
            big: won,
          ),
        ),
        if (potFlight != null) Positioned.fill(child: potFlight!),
        // No banner over the middle of the table (owner's decision, 10 Sep
        // 2026). The result is announced on the winner's own pod instead —
        // see _WinnerFlash in seat_pod.dart — which says the same thing in the
        // one place a player is already looking, and says WHO by sitting on
        // them rather than by naming them.
      ],
    );
  }
}

/// The winner's fireworks: `assets/animations/Fireworks.json`, played once
/// over the seat that won.
///
/// Lottie rather than an animated SVG, which is what this started as:
/// flutter_svg's compiler has no handling for `animate` / `animateTransform`
/// at all, so an animated SVG lands on the felt as one still frame with no
/// error to say why. Lottie is already a dependency (the profile pictures use
/// it) and plays properly.
///
/// It runs ONCE, not on a loop. The celebration stays up for a few seconds
/// while the pot travels and the next deal is announced, and fireworks
/// restarting under that would read as a stuck screen rather than a flourish.
class _WinnerBurst extends StatefulWidget {
  const _WinnerBurst({required this.hand, this.focus, this.big = false});

  /// The hand just won. A change is what replays it.
  final int hand;

  /// Where the burst is centred, as a fraction of this box — the winner's
  /// seat, so the celebration is about a player rather than the room. Null
  /// centres it on the felt.
  final Offset? focus;

  /// Larger when the viewer themselves won.
  final bool big;

  @override
  State<_WinnerBurst> createState() => _WinnerBurstState();
}

class _WinnerBurstState extends State<_WinnerBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  @override
  void didUpdateWidget(covariant _WinnerBurst old) {
    super.didUpdateWidget(old);
    if (old.hand != widget.hand && _controller.duration != null) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) {
          // Square, because the composition is: 512x512. Sized off the
          // SHORTER side so it never runs off a wide felt, and overscaled a
          // little so the sparks clear the pod rather than stopping at it.
          final side =
              math.min(box.maxWidth, box.maxHeight) *
              (widget.big ? 1.25 : 0.95);
          final centre = widget.focus == null
              ? Offset(box.maxWidth / 2, box.maxHeight / 2)
              : Offset(
                  widget.focus!.dx * box.maxWidth,
                  widget.focus!.dy * box.maxHeight,
                );
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: centre.dx - side / 2,
                top: centre.dy - side / 2,
                width: side,
                height: side,
                child: RepaintBoundary(
                  child: Lottie.asset(
                    'assets/animations/Fireworks.json',
                    controller: _controller,
                    fit: BoxFit.contain,
                    // The composition carries its own length; taking it from
                    // the file keeps the timing right if the art is replaced.
                    onLoaded: (composition) {
                      _controller.duration = composition.duration;
                      _controller.forward(from: 0);
                    },
                    // A missing or unreadable file must not take the table
                    // down with it — the hand is already won either way.
                    errorBuilder: (context, error, stack) =>
                        const SizedBox.shrink(),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SideshowLink extends StatefulWidget {
  const _SideshowLink({required this.from, required this.to});

  final Offset from;
  final Offset to;

  @override
  State<_SideshowLink> createState() => _SideshowLinkState();
}

class _SideshowLinkState extends State<_SideshowLink>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => CustomPaint(
        painter: _SideshowLinkPainter(
          from: widget.from,
          to: widget.to,
          t: _pulse.value,
        ),
      ),
    );
  }
}

// Drawn in goldDeep rather than goldBright, and roughly twice as heavy.
// Bright champagne was chosen when this arced across dark emerald cloth; with
// the cloth gone it is pale-on-pale and all but invisible — the ask happened
// and nothing on screen showed it. The deep gold reads on both grounds.
class _SideshowLinkPainter extends CustomPainter {
  const _SideshowLinkPainter({
    required this.from,
    required this.to,
    required this.t,
  });

  final Offset from;
  final Offset to;

  /// 0 to 1, once per pulse.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    // A curve rather than a straight line: seats sit round a rim, and a chord
    // across the middle would cut through the pot.
    final mid = Offset((from.dx + to.dx) / 2, (from.dy + to.dy) / 2);
    final lift = (to - from).distance * 0.18;
    final control = Offset(mid.dx, mid.dy - lift);

    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(control.dx, control.dy, to.dx, to.dy);

    // A thread of light rather than a painted pipe: a soft underlay with a
    // hairline burning down the middle of it.
    canvas.drawPath(
      path,
      Paint()
        ..color = AppTheme.goldDeep.withValues(alpha: 0.30)
        ..strokeWidth = 7
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = AppTheme.goldDeep.withValues(alpha: 0.95)
        ..strokeWidth = 2.6
        ..style = PaintingStyle.stroke,
    );

    // A comet running from the player who asked to the player being asked, so
    // the direction of the request is readable at a glance.
    final metric = path.computeMetrics().first;
    final head = metric.getTangentForOffset(metric.length * t)?.position;
    if (head != null) {
      for (var i = 8; i >= 0; i--) {
        final back = (t - i * 0.022).clamp(0.0, 1.0);
        final at = metric.getTangentForOffset(metric.length * back)?.position;
        if (at == null) continue;
        canvas.drawCircle(
          at,
          5 - i * 0.35,
          Paint()
            ..color = AppTheme.goldDeep.withValues(alpha: 0.85 * (1 - i / 9)),
        );
      }
      canvas.drawCircle(
        head,
        5,
        Paint()..color = AppTheme.goldBright.withValues(alpha: 0.95),
      );
    }

    // A ring opening out of the seat being asked, which is where the answer
    // has to come from.
    canvas.drawCircle(
      to,
      18 + 22 * t,
      Paint()
        ..color = AppTheme.goldBright.withValues(alpha: 0.45 * (1 - t))
        ..strokeWidth = Dim.hairline
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_SideshowLinkPainter old) =>
      old.t != t || old.from != from || old.to != to;
}

/// The accept-or-decline prompt, shown only to the player who was asked.
///
/// The six seconds are the server's: it drops the request on its own clock
/// whatever this does, so the arc here is a readout and the keys simply beat it
/// to the answer.
class _SideshowPrompt extends StatelessWidget {
  const _SideshowPrompt({required this.state});
  final GameState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = state.sideshow;
    if (pending == null) return const SizedBox.shrink();

    String askerName = '';
    for (final seat in state.room?.seats ?? const <Seat>[]) {
      if (seat.userId == pending.fromUserId) askerName = seat.displayName;
    }

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: Dim.sideshowPanelW(MediaQuery.sizeOf(context).width),
        ),
        child: Plate(
          radius: Radii.lg,
          opacity: 0.78,
          elevation: 5,
          borderWidth: 1.5,
          accent: AppTheme.goldBright.withValues(alpha: 0.45),
          padding: const EdgeInsets.fromLTRB(
            Space.xl,
            Space.lg,
            Space.xl,
            Space.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                // One of the few fixed Latin words the code owns, so it may be
                // tracked and set in capitals.
                'SIDESHOW',
                style: TableType.caps(
                  theme,
                  tracking: 2.4,
                  colour: AppTheme.goldBright.withValues(alpha: 0.75),
                ),
              ),
              const SizedBox(height: Space.sm),
              Text(
                '$askerName ${state.t.sideshowAsksYou}',
                textAlign: TextAlign.center,
                style: TableType.system(
                  theme,
                  colour: AppTheme.boneInk,
                  strong: true,
                ),
              ),
              const SizedBox(height: Space.lg),
              _SideshowCountdown(
                expiresAt: pending.expiresAt,
                totalMs: state.config.sideshowTimeoutMs,
              ),
              const SizedBox(height: Space.lg),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Both keys stand on a dark plate on the cloth, so they keep
                  // plate ink in both brightnesses (file header): the decline
                  // key is the glass weight with the plate's own fill and
                  // bone ink laid over it, the accept key the one gold fill.
                  Expanded(
                    child: GlassButton(
                      style: GlassButtonStyle.glass,
                      expand: true,
                      onPressed: () => state.answerSideshow(false),
                      minimumSize: const Size(120, 48),
                      buttonStyle: OutlinedButton.styleFrom(
                        backgroundColor: AppTheme.ink700.withValues(alpha: 0.9),
                        foregroundColor: AppTheme.boneInk,
                        side: BorderSide(
                          color: theme.colorScheme.error.withValues(
                            alpha: 0.45,
                          ),
                          width: Dim.hairline,
                        ),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(state.t.decline, maxLines: 1),
                      ),
                    ),
                  ),
                  const SizedBox(width: Space.lg),
                  Expanded(
                    child: GlassButton(
                      style: GlassButtonStyle.primary,
                      expand: true,
                      onPressed: () => state.answerSideshow(true),
                      minimumSize: const Size(120, 48),
                      buttonStyle: FilledButton.styleFrom(
                        backgroundColor: AppTheme.gold,
                        foregroundColor: AppTheme.ink900,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(state.t.accept, maxLines: 1),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bar draining under a sideshow request.
///
/// It reads the wall clock once per frame rather than taking a level from the
/// game state, which only republishes about once a second — a bar stepping in
/// whole seconds is what makes a countdown look like it is stuttering. There
/// is no number over it: six seconds is short enough that a shortening bar
/// says everything a digit would, and reads faster.
class _SideshowCountdown extends StatefulWidget {
  const _SideshowCountdown({required this.expiresAt, required this.totalMs});

  /// When the server drops the request, in epoch milliseconds, and the window
  /// it allowed. The expiry is the server's; this only draws it.
  final int expiresAt;
  final int totalMs;

  @override
  State<_SideshowCountdown> createState() => _SideshowCountdownState();
}

class _SideshowCountdownState extends State<_SideshowCountdown>
    with SingleTickerProviderStateMixin {
  /// Repeats rather than runs once, so the bar keeps redrawing whatever the
  /// deadline is; the fraction below is what actually ends it.
  late final AnimationController _frames = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  /// How much of the window is left, right now.
  double _remaining() {
    if (widget.totalMs <= 0) return 0;

    final left = widget.expiresAt - DateTime.now().millisecondsSinceEpoch;
    return (left / widget.totalMs).clamp(0.0, 1.0);
  }

  @override
  void dispose() {
    _frames.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _frames,
        builder: (context, _) {
          final left = _remaining();

          // The colour carries the urgency the missing number used to: it
          // slides from champagne towards the error red as the last third
          // runs out.
          final colour = Color.lerp(
            theme.colorScheme.error,
            AppTheme.goldBright,
            (left * 3).clamp(0.0, 1.0),
          )!;

          // Full width of the panel it sits in, so it fits a 640dp phone as
          // well as a tablet.
          return SizedBox(
            height: 6,
            width: double.infinity,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(
                      color: AppTheme.ink400.withValues(alpha: 0.55),
                    ),
                  ),
                  // heightFactor as well as widthFactor: the bar has no
                  // child to give it a height, so without it the fill
                  // collapses to nothing and only the track shows. Aligned
                  // left, or it would drain towards its own middle.
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: left,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [colour.withValues(alpha: 0.75), colour],
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

/// Chips in flight from a seat to the pot, one for every bet as it happens.
///
/// Watches each seat's running total; when it rises, a chip sets off from that
/// seat and lands on the pot. A new hand resets the totals, so the boot
/// everyone posts at the deal flies in too. Nothing is sent for the snapshot a
/// player arrives to — those bets were made before they sat down.
class _BetFlights extends StatefulWidget {
  const _BetFlights({
    required this.seats,
    required this.handNo,
    required this.centreOf,
    required this.pot,
    required this.size,
  });

  final List<Seat> seats;
  final int handNo;
  final Offset Function(int seatIndex) centreOf;
  final Offset pot;
  final double size;

  @override
  State<_BetFlights> createState() => _BetFlightsState();
}

class _Flight {
  _Flight({required this.from, required this.startedAt, required this.delay});
  final Offset from;
  final Duration startedAt;
  final Duration delay;
}

class _BetFlightsState extends State<_BetFlights>
    with SingleTickerProviderStateMixin {
  static const _travel = Duration(milliseconds: 620);

  late final Ticker _ticker;
  Duration _now = Duration.zero;
  final Map<int, int> _seen = {};
  int _handNo = -1;
  final List<_Flight> _flights = [];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _now = elapsed;
      _flights.removeWhere((f) => elapsed - f.startedAt - f.delay > _travel);
      if (_flights.isEmpty) _ticker.stop();
      setState(() {});
    });
    // The state we arrive to is the baseline, not a set of bets to animate.
    _handNo = widget.handNo;
    for (final seat in widget.seats) {
      _seen[seat.seatIndex] = seat.contributed;
    }
  }

  @override
  void didUpdateWidget(covariant _BetFlights old) {
    super.didUpdateWidget(old);
    final newHand = widget.handNo != _handNo;
    if (newHand) {
      _handNo = widget.handNo;
      _seen.clear();
    }
    var launched = 0;
    for (final seat in widget.seats) {
      final before = _seen[seat.seatIndex] ?? 0;
      if (seat.occupied && seat.contributed > before) {
        _flights.add(
          _Flight(
            from: widget.centreOf(seat.seatIndex),
            startedAt: _now,
            // At the deal every seat posts at once; a short stagger keeps the
            // chips from arriving as one lump.
            delay: Duration(milliseconds: 70 * launched),
          ),
        );
        launched += 1;
      }
      _seen[seat.seatIndex] = seat.contributed;
    }
    if (_flights.isNotEmpty && !_ticker.isActive) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_flights.isEmpty) return const SizedBox.expand();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        for (final f in _flights)
          () {
            final elapsed = _now - f.startedAt - f.delay;
            if (elapsed.isNegative) return const SizedBox.shrink();
            final t = (elapsed.inMicroseconds / _travel.inMicroseconds).clamp(
              0.0,
              1.0,
            );
            final eased = Motion.travel.transform(t);
            // A shallow arc, so the chip is tossed rather than slid.
            final lift = math.sin(t * math.pi) * widget.size * 1.6;
            final pos =
                Offset.lerp(f.from, widget.pot, eased)! - Offset(0, lift);
            final fade = t > 0.82 ? (1 - t) / 0.18 : 1.0;
            return Positioned(
              left: pos.dx - widget.size / 2,
              top: pos.dy - widget.size / 2,
              child: Opacity(
                opacity: fade.clamp(0.0, 1.0),
                child: Transform.rotate(
                  angle: t * math.pi * 1.5,
                  child: PokerChip(colour: AppTheme.gold, size: widget.size),
                ),
              ),
            );
          }(),
      ],
    );
  }
}

/// Slides a gradient sideways without rebuilding it.
///
/// `GradientTransform` exists for exactly this: the shader is created from the
/// same gradient every frame and only its matrix changes, which is cheaper
/// than rebuilding stops and lets `shouldRepaint` stay a pure value compare.
class GradientTranslation extends GradientTransform {
  const GradientTranslation(this.dx);

  final double dx;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.identity()..translateByDouble(dx, 0, 0, 1);
}

/// The pot, breathing between hands and flaring when chips land on it.
///
/// Two different jobs in one widget, because they are two halves of the same
/// idea — that the middle of the table is alive.
///
/// The **breath** is a very slow gold bloom under the plinth, on a loop nobody
/// watches. It exists so that a table sitting between hands does not look like
/// a screenshot: an idle pot with no movement anywhere near it reads as a
/// frozen app rather than a quiet moment.
///
/// The **flare** fires only when the pot actually grows. It is the one moment
/// worth interrupting the breath for, and it is deliberately short — money
/// arriving should be noticed, not waited on. A pot that shrinks (a hand ends,
/// the next one starts at zero) gets nothing: that is not chips landing.
class _PotPulse extends StatefulWidget {
  const _PotPulse({required this.pot, required this.child});

  final int pot;
  final Widget child;

  @override
  State<_PotPulse> createState() => _PotPulseState();
}

class _PotPulseState extends State<_PotPulse> with TickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3600),
  )..repeat(reverse: true);

  late final AnimationController _flare = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  @override
  void didUpdateWidget(covariant _PotPulse old) {
    super.didUpdateWidget(old);
    if (widget.pot > old.pot) _flare.forward(from: 0);
  }

  @override
  void dispose() {
    _breath.dispose();
    _flare.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: Listenable.merge([_breath, _flare]),
      builder: (context, child) {
        // Ease out, so the flare is at its brightest the instant it starts and
        // spends the rest of its life fading — the shape money arriving has.
        final flare = Curves.easeOut.transform(1 - _flare.value);
        final breathe = Curves.easeInOut.transform(_breath.value);
        final live = _flare.isAnimating;

        return Transform.scale(
          // Barely more than one. At 1.06 the plate visibly jumps and the
          // number under it stops being readable mid-count.
          scale: live ? 1 + 0.035 * flare : 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.lg),
              boxShadow: [
                // The plinth set into the cloth (owner's brief, 25 Sep 2026:
                // "subtle gold glow, soft shadow, better integration with the
                // table surface"): a soft shadow a little below it, which
                // stands it on the table rather than over it ...
                BoxShadow(
                  color: AppTheme.ink900.withValues(alpha: dark ? 0.32 : 0.14),
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                  spreadRadius: -1,
                ),
                // ... and the gold it gives off: steadier than it was (0.05
                // at rest), so the pot always reads as the table's centre,
                // and still flaring when chips land.
                BoxShadow(
                  color: AppTheme.goldBright.withValues(
                    alpha: 0.08 + 0.04 * breathe + 0.24 * flare,
                  ),
                  blurRadius: 18 + 26 * flare,
                  spreadRadius: 1 + 6 * flare,
                ),
              ],
            ),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// The keys, gathered into the bottom-right corner instead of a bar.
///
/// Laid out as the owner asked (10 Sep 2026): Chaal on the bottom row with the
/// plus to its left and the minus to its right, and the sideshow key sitting
/// directly on top of Chaal.
///
/// Two things are here that were not in the brief, and both are deliberate.
///
/// **Pack**, above the sideshow key. It was not mentioned, and a table you
/// cannot fold at is not a table — leaving it out would have been reading the
/// instruction rather than the intent. It sits at the top of the stack because
/// it is the one key you never want under a thumb reaching for Chaal.
///
/// **No bet window.** The figure lives on the Chaal key itself, which already
/// showed it, so the separate readout the old bar carried would now be saying
/// the same number twice a centimetre apart.
class _ActionCluster extends StatelessWidget {
  const _ActionCluster();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;

    final live = state.myTurn;
    final options = state.options;
    final showCost = options?.show;
    final canSideshow = live && (options?.canSideshow ?? false);
    // A Force Sideshow has a sideshow's rules, and the server says so in an
    // option of its own. Whether the player can PAY is their own count — the
    // table never sees the wallet — so with no hammers the key is greyed but
    // still answers a tap, with an offer of the store.
    final canForce =
        live && (options?.canForceSideshow ?? false) && !state.forcingSideshow;
    final hasHammer = state.hasHammer;
    // Heads-up: a show is on offer, and a sideshow cannot be. One slot, two
    // jobs — a show needs exactly two players left and a sideshow three or
    // more, so they are never askable at the same moment.
    // Held back while a Force Sideshow's hammer is still in the air: the
    // loser has already been packed server-side, so the table turning heads-up
    // under the key would give away who lost before the hammer lands (QA 14
    // Sep 2026), as the fold itself is held back on the felt.
    final headsUp =
        live && showCost != null && showCost > 0 && !state.hammerLinkShown;

    final size = MediaQuery.sizeOf(context);
    final keyH = Dim.keyH(size.height);
    final keyW = Dim.keyW(size.width);
    final gap = TableSpace.gap(size.width);
    // The force key is as wide as the two steppers and the gap between them,
    // so the top row comes out exactly as wide as the − Chaal + row under it.
    // The cluster's footprint — which the viewer's hand and the right-hand
    // seat are laid out to clear — is the one it had with a single key on top.
    final forceW = 2 * Dim.minTouch + gap;

    return Padding(
      padding: EdgeInsets.fromLTRB(gap, gap, TableSpace.edge(size.width), gap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: t.forceSideshow,
                child: MachinedKey(
                  width: forceW,
                  height: keyH,
                  // The whole name beside the hammer Lottie, and nothing else
                  // (owner, 14 Sep 2026): no Material icon and no cost line —
                  // the confirmation says what it costs before anything is
                  // spent. The hammer swings only while the key can be used.
                  glyph: RepaintBoundary(
                    child: SizedBox.square(
                      dimension: 24,
                      child: Lottie.asset(
                        'assets/animations/Hammer.json',
                        animate: canForce,
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stack) =>
                            const Icon(Icons.hardware, size: 18),
                      ),
                    ),
                  ),
                  label: t.forceSideshow,
                  stackLabel: true,
                  alive: canForce && hasHammer,
                  muted: canForce && !hasHammer,
                  onPressed: canForce
                      ? () => _forceSideshow(context, state)
                      : null,
                ),
              ),
              SizedBox(width: gap),
              headsUp
                  ? MachinedKey(
                      width: keyW,
                      height: keyH,
                      icon: Icons.visibility_rounded,
                      label: t.show,
                      alive: true,
                      amount: formatChips(showCost),
                      onPressed: () => state.show(showCost),
                    )
                  // Dead by default: it wakes only on your turn, with three
                  // in the hand and both you and the player on your right
                  // holding seen cards. All of that is the server's
                  // judgement, arriving as canSideshow — a lit key that
                  // refuses on tap is worse than a dark one.
                  : MachinedKey(
                      width: keyW,
                      height: keyH,
                      icon: Icons.compare_arrows_rounded,
                      label: t.sideshow,
                      amount: canSideshow ? options?.sideshowWith : null,
                      alive: canSideshow,
                      onPressed: canSideshow ? state.askSideshow : null,
                    ),
            ],
          ),
          SizedBox(height: gap),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              StepperKey(
                icon: Icons.remove_rounded,
                height: keyH,
                onPressed: state.canStepDown ? () => state.stepBet(-1) : null,
              ),
              SizedBox(width: gap),
              MachinedKey(
                width: keyW,
                height: keyH,
                icon: Icons.arrow_forward_rounded,
                label: t.chaal,
                // Dark when the player cannot pay the chaal, even on their own
                // turn (owner, 14 Sep 2026); the figure stays, so they can see
                // what it would take.
                alive: state.canChaal,
                amount: formatChips(state.betAmount),
                onPressed: state.canChaal ? state.bet : null,
                primary: true,
              ),
              SizedBox(width: gap),
              StepperKey(
                icon: Icons.add_rounded,
                height: keyH,
                onPressed: state.canStepUp ? () => state.stepBet(1) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Pack, alone in the bottom-left corner.
///
/// Everything else lives in the opposite corner. That is not symmetry for its
/// own sake: Chaal and the two steppers are pressed constantly and pack is
/// pressed once, irreversibly, and a fold landing under a thumb that was
/// reaching for a raise is the worst misclick this game has.
class _PackKey extends StatelessWidget {
  const _PackKey();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final size = MediaQuery.sizeOf(context);
    final canPack = state.myTurn && (state.options?.canPack ?? false);
    final gap = TableSpace.gap(size.width);

    return Padding(
      padding: EdgeInsets.fromLTRB(TableSpace.edge(size.width), gap, gap, gap),
      // The destructive key: its glyph, its name and its edge in the error
      // ink, and no glow — it gives the hand up, and is there to be found
      // rather than to beckon (KeyRole).
      child: MachinedKey(
        width: Dim.keyW(size.width),
        height: Dim.keyH(size.height),
        icon: Icons.close_rounded,
        label: state.t.pack,
        role: KeyRole.destructive,
        alive: canPack,
        onPressed: canPack ? state.pack : null,
      ),
    );
  }
}

/// Missile, standing on the Pack key in the bottom-left corner (owner,
/// 14 Sep 2026).
///
/// Lit on the viewer's turn when the server says a missile is allowed —
/// `you.canMissile`: three or more still in the hand, blind or seen alike.
/// Whether the player can PAY is their own count; with no missiles the key is
/// greyed but still answers a tap, with an offer of the store.
///
/// Its second line counts the missiles the player HOLDS (owner, 24 Sep 2026:
/// "Missile count is not updated in missile button when user have used that
/// missile" — it wrote the constant 1 a shot spends, so it read "1" for ever,
/// the only missile long gone). It reads `user.missile`, which the ack of a
/// fired missile sets ([GameState.fireMissile]) and a store purchase raises,
/// and this widget WATCHES GameState — every notify rebuilds it — so the
/// figure drops to 0 the moment the shot is acknowledged, with the player
/// still at the table.
class _MissileKey extends StatelessWidget {
  const _MissileKey();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final gap = TableSpace.gap(size.width);
    final canFire = state.canMissile && !state.firingMissile;
    final hasMissile = state.hasMissile;
    final held = state.user?.missile ?? 0;
    final t = state.t;

    return Padding(
      // Pack's own padding carries the gap between the two keys.
      padding: EdgeInsets.fromLTRB(TableSpace.edge(size.width), gap, gap, 0),
      child: Tooltip(
        message: t.missile,
        child: MachinedKey(
          width: Dim.keyW(size.width),
          height: Dim.keyH(size.height),
          glyph: _MissileGlyph(animate: canFire),
          label: t.missile,
          // Under its name, as Chaal carries its bet: the missiles the player
          // holds (owner, 24 Sep 2026 — the constant a shot spends before
          // that), and the chips a show would cost, which the server's rule
          // needs them to hold, not pay (owner, 14 Sep 2026).
          detail: (style) => _MissileLine(
            missiles: held,
            chips: state.missileChips,
            style: style,
          ),
          // SPECIAL (owner's brief, 25 Sep 2026): a move bought with
          // something collected, in the missile's own coral.
          role: KeyRole.special,
          edge: missileInkOn(theme.brightness),
          alive: canFire && hasMissile,
          muted: canFire && !hasMissile,
          onPressed: canFire ? () => _fireMissile(context, state) : null,
        ),
      ),
    );
  }
}

/// The Missile key's second line: the missiles the player holds and the chips
/// a shot needs them to hold, each beside its mark — the rocket the wallets
/// count missiles with, and a chip (owner, 14 Sep 2026).
///
/// The rocket's figure is the COUNT HELD, not the cost (owner, 24 Sep 2026:
/// the owner reads that figure as the missiles they have, and it stayed at
/// the 1 a shot spends after the only missile was fired). It is the same
/// number the wallet pill in the top-right corner shows, so the two can never
/// disagree; [GameState.hasMissile] still decides whether the key is muted.
/// A count wider than 1 scales down inside the key's own [FittedBox] rather
/// than growing it, so the key keeps its place on Pack.
class _MissileLine extends StatelessWidget {
  const _MissileLine({
    required this.missiles,
    required this.chips,
    required this.style,
  });

  final int missiles;
  final int chips;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final mark = (style.fontSize ?? 12) * 1.05;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          missileIcon,
          size: mark,
          color: missileInkOn(Theme.of(context).brightness),
        ),
        const SizedBox(width: 2),
        Text('$missiles', maxLines: 1, style: style),
        if (chips > 0) ...[
          const SizedBox(width: Space.sm),
          PokerChip(colour: AppTheme.gold, size: mark),
          const SizedBox(width: 3),
          Text(formatChips(chips), maxLines: 1, style: style),
        ],
      ],
    );
  }
}

/// The Missile key's glyph: `assets/animations/Missile.json`, flying in from
/// its corner on a loop while the key can be used — the second half of the
/// file, where the rocket is on its canvas — and resting in the middle of its
/// box while it cannot. A key that simply stopped would show frame 0, where the rocket
/// is still off the canvas — an empty key.
class _MissileGlyph extends StatefulWidget {
  const _MissileGlyph({required this.animate});

  final bool animate;

  @override
  State<_MissileGlyph> createState() => _MissileGlyphState();
}

class _MissileGlyphState extends State<_MissileGlyph>
    with SingleTickerProviderStateMixin {
  /// Made in initState, never lazily (CLAUDE.md §12.3).
  late final AnimationController _controller;

  /// [MissileArt.restFrame] as a share of the file, once it is known.
  double _rest = 0.95;

  /// [MissileArt.glyphLoopFrom] as a share of the file, and how long the file
  /// takes to play from there, once it is known.
  double _loopFrom = 0.5;
  Duration _loopPeriod = const Duration(seconds: 1);
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, value: _rest);
  }

  @override
  void didUpdateWidget(covariant _MissileGlyph old) {
    super.didUpdateWidget(old);
    if (old.animate != widget.animate) _apply();
  }

  void _apply() {
    if (!_loaded) return;
    if (widget.animate) {
      _controller.repeat(min: _loopFrom, max: 1, period: _loopPeriod);
    } else {
      _controller
        ..stop()
        ..value = _rest;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: 26,
        child: Lottie.asset(
          MissileArt.missileAsset,
          controller: _controller,
          fit: BoxFit.contain,
          onLoaded: (composition) {
            _controller.duration = composition.duration;
            _rest =
                ((MissileArt.restFrame - composition.startFrame) /
                        composition.durationFrames)
                    .clamp(0.0, 1.0);
            _loopFrom =
                ((MissileArt.glyphLoopFrom - composition.startFrame) /
                        composition.durationFrames)
                    .clamp(0.0, 1.0);
            _loopPeriod = composition.duration * (1 - _loopFrom);
            _loaded = true;
            _apply();
          },
          errorBuilder: (context, error, stack) =>
              const Icon(missileIcon, size: 18),
        ),
      ),
    );
  }
}

/// Fades its child in once the wild cards of the viewer's hand have had time
/// to turn ([WildTransform]): three cards staggered along the fan, after the
/// cards' own face-up flip. It keeps the child's box from the first frame, so
/// the column it stands in does not jump when the name appears.
class _AfterTheTurn extends StatefulWidget {
  const _AfterTheTurn({super.key, required this.child, this.turns = true});

  final Widget child;

  /// Whether any card of the hand is going to turn.
  final bool turns;

  @override
  State<_AfterTheTurn> createState() => _AfterTheTurnState();
}

class _AfterTheTurnState extends State<_AfterTheTurn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    final wait = widget.turns
        ? Motion.enter + WildTransform.turnFor + WildTransform.stagger * 2
        : Motion.enter;
    _c = AnimationController(
      vsync: this,
      duration: wait + const Duration(milliseconds: 260),
    )..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: CurvedAnimation(
      parent: _c,
      curve: const Interval(0.86, 1, curve: Curves.easeOut),
    ),
    child: widget.child,
  );
}

/// The viewer's hand name at a showdown — "Pair", "Colour", "Run".
///
/// Its own widget rather than SeatPod's, because the viewer's cards are not in
/// a pod: they are the fanned hand on the floor, and the label has to sit over
/// them at the size that hand is drawn rather than at pod scale.
class _OwnHandName extends StatelessWidget {
  const _OwnHandName({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xxs,
      ),
      decoration: BoxDecoration(
        color: AppTheme.plaque(theme.brightness).withValues(alpha: 0.86),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: AppTheme.hairlineColour(theme.brightness)),
      ),
      child: Text(
        name,
        maxLines: 1,
        style: TableType.handName(
          theme,
          colour: theme.brightness == Brightness.dark
              ? AppTheme.goldBright
              : AppTheme.goldDeep,
        ),
      ),
    );
  }
}

/// The Teen Patti table's rail: the shared [SideRail] under the name this
/// screen has always given it, which test/table_wallet_layout_test.dart finds
/// by that name. Its box is the rail's own.
class _SideRail extends StatelessWidget {
  const _SideRail({required this.onOpen});

  final void Function(LeftPanel) onOpen;

  @override
  Widget build(BuildContext context) => SideRail(onOpen: onOpen);
}
