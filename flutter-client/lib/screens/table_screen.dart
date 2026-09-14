import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../settings/feedback_settings.dart';
import '../state/game_state.dart';
import '../state/hammer_strike.dart';
import '../state/missile_strike.dart';
import '../theme/app_theme.dart';
import '../widgets/buy_chips.dart';
import '../widgets/chip_store.dart';
import '../widgets/deal_flight.dart';
import '../widgets/drifting_chips.dart';
import '../widgets/feedback_toggles.dart';
import '../widgets/glass_components.dart';
import '../widgets/glass_panels.dart';
import '../widgets/hammer_flight.dart';
import '../widgets/missile_flight.dart';
import '../widgets/picture_shelf.dart';
import '../widgets/playing_card.dart';
import '../widgets/poker_chip.dart';
import '../widgets/pot_flight.dart';
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

/// The left drawer's content, which tells the table when it has left the
/// screen.
///
/// A [DrawerController] builds its child only while the drawer is at least
/// partly open, so this slot is unmounted at the very moment the slide-out
/// ends — the one moment the panel behind the edge can change without being
/// seen to. A drag that crosses halfway and then settles open again never
/// unmounts it, so nothing changes under a player's thumb.
class _DrawerSlot extends StatefulWidget {
  const _DrawerSlot({required this.onGone, required this.child});

  /// Called from [State.dispose]: no setState here, only a request for later.
  final VoidCallback onGone;
  final Widget child;

  @override
  State<_DrawerSlot> createState() => _DrawerSlotState();
}

class _DrawerSlotState extends State<_DrawerSlot> {
  @override
  void dispose() {
    widget.onGone();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

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
  _LeftPanel _panel = _LeftPanel.menu;

  /// Opening is driven from the rail, which sits inside this Scaffold, so the
  /// state is reached by key rather than by looking up an ancestor. The key
  /// lives on the game state so the back gesture can close the drawer too.
  GlobalKey<ScaffoldState> get _scaffold =>
      context.read<GameState>().tableScaffold;

  void _open(_LeftPanel panel) {
    // Only the chat shows the conversation, so only the chat clears its
    // badge. It always opens on the conversation, even though its quick
    // messages tab sends into it without showing it.
    if (panel == _LeftPanel.chat) context.read<GameState>().markChatRead();
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
  /// menu across the slide-out. [_DrawerSlot] reports the end instead. It is
  /// told while the tree is being finalised, where setState is not allowed,
  /// hence the hop to after the frame — which still lands before any later
  /// touch, because input is handled between frames.
  void _drawerGone() {
    if (_panel == _LeftPanel.menu) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _panel = _LeftPanel.menu);
    });
  }

  @override
  Widget build(BuildContext context) {
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
      drawer: _DrawerSlot(
        onGone: _drawerGone,
        child: switch (_panel) {
          _LeftPanel.menu => const _TableDrawer(),
          _LeftPanel.chat => const _ChatDrawer(),
        },
      ),
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
              ],
            ),
          ),
          // The store, as the same Shop key the lobby's top bar carries and in
          // the same place — the top-left corner, clear of the felt (owner,
          // 13 Sep 2026; it replaces the gold `+` that headed the rail). It
          // opens the same store, on its Chips shelf; its picture key sells
          // the animated shelf alone here, bought with diamonds and worn on
          // the seat at once.
          const Positioned(
            left: Space.md,
            top: Space.sm,
            child: SafeArea(child: ShopButton()),
          ),
          // Diamonds and hammers, in the corner opposite the Shop key and on
          // its line (owner, 13 Sep 2026): what the player can still spend at
          // this table that is not chips. In the room rather than on the felt,
          // like the Shop key, and outside every seat's column (_TableWallet).
          const Positioned(
            right: 0,
            top: Space.sm,
            child: SafeArea(child: _TableWallet()),
          ),
          // The keys, floating over the bottom-right of the table instead of
          // sitting in a bar across the foot of it. Owner's decision,
          // 10 Sep 2026: the bar was a sixth of a landscape screen reserved
          // for six controls, and the table wanted the room.
          const Positioned(
            right: 0,
            bottom: 0,
            child: SafeArea(child: _WhileOnline(child: _ActionCluster())),
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
              child: _WhileOnline(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [_MissileKey(), _PackKey()],
                ),
              ),
            ),
          ),
          const Positioned.fill(child: SafeArea(child: _Reconnecting())),
        ],
      ),
    );
  }
}

/// Diamonds, hammers and missiles, in the top-right corner of the room (owner,
/// 13 and 14 Sep 2026).
///
/// It stands on the Shop key's line, right-aligned with the key cluster below
/// it, and is never wider than the corner it has: from the felt's right edge
/// back to the top-right seat's pod and the glow spilling out of that pod's
/// corner ([_tableWalletRoom]). Three-digit counts at the 1.25 text ceiling
/// on a 640dp phone would run past that, so there it scales down instead of
/// running under the pod. The right-hand seat's column starts below it, and
/// the notices stand between the top two seats ([tableNoticeArea]).
/// test/table_wallet_layout_test.dart checks it at 640x360, 891x411 and
/// 1280x800.
class _TableWallet extends StatelessWidget {
  const _TableWallet();

