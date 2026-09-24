import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';

/// The game table's type scale (owner's table polish brief, 24 Sep 2026:
/// "Define reusable text styles for: player name, player status, boot, chip
/// values, pot amount, primary action, secondary action, labels, metadata,
/// system messages, modal titles, modal descriptions. Do not allow individual
/// widgets to randomly choose font sizes.").
///
/// One style per job, and every size taken from the theme's own ramp
/// ([AppTheme]'s text theme), so a widget on the table asks for its ROLE and
/// never for a number. Largest first, at text x1.0:
///
/// | role              | size | weight | where                                  |
/// |-------------------|------|--------|----------------------------------------|
/// | [pot]             | 20   | 700    | the plinth in the middle of the felt   |
/// | [modalTitle]      | 17   | 600    | a dialog's or a sheet's title          |
/// | [system]          | 15   | 600    | the table speaking: waiting, reconnecting |
/// | [item], [chips]   | 15   | 600/700| a drawer row and its figure            |
/// | [primaryAction]   | 14   | 700    | Chaal                                  |
/// | [secondaryAction] | 13.5 | 600    | Sideshow, Force Sideshow, Pack, Missile |
/// | [modalBody], chat | 13.5 | 400    | a dialog's body, a chat line           |
/// | [boot], [label]   | 12   | 700/600| the tag over the pot, tabs, captions   |
/// | [actionDetail]    | 12   | 700/600| a key's second line                    |
/// | [metadata]        | 12   | 400    | notes, the sitting's clock, footnotes  |
///
/// A seat's roles — the player's name, their status, their chips — are scaled
/// from the pod they stand on ([seat], [SeatType]).
abstract final class TableType {
  // ------------------------------------------------------------- the felt

  /// The pot: the largest figure on the felt, gold on its dark plinth in both
  /// themes, in tabular figures so it does not jitter while it counts up.
  static TextStyle pot(ThemeData theme) =>
      AppTheme.money(_t(theme).titleLarge!, colour: AppTheme.goldBright);

  /// The table's category and stake on the tag over the pot ("BLIND · 200"),
  /// on the tag's dark plate in both themes.
  static TextStyle boot(ThemeData theme) => AppTheme.label(
    _t(theme).labelMedium!,
    colour: AppTheme.goldBright.withValues(alpha: 0.92),
    weight: FontWeight.w700,
  );

  /// The table speaking for itself: the waiting and starting line, a seat
  /// held for a purchase, who the table is waiting on, reconnecting.
  /// [strong] is for the line a player has to answer or has just been dealt
  /// — the sideshow question, their own PACKED plate.
  static TextStyle system(
    ThemeData theme, {
    required Color colour,
    bool strong = false,
  }) => AppTheme.label(
    _t(theme).titleSmall!,
    colour: colour,
    weight: strong ? FontWeight.w700 : FontWeight.w600,
  );

  /// The viewer's own hand's name over their cards ("Pair", "Trail"): the
  /// server's English, so tracked capitals are safe on it.
  static TextStyle handName(ThemeData theme, {required Color colour}) =>
      AppTheme.smallCaps(_t(theme).labelMedium!, tracking: 0.8, colour: colour);

  /// A fixed Latin eyebrow the code owns — SIDESHOW over its question, the
  /// category at the head of the table's menu. Never a translated string.
  static TextStyle caps(
    ThemeData theme, {
    required Color colour,
    double tracking = 1.4,
  }) => AppTheme.smallCaps(
    _t(theme).labelSmall!,
    tracking: tracking,
    colour: colour,
  );

  // ------------------------------------------------------------- the keys

  /// The one primary key's name — Chaal — a step larger and heavier than
  /// every other key's, so the move a turn is built around reads first.
  static TextStyle primaryAction(ThemeData theme) => AppTheme.label(
    _t(theme).labelLarge!,
    fontSize: 14,
    weight: FontWeight.w700,
  );

  /// Every other key's name: Sideshow, Force Sideshow, Show, Missile, Pack,
  /// See cards.
  static TextStyle secondaryAction(ThemeData theme) =>
      AppTheme.label(_t(theme).labelLarge!, weight: FontWeight.w600);

  /// A key's second line — what the move costs, or who it is aimed at — in
  /// tabular figures, as heavy as the key's name is loud.
  static TextStyle actionDetail(ThemeData theme, {bool primary = false}) =>
      AppTheme.money(
        _t(theme).bodySmall!,
        weight: primary ? FontWeight.w700 : FontWeight.w600,
      );

