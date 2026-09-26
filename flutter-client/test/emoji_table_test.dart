// Emojis at the table (owner, 26 Sep 2026: "IN UI add a button of emoji in
// gameplay table, when user click that emoji then that emoji message will
// send to all players just like chat messages").
//
// Laid out and pressed for real, on the Teen Patti felt and the poker felt
// alike: the rail's emoji key under the chat key — a whole target, clear of
// the Shop key above, the corner keys below and the rail's other keys, on
// the tightest phone at the text ceiling in every language — opens the emoji
// page in the table's left drawer, never a route; an owned emoji is sent on
// `chat:emoji` and the drawer goes; the chat's cooldown greys the page and
// the key; a locked emoji shows its price and opens the store on its shelf;
// an empty catalogue says so. An emoji line then plays over its SENDER's
// seat for a few seconds, on every phone, and sits in the chat log as a small
// playing emoji beside the sender's name; a blocked player's does neither.
// The Lotties are tiny inline files primed into the cache: nothing is
// fetched, and the socket is a stand-in that records what is sent.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/buy_chips.dart';
import 'package:teenpatti/widgets/emoji_art.dart';
import 'package:teenpatti/widgets/emoji_shelf.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

import 'script_fonts.dart';

/// A socket that records the emojis sent instead of sending them.
class _Recorder extends GameConnection {
  _Recorder() : super('http://127.0.0.1:9');

  final emojis = <int>[];

  @override
  void sendEmoji(int emojiId) => emojis.add(emojiId);
}

/// Counts what the Navigator pushes, so a page that opened as a route would
/// be seen whatever it was made of.
class _Routes extends NavigatorObserver {
  int pushed = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed++;
  }
}

final Uint8List _lottie = Uint8List.fromList(
  utf8.encode(
    '{"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"e","ddd":0,'
    '"assets":[],"layers":[{"ddd":0,"ind":1,"ty":4,"nm":"d","sr":1,'
    '"ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[50,50,0]},'
    '"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},"ao":0,'
    '"shapes":[{"ty":"gr","nm":"g","it":[{"ty":"el","nm":"c",'
    '"p":{"a":0,"k":[0,0]},"s":{"a":0,"k":[60,60]}},{"ty":"fl","nm":"f",'
    '"c":{"a":0,"k":[1,0.8,0,1]},"o":{"a":0,"k":100}},{"ty":"tr",'
    '"p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},'
    '"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}],"ip":0,"op":30,"st":0,"bm":0}]}',
  ),
);

String _url(int id) => 'https://cdn.test/emojis/$id.json';

EmojiItem _emoji(
  int id,
  String name, {
  String currency = PictureCurrency.diamond,
  String type = 'PREMIUM',
  int cost = 5,
  bool owned = false,
}) => EmojiItem(
  id: id,
  name: name,
  url: _url(id),
  currency: currency,
  type: type,
  cost: cost,
  owned: owned,
);

List<EmojiItem> _emojis() => [
  _emoji(1, 'Wave', type: 'FREE', cost: 0, owned: true),
  _emoji(2, 'Laughing', owned: true),
  _emoji(3, 'Crying With Laughter', owned: true),
  _emoji(4, 'Heart Eyes', currency: PictureCurrency.coin, cost: 1000000000),
  _emoji(5, 'Party Popper', currency: PictureCurrency.hammer, cost: 30),
];

Map<String, dynamic> _seat(int index) => {
  'seatIndex': index,
  'userId': 'u$index',
  'displayName': 'Player $index',
  'chips': 12500000,
  'status': 'active',
  'isBlind': false,
  'lastBet': 1600,
  'lastAction': 'raise',
  'contributed': 5800,
  'connected': true,
  'cardCount': 3,
};

