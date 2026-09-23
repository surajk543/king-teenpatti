// The chip shuffle on the lobby's engine cards (owner, 23 Sep 2026): "use this
// animation on teenPatti and Poker card of UI and change coin colour accord to
// the card coin u have, but animation should be same".
//
// assets/animations/Poker Chip Shuffle.json is played as the file has it and
// recoloured at runtime (widgets/chip_shuffle.dart). These hold the file to the
// layers the recolour names, the recolour to the card coin's own colours, and
// the widget to playing on through the lobby's one-second rebuilds.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/chip_shuffle.dart';
import 'package:teenpatti/widgets/poker_chip.dart';

/// Every map anywhere inside [node], depth first.
Iterable<Map<String, dynamic>> _maps(Object? node) sync* {
  if (node is Map<String, dynamic>) {
    yield node;
    for (final value in node.values) {
      yield* _maps(value);
    }
  } else if (node is List) {
    for (final value in node) {
      yield* _maps(value);
    }
  }
}

final _bytes = File(
  'assets/animations/Poker Chip Shuffle.json',
).readAsBytesSync();
final _json = jsonDecode(utf8.decode(_bytes)) as Map<String, dynamic>;

Map<String, dynamic> _asset(String id) => (_json['assets'] as List)
    .cast<Map<String, dynamic>>()
    .singleWhere((a) => a['id'] == id);

List<Map<String, dynamic>> _layers(Map<String, dynamic> comp) =>
    (comp['layers'] as List).cast<Map<String, dynamic>>();

/// The colour a fill's `c.k` holds.
Color _colourOf(Map<String, dynamic> fill) {
  final k = (fill['c'] as Map<String, dynamic>)['k'] as List;
  return Color.from(
    alpha: 1,
    red: (k[0] as num).toDouble(),
    green: (k[1] as num).toDouble(),
    blue: (k[2] as num).toDouble(),
  );
}

String _hex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0')}';

/// An engine card's coin colour, as the lobby picks it (`_enginePalette`):
/// Teen Patti wears the seen table's gold, Poker the family's teal.
Color _accent(String engine, Brightness brightness) {
  final scheme =
      (brightness == Brightness.dark
              ? AppTheme.dark(sound: false)
              : AppTheme.light(sound: false))
          .colorScheme;
  return AppTheme.paletteFor(
    scheme,
    category: engine == TableEngine.poker
        ? TableCategory.pokerFamily
        : TableCategory.seen,
    bootAmount: 200,
  ).accent;
}

/// What each recoloured fill is given, per engine and theme. Written out, not
/// recomputed, so a change to the rule or to a palette shows up here.
const _gold = {
  'Layer 8 Outlines': '#D2B14A',
  'Layer 10 Outlines': '#D4B93B',
  'Layer 4 Outlines': '#B59223',
  'Layer 5 Outlines': '#9D7E1E',
  'Layer 11 Outlines': '#755E17',
};
const _champagne = {
  'Layer 9 Outlines': '#F2DFA8',
  'Layer 1 Outlines': '#F2DFA8',
  'Layer 7 Outlines': '#E8D6A1',
  'Layer 3 Outlines': '#CABA8C',
  'Layer 2 Outlines': '#AFA179',
};
const _expected = <(String, Brightness), Map<String, String>>{
  (TableEngine.teenPatti, Brightness.dark): {..._gold, ..._champagne},
  (TableEngine.teenPatti, Brightness.light): {..._gold, ..._champagne},
  (TableEngine.poker, Brightness.dark): {
    'Layer 8 Outlines': '#7DBDB6',
    'Layer 10 Outlines': '#69C9FF',
    'Layer 4 Outlines': '#5A9E97',
    'Layer 5 Outlines': '#4E8983',
    'Layer 11 Outlines': '#3A6661',
    ..._champagne,
  },
  (TableEngine.poker, Brightness.light): {
    'Layer 8 Outlines': '#359E9F',
    'Layer 10 Outlines': '#109FD6',
    'Layer 4 Outlines': '#0E7D7F',
    'Layer 5 Outlines': '#0C6C6E',
    'Layer 11 Outlines': '#095152',
    ..._champagne,
  },
};

