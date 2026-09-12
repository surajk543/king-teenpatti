import 'dart:async';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../net/api_client.dart';
import '../net/app_update.dart';
import '../net/connection_failure.dart';
import '../net/game_connection.dart';
import '../net/purchases.dart';
import '../net/social_sign_in.dart';
import 'consent.dart';
import 'theme_preference.dart';

enum Screen { splash, update, login, lobby, table }

/// Everything the UI reads, and the only place the two halves of the server —
/// REST and socket — are stitched together.
///
/// It holds no rules. Bets, legality, who won and what anyone is allowed to see
/// are all decided by the server; this just relays intent and republishes what
/// comes back.
class GameState extends ChangeNotifier {
  GameState({String? serverUrl})
    : serverUrl = serverUrl ?? defaultServerUrl,
      _api = ApiClient(serverUrl ?? defaultServerUrl),
      _conn = GameConnection(serverUrl ?? defaultServerUrl);

  /// The production backend. For a local server override with
  /// `--dart-define=SERVER_URL=http://10.0.2.2:3000` (the emulator's alias
  /// for the host machine) or `http://<lan-ip>:3000` for a phone on the LAN.
  static const defaultServerUrl = String.fromEnvironment(
    'SERVER_URL',
    defaultValue: 'https://api.sungamestudio.com',
  );

  final String serverUrl;
  final ApiClient _api;

  /// Google Play. Subscribed at startup, not when the store opens: Play
  /// delivers a purchase whenever it can — days later, on a new device, after
  /// a reinstall — and one that arrives while the store is closed still has to
  /// be honoured.
  final Purchases purchases = Purchases();

  /// Set while a purchase is with Play or being credited, so the store can
  /// show progress instead of looking unresponsive.
  bool purchasePending = false;

  /// Play's answer on whether a newer build exists, asked once at startup.
  /// [UpdateStatus.none] on anything Play did not install, so a debug or
  /// side-loaded build is never held up by a check that cannot pass.
  UpdateStatus updateStatus = UpdateStatus.none;
  final AppUpdate _update = const AppUpdate();

  /// True while Play's own update flow is on screen.
  bool updating = false;
  final GameConnection _conn;
  final List<StreamSubscription<dynamic>> _subs = [];

  // ----------------------------------------------------------------- state

  /// The app opens on the splash — icon and studio line — while [start] finds
  /// out whether there is a session, a table, or a sign-in screen to show.
  Screen screen = Screen.splash;

  /// System, dark glass or light glass. Dark glass by default; the setting
  /// remembers a change ([ThemePreference]).
  ThemeMode themeMode = ThemePreference.fallback;

  /// English by default; the choice is remembered.
  AppLang lang = AppLang.english;

  /// Requirement 34: whether money is written in lakh and crore or in million
  /// and billion. Indian by default, since that is who the game is for.
  NumberSystem numbers = NumberSystem.indian;

  /// The strings for the chosen language.
  Strings get t => Strings(lang);

  User? user;
  GameConfig config = GameConfig.fallback;
  RoomState? room;
  List<ProfilePicture> pictures = const [];

  String? loginError;
  String? notice;
  bool busy = false;

  /// True while the signed-in player has yet to confirm that they expect no
  /// money or other enrichment from playing. The game is held behind that
  /// statement until they do; [acceptConsent] records it for this account
  /// ([NoWinningsConsent]) and it is never asked of them again on this device.
  bool consentPending = false;

  /// True from a cold start with a saved session until the server has either
  /// put the player back at their table or made clear there is none to go
  /// back to. The lobby is held behind a veil rather than flashed meanwhile.
  bool resuming = false;
  Timer? _resumeTimer;

  /// Set on every `session:ready`, cleared by the next table snapshot. A warm
  /// reconnect that brings no snapshot means the server no longer has us at a
  /// table — it restarted, or the room closed while we were away — and the
  /// table on screen is a ghost that has to go.
  Timer? _seatCheck;
  bool _snapshotSinceSession = false;

  /// The two screens' scaffolds, so the back gesture can close an open drawer
  /// before it ever asks about leaving the table or quitting the app.
  final tableScaffold = GlobalKey<ScaffoldState>();
  final lobbyScaffold = GlobalKey<ScaffoldState>();

  /// "1.0.0 (1)": the build this is, read from the package itself so the
  /// settings drawer can never disagree with the installed APK.
  String appVersion = '';

  /// This build's Android versionCode, for the server's minimum-version gate.
  /// 0 until package_info answers, which is why the gate treats 0 as "cannot
  /// tell" and lets the player through: locking someone out because a plugin
  /// had not replied yet would be a worse failure than an old client.
  int _buildNumber = 0;

  List<Reveal> showdown = const [];
  String showdownResult = '';

  /// Who took the pot, and for how much — kept apart from the sentence so the
  /// table can greet the winner by name, or say "you".
  String? winnerId;
  String winnerName = '';
  int winnerPot = 0;

  bool get iWon => winnerId != null && winnerId == user?.id;

  /// Clears the winner's banner once its moment has passed.
  ///
  /// The banner used to last until the next deal, which is fine while there is
  /// a next deal. When the last of the other players walks out there is not:
  /// the table drops back to waiting, the hand number never moves, and the
  /// winner would sit behind their own celebration forever. So the banner is
  /// given a life of its own, and the next deal merely cuts it short.
  Timer? _celebrationTimer;

