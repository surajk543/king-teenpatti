import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/glass_orb.dart';

/// WCAG contrast of two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  final schemes = {
    'light': AppTheme.light().colorScheme,
    'dark': AppTheme.dark().colorScheme,
  };

  for (final MapEntry(key: name, value: scheme) in schemes.entries) {
    TablePalette of(String category, int boot) =>
        AppTheme.paletteFor(scheme, category: category, bootAmount: boot);

    test('the variation table has a colour and a mark of its own ($name)', () {
      final variation = of(TableCategory.variation, 200);
      final others = [
        of(TableCategory.seen, 200),
        of(TableCategory.blind, 200),
        of(TableCategory.blind, 5000),
      ];
      for (final other in others) {
        expect(variation.accent, isNot(other.accent));
        expect(variation.icon, isNot(other.icon));
      }
      // Blind is one colour at every stake (owner, 24 Sep 2026: one accent a
      // mode), so the others are two — gold and sapphire — where the
      // high-stakes blind table's purple used to make three.
      expect(others.map((p) => p.accent).toSet(), hasLength(2));
    });

    test('its orb is told apart by hue, which is all an orb keeps ($name)', () {
      double hue(String category, int boot) =>
          HSLColor.fromColor(orbColours(of(category, boot).accent).$1).hue;
      final mine = hue(TableCategory.variation, 200);
      for (final other in [
        hue(TableCategory.seen, 200),
        hue(TableCategory.blind, 200),
        hue(TableCategory.blind, 5000),
        HSLColor.fromColor(orbColours(scheme.primary).$1).hue,
      ]) {
        final apart = (mine - other).abs();
        expect(apart > 180 ? 360 - apart : apart, greaterThan(40));
      }
    });

    test('its badge reads: text on the container, mark on the ink ($name)', () {
      final p = of(TableCategory.variation, 200);
      expect(_contrast(p.onContainer, p.container), greaterThan(7));
      // The table's tag draws the mark on a dark ink plate in both themes.
      expect(_contrast(p.accent, AppTheme.ink900), greaterThan(3.5));
    });

    test('its stake does not change it, and blind is untouched ($name)', () {
      expect(
        of(TableCategory.variation, 5000).accent,
        of(TableCategory.variation, 200).accent,
      );
      expect(of(TableCategory.blind, 200).accent, scheme.tertiary);
      expect(of(TableCategory.blind, 200).icon, Icons.visibility_off_rounded);
      expect(of(TableCategory.seen, 200).icon, Icons.visibility_rounded);
    });

    test('a category this build does not know is drawn as seen ($name)', () {
      final unknown = of('something_new', 200);
      final seen = of(TableCategory.seen, 200);
      expect(unknown.accent, seen.accent);
      expect(unknown.icon, seen.icon);
      expect(unknown.container, seen.container);
    });
  }
}
