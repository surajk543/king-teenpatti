import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import '../theme/theme_colors.dart';
import 'edge_fade.dart';
import 'emoji_art.dart';
import 'game_loader.dart';
import 'glass_components.dart';
import 'glass_panels.dart';
import 'level_screen.dart';
import 'premium_surface.dart';
import 'table_chrome.dart';

// The winning tax (owner, 26 Sep 2026): "on Blind table boot amount 10 Lakh,
// and variation table boot amount 10 Lakh, whenever any player wins, the
// table tax will be applied on his winning amount, add a icon on these table,
// so that users can know"; then the rate by the player's LEVEL — 20% at Level
// 1, falling a step a level to 6% at Level 50 (the owner's bracket of 27 Sep
// 2026) — or lower where a BADGE brings it down (owner, 27 Sep 2026: "Vip is
// not a level, it is badge … the tax will be applied acc to minimum of badge
// or player level"); since 27 Sep 2026 on every Seen, Blind and Variation
// table, on what the winner WON — the pot less their own chips — and only on
// winnings of 50 Lakh or more ("no tax for winning amount less than 50
// Lakh"; 30 Lakh at first). Badges are given by hand or bought in the store, for a
// validity, and never reached by XP.
//
// Everything here NAMES the tax; nothing works it out. Which tables tax is the
// menu's word ([LobbyTable.winnerTax], [RoomState.winnerTax]), the rate a
// viewer pays is their account's ([User.paysTaxBps]) or their seat's
// ([You.taxBps]), the ladder is the server's ([LevelLadder]), and what a
// winner paid comes with the hand's end ([GameState.winnerTax]).

/// The owner's ladder as seeded (the bracket of 27 Sep 2026), for the one
/// sentence of a table's rules that describes the whole of it: 20% at Level
/// 1. Nothing is ever charged from it — the server's `player_levels` decides
/// that, and every rate shown as the player's own is the server's.
abstract final class WinningTaxLadder {
  static const int levelOneBps = 2000;
}

/// The tax's mark, before its rate.
const IconData winningTaxIcon = Icons.percent_rounded;

/// A level's title as the app writes it: its mark first ("🌟 Rising Star",
/// "👑👑 King of Kings"), or the title alone when the server sent no mark.
String levelTitle(String icon, String title) {
  if (icon.isEmpty) return title;
  if (title.isEmpty) return icon;
  return '$icon $title';
}

/// The viewer's level named in full: "Level 10 · 🌟 Rising Star".
String levelNameOf(Strings t, PlayerLevel level) =>
    t.levelName(level.level, levelTitle(level.icon, level.title));

/// The Stats drawer's line: "Level 10 · 🌟 Rising Star · 4,180 XP".
String levelLineOf(Strings t, PlayerLevel level) => t.levelLine(
  level.level,
  levelTitle(level.icon, level.title),
  formatChips(level.xp),
);

/// A badge as the app writes it: its mark first where it has one ("🏅 Gold"),
/// like a level; a badge drawn by its art ("Royal King") has none.
String badgeTitleOf(PlayerBadge badge) => levelTitle(badge.icon, badge.title);

/// How long a badge's grant has left: a month or more away, the day it ends
/// ("Until 26/09/2031" — a grant runs five years, owner, 27 Sep 2026, and
/// "4 years left" undersold one given a minute ago); nearer, the largest
/// whole unit — "23 days left", "5 hours left", "12 minutes left".
String badgeLeftOf(Strings t, Duration left, DateTime until) =>
    left.inDays >= 30
    ? t.badgeUntil(badgeDateOf(until))
    : t.timeLeft(
        left.inDays >= 1
            ? t.timeDays(left.inDays)
            : left.inHours >= 1
            ? t.timeHours(left.inHours)
            : t.timeMinutes(math.max(1, left.inMinutes)),
      );

/// A badge's mark: its art where it has one — a Royal badge's Lottie, playing
/// (owner, 27 Sep 2026: "Add this in UI store and with their lottie
/// animation") and cropped to the square, so a 16:9 canvas with its crown in
/// the middle (Royal Ace) shows the crown rather than a strip — else its
/// emoji, else the rosette. One widget for the store's card and the tax
/// popup's rows, so a badge is drawn the same wherever it is named.
class BadgeArt extends StatelessWidget {
  const BadgeArt({
    super.key,
    required this.size,
    this.icon = '',
    this.assetUrl = '',
    this.assetFormat = '',
    this.label,
  });

  BadgeArt.of(LadderBadge badge, {Key? key, required double size})
    : this(
        key: key,
        size: size,
        icon: badge.icon,
        assetUrl: badge.assetUrl,
        assetFormat: badge.assetFormat,
        label: badge.title,
      );

  BadgeArt.held(PlayerBadge badge, {Key? key, required double size})
    : this(
        key: key,
        size: size,
        icon: badge.icon,
        assetUrl: badge.assetUrl,
        assetFormat: badge.assetFormat,
        label: badge.title,
      );

  final double size;
  final String icon;
  final String assetUrl;
  final String assetFormat;

  /// What a screen reader calls it: the badge's name.
  final String? label;

  @override
  Widget build(BuildContext context) {
    if (assetUrl.isNotEmpty && assetFormat == 'LOTTIE') {
      return EmojiArt(
        url: context.read<GameState>().absoluteUrl(assetUrl),
        size: size,
        fit: BoxFit.cover,
        semanticLabel: label,
      );
    }
    if (icon.isNotEmpty) {
      return SizedBox.square(
        dimension: size,
        child: FittedBox(child: Text(icon, style: const TextStyle(height: 1))),
      );
    }
    return Icon(
      Icons.workspace_premium_rounded,
      size: size,
      color: goldInk(Theme.of(context).brightness),
    );
  }
}

