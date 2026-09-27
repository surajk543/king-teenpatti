import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/strings.dart';
import '../models/report.dart';
import '../state/game_state.dart' show formatCountdown;
import '../state/player_reports.dart';
import '../theme/app_theme.dart';
import '../theme/table_theme.dart';
import '../theme/theme_colors.dart';
import 'glass_components.dart';
import 'player_drawer.dart' show DrawerKey;
import 'player_profile.dart' show friendsGreen;
import 'table_chrome.dart';

// Report Player (owner, 27 Sep 2026: "A player sitting at a gameplay table
// must be able to report another player currently at the same table … Add
// 'Report Player' to the existing player interaction menu. Do not place a
// large report button directly on the gameplay table"). A page of the table's
// player drawer, never a route over the table (a route can outlive the table
// it was raised from — CLAUDE.md §8.4): the drawer's quiet Report player line
// turns the drawer to it, and Cancel, Done and the drawer shutting turn it
// back. The player chooses a reason — OTHER needs a few words, the rest take
// them optionally — and sends it; the server says where it was made, and the
// page thanks them in the brief's words. It changes nothing at the table.

/// A reason, in the player's language.
String reportReasonLabel(Strings t, ReportReason r) => switch (r) {
  ReportReason.cheating => t.reportReasonCheating,
  ReportReason.harassment => t.reportReasonHarassment,
  ReportReason.abusiveLanguage => t.reportReasonAbusiveLanguage,
  ReportReason.spam => t.reportReasonSpam,
  ReportReason.inappropriateBehavior => t.reportReasonInappropriate,
  ReportReason.suspiciousGameplay => t.reportReasonSuspicious,
  ReportReason.collusion => t.reportReasonCollusion,
  ReportReason.exploitingBug => t.reportReasonExploit,
  ReportReason.other => t.reportReasonOther,
};

/// The drawer's Report player line: quiet — the drawer's metadata ink, a flag
/// and the words, no fill, no gold — under the move the two players' standing
/// offers, so it is found without being a key the eye goes to first. A
/// player already reported this session reads "✓ Reported", dead.
///
/// With every report the limit allows used ([PlayerReports.limited]; owner,
/// 27 Sep 2026: "if user has reported 2 player, then reporting by him should
/// be disabled in UI, and show a cool down time in UI when can he report
/// again") it is dead for every other player too: an hourglass, "Report limit
/// reached · 2 of 2 reports used", and under it the time to the next report,
/// counting down ([ReportCooldown]). The moment it runs out the line is
/// pressable again.
class ReportPlayerRow extends StatelessWidget {
  const ReportPlayerRow({
    super.key,
    required this.t,
    required this.reported,
    required this.onReport,
    this.reports,
  });

  final Strings t;

  /// This player has been reported this session: nothing to press.
  final bool reported;
  final VoidCallback onReport;

  /// The player's report limit, when known: used up, the line is dead and
  /// counts down to the next report.
  final PlayerReports? reports;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkLowOn(theme.brightness),
    );
    final style = TableType.info(theme, colour: ink);
    final reports = this.reports;
    final opensAt = reports?.limitOpensAt;
    if (!reported && reports != null && opensAt != null) {
      return _limitedRow(context, reports, opensAt, ink, style);
    }
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: Dim.minTouch),
      child: Row(
        children: [
          Icon(
            reported ? Icons.check_rounded : Icons.outlined_flag_rounded,
            size: 18,
            color: ink,
          ),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Text(
              reported ? t.reportedTag : t.reportPlayer,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
        ],
      ),
    );
    if (reported) {
      return Semantics(
        key: const ValueKey('seat-reported'),
        container: true,
        child: row,
      );
    }
    return Semantics(
      key: const ValueKey('seat-report'),
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.sm),
        onTap: () {
          tapHaptic(context);
          onReport();
        },
        child: row,
      ),
    );
  }
}

