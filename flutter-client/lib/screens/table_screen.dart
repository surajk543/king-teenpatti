import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../settings/feedback_settings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../widgets/buy_chips.dart';
import '../widgets/drifting_chips.dart';
import '../widgets/feedback_toggles.dart';
import '../widgets/fireworks.dart';
import '../widgets/glass_panels.dart';
import '../widgets/playing_card.dart';
import '../widgets/poker_chip.dart';
import '../widgets/premium_surface.dart';
import '../widgets/rules_sheet.dart';
import '../widgets/seat_pod.dart';
import '../widgets/table_ground.dart';

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
/// is a solid [_Plate].
///
/// **Anything that sits on the cloth is a dark plate with light ink, in both
/// brightnesses**, because the cloth is dark emerald in both. Only the chrome
/// standing on the ground — the rail, the console, the drawers — follows the
/// theme.
/// Which of the two panels the left drawer is showing.
enum _LeftPanel { menu, chat }

class TableScreen extends StatefulWidget {
  const TableScreen({super.key});

  @override
  State<TableScreen> createState() => _TableScreenState();
}

class _TableScreenState extends State<TableScreen> {
  /// The menu and the chat share one drawer rather than being a drawer and a
  /// sheet: both are "the panel behind the left edge", and a Scaffold has only
  /// one of those. Which one is showing is decided before it opens.
  _LeftPanel _panel = _LeftPanel.menu;

  /// Opening is driven from the rail, which sits inside this Scaffold, so the
  /// state is reached by key rather than by looking up an ancestor. The key
  /// lives on the game state so the back gesture can close the drawer too.
  GlobalKey<ScaffoldState> get _scaffold =>
      context.read<GameState>().tableScaffold;

  void _open(_LeftPanel panel) {
    if (panel == _LeftPanel.chat) context.read<GameState>().markChatRead();
    setState(() => _panel = panel);
    _scaffold.currentState?.openDrawer();
  }

  @override
  Widget build(BuildContext context) {
    // This widget subscribes to nothing itself: the game state ticks once a
    // second for the reward countdown, and rebuilding the Scaffold tears an
    // open drawer down with it. Everything inside subscribes for itself.
    return Scaffold(
      key: _scaffold,
      drawer: _panel == _LeftPanel.menu
          ? const _TableDrawer()
          : const _ChatDrawer(),
      body: Stack(
        children: [
          // The room the table stands in — charcoal floor, one warm pool where
          // the lamp hangs, corners closed by a vignette. It is painted behind
          // the cutout as well as inside it, so the screen has no seam.
          const Positioned.fill(child: _RoomGround()),
          const _TurnBuzzer(),
          // Chips crossing the room the table sits in, from whichever
          // direction each one runs. They live in the margin around the felt —
          // the only part of this screen with nothing in it — so the room reads
          // as somewhere a game is happening rather than as a blank ground.
          // Behind everything and untouchable.
          const Positioned.fill(
            child: IgnorePointer(child: DriftingChips(strength: 2.6)),
          ),
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
                const _MissedTurnsStrip(),
                const _ActionConsole(),
              ],
            ),
          ),
          // Top right, which is the one corner of the felt nothing else uses:
          // the menu and chat are down the left edge, the seats sit around the
          // rim, and the category tag is centred above the pot.
          const Positioned(
            top: Space.sm,
            right: Space.md,
            child: SafeArea(child: BuyChipsButton(compact: true)),
          ),
        ],
      ),
    );
  }
}

/// The floor of the room, carrying a whisper of the table's own colour.
///
/// Its own widget so that the once-a-second tick of the game state rebuilds
/// four widgets rather than the Scaffold — a Scaffold rebuild tears down an
/// open drawer mid-gesture. The painter behind it compares every input, so a
/// rebuild that changes nothing costs no raster at all.
class _RoomGround extends StatelessWidget {
  const _RoomGround();

  @override
  Widget build(BuildContext context) {
    // `select`, not `watch`: the ground is tinted by which table this is, and
    // that changes when the player changes table — not sixty times a minute
    // with the reward ticker. A record compares by value, so this rebuilds
    // only when the pair actually differs.
    final table = context.select<GameState, ({String category, int boot})?>((
      s,
    ) {
      final room = s.room;
      return room == null
          ? null
          : (category: room.category, boot: room.bootAmount);
    });

    return TableGround(
      accent: table == null
          ? null
          : AppTheme.paletteFor(
              Theme.of(context).colorScheme,
              category: table.category,
              bootAmount: table.boot,
            ).accent,
      child: const SizedBox.expand(),
    );
  }
}

/// The only chrome in the game room: the menu, and the chat below it, stacked
/// down the left edge.
///
/// Everything else that used to sit across the top — the table code, the
/// category, the hand number — is in the drawer. None of it changed what a
/// player does next, and a rail costs width, which a landscape screen has, in
/// place of height, which it does not.
class _SideRail extends StatelessWidget {
  const _SideRail({required this.onOpen});

  final void Function(_LeftPanel) onOpen;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final size = MediaQuery.sizeOf(context);
    final t = state.t;

    // The key fills the rail rather than being inset into it, so the target is
    // the whole column: 48.0x46.8 at 640x360, 54.0x53.4 at 891x411 and
    // 54.0x56.0 at 1280x800 — every one of them past the 44dp minimum, which
    // an inset key would not have been at the rail's 48dp floor.
    final railW = Dim.railW(size.width);
    final keyH = Dim.railButtonH(size.height);

    return SizedBox(
      width: railW,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _RailKey(
              tooltip: t.tableMenu,
              width: railW,
              height: keyH,
              onTap: () => onOpen(_LeftPanel.menu),
              child: const Icon(Icons.menu_rounded, size: 22),
            ),
            const SizedBox(height: Space.md),
            Badge(
              isLabelVisible: state.unreadChat > 0,
              backgroundColor: AppTheme.gold,
              textColor: AppTheme.ink900,
              label: Text('${state.unreadChat}'),
              child: _RailKey(
                // While the cooldown runs the icon becomes the countdown, so
                // the player can see when they may speak again without opening
                // the chat to find out.
                tooltip: state.canChat
                    ? t.tableChat
                    : '${t.tableChat} ${state.chatCooldownLeft}s',
                width: railW,
                height: keyH,
                onTap: () => onOpen(_LeftPanel.chat),
                child: state.canChat
                    ? const Icon(Icons.forum_rounded, size: 22)
                    : _ChatCountdown(
                        left: state.chatCooldownLeft,
                        total: GameState.chatCooldown.inSeconds,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One key in the rail: a tinted panel with a glyph in it.
class _RailKey extends StatelessWidget {
  const _RailKey({
    required this.tooltip,
    required this.width,
    required this.height,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final double width;
  final double height;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: width,
        height: height,
        child: IconTheme.merge(
          data: IconThemeData(
            color: theme.colorScheme.onSurface.withValues(
              alpha: AppTheme.inkMed,
            ),
          ),
          child: GlassCapsule(
            radius: Radii.md,
            padding: EdgeInsets.zero,
            minHeight: height,
            onTap: onTap,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}

/// The table menu. Leaving lives here rather than as a button on the console,
/// where it sat one stray tap away from the action controls.
class _TableDrawer extends StatelessWidget {
  const _TableDrawer();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final t = state.t;

    final room = state.room;
    if (room == null) {
      return const GlassDrawerPanel(
        padding: EdgeInsets.zero,
        child: SizedBox.expand(),
      );
    }
    final you = room.you;
    final scheme = theme.colorScheme;

    return GlassDrawerPanel(
      padding: EdgeInsets.zero,
      // The panel is laid out by an Align, which hands its child loose
      // constraints; a ListView under those has no height to scroll in.
      child: SizedBox.expand(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: Space.md),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                0,
                Space.sm,
                Space.md,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Table ${room.code}',
                          style: AppTheme.money(
                            theme.textTheme.titleMedium ?? const TextStyle(),
                          ),
                        ),
                        Text(
                          // The category is server-owned ASCII, so tracked
                          // capitals are safe on it; the hand number is not
                          // translated either.
                          '${room.category.toUpperCase()}  ·  hand ${room.handNo}',
                          style: AppTheme.smallCaps(
                            theme.textTheme.labelSmall ?? const TextStyle(),
                            colour: scheme.onSurface.withValues(
                              alpha: AppTheme.inkLow,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            _MenuRow(
              icon: Icons.swap_horiz_rounded,
              leading: state.switching
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              label: t.switchTable,
              note: '${t.switchTable} · ${room.category}',
              onTap: state.switching
                  ? null
                  : () async {
                      Navigator.pop(context);
                      await _confirmSwitch(context, state, room);
                    },
            ),
            const _MenuRule(),
            _MenuRow(
              icon: Icons.logout_rounded,
              label: t.leaveTable,
              note: t.joinAnother,
              tone: scheme.error,
              onTap: () async {
                // Close the menu first, so the dialog is not stacked on top of
                // a drawer that is still sliding.
                Navigator.pop(context);
                await _confirmLeave(context, state, room);
              },
            ),
            const _MenuRule(),
            _MenuRow(
              icon: Icons.savings_outlined,
              label: t.yourChips,
              value: formatChips(you?.chips ?? state.user?.chips ?? 0),
            ),
            _MenuRow(
              icon: Icons.paid_outlined,
              label: t.boot,
              value: formatChips(room.bootAmount),
            ),
            if (room.maxPot > 0)
              _MenuRow(
                icon: Icons.trending_up_rounded,
                label: t.maxPot,
                value: formatChips(room.maxPot),
              ),
            const _MenuRule(),
            _MenuRow(
              icon: Icons.menu_book_outlined,
              label: t.rules,
              onTap: () {
                Navigator.pop(context);
                showRules(context);
              },
            ),
            // The same two switches the lobby has, from the same widget. A
            // player who wants the phone quiet wants it quiet NOW, at the
            // table, not after leaving one.
            const FeedbackToggles(),
            _MenuRow(
              icon: state.themeMode == ThemeMode.dark
                  ? Icons.light_mode_outlined
                  : Icons.dark_mode_outlined,
              label: state.themeMode == ThemeMode.dark
                  ? t.dayMode
                  : t.nightMode,
              onTap: state.toggleTheme,
            ),
          ],
        ),
      ),
    );
  }
}

/// One hairline between groups of menu rows.
class _MenuRule extends StatelessWidget {
  const _MenuRule();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: Space.lg,
      vertical: Space.sm,
    ),
    child: SizedBox(
      height: Dim.hairline,
      child: ColoredBox(
        color: AppTheme.hairlineColour(Theme.of(context).brightness),
      ),
    ),
  );
}

/// A row in the table menu: a glyph, what it is, and either its figure or the
/// consequence of tapping it.
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.value,
    this.note,
    this.onTap,
    this.tone,
    this.leading,
  });

  final IconData icon;
  final String label;

  /// The figure on the right of a row that only reports something.
  final String? value;

  /// The second line under a row that does something.
  final String? note;
  final VoidCallback? onTap;

  /// A row whose action costs something wears the scheme's error colour.
  final Color? tone;

  /// Replaces the glyph while an action is in flight.
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ink = tone ?? scheme.onSurface;

    final body = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child:
                leading ??
                Icon(
                  icon,
                  size: 18,
                  color: ink.withValues(
                    alpha: tone == null ? AppTheme.inkMed : AppTheme.inkHigh,
                  ),
                ),
          ),
          const SizedBox(width: Space.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: AppTheme.label(
                    theme.textTheme.bodyLarge ?? const TextStyle(),
                    colour: ink,
                  ),
                ),
                if (note != null)
                  Text(
                    note!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: ink.withValues(alpha: AppTheme.inkLow),
                    ),
                  ),
              ],
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: Space.md),
            Text(
              value!,
              style: AppTheme.money(
                theme.textTheme.titleSmall ?? const TextStyle(),
                colour: _goldInk(theme.brightness),
              ),
            ),
          ],
        ],
      ),
    );

    if (onTap == null) {
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Dim.minTouch),
        child: body,
      );
    }

    return InkWell(
      // Material's own click, gated on the player's Sound switch —
      // otherwise a silenced game would still tick on every tap.
      enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Dim.minTouch),
        child: body,
      ),
    );
  }
}

