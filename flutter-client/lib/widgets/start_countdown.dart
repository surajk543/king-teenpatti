import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../state/game_state.dart';
import '../state/start_countdown.dart';
import '../theme/app_theme.dart';
import '../theme/theme_colors.dart';

/// The owner's countdown (`assets/animations/Count Down.json`, 29 Sep 2026),
/// cut to its 3-2-1 and parsed once for the app.
///
/// The file counts down from 9 to 0 and on to GO over 14.9 s at 29.97 frames
/// a second (612x551, 285 shape layers, no expressions, no 3D). Each number
/// is a white digit on a disc of the same deep blue as a burst of stars and
/// squares round it, one number a second: "3" at frame 180, "2" at 210, "1"
/// at 240, "0" at 269. The table plays the three the owner asked for and
/// nothing else, so the composition the phone parses is the file's own
/// layers for 3, 2 and 1 — every layer whose in-point is from "3"'s to
/// "0"'s — over frames 180 to 270 ([threeTwoOne]). Played straight from
/// frame 180 of the whole file, the stars of "4" were still flying round the
/// first disc; cut, the countdown begins on a clean disc, and the phone
/// parses 130 KB and 78 layers instead of 480 KB and 285. The file itself is
/// never edited.
abstract final class StartCountdownArt {
  static const asset = 'assets/animations/Count Down.json';

  /// The disc's middle in the composition's own units, and its diameter at
  /// the top of its pulse (it breathes from 184 to 231 as each number lands).
  /// Read off the rendered frames: the disc is the thing the countdown is
  /// sized and placed by; the stars round it fly out over 2.4 discs.
  static const Offset discCentre = Offset(305.5, 268);
  static const double discPeak = 231;

  static LottieComposition? _composition;
  static Future<LottieComposition?>? _loading;

  /// The parsed 3-2-1, once [load] has finished; null before, or when it
  /// failed (the table then draws the numbers on a plain disc).
  static LottieComposition? get composition => _composition;

  /// Reads, cuts and parses the file the first time it is asked for, and
  /// hands every later caller the same result. The cut runs on another
  /// isolate: it decodes 480 KB of JSON, which the table opening should not
  /// wait for. A failure is remembered as nothing, and the next call tries
  /// again.
  static Future<LottieComposition?> load() => _loading ??= _load();

  static Future<LottieComposition?> _load() async {
    try {
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final cut = await compute(threeTwoOne, bytes);
      return _composition = LottieComposition.parseJsonBytes(cut);
    } catch (_) {
      _loading = null;
      return null;
    }
  }

  /// For the tests: a composition parsed where async is real (`setUpAll`),
  /// kept as a value, so no test awaits a future another test's zone made.
  @visibleForTesting
  static set debugComposition(LottieComposition? composition) {
    _composition = composition;
    _loading = composition == null ? null : Future.value(composition);
  }

  /// The owner's file cut to its 3-2-1: the layers whose in-point is from the
  /// layer named "3"'s to the layer named "0"'s, over a composition that runs
  /// from "3"'s in-point for three numbers' time (frames 180 to 270). The
  /// numbers are found by name rather than by frame, so a re-export that
  /// moves them keeps working; a file without them is refused (a
  /// [FormatException]) rather than played as some other countdown.
  static Uint8List threeTwoOne(Uint8List bytes) {
    final json = jsonDecode(utf8.decode(bytes));
    if (json is! Map<String, dynamic> || json['layers'] is! List) {
      throw const FormatException('not a Lottie composition');
    }
    final layers = [
      for (final layer in json['layers'] as List)
        if (layer is Map<String, dynamic>) layer,
    ];
    num? inPoint(String name) {
      for (final layer in layers) {
        if (layer['nm'] == name && layer['ip'] is num) {
          return layer['ip'] as num;
        }
      }
      return null;
    }

    final three = inPoint('3'), two = inPoint('2'), one = inPoint('1');
    final zero = inPoint('0');
    if (three == null || two == null || one == null || zero == null) {
      throw const FormatException('no 3-2-1 in this countdown');
    }
    json['layers'] = [
      for (final layer in layers)
        if (layer['ip'] is num &&
            (layer['ip'] as num) >= three &&
            (layer['ip'] as num) < zero)
          layer,
    ];
    json['ip'] = three;
    json['op'] = one + (one - two);
    return Uint8List.fromList(utf8.encode(jsonEncode(json)));
  }

  /// The progress at which each number stands at its fullest (its digit at
  /// full strength and the disc at the top of its pulse): about half a second
  /// into its second. What a phone set to reduce motion shows, still.
  static double peakOf(int number) =>
      ((StartCountdown.length.inSeconds - number + 0.47) /
              StartCountdown.length.inSeconds)
          .clamp(0.0, 1.0);
}

