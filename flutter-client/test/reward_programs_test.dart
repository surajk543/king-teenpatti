// The reward programs (owner, 30 Sep 2026): the login streaks and the
// calendar rewards the SERVER runs — it decides every day, every reward and
// every claim; the app claims when the lobby appears, shows what it is told,
// and celebrates only what a claim's answer says it gave.
//
// These hold the wire (a program's days, today, the run and the next reward
// read as sent; a claim's grants; the dates the tiles are labelled with),
// the words (a reward named in every language), GameState (one POST as the
// lobby appears, throttled and forced, nothing at a table, an older server,
// a refusal, a lost network, Try again's GET, sign-out), the lobby chip
// (Collect now until the claim lands, then the streak; beside the Lucky Draw
// and clear of the foot's keys; no chip without a program), the screen ("3
// day streak" over seven tiles, "Day 10 reward" over thirty-one, the next
// reward, the tiles' words for a screen reader, no line cut at 640x360 x1.25
// in all five languages) and the celebration (one line per grant, closed by
// its key; never from anything but a claim's answer).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/net/api_client.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/screens/reward_programs_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

const _server = 'http://127.0.0.1:9';

/// Wednesday 7 October 2026, the third day of its week; Saturday 10 October,
/// the tenth of its month.
const _wednesday = '2026-10-07';
const _tenth = '2026-10-10';

Map<String, Object?> _userJson({int chips = 1000000, int hammer = 20}) => {
  'id': 'u0',
  'provider': 'guest',
  'displayName': 'Ravi',
  'chips': chips,
  'diamond': 9,
  'hammer': hammer,
  'missile': 1,
  // A standing, so the lobby's foot has its level key.
  'playerLevel': {
    'level': 10,
    'title': 'Rising Star',
    'icon': '🌟',
    'xp': 4180,
    'taxBps': 1743,
    'next': {
      'level': 11,
      'title': 'Pro Player',
      'icon': '🏅',
      'minXp': 5200,
      'taxBps': 1714,
    },
  },
};

Map<String, Object?> _day(
  int day,
  String type, {
  int? value,
  String? ref,
  bool claimed = false,
  Map<String, Object?>? emoji,
  Map<String, Object?>? picture,
  Map<String, Object?>? tablePicture,
  Map<String, Object?>? badge,
}) => {
  'day': day,
  'rewardType': type,
  'rewardValue': value,
  'rewardRefId': ref,
  'claimed': claimed,
  'emoji': ?emoji,
  'picture': ?picture,
  'tablePicture': ?tablePicture,
  'badge': ?badge,
};

const _clappingHands = {
  'id': 5,
  'name': 'Clapping Hands',
  'url': 'https://example.test/clap.json',
  'assetFormat': 'LOTTIE',
  'currency': 'HAMMER',
  'type': 'PREMIUM',
  'cost': 5,
  'durationDays': 30,
  'owned': false,
};

const _lovestruckCat = {
  'id': 26,
  'name': 'Lovestruck Cat',
  'url': 'https://example.test/cat.json',
  'assetFormat': 'LOTTIE',
  'currency': 'HAMMER',
  'type': 'PREMIUM',
  'cost': 50,
  'durationDays': 50,
  'owned': false,
};

const _linesBackground = {
  'id': 1,
  'name': 'Lines Background',
  'dayUrl': 'https://example.test/lines.json',
  'nightUrl': 'https://example.test/lines-night.json',
  'assetFormat': 'LOTTIE',
  'currency': 'COIN',
  'type': 'PREMIUM',
  'cost': 100000,
  'durationDays': 7,
  'owned': false,
};

const _royalAce = {
  'code': 'ROYAL_ACE',
  'title': 'Royal Ace',
  'icon': '🃏',
  'validityDays': 7,
  'held': false,
  'expiresAt': 0,
};

/// The owner's WEEKLY_LOGIN, as seeded, the first [claimed] days of a run
/// marked.
List<Map<String, Object?>> _weeklyLoginRewards({int claimed = 0}) => [
  _day(1, 'CHIPS', value: 10000, claimed: claimed >= 1),
  _day(2, 'HAMMER', value: 1, claimed: claimed >= 2),
  _day(3, 'CHIPS', value: 20000, claimed: claimed >= 3),
  _day(4, 'DIAMOND', value: 1, claimed: claimed >= 4),
  _day(5, 'CHIPS', value: 30000, claimed: claimed >= 5),
  _day(6, 'HAMMER', value: 2, claimed: claimed >= 6),
  _day(7, 'DIAMOND', value: 1, claimed: claimed >= 7),
];

/// A month's 31 days: chips on most, an emoji on the 10th, a table picture
/// on the 25th and a badge on the 31st, the [claimed] days marked.
List<Map<String, Object?>> _monthlyCalendarRewards({
  Set<int> claimed = const {},
}) => [
  for (var k = 1; k <= 31; k++)
    switch (k) {
      10 => _day(
        k,
        'EMOJI',
        ref: '5',
        claimed: claimed.contains(k),
        emoji: _clappingHands,
      ),
      25 => _day(
        k,
        'TABLE_PICTURE',
        ref: '1',
        claimed: claimed.contains(k),
        tablePicture: _linesBackground,
      ),
      31 => _day(
        k,
        'BADGE',
        ref: 'ROYAL_ACE',
        claimed: claimed.contains(k),
        badge: _royalAce,
      ),
      _ => _day(k, 'CHIPS', value: 5000 * k, claimed: claimed.contains(k)),
    },
];

Map<String, Object?> _program({
  required String code,
  required String mode,
  required String periodType,
  bool reset = true,
}) => {
  'id': code.hashCode & 0xffff,
  'code': code,
  'name': code.replaceAll('_', ' '),
  'mode': mode,
  'periodType': periodType,
  'timezone': 'UTC',
  'weekStartDay': 1,
  'resetOnMissedDay': reset,
  'startsAt': null,
  'endsAt': null,
  'periodStart': 1791590400000,
  'periodEnd': 1792195200000,
};

/// The weekly streak on its third day (Wednesday), today's collected unless
/// [claimedToday] says not.
Map<String, Object?> _streakJson({
  int day = 3,
  bool claimedToday = true,
  String today = _wednesday,
}) => {
  'program': _program(
    code: 'WEEKLY_LOGIN',
    mode: 'LOGIN_STREAK',
    periodType: 'WEEKLY',
  ),
  'today': today,
  'dayOfPeriod': 3,
  'periodDays': 7,
  'currentDay': day,
  'claimedToday': claimedToday,
  'claimedDays': claimedToday ? day : day - 1,
  'rewards': _weeklyLoginRewards(claimed: claimedToday ? day : day - 1),
};

