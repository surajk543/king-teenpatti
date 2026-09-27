// Pictures of the table's chat drawer for review (owner, 27 Sep 2026: the
// quick messages first, then the table chat, then block; and the time on
// every chat line). Not part of `flutter test` — run by hand, like
// table_shots.dart:
//
//   flutter test test/chat_shots.dart --dart-define=SHOTS_DIR=<abs dir> \
//     --dart-define=ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf
//
// The drawer is opened from the rail of a real table, as a player opens it:
// on Quick messages, then turned to Table chat with a conversation of timed
// lines — the table's own, the players', the viewer's and an emoji.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';

import 'script_fonts.dart';
import 'table_scenes.dart';

const _dir = String.fromEnvironment('SHOTS_DIR');

const _emojiUrl = 'https://cdn.test/emojis/7.json';

final Uint8List _lottie = Uint8List.fromList(
  utf8.encode(
    '{"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"e","ddd":0,'
    '"assets":[],"layers":[{"ddd":0,"ind":1,"ty":4,"nm":"d","sr":1,'
    '"ks":{"o":{"a":0,"k":100},"r":{"a":0,"k":0},"p":{"a":0,"k":[50,50,0]},'
    '"a":{"a":0,"k":[0,0,0]},"s":{"a":0,"k":[100,100,100]}},"ao":0,'
    '"shapes":[{"ty":"gr","nm":"g","it":[{"ty":"el","nm":"c",'
    '"p":{"a":0,"k":[0,0]},"s":{"a":0,"k":[60,60]}},{"ty":"fl","nm":"f",'
    '"c":{"a":0,"k":[1,0.8,0,1]},"o":{"a":0,"k":100}},{"ty":"tr",'
    '"p":{"a":0,"k":[0,0]},"a":{"a":0,"k":[0,0]},"s":{"a":0,"k":[100,100]},'
    '"r":{"a":0,"k":0},"o":{"a":0,"k":100}}]}],"ip":0,"op":30,"st":0,"bm":0}]}',
  ),
);

class _Shot {
  const _Shot(
    this.page,
    this.size,
    this.dark,
    this.scale, {
    this.lang = AppLang.english,
    this.use24h = false,
  });
  final String page; // 'quick' or 'chat'
  final Size size;
  final bool dark;
  final double scale;
  final AppLang lang;
  final bool use24h;

  String get file =>
      'chat-${page}_${size.width.toInt()}x${size.height.toInt()}_'
      '${dark ? 'dark' : 'light'}_x$scale'
      '${lang == AppLang.english ? '' : '_${lang.code}'}'
      '${use24h ? '_24h' : ''}.png';
}

List<_Shot> _shots() => [
  for (final page in ['quick', 'chat'])
    for (final size in const [Size(640, 360), Size(891, 411)])
      for (final dark in [true, false])
        for (final scale in [1.0, 1.25]) _Shot(page, size, dark, scale),
  for (final page in ['quick', 'chat'])
    for (final dark in [true, false])
      _Shot(page, const Size(640, 360), dark, 1.25, lang: AppLang.hindi),
  for (final dark in [true, false])
    _Shot('chat', const Size(640, 360), dark, 1.25, use24h: true),
  _Shot('chat', const Size(592, 360), true, 1.25),
  _Shot('chat', const Size(915, 412), false, 1.25, use24h: true),
];

ChatMessage _line(String? id, String name, String text, int at) =>
    ChatMessage.fromJson({
      'messageId': '$id-$text-$at',
      'userId': id,
      'displayName': name,
      'text': text,
      'at': at,
      if (id == null) 'system': true,
    });