/// The countdown's two colours, from the theme's own gold (29 Sep 2026).
///
/// The file's deep blue (#1400B3) all but vanishes on the dark sapphire of a
/// blind table by night and fights every other cloth, so the disc and its
/// stars are drawn in the table's gold, one for each ground, and the digit is
/// cut out of it in the ground's opposite:
///
///   - by night [AppTheme.goldOnDark] (#F1D27A, the gold the app writes money
///     in on obsidian) under charcoal [AppTheme.ink900] — the Chaal key's own
///     pair: the disc 8.7:1 or more on every cloth, the rail and the room, the
///     digit 13:1 on it;
///   - by day [AppTheme.goldDeep] a step deeper (15% of the way to ink900,
///     #765B16) under white: [AppTheme.goldOnLight] and goldDeep themselves
///     fell to 2.5:1 and 2.7:1 at the edge of the lavender cloth, where the
///     disc stands; this holds 3.4:1 there and 4:1 or more on every other
///     cloth, the rail and the room, and the digit 6.4:1 on it.
///
/// Every cloth (seen, blind, variation, the teal fallback — a private table
/// lays its game's) in both themes: `test/start_countdown_test.dart`.
@immutable
class StartCountdownColours {
  const StartCountdownColours({required this.disc, required this.digit});

  /// Night's and day's.
  static const night = StartCountdownColours(
    disc: AppTheme.goldOnDark,
    digit: AppTheme.ink900,
  );
  static const day = StartCountdownColours(
    disc: dayDisc,
    digit: Color(0xFFFFFFFF),
  );

  /// [AppTheme.goldDeep] lerped 15% of the way to [AppTheme.ink900].
  static const dayDisc = Color(0xFF765B16);

  /// The pair for a theme [dayShare] of the way from night to day
  /// ([GlassColors.dayShare]), so a theme change with the countdown up
  /// cross-fades it with the room instead of snapping at the middle.
  factory StartCountdownColours.at(double dayShare) {
    final t = dayShare.clamp(0.0, 1.0);
    if (t <= 0) return night;
    if (t >= 1) return day;
    return StartCountdownColours(
      disc: Color.lerp(night.disc, day.disc, t)!,
      digit: Color.lerp(night.digit, day.digit, t)!,
    );
  }

  /// The disc and the stars round it.
  final Color disc;

  /// The number.
  final Color digit;

  /// The recolour, by layer name: the discs are the layers named "c", the
  /// stars "s", and each number its own digit's layer.
  List<ValueDelegate<Object>> get delegates => [
    ValueDelegate.color(const ['c', '**'], value: disc),
    ValueDelegate.color(const ['s', '**'], value: disc),
    for (final number in const ['3', '2', '1'])
      ValueDelegate.color([number, '**'], value: digit),
  ];

  @override
  bool operator ==(Object other) =>
      other is StartCountdownColours &&
      other.disc == disc &&
      other.digit == digit;

  @override
  int get hashCode => Object.hash(disc, digit);
}

/// The countdown before a deal on the felt (owner, 29 Sep 2026: "whenever
/// Game starts in any game table, instead of showing text "Starting game .."
/// show this count Down animation 3,2,1").
///
/// A layer the size of the felt, laid in its Stack under the tag, the pot and
/// every seat, so the stars the numbers throw off pass BEHIND them and never
/// over a word; the disc itself stands at [anchor] — where the waiting and
/// starting line stood — [discSize] across at the top of its pulse, which the
/// felt sizes to the room between the tag and the pot's plate.
///
/// It keeps its own time. The countdown is [GameState.startCountdown], the
/// deal as this phone expects it ([StartCountdown]); the layer listens to
/// GameState without rebuilding on its one-second notify, runs a ticker only
/// while the numbers are on the table (the last three seconds before the
/// deal) and repaints one painter off it — the composition was parsed when
/// the table opened. It never restarts: a snapshot that repeats the same deal
/// moves nothing, and one that joins mid-countdown (a reconnect) starts at
/// the number the time left names. At the deal it fades as the cards fly;
/// cancelled (a player left) it goes at once, and the waiting line is back.
/// A phone set to reduce motion shows each number still, at its fullest, and
/// no fades.
///
/// [onNumber] is a hook for a sound per number (3, then 2, then 1) — the
/// owner did not ask for one, so nothing is passed and nothing plays.
class StartCountdownLayer extends StatefulWidget {
  const StartCountdownLayer({
    super.key,
    required this.anchor,
    required this.discSize,
    this.onNumber,
  });

  /// Where the disc's middle stands, in this layer's box.
  final Offset anchor;

  /// The disc's diameter at the top of its pulse, in logical pixels.
  final double discSize;