/// The two keys a dialog closes on: the quiet one, then the one that acts.
List<Widget> _dialogActions(
  BuildContext context, {
  required String stay,
  required String go,
}) => [
  TextButton(onPressed: () => Navigator.pop(context, false), child: Text(stay)),
  FilledButton(
    onPressed: () => Navigator.pop(context, true),
    style: FilledButton.styleFrom(
      minimumSize: const Size(120, Dim.minTouch),
      backgroundColor: AppTheme.gold,
      foregroundColor: AppTheme.ink900,
    ),
    child: Text(go),
  ),
];

/// The title line of a table dialog: a glyph and the question, side by side.
Widget _dialogTitle(BuildContext context, IconData icon, String text) {
  final theme = Theme.of(context);

  return Row(
    children: [
      Icon(icon, size: 20, color: _goldInk(theme.brightness)),
      const SizedBox(width: Space.md),
      Expanded(
        child: Text(
          text,
          style: AppTheme.label(
            theme.textTheme.titleMedium ?? const TextStyle(),
          ),
        ),
      ),
    ],
  );
}

/// Switching is confirmed too. It gives up the seat at this table, and mid-hand
/// that costs the player their stake, so it is not something to do by accident.
Future<void> _confirmSwitch(
  BuildContext context,
  GameState state,
  RoomState room,
) async {
  final midHand =
      room.state == TableState.betting && room.you?.status == SeatState.active;

  // Taken before the first await: after it, `context` may be gone. The
  // Navigator carries the overlay the veil is inserted into, and that overlay
  // outlives every route below it.
  final navigator = Navigator.of(context, rootNavigator: true);

  final go = await showDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: _dialogTitle(
        context,
        Icons.swap_horiz_rounded,
        state.t.switchTableQ,
      ),
      content: Text(midHand ? state.t.switchMidHand : state.t.switchIdle),
      actions: _dialogActions(
        context,
        stay: state.t.stay,
        go: state.t.switchAction,
      ),
    ),
  );

  if (go != true) return;
  // No `context.mounted` guard here, and that is deliberate. This is reached
  // from a drawer row that pops itself before calling, so by now that element
  // is unmounted and the check was returning early every single time — which
  // is why the veil never appeared. Nothing below touches `context`: the
  // overlay comes from the navigator captured above, and the switch is a call
  // on GameState.

  // A held beat, but only once the move has actually happened.
  //
  // The veil used to go up the moment the player confirmed, which meant it
  // also went up when the switch was refused — "no other table at this stake
  // has a free seat" arrived behind half a second of a spinner, which reads as
  // the app having tried and failed rather than as an answer. So the switch
  // runs first, and the veil only covers the swap that follows it.
  //
  // Success is "am I somewhere else now": GameState reports a refusal as a
  // notice rather than a throw, and the room it holds is the only thing that
  // tells the two apart.
  final before = state.room?.roomId;
  await state.switchTable();
  if (state.room?.roomId == before) return;

  final entry = OverlayEntry(builder: (_) => const _SwitchingVeil());
  navigator.overlay?.insert(entry);
  try {
    // Half a second. Long enough that the new table arriving is an event,
    // short enough that nobody waits for it.
    await Future<void>.delayed(const Duration(milliseconds: 500));
  } finally {
    entry.remove();
  }
}

