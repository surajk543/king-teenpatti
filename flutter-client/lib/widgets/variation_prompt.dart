import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/dtos.dart';
import '../theme/app_theme.dart';
import 'glass_components.dart';
import 'playing_card.dart';

/// Everything a variation table draws that a seen or blind one does not: the
/// chooser's picker, everyone else's "… is selecting variation", the line that
/// says what was chosen, and the words the table's tag names it with.
///
/// Every widget here takes plain values — a list of wire names, a deadline in
/// epoch milliseconds, two functions that put a wire name into the player's
/// language — and none reads the game state. That is deliberate: the table
/// hands them what the snapshot says and they draw it, so they can be pumped
/// in a test without a server, a socket or a signed-in player.

/// What is wild under [variation], from the card the server turned up:
/// the card's rank under Joker ("9", "10", "K"), its suit under Hukam ("♥").
/// Null under every other variation, which turns no card up, and for a code
/// too short to read — the tag then names the variation alone.
String? variationWildLabel(String? variation, String? turnUp) {
  if (!Variation.usesTurnUp(variation)) return null;
  if (turnUp == null || turnUp.length < 2) return null;
  if (variation == Variation.joker) return PlayingCard.rankOf(turnUp);
  final glyph = PlayingCard.suitSymbol(PlayingCard.suitOf(turnUp));
  return glyph == '?' ? null : glyph;
}

/// The words on a variation table's tag over the pot.
///
/// Before anything is chosen it reads as every table's does — the category and
/// the stake, "Variation · 200". Once the hand has its rules the stake gives
/// way to them, "Variation · AK47", and under Joker and Hukam to what is wild
/// as well, "Variation · Joker · 9", "Variation · Hukam · ♥": the stake was
/// read when the player sat down, and what beats what is asked every hand.
String variationTagText({
  required String category,
  required String boot,
  required String? selected,
  required String? turnUp,
  required String Function(String wire) nameOf,
}) {
  if (selected == null || selected.isEmpty) return '$category · $boot';
  final wild = variationWildLabel(selected, turnUp);
  final name = nameOf(selected);
  return wild == null ? '$category · $name' : '$category · $name · $wild';
}

/// Whole seconds left until [deadlineMs], never negative; 0 with no deadline.
int _secondsLeft(int deadlineMs) {
  if (deadlineMs <= 0) return 0;
  final ms = deadlineMs - DateTime.now().millisecondsSinceEpoch;
  return ms <= 0 ? 0 : (ms / 1000).ceil();
}

/// A variation window's clock: the whole seconds left, and optionally the bar
/// draining beside them.
///
/// Like the sideshow's bar it reads the wall clock once per frame rather than
/// taking a level from the game state, which republishes about once a second:
/// a bar stepping in whole seconds stutters, and digits driven by that tick
/// can sit on "3" for most of two seconds. Unlike the sideshow's it shows the
/// number — ten seconds with seven things to read is long enough to want to
/// know how long is left, not merely that it is running out.
///
/// The deadline is the server's. This only draws it: at zero the server has
/// already chosen, whatever this says.
class VariationCountdown extends StatefulWidget {
  const VariationCountdown({
    super.key,
    required this.deadlineMs,
    required this.totalMs,
    required this.digitsHeight,
    this.digits = true,
    this.bar = true,
    this.ink,
  });

  /// When the server closes the window, epoch ms; 0 when it runs none, and
  /// then nothing is drawn — there is no clock to read.
  final int deadlineMs;
  final int totalMs;

  /// The box the digits are fitted into. Fixed, so the number can never push
  /// the panel it stands in taller at a larger text scale.
  final double digitsHeight;

  /// Whether the seconds are drawn, and whether the draining bar is. The
  /// picker draws them apart — digits in its header, the bar under it — and
  /// everyone else's line draws the digits alone.
  final bool digits;
  final bool bar;

  /// The digits' colour while there is time; they turn to the error colour
  /// over the last third whatever this is.
  final Color? ink;

  @override
  State<VariationCountdown> createState() => _VariationCountdownState();
}

