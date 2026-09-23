// The table's menu drawer, as its header reads on the tightest phone: the
// game's name alone beside the sitting's clock. The line carried the hand
// number too ("SEEN · hand 12") until the owner saw it cut to "SEEN · han…"
// beside the clock and asked for the hand text to go (24 Sep 2026: "some
// hand info text is visible, remove that text from UI").
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/table_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/table_chrome.dart';

const _code = 'ABCD2345';

/// A Teen Patti table of two in its twelfth hand, the viewer (u0) in seat 0.
RoomState _teenPattiRoom({String category = 'seen', bool private = false}) =>
    RoomState.fromJson({
      'roomId': 'r1',
      'code': _code,
      'isPrivate': private,
      'category': category,
      'state': 'betting',
      'handNo': 12,
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'pot': 400,
      'you': {'seatIndex': 0, 'chips': 20000, 'status': 'active'},
      'seats': [
        for (var i = 0; i < 2; i++)
          {
            'seatIndex': i,
            'userId': 'u$i',
            'displayName': 'Player $i',
            'chips': 20000,
            'status': 'active',
            'connected': true,
            'cardCount': 3,
          },
      ],
    });

/// A Hold'em room of two in its twelfth hand.
RoomState _pokerRoom() => RoomState.fromJson({
  'roomId': 'p1',
  'code': _code,
  'category': 'texas_holdem',
  'game': 'poker',
  'chipsHidden': true,
  'state': 'betting',
  'handNo': 12,
  'maxPlayers': 5,
  'minPlayers': 2,
  'bootAmount': 200,
  'turnTimeoutMs': 25000,
  'pot': 400,
  'you': {'seatIndex': 0, 'chips': 20000, 'status': 'active'},
  'seats': [
    for (var i = 0; i < 2; i++)
      {
        'seatIndex': i,
        'userId': 'u$i',
        'displayName': 'Player $i',
        'chips': i == 0 ? 20000 : null,
        'status': 'active',
        'connected': true,
        'cardCount': 2,
      },
  ],
  'poker': {
    'variant': 'texas_holdem',
    'street': 'preflop',
    'community': const <String>[],
    'pots': const <Map<String, dynamic>>[],
    'smallBlind': 100,
    'bigBlind': 200,
    'ante': 0,
    'holeCards': 2,
    'maxDiscards': 0,
    'minBuyIn': 2000,
  },
});

GameState _newState(RoomState room, {AppLang lang = AppLang.english}) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = lang
    ..user = User.fromJson({
      'id': 'u0',
      'provider': 'guest',
      'displayName': 'Player 0',
      'chips': 20000,
      'diamond': 2,
      'hammer': 20,
      'missile': 1,
    })
    ..screen = Screen.table
    ..handleState(room);
}

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

/// The table on the tightest phone, its menu drawer open.
Future<void> _pumpDrawer(WidgetTester tester, GameState state) async {
  tester.view.physicalSize = const Size(640, 360);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 1.25;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
        theme: AppTheme.dark(sound: false),
        builder: (context, child) => GlassBudget(child: child!),
        home: const TableScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(seconds: 1));
  state.tableScaffold.currentState!.openDrawer();
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _teardown(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

/// Any text on screen that names the hand the room is in.
Finder get _handNumber => find.textContaining(RegExp(r'\bhand\b.*\b12\b'));

/// A line of the menu drawer's own text: the felt prints the category too,
/// on every seat's card fan and on the tag over the pot.
Finder _inDrawer(String text) =>
    find.descendant(of: find.byType(TableDrawer), matching: find.text(text));

void main() {
  setUpAll(_loadInter);

  for (final category in ['seen', 'blind', 'variation']) {
    testWidgets("a $category table's menu header is the category alone, "
        'with no hand number and nothing cut', (tester) async {
      final state = _newState(_teenPattiRoom(category: category));
      await _pumpDrawer(tester, state);
      expect(tester.takeException(), isNull);

      final header = _inDrawer(category.toUpperCase());
      expect(header, findsOneWidget);
      expect(_handNumber, findsNothing, reason: 'the hand number is back');
      expect(
        tester.renderObject<RenderParagraph>(header).didExceedMaxLines,
        isFalse,
        reason: 'the header is ellipsised',
      );
      // A public table shows no code: nothing else names it.
      expect(_inDrawer('Table $_code'), findsNothing);
      await _teardown(tester, state);
    });
  }

  testWidgets("a private table keeps its 'Table <code>' line over the "
      'category, still with no hand number', (tester) async {
    final state = _newState(_teenPattiRoom(private: true));
    await _pumpDrawer(tester, state);
    expect(tester.takeException(), isNull);
    expect(_inDrawer('Table $_code'), findsOneWidget);
    expect(_inDrawer('SEEN'), findsOneWidget);
    expect(_handNumber, findsNothing);
    await _teardown(tester, state);
  });

  for (final lang in AppLang.values) {
    testWidgets("in ${lang.englishName} a poker room's menu header is the "
        "variant's name alone, whole", (tester) async {
      final t = Strings(lang);
      final state = _newState(_pokerRoom(), lang: lang);
      await _pumpDrawer(tester, state);
      expect(tester.takeException(), isNull, reason: '$lang');

      final header = _inDrawer(t.pokerVariantName('texas_holdem'));
      expect(header, findsOneWidget, reason: '$lang');
      expect(_handNumber, findsNothing, reason: '$lang');
      expect(
        tester.renderObject<RenderParagraph>(header).didExceedMaxLines,
        isFalse,
        reason: '$lang: the header is ellipsised',
      );
      await _teardown(tester, state);
    });
  }
}
