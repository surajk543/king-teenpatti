// Player stats v2 on screen (owner, 27 Sep 2026: "Show the stats acc to each
// category"). The three games' records read off the wire — tolerant, zeros
// wherever nothing was sent, and no chip figure ever read from another
// player's profile — and another player's record, ONE widget in both its
// places: the lobby's Friends page profile and the table's player drawer
// (never a chip figure). Each gains All · Teen Patti · Variation · Poker; Teen
// Patti and Variation count the hands held, Trail down to High Card, in the
// server's English; Variation lists the variations played and won, in the
// picker's names; and every view fits a 640x360 phone at text x1.25 in all
// five languages, by day and by night, with the Noto fonts a phone falls back
// to. The lobby's Stats drawer — the player's own record — has drawn it with a
// presentation of its own since the owner's brief of 27 Sep 2026 (no tabs, no
// Poker); its figures are checked here, and the rest in stats_drawer_test.dart.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/config/features.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/models/friends.dart';
import 'package:teenpatti/models/player_stats.dart';
import 'package:teenpatti/screens/friends_screen.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/hammer_flight.dart';
import 'package:teenpatti/widgets/own_record.dart';
import 'package:teenpatti/widgets/player_drawer.dart';
import 'package:teenpatti/widgets/player_profile.dart';
import 'package:teenpatti/widgets/poker_chip.dart';
import 'package:teenpatti/widgets/premium_surface.dart';
import 'package:teenpatti/widgets/seat_pod.dart';

import 'friends_fixture.dart';
import 'player_stats_fixture.dart';
import 'script_fonts.dart';
import 'table_scenes.dart' show silentFeedback, tableApp;

// --------------------------------------------------------------- finders

Finder _key(String key) => find.byKey(ValueKey(key));

Finder _segment(StatsCategory view) => _key('stats-category-${view.name}');

/// [text] in the widget keyed [key], or that widget itself.
Finder _textIn(String key, String text) =>
    find.descendant(of: _key(key), matching: find.text(text), matchRoot: true);

/// A rectangle on the screen, through every transform above [box].
Rect _onScreen(RenderBox box) =>
    MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);

/// Every line of the record under [root] whole and inside [panel], and
/// nothing thrown while laying it out.
void _expectFits(WidgetTester tester, Finder root, Rect panel, String where) {
  expect(tester.takeException(), isNull, reason: where);
  var lines = 0;
  for (final e
      in find
          .descendant(of: root, matching: find.byType(RichText))
          .evaluate()) {
    final paragraph = e.renderObject! as RenderParagraph;
    if (!paragraph.attached || !paragraph.hasSize) continue;
    lines++;
    final line = paragraph.text.toPlainText();
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: '$where: "$line" cut short',
    );
    final rect = _onScreen(paragraph);
    expect(
      rect.left,
      greaterThanOrEqualTo(panel.left - 0.5),
      reason: '$where: "$line" $rect outside $panel',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(panel.right + 0.5),
      reason: '$where: "$line" $rect outside $panel',
    );
  }
  expect(lines, greaterThan(8), reason: '$where: the record was not built');
}

/// The keys of the switch — one per view the build shows ([statsViews]):
/// whole touch targets, inside the record, apart from each other — and two
/// to a row, or all across when [across]. A view the build does not show has
/// no key.
void _expectSwitch(WidgetTester tester, String where, {bool? across}) {
  final track = tester.getRect(_key('stats-categories'));
  final views = statsViews();
  for (final view in StatsCategory.values) {
    if (!views.contains(view)) {
      expect(_segment(view), findsNothing, reason: '$where ${view.name}');
    }
  }
  final keys = [for (final view in views) tester.getRect(_segment(view))];
  for (final (i, rect) in keys.indexed) {
    expect(rect.height, greaterThanOrEqualTo(44 - 0.5), reason: '$where $i');
    expect(rect.left, greaterThanOrEqualTo(track.left - 0.5));
    expect(rect.right, lessThanOrEqualTo(track.right + 0.5));
    for (final other in keys.skip(i + 1)) {
      expect(
        rect.intersect(other).width > 0.5 && rect.intersect(other).height > 0.5,
        isFalse,
        reason: '$where: key $i over another',
      );
    }
  }
  final rows = keys.map((r) => r.top.round()).toSet();
  if (across == true) expect(rows, hasLength(1), reason: where);
  if (across == false) expect(rows, hasLength(2), reason: where);
  // A row the keys do not fill is shared by its keys: none stands alone in
  // half of the track.
  for (final top in rows) {
    final row = keys.where((r) => r.top.round() == top).toList();
    final width = row.fold(0.0, (sum, r) => sum + r.width);
    expect(
      width,
      greaterThan(track.width - 2 * 3 - (row.length - 1) * 3 - 1),
      reason: '$where: a row of ${row.length} leaves the track part empty',
    );
  }
}

