// A wild card of the viewer's own hand turns into the card it played as
// (owner, 18 Sep 2026): "in a variation game of AK47, when the user clicks See
// cards, once the player sees his own cards, change the card according to the
// AK47 variation, with animation and effect."
//
// What a card stood for is the server's to say (`you.hand.playsAs`, sent to
// that player alone); the client only stages it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/wild_transform.dart';

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.dark(sound: false),
  home: Scaffold(body: Center(child: child)),
);

/// Runs the clock forward a frame at a time: the turn starts on a timer, and a
/// single long pump would fire the timer and give the animation no frames.
Future<void> _run(WidgetTester tester, Duration total) async {
  const frame = Duration(milliseconds: 40);
  for (var t = Duration.zero; t < total; t += frame) {
    await tester.pump(frame);
  }
}

String? _shownCode(WidgetTester tester) =>
    tester.widget<PlayingCard>(find.byType(PlayingCard)).code;

/// The tab at the foot of a turned wild card, naming the card really held.
Finder _realCardTab(String code) =>
    find.byKey(ValueKey('wild-real-card:$code'));

/// The painted suit on that tab.
CardPips _tabPip(WidgetTester tester, String code) => tester.widget<CardPips>(
  find.descendant(of: _realCardTab(code), matching: find.byType(CardPips)),
);

