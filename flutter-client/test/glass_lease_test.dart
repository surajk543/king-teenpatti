// The one blur a screen may composite (premium_surface.dart's GlassBudget):
// a glass panel that leaves the tree hands its lease on at once, not at the
// end of the frame (2 Oct 2026). One reward popup gives way to the next in a
// single frame — a new panel mounts as the old one leaves — and the new one
// used to find the blur still held, render unblurred for its whole life and,
// by night, let the lobby's cards show through it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

Widget _app(Widget body) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.dark(sound: false),
  home: GlassBudget(child: Scaffold(body: body)),
);

Widget _panel(Key key, String words) => PremiumGlassPanel(
  key: key,
  mode: GlassMode.auto,
  priority: 30,
  padding: const EdgeInsets.all(8),
  child: Text(words),
);

/// The blur inside the panel that holds [words].
Finder _blurUnder(String words) => find.descendant(
  of: find.ancestor(
    of: find.text(words),
    matching: find.byType(PremiumGlassPanel),
  ),
  matching: find.byType(BackdropFilter),
);

void main() {
  testWidgets('a panel swapped for another in one frame hands the blur on: '
      'the new one blurs, not only the first', (tester) async {
    await tester.pumpWidget(_app(_panel(const ValueKey('one'), 'one')));
    expect(_blurUnder('one'), findsOneWidget);

    // The next popup's panel takes the place of the first in one build.
    await tester.pumpWidget(_app(_panel(const ValueKey('two'), 'two')));
    expect(find.text('one'), findsNothing);
    expect(_blurUnder('two'), findsOneWidget);

    // And the one after it.
    await tester.pumpWidget(_app(_panel(const ValueKey('three'), 'three')));
    expect(_blurUnder('three'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('the budget still holds: a second panel beside one that blurs '
      'is drawn tinted, and the blur goes to the next panel to mount', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            _panel(const ValueKey('one'), 'one'),
            _panel(const ValueKey('two'), 'two'),
          ],
        ),
      ),
    );
    expect(_blurUnder('one'), findsOneWidget);
    expect(_blurUnder('two'), findsNothing);

    // A panel decides when it mounts: the one already drawn tinted stays so
    // when the blur comes free (a blur popping in under a finger)...
    await tester.pumpWidget(
      _app(Column(children: [_panel(const ValueKey('two'), 'two')])),
    );
    expect(_blurUnder('two'), findsNothing);
    // ...and the next panel to mount gets it.
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            _panel(const ValueKey('two'), 'two'),
            _panel(const ValueKey('three'), 'three'),
          ],
        ),
      ),
    );
    expect(_blurUnder('two'), findsNothing);
    expect(_blurUnder('three'), findsOneWidget);
  });

  testWidgets('a panel moved by a global key keeps its blur', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(_app(Center(child: _panel(key, 'moved'))));
    expect(_blurUnder('moved'), findsOneWidget);

    // Reparented in one frame: deactivated, then put back.
    await tester.pumpWidget(
      _app(Align(alignment: Alignment.topLeft, child: _panel(key, 'moved'))),
    );
    expect(_blurUnder('moved'), findsOneWidget);

    // Still the lease's holder: a newcomer beside it is drawn tinted.
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            _panel(key, 'moved'),
            _panel(const ValueKey('other'), 'other'),
          ],
        ),
      ),
    );
    expect(_blurUnder('moved'), findsOneWidget);
    expect(_blurUnder('other'), findsNothing);
  });
}
