// Chips going into the pot — a Chaal above all — sound the platform's own
// click (owner, 1 Oct 2026: "1.3.0 frontend version we were using sound on
// button chaal, i want same sound on chaal button now"), not the synthesised
// `sfx/coins.wav` that took its place once the audio context was fixed.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:teenpatti/settings/feedback_settings.dart';

class _Listening extends FeedbackSettings {
  final clips = <String>[];

  @override
  Future<void> playClip(
    String asset, {
    required double volume,
    required int voice,
  }) async => clips.add(asset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Object?> systemSounds;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    systemSounds = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemSound.play') {
            systemSounds.add(call.arguments);
          }
          return null;
        });
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  test('the pot growing plays the platform click and no clip', () async {
    final feedback = _Listening();
    feedback.potGrew();
    await Future<void>.delayed(Duration.zero);
    expect(systemSounds, ['SystemSoundType.click']);
    expect(feedback.clips, isEmpty);
  });

  test('with the Sound switch off the pot is silent', () async {
    final feedback = _Listening();
    await feedback.setSound(false);
    systemSounds.clear();
    feedback.potGrew();
    await Future<void>.delayed(Duration.zero);
    expect(systemSounds, isEmpty);
    expect(feedback.clips, isEmpty);
  });
}
