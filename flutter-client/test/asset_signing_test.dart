// The catalogue's art in a private Cloudflare R2 bucket (owner, 1 Oct 2026:
// "backend will give signed urls valid for 10 min, UI will download and save
// in phone disk or cache, when user login again, it will see the path of
// assets is changed, so the UI will ask for new signed url for changed asset
// path stored in db"). The server hands out each file's LOCATION — the path
// the database stores — and PictureCache keeps the file under it: a file the
// phone has is read from its disk with no network and no signature; a location
// it does not have is signed by the server (one request for every location
// asked for together), downloaded once from the signed URL, and kept.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:teenpatti/net/picture_cache.dart';

const _bucket =
    'https://a91cb23b3b93a35dd9ea50db7b855e18.r2.cloudflarestorage.com/king-teenpatti/';

Uint8List _lottie(String name) => Uint8List.fromList(
  utf8.encode(
    '{"v":"5.7.4","nm":"$name","fr":30,"ip":0,"op":30,"w":64,"h":64,"layers":[]}',
  ),
);

late Directory _support;

/// What reached the network: every signing request (the locations it
/// carried) and every download (the URL fetched).
final _signRequests = <List<String>>[];
final _downloads = <String>[];

/// Locations the fake server will not sign, signed URLs it answers 403, and
/// URLs whose next download fails with a 503 (once).
final _unsigned = <String>{};
final _expired = <String>{};
final _failOnce = <String>{};
var _signature = 0;

Future<SignedAssets> _signer(List<String> locations) async {
  _signRequests.add(List.of(locations));
  _signature++;
  return SignedAssets({
    for (final l in locations)
      if (!_unsigned.contains(l)) l: '$l?X-Amz-Signature=$_signature',
  }, DateTime.now().add(const Duration(minutes: 10)));
}

final _client = MockClient((request) async {
  final url = request.url.toString();
  _downloads.add(url);
  if (_expired.contains(url)) {
    return http.Response('<Error>expired</Error>', 403);
  }
  if (_failOnce.remove(url)) return http.Response('busy', 503);
  if (url.startsWith(_bucket) && !url.contains('X-Amz-Signature=')) {
    return http.Response('<Error>AccessDenied</Error>', 400);
  }
  final name = Uri.parse(url).path.split('/').last;
  return http.Response.bytes(
    _lottie(name),
    200,
    headers: {'content-type': 'application/json'},
  );
});

/// This test's pictures directory: a fresh one each test, handed to the cache.
late Directory _pictures;

