// The lobby's three rewards are gone (owner, 30 Sep 2026: "Remove 24-hour
// daily reward, 4-hour bonus, and milestone reward"): no 4-hour bonus in the
// top bar, no daily bonus beside the Lucky Draw, no milestone in the
// bottom-right corner — even from a server that still sends the old `rewards`
// object on the account. The picture opens the top bar and the name has the
// room the bonus took; the Lucky Draw stands alone in the bottom-left corner,
// the level key and Friends in the bottom-right one, each on the screen and
// clear of the others, and a toast still keeps off them.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/l10n/strings.dart';
import 'package:teenpatti/models/dtos.dart';
import 'package:teenpatti/screens/lobby_screen.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/theme/app_theme.dart';
import 'package:teenpatti/widgets/premium_surface.dart';

int _at(Duration fromNow) => DateTime.now().add(fromNow).millisecondsSinceEpoch;

/// The account as an older server still sends it: every reward ready to
/// collect, so a chip left behind would be at its widest and loudest.
Map<String, Object?> _userJson() => {
  'id': 'u0',
  'provider': 'guest',
  'displayName': 'Guest0E00B',
  'chips': 324500,
  'diamond': 9,
  'hammer': 20,
  'missile': 1,
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
  'rewards': {
    'milestoneAvailable': true,
    'milestoneReward': 25000,
    'handsToNextMilestone': 25,
    'bonusReward': 10000,
    'bonusReadyAt': 0,
    'bonusAvailable': true,
    'dailyReward': 100000,
    'dailyHammers': 1,
    'dailyReadyAt': 0,
    'dailyAvailable': true,
  },
};

GameState _state() {
  // Play is never started; the override only keeps the purchase plugin from
  // registering an Android billing client in a unit test.
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state
    ..lang = AppLang.english
    ..screen = Screen.lobby
    ..config = GameConfig.fromJson({
      'maxPlayers': 5,
      'minPlayers': 2,
      'bootAmount': 200,
      'turnTimeoutMs': 25000,
      'tables': [
        {'category': 'seen', 'bootAmount': 200, 'maxPot': 2000000},
        {'category': 'blind', 'bootAmount': 200, 'maxChips': 500000},
      ],
    })
    ..user = User.fromJson(_userJson())
    // The Lucky Draw counting down, its chip at its widest.
    ..luckyDraw = LuckyDrawState.fromJson({
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
      'nextSpinAt': _at(const Duration(hours: 50)),
    });
}

Future<void> _loadInter() async {
  final inter = FontLoader('Inter');
  for (final face in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(rootBundle.load('assets/fonts/Inter-$face.ttf'));
  }
  await inter.load();
}

Future<void> _pumpLobby(
  WidgetTester tester,
  GameState state, {
  required Size screen,
  required double scale,
  required Brightness brightness,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
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
        theme: brightness == Brightness.dark
            ? AppTheme.dark(sound: false)
            : AppTheme.light(sound: false),
        builder: (context, child) => GlassBudget(child: child!),
        home: const LobbyScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _unmount(WidgetTester tester, GameState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
  state.dispose();
}

void main() {
  setUpAll(_loadInter);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an account that still carries the old rewards reads as before', () {
    final user = User.fromJson(_userJson());
    expect(user.displayName, 'Guest0E00B');
    expect(user.chips, 324500);
    expect(user.playerLevel?.level, 10);
  });

  for (final (screen, scale) in const [
    (Size(640, 360), 1.25),
    (Size(915, 412), 1.0),
  ]) {
    for (final brightness in Brightness.values) {
      testWidgets('at $screen x$scale (${brightness.name}) the lobby draws no '
          'reward, and its foot is the Lucky Draw, the level key and Friends, '
          'on the screen and clear of each other', (tester) async {
        final state = _state();
        await _pumpLobby(
          tester,
          state,
          screen: screen,
          scale: scale,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        final t = state.t;

        // Nothing of the three rewards — no chip, no popup, not a word of
        // them — whatever the account says.
        for (final words in const [
          '4-HOUR BONUS',
          'DAILY BONUS',
          'MILESTONE',
          'Collect',
          'hands to go',
          'hand to go',
        ]) {
          expect(find.textContaining(words), findsNothing, reason: words);
        }
        // One corner chip left in the lobby: the Lucky Draw's.
        expect(
          find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_CornerChip',
          ),
          findsOneWidget,
        );

        // The foot: the Lucky Draw bottom-left, the level key and Friends
        // bottom-right, each whole on the screen and clear of the others.
        final lucky = tester.getRect(
          find.byKey(const ValueKey('lucky-draw-chip')),
        );
        final level = tester.getRect(find.byKey(const ValueKey('level-key')));
        final friends = tester.getRect(find.byTooltip(t.friends));
        final onScreen = Offset.zero & screen;
        for (final (name, r) in [
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
          expect(r.height, greaterThanOrEqualTo(Dim.minTouch), reason: name);
        }
        expect(lucky.overlaps(level), isFalse);
        expect(lucky.overlaps(friends), isFalse);
        expect(level.overlaps(friends), isFalse);
        // In their corners: the chip from the left edge, the keys to the
        // right one, Friends the last.
        expect(lucky.left, lessThanOrEqualTo(Space.md + 1));
        expect(lucky.center.dx, lessThan(screen.width / 2));
        expect(level.right, lessThanOrEqualTo(friends.left));
        expect(friends.right, greaterThan(screen.width - Space.md - Space.lg));
        // Level with each other at the foot.
        expect((lucky.bottom - friends.bottom).abs(), lessThan(1));
        expect((level.bottom - friends.bottom).abs(), lessThan(1));

        // A toast keeps off all three.
        final lobby = tester.element(find.byType(LobbyScreen));
        final toast = lobbyNoticeArea(lobby);
        expect(toast, isNotNull);
        expect(toast!.left, greaterThanOrEqualTo(lucky.right));
        expect(toast.right, lessThanOrEqualTo(level.left));
        expect(toast.width, greaterThanOrEqualTo(160));

        // The top bar opens with the picture, where the 4-hour bonus stood,
        // and the name has the room it took: whole.
        final picture = tester.getRect(find.byTooltip(t.yourPicture));
        expect(picture.left, lessThanOrEqualTo(Space.md + 1));
        final name = tester.renderObject<RenderParagraph>(
          find.text('Guest0E00B'),
        );
        expect(name.didExceedMaxLines, isFalse);
        expect(
          name.size.width,
          greaterThanOrEqualTo(
            name.getMaxIntrinsicWidth(double.infinity) - 0.5,
          ),
        );

        await _unmount(tester, state);
      });
    }
  }

  testWidgets('the celebration still shows a pack bought in the lobby', (
    tester,
  ) async {
    final state = _state()
      ..rewardWon = (kind: 'purchase', amount: 100000, missiles: 0, hammers: 0);
    await _pumpLobby(
      tester,
      state,
      screen: const Size(640, 360),
      scale: 1.0,
      brightness: Brightness.dark,
    );
    expect(find.text(state.t.rewardCollected), findsOneWidget);
    expect(find.text(state.t.rewardPurchased), findsOneWidget);
    await tester.tap(find.text(state.t.tapToClose));
    await tester.pump();
    expect(state.rewardWon, isNull);
    await _unmount(tester, state);
  });
}
