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

  /// The clips in `assets/sfx/` are synthesised, not sourced: nothing there
  /// carries a licence, an attribution or a third party's rights, and the
  /// whole set is under 90 KB. See tool notes in the repo for how they were
  /// generated. The owner's own recordings live in `assets/sound/`.
  Future<void> _play(String clip) => _playAsset('sfx/$clip.wav');

  /// The look at a hand — the player's own or anybody else's at the table
  /// (owner, 26 Sep 2026: "this sound should be played when player see
  /// cards"). The owner's recording, 0.62 s.
  static const seeCardsClip = 'sound/see card sound.mp3';

  /// A card of the deal (owner, 26 Sep 2026: "when card is being distributed
  /// then use this sound … 12 times if 4 player plays and 15 times if 5 player
  /// plays, 6 times if 2 player plays"). The owner's recording, 0.5 s: a faint
  /// rustle for its first 200 ms, then the card's swish, loudest at 380 ms.
  static const dealCardClip = 'sound/Card Distribute.mp3';

  /// A Force Sideshow's hammer landing (owner, 26 Sep 2026: "when someone hit
  /// force side show then this sound should be played"). The owner's
  /// recording, 2 s: a strike at 100 ms and a ring that fades by 1.2 s.
  static const hammerHitClip = 'sound/hammer hit.mp3';

  /// How many of [dealCardClip] may sound at once. The deal sends a card
  /// every 115 ms and the clip is heard for 440 ms, so four overlap; one voice
  /// would stop each card's sound for the next one before its swish began,
  /// and only the last card of a deal would ever be heard.
  static const dealCardVoices = 5;
  int _dealCardVoice = 0;

  /// The voice the next [dealCard] plays on.
  @visibleForTesting
  int get nextDealCardVoice => _dealCardVoice;

  /// [asset] is under `assets/`, as [AssetSource] takes it; [voice] picks one
  /// of several players for the same clip, so that plays of it can overlap.
  Future<void> _playAsset(
    String asset, {
    double volume = 0.85,
    int voice = 0,
  }) async {
    if (!_sound) return;
    try {
      final player = _voices.putIfAbsent(
        voice == 0 ? asset : '$asset#$voice',
        () {
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
        },
      );
      await player.stop();
      await player.play(AssetSource(asset), volume: volume);
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

  /// One card of a deal leaving the deck ([dealCardClip]), at full volume: it
  /// peaks some 10 dB under the synthesised clips. Each card takes the next of
  /// [dealCardVoices] in turn, so a card's sound plays out while the cards
  /// after it start theirs. No haptic: a buzz for each of fifteen cards would
  /// be a rattle, not a deal. It replaced [tap]'s tick on the deal
  /// (26 Sep 2026).
  void dealCard() {
    final voice = _dealCardVoice;
    _dealCardVoice = (_dealCardVoice + 1) % dealCardVoices;
    unawaited(_playAsset(dealCardClip, volume: 1, voice: voice));
  }

  /// A Force Sideshow's hammer coming down on its target ([hammerHitClip]),
  /// heard by everybody at the table, as everybody sees the hammer. At the
  /// synthesised clips' 0.85: it strikes at full scale already.
  void hammerHit() => unawaited(_playAsset(hammerHitClip));

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
  /// The owner's recording ([seeCardsClip]; it replaced the synthesised
  /// `sfx/card.wav` on 26 Sep 2026). At full volume: it peaks where the others
  /// do but its body is some 15 dB quieter, the flick of a card rather than a
  /// tone. A card being turned over is not a button being pressed, so it gets
  /// its own feel as well: selectionClick is the lightest thing the platform
  /// has, which is what a card sliding over another one should be.
  void cards() {
    unawaited(_playAsset(seeCardsClip, volume: 1));
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
