// The pot's coins on the Teen Patti felt (owner, 30 Sep 2026: "Use this
// animation on game Table for pot coins, change color of coin acc to blind,
// seen and variation table").
//
// assets/animations/PotCoin.json (widgets/pot_coins.dart) stands on the pot's
// plinth where the painted stack of four chips was, in the table's colour.
// These hold the file to what a phone can play and to the window the widget
// fits its pile into (every coin at rest inside it, none at rest by the frame
// it is held at not yet landed), the widget to its box, its colour and its
// clock — once through as the table opens, the last coins again when chips
// land — and the felt to drawing it on a seen, a blind and a variation table
// in each table's own colour, the figure beside it whole and the plinth in
// its fifth.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/fact_mark.dart' show tintAt;
import 'package:teenpatti/widgets/pot_coins.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';
import 'table_scenes.dart';

final _json =
    jsonDecode(File(PotCoinsArt.asset).readAsStringSync())
        as Map<String, dynamic>;

/// Where the painted pixels of [progress] lie on the file's canvas, drawn at
/// a quarter of a unit to a pixel over a mid grey.
Future<Rect> _paintedAt(LottieComposition comp, double progress) async {
  const w = 480, h = 270;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(const Color(0xFF808080), BlendMode.src);
  LottieDrawable(comp)
    ..setProgress(progress)
    ..draw(canvas, const Rect.fromLTWH(0, 0, 480, 270), fit: BoxFit.fill);
  final image = await recorder.endRecording().toImage(w, h);
  final pixels = (await image.toByteData())!;
  var left = w, top = h, right = -1, bottom = -1;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      if ((pixels.getUint8(i) - 0x80).abs() > 6 ||
          (pixels.getUint8(i + 1) - 0x80).abs() > 6 ||
          (pixels.getUint8(i + 2) - 0x80).abs() > 6) {
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
      }
    }
  }
  return Rect.fromLTRB(
    left * 4.0,
    top * 4.0,
    (right + 1) * 4.0,
    (bottom + 1) * 4.0,
  );
}

double _hue(Color c) => HSLColor.fromColor(c).hue;

double _hueGap(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

Finder _private(String type) =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == type);

Finder get _pile => find.byKey(const ValueKey('pot-coins'));

/// The table at [size] showing [room], the felt settled.
Future<GameState> _mount(
  WidgetTester tester,
  RoomState room, {
  Size size = const Size(640, 360),
  bool dark = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  state
    ..lang = AppLang.english
    ..screen = Screen.table
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200},
        {'category': 'blind', 'bootAmount': 200},
        {'category': 'variation', 'bootAmount': 50000},
      ],
    })
    ..user = User.fromJson({
      'id': 'me',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 3245000,
    })
    ..handleState(room);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: withScriptFallback(
          dark ? AppTheme.dark(sound: false) : AppTheme.light(sound: false),
        ),
        builder: (context, child) => GlassBudget(child: child!),
        home: const TableScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
  return state;
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

/// The painter drawing the pile.
PotCoinsPainter _painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.descendant(of: _pile, matching: find.byType(CustomPaint)),
            )
            .painter!
        as PotCoinsPainter;