/// A day as the app writes a date: day, month, year — "26/09/2031".
String badgeDateOf(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')}/'
    '${day.month.toString().padLeft(2, '0')}/${day.year}';

/// The Teen Patti hands by the server's code, named as the table names them —
/// in English in every language (CLAUDE.md §6.3: the wire's hand names are
/// never translated).
const Map<String, String> handNames = {
  'HIGH_CARD': 'High Card',
  'PAIR': 'Pair',
  'COLOR': 'Color',
  'SEQUENCE': 'Sequence',
  'PURE_SEQUENCE': 'Pure Sequence',
  'TRAIL': 'Trail',
};

/// A daily XP source named in the player's language by what earns it —
/// "Play 15 active minutes", "Win by Trail" — for the kinds this build knows;
/// any other by the server's own name for it.
String xpSourceName(Strings t, LadderSource source) => switch ((
  source.kind,
  source.playMinutes,
  handNames[source.hand],
)) {
  (LadderSource.kindPlayTime, final int minutes, _) => t.xpPlayMinutes(minutes),
  (LadderSource.kindWinHand, _, final String hand) => t.xpWinBy(hand),
  _ => source.name.isNotEmpty ? source.name : source.code,
};

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

/// What the tax pill says: the rate the viewer pays — "17.43% TAX" — or
/// "TAX" alone where the rate is not known.
String taxPillLabel(Strings t, {int? bps}) =>
    bps == null ? t.taxPillNoRate : t.taxPill(formatTaxRate(bps));

/// A line that carries a level's mark, laid out on its own style's line
/// height: a colour emoji stands taller than the text round it, and a line
/// that grew for it would move whatever stands under it. The mark is drawn
/// from the phone's colour emoji font in its own colours — nothing tints it.
StrutStyle levelStrut(TextStyle style) =>
    StrutStyle.fromTextStyle(style, forceStrutHeight: true);

/// The pill on the lobby card of a table that taxes its winners: the percent
/// mark and the rate THIS viewer would pay there ("17.43% TAX"), in the tax's
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
/// moving with it, on the table's dark plate in both themes and in the tag's
/// own type. It says who the viewer is and what they pay (owner, 27 Sep 2026:
/// "instead Show text Player Title and then tax percent", then "In table top
/// also the badge name current player holding"): their level's title with its
/// mark in the tag's champagne, and under it the badge they hold — the one
/// that brings their rate lowest ([User.shownBadge]) — in the same champagne,
/// then the rate their seat pays in the tax's amber: "🌟 Rising Star" over
/// "[its Lottie] Regular · 17.43% TAX", "[its Lottie] Royal King · 0% TAX".
/// Two lines, scaled as one
/// where the slot is narrow, so a long title ("🔥🔱 Supreme Overlord") keeps a
/// readable size on a 640dp phone. With no level known it is the percent
/// mark, the badge and the rate on one line. It is a key — a tap lays out
/// everything the rate comes from ([showWinningTaxInfo]) — with a full touch
/// target round a small plate.
class WinningTaxTag extends StatelessWidget {
  const WinningTaxTag({
    super.key,
    required this.tax,
    required this.semanticLabel,
    required this.onTap,
    this.title,
    this.badge,
    this.badgeArt,
  });

  /// The rate the viewer's seat pays, as the pill says it: "17.43% TAX".
  final String tax;

  /// The viewer's level title with its mark ("🌟 Rising Star"), the pill's
  /// first line; null where the level is not known.
  final String? title;

  /// The badge the viewer holds, with its mark where it has one ("🏅 Gold"),
  /// before the rate; null where they hold none this phone knows of.
  final String? badge;

  /// That badge where it has art of its own — Regular's and the Royal badges'
  /// Lotties — played at the pill's left (owner, 27 Sep 2026: "where it is
  /// showing player badge name … it should show the lottie animation near
  /// that badge", then "increase the badge icon size which is shown in game
  /// table"): as tall as the plate inside its edge, both lines and the space
  /// above and below them ([emblemSize]), so the pill stands no taller for it;
  /// null for a badge shown by its emoji, which [badge] already carries.
  final PlayerBadge? badgeArt;

  /// What a screen reader calls the key.
  final String semanticLabel;
  final VoidCallback onTap;

  /// How many lines of the tag's type the pill stands: two with a title,
  /// one without.
  static int linesFor({required bool titled}) => titled ? 2 : 1;

  /// How tall the badge's art stands at the pill's left: the plate inside its
  /// edge — its [lines] of the tag's type, at the phone's text size, and the
  /// padding above and below them. The felt reserves exactly that
  /// (`_Felt.taxPillHeight`), so a bigger badge never moves the table.
  static double emblemSize(
    TextScaler scaler,
    ThemeData theme, {
    required int lines,
  }) {
    final style = TableType.tax(theme);
    return scaler.scale(style.fontSize ?? 14) * (style.height ?? 1.3) * lines +
        2 * Space.xs;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final taxStyle = TableType.tax(theme);
    final titleStyle = TableType.boot(
      theme,
    ).copyWith(fontWeight: FontWeight.w600);
    final held = badge;
    final words = Text.rich(
      TextSpan(
        children: [
          if (held != null && held.isNotEmpty) ...[
            TextSpan(text: held, style: titleStyle),
            TextSpan(text: ' · ', style: taxStyle),
          ],
          TextSpan(text: tax, style: taxStyle),
        ],
      ),
      key: const ValueKey('winning-tax-rate-words'),
      maxLines: 1,
      strutStyle: levelStrut(taxStyle),
    );
    final lines = linesFor(titled: title != null);
    final text = switch (title) {
      final title? => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            key: const ValueKey('winning-tax-title'),
            maxLines: 1,
            strutStyle: levelStrut(titleStyle),
            style: titleStyle,
          ),
          words,
        ],
      ),
      null => words,
    };
    // The badge's art, where it has some, is the pill's emblem: at its left,
    // from its top edge to its bottom, with the words beside it. A Row, never
    // a WidgetSpan (a placeholder opening a paragraph is set on a line with
    // no text metrics yet — CLAUDE.md, the bonus chips); scaled with the
    // words as one where the slot is narrow, so it shrinks with them rather
    // than crowding them.
    final art = badgeArt;
    final Widget content;
    final EdgeInsets padding;
    if (art != null) {
      content = FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            BadgeArt.held(
              art,
              key: const ValueKey('winning-tax-badge-art'),
              size: emblemSize(
                MediaQuery.textScalerOf(context),
                theme,
                lines: lines,
              ),
            ),
            const SizedBox(width: Space.xs),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.xs),
              child: text,
            ),
          ],
        ),
      );
      padding = const EdgeInsets.fromLTRB(Space.xxs, 0, Space.md, 0);
    } else if (title != null) {
      // The title over the rate, scaled as one: it shrinks on a small
      // screen rather than losing a word to an ellipsis.
      content = FittedBox(fit: BoxFit.scaleDown, child: text);
      padding = const EdgeInsets.fromLTRB(
        Space.md,
        Space.xs,
        Space.md,
        Space.xs,
      );
    } else {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(winningTaxIcon, size: 14, color: TableInk.tax),
          const SizedBox(width: Space.xs),
          Flexible(
            child: FittedBox(fit: BoxFit.scaleDown, child: words),
          ),
        ],
      );
      padding = const EdgeInsets.fromLTRB(
        Space.sm,
        Space.xs,
        Space.md,
        Space.xs,
      );
    }
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
              padding: padding,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// The level popup's three tabs (owner, 27 Sep 2026: "in that pop up add one
