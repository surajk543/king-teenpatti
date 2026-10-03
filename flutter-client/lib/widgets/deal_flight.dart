/// Three cards to each seat when a hand is dealt.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/dtos.dart';
import '../settings/feedback_settings.dart';
import '../theme/app_theme.dart';
import 'card_back_art.dart';
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
/// [stagger] behind the card before it, and the backs are images rendered
/// once and drawn by a single painter that repaints off the clock.
///
/// **Each card in its seat's back** (owner, 3 Oct 2026: card backs bought on
/// the store's Cards shelf, which everybody at the table sees on the wearer's
/// cards): with [seatBacks], a card flies in the back the seat it is dealt to
/// wears ([Seat.cardBackground]) — the back it lands as. Every back the seats
/// wear is rendered ONCE, before the deal, into an image of its own from the
/// picture [CardBackImages] has decoded — five seats in three backs are three
/// images — and the one painter draws each card from its seat's. A back
/// still coming flies as the Royal Fox, and the cards still in the air take
/// it up the moment it is decoded, whoever asked for it.
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
    this.seatBacks = false,
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

  /// Whether each card flies in the back its seat wears
  /// ([Seat.cardBackground]): the Teen Patti felt's deal. Off, every card is
  /// the Royal Fox — the poker felt's, whose cards keep it whatever back a
  /// player wears at a Teen Patti table.
  final bool seatBacks;

  static const int cardsEach = 3;

  /// One card's flight from the deck to its seat. Slower than feels necessary
  /// on paper: rushing it is the difference between cards being dealt and
  /// cards appearing.
  static const Duration trip = Duration(milliseconds: 800);

  /// How long after the card before it each card sets off.
  static const Duration stagger = Duration(milliseconds: 115);

  /// How far into its flight a card's sound starts ([FeedbackSettings.dealCard],
  /// once per card: 6 at a table of two, 12 at four, 15 at five). The owner's
  /// clip is a faint rustle for 200 ms and then a swish, loudest at 380 ms, so
  /// started 400 ms before the card comes down it peaks as the card lands.
  /// Started at the landing, as the tick it replaced was, the swish came 0.4 s
  /// after the card.
  static const Duration soundAt = Duration(milliseconds: 400);

  /// When card [index] of a deal is heard, from the deal's start.
  static Duration soundOf(int index) => stagger * index + soundAt;

  /// A deal of [cards], from the first card leaving to the last one landing.
  static Duration total(int cards) => trip + stagger * math.max(0, cards - 1);

  @override
  State<DealFlights> createState() => DealFlightsState();
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

/// Where [card], flying from [deck] to [target], is centred: along the line
/// between them and tossed above it by its lift.
Offset _flightCentre(
  Offset deck,
  Offset target,
  DealCard card,
  double cardHeight,
) => Offset.lerp(deck, target, card.along)! - Offset(0, card.lift * cardHeight);

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

/// A back as the deal renders it: its picture's location and the card's
/// crop in it — the id a catalogue row carries does not change a back — or,
/// with an empty url, the Royal Fox.
typedef _Back = ({String url, CardCrop? crop});

const _Back _royalFox = (url: '', crop: null);

_Back _backOf(CardBackArt? art) =>
    art == null ? _royalFox : (url: art.url, crop: art.crop);

/// [back] as [CardBackImages] is asked for it: null for the Royal Fox.
CardBackArt? _artOf(_Back back) =>
    back.url.isEmpty ? null : CardBackArt(url: back.url, crop: back.crop);