void main() {
  group('you.hand', () {
    test('says which cards were wild and what each stood for', () {
      final you = You.fromJson({
        'seatIndex': 0,
        'chips': 1000,
        'status': 'active',
        'isBlind': false,
        'cards': ['Jh', 'Qs', '4s'],
        'hand': {
          'handName': 'Sequence',
          'category': 3,
          'wild': ['4s'],
          'playsAs': ['Jh', 'Qs', 'Kd'],
        },
      });
      final hand = you.hand!;
      expect(hand.handName, 'Sequence');
      expect(hand.standInFor('4s', 2), 'Kd');
      expect(hand.standInFor('Jh', 0), isNull, reason: 'a natural card');
      expect(hand.standInFor('Qs', 1), isNull);
    });

    test('a wild card that stood for itself does not turn', () {
      final hand = OwnHand.fromJson({
        'handName': 'Color',
        'wild': ['Ac'],
        'playsAs': ['8c', 'Ac', '3c'],
      });
      expect(hand.wild, ['Ac']);
      expect(hand.standInFor('Ac', 1), isNull);
    });

    test('is absent on a seen or blind table, and before it can be known', () {
      final you = You.fromJson({
        'seatIndex': 0,
        'chips': 1000,
        'status': 'active',
        'isBlind': false,
        'cards': ['Jh', 'Qs', '4s'],
      });
      expect(you.hand, isNull);
    });

    test('reads anything unusable as nothing wild', () {
      for (final raw in <Map<String, dynamic>>[
        {},
        {'handName': null, 'wild': null, 'playsAs': null},
        {'handName': 7, 'wild': 'AK47', 'playsAs': {'0': 'Kd'}},
        {
          'wild': ['4s', null, 9, ''],
          'playsAs': ['Jh'],
        },
      ]) {
        final hand = OwnHand.fromJson(raw);
        expect(hand.standInFor('4s', 2), isNull, reason: '$raw');
        expect(hand.standInFor('4s', -1), isNull, reason: '$raw');
      }
      expect(You.fromJson({'hand': 'Sequence'}).hand, isNull);
      expect(You.fromJson({'hand': ['Kd']}).hand, isNull);
    });
  });

  group('the card', () {
    testWidgets('is a plain card until the server says what it stood for', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const WildTransform(height: 120, code: '4s', index: 0, label: 'Wild'),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(_shownCode(tester), '4s');
      expect(find.text('WILD'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('turns into the card it played as, once, and says what it '
        'really is', (tester) async {
      Widget card({String? standIn}) => _host(
        WildTransform(
          height: 120,
          code: '4s',
          standIn: standIn,
          wild: standIn != null,
          index: 0,
          label: 'Wild',
        ),
      );
      await tester.pumpWidget(card());
      await tester.pump(const Duration(seconds: 1));
      expect(_shownCode(tester), '4s');

      // The variation lands while the player is already looking.
      await tester.pumpWidget(card(standIn: 'Kd'));
      await tester.pump(const Duration(milliseconds: 60));
      expect(_shownCode(tester), '4s', reason: 'it has not turned yet');

      // Edge-on at the middle of the turn, then the new face.
      await _run(tester, const Duration(milliseconds: 1500));
      expect(tester.takeException(), isNull);
      expect(_shownCode(tester), 'Kd');
      expect(find.text('WILD'), findsOneWidget);
      expect(
        _realCardTab('4s'),
        findsOneWidget,
        reason: 'the card really held',
      );
      // The rank in type and the suit painted in the suit's own ink — never a
      // bare '♠' from whatever font the phone falls back to (24 Sep 2026).
      expect(
        find.descendant(of: _realCardTab('4s'), matching: find.text('4')),
        findsOneWidget,
      );
      expect(find.text('4♠'), findsNothing);
      expect(_tabPip(tester, '4s').suit, 's');
      expect(_tabPip(tester, '4s').colour, AppTheme.pipBlack);

      // The one-second tick rebuilds the table; the card does not turn again.
      await tester.pumpWidget(card(standIn: 'Kd'));
      await tester.pump(const Duration(milliseconds: 60));
      expect(_shownCode(tester), 'Kd');

      // The hand ends and the server stops naming a hand: the card stays
      // turned for the showdown rather than turning back under it.
      await tester.pumpWidget(card());
      await _run(tester, const Duration(seconds: 2));
      expect(_shownCode(tester), 'Kd');
      expect(find.text('WILD'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('waits for its own face-up flip when both arrive together', (
      tester,
    ) async {
      Widget card({String? code, String? standIn}) => _host(
        WildTransform(
          height: 120,
          code: code,
          standIn: standIn,
          wild: standIn != null,
          index: 2,
          label: 'Wild',
        ),
      );
      await tester.pumpWidget(card());
      expect(_shownCode(tester), isNull, reason: 'face down');

      // See cards, with the variation already chosen: one snapshot brings both.
      await tester.pumpWidget(card(code: '7h', standIn: 'Ah'));
      await _run(tester, const Duration(milliseconds: 500));
      expect(_shownCode(tester), '7h', reason: 'the real card is shown first');
      expect(find.text('WILD'), findsNothing);

      await _run(tester, const Duration(seconds: 3));
      expect(_shownCode(tester), 'Ah');
      expect(find.text('WILD'), findsOneWidget);
      expect(_realCardTab('7h'), findsOneWidget);
      expect(_tabPip(tester, '7h').suit, 'h');
      expect(_tabPip(tester, '7h').colour, AppTheme.pipRed);
      expect(tester.takeException(), isNull);
    });

    testWidgets('built already knowing, it shows the finished state and does '
        'not replay', (tester) async {
      await tester.pumpWidget(
        _host(
          const WildTransform(
            height: 120,
            code: 'Ks',
            standIn: '9d',
            wild: true,
            index: 1,
            label: 'Wild',
          ),
        ),
      );
      await tester.pump();
      expect(_shownCode(tester), '9d');
      expect(find.text('WILD'), findsOneWidget);
      expect(_realCardTab('Ks'), findsOneWidget);
    });

    testWidgets('does not change the size of the card it stands in for', (
      tester,
    ) async {
      Future<Size> sizeOf({String? standIn}) async {
        await tester.pumpWidget(
          _host(
            WildTransform(
              key: ValueKey(standIn),
              height: 96,
              code: '4s',
              standIn: standIn,
              wild: standIn != null,
              index: 0,
              label: 'Wild',
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        return tester.getSize(find.byType(WildTransform));
      }

      final plain = await sizeOf();
      final turned = await sizeOf(standIn: 'Kd');
      expect(turned, plain, reason: 'the fan must not move when a card turns');
      expect(plain.height, 96);
    });

    testWidgets('a long word for Wild stays inside the card', (tester) async {
      await tester.pumpWidget(
        _host(
          const WildTransform(
            height: 61,
            code: '4s',
            standIn: 'Kd',
            wild: true,
            index: 0,
            label: 'ਵਾਈਲਡ ਕਾਰਡ ਜੋਕਰ',
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      final card = tester.getRect(find.byType(PlayingCard));
      final ribbon = tester.getRect(find.text('ਵਾਈਲਡ ਕਾਰਡ ਜੋਕਰ'));
      expect(ribbon.left, greaterThanOrEqualTo(card.left));
      expect(ribbon.right, lessThanOrEqualTo(card.right));
    });
  });
}
