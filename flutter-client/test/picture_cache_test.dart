import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/net/picture_cache.dart';

/// These run on the host VM, where there is no platform channel to answer
/// getApplicationSupportDirectory. That is deliberate: it exercises the path a
/// phone takes when the directory cannot be opened, and proves the cache
/// degrades to memory instead of throwing into a widget build.
void main() {
  // Without this the plugin channel never answers and every load would hang
  // rather than fall back — which is exactly the case the timeout in
  // _openDirectory covers.
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(PictureCache.clearMemory);

  test('a picture that has never been seen is not in memory', () {
    expect(PictureCache.peek('https://example.invalid/bear.png'), isNull);
  });

  test('a fetch that cannot succeed answers null rather than throwing', () async {
    // Malformed on purpose: no socket is opened, so the test stays hermetic.
    expect(await PictureCache.load('not even a url'), isNull);
  });

  test('a failure is not remembered, so the next build tries again', () async {
    const url = 'not even a url';
    await PictureCache.load(url);
    // If failures were cached, peek would hand a widget an empty picture for
    // the rest of the session and a phone that came back online would never
    // recover without a restart.
    expect(PictureCache.peek(url), isNull);
  });

  test('two widgets asking at once share one fetch', () async {
    const url = 'not even a url';
    final a = PictureCache.load(url);
    final b = PictureCache.load(url);
    expect(identical(a, b), isTrue,
        reason: 'the second caller joins the first fetch');
    await Future.wait([a, b]);
  });

  test('warming is safe with an empty catalogue and blank urls', () {
    expect(() => PictureCache.warm(const []), returnsNormally);
    expect(() => PictureCache.warm(const ['']), returnsNormally);
  });
}