void main() {
  setUpAll(() async {
    await loadScriptFonts();
    // Where async is real: a future first awaited inside one test's fake
    // clock never completes in the next (CLAUDE.md §12.3).
    expect(await PotCoinsArt.load(), isNotNull);
  });

  group('the file', () {
    test('is 1920 x 1080, five seconds at 24 fps, and nothing a phone cannot '
        'play', () {
      expect(_json['w'], PotCoinsArt.canvas.width);
      expect(_json['h'], PotCoinsArt.canvas.height);
      expect(_json['fr'], PotCoinsArt.frameRate);
      expect(_json['op'], PotCoinsArt.frames);
      for (final layer in (_json['layers'] as List).cast<Map>()) {
        expect(layer['ddd'] ?? 0, 0, reason: 'no 3D layer');
        expect(layer['ty'], isNot(5), reason: 'no text layer');
        expect(layer['ty'], isNot(2), reason: 'no image layer');
      }
      expect(
        RegExp(r'"x":"').hasMatch(jsonEncode(_json)),
        isFalse,
        reason: 'no expressions',
      );
      expect(_json['assets'], isEmpty, reason: 'no images, no precomps');
      expect(_json['fonts'], isNull);
    });

    test('is twenty layers — fourteen coins, three standing coins and their '
        'three rupee marks — every one gold or white', () {
      final layers = (_json['layers'] as List).cast<Map<String, dynamic>>();
      expect(layers.length, 20);
      final names = layers.map((l) => l['nm']).toList();
      expect(names.where((n) => n == 'L' || n == 'L 1').length, 14);
      expect(names.where((n) => n == 'S').length, 3);
      expect(names.where((n) => n == '₹').length, 3);
      // Every fill: a gold (a warm hue, saturated) or the white of the rupee
      // marks — nothing a tint would leave a stray colour.
      void fills(List items, void Function(Color) each) {
        for (final it in items.cast<Map>()) {
          if (it['ty'] == 'gr') {
            fills(it['it'] as List, each);
          } else if (it['ty'] == 'fl') {
            final c = (it['c'] as Map)['k'] as List;
            each(
              Color.fromARGB(
                255,
                ((c[0] as num) * 255).round(),
                ((c[1] as num) * 255).round(),
                ((c[2] as num) * 255).round(),
              ),
            );
          }
        }
      }

      for (final layer in layers) {
        fills(layer['shapes'] as List, (c) {
          final hsl = HSLColor.fromColor(c);
          if (hsl.saturation < 0.08) {
            expect(c, const Color(0xFFFFFFFF), reason: '${layer['nm']}');
          } else {
            expect(hsl.hue, inInclusiveRange(30, 50), reason: '$c');
          }
        });
      }
    });

    testWidgets('at rest every coin lies inside the window the widget fits '
        'to its box, and fills it; by the held frame every coin has landed', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final comp = await LottieComposition.fromBytes(
          File(PotCoinsArt.asset).readAsBytesSync(),
        );
        final window = PotCoinsArt.window;
        // Held: the pile, whole, in the window — and no wider or taller
        // than it by more than the quarter-unit grid the paint is read on.
        for (final frame in [
          PotCoinsArt.builtFrame,
          PotCoinsArt.builtFrame + 20,
          PotCoinsArt.frames - 1,
        ]) {
          final painted = await _paintedAt(
            comp,
            (frame + 0.5) / PotCoinsArt.frames,
          );
          expect(
            window.inflate(6).contains(painted.topLeft) &&
                window.inflate(6).contains(painted.bottomRight),
            isTrue,
            reason: 'frame $frame paints $painted, window $window',
          );
          expect(painted.width, greaterThan(window.width * 0.97));
          expect(painted.height, greaterThan(window.height * 0.97));
        }
        // Before the held frame the coins are still coming down from above
        // the canvas: the paint reaches above the window.
        final falling = await _paintedAt(
          comp,
          (PotCoinsArt.topUpFrame + 0.5) / PotCoinsArt.frames,
        );
        expect(falling.top, lessThan(window.top - 6));
        // The standing coins and the last coins are still falling at the
        // top-up frame — ten of the seventeen land after it — and six
        // coins are already at rest, so a top-up keeps a pile in view.
        final layers = (_json['layers'] as List).cast<Map<String, dynamic>>();
        int landedAt(Map<String, dynamic> l) {
          final ks = l['ks'] as Map;
          final y = ((ks['p'] as Map)['y'] as Map?)?['k'];
          if (y is! List) return 0;
          final keys = y.cast<Map>();
          return keys.length > 1 ? (keys[1]['t'] as num).toInt() : 0;
        }

        final coins = layers.where(
          (l) => l['nm'] == 'S' || l['nm'] == 'L' || l['nm'] == 'L 1',
        );
        final late = coins
            .where((l) => landedAt(l) > PotCoinsArt.topUpFrame)
            .length;
        expect(late, 10);
        final resting = coins
            .where(
              (l) => l['nm'] != 'S' && landedAt(l) <= PotCoinsArt.topUpFrame,
            )
            .length;
        expect(resting, 6);
        // And by the held frame every fall has ended.
        for (final l in layers) {
          final ks = l['ks'] as Map;
          final y = ((ks['p'] as Map)['y'] as Map?)?['k'];
          if (y is! List) continue;
          final keys = y.cast<Map>();
          final landed = keys.length > 1 ? (keys[1]['t'] as num).toInt() : 0;
          expect(
            landed,
            lessThanOrEqualTo(PotCoinsArt.builtFrame),
            reason: '${l['nm']} ${l['ind']}',
          );
        }
      });
    });
  });

  group('the widget', () {
    testWidgets('takes its box from its width and the pile\'s shape, plays '
        'once to the built frame and holds, and falls again from the top-up '
        'frame when chips land', (tester) async {
      tester.view.physicalSize = const Size(640, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var landings = 0;
      late StateSetter setLandings;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(sound: false),
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) {
                  setLandings = setState;
                  return PotCoins(
                    width: 40,
                    tint: AppTheme.gold,
                    landings: landings,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final box = tester.getRect(_pile);
      expect(box.width, 40);
      expect(box.height, closeTo(PotCoins.heightFor(40), 0.01));
      expect(PotCoins.heightFor(40), closeTo(40 / PotCoinsArt.aspect, 1e-9));
      // A painter, never the Lottie widget (its every frame is a setState
      // that would lay the felt out again), drawing the parsed file.
      expect(find.byType(Lottie), findsNothing);
      final painter = _painter(tester);
      expect(painter.drawable, isNotNull);
      // The clock: forward from the start, at the file's own frame rate.
      final frame = painter.frame;
      expect(frame.value, 0);
      await tester.pump(const Duration(milliseconds: 500));
      expect(frame.value, closeTo(12 / 120, 1e-6));
      await tester.pump(const Duration(milliseconds: 500));
      expect(frame.value, closeTo(24 / 120, 1e-6));
      final built = PotCoinsArt.at(PotCoinsArt.builtFrame);
      await tester.pump(const Duration(seconds: 4));
      expect(frame.value, closeTo(built, 1e-6));
      // Held there.
      await tester.pump(const Duration(seconds: 1));
      expect(frame.value, closeTo(built, 1e-6));
      // Chips land: from the top-up frame to the built one again.
      setLandings(() => landings = 1);
      await tester.pump();
      expect(
        frame.value,
        closeTo(PotCoinsArt.at(PotCoinsArt.topUpFrame), 1 / 120 + 1e-6),
      );
      await tester.pump(const Duration(milliseconds: 500));
      // Twelve frames on (the file rounds its frame down, and 0.2917 + 0.1
      // lands a hair under 47/120).
      expect(frame.value, closeTo((35 + 12) / 120, 1 / 120 + 1e-6));
      await tester.pump(const Duration(seconds: 3));
      expect(frame.value, closeTo(built, 1e-6));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('draws the file in the table\'s colour at the file\'s own '
        'luminances, the rupee marks white', (tester) async {
      final scheme = AppTheme.dark(sound: false).colorScheme;
      for (final category in const ['seen', 'blind', 'variation']) {
        final accent = AppTheme.paletteFor(
          scheme,
          category: category,
          bootAmount: 200,
        ).accent;
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(sound: false),
            home: Center(child: PotCoins(width: 40, tint: accent)),
          ),
        );
        expect(_painter(tester).tint, accent);
        final values = potCoinsDelegates(accent).values!;
        expect(values, hasLength(2));
        for (final v in values) {
          expect(v.keyPath, ['**']);
          // A callback delegate: no fixed value.
          expect(v.value, isNull);
        }
        // Made once per colour.
        expect(
          identical(potCoinsDelegates(accent), potCoinsDelegates(accent)),
          isTrue,
        );
        // What the callbacks answer: the file's golds in the accent's hue
        // at their own luminance, and white as it is.
        const golds = [
          Color(0xFFFFB127),
          Color(0xFFE38601),
          Color(0xFFFFD454),
          Color(0xFFFFBD29),
        ];
        for (final gold in golds) {
          final tinted = tintAt(gold, accent);
          expect(
            _hueGap(_hue(tinted), _hue(accent)),
            lessThan(3),
            reason: category,
          );
          expect(
            tinted.computeLuminance(),
            closeTo(gold.computeLuminance(), 0.01),
            reason: '$category $gold',
          );
        }
        expect(tintAt(Colors.white, accent), Colors.white);
        // The three tables three colours apart.
      }
      final gold = AppTheme.paletteFor(
        scheme,
        category: 'seen',
        bootAmount: 200,
      ).accent;
      final blue = AppTheme.paletteFor(
        scheme,
        category: 'blind',
        bootAmount: 200,
      ).accent;
      final violet = AppTheme.paletteFor(
        scheme,
        category: 'variation',
        bootAmount: 50000,
      ).accent;
      expect(_hueGap(_hue(gold), _hue(blue)), greaterThan(60));
      expect(_hueGap(_hue(blue), _hue(violet)), greaterThan(30));
      expect(_hueGap(_hue(gold), _hue(violet)), greaterThan(60));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('the felt', () {
    for (final (category, boot) in const [
      ('seen', 200),
      ('blind', 200),
      ('variation', 50000),
    ]) {
      testWidgets('a $category table shows the coins on its plinth in its own '
          'colour, the figure beside them whole, both themes', (tester) async {
        for (final dark in [true, false]) {
          final state = await _mount(
            tester,
            seenTurnRoom(category: category, boot: boot, pot: 6800),
            dark: dark,
          );
          final theme = Theme.of(tester.element(_pile));
          final accent = AppTheme.paletteFor(
            theme.colorScheme,
            category: category,
            bootAmount: boot,
          ).accent;
          expect(_pile, findsOneWidget, reason: category);
          final coins = tester.widget<PotCoins>(find.byType(PotCoins));
          expect(coins.tint, accent, reason: category);
          expect(coins.width, greaterThan(20), reason: category);
          // On the plinth, left of the figure, the figure whole.
          final pot = tester.getRect(_private('_Pot'));
          final pile = tester.getRect(_pile);
          final figure = find.descendant(
            of: _private('_Pot'),
            matching: find.byType(Text),
          );
          final drawn = tester.getRect(figure);
          expect(pot.contains(pile.center), isTrue, reason: category);
          expect(pile.right, lessThan(drawn.left), reason: category);
          expect(
            drawn.width,
            closeTo(tester.renderObject<RenderBox>(figure).size.width, 0.5),
            reason: category,
          );
          // No painted stack any more.
          expect(_private('ChipStack'), findsNothing, reason: category);
          expect(tester.takeException(), isNull, reason: category);
          await _unmount(tester, state);
        }
      });
    }

    testWidgets('chips landing top the pile up: the coins fall again once, '
        'not on the pot resetting', (tester) async {
      final state = await _mount(tester, seenTurnRoom(pot: 6800));
      await tester.pump(const Duration(seconds: 4));
      final frame = _painter(tester).frame;
      final built = PotCoinsArt.at(PotCoinsArt.builtFrame);
      expect(frame.value, closeTo(built, 1e-6));
      expect(tester.widget<PotCoins>(find.byType(PotCoins)).landings, 0);
      // A bet: the chip crosses the cloth, then the pile answers.
      state.handleState(seenTurnRoom(pot: 7200));
      await tester.pump();
      expect(tester.widget<PotCoins>(find.byType(PotCoins)).landings, 0);
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.widget<PotCoins>(find.byType(PotCoins)).landings, 1);
      expect(frame.value, lessThan(built));
      expect(
        frame.value,
        greaterThanOrEqualTo(PotCoinsArt.at(PotCoinsArt.topUpFrame) - 1e-6),
      );
      await tester.pump(const Duration(seconds: 3));
      expect(frame.value, closeTo(built, 1e-6));
      // The hand ends: the pot goes to nought, and nothing falls.
      state.handleState(seenTurnRoom(pot: 0));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<PotCoins>(find.byType(PotCoins)).landings, 1);
      expect(frame.value, closeTo(built, 1e-6));
      await _unmount(tester, state);
    });
  });
}