  // ---------------------------------------------- drawers, dialogs, chat

  /// A row of a drawer or a list: its name. [colour] is for a row that costs
  /// something (Leave table, in the error ink); a row that only reports
  /// passes the quieter ink it is given.
  static TextStyle item(
    ThemeData theme, {
    Color? colour,
    FontWeight weight = FontWeight.w600,
  }) => AppTheme.label(_t(theme).bodyLarge!, colour: colour, weight: weight);

  /// A row that only reports — Your chips, Boot, Max pot: system information,
  /// a step smaller and quieter than a row that does something, so its gold
  /// figure carries it.
  static TextStyle info(ThemeData theme, {Color? colour}) => AppTheme.label(
    _t(theme).bodyMedium!,
    colour: colour,
    weight: FontWeight.w500,
  );

  /// A chip figure beside a label: a drawer row's value, in tabular figures.
  static TextStyle chips(ThemeData theme, {Color? colour}) =>
      AppTheme.money(_t(theme).titleSmall!, colour: colour);

  /// A small label: a tab, a section's name, a caption over a control, a
  /// key in a list.
  static TextStyle label(
    ThemeData theme, {
    Color? colour,
    FontWeight weight = FontWeight.w600,
  }) => AppTheme.label(_t(theme).labelMedium!, colour: colour, weight: weight);

  /// The quiet tier: what a row does or costs, the sitting's clock, a
  /// dialog's footnote, a line the table wrote in the chat. Muted by default
  /// ([AppTheme.inkLowOn], which holds 4.5:1 on the drawers' glass);
  /// [figures] sets digits tabular, for a clock or a count.
  static TextStyle metadata(
    ThemeData theme, {
    Color? colour,
    bool figures = false,
  }) {
    final base = _t(theme).bodySmall!.copyWith(
      color:
          colour ??
          theme.colorScheme.onSurface.withValues(
            alpha: AppTheme.inkLowOn(theme.brightness),
          ),
    );
    return figures
        ? AppTheme.money(base, weight: FontWeight.w500)
        : base.copyWith(fontWeight: FontWeight.w500);
  }

  /// A count or a clock beside a label, in tabular figures so 4-3-2-1 never
  /// shifts a row: the chat's seconds, the sitting's clock. [small] is the
  /// figure inside a 22dp dial.
  static TextStyle count(
    ThemeData theme, {
    required Color colour,
    bool small = false,
  }) => AppTheme.money(
    small ? _t(theme).labelSmall! : _t(theme).labelMedium!,
    colour: colour,
  );

  /// A dialog's or a sheet's title.
  static TextStyle modalTitle(ThemeData theme) =>
      AppTheme.label(_t(theme).titleMedium!);

  /// A dialog's body, in the theme's body ink.
  static TextStyle modalBody(ThemeData theme) => _t(theme).bodyMedium!;

  /// Who said a chat line: the NAME carries the line, in the full ink — not
  /// the player's colour, which the bar beside the line keeps (owner's brief:
  /// "Player messages should emphasize the player name rather than using
  /// aggressive red text"). The viewer's own lines are signed in gold.
  static TextStyle chatName(ThemeData theme, {required Color colour}) =>
      AppTheme.label(
        _t(theme).bodyMedium!,
        colour: colour,
        weight: FontWeight.w700,
      );

  /// What a chat line says.
  static TextStyle chatText(ThemeData theme) => _t(theme).bodyMedium!;

  // ------------------------------------------------------------ a seat

  /// The roles of one seat, scaled from its pod's width.
  static SeatType seat(ThemeData theme, double podWidth) =>
      SeatType._(theme, podWidth);

  /// The D on the dealer's button, debossed into a disc [disc] across: a mark
  /// the size of its disc rather than a line of type.
  static TextStyle dealerMark(double disc) => TextStyle(
    fontSize: disc * 0.52,
    height: 1,
    fontWeight: FontWeight.w700,
    color: const Color(0xFF6B5A33),
    // The highlight half a pixel above the letter is what makes it read as
    // pressed into the disc.
    shadows: const [Shadow(color: Color(0x99FFFFFF), offset: Offset(0, -0.5))],
  );

  static TextTheme _t(ThemeData theme) => theme.textTheme;
}