/// The line with every report used: dead, the limit said, and the wait.
extension on ReportPlayerRow {
  Widget _limitedRow(
    BuildContext context,
    PlayerReports reports,
    DateTime opensAt,
    Color ink,
    TextStyle style,
  ) {
    final theme = Theme.of(context);
    final limit = reports.limit;
    final title = limit == null || limit.max <= 0
        ? t.reportLimitTitle
        : '${t.reportLimitTitle} · ${t.reportLimitUsed(limit.used, limit.max)}';
    return Semantics(
      key: const ValueKey('seat-report-limited'),
      container: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Dim.minTouch),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(Icons.hourglass_top_rounded, size: 18, color: ink),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      key: const ValueKey('seat-report-limit-title'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                    const SizedBox(height: Space.xxs),
                    ReportCooldown(
                      key: const ValueKey('seat-report-cooldown'),
                      t: t,
                      opensAt: opensAt,
                      now: reports.now,
                      style: TableType.metadata(
                        theme,
                        colour: AppTheme.goldInk(theme.brightness),
                        figures: true,
                      ).copyWith(fontWeight: FontWeight.w600),
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

/// "You can report again in 23h 41m 5s", counted every second by itself
/// against [now] down to [opensAt] — rounded up, so it never reads 0s while
/// the wait is still on — and nothing once it has passed (the report limit's
/// own timer brings the Report line back then). Only this line ticks: the
/// drawer around it rebuilds for nothing.
class ReportCooldown extends StatefulWidget {
  const ReportCooldown({
    super.key,
    required this.t,
    required this.opensAt,
    required this.now,
    this.style,
    this.textAlign,
  });

  final Strings t;
  final DateTime opensAt;
  final DateTime Function() now;
  final TextStyle? style;
  final TextAlign? textAlign;

  /// The line at [now], or null once the wait is over.
  static String? lineAt(Strings t, DateTime opensAt, DateTime now) {
    final ms = opensAt.difference(now).inMilliseconds;
    if (ms <= 0) return null;
    final wait = Duration(seconds: (ms + 999) ~/ 1000);
    return t.reportAgainIn(formatCountdown(wait, t));
  }

  @override
  State<ReportCooldown> createState() => _ReportCooldownState();
}

class _ReportCooldownState extends State<ReportCooldown> {
  Timer? _timer;
  String? _line;

  @override
  void initState() {
    super.initState();
    _line = _read();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final line = _read();
      if (line != _line) setState(() => _line = line);
      if (line == null) {
        _timer?.cancel();
        _timer = null;
      }
    });
  }

  @override
  void didUpdateWidget(covariant ReportCooldown oldWidget) {
    super.didUpdateWidget(oldWidget);
    _line = _read();
  }

  String? _read() =>
      ReportCooldown.lineAt(widget.t, widget.opensAt, widget.now());

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final line = _line;
    if (line == null) return const SizedBox.shrink();
    return Text(
      line,
      maxLines: 2,
      textAlign: widget.textAlign,
      style:
          widget.style ?? TableType.metadata(Theme.of(context), figures: true),
    );
  }
}

/// The report page: the reasons, the description, Submit and Cancel — or,
/// once the server has filed it, the thank-you. Drawn in the drawer's list
/// under the player's name and picture, so who is being reported is never in
/// doubt.
class ReportPlayerPage extends StatefulWidget {
  const ReportPlayerPage({super.key, required this.t, required this.reports});

  final Strings t;
  final PlayerReports reports;

  @override
  State<ReportPlayerPage> createState() => _ReportPlayerPageState();
}

class _ReportPlayerPageState extends State<ReportPlayerPage> {
  late final TextEditingController _text = TextEditingController(
    text: widget.reports.description,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    await widget.reports.submit();
  }

  @override
  Widget build(BuildContext context) {
    final reports = widget.reports;
    final t = widget.t;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: reports.sent
          ? _Sent(
              key: const ValueKey('report-sent'),
              t: t,
              reports: reports,
              onDone: reports.close,
            )
          : _Form(
              key: const ValueKey('report-form'),
              t: t,
              reports: reports,
              text: _text,
              onSubmit: _submit,
            ),
    );
  }
}