/// tab also for daily xp, one tab for ladder … for all levels with tax
/// rate"): the viewer's own level and what they pay, the daily XP, and every
/// level with its rate.
enum LevelInfoTab { mine, daily, ladder }

/// What the winning tax is and where the viewer stands, over the table (the
/// felt pill's tap; owner, 27 Sep 2026: "when user click on it, it will show
/// everything in detail and it also show all levels and taxes acc to that").
/// On the left the viewer's own standing — the rate they pay and what sets
/// it, their level and XP, the next level, their badges — and the daily XP;
/// on the right the whole ladder (`GET /api/levels`, read afresh each time the
/// popup opens): every level with the XP that reaches it and its rate, the
/// viewer's own row lit and scrolled to, then every badge with its rate,
/// validity and price. A badge is never shown as an XP goal (owner, 26 Sep
/// 2026: "VIP Tag is not granted by XP"). The lobby's level key opens the same
/// content in three tabs ([showLevelInfo]).
///
/// Nothing on the felt opens this two-pane popup any more: since 27 Sep 2026
/// the pill opens the lobby's level screen ([showTableLevelInfo]; owner: "when
/// i click the text on my level in gametable, it should pop the same UI which
/// it shows in Lobby"). It is kept, with its tests, because the owner had it
/// restored once ("restore that UI, only change was in Lobby"): going back is
/// the pill's one line.
Future<void> showWinningTaxInfo(
  BuildContext context, {
  LevelInfoTab tab = LevelInfoTab.mine,
}) => showTableDialog<void>(
  context: context,
  builder: (context) => WinningTaxInfo(initialTab: tab),
);

/// The level screen over the table — the pill's tap ([WinningTaxTag]; owner,
/// 27 Sep 2026: "when i click the text on my level in gametable, it should
/// pop the same UI which it shows in Lobby about player level, daily xp and
/// levels"): the lobby's [LevelScreen], its three tabs and everything on
/// them, behind the table's own dialog scrim ([showTableDialog]).
Future<void> showTableLevelInfo(
  BuildContext context, {
  LevelInfoTab tab = LevelInfoTab.mine,
}) => showTableDialog<void>(
  context: context,
  builder: (context) => LevelScreen(initialTab: tab),
);

/// The same content from the lobby's level key ([LevelKey]; owner, 27 Sep
/// 2026: "Add one icon in lobby so that user can see his level, and in that
/// pop up add one tab also for daily xp, one tab for ladder"), in three tabs
/// ([LevelInfoTab]) and titled with the level rather than the tax.
Future<void> showLevelInfo(
  BuildContext context, {
  LevelInfoTab tab = LevelInfoTab.mine,
}) => showDialog<void>(
  context: context,
  builder: (context) => WinningTaxInfo(initialTab: tab, fromLobby: true),
);

/// What the level popups are drawn from, as one value: the account (level,
/// XP, badges, rate), the ladder and whether it is being read, the language,
/// the rate the seat pays and the table's floor. The popups `select` it
/// rather than watching the game state, which notifies every second for the
/// lobby's reward clocks: a popup rebuilt on that tick restarted its bar's
/// fill and rebuilt its badges' players for nothing. What does move by the
/// second — a countdown, a grant running out — is a [LevelClock] of its own.
Object levelViewOf(GameState s) => (
  levelSignatureOf(s.user),
  s.levelLadder,
  s.levelLadderLoading,
  s.levelLadderFailed,
  s.lang,
  s.myTaxBps,
  s.room?.taxesWinner,
  s.room?.winnerTaxMinWinnings,
  s.config,
);

