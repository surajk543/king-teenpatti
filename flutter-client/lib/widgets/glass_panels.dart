/// The panels the interface puts *on top of* the game.
///
/// The game itself — cloth, cards, chips, players, keys — is solid. Glass is
/// for what covers it: a drawer, a dialog, a small floating pill, a notice.
/// Each of these takes its padding as an argument, because the one thing that
/// broke every panel in the draft was a shared default padding that no
/// container could afford.
///
/// The two full-screen panels — the drawer and the dialog — default to
/// [GlassMode.auto], which blurs only if the [GlassBudget] has a blur free;
/// install one in `MaterialApp.builder`, since dialogs, sheets and snack bars
/// are built from the root Navigator and root ScaffoldMessenger, both of which
/// sit above anything passed as `home`. The small ones are tinted outright.
library;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'premium_surface.dart';
import 'package:provider/provider.dart';

import '../settings/feedback_settings.dart';

/// A drawer that floats over the screen instead of butting against its edge.
///
/// A drawer is slid in by a `Transform`, and a `BackdropFilter` inside a moving
/// transform is the worst case there is — the sampled region changes every
/// frame, so nothing is reusable. It is affordable here only because a drawer
/// is transient and takes the single blur lease for its lifetime, which demotes
/// anything else that wanted one. Pass [GlassMode.tinted] on a screen where the
/// backdrop is busy and the drawer covers it anyway.
class GlassDrawerPanel extends StatelessWidget {
  const GlassDrawerPanel({
    super.key,
    required this.child,
    required this.padding,
    this.width,
    this.margin = const EdgeInsets.all(Space.md),
    this.mode = GlassMode.auto,
    this.sigma = 22,
    this.priority = 10,
  });

  final Widget child;

  /// The panel's inset. A drawer whose child scrolls should pass
  /// [EdgeInsets.zero] and pad its own rows, so the scrollbar reaches the edge.
  final EdgeInsetsGeometry padding;

  /// Defaults to [Dim.drawerW] of the screen: 260dp at 640 wide, 380 at 1280.
  final double? width;

  /// The gap between the panel and the screen edge. Explicit, and small.
  final EdgeInsetsGeometry margin;

  final GlassMode mode;
  final double sigma;

