// An emoji is downloaded from its url ONCE per phone (owner, 26 Sep 2026:
// "make sure once user download the emoji in phone, it does not download
// again from url"). Every place that draws one — the store's tile, the table's
// emoji page, the seat bubble, the chat log — asks PictureCache with the same
// url (GameState.absoluteUrl), and the cache answers from memory, then from
// its file on the phone, and only then from the network, writing the file on
// the way. These count the requests that actually leave the phone.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/widgets/emoji_art.dart';

/// A Lottie as small as one can be and still be one.
final Uint8List _lottie = Uint8List.fromList(
  utf8.encode(
    '{"v":"5.7.4","fr":30,"ip":0,"op":30,"w":64,"h":64,"layers":[]}',
  ),
);

const _url = 'https://drive.google.com/uc?export=download&id=emoji-once';

late Directory _support;
var _fetches = 0;

final _client = MockClient((request) async {
  _fetches++;
  return http.Response.bytes(
    _lottie,
    200,
    headers: {'content-type': 'application/octet-stream'},
  );
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    _support = Directory.systemTemp.createTempSync('emoji-once-');
    // path_provider's getApplicationSupportDirectory, answered with the
    // temporary directory: the phone's own storage, for this test.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => _support.path,
        );
  });

  tearDownAll(() => _support.deleteSync(recursive: true));

  File cached() => File(
    '${_support.path}/pictures/${sha1.convert(_url.codeUnits)}',
  );

  test('the first draw downloads it once and keeps it on the phone', () async {
    await http.runWithClient(() async {
      // The store tile, the emoji page and a seat, all at once: one download.
      final got = await Future.wait([
        PictureCache.load(_url),
        PictureCache.load(_url),
        PictureCache.load(_url),
      ]);
      for (final bytes in got) {
        expect(bytes, _lottie);
      }
      expect(_fetches, 1);
      // Drawn again this session: from memory.
      expect(await PictureCache.load(_url), _lottie);
      expect(_fetches, 1);
    }, () => _client);
    expect(cached().existsSync(), isTrue, reason: 'kept on the phone');
    expect(cached().readAsBytesSync(), _lottie);
  });

  test('after a restart it is read from the phone, never the url', () async {
    await http.runWithClient(() async {
      // A restart: nothing in memory, the file still on disk.
      PictureCache.clearMemory();
      expect(PictureCache.peek(_url), isNull);
      expect(await PictureCache.load(_url), _lottie);
      // The next sign-in warms the whole catalogue: still nothing fetched.
      PictureCache.clearMemory();
      PictureCache.warm([_url]);
      expect(await PictureCache.load(_url), _lottie);
    }, () => _client);
    expect(_fetches, 1, reason: 'one download for the life of the install');
  });

  testWidgets('every emoji drawn on screen at once shares that one copy', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await http.runWithClient(() async {
        PictureCache.clearMemory();
        await tester.pumpWidget(
          const MaterialApp(
            home: Row(
              children: [
                EmojiArt(url: _url, size: 40),
                EmojiArt(url: _url, size: 60),
                EmojiArt(url: _url, size: 80),
              ],
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }, () => _client);
    });
    await tester.pump();
    expect(_fetches, 1, reason: 'three EmojiArts read the phone copy');
    expect(PictureCache.peek(_url), _lottie);
  });
}