/// What the level popups draw of an account, as one comparable string: its
/// level, XP, next level, today's window and claims, the rate it pays, and
/// every badge with its grant. [levelViewOf] compares this rather than the
/// [User] — a fresh copy of the same account (every `me()` re-read, which
/// the lobby's rental watch makes every few seconds) would otherwise rebuild
/// every rung of the ladder for nothing.
String levelSignatureOf(User? u) {
  if (u == null) return '';
  final b = StringBuffer()
    ..write(u.id)
    ..write('|')
    ..write(u.taxBps);
  final l = u.playerLevel;
  if (l != null) {
    b.write(
      '|L${l.level}\u0000${l.title}\u0000${l.icon}\u0000${l.xp}'
      '\u0000${l.taxBps}',
    );
    final n = l.next;
    if (n != null) {
      b.write(
        '|N${n.level}\u0000${n.title}\u0000${n.icon}\u0000${n.minXp}'
        '\u0000${n.taxBps}',
      );
    }
    final today = l.today;
    if (today != null) {
      b.write('|T${today.xp},${today.cap},${today.resetsAt}');
    }
    final daily = l.daily;
    if (daily != null) {
      b.write('|D${daily.resetsAt}');
      for (final code in daily.claimed.keys.toList()..sort()) {
        b.write(',$code=${daily.claimed[code]}');
      }
    }
  }
  for (final x in u.badges) {
    b.write(
      '|B${x.code}\u0000${x.title}\u0000${x.icon}\u0000${x.taxBps}'
      '\u0000${x.expiresAt}\u0000${x.isDefault}\u0000${x.assetUrl}'
      '\u0000${x.assetFormat}',
    );
  }
  return b.toString();
}

/// The winnings a table taxes from: the viewer's table's where they sit at
/// one that taxes, else the smallest any table of the menu taxes from (50
/// Lakh as seeded, the same on every table) — 0 where none says, and then
/// nothing is said about a floor.
int taxFloorOf(GameState state) {
  final room = state.room;
  if (room != null && room.taxesWinner) return room.winnerTaxMinWinnings;
  var least = 0;
  for (final table in state.config.tables) {
    final floor = table.winnerTaxMinWinnings;
    if (!table.taxesWinner || floor <= 0) continue;
    if (least == 0 || floor < least) least = floor;
  }
  return least;
}

/// A piece of a popup that moves with the clock: [read] is asked every
/// second, and [builder] runs again only when its answer changes — a
/// countdown's words each second, a badge's "5 hours left" once an hour, a
/// grant that has run out once. Nothing round it is rebuilt.
class LevelClock<T> extends StatefulWidget {
  const LevelClock({super.key, required this.read, required this.builder});

  final T Function(DateTime now) read;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<LevelClock<T>> createState() => _LevelClockState<T>();
}

class _LevelClockState<T> extends State<LevelClock<T>> {
  late T _value = widget.read(DateTime.now());
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final value = widget.read(DateTime.now());
      if (value != _value) setState(() => _value = value);
    });
  }

  @override
  void didUpdateWidget(covariant LevelClock<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _value = widget.read(DateTime.now());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

/// "resets in 5h 12m 3s" until [resetsAt] (epoch ms), counted every second
/// by itself; nothing once that moment has passed.
class ResetsIn extends StatelessWidget {
  const ResetsIn({
    super.key,
    required this.resetsAt,
    required this.words,
    this.style,
    this.textAlign,
  });

  final int resetsAt;

  /// The line around the time: [Strings.xpResetsIn] or its capitalised twin.
  final String Function(String time) words;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final t = Strings(context.select<GameState, AppLang>((s) => s.lang));
    return LevelClock<String?>(
      read: (now) {
        final ms = resetsAt - now.millisecondsSinceEpoch;
        return ms <= 0
            ? null
            : words(formatCountdown(Duration(milliseconds: ms), t));
      },
      builder: (context, line) => line == null
          ? const SizedBox.shrink()
          : Text(
              line,
              maxLines: 2,
              textAlign: textAlign,
              style:
                  style ?? TableType.metadata(Theme.of(context), figures: true),
            ),
    );
  }
}

/// The popups' close key: a small round glass key — a sunk disc with a
/// hairline, the cross in the body ink — inside a full [Dim.minTouch] target.
class LevelCloseKey extends StatelessWidget {
  const LevelCloseKey({super.key, required this.tooltip, required this.onTap});

  final String tooltip;
  final VoidCallback onTap;

