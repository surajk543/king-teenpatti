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
/// number — ten seconds with six things to read is long enough to want to
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
  /// deadline is. Read on every build, so its initialiser never first runs in
  /// dispose (CLAUDE.md §12.3).
  late final AnimationController _frames = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

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

/// The chooser's picker: six keys and a clock, on the felt.
///
/// **On the felt, not a dialog.** The table puts this in its Stack while the
/// snapshot says the window is open for this player and takes it out the
/// moment the snapshot says otherwise — chosen, timed out, hand over, table
/// left. No route is pushed, so none can outlive the move it was asking about;
/// that is the black screen a missile's question once left behind (14 Sep
/// 2026), and the reason the sideshow prompt is built this way too.
///
/// **Nothing is assumed about the choice.** A tap marks its key, darkens all
/// six and sends the choice; the server decides whether it stood, and the
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

  /// The menu, in the server's order. Drawn three to a row.
  final List<String> options;
  final String Function(String wire) nameOf;
  final String Function(String wire) noteOf;
  final int deadlineMs;
  final int totalMs;

  /// Sends the choice and answers whether the server took it.
  final Future<bool> Function(String wire) onSelect;

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

    const perRow = 3;
    final rows = <List<String>>[
      for (var i = 0; i < widget.options.length; i += perRow)
        widget.options.sublist(i, math.min(i + perRow, widget.options.length)),
    ];

    return LayoutBuilder(
      builder: (context, box) {
        // Wider than the sideshow's panel, which holds two keys to this one's
        // three across: 640 -> 384 (keys of 117) | 891 -> 520 | 1280 -> 520,
        // and never wider than the felt it stands on.
        final width = math.min(
          (screen.width * 0.60).clamp(340.0, 520.0),
          math.max(0.0, box.maxWidth - 2 * Space.md),
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
                        children: [
                          for (final (i, wire) in row.indexed) ...[
                            if (i > 0) const SizedBox(width: Space.sm),
                            Expanded(
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
                          // A short last row keeps its keys the width of the
                          // rows above it rather than stretching them.
                          for (var i = row.length; i < perRow; i++) ...[
                            const SizedBox(width: Space.sm),
                            const Spacer(),
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
          // The five not chosen step back; the one chosen stays lit, so the
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
/// Never the six keys — they are the chooser's — and never in the way: no
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

    return Semantics(
      label: label,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          // The card's own corner (PlayingCard draws 0.055 of its height).
          borderRadius: BorderRadius.circular(cardHeight * 0.055),
          border: Border.all(
            color: AppTheme.goldBright,
            width: math.max(1.5, cardHeight * 0.035),
          ),
        ),
        child: child,
      ),
    );
  }
}