  @override
  Widget build(BuildContext context) {
    // `select`, not `watch`: the counts change when a hammer is spent or a
    // pack lands, never with the reward ticker. A record compares by value.
    final (diamonds, hammers, missiles, lang) = context
        .select<GameState, (int, int, int, AppLang)>(
          (s) => (
            s.user?.diamond ?? 0,
            s.user?.hammer ?? 0,
            s.user?.missile ?? 0,
            s.lang,
          ),
        );
    final width = MediaQuery.sizeOf(context).width;
    final room = _tableWalletRoom(context);
    // Three counts on one line fit a tablet and most phones. Where that line
    // would have to shrink past [_walletLineScale] to fit the corner — a
    // 640dp phone — the missiles take a second line under the other two, and
    // the pill keeps the size two counts had.
    final stacked =
        room <
        WalletPill.rowWidth(
              context,
              diamonds: diamonds,
              hammers: hammers,
              missiles: missiles,
            ) *
            _walletLineScale;

    // A row the Shop key's height with the pill in the middle of it, so the
    // two corners share one centre line.
    return Padding(
      padding: EdgeInsets.only(right: Dim.feltPad(width)),
      child: SizedBox(
        height: Dim.minTouch,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: room),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: WalletPill(
                diamonds: diamonds,
                hammers: hammers,
                missiles: missiles,
                stacked: stacked,
                semanticsLabel: Strings(
                  lang,
                ).walletSummary(diamonds, hammers, missiles),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The smallest a one-line wallet may be scaled to fit its corner before the
/// missiles go to a second line.
const double _walletLineScale = 0.85;

/// How wide the table's wallet may be: from the felt's right edge back to the
/// top-right seat's pod, less the sixth of a pod its orb spills out of that
/// corner and a little air. Worked out from the numbers [_Felt] lays the seats
/// out with, the way [tableNoticeArea] finds the notices' gap — about 95dp at
/// 640x360, 144 at 891x411 and 227 at 1280x800.
double _tableWalletRoom(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final safe = MediaQuery.paddingOf(context);
  final pad = Dim.feltPad(size.width);
  final feltLeft = safe.left + Dim.railW(size.width) + pad;
  final feltTop = safe.top + Space.xxs;
  final w = size.width - safe.right - pad - feltLeft;
  final h = size.height - safe.bottom - feltTop;
  final podW = Dim.podW(w, h);

  final topRight = _Felt._places[3];
  final podLeft = (topRight.dx * w - podW / 2)
      .clamp(0.0, math.max(0.0, w - podW))
      .toDouble();
  final clear = feltLeft + podLeft + podW + podW / 6 + Space.xs;
  final right = size.width - safe.right - pad;
  return math.max(Dim.minTouch, right - clear);
}

/// Said over the table while the connection is down (QA PIX-2, 14 Sep 2026).
///
/// The socket reconnects by itself, but until it does nothing reaches the
/// server, and the table on screen stops where it was — a turn clock still
/// running on a hand the server has already moved past. With no word of it the
/// app looked frozen, or deaf to the keys. This says what is happening, and
/// [_WhileOnline] rests the keys beneath it.
///
/// It shows once the socket reports the loss. On a network that simply goes
/// dark that is the Engine.IO ping timeout — the server's 20s interval plus
/// its 25s grace — not the instant the signal goes.
class _Reconnecting extends StatelessWidget {
  const _Reconnecting();

  @override
  Widget build(BuildContext context) {
    final (offline, lang) = context.select<GameState, (bool, AppLang)>(
      (s) => (s.offline, s.lang),
    );
    final theme = Theme.of(context);

    return IgnorePointer(
      child: Align(
        // Over the status line, between the top seats and the pot.
        alignment: const Alignment(0, -0.42),
        child: AnimatedSwitcher(
          duration: Motion.base,
          child: !offline
              ? const SizedBox.shrink()
              : Semantics(
                  liveRegion: true,
                  child: _Plate(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.lg,
                      vertical: Space.md,
                    ),
                    opacity: 0.88,
                    accent: AppTheme.goldBright.withValues(alpha: 0.55),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(AppTheme.gold),
                          ),
                        ),
                        const SizedBox(width: Space.md),
                        Text(
                          Strings(lang).reconnecting,
                          style: theme.textTheme.titleSmall?.copyWith(
                            // Light ink on a dark plate, in both brightnesses.
                            color: Colors.white.withValues(alpha: 0.92),
                            fontWeight: FontWeight.w600,
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

/// Rests a corner's keys while the connection is down: dimmed, and deaf to
/// touches, since a move then could only be refused (QA PIX-1/PIX-2,
/// 14 Sep 2026). [_Reconnecting] says why.
class _WhileOnline extends StatelessWidget {
  const _WhileOnline({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final offline = context.select<GameState, bool>((s) => s.offline);
    return AbsorbPointer(
      absorbing: offline,
      child: AnimatedOpacity(
        duration: Motion.base,
        opacity: offline ? 0.45 : 1,
        child: child,
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

/// The only chrome in the game room besides the Shop key in the corner above
/// it: the menu and the chat below it, stacked down the left edge. The quick
/// messages are a tab of the chat drawer.
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
    //
    // Two keys and a gap, centred down the rail: 2x46.8 + 10 = 103.6dp at
    // 640x360, so the column runs from y 128.2 to 231.8. The Shop key above
    // it ends by y 50 (6dp inset, 44dp tall) and the Pack key below it starts
    // at y 306 at the earliest (44dp tall, at most 10dp off the bottom), which
    // leaves more than 74dp clear at each end on the tightest phone; at
    // 891x411 the column is 116.8dp tall and the margins only grow. The quick
    // messages had a third key here until 14 Sep 2026 (owner); they are a tab
    // of the chat drawer now.
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
                    ? const _RailLottie(
                        asset: 'assets/animations/Message.json',
                        fallback: Icons.forum_rounded,
                        recolour: _strokesInInk,
                      )
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

/// The chat bubble's strokes, in the rail's ink.
List<ValueDelegate<Object>> _strokesInInk(Color ink, Color paper) => [
  ValueDelegate.strokeColor(const ['**'], value: ink),
];

/// The quick-message envelope in the drawer's ink (owner, 14 Sep 2026: black):
/// the envelope, its flap, the @, the paper plane and its dotted trail take the
/// ink, the letter takes the paper so it shows against the envelope it rises
/// out of, and the disc behind it all is hidden, so the envelope stands on the
/// key itself. Matched by layer and group name; test/message_glyph_test.dart
/// fails if a replacement file renames them.
List<ValueDelegate<Object>> _envelopeInInk(Color ink, Color paper) => [
  ValueDelegate.transformOpacity(const ['background Outlines'], value: 0),
  // The flap, the front's centre and the plane in the ink; the front's side
  // folds and the inside of the back in a lighter shade of it. All in the one
  // ink, a closed envelope was a featureless bar for much of the loop (QA 14
  // Sep 2026); the second shade draws its folds back in.
  for (final path in const [
    ['front Outlines', 'Group 2', '**'],
    ['opener Outlines', '**'],
    ['plane Outlines', '**'],
  ])
    ValueDelegate.color(path, value: ink),
  for (final path in const [
    ['front Outlines', 'Group 1', '**'],
    ['back Outlines', '**'],
  ])
    ValueDelegate.color(path, value: Color.lerp(ink, paper, 0.45)!),
  ValueDelegate.color(const [
    'mail inside Outlines',
    'Group 1',
    '**',
  ], value: ink),
  ValueDelegate.color(const [
    'mail inside Outlines',
    'Group 2',
    '**',
  ], value: paper),
  ValueDelegate.strokeColor(const ['Shape Layer 1', '**'], value: ink),
];

/// An animated chat glyph (owner, 14 Sep 2026): the rail's chat key and the
/// chat drawer's first tab play `assets/animations/Message.json`, a speech
/// bubble that writes its lines, and the drawer's quick-message tab
/// `assets/animations/Quick message.json`, an envelope that opens, sends a
/// paper plane and closes. Each loops while [animate].
///
/// [recolour] gives the file's colours in terms of the rail's ink — the
/// theme's onSurface at full strength, black on the light theme and white on
/// the dark — and its paper, the surface. It is full strength because a colour
/// handed to the delegates is painted solid: the key's translucent icon ink
/// came out solid black on TP_Tall all the same. The rail rebuilds every second
/// (it watches GameState for the chat cooldown), and a new [ValueDelegate]
/// never compares equal to the last one, so the delegates are built once per
/// pair of colours rather than once per build; otherwise every tick would
/// re-resolve every path.
class _RailLottie extends StatefulWidget {
  const _RailLottie({
    required this.asset,
    required this.fallback,
    this.recolour,
    this.size = 26,
    this.art,
    this.artShift = Offset.zero,
    this.animate = true,
  });

  final String asset;

  /// The glyph the key had before; drawn if the file cannot be loaded.
  final IconData fallback;

  /// The file's colours in terms of the rail's ink and paper; null keeps the
  /// file's own.
  final List<ValueDelegate<Object>> Function(Color ink, Color paper)? recolour;

  /// The square the glyph takes in the key's layout, in dp.
  final double size;

  /// The square the animation is drawn into when that is larger than [size]:
  /// centred on it and painted past its edges, so the art grows while the key
  /// keeps its size. Null draws it into [size].
  final double? art;

  /// Moves the art so its drawn content, rather than its canvas, is centred.
  final Offset artShift;

  /// False holds the glyph on its current frame.
  final bool animate;

  @override
  State<_RailLottie> createState() => _RailLottieState();
}

class _RailLottieState extends State<_RailLottie> {
  (Color, Color)? _colours;
  LottieDelegates? _delegates;

  @override
  Widget build(BuildContext context) {
    final recolour = widget.recolour;
    if (recolour == null) {
      _colours = null;
      _delegates = null;
    } else {
      final scheme = Theme.of(context).colorScheme;
      final colours = (scheme.onSurface.withValues(alpha: 1), scheme.surface);
      if (colours != _colours) {
        _colours = colours;
        _delegates = LottieDelegates(values: recolour(colours.$1, colours.$2));
      }
    }
    final art = widget.art ?? widget.size;
    Widget glyph = RepaintBoundary(
      child: SizedBox.square(
        dimension: art,
        child: Lottie.asset(
          widget.asset,
          delegates: _delegates,
          animate: widget.animate,
          fit: BoxFit.contain,
          // A missing or unreadable file must not leave a blank key.
          errorBuilder: (context, error, stack) =>
              Icon(widget.fallback, size: 22),
        ),
      ),
    );
    if (widget.art != null) {
      glyph = OverflowBox(
        minWidth: art,
        maxWidth: art,
        minHeight: art,
        maxHeight: art,
        child: Transform.translate(offset: widget.artShift, child: glyph),
      );
    }
    return SizedBox.square(dimension: widget.size, child: glyph);
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
          // The press-scale is a Listener over the capsule, so the capsule's
          // own ink and tap are untouched; only the feel of the key changes.
          child: PressScale(
            child: GlassCapsule(
              radius: Radii.md,
              padding: EdgeInsets.zero,
              minHeight: height,
              onTap: onTap,
              child: Center(child: child),
            ),
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
                  // Light or dark in one tap, where the table code was (owner,
                  // 13 Sep 2026). The System · Dark · Light choice stays at the
                  // foot of the menu.
                  _ThemeFlip(tooltip: t.switchTheme),
                  const SizedBox(width: Space.xs),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Only a private table keeps its code here: it is how
                        // friends are let in, and nothing else shows it.
                        // One line, shrunk to fit rather than broken: a code
                        // split across two lines ("Table CMU4 / 2LFF" on a
                        // 640dp phone, QA 14 Sep 2026) reads as two codes.
                        if (room.isPrivate)
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Table ${room.code}',
                              maxLines: 1,
                              softWrap: false,
                              style: AppTheme.money(
                                theme.textTheme.titleMedium ??
                                    const TextStyle(),
                              ),
                            ),
                          ),
                        Text(
                          // The category is server-owned ASCII, so tracked
                          // capitals are safe on it; the hand number is not
                          // translated either.
                          '${room.category.toUpperCase()}  ·  hand ${room.handNo}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.smallCaps(
                            theme.textTheme.labelSmall ?? const TextStyle(),
                            colour: scheme.onSurface.withValues(
                              alpha: AppTheme.inkLowOn(theme.brightness),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // How long this sitting has lasted. Top right, above the
                  // close key, because it is a fact about the table rather
                  // than an action on it.
                  const _SeatedFor(),
                  const SizedBox(width: Space.xs),
                  PressScale(
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              ),
            ),
            // A private table cannot be swapped for another — the server
            // refuses it — so it is not offered there, rather than offered and
            // then refused with a toast (QA 14 Sep 2026).
            if (!room.isPrivate) ...[
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
                // Which stake the new table will be: it repeated its own
                // title before, with the category left in English.
                note:
                    '${room.category == 'blind' ? t.blind : t.seen} · ${formatChips(room.bootAmount)}',
                onTap: state.switching
                    ? null
                    : () async {
                        Navigator.pop(context);
                        await _confirmSwitch(context, state, room);
                      },
              ),
              const _MenuRule(),
            ],
            _MenuRow(
              icon: Icons.logout_rounded,
              label: t.leaveTable,
              // What leaving costs right now (QA PIX-4, 14 Sep 2026): it said
              // "join another straight away" in the middle of a hand too.
              note: state.inLiveHand ? t.leaveStakeStays : t.joinAnother,
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
            // Appearance: System · Dark · Light as one segmented control, in
            // place of the day/night toggle row. The switcher selects the
            // mode itself and calls GameState.setThemeMode; nothing here
            // reads the theme.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                Space.md,
                Space.lg,
                Space.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.palette_outlined,
                        size: 16,
                        color: scheme.onSurface.withValues(
                          alpha: AppTheme.inkLowOn(theme.brightness),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: Text(
                          t.appearance,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.label(
                            theme.textTheme.labelMedium ?? const TextStyle(),
                            colour: scheme.onSurface.withValues(
                              alpha: AppTheme.inkLowOn(theme.brightness),
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
          ],
        ),
      ),
    );
  }
}

/// The drawer's light/dark key. One tap flips the theme the table is drawn in;
/// from the System setting it flips away from whatever the phone is showing
/// ([GameState.toggleTheme]). It shows where the tap goes — a moon in the
/// light theme, a sun in the dark.
class _ThemeFlip extends StatelessWidget {
  const _ThemeFlip({required this.tooltip});

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return PressScale(
      child: IconButton(
        tooltip: tooltip,
        onPressed: () {
          tapHaptic(context);
          context.read<GameState>().toggleTheme();
        },
        icon: AnimatedSwitcher(
          duration: Motion.fast,
          child: Icon(
            dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
            key: ValueKey(dark),
            color: dark ? AppTheme.goldBright : AppTheme.goldDeep,
          ),
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
                    // Neutral ink even under a toned label: the error red at
                    // the quiet alpha measured 2:1 under "Leave table", and
                    // the red label above it already says the row costs.
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurface.withValues(
                        alpha: AppTheme.inkLowOn(theme.brightness),
                      ),
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

    // The press-scale sits outside the InkWell as a raw pointer Listener, so
    // the row keeps its tap and its ink exactly as they were.
    return PressScale(
      child: InkWell(
        // Material's own click, gated on the player's Sound switch —
        // otherwise a silenced game would still tick on every tap.
        enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Dim.minTouch),
          child: body,
        ),
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
  // The flat half of the pair: the theme keeps a text button shadowless, so a
  // shadow under "stay" never fights the key it defers to.
  GlassButton(
    style: GlassButtonStyle.text,
    onPressed: () => Navigator.pop(context, false),
    label: stay,
  ),
  // The acting key: the one solid gold fill, on ink900 in both brightnesses,
  // and never under the 44dp touch floor.
  GlassButton(
    style: GlassButtonStyle.primary,
    onPressed: () => Navigator.pop(context, true),
    minimumSize: const Size(120, Dim.minTouch),
    buttonStyle: FilledButton.styleFrom(
      backgroundColor: AppTheme.gold,
      foregroundColor: AppTheme.ink900,
    ),
    label: go,
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

  // No confirmation (owner's decision, 10 Sep 2026). Switching is cheap and
  // recoverable — the player keeps their chips and can switch straight back —
  // so a dialog in front of it was a question with only one interesting
  // answer. The mid-hand case is the one that costs something: the stake
  // already in the pot stays there. That is now told rather than asked, in the
  // notice below, after the move.
  //
  // Nothing here touches `context`. This is reached from a drawer row that
  // pops itself before calling, so that element is already unmounted; the
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

  // The one thing the dialog used to say that was worth saying. Leaving
  // mid-hand packs your cards and your stake stays in the pot behind you —
  // told after the fact rather than asked before it, because it is a
  // consequence to know about, not a decision to take twice.
  if (midHand) state.notice = state.t.switchMidHand;

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
      // The room's own ink, not a bare black: a scrim in both brightnesses,
      // since the veil covers the whole screen for half a second and dims it
      // rather than following it.
      color: AppTheme.ink900.withValues(alpha: 0.42),
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
                  colour: AppTheme.onTable(
                    theme.colorScheme,
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
  final leave = await showDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: _dialogTitle(context, Icons.logout_rounded, state.t.leaveTableQ),
      // Read live: a hand can be dealt while the dialog is up, and then
      // leaving costs the boot (QA PIX-4, 14 Sep 2026).
      content: Builder(
        builder: (context) => Text(
          context.select<GameState, bool>((s) => s.inLiveHand)
              ? state.t.leaveMidHand
              : state.t.leaveAnytime,
        ),
      ),
      actions: _dialogActions(context, stay: state.t.stay, go: state.t.leave),
    ),
  );

  if (leave == true) state.leaveTable();
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
  final go = await showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return _WhileStillOpen(
        open: stillOpen,
        child: GlassDialog(
          padding: const EdgeInsets.all(Space.xl),
          title: _dialogTitle(context, Icons.hardware, t.forceSideshowTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.forceSideshowBody(name)),
              const SizedBox(height: Space.sm),
              Text(
                t.forceSideshowNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(
                    alpha: AppTheme.inkLowOn(theme.brightness),
                  ),
                ),
              ),
            ],
          ),
          actions: _dialogActions(context, stay: t.cancel, go: t.force),
        ),
      );
    },
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
  final shop = await showDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: _dialogTitle(context, Icons.hardware, t.noHammersTitle),
      content: Text(t.noHammersBody),
      actions: _dialogActions(context, stay: t.cancel, go: t.getHammers),
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
  final go = await showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return _WhileStillOpen(
        open: stillOpen,
        child: GlassDialog(
          padding: const EdgeInsets.all(Space.xl),
          title: _dialogTitle(context, missileIcon, t.fireMissileTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.fireMissileBody),
              const SizedBox(height: Space.sm),
              Text(
                t.fireMissileNote,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(
                    alpha: AppTheme.inkLowOn(theme.brightness),
                  ),
                ),
              ),
            ],
          ),
          actions: _dialogActions(context, stay: t.cancel, go: t.fire),
        ),
      );
    },
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
  final shop = await showDialog<bool>(
    context: context,
    builder: (context) => GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: _dialogTitle(context, missileIcon, t.noMissilesTitle),
      content: Text(t.noMissilesBody),
      actions: _dialogActions(context, stay: t.cancel, go: t.getMissiles),
    ),
  );
  if (shop != true || !context.mounted) return;
  await showChipStore(context, opensOn: StoreTab.missiles);
}

/// Gold as *ink*: champagne on charcoal, deep gold on parchment.
///
/// Anything drawn on the cloth is always on charcoal, so it asks for
/// [AppTheme.goldBright] directly; this is for the chrome that follows the
/// theme.
Color _goldInk(Brightness b) =>
    b == Brightness.dark ? AppTheme.goldBright : AppTheme.goldDeep;

class _Felt extends StatefulWidget {
  const _Felt();

  /// Where each seat sits on the felt, as a fraction of it, in view order:
  /// the viewer at the bottom, then clockwise from their left.
  /// A seat's column is pod, then cards, then its bet chip — about half the
  /// felt's height in all — so the top pair sit well clear of the rim or their
  /// names are clipped off by it.
  ///
  /// The columns also have to clear each OTHER sideways. The viewer's column
  /// is reversed, so its status line sits above their pod — at very nearly the
  /// height the top pair's "in pot" line sits below theirs. With the top-left
  /// seat at 0.260 and the viewer at 0.335 those two lines were 0.075 of the
  /// width apart inside columns 0.163 wide, and they ran together into one
  /// unreadable sentence ("in pot 2,200 • Pack"). Widened on 10 Sep 2026, and
  /// there is room to spread now: with the cloth gone nothing clips a pod for
  /// reaching past where the oval used to be.
  ///
  /// The viewer sits at 0.265 rather than centred because their fanned hand is
  /// drawn to the RIGHT of their pod, and the key cluster now occupies the
  /// bottom-right corner. Those two collided at 0.375 — the plus key ended up
  /// underneath the third card — so the whole column moved left until the hand
  /// clears the cluster with room to spare. Their dy moved 0.28 -> 0.335 on 10 Sep 2026
  /// when the pods grew. The anchor is the column's MIDDLE, so a taller column
  /// hangs further above it — and the column's height is not fixed: a seat
  /// showing a revealed hand carries its hand name, its badge and its pot line
  /// as well, which is why the winner's pod was the one losing its top edge
  /// while the seat beside it at the same dy was fine. The figure has to clear
  /// the tallest state a column can reach, not the common one.
  static const List<Offset> _places = [
    Offset(0.265, 0.00), // you — x only; the pair below sit on the floor
    Offset(0.055, 0.44), // left
    Offset(0.275, 0.30), // top left
    Offset(0.725, 0.30), // top right
    Offset(0.945, 0.44), // right
  ];

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
  /// speaks when no hand is running, so it can have the high ground.
  static const double _statusDy = 0.28;

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
  State<_Felt> createState() => _FeltState();
}

/// The felt's state: a Force Sideshow's hammer, a missile volley, and where
/// the pods they fly between actually stand.
class _FeltState extends State<_Felt> with TickerProviderStateMixin {
  static const _places = _Felt._places;
  static const _potDy = _Felt._potDy;
  static const _statusDy = _Felt._statusDy;
  static const _tagDy = _Felt._tagDy;
  static Offset _seatCentre(
    GameState state,
    int seatIndex,
    double w,
    double h,
    double podW,
  ) => _Felt._seatCentre(state, seatIndex, w, h, podW);

  /// One key per place, naming that place's pod. A column's middle is known
  /// from [_places], but where the pod sits in it depends on everything under
  /// it — cards, a hand name, a bet — so the hammer is aimed at the pod as it
  /// was actually laid out, not at a guess.
  final List<GlobalKey> _podKeys = List.generate(
    _Felt._places.length,
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
    final ownHandName =
        myReveal?.handName ??
        (wonSideshow(myPeek?.userId) ? myPeek?.handName : null);
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

          Widget pod(int viewIndex) {
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

            return SeatPod(
              revealed: reveal?.cards ?? peek?.cards,
              revealedHand:
                  reveal?.handName ??
                  (wonSideshow(peek?.userId) ? peek?.handName : null),
              seat: s,
              // The orb leaks towards open felt: away from the rail on the left
              // seat, off the top edge for the top two, and away from the
              // screen edge on the right seat. The viewer's stays inside their
              // glass — the missed-turns plate and their own cards leave it
              // nowhere to go (on TP_Small it lay under the plate).
              orbCorner: viewIndex == 0
                  ? OrbCorner.contained
                  : viewIndex.isOdd
                  ? OrbCorner.topRight
                  : OrbCorner.topLeft,
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
              podKey: viewIndex < _podKeys.length ? _podKeys[viewIndex] : null,
              impact: _flight?.targetView == viewIndex
                  ? _hammer
                  : _volleyJolts[viewIndex],
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
          final potCentre = Offset(0.5 * w, _potDy * h);
          Offset seatCentre(int seatIndex) =>
              _seatCentre(state, seatIndex, w, h, podW);

          // The cloth is gone (owner's decision, 10 Sep 2026) and nothing else
          // moved: every position in this Stack is computed from the
          // LayoutBuilder's box, not from the table that used to be drawn
          // inside it, so removing the drawing leaves the seats exactly where
          // they were. Dropping the ClipRRect with it also means a pod at the
          // rim can no longer lose its edge to the oval's curve.
          return Stack(
            key: _stageKey,
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
              // The table's furniture first, the seats after it: a seat's
              // speech bubble or bet chip is a moment that matters more
              // than the tag or the pot label it might briefly cross, so
              // the seats paint on top.
              at(
                const Offset(0.5, _tagDy),
                _CategoryTag(room: room),
                width: w * 0.30,
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
              at(
                const Offset(0.5, _statusDy),
                _Status(room: room),
                // Narrower than it looks like it needs to be: at this height
                // the line sits between the two top seats, whose pods paint
                // over it, so a long line (the buy-chips countdown) has to
                // shrink into the gap instead of running under them.
                width: w * 0.28,
              ),

              for (var i = 1; i < _places.length; i++) at(_places[i], pod(i)),

              // The viewer's pod and hand stand on the floor of the table
              // rather than being centred on a point: their columns are
              // different heights, so centring both left one hanging over the
              // rim and clipped by it. A shared bottom line keeps them inside
              // and flush with the edge.
              Positioned(
                left: _places[0].dx * w - podW / 2,
                bottom: h * 0.012,
                width: podW,
                child: pod(0),
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
                left: _places[0].dx * w + podW / 2 + Space.md,
                bottom: h * 0.012,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // The viewer's own hand name at a showdown, over their
                    // cards, so the seat that matters most to them is not the
                    // one seat that has to work out what it won with — and
                    // after a sideshow they won, which it names the same way.
                    if (ownHandName != null) ...[
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
                    _OwnHand(cardHeight: handH, revealed: myReveal?.cards),
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
/// between the two top seats, under the category tag and over the pot.
///
/// The foot of the screen is the viewer's own pod, hand and keys, and a band
/// 40% of the width over the pot ran across the top seats' card fans and their
/// SEEN labels, hiding who had looked. Every seat's column is exactly a pod
/// wide and placed from [_Felt._places], so the gap between the top pair is
/// worked out here from the numbers [_Felt] lays them out with rather than
/// guessed as a share of the screen: about 214dp wide on a Pixel 7 Pro, 150 on
/// a 640dp phone and 370 on a tablet. Nothing is drawn there during a hand;
/// between hands the waiting line stands in it, and a notice may cover that
/// for the moment it shows.
Rect tableNoticeArea(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final safe = MediaQuery.paddingOf(context);
  final scaler = MediaQuery.textScalerOf(context);
  final text = Theme.of(context).textTheme;

  // The felt's box as TableScreen lays it out: inside the SafeArea, right of
  // the rail, inside the felt's own padding (_Felt.build).
  final pad = Dim.feltPad(size.width);
  final feltLeft = safe.left + Dim.railW(size.width) + pad;
  final feltTop = safe.top + Space.xxs;
  final w = size.width - safe.right - pad - feltLeft;
  final h = size.height - safe.bottom - feltTop;
  final podW = Dim.podW(w, h);

  // A column's left edge, clamped inside the felt exactly as _Felt.at() does.
  double columnLeft(Offset place) =>
      (place.dx * w - podW / 2).clamp(0.0, math.max(0.0, w - podW)).toDouble();
  final left = feltLeft + columnLeft(_Felt._places[2]) + podW + Space.md;
  final right = feltLeft + columnLeft(_Felt._places[3]) - Space.md;

  // The tag and the pot are each one line of type on a plate: the line, the
  // plate's padding above and below it, and its hairline.
  double plate(TextStyle? style) =>
      scaler.scale(style?.fontSize ?? 14) * (style?.height ?? 1.3) +
      2 * Space.xs +
      2 * Dim.hairline;
  final top =
      feltTop + _Felt._tagDy * h + plate(text.labelMedium) / 2 + Space.sm;
  final bottom =
      feltTop + _Felt._potDy * h - plate(text.titleLarge) / 2 - Space.sm;

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

    return _Plate(
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
                      style: AppTheme.money(
                        theme.textTheme.titleLarge ?? const TextStyle(),
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
    final graceLeft = room.you?.unfundedSecondsLeft(DateTime.now());
    final line = graceLeft != null ? state.t.buyChipsToStay(graceLeft) : text;

    if (line.isEmpty) return const SizedBox.shrink();

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
        // The countdown keeps one key, so its ticking seconds do not
        // cross-fade the line every second.
        key: ValueKey(graceLeft != null ? 'unfunded-grace' : line),
        fit: BoxFit.scaleDown,
        child: Text(
          line,
          style:
              AppTheme.label(
                base,
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
  const _OwnHand({required this.cardHeight, this.revealed});
  final double cardHeight;

  /// The viewer's own cards as the showdown turned them over.
  ///
  /// Only ever needed by a player who paid for a show without looking first:
  /// `you.cards` stays empty while a seat is blind and the server does not
  /// un-blind the seat at the showdown, so their own hand would be the one
  /// hand on the table still face down — under a SEE button, at the moment
  /// they are being told they won with it.
  final List<String>? revealed;

  /// How far each card is turned out of the fan, in radians. Small: three
  /// cards held in one hand are barely splayed at all.
  static const double _fan = 0.078;

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
    // This table's blind allowance, from the menu the server sent with the
    // room; 4 when the room is not on it (a private table).
    final room = state.room!;
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
                          color: AppTheme.goldBright.withValues(alpha: 0.55),
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
                              style: AppTheme.label(
                                theme.textTheme.labelLarge ?? const TextStyle(),
                                colour: AppTheme.goldBright,
                                weight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: Space.xs),
                            _BlindDots(left: you.blindMovesLeft, max: maxBlind),
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
/// that is the only illegal-move signal the game has. The press-scale and the
/// light haptic are laid over it; the caller's callback is called as before.
class _MachinedKey extends StatelessWidget {
  const _MachinedKey({
    required this.width,
    required this.height,
    required this.label,
    required this.onPressed,
    this.icon,
    this.glyph,
    this.amount,
    this.detail,
    this.primary = false,
    this.edge,
    this.alive = false,
    this.muted = false,
    this.stackLabel = false,
  }) : assert(icon != null || glyph != null, 'a key needs an icon or a glyph');

  final double width;
  final double height;
  final IconData? icon;

  /// Drawn in place of [icon]: an animated glyph, like Force Sideshow's hammer.
  final Widget? glyph;
  final String label;

  /// Puts a two-word [label] on two lines, so a long name keeps its size in a
  /// narrow key (Force Sideshow, owner 14 Sep 2026: the whole name, not "Force").
  final bool stackLabel;

  /// The second line: what the move costs, or who it is aimed at. Omitted
  /// leaves the label on its own.
  final String? amount;

  /// A second line drawn rather than written, in [amount]'s type: a cost that
  /// is more than one figure (the Missile key's missile and chips). Takes the
  /// place of [amount].
  final Widget Function(TextStyle style)? detail;
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

  /// Drawn as inert while it still answers a tap. For a move the rules allow
  /// but the player cannot pay for — Force Sideshow with no hammers — where
  /// the tap is what offers the way to pay.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final brightness = theme.brightness;
    final ink = primary ? AppTheme.ink900 : scheme.onSurface;
    final live = edge ?? AppTheme.hairlineColour(brightness, live: true);
    final halo = edge ?? (primary ? AppTheme.gold : AppTheme.goldBright);
    final amountStyle = AppTheme.money(
      theme.textTheme.bodySmall ?? const TextStyle(),
      weight: FontWeight.w600,
    );

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
    final press = onPressed;

    return Opacity(
      opacity: dead || muted ? 0.42 : 1,
      child: _KeyPulse(
        alive: alive,
        colour: halo,
        radius: Radii.md,
        // Inside the pulse, so the halo stays put while the key itself dips
        // under the thumb. A Listener, so the button keeps every tap it had.
        child: PressScale(
          enabled: !dead,
          child: FilledButton(
            onPressed: press,
            style: style,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                glyph ?? Icon(icon, size: 18),
                SizedBox(width: stackLabel ? Space.xs : Space.sm),
                Flexible(
                  child: stackLabel
                      // The two lines scale together, inside the key's width
                      // and height, rather than each shrinking on its own.
                      // A stacked label carries no amount line.
                      ? FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            label.replaceFirst(' ', '\n'),
                            maxLines: 2,
                            style: AppTheme.label(
                              theme.textTheme.labelLarge ?? const TextStyle(),
                              weight: FontWeight.w700,
                            ).copyWith(height: 1.1),
                          ),
                        )
                      : Column(
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
                                  theme.textTheme.labelLarge ??
                                      const TextStyle(),
                                  weight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (detail != null || amount != null)
                              // A crore-sized bet is a long word; it shrinks to
                              // fit rather than losing its tail to an ellipsis.
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child:
                                    detail?.call(amountStyle) ??
                                    Text(
                                      amount!,
                                      maxLines: 1,
                                      style: amountStyle,
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
    final press = onPressed;

    return PressScale(
      enabled: press != null,
      child: IconButton.filledTonal(
        onPressed: press,
        iconSize: 22,
        style: _stepperStyle(theme).copyWith(
          fixedSize: WidgetStatePropertyAll(Size(Dim.minTouch, height)),
          // Exactly 44 wide, not the 48 a padded tap target would take.
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.md),
            ),
          ),
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? BorderSide(
                    color: AppTheme.ink400.withValues(alpha: 0.30),
                    width: Dim.hairline,
                  )
                : BorderSide(
                    color: AppTheme.hairlineColour(
                      theme.brightness,
                      live: true,
                    ),
                    width: Dim.hairline,
                  ),
          ),
        ),
        icon: Icon(icon),
      ),
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

/// The chat drawer's two pages.
enum _ChatView { chat, quick }

class _ChatDrawerState extends State<_ChatDrawer> {
  final _input = TextEditingController();

  /// Which page is up. Every opening starts on the conversation — the drawer
  /// goes back to the menu once it closes, so this state is new each time —
  /// because the conversation is what the rail's key promised.
  _ChatView _view = _ChatView.chat;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final t = state.t;
    // On a landscape phone the soft keyboard leaves the panel about a
    // hundred and fifty points tall — less than the title, the rule and the
    // composer need, and the shortfall painted overflow stripes across the
    // table. While the player is typing the title is decoration and the
    // history behind it is hidden anyway, so both stand down and the composer
    // gets the whole panel.
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;

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
              if (!typing)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Space.md,
                    Space.md,
                    Space.xs,
                    Space.xs,
                  ),
                  // The quick messages are a tab here (owner, 14 Sep 2026;
                  // they had a rail key and a drawer of their own). Both are
                  // how a player talks to the table, and from the top of the
                  // one drawer either is a tap away.
                  child: Row(
                    children: [
                      Expanded(
                        child: _ChatTab(
                          label: t.tableChat,
                          selected: _view == _ChatView.chat,
                          onTap: () => setState(() => _view = _ChatView.chat),
                          glyph: _RailLottie(
                            asset: 'assets/animations/Message.json',
                            fallback: Icons.forum_rounded,
                            recolour: _strokesInInk,
                            size: 24,
                            animate: _view == _ChatView.chat,
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.xs),
                      Expanded(
                        child: _ChatTab(
                          label: t.quickMessagesTitle,
                          selected: _view == _ChatView.quick,
                          onTap: () => setState(() => _view = _ChatView.quick),
                          // The rail's proportions (a 56dp canvas in a 30dp
                          // slot, lifted 2dp), scaled to the tab.
                          glyph: _RailLottie(
                            asset: 'assets/animations/Quick message.json',
                            fallback: Icons.quickreply_rounded,
                            recolour: _envelopeInInk,
                            size: 24,
                            art: 45,
                            artShift: const Offset(0, -1.6),
                            animate: _view == _ChatView.quick,
                          ),
                        ),
                      ),
                      PressScale(
                        child: IconButton(
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                    ],
                  ),
                ),
              if (!typing) const _MenuRule(),
              if (_view == _ChatView.quick)
                Expanded(child: _quickLines(state))
              else ...[
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
                      final colour = state.colourFor(
                        m.userId,
                        theme.colorScheme,
                      );

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: Space.xxs,
                        ),
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
                        // The composer on glass: the same controller, limit,
                        // hint and submit, with the field's fill from the
                        // glass tokens rather than the bare input theme. The
                        // counter stays hidden (the component's default).
                        child: GlassTextField(
                          controller: _input,
                          maxLength: 200,
                          hintText: t.saySomething,
                          decoration: const InputDecoration(isDense: true),
                          onSubmitted: (_) => _send(state),
                        ),
                      ),
                      const SizedBox(width: Space.md),
                      PressScale(
                        enabled: state.canChat,
                        child: IconButton.filled(
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
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The quick messages page: set lines a player can say in one tap —
  /// "Please Play Blind.", "Please take show." and the rest of
  /// [Strings.quickMessages] (owner, 13 Sep 2026).
  ///
  /// A column of the drawer rather than chips over the felt: ten sentences, in
  /// scripts that run long, need a column of room, and the felt has none to
  /// spare. Each goes out through [GameState.sendChat] exactly as typed chat
  /// does — free text in the sender's own language, so the protocol does not
  /// change — and lands as their bubble and in the chat like anything typed.
  /// They share the chat's cooldown, and each row counts it down.
  Widget _quickLines(GameState state) {
    final lines = state.t.quickMessages;
    final left = state.chatCooldownLeft;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      itemCount: lines.length,
      itemBuilder: (context, i) => _QuickLine(
        text: lines[i],
        secondsLeft: left,
        onTap: state.canChat ? () => _sendQuick(state, lines[i]) : null,
      ),
    );
  }

  /// The same ending as a typed line: once it is out the drawer goes, and what
  /// the player sees next is their words over their own seat. A refusal (the
  /// cooldown caught between build and tap) leaves it open.
  void _sendQuick(GameState state, String line) {
    if (!state.sendChat(line)) return;
    Navigator.of(context).pop();
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

/// One of the chat drawer's two tabs, the conversation or the quick messages:
/// a glyph over its name, the whole tab the target. The tab that is up is
/// washed and ringed in gold, and only its glyph plays. The name shrinks to
/// fit rather than being cut: two tabs share a 260dp drawer on a 640dp phone.
class _ChatTab extends StatelessWidget {
  const _ChatTab({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.glyph,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget glyph;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    final gold = _goldInk(theme.brightness);
    final radius = BorderRadius.circular(Radii.md);

    return Semantics(
      button: true,
      selected: selected,
      child: PressScale(
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            enableFeedback: context.select<FeedbackSettings, bool>(
              (f) => f.sound,
            ),
            onTap: onTap,
            child: AnimatedContainer(
              duration: Motion.fast,
              constraints: const BoxConstraints(minHeight: Dim.minTouch),
              padding: const EdgeInsets.symmetric(
                horizontal: Space.xs,
                vertical: Space.xs,
              ),
              decoration: BoxDecoration(
                borderRadius: radius,
                color: selected
                    ? ink.withValues(alpha: 0.07)
                    : ink.withValues(alpha: 0),
                border: Border.all(
                  color: selected
                      ? gold.withValues(alpha: 0.75)
                      : gold.withValues(alpha: 0),
                  width: Dim.hairline,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  glyph,
                  const SizedBox(height: Space.xxs),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: ink.withValues(
                          alpha: selected ? AppTheme.inkHigh : AppTheme.inkMed,
                        ),
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

/// One sentence on the chat drawer's quick messages tab, the whole row its
/// target.
///
/// While the cooldown runs the row is disabled and says how many seconds are
/// left, rather than taking a tap that would do nothing and say nothing.
class _QuickLine extends StatelessWidget {
  const _QuickLine({
    required this.text,
    required this.secondsLeft,
    required this.onTap,
  });

  final String text;
  final int secondsLeft;

  /// Null while the cooldown runs.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface;
    final live = onTap != null;

    final row = ConstrainedBox(
      // Taller than the 44dp floor: a line is picked mid-hand, by thumb, from
      // a list, where a near miss says the wrong thing to the whole table.
      constraints: const BoxConstraints(minHeight: Dim.minTouch + Space.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 18,
              color: live
                  ? _goldInk(theme.brightness)
                  : ink.withValues(alpha: AppTheme.inkLow),
            ),
            const SizedBox(width: Space.lg),
            Expanded(
              child: Text(
                text,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: ink.withValues(
                    alpha: live ? AppTheme.inkHigh : AppTheme.inkLow,
                  ),
                ),
              ),
            ),
            if (!live) ...[
              const SizedBox(width: Space.md),
              Text(
                '${secondsLeft}s',
                // Tabular, so 4-3-2-1 does not shift the row by a pixel.
                style: AppTheme.money(
                  theme.textTheme.labelMedium ?? const TextStyle(),
                  colour: ink.withValues(alpha: AppTheme.inkMed),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    return Semantics(
      button: true,
      enabled: live,
      child: PressScale(
        enabled: live,
        child: InkWell(
          // Material's click, gated on the Sound switch like every menu row.
          enableFeedback: context.select<FeedbackSettings, bool>(
            (f) => f.sound,
          ),
          onTap: onTap,
          child: row,
        ),
      ),
    );
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
                BoxShadow(
                  color: AppTheme.goldBright.withValues(
                    alpha: 0.05 + 0.05 * breathe + 0.26 * flare,
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

/// How long the player has been sitting at this table, as h:mm:ss.
///
/// Counts its own seconds rather than riding GameState's ticker, and that is
/// the whole point of it being a separate widget. The table screen's build
/// deliberately watches nothing — a per-second rebuild up there tears down any
/// open drawer, which is exactly where this clock lives. Keeping the tick
/// local means the only thing repainting each second is these few characters.
///
/// The elapsed figure is derived from [GameState.seatedAt] on every frame
/// rather than counted up, so it stays right across a pause, a backgrounded
/// app, or a dropped frame — a counter that increments a variable drifts, and
/// a clock that drifts is worse than no clock.
class _SeatedFor extends StatefulWidget {
  const _SeatedFor();

  @override
  State<_SeatedFor> createState() => _SeatedForState();
}

class _SeatedForState extends State<_SeatedFor> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// h:mm:ss, with the hours unpadded so a short sitting reads "0:04:12"
  /// rather than "00:04:12" — nobody sits at a table for ten hours, and two
  /// leading digits imply somebody might.
  static String _clock(Duration d) {
    final t = d.isNegative ? Duration.zero : d;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.inHours}:${two(t.inMinutes % 60)}:${two(t.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final seatedAt = context.read<GameState>().seatedAt;
    if (seatedAt == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.schedule_rounded,
          size: 14,
          color: theme.colorScheme.onSurface.withValues(alpha: AppTheme.inkLow),
        ),
        const SizedBox(width: Space.xxs),
        Text(
          _clock(DateTime.now().difference(seatedAt)),
          // Tabular figures, or the whole row shuffles sideways every second
          // as the digits change width.
          style: AppTheme.money(
            theme.textTheme.labelMedium ?? const TextStyle(),
            colour: theme.colorScheme.onSurface.withValues(
              alpha: AppTheme.inkMed,
            ),
          ),
        ),
      ],
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
    final gap = Dim.gap(size.width);
    // The force key is as wide as the two steppers and the gap between them,
    // so the top row comes out exactly as wide as the − Chaal + row under it.
    // The cluster's footprint — which the viewer's hand and the right-hand
    // seat are laid out to clear — is the one it had with a single key on top.
    final forceW = 2 * Dim.minTouch + gap;

    return Padding(
      padding: EdgeInsets.fromLTRB(gap, gap, Dim.feltPad(size.width), gap),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: t.forceSideshow,
                child: _MachinedKey(
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
                  ? _MachinedKey(
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
                  : _MachinedKey(
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
              _StepperKey(
                icon: Icons.remove_rounded,
                height: keyH,
                onPressed: state.canStepDown ? () => state.stepBet(-1) : null,
              ),
              SizedBox(width: gap),
              _MachinedKey(
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
              _StepperKey(
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
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final canPack = state.myTurn && (state.options?.canPack ?? false);
    final gap = Dim.gap(size.width);

    return Padding(
      padding: EdgeInsets.fromLTRB(Dim.feltPad(size.width), gap, gap, gap),
      child: _MachinedKey(
        width: Dim.keyW(size.width),
        height: Dim.keyH(size.height),
        icon: Icons.close_rounded,
        label: state.t.pack,
        alive: canPack,
        edge: theme.colorScheme.error.withValues(alpha: 0.45),
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
class _MissileKey extends StatelessWidget {
  const _MissileKey();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<GameState>();
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final gap = Dim.gap(size.width);
    final canFire = state.canMissile && !state.firingMissile;
    final hasMissile = state.hasMissile;
    final t = state.t;

    return Padding(
      // Pack's own padding carries the gap between the two keys.
      padding: EdgeInsets.fromLTRB(Dim.feltPad(size.width), gap, gap, 0),
      child: Tooltip(
        message: t.missile,
        child: _MachinedKey(
          width: Dim.keyW(size.width),
          height: Dim.keyH(size.height),
          glyph: _MissileGlyph(animate: canFire),
          label: t.missile,
          // What firing takes, under its name as Chaal's bet is (owner,
          // 14 Sep 2026): one missile, and the chips a show would cost — held
          // by the server's rule, not paid.
          detail: (style) => _MissileCost(
            missiles: missileCost,
            chips: state.missileChips,
            style: style,
          ),
          edge: missileInkOn(theme.brightness).withValues(alpha: 0.5),
          alive: canFire && hasMissile,
          muted: canFire && !hasMissile,
          onPressed: canFire ? () => _fireMissile(context, state) : null,
        ),
      ),
    );
  }
}

/// The Missile key's second line: the missile a shot spends and the chips it
/// needs the player to hold, each beside its mark — the rocket the wallets
/// count missiles with, and a chip (owner, 14 Sep 2026).
class _MissileCost extends StatelessWidget {
  const _MissileCost({
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
        style: AppTheme.smallCaps(
          theme.textTheme.labelMedium ?? const TextStyle(),
          tracking: 0.8,
          colour: theme.brightness == Brightness.dark
              ? AppTheme.goldBright
              : AppTheme.goldDeep,
        ),
      ),
    );
  }
}
