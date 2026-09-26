import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import 'glass_components.dart';
import 'glass_panels.dart';
import 'table_chrome.dart';

// The winning tax (owner, 26 Sep 2026): "on Blind table boot amount 10 Lakh,
// and variation table boot amount 10 Lakh, whenever any player wins, the
// table tax will be applied on his winning amount, add a icon on these table,
// so that users can know"; then "only winner be taxed at on whole pot winning
// amount"; then the rate by the player's LEVEL — 20% at Level 1, falling a
// step a level to 10% at Level 50, and 4% for the VIP tier, which is set by
// hand and never reached by XP.
//
// Everything here NAMES the tax; nothing works it out. Which tables tax is the
// menu's word ([LobbyTable.winnerTax], [RoomState.winnerTax]), the rate a
// viewer pays is their level's ([PlayerLevel.taxBps]) or their seat's
// ([You.taxBps]), and what a winner paid comes with the hand's end
// ([GameState.winnerTax]).

/// The owner's ladder as seeded (26 Sep 2026), for the one sentence of a
/// table's rules that describes the whole of it: 20% at Level 1 and 4% for
/// VIP. Nothing is ever charged from these — the server's `player_levels`
/// decides that, and every rate shown as the player's own is the server's.
abstract final class WinningTaxLadder {
  static const int levelOneBps = 2000;
  static const int vipBps = 400;
}

/// The tax's mark, before its rate.
const IconData winningTaxIcon = Icons.percent_rounded;

/// A level's title as the app writes it: its mark first ("🌟 Rising Star",
/// "💎👑 VIP"), or the title alone when the server sent no mark.
String levelTitle(String icon, String title) {
  if (icon.isEmpty) return title;
  if (title.isEmpty) return icon;
  return '$icon $title';
}

/// The viewer's level named in full: "Level 10 · 🌟 Rising Star" — and a
/// VIP's "💎👑 VIP", which is a tier, not a number XP climbs to.
String levelNameOf(Strings t, PlayerLevel level) {
  final title = levelTitle(level.icon, level.title);
  return level.vip ? title : t.levelName(level.level, title);
}

/// The Stats drawer's line: "Level 10 · 🌟 Rising Star · 4,180 XP" — and a
/// VIP's "💎👑 VIP" alone: no XP, since XP leads nowhere for one.
String levelLineOf(Strings t, PlayerLevel level) {
  final title = levelTitle(level.icon, level.title);
  return level.vip
      ? title
      : t.levelLine(level.level, title, formatChips(level.xp));
}

/// Today's XP against its cap, and when the day's window ends: "Today 23 /
/// 50 XP · resets in 5h 12m 3s" — or without the second half while no window
/// is running.
String xpTodayOf(Strings t, XpToday today, DateTime now) {
  final left = today.leftAt(now);
  final line = t.xpToday(today.xp, today.cap);
  return left == null
      ? line
      : '$line · ${t.xpResetsIn(formatCountdown(left, t))}';
}

/// What the tax pill says: the rate the viewer pays — "18.16% TAX", a VIP's
/// "4% TAX · VIP" — or "TAX" alone where the rate is not known.
String taxPillLabel(Strings t, {int? bps, bool vip = false}) {
  if (bps == null) return t.taxPillNoRate;
  final rate = formatTaxRate(bps);
  return vip ? t.taxPillVip(rate) : t.taxPill(rate);
}

/// A line that carries a level's mark, laid out on its own style's line
/// height: a colour emoji stands taller than the text round it, and a line
/// that grew for it would move whatever stands under it. The mark is drawn
/// from the phone's colour emoji font in its own colours — nothing tints it.
StrutStyle levelStrut(TextStyle style) =>
    StrutStyle.fromTextStyle(style, forceStrutHeight: true);

/// The pill on the lobby card of a table that taxes its winners: the percent
/// mark and the rate THIS viewer would pay there ("18.16% TAX"), in the tax's
/// amber, hung on the line under the card's boot ([WinningTaxBeside]) — the
/// one line of a card with room beside it at the lobby's smallest size, and
/// the stake it qualifies. No line of the card moves for it.
class WinningTaxPill extends StatelessWidget {
  const WinningTaxPill({super.key, required this.label, required this.style});

  final String label;

