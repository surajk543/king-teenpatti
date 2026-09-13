import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';

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

void main() {
  // The table's chat key plays assets/animations/Message.json and its
  // quick-message key assets/animations/Quick message.json. A file that fails
  // to parse leaves its key on the fallback glyph with nothing on screen to say
  // why, so each is parsed here, and what the phone players cannot draw
  // (CLAUDE.md §12.3) is ruled out: 3D layers, orientation and x/y rotation
  // (tools/lottie/flatten_orientation.py bakes those into 2D), and expressions.
  for (final (name, seconds) in [
    ('Message.json', 2),
    ('Quick message.json', 4),
  ]) {
    test('$name is a Lottie the phone players can draw', () async {
      final bytes = File('assets/animations/$name').readAsBytesSync();
      final composition = await LottieComposition.fromBytes(bytes);
      expect(composition.duration, Duration(seconds: seconds));

      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      for (final layer
          in (json['layers'] as List).cast<Map<String, dynamic>>()) {
        final nm = layer['nm'];
        expect(layer['ddd'] ?? 0, 0, reason: '$nm is a 3D layer');
        final ks = layer['ks'] as Map<String, dynamic>;
        for (final turn in ['or', 'rx', 'ry']) {
          expect(
            ks.containsKey(turn),
            isFalse,
            reason:
                '$nm carries $turn, which phones ignore (or) or draw only '
                'as a flat stretch (rx, ry)',
          );
        }
      }
      expect(
        _maps(json).where((m) => m['x'] is String),
        isEmpty,
        reason: 'expressions do not run on phones',
      );
    });
  }

  test('the chat bubble is drawn in strokes, which the rail recolours', () {
    final json = jsonDecode(
      File('assets/animations/Message.json').readAsStringSync(),
    );
    expect(_maps(json).where((m) => m['ty'] == 'st'), isNotEmpty);
  });

  // The quick-message key draws the envelope in the rail's ink by layer and
  // group name (table_screen.dart, _envelopeInInk). A replacement file that
  // renamed them would keep its own colours and its disc without a word.
  test('the envelope still has the layers the rail recolours', () {
    final json =
        jsonDecode(
              File('assets/animations/Quick message.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final groups = {
      for (final layer in (json['layers'] as List).cast<Map<String, dynamic>>())
        layer['nm'] as String: [
          for (final group
              in (layer['shapes'] as List? ?? const [])
                  .cast<Map<String, dynamic>>())
            group['nm'],
        ],
    };
    for (final name in [
      'background Outlines',
      'front Outlines',
      'back Outlines',
      'opener Outlines',
      'plane Outlines',
      'Shape Layer 1',
    ]) {
      expect(groups.keys, contains(name));
    }
    expect(groups['mail inside Outlines'], containsAll(['Group 1', 'Group 2']));
  });
}
