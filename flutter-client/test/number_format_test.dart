// Requirement 34: money above a lakh is named rather than spelled out in
// digits, in whichever system the player has chosen.
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/state/game_state.dart';

void main() {
  tearDown(() => chipNumberSystem = NumberSystem.indian);

  test('small amounts stay exact and grouped', () {
    for (final system in NumberSystem.values) {
      chipNumberSystem = system;
      expect(formatChips(0), '0');
      expect(formatChips(200), '200');
      expect(formatChips(99999), '99,999');
      // The threshold itself is still written out.
      expect(formatChips(100000), '100,000');
    }
  });

  test('the Indian system names lakh and crore', () {
    chipNumberSystem = NumberSystem.indian;
    // The figure from the requirement.
    expect(formatChips(324011), '3.24 Lakh');
    expect(formatChips(1200000), '12 Lakh');
    expect(formatChips(595200), '5.95 Lakh');
    expect(formatChips(10000000), '1 Crore');
    expect(formatChips(25000000), '2.5 Crore');
    expect(formatChips(327690000), '32.77 Crore', reason: 'rounded, not truncated');
    expect(formatChips(500495800), '50.05 Crore');
  });

  test('the international system names million and billion', () {
    chipNumberSystem = NumberSystem.international;
    // Under a million there is no unit worth using, so it stays in digits.
    expect(formatChips(324011), '324,011');
    expect(formatChips(1200000), '1.2 Million');
    expect(formatChips(10000000), '10 Million');
    expect(formatChips(2500000000), '2.5 Billion');
  });

  test('the same figure reads differently in each system', () {
    chipNumberSystem = NumberSystem.indian;
    expect(formatChips(1000000), '10 Lakh');
    chipNumberSystem = NumberSystem.international;
    expect(formatChips(1000000), '1 Million');
  });

  test('a debt keeps its sign', () {
    chipNumberSystem = NumberSystem.indian;
    expect(formatChips(-324011), '-3.24 Lakh');
    expect(formatChips(-500), '-500');
  });

  test('the unit words follow the language', () {
    chipNumberSystem = NumberSystem.indian;
    chipUnits = (lakh: 'लाख', crore: 'करोड़', million: 'x', billion: 'y');
    expect(formatChips(1200000), '12 लाख');
    chipUnits =
        (lakh: 'Lakh', crore: 'Crore', million: 'Million', billion: 'Billion');
  });
}
