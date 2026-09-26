// The emoji store's wire and state (owner, 26 Sep 2026: "add a feature of
// buying emoji which will be type of LOTTIE animation … when user click that
// emoji then that emoji message will send to all players just like chat
// messages").
//
// What is pinned here, without a screen: the catalogue row and the chat
// line as the server sends them (docs: the shared emoji contract); the two
// REST calls; sending an emoji over the socket, sharing the chat's cooldown;
// an emoji line playing over its sender's seat for a few seconds and then
// going, queued like a line of words; a blocked player's emoji dropped; and
// every emoji refusal said in the player's language. The screens — the store
// shelf, the rail key, the drawer page, the seat and the chat log — are in
// emoji_store_test.dart and emoji_table_test.dart.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/net/game_connection.dart';
import 'package:teenpatti/state/game_state.dart';

/// A socket that records the emojis and lines sent instead of sending them.
class _Recorder extends GameConnection {
  _Recorder() : super('http://127.0.0.1:9');

  final emojis = <int>[];
  final lines = <String>[];

  @override
  void sendEmoji(int emojiId) => emojis.add(emojiId);

  @override
  void sendChat(String text) => lines.add(text);
}

GameState _state({_Recorder? socket, AppLang lang = AppLang.english}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://api.test', connection: socket);
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..user = User.fromJson(_user());
}

Map<String, dynamic> _user({int diamond = 5, int hammer = 20}) => {
  'id': 'me',
  'provider': 'guest',
  'displayName': 'You',
  'chips': 500000,
  'diamond': diamond,
  'hammer': hammer,
};

/// A catalogue row as `GET /api/emojis` sends it.
Map<String, dynamic> _row(
  int id, {
  String name = 'Laughing',
  String currency = 'DIAMOND',
  String type = 'PREMIUM',
  int cost = 5,
  int days = 0,
  int hours = 0,
  bool owned = false,
  int expiresAt = 0,
}) => {
  'id': id,
  'name': name,
  'url': 'https://cdn.test/emojis/$id.json',
  'assetFormat': 'LOTTIE',
  'currency': currency,
  'type': type,
  'cost': cost,
  'durationDays': days,
  'durationHours': hours,
  'sortOrder': 10 * id,
  'owned': owned,
  'expiresAt': expiresAt,
};

/// An emoji line as the room hears it: the ordinary chat:message with an
/// `emoji` key — and the emoji's name as its text.
ChatMessage _emojiLine(String userId, String name, {int id = 3}) =>
    ChatMessage.fromJson({
      'id': '$userId-$id',
      'userId': userId,
      'displayName': name,
      'text': 'Laughing',
      'at': 1790000000000,
      'emoji': {
        'id': id,
        'name': 'Laughing',
        'url': 'https://cdn.test/emojis/$id.json',
        'assetFormat': 'LOTTIE',
      },
    });

ChatMessage _line(String userId, String name, String text) =>
    ChatMessage.fromJson({
      'userId': userId,
      'displayName': name,
      'text': text,
      'at': 1790000000000,
    });