  /// Told each number as it comes up. Off (null) by default.
  final ValueChanged<int>? onNumber;

  /// The disc for a slot [room] tall: all of it, within a floor where the
  /// digit still reads and a ceiling where the countdown is a number rather
  /// than the subject of the table.
  static double discFor(double room) => room.clamp(minDisc, maxDisc);
  static const double minDisc = 30;
  static const double maxDisc = 96;

  /// How long it takes to come up, and to go at the deal.
  static const Duration fadeIn = Duration(milliseconds: 160);
  static const Duration fadeOut = Duration(milliseconds: 220);

  /// How long before the deal the countdown starts to go: the "1" has faded
  /// by then (frame 266 of 270), so the empty disc dissolves as the deal
  /// arrives rather than waiting on the table for the cards.
  static const int leaveAtMs = 140;

  @override
  State<StartCountdownLayer> createState() => _StartCountdownLayerState();
}

class _StartCountdownLayerState extends State<StartCountdownLayer>
    with TickerProviderStateMixin {
  late final Ticker _ticker;
  late final AnimationController _fade;
  final ValueNotifier<double> _progress = ValueNotifier(0);

  GameState? _game;
  LottieDrawable? _drawable;
  StartCountdownColours? _colours;
  bool _still = false;

  /// The countdown on the table, and the number it shows (0: none). A
  /// countdown the deal has [_ended] is kept while it fades, so its stars go
  /// on flying as it goes.
  StartCountdown? _countdown;
  int _number = 0;
  bool _leaving = false;
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    // Made here, never first touched in dispose (CLAUDE.md §12.3).
    _ticker = createTicker(_tick);
    _fade = AnimationController(
      vsync: this,
      duration: StartCountdownLayer.fadeIn,
      reverseDuration: StartCountdownLayer.fadeOut,
    )..addStatusListener(_faded);
    final composition = StartCountdownArt.composition;
    if (composition != null) {
      _drawable = LottieDrawable(composition, frameRate: FrameRate.max);
    } else {
      // Parsed as the table opens, so the art is ready long before a deal.
      StartCountdownArt.load().then((composition) {
        if (!mounted || composition == null || _drawable != null) return;
        setState(() {
          _drawable = LottieDrawable(composition, frameRate: FrameRate.max);
          _drawable!.delegates = LottieDelegates(values: _colours?.delegates);
        });
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final game = context.read<GameState>();
    if (!identical(game, _game)) {
      _game?.removeListener(_sync);
      _game = game..addListener(_sync);
    }
    _still = MediaQuery.disableAnimationsOf(context);
    final colours = StartCountdownColours.at(GlassColors.of(context).dayShare);
    if (colours != _colours) {
      _colours = colours;
      _drawable?.delegates = LottieDelegates(values: colours.delegates);
    }
    _sync();
  }

  @override
  void dispose() {
    _game?.removeListener(_sync);
    _ticker.dispose();
    _fade.dispose();
    _progress.dispose();
    super.dispose();
  }

  int _now() => StartCountdown.clock();

  /// How far ahead of the numbers the ticker may start.
  static const int _early = 250;

  /// What GameState says now: a countdown to show, or none.
  void _sync() {
    final game = _game;
    if (game == null || !mounted) return;
    final countdown = game.startCountdown;
    // A seat held for a chip purchase has its own countdown in the status
    // slot and is not dealt in; a missile volley is still in the air.
    final blocked =
        game.missileStrike != null ||
        (game.room?.you?.unfundedDeadline ?? 0) > 0;
    if (countdown == null || blocked) {
      if (!_ended && (_countdown != null || _number != 0)) {
        _end(dealt: game.room?.state == TableState.betting);
      }
      return;
    }
    if (countdown != _countdown) {
      final fresh = _ended || _countdown?.startsAt != countdown.startsAt;
      _countdown = countdown;
      if (fresh) {
        _leaving = false;
        _ended = false;
      }
    }
    // A little early too: the timer that says the numbers are due can fire
    // a moment before the clock agrees, and the ticker waits out the rest.
    if (countdown.leftMs(_now()) <= StartCountdown.lengthMs + _early &&
        !_ticker.isActive) {
      _ticker.start();
    }
  }

  /// The countdown is over: the deal took it (it fades as the cards fly) or
  /// it was cancelled (it goes at once).
  void _end({required bool dealt}) {
    _leaving = true;
    if (dealt && !_still && _fade.value > 0) {
      _ended = true;
      _fade.reverse();
      return;
    }
    _fade.value = 0;
    _stop();
  }

  /// Done with this countdown: forgotten, the ticker still, no number.
  void _stop() {
    _countdown = null;
    _ended = false;
    _rest();
  }

  /// The ticker still and no number, the countdown kept: gone from the table
  /// before the deal's snapshot has come to end it.
  void _rest() {
    if (_ticker.isActive) _ticker.stop();
    if (_number != 0 && mounted) setState(() => _number = 0);
  }

  void _faded(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _leaving && _ended) _stop();
  }

  void _tick(Duration _) {
    final countdown = _countdown;
    if (countdown == null) return;
    final left = countdown.leftMs(_now());
    if (left > StartCountdown.lengthMs) {
      // Not yet: a frame or two early, or a later snapshot put the deal
      // further off — then wait for GameState to say the numbers are due.
      _fade.value = 0;
      if (left > StartCountdown.lengthMs + _early) _ticker.stop();
      return;
    }
    final number = left > 0 ? StartCountdown.numberFor(left) : 0;
    _progress.value = _still
        ? StartCountdownArt.peakOf(math.max(number, 1))
        : StartCountdown.progressFor(left);
    if (!_leaving) {
      if (left <= (_still ? 0 : StartCountdownLayer.leaveAtMs)) {
        _leaving = true;
        if (_still) {
          _fade.value = 0;
          _rest();
          return;
        }
        _fade.reverse();
      } else if (_fade.value < 1 && _fade.status != AnimationStatus.forward) {
        if (_still) {
          _fade.value = 1;
        } else {
          _fade.forward();
        }
      }
    }
    if (number != _number && number > 0) {
      setState(() => _number = number);
      widget.onNumber?.call(number);
    }
    if (_leaving && _fade.isDismissed) {
      if (_ended) {
        _stop();
      } else {
        // Gone before the deal's snapshot: nothing to draw until it comes.
        _rest();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.select<GameState, AppLang>((s) => s.lang);
    final showing = _number > 0;
    final colours = _colours ?? StartCountdownColours.night;
    final drawable = _drawable;
    final art = drawable == null
        ? _PlainDisc(
            anchor: widget.anchor,
            size: widget.discSize,
            number: _number,
            colours: colours,
          )
        : CustomPaint(
            size: Size.infinite,
            painter: _CountdownPainter(
              drawable: drawable,
              progress: _progress,
              anchor: widget.anchor,
              discSize: widget.discSize,
              colours: colours,
            ),
          );
    return IgnorePointer(
      child: Semantics(
        container: true,
        liveRegion: showing,
        label: showing ? Strings(lang).startingIn(_number) : null,
        child: ExcludeSemantics(
          child: RepaintBoundary(
            child: FadeTransition(
              opacity: _fade,
              child: showing || _fade.value > 0 ? art : const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

/// One frame of the 3-2-1, the disc's middle on [anchor] and its pulse
/// [discSize] across; the stars fly round it as far as they go.
class _CountdownPainter extends CustomPainter {
  _CountdownPainter({
    required this.drawable,
    required this.progress,
    required this.anchor,
    required this.discSize,
    required this.colours,
  }) : super(repaint: progress);

  final LottieDrawable drawable;
  final ValueListenable<double> progress;
  final Offset anchor;
  final double discSize;

  /// Only so a theme change repaints: the drawable already carries them.
  final StartCountdownColours colours;

  @override
  void paint(Canvas canvas, Size size) {
    drawable.setProgress(progress.value.clamp(0.0, 1.0));
    final scale = discSize / StartCountdownArt.discPeak;
    final bounds = drawable.composition.bounds;
    final rect = Rect.fromLTWH(
      anchor.dx - StartCountdownArt.discCentre.dx * scale,
      anchor.dy - StartCountdownArt.discCentre.dy * scale,
      bounds.width * scale,
      bounds.height * scale,
    );
    drawable.draw(canvas, rect, fit: BoxFit.fill);
  }

  @override
  bool shouldRepaint(_CountdownPainter old) =>
      old.drawable != drawable ||
      old.progress != progress ||
      old.anchor != anchor ||
      old.discSize != discSize ||
      old.colours != colours;
}

/// The numbers on a plain disc, for the moment before the art is parsed or a
/// phone that could not parse it: the countdown still says how long is left.
class _PlainDisc extends StatelessWidget {
  const _PlainDisc({
    required this.anchor,
    required this.size,
    required this.number,
    required this.colours,
  });

  final Offset anchor;
  final double size;
  final int number;
  final StartCountdownColours colours;

  @override
  Widget build(BuildContext context) {
    if (number <= 0) return const SizedBox.expand();
    final disc = size * 184 / StartCountdownArt.discPeak;
    return Stack(
      children: [
        Positioned(
          left: anchor.dx - disc / 2,
          top: anchor.dy - disc / 2,
          width: disc,
          height: disc,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colours.disc,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '$number',
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontFamily: AppTheme.fontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: disc * 0.5,
                  height: 1,
                  color: colours.digit,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