class _Form extends StatelessWidget {
  const _Form({
    super.key,
    required this.t,
    required this.reports,
    required this.text,
    required this.onSubmit,
  });

  final Strings t;
  final PlayerReports reports;
  final TextEditingController text;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quiet = scheme.onSurface.withValues(alpha: AppTheme.inkMed);
    final reason = reports.reason;
    final busy = reports.submitting;
    final required = reason?.needsDescription ?? false;
    final length = reportDescriptionLength(text.text.trim());
    final error = reports.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              key: const ValueKey('report-back'),
              visualDensity: VisualDensity.compact,
              tooltip: t.back,
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: busy ? null : reports.close,
            ),
            const SizedBox(width: Space.xs),
            Expanded(
              child: Text(
                t.reportPlayer,
                key: const ValueKey('report-title'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TableType.system(
                  theme,
                  colour: scheme.onSurface,
                  strong: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.xs),
        Text(t.reportWhy, style: TableType.info(theme, colour: quiet)),
        const SizedBox(height: Space.sm),
        Wrap(
          key: const ValueKey('report-reasons'),
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            for (final r in ReportReason.values)
              _ReasonChip(
                key: ValueKey('report-reason:${r.wire}'),
                label: reportReasonLabel(t, r),
                selected: r == reason,
                onTap: busy ? null : () => reports.choose(r),
              ),
          ],
        ),
        const SizedBox(height: Space.lg),
        TextField(
          key: const ValueKey('report-description'),
          controller: text,
          enabled: !busy,
          minLines: 2,
          maxLines: 4,
          keyboardType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          inputFormatters: [_CodePointLimit(reportDescriptionMax)],
          onChanged: reports.describe,
          style: TableType.modalBody(theme),
          decoration: InputDecoration(
            labelText: t.reportDetails,
            hintText: required
                ? t.reportDetailsRequiredHint
                : t.reportDetailsHint,
            hintMaxLines: 2,
            floatingLabelBehavior: FloatingLabelBehavior.always,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: Space.xxs),
          child: Text(
            '$length / $reportDescriptionMax',
            key: const ValueKey('report-count'),
            textAlign: TextAlign.end,
            style: TableType.metadata(theme, figures: true),
          ),
        ),
        if (reports.limited)
          _ReportNote(
            key: const ValueKey('report-error'),
            text: t.reportLimitTitle,
            below: ReportCooldown(
              key: const ValueKey('report-cooldown'),
              t: t,
              opensAt: reports.limitOpensAt!,
              now: reports.now,
              style: TableType.metadata(
                theme,
                colour: scheme.error,
                figures: true,
              ),
            ),
          )
        else if (error != null)
          _ReportNote(
            key: const ValueKey('report-error'),
            text: reportRefusalText(t, error),
          ),
        const SizedBox(height: Space.md),
        DrawerKey(
          key: const ValueKey('report-submit'),
          role: KeyRole.primary,
          icon: Icons.outlined_flag_rounded,
          label: busy ? t.reportSubmitting : t.reportSubmit,
          busy: busy,
          onPressed: reports.canSubmit ? () => unawaited(onSubmit()) : null,
        ),
        const SizedBox(height: Space.sm),
        DrawerKey(
          key: const ValueKey('report-cancel'),
          role: KeyRole.secondary,
          icon: Icons.close_rounded,
          label: t.cancel,
          onPressed: busy ? null : reports.close,
        ),
      ],
    );
  }
}