/// The veil shown while a table switch is in flight.
///
/// Deliberately says what is happening rather than showing a bare spinner: the
/// player asked to move, and "finding a seat" is the answer to what the wait
/// is for.
class _SwitchingVeil extends StatelessWidget {
  const _SwitchingVeil();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.read<GameState>().t;

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.42),
      child: Center(
        child: PremiumGlassPanel(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.xxl,
            vertical: Space.xl,
          ),
          mode: GlassMode.blurred,
          radius: Radii.lg,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation(AppTheme.gold),
                ),
              ),
              const SizedBox(width: Space.lg),
              Text(
                t.switchTable,
                style: AppTheme.smallCaps(
                  theme.textTheme.titleSmall!,
                  colour: AppTheme.onFelt(
                    theme.brightness,
                    alpha: AppTheme.inkHigh,
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

/// Requirement 25: leaving is confirmed first, and the wording changes when a
/// hand is live — that is when walking away actually costs something.
Future<void> _confirmLeave(
  BuildContext context,
  GameState state,
  RoomState room,
) async {
  final midHand =
      room.state == TableState.betting && room.you?.status == SeatState.active;

  final leave = await showDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: _dialogTitle(context, Icons.logout_rounded, state.t.leaveTableQ),
      content: Text(midHand ? state.t.leaveMidHand : state.t.leaveAnytime),
      actions: _dialogActions(context, stay: state.t.stay, go: state.t.leave),
    ),
  );

  if (leave == true) state.leaveTable();
}

/// Gold as *ink*: champagne on charcoal, deep gold on parchment.
///
/// Anything drawn on the cloth is always on charcoal, so it asks for
/// [AppTheme.goldBright] directly; this is for the chrome that follows the
/// theme.
Color _goldInk(Brightness b) =>
    b == Brightness.dark ? AppTheme.goldBright : AppTheme.goldDeep;

class _Felt extends StatelessWidget {
  const _Felt();

  /// Where each seat sits on the felt, as a fraction of it, in view order:
  /// the viewer at the bottom, then clockwise from their left.
  /// A seat's column is pod, then cards, then its bet chip — about half the
  /// felt's height in all — so the top pair sit well clear of the rim or their
  /// names are clipped off by it.
  static const List<Offset> _places = [
    Offset(0.335, 0.00), // you — x only; the pair below sit on the floor
    Offset(0.090, 0.42), // left
    Offset(0.260, 0.28), // top left
    Offset(0.740, 0.28), // top right
    Offset(0.910, 0.42), // right
  ];

  /// Where the middle of the pot is, as a fraction of the felt's height.
  ///
  /// One number, read by the plinth, by the chips flying into it and by the
  /// pot leaving for the winner. They used to be three different numbers —
  /// 0.30, 0.26 and 0.26 — so a bet landed a little above the pile it was
  /// joining.
  static const double _potDy = 0.27;

  /// Where a seat sits on the felt, given its index as the server numbers it.
  ///
  /// The table is drawn from the viewer's chair, so a server index has to be
  /// rotated into view order first — the viewer is always view seat 0, at the
  /// bottom, and that one stands on the floor rather than being centred.
  static Offset _seatCentre(
    GameState state,
    int seatIndex,
    double w,
    double h,
    double podW,
  ) {
    final total = state.config.maxPlayers == 0 ? 5 : state.config.maxPlayers;
    final mine = state.room?.you?.seatIndex ?? 0;
    final view = (seatIndex - mine + total * 2) % total;

    if (view == 0) return Offset(_places[0].dx * w, h * 0.84);
    final place = _places[view % _places.length];
    return Offset(place.dx * w, place.dy * h);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);

    final room = state.room;
    if (room == null) return const Center(child: CircularProgressIndicator());

    final seats = state.seatsInViewOrder();
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
    final handLive =
        room.state == TableState.betting ||
        room.state == TableState.showdown ||
        state.showdown.isNotEmpty ||
        state.showdownResult.isNotEmpty;

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

          Widget pod(int viewIndex) {
            final s = viewIndex < seats.length ? seats[viewIndex] : null;
            // At a showdown the hand is drawn at the seat that played it, so
            // find this seat's reveal and hand it down. The server sends
            // reveals for the players still in the hand; everyone else keeps
            // their backs.
            final reveal = s == null
                ? null
                : state.showdown.where((r) => r.userId == s.userId).firstOrNull;

            return SeatPod(
              revealed: reveal?.cards,
              revealedHand: reveal?.handName,
              seat: s,
              isMe: s?.userId != null && s!.userId == state.user?.id,
              isDealer: s?.seatIndex == room.dealerSeat,
              onTurn: onTurn(s),
              progress: onTurn(s) ? progress : null,
              deadlineMs: room.turn?.deadline ?? 0,
              totalMs: room.turnTimeoutMs,
              chipsHidden: room.chipsHidden,
              handLive: handLive,
              width: podW,
              avatarUrl: state.absoluteUrl(s?.avatarUrl),
              saying: s?.userId == null
                  ? null
                  : state.saidRecently[s!.userId]?.text,
              // A bubble opens towards the middle of the table: seats on the
              // left speak to the right, seats on the right to the left, and
              // the viewer's own words go up over their pod.
              bubbleSide: viewIndex == 0
                  ? BubbleSide.above
                  : viewIndex <= 2
                  ? BubbleSide.right
                  : BubbleSide.left,
              // The bottom seat stacks upwards, or its chip runs off the felt.
              reversed: viewIndex == 0,
            );
          }

          // Positioned by centre, so a seat stays put as its own column grows
          // and shrinks with the hand — but never past either edge, which is
          // what clipped the outermost seat on a narrow screen.
          Widget at(Offset place, Widget child, {double? width}) {
            final box = width ?? podW;
            final left = (place.dx * w - box / 2)
                .clamp(0.0, math.max(0.0, w - box))
                .toDouble();

            return Positioned(
              left: left,
              top: place.dy * h,
              width: box,
              child: FractionalTranslation(
                translation: const Offset(0, -0.5),
                child: child,
              ),
            );
          }

          // The room takes its colour from the table you sat down at, so a
          // blind table and a seen one are told apart at a glance — and the
          // room matches the lobby card you tapped to get here. A bigger stake
          // tints deeper, so the two stakes differ as well. The identity lives
          // in the rail around the cloth, not in the cloth: baize is emerald,
          // whatever the stake.
          final palette = AppTheme.paletteFor(
            theme.colorScheme,
            category: room.category,
            bootAmount: room.bootAmount,
          );
          final potCentre = Offset(0.5 * w, _potDy * h);
          Offset seatCentre(int seatIndex) =>
              _seatCentre(state, seatIndex, w, h, podW);

          return _FeltCloth(
            palette: palette,
            radius: h / 2,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // The overhead lamp, breathing slowly over the middle of the
                // cloth, so the felt is never a flat wash. Its own layer: it
                // repaints every frame for the life of the room, and the cloth
                // beneath it never does.
                const Positioned.fill(
                  child: RepaintBoundary(
                    child: IgnorePointer(child: _AmbientLamp()),
                  ),
                ),
                // Every bet is seen to travel: a chip leaves the seat that made
                // it and lands on the pot. Boundaried for the same reason.
                // The deal, drawn before the bets so a boot chip lands on a
                // seat that has already been given its cards.
                Positioned.fill(
                  child: RepaintBoundary(
                    child: IgnorePointer(
                      child: _DealFlights(
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
                // The table's furniture first, the seats after it: a seat's
                // speech bubble or bet chip is a moment that matters more
                // than the tag or the pot label it might briefly cross, so
                // the seats paint on top.
                at(
                  const Offset(0.5, 0.075),
                  _CategoryTag(room: room),
                  width: w * 0.30,
                ),
                // Narrower than the tag above it: the plinth has an edge now,
                // and at a third of the felt that edge ran under the top-left
                // pod on a 640dp phone.
                at(
                  const Offset(0.5, _potDy),
                  _Pot(room: room, chipSize: (podW * 0.22).clamp(14.0, 26.0)),
                  width: w * 0.30,
                ),
                at(
                  const Offset(0.5, 0.44),
                  _Status(room: room),
                  width: w * 0.4,
                ),

                for (var i = 1; i < _places.length; i++) at(_places[i], pod(i)),

                // The viewer's pod and hand stand on the floor of the table
                // rather than being centred on a point: their columns are
                // different heights, so centring both left one hanging over the
                // rim and clipped by it. A shared bottom line keeps them inside
                // and flush with the edge.
                Positioned(
                  left: _places[0].dx * w - podW / 2,
                  bottom: h * 0.035,
                  width: podW,
                  child: pod(0),
                ),
                Positioned(
                  left: _places[0].dx * w + podW / 2 + Space.md,
                  bottom: h * 0.035,
                  child: _OwnHand(cardHeight: handH),
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

                // Only the player being asked gets the buttons.
                if (state.sideshowIsForMe)
                  Positioned.fill(child: _SideshowPrompt(state: state)),

                // And only the two of them ever see the hands. The winner's
                // banner wins any race between the two.
                if (state.sideshowReveal != null &&
                    state.showdown.isEmpty &&
                    state.showdownResult.isEmpty)
                  Positioned.fill(
                    child: _SideshowRevealPanel(reveal: state.sideshowReveal!),
                  ),

                if (state.showdown.isNotEmpty ||
                    state.showdownResult.isNotEmpty)
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
                          : _PotToWinner(
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
            ),
          );
        },
      ),
    );
  }
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

/// The engraved plate everything on the cloth is mounted on.
///
/// The cloth is dark emerald in both brightnesses, so a plate standing on it is
/// dark in both too, with light ink — a theme-following panel here would be a
/// white card on a green table in the morning.
class _Plate extends StatelessWidget {
  const _Plate({
    required this.child,
    required this.padding,
    this.accent,
    this.radius = Radii.sm,
    this.borderWidth = Dim.hairline,
    this.opacity = 0.46,
    this.elevation = 2,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// The colour of the plate's edge. Champagne when nothing else is said.
  final Color? accent;
  final double radius;
  final double borderWidth;

  /// How solid the plate is over the cloth.
  final double opacity;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    final edge = accent ?? AppTheme.goldBright.withValues(alpha: 0.30);
    final corner = BorderRadius.circular(radius);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corner,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppTheme.ink800.withValues(alpha: opacity * 0.88),
            AppTheme.ink900.withValues(alpha: opacity),
          ],
        ),
        border: Border.all(color: edge, width: borderWidth),
        boxShadow: AppTheme.controlShadow(
          Brightness.dark,
          elevation: elevation,
        ),
      ),
      child: ClipRRect(
        borderRadius: corner,
        child: Stack(
          children: [
            Padding(padding: padding, child: child),
            // The light catching the plate's top edge, which is what makes it
            // read as engraved metal rather than a translucent rectangle.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: Dim.hairline,
              child: IgnorePointer(
                child: ColoredBox(color: Colors.white.withValues(alpha: 0.07)),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
    final t = context.watch<GameState>().t;
    final blind = room.category == TableCategory.blind;
    final palette = AppTheme.paletteFor(
      theme.colorScheme,
      category: room.category,
      bootAmount: room.bootAmount,
    );

    return Center(
      child: _Plate(
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
            // whether this player sees their own cards at all.
            Icon(palette.icon, size: 14, color: palette.accent),
            const SizedBox(width: Space.sm),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  // The category and the stake together: "Blind · 5,000"
                  // names the table, and the colour behind it is the table's
                  // own. It shrinks on a small screen rather than losing its
                  // stake to an ellipsis. The category word is translated, so
                  // it keeps its natural case — tracked capitals are a no-op on
                  // Devanagari and would only mismatch the tracking beside it.
                  '${blind ? t.blind : t.seen} · ${formatChips(room.bootAmount)}',
                  maxLines: 1,
                  style: AppTheme.label(
                    theme.textTheme.labelMedium ?? const TextStyle(),
                    colour: AppTheme.goldBright.withValues(alpha: 0.92),
                    weight: FontWeight.w700,
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

/// How many turns this player has let run out, how many blind bets they have
/// left, and what happens if they let one more turn go.
///
/// Missing a turn is not obviously a countable thing while it is happening —
/// the hand simply carries on without you — so the count is stated, and the
/// last one is stated loudly. It is shown to nobody else: the server sends the
/// figure only to the player it concerns.
///
/// Requirement 31, kept where the thumb already is: the count of turns
/// auto-packed in a row sits over the Pack key, bottom left, and stays put at
/// zero too, so the player can always see how the table is scoring them.
///
/// It takes no height of its own — it is drawn upward over the bottom-left
/// corner of the felt, which nothing else uses — so the keys never shift under
/// a hand as the count changes.
class _MissedTurnsStrip extends StatelessWidget {
  const _MissedTurnsStrip();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final room = state.room;
    final you = room?.you;
    if (room == null || you == null) return const SizedBox.shrink();

    // Blind moves are only a live question while the player is still blind
    // and still in the hand; once they look, the row goes and the missed
    // count settles back on its own.
    final showBlind =
        you.isBlind &&
        you.status == SeatState.active &&
        room.state == TableState.betting;
    final maxBlind =
        state.config.tables
            .where(
              (t) =>
                  t.category == room.category &&
                  t.bootAmount == room.bootAmount,
            )
            .map((t) => t.maxBlindMoves)
            .firstOrNull ??
        4;

    // The corner the cluster lives in is only as wide as the gap between the
    // felt's left edge and the viewer's pod, so its width is derived from the
    // very same figures the felt lays that pod out with — rail, felt padding,
    // console height, the pod formula — rather than from a share of the screen,
    // which runs under the pod on a tablet.
    final size = MediaQuery.sizeOf(context);
    final inset = MediaQuery.paddingOf(context);
    final screenW = size.width;
    final railW = Dim.railW(screenW);
    final feltPad = Dim.feltPad(screenW);
    final feltW = screenW - inset.horizontal - railW - 2 * feltPad;
    final feltH =
        size.height - inset.vertical - _consoleBlock(size.height) - Space.xxs;
    final podW = Dim.podW(feltW, feltH);
    final left = railW + feltPad;
    final podLeft = left + _Felt._places[0].dx * feltW - podW / 2;
    // Space.xl of clear felt between the cluster's edge and the pod, shadows
    // included: 127.3 wide at 640x360, 200.1 at 891x411, 301.3 at 1280x800.
    final maxW = (podLeft - left - Space.xl).clamp(110.0, 360.0);
    // One line and no explanation where there is no room for two.
    final compact = Breaks.isCompact(screenW) || Breaks.isShort(size.height);

    return SizedBox(
      height: 0,
      width: double.infinity,
      child: OverflowBox(
        alignment: Alignment.bottomLeft,
        minHeight: 0,
        maxHeight: 120,
        child: Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: EdgeInsets.only(left: left, bottom: Space.xs),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW),
              child: _Plate(
                radius: Radii.md,
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.md,
                  vertical: Space.sm,
                ),
                accent: you.onLastWarning
                    ? Theme.of(
                        context,
                      ).colorScheme.error.withValues(alpha: 0.75)
                    : null,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showBlind) ...[
                      _BlindMoves(left: you.blindMovesLeft, max: maxBlind),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: Space.sm),
                        child: _ClusterRule(),
                      ),
                    ],
                    _MissedTurns(you: you, compact: compact),
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

/// What the console and its surround take out of the screen's height.
///
/// 71.6 of 360, 80.3 of 411, 88.0 of 800 — the figure the felt is left with,
/// and the one the instrument cluster has to reproduce to know where the
/// viewer's pod ends up.
double _consoleBlock(double h) => Dim.consoleH(h) + Space.xs + Space.sm;

/// A hairline between the cluster's two rows.
class _ClusterRule extends StatelessWidget {
  const _ClusterRule();

  @override
  Widget build(BuildContext context) => SizedBox(
    height: Dim.hairline,
    child: ColoredBox(color: AppTheme.goldBright.withValues(alpha: 0.14)),
  );
}

/// How many bets this player may still make without looking at their cards,
/// as pips rather than a fraction: on a 25-second clock a row of dots is read
/// at a glance and "3/4" is read twice.
class _BlindMoves extends StatelessWidget {
  const _BlindMoves({required this.left, required this.max});

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
      // A private table sets its own allowance, so the row of pips shrinks to
      // the plate rather than running off it.
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.visibility_off_outlined,
              size: 15,
              color: AppTheme.boneInk.withValues(alpha: AppTheme.inkLow),
            ),
            const SizedBox(width: Space.md),
            for (var i = 0; i < max; i++)
              Padding(
                padding: const EdgeInsets.only(right: Space.xs),
                child: _Pip(
                  filled: i < left,
                  colour: lastOne ? AppTheme.amber : AppTheme.goldBright,
                ),
              ),
          ],
        ),
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

class _MissedTurns extends StatefulWidget {
  const _MissedTurns({required this.you, this.compact = false});
  final You you;

  /// One line only, for a screen with no room for the explanation.
  final bool compact;

  @override
  State<_MissedTurns> createState() => _MissedTurnsState();
}

class _MissedTurnsState extends State<_MissedTurns>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _MissedTurns old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Only the final warning breathes, and only then does the controller run.
  /// A controller left repeating schedules a frame for ever, and below the last
  /// warning this is information — information that pulses is just noise.
  void _sync() {
    final last = widget.you.onLastWarning;
    if (last && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!last && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.watch<GameState>().t;

    final missed = widget.you.missedTurns;
    final limit = widget.you.maxMissedTurns;
    final last = widget.you.onLastWarning;
    // Anything above zero is a mark against the seat; the mark warms up with
    // the count and turns red for the final warning.
    final marked = missed > 0 && !last;

    final foreground = last
        ? scheme.error
        : marked
        ? AppTheme.amber
        : AppTheme.boneInk.withValues(alpha: AppTheme.inkMed);

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          last ? Icons.warning_amber_rounded : Icons.timer_off_outlined,
          size: last ? 20 : 15,
          color: foreground,
        ),
        const SizedBox(width: Space.md),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  // "Missed turns 1/3" — the count is the whole point, so
                  // it is always there, even at 0/3.
                  '${last ? t.lastWarning : t.missedTurnsLabel} $missed/$limit',
                  maxLines: 1,
                  style: AppTheme.money(
                    theme.textTheme.labelMedium ?? const TextStyle(),
                    colour: foreground,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              if (last && !widget.compact)
                Text(
                  t.missOneMore,
                  // Two lines when the corner is narrow, rather than an
                  // explanation cut off mid-sentence.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppTheme.boneInk.withValues(alpha: AppTheme.inkMed),
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    if (!last) return row;

    // The alpha breathes and the blur does not: animating a blur radius
    // regenerates the shadow's mask on every frame, while animating the alpha
    // reuses one cached mask and looks the same at this size.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.xs),
            boxShadow: [
              BoxShadow(
                color: scheme.error.withValues(
                  alpha: 0.18 + 0.26 * Motion.breathe.transform(_pulse.value),
                ),
                blurRadius: 12,
                spreadRadius: 1,
              ),
            ],
          ),
          child: child,
        ),
        child: row,
      ),
    );
  }
}

/// The pot travelling to whoever won it.
///
/// A row of chips leaves the middle of the table and lands on the winner's
/// seat, one after another. It runs once — the pot moves once — and the arc
/// carries them wide of the straight line, so a handful of chips reads as a
/// pile being pushed across rather than a swarm.
class _PotToWinner extends StatefulWidget {
  const _PotToWinner({
    super.key,
    required this.from,
    required this.to,
    required this.size,
  });

  final Offset from;
  final Offset to;
  final double size;

  @override
  State<_PotToWinner> createState() => _PotToWinnerState();
}

class _PotToWinnerState extends State<_PotToWinner>
    with SingleTickerProviderStateMixin {
  static const int _chips = 9;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1700),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The bow in the flight path, at right angles to it.
    final line = widget.to - widget.from;
    final normal =
        Offset(-line.dy, line.dx) / (line.distance == 0 ? 1 : line.distance);

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(
          children: [for (var i = 0; i < _chips; i++) ..._chip(i, normal)],
        ),
      ),
    );
  }

  List<Widget> _chip(int i, Offset normal) {
    // Each chip leaves a moment after the one before it.
    final start = i / (_chips * 1.6);
    final local = ((_c.value - start) / (1 - start)).clamp(0.0, 1.0);
    if (local <= 0) return const [];

    final eased = Motion.travel.transform(local);
    // Alternating sides, so the chips fan out instead of following one another.
    final bow = (i.isEven ? 1 : -1) * widget.size * (1.4 + i * 0.25);

    // The chip, and one ghost of where it was a moment ago: a pile being
    // pushed leaves a trail, a swarm does not.
    return [
      for (final (double back, double alpha) in const [
        (0.05, 0.22),
        (0.0, 1.0),
      ])
        () {
          final at = (eased - back).clamp(0.0, 1.0);
          // Zero at both ends, widest in the middle: the arc, not a drift.
          final arc = math.sin(at * math.pi) * bow;
          final pos = Offset.lerp(widget.from, widget.to, at)! + normal * arc;

          return Positioned(
            left: pos.dx - widget.size / 2,
            top: pos.dy - widget.size / 2,
            child: Opacity(
              // It holds until it lands on the seat, then goes: the chips are
              // absorbed by the winner rather than evaporating in mid-air.
              opacity: (alpha * (1 - math.max(0.0, (eased - 0.94) / 0.06)))
                  .clamp(0.0, 1.0)
                  .toDouble(),
              child: Transform.rotate(
                angle: eased * math.pi * (i.isEven ? 2 : -2),
                child: PokerChip(colour: AppTheme.gold, size: widget.size),
              ),
            ),
          );
        }(),
    ];
  }
}