/// A full Teen Patti table, the viewer (u0) at seat 0.
RoomState _teenPatti() => RoomState.fromJson({
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
  'pot': 29000,
  'maxPot': 2000000,
  'stake': 800,
  'you': {
    'seatIndex': 0,
    'chips': 12500000,
    'status': 'active',
    'isBlind': false,
    'contributed': 5800,
    'missedTurns': 0,
    'maxMissedTurns': 3,
    'cards': ['As', 'Kd', 'Qh'],
  },
  'seats': [for (var i = 0; i < 5; i++) _seat(i)],
});

/// A Texas Hold'em room, the viewer (u0) at seat 0.
RoomState _poker() => RoomState.fromJson({
  'roomId': 'p1',
  'code': 'ABCD2345',
  'category': 'texas_holdem',
  'game': 'poker',
  'chipsHidden': true,
  'state': 'betting',
  'handNo': 3,
  'dealerSeat': 1,
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 50000,
  'turnTimeoutMs': 25000,
  'pot': 75000,
  'turn': {
    'seatIndex': 1,
    'userId': 'u1',
    'deadline': DateTime.now().millisecondsSinceEpoch + 25000,
  },
  'you': {
    'seatIndex': 0,
    'chips': 2000000,
    'status': 'active',
    'cards': const <String>[],
    'missedTurns': 0,
    'maxMissedTurns': 3,
  },
  'seats': [
    for (var i = 0; i < 5; i++)
      {
        'seatIndex': i,
        'userId': 'u$i',
        'displayName': 'Player $i',
        'chips': i == 0 ? 2000000 : null,
        'status': 'active',
        'connected': true,
        'cardCount': 2,
      },
  ],
  'poker': {
    'variant': 'texas_holdem',
    'street': 'preflop',
    'community': const <String>[],
    'pots': const <Map<String, dynamic>>[],
    'smallBlind': 25000,
    'bigBlind': 50000,
    'ante': 0,
    'holeCards': 2,
    'maxDiscards': 0,
    'minBuyIn': 500000,
  },
});

GameState _state(
  RoomState room, {
  AppLang lang = AppLang.english,
  _Recorder? socket,
  List<EmojiItem>? emojis,
}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9', connection: socket);
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..emojis = emojis ?? _emojis()
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Player 0',
      'chips': 12500000,
      'diamond': 9,
      'hammer': 45,
      'missile': 1,
    })
    ..screen = Screen.table
    ..handleState(room);
}

Future<_Routes> _pump(
  WidgetTester tester,
  GameState state, {
  Size size = const Size(640, 360),
  double scale = 1.25,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  final routes = _Routes();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withScriptFallback(AppTheme.dark(sound: false)),
        navigatorObservers: [routes],
        // As main.dart builds the app: the blur budget and the transparent
        // Scaffold round the Navigator, which is the Material every route
        // pushed over the table — the store — stands on.
        builder: (context, child) => GlassBudget(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: child,
          ),
        ),
        home: const TableScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(seconds: 1));
  return routes;
}

Future<void> _teardown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

final _emojiKey = find.byKey(const ValueKey('rail-emoji'));

Future<void> _openEmojiPage(WidgetTester tester) async {
  await tester.tap(_emojiKey);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// The pod of the player [userId], and what hangs off it.
Finder _podOf(String userId) =>
    find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId);

Finder _seatEmoji(String userId) => find.descendant(
  of: _podOf(userId),
  matching: find.byKey(const ValueKey('seat-emoji')),
);

ChatMessage _emojiLine(String userId, String name, int id) =>
    ChatMessage.fromJson({
      'id': '$userId-$id',
      'userId': userId,
      'displayName': name,
      'text': 'Laughing',
      'at': 1790000000000,
      'emoji': {
        'id': id,
        'name': 'Laughing',
        'url': _url(id),
        'assetFormat': 'LOTTIE',
      },
    });

