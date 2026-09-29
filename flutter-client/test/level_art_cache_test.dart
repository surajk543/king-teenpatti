// Every level's art kept on the phone (owner, 29 Sep 2026: "Make sure you
// cache the all level icons in phone"): PictureCache.keep puts files on the
// disk without holding them in memory, never fetches one twice, refuses a page
// in place of a file, and a later show reads the disk; and reading the level
// ladder keeps every level's art.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/state/game_state.dart';

import 'level_fixtures.dart';

/// A Lottie as the server would send it, told apart by [n].
Uint8List _lottie(int n) =>
    Uint8List.fromList(utf8.encode('{"v":"5.7","w":64,"h":64,"n":$n}'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('level-art-');
    PictureCache.debugUseDirectory(dir);
  });
  tearDown(() {
    PictureCache.clearMemory();
    PictureCache.debugUseDirectory(null);
    dir.deleteSync(recursive: true);
  });

  /// The files the cache holds on the disk.
  int onDisk() => dir
      .listSync()
      .whereType<File>()
      .where((f) => !f.path.endsWith('.part'))
      .length;

  test('keep puts every file on the disk, not in memory, once', () async {
    final asked = <String>[];
    final client = MockClient((r) async {
      asked.add(r.url.toString());
      final n = int.parse(r.url.pathSegments.last.split('.').first);
      return http.Response.bytes(_lottie(n), 200);
    });
    final urls = [
      for (var n = 1; n <= 5; n++) 'https://drive.test/levels/$n.json',
    ];
    await http.runWithClient(() async {
      await PictureCache.keep([...urls, urls.first, '']);
    }, () => client);
    expect(asked, urls, reason: 'each once, one after another, blanks skipped');
    expect(onDisk(), 5);
    for (final url in urls) {
      expect(PictureCache.peek(url), isNull, reason: 'kept on the disk only');
    }

    // Kept already: nothing asked again.
    await http.runWithClient(() async {
      await PictureCache.keep(urls);
    }, () => client);
    expect(asked, hasLength(5));

    // And a show reads the disk, with no network.
    final bytes = await http.runWithClient(
      () => PictureCache.load(urls[2]),
      () => client,
    );
    expect(bytes, _lottie(3));
    expect(asked, hasLength(5));
  });

  test('keep writes nothing for a page or a failure, and tries again next '
      'time', () async {
    var down = true;
    final client = MockClient((r) async {
      if (down) {
        return r.url.path.endsWith('1.json')
            ? http.Response(
                '<!doctype html><html></html>',
                200,
                headers: {'content-type': 'text/html'},
              )
            : http.Response('', 500);
      }
      return http.Response.bytes(_lottie(1), 200);
    });
    const urls = [
      'https://drive.test/levels/1.json',
      'https://drive.test/levels/2.json',
    ];
    await http.runWithClient(() => PictureCache.keep(urls), () => client);
    expect(onDisk(), 0);
    down = false;
    await http.runWithClient(() => PictureCache.keep(urls), () => client);
    expect(onDisk(), 2);
  });

  test(
    'reading the level ladder keeps every level\'s art on the phone',
    () async {
      final asked = <String>[];
      final client = MockClient((r) async {
        asked.add(r.url.toString());
        if (r.url.path == '/api/levels') {
          return http.Response(
            jsonEncode(ladderJson()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        final n = int.parse(r.url.pathSegments.last.split('.').first);
        return http.Response.bytes(_lottie(n), 200);
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final state = GameState(serverUrl: 'http://api.test');
      debugDefaultTargetPlatformOverride = null;
      await http.runWithClient(() async {
        await state.loadLevelLadder();
        // The keeping runs behind the read, one file at a time.
        for (var i = 0; i < 200 && onDisk() < levelsWithArt; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
      }, () => client);
      expect(onDisk(), levelsWithArt);
      for (var n = 1; n <= levelsWithArt; n++) {
        expect(
          asked.where((u) => u == levelArtUrl(n)),
          hasLength(1),
          reason: 'level $n fetched once',
        );
      }
      state.dispose();
    },
  );
}
