// The store polish (owner's brief, 26 Sep 2026: "a UI POLISH task, NOT a
// complete redesign"): one product card for every pack on every shelf, its
// value the largest thing on it, one figure size a shelf, badges on the packs
// the owner marked and on no others, a glow a quarter less of the card and
// kept in its top right corner, a purchase key that reads as a key, a card
// that presses down to 0.97; round shelf keys that stop on whole keys; the
// worn picture's head on the Pictures shelf; and cards that fill their row.
//
// Laid out for real with Inter and the phone's Noto fonts for the Indic
// scripts (script_fonts.dart), at the sizes the game is checked on. A
// RenderFlex overflow fails a test by itself.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/glass_components.dart';
import 'package:teenpatti/widgets/glass_orb.dart';
import 'package:teenpatti/widgets/picture_shelf.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

final _tabs = _private('_StoreTabs');
final _chipCards = _private('_PackCard');
final _premiumCards = _private('_PremiumPackCard');
final _countCards = _private('_CountPackCard');
final _badges = _private('_StoreBadge');
final _keys = _private('_PriceButton');

/// A picture the player wears: a rental with a week left.
const _lion = 3;

GameState _state({
  Screen screen = Screen.lobby,
  AppLang lang = AppLang.english,
}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = screen
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 20740000,
      'diamond': 9,
      'hammer': 45,
      'missile': 3,
      'activePictureId': _lion,
    })
    ..pictures = [
      const ProfilePicture(
        id: 1,
        name: 'Bear',
        url: '',
        type: 'FREE',
        cost: 0,
        durationDays: 0,
        owned: true,
        expiresAt: 0,
      ),
      ProfilePicture(
        id: _lion,
        name: 'Lion',
        url: '',
        type: 'PREMIUM',
        cost: 2500000,
        durationDays: 10,
        owned: true,
        expiresAt: DateTime.now()
            .add(const Duration(days: 6, hours: 4))
            .millisecondsSinceEpoch,
      ),
    ];
}