  static const double disc = 34;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        // The node keeps the key's tap: excluding the InkWell's own
        // semantics would otherwise leave a screen reader a button it
        // cannot press.
        onTap: () {
          tapHaptic(context);
          onTap();
        },
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('winning-tax-close'),
            customBorder: const CircleBorder(),
            onTap: () {
              tapHaptic(context);
              onTap();
            },
            child: SizedBox.square(
              dimension: Dim.minTouch,
              child: Center(
                child: Container(
                  width: disc,
                  height: disc,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: glass.wellFill,
                    border: Border.all(color: glass.cardBorder),
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurface.withValues(
                      alpha: AppTheme.inkMed,
                    ),
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

/// The popup [showWinningTaxInfo] and [showLevelInfo] open. From the lobby
/// it is the level screen ([LevelScreen]: three tabs); over the table, the
/// winning tax in two panes. Either follows the account ([levelViewOf]), so a
/// level reached at the hand's end — or a badge run out — is shown the moment
/// the server says so.
class WinningTaxInfo extends StatefulWidget {
  const WinningTaxInfo({
    super.key,
    this.initialTab = LevelInfoTab.mine,
    this.fromLobby = false,
  });

  /// The tab it opens on.
  final LevelInfoTab initialTab;

  /// Opened from the lobby's level key: the level screen, titled "Your
  /// level" and laid out in tabs, where the table's pill titles it with the
  /// tax and lays it out in two panes.
  final bool fromLobby;

  /// The table's popup lays its two panes side by side from this width; under
  /// it, one scroll holds both, the standing first.
  static const double twoPanesFrom = 460;

  /// The widest the popup grows, on a tablet.
  static const double maxWidth = 760;

  @override
  State<WinningTaxInfo> createState() => _WinningTaxInfoState();
}

class _WinningTaxInfoState extends State<WinningTaxInfo> {
  /// The viewer's own row of the ladder, brought into view once the ladder
  /// is first shown.
  final _you = GlobalKey();
  bool _placed = false;

  @override
  void initState() {
    super.initState();
    if (widget.fromLobby) return; // the level screen reads it itself
    // Read afresh once the popup is up, so an owner's edit shows the next
    // time it is looked at — after the frame, so the read's notice does not
    // ask for a rebuild in the middle of this one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<GameState>().loadLevelLadder();
    });
  }

  /// Scrolls the ladder to the viewer's row the first time it is built.
  void _placeYou() {
    if (_placed || !mounted) return;
    final row = _you.currentContext;
    if (row == null) return;
    _placed = true;
    Scrollable.ensureVisible(row, alignment: 0.3);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fromLobby) return LevelScreen(initialTab: widget.initialTab);
    context.select<GameState, Object>(levelViewOf);
    final state = context.read<GameState>();
    final t = state.t;
    final size = MediaQuery.sizeOf(context);
    final width = math.min(size.width - 2 * Space.lg, WinningTaxInfo.maxWidth);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(Space.lg),
      child: SizedBox(
        width: width,
        height: Dim.dialogMaxH(size.height),
        child: PremiumGlassPanel(
          mode: GlassMode.auto,
          priority: 20,
          radius: Radii.lg,
          padding: const EdgeInsets.fromLTRB(
            Space.lg,
            Space.sm,
            Space.xs,
            Space.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: dialogTitle(
                      context,
                      winningTaxIcon,
                      t.winningTaxTitle,
                    ),
                  ),
                  LevelCloseKey(
                    tooltip: t.close,
                    onTap: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: Space.xs),
              Expanded(child: _panes(context, state)),
            ],
          ),
        ),
      ),
    );
  }

  /// The table's layout: the standing and the daily XP beside the ladder
  /// from [WinningTaxInfo.twoPanesFrom], or all of it in one scroll under it.
  Widget _panes(BuildContext context, GameState state) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final two = box.maxWidth >= WinningTaxInfo.twoPanesFrom;
        final standing = [
          ..._standing(context, state),
          ..._dailyList(context, state, first: false),
        ];
        final ladder = _ladder(context, state, place: two);
        if (two) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _placeYou());
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 5,
                child: _Pane(
                  key: const ValueKey('winning-tax-standing'),
                  children: standing,
                ),
              ),
              Container(
                width: Dim.hairline,
                margin: const EdgeInsets.symmetric(horizontal: Space.sm),
                color: theme.colorScheme.onSurface.withValues(alpha: 0.12),
              ),
              Expanded(
                flex: 6,
                child: _Pane(
                  key: const ValueKey('winning-tax-ladder'),
                  children: ladder,
                ),
              ),
            ],
          );
        }
        return _Pane(
          key: const ValueKey('winning-tax-standing'),
          children: [...standing, ...ladder],
        );
      },
    );
  }

  /// The standing: what the viewer pays and why, their level, XP and
  /// today's XP where there is a cap, the next level, and their badges.
  List<Widget> _standing(BuildContext context, GameState state) {
    final theme = Theme.of(context);
    final t = state.t;
    final user = state.user;
    final level = user?.playerLevel;
    final bps = state.myTaxBps ?? user?.paysTaxBps;
    final rateBadge = user?.rateBadge;
    final next = level?.next;
    final today = level?.today;
    final ladder = state.levelLadder;
    final minWinnings = taxFloorOf(state);

    // How far the XP has come from this level's threshold to the next's —
    // only where the ladder says where this level starts.
    final progress = level == null || next == null
        ? null
        : levelProgressOf(level, ladder);

    return [
      Text(t.winningTaxOnlyWinner, style: TableType.modalBody(theme)),
      if (minWinnings > 0) ...[
        const SizedBox(height: Space.xxs),
        Text(
          t.winningTaxFrom(formatChips(minWinnings)),
          key: const ValueKey('winning-tax-from'),
          style: TableType.modalBody(theme),
        ),
      ],
      const SizedBox(height: Space.xxs),
      Text(t.winningTaxFalls, style: TableType.metadata(theme)),
      Text(t.winningTaxLowest, style: TableType.metadata(theme)),
      const SizedBox(height: Space.sm),
      if (bps != null)
        WinningTaxFact(
          key: const ValueKey('winning-tax-rate'),
          icon: winningTaxIcon,
          label: t.yourRateLabel,
          value: formatTaxRate(bps),
          detail: rateBadge == null
              ? t.rateSetByLevel
              : t.rateSetByBadge(badgeTitleOf(rateBadge)),
          strong: true,
        ),
      if (level != null) ...[
        WinningTaxFact(
          icon: Icons.military_tech_rounded,
          label: t.yourLevelLabel,
          value: levelNameOf(t, level),
          detail: '${t.levelTaxLabel} ${formatTaxRate(level.taxBps)}',
        ),
        WinningTaxFact(
          icon: Icons.bolt_rounded,
          label: t.xpLabel,
          value: formatChips(level.xp),
        ),
        if (progress != null) _XpProgress(fraction: progress),
      ],
      if (today != null)
        WinningTaxFact(
          icon: Icons.today_rounded,
          label: t.todayLabel,
          value: '${today.xp} / ${today.cap} XP',
          detailWidget: ResetsIn(
            resetsAt: today.resetsAt,
            words: t.xpResetsIn,
            textAlign: TextAlign.end,
          ),
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
      // The top of the ladder: nothing further for XP to reach.
      if (level != null && next == null) ...[
        const SizedBox(height: Space.xs),
        Text(t.topLevelNote, style: TableType.metadata(theme)),
      ],
      if (user != null && user.badges.isNotEmpty) ...[
        _SectionHead(t.yourBadgesTitle),
        for (final badge in user.badges) _heldBadgeRow(t, badge),
      ],
    ];
  }

  /// One of the viewer's badges, its grant's words following the clock — "5
  /// hours left" becomes "4 hours left" on the hour, and a grant that runs
  /// out while the popup is open says nothing more — while its art, built
  /// once here, is never rebuilt by it.
  Widget _heldBadgeRow(Strings t, PlayerBadge badge) {
    final art = badge.assetUrl.isEmpty ? null : BadgeArt.held(badge, size: 24);
    return LevelClock<String?>(
      key: ValueKey('my-badge-${badge.code}'),
      read: (now) => switch (badge.leftAt(now)) {
        final left? => badgeLeftOf(
          t,
          left,
          DateTime.fromMillisecondsSinceEpoch(badge.expiresAt),
        ),
        // Regular, everybody's for life (owner, 27 Sep 2026: "validaity life
        // time").
        null when badge.isDefault || badge.expiresAt == 0 => t.badgeLifetime,
        null => null,
      },
      builder: (context, detail) => _BadgeRow(
        art: art,
        mark: badge.icon,
        title: badge.title,
        rate: badge.taxBps,
        detail: detail,
      ),
    );
  }

  /// The daily XP section — the sources with what they give, ticked where
  /// earned, and how the list resets — the standing pane's foot; nothing
  /// until the ladder is read. Whether the window is still running follows
  /// the clock, so a window that ends while the popup is open clears its
  /// ticks and its countdown at once.
  List<Widget> _dailyList(
    BuildContext context,
    GameState state, {
    required bool first,
  }) {
    final ladder = state.levelLadder;
    final daily = state.user?.playerLevel?.daily;
    if (ladder == null || ladder.sources.isEmpty) return const [];
    return [
      LevelClock<bool>(
        key: const ValueKey('winning-tax-daily-list'),
        read: (now) => daily?.leftAt(now) != null,
        builder: (context, running) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _dailyRows(context, state, ladder, first, running),
        ),
      ),
    ];
  }

  List<Widget> _dailyRows(
    BuildContext context,
    GameState state,
    LevelLadder ladder,
    bool first,
    bool running,
  ) {
    final theme = Theme.of(context);
    final t = state.t;
    final daily = state.user?.playerLevel?.daily;
    return [
      _SectionHead(
        t.xpDailyTitle,
        first: first,
        trailing: !running || daily == null
            ? null
            : ResetsIn(resetsAt: daily.resetsAt, words: t.xpResetsIn),
      ),
      for (final source in ladder.sources)
        _SourceRow(
          key: ValueKey('xp-source-${source.code}'),
          mark: source.icon,
          name: xpSourceName(t, source),
          xp: source.xp,
          times: source.times,
          // A window that has run out is a fresh one: nothing earned yet.
          claims: !running || daily == null ? 0 : daily.claimsOf(source.code),
          earnedLabel: t.xpEarned,
        ),
      const SizedBox(height: Space.xs),
      Text(
        t.xpListResets(math.max(1, (ladder.windowMs / 3600000).round())),
        style: TableType.metadata(theme),
      ),
      if (ladder.dailyCap > 0) ...[
        const SizedBox(height: Space.xxs),
        Text(
          t.xpDailyCap(
            ladder.dailyCap,
            math.max(1, (ladder.windowMs / 3600000).round()),
          ),
          style: TableType.metadata(theme),
        ),
      ],
      const SizedBox(height: Space.xxs),
      Text(t.xpNeverExpires, style: TableType.metadata(theme)),
    ];
  }

  /// The ladder's pane before it has been read: its heading over a spinner,
  /// or — where it cannot be read — a line and Try again.
  List<Widget> _unread(BuildContext context, GameState state, String head) {
    final theme = Theme.of(context);
    final t = state.t;
    return [
      _SectionHead(head, first: true),
      const SizedBox(height: Space.lg),
      if (state.levelLadderFailed && !state.levelLadderLoading) ...[
        Text(
          t.levelsUnavailable,
          textAlign: TextAlign.center,
          style: TableType.metadata(theme),
        ),
        const SizedBox(height: Space.sm),
        Center(
          child: TextButton(
            key: const ValueKey('winning-tax-retry'),
            onPressed: state.loadLevelLadder,
            child: Text(t.luckyRetry),
          ),
        ),
      ] else
        const Center(child: GameLoader(size: 32)),
    ];
  }

  /// The whole ladder, then every badge — or, until it is read, a spinner,
  /// and where it cannot be, a line and Try again.
  List<Widget> _ladder(
    BuildContext context,
    GameState state, {
    required bool place,
  }) {
    final t = state.t;
    final ladder = state.levelLadder;
    final user = state.user;
    final mine = user?.playerLevel?.level;
    final held = {
      for (final b in user?.badges ?? const <PlayerBadge>[]) b.code,
    };

    if (ladder == null) {
      return _unread(context, state, t.allLevelsTitle);
    }
    return [
      _SectionHead(t.allLevelsTitle, first: true, column: t.taxColumn),
      for (final level in ladder.levels)
        _LadderRow(
          key: level.level == mine && place
              ? _you
              : ValueKey('ladder-${level.level}'),
          level: level,
          you: level.level == mine,
          youLabel: t.levelYou,
        ),
      if (ladder.badges.isNotEmpty) ...[
        _SectionHead(t.badgesTitle, column: t.taxColumn),
        for (final badge in ladder.badges)
          _BadgeRow(
            key: ValueKey('ladder-badge-${badge.code}'),
            art: badge.assetUrl.isEmpty ? null : BadgeArt.of(badge, size: 24),
            mark: badge.icon,
            title: badge.title,
            rate: badge.taxBps,
            detail: ladderBadgeDetail(t, badge),
            lit: held.contains(badge.code) && !badge.isDefault,
          ),
      ],
    ];
  }
}

