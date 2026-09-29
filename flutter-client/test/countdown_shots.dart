// Pictures of the countdown before a deal (29 Sep 2026): the table at "3",
// "2" and "1" on each game's cloth, in both themes, at two phone sizes and
// the text sizes the app allows, one countdown frame by frame, a head seat
// over the slot (two and four places, seen and blind, before a first deal and
// after a hand: `head`), three and five places after a hand (`rim`), the
// missed-turn warning keeping its slot (`missed`), and the poker felt. Not part of
// `flutter test` (the name has no `_test`): run it by hand, like table_shots.
//
//   flutter test test/countdown_shots.dart --dart-define=SHOTS_DIR=/abs/dir \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//   (optional) --dart-define=SHOTS_ONLY=blind_640   a substring of the names
//
// The viewer holds a level (the winning tax's pill over the countdown is two
// lines then, its tallest), as every account on a server with levels does.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/theme/app_theme.dart';

import 'start_countdown_fixture.dart';
import 'table_scenes.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');
const _only = String.fromEnvironment('SHOTS_ONLY');

class _Shot {
  const _Shot(
    this.name,
    this.size,
    this.dark,
    this.leftMs, {
    this.category = 'blind',
    this.isPrivate = false,
    this.scale = 1.0,
    this.players = 5,
    this.lang = AppLang.english,
    this.poker = '',
    this.afterHand = false,
    this.missedTurns = 0,
  });
  final String name;
  final Size size;
  final bool dark;
  final int leftMs;
  final String category;
  final bool isPrivate;
  final double scale;
  final int players;
  final AppLang lang;

  /// A poker room: 'first' before its first hand, 'after' with the last
  /// hand's result still on the felt; '' a Teen Patti table.
  final String poker;

  /// A Teen Patti table with the last hand still on show: the viewer won,
  /// every other seat lost with its cards face up and dimmed.
  final bool afterHand;

  /// The viewer's missed turns (a warning in the status slot).
  final int missedTurns;

  String get file =>
      '${name}_${poker.isEmpty ? category : 'poker-$poker'}'
      '${isPrivate ? '-private' : ''}${afterHand ? '-after' : ''}'
      '${missedTurns > 0 ? '-missed$missedTurns' : ''}_'
      '${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x${scale}_'
      '${players}p_t${leftMs.toString().padLeft(4, '0')}'
      '${lang == AppLang.english ? '' : '_${lang.code}'}.png';
}

/// "3", "2" and "1", each at its fullest.
const _numbers = {3: 2530, 2: 1530, 1: 530};

List<_Shot> _shots() => [
  for (final category in ['seen', 'blind', 'variation'])
    for (final size in const [Size(640, 360), Size(891, 411)])
      for (final dark in [true, false])
        for (final MapEntry(key: n, value: left) in _numbers.entries)
          _Shot('n$n', size, dark, left, category: category),
  for (final dark in [true, false]) ...[
    _Shot(
      'private',
      const Size(640, 360),
      dark,
      1530,
      category: 'seen',
      isPrivate: true,
    ),
    _Shot('scale', const Size(640, 360), dark, 2530, scale: 1.25),
    _Shot('narrow', const Size(592, 360), dark, 1530, scale: 1.25),
    _Shot('tall', const Size(915, 412), dark, 1530, scale: 1.25),
    _Shot('tablet', const Size(1280, 800), dark, 2530),
    _Shot(
      'hindi',
      const Size(640, 360),
      dark,
      1530,
      scale: 1.25,
      lang: AppLang.hindi,
    ),
    for (final poker in ['first', 'after'])
      for (final size in const [Size(640, 360), Size(891, 411)])
        _Shot('poker', size, dark, 1530, poker: poker, scale: 1.25),
    for (final places in [2, 3, 4])
      _Shot(
        'places',
        const Size(640, 360),
        dark,
        1530,
        players: places,
        scale: 1.25,
      ),
    // A head seat over the slot (29 Sep 2026 review): seen (its stack
    // showing) and blind, before a first deal and after a hand, the stars
    // at their highest.
    for (final places in [2, 4])
      for (final category in ['seen', 'blind'])
        for (final afterHand in [false, true])
          for (final size in const [Size(640, 360), Size(891, 411)])
            for (final left in const [2700, 2530, 1530, 1400])
              _Shot(
                'head',
                size,
                dark,
                left,
                players: places,
                category: category,
                afterHand: afterHand,
                scale: size.width < 700 ? 1.25 : 1.0,
              ),
    for (final left in const [2700, 1530])
      _Shot(
        'head592',
        const Size(592, 360),
        dark,
        left,
        players: 2,
        category: 'seen',
        afterHand: true,
        scale: 1.25,
      ),
    // Three and five places after a hand, seen.
    for (final places in [3, 5])
      _Shot(
        'rim',
        const Size(640, 360),
        dark,
        2530,
        players: places,
        category: 'seen',
        afterHand: true,
        scale: 1.25,
      ),
    // The missed-turn warning keeps the slot; the countdown comes in after.
    for (final left in const [2000, 900])
      _Shot(
        'missed',
        const Size(640, 360),
        dark,
        left,
        missedTurns: 2,
        scale: 1.25,
      ),
    for (final poker in ['first', 'after'])
      _Shot(
        'poker592',
        const Size(592, 360),
        dark,
        1530,
        poker: poker,
        scale: 1.25,
      ),
  ],
  // One countdown frame by frame, a tenth of a second apart.
  for (var left = 3000; left >= -300; left -= 100)
    _Shot('seq', const Size(640, 360), true, left),
];

