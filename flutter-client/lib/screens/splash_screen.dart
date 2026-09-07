import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

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

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      // The same ground the native launch window paints, so the hand-over
      // from the system splash to this frame is invisible.
      backgroundColor: scheme.surface,
      body: LayoutBuilder(
        builder: (context, box) {
          final size = (box.maxHeight * 0.46).clamp(120.0, 260.0);
          return Center(
            child: FadeTransition(
              opacity: CurvedAnimation(parent: _in, curve: Curves.easeOut),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.asset(
                    'assets/app_icon.svg',
                    width: size,
                    height: size,
                    semanticsLabel: 'King Teen Patti',
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'powered by sungamestudio.com',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                      letterSpacing: 0.6,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