  /// How long the banner stands when the server has not said when the next
  /// hand is due — the same six seconds it schedules by default.
  static const _celebrationFor = Duration(seconds: 6);

  final List<ChatMessage> chat = [];

  /// When the player sat down at the table they are at *now*.
  ///
  /// Display only — the drawer's "how long have I been here" readout and
  /// nothing else. It is never sent anywhere, never persisted, and no rule of
  /// the game reads it. The server has its own idea of when a seat was taken
  /// and this is deliberately not that: it answers the question the player is
  /// actually asking, which is how long *this sitting* has lasted.
  ///
  /// Reset whenever the room id changes, which is what makes switching tables
  /// start the clock again, and cleared on leaving so a stale figure cannot
  /// survive into the next table.
  DateTime? seatedAt;
  int unreadChat = 0;

  /// The message each player last said, while it is still worth showing over
  /// their seat. Cleared on a timer rather than by the countdown tick, so a
  /// bubble lasts the same three seconds however often the state republishes.
  final Map<String, ChatMessage> saidRecently = {};
  final Map<String, Timer> _bubbleTimers = {};

  /// What a player said while their previous line was still up — the newest
  /// one only, never a backlog. One bubble per player at a time; each holds
  /// for [bubbleFor], then the waiting line takes its place.
  final Map<String, List<ChatMessage>> _bubbleQueue = {};

  static const bubbleFor = Duration(seconds: 8);

  // ------------------------------------------------------------- sideshow

  /// The two hands of a sideshow this player was part of, while they are still
  /// on screen. The server sends these to nobody else, so holding them here
  /// gives no one else sight of them.
  SideshowReveal? sideshowReveal;
  Timer? _revealTimer;

  /// How long the two players get to look at the compared hands.
  static const revealFor = Duration(seconds: 5);

  /// The request currently waiting for an answer, straight from the table
  /// snapshot so a reconnect mid-request still shows the prompt.
  PendingSideshow? get sideshow => room?.sideshow;

  /// True when the viewer is the one being asked, and so the one who answers.
  bool get sideshowIsForMe =>
      sideshow != null && sideshow!.toUserId == user?.id;

  String? _token;
  String _deviceId = '';
  Timer? _ticker;

  /// Which rung of the bet ladder the stepper is on.
  int raiseIndex = 0;

  bool get connected => _conn.isConnected;
  TurnOptions? get options => room?.you?.options;
  bool get myTurn => options != null;

  // ------------------------------------------------------------- lifecycle

  /// The splash holds at least this long, so the icon is seen as a moment
  /// rather than a flicker on a fast network.
  static const minSplash = Duration(milliseconds: 1400);

