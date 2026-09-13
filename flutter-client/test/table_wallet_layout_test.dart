// Where the table's two new pieces stand (owner, 13 Sep 2026): the diamonds
// and hammers pill in the top-right corner, and the Force Sideshow key at the
// top of the key cluster.
//
// Laid out for real rather than reasoned about: the whole TableScreen is
// pumped around a full table — five seated players who have all bet, seen
// cards on a seen table, which is the tallest a seat's column gets without a
// showdown — at the three screens the game is checked on, and at the 1.25 text
// ceiling as well as the normal scale. Inter is loaded, so text is measured in
// the face the phone draws, not the test font's square glyphs.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/playing_card.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

Map<String, dynamic> _seat(int index) => {
  'seatIndex': index,
  'userId': 'u$index',
  'displayName': 'Player $index',
  'avatarUrl': null,
  'chips': 12500000,
  'status': 'active',
  'isBlind': false,
  'lastBet': 1600,
  'lastAction': 'raise',
  'contributed': 5800,
  'connected': true,
  'cardCount': 3,
};

RoomState _fullTable() => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCD2345',
  'category': 'seen',
  'chipsHidden': false,
  'state': 'betting',
  'handNo': 4,
  'dealerSeat': 2,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'startsAt': 0,
  'pot': 29000,
  'maxPot': 2000000,
  'stake': 800,
  'you': {
    'seatIndex': 0,
    'chips': 12500000,
    'status': 'active',
    'isBlind': false,
    'blindMovesLeft': 0,
    'contributed': 5800,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': ['As', 'Kd', 'Qh'],
  },
  'seats': [for (var i = 0; i < 5; i++) _seat(i)],
});

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

void main() {
  setUpAll(_loadInter);

  const screens = [Size(640, 360), Size(891, 411), Size(1280, 800)];
  for (final screen in screens) {
    for (final scale in [1.0, 1.25]) {
      final name = '${screen.width.toInt()}x${screen.height.toInt()}';
      testWidgets(
        'at $name, text x$scale, the wallet and the force key clear the table',
        (tester) async {
          tester.view.physicalSize = screen;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

          // Play is never started here; the override only keeps the purchase
          // plugin from registering an Android billing client in a unit test.
          debugDefaultTargetPlatformOverride = TargetPlatform.linux;
          final state = GameState(serverUrl: 'http://127.0.0.1:9');
          debugDefaultTargetPlatformOverride = null;
          final feedback = FeedbackSettings();
          addTearDown(feedback.dispose);

          // The widest counts a player is likely to hold.
          state
            ..user = User.fromJson({
              'id': 'u0',
              'provider': 'guest',
              'displayName': 'Player 0',
              'chips': 12500000,
              'diamond': 100,
              'hammer': 250,
            })
            ..room = _fullTable()
            ..screen = Screen.table;

          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<GameState>.value(value: state),
                ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
              ],
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: AppTheme.dark(sound: false),
                builder: (context, child) => GlassBudget(child: child!),
                home: const TableScreen(),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 50));

          final wallet = tester.getRect(find.byType(WalletPill));
          final force = tester.getRect(find.byTooltip('Force Sideshow'));
          final failures = <String>[];
          void clears(String label, Rect rect, String what, Rect other) {
            if (rect.overlaps(other)) {
              failures.add('the $label $rect runs into $what $other');
            }
          }

          final whole = Offset.zero & screen;
          for (final (label, rect) in [
            ('wallet', wallet),
            ('force key', force),
          ]) {
            if (whole.intersect(rect) != rect) {
              failures.add('the $label $rect is not wholly on the screen');
            }
          }

          final seatFinder = find.byType(SeatPod);
          final seats = <Rect>[
            for (var i = 0; i < seatFinder.evaluate().length; i++)
              tester.getRect(seatFinder.at(i)),
          ];
          expect(seats, hasLength(5));

          // What the viewer's hand paints: its cards, not the column round them.
          final cardFinder = find.descendant(
            of: _private('_OwnHand'),
            matching: find.byType(PlayingCard),
          );
          var cards = tester.getRect(cardFinder.first);
          for (var i = 1; i < cardFinder.evaluate().length; i++) {
            cards = cards.expandToInclude(tester.getRect(cardFinder.at(i)));
          }

          <String, Rect>{
            for (final (i, seat) in seats.indexed) 'seat $i': seat,
            'Shop key': tester.getRect(find.byType(ShopButton)),
            'side rail': tester.getRect(_private('_SideRail')),
            'category tag': tester.getRect(_private('_CategoryTag')),
            'key cluster': tester.getRect(_private('_ActionCluster')),
            'notices': tableNoticeArea(
              tester.element(find.byType(TableScreen)),
            ),
          }.forEach((what, rect) => clears('wallet', wallet, what, rect));

          <String, Rect>{
            for (final (i, seat) in seats.indexed) 'seat $i': seat,
            "viewer's cards": cards,
            "viewer's bet": tester.getRect(find.byType(SeatBet).last),
            'pot': tester.getRect(_private('_Pot')),
            'pack key': tester.getRect(_private('_PackKey')),
            'wallet': wallet,
          }.forEach((what, rect) => clears('force key', force, what, rect));

          // The force key and the − Chaal + row make one block: the top row
          // ends where the bottom one does.
          final plus = tester.getRect(
            find.ancestor(
              of: find.byIcon(Icons.add_rounded),
              matching: find.byType(IconButton),
            ),
          );
          final sideshow = tester.getRect(
            find.ancestor(
              of: find.byIcon(Icons.compare_arrows_rounded),
              matching: find.byType(FilledButton),
            ),
          );
          final hand = tester.getRect(_private('_OwnHand'));

          await tester.pumpWidget(const SizedBox.shrink());
          // Staggered starts scheduled while the table was up (Future.delayed
          // cannot be cancelled) fire into unmounted widgets and do nothing.
          await tester.pump(const Duration(seconds: 10));
          state.dispose();

          expect(
            failures,
            isEmpty,
            reason:
                '$name x$scale\n${failures.join('\n')}\n'
                '(hand column $hand, cards $cards, plus $plus, force $force, '
                'sideshow $sideshow)',
          );
        },
      );
    }
  }
}
