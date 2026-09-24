/// Three cards to each seat when a hand is dealt.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../settings/feedback_settings.dart';
import '../theme/app_theme.dart';
import 'playing_card.dart';

/// Face-down cards flying from the middle of the cloth to every occupied seat,
/// one seat at a time and three times round — the order a hand is dealt in.
///
/// Purely presentation: the real hand is already in the snapshot that started
/// it, and nothing here decides who gets what. Keyed on handNo, like the bet
/// flights, so a deal is "the hand number changed at the same table": a player
/// who sits down mid-hand, or moves table, is dealt nothing.
///
/// Rebuilt for smoothness (owner, 14 Sep 2026: the deal was not smooth). The
/// flight it replaces ran every card off one two-second clock, 124 ms apart
/// and 920 ms in the air each, so at a table of four or five the last cards
/// were still travelling when the clock ran out and vanished mid-flight. And
/// every card in the air was a whole [PlayingCard] — an SVG back, two blurred
/// shadows and a clip — under an opacity layer and a rotation of its own,
/// rebuilt, laid out and rastered again each frame, with a new card widget
/// made (and its SVG fetched) every time one set off. Now the deal's clock is
/// as long as its cards need ([total]), every card makes the same [trip] a
/// [stagger] behind the card before it, and the backs are one image rendered
/// once and drawn by a single painter that repaints off the clock.
class DealFlights extends StatefulWidget {
  const DealFlights({
    super.key,
    required this.seats,
    required this.roomId,
    required this.handNo,
    required this.centreOf,
    required this.deck,
    required this.cardHeight,
    this.cards = cardsEach,
  });

  final List<Seat?> seats;

  /// How many cards each seat is dealt: the Teen Patti three unless the
  /// table says otherwise (a poker room deals two, three, four or five).
  final int cards;

  /// Which table this is. A switch changes it, and a hand already in progress
  /// at the new table was not dealt to anyone here.
  final String roomId;
  final int handNo;
  final Offset Function(int seatIndex) centreOf;

  /// Where the cards come from — just above the middle, where a dealer's
  /// hands would be.
  final Offset deck;
  final double cardHeight;

  static const int cardsEach = 3;

  /// One card's flight from the deck to its seat. Slower than feels necessary
  /// on paper: rushing it is the difference between cards being dealt and
  /// cards appearing.
  static const Duration trip = Duration(milliseconds: 800);

  /// How long after the card before it each card sets off.
  static const Duration stagger = Duration(milliseconds: 115);

  /// A deal of [cards], from the first card leaving to the last one landing.
  static Duration total(int cards) => trip + stagger * math.max(0, cards - 1);

  /// Whether a table moving from [oldHandNo] at [oldRoomId] to [handNo] at
  /// [roomId] is dealt in view: a new hand, at the SAME table, and not the
  /// first after arriving. The room check keeps a switch quiet: the flights
  /// survive a move and see handNo jump to the new table's, which looks
  /// exactly like a deal. The table's host deals on the same test
  /// (dealer_host.dart), so the two can never disagree.
  static bool deals({
    required String oldRoomId,
    required int oldHandNo,
    required String roomId,
    required int handNo,
  }) => roomId == oldRoomId && handNo != oldHandNo && oldHandNo != 0;

  @override
  State<DealFlights> createState() => _DealFlightsState();
}

/// One card of a deal at one moment.
@immutable
class DealCard {
  const DealCard({
    required this.t,
    required this.along,
    required this.lift,
    required this.turn,
    required this.alpha,
    required this.scale,
  });

  /// How far through its own flight the card is, 0 to 1 in time.
  final double t;

  /// How far along the way from the deck to the seat, 0 to 1: [t] eased at
  /// both ends, so each card gathers and settles rather than being flicked.
  final double along;

  /// How high it is tossed above the straight line, in card heights. Zero at
  /// both ends.
  final double lift;

  /// Its tilt in radians, straightening as it arrives.
  final double turn;

  /// Its opacity, and its size as a fraction of a full card.
  final double alpha;
  final double scale;
}

