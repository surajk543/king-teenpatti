// The two Lotties the missile is drawn from (owner, 14 Sep 2026):
// assets/animations/Missile.json — the Missile key's glyph and the rocket that
// flies — and assets/animations/explosion.json, the blast on each pod.
//
// Each is parsed by the same player the phone uses and drawn to a picture, so
// a file that fails to parse or draws nothing fails here rather than leaving
// the key blank and the felt silent. What phones cannot draw (CLAUDE.md
// §12.3) is ruled out as in message_glyph_test.dart: 3D layers, orientation
// and x/y rotation, and expressions.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/widgets/missile_flight.dart';

/// Every map anywhere inside [node], depth first.
Iterable<Map<String, dynamic>> _maps(Object? node) sync* {
  if (node is Map<String, dynamic>) {
    yield node;
    for (final value in node.values) {
      yield* _maps(value);
    }
  } else if (node is List) {
    for (final value in node) {
      yield* _maps(value);
    }
  }
}

/// Every layer of [json], its precomps' layers included.
Iterable<Map<String, dynamic>> _layers(Map<String, dynamic> json) sync* {
  yield* (json['layers'] as List).cast<Map<String, dynamic>>();
  for (final asset in (json['assets'] as List? ?? const [])) {
    final layers = (asset as Map<String, dynamic>)['layers'] as List?;
    if (layers != null) yield* layers.cast<Map<String, dynamic>>();
  }
}

/// How many pixels [composition] paints at [frame], drawn into a [side]-wide
/// box.
Future<int> _inkAt(LottieComposition composition, double frame) async {
  const side = 120;
  final drawable = LottieDrawable(composition, frameRate: FrameRate.max)
    ..setProgress(
      ((frame - composition.startFrame) / composition.durationFrames).clamp(
        0.0,
        1.0,
      ),
    );
  final recorder = ui.PictureRecorder();
  drawable.draw(
    Canvas(recorder),
    const Rect.fromLTWH(0, 0, side * 1.0, side * 1.0),
    fit: BoxFit.contain,
  );
  final image = await recorder.endRecording().toImage(side, side);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  var ink = 0;
  for (var i = 3; i < bytes!.lengthInBytes; i += 4) {
    if (bytes.getUint8(i) > 0) ink++;
  }
  return ink;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (asset, frames, width, height) in [
    (MissileArt.missileAsset, 60.0, 1000.0, 1000.0),
    (MissileArt.explosionAsset, 11.0, 134.0, 87.0),
  ]) {
    test('$asset is a Lottie the phone players can draw', () async {
      final bytes = File(asset).readAsBytesSync();
      final composition = await LottieComposition.fromBytes(bytes);
      // The player counts to the last frame, not past it.
      expect(composition.durationFrames, closeTo(frames, 0.02));
      expect(composition.bounds.width, width);
      expect(composition.bounds.height, height);

      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      for (final layer in _layers(json)) {
        final nm = layer['nm'];
        expect(layer['ddd'] ?? 0, 0, reason: '$nm is a 3D layer');
        final ks = layer['ks'] as Map<String, dynamic>;
        for (final turn in ['or', 'rx', 'ry']) {
          expect(ks.containsKey(turn), isFalse, reason: '$nm carries $turn');
        }
      }
      expect(
        _maps(json).where((m) => m['x'] is String),
        isEmpty,
        reason: 'expressions do not run on phones',
      );
    });
  }

  test('the rocket is on its canvas where the key and the flight draw it, '
      'and nowhere at frame 0', () async {
    final composition = await LottieComposition.fromBytes(
      File(MissileArt.missileAsset).readAsBytesSync(),
    );
    // Frame 0 is the rocket off the canvas: a key that stopped there would be
    // empty, which is why the key rests on restFrame instead.
    expect(await _inkAt(composition, 0), 0);
    for (final frame in [
      MissileArt.restFrame,
      MissileArt.flyFrom,
      MissileArt.flyFrom + MissileArt.flyFrames,
    ]) {
      expect(
        await _inkAt(composition, frame),
        greaterThan(400),
        reason: '$frame',
      );
    }
  });

  test('the explosion draws on every frame the blast plays', () async {
    final composition = await LottieComposition.fromBytes(
      File(MissileArt.explosionAsset).readAsBytesSync(),
    );
    for (var frame = 0.0; frame < 10; frame++) {
      expect(
        await _inkAt(composition, frame),
        greaterThan(0),
        reason: '$frame',
      );
    }
  });

  test('the exhaust pulse runs through every frame a flying rocket uses', () {
    final json =
        jsonDecode(File(MissileArt.missileAsset).readAsStringSync())
            as Map<String, dynamic>;
    final exhaust = (json['layers'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((layer) => layer['nm'] == 'Layer 2 Outlines');
    final keys = ((exhaust['ks'] as Map)['s'] as Map)['k'] as List;
    final times = [for (final k in keys) (k as Map)['t'] as num];
    expect(
      times.last,
      greaterThanOrEqualTo(MissileArt.flyFrom + MissileArt.flyFrames),
    );
    // One pulse is eight frames, so the flight's loop has no seam.
    expect(times[1] - times[0], 4);
    expect(MissileArt.flyFrames, 2 * (times[1] - times[0]));
  });

  test('the rocket points up and to the right, as the flight turns it', () {
    final json =
        jsonDecode(File(MissileArt.missileAsset).readAsStringSync())
            as Map<String, dynamic>;
    final rocket = (json['layers'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((layer) => layer['nm'] == 'Layer 3 Outlines');
    // The body: a triangle whose far vertex is the nose and whose other two
    // are the tail.
    final body = (rocket['shapes'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((group) => group['nm'] == 'Group 4');
    final path = (body['it'] as List).cast<Map<String, dynamic>>().firstWhere(
      (item) => item['ty'] == 'sh',
    );
    final vertices = [
      for (final v in ((path['ks'] as Map)['k'] as Map)['v'] as List)
        Offset(((v as List)[0] as num).toDouble(), (v[1] as num).toDouble()),
    ];
    final nose = vertices[1];
    final tail = Offset.lerp(vertices[0], vertices[2], 0.5)!;
    expect(
      (nose - tail).direction,
      closeTo(MissileArt.forward, 2 * math.pi / 180),
    );
  });
}