class DealFlightsState extends State<DealFlights>
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
            setState(() {
              _targets = const [];
              _cardBacks = const [];
              _cardImages = const [];
            });
            // The deal is down: a back only its cards were still wearing —
            // a player who left mid-deal — can go.
            _restock();
          }
        });

  /// Where each card of the deal lands, in the order they are dealt.
  List<Offset> _targets = const [];

  /// The back each card of the deal is dealt in — the one its seat wears,
  /// which it lands as — in the same order.
  List<_Back> _cardBacks = const [];

  /// The image each card of the deal is drawn from now: its back's render,
  /// the Royal Fox's while its own is still coming, or null — the plain back
  /// — before even the Royal Fox has been decoded.
  List<ui.Image?> _cardImages = const [];

  /// How many cards of this deal have been heard.
  int _sounded = 0;

  /// Every back the deal may draw, each rendered once ([_renderBack]) at
  /// [_backHeight] logical pixels and [_backScale] device pixels to one —
  /// one image a back, however many cards wear it.
  final Map<_Back, ui.Image> _rendered = {};
  double _backHeight = 0;
  double _backScale = 0;

  /// The screen's device pixels to one, read where the dependency is kept.
  double _scale = 1;

  /// Backs being fetched and decoded for the deal, and backs that could not
  /// be had — not asked for again until the next deal, though one decoded
  /// meanwhile for a seat's own cards is taken up all the same ([_arrived]).
  final Set<_Back> _loading = {};
  final Set<_Back> _unavailable = {};

  int _renders = 0;

  @override
  void initState() {
    super.initState();
    CardBackImages.changes.addListener(_arrived);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scale = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    if (_restock()) _cardImages = _imagesFor(_cardBacks);
  }

  @override
  void didUpdateWidget(DealFlights oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Ready before anything is dealt: a new size, a player sitting down in
    // a back of their own, or one wearing another.
    if (_restock()) _cardImages = _imagesFor(_cardBacks);
    // A new hand, at the SAME table, and not the first after arriving. The
    // room check keeps a switch quiet: this state survives a move and sees
    // handNo jump to the new table's, which looks exactly like a deal.
    if (widget.roomId != oldWidget.roomId) return;
    if (widget.handNo == oldWidget.handNo || oldWidget.handNo == 0) return;
    _deal();
  }

  @override
  void dispose() {
    CardBackImages.changes.removeListener(_arrived);
    _controller?.dispose();
    for (final image in _rendered.values) {
      image.dispose();
    }
    _rendered.clear();
    super.dispose();
  }

  void _deal() {
    final seated = dealtSeats(widget.seats);
    if (seated.isEmpty) return;

    // A back that could not be had for the last deal is asked for again.
    _unavailable.clear();
    final targets = <Offset>[];
    final backs = <_Back>[];
    for (var round = 0; round < widget.cards; round++) {
      for (final seat in seated) {
        targets.add(widget.centreOf(seat));
        backs.add(
          widget.seatBacks
              ? _backOf(widget.seats[seat]?.cardBackground)
              : _royalFox,
        );
      }
    }
    _cardBacks = backs;
    _restock();
    setState(() {
      _targets = targets;
      _cardImages = _imagesFor(backs);
      _sounded = 0;
    });
    _run
      ..duration = DealFlights.total(targets.length)
      ..forward(from: 0);
  }

  /// The owner's deal sound once for every card, in the deal's rhythm
  /// ([DealFlights.soundOf]), through the settings so it honours the player's
  /// switch: the rhythm of the cards IS the sound of dealing. A frame that
  /// comes late still plays every card it passed, so a deal is always heard
  /// exactly as many times as it has cards.
  void _onTick() {
    final elapsed = (_run.duration ?? Duration.zero) * _run.value;
    var due = _sounded;
    while (due < _targets.length && elapsed >= DealFlights.soundOf(due)) {
      due++;
    }
    if (due == _sounded) return;
    final feedback = context.read<FeedbackSettings>();
    for (var i = _sounded; i < due; i++) {
      feedback.dealCard();
    }
    _sounded = due;
  }

  /// The backs the deal may draw: the Royal Fox, which stands in for any
  /// back still coming, every seated player's own, and those of the cards in
  /// the air (whose players may have left since they set off).
  Set<_Back> _wanted() => {
    _royalFox,
    if (widget.seatBacks)
      for (final seat in widget.seats)
        if (seat != null && seat.occupied) _backOf(seat.cardBackground),
    ..._cardBacks,
  };

  /// Renders every back the deal may draw ([_wanted]) that is not rendered at
  /// this size, from the pictures decoded so far; asks for those not decoded
  /// ([_ask]); and lets go of the renders nobody wears any more. True when a
  /// render was made or let go — the cards in the air are then pointed at
  /// what there is now ([_imagesFor]) before they are painted again.
  bool _restock() {
    var changed = false;
    final height = widget.cardHeight;
    if (height != _backHeight || _scale != _backScale) {
      for (final image in _rendered.values) {
        image.dispose();
      }
      _rendered.clear();
      _backHeight = height;
      _backScale = _scale;
      changed = true;
    }
    final wanted = _wanted();
    _rendered.removeWhere((back, image) {
      if (wanted.contains(back)) return false;
      image.dispose();
      changed = true;
      return true;
    });
    for (final back in wanted) {
      if (_rendered.containsKey(back)) continue;
      final picture = CardBackImages.peek(_artOf(back));
      if (picture == null) {
        _ask(back);
        continue;
      }
      _rendered[back] = _renderBack(picture, height, _scale);
      _renders++;
      changed = true;
    }
    return changed;
  }

  /// Has [back]'s picture fetched and decoded, unless it is on its way
  /// already or could not be had for this deal. It is rendered when it lands
  /// ([_arrived]), not here.
  void _ask(_Back back) {
    if (_loading.contains(back) || _unavailable.contains(back)) return;
    final art = _artOf(back);
    // A location nothing can sign (no session yet, or a test) is not
    // fetched at all: the Royal Fox flies in its place.
    if (art != null && !CardBackImages.canFetch(art)) {
      _unavailable.add(back);
      return;
    }
    _loading.add(back);
    unawaited(
      CardBackImages.load(art)
          // A load reports a picture it cannot have as null; anything thrown
          // on the way is the same thing to a deal.
          .catchError((Object _) => null)
          .then((picture) {
            if (!mounted) return;
            _loading.remove(back);
            if (picture == null) _unavailable.add(back);
          }),
    );
  }

  /// A back has been decoded somewhere — for the deal, or for a seat's own
  /// cards: rendered if the deal wears it, and handed to the cards in the
  /// air. Only this layer repaints for it.
  void _arrived() {
    if (!mounted || !_restock()) return;
    if (_targets.isEmpty) return;
    setState(() => _cardImages = _imagesFor(_cardBacks));
  }

  /// What each of [backs] is drawn from: its render, else the Royal Fox's,
  /// else nothing (the plain back).
  List<ui.Image?> _imagesFor(List<_Back> backs) => [
    for (final back in backs) _rendered[back] ?? _rendered[_royalFox],
  ];

  /// The back each card of the deal in the air is dealt in, in the order
  /// dealt — its seat's, or null for the Royal Fox. For tests.
  @visibleForTesting
  List<CardBackArt?> get dealtBacks => [
    for (final back in _cardBacks) _artOf(back),
  ];

  /// How many times a back has been rendered into an image since the deal
  /// was built: once for each back worn, and again only at a new size. For
  /// tests.
  @visibleForTesting
  int get backsRendered => _renders;

  /// The cards of the deal in the air now: which card of it (in the order
  /// dealt), where it is centred on the deal's box, and how opaque it is.
  /// For tests, which read the back a card is drawn in off the pixels there.
  @visibleForTesting
  List<({int card, Offset centre, double alpha})> get cardsInFlight {
    final controller = _controller;
    if (controller == null || _targets.isEmpty) return const [];
    final elapsed = (controller.duration ?? Duration.zero) * controller.value;
    return [
      for (var i = 0; i < _targets.length; i++)
        if (dealCardAt(i, elapsed) case final card?)
          (
            card: i,
            centre: _flightCentre(
              widget.deck,
              _targets[i],
              card,
              widget.cardHeight,
            ),
            alpha: card.alpha,
          ),
    ];
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
          images: _cardImages,
          imageScale: _backScale,
        ),
      ),
    );
  }
}