/// Each language's own words for its wallets — chips, diamonds, hammers,
/// missiles, lakh, crore — as stems, so a declension still matches (the
/// Friends at the table suite's own list).
const _walletWords = {
  AppLang.english: <String>[],
  AppLang.hindi: ['चिप', 'हीर', 'हथौ', 'मिसाइल', 'लाख', 'करोड़', 'सिक्'],
  AppLang.bengali: ['চিপ', 'হীর', 'হাতুড়', 'মিসাইল', 'লাখ', 'কোটি'],
  AppLang.gujarati: ['ચિપ', 'હીર', 'હથો', 'મિસાઇલ', 'લાખ', 'કરોડ'],
  AppLang.punjabi: ['ਚਿਪ', 'ਹੀਰ', 'ਹਥੌ', 'ਮਿਜ਼ਾਈਲ', 'ਲੱਖ', 'ਕਰੋੜ'],
};

/// Nothing under [root] is, or names, a wallet: no chip figure — neither of
/// the two slipped into another player's profile, in any form — no word of
/// one, no coin, and no winnings or biggest pot tile.
void _expectNoChipFigure(
  WidgetTester tester,
  Finder root,
  Strings t,
  String where,
) {
  final wallet = RegExp(
    r'chip|diamond|hammer|missile|coin|wallet|lakh|crore|million|₹|balance',
    caseSensitive: false,
  );
  final stray = [
    for (final n in [strayWinnings, strayBiggest]) ...[
      '$n',
      formatChips(n),
      _grouped(n),
    ],
  ];
  for (final e
      in find
          .descendant(of: root, matching: find.byType(RichText))
          .evaluate()) {
    final line = (e.widget as RichText).text.toPlainText();
    expect(wallet.hasMatch(line), isFalse, reason: '$where: "$line"');
    for (final word in _walletWords[t.lang]!) {
      expect(line, isNot(contains(word)), reason: '$where: "$line"');
    }
    for (final figure in stray) {
      expect(line, isNot(contains(figure)), reason: '$where: "$line"');
    }
    expect(line, isNot(t.totalWinnings), reason: where);
    expect(line, isNot(t.biggestPot), reason: where);
  }
  for (final icon in [
    Icons.savings_outlined,
    Icons.local_fire_department_outlined,
  ]) {
    expect(
      find.descendant(of: root, matching: find.byIcon(icon)),
      findsNothing,
      reason: where,
    );
  }
  expect(
    find.descendant(of: root, matching: find.byType(PokerChip)),
    findsNothing,
  );
}

