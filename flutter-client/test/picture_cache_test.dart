import 'dart:convert';
import 'dart:typed_data';

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

  group('looksLikeHtml', () {
    Uint8List text(String t) => Uint8List.fromList(utf8.encode(t));

    test('a page a host serves in place of a file is not a picture', () {
      // Drive's sign-in page for a file that is not (yet) shared, as a phone
      // cached it on 16 Sep 2026 and drew a bare felt from then on.
      expect(looksLikeHtml(text('<!doctype html><html lang="en-US" dir="ltr"><head>')), isTrue);
      expect(looksLikeHtml(text('<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN">')), isTrue);
      expect(looksLikeHtml(text('﻿\n  <html><body>quota exceeded</body></html>')), isTrue,
          reason: 'a byte-order mark and whitespace do not hide the page');
    });

    test('pictures pass, doctyped SVGs included', () {
      expect(looksLikeHtml(text('<svg xmlns="http://www.w3.org/2000/svg"/>')), isFalse);
      expect(looksLikeHtml(text('<?xml version="1.0"?><svg/>')), isFalse);
      expect(looksLikeHtml(text('<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN"><svg/>')), isFalse);
      expect(looksLikeHtml(text('{"v":"5.5.3","layers":[]}')), isFalse);
      expect(looksLikeHtml(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isFalse);
      expect(looksLikeHtml(Uint8List(0)), isFalse);
    });
  });

  group('lottieCanvasAspect', () {
    Uint8List text(String t) => Uint8List.fromList(utf8.encode(t));

    test('reads the canvas off the file head', () {
      // Welcome.json's head, and Background Pattern's.
      expect(
        lottieCanvasAspect(text('{"v":"4.8.0","meta":{"g":"LottieFiles AE 3.1.1"},"fr":60,"ip":0,"op":493,"w":428,"h":123,"nm":"welcome"')),
        closeTo(428 / 123, 1e-9),
      );
      expect(lottieCanvasAspect(text('{"v":"5.5.3","fr":25,"ip":0,"op":150,"w":1500,"h":1000,"nm":"Background Pattern"')), 1.5);
    });

    test('answers null where the head does not say', () {
      expect(lottieCanvasAspect(text('{"v":"5.5.3","layers":[]}')), isNull);
      expect(lottieCanvasAspect(text('<svg width="10" height="10"/>')), isNull);
      expect(lottieCanvasAspect(text('{"w":0,"h":10}')), isNull);
      expect(lottieCanvasAspect(Uint8List(0)), isNull);
    });
  });

  group('pictureKindOf', () {
    Uint8List text(String t) => Uint8List.fromList(utf8.encode(t));

    test('a declared format wins over what the bytes look like', () {
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      expect(pictureKindOf('LOTTIE', png), PictureKind.lottie);
      expect(pictureKindOf('SVG', text('{}')), PictureKind.svg);
      expect(pictureKindOf('IMAGE', text('<svg/>')), PictureKind.bitmap);
      expect(pictureKindOf('RIVE', text('{}')), PictureKind.unsupported);
    });

    test('without one, a worn picture is told apart by its bytes', () {
      // What a seat pod gets: a bare URL, no catalogue row, so no format.
      expect(pictureKindOf(null, text('{"v":"5.7.0","layers":[]}')), PictureKind.lottie);
      expect(pictureKindOf(null, text('\uFEFF  \n{"v":"5.7.0"}')), PictureKind.lottie,
          reason: 'a byte-order mark and whitespace do not hide the brace');
      expect(pictureKindOf(null, text('<svg xmlns="http://www.w3.org/2000/svg"/>')), PictureKind.svg);
      expect(pictureKindOf(null, text('<?xml version="1.0"?><svg/>')), PictureKind.svg);
      expect(pictureKindOf(null, Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 0])), PictureKind.lottie,
          reason: 'a zip in a picture slot is a dotLottie');
      expect(pictureKindOf(null, text('RIVE\u0007')), PictureKind.unsupported);
      expect(pictureKindOf(null, Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D])), PictureKind.bitmap);
      expect(pictureKindOf(null, Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), PictureKind.bitmap);
    });

    test('empty bytes fall to the bitmap loader, whose error shows the default', () {
      expect(pictureKindOf(null, Uint8List(0)), PictureKind.bitmap);
    });
  });
}