/// A seat's type, scaled from the width of its pod ([Dim.podW]).
///
/// A pod runs from 60 to 140dp, so every size here is a share of its width
/// with a floor under it: a share that reads at 110dp is 5px at 60 and
/// illegible in any of the five languages. The ladder, largest first: what a
/// player says over their seat, their name and their balance, what they are
/// doing (BLIND / SEEN on their cards) and what they just bet, the status line
/// under a pod, and the quieter "In Pot" beside the bet.
@immutable
class SeatType {
  const SeatType._(this.theme, this.podWidth);

  final ThemeData theme;

  /// The pod every size is taken from.
  final double podWidth;

  double _at(double share, double floor) => math.max(floor, podWidth * share);

  TextTheme get _t => theme.textTheme;

  /// A player's name across the head of their pod. Translated names keep
  /// their own case: tracked capitals do nothing to Devanagari.
  TextStyle name({Color? colour}) =>
      AppTheme.label(_t.labelLarge!, fontSize: _at(0.125, 10), colour: colour);

  /// YOU, on the viewer's own pod: the name's size, in tracked capitals —
  /// a fixed Latin word the code owns.
  TextStyle you({required Color colour}) => AppTheme.smallCaps(
    _t.labelLarge!,
    fontSize: _at(0.125, 10),
    tracking: 1.2,
    colour: colour,
  );

  /// The player's status, written on their cards: BLIND or SEEN. SEEN is
  /// [strong] — a player who has looked is the one fact about an opponent
  /// that changes how you bet.
  TextStyle tag({required Color colour, bool strong = false}) => AppTheme.label(
    _t.labelMedium!,
    fontSize: _at(0.105, 10),
    colour: colour,
    weight: strong ? FontWeight.w800 : FontWeight.w600,
  );

  /// A revealed hand's name on the foot of its cards ("Pure Sequence"): the
  /// server's English, in tracked capitals.
  TextStyle handName({required Color colour}) => AppTheme.smallCaps(
    _t.labelSmall!,
    fontSize: _at(0.095, 9),
    colour: colour,
    weight: FontWeight.w800,
  );

  /// The player's status line under their pod: Pack, Winner, Waiting,
  /// Offline.
  TextStyle status({required Color colour}) => AppTheme.label(
    _t.labelSmall!,
    fontSize: _at(0.095, 9),
    colour: colour,
    weight: FontWeight.w700,
  );

  /// A player's balance on their pod's pill: the largest figure on a pod.
  TextStyle stack({required Color colour}) => AppTheme.money(
    _t.labelMedium!,
    fontSize: _at(0.125, 11.5),
    colour: colour,
  );

  /// What a seat just bet, on its badge — and the word BLIND or SEEN that
  /// opens the viewer's own badge.
  TextStyle bet({required Color colour, bool figure = true}) => figure
      ? AppTheme.money(
          _t.labelMedium!,
          fontSize: _at(0.105, 10),
          colour: colour,
        )
      : AppTheme.label(
          _t.labelMedium!,
          fontSize: _at(0.105, 10),
          colour: colour,
        );

  /// "In Pot" and its figure: the badge's quieter partner.
  TextStyle inPot({required Color colour, bool figure = false}) => figure
      ? AppTheme.money(
          _t.labelSmall!,
          fontSize: _at(0.086, 9),
          colour: colour,
          weight: FontWeight.w600,
        )
      : AppTheme.label(_t.labelSmall!, fontSize: _at(0.086, 9), colour: colour);

  /// A chat line over a seat — the one thing on the felt a player reads
  /// rather than glances at, so its floor is higher than a caption's.
  TextStyle speech({required Color colour}) => _t.bodySmall!.copyWith(
    fontSize: _at(0.135, 12),
    height: 1.3,
    fontWeight: FontWeight.w500,
    color: colour,
  );

  /// WINNER, struck across the winner's pod ([big]), and the hand it won with
  /// under it.
  TextStyle winner({required bool big, required FontWeight weight}) {
    final size = math.max(9.0, podWidth * (big ? 0.175 : 0.092));
    return AppTheme.smallCaps(
      _t.titleLarge!,
      fontSize: size,
      tracking: size * 0.065,
      weight: weight,
      colour: AppTheme.boneInk,
    );
  }
}