/// A count grouped by thousands, as the record writes one.
String _grouped(int n) {
  final s = '$n';
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// Chooses [view] on the record's switch and lets one view cross over the
/// other.
Future<void> _choose(WidgetTester tester, StatsCategory view) async {
  await tester.ensureVisible(_segment(view));
  await tester.pump();
  await tester.tap(_segment(view));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// The view on show: its figures, and the hands held and the variations
/// played exactly where that view has them; the figures end on another
/// player's win rate.
void _expectView(
  WidgetTester tester,
  Strings t,
  StatsCategory view,
  Map<String, dynamic> game, {
  required String where,
}) {
  expect(_key('stats-view-${view.name}'), findsOneWidget, reason: where);
  for (final other in StatsCategory.values.where((v) => v != view)) {
    expect(_key('stats-view-${other.name}'), findsNothing, reason: where);
  }
  final left = game['handsLeft'] ?? game['handsLeftMid'];
  final figures = [
    (t.handsPlayed, _grouped(game['handsPlayed'] as int)),
    (t.won, _grouped(game['handsWon'] as int)),
    (t.lost, _grouped(game['handsLost'] as int)),
    (t.leftMidHand, _grouped(left as int)),
    (t.winRate, '${game['winRate']}%'),
  ];
  for (final (i, (label, value)) in figures.indexed) {
    expect(_textIn('friend-stat-$i', label), findsOneWidget, reason: where);
    expect(_textIn('friend-stat-$i', value), findsOneWidget, reason: where);
  }
  expect(_key('friend-stat-${figures.length}'), findsNothing, reason: where);

  if (view.countsHands) {
    expect(find.text(t.handsHeld), findsOneWidget, reason: where);
    final hands = game['hands'] as Map<String, int>;
    for (final (i, field) in HandTally.fields.indexed) {
      final cell = 'stats-hand-$field';
      expect(_textIn(cell, HandTally.names[i]), findsOneWidget, reason: where);
      expect(_textIn(cell, '${hands[field]}'), findsOneWidget, reason: where);
      // Each hand wears its icon, the daily XP's own mark for it.
      expect(_textIn(cell, HandTally.icons[i]), findsOneWidget, reason: where);
    }
  } else {
    expect(find.text(t.handsHeld), findsNothing, reason: where);
    expect(_key('stats-hands'), findsNothing, reason: where);
  }

  if (view.listsVariations) {
    expect(find.text(t.variationsPlayed), findsOneWidget, reason: where);
    expect(_textIn('stats-variations', t.statsPlayed), findsOneWidget);
    expect(_textIn('stats-variations', t.statsWon), findsOneWidget);
    final rows = game['variations'] as List<Map<String, dynamic>>;
    final tops = <double>[];
    for (final row in rows) {
      final name = row['variation'] as String;
      final label = _key('stats-variation-$name');
      expect(
        tester.widget<Text>(label).data,
        t.variationName(name),
        reason: where,
      );
      expect(
        _textIn('stats-variation-$name-played', '${row['handsPlayed']}'),
        findsOneWidget,
      );
      expect(
        _textIn('stats-variation-$name-won', '${row['handsWon']}'),
        findsOneWidget,
      );
      tops.add(tester.getRect(label).top);
    }
    // In the server's order, Muflis first.
    expect(tops, [...tops]..sort(), reason: where);
  } else {
    expect(find.text(t.variationsPlayed), findsNothing, reason: where);
    expect(_key('stats-variations'), findsNothing, reason: where);
  }
}

// ----------------------------------------------------------- the surfaces

void _setView(
  WidgetTester tester, {
  Size size = const Size(640, 360),
  double scale = 1.25,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// The lobby with its Stats drawer open.
Future<GameState> _openStats(
  WidgetTester tester, {
  AppLang lang = AppLang.english,
  Brightness brightness = Brightness.dark,
  Map<String, dynamic>? me,
}) async {
  final state = statsLobbyState(lang: lang, me: me);
  final feedback = FeedbackSettings();
  addTearDown(() {
    state.dispose();
    feedback.dispose();
  });
  await tester.pumpWidget(
    statsApp(state, feedback, const LobbyScreen(), brightness: brightness),
  );
  await tester.pump(const Duration(seconds: 1));
  await tester.tap(find.byIcon(Icons.insights_outlined).first);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  // The record's entrance starts on the frame the drawer settles in, and
  // runs Motion.enter from there.
  await tester.pump(const Duration(milliseconds: 600));
  return state;
}

Future<void> _closeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}

/// Frames enough for the Friends page to rise, read its lists and settle.
Future<void> _settlePage(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 300));
}

/// The Friends page, open on Meera's profile, which carries [stats].
Future<GameState> _openProfile(
  WidgetTester tester,
  FakeFriendsServer server, {
  AppLang lang = AppLang.english,
  Brightness brightness = Brightness.dark,
}) async {
  final state = signedInState(lang: lang);
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    statsApp(
      state,
      feedback,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showFriends(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      brightness: brightness,
    ),
  );
  await tester.tap(find.text('open'));
  await _settlePage(tester);
  await tester.ensureVisible(_key('friend-u-meera'));
  await tester.pump();
  await tester.tap(_key('friend-u-meera'));
  await _settlePage(tester);
  return state;
}

Future<void> _closePage(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

/// Priya, seated at [statsTableRoom], as the app mounts a table.
Future<GameState> _mountTable(
  WidgetTester tester, {
  AppLang lang = AppLang.english,
  Brightness brightness = Brightness.dark,
}) async {
  final state = statsTableState(lang: lang);
  final feedback = await silentFeedback();
  addTearDown(feedback.dispose);
  state.handleState(statsTableRoom());
  await tester.pumpWidget(
    tableApp(state: state, feedback: feedback, theme: statsTheme(brightness)),
  );
  await tester.pump(const Duration(milliseconds: 900));
  await tester.pump(const Duration(milliseconds: 900));
  return state;
}

Future<void> _unmountTable(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
  state.dispose();
}

Finder _plaqueOf(String userId) => find.descendant(
  of: find.byWidgetPredicate((w) => w is SeatPod && w.seat?.userId == userId),
  matching: find.byType(PodImpact),
);

Future<void> _openSeat(WidgetTester tester, String userId) async {
  await tester.tap(_plaqueOf(userId));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _inDrawer(Finder matching) =>
    find.descendant(of: find.byType(PlayerDrawer), matching: matching);

// ------------------------------------------------------------------- main

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadScriptFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({'soundOn': false}));

  group('the wire', () {
    testWidgets('leaving a table reads the account at once and once more just '
        'after the stats flush, and signing out cancels the second read', (
      tester,
    ) async {
      var reads = 0;
      final client = MockClient((r) async {
        if (r.url.path == '/api/auth/me') {
          reads++;
          return http.Response(
            jsonEncode({'user': meWithStatsJson()}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      });
      await http.runWithClient(() async {
        final state = statsLobbyState()..debugToken = 'tok';
        state.handleBackToLobby();
        await tester.pump();
        expect(reads, 1, reason: 'the lobby reads the account at once');
        await tester.pump(
          GameState.statsCatchUpAfter - const Duration(seconds: 1),
        );
        expect(reads, 1, reason: 'nothing more before the flush');
        await tester.pump(const Duration(seconds: 1));
        expect(
          reads,
          2,
          reason: 'one more read just after the server moves the counters',
        );
        await tester.pump(const Duration(minutes: 1));
        expect(reads, 2, reason: 'and only one');

        state.handleBackToLobby();
        await tester.pump();
        expect(reads, 3);
        await state.signOut();
        await tester.pump(GameState.statsCatchUpAfter * 2);
        expect(reads, 3, reason: 'signed out: the second read never happens');
        state.dispose();
      }, () => client);
    });

    test(
      'every copy of the account keeps the games: a player:level push, a '
      'fired missile and a hammer count leave the per-game record as it was',
      () {
        final user = User.fromJson(meWithStatsJson());
        final standing = Standing.maybe({
          'playerLevel': {
            'level': 10,
            'title': 'Rising Star',
            'icon': '🌟',
            'xp': 4180,
            'taxBps': 1743,
          },
          'badges': const <Object>[],
          'taxBps': 1743,
        })!;
        // The merge of Player stats v2 onto the player levels once dropped
        // `stats:` from withStanding, so every level-up zeroed the three games.
        for (final copy in [
          user.withStanding(standing),
          user.withMissile(0),
          user.withHammer(3),
        ]) {
          expect(copy.stats.teenPatti.handsPlayed, 912);
          expect(copy.stats.variation.handsPlayed, 380);
          expect(
            copy.stats.teenPatti.hands.counts,
            user.stats.teenPatti.hands.counts,
          );
          expect(copy.handsPlayed, user.handsPlayed);
        }
        expect(user.withStanding(standing).playerLevel!.level, 10);
      },
    );

    test('the player\'s own account reads each game: its figures, both chip '
        'figures, its win rate, the hands held and the variations played', () {
      final user = User.fromJson(meWithStatsJson());
      final tp = user.stats.teenPatti;
      expect(tp.handsPlayed, 912);
      expect(tp.handsWon, 401);
      expect(tp.handsLost, 473);
      expect(tp.handsLeft, 38);
      expect(tp.totalWinnings, 5400000);
      expect(tp.biggestPot, 812000);
      expect(tp.winRate, 43.97);
      expect(tp.hands.counts, [3, 5, 29, 47, 153, 661]);
      expect(tp.hands.total, 898);
      expect(tp.variations, isEmpty);

      final v = user.stats.variation;
      expect(v.handsPlayed, 380);
      expect(v.totalWinnings, 3900000);
      expect(v.hands.trail, 24);
      expect(v.hands.pureSequence, 9);
      expect(v.hands.sequence, 33);
      expect(v.hands.color, 41);
      expect(v.hands.pair, 91);
      expect(v.hands.highCard, 182);
      expect(
        [for (final row in v.variations) row.variation],
        [
          'MUFLIS',
          'AK47',
          'JOKER',
          'HUKAM',
          'LOWEST_JOKER',
          'HIGHEST_JOKER',
          'FIVE_CARD',
        ],
      );
      expect(v.variations.first.handsPlayed, 120);
      expect(v.variations.first.handsWon, 50);

      final poker = user.stats.poker;
      expect(poker.handsPlayed, 206);
      expect(poker.biggestPot, 402000);
      expect(poker.hands.total, 0);
      expect(poker.variations, isEmpty);

      // All: the six totals the account always carried.
      final all = user.totals;
      expect(all.handsPlayed, 1498);
      expect(all.handsWon, 610);
      expect(all.handsLost, 813);
      expect(all.handsLeft, 75);
      expect(all.totalWinnings, 9876500);
      expect(all.biggestPot, 1250000);
    });

    test('nothing sent reads as zeros, never as an error; junk is dropped', () {
      for (final user in [
        User.fromJson({'id': 'u1'}),
        User.fromJson({'id': 'u1', 'stats': 'lots'}),
        User.fromJson({
          'id': 'u1',
          'stats': {'teenPatti': 5, 'variation': null, 'poker': []},
        }),
      ]) {
        for (final game in [
          user.stats.teenPatti,
          user.stats.variation,
          user.stats.poker,
        ]) {
          expect(game.handsPlayed, 0);
          expect(game.handsWon, 0);
          expect(game.handsLost, 0);
          expect(game.handsLeft, 0);
          expect(game.totalWinnings, 0);
          expect(game.biggestPot, 0);
          expect(game.winRate, 0);
          expect(game.hands.counts, List.filled(6, 0));
          expect(game.variations, isEmpty);
        }
      }
      final junk = CategoryStats.fromJson({
        'handsPlayed': '12',
        'handsWon': null,
        'winRate': 250,
        'hands': {'trail': 'x', 'pair': 4.9, 'highCard': 7},
        'variations': [
          'MUFLIS',
          {'handsPlayed': 3},
          {'variation': '', 'handsPlayed': 1},
          {'variation': 'AK47', 'handsPlayed': 'many', 'handsWon': 2},
          {'variation': 'NEW_ONE', 'handsPlayed': 1, 'handsWon': 1},
        ],
      });
      expect(junk.handsPlayed, 0);
      expect(junk.handsWon, 0);
      expect(junk.winRate, 100);
      expect(junk.hands.trail, 0);
      expect(junk.hands.pair, 4);
      expect(junk.hands.highCard, 7);
      // A row with no variation is no row; one this build has never heard
      // of is kept, as the server sent it.
      expect(
        [for (final row in junk.variations) row.variation],
        ['AK47', 'NEW_ONE'],
      );
      expect(junk.variations.first.handsPlayed, 0);
      expect(junk.variations.first.handsWon, 2);
      expect(CategoryStats.fromJson({'winRate': -3}).winRate, 0);
      expect(
        CategoryStats.fromJson({'variations': 'MUFLIS'}).variations,
        isEmpty,
      );
    });

    test('another player\'s profile reads each game with no chip figure, '
        'whatever the server sent', () {
      final profile = PublicProfile.fromJson({
        'profile': {
          ...cardJson('u-meera', 'Meera'),
          'friendStatus': 'FRIENDS',
          'stats': theirStatsJson(),
        },
      });
      final stats = profile.stats;
      expect(stats.handsPlayed, 1498);
      expect(stats.winRate, 40.72);
      for (final game in [
        stats.categories.teenPatti,
        stats.categories.variation,
        stats.categories.poker,
      ]) {
        expect(game.totalWinnings, 0);
        expect(game.biggestPot, 0);
      }
      expect(stats.categories.teenPatti.handsPlayed, 912);
      expect(stats.categories.teenPatti.winRate, 43.97);
      expect(stats.categories.variation.hands.trail, 24);
      expect(stats.categories.variation.variations, hasLength(7));
      expect(stats.categories.poker.handsWon, 59);
      // All: the totals, and a win rate — never a chip figure.
      expect(stats.totals.handsLeft, 75);
      expect(stats.totals.winRate, 40.72);
      expect(stats.totals.totalWinnings, 0);
      // A request answered keeps the record.
      final moved = profile.withStatus(FriendStatus.none);
      expect(moved.stats.categories.teenPatti.handsPlayed, 912);
      // A profile with no games reads zeros.
      expect(
        PlayerStats.fromJson(statsJson()).categories.variation.handsPlayed,
        0,
      );
    });

    test('a new hammer or missile count keeps the record', () {
      final user = User.fromJson(meWithStatsJson());
      expect(user.withHammer(3).stats.variation.handsPlayed, 380);
      expect(user.withMissile(3).stats.poker.biggestPot, 402000);
    });

    test('the views: which count the hands held, which list variations, and '
        'what the six hands are called', () {
      expect(StatsCategory.values, [
        StatsCategory.all,
        StatsCategory.teenPatti,
        StatsCategory.variation,
        StatsCategory.poker,
      ]);
      expect(
        [for (final v in StatsCategory.values) v.countsHands],
        [false, true, true, false],
      );
      expect(
        [for (final v in StatsCategory.values) v.listsVariations],
        [false, false, true, false],
      );
      // The server's own English names, strongest first, keyed as the wire
      // keys them.
      expect(HandTally.names, [
        'Trail',
        'Pure Sequence',
        'Sequence',
        'Color',
        'Pair',
        'High Card',
      ]);
      expect(HandTally.fields, [
        'trail',
        'pureSequence',
        'sequence',
        'color',
        'pair',
        'highCard',
      ]);
      const games = StatsByCategory(
        teenPatti: CategoryStats(handsPlayed: 1),
        variation: CategoryStats(handsPlayed: 2),
        poker: CategoryStats(handsPlayed: 3),
      );
      expect(games.of(StatsCategory.teenPatti).handsPlayed, 1);
      expect(games.of(StatsCategory.variation).handsPlayed, 2);
      expect(games.of(StatsCategory.poker).handsPlayed, 3);
      expect(games.of(StatsCategory.all).handsPlayed, 0);
    });
  });

  group('the words', () {
    test('the views go by the lobby\'s own names, in every language', () {
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        expect(statsCategoryName(t, StatsCategory.all), t.statsAll);
        expect(
          statsCategoryName(t, StatsCategory.teenPatti),
          friendlyName(t.teenPatti),
        );
        expect(
          statsCategoryName(t, StatsCategory.variation),
          friendlyName(t.variation),
        );
        expect(
          statsCategoryName(t, StatsCategory.poker),
          friendlyName(t.poker),
        );
      }
      const t = Strings(AppLang.english);
      expect(
        [for (final v in StatsCategory.values) statsCategoryName(t, v)],
        ['All', 'Teen Patti', 'Variation', 'Poker'],
      );
    });

    test('every new word is written in all five languages, and none names '
        'a wallet', () {
      const keys = [
        'statsAll',
        'handsHeld',
        'variationsPlayed',
        'statsPlayed',
        'statsWon',
        'statsNoVariations',
      ];
      const english = Strings(AppLang.english);
      expect(english.statsAll, 'All');
      expect(english.handsHeld, 'Hands held');
      expect(english.variationsPlayed, 'Variations played');
      expect(english.statsPlayed, 'Played');
      expect(english.statsWon, 'Won');
      expect(english.statsNoVariations, 'No variation hands yet');
      final wallet = RegExp(
        r'chip|diamond|hammer|missile|coin|wallet|lakh|crore|₹',
        caseSensitive: false,
      );
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        for (final key in keys) {
          final own = t.ownEntry(key);
          expect(own, isNotNull, reason: '${lang.name} $key');
          expect(own!.trim(), isNotEmpty, reason: '${lang.name} $key');
          if (lang != AppLang.english) {
            expect(own, isNot(english.ownEntry(key)), reason: lang.name);
          }
        }
        for (final line in [
          for (final key in keys) t.ownEntry(key)!,
          for (final v in StatsCategory.values) statsCategoryName(t, v),
          for (final row in allVariationsJson)
            t.variationName(row['variation'] as String),
          ...HandTally.names,
        ]) {
          expect(wallet.hasMatch(line), isFalse, reason: '${lang.name} $line');
          for (final word in _walletWords[lang]!) {
            expect(line, isNot(contains(word)), reason: '${lang.name} $line');
          }
        }
      }
    });
  });

  // The lobby's Stats drawer no longer draws this widget (the owner's brief,
  // 27 Sep 2026: one continuous profile, no tabs, no Poker): it draws the
  // player's own record with OwnRecord, and stats_drawer_test.dart holds it —
  // the scope menu, its semantics, the empty states and every size. What this
  // suite held of the drawer's figures still holds, scope by scope, here.
  group('the lobby\'s Stats drawer: the player\'s own record', () {
    testWidgets('draws the account\'s own figures — the six totals in All '
        'Games, chip figures in gold, then each game — with no switch and no '
        'Poker', (tester) async {
      _setView(tester);
      final state = await _openStats(tester);
      final t = state.t;
      final me = meWithStatsJson();
      final drawer = find.byType(Drawer);
      expect(
        find.descendant(of: drawer, matching: find.byType(PlayerStatsGrid)),
        findsNothing,
      );
      expect(
        find.descendant(of: drawer, matching: find.byType(OwnRecord)),
        findsOneWidget,
      );
      expect(_key('stats-categories'), findsNothing);
      void figures(Map<String, dynamic> game, String where) {
        for (final (key, value) in [
          ('stats-played', _grouped(game['handsPlayed'] as int)),
          ('stats-won', _grouped(game['handsWon'] as int)),
          ('stats-lost', _grouped(game['handsLost'] as int)),
          ('stats-total-winnings', formatChips(game['totalWinnings'] as int)),
          ('stats-biggest-pot', formatChips(game['biggestPot'] as int)),
        ]) {
          expect(_textIn(key, value), findsOneWidget, reason: '$where $key');
        }
      }

      figures(me, 'all');
      // Money in the lobby's gold; counts in the display ink.
      final winnings = tester.widget<Text>(
        _textIn('stats-total-winnings', formatChips(9876500)),
      );
      expect(winnings.style?.color, AppTheme.goldInk(Brightness.dark));
      final played = tester.widget<Text>(_textIn('stats-played', '1,498'));
      expect(played.style?.color, isNot(AppTheme.goldInk(Brightness.dark)));

      final games = me['stats'] as Map<String, dynamic>;
      for (final (scope, key) in [
        (StatsScope.teenPatti, 'teenPatti'),
        (StatsScope.variations, 'variation'),
        (StatsScope.allGames, null),
      ]) {
        await tester.tap(_key('stats-scope'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(_key('stats-scope-option-poker'), findsNothing);
        expect(
          find.descendant(
            of: _key('stats-scope-menu'),
            matching: find.text(statsCategoryName(t, StatsCategory.poker)),
          ),
          findsNothing,
        );
        await tester.tap(_key('stats-scope-option-${scope.name}'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        figures(
          key == null ? me : games[key] as Map<String, dynamic>,
          scope.name,
        );
        expect(tester.takeException(), isNull);
      }
      await _closeApp(tester);
    });
  });

  // Each place is checked in both builds: the default one, whose switch is
  // All · Teen Patti · Variation (owner, 27 Sep 2026: "remove poker
  // category"), and one built with SHOW_POKER, whose switch has Poker too.
  for (final poker in [false, true]) {
    group(poker ? 'with the Poker family' : 'without the Poker family', () {
      setUp(() => AppFeatures.poker = poker);
      tearDown(() => AppFeatures.poker = false);

      test(
        'the switch offers ${poker ? 'every game' : 'All, Teen Patti and Variation'}',
        () {
          expect(statsViews(), [
            StatsCategory.all,
            StatsCategory.teenPatti,
            StatsCategory.variation,
            if (poker) StatsCategory.poker,
          ]);
        },
      );

      group('the Friends page profile: another player\'s record', () {
        testWidgets('the switch shows every game, and no chip figure in any of '
            'them', (tester) async {
          _setView(tester);
          final server = statsProfileServer();
          await http.runWithClient(() async {
            final state = await _openProfile(tester, server);
            final t = state.t;
            final page = find.byType(FriendsScreen);
            expect(
              find.descendant(of: page, matching: find.byType(PlayerStatsGrid)),
              findsOneWidget,
            );
            _expectSwitch(tester, 'profile');
            final stats = theirStatsJson();
            _expectView(tester, t, StatsCategory.all, stats, where: 'all');
            _expectNoChipFigure(tester, page, t, 'all');
            final games = stats['categories'] as Map<String, dynamic>;
            for (final (view, key) in [
              (StatsCategory.teenPatti, 'teenPatti'),
              (StatsCategory.variation, 'variation'),
              if (poker) (StatsCategory.poker, 'poker'),
            ]) {
              await _choose(tester, view);
              _expectView(
                tester,
                t,
                view,
                games[key] as Map<String, dynamic>,
                where: view.name,
              );
              _expectNoChipFigure(tester, page, t, view.name);
            }
            await _closePage(tester, state);
          }, () => server.client);
        });

        testWidgets('on a tablet every view stands in one row', (tester) async {
          _setView(tester, size: const Size(1280, 800), scale: 1.0);
          final server = statsProfileServer();
          await http.runWithClient(() async {
            final state = await _openProfile(tester, server);
            _expectSwitch(tester, 'tablet', across: true);
            await _choose(tester, StatsCategory.variation);
            _expectSwitch(tester, 'tablet, variation', across: true);
            expect(tester.takeException(), isNull);
            await _closePage(tester, state);
          }, () => server.client);
        });
      });

      group('the table\'s player drawer: another player\'s record', () {
        testWidgets('the switch shows every game, and no chip figure in any of '
            'them', (tester) async {
          _setView(tester);
          final server = statsTableServer();
          await http.runWithClient(() async {
            final state = await _mountTable(tester);
            final t = state.t;
            await _openSeat(tester, 'u1');
            final drawer = find.byType(PlayerDrawer);
            expect(_inDrawer(find.byType(PlayerStatsGrid)), findsOneWidget);
            _expectSwitch(tester, 'drawer', across: false);
            final stats = theirStatsJson();
            _expectView(tester, t, StatsCategory.all, stats, where: 'all');
            _expectNoChipFigure(tester, drawer, t, 'all');
            final games = stats['categories'] as Map<String, dynamic>;
            for (final (view, key) in [
              (StatsCategory.teenPatti, 'teenPatti'),
              (StatsCategory.variation, 'variation'),
              if (poker) (StatsCategory.poker, 'poker'),
            ]) {
              await _choose(tester, view);
              _expectView(
                tester,
                t,
                view,
                games[key] as Map<String, dynamic>,
                where: view.name,
              );
              _expectNoChipFigure(tester, drawer, t, view.name);
            }
            await _unmountTable(tester, state);
          }, () => server.client);
        });

        testWidgets('the game chosen stays chosen when a refusal is said above '
            'it', (tester) async {
          _setView(tester);
          final server = statsTableServer()
            ..sendRefusal = refusal('rate_limited', 429);
          await http.runWithClient(() async {
            final state = await _mountTable(tester);
            await _openSeat(tester, 'u1');
            await _choose(tester, StatsCategory.variation);
            expect(_key('stats-view-variation'), findsOneWidget);
            // Choosing Variation scrolled the key up out of sight.
            await tester.ensureVisible(
              find.byKey(
                const ValueKey('seat-add-friend'),
                skipOffstage: false,
              ),
            );
            await tester.pump();
            await tester.tap(_key('seat-add-friend'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            await tester.pump(const Duration(milliseconds: 100));
            expect(_inDrawer(_key('seat-note')), findsOneWidget);
            expect(_key('stats-view-variation'), findsOneWidget);
            expect(_key('stats-view-all'), findsNothing);
            await _unmountTable(tester, state);
          }, () => server.client);
        });
      });

      // Every view of every place, on the tightest phone the app is checked on,
      // at the largest text it allows, in every language, by day and by night.
      group('every view fits a 640x360 phone at text x1.25', () {
        for (final brightness in Brightness.values) {
          for (final lang in AppLang.values) {
            final where = '${lang.name} (${brightness.name})';

            // The Stats drawer's own record is held to every size, both text
            // sizes, every language and both themes in stats_drawer_test.dart.
            testWidgets('the Friends page profile in $where', (tester) async {
              _setView(tester);
              final server = statsProfileServer();
              await http.runWithClient(() async {
                final state = await _openProfile(
                  tester,
                  server,
                  lang: lang,
                  brightness: brightness,
                );
                final page = find.byType(FriendsScreen);
                final panel = tester.getRect(
                  find
                      .descendant(
                        of: page,
                        matching: find.byType(PremiumGlassPanel),
                      )
                      .first,
                );
                for (final view in statsViews()) {
                  await _choose(tester, view);
                  _expectFits(
                    tester,
                    find.descendant(
                      of: page,
                      matching: find.byType(PlayerStatsGrid),
                    ),
                    panel,
                    'profile ${view.name} $where',
                  );
                  _expectSwitch(tester, 'profile ${view.name} $where');
                  _expectNoChipFigure(
                    tester,
                    page,
                    state.t,
                    '${view.name} $where',
                  );
                }
                await _closePage(tester, state);
              }, () => server.client);
            });

            testWidgets('the player drawer in $where', (tester) async {
              _setView(tester);
              final server = statsTableServer();
              await http.runWithClient(() async {
                final state = await _mountTable(
                  tester,
                  lang: lang,
                  brightness: brightness,
                );
                // Arjun has asked: Accept and Reject stand above the record.
                await _openSeat(tester, 'u3');
                expect(_inDrawer(_key('seat-accept')), findsOneWidget);
                final drawer = find.byType(PlayerDrawer);
                final panel = tester.getRect(
                  _inDrawer(find.byType(PremiumGlassPanel)).first,
                );
                for (final view in statsViews()) {
                  await _choose(tester, view);
                  _expectFits(
                    tester,
                    _inDrawer(find.byType(PlayerStatsGrid)),
                    panel,
                    'drawer ${view.name} $where',
                  );
                  _expectSwitch(tester, 'drawer ${view.name} $where');
                  _expectNoChipFigure(
                    tester,
                    drawer,
                    state.t,
                    '${view.name} $where',
                  );
                }
                await _unmountTable(tester, state);
              }, () => server.client);
            });
          }
        }
      });
    });
  }

  // Since the owner's brief of 27 Sep 2026 the lobby's Stats drawer lays the
  // player's own record out in a presentation of its own (OwnRecord), while
  // the Friends page and a table's player drawer keep this one widget. The
  // screens still keep no rows of their own, and OwnRecord writes its counts
  // and lays its tiles out with this file's own helpers, not copies of them.
  test('another player\'s record is ONE widget in both its places, and no '
      'screen keeps rows of its own', () {
    final lobby = File('lib/screens/lobby_screen.dart').readAsStringSync();
    final page = File('lib/screens/friends_screen.dart').readAsStringSync();
    final drawer = File('lib/widgets/player_drawer.dart').readAsStringSync();
    final own = File('lib/widgets/own_record.dart').readAsStringSync();
    expect(lobby, contains('OwnRecord('));
    expect(page, contains('PlayerStatsGrid('));
    expect(drawer, contains('PlayerStatsGrid('));
    // The Stats drawer shares the grid, the counts' grouping and the hands'
    // icons with the record, rather than drawing any of them twice.
    expect(own, contains("show EvenGrid, HandIcon, countText"));
    expect(own, isNot(contains("HandTally.icons[")));
    expect(own, isNot(contains('String _count(')));
    expect(own, isNot(contains('class _EvenGrid')));
    for (final source in [lobby, page, drawer]) {
      expect(source, isNot(contains('class _StatRow')));
      expect(source, isNot(contains('class _StatTile')));
      expect(source, isNot(contains('handsHeld')));
      expect(source, isNot(contains('variationsPlayed')));
    }
  });
}
