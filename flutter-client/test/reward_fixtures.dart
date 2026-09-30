// Fixtures for the reward programs' suites (30 Sep 2026): the owner's
// WEEKLY_LOGIN and a monthly calendar as GET /api/reward-programs and the
// claim send them, a fake server, and a GameState signed in at the lobby.
// Not a test file: `reward_programs_test.dart` and `weekly_login_test.dart`
// import it.
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
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

import 'script_fonts.dart';

const rewardServer = 'http://127.0.0.1:9';

/// Wednesday 7 October 2026, the third day of its week; Saturday 10 October,
/// the tenth of its month.
const wednesday = '2026-10-07';
const tenth = '2026-10-10';

Map<String, Object?> userJson({int chips = 1000000, int hammer = 20}) => {
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

Map<String, Object?> dayJson(
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

const clappingHands = {
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

const lovestruckCat = {
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

const linesBackground = {
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

const royalAce = {
  'code': 'ROYAL_ACE',
  'title': 'Royal Ace',
  'icon': '🃏',
  'validityDays': 7,
  'held': false,
  'expiresAt': 0,
};

/// The owner's WEEKLY_LOGIN, as seeded, the first [claimed] days of a run
/// marked.
List<Map<String, Object?>> weeklyLoginRewards({int claimed = 0}) => [
  dayJson(1, 'CHIPS', value: 10000, claimed: claimed >= 1),
  dayJson(2, 'HAMMER', value: 1, claimed: claimed >= 2),
  dayJson(3, 'CHIPS', value: 20000, claimed: claimed >= 3),
  dayJson(4, 'DIAMOND', value: 1, claimed: claimed >= 4),
  dayJson(5, 'CHIPS', value: 30000, claimed: claimed >= 5),
  dayJson(6, 'HAMMER', value: 2, claimed: claimed >= 6),
  dayJson(7, 'DIAMOND', value: 1, claimed: claimed >= 7),
];

/// A month's 31 days: chips on most, an emoji on the 10th, a table picture
/// on the 25th and a badge on the 31st, the [claimed] days marked.
List<Map<String, Object?>> monthlyCalendarRewards({
  Set<int> claimed = const {},
}) => [
  for (var k = 1; k <= 31; k++)
    switch (k) {
      10 => dayJson(
        k,
        'EMOJI',
        ref: '5',
        claimed: claimed.contains(k),
        emoji: clappingHands,
      ),
      25 => dayJson(
        k,
        'TABLE_PICTURE',
        ref: '1',
        claimed: claimed.contains(k),
        tablePicture: linesBackground,
      ),
      31 => dayJson(
        k,
        'BADGE',
        ref: 'ROYAL_ACE',
        claimed: claimed.contains(k),
        badge: royalAce,
      ),
      _ => dayJson(k, 'CHIPS', value: 5000 * k, claimed: claimed.contains(k)),
    },
];

Map<String, Object?> programJson({
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

/// The weekly streak on its [day] (the third, Wednesday, by default),
/// today's collected unless [claimedToday] says not.
Map<String, Object?> streakJson({
  int day = 3,
  bool claimedToday = true,
  String today = wednesday,
}) => {
  'program': programJson(
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
  'rewards': weeklyLoginRewards(claimed: claimedToday ? day : day - 1),
};

/// The monthly calendar on the 10th, six days collected before it (the 4th,
/// 6th and 8th missed), today's still waiting unless [claimedToday].
Map<String, Object?> calendarJson({bool claimedToday = false}) => {
  'program': programJson(
    code: 'MONTHLY_CALENDAR',
    mode: 'CALENDAR',
    periodType: 'MONTHLY',
    reset: false,
  ),
  'today': tenth,
  'dayOfPeriod': 10,
  'periodDays': 31,
  'currentDay': 10,
  'claimedToday': claimedToday,
  'claimedDays': claimedToday ? 7 : 6,
  'rewards': monthlyCalendarRewards(
    claimed: {1, 2, 3, 5, 7, 9, if (claimedToday) 10},
  ),
};

Map<String, Object?> grantJson({
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
Map<String, Object?> claimJson({
  List<Map<String, Object?>>? granted,
  List<Map<String, Object?>>? programs,
  int chips = 1010000,
}) => {
  'granted': granted ?? const [],
  'programs': programs ?? [streakJson(), calendarJson(claimedToday: true)],
  'user': userJson(chips: chips),
};

/// The grants a first claim of the day gives: the streak's Day 3 chips and
/// the calendar's 10th, an emoji.
List<Map<String, Object?>> twoGrants() => [
  grantJson(
    code: 'WEEKLY_LOGIN',
    day: 3,
    reward: dayJson(3, 'CHIPS', value: 20000),
  ),
  grantJson(
    code: 'MONTHLY_CALENDAR',
    day: 10,
    reward: dayJson(10, 'EMOJI', ref: '5', emoji: clappingHands),
  ),
];

/// [body] as the server sends it: JSON in UTF-8 (a badge's icon is an emoji,
/// which `http.Response(String)` would refuse as Latin-1).
http.Response rewardJson(Object body, [int status = 200]) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

/// A fake server: the read answers [programs] (or [programsResponse]), the
/// claim [claim] (or [claimResponse]); every request is kept in [sent] and
/// waits for [release] when given. The lobby's Friends key reads its count
/// as the lobby appears and hides itself from a server without the route,
/// so the friends routes answer empty.
MockClient fakeRewards({
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
      return rewardJson({'error': 'not_found'}, 404);
    }
    return claimResponse ?? rewardJson(claim ?? claimJson());
  }
  if (request.url.path == '/api/reward-programs') {
    return programsResponse ??
        rewardJson(
          programs ??
              {
                'programs': [streakJson(), calendarJson()],
              },
        );
  }
  if (request.url.path == '/api/friends/requests') {
    return rewardJson({
      'incoming': const [],
      'outgoing': const [],
      'incomingTotal': 0,
      'outgoingTotal': 0,
      'nextIncoming': null,
      'nextOutgoing': null,
    });
  }
  if (request.url.path == '/api/friends') {
    return rewardJson({'friends': const [], 'total': 0, 'nextCursor': null});
  }
  return rewardJson({'error': 'not_found'}, 404);
});

/// A GameState at the lobby, signed in (unless not), with an account whose
/// no-winnings confirmation is recorded on this phone (unless not
/// [consented]) — and read, as a sign-in reads it, since the weekly login
/// popup waits for that answer.
GameState rewardState({
  AppLang lang = AppLang.english,
  bool signedIn = true,
  bool consented = true,
}) {
  SharedPreferences.setMockInitialValues({
    if (consented) 'noWinningsAck:u0': true,
  });
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: rewardServer);
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
    ..user = User.fromJson(userJson());
  if (signedIn) {
    state.debugToken = 'tok';
    unawaited(state.loadConsent());
  }
  return state;
}

Future<void> setRewardView(
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

Widget rewardApp(
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

Future<void> pumpRewardLobby(
  WidgetTester tester,
  GameState state, {
  Brightness brightness = Brightness.dark,
}) async {
  final feedback = FeedbackSettings();
  addTearDown(feedback.dispose);
  await tester.pumpWidget(
    rewardApp(state, feedback, const LobbyScreen(), brightness: brightness),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

/// Nothing pumped in the tree ends the lobby's drifting chips before the
/// state is disposed.
Future<void> unmountReward(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

/// Whether every line of [finder]'s paragraphs is whole.
void expectRewardWhole(WidgetTester tester, Finder finder, String reason) {
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

/// Inter and the four Indic fonts; on a Mac (no Noto fonts at the Linux
/// path script_fonts.dart reads) the system's own Indic fonts stand in under
/// the Noto names, so the four Indic languages are laid out with real glyph
/// widths here too.
Future<void> loadRewardFonts() async {
  await loadScriptFonts();
  if (haveScriptFonts()) return;
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
