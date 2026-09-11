/// The glass vocabulary the screens are built from: a card, a button, a text
/// field, a segmented theme switcher, and the two small behaviours every
/// tappable thing shares — a light haptic and a press-down scale.
///
/// All of it is presentation. Each widget takes the caller's own callback,
/// controller or value and hands it straight through; nothing here decides
/// anything about the game. That is the contract that let the screens be
/// re-skinned without touching what they do.
library;

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../settings/feedback_settings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import 'premium_surface.dart';

// ---------------------------------------------------------------- feel

/// A light tap through the platform's haptic channel, gated on the player's
/// Vibration switch. Safe anywhere: a context with no [FeedbackSettings]
/// above it (a test, a tool) simply taps.
void tapHaptic(BuildContext context) {
  var on = true;
  try {
    on = Provider.of<FeedbackSettings>(context, listen: false).vibrate;
  } on ProviderNotFoundException {
    on = true;
  }
  if (on) HapticFeedback.lightImpact();
}

/// Whether Material's own click should play on a tap — the player's Sound
/// switch, or on when there is no switch in scope.
///
/// A `select`, not a `watch`: this is called from the build of every tappable
/// thing in the app, and a `watch` would rebuild all of them whenever the
/// Vibration switch moved too.
bool soundOn(BuildContext context) {
  try {
    return context.select<FeedbackSettings, bool>((f) => f.sound);
  } on ProviderNotFoundException {
    return true;
  }
}

/// Scales its child down to [scale] while a finger is on it, springs it back
/// on release, and gives the light haptic at the moment of the tap.
///
/// A `Listener`, not a `GestureDetector`: it watches the raw pointer and never
/// enters the gesture arena, so the button underneath keeps every tap, long
/// press and ink response it had. Nothing about what the child does changes;
/// only how it feels.
///
/// Staying out of the arena has one cost: nobody tells this widget when a
/// scroll has taken the pointer, so a press that turns into a drag would sit
/// shrunk for the whole drag. It therefore watches the pointer itself and
/// lets go once it has travelled past [kTouchSlop] — the same distance the
/// tap recogniser gives up at. That is also what makes the haptic honest: it
/// fires on release, and only for a press that stayed a press, so starting a
/// scroll on a row never ticks.
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.enabled = true,
    this.scale = 0.97,
    this.haptic = true,
  });

  final Widget child;
  final bool enabled;
  final double scale;

  /// Pass false where the child's own callback already taps — [GlassButton]
  /// and [GlassCard] do it there, so that a refused or disabled action still
  /// scales but does not buzz.
  final bool haptic;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;
  Offset? _origin;

  void _set(bool down) {
    if (_down == down) return;
    setState(() => _down = down);
  }

  void _release({required bool tapped}) {
    final was = _down;
    _origin = null;
    _set(false);
    if (was && tapped && widget.enabled && widget.haptic) tapHaptic(context);
  }

  @override
  Widget build(BuildContext context) {
    final pressed = _down && widget.enabled;

    return Listener(
      onPointerDown: (e) {
        _origin = e.position;
        _set(true);
      },
      onPointerMove: (e) {
        final origin = _origin;
        if (origin == null) return;
        // Far enough to be a scroll or a drag: the tap is gone, so let go
        // without the haptic rather than wait for an up that may never come
        // over this widget.
        if ((e.position - origin).distance > kTouchSlop) {
          _origin = null;
          _set(false);
        }
      },
      onPointerUp: (_) => _release(tapped: true),
      onPointerCancel: (_) => _release(tapped: false),
      child: AnimatedScale(
        scale: pressed ? widget.scale : 1.0,
        // Down is instant; up settles with a little overshoot, which is what
        // makes a key feel sprung rather than damped.
        duration: pressed ? Motion.instant : Motion.base,
        curve: pressed ? Curves.easeOut : Motion.settle,
        child: widget.child,
      ),
    );
  }
}

// ---------------------------------------------------------------- card