void main() {
  group('the wire', () {
    test('a catalogue row reads every field the contract names', () {
      final e = EmojiItem.fromJson(
        _row(3, days: 7, hours: 2, owned: true, expiresAt: 99),
      );
      expect(e.id, 3);
      expect(e.name, 'Laughing');
      expect(e.url, 'https://cdn.test/emojis/3.json');
      expect(e.assetFormat, 'LOTTIE');
      expect(e.currency, 'DIAMOND');
      expect(e.type, 'PREMIUM');
      expect(e.cost, 5);
      expect(e.durationDays, 7);
      expect(e.durationHours, 2);
      expect(e.sortOrder, 30);
      expect(e.owned, isTrue);
      expect(e.expiresAt, 99);
      expect(e.free, isFalse);
      expect(e.locked, isFalse);
      expect(e.rented, isTrue);
      expect(e.pricedInDiamonds, isTrue);
      expect(e.pricedInHammers, isFalse);
    });

    test('a sparse row reads as a free LOTTIE priced in chips, not owned', () {
      final e = EmojiItem.fromJson({'id': 1, 'name': 'Wave', 'url': '/x.json'});
      expect(e.assetFormat, 'LOTTIE');
      expect(e.currency, 'COIN');
      expect(e.type, 'FREE');
      expect(e.cost, 0);
      expect(e.rented, isFalse);
      // Absent is "the server did not say", which is not a yes.
      expect(e.owned, isFalse);
      expect(e.locked, isTrue);
    });

    test('a chat line with an emoji carries it, and its name as the text', () {
      final m = _emojiLine('u1', 'Ravi');
      expect(m.isEmoji, isTrue);
      expect(m.text, 'Laughing');
      expect(m.emoji!.id, 3);
      expect(m.emoji!.name, 'Laughing');
      expect(m.emoji!.url, 'https://cdn.test/emojis/3.json');
      expect(m.emoji!.assetFormat, 'LOTTIE');
    });

    test('a plain line has no emoji — absent, null or not an object', () {
      expect(_line('u1', 'Ravi', 'hi').emoji, isNull);
      for (final raw in [null, 'Laughing', 3, <Object>[]]) {
        final m = ChatMessage.fromJson({
          'userId': 'u1',
          'displayName': 'Ravi',
          'text': 'hi',
          'at': 0,
          'emoji': raw,
        });
        expect(m.emoji, isNull, reason: '$raw');
        expect(m.isEmoji, isFalse);
      }
    });

    test('an emoji with no file to play is shown as its words', () {
      final m = ChatMessage.fromJson({
        'userId': 'u1',
        'displayName': 'Ravi',
        'text': 'Laughing',
        'at': 0,
        'emoji': {'id': 3, 'name': 'Laughing', 'url': ''},
      });
      expect(m.emoji, isNull);
      expect(m.text, 'Laughing');
    });
  });

  group('REST', () {
    test('GET /api/emojis sends the token and reads the rows', () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'emojis': [_row(3), _row(4, type: 'FREE', cost: 0, owned: true)],
          }),
          200,
        );
      });
      final rows = await http.runWithClient(
        () => ApiClient('http://api.test').emojis(token: 'tok'),
        () => client,
      );
      expect(sent.method, 'GET');
      expect(sent.url.toString(), 'http://api.test/api/emojis');
      expect(sent.headers['Authorization'], 'Bearer tok');
      expect(rows.map((e) => e.id), [3, 4]);
      expect(rows.last.owned, isTrue);
    });

    test('GET /api/emojis without a token is anonymous', () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response(jsonEncode({'emojis': <Object>[]}), 200);
      });
      await http.runWithClient(
        () => ApiClient('http://api.test').emojis(),
        () => client,
      );
      expect(sent.headers.containsKey('Authorization'), isFalse);
    });

    test(
      'a server that predates emojis (404) has an empty catalogue',
      () async {
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({'error': 'not_found', 'message': 'Not found'}),
            404,
          ),
        );
        final rows = await http.runWithClient(
          () => ApiClient('http://api.test').emojis(token: 'tok'),
          () => client,
        );
        expect(rows, isEmpty);
      },
    );

    test('POST /api/emojis/buy sends the id and reads the answer', () async {
      late http.Request sent;
      final client = MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'user': _user(diamond: 0),
            'emoji': _row(3, owned: true),
            'charged': true,
            'spent': 5,
          }),
          200,
        );
      });
      final r = await http.runWithClient(
        () => ApiClient('http://api.test').buyEmoji('tok', 3),
        () => client,
      );
      expect(sent.method, 'POST');
      expect(sent.url.toString(), 'http://api.test/api/emojis/buy');
      expect(sent.headers['Authorization'], 'Bearer tok');
      expect(jsonDecode(sent.body), {'emojiId': 3});
      expect(r.charged, isTrue);
      expect(r.spent, 5);
      expect(r.user.diamond, 0);
      expect(r.emoji!.owned, isTrue);
    });

    for (final (status, code) in [
      (400, 'unknown_emoji'),
      (400, 'emoji_retired'),
      (400, 'emoji_free'),
      (409, 'emoji_unaffordable'),
      (409, 'seated'),
    ]) {
      test('a $status $code refusal carries its code', () async {
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({'error': code, 'message': 'Refused'}),
            status,
          ),
        );
        await expectLater(
          http.runWithClient(
            () => ApiClient('http://api.test').buyEmoji('tok', 3),
            () => client,
          ),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.status, 'status', status),
          ),
        );
      });
    }
  });

  group('GameState', () {
    test('the catalogue is read with the token, and warmed', () async {
      final seen = <String?>[];
      final client = MockClient((request) async {
        seen.add(request.headers['Authorization']);
        return http.Response(
          jsonEncode({
            'emojis': [_row(3, owned: true)],
          }),
          200,
        );
      });
      final state = _state()..debugToken = 'tok';
      await http.runWithClient(state.reloadEmojis, () => client);
      expect(seen, ['Bearer tok']);
      expect(state.emojis.single.owned, isTrue);
      state.dispose();
    });

    test('buying re-reads the catalogue, so the padlock goes', () async {
      final calls = <String>[];
      var bought = false;
      final client = MockClient((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/api/emojis/buy') {
          bought = true;
          return http.Response(
            jsonEncode({
              'user': _user(diamond: 0),
              'emoji': _row(3, owned: true),
              'charged': true,
              'spent': 5,
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'emojis': [_row(3, owned: bought)],
          }),
          200,
        );
      });
      final state = _state()
        ..debugToken = 'tok'
        ..emojis = [EmojiItem.fromJson(_row(3))];
      final result = await http.runWithClient(
        () => state.buyEmoji(3),
        () => client,
      );
      expect(result, PictureBuyResult.bought);
      expect(calls, ['POST /api/emojis/buy', 'GET /api/emojis']);
      expect(state.emojis.single.owned, isTrue);
      expect(state.user!.diamond, 0);
      expect(state.buyingEmoji, isNull);
      state.dispose();
    });

    test('a hammer or diamond shortage is the offer of that shelf', () {
      final state = _state()
        ..emojis = [
          EmojiItem.fromJson(_row(3)),
          EmojiItem.fromJson(_row(4, currency: 'HAMMER', cost: 30)),
          EmojiItem.fromJson(_row(5, currency: 'COIN', cost: 100000)),
        ];
      final short = ApiException(
        'You need 5 diamonds to unlock this emoji.',
        code: 'emoji_unaffordable',
        status: 409,
      );
      expect(state.emojiRefused(3, short), PictureBuyResult.notEnough);
      expect(state.emojiRefused(4, short), PictureBuyResult.notEnough);
      expect(state.notice, isNull, reason: 'the offer says it, not a toast');
      // Chips are no shelf's to refill: said, in the player's language.
      expect(state.emojiRefused(5, short), PictureBuyResult.refused);
      expect(state.notice, state.t.emojiUnaffordableRefusal);
      state.dispose();
    });

    test('a chip-priced emoji refused at a table says lobby only', () {
      final state = _state(lang: AppLang.hindi)
        ..emojis = [EmojiItem.fromJson(_row(5, currency: 'COIN', cost: 9))];
      final r = state.emojiRefused(
        5,
        ApiException(
          'You can only buy a chip-priced emoji in the lobby.',
          code: 'seated',
          status: 409,
        ),
      );
      expect(r, PictureBuyResult.refused);
      expect(state.notice, const Strings(AppLang.hindi).emojiChipsLobbyOnly);
      state.dispose();
    });

    for (final lang in AppLang.values) {
      test('every emoji refusal is said in ${lang.englishName}', () {
        final state = _state(lang: lang);
        final t = Strings(lang);
        for (final (code, words) in [
          ('emoji_locked', t.emojiLockedRefusal),
          ('unknown_emoji', t.emojiUnknownRefusal),
          ('emoji_retired', t.emojiRetiredRefusal),
          ('emoji_unaffordable', t.emojiUnaffordableRefusal),
        ]) {
          expect(state.refusalText(code, 'English'), words, reason: code);
          expect(words.trim(), isNotEmpty);
        }
        state.dispose();
      });
    }
  });

  group('sending', () {
    test('an emoji goes out on chat:emoji and starts the chat cooldown', () {
      final socket = _Recorder();
      final state = _state(socket: socket);
      expect(state.canChat, isTrue);
      expect(state.sendEmoji(3), isTrue);
      expect(socket.emojis, [3]);
      // One wait for both: an emoji is a chat line.
      expect(state.canChat, isFalse);
      expect(state.chatCooldownLeft, greaterThan(0));
      expect(state.sendEmoji(4), isFalse);
      expect(state.sendChat('hello'), isFalse);
      expect(socket.emojis, [3]);
      expect(socket.lines, isEmpty);
      state.dispose();
    });

    test('a chat line holds an emoji back too', () {
      final socket = _Recorder();
      final state = _state(socket: socket);
      expect(state.sendChat('hello'), isTrue);
      expect(state.sendEmoji(3), isFalse);
      expect(socket.emojis, isEmpty);
      state.dispose();
    });

    test('offline, nothing is sent and the cooldown does not start', () {
      final socket = _Recorder();
      final state = _state(socket: socket)..offline = true;
      expect(state.sendEmoji(3), isFalse);
      expect(socket.emojis, isEmpty);
      expect(state.canChat, isTrue);
      expect(state.notice, state.t.notConnected);
      state.dispose();
    });
  });

  group('receiving', () {
    testWidgets('an emoji plays over its sender for four seconds, then goes', (
      tester,
    ) async {
      final state = _state();
      state.handleChat(_emojiLine('u1', 'Ravi'));
      expect(state.emojiOver('u1')?.id, 3);
      // It is a chat line: in the log, and unread.
      expect(state.chat.single.isEmoji, isTrue);
      expect(state.unreadChat, 1);
      // Not a line of words over the seat.
      expect(state.saidRecently, isEmpty);

      await tester.pump(
        GameState.emojiBubbleFor - const Duration(milliseconds: 100),
      );
      expect(state.emojiOver('u1'), isNotNull);
      await tester.pump(const Duration(milliseconds: 200));
      expect(state.emojiOver('u1'), isNull);
      // The line stays in the log.
      expect(state.chat, hasLength(1));
      state.dispose();
    });

    testWidgets('a second emoji waits for the first, the newest only', (
      tester,
    ) async {
      final state = _state();
      state.handleChat(_emojiLine('u1', 'Ravi', id: 3));
      state.handleChat(_emojiLine('u1', 'Ravi', id: 4));
      state.handleChat(_emojiLine('u1', 'Ravi', id: 5));
      expect(state.emojiOver('u1')?.id, 3);
      await tester.pump(GameState.emojiBubbleFor);
      expect(state.emojiOver('u1')?.id, 5);
      await tester.pump(GameState.emojiBubbleFor);
      expect(state.emojiOver('u1'), isNull);
      state.dispose();
    });

    testWidgets("the sender's own emoji plays over their own seat", (
      tester,
    ) async {
      final state = _state();
      state.handleChat(_emojiLine('me', 'You'));
      expect(state.emojiOver('me'), isNotNull);
      expect(state.unreadChat, 0, reason: 'your own line is never unread');
      await tester.pump(GameState.emojiBubbleFor);
      state.dispose();
    });

    testWidgets('a blocked player\'s emoji is dropped, and blocking takes '
        'one off the felt', (tester) async {
      final state = _state()..blockPlayer('u2');
      state.handleChat(_emojiLine('u2', 'Meera'));
      expect(state.emojiOver('u2'), isNull);
      expect(state.chat, isEmpty);
      expect(state.unreadChat, 0);

      state.handleChat(_emojiLine('u1', 'Ravi'));
      expect(state.emojiOver('u1'), isNotNull);
      state.blockPlayer('u1');
      expect(state.emojiOver('u1'), isNull);
      expect(state.chat, isEmpty);
      await tester.pump(GameState.emojiBubbleFor);
      state.dispose();
    });

    testWidgets('a line of words still bubbles as it did', (tester) async {
      final state = _state();
      state.handleChat(_line('u1', 'Ravi', 'good hand'));
      expect(state.saidRecently['u1']?.text, 'good hand');
      expect(state.emojiOver('u1'), isNull);
      await tester.pump(GameState.bubbleFor);
      expect(state.saidRecently, isEmpty);
      state.dispose();
    });
  });

  group('the strings', () {
    const keys = [
      'storeTabEmojis',
      'storeEmojisTitle',
      'storeEmojisBlurb',
      'emojiShelfEmpty',
      'unlockEmojiTitle',
      'unlockEmojiBody',
      'unlockEmojiRentBody',
      'emojiChipsLobbyOnly',
      'emojiOwnedNote',
      'tableEmojis',
      'emojiSendHint',
      'emojiUnlockMore',
      'emojiNoneOwned',
      'emojiSentBy',
      'emojiLockedRefusal',
      'emojiUnknownRefusal',
      'emojiRetiredRefusal',
      'emojiUnaffordableRefusal',
    ];
    for (final lang in AppLang.values) {
      test('${lang.englishName} has every emoji string of its own', () {
        final t = Strings(lang);
        const en = Strings(AppLang.english);
        for (final key in keys) {
          final own = t.ownEntry(key);
          expect(own, isNotNull, reason: '$key in ${lang.code}');
          expect(own!.trim(), isNotEmpty, reason: key);
          // Every other language is in another script, so its own entry can
          // never equal the English.
          if (lang != AppLang.english) {
            expect(own, isNot(en.ownEntry(key)), reason: key);
          }
        }
        // The placeholders survive the translation.
        expect(
          t.unlockEmojiBody('X', 'Y'),
          allOf(contains('X'), contains('Y')),
        );
        expect(
          t.unlockEmojiRentBody('X', 'Y', 'Z'),
          allOf(contains('X'), contains('Y'), contains('Z')),
        );
        expect(t.emojiSentBy('X', 'Y'), allOf(contains('X'), contains('Y')));
      });
    }
  });
}