/// A badge of the catalogue described: who holds it, how long a grant lasts
/// and its price — "Everyone · Lifetime · Free", "Lasts 15 days · ₹999".
String ladderBadgeDetail(Strings t, LadderBadge badge) => [
  if (badge.isDefault) t.badgeEveryone,
  badge.validityDays > 0 ? t.badgeLasts(badge.validityDays) : t.badgeLifetime,
  // Always rupees (owner, 27 Sep 2026: "price in badges will always be in inr
  // currency"); Regular's 0 is free.
  if (badge.priceInr case final price?)
    price == 0 ? t.badgeFree : '₹${formatChips(price)}',
].join(' · ');

/// The lobby's level key (owner, 27 Sep 2026: "Add one icon in lobby so that
/// user can see his level"): a round key at the foot, beside the Friends key,
/// wearing the level's number; a tap opens the level popup
/// ([showLevelInfo]). Nothing until the account names a level.
class LevelKey extends StatelessWidget {
  const LevelKey({super.key});

  static const double side = Dim.minTouch;

  @override
  Widget build(BuildContext context) {
    final level = context.select<GameState, PlayerLevel?>(
      (s) => s.user?.playerLevel,
    );
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    if (level == null) return const SizedBox.shrink();
    final t = Strings(lang);
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final gold = goldInk(theme.brightness);
    final name = levelNameOf(t, level);
    return Padding(
      padding: const EdgeInsets.only(right: Space.sm),
      child: Semantics(
        button: true,
        label: '${t.yourLevelTitle}: $name',
        onTap: () {
          lobbyClick(context);
          showLevelInfo(context);
        },
        excludeSemantics: true,
        child: Tooltip(
          message: name,
          child: PressScale(
            child: Badge(
              key: const ValueKey('level-key-badge'),
              backgroundColor: AppTheme.gold,
              textColor: AppTheme.ink900,
              offset: const Offset(2, -2),
              label: Text('${level.level}'),
              child: SizedBox.square(
                dimension: side,
                child: GlassCapsule(
                  key: const ValueKey('level-key'),
                  surface: GlassSurface.card,
                  minHeight: side,
                  // The lobby's click (owner, 27 Sep 2026).
                  click: true,
                  onTap: () => showLevelInfo(context),
                  padding: const EdgeInsets.all((side - 28) / 2),
                  child: Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: glass.wellFill,
                      border: Border.all(color: glass.cardBorder),
                    ),
                    child: level.icon.isEmpty
                        ? Icon(
                            Icons.military_tech_rounded,
                            size: 16,
                            color: gold,
                          )
                        : Text(
                            level.icon,
                            style: const TextStyle(fontSize: 14, height: 1),
                          ),
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

/// One of the popup's panes: its children in a scroll of their own, faded
/// at an edge while there is more beyond it.
class _Pane extends StatelessWidget {
  const _Pane({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => EdgeFade(
    child: SingleChildScrollView(
      primary: false,
      padding: const EdgeInsets.only(right: Space.sm, bottom: Space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

/// A section's name — "Your badges", "How to earn XP", "All levels" — with,
/// for the ladder's, the name of its rate column at the right.
class _SectionHead extends StatelessWidget {
  const _SectionHead(
    this.text, {
    this.first = false,
    this.column,
    this.trailing,
  });

  final String text;
  final bool first;
  final String? column;

  /// Something that moves at the right instead of [column]: the daily list's
  /// reset, counted by itself.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = TableType.label(theme, colour: goldInk(theme.brightness));
    return Padding(
      padding: EdgeInsets.only(top: first ? 0 : Space.md, bottom: Space.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          if (trailing case final trailing?)
            trailing
          else if (column case final column?)
            Text(column, style: TableType.metadata(theme)),
        ],
      ),
    );
  }
}

/// A thin gold bar: how far the viewer's XP has come from their level's
/// threshold to the next's.
class _XpProgress extends StatelessWidget {
  const _XpProgress({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gold = goldInk(theme.brightness);
    return Padding(
      key: const ValueKey('winning-tax-progress'),
      padding: const EdgeInsets.only(
        left: TableSpace.rowIconSlot + Space.md,
        top: Space.xxs,
        bottom: Space.xs,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.pill),
        child: SizedBox(
          height: 4,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: gold.withValues(alpha: 0.18)),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: fraction,
                heightFactor: 1,
                child: ColoredBox(color: gold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One rung of the ladder: its number, its title with its mark and the XP
/// that reaches it, and its rate — the viewer's own rung lit in gold and
/// marked as theirs.
class _LadderRow extends StatelessWidget {
  const _LadderRow({
    super.key,
    required this.level,
    required this.you,
    required this.youLabel,
  });

  final LadderLevel level;
  final bool you;
  final String youLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final gold = goldInk(theme.brightness);
    final name = TableType.info(theme, colour: scheme.onSurface);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.xs,
        vertical: Space.xxs,
      ),
      decoration: you
          ? BoxDecoration(
              color: gold.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: gold.withValues(alpha: 0.6)),
            )
          : null,
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '${level.level}',
              textAlign: TextAlign.end,
              style: TableType.metadata(theme, figures: true),
            ),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          levelTitle(level.icon, level.title),
                          maxLines: 1,
                          strutStyle: levelStrut(name),
                          style: name,
                        ),
                      ),
                    ),
                    // The viewer's own rung says so beside its name, never
                    // under it: the line under a name is the XP that reaches
                    // the rung, not the viewer's own.
                    if (you) ...[
                      const SizedBox(width: Space.xs),
                      Container(
                        key: const ValueKey('ladder-you'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.xs,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: gold.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(Radii.xs),
                          border: Border.all(
                            color: gold.withValues(alpha: 0.6),
                          ),
                        ),
                        child: Text(
                          youLabel,
                          maxLines: 1,
                          style: TableType.label(theme, colour: gold),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  '${formatChips(level.minXp)} XP',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TableType.metadata(theme, figures: true),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.sm),
          Text(
            formatTaxRate(level.taxBps),
            style: TableType.chips(
              theme,
              colour: you ? TableInk.taxOn(theme.brightness) : gold,
            ),
          ),
        ],
      ),
    );
  }
}

/// A badge: its mark and title, a quieter line under them (who holds it, how
/// long a grant lasts, or how long the viewer's has left), and the rate it
/// brings a holder's down to — a dash for one that sets none. [lit] is a
/// badge the viewer holds.
class _BadgeRow extends StatelessWidget {
  const _BadgeRow({
    super.key,
    required this.mark,
    required this.title,
    required this.rate,
    this.art,
    this.detail,
    this.lit = false,
  });

  /// The badge's own art (a Royal badge's Lottie), drawn in the mark's place.
  final Widget? art;
  final String mark;
  final String title;
  final int? rate;
  final String? detail;
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final gold = goldInk(theme.brightness);
    final name = TableType.info(theme, colour: scheme.onSurface);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.xs,
        vertical: Space.xxs,
      ),
      decoration: lit
          ? BoxDecoration(
              color: gold.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: gold.withValues(alpha: 0.6)),
            )
          : null,
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: art != null
                ? Center(child: art)
                : mark.isEmpty
                ? Icon(Icons.workspace_premium_rounded, size: 16, color: gold)
                : FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      mark,
                      strutStyle: levelStrut(name),
                      style: name,
                    ),
                  ),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: name,
                ),
                if (detail case final detail?)
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TableType.metadata(theme, figures: true),
                  ),
              ],
            ),
          ),
          const SizedBox(width: Space.sm),
          Text(
            rate == null ? '—' : formatTaxRate(rate!),
            style: TableType.chips(theme, colour: gold),
          ),
        ],
      ),
    );
  }
}