/// The table's spacing, built from the app's one ramp ([Space]) and the
/// device classes ([Dim]) rather than numbers of its own.
///
/// Every control in a corner of the room — the Shop key and the wallet at the
/// top, Missile and Pack and the key cluster at the foot — stands [edge] in
/// from the safe edge beside it and [gap] in from the top or the bottom, and
/// the keys of one group stand [gap] apart, so the four corners agree.
abstract final class TableSpace {
  /// A corner control's inset from the safe edge beside it.
  /// 640 -> 11.5 | 891 -> 16.0 | 1280 -> 23.0
  static double edge(double width) => Dim.feltPad(width);

  /// A corner control's inset from the top or the bottom, and the gap
  /// between two keys of one group. 640 -> 6 | 891 -> 10
  static double gap(double width) => Dim.gap(width);

  /// Between a seat's pod and the cards and the badge that hang under it.
  static double seat(double podWidth) => podWidth * 0.05;

  /// Between the viewer's fanned hand and the name and bet stood over it.
  static const double hand = Space.xs;

  /// The table's two drawers — the menu and the chat. A step wider than the
  /// app's own drawer ([Dim.drawerW]): the chat's two tabs name themselves in
  /// full and its lines wrap less, and the room behind is dimmed, not in use.
  /// 640 -> 281.6 | 732 -> 322.1 | 891 -> 392.0 | 915 -> 400.0
  static double drawerW(double width) => (width * 0.44).clamp(280.0, 400.0);

  /// A drawer row's inset from the drawer's sides.
  static const double drawerInset = Space.lg;

  /// A drawer row's height, whatever it holds: a comfortable thumb's target,
  /// a step over [Dim.minTouch], so a column of them reads as a list and not
  /// a stack of buttons.
  static const double rowHeight = 48;

  /// The slot a drawer row's glyph stands in, and the glyph itself.
  static const double rowIconSlot = 24;
  static const double rowIcon = 20;

  /// Above and below the rule between two groups of drawer rows.
  static const double section = Space.sm;
}

/// How far the game is dimmed behind what covers it (owner's brief: "The
/// backdrop should dim the game without completely destroying visual
/// context"). The room's own ink rather than black, lighter than Material's
/// black at 0.54, which turned the light theme's pale room into grey mud.
abstract final class TableScrim {
  /// Behind the table's drawer: ink900 at 0.40.
  static const Color drawer = Color(0x6608080A);

  /// Behind a dialog or the rules over the table: ink900 at 0.45, the rules
  /// sheet's own since it was written.
  static const Color dialog = Color(0x7308080A);

  /// Behind a picker laid on the felt (the variation choice, the 5-Card
  /// pick): the felt calmed under the panel, then clear again above the
  /// viewer's own hand, which stays lit and live while they choose. The
  /// figures the two pickers always had, in one place now.
  static const LinearGradient picker = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0x8C000000), Color(0x8C000000), Color(0x00000000)],
    stops: [0, 0.58, 0.72],
  );
}

/// The table's ambient light, turned down so it supports the game rather than
/// competing with it (owner's brief: "Ambient gradients/circles should remain
/// visible but subtle ... Use lower opacity, softer blur, and better
/// positioning"). The pot, the cards, the seat on turn and the key to press
/// are the brightest things on the felt; everything here sits under them.
abstract final class TableAmbient {
  /// The chips drifting across the room while no table picture is laid
  /// ([DriftingChips.strength]). It was 2.6, which on the light ground put a
  /// grey disc at 42% behind the keys.
  static const double roomChips = 1.8;

  /// A seat's colour, spilling out of its pod's top corner as a soft glow
  /// (it was a hard-edged disc at 0.95): its peak opacity outside the glass,
  /// and inside it, where the glass shows it.
  static double orbOutside(Brightness b) => b == Brightness.dark ? 0.46 : 0.34;
  static double orbInside(Brightness b) => b == Brightness.dark ? 0.40 : 0.28;

  /// The orb's diameter as a share of the pod's width, and how much of the
  /// pod's width it reaches past the pod's corner (0.80 and 0.15 before).
  static const double orbSize = 0.74;
  static const double orbSpill = 0.10;

  /// One breath of the ring round the pod on turn: slower than the 780ms it
  /// was, so it reads as a glow that pulses rather than a light that flickers
  /// — still the one ring on the felt, and still answerable at a glance.
  static const Duration turnBreath = Duration(milliseconds: 1150);
}