/// A glass pane with the spec's padding, and optionally a tap.
///
/// Thin on purpose: [PremiumGlassPanel] is the one glass primitive and knows
/// about the blur budget; this only sets the defaults a card wants and adds
/// the tap feel. A card that does something takes an [onTap] and gets the
/// haptic, the ink and the press-scale for free.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.xl),
    this.radius = Radii.lg,
    this.mode = GlassMode.auto,
    this.priority = 0,
    this.live = false,
    this.tint,
    this.elevated = true,
    this.onTap,
    this.clipBehavior = Clip.antiAlias,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final GlassMode mode;
  final int priority;
  final bool live;
  final Color? tint;
  final bool elevated;
  final VoidCallback? onTap;
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final tap = onTap;
    final body = tap == null
        ? Padding(padding: padding, child: child)
        : Material(
            type: MaterialType.transparency,
            child: InkWell(
              enableFeedback: soundOn(context),
              borderRadius: BorderRadius.circular(radius),
              onTap: () {
                tapHaptic(context);
                tap();
              },
              child: Padding(padding: padding, child: child),
            ),
          );

    final panel = PremiumGlassPanel(
      mode: mode,
      priority: priority,
      radius: radius,
      live: live,
      tint: tint,
      elevated: elevated,
      clipBehavior: clipBehavior,
      padding: EdgeInsets.zero,
      child: body,
    );

    // haptic: false — the InkWell above taps when the card is actually
    // activated, so a press that slides off does not buzz.
    return tap == null ? panel : PressScale(haptic: false, child: panel);
  }
}

// ---------------------------------------------------------------- button

/// The four weights a key comes in.
///
/// [primary] is the one filled key in a group; [glass] is a pane of the
/// surface it sits on; [outline] is the quiet alternative beside a primary;
/// [text] is the flat half of a dialog's pair.
enum GlassButtonStyle { primary, glass, outline, text }

/// A key: Material's own button underneath — so `enableFeedback`, focus, ink
/// and the disabled state all keep working — with the haptic and the
/// press-scale over it.
///
/// [onPressed] is the caller's callback, called exactly as before; null still
/// disables the key. Pass a [label] or a [child], and an [icon] to put one
/// before it.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.onPressed,
    this.label,
    this.child,
    this.icon,
    this.style = GlassButtonStyle.glass,
    this.minimumSize,
    this.expand = false,
    this.tone,
    this.buttonStyle,
    this.pressScale = true,
  }) : assert(
         label != null || child != null,
         'a GlassButton needs a label or a child',
       );

  final VoidCallback? onPressed;
  final String? label;
  final Widget? child;
  final Widget? icon;
  final GlassButtonStyle style;

  /// A floor for the key's size; a row of keys passes the same one.
  final Size? minimumSize;

  /// Stretches the key to its parent's width.
  final bool expand;

  /// A foreground colour: a danger key passes the scheme's error.
  final Color? tone;

  /// Anything else, merged over the style this widget builds.
  final ButtonStyle? buttonStyle;

  /// Pass false where the surface around the key already presses in — a key
  /// inside a card that scales on tap would otherwise shrink twice.
  final bool pressScale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    final enabled = onPressed != null;

    void press() {
      tapHaptic(context);
      onPressed!();
    }

    final content =
        child ?? Text(label!, maxLines: 1, overflow: TextOverflow.ellipsis);

    final ink = tone ?? theme.colorScheme.onSurface;
    final variant = switch (style) {
      GlassButtonStyle.glass => ButtonStyle(
        // The well fill, not the pane fill: a key usually sits ON a panel,
        // and a wash of white over a white panel has no body at all.
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? glass.wellFill.withValues(alpha: dark ? 0.04 : 0.50)
              : glass.wellFill,
        ),
        side: WidgetStatePropertyAll(
          BorderSide(
            color: dark ? glass.borderTop : glass.borderBottom,
            width: Dim.hairline,
          ),
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.disabled)
              ? ink.withValues(alpha: AppTheme.inkLow)
              : ink,
        ),
      ),
      _ => ButtonStyle(
        foregroundColor: tone == null ? null : WidgetStatePropertyAll(tone),
      ),
    };
    final base = ButtonStyle(
      minimumSize: minimumSize == null
          ? null
          : WidgetStatePropertyAll(minimumSize),
    );
    final merged = (buttonStyle ?? const ButtonStyle())
        .merge(variant)
        .merge(base);
    final onTap = enabled ? press : null;

    Widget button = switch (style) {
      GlassButtonStyle.primary =>
        icon == null
            ? FilledButton(onPressed: onTap, style: merged, child: content)
            : FilledButton.icon(
                onPressed: onTap,
                style: merged,
                icon: icon!,
                label: content,
              ),
      GlassButtonStyle.glass || GlassButtonStyle.outline =>
        icon == null
            ? OutlinedButton(onPressed: onTap, style: merged, child: content)
            : OutlinedButton.icon(
                onPressed: onTap,
                style: merged,
                icon: icon!,
                label: content,
              ),
      GlassButtonStyle.text =>
        icon == null
            ? TextButton(onPressed: onTap, style: merged, child: content)
            : TextButton.icon(
                onPressed: onTap,
                style: merged,
                icon: icon!,
                label: content,
              ),
    };
    if (expand) button = SizedBox(width: double.infinity, child: button);
    if (!pressScale) return button;

    // haptic: false — `press` above taps when the button actually fires, so a
    // disabled key and a press that slides off stay silent.
    return PressScale(enabled: enabled, haptic: false, child: button);
  }
}

