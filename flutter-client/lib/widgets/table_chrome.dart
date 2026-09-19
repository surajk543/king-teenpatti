import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../settings/feedback_settings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import 'feedback_toggles.dart';
import 'glass_components.dart';
import 'glass_panels.dart';
import 'picture_shelf.dart';
import 'premium_surface.dart';
import 'rules_sheet.dart';
import 'table_ground.dart';

/// The chrome every table screen shares — the Teen Patti felt and the poker
/// felt alike: the room's ground, the rail with the menu and the chat, the
/// two drawers, the wallet in the corner, the reconnecting plate, the machined
/// keys and the plate everything on the cloth stands on. Moved out of
/// table_screen.dart unchanged when the poker family arrived, so the two
/// screens are one room with different games on the cloth.
///
/// Where each seat sits on the felt, as a fraction of it, in view order: the
/// viewer at the bottom, then clockwise from their left. The felt's own copy
/// (`_Felt._places`) is this list; the wallet measures its corner from it.
const List<Offset> seatPlaces = [
  Offset(0.265, 0.00), // you — x only; the pair below sit on the floor
  Offset(0.055, 0.44), // left
  Offset(0.275, 0.30), // top left
  Offset(0.725, 0.30), // top right
  Offset(0.945, 0.44), // right
];

/// Which of the two panels the left drawer is showing.
enum LeftPanel { menu, chat }

/// The left drawer's content, which tells the table when it has left the
/// screen.
///
/// A [DrawerController] builds its child only while the drawer is at least
/// partly open, so this slot is unmounted at the very moment the slide-out
/// ends — the one moment the panel behind the edge can change without being
/// seen to. A drag that crosses halfway and then settles open again never
/// unmounts it, so nothing changes under a player's thumb.
class DrawerSlot extends StatefulWidget {
  const DrawerSlot({super.key, required this.onGone, required this.child});

  /// Called from [State.dispose]: no setState here, only a request for later.
  final VoidCallback onGone;
  final Widget child;

  @override
  State<DrawerSlot> createState() => _DrawerSlotState();
}

