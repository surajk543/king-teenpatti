import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

import '../theme/app_theme.dart';
import 'fact_mark.dart' show tintAt;
import 'poker_chip.dart';

// The pot's coins on the Teen Patti felt (owner, 30 Sep 2026: "Use this
// animation on game Table for pot coins, change color of coin acc to blind,
// seen and variation table").
//
// The owner's `assets/animations/PotCoin.json`: fourteen gold coins falling
// one after another into three stacks — three, four and seven high — and a
// coin standing on edge on each, a rupee mark on its face; 1920 x 1080
// units, 24 fps, 120 frames, every coin at rest by frame 75 and the rest a
// hold. No 3D, no expressions, no images (the §12.3 traps). It plays ONCE
// as the table opens — the pile forms — and holds at the built frame; every
// time chips land on the pot the last eight coins and the three standing
// ones fall again ([PotCoins.landings], from [PotCoinsArt.topUpFrame]), in
// place of the pile's lift. Looped whole it would empty the pot every five
// seconds. It is drawn in the TABLE's colour — the seen table's gold, the
// blind table's sapphire, the variation table's violet ([AppTheme.paletteFor],
// the cloth's, the tag's and the lobby card's) — laid on the file's golds at
// their own luminances ([tintAt], the lobby marks' rule), the white rupee
// marks untouched.
//
// Drawn by a PAINTER, never the Lottie widget: the pot stands inside the
// felt's LayoutBuilder, and the Lottie widget sets its own state on every
// frame of the file, which lays the felt out and re-records it again on each
// (the fireworks' reasoning, [FireworksArt]). The file is parsed once
// ([PotCoinsArt.load], read as the table opens) and a [CustomPainter] on its
// own layer draws the frame the clock is at, repainting only when the file's
// own frame changes.

/// Where the file lays its pile out, in the file's own units — read off the
/// layers (`test/pot_coins_test.dart` holds them to the file) — and the
/// parsed file itself.
abstract final class PotCoinsArt {
  /// The asset.
  static const asset = 'assets/animations/PotCoin.json';

  /// The file's canvas.
  static const Size canvas = Size(1920, 1080);

  /// The file's frame rate and length.
  static const double frameRate = 24;
  static const int frames = 120;

  /// The pile at rest — the three stacks and the three standing coins —
  /// which is what fills the widget's box; the coins fall in from above it,
  /// past the box, and whatever clips the box clips them.
  static const Rect window = Rect.fromLTRB(315, 102, 1641, 960);

  /// The frame every coin is at rest from: the pile built, and held there.
  static const int builtFrame = 75;

  /// Where a top-up replays from: six coins already at rest, the other eight
  /// and the three standing ones falling in over the next forty frames.
  static const int topUpFrame = 35;

  /// The pile's width to its height.
  static double get aspect => window.width / window.height;

  /// The share of the file [frame] is.
  static double at(int frame) => frame / frames;

  static LottieComposition? _composition;
  static Future<LottieComposition?>? _loading;

  /// The parsed file, once [load] has finished; null before, or if it failed.
  static LottieComposition? get composition => _composition;

  /// Reads and parses the file the first time it is asked for, and hands
  /// every later caller the same result. A failure is remembered as nothing
  /// and the next call tries again: a pot without its coins is still a pot
  /// (the painted stack stands in).
  static Future<LottieComposition?> load() =>
      _loading ??= AssetLottie(asset).load().then<LottieComposition?>(
        (composition) => _composition = composition,
        onError: (Object _) {
          _loading = null;
          return null;
        },
      );
}

/// The delegates the file is drawn with in [tint] — made once per colour and
/// kept.
final _delegates = <Color, LottieDelegates>{};

LottieDelegates potCoinsDelegates(Color tint) =>
    _delegates.putIfAbsent(tint, () {
      final tinted = <Color, Color>{};
      Color at(Color c) => tinted.putIfAbsent(c, () => tintAt(c, tint));
      return LottieDelegates(
        values: [
          ValueDelegate.color(const ['**'], callback: (f) => at(f.startValue!)),
          ValueDelegate.strokeColor(const [
            '**',
          ], callback: (f) => at(f.startValue!)),
        ],
      );
    });

/// The pile of coins on the pot's plinth, [width] across (its height follows
/// the pile's own shape), in [tint], the table's colour.
///
/// [landings] counts the times chips have landed on the pot: each change
/// replays the last coins' fall. The parent clips: the coins fall in from
/// above the box.
class PotCoins extends StatefulWidget {
  const PotCoins({
    super.key,
    required this.width,
    required this.tint,
    this.landings = 0,
    this.boxKey = const ValueKey('pot-coins'),
  });

  final double width;
  final Color tint;
  final int landings;

  /// The key on the pile's box, by which the tests find it.
  final Key boxKey;