// ---------------------------------------------------------------- field

/// A text field on glass. Every input property is the caller's and is passed
/// through untouched; this only supplies the pane it sits in.
class GlassTextField extends StatelessWidget {
  const GlassTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.onEditingComplete,
    this.labelText,
    this.hintText,
    this.prefixIcon,
    this.suffixIcon,
    this.maxLength,
    this.maxLines = 1,
    this.minLines,
    this.textInputAction,
    this.keyboardType,
    this.textCapitalization = TextCapitalization.none,
    this.autofocus = false,
    this.enabled,
    this.counterText = '',
    this.decoration,
    this.style,
    this.inputFormatters,
    this.textAlign = TextAlign.start,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.obscureText = false,
    this.readOnly = false,
    this.onTap,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onEditingComplete;
  final String? labelText;
  final String? hintText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final int? maxLength;
  final int? maxLines;
  final int? minLines;
  final TextInputAction? textInputAction;
  final TextInputType? keyboardType;
  final TextCapitalization textCapitalization;
  final bool autofocus;
  final bool? enabled;

  /// Empty by default: the counter under a field is the one thing a dense
  /// landscape form cannot afford. Pass null to get Material's.
  final String? counterText;

  /// A decoration of the caller's own; the label, hint, icons and counter
  /// above are laid over it.
  final InputDecoration? decoration;
  final TextStyle? style;
  final List<TextInputFormatter>? inputFormatters;
  final TextAlign textAlign;
  final bool autocorrect;
  final bool enableSuggestions;
  final bool obscureText;
  final bool readOnly;
  final GestureTapCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      onEditingComplete: onEditingComplete,
      onTap: onTap,
      maxLength: maxLength,
      maxLines: maxLines,
      minLines: minLines,
      textInputAction: textInputAction,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      autofocus: autofocus,
      enabled: enabled,
      style: style,
      inputFormatters: inputFormatters,
      textAlign: textAlign,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      obscureText: obscureText,
      readOnly: readOnly,
      cursorColor: theme.colorScheme.primary,
      decoration: (decoration ?? const InputDecoration()).copyWith(
        labelText: labelText,
        hintText: hintText,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        counterText: counterText,
      ),
    );
  }
}

// ---------------------------------------------------------------- switcher

/// System · Dark · Light, as one segmented glass control.
///
/// The thumb is on a real spring — a [SpringSimulation] driven by the mode
/// the state reports — so a change made anywhere (this control, the old
/// toggle, another drawer) is followed here with the same overshoot and
/// settle. Tapping a segment gives the light haptic and calls
/// `GameState.setThemeMode`, which is the only thing it does.
class GlassThemeSwitcher extends StatefulWidget {
  const GlassThemeSwitcher({super.key, this.compact = false, this.height});

  /// Icons only, whatever the width allows. A narrow slot drops the words on
  /// its own, so this is for a caller that wants them gone regardless.
  final bool compact;

  /// Defaults to [Dim.minTouch] plus the track's own padding, so each of the
  /// three segments is a legal touch target. A caller that passes less gets
  /// what it asked for.
  final double? height;

  /// The inset between the track and its segments, top and bottom.
  static const double _pad = 3;

  /// What the control needs to show three words at the current text scale.
  /// Below this it shows icons alone rather than three ellipses.
  static const double _wordsNeed = 210;

  @override
  State<GlassThemeSwitcher> createState() => _GlassThemeSwitcherState();
}

