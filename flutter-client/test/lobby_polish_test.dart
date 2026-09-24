// The lobby's polish (owner, 24 Sep 2026): one accent a game mode — "SEEN:
// Gold. BLIND: Cyan / Blue. VARIATION: Purple. PRIVATE TABLE: Emerald / Green"
// — spent on small things and never on a whole card; cards that are the same
// neutral card by day and by night, lit from behind by an ambient light rather
// than a coloured disc; the boot as the largest figure on a table card; keys
// that carry their mode's colour; and a top bar whose wallets stand in a group
// of their own without the player's name losing a letter.
//
// And its final pass, the same day: the tint turned down (about 5% by day, 18%
// by night), the boot "prominent but not dominating", a rail that stops on
// whole cards and a glimpse of the next rather than on a card two-thirds shown,
// the insides of a card on a 4dp grid, and a card's words that neither run
// under its corner keys nor lose a line when a phone has less room than they
// want.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/game_card.dart';
import 'package:teenpatti/widgets/glass_orb.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_ground.dart';

const _menu = <Map<String, Object>>[
  {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
  {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
  {'category': 'blind', 'bootAmount': 5000, 'maxChips': 50000000},
  {'category': 'blind', 'bootAmount': 50000, 'maxChips': 1000000000},
  {'category': 'blind', 'bootAmount': 1000000, 'minChips': 500000000},
  {'category': 'variation', 'bootAmount': 50000, 'maxChips': 1000000000},
  {'category': 'variation', 'bootAmount': 1000000, 'minChips': 500000000},
  {
    'category': 'omaha',
    'bootAmount': 50000,
    'minChips': 500000,
    'game': 'poker',
  },
  // The card with the most to say: an ante, a buy-in, the cards dealt, the
  // exchange and the entry under a two-line blurb.
  {
    'category': 'five_card_draw',
    'bootAmount': 50000,
    'minChips': 500000,
    'minBuyIn': 500000,
    'ante': 50000,
    'holeCards': 5,
    'maxDiscards': 3,
    'game': 'poker',
  },
];

GameState _state({int chips = 324500}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = AppLang.english
    ..screen = Screen.lobby
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': _menu,
    })
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Guest0E00B',
      'chips': chips,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
      // The 4-hour bonus counting down in the top bar, as a player usually
      // finds it: the bar's widest neighbour of the name.
      'rewards': {
        'milestoneAvailable': false,
        'milestoneReward': 25000,
        'handsToNextMilestone': 25,
        'bonusReward': 10000,
        'bonusReadyAt': DateTime.now()
            .add(const Duration(hours: 3, minutes: 12))
            .millisecondsSinceEpoch,
        'bonusAvailable': false,
        'dailyReward': 100000,
        'dailyHammers': 1,
        'dailyReadyAt': 0,
        'dailyAvailable': true,
      },
    });
}

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

Future<void> _pumpLobby(
  WidgetTester tester,
  GameState state, {
  required Size screen,
  required Brightness brightness,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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
        theme: brightness == Brightness.dark
            ? AppTheme.dark(sound: false)
            : AppTheme.light(sound: false),
        builder: (context, child) => GlassBudget(child: child!),
        home: const LobbyScreen(),
      ),
    ),
  );
  await _settle(tester);
}

/// The cards' entrances, the stake's count-up and the room light's fade.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// WCAG contrast of two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// A card's body as it stands on the ground: its lighter end laid over the
/// screen's ground colour.
Color _cardOn(GlassColors glass, {required bool top}) =>
    Color.alphaBlend(top ? glass.cardFill : glass.cardFillEnd, glass.ground);

bool _sameRgb(Color a, Color b) =>
    (a.r - b.r).abs() < 0.002 &&
    (a.g - b.g).abs() < 0.002 &&
    (a.b - b.b).abs() < 0.002;

Finder _private(String type) => find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == type,
  skipOffstage: false,
);