/// The monthly calendar on the 10th, six days collected before it (the 4th,
/// 6th and 8th missed), today's still waiting unless [claimedToday].
Map<String, Object?> _calendarJson({bool claimedToday = false}) => {
  'program': _program(
    code: 'MONTHLY_CALENDAR',
    mode: 'CALENDAR',
    periodType: 'MONTHLY',
    reset: false,
  ),
  'today': _tenth,
  'dayOfPeriod': 10,
  'periodDays': 31,
  'currentDay': 10,
  'claimedToday': claimedToday,
  'claimedDays': claimedToday ? 7 : 6,
  'rewards': _monthlyCalendarRewards(
    claimed: {1, 2, 3, 5, 7, 9, if (claimedToday) 10},
  ),
};

Map<String, Object?> _grant({
  required String code,
  required int day,
  required Map<String, Object?> reward,
  bool alreadyOwned = false,
}) => {
  'programCode': code,
  'programName': code.replaceAll('_', ' '),
  'mode': code.endsWith('LOGIN') ? 'LOGIN_STREAK' : 'CALENDAR',
  'periodType': code.startsWith('WEEKLY') ? 'WEEKLY' : 'MONTHLY',
  'day': day,
  ...reward,
  'alreadyOwned': alreadyOwned,
  'claimedAt': 1791801600000,
};

/// A claim's answer: what it gave, every program after, the account after.
Map<String, Object?> _claimJson({
  List<Map<String, Object?>>? granted,
  List<Map<String, Object?>>? programs,
  int chips = 1010000,
}) => {
  'granted': granted ?? const [],
  'programs': programs ?? [_streakJson(), _calendarJson(claimedToday: true)],
  'user': _userJson(chips: chips),
};

/// The grants a first claim of the day gives: the streak's Day 3 chips and
/// the calendar's 10th, an emoji.
List<Map<String, Object?>> _twoGrants() => [
  _grant(code: 'WEEKLY_LOGIN', day: 3, reward: _day(3, 'CHIPS', value: 20000)),
  _grant(
    code: 'MONTHLY_CALENDAR',
    day: 10,
    reward: _day(10, 'EMOJI', ref: '5', emoji: _clappingHands),
  ),
];

/// [body] as the server sends it: JSON in UTF-8 (a badge's icon is an emoji,
/// which `http.Response(String)` would refuse as Latin-1).
http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
  utf8.encode(jsonEncode(body)),
  status,
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

/// A fake server: the claim answers [claim] (or [claimResponse]), the read
/// answers [programs] (or [programsResponse]); every request is kept in
/// [sent].
MockClient _fake({
  required List<http.Request> sent,
  Map<String, Object?>? claim,
  http.Response? claimResponse,
  Map<String, Object?>? programs,
  http.Response? programsResponse,
  Completer<void>? release,
}) => MockClient((request) async {
  sent.add(request);
  if (release != null) await release.future;
  if (request.url.path == '/api/reward-programs/claim') {
    if (request.method != 'POST') {
      return _json({'error': 'not_found'}, 404);
    }
    return claimResponse ?? _json(claim ?? _claimJson());
  }
  if (request.url.path == '/api/reward-programs') {
    return programsResponse ??
        _json(
          programs ??
              {
                'programs': [_streakJson(), _calendarJson()],
              },
        );
  }
  // The lobby's Friends key reads its count as the lobby appears, and
  // hides itself from a server without the route: nobody waiting here.
  if (request.url.path == '/api/friends/requests') {
    return _json({
      'incoming': const [],
      'outgoing': const [],
      'incomingTotal': 0,
      'outgoingTotal': 0,
      'nextIncoming': null,
      'nextOutgoing': null,
    });
  }
  if (request.url.path == '/api/friends') {
    return _json({'friends': const [], 'total': 0, 'nextCursor': null});
  }
  return _json({'error': 'not_found'}, 404);
});

List<String> _posts(List<http.Request> sent) => [
  for (final r in sent)
    if (r.method == 'POST') r.url.path,
];

GameState _state({AppLang lang = AppLang.english, bool signedIn = true}) {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: _server);
  debugDefaultTargetPlatformOverride = null;
  state
    ..lang = lang
    ..screen = Screen.lobby
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
      ],
    })
    ..user = User.fromJson(_userJson());
  if (signedIn) state.debugToken = 'tok';
  return state;
}

/// The Lucky Draw's chip in its corner beside the rewards', at its widest.
LuckyDrawState _luckyDraw() => LuckyDrawState.fromJson({
  'draw': {
    'code': 'BEGINNER_LUCKY_DRAW',
    'name': 'Beginner Lucky Draw',
    'spinnerType': 'BEGINNER',
    'cooldownMs': 259200000,
  },
  'slots': [
    for (var n = 1; n <= 6; n++)
      {'slotNumber': n, 'rewardType': 'CHIPS', 'rewardValue': 100000 * n},
  ],
  'nextSpinAt': DateTime.now()
      .add(const Duration(hours: 50))
      .millisecondsSinceEpoch,
});

RoomState _table() => RoomState.fromJson({
  'roomId': 'r1',
  'code': 'ABCDEFGH',
  'category': 'seen',
  'state': 'WAITING',
  'maxPlayers': 5,
  'seats': const [],
});

