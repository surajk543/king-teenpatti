import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Whether the game clicks and buzzes, and the two switches that decide.
///
/// Deliberately NOT part of GameState. Nothing here touches the game, the
/// server or the wallet — it is two booleans and a call into the platform —
/// and putting it in the one ChangeNotifier the whole app listens to would
/// mean every seat, card and chip rebuilt whenever somebody toggled a switch
/// in a drawer.
///
/// Both default to on, because a card game that is silent and still on first
/// launch reads as broken rather than as tasteful.
class FeedbackSettings extends ChangeNotifier {
  static const _soundKey = 'soundOn';
  static const _vibrateKey = 'vibrateOn';

  bool _sound = true;
  bool _vibrate = true;

  bool get sound => _sound;
  bool get vibrate => _vibrate;

  /// One player per voice.
  ///
  /// A single shared player would cut its own tail off: chips landing while
  /// the previous chip is still ringing is the normal case at a table, not the
  /// exception. Six players is cheaper than the alternative of hearing every
  /// sound truncated.
  final Map<String, AudioPlayer> _voices = {};

  /// The audio profile every one of these clips plays under.
  static final AudioContext _uiSound = AudioContext(
    android: AudioContextAndroid(
      isSpeakerphoneOn: false,
      stayAwake: false,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.assistanceSonification,
      audioFocus: AndroidAudioFocus.none,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.ambient,
      options: const {AVAudioSessionOptions.mixWithOthers},
    ),
  );

  /// The clips are synthesised, not sourced: nothing here carries a licence,
  /// an attribution or a third party's rights, and the whole set is under
  /// 90 KB. See tool notes in the repo for how they were generated.
  Future<void> _play(String clip) async {
    if (!_sound) return;
    try {
      final player = _voices.putIfAbsent(clip, () {
        final p = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
        unawaited(p.setPlayerMode(PlayerMode.lowLatency));
        // Sonification, not media, and NO audio focus.
        //
        // The default asks Android for USAGE_MEDIA focus, which pauses
        // whatever the player is listening to — every tick would stop their
        // music. These are interface sounds: they belong in the same category
        // as a keyboard click, mixing over anything else rather than
        // interrupting it, and they respect the player's own silent mode.
        unawaited(p.setAudioContext(_uiSound));
        return p;
      });
      await player.stop();
      await player.play(AssetSource('sfx/$clip.wav'), volume: 0.85);
    } catch (_) {
      // A missing or unplayable clip must never be the reason a tap feels
      // dead: fall back to the platform tick.
      SystemSound.play(SystemSoundType.click);
    }
  }

  @override
  void dispose() {
    for (final p in _voices.values) {
      p.dispose();
    }
    _voices.clear();
    super.dispose();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _sound = prefs.getBool(_soundKey) ?? true;
    _vibrate = prefs.getBool(_vibrateKey) ?? true;
    notifyListeners();
  }

  Future<void> setSound(bool on) async {
    _sound = on;
    notifyListeners();
    // Play the click the switch just enabled, so the setting demonstrates
    // itself rather than being taken on trust.
    if (on) tap();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_soundKey, on);
  }

  Future<void> setVibrate(bool on) async {
    _vibrate = on;
    notifyListeners();
    if (on) turn();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_vibrateKey, on);
  }

  /// A tap on a control.
  ///
  /// SystemSoundType.click, not an asset: it is the sound the platform already
  /// uses for every other button on the device, it needs no file and no
  /// licence, and it stays silent when the player has turned touch sounds off
  /// system-wide — which a bundled clip would ignore.
  void tap() => unawaited(_play('tick'));

  /// The player's turn has begun.
  ///
  /// The turn clock is 25 seconds and the phone may well be face-down on a
  /// table, so this is the only thing that reaches someone who is not looking.
  /// mediumImpact rather than vibrate(): it is a notification, not an alarm,
  /// and it needs no VIBRATE permission because it goes through the view's own
  /// haptic channel.
  void turn() {
    if (!_vibrate) return;
    HapticFeedback.mediumImpact();
  }

  /// The player's turn passed without them: the server has packed their hand.
  ///
  /// Heavier than [turn], and deliberately so — the two must not feel alike.
  /// One says "you are up", the other says "you just lost that hand and two
  /// more of these and you leave the table", and a player who cannot tell them
  /// apart by feel learns nothing from either.
  void missedTurn() {
    if (!_vibrate) return;
    HapticFeedback.heavyImpact();
  }

  /// A hand has been looked at — this player's or somebody else's.
  ///
  /// A card being turned over is not a button being pressed, so it gets its
  /// own feel: selectionClick is the lightest thing the platform has, which is
  /// what a card sliding over another one should be.
  ///
  /// The SOUND is still the platform tick, because Flutter only exposes two
  /// system sounds (click and alert) and neither is a card. A real flick needs
  /// an asset — see the note on [alarm].
  void cards() {
    unawaited(_play('card'));
    if (_vibrate) HapticFeedback.selectionClick();
  }

  /// Chips have gone into the pot.
  ///
  /// Same limitation as [cards]: the tick stands in for a coin until there is
  /// a clip to play. The haptic is what actually distinguishes it — a light
  /// impact, the weight of something landing rather than being pressed.
  void potGrew() {
    unawaited(_play('coins'));
    if (_vibrate) HapticFeedback.lightImpact();
  }

  /// The turn clock is nearly out.
  ///
  /// SystemSoundType.alert, which IS a genuinely different sound from the tick
  /// — the platform's own notification tone. Paired with a heavy buzz so it
  /// reaches a phone lying face-down on a table, which is exactly the case
  /// this exists for.
  ///
  /// The other two events above would need audio files (and a package such as
  /// audioplayers) to be truly distinct; this one does not, which is why it is
  /// the one that sounds right today.
  void alarm() {
    unawaited(_play('alarm'));
    if (_vibrate) HapticFeedback.heavyImpact();
  }

  /// Sitting down at a table from the lobby.
  void enterTable() {
    unawaited(_play('door'));
    if (_vibrate) HapticFeedback.mediumImpact();
  }

  /// This player won the hand.
  void win() {
    unawaited(_play('win'));
    if (_vibrate) HapticFeedback.heavyImpact();
  }
}