class _GlassThemeSwitcherState extends State<GlassThemeSwitcher>
    with SingleTickerProviderStateMixin {
  static const _order = [ThemeMode.system, ThemeMode.dark, ThemeMode.light];

  /// Snappy, with one visible overshoot — the hand of a good switch.
  static const _spring = SpringDescription(
    mass: 1,
    stiffness: 420,
    damping: 26,
  );

  late final AnimationController _c = AnimationController.unbounded(
    vsync: this,
  );
  int? _shown;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _settle(int index) {
    if (_shown == index) return;
    _shown = index;
    _c.animateWith(
      SpringSimulation(_spring, _c.value, index.toDouble(), _c.velocity),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mode = context.select<GameState, ThemeMode>((s) => s.themeMode);
    // Selected, not read: the language picker sits in the same drawer as this
    // control, so a change to it has to relabel the three segments there and
    // then — and every placement is a `const` widget, which a parent's own
    // rebuild would never reach.
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    final t = Strings(lang);

    final index = _order.indexOf(mode);
    if (_shown == null) {
      // First build: the thumb starts where the setting is, no travel.
      _c.value = index.toDouble();
      _shown = index;
    } else if (_shown != index) {
      // A change: spring there once this frame is out of the way.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _settle(index);
      });
    }

    final labels = <ThemeMode, (IconData, String)>{
      ThemeMode.system: (Icons.brightness_auto_rounded, t.themeSystem),
      ThemeMode.dark: (Icons.dark_mode_rounded, t.themeDark),
      ThemeMode.light: (Icons.light_mode_rounded, t.themeLight),
    };

    // Derived from the touch target it has to contain, like every other
    // height in the app: the segments are what the finger lands on, so the
    // track is minTouch plus its own padding rather than a round number that
    // leaves them short.
    final height = widget.height ?? Dim.minTouch + 2 * GlassThemeSwitcher._pad;

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          // Words only where three of them fit. The drawer is 260dp at 640
          // and the words are translated into five languages at up to 1.25
          // text scale; three ellipses ("Sys…", "Dar…", "Lig…") say less than
          // three icons do.
          final scale = MediaQuery.textScalerOf(context).scale(1);
          final words =
              !widget.compact &&
              box.maxWidth >= GlassThemeSwitcher._wordsNeed * scale;
          return _track(context, mode: mode, labels: labels, words: words);
        },
      ),
    );
  }

  Widget _track(
    BuildContext context, {
    required ThemeMode mode,
    required Map<ThemeMode, (IconData, String)> labels,
    required bool words,
  }) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final b = theme.brightness;

    return PremiumGlassPanel(
      mode: GlassMode.tinted,
      radius: Radii.pill,
      padding: const EdgeInsets.all(GlassThemeSwitcher._pad),
      elevated: false,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (context, _) => Align(
              // Three segments, so the thumb's centre runs -1 .. 0 .. 1.
              alignment: Alignment(-1 + _c.value.clamp(0.0, 2.0), 0),
              child: FractionallySizedBox(
                widthFactor: 1 / 3,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    color: glass.thumb,
                    border: Border.all(
                      color: AppTheme.hairlineColour(b, live: true),
                      width: Dim.hairline,
                    ),
                    boxShadow: AppTheme.controlShadow(b, elevation: 2),
                  ),
                ),
              ),
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: Row(
              children: [
                for (final m in _order)
                  Expanded(
                    child: _Segment(
                      icon: labels[m]!.$1,
                      label: labels[m]!.$2,
                      selected: m == mode,
                      compact: !words,
                      onTap: () {
                        tapHaptic(context);
                        context.read<GameState>().setThemeMode(m);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.icon,
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);
    final colour = selected ? glass.textDisplay : glass.textMuted;

    Widget body = InkWell(
      enableFeedback: soundOn(context),
      borderRadius: BorderRadius.circular(Radii.pill),
      onTap: onTap,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(
              duration: Motion.base,
              child: Icon(
                icon,
                key: ValueKey(selected),
                size: 16,
                color: colour,
              ),
            ),
            if (!compact) ...[
              const SizedBox(width: Space.xs),
              Flexible(
                child: AnimatedDefaultTextStyle(
                  duration: Motion.base,
                  style: AppTheme.label(
                    theme.textTheme.labelMedium ?? const TextStyle(),
                    colour: colour,
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    if (compact) body = Tooltip(message: label, child: body);

    return Semantics(
      button: true,
      selected: selected,
      label: compact ? label : null,
      child: body,
    );
  }
}
