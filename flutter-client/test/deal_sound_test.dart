// The deal is heard card by card (owner, 26 Sep 2026: "when card is being
// distributed then use this sound … remove old sound and this sound should be
// played continuously 12 times if 4 player plays and 15 times if 5 player
// plays, 6 times if 2 player plays"): assets/sound/Card Distribute.mp3, once
// for every card dealt, in the deal's rhythm, in place of the tick that used
// to click as each card landed.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/widgets/deal_flight.dart';

/// Every deal sound and every tick the deal asks for, and when.
class _Heard extends FeedbackSettings {
  _Heard(this.now);

  final DateTime Function() now;
  final dealt = <DateTime>[];
  var ticks = 0;

  @override
  void dealCard() => dealt.add(now());

  @override
  void tap() => ticks++;
}

Seat _seat(int i) => Seat.fromJson({
  'seatIndex': i,
  'userId': 'u$i',
  'displayName': 'Player $i',
  'chips': 200000,
  'status': 'active',
  'isBlind': true,
  'lastBet': 200,
  'lastAction': 'chaal',
  'contributed': 200,
  'connected': true,
  'cardCount': 3,
});

void main() {
  for (final (players, heard) in [(2, 6), (3, 9), (4, 12), (5, 15)]) {
    testWidgets('a deal to $players players is heard $heard times, one card '
        'after another, and no tick', (tester) async {
      final sounds = _Heard(() => tester.binding.clock.now());
      addTearDown(sounds.dispose);

      Widget table(int handNo) =>
          ChangeNotifierProvider<FeedbackSettings>.value(
            value: sounds,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DealFlights(
                      seats: [for (var i = 0; i < players; i++) _seat(i)],
                      roomId: 'r1',
                      handNo: handNo,
                      centreOf: (i) => Offset(100.0 + 100 * i, 300),
                      deck: const Offset(300, 150),
                      cardHeight: 40,
                    ),
                  ),
                ],
              ),
            ),
          );

      await tester.pumpWidget(table(6));
      await tester.pumpWidget(table(7));
      final start = tester.binding.clock.now();
      // Frame by frame, as a phone draws them, past the deal's end.
      final end = DealFlights.total(heard) + const Duration(milliseconds: 200);
      for (
        var t = Duration.zero;
        t < end;
        t += const Duration(milliseconds: 16)
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }

      expect(sounds.dealt, hasLength(heard));
      expect(sounds.ticks, 0, reason: 'the old tick is gone from the deal');

      // Card k is heard when DealFlights.soundOf says, within a frame or two
      // of the ticker starting.
      for (var k = 0; k < heard; k++) {
        final at = sounds.dealt[k].difference(start).inMilliseconds;
        expect(
          at,
          inInclusiveRange(
            DealFlights.soundOf(k).inMilliseconds,
            DealFlights.soundOf(k).inMilliseconds + 40,
          ),
          reason: 'card $k',
        );
      }
      // Each card's sound peaks (380 ms into the clip) as the card lands.
      expect(
        (DealFlights.soundAt +
                const Duration(milliseconds: 380) -
                DealFlights.trip)
            .inMilliseconds
            .abs(),
        lessThanOrEqualTo(20),
      );

      // The same hand again (a snapshot, a chat line) deals and sounds nothing.
      await tester.pumpWidget(table(7));
      await tester.pump(const Duration(seconds: 3));
      expect(sounds.dealt, hasLength(heard));

      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test('each card of a deal takes the next voice, so none cuts the one before '
      'it short', () async {
    SharedPreferences.setMockInitialValues({'soundOn': false});
    final sounds = FeedbackSettings();
    await sounds.load();
    expect(sounds.nextDealCardVoice, 0);
    for (var card = 1; card <= 12; card++) {
      sounds.dealCard();
      expect(sounds.nextDealCardVoice, card % FeedbackSettings.dealCardVoices);
    }
    // Enough voices for every card still sounding when the next one starts:
    // the clip is heard for 440 ms and the cards go 115 ms apart.
    expect(
      FeedbackSettings.dealCardVoices * DealFlights.stagger.inMilliseconds,
      greaterThanOrEqualTo(440),
    );
    sounds.dispose();
  });

  test("the owner's clip is bundled where the deal plays it from", () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    expect(FeedbackSettings.dealCardClip, 'sound/Card Distribute.mp3');
    final clip = await rootBundle.load(
      'assets/${FeedbackSettings.dealCardClip}',
    );
    final bytes = clip.buffer.asUint8List();
    expect(bytes.length, greaterThan(10000));
    final id3 = String.fromCharCodes(bytes.take(3)) == 'ID3';
    final frame = bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0;
    expect(id3 || frame, isTrue);
  });
}