/// A render box's own rectangle on the screen, through every scale and
/// transform above it.
Rect _onScreen(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

/// The rail on screen: the lobby's one horizontal list of cards.
Finder get _rail => find.byWidgetPredicate(
  (w) =>
      w is ListView &&
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('lobby-rail:'),
);

/// How much of each card on the rail stands inside the rail, 0 to 1.
List<double> _cardsShown(WidgetTester tester) {
  final rail = _onScreen(tester.renderObject<RenderBox>(_rail));
  return [
    for (final card
        in find
            .descendant(of: _rail, matching: find.byType(AspectRatio))
            .evaluate())
      if (card.renderObject case final RenderBox box when box.hasSize)
        () {
          final r = _onScreen(box);
          final shown =
              (r.right.clamp(rail.left, rail.right) -
                  r.left.clamp(rail.left, rail.right)) /
              r.width;
          return shown;
        }(),
  ];
}

/// The discs of every table card's two corner keys: a 28dp disc centred in
/// each 44dp key.
List<Rect> _cornerDiscs(WidgetTester tester) => [
  for (final key in _private('_CardCornerKey').evaluate())
    if (key.renderObject case final RenderBox box when box.hasSize)
      _onScreen(box).deflate((Dim.minTouch - 28) / 2),
];

/// A small column to lay out alone, [width] wide.
Future<RenderCardColumn> _pumpColumn(
  WidgetTester tester, {
  required double width,
  double? maxHeight,
  Size keepClear = Size.zero,
  required List<Widget> children,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: CardColumn(
            maxHeight: maxHeight,
            keepClear: keepClear,
            children: children,
          ),
        ),
      ),
    ),
  );
  return tester.renderObject<RenderCardColumn>(find.byType(CardColumn));
}

/// A block of a column: as wide as it is allowed, [height] tall.
Widget _block(String key, double height) =>
    SizedBox(key: ValueKey(key), width: double.infinity, height: height);