  /// The height a pile [width] across takes.
  static double heightFor(double width) => width / PotCoinsArt.aspect;

  @override
  State<PotCoins> createState() => _PotCoinsState();
}

class _PotCoinsState extends State<PotCoins>
    with SingleTickerProviderStateMixin {
  /// The file's clock: 0 its first frame, 1 its last. Made here, never
  /// lazily (CLAUDE.md §12.3).
  late final AnimationController _clock = AnimationController(vsync: this)
    ..addListener(_tick);

  /// The frame the painter draws: the clock rounded to the file's own frame
  /// rate, so the pile repaints 24 times a second, not on every tick.
  final ValueNotifier<double> _frame = ValueNotifier(0);

  LottieComposition? _composition;
  bool _failed = false;

  /// The file ready to draw, in the tint it was made for.
  LottieDrawable? _drawable;
  Color? _drawableTint;

  @override
  void initState() {
    super.initState();
    final loaded = PotCoinsArt.composition;
    if (loaded != null) {
      _composition = loaded;
      _start();
    } else {
      PotCoinsArt.load().then((composition) {
        if (!mounted) return;
        setState(() {
          if (composition == null) {
            _failed = true;
          } else {
            _composition = composition;
          }
        });
        if (composition != null) _start();
      });
    }
  }

  void _start() {
    _clock.duration = _composition!.duration;
    _play(from: 0);
  }

  /// From [from] to the built frame at the file's own speed, and hold.
  void _play({required double from}) {
    final to = PotCoinsArt.at(PotCoinsArt.builtFrame);
    _clock.value = from;
    _clock.animateTo(
      to,
      duration: _composition!.duration * (to - from),
      curve: Curves.linear,
    );
  }

  void _tick() {
    final composition = _composition;
    if (composition == null) return;
    final rounded = composition.roundProgress(
      _clock.value,
      frameRate: FrameRate.composition,
    );
    if (rounded != _frame.value) _frame.value = rounded;
  }

  @override
  void didUpdateWidget(PotCoins old) {
    super.didUpdateWidget(old);
    if (widget.landings != old.landings && _composition != null) {
      _play(from: PotCoinsArt.at(PotCoinsArt.topUpFrame));
    }
  }

  @override
  void dispose() {
    _clock.dispose();
    _frame.dispose();
    super.dispose();
  }

  LottieDrawable? _drawableFor(Color tint) {
    final composition = _composition;
    if (composition == null) return null;
    if (_drawable == null || _drawableTint != tint) {
      // The delegates set after the drawable is made: its constructor
      // resolves them against a layer it has not built yet (lottie 3.5.1).
      _drawable = LottieDrawable(composition, frameRate: FrameRate.composition)
        ..delegates = potCoinsDelegates(tint);
      _drawableTint = tint;
    }
    return _drawable;
  }

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    final height = PotCoins.heightFor(width);
    final Widget pile;
    if (_failed) {
      // The pile the plinth always had, in the table's colour.
      pile = Center(
        child: ChipStack(
          size: height * 0.6,
          colours: [
            tintAt(AppTheme.goldDeep, widget.tint),
            AppTheme.ink500,
            tintAt(AppTheme.gold, widget.tint),
            tintAt(AppTheme.goldBright, widget.tint),
          ],
        ),
      );
    } else {
      pile = CustomPaint(
        painter: PotCoinsPainter(
          drawable: _drawableFor(widget.tint),
          tint: widget.tint,
          frame: _frame,
        ),
      );
    }
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox(
          key: widget.boxKey,
          width: width,
          height: height,
          child: pile,
        ),
      ),
    );
  }
}

/// Draws the file's [frame] with the pile's window filling the box: the
/// canvas scaled to the window and set so the window's corner is the box's,
/// the coins falling in above it. Repaints when [frame] moves.
class PotCoinsPainter extends CustomPainter {
  PotCoinsPainter({
    required this.drawable,
    required this.tint,
    required this.frame,
  }) : super(repaint: frame);

  /// Null while the file is still being read: nothing is drawn.
  final LottieDrawable? drawable;

  /// The colour [drawable] was made for.
  final Color tint;

  /// The file's frame, 0 to 1.
  final ValueListenable<double> frame;

  @override
  void paint(Canvas canvas, Size size) {
    final drawable = this.drawable;
    if (drawable == null) return;
    final window = PotCoinsArt.window;
    final scale = size.width / window.width;
    final canvasSize = PotCoinsArt.canvas * scale;
    drawable.setProgress(frame.value);
    canvas.save();
    canvas.translate(-window.left * scale, -window.top * scale);
    drawable.draw(
      canvas,
      Offset.zero & canvasSize,
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(PotCoinsPainter old) =>
      old.drawable != drawable || old.tint != tint || old.frame != frame;
}