class _VariationCountdownState extends State<VariationCountdown>
    with SingleTickerProviderStateMixin {
  /// Repeats rather than runs once, so the clock keeps redrawing whatever the
  /// deadline is.
  ///
  /// Built in initState rather than as a `late final` read from build: build
  /// returns early when there is no deadline to draw, so on that path the
  /// field was first read in dispose() — where `vsync: this` looks up
  /// TickerMode on a deactivated element, the throw lands inside
  /// _InactiveElements._unmount, and the NEXT screen dies on an
  /// _ElementLifecycle.inactive assertion (CLAUDE.md §12.3). A line that shows
  /// someone else choosing has no deadline of its own, which is how a clock
  /// that never drew came to be disposed (19 Sep 2026).
  late final AnimationController _frames;

  @override
  void initState() {
    super.initState();
    _frames = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  double _remaining() {
    if (widget.totalMs <= 0) return 0;
    final left = widget.deadlineMs - DateTime.now().millisecondsSinceEpoch;
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
    if (widget.deadlineMs <= 0) return const SizedBox.shrink();

    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _frames,
        builder: (context, _) {
          final left = _remaining();
          final colour = Color.lerp(
            theme.colorScheme.error,
            widget.ink ?? AppTheme.goldBright,
            (left * 3).clamp(0.0, 1.0),
          )!;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.digits)
                SizedBox(
                  height: widget.digitsHeight,
                  child: FittedBox(
                    fit: BoxFit.contain,
                    child: Text(
                      '${_secondsLeft(widget.deadlineMs)}',
                      key: const ValueKey('variation-seconds'),
                      maxLines: 1,
                      style: AppTheme.money(
                        theme.textTheme.headlineMedium ?? const TextStyle(),
                        colour: colour,
                      ).copyWith(height: 1),
                    ),
                  ),
                ),
              if (widget.bar) ...[
                if (widget.digits) const SizedBox(height: Space.xs),
                SizedBox(
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
                        // heightFactor as well as widthFactor, or the
                        // childless fill collapses to nothing (CLAUDE.md
                        // §12.3); aligned left so it drains one way.
                        FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: left,
                          heightFactor: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  colour.withValues(alpha: 0.75),
                                  colour,
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// The chooser's picker: the server's menu as keys, and a clock, on the felt.
///
/// **On the felt, not a dialog.** The table puts this in its Stack while the
/// snapshot says the window is open for this player and takes it out the
/// moment the snapshot says otherwise — chosen, timed out, hand over, table
/// left. No route is pushed, so none can outlive the move it was asking about;
/// that is the black screen a missile's question once left behind (14 Sep
/// 2026), and the reason the sideshow prompt is built this way too.
///
/// **Nothing is assumed about the choice.** A tap marks its key, darkens them
/// all and sends the choice; the server decides whether it stood, and the
/// snapshot that says so is what removes the panel. The keys stay dark until
/// the server has answered: accepted, and they stay dark until that snapshot
/// lands however slow the link; refused — the toast says why — or never
/// answered, and they come back so the player is not left holding a dead
/// panel while their clock runs.
///
/// **It stands in the upper part of the felt**, never over the foot: the
/// chooser may look at their cards before choosing (the server allows `see`
/// during the window), and their hand and its "See cards" key are down there.
/// The table gives it the top 64% of the felt; the heights below fit inside
/// that on the tightest screen there is. At 640x360, text scale 1.25, the felt
/// is about 354dp tall, so the box is 226dp and the panel is
///
///   border 2x1.5 + padding 2x10 + header 30 + 6 + bar 6 + 10
///   + two rows of 44 + the 6 between them  =  169dp,
///
/// with 57 to spare. Nothing in it grows with the text scale — every label is
/// fitted into a box of fixed height — so 1.25, or 2.0, changes how large the
/// words are drawn and never how tall the panel is. A screen that is not
/// short (411 and up) gets 56dp keys with a line under each name saying what
/// the variation does, and a 40dp header: 28 + 3 + 40 + 6 + 6 + 10 + 118 =
/// 211dp into a box of at least 259.
///
/// **Always two rows** (owner, 18 Sep 2026, when 5-Card made the menu seven).
/// A third row of 44 + 6 would still have fitted the 640x360 box (219 of 226)
/// but with nothing to spare for a felt a few dp shorter, and it would put the
/// last key on a line of its own. So the panel grows SIDEWAYS instead, where a
/// landscape felt has room: up to six keys stand three to a row in a panel
/// 60% of the screen wide (640 -> 384, keys of 117dp), and seven or eight
/// stand four to a row in one 72% wide (640 -> 461: inside the padding 441,
/// less three gaps of 6, four keys of 105dp; 891 and up -> 600, keys of
/// 138dp). The height arithmetic above is therefore the same for six keys and
/// for seven. A short last row — three keys under four — is centred, its keys
/// the width of those above it.
class VariationPrompt extends StatefulWidget {
  const VariationPrompt({
    super.key,
    required this.title,
    required this.options,
    required this.nameOf,
    required this.noteOf,
    required this.deadlineMs,
    required this.totalMs,
    required this.onSelect,
  });

  final String title;

  /// The menu, in the server's order. Drawn in two rows ([perRowFor]).
  final List<String> options;
  final String Function(String wire) nameOf;
  final String Function(String wire) noteOf;
  final int deadlineMs;
  final int totalMs;

  /// Sends the choice and answers whether the server took it.
  final Future<bool> Function(String wire) onSelect;

  /// How many keys stand in a row for a menu of [count]: three, as the six
  /// older variations always had, until that would need a third row — then as
  /// many as keep it to two.
  static int perRowFor(int count) => math.max(3, (count / 2).ceil());

  @override
  State<VariationPrompt> createState() => _VariationPromptState();
}

class _VariationPromptState extends State<VariationPrompt> {
  String? _chosen;

  Future<void> _choose(String wire) async {
    if (_chosen != null) return;
    tapHaptic(context);
    setState(() => _chosen = wire);
    final taken = await widget.onSelect(wire);
    if (taken || !mounted) return;
    setState(() => _chosen = null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    // The notes are the first thing to go: a short screen has no height for a
    // second line in a key, and a narrow one no width for the sentence.
    final roomy =
        !Breaks.isShort(screen.height) && !Breaks.isCompact(screen.width);
    final keyH = roomy ? 56.0 : Dim.minTouch;
    final headerH = roomy ? 40.0 : 30.0;
    final pad = roomy ? Space.lg : Space.md;

    final perRow = VariationPrompt.perRowFor(widget.options.length);
    const gap = Space.sm;
    final rows = <List<String>>[
      for (var i = 0; i < widget.options.length; i += perRow)
        widget.options.sublist(i, math.min(i + perRow, widget.options.length)),
    ];

    return LayoutBuilder(
      builder: (context, box) {
        // Wider than the sideshow's panel, which holds two keys to this one's
        // three across: 640 -> 384 (keys of 117) | 891 -> 520 | 1280 -> 520.
        // Four across: 640 -> 461 (keys of 105) | 891 -> 600 | 1280 -> 600.
        // Never wider than the felt it stands on.
        final width = math.min(
          perRow <= 3
              ? (screen.width * 0.60).clamp(340.0, 520.0)
              : (screen.width * 0.72).clamp(340.0, 600.0),
          math.max(0.0, box.maxWidth - 2 * Space.md),
        );
        // Every key the same width, worked out rather than left to Expanded,
        // so a short last row can be centred without its keys stretching.
        final keyW = math.max(
          0.0,
          (width - 2 * pad - (perRow - 1) * gap) / perRow,
        );

        return Center(
          child: SizedBox(
            width: width,
            child: DecoratedBox(
              // The table's own dark plate, in both brightnesses: what stands
              // on the cloth is dark with light ink (table_screen's _Plate).
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.lg),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppTheme.ink800.withValues(alpha: 0.86),
                    AppTheme.ink900.withValues(alpha: 0.94),
                  ],
                ),
                border: Border.all(
                  color: AppTheme.goldBright.withValues(alpha: 0.45),
                  width: 1.5,
                ),
                boxShadow: AppTheme.controlShadow(
                  Brightness.dark,
                  elevation: 5,
                ),
              ),
              child: Padding(
                padding: EdgeInsets.all(pad),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: headerH,
                      child: Row(
                        children: [
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                // Translated, so it keeps its natural case.
                                widget.title,
                                maxLines: 1,
                                style: AppTheme.label(
                                  theme.textTheme.titleMedium ??
                                      const TextStyle(),
                                  colour: AppTheme.goldBright,
                                  weight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: Space.md),
                          VariationCountdown(
                            deadlineMs: widget.deadlineMs,
                            totalMs: widget.totalMs,
                            digitsHeight: headerH,
                            bar: false,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    // The same clock again, as the bar alone: the header above
                    // already carries its digits.
                    VariationCountdown(
                      deadlineMs: widget.deadlineMs,
                      totalMs: widget.totalMs,
                      digitsHeight: 0,
                      digits: false,
                    ),
                    const SizedBox(height: Space.md),
                    for (final (r, row) in rows.indexed) ...[
                      if (r > 0) const SizedBox(height: Space.sm),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final (i, wire) in row.indexed) ...[
                            if (i > 0) const SizedBox(width: gap),
                            SizedBox(
                              width: keyW,
                              child: _VariationKey(
                                key: ValueKey('variation-option-$wire'),
                                name: widget.nameOf(wire),
                                note: roomy ? widget.noteOf(wire) : '',
                                height: keyH,
                                chosen: _chosen == wire,
                                enabled: _chosen == null,
                                onTap: () => _choose(wire),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// One variation in the picker.
///
/// A box of fixed height with its words fitted inside, rather than a Material
/// button that sizes itself from its label: the panel's height is arithmetic
/// the table depends on (see [VariationPrompt]), and a key that grew with the
/// text scale would push the panel down over the player's own cards.
class _VariationKey extends StatelessWidget {
  const _VariationKey({
    super.key,
    required this.name,
    required this.note,
    required this.height,
    required this.chosen,
    required this.enabled,
    required this.onTap,
  });

  final String name;
  final String note;
  final double height;
  final bool chosen;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final corner = BorderRadius.circular(Radii.md);
    final ink = chosen ? AppTheme.ink900 : AppTheme.boneInk;

    return Semantics(
      button: true,
      enabled: enabled,
      selected: chosen,
      child: PressScale(
        enabled: enabled,
        // The haptic is given in [_VariationPromptState._choose], with the
        // choice, so it cannot fire for a tap that chose nothing.
        haptic: false,
        child: Opacity(
          // The ones not chosen step back; the one chosen stays lit, so the
          // player sees what they sent while the server answers.
          opacity: enabled || chosen ? 1 : 0.42,
          child: Material(
            color: chosen
                ? AppTheme.gold
                : AppTheme.ink700.withValues(alpha: 0.92),
            shape: RoundedRectangleBorder(
              borderRadius: corner,
              side: BorderSide(
                color: AppTheme.goldBright.withValues(
                  alpha: chosen ? 0.9 : 0.34,
                ),
                width: Dim.hairline,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? onTap : null,
              child: SizedBox(
                height: height,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.sm,
                    vertical: Space.xs,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        flex: 3,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            name,
                            maxLines: 1,
                            style: AppTheme.label(
                              theme.textTheme.labelLarge ?? const TextStyle(),
                              colour: ink,
                              weight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      if (note.isNotEmpty)
                        Flexible(
                          flex: 2,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              note,
                              maxLines: 1,
                              style: AppTheme.label(
                                theme.textTheme.labelSmall ?? const TextStyle(),
                                colour: ink.withValues(alpha: 0.72),
                                weight: FontWeight.w500,
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
        ),
      ),
    );
  }
}

/// What everyone but the chooser reads while the window is open: "Rahul is
/// selecting variation…" with the seconds left beneath it.
///
/// Never the keys — they are the chooser's — and never in the way: no
/// scrim, and nothing here takes a touch, because the rest of the table may
/// still look at their cards while they wait. It stands where the waiting line
/// stands between hands, a slot that is blank during one.
///
/// The slot is the gap between the two top seats, so every piece is fitted:
/// the sentence shrinks to the gap's width and the digits into a box of fixed
/// height. At 640x360 that is a line of at most 25dp, 4, and 22dp of digits —
/// 51dp centred on 0.28 of a 354dp felt, so 74..125dp, clear of the tag that
/// ends near 43 and the pot that starts near 140.
class VariationSelectingLine extends StatelessWidget {
  const VariationSelectingLine({
    super.key,
    required this.text,
    required this.deadlineMs,
    required this.totalMs,
  });

  final String text;
  final int deadlineMs;
  final int totalMs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The same ink the waiting line uses: light on the dark ground, dark on
    // the pale one, where white all but vanished (QA 14 Sep 2026).
    final ink = theme.brightness == Brightness.dark
        ? AppTheme.boneInk.withValues(alpha: 0.86)
        : AppTheme.inkOnLight.withValues(alpha: 0.82);

    return IgnorePointer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              // A player's name is in it, so it keeps its own case.
              text,
              maxLines: 1,
              style: AppTheme.label(
                theme.textTheme.titleSmall ?? const TextStyle(),
                colour: ink,
                weight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: Space.xs),
          VariationCountdown(
            deadlineMs: deadlineMs,
            totalMs: totalMs,
            digitsHeight: 22,
            bar: false,
            ink: ink,
          ),
        ],
      ),
    );
  }
}

/// What the whole table reads for a few seconds once the window has closed:
/// "Variation: AK47" in gold, and under it [detail] when the server had to
/// choose because nobody did.
class VariationChosenLine extends StatelessWidget {
  const VariationChosenLine({super.key, required this.text, this.detail});

  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // Gold on the dark ground; on the pale one champagne has no contrast, so
    // the deep gold the light theme uses for the same job.
    final gold = dark ? AppTheme.goldBright : AppTheme.gold;

    return IgnorePointer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              text,
              maxLines: 1,
              style:
                  AppTheme.label(
                    theme.textTheme.titleMedium ?? const TextStyle(),
                    colour: gold,
                    weight: FontWeight.w700,
                  ).copyWith(
                    shadows: [
                      Shadow(
                        color: gold.withValues(alpha: 0.28),
                        blurRadius: 8,
                      ),
                    ],
                  ),
            ),
          ),
          if (detail != null && detail!.isNotEmpty) ...[
            const SizedBox(height: Space.xxs),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                detail!,
                maxLines: 1,
                style: AppTheme.label(
                  theme.textTheme.labelMedium ?? const TextStyle(),
                  colour: dark
                      ? AppTheme.boneInk.withValues(alpha: 0.78)
                      : AppTheme.inkOnLight.withValues(alpha: 0.74),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A gold edge on a card that played as a wild one, at a reveal.
///
/// Under AK47 a hand of A-K-4 is named a Trail, and nothing on three ordinary
/// faces says why; the edge is what does. It is a foreground decoration, so it
/// adds nothing to the card's box — a seat's column must not change height at
/// the reveal (owner, 14 Sep 2026; test/seat_reveal_layout_test.dart) — and a
/// card that is not wild is returned exactly as it came.
class WildEdge extends StatelessWidget {
  const WildEdge({
    super.key,
    required this.wild,
    required this.cardHeight,
    required this.label,
    required this.child,
  });

  final bool wild;
  final double cardHeight;

  /// "Wild", in the player's language, for a screen reader: the edge itself
  /// is only a colour.
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!wild) return child;

    // A gold that reads on the card's cream face as well as on either ground.
    // The champagne edge it had (goldBright, 1.24:1 against the face — the
    // same contrast as the card's own edge) was the ONLY sign of a wild card
    // on a rim seat, 1.5dp wide on a 26dp card, and it was missed: a natural
    // pair plus a wild card is a Trail by the rules (§6.4), and a player who
    // could not see the wild card saw a pair winning as a trail (owner, 24 Sep
    // 2026). The edge is wider and darker now, and a gold star sits at the
    // card's head on the side the index is not — the mark of a joker, in no
    // language — inside the card's box, so the seat's column still does not
    // move and a neighbouring card in the fan cannot cover it.
    final dark = Theme.of(context).brightness == Brightness.dark;
    final gold = dark ? AppTheme.gold : AppTheme.goldDeep;
    final edge = math.max(2.0, cardHeight * 0.06);
    final star = math.max(10.0, cardHeight * 0.30);

    return Semantics(
      label: label,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          DecoratedBox(
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              // The card's own corner (PlayingCard draws 0.055 of its height).
              borderRadius: BorderRadius.circular(cardHeight * 0.055),
              border: Border.all(color: gold, width: edge),
            ),
            child: child,
          ),
          Positioned(
            top: edge,
            right: edge,
            child: IgnorePointer(
              child: Container(
                width: star,
                height: star,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [AppTheme.goldBright, AppTheme.gold],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppTheme.ink900.withValues(alpha: 0.45),
                      blurRadius: star * 0.3,
                      offset: Offset(0, star * 0.1),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: star * 0.66,
                  color: AppTheme.ink900,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A card that is held but does not count, set back behind the ones that do.
///
/// Under 5-Card a player holds five cards and plays the best three, and the
/// SERVER says which three (`best`). The other two stay in the hand — they
/// were dealt, and a player wants to see what they did not need — but darker
/// and a little smaller, standing on the same foot, so the three that are
/// being played read at a glance. Nobody chooses anything by it.
///
/// Like [WildEdge] it adds nothing to the card's box: the wash is a foreground
/// decoration and the shrink a paint-time transform, so neither the viewer's
/// fan nor a seat's column moves when it happens. It eases in when [setBack]
/// turns true, and a widget BUILT already set back (a reconnect, the table
/// rebuilt) is drawn that way at once and does not replay. With [setBack]
/// false it paints the child exactly as it came — a scale of one under a wash
/// of nothing — and keeps one tree shape in both states, so the card under it
/// keeps its State (its flip, its wild turn) across the change.
class SetBack extends StatelessWidget {
  const SetBack({
    super.key,
    required this.setBack,
    required this.cardHeight,
    required this.child,
  });

  final bool setBack;
  final double cardHeight;
  final Widget child;

  /// How much smaller a set-back card is drawn, and how dark its wash is.
  static const double shrink = 0.08;
  static const double wash = 0.52;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: setBack ? 1 : 0),
      duration: Motion.slow,
      curve: Motion.standard,
      child: child,
      builder: (context, t, child) => Transform.scale(
        scale: 1 - shrink * t,
        alignment: Alignment.bottomCenter,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            // The card's own corner (PlayingCard draws 0.055 of its height).
            borderRadius: BorderRadius.circular(cardHeight * 0.055),
            color: AppTheme.ink900.withValues(alpha: wash * t),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// 5-Card Teen Patti's card picker (owner, 19 Sep 2026: "when user clicks on
/// See cards … give user extra time so that he can choose 3 cards among 5 which
/// is shown in pop").
///
/// The five cards are drawn IN the panel rather than the player being sent to
/// their own fan: the fan sits under the action keys on a 640dp phone, and a
/// hand being chosen from should be the thing the screen is about. Tapping a
/// card marks it and tapping it again unmarks it; the third fills the hand and
/// a fourth tap is ignored rather than quietly dropping one of the three.
///
/// It is a panel in the felt's Stack, never a `showDialog` route, for the
/// reason [VariationPrompt] is: the window can close under the player — their
/// own clock runs out — and a route that outlives the question it asked takes
/// the table down with it when it is popped.
class CardPickPrompt extends StatefulWidget {
  const CardPickPrompt({
    super.key,
    required this.title,
    required this.hint,
    required this.confirm,
    required this.chosenLabel,
    required this.cards,
    required this.selected,
    required this.deadlineMs,
    required this.totalMs,
    required this.onToggle,
    required this.onConfirm,
  });

  final String title;
  final String hint;
  final String confirm;

  /// What a marked card is, for a screen reader: the gold edge is a colour.
  final String chosenLabel;

  /// The player's own five, in the order they are held.
  final List<String> cards;

  /// Which of them are marked, in the order they were tapped.
  final List<String> selected;
  final int deadlineMs;
  final int totalMs;
  final void Function(String code) onToggle;

  /// Sends the three. Answers whether the server took them; a refusal puts the
  /// keys back so the player can choose again.
  final Future<bool> Function(List<String> cards) onConfirm;

  /// How many cards make a hand. Three, wherever this is used.
  static const int plays = 3;

  /// The clock's bar and the hint line, as the height arithmetic above counts
  /// them: both are drawn by widgets that size themselves, so the panel has to
  /// be told what they come to.
  static const double _barH = 6;
  static const double _hintH = 16;

  @override
  State<CardPickPrompt> createState() => _CardPickPromptState();
}

class _CardPickPromptState extends State<CardPickPrompt> {
  bool _sending = false;

  Future<void> _confirm() async {
    if (_sending || widget.selected.length != CardPickPrompt.plays) return;
    tapHaptic(context);
    setState(() => _sending = true);
    final taken = await widget.onConfirm(widget.selected);
    if (taken || !mounted) return;
    setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    final roomy =
        !Breaks.isShort(screen.height) && !Breaks.isCompact(screen.width);
    final headerH = roomy ? 40.0 : 30.0;
    final pad = roomy ? Space.lg : Space.md;
    final ready = widget.selected.length == CardPickPrompt.plays;

    return LayoutBuilder(
      builder: (context, box) {
        final width = math.min(
          (screen.width * 0.72).clamp(340.0, 600.0),
          math.max(0.0, box.maxWidth - 2 * Space.md),
        );
        // Five cards and four gaps inside the panel's padding — but the row
        // is sized by the HEIGHT it is given as well as the width it has. A
        // card wide enough for the panel is 116dp tall at 640x360, which with
        // the header, the clock, the hint and the confirm key is taller than
        // the 0.64 of the felt this stands in: the panel overflowed its box by
        // 16 pixels there. So the row takes whatever is left after the chrome
        // and the cards are cut to fit it, keeping their own aspect.
        const gap = Space.sm;
        const lift = 10.0;
        final byWidth =
            math.max(
              0.0,
              (width - 2 * pad - (widget.cards.length - 1) * gap) /
                  widget.cards.length,
            ) /
            PlayingCard.aspect;
        // Everything in the column that is not the row of cards.
        final chrome =
            2 * pad +
            headerH +
            (widget.deadlineMs > 0 ? Space.sm + CardPickPrompt._barH : 0) +
            (roomy ? Space.xs + CardPickPrompt._hintH : 0) +
            Space.sm +
            Space.sm +
            Dim.minTouch;
        final byHeight = box.maxHeight.isFinite
            ? box.maxHeight - chrome - lift
            : byWidth;
        final cardH = math.max(24.0, math.min(byWidth, byHeight));

        return Center(
          child: SizedBox(
            width: width,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(Radii.lg),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppTheme.ink800.withValues(alpha: 0.86),
                    AppTheme.ink900.withValues(alpha: 0.94),
                  ],
                ),
                border: Border.all(
                  color: AppTheme.goldBright.withValues(alpha: 0.45),
                  width: 1.5,
                ),
                boxShadow: AppTheme.controlShadow(
                  Brightness.dark,
                  elevation: 5,
                ),
              ),
              child: Padding(
                padding: EdgeInsets.all(pad),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: headerH,
                      child: Row(
                        children: [
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                widget.title,
                                maxLines: 1,
                                style: AppTheme.label(
                                  theme.textTheme.titleMedium ??
                                      const TextStyle(),
                                  colour: AppTheme.goldBright,
                                  weight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: Space.md),
                          if (widget.deadlineMs > 0)
                            VariationCountdown(
                              deadlineMs: widget.deadlineMs,
                              totalMs: widget.totalMs,
                              digitsHeight: headerH,
                              bar: false,
                            ),
                        ],
                      ),
                    ),
                    if (widget.deadlineMs > 0) ...[
                      const SizedBox(height: Space.sm),
                      VariationCountdown(
                        deadlineMs: widget.deadlineMs,
                        totalMs: widget.totalMs,
                        digitsHeight: 0,
                        digits: false,
                      ),
                    ],
                    if (roomy) ...[
                      const SizedBox(height: Space.xs),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          widget.hint,
                          maxLines: 1,
                          style:
                              (theme.textTheme.bodySmall ?? const TextStyle())
                                  .copyWith(color: Colors.white70),
                        ),
                      ),
                    ],
                    const SizedBox(height: Space.sm),
                    SizedBox(
                      height: cardH + lift,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (final (i, code) in widget.cards.indexed) ...[
                            if (i > 0) const SizedBox(width: gap),
                            _PickableCard(
                              key: ValueKey('pick-card-$code'),
                              code: code,
                              label: widget.chosenLabel,
                              height: cardH,
                              lift: lift,
                              marked: widget.selected.contains(code),
                              enabled: !_sending,
                              onTap: () => widget.onToggle(code),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    SizedBox(
                      width: double.infinity,
                      height: Dim.minTouch,
                      child: GlassButton(
                        onPressed: ready && !_sending ? _confirm : null,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '${widget.confirm}  ${widget.selected.length}/${CardPickPrompt.plays}',
                            maxLines: 1,
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
  }
}

/// One of the five, marked or not. A marked card lifts and takes the gold edge
/// a wild card takes at a reveal, so "chosen" reads the same way everywhere.
class _PickableCard extends StatelessWidget {
  const _PickableCard({
    super.key,
    required this.code,
    required this.label,
    required this.height,
    required this.lift,
    required this.marked,
    required this.enabled,
    required this.onTap,
  });

  final String code;
  final String label;
  final double height;
  final double lift;
  final bool marked;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: height * PlayingCard.aspect,
      height: height + lift,
      // A card being chosen is a control, so it says which card it is and
      // whether it is marked (owner, 19 Sep 2026). PlayingCard itself draws
      // pips and paints nothing a screen reader can read, so without this the
      // five cards of the picker were five unlabelled boxes — and nothing an
      // automated run could tap either.
      child: Semantics(
        button: true,
        selected: marked,
        enabled: enabled,
        label: cardLabel(code),
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: AnimatedAlign(
            duration: Motion.base,
            curve: Motion.standard,
            alignment: marked ? Alignment.topCenter : Alignment.bottomCenter,
            child: SetBack(
              setBack: !marked,
              cardHeight: height,
              child: WildEdge(
                wild: marked,
                cardHeight: height,
                label: label,
                child: PlayingCard(code: code, height: height),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A card's face as a screen reader should say it: "A♠", "10♥". The rank and
/// the suit symbol the card itself is printed with, so what is heard and what
/// is seen are the same thing.
String cardLabel(String code) =>
    '${PlayingCard.rankOf(code)}${PlayingCard.suitSymbol(PlayingCard.suitOf(code))}';

/// The verdict, for the few seconds after a hand's three are settled: "you
/// played the best combination", or what was played beside what would have
/// been best (owner, 19 Sep 2026). It names the cards rather than only the
/// hand, because the point is to show the player the three they missed.
class PickVerdict extends StatelessWidget {
  const PickVerdict({
    super.key,
    required this.wasBest,
    required this.byTimeout,
    required this.played,
    required this.best,
    required this.title,
    required this.playedLabel,
    required this.bestLabel,
    required this.timedOutNote,
  });

  final bool wasBest;
  final bool byTimeout;

  /// The three that were PLAYED, and the three that would have been best.
  /// Both are drawn when they differ (owner, 19 Sep 2026: "while showing the
  /// best card … also show your selected card"), so the player can see the
  /// two hands side by side rather than being told about one of them.
  final List<String> played;
  final List<String> best;
  final String title;
  final String playedLabel;
  final String bestLabel;
  final String timedOutNote;

  /// The green a hand well played is written in — the same green a seen
  /// opponent's cards take, read off the dark plate this stands on.
  static Color get _good => AppTheme.seenInk(Brightness.dark);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    final cardH = Breaks.isShort(screen.height) ? 34.0 : 44.0;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.md),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            color: AppTheme.ink900.withValues(alpha: 0.92),
            border: Border.all(
              color: (wasBest ? _good : AppTheme.goldBright).withValues(
                alpha: 0.55,
              ),
              width: 1.5,
            ),
            boxShadow: AppTheme.controlShadow(Brightness.dark, elevation: 4),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.lg,
              vertical: Space.md,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (byTimeout)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Space.xs),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        timedOutNote,
                        maxLines: 1,
                        style: (theme.textTheme.bodySmall ?? const TextStyle())
                            .copyWith(color: Colors.white70),
                      ),
                    ),
                  ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    title,
                    maxLines: 1,
                    style: AppTheme.label(
                      theme.textTheme.titleSmall ?? const TextStyle(),
                      colour: wasBest ? _good : AppTheme.goldBright,
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
                if (!wasBest && best.isNotEmpty) ...[
                  const SizedBox(height: Space.sm),
                  // What was played, then what would have been best: the two
                  // rows side by side are the whole point of the message.
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _VerdictHand(
                        label: playedLabel,
                        cards: played,
                        cardHeight: cardH,
                        marked: false,
                      ),
                      const SizedBox(width: Space.md),
                      Icon(
                        Icons.arrow_forward_rounded,
                        size: cardH * 0.4,
                        color: Colors.white38,
                      ),
                      const SizedBox(width: Space.md),
                      _VerdictHand(
                        label: bestLabel,
                        cards: best,
                        cardHeight: cardH,
                        marked: true,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One of the verdict's two hands: a caption over three small cards. The best
/// three take the gold edge a chosen card takes in the picker, so the eye goes
/// to them; what was played is drawn plainly beside them.
class _VerdictHand extends StatelessWidget {
  const _VerdictHand({
    required this.label,
    required this.cards,
    required this.cardHeight,
    required this.marked,
  });

  final String label;
  final List<String> cards;
  final double cardHeight;
  final bool marked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            label,
            maxLines: 1,
            style: (theme.textTheme.labelSmall ?? const TextStyle()).copyWith(
              color: marked ? AppTheme.goldBright : Colors.white70,
            ),
          ),
        ),
        const SizedBox(height: Space.xs),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, code) in cards.indexed) ...[
              if (i > 0) const SizedBox(width: Space.xs),
              Semantics(
                label: '$label ${cardLabel(code)}',
                excludeSemantics: true,
                child: WildEdge(
                  wild: marked,
                  cardHeight: cardHeight,
                  label: label,
                  child: PlayingCard(code: code, height: cardHeight),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
