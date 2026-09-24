// The lobby's polish (owner, 24 Sep 2026): one accent a game mode — "SEEN:
// Gold. BLIND: Cyan / Blue. VARIATION: Purple. PRIVATE TABLE: Emerald / Green"
// — spent on small things and never on a whole card; cards that are the same
// neutral card by day and by night, lit from behind by an ambient light rather
// than a coloured disc; the boot as the largest figure on a table card; keys
// that carry their mode's colour; and a top bar whose wallets stand in a group
// of their own without the player's name losing a letter.
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
];

GameState _state() {
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
      'chips': 324500,
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
      expect(glass.glowStrength, inInclusiveRange(0.08, 0.15));
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
      expect(glass.glowStrength, inInclusiveRange(0.20, 0.30));
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
}
