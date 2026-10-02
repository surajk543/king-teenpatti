// The lobby's music (owner, 2 Oct 2026: "use this sound and play when player
// is in Lobby, when player joins the table, then this sound should be
// switched off").
//
// `assets/sound/Lobby.mp3` plays in a loop while the lobby SCREEN is showing,
// stops the moment the player is at a table (or signed out), starts again from
// its beginning on the way back, is held while the app is not in front, and is
// behind the Sound switch like every other sound of the game.
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/settings/feedback_settings.dart';
import 'package:teenpatti/state/game_state.dart';
import 'package:teenpatti/widgets/lobby_music.dart';

/// What the app asks the audio plugin to do with the music, in order — past
/// the Sound switch and the lobby/background rules, which the real
/// [FeedbackSettings] still applies.
class _Heard extends FeedbackSettings {
  final music = <String>[];

  // The clips are not this file's business (the Sound switch clicks as it
  // turns on), and no audio plugin runs here.
  @override
  Future<void> playClip(
    String asset, {
    required double volume,
    required int voice,
  }) async {}

  @override
  Future<void> startLoop(String asset, {required double volume}) async =>
      music.add('start $asset @$volume');

  @override
  Future<void> pauseLoop() async => music.add('pause');

  @override
  Future<void> resumeLoop() async => music.add('resume');

  @override
  Future<void> stopLoop() async => music.add('stop');
}

const _start = 'start sound/Lobby.mp3 @0.8';

GameState _state(Screen screen) {
  debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  final state = GameState(serverUrl: 'http://127.0.0.1:9');
  debugDefaultTargetPlatformOverride = null;
  return state..screen = screen;
}

Future<void> _pump(WidgetTester tester, GameState state, _Heard heard) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<GameState>.value(value: state),
        ChangeNotifierProvider<FeedbackSettings>.value(value: heard),
      ],
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: LobbyMusic(child: SizedBox.shrink()),
      ),
    ),
  );
  await tester.pump();
}

