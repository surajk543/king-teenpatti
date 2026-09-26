// The store's Badges shelf (owner, 27 Sep 2026: "Add a icon in Store to buy
// badges, and for all type of royal badges Add a button to contact support in
// store"; then "for badges use this entry, not vips entry … Add this in UI
// store and with their lottie animation": Royal Ace, King, Master, Emperor,
// Legend and King of Kings, 0% for 7 to 90 days at ₹499 to ₹4,499; "price in
// badges will always be in inr currency"; "By default every user will hold
// this Regular badge … do not show this badge in store"; "remove the entry
// vip, royal vip and elite vip").
//
// The shelf lists every badge with a price but the default one — the Royal
// ones, never Regular, nor one an owner gives by hand with no price — each card playing its Lottie beside its name, over its rate and how
// long it lasts, its price on the key ("for all badges i have given u price
// 499, 999, 1799, these should be shown in button not the text contact
// support"); a badge Play sells is bought at its price, the key of a royal
// one asks for it through support. A badge the player holds says so, with
// the time it has left.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/picture_cache.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/chip_store.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

int get _now => DateTime.now().millisecondsSinceEpoch;

/// A Lottie as small as one can be: a spinning disc, one layer.
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

String _art(String code) => 'https://drive.test/badges/$code.json';

/// The owner's Royal badges: code, name, days, rupees.
const List<(String, String, int, int)> _royal = [
  ('ROYAL_ACE', 'Royal Ace', 7, 499),
  ('ROYAL_KING', 'Royal King', 15, 999),
  ('ROYAL_MASTER', 'Royal Master', 30, 1799),
  ('ROYAL_EMPEROR', 'Royal Emperor', 45, 2499),
  ('ROYAL_LEGEND', 'Royal Legend', 60, 3299),
  ('ROYAL_KING_OF_KINGS', 'Royal King of Kings', 90, 4499),
];

/// The badges as `GET /api/levels` sends them, the levels cut to one.
/// [onPlay] puts that badge on Play, as an owner's row may.
LevelLadder _ladder({String? onPlay}) => LevelLadder.maybe({
  'levels': [
    {'level': 1, 'title': 'Newbie', 'icon': '🌱', 'minXp': 0, 'taxBps': 2000},
  ],
  'badges': [
    // Everyone's, for life, at ₹0: never in the store.
    {
      'code': 'REGULAR',
      'title': 'Regular',
      'icon': '',
      'taxBps': 2000,
      'validityDays': 0,
      'isDefault': true,
      'priceInr': 0,
      'assetUrl': _art('REGULAR'),
      'assetFormat': 'LOTTIE',
    },
    // One an owner added and gives by hand, with no price: not listed.
    {
      'code': 'GOLD',
      'title': 'Gold',
      'icon': '🏅',
      'taxBps': 500,
      'validityDays': 1825,
      'isDefault': false,
      'priceInr': null,
    },
    for (final (code, title, days, rupees) in _royal)
      {
        'code': code,
        'title': title,
        'icon': '',
        'taxBps': 0,
        'validityDays': days,
        'isDefault': false,
        'priceInr': rupees,
        'assetUrl': _art(code),
        'assetFormat': 'LOTTIE',
        if (code == onPlay) 'productId': 'badge_${code.toLowerCase()}',
      },
  ],
  'xpSources': const <Object>[],
  'dailyCap': null,
  'windowMs': 86400000,
})!;

GameState _state({
  AppLang lang = AppLang.english,
  bool holdsKing = false,
  String? onPlay,
}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..screen = Screen.lobby
    ..levelLadder = _ladder(onPlay: onPlay)
    ..user = User.fromJson({
      'id': 'u1',
      'provider': 'guest',
      'displayName': 'Ravi',
      'chips': 1000000,
      'diamond': 9,
      'hammer': 20,
      'missile': 1,
      // No badge by default (owner, 27 Sep 2026).
      'badges': [
        if (holdsKing)
          {
            'code': 'ROYAL_KING',
            'title': 'Royal King',
            'icon': '',
            'taxBps': 0,
            'expiresAt': _now + 10 * 24 * 3600 * 1000 + 60 * 1000,
            'assetUrl': _art('ROYAL_KING'),
            'assetFormat': 'LOTTIE',
          },
      ],
    });
}

Future<void> _openStore(
  WidgetTester tester,
  GameState state,
  FeedbackSettings feedback, {
  Size screen = const Size(891, 411),
  double textScale = 1,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
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
        theme: AppTheme.dark(sound: false),
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
  unawaited(showChipStore(host, opensOn: StoreTab.badges));
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
}

Future<void> _close(
  WidgetTester tester,
  GameState state,
  FeedbackSettings f,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 2));
  state.dispose();
  f.dispose();
}

Finder _card(String code) => find.byKey(ValueKey('badge-card-$code'));

Finder _onCard(String code, String text) =>
    find.descendant(of: _card(code), matching: find.text(text));