/// Card [index] of a deal, [elapsed] after the deal began; null before that
/// card has left the deck and once it has landed.
DealCard? dealCardAt(int index, Duration elapsed) {
  final ms =
      elapsed.inMicroseconds / Duration.microsecondsPerMillisecond -
      DealFlights.stagger.inMilliseconds * index;
  if (ms <= 0) return null;
  final t = ms / DealFlights.trip.inMilliseconds;
  if (t >= 1) return null;

  final along = Curves.easeInOutCubic.transform(t);
  // Off the deck over the first 12% of the flight; handed over to the card the
  // seat already draws over the last 18%, rather than doubling it.
  final leaving = Curves.easeOut.transform(math.min(t / 0.12, 1.0));
  final arriving = Curves.easeOut.transform(math.min((1 - t) / 0.18, 1.0));

  return DealCard(
    t: t,
    along: along,
    lift: 0.3 * math.sin(along * math.pi),
    turn: (1 - along) * 0.38,
    alpha: math.min(leaving, arriving),
    scale: 0.85 + 0.15 * leaving,
  );
}

/// The seats a new hand is dealt to, by index: those holding a player who is
/// in it. An empty chair is still a place in the list — and until 14 Sep 2026
/// was dealt to, cards sailing across the felt to nobody — and a player sitting
/// the hand out holds no cards.
List<int> dealtSeats(List<Seat?> seats) => [
  for (var i = 0; i < seats.length; i++)
    if (seats[i] case final seat?
        when seat.occupied && (seat.inHand || seat.cardCount > 0))
      i,
];

class _DealFlightsState extends State<DealFlights>
    with SingleTickerProviderStateMixin {
  /// Created by the first deal, never in advance — and never by [dispose].
  ///
  /// A table left before any hand is dealt never touched it, so as a
  /// `late final` its first read was `dispose()`, which built a ticker
  /// mid-teardown, half-unmounted the table and red-screened the next one
  /// (CLAUDE.md §12.3). Keep the null check.
  AnimationController? _controller;

  AnimationController get _run =>
      _controller ??= AnimationController(vsync: this)
        ..addListener(_onTick)
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed && mounted) {
            setState(() => _targets = const []);
          }
        });

  /// Where each card of the deal lands, in the order they are dealt.
  List<Offset> _targets = const [];
  int _landed = 0;

  /// The card back as one image, and the size and pixel ratio it was made
  /// for; null until the artwork has loaded, when a plain back stands in.
  ui.Image? _back;
  double _backHeight = 0;
  double _backScale = 0;
  PictureInfo? _art;
  bool _loadingArt = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _prepareBack();
  }

  @override
  void didUpdateWidget(DealFlights old) {
    super.didUpdateWidget(old);
    if (widget.cardHeight != old.cardHeight) _prepareBack();
    if (!DealFlights.deals(
      oldRoomId: old.roomId,
      oldHandNo: old.handNo,
      roomId: widget.roomId,
      handNo: widget.handNo,
    )) {
      return;
    }
    _deal();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _back?.dispose();
    _art?.picture.dispose();
    super.dispose();
  }

  void _deal() {
    final seated = dealtSeats(widget.seats);
    if (seated.isEmpty) return;

    final targets = [
      for (var round = 0; round < widget.cards; round++)
        for (final seat in seated) widget.centreOf(seat),
    ];
    setState(() {
      _targets = targets;
      _landed = 0;
    });
    _run
      ..duration = DealFlights.total(targets.length)
      ..forward(from: 0);
  }

  /// A click as each card lands, through the settings so it honours the
  /// player's switch: the rhythm of the cards landing IS the sound of dealing.
  void _onTick() {
    final elapsed = (_run.duration ?? Duration.zero) * _run.value;
    var landed = 0;
    for (var i = 0; i < _targets.length; i++) {
      if (elapsed >= DealFlights.stagger * i + DealFlights.trip) landed++;
    }
    if (landed <= _landed) return;
    final feedback = context.read<FeedbackSettings>();
    for (var i = _landed; i < landed; i++) {
      feedback.tap();
    }
    _landed = landed;
  }

  /// Renders the card back, once per size, into the image every flying card
  /// is drawn from.
  Future<void> _prepareBack() async {
    if (_art == null) {
      if (_loadingArt) return;
      _loadingArt = true;
      try {
        _art = await vg.loadPicture(
          SvgAssetLoader('assets/card_back.svg'),
          null,
        );
      } catch (_) {
        return; // The plain back stands in; the deal still runs.
      } finally {
        _loadingArt = false;
      }
      if (!mounted) return;
    }

    final height = widget.cardHeight;
    final scale = MediaQuery.devicePixelRatioOf(context);
    if (_back != null && _backHeight == height && _backScale == scale) return;
    final image = _renderBack(_art!, height, scale);
    setState(() {
      _back?.dispose();
      _back = image;
      _backHeight = height;
      _backScale = scale;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_targets.isEmpty) return const SizedBox.shrink();
    return SizedBox.expand(
      child: CustomPaint(
        painter: _DealPainter(
          clock: _run,
          deck: widget.deck,
          targets: _targets,
          cardHeight: widget.cardHeight,
          back: _back,
          backScale: _backScale,
        ),
      ),
    );
  }
}