  /// The words' style: the caption's own size, which the pill stands a
  /// little taller than ([WinningTaxBeside] lets it).
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final ink = TableInk.taxOn(theme.brightness);
    final size = MediaQuery.textScalerOf(context).scale(style.fontSize ?? 11);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: size * 0.45, vertical: 2.5),
      decoration: BoxDecoration(
        color: ink.withValues(alpha: dark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(Radii.xs),
        border: Border.all(color: ink.withValues(alpha: dark ? 0.55 : 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(winningTaxIcon, size: size, color: ink),
          SizedBox(width: size * 0.2),
          Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: style.copyWith(
              color: ink,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// A line of a card with something hung after it: [lead] laid out exactly
/// as it is alone, and [trail] after it in whatever room the line has left
/// (scaled down, never cut, when it is short of it), centred on the lead's
/// own line and allowed to stand taller than it. The block is as tall as the
/// lead, so nothing above or under it moves.
///
/// [shift] moves the trail's centre down from the lead's middle: a lead with
/// padding above its words (the caption's) has its line below its middle.
class WinningTaxBeside extends MultiChildRenderObjectWidget {
  WinningTaxBeside({
    super.key,
    required Widget lead,
    required Widget trail,
    required this.gap,
    this.shift = 0,
  }) : super(
         children: [
           lead,
           FittedBox(fit: BoxFit.scaleDown, child: trail),
         ],
       );

  final double gap;
  final double shift;

  @override
  RenderWinningTaxBeside createRenderObject(BuildContext context) =>
      RenderWinningTaxBeside(gap: gap, shift: shift);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderWinningTaxBeside renderObject,
  ) {
    renderObject
      ..gap = gap
      ..shift = shift;
  }
}

class _BesideParentData extends ContainerBoxParentData<RenderBox> {}

/// The render object behind [WinningTaxBeside].
class RenderWinningTaxBeside extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _BesideParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _BesideParentData> {
  RenderWinningTaxBeside({required this._gap, required this._shift});

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  double _shift;
  set shift(double value) {
    if (value == _shift) return;
    _shift = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _BesideParentData) {
      child.parentData = _BesideParentData();
    }
  }

  RenderBox get _lead => firstChild!;
  RenderBox get _trail => childAfter(firstChild!)!;

  double _widthFor(BoxConstraints constraints) => constraints.hasBoundedWidth
      ? constraints.maxWidth
      : _lead.getMaxIntrinsicWidth(double.infinity) +
            _gap +
            _trail.getMaxIntrinsicWidth(double.infinity);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final width = _widthFor(constraints);
    final lead = _lead.getDryLayout(BoxConstraints(maxWidth: width));
    return constraints.constrain(Size(width, lead.height));
  }

  @override
  void performLayout() {
    final width = _widthFor(constraints);
    final lead = _lead
      ..layout(BoxConstraints(maxWidth: width), parentUsesSize: true);
    (lead.parentData! as _BesideParentData).offset = Offset.zero;
    final room = math.max(0.0, width - lead.size.width - _gap);
    final trail = _trail
      ..layout(BoxConstraints(maxWidth: room), parentUsesSize: true);
    (trail.parentData! as _BesideParentData).offset = Offset(
      lead.size.width + _gap,
      (lead.size.height - trail.size.height) / 2 + _shift,
    );
    size = constraints.constrain(Size(width, lead.size.height));
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _lead.getMinIntrinsicWidth(height);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _lead.getMaxIntrinsicWidth(height) +
      _gap +
      _trail.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      _lead.getMinIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _lead.getMaxIntrinsicHeight(width);

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// The same pill on the Teen Patti felt, under the table's category tag and
/// moving with it: on the table's dark plate in both themes, in the tag's own
/// type ([TableType.tax]), with the rate THIS viewer's seat pays. It is a key
/// — a tap says what the tax is and where the viewer stands
/// ([showWinningTaxInfo]) — with a full touch target round a small plate.
class WinningTaxTag extends StatelessWidget {
  const WinningTaxTag({
    super.key,
    required this.label,
    required this.semanticLabel,
    required this.onTap,
  });

  final String label;

  /// What a screen reader calls the key: the tax's name.
  final String semanticLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          tapHaptic(context);
          onTap();
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Dim.minTouch),
          child: Center(
            widthFactor: 1,
            child: Plate(
              accent: TableInk.tax.withValues(alpha: 0.5),
              padding: const EdgeInsets.fromLTRB(
                Space.sm,
                Space.xs,
                Space.md,
                Space.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(winningTaxIcon, size: 14, color: TableInk.tax),
                  const SizedBox(width: Space.xs),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: TableType.tax(theme),
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

/// What the winning tax is and where the viewer stands, over the table (the
/// felt pill's tap): that only the winner of each hand pays it, on the whole
/// pot; the viewer's level, their XP (all of it, and today's against the
/// day's cap), the rate their seat pays, and the next level up with its XP
/// and rate — or, at the top of the ladder, that it is the top. A VIP is
/// shown the tier and their rate and nothing of XP: VIP is set by hand, never
/// earned (owner, 26 Sep 2026: "VIP Tag is not granted by XP").
Future<void> showWinningTaxInfo(BuildContext context) => showTableDialog<void>(
  context: context,
  builder: (context) => const WinningTaxInfo(),
);

/// The popup [showWinningTaxInfo] opens. Watches the game state, so a level
/// reached at the hand's end is shown the moment the server says so.
class WinningTaxInfo extends StatelessWidget {
  const WinningTaxInfo({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = context.watch<GameState>();
    final t = state.t;
    final level = state.user?.playerLevel;
    final vip = level?.vip ?? false;
    final bps = state.myTaxBps;
    final next = vip ? null : level?.next;
    final today = vip ? null : level?.today;

    final rows = <Widget>[
      if (level != null)
        WinningTaxFact(
          icon: Icons.military_tech_rounded,
          label: t.yourLevelLabel,
          value: levelNameOf(t, level),
        ),
      if (level != null && !vip)
        WinningTaxFact(
          icon: Icons.bolt_rounded,
          label: t.xpLabel,
          value: formatChips(level.xp),
        ),
      if (today != null)
        WinningTaxFact(
          icon: Icons.today_rounded,
          label: t.todayLabel,
          value: '${today.xp} / ${today.cap} XP',
        ),
      if (bps != null)
        WinningTaxFact(
          icon: winningTaxIcon,
          label: t.yourRateLabel,
          value: formatTaxRate(bps),
          strong: true,
        ),
      if (next != null)
        WinningTaxFact(
          icon: Icons.trending_up_rounded,
          label: t.nextLevelLabel,
          value: t.levelName(next.level, levelTitle(next.icon, next.title)),
          detail: t.nextLevelValue(
            formatChips(next.minXp),
            formatTaxRate(next.taxBps),
          ),
        ),
    ];

    return GlassDialog(
      padding: const EdgeInsets.all(Space.xl),
      title: dialogTitle(context, winningTaxIcon, t.winningTaxTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.winningTaxOnlyWinner, style: TableType.modalBody(theme)),
          if (!vip) ...[
            const SizedBox(height: Space.xs),
            Text(t.winningTaxFalls, style: TableType.metadata(theme)),
          ],
          if (rows.isNotEmpty) const SizedBox(height: Space.md),
          ...rows,
          // The top of the ladder: nothing further for XP to reach.
          if (level != null && !vip && next == null) ...[
            const SizedBox(height: Space.sm),
            Text(t.topLevelNote, style: TableType.metadata(theme)),
          ],
        ],
      ),
      actions: [
        GlassButton(
          style: GlassButtonStyle.primary,
          onPressed: () => Navigator.pop(context),
          minimumSize: const Size(120, Dim.minTouch),
          buttonStyle: FilledButton.styleFrom(
            backgroundColor: AppTheme.gold,
            foregroundColor: inkOnFill(AppTheme.gold),
            textStyle: TableType.primaryAction(theme),
          ),
          label: t.close,
        ),
      ],
    );
  }
}

/// One line of the tax popup: what it is on the left, its value on the
/// right in gold (the viewer's own rate in the tax's amber). Both may take a
/// second line rather than lose a word — a level's name, with its mark, runs
/// long in a narrow dialog at a large text size.
class WinningTaxFact extends StatelessWidget {
  const WinningTaxFact({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
    this.strong = false,
  });

  final IconData icon;
  final String label;
  final String value;

  /// A quieter line under the value: what reaches the next level, and what
  /// it charges.
  final String? detail;

  /// The viewer's own rate: the figure the popup is about.
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = TableType.chips(
      theme,
      colour: strong
          ? TableInk.taxOn(theme.brightness)
          : goldInk(theme.brightness),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        children: [
          SizedBox(
            width: TableSpace.rowIconSlot,
            child: Icon(
              icon,
              size: TableSpace.rowIcon,
              color: scheme.onSurface.withValues(
                alpha: AppTheme.inkLowOn(theme.brightness),
              ),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            flex: 2,
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TableType.info(
                theme,
                colour: scheme.onSurface.withValues(alpha: AppTheme.inkMed),
              ),
            ),
          ),
          const SizedBox(width: Space.md),
          Flexible(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  strutStyle: levelStrut(style),
                  style: style,
                ),
                if (detail case final detail?)
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TableType.metadata(theme, figures: true),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