void _conversation(GameState state, AppLang lang) {
  final said = Strings(lang).quickMessages;
  final hindi = lang != AppLang.english;
  state.chat
    ..add(_line(null, 'Table', 'Vikramaditya joined the table', chatAt(9, 58)))
    ..add(
      _line(
        'u1',
        'Ravi',
        hindi ? said[0] : 'Good luck everyone',
        chatAt(10, 0),
      ),
    )
    ..add(_line('u2', 'Meera', said[1], chatAt(12, 41)))
    ..add(
      ChatMessage.fromJson({
        'messageId': 'emoji',
        'userId': 'u3',
        'displayName': 'Arjun',
        'text': 'Laughing',
        'at': chatAt(13, 5),
        'emoji': {
          'id': 7,
          'name': 'Laughing',
          'url': _emojiUrl,
          'assetFormat': 'LOTTIE',
        },
      }),
    )
    ..add(_line('u0', 'Priya', hindi ? said[2] : 'All the best', chatAt(15, 2)))
    ..add(
      _line(
        'u4',
        'Vikramaditya',
        hindi
            ? '${said[3]} ${said[4]}'
            : 'That was a close one, next hand is mine',
        chatAt(15, 7),
      ),
    )
    ..add(
      _line(
        null,
        'Table',
        'Ravindranath Chattopadhy left the table',
        chatAt(15, 9),
      ),
    )
    // A long name on an emoji line: the name whole, the emoji and its time
    // under it (27 Sep 2026 review).
    ..add(
      ChatMessage.fromJson({
        'messageId': 'emoji-long',
        'userId': 'u5',
        'displayName': 'Guest0E00B',
        'text': 'Laughing',
        'at': chatAt(19, 30),
        'emoji': {
          'id': 7,
          'name': 'Laughing',
          'url': _emojiUrl,
          'assetFormat': 'LOTTIE',
        },
      }),
    )
    ..add(
      _line(
        'u3',
        'Arjun',
        hindi ? said[5] : 'Oops! I should not have played it.',
        chatAt(23, 45),
      ),
    );
}

Future<void> _loadFonts() async {
  await loadScriptFonts();
  final icons = File(const String.fromEnvironment('ICON_FONT'));
  if (icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await loader.load();
  }
  PictureCache.prime(_emojiUrl, _lottie);
}

void main() {
  setUpAll(_loadFonts);
  final problems = <String>[];
  tearDownAll(() {
    if (_dir.isEmpty) return;
    File('$_dir/problems.txt').writeAsStringSync(
      problems.isEmpty ? 'none\n' : '${problems.join('\n')}\n',
    );
  });

  for (final shot in _shots()) {
    testWidgets(shot.file, (tester) async {
      debugDisableShadows = false;
      try {
        await _shoot(tester, shot, problems);
      } finally {
        debugDisableShadows = true;
      }
    });
  }
}

Future<void> _shoot(
  WidgetTester tester,
  _Shot shot,
  List<String> problems,
) async {
  tester.view.physicalSize = shot.size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = shot.scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  final scene = TableScene('chat', (s) {
    s.handleState(opponentTurnRoom());
    _conversation(s, shot.lang);
  });
  final state = sceneState(scene, lang: shot.lang);
  final base = shot.dark
      ? AppTheme.dark(sound: false)
      : AppTheme.light(sound: false);

  final key = GlobalKey();
  await tester.pumpWidget(
    // The phone's 24-hour setting, as the platform hands it to MediaQuery.
    MediaQuery(
      data: MediaQueryData.fromView(
        tester.view,
      ).copyWith(alwaysUse24HourFormat: shot.use24h),
      child: RepaintBoundary(
        key: key,
        child: tableApp(
          state: state,
          feedback: feedback,
          theme: withScriptFallback(base),
        ),
      ),
    ),
  );
  Future<void> settle(int ms) async {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump(Duration(milliseconds: ms));
  }

  await settle(900);
  await settle(900);
  if (shot.page == 'chat') {
    await openTableChat(tester, state);
  } else {
    await openChat(tester, state);
  }
  await settle(700);
  await settle(300);
  final problem = tester.takeException();
  if (problem != null) problems.add('${shot.file}: $problem');

  if (_dir.isNotEmpty) {
    await tester.runAsync(() async {
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
  final late = tester.takeException();
  if (late != null) problems.add('${shot.file} (teardown): $late');
  state.dispose();
}