void _go(GameState state, Screen screen, {bool resuming = false}) {
  state
    ..screen = screen
    ..resuming = resuming
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    ..notifyListeners();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'the recording is in the bundle, and it plays loud enough to be heard',
    () {
      expect(FeedbackSettings.lobbyMusicClip, 'sound/Lobby.mp3');
      expect(
        File('assets/${FeedbackSettings.lobbyMusicClip}').existsSync(),
        isTrue,
      );
      expect(
        File('pubspec.yaml').readAsStringSync(),
        contains('assets/sound/'),
      );
      expect(FeedbackSettings.lobbyMusicVolume, inInclusiveRange(0.7, 1.0));
    },
  );

  test(
    'its audio context builds with asserts on, and takes no audio focus',
    () {
      expect(() => FeedbackSettings.musicSound, returnsNormally);
      final android = FeedbackSettings.musicSound.android;
      expect(android.usageType, AndroidUsageType.game);
      expect(android.contentType, AndroidContentType.music);
      expect(android.audioFocus, AndroidAudioFocus.none);
      final ios = FeedbackSettings.musicSound.iOS;
      expect(ios.category, AVAudioSessionCategory.ambient);
      expect(ios.options, isNot(contains(AVAudioSessionOptions.mixWithOthers)));
    },
  );

  group('the settings', () {
    test('play it once for the lobby, and stop it for a table', () async {
      final f = _Heard();
      f.lobbyMusic(playing: true);
      f.lobbyMusic(playing: true); // said again: nothing restarts
      await pumpEventQueue();
      expect(f.music, [_start]);
      expect(f.musicPlaying, isTrue);

      f.lobbyMusic(playing: false);
      f.lobbyMusic(playing: false);
      await pumpEventQueue();
      expect(f.music, [_start, 'stop']);
      expect(f.musicPlaying, isFalse);

      // Back in the lobby: from its beginning, not where it stopped.
      f.lobbyMusic(playing: true);
      await pumpEventQueue();
      expect(f.music, [_start, 'stop', _start]);
    });

    test('keep it behind the Sound switch', () async {
      final f = _Heard();
      await f.setSound(false);
      f.lobbyMusic(playing: true);
      await pumpEventQueue();
      expect(f.music, isEmpty);

      await f.setSound(true);
      await pumpEventQueue();
      expect(f.music, [_start]);

      await f.setSound(false);
      await pumpEventQueue();
      expect(f.music, [_start, 'stop']);
    });

    test(
      'a Sound switch saved off is honoured when the settings load',
      () async {
        SharedPreferences.setMockInitialValues({'soundOn': false});
        final f = _Heard();
        f.lobbyMusic(playing: true); // the lobby beat the load
        await f.load();
        await pumpEventQueue();
        expect(f.music, [_start, 'stop']);
        expect(f.musicPlaying, isFalse);
      },
    );

    test('hold it while the app is not in front, and carry on after', () async {
      final f = _Heard();
      f.lobbyMusic(playing: true);
      f.holdMusic(held: true);
      f.holdMusic(held: false);
      await pumpEventQueue();
      expect(f.music, [_start, 'pause', 'resume']);

      // Held, and the player is taken to a table meanwhile: stopped, and
      // coming back to the front starts nothing.
      f.holdMusic(held: true);
      f.lobbyMusic(playing: false);
      f.holdMusic(held: false);
      await pumpEventQueue();
      expect(f.music, [_start, 'pause', 'resume', 'pause', 'stop']);
    });

    test(
      'never start it behind the scenes: it begins when the app is back',
      () async {
        final f = _Heard();
        f.holdMusic(held: true);
        f.lobbyMusic(playing: true);
        await pumpEventQueue();
        expect(f.music, isEmpty);
        f.holdMusic(held: false);
        await pumpEventQueue();
        expect(f.music, [_start]);
      },
    );

    test('do what was asked in the order it was asked', () async {
      final f = _Heard();
      for (var i = 0; i < 3; i++) {
        f.lobbyMusic(playing: true);
        f.lobbyMusic(playing: false);
      }
      await pumpEventQueue();
      expect(f.music, [_start, 'stop', _start, 'stop', _start, 'stop']);
    });
  });

  group('the app', () {
    testWidgets('plays it in the lobby and not on the sign-in screen', (
      tester,
    ) async {
      final heard = _Heard();
      final state = _state(Screen.login);
      await _pump(tester, state, heard);
      expect(heard.music, isEmpty);

      _go(state, Screen.lobby);
      await tester.pump();
      expect(heard.music, [_start]);

      // GameState notifies every second in the lobby: nothing restarts.
      for (var i = 0; i < 5; i++) {
        _go(state, Screen.lobby);
        await tester.pump();
      }
      expect(heard.music, [_start]);
    });

    testWidgets('switches it off at a table and on again back in the lobby', (
      tester,
    ) async {
      final heard = _Heard();
      final state = _state(Screen.lobby);
      await _pump(tester, state, heard);
      expect(heard.music, [_start]);

      _go(state, Screen.table);
      await tester.pump();
      expect(heard.music, [_start, 'stop']);

      _go(state, Screen.lobby);
      await tester.pump();
      expect(heard.music, [_start, 'stop', _start]);

      // Signed out.
      _go(state, Screen.login);
      await tester.pump();
      expect(heard.music, [_start, 'stop', _start, 'stop']);
    });

    testWidgets('stays quiet behind a cold start\'s way back to a table', (
      tester,
    ) async {
      final heard = _Heard();
      final state = _state(Screen.splash);
      await _pump(tester, state, heard);

      // The lobby is under the "resuming your table" veil, then the table.
      _go(state, Screen.lobby, resuming: true);
      await tester.pump();
      _go(state, Screen.table);
      await tester.pump();
      expect(heard.music, isEmpty);

      // No seat to go back to: the veil lifts on the lobby, and it plays.
      _go(state, Screen.lobby, resuming: true);
      await tester.pump();
      _go(state, Screen.lobby);
      await tester.pump();
      expect(heard.music, [_start]);
    });

    testWidgets('holds it when the app leaves the front and carries on when '
        'it is back', (tester) async {
      final heard = _Heard();
      final state = _state(Screen.lobby);
      await _pump(tester, state, heard);

      // A shade or a system dialog over the app is not leaving it.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(heard.music, [_start]);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(heard.music, [_start, 'pause']);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(heard.music, [_start, 'pause', 'resume']);
    });

    testWidgets('the Sound switch turned off in the lobby stops it', (
      tester,
    ) async {
      final heard = _Heard();
      final state = _state(Screen.lobby);
      await _pump(tester, state, heard);
      await heard.setSound(false);
      await tester.pump();
      expect(heard.music, [_start, 'stop']);
    });
  });
}