  /// Above a capsule, below a dialog: a dialog opened over a drawer takes the
  /// blur and the drawer settles for tint.
  final int priority;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        width: width ?? Dim.drawerW(w),
        child: SafeArea(
          child: Padding(
            padding: margin,
            // Transparency rather than a colour: the panel paints its own body,
            // and this is only here so ink responses inside it have a surface.
            child: Material(
              type: MaterialType.transparency,
              child: PremiumGlassPanel(
                mode: mode,
                sigma: sigma,
                priority: priority,
                radius: Radii.lg,
                padding: padding,
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A dialog on the same glass as everything else.
///
/// Its body scrolls. `AlertDialog` scrolls its content and a bare `Column` does
/// not, and the longest string in the app is the mid-hand leave warning
/// (requirement 25) — three lines of Bengali at a large text scale is exactly
/// the dialog that must not overflow.
class GlassDialog extends StatelessWidget {
  const GlassDialog({
    super.key,
    required this.content,
    required this.padding,
    this.title,
    this.actions = const [],
    this.mode = GlassMode.auto,
    this.sigma = 22,
    this.priority = 20,
    this.maxWidth,
  });

  /// The dialog's body. It is made scrollable here; do not wrap it again.
  final Widget content;

  final EdgeInsetsGeometry padding;

  /// Already styled by the caller, so a translated title keeps its own case.
  final Widget? title;

  /// Laid out end-aligned, in the order given.
  final List<Widget> actions;

  final GlassMode mode;
  final double sigma;
  final int priority;

  /// Defaults to [Dim.dialogW]: 396.8dp at 640 wide, 520 above 840.
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final theme = Theme.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(Space.lg),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth ?? Dim.dialogW(size.width),
          maxHeight: Dim.dialogMaxH(size.height),
        ),
        child: PremiumGlassPanel(
          mode: mode,
          sigma: sigma,
          priority: priority,
          radius: Radii.lg,
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null) ...[
                DefaultTextStyle.merge(
                  style: theme.textTheme.titleMedium,
                  child: title!,
                ),
                const SizedBox(height: Space.md),
              ],
              // Height is the scarce axis in landscape, so the body gives way
              // before the title or the actions do.
              Flexible(
                child: SingleChildScrollView(
                  primary: false,
                  child: content,
                ),
              ),
              if (actions.isNotEmpty) ...[
                const SizedBox(height: Space.lg),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Space.md,
                  runSpacing: Space.sm,
                  children: actions,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small floating pill: a corner chip, a status plate, a count.
///
/// Tinted by default. There are several of these on screen at once and each one
/// sits over something that moves, which is the case a blur is worst at and
/// buys least from.
class GlassCapsule extends StatelessWidget {
  const GlassCapsule({
    super.key,
    required this.child,
    required this.padding,
    this.live = false,
    this.mode = GlassMode.tinted,
    this.radius = Radii.pill,
    this.tint,
    this.elevated = true,
    this.onTap,
    this.minHeight,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Wears the brighter hairline: claimable, focused, or on the clock.
  final bool live;

  final GlassMode mode;
  final double radius;
  final Color? tint;
  final bool elevated;
  final VoidCallback? onTap;

  /// A tappable capsule is never smaller than [Dim.minTouch]; a decorative one
  /// sizes to its content.
  final double? minHeight;

  @override
  Widget build(BuildContext context) {
    // The panel is given no padding of its own so the ink response covers the
    // whole capsule rather than just the text inside it.
    Widget body = Padding(padding: padding, child: child);

    if (onTap != null) {
      body = Material(
        type: MaterialType.transparency,
        child: InkWell(
      // Material's own click, gated on the player's Sound switch —
      // otherwise a silenced game would still tick on every tap.
      enableFeedback: context.select<FeedbackSettings, bool>((f) => f.sound),
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: body,
        ),
      );
    }

    return ConstrainedBox(
      constraints: BoxConstraints(
        minHeight: minHeight ?? (onTap != null ? Dim.minTouch : 0),
      ),
      child: PremiumGlassPanel(
        mode: mode,
        radius: radius,
        live: live,
        tint: tint,
        elevated: elevated,
        padding: EdgeInsets.zero,
        child: body,
      ),
    );
  }
}

/// What a notice means. It sets the icon and the hairline, never the copy.
enum NoticeTone { neutral, good, bad }

/// The shell a server notice is shown in.
///
/// It carries no strings of its own: the message is whatever the server last
/// refused or granted, already translated upstream, and it renders in its
/// natural case — a refusal in Gujarati must not be tracked and uppercased.
class NoticeToast extends StatelessWidget {
  const NoticeToast({
    super.key,
    required this.message,
    this.tone = NoticeTone.neutral,
    this.icon,
  });

  final String message;
  final NoticeTone tone;

  /// Overrides the tone's own mark.
  final IconData? icon;

  /// A snack bar wearing this shell, sized to the screen rather than to a fixed
  /// 420dp that does not fit a 640dp phone.
  static SnackBar snackBar(
    BuildContext context, {
    required String message,
    NoticeTone tone = NoticeTone.neutral,
    IconData? icon,
  }) =>
      SnackBar(
        content: NoticeToast(message: message, tone: tone, icon: icon),
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        behavior: SnackBarBehavior.floating,
        width: Dim.toastW(MediaQuery.sizeOf(context).width),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (Color mark, IconData glyph) = switch (tone) {
      NoticeTone.good => (scheme.primary, Icons.check_circle_rounded),
      NoticeTone.bad => (scheme.error, Icons.error_rounded),
      NoticeTone.neutral => (
          AppTheme.goldBright,
          Icons.info_rounded,
        ),
    };

    return PremiumGlassPanel(
      mode: GlassMode.tinted,
      radius: Radii.md,
      live: tone != NoticeTone.neutral,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon ?? glyph, size: 18, color: mark),
          const SizedBox(width: Space.sm),
          Flexible(
            child: Text(
              message,
              style: AppTheme.label(
                theme.textTheme.bodyMedium ?? const TextStyle(),
                weight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