void main() {
  setUpAll(() async {
    await loadScriptFonts();
    for (final e in _emojis()) {
      PictureCache.prime(_url(e.id), _lottie);
    }
  });
  tearDownAll(PictureCache.clearMemory);

  final felts = {'Teen Patti': _teenPatti, 'poker': _poker};

  for (final MapEntry(key: felt, value: room) in felts.entries) {
    group('the $felt felt', () {
      // The key is a whole target, under the chat key, clear of everything
      // else on the left of the screen — at every phone the game is checked
      // on, and in every language at the tightest one.
      final screens = <(Size, double, AppLang)>[
        for (final lang in AppLang.values) (const Size(640, 360), 1.25, lang),
        (const Size(640, 360), 1.0, AppLang.english),
        (const Size(592, 360), 1.25, AppLang.english),
        (const Size(732, 412), 1.25, AppLang.english),
        (const Size(891, 411), 1.25, AppLang.english),
        (const Size(915, 412), 1.0, AppLang.english),
        (const Size(1280, 800), 1.0, AppLang.english),
      ];
      for (final (size, scale, lang) in screens) {
        testWidgets('at ${size.width.toInt()}x${size.height.toInt()}, text '
            'x$scale, ${lang.englishName}: the emoji key stands under the '
            'chat key, clear of every other key', (tester) async {
          final state = _state(room(), lang: lang);
          await _pump(tester, state, size: size, scale: scale);
          expect(tester.takeException(), isNull);

          final t = Strings(lang);
          expect(_emojiKey, findsOneWidget);
          final key = tester.getRect(_emojiKey);
          expect(key.width, greaterThanOrEqualTo(44));
          expect(key.height, greaterThanOrEqualTo(44));
          // On the screen.
          expect(key.top, greaterThanOrEqualTo(0));
          expect(key.bottom, lessThanOrEqualTo(size.height));

          // Under the chat key, in the rail's column.
          final chat = tester.getRect(
            find.ancestor(
              of: find.byTooltip(t.tableChat),
              matching: find.byType(RailKey),
            ),
          );
          expect(key.top, greaterThan(chat.bottom));
          expect(key.left, closeTo(chat.left, 0.5));

          // Clear of the rail's other keys, the Shop key, and every
          // machined key — the corner's Missile and Pack, or Fold.
          final others = <Rect>[
            for (final e in find.byType(RailKey).evaluate())
              if (e.widget.key != const ValueKey('rail-emoji'))
                tester.getRect(find.byElementPredicate((x) => x == e)),
            tester.getRect(find.byType(ShopButton)),
            for (final e in find.byType(MachinedKey).evaluate())
              tester.getRect(find.byElementPredicate((x) => x == e)),
          ];
          for (final other in others) {
            expect(
              key.overlaps(other),
              isFalse,
              reason: 'the emoji key $key overlaps $other',
            );
          }
          // And the whole rail stands clear of the corner keys below it.
          for (final rail in find.byType(RailKey).evaluate()) {
            final r = tester.getRect(find.byElementPredicate((x) => x == rail));
            for (final e in find.byType(MachinedKey).evaluate()) {
              final m = tester.getRect(find.byElementPredicate((x) => x == e));
              expect(r.overlaps(m), isFalse, reason: '$r overlaps $m');
            }
            expect(
              r.overlaps(tester.getRect(find.byType(ShopButton))),
              isFalse,
            );
          }

          await _teardown(tester, state);
        });
      }

      testWidgets('the key opens the emoji page in the drawer, never a route', (
        tester,
      ) async {
        final state = _state(room());
        final routes = await _pump(tester, state);
        final before = routes.pushed;
        expect(find.byType(EmojiDrawer), findsNothing);

        await _openEmojiPage(tester);
        expect(find.byType(EmojiDrawer), findsOneWidget);
        expect(routes.pushed, before, reason: 'a drawer page, not a route');
        expect(find.byType(ChatDrawer), findsNothing);
        expect(tester.takeException(), isNull);

        // Owned emojis to send, playing; the rest with their price.
        for (final id in [1, 2, 3]) {
          final tile = find.byKey(ValueKey('emoji-send-$id'));
          expect(tile, findsOneWidget, reason: '$id');
          final art = find.descendant(of: tile, matching: find.byType(Lottie));
          expect(art, findsOneWidget, reason: '$id');
          expect(tester.widget<Lottie>(art).animate, isTrue);
        }
        for (final id in [4, 5]) {
          final tile = find.byKey(ValueKey('emoji-locked-$id'));
          expect(tile, findsOneWidget, reason: '$id');
          expect(
            find.descendant(of: tile, matching: find.byType(PriceTag)),
            findsOneWidget,
          );
        }

        await _teardown(tester, state);
      });

      testWidgets('an owned emoji is sent on chat:emoji and the drawer goes; '
          'the cooldown then greys the page and the key', (tester) async {
        final socket = _Recorder();
        final state = _state(room(), socket: socket);
        await _pump(tester, state);
        await _openEmojiPage(tester);

        await tester.tap(find.byKey(const ValueKey('emoji-send-2')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(socket.emojis, [2]);
        expect(find.byType(EmojiDrawer), findsNothing);
        expect(state.canChat, isFalse);

        // The key counts the shared wait down.
        expect(
          find.descendant(of: _emojiKey, matching: find.byType(ChatCountdown)),
          findsOneWidget,
        );
        // And the page, reopened within it, sends nothing.
        await _openEmojiPage(tester);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('emoji-send-1')),
            matching: find.byType(ChatCountdown),
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('emoji-send-1')));
        await tester.pump();
        expect(socket.emojis, [2]);
        expect(find.byType(EmojiDrawer), findsOneWidget);
        // (The wait itself is the chat's, read off the wall clock, which a
        // widget test's fake clock does not move; emoji_state_test.dart pins
        // that an emoji and a line share it.)

        await tester.pump(GameState.chatCooldown);
        await _teardown(tester, state);
      });

      testWidgets('a locked emoji opens the store on the Emojis shelf', (
        tester,
      ) async {
        final state = _state(room());
        await _pump(tester, state);
        await _openEmojiPage(tester);

        // Below the player's own on the page, a scroll away on a phone.
        await tester.ensureVisible(
          find.byKey(const ValueKey('emoji-locked-5')),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.byKey(const ValueKey('emoji-locked-5')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(find.byType(EmojiChoice), findsNWidgets(_emojis().length));
        expect(find.text(state.t.storeEmojisBlurb), findsOneWidget);
        expect(tester.takeException(), isNull);

        await _teardown(tester, state);
      });

      testWidgets('an empty catalogue says there are no emojis yet', (
        tester,
      ) async {
        final state = _state(room(), emojis: const []);
        await _pump(tester, state);
        await _openEmojiPage(tester);
        expect(find.byKey(const ValueKey('emoji-page-empty')), findsOneWidget);
        expect(find.text(state.t.emojiShelfEmpty), findsOneWidget);
        await _teardown(tester, state);
      });

      testWidgets('an emoji plays over its sender\'s seat, then goes', (
        tester,
      ) async {
        final state = _state(room());
        await _pump(tester, state);
        expect(_seatEmoji('u2'), findsNothing);

        state.handleChat(_emojiLine('u2', 'Player 2', 3));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(_seatEmoji('u2'), findsOneWidget);
        // Nobody else's seat.
        for (final other in ['u0', 'u1', 'u3', 'u4']) {
          expect(_seatEmoji(other), findsNothing, reason: other);
        }
        // Playing, from the cache.
        final lottie = find.descendant(
          of: _seatEmoji('u2'),
          matching: find.byType(Lottie),
        );
        expect(lottie, findsOneWidget);
        expect(tester.widget<Lottie>(lottie).animate, isTrue);
        // Hung off that seat: its middle within the seat's pod's reach.
        final pod = tester.getRect(_podOf('u2'));
        final bubble = tester.getRect(_seatEmoji('u2'));
        expect(bubble.center.dx, inInclusiveRange(pod.left, pod.right));

        await tester.pump(GameState.emojiBubbleFor);
        await tester.pump(const Duration(milliseconds: 300));
        expect(_seatEmoji('u2'), findsNothing);
        expect(tester.takeException(), isNull);
        await _teardown(tester, state);
      });

      testWidgets("the viewer's own emoji plays over their own seat", (
        tester,
      ) async {
        final state = _state(room());
        await _pump(tester, state);
        state.handleChat(_emojiLine('u0', 'Player 0', 1));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(_seatEmoji('u0'), findsOneWidget);
        await tester.pump(GameState.emojiBubbleFor);
        await _teardown(tester, state);
      });

      testWidgets('the chat log shows an emoji line as the emoji beside the '
          "sender's name", (tester) async {
        final state = _state(room());
        await _pump(tester, state);
        state.handleChat(_emojiLine('u2', 'Player 2', 3));
        await tester.pump();
        await tester.tap(find.byTooltip(state.t.tableChat).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(find.byType(ChatDrawer), findsOneWidget);
        final art = find.descendant(
          of: find.byType(ChatDrawer),
          matching: find.byKey(const ValueKey('chat-emoji')),
        );
        expect(art, findsOneWidget);
        expect(tester.widget<EmojiArt>(art).url, _url(3));
        expect(tester.widget<EmojiArt>(art).size, ChatDrawer.chatEmojiSize);
        expect(
          find.descendant(of: art, matching: find.byType(Lottie)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(ChatDrawer),
            matching: find.text('Player 2:'),
          ),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel(state.t.emojiSentBy('Player 2', 'Laughing')),
          findsOneWidget,
        );
        await tester.pump(GameState.emojiBubbleFor);
        await _teardown(tester, state);
      });

      testWidgets("a blocked player's emoji is shown nowhere", (tester) async {
        final state = _state(room())..blockPlayer('u2');
        await _pump(tester, state);
        state.handleChat(_emojiLine('u2', 'Player 2', 3));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(_seatEmoji('u2'), findsNothing);

        await tester.tap(find.byTooltip(state.t.tableChat).first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(const ValueKey('chat-emoji')), findsNothing);
        await _teardown(tester, state);
      });
    });
  }

  // The page itself, open, at the tightest phone and the text ceiling in all
  // five languages: no overflow, every word inside its tile, and every tile a
  // whole target.
  for (final lang in AppLang.values) {
    testWidgets('the emoji page fits 640x360 at text x1.25 in '
        '${lang.englishName}', (tester) async {
      if (!haveScriptFonts()) {
        markTestSkipped('the Noto script fonts are not installed');
        return;
      }
      final state = _state(_teenPatti(), lang: lang);
      await _pump(tester, state);
      await _openEmojiPage(tester);
      expect(tester.takeException(), isNull);

      final drawer = tester.getRect(find.byType(EmojiDrawer));
      for (final text
          in find
              .descendant(
                of: find.byType(EmojiDrawer),
                matching: find.byType(RichText),
              )
              .evaluate()) {
        final paragraph = text.renderObject! as RenderParagraph;
        final r = tester.getRect(find.byElementPredicate((e) => e == text));
        final words = paragraph.text.toPlainText();
        expect(
          r.left >= drawer.left - 0.5 && r.right <= drawer.right + 0.5,
          isTrue,
          reason: '${lang.code}: "$words" leaves the drawer',
        );
        // The hint and the headings wrap; a tile's name is one line, cut
        // with an ellipsis where it must be.
        if (!paragraph.text.toPlainText().contains('Laughter')) {
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: '${lang.code}: "$words" is cut',
          );
        }
      }
      for (final id in [1, 2, 3]) {
        final tile = tester.getRect(find.byKey(ValueKey('emoji-send-$id')));
        expect(tile.width, greaterThanOrEqualTo(44));
        expect(tile.height, greaterThanOrEqualTo(44));
        expect(tile.right, lessThanOrEqualTo(drawer.right));
      }
      await _teardown(tester, state);
    });
  }
}
