// Depth on the Friends page (owner's brief, 28 Sep 2026: "I only want to add
// DEPTH and subtle visual hierarchy ... Depth should be felt more than
// seen"). The depth tokens exist by night and by day and cross-fade with the
// theme; the page's ground and its metadata stay flat; the panes stand on the
// page with their own soft shadow and a lit top edge (the requests' edge
// live gold); a portrait stands on its pane and settles under a finger; a
// lit presence dot wears its bezel and halo and an offline one neither; the
// playing chip is washed and edged in its game's own colour; and the search
// field is raised, lit and gold-lit while typed in — in both themes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:teenpatti/models/friends.dart';
import 'package:teenpatti/screens/friends_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/friend_presence.dart';
import 'package:teenpatti/widgets/game_card.dart';
import 'package:teenpatti/widgets/glass_components.dart';
import 'package:teenpatti/widgets/player_profile.dart' show friendsGreen;
import 'package:teenpatti/widgets/premium_surface.dart';

import 'friends_fixture.dart';
import 'script_fonts.dart';

Future<void> _setView(WidgetTester tester) async {
  tester.view.physicalSize = const Size(915, 412);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _openPage(
  WidgetTester tester,
  GameState state, {
  required Brightness brightness,
}) async {
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(sound: false),
        darkTheme: AppTheme.dark(sound: false),
        themeMode: brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        builder: (context, child) => GlassBudget(child: child!),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showFriends(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

Finder _inPage(Finder matching) =>
    find.descendant(of: find.byType(FriendsScreen), matching: matching);

Finder _key(String key) => find.byKey(ValueKey(key));

GlassColors _glass(Brightness b) =>
    b == Brightness.dark ? GlassColors.dark : GlassColors.light;

/// Every shadow any box at or under [finder] casts.
List<BoxShadow> _shadowsUnder(WidgetTester tester, Finder finder) {
  final shadows = <BoxShadow>[];
  void take(Decoration? d) {
    if (d is BoxDecoration) shadows.addAll(d.boxShadow ?? const []);
  }

  for (final e
      in find
          .descendant(of: finder, matching: find.byWidgetPredicate((_) => true))
          .evaluate()
          .followedBy(finder.evaluate())) {
    final w = e.widget;
    if (w is DecoratedBox) take(w.decoration);
    if (w is Container) take(w.decoration);
    if (w is AnimatedContainer) take(w.decoration);
  }
  return shadows;
}

BoxDecoration _decorationOf(WidgetTester tester, Finder finder) {
  final w = tester.widget(finder);
  final d = switch (w) {
    Container(:final decoration) => decoration,
    AnimatedContainer(:final decoration) => decoration,
    DecoratedBox(:final decoration) => decoration,
    _ => null,
  };
  return d! as BoxDecoration;
}

/// The glass panel a pane of the page is built on, found from a row in it.
PremiumGlassPanel _paneOf(WidgetTester tester, Finder row) => tester.widget(
  find.ancestor(of: row, matching: find.byType(PremiumGlassPanel)).first,
);

void main() {
  // Inter, as the app draws it: where the chip's words break depends on it.
  setUpAll(loadScriptFonts);

  group('the depth tokens', () {
    test('exist by night and by day, and differ where the grounds differ', () {
      for (final g in [GlassColors.dark, GlassColors.light]) {
        expect(g.paneShadow, hasLength(2));
        expect(g.avatarShadow, isNotEmpty);
        expect(g.nestedShadow, isNotEmpty);
        expect(g.focusGlow, isNotEmpty);
        expect(g.ambientLight.a, inInclusiveRange(0.01, 0.6));
        expect(g.presenceGlow, inInclusiveRange(0.05, 0.4));
        expect(g.chipTint, inInclusiveRange(0.04, 0.2));
        // Soft, tucked under what casts them: never a halo round the sides
        // bigger than the lift, never a hard black slab.
        for (final s in [...g.paneShadow, ...g.avatarShadow]) {
          expect(s.color.a, lessThan(0.5));
          expect(s.blurRadius, lessThanOrEqualTo(16));
          expect(s.offset.dy, greaterThan(0));
        }
      }
      // Stronger by night, where a shadow has to work harder.
      expect(
        GlassColors.dark.paneShadow.last.color.a,
        greaterThan(GlassColors.light.paneShadow.last.color.a),
      );
      expect(
        GlassColors.dark.avatarShadow.first.color.a,
        greaterThan(GlassColors.light.avatarShadow.first.color.a),
      );
      // The bezel is each ground's own pane.
      expect(
        GlassColors.dark.presenceRing,
        isNot(GlassColors.light.presenceRing),
      );
    });

    test('cross-fade with the theme, every depth token included', () {
      const night = GlassColors.dark;
      const day = GlassColors.light;
      expect(night.lerp(day, 0), _sameDepth(night));
      expect(night.lerp(day, 1), _sameDepth(day));
      final half = night.lerp(day, 0.5);
      expect(half.presenceGlow, closeTo(0.26, 1e-9));
      expect(half.chipTint, closeTo((0.12 + 0.09) / 2, 1e-9));
      expect(
        half.paneShadow.last.color,
        Color.lerp(night.paneShadow.last.color, day.paneShadow.last.color, 0.5),
      );
      expect(
        half.presenceRing,
        Color.lerp(night.presenceRing, day.presenceRing, 0.5),
      );
      expect(half.avatarShadow.single.blurRadius, 10);
      // copyWith keeps what it is not given.
      final copy = night.copyWith(presenceGlow: 0.1);
      expect(copy.presenceGlow, 0.1);
      expect(copy, _sameDepth(night, except: 'presenceGlow'));
    });

    test('a pressed shadow is the same shadow, nearer', () {
      final pressed = AppTheme.pressedShadow(GlassColors.dark.avatarShadow);
      final rest = GlassColors.dark.avatarShadow.single;
      expect(pressed.single.color, rest.color);
      expect(pressed.single.blurRadius, rest.blurRadius * AppTheme.pressedLift);
      expect(pressed.single.offset, rest.offset * AppTheme.pressedLift);
    });
  });

  for (final brightness in Brightness.values) {
    final g = _glass(brightness);
    group('by ${brightness.name}', () {
      testWidgets('the ground and the metadata cast nothing; the panes stand '
          'on the page, the requests\' edge live', (tester) async {
        await _setView(tester);
        final server = populatedServer();
        await http.runWithClient(() async {
          final state = signedInState();
          await _openPage(tester, state, brightness: brightness);
          // The ground: a light, and no shadow of its own.
          final ambient = _inPage(_key('friends-ambient'));
          expect(ambient, findsOneWidget);
          expect(tester.widget<CardLight>(ambient).strength, g.ambientLight.a);
          expect(_shadowsUnder(tester, ambient), isEmpty);
          // Metadata stays flat: the Player ID, the sections' names and
          // counts, the words "Online" and "Offline".
          expect(_shadowsUnder(tester, _key('friends-player-id')), isEmpty);
          for (final head in ['FRIEND REQUESTS', 'FRIENDS']) {
            final line = find.ancestor(
              of: _inPage(find.text(head)),
              matching: find.byType(Row),
            );
            expect(_shadowsUnder(tester, line.first), isEmpty, reason: head);
          }
          expect(_inPage(find.text('Offline')), findsOneWidget);
          // The panes: the theme's pane shadow, the friends' edge lit, the
          // requests' the app's live hairline.
          final friends = _paneOf(tester, _key('friend-u-kavya'));
          expect(friends.elevated, isTrue);
          expect(friends.shadow, g.paneShadow);
          expect(friends.edge, g.paneEdge);
          final requests = _paneOf(tester, _key('friend-accept-41'));
          expect(requests.shadow, g.paneShadow);
          expect(
            requests.edge,
            AppTheme.hairlineColour(brightness, live: true),
          );
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('a lit dot wears its bezel and halo, an offline one '
          'neither', (tester) async {
        await _setView(tester);
        final server = populatedServer();
        await http.runWithClient(() async {
          final state = signedInState();
          await _openPage(tester, state, brightness: brightness);
          final green = friendsGreen(brightness);
          // Meera plays, Arjun is online: both lit.
          for (final id in ['u-meera', 'u-arjun']) {
            final dot = find.descendant(
              of: _key('friend-$id'),
              matching: _key('presence-dot-online'),
            );
            expect(dot, findsOneWidget, reason: id);
            final shadows = _decorationOf(tester, dot).boxShadow!;
            expect(shadows, hasLength(2), reason: id);
            final (halo, ring) = (shadows.first, shadows.last);
            expect(halo.color, green.withValues(alpha: g.presenceGlow));
            expect(halo.blurRadius, Dim.presenceHalo);
            expect(ring.color, g.presenceRing);
            expect(ring.spreadRadius, Dim.presenceRing);
            expect(ring.blurRadius, 0);
            // Still eight across: the bezel and the halo are outside it.
            expect(tester.getSize(dot), const Size.square(PresenceDot.size));
          }
          // Kavya is offline: the plain grey dot, no bezel, no halo.
          final offline = find.descendant(
            of: _key('friend-u-kavya'),
            matching: _key('presence-dot-offline'),
          );
          final quiet = _decorationOf(tester, offline);
          expect(quiet.boxShadow, isNull);
          expect(quiet.color, g.cardMuted);
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('the playing chip carries its game\'s own colour', (
        tester,
      ) async {
        await _setView(tester);
        final games = {
          'u-seen': ('TEEN_PATTI', 'SEEN', 'seen'),
          'u-blind': ('TEEN_PATTI', 'BLIND', 'blind'),
          'u-var': ('TEEN_PATTI', 'VARIATION', 'variation'),
          'u-poker': ('POKER', 'TEXAS_HOLDEM', 'texas_holdem'),
        };
        final server = FakeFriendsServer(
          friends: [
            for (final MapEntry(key: id, value: (game, variant, _))
                in games.entries)
              friendJson(
                id,
                id.substring(2),
                status: 'PLAYING',
                game: game,
                variant: variant,
              ),
            friendJson('u-on', 'On', status: 'ONLINE'),
          ],
        );
        await http.runWithClient(() async {
          final state = signedInState();
          await _openPage(tester, state, brightness: brightness);
          final scheme = Theme.of(
            tester.element(find.byType(FriendsScreen)),
          ).colorScheme;
          for (final MapEntry(key: id, value: (_, _, category))
              in games.entries) {
            final chip = find.descendant(
              of: _key('friend-$id'),
              matching: _key('friend-playing'),
            );
            await tester.ensureVisible(chip);
            expect(chip, findsOneWidget, reason: id);
            final palette = AppTheme.paletteFor(
              scheme,
              category: category,
              bootAmount: 0,
            );
            final decoration = _decorationOf(
              tester,
              find.descendant(of: chip, matching: find.byType(Container)).first,
            );
            final border = decoration.border! as Border;
            expect(
              border.top.color,
              palette.accent.withValues(alpha: PlayingChip.edgeAlpha),
              reason: id,
            );
            expect(decoration.boxShadow, g.nestedShadow, reason: id);
            final gradient = decoration.gradient! as LinearGradient;
            expect(
              gradient.colors.last,
              Color.alphaBlend(
                palette.accent.withValues(alpha: g.chipTint),
                g.wellFill,
              ),
              reason: id,
            );
            final lead = tester.widget<Text>(
              find.descendant(of: chip, matching: find.text('Playing now')),
            );
            expect(lead.style!.color, palette.ink, reason: id);
            expect(lead.style!.fontWeight, FontWeight.w700);
            final where = tester.widget<Text>(
              find.descendant(of: chip, matching: _key('friend-game')),
            );
            expect(
              where.style!.fontSize,
              lessThan(lead.style!.fontSize!),
              reason: 'the game a step under "Playing now"',
            );
          }
          // Online and not playing: no chip at all.
          expect(
            find.descendant(
              of: _key('friend-u-on'),
              matching: _key('friend-playing'),
            ),
            findsNothing,
          );
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('where "Playing now" and the game will not share a line of '
          'the chip, the chip holds the game and "Playing now" keeps its place '
          'on the status line', (tester) async {
        tester.view.physicalSize = const Size(640, 360);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.25;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final server = populatedServer();
        await http.runWithClient(() async {
          final state = signedInState();
          await _openPage(tester, state, brightness: brightness);
          final row = _key('friend-u-meera');
          final chip = find.descendant(
            of: row,
            matching: _key('friend-playing'),
          );
          expect(chip, findsOneWidget);
          expect(
            find.descendant(of: chip, matching: find.text('Playing now')),
            findsNothing,
          );
          expect(
            find.descendant(of: chip, matching: _key('friend-game')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: row,
              matching: find.textContaining('Online  ·  Playing now'),
            ),
            findsOneWidget,
          );
          // One line of the chip: no taller than its words' line, its inset
          // and its hairlines.
          final game = tester.getSize(
            find.descendant(of: chip, matching: _key('friend-game')),
          );
          expect(
            tester.getSize(chip).height,
            lessThanOrEqualTo(
              game.height + PlayingChip.padding.vertical + 2 * Dim.hairline,
            ),
          );
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('a portrait stands on its pane and settles under a finger', (
        tester,
      ) async {
        await _setView(tester);
        final server = populatedServer();
        await http.runWithClient(() async {
          final state = signedInState();
          await _openPage(tester, state, brightness: brightness);
          final row = _key('friend-u-arjun');
          final lift = find.descendant(
            of: row,
            matching: _key('friends-portrait-lift'),
          );
          List<BoxShadow> shadows() => _decorationOf(tester, lift).boxShadow!;
          final highlight = BoxShadow(
            color: g.avatarHighlight,
            spreadRadius: Dim.avatarHalo,
          );
          expect(shadows(), [...g.avatarShadow, highlight]);
          final gesture = await tester.startGesture(tester.getCenter(row));
          await tester.pump(const Duration(milliseconds: 150));
          await tester.pump(Motion.fast);
          expect(shadows(), [
            ...AppTheme.pressedShadow(g.avatarShadow),
            highlight,
          ]);
          // Let go without a tap: a drag off the row.
          await gesture.moveBy(const Offset(0, 80));
          await gesture.up();
          await tester.pump();
          await tester.pump(Motion.fast);
          await tester.pump(Motion.fast);
          expect(shadows(), [...g.avatarShadow, highlight]);
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('the search field is raised, lit, and gold-lit while typed '
          'in; the player found emerges under it', (tester) async {
        await _setView(tester);
        final server = populatedServer();
        server.players['u-asha'] = {
          'player': cardJson('u-asha', 'Asha'),
          'friendStatus': FriendStatus.none,
        };
        await http.runWithClient(() async {
          final state = signedInState();
          await _openPage(tester, state, brightness: brightness);
          await tester.tap(_key('friends-add'));
          await _settle(tester);
          final field = tester.widget<TextField>(
            find.descendant(
              of: _key('friends-id-field'),
              matching: find.byType(TextField),
            ),
          );
          final rest = field.decoration!.enabledBorder! as RaisedFieldBorder;
          final live = field.decoration!.focusedBorder! as RaisedFieldBorder;
          expect(rest.shadows, g.nestedShadow);
          expect(live.shadows, [...g.nestedShadow, ...g.focusGlow]);
          expect(rest.highlight, g.cardHighlight);
          expect(rest.borderSide.color, AppTheme.hairlineColour(brightness));
          expect(
            live.borderSide.color,
            AppTheme.hairlineColour(brightness, live: true),
          );
          // Through the focus animation it stays raised.
          final mid = ShapeBorder.lerp(rest, live, 0.5);
          expect(mid, isA<RaisedFieldBorder>());
          expect((mid! as RaisedFieldBorder).shadows, hasLength(2));

          await tester.enterText(_key('friends-id-field'), 'u-asha');
          await tester.tap(_key('friends-search'));
          await tester.pump();
          await tester.pump();
          final card = _key('friend-result-u-asha');
          expect(card, findsOneWidget);
          final fade = find
              .descendant(of: card, matching: find.byType(Opacity))
              .first;
          expect(tester.widget<Opacity>(fade).opacity, lessThan(1));
          await _settle(tester);
          expect(tester.widget<Opacity>(fade).opacity, 1);
          // And it stands on the page as every pane does.
          expect(_paneOf(tester, find.text('Asha')).shadow, g.paneShadow);
          await _unmount(tester, state);
        }, () => server.client);
      });

      testWidgets('the empty state\'s glyph stands on a medallion', (
        tester,
      ) async {
        await _setView(tester);
        final server = FakeFriendsServer();
        await http.runWithClient(() async {
          final state = signedInState();
          await _openPage(tester, state, brightness: brightness);
          final medallion = _inPage(_key('friends-empty-medallion'));
          expect(medallion, findsOneWidget);
          // The glyph's own box, as it stood.
          expect(tester.getSize(medallion), const Size.square(28));
          expect(_shadowsUnder(tester, medallion), g.nestedShadow);
          await _unmount(tester, state);
        }, () => server.client);
      });
    });
  }
}

/// A [GlassColors] whose depth tokens are [expected]'s — every one but
/// [except].
Matcher _sameDepth(
  GlassColors expected, {
  String? except,
}) => predicate<GlassColors>((g) {
  bool same(String name, Object a, Object b) => name == except || a == b;
  bool shadows(String name, List<BoxShadow> a, List<BoxShadow> b) =>
      name == except ||
      (a.length == b.length &&
          [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x));
  return same('ambientLight', g.ambientLight, expected.ambientLight) &&
      shadows('paneShadow', g.paneShadow, expected.paneShadow) &&
      same('paneEdge', g.paneEdge, expected.paneEdge) &&
      same('rowRule', g.rowRule, expected.rowRule) &&
      same('rowRuleLight', g.rowRuleLight, expected.rowRuleLight) &&
      shadows('avatarShadow', g.avatarShadow, expected.avatarShadow) &&
      same('avatarHighlight', g.avatarHighlight, expected.avatarHighlight) &&
      shadows('nestedShadow', g.nestedShadow, expected.nestedShadow) &&
      same('chipTint', g.chipTint, expected.chipTint) &&
      same('presenceGlow', g.presenceGlow, expected.presenceGlow) &&
      same('presenceRing', g.presenceRing, expected.presenceRing) &&
      shadows('focusGlow', g.focusGlow, expected.focusGlow);
}, 'the depth tokens of $expected');
