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
import 'missed_turns_notice.dart';

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

  /// The most the 3-2-1 ever paints, in the composition's own units: the box
  /// round every pixel of every frame of the cut (measured by rendering them
  /// all; `test/start_countdown_test.dart` holds it). About a disc above the
  /// disc's middle, 1.1 below and 1.2 to either side — the stars' flight.
  static const Rect reach = Rect.fromLTRB(19, 40, 577, 526);

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

  /// For the tests: the art not parsed yet, and arriving when [loading]
  /// completes — a table that opens before the parse has finished.
  @visibleForTesting
  static set debugLoading(Future<LottieComposition?> loading) {
    _composition = null;
    _loading = loading;
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

/// Where the countdown stands on the felt: the disc the felt asked for, kept
/// clear of what stands over it, and the box its stars may fly in (29 Sep
/// 2026).
///
/// Everything drawn over the countdown on the felt — a seat's pod, the tag,
/// the winning tax's pill, the pot — is glass, and a seat sitting a hand out
/// is faded to under half its strength: the stars that fly a disc above the
/// numbers showed through the head seat's pod at a table of two or four
/// places, over its name and its stack. So the felt names the box the
/// countdown may draw in ([StartCountdownLayer.bounds]): the disc stays
/// [gap] inside it, and the stars fade out as they reach an edge of it,
/// over the room between that edge and the disc (at most
/// [StartCountdownLayer.feather]) — never over the disc itself.
@immutable
class StartCountdownPlacement {
  const StartCountdownPlacement({required this.disc, this.bounds});

  /// Where the disc stands at the top of its pulse.
  final Rect disc;

  /// The box the countdown may draw in; an infinite edge is no edge. Null:
  /// anywhere.
  final Rect? bounds;

  /// How far inside [bounds] the disc stays.
  static const double gap = Space.xs;

  /// The smallest disc: where there is less room than this, the disc takes
  /// this much, centred on the room there is, rather than a number no one
  /// can read.
  static const double least = 24;

  /// The disc [size] across with its middle on [anchor], kept inside
  /// [bounds]: it gives way from the edge it would cross — from its top,
  /// under a head seat's pod, keeping its foot where it was (clear of the
  /// pot) — and never grows.
  factory StartCountdownPlacement.of({
    required Offset anchor,
    required double size,
    Rect? bounds,
  }) {
    var top = anchor.dy - size / 2;
    var bottom = anchor.dy + size / 2;
    final b = bounds;
    if (b != null) {
      if (b.top.isFinite) top = math.max(top, b.top + gap);
      if (b.bottom.isFinite) bottom = math.min(bottom, b.bottom - gap);
    }
    var across = bottom - top;
    if (across < least) {
      final middle = (top + bottom) / 2;
      across = least;
      top = middle - least / 2;
    }
    return StartCountdownPlacement(
      disc: Rect.fromLTWH(anchor.dx - across / 2, top, across, across),
      bounds: b,
    );
  }

  /// The owner's art as this placement draws it: the whole composition's box
  /// ([composition] is its size in its own units), scaled so its disc is
  /// [disc].
  Rect artFor(Size composition) {
    final scale = disc.width / StartCountdownArt.discPeak;
    return Rect.fromLTWH(
      disc.center.dx - StartCountdownArt.discCentre.dx * scale,
      disc.center.dy - StartCountdownArt.discCentre.dy * scale,
      composition.width * scale,
      composition.height * scale,
    );
  }

  /// The most the art ever paints here ([StartCountdownArt.reach], scaled),
  /// before [bounds] are applied.
  Rect get reach {
    final scale = disc.width / StartCountdownArt.discPeak;
    final r = StartCountdownArt.reach;
    final c = StartCountdownArt.discCentre;
    return Rect.fromLTRB(
      disc.center.dx + (r.left - c.dx) * scale,
      disc.center.dy + (r.top - c.dy) * scale,
      disc.center.dx + (r.right - c.dx) * scale,
      disc.center.dy + (r.bottom - c.dy) * scale,
    );
  }

  /// Where the art can show at all: its [reach] inside [bounds].
  Rect get painted {
    final b = bounds;
    return b == null ? reach : reach.intersect(b);
  }

  /// How far inside each edge of [bounds] the stars fade: the room between
  /// that edge and the disc, at most [StartCountdownLayer.feather]; none on
  /// an edge that is not there.
  EdgeInsets get feather {
    final b = bounds;
    if (b == null) return EdgeInsets.zero;
    double fade(double edge, double room) =>
        edge.isFinite ? room.clamp(0.0, StartCountdownLayer.feather) : 0;
    return EdgeInsets.fromLTRB(
      fade(b.left, disc.left - b.left),
      fade(b.top, disc.top - b.top),
      fade(b.right, b.right - disc.right),
      fade(b.bottom, b.bottom - disc.bottom),
    );
  }

  /// A step of the way from this placement to [target] — the disc eases a
  /// third of the way each frame, and lands once it is within half a point —
  /// so a head seat that changes height mid-countdown (a player sitting down
  /// in it) moves the disc rather than jumping it.
  StartCountdownPlacement towards(StartCountdownPlacement target) {
    final far = (disc.topLeft - target.disc.topLeft).distance;
    if (far < 0.5 && (disc.width - target.disc.width).abs() < 0.5) {
      return target;
    }
    return StartCountdownPlacement(
      disc: Rect.lerp(disc, target.disc, 1 / 3)!,
      bounds: target.bounds,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StartCountdownPlacement &&
      other.disc == disc &&
      other.bounds == bounds;

  @override
  int get hashCode => Object.hash(disc, bounds);

  @override
  String toString() => 'StartCountdownPlacement($disc, bounds: $bounds)';
}

/// The countdown before a deal on the felt (owner, 29 Sep 2026: "whenever
/// Game starts in any game table, instead of showing text "Starting game .."
/// show this count Down animation 3,2,1").
///
/// A layer the size of the felt, laid in its Stack under the tag, the pot and
/// every seat, the disc at [anchor] — where the waiting and starting line
/// stood — [discSize] across at the top of its pulse, which the felt sizes to
/// the room between what stands over the slot and the pot's plate. Whatever
/// stands over it is named by [bounds], read as the felt was last laid out
/// on every frame the countdown shows: the disc stays inside them and the
/// stars fade out at their edges ([StartCountdownPlacement]).
///
/// It keeps its own time. The countdown is [GameState.startCountdown], the
/// deal as this phone expects it ([StartCountdown]); the layer listens to
/// GameState without rebuilding on its one-second notify, runs a ticker only
/// while the numbers are on the table (the last three seconds before the
/// deal) and repaints one painter off it — the composition was parsed as the
/// app started. It never restarts: a snapshot that repeats the same deal
/// moves nothing, and one that joins mid-countdown (a reconnect) starts at
/// the number the time left names. At the deal it fades as the cards fly;
/// cancelled (a player left) it goes at once, and the waiting line is back.
/// A phone set to reduce motion shows each number still, at its fullest, and
/// no fades.
///
/// The status slot's more urgent lines outrank it: a seat held for a chip
/// purchase, a missile volley in the air, and — where the missed-turn
/// warning shares its slot ([yieldToWarning]) — that warning for its five
/// seconds (owner, 27 Sep 2026: "missed turn text show only for 5 seconds");
/// the countdown then comes in at the number the time left names.
///
/// [onNumber] is a hook for a sound per number (3, then 2, then 1) — the
/// owner did not ask for one, so nothing is passed and nothing plays.
class StartCountdownLayer extends StatefulWidget {
  const StartCountdownLayer({
    super.key,
    required this.anchor,
    required this.discSize,
    this.bounds,
    this.yieldToWarning = false,
    this.onNumber,
  });

  /// Where the disc's middle stands, in this layer's box.
  final Offset anchor;

  /// The disc's diameter at the top of its pulse, in logical pixels.
  final double discSize;

  /// The box the countdown may draw in, in this layer's box, as the felt was
  /// last laid out: the head seat's pod over it at a table of two or four
  /// places, else the winning tax's pill or the category tag; the pocket's
  /// edges on the poker felt. Null: anywhere.
  final ValueGetter<Rect?>? bounds;

  /// Whether the missed-turn warning stands in this countdown's slot, where
  /// it keeps its five seconds and the countdown waits for them.
  final bool yieldToWarning;

  /// Told each number as it comes up. Off (null) by default.
  final ValueChanged<int>? onNumber;

  /// The disc for a slot [room] tall: all of it, within a floor where the
  /// digit still reads and a ceiling where the countdown is a number rather
  /// than the subject of the table.
  static double discFor(double room) => room.clamp(minDisc, maxDisc);
  static const double minDisc = 30;
  static const double maxDisc = 96;

  /// The most the stars fade over as they reach an edge of [bounds].
  static const double feather = 14;

  /// Where the countdown built by [layer] (a [StartCountdownLayer]'s
  /// element) stands, in the layer's own box; null before it has run.
  @visibleForTesting
  static StartCountdownPlacement? placementIn(Element layer) {
    if (layer is! StatefulElement) return null;
    final state = layer.state;
    return state is _StartCountdownLayerState ? state._placement : null;
  }

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

  /// The art, parsed while a number stood on the plain disc: it takes over at
  /// the next number, never in the middle of one (the plain disc and the
  /// art's pulse at that moment are different sizes).
  LottieDrawable? _waiting;
  StartCountdownColours? _colours;
  bool _still = false;

  /// Where the disc stands, measured on the frames the countdown runs; null
  /// until the first of them, and nothing is drawn before it.
  StartCountdownPlacement? _placement;

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
      // Parsed as the app starts (main.dart), so this is the rare table that
      // opened before it had finished, or one where it failed and is tried
      // again.
      StartCountdownArt.load().then((composition) {
        if (!mounted || composition == null || _drawable != null) return;
        final drawable = LottieDrawable(composition, frameRate: FrameRate.max)
          ..delegates = LottieDelegates(values: _colours?.delegates);
        if (_number > 0) {
          _waiting = drawable;
        } else {
          setState(() => _drawable = drawable);
        }
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
      for (final drawable in [?_drawable, ?_waiting]) {
        drawable.delegates = LottieDelegates(values: colours.delegates);
      }
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
    // slot and is not dealt in; a missile volley is still in the air; a
    // missed-turn warning sharing the slot keeps its five seconds.
    final blocked =
        game.missileStrike != null ||
        (game.room?.you?.unfundedDeadline ?? 0) > 0 ||
        (widget.yieldToWarning &&
            game.missedTurnsNoticeShowing &&
            missedTurnsWarning(game.room?.you, game.t) != null);
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
    _takeWaitingArt();
  }

  /// The art that arrived while a number stood on the plain disc, now that
  /// none does.
  void _takeWaitingArt() {
    final waiting = _waiting;
    if (waiting == null || !mounted) return;
    _waiting = null;
    setState(() => _drawable = waiting);
  }

  void _faded(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _leaving && _ended) _stop();
  }

  /// Where the disc stands now: the felt's anchor and size inside what
  /// stands over them, as the felt was last laid out — an easing step from
  /// where it stood last frame.
  void _place() {
    final target = StartCountdownPlacement.of(
      anchor: widget.anchor,
      size: widget.discSize,
      bounds: widget.bounds?.call(),
    );
    final held = _placement;
    final next = held == null || _still ? target : held.towards(target);
    if (next != held) setState(() => _placement = next);
  }

  void _tick(Duration _) {
    final countdown = _countdown;
    if (countdown == null) return;
    final left = countdown.leftMs(_now());
    if (left > StartCountdown.lengthMs) {
      // Not yet: a frame or two early, or a later snapshot put the deal
      // further off — then wait for GameState to say the numbers are due.
      _fade.value = 0;
      _place();
      if (left > StartCountdown.lengthMs + _early) _ticker.stop();
      return;
    }
    _place();
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
      _takeWaitingArt();
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
    final placement = _placement;
    if (placement == null) return const SizedBox.expand();
    final showing = _number > 0;
    final colours = _colours ?? StartCountdownColours.night;
    final drawable = _drawable;
    final Widget art = drawable == null
        ? _PlainDisc(disc: placement.disc, number: _number, colours: colours)
        : CustomPaint(
            size: Size.infinite,
            painter: _CountdownPainter(
              drawable: drawable,
              progress: _progress,
              placement: placement,
              colours: colours,
            ),
          );
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: FadeTransition(
                opacity: _fade,
                child: showing || _fade.value > 0
                    ? art
                    : const SizedBox.expand(),
              ),
            ),
          ),
          // What a screen reader hears, on the disc: "Starting in 3".
          Positioned.fromRect(
            rect: placement.disc,
            child: Semantics(
              key: const ValueKey('start-countdown-disc'),
              container: true,
              liveRegion: showing,
              label: showing ? Strings(lang).startingIn(_number) : null,
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    );
  }
}

/// One frame of the 3-2-1, its disc on the placement's and its stars flying
/// round it as far as the placement's bounds let them, fading at their
/// edges.
class _CountdownPainter extends CustomPainter {
  _CountdownPainter({
    required this.drawable,
    required this.progress,
    required this.placement,
    required this.colours,
  }) : super(repaint: progress);

  final LottieDrawable drawable;
  final ValueListenable<double> progress;
  final StartCountdownPlacement placement;

  /// Only so a theme change repaints: the drawable already carries them.
  final StartCountdownColours colours;

  @override
  void paint(Canvas canvas, Size size) {
    drawable.setProgress(progress.value.clamp(0.0, 1.0));
    final composition = drawable.composition.bounds;
    final art = placement.artFor(
      Size(composition.width.toDouble(), composition.height.toDouble()),
    );
    final bounds = placement.bounds;
    final reach = placement.reach;
    final feather = placement.feather;
    // Nothing of the art comes near an edge: drawn as it is.
    if (bounds == null ||
        (reach.left >= bounds.left + feather.left &&
            reach.top >= bounds.top + feather.top &&
            reach.right <= bounds.right - feather.right &&
            reach.bottom <= bounds.bottom - feather.bottom)) {
      drawable.draw(canvas, art, fit: BoxFit.fill);
      return;
    }
    final area = placement.painted;
    if (area.isEmpty) return;
    canvas
      ..save()
      ..clipRect(area)
      ..saveLayer(area, Paint());
    drawable.draw(canvas, art, fit: BoxFit.fill);
    // Each edge fades the stars out over the room between it and the disc:
    // the band's alpha multiplied from nothing at the edge to whole at the
    // band's inner side (drawn inside the clip, so only what is there).
    void fade(Rect band, Alignment from) {
      if (band.width <= 0 || band.height <= 0) return;
      canvas.drawRect(
        band,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = LinearGradient(
            begin: from,
            end: -from,
            colors: const [Color(0x00000000), Color(0xFF000000)],
          ).createShader(band),
      );
    }

    if (feather.top > 0) {
      fade(
        Rect.fromLTRB(
          area.left,
          bounds.top,
          area.right,
          bounds.top + feather.top,
        ),
        Alignment.topCenter,
      );
    }
    if (feather.bottom > 0) {
      fade(
        Rect.fromLTRB(
          area.left,
          bounds.bottom - feather.bottom,
          area.right,
          bounds.bottom,
        ),
        Alignment.bottomCenter,
      );
    }
    if (feather.left > 0) {
      fade(
        Rect.fromLTRB(
          bounds.left,
          area.top,
          bounds.left + feather.left,
          area.bottom,
        ),
        Alignment.centerLeft,
      );
    }
    if (feather.right > 0) {
      fade(
        Rect.fromLTRB(
          bounds.right - feather.right,
          area.top,
          bounds.right,
          area.bottom,
        ),
        Alignment.centerRight,
      );
    }
    canvas
      ..restore()
      ..restore();
  }

  @override
  bool shouldRepaint(_CountdownPainter old) =>
      old.drawable != drawable ||
      old.progress != progress ||
      old.placement != placement ||
      old.colours != colours;
}

/// The numbers on a plain disc, for the moment before the art is parsed or a
/// phone that could not parse it: the countdown still says how long is left.
class _PlainDisc extends StatelessWidget {
  const _PlainDisc({
    required this.disc,
    required this.number,
    required this.colours,
  });

  /// The art's disc at the top of its pulse.
  final Rect disc;
  final int number;
  final StartCountdownColours colours;

  @override
  Widget build(BuildContext context) {
    if (number <= 0) return const SizedBox.expand();
    final plain = disc.width * 184 / StartCountdownArt.discPeak;
    return Stack(
      children: [
        Positioned.fromRect(
          rect: Rect.fromCenter(
            center: disc.center,
            width: plain,
            height: plain,
          ),
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
                  fontSize: plain * 0.5,
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