Future<void> _setView(
  WidgetTester tester, {
  Size screen = const Size(640, 360),
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Widget _app(
  GameState state,
  FeedbackSettings feedback,
  Widget home, {
  Brightness brightness = Brightness.dark,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<GameState>.value(value: state),
    ChangeNotifierProvider<FeedbackSettings>.value(value: feedback),
  ],
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withScriptFallback(
      brightness == Brightness.dark
          ? AppTheme.dark(sound: false)
          : AppTheme.light(sound: false),
    ),
    builder: (context, child) => GlassBudget(child: child!),
    home: home,
  ),
);

Future<void> _pumpLobby(
  WidgetTester tester,
  GameState state, {
  Brightness brightness = Brightness.dark,
}) async {
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    _app(state, feedback, const LobbyScreen(), brightness: brightness),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// A bare page with a key that opens the rewards, as the lobby's chip does.
Future<void> _openScreen(WidgetTester tester, GameState state) async {
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    _app(
      state,
      feedback,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showRewardPrograms(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump(const Duration(milliseconds: 600));
}

/// Nothing pumped in the tree ends the lobby's drifting chips before the
/// state is disposed.
Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

/// Whether every line of [finder]'s paragraphs is whole.
void _expectWhole(WidgetTester tester, Finder finder, String reason) {
  for (final paragraph in tester.renderObjectList<RenderParagraph>(
    find.descendant(of: finder, matching: find.byType(RichText)),
  )) {
    expect(
      paragraph.didExceedMaxLines,
      isFalse,
      reason: '$reason: ${paragraph.text.toPlainText()}',
    );
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadScriptFonts();
    // On a Mac (no Noto fonts at the Linux path script_fonts.dart reads) the
    // system's own Indic fonts stand in under the Noto names, so the four
    // Indic languages are laid out with real glyph widths here too.
    if (!haveScriptFonts()) {
      const mac = {
        'Noto Sans Devanagari': '/System/Library/Fonts/Kohinoor.ttc',
        'Noto Sans Bengali': '/System/Library/Fonts/KohinoorBangla.ttc',
        'Noto Sans Gujarati': '/System/Library/Fonts/KohinoorGujarati.ttc',
        'Noto Sans Gurmukhi': '/System/Library/Fonts/Supplemental/Gurmukhi.ttf',
      };
      for (final MapEntry(key: family, value: path) in mac.entries) {
        final file = File(path);
        if (!file.existsSync()) continue;
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
        await loader.load();
      }
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the wire', () {
    test('a program reads its days in order, today, the run and what is '
        'next', () {
      final s = RewardProgramState.fromJson({
        ..._streakJson(),
        'rewards': _weeklyLoginRewards(claimed: 3).reversed.toList(),
      });
      expect(s.program.code, 'WEEKLY_LOGIN');
      expect(s.program.isStreak, isTrue);
      expect(s.program.isWeekly, isTrue);
      expect(s.program.resetOnMissedDay, isTrue);
      expect(s.today, _wednesday);
      expect(s.dayOfPeriod, 3);
      expect(s.periodDays, 7);
      expect(s.currentDay, 3);
      expect(s.claimedToday, isTrue);
      expect(s.claimedDays, 3);
      expect(s.rewards.map((d) => d.day), [1, 2, 3, 4, 5, 6, 7]);
      expect(s.rewards.map((d) => d.claimed), [
        true,
        true,
        true,
        false,
        false,
        false,
        false,
      ]);
      expect(s.rewardFor(3)?.prize.kind, RewardKind.chips);
      expect(s.rewardFor(3)?.prize.amount, 20000);
      expect(s.rewardFor(8), isNull);
      // Collected today: the next reward is tomorrow's, Day 4's diamond.
      expect(s.nextDay, 4);
      expect(s.nextReward?.prize.kind, RewardKind.diamond);
    });

    test('the next reward is today while it waits, tomorrow once collected, '
        'and none past the period', () {
      final waiting = RewardProgramState.fromJson(
        _streakJson(claimedToday: false),
      );
      expect(waiting.nextDay, 3);
      expect(waiting.claimedDays, 2);
      final last = RewardProgramState.fromJson(
        _streakJson(day: 7, claimedToday: true),
      );
      expect(last.nextDay, isNull);
      expect(last.nextReward, isNull);
      final calendar = RewardProgramState.fromJson(_calendarJson());
      expect(calendar.program.isStreak, isFalse);
      expect(calendar.nextDay, 10);
      expect(calendar.nextReward?.prize.kind, RewardKind.emoji);
      expect(calendar.nextReward?.prize.itemName, 'Clapping Hands');
      final collected = RewardProgramState.fromJson(
        _calendarJson(claimedToday: true),
      );
      expect(collected.nextDay, 11);
      expect(collected.claimedDays, 7);
    });

    test("a day's date comes from today: a streak counts back along its "
        'run, a calendar along the period', () {
      final streak = RewardProgramState.fromJson(_streakJson());
      // Day 3 is Wednesday 7 October; Day 1 was the Monday, Day 7 will be
      // the Sunday.
      expect(streak.todayDate, DateTime.utc(2026, 10, 7));
      expect(streak.dateOfDay(3), DateTime.utc(2026, 10, 7));
      expect(streak.dateOfDay(1), DateTime.utc(2026, 10, 5));
      expect(streak.weekdayOfDay(1), DateTime.monday);
      expect(streak.weekdayOfDay(7), DateTime.sunday);
      final calendar = RewardProgramState.fromJson(_calendarJson());
      expect(calendar.dateOfDay(1), DateTime.utc(2026, 10, 1));
      expect(calendar.dateOfDay(31), DateTime.utc(2026, 10, 31));
      expect(calendar.weekdayOfDay(1), DateTime.thursday);
      // A streak on Day 5 whose today is the 7th began on the 3rd.
      final older = RewardProgramState.fromJson(_streakJson(day: 5));
      expect(older.dateOfDay(1), DateTime.utc(2026, 10, 3));
      // No date at all: today, at least.
      final bare = RewardProgramState.fromJson({
        ..._streakJson(),
        'today': 'someday',
      });
      final now = DateTime.now().toUtc();
      expect(bare.todayDate, DateTime.utc(now.year, now.month, now.day));
    });

    test('a reward is its kind: a wallet amount, an item with its catalogue '
        'row, a badge with its days, or nothing', () {
      final chips = RewardPrize.fromJson(_day(1, 'CHIPS', value: 10000));
      expect(chips.kind, RewardKind.chips);
      expect(chips.isWallet, isTrue);
      expect(chips.isItem, isFalse);
      expect(chips.amount, 10000);
      expect(chips.itemName, '');

      final emoji = RewardPrize.fromJson(
        _day(10, 'EMOJI', ref: '5', emoji: _clappingHands),
      );
      expect(emoji.isItem, isTrue);
      expect(emoji.refId, '5');
      expect(emoji.emoji?.name, 'Clapping Hands');
      expect(emoji.itemName, 'Clapping Hands');
      expect(emoji.amount, 0);

      final picture = RewardPrize.fromJson(
        _day(25, 'PROFILE_PICTURE', ref: '26', picture: _lovestruckCat),
      );
      expect(picture.picture?.name, 'Lovestruck Cat');
      expect(picture.itemName, 'Lovestruck Cat');

      final table = RewardPrize.fromJson(
        _day(25, 'TABLE_PICTURE', ref: '1', tablePicture: _linesBackground),
      );
      expect(table.tablePicture?.name, 'Lines Background');
      expect(table.itemName, 'Lines Background');

      final badge = RewardPrize.fromJson(
        _day(31, 'BADGE', ref: 'ROYAL_ACE', badge: _royalAce),
      );
      expect(badge.badge?.code, 'ROYAL_ACE');
      expect(badge.badge?.validityDays, 7);
      expect(badge.badge?.held, isFalse);
      expect(badge.itemName, 'Royal Ace');

      final none = RewardPrize.fromJson(_day(4, 'NO_REWARD'));
      expect(none.isNothing, isTrue);
      expect(none.isWallet, isFalse);
      expect(none.isItem, isFalse);

      // A kind this build has never heard of is neither a wallet nor an
      // item, and is still read.
      final other = RewardPrize.fromJson(_day(4, 'CARD_BACK', ref: '9'));
      expect(other.kind, 'CARD_BACK');
      expect(other.isWallet, isFalse);
      expect(other.isItem, isFalse);
    });

    test('a claim reads what it gave, every program after and the account', () {
      final r = RewardClaimResult.fromJson(
        _claimJson(granted: _twoGrants(), chips: 1020000),
      );
      expect(r.granted.length, 2);
      final first = r.granted.first;
      expect(first.programCode, 'WEEKLY_LOGIN');
      expect(first.mode, RewardMode.loginStreak);
      expect(first.periodType, RewardPeriod.weekly);
      expect(first.day, 3);
      expect(first.prize.kind, RewardKind.chips);
      expect(first.prize.amount, 20000);
      expect(first.alreadyOwned, isFalse);
      expect(first.claimedAt, 1791801600000);
      final second = r.granted[1];
      expect(second.programCode, 'MONTHLY_CALENDAR');
      expect(second.prize.isItem, isTrue);
      expect(second.prize.itemName, 'Clapping Hands');
      expect(r.programs.map((p) => p.program.code), [
        'WEEKLY_LOGIN',
        'MONTHLY_CALENDAR',
      ]);
      expect(r.user?.chips, 1020000);
      // Nothing given, no account: an empty answer still reads.
      final empty = RewardClaimResult.fromJson(const {});
      expect(empty.granted, isEmpty);
      expect(empty.programs, isEmpty);
      expect(empty.user, isNull);
    });

    test('only real programs and real days are kept', () {
      expect(rewardProgramsFromJson('garbage'), isEmpty);
      expect(rewardProgramsFromJson(null), isEmpty);
      final programs = rewardProgramsFromJson([
        'not a program',
        7,
        {
          ..._streakJson(),
          'rewards': [
            ..._weeklyLoginRewards(),
            _day(0, 'CHIPS', value: 1),
            _day(-3, 'CHIPS', value: 1),
            'not a day',
          ],
        },
      ]);
      expect(programs.length, 1);
      expect(programs.single.rewards.map((d) => d.day), [1, 2, 3, 4, 5, 6, 7]);
      // A program with no program block reads as nothing, not a crash.
      final bare = RewardProgramState.fromJson(const {'today': _wednesday});
      expect(bare.program.code, '');
      expect(bare.rewards, isEmpty);
      expect(bare.nextDay, isNull);
    });
  });

  group('the words', () {
    test('a reward is named in every language: the figure for chips, the '
        'count for a wallet, the item by its name', () {
      for (final lang in AppLang.values) {
        final t = Strings(lang);
        final chips = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(_day(1, 'CHIPS', value: 10000)),
        );
        expect(chips, contains('10,000'), reason: lang.name);
        final hammers = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(_day(6, 'HAMMER', value: 2)),
        );
        expect(hammers, contains('2'), reason: lang.name);
        expect(hammers, isNot(equals(chips)), reason: lang.name);
        final oneHammer = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(_day(2, 'HAMMER', value: 1)),
        );
        expect(oneHammer, isNot(equals(hammers)), reason: lang.name);
        final diamond = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(_day(4, 'DIAMOND', value: 1)),
        );
        expect(diamond, isNotEmpty, reason: lang.name);
        expect(diamond, isNot(equals(oneHammer)), reason: lang.name);
        final emoji = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(
            _day(10, 'EMOJI', ref: '5', emoji: _clappingHands),
          ),
        );
        expect(emoji, contains('Clapping Hands'), reason: lang.name);
        expect(emoji, isNot(equals('Clapping Hands')), reason: lang.name);
        final badge = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(
            _day(31, 'BADGE', ref: 'ROYAL_ACE', badge: _royalAce),
          ),
        );
        expect(badge, contains('Royal Ace'), reason: lang.name);
        expect(badge, contains('7'), reason: lang.name);
        final forever = rewardPrizeLabel(
          t,
          RewardPrize.fromJson(
            _day(
              31,
              'BADGE',
              ref: 'ROYAL_ACE',
              badge: {..._royalAce, 'validityDays': 0},
            ),
          ),
        );
        expect(forever, contains('Royal Ace'), reason: lang.name);
        expect(forever, isNot(contains('7')), reason: lang.name);
        expect(
          rewardPrizeLabel(t, RewardPrize.fromJson(_day(4, 'NO_REWARD'))),
          t.rewardNothing,
          reason: lang.name,
        );
        // The four seeded programs in the player's language; any other by
        // the name the server gave it.
        final names = {
          for (final code in const [
            'WEEKLY_LOGIN',
            'MONTHLY_LOGIN',
            'WEEKLY_CALENDAR',
            'MONTHLY_CALENDAR',
          ])
            t.rewardProgramName(code, 'x'),
        };
        expect(names.length, 4, reason: lang.name);
        expect(names, isNot(contains('x')), reason: lang.name);
        expect(
          t.rewardProgramName('DECEMBER_2026', 'December Rewards'),
          'December Rewards',
        );
        // The headline, both ways, and the seven weekdays.
        expect(t.streakDays(3), contains('3'), reason: lang.name);
        expect(t.streakDays(1), isNot(equals(t.streakDays(2))));
        expect(t.calendarDayReward(10), contains('10'), reason: lang.name);
        final weekdays = {for (var d = 1; d <= 7; d++) t.weekdayShort(d)};
        expect(weekdays.length, 7, reason: lang.name);
      }
    });

    test('the short figure on a tile', () {
      expect(
        rewardPrizeShort(RewardPrize.fromJson(_day(1, 'CHIPS', value: 10000))),
        '10,000',
      );
      expect(
        rewardPrizeShort(RewardPrize.fromJson(_day(6, 'HAMMER', value: 2))),
        '×2',
      );
      expect(
        rewardPrizeShort(
          RewardPrize.fromJson(
            _day(10, 'EMOJI', ref: '5', emoji: _clappingHands),
          ),
        ),
        'Clapping Hands',
      );
      expect(rewardPrizeShort(RewardPrize.fromJson(_day(4, 'NO_REWARD'))), '');
    });
  });

  group('GameState', () {
    test('a claim sends one POST with the session, takes what it gave, the '
        'programs and the account, and celebrates the grants', () async {
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = _state();
          addTearDown(state.dispose);
          var notified = 0;
          state.addListener(() => notified++);
          await state.claimRewardPrograms();
          expect(_posts(sent), ['/api/reward-programs/claim']);
          final post = sent.singleWhere((r) => r.method == 'POST');
          expect(post.headers['Authorization'], 'Bearer tok');
          expect(post.body, '{}');
          expect(state.rewardClaimPending, isFalse);
          expect(state.rewardProgramsFailed, isFalse);
          expect(state.rewardPrograms?.map((p) => p.program.code), [
            'WEEKLY_LOGIN',
            'MONTHLY_CALENDAR',
          ]);
          expect(state.user?.chips, 1020000);
          expect(state.rewardsGranted?.length, 2);
          expect(state.rewardsGranted?.first.prize.amount, 20000);
          expect(notified, greaterThanOrEqualTo(2));
          // An item won: the shelves are read again for who owns what.
          await pumpEventQueue();
          expect(sent.map((r) => r.url.path), contains('/api/profiles'));
          state.dismissRewardsGranted();
          expect(state.rewardsGranted, isNull);
        },
        () => _fake(
          sent: sent,
          claim: _claimJson(granted: _twoGrants(), chips: 1020000),
        ),
      );
    });

    test('a second claim within the trust window is not sent; the screen '
        'opening forces one; nothing granted raises no celebration', () async {
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = _state();
        addTearDown(state.dispose);
        await state.claimRewardPrograms();
        await state.claimRewardPrograms();
        expect(_posts(sent).length, 1);
        await state.claimRewardPrograms(force: true);
        expect(_posts(sent).length, 2);
        expect(state.rewardsGranted, isNull);
        expect(state.rewardPrograms?.length, 2);
        // The shelves were not read: nothing was won.
        expect(sent.map((r) => r.url.path), isNot(contains('/api/profiles')));
      }, () => _fake(sent: sent, claim: _claimJson()));
    });

    test('nothing is claimed at a table, or signed out', () async {
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final seated = _state()..room = _table();
        addTearDown(seated.dispose);
        await seated.claimRewardPrograms();
        await seated.claimRewardPrograms(force: true);
        expect(sent, isEmpty);
        final out = _state(signedIn: false);
        addTearDown(out.dispose);
        await out.claimRewardPrograms(force: true);
        await out.loadRewardPrograms();
        expect(sent, isEmpty);
      }, () => _fake(sent: sent));
    });

    test(
      'a server without the programs shows none, and that is no failure',
      () async {
        for (final status in [404, 503]) {
          final sent = <http.Request>[];
          await http.runWithClient(
            () async {
              final state = _state();
              addTearDown(state.dispose);
              await state.claimRewardPrograms();
              expect(state.rewardPrograms, isNull);
              expect(state.rewardProgramsFailed, isFalse);
              expect(state.rewardsGranted, isNull);
              await state.loadRewardPrograms();
              expect(state.rewardPrograms, isNull);
              expect(state.rewardProgramsFailed, isFalse);
              // Not trusted as an answer: the next lobby asks again.
              await state.claimRewardPrograms();
              expect(_posts(sent).length, 2);
            },
            () {
              final refusal = http.Response(
                jsonEncode({'error': 'reward_programs_unavailable'}),
                status,
              );
              return _fake(
                sent: sent,
                claimResponse: refusal,
                programsResponse: refusal,
              );
            },
          );
        }
      },
    );

    test('a claim refused at a table changes nothing', () async {
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = _state();
          addTearDown(state.dispose);
          await state.claimRewardPrograms();
          expect(_posts(sent).length, 1);
          expect(state.rewardPrograms, isNull);
          expect(state.rewardProgramsFailed, isFalse);
          expect(state.rewardsGranted, isNull);
          expect(state.user?.chips, 1000000);
        },
        () => _fake(
          sent: sent,
          claimResponse: http.Response(
            jsonEncode({
              'error': 'seated',
              'message': 'Collect your rewards from the lobby.',
            }),
            409,
          ),
        ),
      );
    });

    test(
      'a claim the network lost is a failure only while nothing is held',
      () async {
        final sent = <http.Request>[];
        var down = true;
        await http.runWithClient(
          () async {
            final state = _state();
            addTearDown(state.dispose);
            await state.claimRewardPrograms();
            expect(state.rewardPrograms, isNull);
            expect(state.rewardProgramsFailed, isTrue);
            // Try again reads without claiming.
            down = false;
            await state.loadRewardPrograms();
            expect(sent.last.method, 'GET');
            expect(sent.last.url.path, '/api/reward-programs');
            expect(state.rewardPrograms?.length, 2);
            expect(state.rewardProgramsFailed, isFalse);
            expect(state.rewardsGranted, isNull);
            // Held now: a later loss keeps what is held and says nothing.
            down = true;
            await state.claimRewardPrograms(force: true);
            expect(state.rewardPrograms?.length, 2);
            expect(state.rewardProgramsFailed, isFalse);
          },
          () => MockClient((request) async {
            sent.add(request);
            if (down) throw const SocketException('no route');
            if (request.url.path == '/api/reward-programs') {
              return _json({
                'programs': [_streakJson(), _calendarJson()],
              });
            }
            return http.Response(jsonEncode({'error': 'not_found'}), 404);
          }),
        );
      },
    );

    test('an answer to a session that has ended is dropped', () async {
      final sent = <http.Request>[];
      final release = Completer<void>();
      await http.runWithClient(
        () async {
          final state = _state();
          addTearDown(state.dispose);
          final claim = state.claimRewardPrograms();
          expect(state.rewardClaimPending, isTrue);
          await state.signOut();
          release.complete();
          await claim;
          expect(state.rewardPrograms, isNull);
          expect(state.rewardsGranted, isNull);
          expect(state.user, isNull);
        },
        () => _fake(
          sent: sent,
          release: release,
          claim: _claimJson(granted: _twoGrants()),
        ),
      );
    });

    test('sign-out forgets the programs and the celebration', () async {
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = _state();
          addTearDown(state.dispose);
          await state.claimRewardPrograms();
          expect(state.rewardPrograms, isNotNull);
          expect(state.rewardsGranted, isNotNull);
          await state.signOut();
          expect(state.rewardPrograms, isNull);
          expect(state.rewardsGranted, isNull);
          expect(state.rewardProgramsFailed, isFalse);
        },
        () => _fake(
          sent: sent,
          claim: _claimJson(granted: _twoGrants()),
        ),
      );
    });

    test(
      'the API answers null on 404 and 503, throws the refusal otherwise',
      () async {
        for (final status in [404, 503]) {
          await http.runWithClient(
            () async {
              final api = ApiClient(_server);
              expect(await api.rewardPrograms('tok'), isNull);
              expect(await api.claimRewardPrograms('tok'), isNull);
            },
            () => MockClient(
              (_) async => http.Response(
                jsonEncode({'error': 'reward_programs_unavailable'}),
                status,
              ),
            ),
          );
        }
        await http.runWithClient(
          () async {
            await expectLater(
              ApiClient(_server).claimRewardPrograms('tok'),
              throwsA(
                isA<ApiException>().having((e) => e.code, 'code', 'seated'),
              ),
            );
          },
          () => MockClient(
            (_) async => http.Response(
              jsonEncode({'error': 'seated', 'message': 'Not here.'}),
              409,
            ),
          ),
        );
      },
    );
  });

  group('the lobby', () {
    testWidgets('claims as it appears, keeps the chip\'s room meanwhile, then '
        'says the streak and opens the screen', (tester) async {
      await _setView(tester);
      final sent = <http.Request>[];
      final release = Completer<void>();
      await http.runWithClient(
        () async {
          final state = _state();
          await _pumpLobby(tester, state);
          // The claim is out: one POST, the chip's room kept and nothing shown.
          expect(_posts(sent), ['/api/reward-programs/claim']);
          expect(find.byKey(const ValueKey('rewards-chip')), findsNothing);
          final held = find.ancestor(
            of: find.text(state.t.rewardsChip),
            matching: find.byType(Visibility),
          );
          expect(held, findsOneWidget);
          expect(tester.widget<Visibility>(held).visible, isFalse);
          release.complete();
          await tester.pump();
          await tester.pump(const Duration(seconds: 1));
          // Landed, everything collected: the chip says the streak.
          final chip = find.byKey(const ValueKey('rewards-chip'));
          expect(chip, findsOneWidget);
          expect(
            find.descendant(of: chip, matching: find.text(state.t.rewardsChip)),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: chip,
              matching: find.text(state.t.streakDays(3)),
            ),
            findsOneWidget,
          );
          // The celebration of what the claim gave.
          expect(
            find.byKey(const ValueKey('rewards-celebration')),
            findsOneWidget,
          );
          await tester.tap(find.text(state.t.tapToClose));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(
            find.byKey(const ValueKey('rewards-celebration')),
            findsNothing,
          );
          // A tap opens the screen, which claims again — the day may have
          // turned — and shows the programs.
          await tester.tap(chip);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump(const Duration(milliseconds: 600));
          expect(find.byType(RewardProgramsScreen), findsOneWidget);
          expect(_posts(sent).length, 2);
          expect(
            find.byKey(const ValueKey('reward-program-WEEKLY_LOGIN')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('reward-programs-close')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(find.byType(RewardProgramsScreen), findsNothing);
          await _unmount(tester, state);
        },
        () => _fake(
          sent: sent,
          release: release,
          claim: _claimJson(granted: _twoGrants(), chips: 1020000),
        ),
      );
    });

    testWidgets('while a reward waits the chip says Collect now', (
      tester,
    ) async {
      await _setView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = _state();
          await _pumpLobby(tester, state);
          final chip = find.byKey(const ValueKey('rewards-chip'));
          expect(chip, findsOneWidget);
          expect(
            find.descendant(
              of: chip,
              matching: find.text(state.t.rewardsCollect),
            ),
            findsOneWidget,
          );
          await _unmount(tester, state);
        },
        () => _fake(
          sent: sent,
          claim: _claimJson(
            programs: [_streakJson(claimedToday: false), _calendarJson()],
          ),
        ),
      );
    });

    testWidgets('a server with no programs shows no chip', (tester) async {
      await _setView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = _state();
          await _pumpLobby(tester, state);
          expect(_posts(sent), ['/api/reward-programs/claim']);
          expect(find.byKey(const ValueKey('rewards-chip')), findsNothing);
          expect(find.text(state.t.rewardsChip), findsNothing);
          await _unmount(tester, state);
        },
        () => _fake(
          sent: sent,
          claimResponse: http.Response(jsonEncode({'error': 'not_found'}), 404),
        ),
      );
    });

    for (final (screen, scale) in const [
      (Size(640, 360), 1.25),
      (Size(592, 360), 1.25),
      (Size(915, 412), 1.0),
      (Size(1280, 800), 1.25),
    ]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'at ${screen.width.toInt()}x${screen.height.toInt()} x$scale '
          '(${brightness.name}) the chip stands beside the Lucky Draw, on '
          'the screen, clear of the foot keys, and a toast keeps off it',
          (tester) async {
            await _setView(tester, screen: screen, textScale: scale);
            final sent = <http.Request>[];
            await http.runWithClient(() async {
              final state = _state()..luckyDraw = _luckyDraw();
              await _pumpLobby(tester, state, brightness: brightness);
              expect(tester.takeException(), isNull);
              final t = state.t;
              final rewards = tester.getRect(
                find.byKey(const ValueKey('rewards-chip')),
              );
              final lucky = tester.getRect(
                find.byKey(const ValueKey('lucky-draw-chip')),
              );
              final level = tester.getRect(
                find.byKey(const ValueKey('level-key')),
              );
              final friends = tester.getRect(find.byTooltip(t.friends));
              final onScreen = Offset.zero & screen;
              for (final (name, r) in [
                ('the rewards', rewards),
                ('the Lucky Draw', lucky),
                ('the level key', level),
                ('Friends', friends),
              ]) {
                expect(r.isEmpty, isFalse, reason: name);
                expect(
                  onScreen.contains(r.topLeft) &&
                      onScreen.contains(r.bottomRight - const Offset(1, 1)),
                  isTrue,
                  reason: '$name at $r',
                );
                expect(
                  r.height,
                  greaterThanOrEqualTo(Dim.minTouch),
                  reason: name,
                );
              }
              // In the left-hand corner after the Lucky Draw, level with it.
              expect(rewards.left, greaterThanOrEqualTo(lucky.right));
              expect((rewards.bottom - lucky.bottom).abs(), lessThan(1));
              expect(rewards.overlaps(lucky), isFalse);
              expect(rewards.overlaps(level), isFalse);
              expect(rewards.overlaps(friends), isFalse);
              expect(rewards.right, lessThan(level.left));
              // Its two lines whole.
              _expectWhole(
                tester,
                find.byKey(const ValueKey('rewards-chip')),
                '${screen.width.toInt()} x$scale',
              );
              // A toast keeps off both chips.
              final lobby = tester.element(find.byType(LobbyScreen));
              final toast = lobbyNoticeArea(lobby);
              expect(toast, isNotNull);
              expect(toast!.left, greaterThanOrEqualTo(rewards.right));
              await _unmount(tester, state);
            }, () => _fake(sent: sent, claim: _claimJson()));
          },
        );
      }
    }
  });

  group('the screen', () {
    testWidgets('a streak is headed by its run, a calendar by its day; the '
        'week has seven tiles and the month thirty-one; the next reward is '
        'named; and every tile says its day, its reward and its standing', (
      tester,
    ) async {
      await _setView(tester, textScale: 1.25);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = _state();
          final handle = tester.ensureSemantics();
          await _openScreen(tester, state);
          final t = state.t;
          expect(tester.takeException(), isNull);
          expect(find.byType(RewardProgramsScreen), findsOneWidget);
          expect(find.text(t.rewardsTitle), findsOneWidget);
          // Opening claimed (forced), and the screen shows the answer.
          expect(_posts(sent), ['/api/reward-programs/claim']);

          // The streak: "3 day streak", LOGIN STREAK, seven tiles, Day 4's
          // diamond next.
          final streak = find.byKey(
            const ValueKey('reward-program-WEEKLY_LOGIN'),
          );
          expect(streak, findsOneWidget);
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('reward-headline-WEEKLY_LOGIN')),
                )
                .data,
            t.streakDays(3),
          );
          expect(
            find.descendant(
              of: streak,
              matching: find.text(t.rewardModeStreak),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: streak,
              matching: find.text(t.rewardProgramName('WEEKLY_LOGIN', '')),
            ),
            findsOneWidget,
          );
          for (var k = 1; k <= 7; k++) {
            expect(
              find.byKey(ValueKey('reward-day-WEEKLY_LOGIN-$k')),
              findsOneWidget,
              reason: 'day $k',
            );
          }
          expect(
            find.byKey(const ValueKey('reward-day-WEEKLY_LOGIN-8')),
            findsNothing,
          );
          final next = tester.widget<Text>(
            find.byKey(const ValueKey('reward-next-WEEKLY_LOGIN')),
          );
          expect(next.data, contains(t.rewardNext));
          expect(
            next.data,
            contains(
              rewardPrizeLabel(
                t,
                RewardPrize.fromJson(_day(4, 'DIAMOND', value: 1)),
              ),
            ),
          );
          // What a screen reader hears of Day 3 — today's, collected — and of
          // Day 5, not reached, and Day 1, collected on Monday.
          String heard(String code, int k) => tester
              .getSemantics(find.byKey(ValueKey('reward-day-$code-$k')))
              .label;
          expect(heard('WEEKLY_LOGIN', 3), contains(t.rewardDay(3)));
          expect(heard('WEEKLY_LOGIN', 3), contains(t.weekdayShort(3)));
          expect(heard('WEEKLY_LOGIN', 3), contains('20,000'));
          expect(heard('WEEKLY_LOGIN', 3), contains(t.rewardTileClaimed));
          expect(heard('WEEKLY_LOGIN', 5), contains(t.rewardTileLocked));
          expect(heard('WEEKLY_LOGIN', 1), contains(t.weekdayShort(1)));

          // The calendar: "Day 10 reward", CALENDAR, thirty-one tiles, the 4th
          // missed, the 10th today's and waiting, the emoji next.
          final list = find.byKey(const ValueKey('reward-programs-list'));
          final calendar = find.byKey(
            const ValueKey('reward-program-MONTHLY_CALENDAR'),
          );
          await tester.dragUntilVisible(calendar, list, const Offset(0, -120));
          await tester.pump();
          expect(
            tester
                .widget<Text>(
                  find.byKey(
                    const ValueKey('reward-headline-MONTHLY_CALENDAR'),
                  ),
                )
                .data,
            t.calendarDayReward(10),
          );
          expect(
            find.descendant(
              of: calendar,
              matching: find.text(t.rewardModeCalendar),
            ),
            findsOneWidget,
          );
          for (var k = 1; k <= 31; k++) {
            expect(
              find.byKey(ValueKey('reward-day-MONTHLY_CALENDAR-$k')),
              findsOneWidget,
              reason: 'day $k',
            );
          }
          expect(
            find.byKey(const ValueKey('reward-day-MONTHLY_CALENDAR-32')),
            findsNothing,
          );
          expect(heard('MONTHLY_CALENDAR', 4), contains(t.rewardTileMissed));
          expect(heard('MONTHLY_CALENDAR', 9), contains(t.rewardTileClaimed));
          expect(heard('MONTHLY_CALENDAR', 10), contains(t.rewardToday));
          expect(heard('MONTHLY_CALENDAR', 10), contains('Clapping Hands'));
          expect(heard('MONTHLY_CALENDAR', 11), contains(t.rewardTileLocked));
          expect(heard('MONTHLY_CALENDAR', 31), contains('Royal Ace'));
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('reward-next-MONTHLY_CALENDAR')),
                )
                .data,
            contains('Clapping Hands'),
          );
          handle.dispose();
          await _unmount(tester, state);
        },
        () => _fake(
          sent: sent,
          claim: _claimJson(programs: [_streakJson(), _calendarJson()]),
        ),
      );
    });

    testWidgets('a streak not yet begun says so, and a day that gives '
        'nothing is drawn as none', (tester) async {
      await _setView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(
        () async {
          final state = _state();
          final handle = tester.ensureSemantics();
          await _openScreen(tester, state);
          final t = state.t;
          expect(
            tester
                .widget<Text>(
                  find.byKey(const ValueKey('reward-headline-WEEKLY_LOGIN')),
                )
                .data,
            t.streakStart,
          );
          expect(
            tester
                .getSemantics(
                  find.byKey(const ValueKey('reward-day-WEEKLY_LOGIN-2')),
                )
                .label,
            contains(t.rewardNothing),
          );
          handle.dispose();
          await _unmount(tester, state);
        },
        () => _fake(
          sent: sent,
          claim: _claimJson(
            programs: [
              {
                ..._streakJson(day: 1, claimedToday: false),
                'rewards': [
                  _day(1, 'CHIPS', value: 10000),
                  _day(3, 'CHIPS', value: 20000),
                ],
              },
            ],
          ),
        ),
      );
    });

    testWidgets('with nothing running it says so; a failed read offers Try '
        'again, which reads without claiming', (tester) async {
      await _setView(tester);
      final sent = <http.Request>[];
      var down = true;
      await http.runWithClient(
        () async {
          final state = _state();
          await _openScreen(tester, state);
          final t = state.t;
          expect(find.text(t.rewardLoadFailed), findsOneWidget);
          expect(find.text(t.luckyRetry), findsOneWidget);
          down = false;
          await tester.tap(find.text(t.luckyRetry));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          expect(sent.last.method, 'GET');
          expect(sent.last.url.path, '/api/reward-programs');
          expect(find.text(t.rewardNone), findsOneWidget);
          expect(find.text(t.luckyRetry), findsNothing);
          await _unmount(tester, state);
        },
        () => MockClient((request) async {
          sent.add(request);
          if (down) throw const SocketException('no route');
          return _json({'programs': const []});
        }),
      );
    });

    for (final lang in AppLang.values) {
      testWidgets('fits a 640x360 phone at text x1.25 in ${lang.name}, no '
          'line cut, in both themes', (tester) async {
        await _setView(tester, textScale: 1.25);
        for (final brightness in Brightness.values) {
          final sent = <http.Request>[];
          await http.runWithClient(
            () async {
              final state = _state(lang: lang);
              final feedback = FeedbackSettings();
              addTearDown(feedback.dispose);
              await tester.pumpWidget(
                _app(
                  state,
                  feedback,
                  Builder(
                    builder: (context) => Scaffold(
                      body: Center(
                        child: TextButton(
                          onPressed: () => showRewardPrograms(context),
                          child: const Text('open'),
                        ),
                      ),
                    ),
                  ),
                  brightness: brightness,
                ),
              );
              await tester.tap(find.text('open'));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 600));
              await tester.pump(const Duration(milliseconds: 600));
              expect(tester.takeException(), isNull);
              final reason = '${lang.name} ${brightness.name}';
              final view = Offset.zero & const Size(640, 360);
              for (final code in const ['WEEKLY_LOGIN', 'MONTHLY_CALENDAR']) {
                final panel = find.byKey(ValueKey('reward-program-$code'));
                await tester.dragUntilVisible(
                  panel,
                  find.byKey(const ValueKey('reward-programs-list')),
                  const Offset(0, -120),
                );
                await tester.pump();
                _expectWhole(tester, panel, reason);
                final headline = find.byKey(ValueKey('reward-headline-$code'));
                expect(
                  tester
                      .renderObject<RenderParagraph>(
                        find.descendant(
                          of: headline,
                          matching: find.byType(RichText),
                        ),
                      )
                      .didExceedMaxLines,
                  isFalse,
                  reason: '$reason $code headline',
                );
                // The panel inside the page, side to side.
                final r = tester.getRect(panel);
                expect(r.left, greaterThanOrEqualTo(view.left), reason: reason);
                expect(r.right, lessThanOrEqualTo(view.right), reason: reason);
                // Its tiles, every one, and their words never cut: a tile
                // sets them down instead. (Counted while the panel is on
                // screen: the list lets a panel go once it has scrolled far
                // enough away.)
                final tiles = find.descendant(
                  of: panel,
                  matching: find.byWidgetPredicate(
                    (w) =>
                        w.key is ValueKey<String> &&
                        (w.key as ValueKey<String>).value.startsWith(
                          'reward-day-$code-',
                        ),
                  ),
                );
                expect(
                  tiles,
                  findsNWidgets(code == 'WEEKLY_LOGIN' ? 7 : 31),
                  reason: '$reason $code',
                );
                _expectWhole(tester, tiles, '$reason $code tiles');
              }
              await _unmount(tester, state);
            },
            () => _fake(
              sent: sent,
              claim: _claimJson(programs: [_streakJson(), _calendarJson()]),
            ),
          );
        }
      });
    }
  });

  group('the celebration', () {
    testWidgets('lists what the claim gave, one line each, and closes', (
      tester,
    ) async {
      await _setView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = _state()
          ..rewardPrograms = rewardProgramsFromJson([
            _streakJson(),
            _calendarJson(claimedToday: true),
          ])
          ..rewardsGranted = [
            for (final g in [
              ..._twoGrants(),
              _grant(
                code: 'MONTHLY_CALENDAR',
                day: 25,
                reward: _day(
                  25,
                  'TABLE_PICTURE',
                  ref: '1',
                  tablePicture: _linesBackground,
                ),
                alreadyOwned: true,
              ),
            ])
              RewardGrant.fromJson(g),
          ];
        await _pumpLobby(tester, state);
        expect(tester.takeException(), isNull);
        final t = state.t;
        final party = find.byKey(const ValueKey('rewards-celebration'));
        expect(party, findsOneWidget);
        expect(
          find.descendant(
            of: party,
            matching: find.text(t.rewardsCollectedTitle),
          ),
          findsOneWidget,
        );
        String lineOf(Map<String, Object?> reward) =>
            rewardPrizeLabel(t, RewardPrize.fromJson(reward));
        expect(
          find.descendant(
            of: party,
            matching: find.text('+ ${lineOf(_day(3, 'CHIPS', value: 20000))}'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: party,
            matching: find.text(
              lineOf(_day(10, 'EMOJI', ref: '5', emoji: _clappingHands)),
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: party,
            matching: find.textContaining(t.rewardAlreadyOwned),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: party,
            matching: find.textContaining(
              t.rewardProgramName('WEEKLY_LOGIN', ''),
            ),
          ),
          findsOneWidget,
        );
        // The lobby's own purchase celebration is not shown as well.
        expect(find.text(t.rewardCollected), findsNothing);
        await tester.tap(find.text(t.tapToClose));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(state.rewardsGranted, isNull);
        expect(party, findsNothing);
        await _unmount(tester, state);
      }, () => _fake(sent: sent, claim: _claimJson()));
    });

    testWidgets('is raised by nothing but a claim that gave something', (
      tester,
    ) async {
      await _setView(tester);
      final sent = <http.Request>[];
      await http.runWithClient(() async {
        final state = _state();
        await _pumpLobby(tester, state);
        // The lobby claimed, was given nothing (today already collected on
        // another phone): no celebration.
        expect(_posts(sent), ['/api/reward-programs/claim']);
        expect(state.rewardPrograms, isNotNull);
        expect(state.rewardsGranted, isNull);
        expect(find.byKey(const ValueKey('rewards-celebration')), findsNothing);
        await _unmount(tester, state);
      }, () => _fake(sent: sent, claim: _claimJson()));
    });
  });
}