File _fileOf(String url) =>
    File('${_pictures.path}/${sha1.convert(url.codeUnits)}');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    _support = Directory.systemTemp.createTempSync('asset-signing-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => _support.path,
        );
  });

  tearDownAll(() => _support.deleteSync(recursive: true));

  setUp(() {
    PictureCache.clearMemory();
    PictureCache.debugResetSigning();
    PictureCache.signer = _signer;
    _signRequests.clear();
    _downloads.clear();
    _unsigned.clear();
    _expired.clear();
    _failOnce.clear();
    _signature = 0;
    _pictures = _support.createTempSync('pictures-');
    PictureCache.debugUseDirectory(_pictures);
  });

  tearDown(PictureCache.debugResetSigning);

  test('a location is an R2 URL with no query, and nothing else is', () {
    expect(isAssetLocation('${_bucket}emojis/angry.json'), isTrue);
    expect(isAssetLocation('${_bucket}profile_pictures/bear.png'), isTrue);
    for (final other in [
      '${_bucket}emojis/angry.json?X-Amz-Signature=abc',
      '/levels/newbie.json',
      'https://lh3.googleusercontent.com/a/photo',
      'https://drive.google.com/uc?export=download&id=1abc',
      'http://a91cb23b3b93a35dd9ea50db7b855e18.r2.cloudflarestorage.com/king-teenpatti/emojis/angry.json',
      'https://a91cb23b3b93a35dd9ea50db7b855e18.r2.cloudflarestorage.com/king-teenpatti',
      '',
    ]) {
      expect(isAssetLocation(other), isFalse, reason: other);
    }
  });

  test(
    'a location is signed, downloaded once and kept under the location',
    () async {
      final angry = '${_bucket}emojis/angry.json';
      await http.runWithClient(() async {
        final bytes = await PictureCache.load(angry);
        expect(bytes, _lottie('angry.json'));
        expect(_signRequests, [
          [angry],
        ]);
        expect(_downloads, [
          '$angry?X-Amz-Signature=1',
        ], reason: 'downloaded from the signed URL, never the location');
        expect(
          _fileOf(angry).existsSync(),
          isTrue,
          reason: 'kept under the location, not the signed URL',
        );

        // Next login: memory gone, the file on the disk. No signature, no network.
        PictureCache.clearMemory();
        expect(await PictureCache.load(angry), _lottie('angry.json'));
        expect(_signRequests, hasLength(1));
        expect(_downloads, hasLength(1));
      }, () => _client);
    },
  );

  test('locations asked for together are signed in one request', () async {
    final keys = [
      'emojis/ok.json',
      'badges/royal-ace.json',
      'levels/32-royal-titan.json',
      'profile_pictures/bear.png',
    ];
    await http.runWithClient(() async {
      final loaded = await Future.wait([
        for (final k in keys) PictureCache.load('$_bucket$k'),
      ]);
      expect(loaded.every((b) => b != null), isTrue);
      expect(_signRequests, hasLength(1));
      expect(_signRequests.single.toSet(), {
        for (final k in keys) '$_bucket$k',
      });
      expect(_downloads, hasLength(4));
    }, () => _client);
  });

  test(
    'a path that changed is a file the phone does not have: signed and downloaded',
    () async {
      final before = '${_bucket}levels/02-rookie.json';
      final after = '${_bucket}levels/02-rookie-v2.json';
      await http.runWithClient(() async {
        await PictureCache.load(before);
        PictureCache.clearMemory();
        // The server now names the file by a new path: the phone asks for it.
        expect(await PictureCache.load(after), _lottie('02-rookie-v2.json'));
        expect(_signRequests.last, [after]);
        // The old path is still on the disk, and nothing asks for it again.
        expect(await PictureCache.load(before), _lottie('02-rookie.json'));
        expect(_signRequests, hasLength(2));
      }, () => _client);
    },
  );

  test(
    'a location the server will not sign is not fetched, and asked again later',
    () async {
      final stray = '${_bucket}emojis/stray.json';
      _unsigned.add(stray);
      await http.runWithClient(() async {
        expect(await PictureCache.load(stray), isNull);
        expect(
          _downloads,
          isEmpty,
          reason: 'nothing downloaded without a signature',
        );
        expect(_fileOf(stray).existsSync(), isFalse);
        _unsigned.clear();
        expect(await PictureCache.load(stray), _lottie('stray.json'));
        expect(_signRequests, hasLength(2));
      }, () => _client);
    },
  );

  test(
    'a signed URL Cloudflare refuses is dropped, and the next try asks for a fresh one',
    () async {
      final cat = '${_bucket}profile_pictures/cool-cat.json';
      await http.runWithClient(() async {
        _expired.add('$cat?X-Amz-Signature=1');
        expect(await PictureCache.load(cat), isNull);
        expect(await PictureCache.load(cat), _lottie('cool-cat.json'));
        expect(_downloads, [
          '$cat?X-Amz-Signature=1',
          '$cat?X-Amz-Signature=2',
        ]);
      }, () => _client);
    },
  );

  test(
    'a download that fails for another reason keeps its signature for the retry',
    () async {
      final dog = '${_bucket}profile_pictures/dog.png';
      _failOnce.add('$dog?X-Amz-Signature=1');
      await http.runWithClient(() async {
        expect(
          await PictureCache.load(dog),
          isNull,
          reason: 'the first download failed',
        );
        expect(
          await PictureCache.load(dog),
          isNotNull,
          reason: 'the retry inside the ten minutes',
        );
        expect(
          _signRequests,
          hasLength(1),
          reason: 'signed once, the signature used twice',
        );
        expect(_downloads, [
          '$dog?X-Amz-Signature=1',
          '$dog?X-Amz-Signature=1',
        ]);
      }, () => _client);
    },
  );

  test(
    'keep signs every file it will fetch in one request, then downloads them',
    () async {
      final levels = [
        for (var l = 2; l <= 7; l++) '${_bucket}levels/0$l-level.json',
      ];
      await http.runWithClient(() async {
        await PictureCache.load(levels.first); // already on the phone
        _signRequests.clear();
        _downloads.clear();
        await PictureCache.keep([...levels, '/levels/old-path.json']);
        expect(_signRequests, hasLength(1));
        expect(_signRequests.single.toSet(), levels.skip(1).toSet());
        expect(_downloads.where((d) => d.startsWith(_bucket)), hasLength(5));
        for (final l in levels) {
          expect(_fileOf(l).existsSync(), isTrue, reason: l);
        }
      }, () => _client);
    },
  );

  test(
    'a URL that is not a location is downloaded as it is, unsigned',
    () async {
      const photo = 'https://lh3.googleusercontent.com/a/photo';
      await http.runWithClient(() async {
        expect(await PictureCache.load(photo), isNotNull);
        expect(_signRequests, isEmpty);
        expect(_downloads, [photo]);
      }, () => _client);
    },
  );

  test(
    'with no signer (no session yet) a location is simply not fetched',
    () async {
      PictureCache.signer = null;
      await http.runWithClient(() async {
        expect(await PictureCache.load('${_bucket}emojis/angry.json'), isNull);
        expect(_downloads, isEmpty);
      }, () => _client);
    },
  );

  // A first sign-in asks for every picture at once: on the emulator, 128
  // downloads at the same moment all ran out of time (1 Oct 2026).
  test(
    'at most six downloads run at once, signed together, the rest in turn',
    () async {
      final held = <Completer<void>>[];
      var running = 0;
      var most = 0;
      final slow = MockClient((request) async {
        _downloads.add(request.url.toString());
        running++;
        most = running > most ? running : most;
        final turn = Completer<void>();
        held.add(turn);
        await turn.future;
        running--;
        return http.Response.bytes(
          _lottie(request.url.pathSegments.last),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final files = [for (var i = 0; i < 20; i++) '${_bucket}emojis/e$i.json'];
      await http.runWithClient(() async {
        final loads = Future.wait(files.map(PictureCache.load));
        while (held.length < PictureCache.maxDownloads) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(held, hasLength(PictureCache.maxDownloads));
        expect(PictureCache.debugDownloads, (running: 6, waiting: 14));
        expect(_signRequests, hasLength(1), reason: 'one request signs all');
        for (var released = 0; released < files.length;) {
          if (released < held.length) held[released++].complete();
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        final loaded = await loads;
        expect(loaded.every((b) => b != null), isTrue);
        expect(most, PictureCache.maxDownloads);
        expect(_downloads, hasLength(files.length));
        expect(PictureCache.debugDownloads, (running: 0, waiting: 0));
      }, () => slow);
    },
  );

  test(
    'a link that has run down by the time its download starts is asked for again',
    () async {
      final angry = '${_bucket}emojis/angry.json';
      // Twenty seconds left: under the margin the cache starts a download on.
      PictureCache.signer = (locations) async {
        _signRequests.add(List.of(locations));
        _signature++;
        return SignedAssets({
          for (final l in locations) l: '$l?X-Amz-Signature=$_signature',
        }, DateTime.now().add(const Duration(seconds: 20)));
      };
      await http.runWithClient(() async {
        expect(await PictureCache.load(angry), isNotNull);
        expect(_signRequests, hasLength(2));
        expect(_downloads, ['$angry?X-Amz-Signature=2']);
      }, () => _client);
    },
  );
}