class _DrawerSlotState extends State<DrawerSlot> {
  @override
  void dispose() {
    widget.onGone();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Diamonds, hammers and missiles, in the top-right corner of the room (owner,
/// 13 and 14 Sep 2026).
///
/// It stands on the Shop key's line, right-aligned with the key cluster below
/// it, and is never wider than the corner it has: from the felt's right edge
/// back to the top-right seat's pod and the glow spilling out of that pod's
/// corner ([tableWalletRoom]). Three-digit counts at the 1.25 text ceiling
/// on a 640dp phone would run past that, so there it scales down instead of
/// running under the pod. The right-hand seat's column starts below it, and
/// the notices stand between the top two seats ([tableNoticeArea]).
/// test/table_wallet_layout_test.dart checks it at 640x360, 891x411 and
/// 1280x800.
class TableWallet extends StatelessWidget {
  const TableWallet({super.key});

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
    final room = tableWalletRoom(context);
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
double tableWalletRoom(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final safe = MediaQuery.paddingOf(context);
  final pad = Dim.feltPad(size.width);
  final feltLeft = safe.left + Dim.railW(size.width) + pad;
  final feltTop = safe.top + Space.xxs;
  final w = size.width - safe.right - pad - feltLeft;
  final h = size.height - safe.bottom - feltTop;
  final podW = Dim.podW(w, h);

  final topRight = seatPlaces[3];
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
/// [WhileOnline] rests the keys beneath it.
///
/// It shows once the socket reports the loss. On a network that simply goes
/// dark that is the Engine.IO ping timeout — the server's 20s interval plus
/// its 25s grace — not the instant the signal goes.
class Reconnecting extends StatelessWidget {
  const Reconnecting({super.key});

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
                  child: Plate(
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
/// 14 Sep 2026). [Reconnecting] says why.
class WhileOnline extends StatelessWidget {
  const WhileOnline({super.key, required this.child});

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
class RoomGround extends StatelessWidget {
  const RoomGround({super.key});

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
class SideRail extends StatelessWidget {
  const SideRail({super.key, required this.onOpen, this.onRules});

  final void Function(LeftPanel) onOpen;

  /// A third key, under the chat: the rules of the game being played. Given
  /// only by the poker table (owner, 19 Sep 2026: "in each poker gameplay add
  /// an icon of rulebook"), where every game on the menu has different rules
  /// and the only way to them was the drawer. The Teen Patti table passes
  /// nothing and keeps two keys.
  final VoidCallback? onRules;

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
    //
    // A poker table puts the rulebook back in that third place: three keys and
    // two gaps are 3x46.8 + 20 = 160.4dp at 640x360, running y 97.8 to 258.2
    // in a 356dp column — still clear of the Shop key above and the Fold key
    // below, and every key still fills the rail, so each target is the whole
    // 48dp width.
    final railW = Dim.railW(size.width);
    final keyH = Dim.railButtonH(size.height);

    return SizedBox(
      width: railW,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RailKey(
              tooltip: t.tableMenu,
              width: railW,
              height: keyH,
              onTap: () => onOpen(LeftPanel.menu),
              child: const Icon(Icons.menu_rounded, size: 22),
            ),
            const SizedBox(height: Space.md),
            Badge(
              isLabelVisible: state.unreadChat > 0,
              backgroundColor: AppTheme.gold,
              textColor: AppTheme.ink900,
              label: Text('${state.unreadChat}'),
              child: RailKey(
                // While the cooldown runs the icon becomes the countdown, so
                // the player can see when they may speak again without opening
                // the chat to find out.
                tooltip: state.canChat
                    ? t.tableChat
                    : '${t.tableChat} ${state.chatCooldownLeft}s',
                width: railW,
                height: keyH,
                onTap: () => onOpen(LeftPanel.chat),
                child: state.canChat
                    ? const RailLottie(
                        asset: 'assets/animations/Message.json',
                        fallback: Icons.forum_rounded,
                        recolour: strokesInInk,
                      )
                    : ChatCountdown(
                        left: state.chatCooldownLeft,
                        total: GameState.chatCooldown.inSeconds,
                      ),
              ),
            ),
            if (onRules != null) ...[
              const SizedBox(height: Space.md),
              RailKey(
                // The lobby table cards' rules glyph, so the key a player
                // pressed to read the rules before sitting down is the same
                // key once they are at the table.
                tooltip: t.tableRulesKey,
                width: railW,
                height: keyH,
                onTap: onRules!,
                child: const Icon(Icons.menu_book_outlined, size: 22),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The chat bubble's strokes, in the rail's ink.
List<ValueDelegate<Object>> strokesInInk(Color ink, Color paper) => [
  ValueDelegate.strokeColor(const ['**'], value: ink),
];

/// The quick-message envelope in the drawer's ink (owner, 14 Sep 2026: black):
/// the envelope, its flap, the @, the paper plane and its dotted trail take the
/// ink, the letter takes the paper so it shows against the envelope it rises
/// out of, and the disc behind it all is hidden, so the envelope stands on the
/// key itself. Matched by layer and group name; test/message_glyph_test.dart
/// fails if a replacement file renames them.
List<ValueDelegate<Object>> envelopeInInk(Color ink, Color paper) => [
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
class RailLottie extends StatefulWidget {
  const RailLottie({
    super.key,
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
  State<RailLottie> createState() => _RailLottieState();
}

class _RailLottieState extends State<RailLottie> {
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
class RailKey extends StatelessWidget {
  const RailKey({
    super.key,
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
class TableDrawer extends StatelessWidget {
  const TableDrawer({super.key});

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
                        if (room.isPoker)
                          // A poker game's name is long ("Texas Hold'em ·
                          // hand 12"): shrunk to the line rather than cut to
                          // "Texas Hold'em · …" before the clock beside it.
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '${t.pokerVariantName(room.category)}  ·  hand ${room.handNo}',
                              maxLines: 1,
                              softWrap: false,
                              style: AppTheme.smallCaps(
                                theme.textTheme.labelSmall ??
                                    const TextStyle(),
                                colour: scheme.onSurface.withValues(
                                  alpha: AppTheme.inkLowOn(theme.brightness),
                                ),
                              ),
                            ),
                          )
                        else
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
              MenuRow(
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
                    '${room.isPoker
                        ? t.pokerVariantName(room.category)
                        : room.category == TableCategory.blind
                        ? t.blind
                        : room.category == TableCategory.variation
                        ? t.variation
                        : t.seen} · ${formatChips(room.bootAmount)}',
                onTap: state.switching
                    ? null
                    : () async {
                        Navigator.pop(context);
                        await _confirmSwitch(context, state, room);
                      },
              ),
              const MenuRule(),
            ],
            MenuRow(
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
            const MenuRule(),
            MenuRow(
              icon: Icons.savings_outlined,
              label: t.yourChips,
              value: formatChips(you?.chips ?? state.user?.chips ?? 0),
            ),
            MenuRow(
              icon: Icons.paid_outlined,
              // A poker room's figure is its big blind or its ante.
              label: room.isPoker
                  ? (room.poker?.usesBlinds ?? false
                        ? t.blindsTitle
                        : t.anteTitle)
                  : t.boot,
              value: formatChips(room.bootAmount),
            ),
            if (room.maxPot > 0)
              MenuRow(
                icon: Icons.trending_up_rounded,
                label: t.maxPot,
                value: formatChips(room.maxPot),
              ),
            const MenuRule(),
            MenuRow(
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
class MenuRule extends StatelessWidget {
  const MenuRule({super.key});

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
class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
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
                colour: goldInk(theme.brightness),
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
List<Widget> dialogActions(
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
Widget dialogTitle(BuildContext context, IconData icon, String text) {
  final theme = Theme.of(context);

  return Row(
    children: [
      Icon(icon, size: 20, color: goldInk(theme.brightness)),
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
      title: dialogTitle(context, Icons.logout_rounded, state.t.leaveTableQ),
      // Read live: a hand can be dealt while the dialog is up, and then
      // leaving costs the boot (QA PIX-4, 14 Sep 2026).
      content: Builder(
        builder: (context) => Text(
          context.select<GameState, bool>((s) => s.inLiveHand)
              ? state.t.leaveMidHand
              : state.t.leaveAnytime,
        ),
      ),
      actions: dialogActions(context, stay: state.t.stay, go: state.t.leave),
    ),
  );

  if (leave == true) state.leaveTable();
}

/// Gold as *ink*: champagne on charcoal, deep gold on parchment.
///
/// Anything drawn on the cloth is always on charcoal, so it asks for
/// [AppTheme.goldBright] directly; this is for the chrome that follows the
/// theme.
Color goldInk(Brightness b) =>
    b == Brightness.dark ? AppTheme.goldBright : AppTheme.goldDeep;

/// The engraved plate everything on the cloth is mounted on.
///
/// The cloth is dark emerald in both brightnesses, so a plate standing on it is
/// dark in both too, with light ink — a theme-following panel here would be a
/// white card on a green table in the morning.
class Plate extends StatelessWidget {
  const Plate({
    super.key,
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

/// The lift on an icon button that has a background of its own.
///
/// The button themes cover the labelled buttons; icon buttons are left out of
/// those on purpose, because most of the ones here — the menu, the chat, the
/// close on a sheet — are transparent, and a shadow under nothing visible is
/// just a smudge. This is applied to the ones that are filled.
ButtonStyle stepperStyle(ThemeData theme) =>
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
class MachinedKey extends StatelessWidget {
  const MachinedKey({
    super.key,
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
      child: KeyPulse(
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
class StepperKey extends StatelessWidget {
  const StepperKey({
    super.key,
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
        style: stepperStyle(theme).copyWith(
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
class ChatDrawer extends StatefulWidget {
  const ChatDrawer({super.key});

  @override
  State<ChatDrawer> createState() => _ChatDrawerState();
}

/// The chat drawer's two pages.
enum _ChatView { chat, quick }

class _ChatDrawerState extends State<ChatDrawer> {
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
                        child: ChatTab(
                          label: t.tableChat,
                          selected: _view == _ChatView.chat,
                          onTap: () => setState(() => _view = _ChatView.chat),
                          glyph: RailLottie(
                            asset: 'assets/animations/Message.json',
                            fallback: Icons.forum_rounded,
                            recolour: strokesInInk,
                            size: 24,
                            animate: _view == _ChatView.chat,
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.xs),
                      Expanded(
                        child: ChatTab(
                          label: t.quickMessagesTitle,
                          selected: _view == _ChatView.quick,
                          onTap: () => setState(() => _view = _ChatView.quick),
                          // The rail's proportions (a 56dp canvas in a 30dp
                          // slot, lifted 2dp), scaled to the tab.
                          glyph: RailLottie(
                            asset: 'assets/animations/Quick message.json',
                            fallback: Icons.quickreply_rounded,
                            recolour: envelopeInInk,
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
              if (!typing) const MenuRule(),
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
                          style: stepperStyle(theme).copyWith(
                            minimumSize: const WidgetStatePropertyAll(
                              Size(Dim.minTouch, Dim.minTouch),
                            ),
                          ),
                          icon: state.canChat
                              ? const Icon(Icons.send_rounded)
                              : ChatCountdown(
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
      itemBuilder: (context, i) => QuickLine(
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
class ChatTab extends StatelessWidget {
  const ChatTab({
    super.key,
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
    final gold = goldInk(theme.brightness);
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
class QuickLine extends StatelessWidget {
  const QuickLine({
    super.key,
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
                  ? goldInk(theme.brightness)
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
class ChatCountdown extends StatelessWidget {
  const ChatCountdown({super.key, required this.left, required this.total});

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
          fill: goldInk(theme.brightness),
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
class TurnBuzzer extends StatefulWidget {
  const TurnBuzzer({super.key});

  @override
  State<TurnBuzzer> createState() => _TurnBuzzerState();
}

class _TurnBuzzerState extends State<TurnBuzzer> {
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
class KeyPulse extends StatefulWidget {
  const KeyPulse({
    super.key,
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
  State<KeyPulse> createState() => _KeyPulseState();
}

class _KeyPulseState extends State<KeyPulse>
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