void main() {
  setUpAll(() async {
    await loadScriptFonts();
    for (final (code, _, _, _) in _royal) {
      PictureCache.prime(_art(code), _lottie);
    }
  });
  tearDownAll(PictureCache.clearMemory);

  testWidgets('the shelf is the last store key, with its own icon', (
    tester,
  ) async {
    expect(StoreTab.values.last, StoreTab.badges);
    final state = _state();
    final f = FeedbackSettings();
    await _openStore(tester, state, f);
    expect(find.byIcon(Icons.workspace_premium_rounded), findsWidgets);
    expect(find.text(state.t.storeBadgesBlurb), findsOneWidget);
    await _close(tester, state, f);
  });

  testWidgets('the six Royal badges and never Regular or an unpriced one, in '
      'the owner\'s order, each playing its Lottie beside its price, over its '
      'name, its rate and its days, with a key to contact support', (
    tester,
  ) async {
    final state = _state();
    final t = state.t;
    final f = FeedbackSettings();
    await _openStore(tester, state, f);
    for (final code in ['REGULAR', 'GOLD']) {
      expect(_card(code), findsNothing, reason: '$code is not for sale');
    }
    Offset? before;
    for (final (code, title, days, rupees) in _royal) {
      final card = _card(code);
      await tester.ensureVisible(card);
      await tester.pump();
      expect(card, findsOneWidget, reason: code);
      final at = tester.getTopLeft(card);
      if (before != null) {
        expect(
          at.dy > before.dy + 1 ||
              ((at.dy - before.dy).abs() <= 1 && at.dx > before.dx),
          isTrue,
          reason: '$code stands after the badge before it',
        );
      }
      before = at;
      final price = rupees >= 1000
          ? '₹${rupees ~/ 1000},${(rupees % 1000).toString().padLeft(3, '0')}'
          : '₹$rupees';
      expect(_onCard(code, price), findsOneWidget, reason: '$code $price');
      expect(_onCard(code, title), findsOneWidget);
      expect(_onCard(code, t.badgeTaxLine('0%')), findsOneWidget);
      expect(_onCard(code, t.badgeLasts(days)), findsOneWidget);
      expect(
        _onCard(code, t.badgeContactSupport),
        findsNothing,
        reason: 'the key names the price',
      );
      expect(
        find.descendant(of: card, matching: find.byType(Lottie)),
        findsOneWidget,
        reason: '$code plays its animation',
      );
    }
    await _close(tester, state, f);
  });

  testWidgets('a royal badge asks the player to contact support: the address '
      'to copy, and a key that writes to it', (tester) async {
    final state = _state();
    final t = state.t;
    final f = FeedbackSettings();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _openStore(tester, state, f);
    await tester.tap(_onCard('ROYAL_ACE', '₹499'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('badge-support')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('badge-support-terms')))
          .data,
      '₹499 · ${t.badgeLasts(7)}',
    );
    expect(find.text(t.badgeContactTitle('Royal Ace')), findsOneWidget);
    expect(find.text(t.badgeContactBody('Royal Ace')), findsOneWidget);
    expect(find.text('support@sungamestudio.com'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('badge-support-copy')));
    await tester.pump();
    expect(copied, 'support@sungamestudio.com');
    expect(state.notice, t.addressCopied);
    await _close(tester, state, f);
  });

  testWidgets('a badge put on Play is bought through Play — and says so where '
      'Play is not there', (tester) async {
    final state = _state(onPlay: 'ROYAL_ACE');
    final f = FeedbackSettings();
    await _openStore(tester, state, f);
    // No Play on the test host: its price is the rupees, on the key, and the
    // key goes to Play rather than to support.
    await tester.tap(_onCard('ROYAL_ACE', '₹499'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(state.notice, state.t.storeNotLive);
    await _close(tester, state, f);
  });

  testWidgets('a badge the player holds says so, with the time it has left', (
    tester,
  ) async {
    final state = _state(holdsKing: true);
    final t = state.t;
    final f = FeedbackSettings();
    await _openStore(tester, state, f);
    expect(_onCard('ROYAL_KING', '✓ ${t.pictureOwned}'), findsOneWidget);
    expect(_onCard('ROYAL_KING', '10 days left'), findsOneWidget);
    expect(_onCard('ROYAL_ACE', '✓ ${t.pictureOwned}'), findsNothing);
    await _close(tester, state, f);
  });

  for (final lang in AppLang.values) {
    testWidgets('the shelf fits a 640x360 phone at text x1.25 in '
        '${lang.name}', (tester) async {
      final state = _state(lang: lang, holdsKing: true);
      final f = FeedbackSettings();
      await _openStore(
        tester,
        state,
        f,
        screen: const Size(640, 360),
        textScale: 1.25,
      );
      expect(tester.takeException(), isNull);
      for (final (code, _, _, _) in _royal) {
        final card = _card(code);
        expect(card, findsOneWidget, reason: code);
        await tester.ensureVisible(card);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: code);
        // Each card's words stand inside it.
        final box = tester.getRect(card).inflate(1);
        for (final text in tester.widgetList<Text>(
          find.descendant(of: card, matching: find.byType(Text)),
        )) {
          final rect = tester.getRect(find.byWidget(text));
          expect(
            box.contains(rect.topLeft) && box.contains(rect.bottomRight),
            isTrue,
            reason: '$code: ${text.data} in ${lang.name}',
          );
        }
      }
      await _close(tester, state, f);
    });
  }
}
