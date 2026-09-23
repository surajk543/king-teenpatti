// A suit on a miniature card face (owner, 24 Sep 2026): "in Variation Game
// play when user selects Hukam, then the icon on top is not visible properly."
//
// The table's tag ended in a bare '♣' in the label's gold — a glyph the bundled
// Inter does not have, so Android drew it from the colour emoji font, which
// ignores the text colour: a black club on the dark pill. SuitMark paints the
// suit instead, and this pins what it paints.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/playing_card.dart';

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.dark(sound: false),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('paints every suit as a pip in its own ink on a pale face', (
    tester,
  ) async {
    for (final (suit, ink) in [
      ('s', AppTheme.pipBlack),
      ('c', AppTheme.pipBlack),
      ('h', AppTheme.pipRed),
      ('d', AppTheme.pipRed),
    ]) {
      await tester.pumpWidget(_host(SuitMark(suit: suit, size: 14)));
      final mark = find.byType(SuitMark);
      expect(tester.getSize(mark), const Size(14, 14));

      final pip = tester.widget<CardPips>(
        find.descendant(of: mark, matching: find.byType(CardPips)),
      );
      expect(pip.suit, suit);
      expect(pip.colour, ink, reason: 'the $suit keeps its colour anywhere');
      expect(pip.size, closeTo(14 * SuitMark.pipShare, 0.001));
      expect(
        find.descendant(of: mark, matching: find.byType(CustomPaint)),
        findsOneWidget,
        reason: 'a shape, not a glyph',
      );
      expect(find.text(PlayingCard.suitSymbol(suit)), findsNothing);

      final face = tester.widget<Container>(
        find.descendant(of: mark, matching: find.byType(Container)),
      );
      expect(
        (face.decoration! as BoxDecoration).color,
        AppTheme.cardFace.withValues(alpha: SuitMark.faceAlpha),
        reason: 'the pale face the pip keeps its colour on',
      );
    }
  });

  testWidgets('is read out as the glyph it replaced', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(const SuitMark(suit: 'h', size: 14)));
    expect(find.bySemanticsLabel('♥'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('an unknown suit falls back to the card face\'s own "?"', (
    tester,
  ) async {
    // A protocol break must never render as a plausible wrong suit.
    await tester.pumpWidget(_host(const SuitMark(suit: 'x', size: 14)));
    expect(find.text('?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