  Future<void> start() async {
    final splashShownAt = DateTime.now();
    _startPurchases();
    final prefs = await SharedPreferences.getInstance();

    // Guest play is keyed to a device id, so chips survive a restart.
    _deviceId = prefs.getString('deviceId') ?? const Uuid().v4();
    await prefs.setString('deviceId', _deviceId);

    themeMode = ThemePreference.read(prefs);
    unawaited(
      PackageInfo.fromPlatform()
          .then((info) {
            appVersion = '${info.version} (${info.buildNumber})';
            _buildNumber = int.tryParse(info.buildNumber) ?? 0;
            notifyListeners();
          })
          .catchError((_) {}),
    );
    lang = AppLang.fromCode(prefs.getString('lang'));
    numbers = NumberSystem.fromName(prefs.getString('numbers'));
    _publishNumberFormat();

    _wire();
    unawaited(_loadPictures());

    // Asked alongside the rest of startup rather than before it: the check is
    // a Play round trip, and making the splash wait on it would add its
    // latency to every launch for the sake of an answer that is usually "no".
    final updateCheck = _update.check();

    // A saved session goes straight to the lobby.
    var next = Screen.login;
    final saved = prefs.getString('token');
    if (saved != null && saved.isNotEmpty) {
      _token = saved;
      try {
        user = await _api.me(saved);
        unawaited(_loadPictures());
        next = Screen.lobby;
        // An install that signed in before the statement existed meets it on
        // its next launch, once, like everyone else.
        await loadConsent(prefs);
        // If the app was closed mid-hand the seat may still be held, or the
        // table remembered; either way the answer comes with the connection,
        // which starts now, behind the splash.
        _beginResume();
        _conn.connect(saved);
      } catch (_) {
        // Expired or revoked — fall back to the sign-in screen.
        _token = null;
        await prefs.remove('token');
      }
    }

    updateStatus = await updateCheck;
    // An old client and a newer server can disagree about the wire, so the
    // update stands in front of everything — including a saved session, since
    // being signed in already does not make an out-of-date build safe.
    if (updateStatus != UpdateStatus.none) next = Screen.update;

    final shownFor = DateTime.now().difference(splashShownAt);
    if (shownFor < minSplash) await Future<void>.delayed(minSplash - shownFor);
    // A table snapshot may already have arrived and moved us on; only the
    // splash itself is replaced.
    if (screen == Screen.splash) screen = next;

    // One second is enough for a countdown that shows seconds.
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => notifyListeners(),
    );
    notifyListeners();
  }

  /// Whether this build is older than the server will talk to.
  ///
  /// Fails OPEN in both unknowable cases: a server that names no floor (0) and
  /// a build whose own number we do not have yet. A gate that locks people out
  /// when it cannot tell is worse than one that occasionally lets an old
  /// client through — the old client sees a broken table, the false positive
  /// sees a game it can never open.
  bool _belowMinimumBuild(int minimum) =>
      minimum > 0 && _buildNumber > 0 && _buildNumber < minimum;

  /// Sends the player to the update screen and cuts the socket.
  ///
  /// Disconnecting matters: this build has been told it cannot be understood,
  /// so leaving it talking would produce exactly the misread state the floor
  /// exists to prevent.
  void _forceUpdate() {
    _conn.disconnect();
    room = null;
    seatedAt = null;
    screen = Screen.update;
    notifyListeners();
  }

  void _wire() {
    _subs.addAll([
      _conn.onSession.listen((s) {
        user = s.user;
        config = s.config;
        _snapshotSinceSession = false;
        // The server's own floor, checked the moment it tells us what it is.
        // Play's update check answers "is there something newer"; this answers
        // "can this build still be talked to", which is the question that
        // matters when the wire has moved on — and only the server knows it.
        if (_belowMinimumBuild(s.config.minClientBuild)) {
          _forceUpdate();
          return;
        }
        _snapshotSinceSession = false;
        if (!resuming && room != null) _armSeatCheck();
        if (resuming) {
          final offer = s.resume;
          if (offer != null) {
            // The seat itself lapsed while the app was closed, but the table
            // is still there: sit back down at it. A refusal — full by now,
            // or too few chips — comes back as an error and ends the wait.
            _conn.joinByCode(offer.code);
            _armResumeFallback(const Duration(seconds: 4));
          } else {
            // A held seat's snapshot follows this message on the same socket,
            // so a short wait is enough to know whether one is coming.
            _armResumeFallback(const Duration(milliseconds: 900));
          }
        }
        notifyListeners();
      }),
      _conn.onState.listen((s) {
        final restored = resuming;
        _snapshotSinceSession = true;
        _seatCheck?.cancel();
        final newHand = room?.handNo != s.handNo;
        // A different room id means a different table — a switch, a resume
        // onto another table, or sitting down for the first time. All three
        // are a new sitting as far as the drawer's clock is concerned.
        final newTable = room?.roomId != s.roomId;
        // The server sends options to the player on turn and to nobody else,
        // so options arriving where there were none is this seat's turn
        // beginning.
        final myTurnBegan =
            room?.you?.options == null && s.you?.options != null;
        room = s;
        if (newTable) seatedAt = DateTime.now();
        if (newHand) {
          // A fresh deal cuts the last celebration short.
          _clearSideshow();
          _clearCelebration();
        }
        // Every turn opens on the plain chaal. The stepper used to keep the
        // rung it was left on until the next deal, so a raise made on one turn
        // was quietly made again when the turn came back round — and for more,
        // because the ladder had climbed with the stake it had just raised. On
        // a blind table, where the ladder runs to the whole stack, that is a
        // hand-sized bet the player never asked for.
        if (newHand || myTurnBegan) raiseIndex = 0;
        final steps = s.you?.options?.raiseSteps ?? const [];
        if (steps.isNotEmpty && raiseIndex > steps.length - 1) {
          raiseIndex = steps.length - 1;
        }
        if (screen != Screen.table) {
          screen = Screen.table;
          chat.clear();
          unreadChat = 0;
        }
        if (restored) _endResume(welcome: true);
        notifyListeners();
      }),
      _conn.onShowdown.listen((s) {
        // The hand is over, so a sideshow reveal still on its five seconds is
        // dropped rather than left to stack under the winner's banner.
        _clearSideshow();
        if (s.reveals.isNotEmpty) showdown = s.reveals;
        if (s.result.isNotEmpty) showdownResult = s.result;
        if (s.winnerId != null) {
          winnerId = s.winnerId;
          winnerName = s.winnerName;
          winnerPot = s.pot;
        }
        _armCelebration(s.nextHandAt);
        notifyListeners();
        unawaited(refreshUser());
      }),
      // Requirements 31 and 32: idled out, or out of chips for this table.
      // Shown out is not the same as leaving, so the reason is carried back to
      // the lobby rather than the player simply finding themselves there.
      _conn.onKicked.listen((message) {
        notice = message;
        switching = false;
        room = null;
        seatedAt = null;
        chat.clear();
        _clearBubbles();
        _clearSideshow();
        _clearCelebration();
        screen = Screen.lobby;
        notifyListeners();
        unawaited(refreshUser());
      }),

      _conn.onLeft.listen((_) {
        // Mid-switch, the next table's snapshot is already on its way, so a
        // room closing behind us is not a reason to walk back to the lobby.
        if (switching) return;
        room = null;
        seatedAt = null;
        chat.clear();
        _clearBubbles();
        _clearSideshow();
        _clearCelebration();
        screen = Screen.lobby;
        notifyListeners();
        unawaited(refreshUser());
      }),
      _conn.onSideshowAsked.listen((_) {
        // The request itself arrives in the table snapshot that follows; this
        // is only the cue to tick the clock the prompt counts down.
        notifyListeners();
      }),
      _conn.onSideshowReveal.listen((reveal) {
        sideshowReveal = reveal;
        _revealTimer?.cancel();
        _revealTimer = Timer(revealFor, () {
          sideshowReveal = null;
          notifyListeners();
        });
        notifyListeners();
      }),
      _conn.onSideshowDone.listen((done) {
        // Everyone is told what became of it. The two who compared hands are
        // already looking at the cards, so they are not told twice.
        if (done.fromUserId == user?.id || done.toUserId == user?.id) {
          if (!done.accepted) notice = _sideshowRefusedLine(done.reason);
        }
        notifyListeners();
      }),
      _conn.onChat.listen((m) {
        chat.add(m);
        // The room keeps at most a hundred messages, and so does this.
        if (chat.length > 100) chat.removeAt(0);
        unreadChat++;

        // Show it over the sender's seat for a moment, so a table that is
        // talking is visible without opening the chat. If their last line is
        // still up, this one waits its turn rather than cutting it short.
        //
        // At most ONE line waits. A bubble holds for 8s and a player may send
        // every 4s, so an unbounded queue drains slower than it fills and the
        // bubble drifts further behind real time with every message — a
        // chatty player would end up with the felt showing something they
        // said a minute ago. Keeping only the newest bounds how stale a
        // bubble can be to one hold. The full conversation is in the chat
        // drawer, in order and complete; the bubble is a glance, not a log.
        if (saidRecently.containsKey(m.userId)) {
          _bubbleQueue[m.userId] = [m];
        } else {
          _showBubble(m);
        }

        notifyListeners();
      }),
      _conn.onChatHistory.listen((h) {
        chat
          ..clear()
          ..addAll(h);
        notifyListeners();
      }),
      _conn.onError.listen((e) {
        notice = e;
        // A refused rejoin is an answer too: there is nothing to resume.
        if (resuming) _endResume();
        notifyListeners();
      }),
      _conn.onConnected.listen((_) => notifyListeners()),
    ]);
  }

  // --------------------------------------------------------------- bubbles

  void _showBubble(ChatMessage m) {
    saidRecently[m.userId] = m;
    _bubbleTimers[m.userId]?.cancel();
    _bubbleTimers[m.userId] = Timer(bubbleFor, () {
      saidRecently.remove(m.userId);
      final waiting = _bubbleQueue[m.userId];
      if (waiting != null && waiting.isNotEmpty) {
        _showBubble(waiting.removeAt(0));
      } else {
        _bubbleTimers.remove(m.userId);
      }
      notifyListeners();
    });
  }

  /// Drops every bubble and everything queued behind one — for leaving a
  /// table, where the people who said them are no longer in view.
  void _clearBubbles() {
    for (final t in _bubbleTimers.values) {
      t.cancel();
    }
    _bubbleTimers.clear();
    _bubbleQueue.clear();
    saidRecently.clear();
  }

  // ------------------------------------------------------------ seat check

  /// After a reconnect the server re-sends the table straight after
  /// `session:ready` if it still has us seated. If nothing follows, the seat
  /// is gone: back to the lobby, with a word about why, rather than a table
  /// that never moves again.
  void _armSeatCheck() {
    _seatCheck?.cancel();
    _seatCheck = Timer(const Duration(milliseconds: 1800), () {
      if (_snapshotSinceSession || room == null) return;
      room = null;
      seatedAt = null;
      chat.clear();
      _clearBubbles();
      _clearSideshow();
      _clearCelebration();
      switching = false;
      notice = t.tableLost;
      screen = Screen.lobby;
      notifyListeners();
      unawaited(refreshUser());
    });
  }

  // ---------------------------------------------------------------- resume

  void _beginResume() {
    resuming = true;
    // Whatever happens — no network, a slow server — the lobby is never held
    // back for long.
    _armResumeFallback(const Duration(seconds: 8));
  }

  void _armResumeFallback(Duration after) {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(after, _endResume);
  }

  /// Lifts the veil. [welcome] greets a player who was put back at a table.
  void _endResume({bool welcome = false}) {
    _resumeTimer?.cancel();
    _resumeTimer = null;
    if (!resuming) return;
    resuming = false;
    if (welcome) notice = t.welcomeBack;
    notifyListeners();
  }

  // ------------------------------------------------------------------ auth

  Future<void> loginAsGuest(String displayName) async {
    busy = true;
    loginError = null;
    notifyListeners();

    try {
      final r = await _api.loginGuest(
        deviceId: _deviceId,
        displayName: displayName,
      );
      _token = r.token;
      user = r.user;
      // Re-read the catalogue now there is a token: ownership is resolved per
      // viewer, and the startup call was anonymous.
      unawaited(_loadPictures());

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', r.token);
      await loadConsent(prefs);

      if (r.isNew && r.welcomeChips > 0) {
        notice =
            'Welcome! ${formatChips(r.welcomeChips)} chips added to your account.';
      }

      _conn.connect(r.token);
      screen = Screen.lobby;
    } on ApiException catch (e) {
      loginError = e.message;
    } catch (e) {
      // Not an answer from the server: a network-level failure, named by
      // kind so a report from a phone says what actually went wrong.
      debugPrint('login: $e');
      loginError =
          'Could not reach the server.\n${describeConnectionFailure(e, serverUrl)}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Signs in with Google or Facebook.
  ///
  /// The provider hands back a credential, the server verifies it and answers
  /// with the same session guest play gets — so everything after this line is
  /// identical to [loginAsGuest], deliberately: one session shape means one
  /// set of behaviour to reason about, whichever door was used.
  ///
  /// `credential` is null when the player backed out of the provider's own
  /// sheet, which is not an error and must not be reported as one.
  Future<void> loginWithProvider(
    String provider,
    Future<String?> Function() credentialOf,
  ) async {
    busy = true;
    loginError = null;
    notifyListeners();

    try {
      final credential = await credentialOf();
      if (credential == null) return;

      final r = await _api.loginProvider(
        provider: provider,
        credential: credential,
      );
      _token = r.token;
      user = r.user;
      // Re-read the catalogue now there is a token: ownership is resolved per
      // viewer, and the startup call was anonymous.
      unawaited(_loadPictures());

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', r.token);
      await loadConsent(prefs);

      if (r.isNew && r.welcomeChips > 0) {
        notice =
            'Welcome! ${formatChips(r.welcomeChips)} chips added to your account.';
      }

      _conn.connect(r.token);
      screen = Screen.lobby;
    } on SignInUnavailable catch (e) {
      // Not a failure of the network or the server: this build simply has no
      // credentials for that provider. Saying so keeps the player from
      // retrying something that cannot start working.
      loginError = t.signInUnavailable(e.provider);
    } on ApiException catch (e) {
      loginError = e.message;
    } catch (e) {
      // Not an answer from the server: a network-level failure, named by
      // kind so a report from a phone says what actually went wrong.
      debugPrint('login: $e');
      loginError =
          'Could not reach the server.\n${describeConnectionFailure(e, serverUrl)}';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    _token = null;
    _conn.disconnect();
    room = null;
    seatedAt = null;
    user = null;
    consentPending = false;
    screen = Screen.login;
    notifyListeners();
  }

  /// Works out whether [user] still owes the no-winnings confirmation.
  ///
  /// Called wherever a session begins — both sign-in doors and the saved
  /// session a cold start restores — so the statement stands in front of the
  /// game whichever way the player arrived, and only if this account has not
  /// confirmed it on this device before.
  Future<void> loadConsent([SharedPreferences? prefs]) async {
    consentPending = await NoWinningsConsent.isPending(user?.id, prefs);
  }

  /// Records the confirmation for this account and lets the game open.
  ///
  /// Written before the flag clears, so a crash between the two leaves the
  /// player asked again rather than never asked.
  Future<void> acceptConsent() async {
    final id = user?.id;
    if (id != null) await NoWinningsConsent.record(id);
    consentPending = false;
    notifyListeners();
  }

  Future<void> refreshUser() async {
    final token = _token;
    if (token == null) return;
    try {
      user = await _api.me(token);
      notifyListeners();
    } catch (_) {
      // Offline or reconnecting; the next update catches up.
    }
  }

  /// Loads the picture catalogue.
  ///
  /// Called once at startup and again after signing in, because ownership is
  /// resolved per viewer: the first call has no token and every premium
  /// picture comes back locked, and the second is what unlocks the ones this
  /// player has bought. Also re-run after a purchase.
  Future<void> _loadPictures() async {
    try {
      pictures = await _api.profilePictures(_token);
      notifyListeners();
    } catch (_) {
      // The picker just stays empty.
    }
  }

  // --------------------------------------------------------------- profile

  /// Requirement 29: renames the player. Returns the server's complaint, or
  /// null when it worked — the caller shows it under the field.
  Future<String?> renameTo(String name) async {
    final token = _token;
    if (token == null) return 'Not signed in';

    try {
      user = await _api.setDisplayName(token, name);
      notifyListeners();
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not reach the server.';
    }
  }

  /// Whether this table is closed to the player because of their stack.
  bool cappedOut(int boot, String category) =>
      config.cappedFor(user?.chips ?? 0, boot: boot, category: category);

  /// Wears a catalogue picture, or null to go back to the provider photo.
  Future<void> chooseAvatar(int? id) async {
    final token = _token;
    if (token == null) return;
    try {
      user = await _api.setAvatar(token, id);
    } on ApiException catch (e) {
      notice = e.message;
    }
    notifyListeners();
  }

  /// Set while a picture purchase is with the server, so the picker can show
  /// progress on that one tile instead of looking unresponsive.
  int? buyingPicture;

  /// Buys a premium picture and, when that works, puts it on.
  ///
  /// Two requests rather than one: the server sells and dresses separately so
  /// the refusals stay separate, and this is the one place that wants both.
  /// Returns true when the player ends up wearing it.
  Future<bool> buyPicture(int id) async {
    final token = _token;
    if (token == null || buyingPicture != null) return false;
    buyingPicture = id;
    notifyListeners();
    try {
      final bought = await _api.buyPicture(token, id);
      user = bought.user;
      // The catalogue carries `owned` per viewer, so it has to be re-read
      // before the picker can stop drawing a padlock on what was just bought.
      await _loadPictures();
      await chooseAvatar(id);
      return true;
    } on ApiException catch (e) {
      notice = e.message;
      return false;
    } catch (_) {
      notice = 'Could not reach the server.';
      return false;
    } finally {
      buyingPicture = null;
      notifyListeners();
    }
  }

  /// The reward just collected, while its celebration is on screen. Null the
  /// rest of the time. `readyAt` is epoch ms for the timed bonus and 0 for the
  /// milestone, which has no clock.
  ({String kind, int amount, int readyAt})? rewardWon;

  /// Closes the celebration. The overlay calls this when the player dismisses
  /// it or its own timer runs out.
  void dismissReward() {
    if (rewardWon == null) return;
    rewardWon = null;
    notifyListeners();
  }

  /// Subscribes to Play and says what to do with a purchase when one lands.
  /// Runs Play's in-place update. Play takes the screen, installs, and
  /// restarts the app, so a success never returns here.
  ///
  /// A failure or a cancel leaves the prompt exactly where it was: the player
  /// is still on an old build, and pretending otherwise would drop them into a
  /// game that may not work.
  Future<void> startUpdate() async {
    if (updating) return;
    updating = true;
    notifyListeners();

    // Play's in-place flow first, but only when Play said it could run one.
    // The server can force this screen for a build Play has nothing newer
    // for — or one Play never installed — and calling startImmediate() there
    // fails every time, which would leave the player on a locked screen
    // pressing a button that cannot work.
    var ok = updateStatus == UpdateStatus.available
        ? await _update.startImmediate()
        : false;

    // Otherwise send them to the listing — the store app first, its web page
    // second (net/app_update.dart picks the pair for the platform).
    if (!ok) {
      for (final uri in storeListingUris()) {
        try {
          ok = await launchUrl(
            Uri.parse(uri),
            mode: LaunchMode.externalApplication,
          );
        } catch (_) {
          ok = false;
        }
        if (ok) break;
      }
    }

    updating = false;
    if (!ok) notice = t.updateFailed;
    notifyListeners();
  }

  void _startPurchases() {
    purchases
      ..onPending = () {
        purchasePending = true;
        notifyListeners();
      }
      ..onFailed = (message) {
        purchasePending = false;
        notice = message;
        notifyListeners();
      }
      ..onDeliver = _deliverPurchase;
    unawaited(purchases.start());
  }

  /// Hands one receipt to the server and, if it banks the chips, reports true
  /// so the purchase can be completed with Play.
  ///
  /// Returning false is not a failure to swallow — it leaves the purchase
  /// pending with Play, which re-delivers it on the next launch. That is the
  /// safety net for dying between paying and crediting, and the reason this
  /// must never return true on a path that did not credit.
  Future<bool> _deliverPurchase(PurchaseDetails purchase) async {
    final token = _token;
    if (token == null) return false; // signed out; Play will bring it back
    final receipt = purchase.verificationData.serverVerificationData;
    if (receipt.isEmpty) return false;

    try {
      final r = await _api.redeemPurchase(token, purchase.productID, receipt);
      if (r.user != null) user = r.user;
      purchasePending = false;
      // `credited` false means the server had already banked this receipt.
      // Still a success: the chips are in the wallet and the transaction
      // should be finished rather than delivered again.
      if (r.credited) {
        rewardWon = (kind: 'purchase', amount: r.chips, readyAt: 0);
      }
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      // The server refused it — a receipt Google would not confirm, or an
      // unknown product. Completing it stops an endless redelivery loop of
      // something that will never be accepted.
      purchasePending = false;
      notice = e.message;
      notifyListeners();
      return true;
    } catch (_) {
      // Network or server trouble: keep the purchase pending so the next
      // launch retries. The player has paid and must not lose the chips.
      purchasePending = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> claimReward(String kind) async {
    final token = _token;
    if (token == null) return;
    try {
      final r = await _api.claimReward(token, kind);
      if (r.user != null) user = r.user;
      // Success is `claimed`, not a non-zero amount read from a field the
      // server does not send. A refusal keeps the server's own wording, which
      // is already specific ("Come back later", "You are at a table").
      if (r.claimed) {
        rewardWon = (kind: kind, amount: r.amount, readyAt: r.readyAt);
      } else {
        notice = r.message.isEmpty ? t.rewardRefused : r.message;
      }
    } on ApiException catch (e) {
      notice = e.message;
    }
    notifyListeners();
  }

  /// The three-way appearance setting: follow the system, dark glass, or
  /// light glass.
  Future<void> setThemeMode(ThemeMode next) async {
    if (next == themeMode) return;
    themeMode = next;
    notifyListeners();
    await ThemePreference.write(next);
  }

  Future<void> setLanguage(AppLang next) async {
    if (next == lang) return;
    lang = next;
    // The unit names are part of the language, so they follow it.
    _publishNumberFormat();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lang', next.code);
    notifyListeners();
  }

  Future<void> setNumberSystem(NumberSystem next) async {
    if (next == numbers) return;
    numbers = next;
    _publishNumberFormat();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('numbers', next.name);
    notifyListeners();
  }

  /// Hands the current choice and the current language's words for the units
  /// to [formatChips], which every part of the UI writing money goes through.
  void _publishNumberFormat() {
    chipNumberSystem = numbers;
    chipUnits = (
      lakh: t.unitLakh,
      crore: t.unitCrore,
      million: t.unitMillion,
      billion: t.unitBillion,
    );
  }

  /// The old two-way toggle, still wired where a single key is all there is
  /// room for: flips between light and dark. From `system` it flips away from
  /// whatever the device is showing right now, which is what a player tapping
  /// "the other one" means.
  Future<void> toggleTheme() async {
    final dark = switch (themeMode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark,
    };
    await setThemeMode(dark ? ThemeMode.light : ThemeMode.dark);
  }

  // -------------------------------------------------------------- gameplay

  void quickJoin(int boot, String category) => _conn.quickJoin(boot, category);
  void createPrivate() => _conn.createPrivate(TableCategory.seen);
  void joinByCode(String code) => _conn.joinByCode(code.trim().toUpperCase());
  void leaveTable() => _conn.leave();

  /// True while a table switch is in flight, so the brief moment between
  /// leaving one room and joining the next does not flash the lobby.
  bool switching = false;

  /// Moves to another table of the same category and stake.
  ///
  /// One server call: it finds the table, moves the seat and answers. The
  /// client used to leave, re-read the lobby and join by code, which had two
  /// problems — the player was briefly seated nowhere, and leaving can itself
  /// merge the very table that was about to be joined. Neither is possible now.
  ///
  /// The stake and category never change, and the entry cap is not re-checked:
  /// that guards the way in from the lobby, and this is a sideways move.
  Future<void> switchTable() async {
    if (room == null || switching) return;

    switching = true;
    notifyListeners();

    try {
      final reply = await _conn.request('room:switch', const {});
      if (reply['ok'] == false) {
        notice = '${reply['message'] ?? 'Could not switch table'}';
      }
    } finally {
      switching = false;
      notifyListeners();
    }
  }

  /// Looking is free and does not end the turn, but the ladder that comes
  /// back is double the blind one — so the stepper starts again rather than
  /// re-pricing whatever rung it happened to be showing.
  void see() {
    raiseIndex = 0;
    _conn.act(GameAction.see);
    notifyListeners();
  }

  void pack() => _conn.act(GameAction.pack);
  void show(int amount) => _conn.act(GameAction.show, amount: amount);

  /// Requirement: ask the player on your right to compare hands.
  ///
  /// Whether this is allowed at all is the server's call — the button is only
  /// lit when the server says so, and asking anyway is refused there.
  void askSideshow() => _conn.act(GameAction.sideshow);

  void answerSideshow(bool accept) => _conn.respondToSideshow(accept);

  String _sideshowRefusedLine(String reason) => switch (reason) {
    'timeout' => t.sideshowTimedOut,
    'left' => t.sideshowCancelled,
    _ => t.sideshowDeclined,
  };

  /// After a message goes out, the next one waits this long. Kept on the
  /// client — the server has its own, looser limiter — so the countdown the
  /// chat icon shows is exactly what the player can do.
  static const chatCooldown = Duration(seconds: 4);
  DateTime? _chatReadyAt;
  Timer? _chatCooldownTimer;

  bool get canChat =>
      _chatReadyAt == null || !DateTime.now().isBefore(_chatReadyAt!);

  /// Whole seconds until the next message may be sent; 0 when it may.
  int get chatCooldownLeft {
    final at = _chatReadyAt;
    if (at == null) return 0;
    final ms = at.difference(DateTime.now()).inMilliseconds;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  /// Sends the line and starts the cooldown. False when nothing was sent —
  /// blank text, or the cooldown still running.
  bool sendChat(String text) {
    if (text.trim().isEmpty || !canChat) return false;
    _conn.sendChat(text.trim());
    _chatReadyAt = DateTime.now().add(chatCooldown);
    _chatCooldownTimer?.cancel();
    // The one-second ticker redraws the countdown; this makes the moment it
    // reaches zero exact rather than up to a second late.
    _chatCooldownTimer = Timer(chatCooldown, notifyListeners);
    notifyListeners();
    return true;
  }

  /// Places the bet the stepper is showing. Anything above the base rung is a
  /// raise to the server and to the hand history, even though it is one button.
  void bet() {
    final steps = options?.raiseSteps ?? const [];
    if (steps.isEmpty) return;
    final amount = steps[raiseIndex.clamp(0, steps.length - 1)];
    _conn.act(
      amount == steps.first ? GameAction.chaal : GameAction.raise,
      amount: amount,
    );
  }

  void stepBet(int direction) {
    final steps = options?.raiseSteps ?? const [];
    if (steps.isEmpty) return;
    raiseIndex = (raiseIndex + direction).clamp(0, steps.length - 1);
    notifyListeners();
  }

  /// The amount the Chaal button will place.
  int get betAmount {
    final steps = options?.raiseSteps ?? const [];
    if (steps.isEmpty) return room?.stake ?? 0;
    return steps[raiseIndex.clamp(0, steps.length - 1)];
  }

  bool get canStepDown => myTurn && raiseIndex > 0;
  bool get canStepUp =>
      myTurn && raiseIndex < ((options?.raiseSteps.length ?? 1) - 1);

  /// Turns a server-relative picture path into something loadable.
  String? absoluteUrl(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http')) return path;
    return '$serverUrl${path.startsWith('/') ? '' : '/'}$path';
  }

  String? get avatarUrl => absoluteUrl(user?.avatarUrl);

  void markChatRead() {
    unreadChat = 0;
    notifyListeners();
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }

  /// Shows a one-off message to the player.
  void say(String message) {
    notice = message;
    notifyListeners();
  }

  /// Seats drawn from the viewer's chair: whoever is looking sits at the bottom
  /// and the table turns around them.
  List<Seat?> seatsInViewOrder() {
    final r = room;
    if (r == null) return const [];

    final total = config.maxPlayers == 0 ? 5 : config.maxPlayers;
    final mine = r.you?.seatIndex ?? 0;
    return List<Seat?>.generate(total, (i) {
      final serverIndex = (mine + i) % total;
      return serverIndex < r.seats.length ? r.seats[serverIndex] : null;
    });
  }

  /// How far through their turn the player to act is, 0 to 1, or null when no
  /// clock is running. Drives the pod filling up.
  double? get turnProgress {
    final t = room?.turn;
    if (t == null || t.deadline <= 0 || room?.state != TableState.betting) {
      return null;
    }

    final total = (room?.turnTimeoutMs ?? 25000) / 1000.0;
    if (total <= 0) return null;

    final left = (t.deadline - DateTime.now().millisecondsSinceEpoch) / 1000.0;
    return (1 - left / total).clamp(0.0, 1.0);
  }

  /// A colour per player for the chat.
  ///
  /// Taken from where they are sitting, so everyone at a table is a different
  /// colour — hashing the id gave two of five players the same one, which is
  /// exactly the case the colour is meant to tell apart. Someone who has left
  /// falls back to their id.
  Color colourFor(String userId, ColorScheme scheme) {
    final options = [
      scheme.primary,
      scheme.tertiary,
      scheme.error,
      scheme.secondary,
      scheme.inversePrimary,
    ];

    final seats = room?.seats ?? const [];
    for (final seat in seats) {
      if (seat.userId == userId) {
        return options[seat.seatIndex % options.length];
      }
    }

    final hash = userId.codeUnits.fold<int>(
      7,
      (a, c) => (a * 31 + c) & 0x7fffffff,
    );
    return options[hash % options.length];
  }

  /// Starts the banner's clock, running to the next deal the server has
  /// scheduled, or to a plain six seconds when it has not scheduled one.
  void _armCelebration(int nextHandAt) {
    final left = nextHandAt <= 0
        ? _celebrationFor
        : Duration(
            milliseconds: nextHandAt - DateTime.now().millisecondsSinceEpoch,
          );

    _celebrationTimer?.cancel();
    _celebrationTimer = Timer(left.isNegative ? Duration.zero : left, () {
      _clearCelebration();
      notifyListeners();
    });
  }

  void _clearCelebration() {
    _celebrationTimer?.cancel();
    _celebrationTimer = null;
    showdown = const [];
    showdownResult = '';
    winnerId = null;
    winnerName = '';
    winnerPot = 0;
  }

  void _clearSideshow() {
    _revealTimer?.cancel();
    _revealTimer = null;
    sideshowReveal = null;
  }

  @override
  void dispose() {
    unawaited(purchases.dispose());
    _clearSideshow();
    _resumeTimer?.cancel();
    _seatCheck?.cancel();
    _chatCooldownTimer?.cancel();
    _celebrationTimer?.cancel();
    _ticker?.cancel();
    for (final t in _bubbleTimers.values) {
      t.cancel();
    }
    for (final s in _subs) {
      s.cancel();
    }
    _conn.dispose();
    super.dispose();
  }
}

/// 1234567 -> "12,34,567" is the Indian grouping, but the server and the web
/// client both use plain thousands, so this matches them.
/// How large numbers are written (requirement 34).
enum NumberSystem {
  /// Lakh and crore: 10,00,000 reads as 10 Lakh.
  indian,

  /// Million and billion: the same figure reads as 1 Million.
  international;

  static NumberSystem fromName(String? name) => NumberSystem.values.firstWhere(
    (system) => system.name == name,
    orElse: () => NumberSystem.indian,
  );
}

/// The system money is written in, and the words for its units.
///
/// Module-level rather than threaded through every call: [formatChips] is used
/// at nearly thirty places, all of them presentation, and this is one setting a
/// player picks once. [GameState] owns it — it sets these when the preference
/// or the language changes and republishes, so everything showing money
/// rebuilds with the rest of the UI.
NumberSystem chipNumberSystem = NumberSystem.indian;
({String lakh, String crore, String million, String billion}) chipUnits = (
  lakh: 'Lakh',
  crore: 'Crore',
  million: 'Million',
  billion: 'Billion',
);

/// Where abbreviating starts. Below this a figure is short enough to read
/// digit by digit, and rounding it would only lose information.
const int _abbreviateAbove = 100000;

/// Money, as the player has asked to see it.
///
/// Small amounts stay exact and grouped. Large ones are named in the current
/// system, to four decimals with trailing zeros dropped — enough that 3,24,011
/// still reads as 3.2401 Lakh rather than collapsing to a rounded 3 Lakh.
String formatChips(int n) {
  final magnitude = n.abs();
  if (magnitude > _abbreviateAbove) {
    final unit = _unitFor(magnitude);
    if (unit != null) {
      return '${n < 0 ? '-' : ''}${_trim(magnitude / unit.$1)} ${unit.$2}';
    }
  }
  return _grouped(n);
}

/// The largest unit that fits, or null when the figure is better left in
/// digits — which in the international system is anything under a million.
(int, String)? _unitFor(int magnitude) => switch (chipNumberSystem) {
  NumberSystem.indian =>
    magnitude >= 10000000
        ? (10000000, chipUnits.crore)
        : (100000, chipUnits.lakh),
  NumberSystem.international =>
    magnitude >= 1000000000
        ? (1000000000, chipUnits.billion)
        : magnitude >= 1000000
        ? (1000000, chipUnits.million)
        : null,
};

/// Two decimals at most, and none of the trailing zeros that come with them:
/// 3.24 Lakh, 12 Lakh, 32.77 Crore. Two is what a player can take in at a
/// glance across the table; the exact figure is always a tap away in the menu.
String _trim(double value) {
  final text = value.toStringAsFixed(2);
  if (!text.contains('.')) return text;
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}

String _grouped(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

/// "3h 59m 54s". Seconds are always shown (requirement 26), so the timer
/// visibly ticks instead of resting on a minute.
String formatCountdown(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  if (h > 0) return '${h}h ${m}m ${s}s';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}
