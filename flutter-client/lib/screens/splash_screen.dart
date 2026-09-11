import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';
import '../widgets/premium_surface.dart';
import '../widgets/table_ground.dart';

/// The opening frame: the crown-and-cards mark over the studio line, shown
/// while the app finds out whether it has a session and a table to return to.
///
/// The same artwork is the launcher icon and the Android 12 splash, so the
/// app opens on one image from tap to lobby rather than three.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..forward();

  late final CurvedAnimation _fade = CurvedAnimation(
    parent: _in,
    curve: Motion.standard,
  );

  @override
  void dispose() {
    _fade.dispose();
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final glass = GlassColors.of(context);

    return Scaffold(
      // The room the game is played in, lamp and all, from the very first
      // frame: the palette is stated before anything else is.
      body: TableGround(
        lamp: const Alignment(0, -0.12),
        child: LayoutBuilder(
          builder: (context, box) {
            // Height-driven, because height is the scarce axis in landscape.
            // 165.6dp at h=360, 189.1 at h=411, 260 (the ceiling) at h=800.
            final size = (box.maxHeight * 0.46).clamp(120.0, 260.0);

            return Center(
              child: FadeTransition(
                opacity: _fade,
                child: ScaleTransition(
                  // Barely there, and outwards: the mark settles into the room
                  // rather than being dropped onto it.
                  scale: Tween<double>(begin: 0.94, end: 1).animate(_fade),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: size,
                        height: size,
                        // One slow champagne pass over the mark. The splash is
                        // held for GameState.minSplash, which is a quarter of
                        // the sweep — so what is seen is a single light
                        // crossing it, not a loop.
                        child: Glint(
                          child: SvgPicture.asset(
                            'assets/app_icon.svg',
                            width: size,
                            height: size,
                            semanticsLabel: 'King Teen Patti',
                          ),
                        ),
                      ),
                      const SizedBox(height: Space.xl),
                      Text(
                        // A fixed Latin string the code owns, so it can carry
                        // tracking; nothing translated is treated this way.
                        'powered by sungamestudio.com',
                        style: AppTheme.smallCaps(
                          theme.textTheme.labelMedium ?? const TextStyle(),
                          tracking: 1.8,
                          colour: glass.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