Future<void> _loadFonts() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
  final icons = File(const String.fromEnvironment('ICON_FONT'));
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
  // A Devanagari face for the Hindi pass, as a phone falls back to one.
  for (final path in const [
    '/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf',
    '/usr/share/fonts/opentype/noto/NotoSansDevanagari-Regular.ttf',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final loader = FontLoader('Devanagari')
      ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await loader.load();
    break;
  }
}

ThemeData _theme(bool dark, AppLang lang) {
  final base = dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);
  if (lang == AppLang.english) return base;
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamilyFallback: const ['Devanagari']),
  );
}

void main() {
  setUpAll(() async {
    await _loadFonts();
    loadCountdownArt();
  });

  for (final shot in _shots()) {
    if (_only.isNotEmpty && !shot.file.contains(_only)) continue;
    testWidgets(shot.file, (tester) async {
      debugDisableShadows = false;
      final restore = holdCountdownClock();
      try {
        await _shoot(tester, shot);
      } finally {
        restore();
        debugDisableShadows = true;
      }
    });
  }
}

Future<void> _shoot(WidgetTester tester, _Shot shot) async {
  tester.view.physicalSize = shot.size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = shot.scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  // The snapshot arrives with the countdown's own three seconds at most to
  // run, as after a hand's celebration; the clock is then walked to the
  // moment wanted. After a hand (or a missed turn raised at its end) the
  // whole 6 s window: the celebration first.
  final arrival = shot.afterHand || shot.missedTurns > 0
      ? 6000
      : shot.leftMs.clamp(1, 3000);
  final state = sceneState(
    TableScene(shot.file, (s) {
      s.user = countdownViewer();
      s.config = s.config.copyWith(maxPlayers: shot.players);
      s.handleState(
        shot.poker.isNotEmpty
            ? countingDownPokerRoom(
                leftMs: arrival,
                afterHand: shot.poker == 'after',
              )
            : countingDownRoom(
                leftMs: arrival,
                category: shot.category,
                isPrivate: shot.isPrivate,
                players: shot.players,
                maxPlayers: shot.players,
                afterHand: shot.afterHand,
                missedTurns: shot.missedTurns,
              ),
      );
      if (shot.afterHand) {
        s.handleShowdown(countdownShowdown(players: shot.players));
      }
    }),
    lang: shot.lang,
  );
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: tableApp(
        state: state,
        feedback: feedback,
        theme: _theme(shot.dark, shot.lang),
      ),
    ),
  );
  final target = arrival - shot.leftMs;
  var walked = 0;
  while (walked < target) {
    final step = (target - walked).clamp(0, 16);
    countdownNow += step;
    walked += step;
    await tester.pump(Duration(milliseconds: step));
  }
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 60)),
  );
  await tester.pump();
  final problem = tester.takeException();
  if (problem != null) stderr.writeln('${shot.file}: $problem');
  if (_dir.isNotEmpty) {
    await tester.runAsync(() async {
      Directory(_dir).createSync(recursive: true);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$_dir/${shot.file}').writeAsBytesSync(data!.buffer.asUint8List());
      image.dispose();
    });
  }
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  countdownNow -= target;
  state.dispose();
}
