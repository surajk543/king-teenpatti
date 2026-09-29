// The audio profile every clip of the game plays under (owner, 29 Sep 2026:
// "Make sure hammer sound plays when i hit force sideshow", "Make sure missile
// sounds plays when i hit in gametable").
//
// Every other sound test replaces `FeedbackSettings.playClip`, so none of them
// ever built the real context — and it asserted: `mixWithOthers` on iOS's
// ambient category, which the plugin allows only on playback, playAndRecord or
// multiRoute. In a debug build that threw inside `playClip` on every clip, the
// catch played the platform click instead, and not one of the owner's
// recordings — the deal, the look, the hammer, the missile — was ever heard.
// Asserts run here as they do in a debug build.
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:teenpatti/settings/feedback_settings.dart';

void main() {
  test('the clips\' audio context builds with asserts on', () {
    expect(() => FeedbackSettings.uiSound, returnsNormally);
  });

  test('iOS: ambient, which mixes with other audio without asking', () {
    final ios = FeedbackSettings.uiSound.iOS;
    expect(ios.category, AVAudioSessionCategory.ambient);
    expect(ios.options, isNot(contains(AVAudioSessionOptions.mixWithOthers)));
  });

  test('Android: an interface sound that takes no audio focus', () {
    final android = FeedbackSettings.uiSound.android;
    expect(android.usageType, AndroidUsageType.assistanceSonification);
    expect(android.contentType, AndroidContentType.sonification);
    expect(android.audioFocus, AndroidAudioFocus.none);
  });
}
