import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/game_state.dart';
import '../theme/app_theme.dart';

// The game's loader (owner, 28 Sep 2026: "change the loader of game … use this
// lottie json … whereever loader you are showing show this loader, and below
// text also please wait..."): the owner's GameLoader.json — a teal arc chasing
// a dark one round a ring, 2.2 s a loop — in place of every spinner the app
// drew. Where a loader stands for content still coming (a table, a page, a
// list, a veil) it is [GameLoader]: the ring over "Please wait...", and under
// that what is being waited for where the screen said so before. Inside a key
// or over a tile being bought, where a line of words cannot fit, it is the
// ring alone ([GameLoaderRing]) in the spinner's own box — the key's own words
// say what it is doing.

/// The owner's file, as uploaded; never edited (its dark arc is recoloured at
/// run time, [GameLoaderRing]).
const gameLoaderAsset = 'assets/animations/GameLoader.json';

/// The ring's outer diameter as a share of the file's 540-unit canvas: an
/// ellipse 176 across under a 20-unit stroke, centred on the canvas.
const double gameLoaderRingShare = (176 + 20) / 540;

/// The file's arc colours: its dark arc is black — which the dark theme's
/// ground all but swallows — so it is drawn in [ink]; the teal is the file's.
Color gameLoaderArc(Color file, Color ink) =>
    file.r < 0.1 && file.g < 0.1 && file.b < 0.1 ? ink : file;

/// The loader's ring alone, [size] across: for a key or a tile, where the old
/// spinner stood. Its dark arc is drawn in [ink] (the theme's ink by default).
class GameLoaderRing extends StatelessWidget {
  const GameLoaderRing({super.key, this.size = 40, this.ink});

  /// The ring's outer diameter; the canvas around it is drawn past the box,
  /// and is transparent.
  final double size;

  /// What the file's black arc is drawn in.
  final Color? ink;

  /// One set of delegates per ink, so a rebuild — the lobby's one-second
  /// tick — hands the player the same object and nothing is resolved again.
  static final Map<Color, LottieDelegates> _delegates = {};

  static LottieDelegates _for(Color ink) => _delegates.putIfAbsent(
    ink,
    () => LottieDelegates(
      values: [
        ValueDelegate.strokeColor(
          const ['**'],
          callback: (info) =>
              gameLoaderArc(info.startValue ?? const Color(0xFF000000), ink),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colour = ink ?? Theme.of(context).colorScheme.onSurface;
    final canvas = size / gameLoaderRingShare;
    return ExcludeSemantics(
      child: SizedBox.square(
        key: const ValueKey('game-loader-ring'),
        dimension: size,
        child: OverflowBox(
          minWidth: canvas,
          maxWidth: canvas,
          minHeight: canvas,
          maxHeight: canvas,
          child: Lottie.asset(
            gameLoaderAsset,
            width: canvas,
            height: canvas,
            frameRate: FrameRate.max,
            delegates: _for(colour),
          ),
        ),
      ),
    );
  }
}

/// The loader where content is still coming: the ring over "Please wait..."
/// in the player's language and, where the screen says what it is waiting
/// for, [detail] under that, quieter. Read aloud as its words.
class GameLoader extends StatelessWidget {
  const GameLoader({
    super.key,
    this.size = 40,
    this.detail,
    this.ink,
    this.textColour,
  });

  /// The ring's diameter.
  final double size;

  /// What is being waited for ("Reconnecting…"), under "Please wait...".
  final String? detail;

  /// The ring's dark arc; the theme's ink by default.
  final Color? ink;

  /// The words' colour, for a plate that keeps one ink in both themes; the
  /// theme's ink by default.
  final Color? textColour;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = Strings(_langOf(context));
    final words = textColour ?? theme.colorScheme.onSurface;
    return Semantics(
      liveRegion: true,
      label: [t.pleaseWait, ?detail].join(' '),
      child: ExcludeSemantics(
        child: Column(
          key: const ValueKey('game-loader'),
          mainAxisSize: MainAxisSize.min,
          children: [
            GameLoaderRing(size: size, ink: ink),
            const SizedBox(height: Space.md),
            Text(
              t.pleaseWait,
              textAlign: TextAlign.center,
              style: AppTheme.label(
                theme.textTheme.titleSmall ?? const TextStyle(),
                colour: words.withValues(alpha: AppTheme.inkHigh),
              ),
            ),
            if (detail case final line?) ...[
              const SizedBox(height: Space.xs),
              Text(
                line,
                textAlign: TextAlign.center,
                style: AppTheme.label(
                  theme.textTheme.bodySmall ?? const TextStyle(),
                  colour: words.withValues(alpha: AppTheme.inkMed),
                  weight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The player's language — or English where no game is in scope (a
  /// widget test that mounts a piece of a screen on its own).
  static AppLang _langOf(BuildContext context) {
    try {
      return context.select<GameState, AppLang>((s) => s.lang);
    } on ProviderNotFoundException {
      return AppLang.english;
    }
  }
}