/// The margin round the card back's image, in card heights, that its shadow
/// is drawn into.
const double _shadowRoom = 0.12;

/// The card back at [height] logical pixels and [scale] device pixels to one,
/// with its rounded corners cut and a soft shadow under it, as one image.
ui.Image _renderBack(PictureInfo art, double height, double scale) {
  final width = height * PlayingCard.aspect;
  final room = height * _shadowRoom;
  final card = RRect.fromRectAndRadius(
    Rect.fromLTWH(room, room, width, height),
    // PlayingCard's own corner, a fraction of its height.
    Radius.circular(height * 0.055),
  );

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  canvas.drawRRect(
    card.shift(Offset(0, height * 0.03)),
    Paint()
      ..color = AppTheme.ink900.withValues(alpha: 0.42)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, height * 0.05),
  );
  canvas
    ..save()
    ..clipRRect(card)
    ..translate(room, room)
    ..scale(width / art.size.width, height / art.size.height)
    ..drawPicture(art.picture)
    ..restore();

  final picture = recorder.endRecording();
  final image = picture.toImageSync(
    ((width + 2 * room) * scale).ceil(),
    ((height + 2 * room) * scale).ceil(),
  );
  picture.dispose();
  return image;
}

class _DealPainter extends CustomPainter {
  _DealPainter({
    required this.clock,
    required this.deck,
    required this.targets,
    required this.cardHeight,
    required this.back,
    required this.backScale,
  }) : super(repaint: clock);

  final AnimationController clock;
  final Offset deck;
  final List<Offset> targets;
  final double cardHeight;
  final ui.Image? back;
  final double backScale;

  /// The back a card is drawn with until the artwork has loaded.
  static const Color _plainBack = Color(0xFF2E211B);

  @override
  void paint(Canvas canvas, Size size) {
    final elapsed = (clock.duration ?? Duration.zero) * clock.value;
    final image = back;

    // In the order dealt, so each card lands over the one dealt before it.
    for (var i = 0; i < targets.length; i++) {
      final card = dealCardAt(i, elapsed);
      if (card == null) continue;
      final at =
          Offset.lerp(deck, targets[i], card.along)! -
          Offset(0, card.lift * cardHeight);
      canvas
        ..save()
        ..translate(at.dx, at.dy)
        ..rotate(card.turn)
        ..scale(card.scale);

      if (image != null) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromCenter(
            center: Offset.zero,
            width: image.width / backScale,
            height: image.height / backScale,
          ),
          Paint()
            ..color = Color.fromRGBO(0, 0, 0, card.alpha)
            ..filterQuality = FilterQuality.medium,
        );
      } else {
        final plain = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: cardHeight * PlayingCard.aspect,
            height: cardHeight,
          ),
          Radius.circular(cardHeight * 0.055),
        );
        canvas
          ..drawRRect(
            plain,
            Paint()..color = _plainBack.withValues(alpha: card.alpha),
          )
          ..drawRRect(
            plain,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1
              ..color = AppTheme.goldDeep.withValues(alpha: card.alpha),
          );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_DealPainter old) =>
      old.clock != clock ||
      old.deck != deck ||
      !identical(old.targets, targets) ||
      old.cardHeight != cardHeight ||
      old.back != back ||
      old.backScale != backScale;
}
