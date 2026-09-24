// Close-ups of the table's host (lib/widgets/dealer_host.dart) in each state
// and both themes, standing behind a strip of the table's rail — at the size
// a phone shows her and larger, for judging the artwork itself. Not part of
// `flutter test` (the name has no `_test`): run it by hand.
//
//   flutter test test/dealer_shots.dart --dart-define=SHOTS_DIR=/abs/dir
//   (optional) --dart-define=DEALER_ART=/abs/host.svg   a draft to try, read
//   from disk instead of the bundled asset
//
// Every picture is the real DealerHost, stepped to a fixed moment of its
// state so each run draws the same frames.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/theme/theme_colors.dart';
import 'package:teenpatti/widgets/dealer_host.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');
const _draft = String.fromEnvironment('DEALER_ART');

/// A state and the moment of it to picture, in seconds into the state.
typedef _Moment = ({String name, DealerState state, double at});

const List<_Moment> _moments = [
  (name: 'idle', state: DealerState.idle, at: 1.2),
  (name: 'idle-blink', state: DealerState.idle, at: 4.37),
  (name: 'new-hand', state: DealerState.newHand, at: 0.22),
  (name: 'dealing-a', state: DealerState.dealing, at: 0.62),
  (name: 'dealing-b', state: DealerState.dealing, at: 0.86),
  (name: 'your-turn', state: DealerState.yourTurn, at: 1.0),
  (name: 'win-lift', state: DealerState.win, at: 0.32),
  (name: 'win-sparks', state: DealerState.win, at: 0.9),
];

/// Heights of her box, in logical pixels, and the pixel ratio each is shot
/// at: about what a phone gives her, and two enlargements.
const List<(double, double)> _sizes = [(52, 2.75), (140, 2), (300, 2)];

/// The artwork under test: the bundled one, or a draft on disk.
class _DraftBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key == DealerArt.defaultAsset && _draft.isNotEmpty) {
      final bytes = File(_draft).readAsBytesSync();
      return ByteData.sublistView(bytes);
    }
    return rootBundle.load(key);
  }
}

void main() {
  setUpAll(() async {
    await DealerArt.load(DealerArt.defaultAsset, bundle: _DraftBundle());
  });

  for (final moment in _moments) {
    for (final dark in [true, false]) {
      for (final (height, ratio) in _sizes) {
        final file =
            '${moment.name}_${dark ? 'dark' : 'light'}_${height.toInt()}.png';
        testWidgets(file, (tester) async {
          debugDisableShadows = false;
          try {
            await _shoot(tester, moment, dark, height, ratio, file);
          } finally {
            debugDisableShadows = true;
          }
        });
      }
    }
  }
}

Future<void> _shoot(
  WidgetTester tester,
  _Moment moment,
  bool dark,
  double height,
  double ratio,
  String file,
) async {
  final width = height * DealerArt.boxAspect;
  final pane = Size(width + 2 * height * 0.35, height * 1.45);
  tester.view.physicalSize = pane * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);

  final theme = dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  final colours = dark ? CasinoTableColors.dark : CasinoTableColors.light;
  final rail = (height * 0.2).clamp(8.0, 22.0);
  final key = GlobalKey();

  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: Scaffold(
          backgroundColor: AppTheme.ground(theme.brightness),
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              SizedBox(
                width: width,
                height: height,
                child: DealerHost(state: moment.state),
              ),
              // The far rail she stands behind, and a strip of the cloth.
              Container(
                height: rail,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [colours.railTop, colours.railBottom],
                  ),
                  border: Border(
                    top: BorderSide(color: colours.rim, width: 1.3),
                  ),
                ),
              ),
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [colours.feltCentre, colours.feltEdge],
                    ),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  // Step her clock to the moment wanted, a frame at a time so the blend
  // into the state completes as it would on a phone.
  var t = 0.0;
  while (t < moment.at) {
    final step = (moment.at - t).clamp(0.0, 1 / 60);
    await tester.pump(Duration(microseconds: (step * 1e6).round()));
    t += step;
  }
  await tester.pump();

  if (_dir.isNotEmpty) {
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: ratio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_dir/$file').writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }
  await tester.pumpWidget(const SizedBox.shrink());
}
