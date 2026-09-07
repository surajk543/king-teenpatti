import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../net/api_client.dart';
import '../net/game_connection.dart';

enum Screen { login, lobby, table }

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

  /// An Android emulator reaches the host machine's loopback at 10.0.2.2.
  /// Override with `--dart-define=SERVER_URL=...` for a device or a LAN box.
  static const defaultServerUrl = String.fromEnvironment(
    'SERVER_URL',
    defaultValue: 'http://10.0.2.2:3000',
  );

  final String serverUrl;
  final ApiClient _api;
  final GameConnection _conn;
  final List<StreamSubscription<dynamic>> _subs = [];

  // ----------------------------------------------------------------- state

  Screen screen = Screen.login;

  /// Day mode by default; the toggle remembers a change.
  ThemeMode themeMode = ThemeMode.light;

  /// English by default; the choice is remembered.
  AppLang lang = AppLang.english;

  /// The strings for the chosen language.
  Strings get t => Strings(lang);

  User? user;
  GameConfig config = GameConfig.fallback;
  RoomState? room;
  List<ProfilePicture> pictures = const [];

  String? loginError;
  String? notice;
  bool busy = false;

  List<Reveal> showdown = const [];
  String showdownResult = '';

  /// Who took the pot, and for how much — kept apart from the sentence so the
  /// table can greet the winner by name, or say "you".
  String? winnerId;
  String winnerName = '';
  int winnerPot = 0;

  bool get iWon => winnerId != null && winnerId == user?.id;

  final List<ChatMessage> chat = [];
  int unreadChat = 0;

  /// The message each player last said, while it is still worth showing over
  /// their seat. Cleared on a timer rather than by the countdown tick, so a
  /// bubble lasts the same three seconds however often the state republishes.
  final Map<String, ChatMessage> saidRecently = {};
  final Map<String, Timer> _bubbleTimers = {};

  static const bubbleFor = Duration(seconds: 3);

  String? _token;
  String _deviceId = '';
  Timer? _ticker;

  /// Which rung of the bet ladder the stepper is on.
  int raiseIndex = 0;

  bool get connected => _conn.isConnected;
  TurnOptions? get options => room?.you?.options;
  bool get myTurn => options != null;

  // ------------------------------------------------------------- lifecycle

  Future<void> start() async {
    final prefs = await SharedPreferences.getInstance();

    // Guest play is keyed to a device id, so chips survive a restart.
    _deviceId = prefs.getString('deviceId') ?? const Uuid().v4();
    await prefs.setString('deviceId', _deviceId);

    themeMode = prefs.getBool('darkMode') == true ? ThemeMode.dark : ThemeMode.light;
    lang = AppLang.fromCode(prefs.getString('lang'));

    _wire();
    unawaited(_loadPictures());

    // A saved session goes straight to the lobby.
    final saved = prefs.getString('token');
    if (saved != null && saved.isNotEmpty) {
      _token = saved;
      try {
        user = await _api.me(saved);
        _conn.connect(saved);
        screen = Screen.lobby;
      } catch (_) {
        // Expired or revoked — fall back to the sign-in screen.
        _token = null;
        await prefs.remove('token');
      }
    }

    // One second is enough for a countdown that shows seconds.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
    notifyListeners();
  }

  void _wire() {
    _subs.addAll([
      _conn.onSession.listen((s) {
        user = s.user;
        config = s.config;
        notifyListeners();
      }),
      _conn.onState.listen((s) {
        final newHand = room?.handNo != s.handNo;
        room = s;
        if (newHand) {
          // A fresh deal clears the last reveal and resets the stepper.
          showdown = const [];
          showdownResult = '';
          winnerId = null;
          winnerName = '';
          winnerPot = 0;
          raiseIndex = 0;
        }
        final steps = s.you?.options?.raiseSteps ?? const [];
        if (steps.isNotEmpty && raiseIndex > steps.length - 1) {
          raiseIndex = steps.length - 1;
        }
        if (screen != Screen.table) {
          screen = Screen.table;
          chat.clear();
          unreadChat = 0;
        }
        notifyListeners();
      }),
      _conn.onShowdown.listen((s) {
        if (s.reveals.isNotEmpty) showdown = s.reveals;
        if (s.result.isNotEmpty) showdownResult = s.result;
        if (s.winnerId != null) {
          winnerId = s.winnerId;
          winnerName = s.winnerName;
          winnerPot = s.pot;
        }
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
        showdown = const [];
        showdownResult = '';
        winnerId = null;
        chat.clear();
        saidRecently.clear();
        screen = Screen.lobby;
        notifyListeners();
        unawaited(refreshUser());
      }),

      _conn.onLeft.listen((_) {
        // Mid-switch, the next table's snapshot is already on its way, so a
        // room closing behind us is not a reason to walk back to the lobby.
        if (switching) return;
        room = null;
        showdown = const [];
        showdownResult = '';
        winnerId = null;
        chat.clear();
        saidRecently.clear();
        screen = Screen.lobby;
        notifyListeners();
        unawaited(refreshUser());
      }),
      _conn.onChat.listen((m) {
        chat.add(m);
        // The room keeps at most a hundred messages, and so does this.
        if (chat.length > 100) chat.removeAt(0);
        unreadChat++;

        // Show it over the sender's seat for a moment, so a table that is
        // talking is visible without opening the chat.
        saidRecently[m.userId] = m;
        _bubbleTimers[m.userId]?.cancel();
        _bubbleTimers[m.userId] = Timer(bubbleFor, () {
          // Only clear it if nothing newer arrived in the meantime.
          if (saidRecently[m.userId] == m) {
            saidRecently.remove(m.userId);
            notifyListeners();
          }
        });

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
        notifyListeners();
      }),
      _conn.onConnected.listen((_) => notifyListeners()),
    ]);
  }

  // ------------------------------------------------------------------ auth

  Future<void> loginAsGuest(String displayName) async {
    busy = true;
    loginError = null;
    notifyListeners();

    try {
      final r = await _api.loginGuest(deviceId: _deviceId, displayName: displayName);
      _token = r.token;
      user = r.user;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', r.token);

      if (r.isNew && r.welcomeChips > 0) {
        notice = 'Welcome! ${formatChips(r.welcomeChips)} chips added to your account.';
      }

      _conn.connect(r.token);
      screen = Screen.lobby;
    } on ApiException catch (e) {
      loginError = e.message;
    } catch (e) {
      loginError = 'Could not reach the server. Is it running?';
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
    user = null;
    screen = Screen.login;
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

  Future<void> _loadPictures() async {
    try {
      pictures = await _api.profilePictures();
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

  Future<void> chooseAvatar(String? id) async {
    final token = _token;
    if (token == null) return;
    try {
      user = await _api.setAvatar(token, id);
    } on ApiException catch (e) {
      notice = e.message;
    }
    notifyListeners();
  }

  Future<void> claimReward(String kind) async {
    final token = _token;
    if (token == null) return;
    try {
      final r = await _api.claimReward(token, kind);
      if (r.user != null) user = r.user;
      notice = r.awarded > 0
          ? 'Collected ${formatChips(r.awarded)} chips.'
          : (r.message.isEmpty ? 'Not ready yet.' : r.message);
    } on ApiException catch (e) {
      notice = e.message;
    }
    notifyListeners();
  }

  Future<void> setLanguage(AppLang next) async {
    if (next == lang) return;
    lang = next;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lang', next.code);
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    themeMode = themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('darkMode', themeMode == ThemeMode.dark);
    notifyListeners();
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

  void see() => _conn.act(GameAction.see);
  void pack() => _conn.act(GameAction.pack);
  void show(int amount) => _conn.act(GameAction.show, amount: amount);

  void sendChat(String text) {
    if (text.trim().isEmpty) return;
    _conn.sendChat(text.trim());
  }

  /// Places the bet the stepper is showing. Anything above the base rung is a
  /// raise to the server and to the hand history, even though it is one button.
  void bet() {
    final steps = options?.raiseSteps ?? const [];
    if (steps.isEmpty) return;
    final amount = steps[raiseIndex.clamp(0, steps.length - 1)];
    _conn.act(amount == steps.first ? GameAction.chaal : GameAction.raise,
        amount: amount);
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
    if (t == null || t.deadline <= 0 || room?.state != TableState.betting) return null;

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
      if (seat.userId == userId) return options[seat.seatIndex % options.length];
    }

    final hash = userId.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0x7fffffff);
    return options[hash % options.length];
  }

  @override
  void dispose() {
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
String formatChips(int n) {
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