void main() {
  setUpAll(_loadInter);

  group('the game modes', () {
    for (final brightness in Brightness.values) {
      final scheme =
          (brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light())
              .colorScheme;
      final glass = brightness == Brightness.dark
          ? GlassColors.dark
          : GlassColors.light;
      TablePalette of(String category, [int boot = 200]) =>
          AppTheme.paletteFor(scheme, category: category, bootAmount: boot);

      test('have one accent each, at every stake (${brightness.name})', () {
        // Blind at 10 Lakh is the blind table's colour, not a purple of its
        // own, and violet is variation's.
        for (final boot in [200, 5000, 50000, 1000000]) {
          expect(of(TableCategory.blind, boot).accent, scheme.tertiary);
          expect(
            of(TableCategory.variation, boot).accent,
            AppTheme.violetPalette(scheme).accent,
          );
        }
        expect(of(TableCategory.seen).accent, AppTheme.gold);
        expect(AppTheme.privatePalette(scheme).accent, scheme.primary);
        final accents = {
          of(TableCategory.seen).accent,
          of(TableCategory.blind).accent,
          of(TableCategory.variation).accent,
          of(TableCategory.omaha).accent,
          AppTheme.privatePalette(scheme).accent,
        };
        expect(accents, hasLength(5), reason: 'five modes, five colours');
      });

      test('write in an ink that reads on a card (${brightness.name})', () {
        for (final (name, palette) in [
          ('seen', of(TableCategory.seen)),
          ('blind', of(TableCategory.blind)),
          ('variation', of(TableCategory.variation)),
          ('poker', of(TableCategory.texasHoldem)),
          ('private', AppTheme.privatePalette(scheme)),
        ]) {
          for (final top in [true, false]) {
            expect(
              _contrast(palette.ink, _cardOn(glass, top: top)),
              greaterThanOrEqualTo(4.5),
              reason: '$name on the card',
            );
          }
        }
        // Money, in the lobby's gold.
        expect(
          _contrast(AppTheme.goldInk(brightness), _cardOn(glass, top: false)),
          greaterThanOrEqualTo(4.5),
        );
        // And the card's quietest words.
        expect(
          _contrast(
            Color.alphaBlend(glass.cardMuted, _cardOn(glass, top: false)),
            _cardOn(glass, top: false),
          ),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
  });

  group('the card', () {
    test('by day is white on a grey hairline with a soft shadow', () {
      const glass = GlassColors.light;
      for (final fill in [glass.cardFill, glass.cardFillEnd]) {
        expect(_sameRgb(fill, Colors.white), isTrue);
        expect(fill.a, inInclusiveRange(0.94, 0.97));
      }
      expect(glass.cardBorder, const Color(0xFFE2E4E7));
      // "Light: about 3-6% tint; the card mostly white" (the final pass).
      expect(glass.glowStrength, inInclusiveRange(0.03, 0.06));
    });

    test('by night is charcoal on a white hairline with a deeper shadow', () {
      const glass = GlassColors.dark;
      for (final fill in [glass.cardFill, glass.cardFillEnd]) {
        expect(fill.a, inInclusiveRange(0.88, 0.92));
        for (final channel in [fill.r, fill.g, fill.b]) {
          expect(channel * 255, inInclusiveRange(25, 45));
        }
      }
      expect(_sameRgb(glass.cardBorder, Colors.white), isTrue);
      expect(glass.cardBorder.a, closeTo(0.10, 0.01));
      // "Dark: about 15-25% ambient; no neon."
      expect(glass.glowStrength, inInclusiveRange(0.15, 0.25));
      // A stronger light, reaching further, and a darker shadow than by day.
      expect(glass.glowReach, greaterThan(GlassColors.light.glowReach));
      double weight(List<BoxShadow> s) =>
          s.fold(0, (sum, b) => sum + b.color.a);
      expect(
        weight(glass.cardShadow),
        greaterThan(weight(GlassColors.light.cardShadow)),
      );
    });

    test('is rounder than a panel', () {
      expect(Radii.xl, inInclusiveRange(20, 26));
      expect(Radii.xl, greaterThan(Radii.lg));
    });
  });

  for (final screen in [const Size(640, 360), const Size(915, 411)]) {
    for (final brightness in Brightness.values) {
      final name =
          '${screen.width.toInt()}x${screen.height.toInt()} ${brightness.name}';

      testWidgets('at $name every card is a GameCard lit from behind, with '
          'no coloured disc round it', (tester) async {
        final state = _state();
        await _pumpLobby(tester, state, screen: screen, brightness: brightness);
        expect(tester.takeException(), isNull);
        // The front: Teen Patti, Poker, the private room.
        expect(find.byType(GameCard, skipOffstage: false), findsNWidgets(3));
        expect(find.byType(GlassOrb, skipOffstage: false), findsNothing);
        expect(find.byType(CardLight, skipOffstage: false), findsNWidgets(3));

        state.openLobbyCategory(TableCategory.blind);
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(GlassOrb, skipOffstage: false), findsNothing);
        await _unmount(tester);
        state.dispose();
      });

      testWidgets('at $name the boot is the largest figure on a table card, '
          'and the key carries its mode\'s colour', (tester) async {
        final state = _state()..openLobbyCategory(TableCategory.blind);
        await _pumpLobby(tester, state, screen: screen, brightness: brightness);
        expect(tester.takeException(), isNull);
        final scheme = Theme.of(
          tester.element(find.byType(LobbyScreen)),
        ).colorScheme;
        final blind = AppTheme.paletteFor(
          scheme,
          category: TableCategory.blind,
          bootAmount: 200,
        );

        final cards = find.ancestor(
          of: find.byType(GameCard, skipOffstage: false),
          matching: find.byType(AspectRatio, skipOffstage: false),
        );
        expect(cards, findsWidgets);
        for (final card in cards.evaluate()) {
          double? bootSize;
          var others = 0.0;
          final seen = <String>[];
          void visit(Element e) {
            final widget = e.widget;
            if (widget is RichText) {
              final text = widget.text;
              final size = text.style?.fontSize ?? 0;
              seen.add('${text.toPlainText()}@$size');
              if (const {
                '200',
                '5,000',
                '50,000',
                '10 Lakh',
              }.contains(text.toPlainText())) {
                bootSize = size;
              } else if (size > others) {
                others = size;
              }
            }
            e.visitChildren(visit);
          }

          card.visitChildren(visit);
          expect(bootSize, isNotNull, reason: 'the boot, among $seen');
          expect(bootSize, greaterThan(others * 1.4), reason: '$seen');
          // "Prominent but not dominating" (the final pass): under twice the
          // next largest words on the card, where it had been more.
          expect(bootSize, lessThanOrEqualTo(others * 2), reason: '$seen');
        }

        final keys = _private('_SitCapsule').evaluate().toList();
        expect(keys, isNotEmpty);
        for (final key in keys) {
          // The capsule's own box: the first Container it builds.
          Container? box;
          void visit(Element e) {
            if (box != null) return;
            final widget = e.widget;
            if (widget is Container) {
              box = widget;
              return;
            }
            e.visitChildren(visit);
          }

          key.visitChildren(visit);
          final edge =
              ((box!.decoration! as BoxDecoration).border! as Border).top.color;
          // An open table's key is edged in blind's sapphire; a shut one's in
          // the card's own quiet hairline.
          expect(
            _sameRgb(edge, blind.accent) ||
                edge == GlassColors.of(key).cardBorder,
            isTrue,
            reason: '$edge',
          );
        }
        await _unmount(tester);
        state.dispose();
      });
    }
  }

  testWidgets('the wallets stand in a pill of their own beside the Shop, and '
      'the name keeps its letters on a 640dp phone', (tester) async {
    final state = _state();
    await _pumpLobby(
      tester,
      state,
      screen: const Size(640, 360),
      brightness: Brightness.dark,
    );
    final pill = _private('_WalletPill');
    expect(pill, findsOneWidget);
    expect(
      find.descendant(of: pill, matching: find.text(formatChips(324500))),
      findsOneWidget,
    );
    // Before the pill the name had 101.5dp here; the tight bar's closer steps
    // pay for the pill's margin and a little more.
    final name = tester.renderObject<RenderParagraph>(find.text('Guest0E00B'));
    expect(name.size.width, greaterThanOrEqualTo(101));
    await _unmount(tester);
    state.dispose();
  });

  testWidgets('the room takes the open level\'s colour as its light, and '
      'none at the front', (tester) async {
    final state = _state();
    await _pumpLobby(
      tester,
      state,
      screen: const Size(915, 411),
      brightness: Brightness.dark,
    );
    LobbyGround ground() => tester.widget(find.byType(LobbyGround));
    expect(ground().accent, isNull);

    state.openLobbyCategory(TableCategory.variation);
    await _settle(tester);
    final scheme = Theme.of(
      tester.element(find.byType(LobbyScreen)),
    ).colorScheme;
    expect(ground().accent, AppTheme.violetPalette(scheme).accent);
    expect(ground().accentStrength, greaterThan(1));

    state.closeLobbyLevel();
    state.closeLobbyLevel();
    await _settle(tester);
    expect(ground().accent, isNull);
    await _unmount(tester);
    state.dispose();
  });

  test('a card is spaced on the 4dp grid, and the app\'s own steps are left '
      'as they were', () {
    for (final step in [
      CardSpace.s4,
      CardSpace.s8,
      CardSpace.s12,
      CardSpace.s16,
      CardSpace.s20,
      CardSpace.s24,
      CardSpace.s32,
    ]) {
      expect(step % 4, 0, reason: '$step');
    }
    // Every other screen is laid out on these.
    expect(
      [
        Space.xxs,
        Space.xs,
        Space.sm,
        Space.md,
        Space.lg,
        Space.xl,
        Space.xxl,
        Space.xxxl,
      ],
      [2, 4, 6, 10, 14, 20, 28, 40],
    );
  });

  group('the rail', () {
    // Where the rail puts its cards: Space.xl in, then the way back when there
    // is one (a quarter of a card, never narrower than a finger and its
    // margins) and its gap, then each card and the gap after it. The share of
    // the first card that does not stand whole Space.xl clear of the edge, or
    // null when every card does.
    double? partShown({
      required double side,
      required double width,
      required int cards,
      required bool backTile,
    }) {
      var left =
          Space.xl +
          (backTile
              ? math.max(Dim.minTouch + Space.xl, side * 0.26) + Space.lg
              : 0.0);
      for (var i = 0; i < cards; i++, left += side + Space.lg) {
        if (left + side + Space.xl <= width) continue;
        return (width - left) / side;
      }
      return null;
    }

    // Phones and a tablet as the rail finds them: its width, and the side its
    // height allows.
    for (final (width, fit) in [
      (732.0, 270.6),
      (844.0, 252.0),
      (891.0, 269.6),
      (915.0, 270.6),
      (932.0, 285.4),
      (1280.0, 400.0),
    ]) {
      for (final (cards, backTile) in [(3, false), (4, true), (5, true)]) {
        test(
          '$width wide, $cards cards${backTile ? ' behind the way back' : ''}'
          ': whole cards and a glimpse, from no more than the height '
          'allows',
          () {
            final side = lobbyRailSide(
              fit: fit,
              width: width,
              cards: cards,
              backTile: backTile,
            );
            expect(side, lessThanOrEqualTo(fit));
            expect(side, greaterThanOrEqualTo(196));
            final shown = partShown(
              side: side,
              width: width,
              cards: cards,
              backTile: backTile,
            );
            if (shown != null) expect(shown, inInclusiveRange(0.15, 0.6));
            // And it gave up no more than it had to: half a dp more, and the
            // rail no longer stops cleanly.
            if (side < fit) {
              final bigger = partShown(
                side: side + 0.5,
                width: width,
                cards: cards,
                backTile: backTile,
              );
              expect(bigger != null && (bigger < 0.15 || bigger > 0.6), isTrue);
            }
          },
        );
      }
    }

    test('keeps the side its height allows where only smaller cards than a '
        'card\'s words fit in would stop cleanly', () {
      // A 640dp phone's front: its third card, the private room, shows 61%;
      // every card whole would take 190dp cards, too small for that card.
      expect(
        lobbyRailSide(fit: 227, width: 640, cards: 3, backTile: false),
        227,
      );
      // Every card whole at the height's side: nothing to give up.
      expect(
        lobbyRailSide(fit: 400, width: 1280, cards: 3, backTile: false),
        400,
      );
    });

    for (final screen in [
      const Size(732, 412),
      const Size(844, 390),
      const Size(891, 411),
      const Size(915, 412),
      const Size(932, 430),
      const Size(1280, 800),
    ]) {
      final name = '${screen.width.toInt()}x${screen.height.toInt()}';
      testWidgets('at $name every level stops on whole cards and a glimpse of '
          'the next, and ends as far from the edge as it starts', (
        tester,
      ) async {
        final state = _state();
        await _pumpLobby(
          tester,
          state,
          screen: screen,
          brightness: Brightness.dark,
        );
        for (final open in <void Function()>[
          () {},
          () => state.openLobbyEngine(TableEngine.teenPatti),
          () => state.openLobbyCategory(TableCategory.blind),
        ]) {
          open();
          await _settle(tester);
          expect(tester.takeException(), isNull);
          final level = tester.widget<ListView>(_rail).key;
          for (final shown in _cardsShown(tester)) {
            expect(
              shown <= 0.605 || shown >= 0.995,
              isTrue,
              reason: '$level: a card $shown on screen',
            );
          }

          final scroll = tester.state<ScrollableState>(
            // The rail's own, before any a card holds (the code field's).
            find.descendant(of: _rail, matching: find.byType(Scrollable)).first,
          );
          scroll.position.jumpTo(scroll.position.maxScrollExtent);
          await tester.pump();
          final rail = _onScreen(tester.renderObject<RenderBox>(_rail));
          final last = find
              .descendant(of: _rail, matching: find.byType(AspectRatio))
              .evaluate()
              .map((e) => _onScreen(e.renderObject! as RenderBox))
              .reduce((a, b) => a.right > b.right ? a : b);
          if (scroll.position.maxScrollExtent > 0) {
            expect(
              rail.right - last.right,
              closeTo(Space.xl, 0.5),
              reason: '$level',
            );
          } else {
            expect(
              rail.right - last.right,
              greaterThanOrEqualTo(Space.xl - 0.5),
              reason: '$level',
            );
          }
          scroll.position.jumpTo(0);
          await tester.pump();
        }
        await _unmount(tester);
        state.dispose();
      });
    }
  });

  group('a card\'s column', () {
    testWidgets('where its blocks fit, stands as tall as they are and moves '
        'nothing', (tester) async {
      final column = await _pumpColumn(
        tester,
        width: 200,
        maxHeight: 100,
        children: [_block('a', 30), const CardGap(20), _block('b', 30)],
      );
      expect(column.scale, 1);
      expect(column.squeeze, 0);
      expect(column.size, const Size(200, 80));
      expect(tester.getRect(find.byKey(const ValueKey('b'))).top, 50);
    });

    testWidgets('gives up its air before its words: each gap to half, and '
        'no further than it must', (tester) async {
      final column = await _pumpColumn(
        tester,
        width: 200,
        maxHeight: 75,
        children: [_block('a', 30), const CardGap(20), _block('b', 30)],
      );
      expect(column.scale, 1);
      expect(column.squeeze, closeTo(0.5, 0.001));
      expect(column.size.height, closeTo(75, 0.001));
      expect(tester.getRect(find.byKey(const ValueKey('b'))).top, 45);
      // A rule keeps its line and gives up only its air.
      expect(RenderCardGap(height: 9, line: Colors.black).extentAt(1), 5);
      expect(RenderCardGap(height: 8).extentAt(1), 4);
      expect(RenderCardGap(height: 8).extentAt(0), 8);
    });

    testWidgets('then scales its words down as one, still as wide as the '
        'card', (tester) async {
      final column = await _pumpColumn(
        tester,
        width: 200,
        maxHeight: 50,
        children: [_block('a', 30), const CardGap(20), _block('b', 30)],
      );
      expect(column.squeeze, 1);
      expect(column.scale, lessThan(1));
      expect(column.size.height, lessThanOrEqualTo(50));
      // Laid out wider and scaled back to the card's width, never shrunk
      // towards its left edge.
      for (final key in ['a', 'b']) {
        expect(
          tester.getRect(find.byKey(ValueKey(key))).width,
          closeTo(200, 0.01),
        );
      }
    });

    testWidgets('keeps every block clear of the corner keys, however far it is '
        'scaled', (tester) async {
      // Four blocks where three fit: scaled to 0.75, the third rises beside
      // the keys and is set short of them too.
      const clear = Size(40, 50);
      final column = await _pumpColumn(
        tester,
        width: 200,
        maxHeight: 90,
        keepClear: clear,
        children: [
          for (final key in ['a', 'b', 'c', 'd']) _block(key, 30),
        ],
      );
      expect(column.scale, closeTo(0.75, 0.01));
      final zone = Rect.fromLTWH(
        200 - clear.width,
        0,
        clear.width,
        clear.height,
      );
      for (final key in ['a', 'b', 'c', 'd']) {
        final rect = tester.getRect(find.byKey(ValueKey(key)));
        expect(rect.overlaps(zone), isFalse, reason: '$key at $rect');
      }
      // Below the keys, a block has the card's whole width.
      expect(
        tester.getRect(find.byKey(const ValueKey('d'))).width,
        closeTo(200, 0.01),
      );
    });
  });

  for (final scale in [1.0, 1.25]) {
    testWidgets('on a 640dp phone at text x$scale no card cuts a line short, '
        'and no card\'s words run under its corner keys', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final (chips, open) in <(int, void Function(GameState))>[
        (324500, (_) {}),
        (324500, (s) => s.openLobbyCategory(TableCategory.blind)),
        (600000000, (s) => s.openLobbyCategory(TableCategory.blind)),
        (600000000, (s) => s.openLobbyCategory(TableCategory.fiveCardDraw)),
      ]) {
        final state = _state(chips: chips);
        open(state);
        await _pumpLobby(
          tester,
          state,
          screen: const Size(640, 360),
          brightness: Brightness.light,
        );
        expect(tester.takeException(), isNull);
        final level = tester.widget<ListView>(_rail).key;
        final discs = _cornerDiscs(tester);
        final words = find.descendant(
          of: find.byType(CardColumn),
          matching: find.byType(RichText),
        );
        expect(words, findsWidgets);
        for (final e in words.evaluate()) {
          final paragraph = e.renderObject! as RenderParagraph;
          final line = paragraph.text.toPlainText();
          expect(
            paragraph.didExceedMaxLines,
            isFalse,
            reason: '$level: "$line" cut short',
          );
          final rect = _onScreen(paragraph);
          for (final disc in discs) {
            expect(
              rect.overlaps(disc),
              isFalse,
              reason: '$level: "$line" at $rect under a key at $disc',
            );
          }
        }
        await _unmount(tester);
        state.dispose();
      }
    });
  }
}