Future<void> _openStore(
  WidgetTester tester, {
  required GameState state,
  required FeedbackSettings feedback,
  required StoreTab tab,
  Size screen = const Size(640, 360),
  double scale = 1.0,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  late BuildContext host;
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withScriptFallback(AppTheme.dark(sound: false)),
        builder: (context, child) => GlassBudget(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: child,
          ),
        ),
        home: Builder(
          builder: (context) {
            host = context;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  unawaited(showChipStore(host, opensOn: tab));
  // The sheet's entrance, and the packs set out one stagger apart; a card's
  // entrance starts on the frame after its delay has run out.
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

/// Takes the store and its host down, so the next open starts afresh.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _close(
  WidgetTester tester,
  GameState state,
  FeedbackSettings feedback,
) async {
  await _unmount(tester);
  state.dispose();
  feedback.dispose();
}

/// The shelf keys: one InkWell each.
Finder get _keyWells =>
    find.descendant(of: _tabs, matching: find.byType(InkWell));

/// The face of a key — the scale inside its InkWell, not PressScale's.
AnimatedScale _face(WidgetTester tester, Finder well) =>
    tester.widget<AnimatedScale>(
      find.descendant(of: well, matching: find.byType(AnimatedScale)),
    );

/// The texts of [card] that are its figure: the largest type on it.
double _fontOf(WidgetTester tester, Finder text) =>
    tester.widget<Text>(text).style!.fontSize!;

void main() {
  setUpAll(loadScriptFonts);

  group('the shelf keys', () {
    for (final (size, scale) in const [
      (Size(640, 360), 1.25),
      (Size(891, 411), 1.0),
    ]) {
      final name = '${size.width.toInt()}x${size.height.toInt()} x$scale';
      testWidgets('are round and the touch floor across at $name, the one '
          'that is on full size and the others drawn down', (tester) async {
        final state = _state();
        final feedback = FeedbackSettings();
        for (final tab in StoreTab.values) {
          await _openStore(
            tester,
            state: state,
            feedback: feedback,
            tab: tab,
            screen: size,
            scale: scale,
          );
          final wells = _keyWells;
          expect(wells, findsNWidgets(StoreTab.values.length), reason: '$tab');
          for (var i = 0; i < StoreTab.values.length; i++) {
            final well = wells.at(i);
            // A circle, never the header's height: on a two-line header a
            // key used to be a 44 by 69dp capsule.
            expect(tester.getSize(well), const Size(44, 44), reason: '$tab');
            final on = tester.widget<InkWell>(well).onTap == null;
            expect(_face(tester, well).scale, on ? 1 : 0.92, reason: '$tab');
          }
          // Exactly one key is on.
          expect(
            [
              for (var i = 0; i < StoreTab.values.length; i++)
                tester.widget<InkWell>(wells.at(i)).onTap == null,
            ].where((on) => on),
            hasLength(1),
          );
          expect(tester.takeException(), isNull, reason: '$tab');
          await _unmount(tester);
        }
        state.dispose();
        feedback.dispose();
      });
    }

    for (final lang in const [AppLang.english, AppLang.hindi]) {
      testWidgets('stop on whole keys with the one that is on in view, at '
          '640x360 x1.25 in ${lang.englishName}', (tester) async {
        final state = _state(lang: lang);
        final feedback = FeedbackSettings();
        for (final tab in StoreTab.values) {
          await _openStore(
            tester,
            state: state,
            feedback: feedback,
            tab: tab,
            scale: 1.25,
          );
          final strip = find
              .ancestor(of: _tabs, matching: find.byType(Scrollable))
              .first;
          final position = tester.state<ScrollableState>(strip).position;
          // The strip is cut on this phone: six keys do not fit.
          expect(position.maxScrollExtent, greaterThan(0));
          const step = 44.0 + 6.0;
          final off = position.pixels % step;
          expect(
            math.min(off, step - off),
            lessThan(0.5),
            reason: '$tab: the strip stopped part-way into a key',
          );
          final view = tester.getRect(strip);
          final wells = _keyWells;
          for (var i = 0; i < StoreTab.values.length; i++) {
            if (tester.widget<InkWell>(wells.at(i)).onTap != null) continue;
            final key = tester.getRect(wells.at(i));
            expect(
              view.inflate(0.5).contains(key.topLeft) &&
                  view.inflate(0.5).contains(key.bottomRight),
              isTrue,
              reason: '$tab: $key is not inside the strip $view',
            );
          }
          await _unmount(tester);
        }
        state.dispose();
        feedback.dispose();
      });
    }
  });

  group('the pack cards', () {
    for (final (size, scale) in const [
      (Size(640, 360), 1.0),
      (Size(640, 360), 1.25),
      (Size(592, 360), 1.25),
      (Size(891, 411), 1.0),
      (Size(915, 412), 1.25),
      (Size(1280, 800), 1.0),
    ]) {
      final name = '${size.width.toInt()}x${size.height.toInt()} x$scale';
      testWidgets('fill their row at $name, stand one size, and leave a '
          'glimpse of the next row', (tester) async {
        final state = _state();
        final feedback = FeedbackSettings();
        await _openStore(
          tester,
          state: state,
          feedback: feedback,
          tab: StoreTab.chips,
          screen: size,
          scale: scale,
        );
        final cards = [
          for (var i = 0; i < chipPacks.length; i++)
            tester.getRect(_chipCards.at(i)),
        ];
        for (final card in cards) {
          expect(card.size.width, closeTo(cards.first.width, 0.01));
          expect(card.size.height, closeTo(cards.first.height, 0.01));
        }
        final row = cards.where((c) => (c.top - cards.first.top).abs() < 1);
        expect(row.length, greaterThan(1));
        // The body: the scroll view the cards stand in, less its padding
        // (4 left, 10 right for the scrollbar).
        final body = tester.getRect(
          find.ancestor(
            of: _chipCards.first,
            matching: find.byType(Scrollable),
          ),
        );
        final right = row.map((c) => c.right).reduce(math.max);
        expect(
          right,
          greaterThan(body.right - 10 - row.length - 0.5),
          reason: 'the row stops short of the body at $right in $body',
        );
        expect(right, lessThanOrEqualTo(body.right - 10 + 0.5));
        // A card is never taller than 80% of the body, so the next row shows.
        expect(cards.first.height, lessThanOrEqualTo(body.height * 0.8 + 1));
        expect(tester.takeException(), isNull);
        await _close(tester, state, feedback);
      });
    }

    testWidgets('set a shelf\'s figures in one size, the largest type on each '
        'card, before the price, the badge and the lines', (tester) async {
      final state = _state();
      final feedback = FeedbackSettings();
      await _openStore(
        tester,
        state: state,
        feedback: feedback,
        tab: StoreTab.chips,
        scale: 1.25,
      );
      double? shelf;
      for (final (i, p) in chipPacks.indexed) {
        final card = _chipCards.at(i);
        final figure = find.descendant(
          of: card,
          matching: find.text(formatChips(p.chips)),
        );
        final size = _fontOf(tester, figure);
        shelf ??= size;
        // "12 Crore" stood larger than "5.28 Crore" beside it.
        expect(size, shelf, reason: formatChips(p.chips));
        final others = [
          for (final text in tester.widgetList<Text>(
            find.descendant(of: card, matching: find.byType(Text)),
          ))
            if (text.data != formatChips(p.chips)) text.style?.fontSize ?? 0,
        ];
        expect(others, isNotEmpty);
        expect(size, greaterThan(others.reduce(math.max)), reason: '$i');
        // The price is the next thing read: at least the size of the lines.
        final price = find.descendant(
          of: find.descendant(of: card, matching: _keys),
          matching: find.byType(Text),
        );
        final lines = find.descendant(
          of: card,
          matching: find.text(
            chipPacks[i].bonusPercent == 0
                ? '—'
                : '${chipPacks[i].bonusPercent}%',
          ),
        );
        expect(
          _fontOf(tester, price),
          greaterThanOrEqualTo(_fontOf(tester, lines)),
        );
      }
      await _close(tester, state, feedback);

      for (final tab in [StoreTab.diamonds, StoreTab.hammers]) {
        final other = _state();
        final otherFeedback = FeedbackSettings();
        await _openStore(
          tester,
          state: other,
          feedback: otherFeedback,
          tab: tab,
          scale: 1.25,
        );
        final counts = tab == StoreTab.diamonds
            ? [for (final p in diamondPacks) '${p.diamonds}']
            : [for (final p in hammerPacks) '${p.hammers}'];
        final sizes = {
          for (final (i, count) in counts.indexed)
            _fontOf(
              tester,
              find.descendant(
                of: _countCards.at(i),
                matching: find.text(count),
              ),
            ),
        };
        expect(sizes, hasLength(1), reason: '$tab');
        await _close(tester, other, otherFeedback);
      }
    });

    testWidgets('wear a badge only where the owner marked the pack, one height '
        'on a shelf, the marks\' glyphs on every shelf', (tester) async {
      const t = Strings(AppLang.english);
      final marked = {
        StoreTab.chips:
            chipPacks.where((p) => p.mark != ShelfMark.none).length +
            premiumPacks.length,
        StoreTab.diamonds: diamondPacks
            .where((p) => p.mark != ShelfMark.none)
            .length,
        StoreTab.hammers: hammerPacks
            .where((p) => p.mark != ShelfMark.none)
            .length,
        StoreTab.missiles: missilePacks
            .where((p) => p.mark != ShelfMark.none)
            .length,
      };
      for (final MapEntry(key: tab, value: count) in marked.entries) {
        final state = _state();
        final feedback = FeedbackSettings();
        await _openStore(tester, state: state, feedback: feedback, tab: tab);
        expect(_badges, findsNWidgets(count), reason: '$tab');
        // One height for every badge on cards of one size.
        for (final cards in [_chipCards, _premiumCards, _countCards]) {
          final found = find.descendant(of: cards, matching: _badges);
          final heights = {
            for (var i = 0; i < found.evaluate().length; i++)
              (tester.getSize(found.at(i)).height * 100).roundToDouble() / 100,
          };
          expect(heights.length, lessThanOrEqualTo(1), reason: '$tab');
        }
        await _close(tester, state, feedback);
      }
      // The chip packs' marks carry the same glyphs as the other shelves'.
      final state = _state();
      final feedback = FeedbackSettings();
      await _openStore(
        tester,
        state: state,
        feedback: feedback,
        tab: StoreTab.chips,
      );
      expect(find.text('⭐ ${t.posPopular}'), findsNWidgets(2));
      expect(find.text('🔥 ${t.posBestValue}'), findsNWidgets(2));
      expect(find.text(t.posStarter), findsOneWidget);
      expect(find.text(t.posPremium), findsOneWidget);
      expect(
        find.text(t.posPremiumPackage),
        findsNWidgets(premiumPacks.length),
      );
      // An unmarked pack no longer says its bonus on a plate as well as on
      // the line under its figure.
      expect(find.text('20% ${t.storeBonus}'), findsNothing);
      await _close(tester, state, feedback);
    });

    testWidgets('keep one soft light each, in the card\'s top right corner', (
      tester,
    ) async {
      final state = _state();
      final feedback = FeedbackSettings();
      await _openStore(
        tester,
        state: state,
        feedback: feedback,
        tab: StoreTab.chips,
        screen: const Size(891, 411),
      );
      for (var i = 0; i < chipPacks.length; i++) {
        final card = tester.getRect(_chipCards.at(i));
        final orbs = find.descendant(
          of: _chipCards.at(i),
          matching: find.byType(GlassOrb),
        );
        // One, baked soft, where there were two — a sharp twin behind the
        // card spilled past its right edge as a hard crescent.
        expect(orbs, findsOneWidget, reason: '$i');
        final orb = tester.widget<GlassOrb>(orbs);
        expect(orb.soft, isTrue);
        // Dark theme: a quarter less of the light the glass let through.
        expect(orb.opacity, lessThanOrEqualTo(0.5));
        expect(orb.size, lessThan(math.min(card.width, card.height) * 0.6));
        final centre = tester.getCenter(orbs);
        expect(centre.dx, greaterThan(card.center.dx), reason: '$i');
        expect(centre.dy, lessThan(card.top + card.height * 0.3), reason: '$i');
      }
      await _close(tester, state, feedback);
    });

    testWidgets('carry one purchase key each, one height, inside the card, '
        'with the price and an arrow', (tester) async {
      for (final tab in [StoreTab.chips, StoreTab.missiles]) {
        final state = _state();
        final feedback = FeedbackSettings();
        await _openStore(
          tester,
          state: state,
          feedback: feedback,
          tab: tab,
          scale: 1.25,
        );
        final cards = tab == StoreTab.chips ? _chipCards : _countCards;
        final n = tab == StoreTab.chips
            ? chipPacks.length
            : missilePacks.length;
        final heights = <double>{};
        for (var i = 0; i < n; i++) {
          final key = find.descendant(of: cards.at(i), matching: _keys);
          expect(key, findsOneWidget);
          final rect = tester.getRect(key);
          final card = tester.getRect(cards.at(i));
          expect(
            card.contains(rect.topLeft) && card.contains(rect.bottomRight),
            isTrue,
          );
          heights.add((rect.height * 100).roundToDouble() / 100);
          expect(
            find.descendant(
              of: key,
              matching: find.byIcon(Icons.arrow_forward_rounded),
            ),
            findsOneWidget,
          );
        }
        expect(heights, hasLength(1), reason: '$tab');
        if (tab == StoreTab.missiles) {
          // A trade is priced in diamonds: the gem and the count.
          for (final p in missilePacks) {
            expect(
              find.descendant(of: _keys, matching: find.text('${p.diamonds}')),
              findsOneWidget,
            );
          }
          expect(find.textContaining('₹'), findsNothing);
        }
        await _close(tester, state, feedback);
      }
    });

    testWidgets('press down to 0.97 under the finger and come back', (
      tester,
    ) async {
      final state = _state();
      final feedback = FeedbackSettings();
      await _openStore(
        tester,
        state: state,
        feedback: feedback,
        tab: StoreTab.diamonds,
        screen: const Size(891, 411),
      );
      final card = _countCards.first;
      final press = find.descendant(
        of: card,
        matching: find.byType(PressScale),
      );
      expect(press, findsOneWidget);
      expect(tester.widget<PressScale>(press).scale, 0.97);
      AnimatedScale pressScale() => tester.widget<AnimatedScale>(
        find.descendant(of: press, matching: find.byType(AnimatedScale)).first,
      );
      final gesture = await tester.startGesture(tester.getCenter(card));
      await tester.pump(const Duration(milliseconds: 120));
      expect(pressScale().scale, 0.97);
      // Cancelled rather than released: a tap would go to Play.
      await gesture.cancel();
      await tester.pump(const Duration(milliseconds: 400));
      expect(pressScale().scale, 1);
      await _close(tester, state, feedback);
    });
  });

  group('the Pictures shelf', () {
    for (final lang in AppLang.values) {
      testWidgets(
        'heads with the picture worn, "your picture", its name and '
        'the check it is worn with, at 640x360 x1.25 in ${lang.englishName}',
        (tester) async {
          final t = Strings(lang);
          for (final screen in [Screen.lobby, Screen.table]) {
            final state = _state(lang: lang, screen: screen);
            final feedback = FeedbackSettings();
            await _openStore(
              tester,
              state: state,
              feedback: feedback,
              tab: StoreTab.pictures,
              scale: 1.25,
            );
            final head = _private('_PicturesHead');
            expect(head, findsOneWidget);
            expect(
              find.descendant(of: head, matching: find.text(t.yourPicture)),
              findsOneWidget,
            );
            expect(
              find.descendant(of: head, matching: find.text('Lion')),
              findsOneWidget,
            );
            // The equipped state in words, with what is left of the rental.
            expect(
              find.descendant(
                of: head,
                matching: find.text('${t.wearing} · ${t.daysLeft(7)}'),
              ),
              findsOneWidget,
            );
            // A third of the height of the 96dp portrait it replaced, which
            // took 105dp of this phone's shelf.
            expect(tester.getSize(head).height, lessThan(80));
            // At a table the shelf is the animated one, with no filter menu.
            expect(
              find.byType(PictureFilterMenu),
              screen == Screen.lobby ? findsOneWidget : findsNothing,
            );
            expect(tester.takeException(), isNull);
            await _close(tester, state, feedback);
          }
        },
      );
    }
  });

  for (final lang in AppLang.values) {
    testWidgets('at 640x360 x1.25 in ${lang.englishName}, every pack card '
        'holds every word it says', (tester) async {
      if (!haveScriptFonts()) {
        markTestSkipped('the Noto script fonts are not installed');
        return;
      }
      for (final tab in [
        StoreTab.chips,
        StoreTab.diamonds,
        StoreTab.hammers,
        StoreTab.missiles,
      ]) {
        final state = _state(lang: lang);
        final feedback = FeedbackSettings();
        await _openStore(
          tester,
          state: state,
          feedback: feedback,
          tab: tab,
          scale: 1.25,
        );
        final cards = find.byWidgetPredicate(
          (w) => const [
            '_PackCard',
            '_PremiumPackCard',
            '_CountPackCard',
          ].contains(w.runtimeType.toString()),
        );
        final failures = <String>[];
        for (var i = 0; i < cards.evaluate().length; i++) {
          final card = tester.getRect(cards.at(i)).inflate(0.5);
          final texts = find.descendant(
            of: cards.at(i),
            matching: find.byType(Text),
          );
          for (var k = 0; k < texts.evaluate().length; k++) {
            final rect = tester.getRect(texts.at(k));
            if (!card.contains(rect.topLeft) ||
                !card.contains(rect.bottomRight)) {
              final words = tester.widget<Text>(texts.at(k)).data;
              failures.add('$tab card $i "$words" $rect outside $card');
            }
          }
        }
        expect(failures, isEmpty, reason: failures.join('\n'));
        expect(tester.takeException(), isNull, reason: '$tab');
        await _close(tester, state, feedback);
      }
    });
  }
}