/// One reason: a pill a tap chooses, the one chosen marked by a tick and the
/// table's gold edge as well as its wash — never by colour alone — and read
/// to a screen reader as a choice of one among several.
class _ReasonChip extends StatelessWidget {
  const _ReasonChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final gold = AppTheme.goldInk(theme.brightness);
    final ink = theme.colorScheme.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.pill),
          onTap: onTap == null
              ? null
              : () {
                  tapHaptic(context);
                  onTap!();
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            constraints: const BoxConstraints(minHeight: Dim.minTouch),
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            decoration: BoxDecoration(
              color: selected
                  ? AppTheme.gold.withValues(alpha: 0.16)
                  : glass.wellFill,
              borderRadius: BorderRadius.circular(Radii.pill),
              border: Border.all(
                color: selected
                    ? gold
                    : AppTheme.hairlineColour(theme.brightness, live: false),
                width: selected ? 1.5 : Dim.hairline,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Icon(Icons.check_rounded, size: 16, color: gold),
                  const SizedBox(width: Space.xs),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TableType.label(
                      theme,
                      colour: ink,
                      weight: selected ? FontWeight.w700 : FontWeight.w600,
                    ),
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

/// The thank-you, in the brief's words: "✓ Report submitted", "Thank you for
/// helping keep the game fair.", "Our team will review the report." Nothing
/// about what will be done, or when.
class _Sent extends StatelessWidget {
  const _Sent({
    super.key,
    required this.t,
    required this.reports,
    required this.onDone,
  });

  final Strings t;
  final PlayerReports reports;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final green = friendsGreen(theme.brightness);
    final quiet = theme.colorScheme.onSurface.withValues(
      alpha: AppTheme.inkMed,
    );
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: Space.md),
          Icon(
            Icons.check_circle_rounded,
            key: const ValueKey('report-sent-mark'),
            size: 40,
            color: green,
          ),
          const SizedBox(height: Space.sm),
          Text(
            t.reportSubmitted,
            key: const ValueKey('report-sent-title'),
            textAlign: TextAlign.center,
            style: TableType.modalTitle(theme),
          ),
          const SizedBox(height: Space.sm),
          Text(
            t.reportThanks,
            key: const ValueKey('report-sent-thanks'),
            textAlign: TextAlign.center,
            style: TableType.modalBody(theme),
          ),
          const SizedBox(height: Space.xs),
          Text(
            t.reportReview,
            key: const ValueKey('report-sent-review'),
            textAlign: TextAlign.center,
            style: TableType.modalBody(theme).copyWith(color: quiet),
          ),
          // That was the last report the limit allows: say when the next opens,
          // so the Report line switched off on the next player is no surprise.
          if (reports.limitOpensAt case final opensAt?) ...[
            const SizedBox(height: Space.md),
            ReportCooldown(
              key: const ValueKey('report-sent-cooldown'),
              t: t,
              opensAt: opensAt,
              now: reports.now,
              textAlign: TextAlign.center,
              style: TableType.metadata(
                theme,
                colour: AppTheme.goldInk(theme.brightness),
                figures: true,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: Space.lg),
          DrawerKey(
            key: const ValueKey('report-done'),
            role: KeyRole.secondary,
            icon: Icons.check_rounded,
            label: t.reportDone,
            onPressed: onDone,
          ),
        ],
      ),
    );
  }
}

/// Why the report did not go, said where it was made.
class _ReportNote extends StatelessWidget {
  const _ReportNote({super.key, required this.text, this.below});

  final String text;

  /// A second line under the words (the limit's countdown).
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = theme.colorScheme.error;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: Space.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(Icons.error_outline_rounded, size: 16, color: ink),
            ),
            const SizedBox(width: Space.sm),
            Expanded(
              child: below == null
                  ? Text(text, style: TableType.info(theme, colour: ink))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(text, style: TableType.info(theme, colour: ink)),
                        const SizedBox(height: Space.xxs),
                        below!,
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Stops the description at [max] code points — the server's measure
/// ([reportDescriptionLength]) — so the field never holds a description the
/// server would refuse as too long. An edit that would pass it is kept only
/// as far as it fits.
class _CodePointLimit extends TextInputFormatter {
  _CodePointLimit(this.max);

  final int max;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.runes.length <= max) return newValue;
    final kept = String.fromCharCodes(newValue.text.runes.take(max));
    return TextEditingValue(
      text: kept,
      selection: TextSelection.collapsed(offset: kept.length),
    );
  }
}
