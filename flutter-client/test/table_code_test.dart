import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/state/game_state.dart';

void main() {
  group('table codes', () {
    test('are eight characters long', () {
      expect(tableCodeLength, 8);
    });

    test('accept exactly eight letters or digits, in either case', () {
      for (final ok in ['ABCD2345', 'abcd2345', 'ZZZZ0000', ' ABCD2345 ']) {
        expect(isValidTableCode(ok), isTrue, reason: ok);
      }
    });

    test('refuse any other length or character', () {
      for (final bad in [
        '',
        'NOPE00',
        'ABC2345',
        'ABCD23456',
        'ABCD-234',
        'ABCD 234',
      ]) {
        expect(isValidTableCode(bad), isFalse, reason: bad);
      }
    });
  });
}