/// The property a colour delegate sets (the lottie package does not export
/// its property constants).
final Object _colourProperty = ValueDelegate.color(const []).property;

/// Channel by channel, [a] laid in multiply over [b].
Color _multiply(Color a, Color b) =>
    Color.from(alpha: 1, red: a.r * b.r, green: a.g * b.g, blue: a.b * b.b);

/// The file drawn at [progress] into a [side]-square image, recoloured by
/// [delegates] when given.
Future<ui.Image> _render(
  LottieComposition composition,
  double progress, {
  List<ValueDelegate<Object>>? delegates,
  int side = 270,
}) async {
  final drawable = LottieDrawable(composition);
  if (delegates != null) {
    drawable.delegates = LottieDelegates(values: delegates);
  }
  drawable.setProgress(progress);
  final recorder = ui.PictureRecorder();
  drawable.draw(
    Canvas(recorder),
    Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    fit: BoxFit.fill,
  );
  return recorder.endRecording().toImage(side, side);
}

/// Every opaque pixel of [image], as colours.
Future<List<Color>> _opaque(ui.Image image) async {
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  return [
    for (var i = 0; i < data.lengthInBytes; i += 4)
      if (data.getUint8(i + 3) == 255)
        Color.fromARGB(
          255,
          data.getUint8(i),
          data.getUint8(i + 1),
          data.getUint8(i + 2),
        ),
  ];
}

/// The file's red: strong red, weak green and blue — nothing gold, teal or
/// champagne comes near it.
bool _red(Color c) => c.r > 0.4 && c.g < 0.35 * c.r && c.b < 0.35 * c.r;