/// The pot, on a plinth in the middle of the cloth.
class _Pot extends StatelessWidget {
  const _Pot({required this.room, required this.chipSize});

  final RoomState room;

  /// The same figure the chips flying in are drawn at, so the pile and the
  /// chips landing on it are the same size.
  final double chipSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // No watch: `room` arrives as a field from _Felt, which does watch, so the
    // figure still moves with the pot. The watch here only ever fed the two
    // captions that are gone.

    return _Plate(
      radius: Radii.lg,
      opacity: 0.52,
      elevation: 3,
      accent: AppTheme.goldBright.withValues(alpha: 0.22),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
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
              _PotChips(pot: room.pot, size: chipSize),
              const SizedBox(width: Space.md),
              Flexible(
                // Chips arriving in the pot is the thing players watch, so the
                // number travels to its new value instead of jumping. Tabular
                // figures are what stop it jittering sideways while it counts.
                child: TweenAnimationBuilder<double>(
                  tween: Tween(end: room.pot.toDouble()),
                  duration: const Duration(milliseconds: 550),
                  curve: Motion.standard,
                  builder: (context, value, _) => FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      formatChips(value.round()),
                      style: AppTheme.money(
                        theme.textTheme.headlineSmall ?? const TextStyle(),
                        colour: AppTheme.goldBright,
                      ),
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

    if (text.isEmpty) return const SizedBox.shrink();

    final mine = state.myTurn && room.state == TableState.betting;
    final base = theme.textTheme.titleSmall ?? const TextStyle();

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
        key: ValueKey(text),
        fit: BoxFit.scaleDown,
        child: Text(
          text,
          style:
              AppTheme.label(
                base,
                colour: mine
                    ? AppTheme.goldBright
                    : AppTheme.boneInk.withValues(alpha: 0.82),
                weight: FontWeight.w700,
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

/// The viewer's own three cards, resting on the cloth in a fan, with "See
/// cards" laid over them: looking at your hand is something you do to the
/// cards, and once you have looked the key has no reason to still be there.
class _OwnHand extends StatelessWidget {
  const _OwnHand({required this.cardHeight});
  final double cardHeight;

  /// How far each card is turned out of the fan, in radians. Small: three
  /// cards held in one hand are barely splayed at all.
  static const double _fan = 0.078;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final you = state.room?.you;
    if (you == null) return const SizedBox.shrink();

    final packed =
        you.status == SeatState.packed || you.status == SeatState.lost;
    // A packed hand stays on the table, face down and struck out, so the player
    // can see what they folded rather than having it vanish.
    if (you.status != SeatState.active && !packed) {
      return const SizedBox.shrink();
    }

    final cards = you.cards;

    // Looking is allowed at any point, not only on your own turn: it costs
    // nothing and changes nothing for anyone else. Betting still waits for the
    // turn, which the console handles.
    final stillBlind = you.isBlind && !packed;

    // The fan's own box. The cards overlap by 18% and the outer two lean out,
    // so the box pays for both the overlap and the lean; the cards cast their
    // shadows onto the cloth, so nothing here may clip tightly to a card.
    final cardW = cardHeight * PlayingCard.aspect;
    final step = cardW * 0.82;
    final lean = cardHeight * 0.09;
    final width = cardW + 2 * step + 2 * lean;

    return SizedBox(
      width: width,
      height: cardHeight * 1.12,
      child: Stack(
        children: [
          for (var i = 0; i < 3; i++)
            Positioned(
              left: lean + i * step,
              // The middle card sits a little proud of its neighbours.
              bottom: i == 1 ? cardHeight * 0.04 : 0,
              child: _Dealt(
                key: ValueKey('${state.room?.handNo}-$i'),
                index: i,
                restAngle: (i - 1) * _fan,
                child: PlayingCard(
                  height: cardHeight,
                  code: i < cards.length ? cards[i] : null,
                  dimmed: packed,
                ),
              ),
            ),
          if (packed)
            Positioned.fill(
              child: Center(
                child: _Plate(
                  radius: Radii.sm,
                  opacity: 0.68,
                  accent: theme.colorScheme.error.withValues(alpha: 0.45),
                  padding: EdgeInsets.symmetric(
                    horizontal: cardHeight * 0.18,
                    vertical: cardHeight * 0.07,
                  ),
                  child: Text(
                    state.t.packed,
                    style: AppTheme.label(
                      theme.textTheme.titleSmall ?? const TextStyle(),
                      colour: theme.colorScheme.error,
                      weight: FontWeight.w700,
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
                  child: FilledButton(
                    onPressed: state.see,
                    style: FilledButton.styleFrom(
                      // A ghost key, so it no longer hides the artwork it is
                      // laid over.
                      minimumSize: Size(cardW * 1.6, Dim.minTouch),
                      backgroundColor: AppTheme.ink900.withValues(alpha: 0.62),
                      foregroundColor: AppTheme.goldBright,
                      side: BorderSide(
                        color: AppTheme.goldBright.withValues(alpha: 0.55),
                        width: 1.4,
                      ),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        state.t.seeCards,
                        maxLines: 1,
                        style: AppTheme.label(
                          theme.textTheme.labelLarge ?? const TextStyle(),
                          colour: AppTheme.goldBright,
                          weight: FontWeight.w700,
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
  }
}

/// Tosses a card in from the middle of the table, staggered, so a hand looks
/// dealt onto cloth rather than switched on.
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

class _DealtState extends State<_Dealt> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
  );

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(Duration(milliseconds: widget.index * 110), () {
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
    final curved = CurvedAnimation(parent: _c, curve: Motion.standard);

    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        // From up and to the left: the middle of the table, where the pot is.
        position: Tween(
          begin: const Offset(-0.5, -0.9),
          end: Offset.zero,
        ).animate(curved),
        child: ScaleTransition(
          scale: Tween(begin: 0.85, end: 1.0).animate(curved),
          child: AnimatedBuilder(
            animation: curved,
            builder: (context, child) => Transform.rotate(
              // Turning into its place in the fan as it lands.
              angle: -0.18 + (widget.restAngle + 0.18) * curved.value,
              alignment: Alignment.bottomCenter,
              child: child,
            ),
            child: widget.child,
          ),
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
    final headline = won
        ? state.t.youAreWinner
        : state.winnerName.isNotEmpty
        ? '${state.winnerName} ${state.t.isTheWinner}'
        : state.showdownResult;

    // Attention is focused rather than the whole table greyed: the cloth stays
    // bright where the winner is sitting and closes down towards the rim. When
    // they have already left, the light falls on the middle instead — the same
    // branch the scattered fireworks take.
    final focus = winnerAt == null
        ? Alignment.center
        : Alignment(winnerAt!.dx * 2 - 1, winnerAt!.dy * 2 - 1);

    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: focus,
                  radius: 0.85,
                  colors: [
                    // Barely there. This scrim existed to lift a panel of
                    // cards off the felt; the hands are now revealed at the
                    // seats, and 62% of ink over them is why they could not be
                    // seen. It only has to seat the banner now.
                    AppTheme.ink900.withValues(alpha: 0.04),
                    AppTheme.ink900.withValues(alpha: 0.30),
                  ],
                  stops: const [0.20, 1],
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: Fireworks(
            seed: state.room?.handNo ?? 0,
            bursts: won ? 8 : 5,
            focus: winnerAt,
          ),
        ),
        if (potFlight != null) Positioned.fill(child: potFlight!),
        Positioned.fill(
          child: Center(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Space.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Only the result. The hands themselves are revealed at the
                  // seats that played them — a panel of cards over the middle
                  // of the table covers the very seats a player is trying to
                  // read, and no real table shows you a hand anywhere but in
                  // front of the person holding it.
                  _Banner(headline: headline, won: won, pot: state.winnerPot),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The announcement itself, which lands rather than appears.
///
/// Winning and losing are told apart by the fireworks and by where the light
/// falls, not by a change of surface: a green pill for a win and a grey one for
/// a loss made the same moment look like two different screens.
class _Banner extends StatelessWidget {
  const _Banner({required this.headline, required this.won, required this.pot});

  final String headline;
  final bool won;
  final int pot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.arrive,
      curve: Motion.settle,
      builder: (context, v, child) => Transform.scale(
        scale: 0.7 + 0.3 * v,
        child: Opacity(opacity: v.clamp(0, 1), child: child),
      ),
      child: _Plate(
        radius: Radii.lg,
        opacity: 0.72,
        elevation: 5,
        borderWidth: 1.5,
        accent: AppTheme.goldBright.withValues(alpha: won ? 0.55 : 0.30),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.xxl,
          vertical: Space.lg,
        ),
        // Scaled as one piece: a pot in crores must never push the trophy or
        // the name out of the plate, or the plate off the felt.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (won) ...[
                const Icon(
                  Icons.emoji_events_rounded,
                  color: AppTheme.goldBright,
                  size: 24,
                ),
                const SizedBox(width: Space.md),
              ],
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    headline,
                    style: AppTheme.label(
                      theme.textTheme.titleMedium ?? const TextStyle(),
                      colour: AppTheme.boneInk,
                      weight: FontWeight.w700,
                    ),
                  ),
                  if (pot > 0) ...[
                    const SizedBox(height: Space.xs),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const PokerChip(colour: AppTheme.gold, size: 18),
                        const SizedBox(width: Space.sm),
                        Text(
                          formatChips(pot),
                          style: AppTheme.money(
                            theme.textTheme.titleMedium ?? const TextStyle(),
                            colour: AppTheme.goldBright,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
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
        ..color = AppTheme.goldBright.withValues(alpha: 0.14)
        ..strokeWidth = 4
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = AppTheme.goldBright.withValues(alpha: 0.55)
        ..strokeWidth = 1.2
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
            ..color = AppTheme.goldBright.withValues(alpha: 0.55 * (1 - i / 9)),
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
        child: _Plate(
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
                style: AppTheme.smallCaps(
                  theme.textTheme.labelSmall ?? const TextStyle(),
                  tracking: 2.4,
                  colour: AppTheme.goldBright.withValues(alpha: 0.75),
                ),
              ),
              const SizedBox(height: Space.sm),
              Text(
                '$askerName ${state.t.sideshowAsksYou}',
                textAlign: TextAlign.center,
                style: AppTheme.label(
                  theme.textTheme.titleSmall ?? const TextStyle(),
                  colour: AppTheme.boneInk,
                  weight: FontWeight.w700,
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
                  Expanded(
                    child: FilledButton(
                      onPressed: () => state.answerSideshow(false),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(120, 48),
                        backgroundColor: AppTheme.ink700.withValues(alpha: 0.9),
                        foregroundColor: AppTheme.boneInk,
                        side: BorderSide(
                          color: theme.colorScheme.error.withValues(
                            alpha: 0.45,
                          ),
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
                    child: FilledButton(
                      onPressed: () => state.answerSideshow(true),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(120, 48),
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

/// The two compared hands. The server sends these to the two players in the
/// sideshow and to nobody else, so this widget is only ever built for them.
class _SideshowRevealPanel extends StatelessWidget {
  const _SideshowRevealPanel({required this.reveal});
  final SideshowReveal reveal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<GameState>();
    final me = state.user?.id;

    final iPacked = reveal.packedUserId != null && reveal.packedUserId == me;

    return IgnorePointer(
      child: ColoredBox(
        color: AppTheme.ink900.withValues(alpha: 0.55),
        child: Center(
          child: _Plate(
            radius: Radii.lg,
            opacity: 0.78,
            elevation: 5,
            borderWidth: 1.5,
            accent: AppTheme.goldBright.withValues(alpha: 0.45),
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.md,
              Space.lg,
              Space.lg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'SIDESHOW',
                  style: AppTheme.smallCaps(
                    theme.textTheme.labelSmall ?? const TextStyle(),
                    tracking: 2.4,
                    colour: AppTheme.goldBright.withValues(alpha: 0.75),
                  ),
                ),
                const SizedBox(height: Space.md),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (final hand in reveal.hands) ...[
                      _SideshowHandCard(
                        hand: hand,
                        packed: hand.userId == reveal.packedUserId,
                        isMe: hand.userId == me,
                      ),
                      if (hand != reveal.hands.last)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.md,
                          ),
                          child: Text(
                            'VS',
                            style: AppTheme.smallCaps(
                              theme.textTheme.titleMedium ?? const TextStyle(),
                              tracking: 2,
                              colour: AppTheme.goldBright,
                              weight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
                const SizedBox(height: Space.md),
                Text(
                  iPacked ? state.t.sideshowYouLost : state.t.sideshowYouWon,
                  style: AppTheme.label(
                    theme.textTheme.titleSmall ?? const TextStyle(),
                    colour: iPacked
                        ? AppTheme.boneInk.withValues(alpha: 0.55)
                        : AppTheme.goldBright,
                    weight: FontWeight.w700,
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

class _SideshowHandCard extends StatelessWidget {
  const _SideshowHandCard({
    required this.hand,
    required this.packed,
    required this.isMe,
  });

  final SideshowHand hand;
  final bool packed;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cardH = Dim.revealCardH(MediaQuery.sizeOf(context).height);

    return _Plate(
      radius: Radii.md,
      opacity: 0.55,
      borderWidth: packed ? Dim.hairline : 1.5,
      accent: packed
          ? AppTheme.ink400.withValues(alpha: 0.7)
          : AppTheme.goldBright.withValues(alpha: 0.55),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            isMe ? '${hand.displayName} *' : hand.displayName,
            style: AppTheme.label(
              theme.textTheme.labelMedium ?? const TextStyle(),
              colour: packed
                  ? AppTheme.boneInk.withValues(alpha: AppTheme.inkLow)
                  : AppTheme.boneInk,
            ),
          ),
          const SizedBox(height: Space.sm),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in hand.cards)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.xxs),
                  child: PlayingCard(height: cardH, code: c, dimmed: packed),
                ),
            ],
          ),
          const SizedBox(height: Space.xs),
          Text(
            hand.handName,
            style: AppTheme.label(
              theme.textTheme.bodySmall ?? const TextStyle(),
              colour: AppTheme.boneInk.withValues(alpha: AppTheme.inkLow),
              weight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

/// The lift on an icon button that has a background of its own.
///
/// The button themes cover the labelled buttons; icon buttons are left out of
/// those on purpose, because most of the ones here — the menu, the chat, the
/// close on a sheet — are transparent, and a shadow under nothing visible is
/// just a smudge. This is applied to the ones that are filled.
ButtonStyle _stepperStyle(ThemeData theme) =>
    AppTheme.raisedIcon(theme.brightness);

/// One key on the console: an icon, what it does, and what it costs.
///
/// They share a shape so the console reads as one set of keys rather than four
/// buttons that happen to sit together — and the icon is what a player finds
/// under their thumb without reading, which matters on a clock.
///
/// Still a [FilledButton], because leaving `elevation` unset in `styleFrom` is
/// what lets the theme's `liftElevation` resolve the rest / pressed / hovered /
/// disabled ladder. A disabled key loses its gold rather than changing colour:
/// that is the only illegal-move signal the game has.
class _MachinedKey extends StatelessWidget {
  const _MachinedKey({
    required this.width,
    required this.height,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.amount,
    this.primary = false,
    this.edge,
    this.alive = false,
  });

  final double width;
  final double height;
  final IconData icon;
  final String label;

  /// The second line: what the move costs, or who it is aimed at. Omitted
  /// leaves the label on its own.
  final String? amount;
  final VoidCallback? onPressed;

  /// The one gold-filled key on the screen. There is never a second.
  final bool primary;

  /// The hairline that gives this key its identity — crimson on Pack.
  final Color? edge;

  /// This key is one of the moves available RIGHT NOW.
  ///
  /// The pod ring says whose turn it is; this says what can be done about it.
  /// Only ever set on keys that are actually pressable, so a lit key is always
  /// a promise that tapping it will do something.
  final bool alive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final ink = primary ? AppTheme.ink900 : scheme.onSurface;
    final live = edge ?? AppTheme.hairlineColour(brightness, live: true);
    final halo = edge ?? (primary ? AppTheme.gold : AppTheme.goldBright);

    final style =
        FilledButton.styleFrom(
          fixedSize: Size(width, height),
          // The key already clears the touch floor on both axes, and the
          // padded target would silently grow it past the width the console
          // measured out for it.
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: Space.sm),
          backgroundColor: primary
              ? AppTheme.gold
              : AppTheme.plaque(brightness),
          foregroundColor: ink,
          disabledBackgroundColor: AppTheme.panelBase(brightness),
          disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.26),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
          ),
        ).copyWith(
          side: WidgetStateProperty.resolveWith(
            (states) => BorderSide(
              color: states.contains(WidgetState.disabled)
                  ? AppTheme.ink400.withValues(alpha: 0.35)
                  : live,
              width: Dim.hairline,
            ),
          ),
        );

    // A key with nothing behind it is drawn as inert, not merely as a paler
    // version of itself.
    //
    // The colours alone were not enough: on the light scheme the disabled
    // plaque and the live one are both near-white, so a player waiting out a
    // hand saw three buttons that looked pressable and were not. Dropping the
    // whole key's opacity is the one treatment nobody has to learn.
    final dead = onPressed == null;

    return Opacity(
      opacity: dead ? 0.42 : 1,
      child: _KeyPulse(
        alive: alive,
        colour: halo,
        radius: Radii.md,
        child: FilledButton(
          onPressed: onPressed,
          style: style,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: Space.sm),
              Flexible(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        // Translated, so it keeps its natural case.
                        label,
                        maxLines: 1,
                        style: AppTheme.label(
                          theme.textTheme.labelLarge ?? const TextStyle(),
                          weight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (amount != null)
                      // A crore-sized bet is a long word; it shrinks to fit rather
                      // than losing its tail to an ellipsis.
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          amount!,
                          maxLines: 1,
                          style: AppTheme.money(
                            theme.textTheme.bodySmall ?? const TextStyle(),
                            weight: FontWeight.w600,
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
    );
  }
}

/// The amount on the ladder, in a window cut into the console.
///
/// It is the visual anchor of the row: darker than the console around it, with
/// a champagne rim, so it reads as recessed rather than as a fifth key.
class _BetWindow extends StatelessWidget {
  const _BetWindow({
    required this.width,
    required this.height,
    required this.amount,
    required this.live,
  });

  final double width;
  final double height;
  final int amount;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = live
        ? _goldInk(theme.brightness)
        : theme.colorScheme.onSurface.withValues(alpha: 0.34);

    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      decoration: BoxDecoration(
        // Recessed in both schemes: darker than whatever the console is.
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [AppTheme.ink900, AppTheme.ink700]
              : const [AppTheme.bone300, AppTheme.bone200],
        ),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: live
              ? AppTheme.hairlineColour(theme.brightness, live: true)
              : AppTheme.ink400.withValues(alpha: 0.30),
          width: Dim.hairline,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // A real chip rather than an icon of one: it is the same artwork the
          // pot and the seats are counted in.
          PokerChip(
            colour: live ? AppTheme.gold : theme.colorScheme.outline,
            size: 18,
          ),
          const SizedBox(width: Space.sm),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: AnimatedSwitcher(
                duration: Motion.fast,
                child: Text(
                  formatChips(amount),
                  // Keyed on the figure so a step swaps it rather than
                  // redrawing it in place; tabular, so the ladder's doublings
                  // never change the window's width.
                  key: ValueKey(amount),
                  style: AppTheme.money(
                    theme.textTheme.titleMedium ?? const TextStyle(),
                    colour: ink,
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

/// Pack on the left, the stake stepper in the middle, then Chaal and one more
/// key on the right.
///
/// The console is always there and simply goes dead between turns: one that
/// disappears and comes back moves the keys under the player's thumb, which is
/// how misclicks happen.
///
/// That last slot is Sideshow, and becomes Show once only two players are left
/// in the hand — the two can never be offered at once, because a sideshow needs
/// a third player and a show needs there not to be one.
///
/// It is [GlassMode.tinted], never blurred: it sits over the room's ground for
/// the whole session, and a `BackdropFilter` re-blurs its backdrop on every
/// frame that backdrop repaints.
class _ActionConsole extends StatelessWidget {
  const _ActionConsole();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final t = state.t;
    final theme = Theme.of(context);

    final live = state.myTurn;
    final options = state.options;
    final showCost = options?.show;
    final canSideshow = live && (options?.canSideshow ?? false);
    // Heads-up: a show is on offer, and a sideshow cannot be.
    final headsUp = live && showCost != null && showCost > 0;

    final size = MediaQuery.sizeOf(context);
    final keyH = Dim.keyH(size.height);
    final gap = Dim.gap(size.width);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        Dim.feltPad(size.width),
        Space.xs,
        Dim.feltPad(size.width),
        Space.sm,
      ),
      child: PremiumGlassPanel(
        mode: GlassMode.tinted,
        radius: Radii.lg,
        live: live,
        // The panel's height is its keys plus its own padding, never the other
        // way round: keyH + 2*consolePad is 61.6 at h=360, 70.3 at h=411 and
        // 78.0 at h=800, and the keys inside it are 48.6 / 55.5 / 60.0 tall.
        padding: EdgeInsets.symmetric(
          horizontal: gap,
          vertical: Dim.consolePad(size.height),
        ),
        child: SizedBox(
          height: keyH,
          child: LayoutBuilder(
            builder: (context, box) {
              // The row is laid out inside a bounded box rather than scaled
              // down by a FittedBox, which is what used to take a 46dp key to
              // about 37 on a small phone. Three keys, the bet window and two
              // steppers, with what is left over going to the two spacers:
              // 119.7dp keys of 605 at 640x360, 178.7 of 838.9 at 891x411 and
              // 235.2 of 1213.9 at 1280x800.
              final bet = Dim.betW(size.width);
              final free = box.maxWidth - bet - 2 * Dim.minTouch - 5 * gap;
              final keyW = math.max(
                0.0,
                math.min(free / 3, Dim.keyW(size.width) * 1.4),
              );

              return Row(
                children: [
                  _MachinedKey(
                    width: keyW,
                    height: keyH,
                    icon: Icons.close_rounded,
                    label: t.pack,
                    alive: live && (options?.canPack ?? false),
                    edge: theme.colorScheme.error.withValues(alpha: 0.45),
                    onPressed: live && (options?.canPack ?? false)
                        ? state.pack
                        : null,
                  ),
                  const Spacer(),
                  _StepperKey(
                    icon: Icons.remove_rounded,
                    height: keyH,
                    onPressed: state.canStepDown
                        ? () => state.stepBet(-1)
                        : null,
                  ),
                  SizedBox(width: gap),
                  _BetWindow(
                    width: bet,
                    height: keyH,
                    amount: state.betAmount,
                    live: live,
                  ),
                  SizedBox(width: gap),
                  _StepperKey(
                    icon: Icons.add_rounded,
                    height: keyH,
                    onPressed: state.canStepUp ? () => state.stepBet(1) : null,
                  ),
                  const Spacer(),
                  _MachinedKey(
                    width: keyW,
                    height: keyH,
                    icon: Icons.arrow_forward_rounded,
                    label: t.chaal,
                    alive: live,
                    amount: formatChips(state.betAmount),
                    onPressed: live ? state.bet : null,
                    primary: true,
                  ),
                  SizedBox(width: gap),
                  // One slot, two jobs. A show is only possible with two
                  // players left and a sideshow only with three or more, so the
                  // key turns into Show at exactly the point Sideshow stops
                  // being askable — and the two are never on screen together.
                  headsUp
                      ? _MachinedKey(
                          width: keyW,
                          height: keyH,
                          icon: Icons.visibility_rounded,
                          label: t.show,
                          alive: true,
                          amount: formatChips(showCost),
                          onPressed: () => state.show(showCost),
                        )
                      // Dead by default: it wakes up only on your turn, with
                      // three players in the hand and both you and the player
                      // on your right holding seen cards. All of that is the
                      // server's judgement, arriving as canSideshow.
                      : _MachinedKey(
                          width: keyW,
                          height: keyH,
                          icon: Icons.compare_arrows_rounded,
                          label: t.sideshow,
                          amount: canSideshow ? options?.sideshowWith : null,
                          // Only when the server says it is actually offered —
                          // a lit key that refuses on tap is worse than a dark
                          // one.
                          alive: canSideshow,
                          onPressed: canSideshow ? state.askSideshow : null,
                        ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// One end of the stake stepper. A ring of champagne is the affordance, and it
/// is present only while the key can be pressed.
class _StepperKey extends StatelessWidget {
  const _StepperKey({
    required this.icon,
    required this.height,
    required this.onPressed,
  });

  final IconData icon;
  final double height;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return IconButton.filledTonal(
      onPressed: onPressed,
      iconSize: 22,
      style: _stepperStyle(theme).copyWith(
        fixedSize: WidgetStatePropertyAll(Size(Dim.minTouch, height)),
        // Exactly 44 wide, not the 48 a padded tap target would take.
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        ),
        side: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? BorderSide(
                  color: AppTheme.ink400.withValues(alpha: 0.30),
                  width: Dim.hairline,
                )
              : BorderSide(
                  color: AppTheme.hairlineColour(theme.brightness, live: true),
                  width: Dim.hairline,
                ),
        ),
      ),
      icon: Icon(icon),
    );
  }
}

/// Requirement 8: room chat. It lives only in memory on the server and goes
/// when the room does.
class _ChatDrawer extends StatefulWidget {
  const _ChatDrawer();

  @override
  State<_ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<_ChatDrawer> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);

    return GlassDrawerPanel(
      padding: EdgeInsets.zero,
      child: SizedBox.expand(
        child: Padding(
          // The composer sits at the bottom of a full-height panel, so it has
          // to ride above the keyboard rather than behind it.
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  Space.md,
                  Space.sm,
                  Space.xs,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.forum_rounded,
                      size: 18,
                      color: _goldInk(theme.brightness),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: Text(
                        state.t.tableChat,
                        style: AppTheme.label(
                          theme.textTheme.titleMedium ?? const TextStyle(),
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const _MenuRule(),
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    Space.sm,
                    Space.lg,
                    Space.sm,
                  ),
                  itemCount: state.chat.length,
                  itemBuilder: (context, i) {
                    final m = state.chat[state.chat.length - 1 - i];
                    final mine = m.userId == state.user?.id;
                    // Everyone gets their own colour, kept from their id so a
                    // player looks the same every time they speak.
                    final colour = state.colourFor(m.userId, theme.colorScheme);

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: Space.xxs),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 3,
                            height: 18,
                            margin: const EdgeInsets.only(
                              right: Space.md,
                              top: 3,
                            ),
                            decoration: BoxDecoration(
                              color: colour,
                              borderRadius: BorderRadius.circular(Radii.xs),
                            ),
                          ),
                          Expanded(
                            child: RichText(
                              text: TextSpan(
                                style: theme.textTheme.bodyMedium,
                                children: [
                                  TextSpan(
                                    text: '${mine ? 'You' : m.displayName}: ',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: colour,
                                    ),
                                  ),
                                  TextSpan(text: m.text),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  Space.sm,
                  Space.lg,
                  Space.md,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        maxLength: 200,
                        decoration: InputDecoration(
                          hintText: state.t.saySomething,
                          counterText: '',
                          isDense: true,
                        ),
                        onSubmitted: (_) => _send(state),
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    IconButton.filled(
                      tooltip: state.canChat
                          ? null
                          : '${state.chatCooldownLeft}s',
                      onPressed: state.canChat ? () => _send(state) : null,
                      style: _stepperStyle(theme).copyWith(
                        minimumSize: const WidgetStatePropertyAll(
                          Size(Dim.minTouch, Dim.minTouch),
                        ),
                      ),
                      icon: state.canChat
                          ? const Icon(Icons.send_rounded)
                          : _ChatCountdown(
                              left: state.chatCooldownLeft,
                              total: GameState.chatCooldown.inSeconds,
                            ),
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

  void _send(GameState state) {
    if (!state.sendChat(_input.text)) return;
    _input.clear();
    // Said: the keyboard and the drawer go together, and what the player sees
    // next is the table with their words over their own seat.
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop();
  }
}

/// The seconds until the next message may be sent, drawn as a number inside a
/// dial that drains as the wait runs down.
class _ChatCountdown extends StatelessWidget {
  const _ChatCountdown({required this.left, required this.total});

  final int left;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 22,
      height: 22,
      child: CustomPaint(
        painter: _DialPainter(
          fraction: total == 0 ? 0 : (left / total).clamp(0.0, 1.0),
          track: AppTheme.ink400.withValues(alpha: 0.55),
          fill: _goldInk(theme.brightness),
        ),
        child: Center(
          child: Text(
            '$left',
            // Tabular, so 4-3-2-1 does not shift by a pixel inside the dial.
            style: AppTheme.money(
              theme.textTheme.labelSmall ?? const TextStyle(),
              colour: theme.colorScheme.onSurface.withValues(
                alpha: AppTheme.inkMed,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  const _DialPainter({
    required this.fraction,
    required this.track,
    required this.fill,
  });

  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height).deflate(1.2);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, 0, math.pi * 2, false, stroke..color = track);
    if (fraction <= 0) return;
    // From the top, draining anticlockwise.
    canvas.drawArc(
      rect,
      -math.pi / 2,
      -fraction * math.pi * 2,
      false,
      stroke..color = fill,
    );
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.fraction != fraction || old.track != track || old.fill != fill;
}

/// The overhead lamp on the cloth, brightening and dimming on a slow cycle.
///
/// Plain `srcOver` and no blend mode: a blend here would force an offscreen
/// pass across the largest region on the screen, on every frame, for the life
/// of the room.
class _AmbientLamp extends StatefulWidget {
  const _AmbientLamp();

  @override
  State<_AmbientLamp> createState() => _AmbientLampState();
}

class _AmbientLampState extends State<_AmbientLamp>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: Motion.breath,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: _breath,
      builder: (context, _) {
        final v = Motion.breathe.transform(_breath.value);
        final lamp = (dark ? 0.075 : 0.055) + 0.022 * v;

        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.35),
              focal: const Alignment(0, -0.55),
              radius: 0.62 + 0.05 * v,
              colors: [
                AppTheme.lampWarm.withValues(alpha: lamp),
                AppTheme.lampWarm.withValues(alpha: lamp * 0.4),
                AppTheme.lampWarm.withValues(alpha: 0),
              ],
              stops: const [0, 0.45, 1],
            ),
          ),
          // The near rim falls into shadow, which is what actually says the
          // light is coming from above rather than from inside the cloth.
          child: const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, 0.72),
                radius: 0.75,
                colors: [Color(0x3806080A), Color(0x0006080A)],
              ),
            ),
          ),
        );
      },
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

/// Buzzes the phone the moment it becomes this player's turn.
///
/// A widget rather than something in _TableScreenState, because that State
/// deliberately watches NOTHING: GameState notifies once a second for the
/// reward countdown, and a dependency there rebuilds the Scaffold every second
/// and closes an open drawer under the player's hand. This depends on one
/// boolean through `select`, so it rebuilds only when the turn actually
/// changes hands.
///
/// It fires on the EDGE. Reacting to `myTurn` being true rather than to it
/// becoming true would buzz twenty-five times a turn.
class _TurnBuzzer extends StatefulWidget {
  const _TurnBuzzer();

  @override
  State<_TurnBuzzer> createState() => _TurnBuzzerState();
}

class _TurnBuzzerState extends State<_TurnBuzzer> {
  bool _was = false;
  int _missed = -1;
  int _pot = -1;
  int _seen = -1;
  bool _alarmed = false;
  bool _won = false;

  /// How much of the turn clock is left when the alarm sounds. Five seconds of
  /// twenty-five: late enough that it is not nagging, early enough to act on.
  static const _alarmAt = Duration(seconds: 5);

  @override
  Widget build(BuildContext context) {
    // One record, several facts, still rebuilt only when one of them changes.
    final now = context
        .select<
          GameState,
          ({bool mine, int missed, int pot, int seen, int deadline, bool won})
        >((s) {
          final room = s.room;
          return (
            // The showdown has named this player. The celebration keys off the
            // same fact, so the sound and the fireworks arrive together.
            won: s.showdownResult.isNotEmpty && s.iWon,
            mine: s.myTurn && room?.state == TableState.betting,
            missed: room?.you?.missedTurns ?? 0,
            pot: room?.pot ?? 0,
            // How many players have looked at their cards. Any increase is
            // somebody turning a hand over, whoever it was.
            seen:
                room?.seats.nonNulls.where((seat) => !seat.isBlind).length ?? 0,
            deadline: room?.turn?.deadline ?? 0,
          );
        });

    final startedTurn = now.mine && !_was;
    // The count only ever goes up within a seat; it resets to 0 after a
    // successful move and on a new seat, and neither of those is a miss.
    final autoPacked = _missed >= 0 && now.missed > _missed;
    final potGrew = _pot >= 0 && now.pot > _pot;
    final justWon = now.won && !_won;
    final sawCards = _seen >= 0 && now.seen > _seen;

    if (startedTurn) _alarmed = false;

    if (startedTurn || autoPacked || potGrew || sawCards || justWon) {
      // After the frame: a platform call out of build is a side effect in the
      // middle of laying the screen out.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final feedback = context.read<FeedbackSettings>();
        // Ordered by how much news each carries, and only one fires per frame
        // — three sounds at once is noise, not feedback.
        if (justWon) {
          feedback.win();
        } else if (autoPacked) {
          feedback.missedTurn();
        } else if (startedTurn) {
          feedback.turn();
        } else if (potGrew) {
          feedback.potGrew();
        } else if (sawCards) {
          feedback.cards();
        }
      });
    }

    _was = now.mine;
    _missed = now.missed;
    _pot = now.pot;
    _seen = now.seen;
    _won = now.won;

    // The clock is its own thing: it is not driven by a state change but by
    // time passing, so it needs a timer rather than a rebuild.
    _armAlarm(now.mine, now.deadline);
    return const SizedBox.shrink();
  }

  Timer? _alarmTimer;

  void _armAlarm(bool mine, int deadlineMs) {
    _alarmTimer?.cancel();
    if (!mine || deadlineMs <= 0 || _alarmed) return;
    final left = DateTime.fromMillisecondsSinceEpoch(
      deadlineMs,
    ).difference(DateTime.now());
    final wait = left - _alarmAt;
    if (wait.isNegative) return;
    _alarmTimer = Timer(wait, () {
      if (!mounted || _alarmed) return;
      _alarmed = true;
      context.read<FeedbackSettings>().alarm();
    });
  }

  @override
  void dispose() {
    _alarmTimer?.cancel();
    super.dispose();
  }
}

/// Three cards to each seat when a hand is dealt.
///
/// Purely presentation: the cards it draws are face-down blanks flying from
/// the middle of the cloth to each occupied seat, and the real hand is already
/// in the snapshot that triggered it. Nothing here decides who gets what.
///
/// Keyed on handNo, the same signal _BetFlights uses, so a deal is "the hand
/// number changed" and not a guess from card counts. A player who sits down
/// mid-hand sees nothing: their handNo arrives already set, and dealing cards
/// for a hand that started before they arrived would be a lie.
class _DealFlights extends StatefulWidget {
  const _DealFlights({
    required this.seats,
    required this.roomId,
    required this.handNo,
    required this.centreOf,
    required this.deck,
    required this.cardHeight,
  });

  final List<Seat?> seats;

  /// Which table this is. A switch changes it, and a hand already in progress
  /// at the new table was not dealt to anyone here.
  final String roomId;
  final int handNo;
  final Offset Function(int seatIndex) centreOf;

  /// Where the cards come from — just above the middle, where a dealer's hands
  /// would be.
  final Offset deck;
  final double cardHeight;

  @override
  State<_DealFlights> createState() => _DealFlightsState();
}

class _DealFlightsState extends State<_DealFlights>
    with SingleTickerProviderStateMixin {
  static const _cardsEach = 3;

  late final AnimationController _run =
      AnimationController(
        vsync: this,
        // Slower than feels necessary on paper. Dealing is the moment the hand
        // begins, and rushing it is the difference between cards being dealt and
        // cards appearing — the whole point of drawing it at all.
        duration: const Duration(milliseconds: 2000),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed && mounted) {
          setState(() => _flights = const []);
        }
      });

  List<({Offset to, double delay})> _flights = const [];
  int _dealt = 0;

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_DealFlights old) {
    super.didUpdateWidget(old);
    // A new hand, at the SAME table, and not the first frame after mounting.
    //
    // The room check is what makes a switch quiet. This widget is not rebuilt
    // from scratch when a player moves — it keeps its state and simply sees
    // handNo go from the old table's number to the new one's, which is
    // indistinguishable from a deal unless the table is compared too. Landing
    // mid-hand and being shown cards flying to seats that are already holding
    // them is worse than showing nothing.
    if (widget.roomId != old.roomId) return;
    if (widget.handNo == old.handNo || old.handNo == 0) return;
    _deal();
  }

  void _deal() {
    final seated = <int>[
      for (var i = 0; i < widget.seats.length; i++)
        if (widget.seats[i] != null) i,
    ];
    if (seated.isEmpty) return;

    // One card to each seat in turn, three times round — the order a hand is
    // actually dealt in, which is what makes it read as dealing rather than as
    // cards appearing.
    final flights = <({Offset to, double delay})>[];
    var n = 0;
    for (var round = 0; round < _cardsEach; round++) {
      for (final seat in seated) {
        flights.add((to: widget.centreOf(seat), delay: n * 0.062));
        n++;
      }
    }
    setState(() {
      _flights = flights;
      _dealt = 0;
    });
    _run.forward(from: 0);
  }

  /// A click as each card lands, through the settings so it honours the
  /// player's switch. Not one sound per deal: the rhythm of the cards landing
  /// IS the sound of dealing, and a single clip cannot follow a table that has
  /// two players at one moment and five at the next.
  void _sound(int landed) {
    if (landed <= _dealt) return;
    final feedback = context.read<FeedbackSettings>();
    for (var i = _dealt; i < landed; i++) {
      feedback.tap();
    }
    _dealt = landed;
  }

  @override
  Widget build(BuildContext context) {
    if (_flights.isEmpty) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _run,
      builder: (context, _) {
        final t = _run.value;
        var landed = 0;
        final cards = <Widget>[];
        for (final flight in _flights) {
          // Each card has the same short travel, started at its own offset.
          // A long travel window per card, overlapping its neighbours: the
          // hand reads as one continuous motion round the table rather than as
          // fifteen separate darts.
          final local = ((t - flight.delay) / 0.46).clamp(0.0, 1.0);
          if (local <= 0) continue;
          if (local >= 1) {
            landed++;
            continue;
          }
          // Eased at BOTH ends. easeOutCubic leaves at full speed, which is
          // what made the cards look flicked; this lets each one gather and
          // settle.
          final eased = Curves.easeInOutCubic.transform(local);
          final at = Offset.lerp(widget.deck, flight.to, eased)!;
          cards.add(
            Positioned(
              left: at.dx - widget.cardHeight * 0.35,
              top: at.dy - widget.cardHeight / 2,
              child: Opacity(
                // Fades out as it arrives, so the flying card hands over to
                // the one the pod draws rather than doubling it.
                // Holds its opacity most of the way and only lets go at the
                // very end, so the card is visible for the whole flight
                // instead of fading through the middle of it.
                opacity: (1 - eased * eased * eased * eased).clamp(0.0, 1.0),
                child: Transform.rotate(
                  angle: (1 - eased) * 0.38,
                  child: PlayingCard(height: widget.cardHeight),
                ),
              ),
            ),
          );
        }
        if (landed > _dealt) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _sound(landed);
          });
        }
        return Stack(children: cards);
      },
    );
  }
}

/// A soft pulse around an action key while that move is available.
///
/// The same idea as the pod's turn ring and deliberately quieter: the ring
/// answers "whose turn", these answer "what can I do", and if both shouted at
/// the same volume neither would be read. Nothing is drawn at all when the key
/// is not alive.
class _KeyPulse extends StatefulWidget {
  const _KeyPulse({
    required this.alive,
    required this.colour,
    required this.radius,
    required this.child,
  });

  final bool alive;
  final Color colour;
  final double radius;
  final Widget child;

  @override
  State<_KeyPulse> createState() => _KeyPulseState();
}

class _KeyPulseState extends State<_KeyPulse>
    with SingleTickerProviderStateMixin {
  /// Nullable and built on demand, for the same reason _TurnRing's is: most
  /// keys are never alive, and a `late final` initialiser would be run by
  /// `dispose()` on every one of them — a TickerMode lookup on a deactivated
  /// element, which throws in the middle of unmounting the tree.
  AnimationController? _c;

  AnimationController get _pulse => _c ??= AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 980),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.alive) return widget.child;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final t = Motion.breathe.transform(_pulse.value);
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            boxShadow: [
              BoxShadow(
                color: widget.colour.withValues(alpha: 0.16 + 0.26 * t),
                blurRadius: 10 + 8 * t,
                spreadRadius: 0.5,
              ),
            ],
          ),
          child: child,
        );
      },
      child: RepaintBoundary(child: widget.child),
    );
  }
}