/// A daily XP source and what it gives — "🎮 Play 15 active minutes  +3 XP" —
/// ticked, its XP gone quiet, once earned in the running window; one that
/// can be earned more than once a window says how many times so far ("1/3").
class _SourceRow extends StatelessWidget {
  const _SourceRow({
    super.key,
    required this.mark,
    required this.name,
    required this.xp,
    required this.earnedLabel,
    this.times = 1,
    this.claims = 0,
  });

  final String mark;
  final String name;
  final int xp;
  final int times;
  final int claims;

  /// What a screen reader says of a source already earned.
  final String earnedLabel;

  bool get earned => claims >= times;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final gold = goldInk(theme.brightness);
    final quiet = scheme.onSurface.withValues(
      alpha: AppTheme.inkLowOn(theme.brightness),
    );
    final nameStyle = TableType.info(
      theme,
      colour: scheme.onSurface.withValues(alpha: AppTheme.inkMed),
    );
    return Semantics(
      label: '$name, +$xp XP${earned ? ', $earnedLabel' : ''}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.xxs),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: mark.isEmpty
                  ? Icon(Icons.bolt_rounded, size: 16, color: gold)
                  : FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        mark,
                        strutStyle: levelStrut(nameStyle),
                        style: nameStyle,
                      ),
                    ),
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(
                name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: nameStyle,
              ),
            ),
            if (times > 1) ...[
              const SizedBox(width: Space.sm),
              Text(
                '${math.min(claims, times)}/$times',
                style: TableType.metadata(theme, figures: true),
              ),
            ],
            const SizedBox(width: Space.sm),
            if (earned) ...[
              Icon(
                Icons.check_circle_rounded,
                key: ValueKey('xp-earned-$name'),
                size: 16,
                color: scheme.primary,
              ),
              const SizedBox(width: Space.xs),
            ],
            Text(
              '+$xp XP',
              style: TableType.chips(theme, colour: earned ? quiet : gold),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line of the tax popup: what it is on the left, its value on the
/// right in gold (the viewer's own rate in the tax's amber). Both may take a
/// second line rather than lose a word — a level's name, with its mark, runs
/// long in a narrow pane at a large text size.
class WinningTaxFact extends StatelessWidget {
  const WinningTaxFact({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.detail,
    this.detailWidget,
    this.strong = false,
  });

  final IconData icon;
  final String label;
  final String value;

  /// A quieter line that counts by itself (a [ResetsIn]), in [detail]'s place.
  final Widget? detailWidget;

  /// A quieter line under the value: what reaches the next level and what it
  /// charges, what sets the rate paid, when today's window resets.
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
              color: strong
                  ? TableInk.taxOn(theme.brightness)
                  : scheme.onSurface.withValues(
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
                  )
                else
                  ?detailWidget,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