bool _near(Color a, Color b, {double within = 3 / 255}) =>
    (a.r - b.r).abs() <= within &&
    (a.g - b.g).abs() <= within &&
    (a.b - b.b).abs() <= within;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the file', () {
    test('is a two-second loop the phone players can draw', () async {
      final composition = await LottieComposition.fromBytes(_bytes);
      expect(composition.duration, const Duration(seconds: 2));
      // 120 frames at 60 a second, on a 1080 square.
      expect((_json['ip'], _json['op'], _json['fr']), (0, 120, 60));
      expect((_json['w'], _json['h']), (1080, 1080));

      // CLAUDE.md §12.3: no 3D, no orientation or x/y rotation, no
      // expressions — in the root and in both precomps.
      final layers = [
        ..._layers(_json),
        for (final asset in (_json['assets'] as List).cast<Map>())
          ...(asset['layers'] as List? ?? const [])
              .cast<Map<String, dynamic>>(),
      ];
      for (final layer in layers) {
        expect(layer['ddd'] ?? 0, 0, reason: '${layer['nm']} is a 3D layer');
        final ks = layer['ks'] as Map<String, dynamic>;
        for (final turn in ['or', 'rx', 'ry']) {
          expect(
            ks.containsKey(turn),
            isFalse,
            reason: '${layer['nm']}: $turn',
          );
        }
      }
      expect(_maps(_json).where((m) => m['x'] is String), isEmpty);
    });

    test('is one chip, drawn twelve times', () {
      expect([for (final l in _layers(_json)) l['refId']], ['comp_0']);
      final chips = _layers(_asset('comp_0'));
      expect(chips, hasLength(12));
      expect({for (final chip in chips) chip['refId']}, {'comp_1'});
    });

    // chip_shuffle.dart names the chip's fills by layer and lists the file's
    // own colour beside each. A replacement file that renamed a layer, moved a
    // colour or added a stroke or gradient would keep its red without a word;
    // here it fails instead.
    test('the chip holds exactly the fills the recolour names, in the '
        "file's own colours", () {
      final fills = <String, Color>{};
      final multiply = <String>{};
      for (final layer in _layers(_asset('comp_1'))) {
        final name = layer['nm'] as String;
        final painted = [
          for (final shape in _maps(layer['shapes']))
            if (const {'fl', 'st', 'gf', 'gs'}.contains(shape['ty'])) shape,
        ];
        expect(painted, hasLength(1), reason: '$name paints more than a fill');
        expect(painted.single['ty'], 'fl', reason: name);
        expect((painted.single['c'] as Map)['a'], 0, reason: '$name animates');
        fills[name] = _colourOf(painted.single);
        if (layer['bm'] == 1) multiply.add(name);
      }

      expect(fills.keys.toSet(), {
        ...chipShuffleBodyLayers.keys,
        ...chipShuffleInlayLayers.keys,
        chipShuffleShadeLayer,
      });
      for (final entry in {
        ...chipShuffleBodyLayers,
        ...chipShuffleInlayLayers,
      }.entries) {
        expect(
          _near(fills[entry.key]!, entry.value, within: 0.0005),
          isTrue,
          reason: '${entry.key} is ${fills[entry.key]} in the file',
        );
      }
      // The two laid in multiply: the spots, whose delegate is divided by
      // the champagne under them, and the neutral shade left as it is.
      expect(multiply, {'Layer 10 Outlines', chipShuffleShadeLayer});
      final shade = fills[chipShuffleShadeLayer]!;
      expect((shade.r, shade.g), (shade.b, shade.b), reason: 'a neutral grey');
    });

    test('each family is listed lightest first', () {
      for (final family in [chipShuffleBodyLayers, chipShuffleInlayLayers]) {
        final light = [for (final c in family.values) c.computeLuminance()];
        for (var i = 1; i < light.length; i++) {
          expect(light[i], lessThanOrEqualTo(light[i - 1]));
        }
      }
    });
  });

  group('the recolour', () {
    for (final MapEntry(key: (engine, brightness), value: expected)
        in _expected.entries) {
      final accent = _accent(engine, brightness);

      test('$engine in the ${brightness.name} theme: every red and every '
          'white of the file is delegated, in the coin\'s own colours', () {
        final delegates = chipShuffleDelegates(accent);
        expect(delegates, hasLength(10));
        final given = <String, String>{};
        for (final delegate in delegates) {
          expect(delegate.property, _colourProperty);
          expect(delegate.keyPath, hasLength(3));
          expect(delegate.keyPath.first, '**', reason: 'into both precomps');
          expect(delegate.keyPath.last, '**', reason: "to the layer's fill");
          given[delegate.keyPath[1]] = _hex(delegate.value! as Color);
        }
        expect(given, expected);
        expect(given.keys, isNot(contains(chipShuffleShadeLayer)));
      });

      test('$engine in the ${brightness.name} theme: the body shades are the '
          "coin's own, and the spots show its colour over the inlay", () {
        final colours = chipShuffleColours(accent);
        final top = colours['Layer 1 Outlines']!;
        expect(top, AppTheme.goldBright, reason: 'the champagne inserts');

        // What the spots show: their delegate multiplied by the top they lie
        // on. That is the coin's body, or where the champagne cannot carry it
        // (the dark theme's pale teal is bluer than champagne) the lightest
        // shade of the same hue it can.
        final shown = _multiply(colours['Layer 10 Outlines']!, top);
        final hue = HSVColor.fromColor(accent).hue;
        expect(HSVColor.fromColor(shown).hue, closeTo(hue, 1));
        if (engine == TableEngine.teenPatti || brightness == Brightness.light) {
          expect(_near(shown, accent), isTrue, reason: '$shown vs $accent');
        } else {
          expect(shown.computeLuminance(), lessThan(accent.computeLuminance()));
          expect([
            for (final c in [shown.r, shown.g, shown.b]) c <= 1,
          ], everyElement(isTrue));
        }

        // The other four are the chip painter's own shades of that body, in
        // the file's order.
        final body = chipBodyShades(shown);
        for (final (i, layer) in chipShuffleBodyLayers.keys.indexed) {
          if (layer == 'Layer 10 Outlines') continue;
          expect(_near(colours[layer]!, body[i]), isTrue, reason: layer);
        }

        // Each family keeps the file's light-to-dark order.
        for (final family in [chipShuffleBodyLayers, chipShuffleInlayLayers]) {
          final light = [
            for (final layer in family.keys)
              (layer == 'Layer 10 Outlines' ? shown : colours[layer]!)
                  .computeLuminance(),
          ];
          for (var i = 1; i < light.length; i++) {
            expect(light[i], lessThanOrEqualTo(light[i - 1] + 1e-9));
          }
        }
      });

      test('$engine in the ${brightness.name} theme: drawn, no pixel of the '
          "file's red is left, and the spots wear the coin", () async {
        final composition = await LottieComposition.fromBytes(_bytes);
        final shown = _multiply(
          chipShuffleColours(accent)['Layer 10 Outlines']!,
          AppTheme.goldBright,
        );
        for (final progress in [0.0, 0.25, 0.5, 0.75]) {
          final pixels = await _opaque(
            await _render(
              composition,
              progress,
              delegates: chipShuffleDelegates(accent),
            ),
          );
          expect(pixels, isNotEmpty);
          expect(
            pixels.where(_red),
            isEmpty,
            reason: 'at $progress a chip kept its red',
          );
          expect(
            pixels.where((p) => _near(p, shown)).length,
            greaterThan(50),
            reason: 'at $progress the spots are not ${_hex(shown)}',
          );
        }
      });
    }

    test(
      'the file as it is is red, which is what the recolour removes',
      () async {
        final composition = await LottieComposition.fromBytes(_bytes);
        final pixels = await _opaque(await _render(composition, 0));
        expect(pixels.where(_red).length, greaterThan(500));
      },
    );
  });

  group('the widget', () {
    testWidgets('plays on through its parent rebuilding every second, and '
        'recolours only when its colour changes', (tester) async {
      // Loaded into the lottie package's cache first, as the phone has it
      // after the first frame; a widget test cannot wait on real file I/O.
      await tester.runAsync(() => AssetLottie(chipShuffleAsset).load());

      final colour = ValueNotifier<Color>(const Color(0xFFC9A227));
      final tick = ValueNotifier<int>(0);
      addTearDown(colour.dispose);
      addTearDown(tick.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ListenableBuilder(
              listenable: Listenable.merge([colour, tick]),
              // A new ChipShuffle every build, as the lobby's cards make one.
              builder: (context, _) =>
                  ChipShuffle(colour: colour.value, size: 40),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      final lottie = find.byType(Lottie);
      expect(lottie, findsOneWidget, reason: 'the composition has loaded');
      final state = tester.state(lottie);
      final widget = tester.widget<Lottie>(lottie);
      double progress() =>
          tester.widget<RawLottie>(find.byType(RawLottie)).progress;

      // Half a second, a rebuild from above, another half second: one
      // continuous second of a two-second loop, never back to its start.
      await tester.pump(const Duration(milliseconds: 500));
      final before = progress();
      tick.value++;
      await tester.pump(const Duration(milliseconds: 500));
      final after = progress();
      expect(tester.state(lottie), same(state));
      expect(tester.widget<Lottie>(lottie), same(widget));
      expect(
        tester.widget<Lottie>(lottie).composition,
        same(widget.composition),
      );
      expect((after - before) % 1, closeTo(0.25, 0.02));

      // A new colour is a new set of delegates, on the same animation.
      final delegates = widget.delegates;
      colour.value = const Color(0xFF0F8B8D);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.state(lottie), same(state));
      expect(tester.widget<Lottie>(lottie).delegates, isNot(same(delegates)));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('takes a square of its size in layout', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ChipShuffle(colour: Color(0xFFC9A227), size: 40),
          ),
        ),
      );
      expect(tester.getSize(find.byType(ChipShuffle)), const Size(40, 40));
      // Twelve chips each as wide as the coin they replace.
      expect(ChipShuffle.sizeForChip(370 / 764 * 40), closeTo(40, 1e-9));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