/// The margin round a card back's image, in card heights, that its shadow
/// is drawn into.
const double _shadowRoom = 0.12;

/// The card back [picture] at [height] logical pixels and [scale] device
/// pixels to one, with a soft shadow under it, as one image — printed as the
/// card it lands as ([paintCardBack]: the picture cut to the card's corner,
/// the stock's light along its top and its gold edge).
ui.Image _renderBack(CardBackPicture picture, double height, double scale) {
  final width = height * PlayingCard.aspect;
  final room = height * _shadowRoom;
  final card = Rect.fromLTWH(room, room, width, height);

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      card.shift(Offset(0, height * 0.03)),
      Radius.circular(height * PlayingCard.cornerShare),
    ),
    Paint()
      ..color = AppTheme.ink900.withValues(alpha: 0.42)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, height * 0.05),
  );
  paintCardBack(canvas, card, picture: picture);

  final recorded = recorder.endRecording();
  final image = recorded.toImageSync(
    ((width + 2 * room) * scale).ceil(),
    ((height + 2 * room) * scale).ceil(),
  );
  recorded.dispose();
  return image;
}

class _DealPainter extends CustomPainter {
  _DealPainter({
    required this.clock,
    required this.deck,
    required this.targets,
    required this.cardHeight,
    required this.images,
    required this.imageScale,
  }) : super(repaint: clock);

  final AnimationController clock;
  final Offset deck;
  final List<Offset> targets;
  final double cardHeight;

  /// The image each card is drawn from, in the order dealt; null draws the
  /// plain back.
  final List<ui.Image?> images;

  /// The device pixels to one every image was rendered at.
  final double imageScale;

  /// The back a card is drawn with until any artwork has loaded: its black
  /// border's colour.
  static const Color _plainBack = PlayingCard.backGround;

  @override
  void paint(Canvas canvas, Size size) {
    final elapsed = (clock.duration ?? Duration.zero) * clock.value;

    // In the order dealt, so each card lands over the one dealt before it.
    for (var i = 0; i < targets.length; i++) {
      final card = dealCardAt(i, elapsed);
      if (card == null) continue;
      final at = _flightCentre(deck, targets[i], card, cardHeight);
      canvas
        ..save()
        ..translate(at.dx, at.dy)
        ..rotate(card.turn)
        ..scale(card.scale);

      final image = i < images.length ? images[i] : null;
      if (image != null) {
        canvas.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Rect.fromCenter(
            center: Offset.zero,
            width: image.width / imageScale,
            height: image.height / imageScale,
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
          Radius.circular(cardHeight * PlayingCard.cornerShare),
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
              ..color = AppTheme.cardRim.withValues(alpha: card.alpha),
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
      !identical(old.images, images) ||
      old.imageScale != imageScale;
}
