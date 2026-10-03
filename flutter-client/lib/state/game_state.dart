import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../config/features.dart';
import '../config/server_config.dart';
import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../models/friends.dart';
import '../net/picture_cache.dart';
import '../net/api_client.dart';
import '../net/app_update.dart';
import '../net/app_version.dart';
import '../net/connection_failure.dart';
import '../net/game_connection.dart';
import '../net/purchases.dart';
import '../net/social_sign_in.dart';
import '../widgets/card_back_art.dart' show CardBackImages;
import 'consent.dart';
import 'friends_state.dart';
import 'hammer_strike.dart';
import 'missile_strike.dart';
import 'player_reports.dart';
import 'quick_message_order.dart';
import 'table_config_cache.dart';
import 'theme_preference.dart';
import 'level_up.dart';
import 'xp_missions.dart';

/// `update` is the Force Update screen and `maintenance` the Maintenance one
/// (the app version gate, 28 Sep 2026): neither has a way past it.
enum Screen { splash, update, maintenance, login, lobby, table }

/// How long a table code is (owner, 13 Sep 2026): the server issues exactly
/// this many letters and digits and refuses a join by any other shape.
const tableCodeLength = 8;

/// Whether [code] has the shape of a table code — [tableCodeLength] ASCII
/// letters or digits, in either case, surrounding spaces ignored. Shape only:
/// whether a table carries it is the server's answer.
bool isValidTableCode(String code) =>
    RegExp('^[A-Za-z0-9]{$tableCodeLength}\$').hasMatch(code.trim());

/// What became of a Force Sideshow, for the key that asked for one.
enum ForceSideshowResult {
  /// The server compared the hands; the reveal and the table's notice follow.
  forced,

  /// The wallet was empty after all. Nothing was spent and this turn's ask is
  /// still there, so the store's Hammers shelf is the useful answer.
  noHammers,

  /// Anything else — the move is no longer allowed, or the server could not
  /// be reached. The player has already been told which.
  refused,
}

/// What became of a missile, for the key that fired it.
enum MissileResult {
  /// The server took it; the volley and the showdown follow for everyone.
  fired,

  /// The wallet was empty after all. Nothing was spent, so the store's
  /// Missiles shelf is the useful answer.
  noMissiles,

  /// Anything else — the move is no longer allowed, or the server could not
  /// be reached. The player has already been told which.
  refused,
}

/// What became of a trade of diamonds for missiles, for the store card.
enum MissileTradeResult {
  /// The missiles are in the wallet (or already were, from a replay).
  traded,

  /// Too few diamonds: the store's Diamonds shelf is the useful answer.
  notEnoughDiamonds,

  /// Anything else. The player has already been told why.
  refused,
}

/// What became of buying a premium picture, for the tile that asked.
enum PictureBuyResult {
  /// Bought (or already owned) and put on.
  bought,

  /// Too few hammers or diamonds for it: the store's shelf for that wallet is
  /// the useful answer, and nothing has been said yet.
  notEnough,

  /// Anything else. The player has already been told why.
  refused,
}

/// The line a missile leaves at the table, or null when there is nobody to
/// name: "You fired a missile" to the player who fired, "{name} fired a
/// missile" to everyone else. `game:action` carries an id and no name, so the
/// name comes from the seats.
String? missileFiredLine(
  Strings t, {
  required String? viewerId,
  required String fromUserId,
  required List<Seat> seats,
}) {
  if (viewerId != null && viewerId == fromUserId) return t.missileFiredByYou;
  for (final seat in seats) {
    if (seat.userId == fromUserId && seat.displayName.isNotEmpty) {
      return t.missileFiredBy(seat.displayName);
    }
  }
  return null;
}

/// The line a Force Sideshow leaves at the table, or null when there is nobody
/// to name.
///
/// Three audiences, three sentences: the player who forced it, the player it
/// was forced on, and everyone else. `game:sideshowResolved` carries ids but
/// no names, so the names come from the seats — both players are still seated
/// when it lands, the loser merely packed.
String? forcedSideshowLine(
  Strings t, {
  required String? viewerId,
  required String fromUserId,
  required String toUserId,
  required List<Seat> seats,
}) {
  String? nameOf(String userId) {
    for (final seat in seats) {
      if (seat.userId == userId && seat.displayName.isNotEmpty) {
        return seat.displayName;
      }
    }
    return null;
  }

  final from = nameOf(fromUserId);
  final to = nameOf(toUserId);
  if (viewerId != null && viewerId == fromUserId) {
    return to == null ? null : t.sideshowForcedByYou(to);
  }
  if (viewerId != null && viewerId == toUserId) {
    return from == null ? null : t.sideshowForcedOnYou(from);
  }
  return from == null || to == null ? null : t.sideshowForcedOn(from, to);
}

/// Everything the UI reads, and the only place the two halves of the server —
/// REST and socket — are stitched together.
///
/// It holds no rules. Bets, legality, who won and what anyone is allowed to see
/// are all decided by the server; this just relays intent and republishes what
/// comes back.
class GameState extends ChangeNotifier {
  /// [connection] is for tests: a stand-in socket that records what is sent
  /// (an emoji, say) without a server. The app leaves it null.
  GameState({String? serverUrl, @visibleForTesting GameConnection? connection})
    : serverUrl = serverUrl ?? defaultServerUrl,
      _api = ApiClient(serverUrl ?? defaultServerUrl),
      _conn = connection ?? GameConnection(serverUrl ?? defaultServerUrl) {
    _api.onAccountDisabled = _accountWasDisabled;
    // A 401 about a token this phone has already replaced with a newer
    // sign-in of its own is old news, not this session's.
    _api.onSessionReplaced = (token) {
      if (token != null && token != _token) return;
      _sessionWasReplaced();
    };
    // The app version gate: any request refused as too old or in maintenance.
    _api.onAppGate = _appGateRefused;
  }

  /// The backend this build was made against — [ServerConfig.url]: production
  /// unless a `--dart-define` (or `--dart-define-from-file=config/<env>.json`)
  /// says otherwise.
  static const defaultServerUrl = ServerConfig.url;

  final String serverUrl;
  final ApiClient _api;

  /// Friends (owner, 26 Sep 2026): the friend list, the requests and the
  /// lobby key's count. A notifier of its own, beside this one rather than
  /// inside it, so the Friends page rebuilds for a friend's news and never
  /// for this one's one-second tick; it signs in and out with this session.
  late final FriendsState friends = FriendsState(
    api: _api,
    token: () => _token,
    strings: () => t,
    say: say,
  );

  /// Report Player (owner, 27 Sep 2026): the report being written in the
  /// table's player drawer and the players reported this session. A notifier
  /// of its own, like [friends], so the drawer never rebuilds for this one's
  /// tick; it signs out with this session.
  late final PlayerReports reports = PlayerReports(
    api: _api,
    token: () => _token,
  );

  /// The daily XP missions just completed (owner, 27 Sep 2026: "whenever xp
  /// mission completed, show top notification bar for 5 seconds showing this
  /// is completed and xp increased"), queued for the bar at the top of every
  /// screen (XpMissionHost). A notifier of its own, so the bar never rebuilds
  /// with this one's one-second tick.
  final XpMissions xpMissions = XpMissions();

  /// The level the player has just reached (owner, 2 Oct 2026: "Use this
  /// animation to COngrats Player once his level upgraded , show a pop in
  /// UI"), held for the popup above every screen (LevelUpHost). A notifier of
  /// its own, as [xpMissions] is.
  final LevelUps levelUps = LevelUps();

  /// The standing the last `player:level` left — or the one a session began
  /// with (a sign-in, a cold start's `me()`, `session:ready`) — keyed by the
  /// account. What an award is compared against to find the missions it
  /// completed: NOT the account's own, which a `/api/auth/me` refresh (after
  /// every showdown) may already have moved to the award's figures before
  /// the push that announces them arrives.
  ({String userId, PlayerLevel? level})? _xpSeen;

  /// Set by [dispose], for the one answer that can arrive after it
  /// ([loadLevelLadder], asked by an award).
  bool _disposed = false;

  /// Awards that completed a mission while the level ladder was not on the
  /// phone, in the order they came, waiting for it: the ladder names each
  /// mission, says what it gave and orders an award's bars, and an award
  /// queued without it could only guess at them (two sources sharing one
  /// award). Queued when the read ends — with the ladder, or as best they can
  /// when it failed. Cleared at a sign-out.
  final List<({PlayerLevel? before, PlayerLevel after, int? taxBps})>
  _awardsAwaitingLadder = [];

  void _queueAwardsAwaitingLadder() {
    if (_disposed || _awardsAwaitingLadder.isEmpty) return;
    final waiting = List.of(_awardsAwaitingLadder);
    _awardsAwaitingLadder.clear();
    for (final a in waiting) {
      xpMissions.award(a.before, a.after, levelLadder, levelUpTaxBps: a.taxBps);
    }
  }

  /// A session has begun: the standing it brought is what the next award is
  /// compared against, so nothing earned before it is announced.
  void _seeStanding() {
    final u = user;
    _xpSeen = u == null ? null : (userId: u.id, level: u.playerLevel);
  }

  /// What `session:ready` (and every sign-in) does with the standing it
  /// brings, for the tests.
  @visibleForTesting
  void seeSessionStanding() => _seeStanding();

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

  // ------------------------------------------------------- app version gate

  /// What the server's app version gate (owner, 28 Sep 2026) holds this
  /// build to while it cannot play: FORCE_UPDATE ([Screen.update]) or
  /// MAINTENANCE ([Screen.maintenance]), with the store link, the version to
  /// reach and the operator's words, if any. Set by the start-up check
  /// (`GET /api/app-config`), by any REST refusal (426 / 503) and by the
  /// socket handshake's (connect_error `update_required` / `maintenance`);
  /// null while this build may play.
  AppGateVerdict? appGate;

  /// The optional update on offer (SOFT_UPDATE, or Play's own nudge), while
  /// its prompt is up; [laterSoftUpdate] puts it away for that announcement.
  AppGateVerdict? softUpdate;
  String? _softUpdateKey;

  /// The last answer of the start-up check, for the store link a legacy
  /// build floor ([_forceUpdate]) sends the player to.
  AppGateVerdict? _announced;

  /// True while the maintenance screen's Try again is asking.
  bool checkingAppGate = false;

  /// This build's own version, "1.6.0" — pubspec's, read from the package —
  /// or empty until read.
  String _installedVersion = '';

  /// Opens a store link. The app's is url_launcher, outside the app; a test
  /// replaces it to see which link Update now opened.
  @visibleForTesting
  Future<bool> Function(Uri uri) openStoreUrl = (uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

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

  /// The quick-message order the player saved on this phone, as read back —
  /// unchecked; [quickMessageOrder] is the order to draw.
  List<String> _quickOrder = const [];

  /// The quick messages of the player's own, oldest first, kept on this phone
  /// ([addCustomQuickMessage]).
  List<CustomQuickMessage> _quickCustom = const [];

  /// The player's own quick messages, oldest first.
  List<CustomQuickMessage> get customQuickMessages => _quickCustom;

  /// The order the chat drawer lists its quick messages in, as order keys
  /// ([builtInQuickKey], [customQuickKey]): the player's own arrangement
  /// ([moveQuickMessage]), every line — the set ones and their own — always
  /// present exactly once ([normaliseQuickOrder]). The owner's order, with
  /// nothing of their own, until the player changes it.
  List<String> get quickMessageOrder => normaliseQuickOrder(
    _quickOrder,
    t.quickMessages.length,
    [for (final line in _quickCustom) line.id],
  );

  /// The quick messages page, line by line in [quickMessageOrder]: each set
  /// line in the player's language, each of their own as they saved it.
  List<QuickEntry> get quickMessageEntries {
    final lines = t.quickMessages;
    final own = {for (final line in _quickCustom) line.id: line.text};
    return [
      for (final key in quickMessageOrder)
        if (builtInIndexOf(key) case final i?)
          (key: key, text: lines[i], builtIn: i, customId: null)
        else if (customIdOf(key) case final id?)
          (key: key, text: own[id]!, builtIn: null, customId: id),
    ];
  }

  User? user;

  /// The menu on screen and the table-wide figures beside it. Written only by
  /// [_applyMenu] (tests set it directly), from one of three sources: the
  /// phone's copy of the table catalogue at a cold start, `session:ready`, or
  /// a fetched catalogue — [MenuPrecedence] decides which wins.
  GameConfig config = GameConfig.fallback;

  /// The richest menu held: the table catalogue last fetched or read from the
  /// phone ([TableConfigCache]), whether or not it is the one on screen. Its
  /// version is what a fetch sends as `If-None-Match`, and what a session's
  /// `tableConfigVersion` is compared with.
  GameConfig? _catalogue;

  /// The catalogue version the latest `session:ready` named, or null while
  /// none has (or the server predates the catalogue and names none).
  String? _announcedVersion;

  /// The latest `session:ready`'s build floor, carried onto a catalogue when
  /// one is shown: the catalogue does not hold it, and a menu swap must never
  /// lift a floor the server set.
  int _sessionMinClientBuild = 0;

  /// The catalogue fetch in flight, so a login and a version mismatch landing
  /// together ask once.
  Future<void>? _tableConfigFetch;
  RoomState? room;
  List<ProfilePicture> pictures = const [];

  /// The table-picture catalogue (owner, 15 Sep 2026): the cloths a player
  /// can lay on their own table, loaded beside [pictures].
  List<TablePicture> tablePictures = const [];

  /// The emoji catalogue (owner, 26 Sep 2026): animated emojis a player can
  /// own and send at a table, loaded beside [pictures] — anonymously at
  /// start, with the token at every sign-in — so `owned` is this player's.
  List<EmojiItem> emojis = const [];

  /// The card-back catalogue (owner, 3 Oct 2026: "add one more tab Cards in
  /// Store which user can buy"): the backs a player can wear on their cards,
  /// loaded beside [pictures] at the same moments, so `owned` is this
  /// player's. The bundled Royal Fox, everybody's for nothing, is not in it.
  /// Forgotten at sign-out and account deletion.
  List<CardBackground> cardBackgrounds = const [];

  String? loginError;
  String? notice;
  bool busy = false;

  /// True once the server has said this account is disabled (users.is_active
  /// FALSE; owner, 26 Sep 2026): the sign-in screen shows the "contact
  /// support" popup, and [dismissAccountDisabled] clears it. Set from the
  /// login, a restored session, any signed-in request, the socket's handshake
  /// and a table's refusal alike ([accountDisabledCode]).
  bool accountDisabled = false;

  /// True once the server has said this device's sign-in was replaced — the
  /// account signed in on another device (owner, 28 Sep 2026: "the first one
  /// will be auto logout and showing message someone has logged in your
  /// account"): the device is signed out and the sign-in screen says why;
  /// [dismissSessionReplaced] clears it. Set from a restored session, any
  /// signed-in request, the socket's handshake and the `session:replaced`
  /// push alike ([sessionReplacedCode]).
  bool sessionReplaced = false;

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

  /// What the winner paid in winning tax out of [winnerPot], and at what
  /// rate in basis points (owner, 26 Sep 2026: at a table that taxes its
  /// winners, the winner of each hand pays their level's share of the whole
  /// pot). The server's own figures from `game:handEnded` — the client never
  /// works a tax out — and 0 for every hand none was taken from.
  int winnerTax = 0;
  int winnerTaxBps = 0;

  /// The chips that actually land on the winner's stack: the pot, less the
  /// tax. What the stack is seen to rise by — never the whole pot and then a
  /// drop, since the settled table already holds the pot less the tax.
  int get winnerLanded => winnerTax >= winnerPot ? 0 : winnerPot - winnerTax;

  /// The tax the latest `game:handEnded` named, until the news that names
  /// its winner is applied ([handleHandTax], [_applyShowdown]). Held apart
  /// because that news can itself be held back behind a missile volley.
  HandTaxNews? _handTax;

  bool get iWon => winnerId != null && winnerId == user?.id;

  /// Whether the viewer's table taxes its winners (owner, 26–27 Sep 2026:
  /// every public Seen, Blind and Variation table). Never a poker room.
  bool get tableTaxesWinner => room?.taxesWinner == true;

  /// The winning tax the viewer would pay at their table if they won a hand
  /// now, in basis points: their seat's rate as the server sent it
  /// ([You.taxBps]), else the rate their account pays — the lower of their
  /// level's and their badges' ([User.paysTaxBps]); null where neither is
  /// known, or the table does not tax. Only ever shown — the server charges
  /// it.
  int? get myTaxBps {
    if (!tableTaxesWinner) return null;
    return room?.you?.taxBps ?? user?.paysTaxBps;
  }

  /// The whole level ladder (`GET /api/levels`, owner, 27 Sep 2026): every
  /// level with its winning tax, every badge with its rate, the ways XP is
  /// earned and the day's cap — what the table's tax popup lays out in full.
  /// Configuration, the same for every player, so it outlives a sign-out.
  /// Null until first read, and from a server that predates it.
  LevelLadder? levelLadder;

  /// True while [loadLevelLadder] is asking.
  bool levelLadderLoading = false;

  /// True when the last [loadLevelLadder] failed and there is no ladder to
  /// show; the popup offers Try again.
  bool levelLadderFailed = false;

  /// Reads the ladder afresh, so an owner's edit shows the next time it is
  /// looked at. What is on screen stays while it is asked, and when the
  /// asking fails; one read at a time — a second call while one is out
  /// answers when that one does.
  Future<void> loadLevelLadder() =>
      _ladderRead ??= _readLevelLadder().whenComplete(() => _ladderRead = null);

  Future<void>? _ladderRead;

  Future<void> _readLevelLadder() async {
    levelLadderLoading = true;
    notifyListeners();
    try {
      final ladder = await _api.levels();
      if (ladder != null) {
        levelLadder = ladder;
        // Every level's art onto the phone now, not when each level is first
        // seen (29 Sep 2026: "Make sure you cache the all level icons in
        // phone"): fetched once per phone, ever, and read from its disk after.
        unawaited(
          PictureCache.keep(
            [
              for (final level in ladder.levels)
                if (level.hasArt) absoluteUrl(level.assetUrl),
            ].nonNulls,
          ),
        );
      }
      levelLadderFailed = levelLadder == null;
    } catch (_) {
      levelLadderFailed = levelLadder == null;
    } finally {
      levelLadderLoading = false;
      // A mission bar may ask for the ladder moments before the state goes
      // (a sign-out in a test, the app closing): the answer then has nobody
      // to tell.
      if (!_disposed) notifyListeners();
    }
  }

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

  /// The emoji each player last sent, while it still plays over their seat
  /// (owner, 26 Sep 2026) — in the chat bubble's place, and apart from
  /// [saidRecently]: an emoji is a moment, not a sentence, so it holds for
  /// [emojiBubbleFor] rather than [bubbleFor], and while it plays it stands
  /// where the player's words would.
  final Map<String, ChatMessage> emojiShown = {};
  final Map<String, Timer> _emojiTimers = {};

  /// An emoji sent while the player's previous one was still playing — the
  /// newest only, as [_bubbleQueue] keeps for words.
  final Map<String, ChatMessage> _emojiWaiting = {};

  /// How long an emoji plays over its sender's seat (owner, 26 Sep 2026: "for
  /// emoji keep the timing 5 seconds instead of 4").
  static const emojiBubbleFor = Duration(seconds: 5);

  /// Players this viewer has muted, by user id.
  ///
  /// Deliberately small: it is **this client, this table, this sitting**.
  /// Nothing is sent to the server, nothing is written to disk, and the set is
  /// emptied the moment the table changes — leaving, being shown out, or
  /// switching. A player who blocks somebody and comes back to a table they
  /// are also at blocks them again. That is the owner's rule (22 Sep 2026),
  /// and it is why this is a `Set` on the state object rather than a
  /// preference or a server-side relationship: a mute that outlived the
  /// sitting would be a moderation feature, which this is not.
  ///
  /// A blocked player's lines are dropped on arrival rather than filtered at
  /// paint: they raise no unread badge, never bubble over a seat, and do not
  /// sit in [chat] waiting to reappear if the block is lifted. Blocking is
  /// "stop showing me this person", not "hide, but keep".
  final Set<String> _blocked = {};

  /// The ids currently blocked, for the drawer to list. Unmodifiable so the
  /// only ways in and out are [blockPlayer] and [unblockPlayer].
  Set<String> get blockedIds => Set.unmodifiable(_blocked);

  /// Whether [userId]'s messages are hidden from this viewer right now.
  bool isBlocked(String userId) => _blocked.contains(userId);

  /// Hides [userId]'s messages and takes away anything of theirs on screen —
  /// the line over their seat and any line queued behind it — so blocking
  /// takes effect on the felt at once rather than at their next message.
  void blockPlayer(String userId) {
    if (userId.isEmpty || userId == user?.id) return;
    if (!_blocked.add(userId)) return;
    chat.removeWhere((m) => m.userId == userId);
    _bubbleTimers.remove(userId)?.cancel();
    _bubbleQueue.remove(userId);
    saidRecently.remove(userId);
    // Their emoji goes with their words: it is a chat line like any other.
    _emojiTimers.remove(userId)?.cancel();
    _emojiWaiting.remove(userId);
    emojiShown.remove(userId);
    notifyListeners();
  }

  /// Lets [userId] be heard again. Their past lines stay gone — they were
  /// dropped, not hidden — so the drawer fills from their next message.
  void unblockPlayer(String userId) {
    if (_blocked.remove(userId)) notifyListeners();
  }

  /// Empties the block list. Called wherever the sitting ends, so the rule
  /// "blocking lasts as long as you are at this table" has one meaning.
  void _clearBlocked() {
    if (_blocked.isEmpty) return;
    _blocked.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------- sideshow

  /// The two hands of a sideshow this player was part of, while they are still
  /// on screen. The server sends these to nobody else, so holding them here
  /// gives no one else sight of them.
  SideshowReveal? sideshowReveal;
  Timer? _revealTimer;

  /// How long the two players get to look at the compared hands.
  static const revealFor = Duration(seconds: 5);

  // ------------------------------------------------------------- the hammer

  /// The Force Sideshow being struck across the table, from the moment either
  /// of its events reaches this client until [HammerTiming.total] later.
  ///
  /// Everyone at the table sees the hammer — the two players and every
  /// bystander — and only the two players ever get cards with it.
  HammerStrike? hammerStrike;

  /// Whether the hammer has landed. Until it has, the compared hands stay face
  /// down even for the two players who were sent them.
  bool _hammerLanded = false;

  /// Whether the loser's fold and the table's notice have been shown.
  bool _hammerResolved = false;

  final List<Timer> _hammerTimers = [];

  /// Every strike already shown this hand, by [HammerStrike.key]. A player
  /// hears of one sideshow twice (the reveal, then the resolution) and must
  /// see one hammer.
  final Set<String> _hammersShown = {};

  /// The player whose fold is drawn as not having happened yet, and the timer
  /// that lets it show anyway if no strike follows the pack that set it.
  String? _foldHeldFor;
  Timer? _foldHoldTimer;

  /// "X forced a sideshow on Y", waiting for the hammer to land.
  String? _hammerNotice;

  /// The sideshow reveal as the felt may draw it: nothing while a hammer is
  /// still on its way to the pod, so the cards turn over when it lands.
  SideshowReveal? get shownSideshowReveal =>
      hammerStrike != null && !_hammerLanded ? null : sideshowReveal;

  /// Whether [userId]'s pack is being held back until the hammer has landed.
  /// The server has already packed them; the table draws them still playing
  /// for the second and a bit it takes the hammer to get there.
  bool foldHeldFor(String? userId) => userId != null && userId == _foldHeldFor;

  /// Whether a strike is still playing out: from the throw until the loser
  /// folds. For that long the felt links the two players' pods, the way it
  /// links an ordinary sideshow's two seats while the request waits — so the
  /// whole table, not just the two in it, can see who the sideshow is between.
  bool get hammerLinkShown => hammerStrike != null && !_hammerResolved;

  // ------------------------------------------------------------ the missile

  /// The missile volley crossing the table, from the `game:action` that
  /// announced it until [MissileTiming.total] later (owner, 14 Sep 2026).
  ///
  /// Every viewer sees it — the player who fired and everyone they fired at —
  /// and the showdown that the server sends straight after is held back until
  /// the explosions have played out ([missileHoldsReveal]).
  MissileStrike? missileStrike;

  /// Whether the winner has been told, and the held showdown gone out.
  bool _missileLanded = false;

  final List<Timer> _missileTimers = [];

  /// Every volley already shown, by [MissileStrike.key], so a `game:action`
  /// delivered twice launches one volley.
  final Set<String> _missilesShown = {};

  /// `game:showdown` and `game:handEnded` that arrived while the missiles were
  /// still in the air, in the order they came.
  final List<ShowdownNews> _heldShowdowns = [];

  /// `player:level` that arrived while the missiles were still in the air, in
  /// the order they came. An award lands with the hand's end, which the
  /// volley is holding back: the bar that says "Win by Trail" and the
  /// level-up popup would tell the result before the cards turn over, and
  /// their sounds would be lost under the blasts. They go out after the held
  /// showdown ([_releaseHeldStandings]).
  final List<Standing> _heldStandings = [];

  /// The pot as it stood when the missile was fired. The server settles it at
  /// once, and a plinth emptying before the missiles land would say the hand
  /// was over before the table has been shown how.
  int? _missilePot;

  /// True from the missile's `game:action` until [MissileTiming.reveal]: the
  /// cards, the winner and the seats' won/lost are all held back until the
  /// explosions have played out.
  bool get missileHoldsReveal => missileStrike != null && !_missileLanded;

  /// The pot the felt should draw: the one the missile was fired over, while
  /// the reveal is held; the table's own otherwise.
  int? get heldPot => missileHoldsReveal ? _missilePot : null;

  /// [seat] as the felt should draw it while a volley holds the reveal: a seat
  /// the server has already marked won or lost is still playing until the
  /// missiles land. Everything else, and every seat outside a volley, is drawn
  /// as it is.
  Seat? seatAsShown(Seat? seat) {
    if (seat == null) return null;
    if (seat.status == SeatState.packed && foldHeldFor(seat.userId)) {
      return seat.withStatus(SeatState.active);
    }
    if (missileHoldsReveal &&
        (seat.status == SeatState.won || seat.status == SeatState.lost)) {
      return seat.withStatus(SeatState.active);
    }
    return seat;
  }

  /// The request currently waiting for an answer, straight from the table
  /// snapshot so a reconnect mid-request still shows the prompt.
  PendingSideshow? get sideshow => room?.sideshow;

  /// True when the viewer is the one being asked, and so the one who answers.
  bool get sideshowIsForMe =>
      sideshow != null && sideshow!.toUserId == user?.id;

  // ------------------------------------------------------------- variation

  /// A variation table's window and what came of it, straight from the table
  /// snapshot — never a copy kept here — so a reconnect mid-window rebuilds
  /// the picker, the "… is selecting" line and both countdowns from the one
  /// snapshot it is sent. Null on seen and blind tables and between hands.
  VariationState? get variation => room?.variation;

  bool get onVariationTable => room?.category == TableCategory.variation;

  /// True while the hand is waiting for somebody to choose its rules. Nobody
  /// is on turn for as long as this is.
  bool get variationSelecting => variation?.selecting == true;

  /// True when the viewer is the one choosing, and so the one who gets the
  /// keys. Everyone else is only told who is.
  bool get variationIsMine =>
      variationSelecting && variation!.userId == user?.id;

  /// How far through the window the chooser is, 0 to 1, or null when no window
  /// is open or it has no deadline. The chooser's pod fills with it exactly as
  /// a pod fills on a turn ([turnProgress]): they are the one on the clock.
  double? get variationProgress {
    final v = variation;
    if (v == null || !v.selecting || v.deadline <= 0 || v.timeoutMs <= 0) {
      return null;
    }
    final left = v.deadline - DateTime.now().millisecondsSinceEpoch;
    return (1 - left / v.timeoutMs).clamp(0.0, 1.0);
  }

  /// The window that has just closed, for the few seconds the table says so:
  /// what was chosen, and whether the server had to choose. Set from
  /// `game:variationSelected` or from seeing the snapshot go from selecting to
  /// selected — whichever comes first, once per hand — so a client that
  /// missed the event still announces it.
  VariationNews? variationAnnounced;
  Timer? _variationTimer;

  /// The hand [variationAnnounced] was last raised for, so the event and the
  /// snapshot that repeats it make one announcement between them.
  int? _variationAnnouncedFor;

  /// How long the announcement stands in the middle of the table.
  static const variationAnnouncedFor = Duration(seconds: 3);

  /// The 5-Card verdict, for the few seconds the table shows it (owner, 19 Sep
  /// 2026: "show user you selected best combination… if not… you selected this
  /// and best combination was that"). Raised once per hand, from the snapshot
  /// itself — the moment `you.hand` stops asking and starts answering — so a
  /// player who reconnects into a decided hand is not told twice and one whose
  /// window the server closed is told at all.
  PickNews? pickAnnounced;
  Timer? _pickTimer;
  int? _pickAnnouncedFor;

  /// How long the verdict stands.
  static const pickAnnouncedFor = Duration(seconds: 5);

  /// Raises the verdict when a hand's choice has just been made.
  void _announcePick(OwnHand? hand) {
    final no = room?.handNo;
    if (no == null || hand == null || hand.picking || hand.pickedBy.isEmpty) {
      return;
    }
    if (_pickAnnouncedFor == no) return;
    _pickAnnouncedFor = no;
    pickAnnounced = (
      played: hand.best,
      best: hand.bestPossible,
      wasBest: hand.pickedTheBest,
      byTimeout: hand.pickedBy == 'TIMEOUT',
    );
    _pickTimer?.cancel();
    _pickTimer = Timer(pickAnnouncedFor, () {
      pickAnnounced = null;
      notifyListeners();
    });
  }

  /// The variation the hand on the table was played under, and the card that
  /// was turned up for it, remembered past the hand's end: the snapshot drops
  /// its variation block the moment the hand is over, but the winner is
  /// celebrated — and the hands lie face up — for seconds after, and "why did
  /// THAT win?" is asked exactly then. Dropped with the celebration.
  String? lastVariation;
  String? lastTurnUp;

  /// What the table's tag names: the live hand's variation, or the one the
  /// hand still being celebrated was played under.
  String? get shownVariation => variation?.selected ?? lastVariation;

  /// The turned-up card that goes with [shownVariation]; null unless that is
  /// Joker or Hukam.
  String? get shownTurnUp {
    final v = shownVariation;
    if (!Variation.usesTurnUp(v)) return null;
    return variation?.selected != null ? variation?.turnUp : lastTurnUp;
  }

  // ----------------------------------------------------------------- poker

  /// A poker room's own block, straight from the table snapshot — never a
  /// copy kept here — so a reconnect mid-hand rebuilds the board, the pots,
  /// the turn and the keys from the one snapshot it is sent. Null on every
  /// Teen Patti table.
  PokerState? get poker => room?.poker;

  bool get isPokerTable => room?.isPoker == true;

  /// The moves the server offers this player right now, and only on their
  /// turn: `you.options` at a poker table. Null off turn.
  PokerOptions? get pokerOptions =>
      isPokerTable ? room?.you?.pokerOptions : null;

  bool get myPokerTurn => pokerOptions != null;

  /// A [PokerStreet]; empty between hands and on a Teen Patti table.
  String get pokerStreet => poker?.street ?? PokerStreet.none;

  /// The board, in the order dealt; empty when there is none.
  List<String> get community => poker?.community ?? const [];

  /// The main pot first, then the side pots.
  List<PokerPot> get pots => poker?.pots ?? const [];

  // The keys, each lit only when the server offers the move. A key that
  // refuses on tap is worse than a dark one.
  bool get canFold => pokerOptions?.fold == true;
  bool get canCheck => pokerOptions?.check == true;
  bool get canCall => pokerOptions?.call == true;
  bool get canPokerBet => pokerOptions?.bet == true;
  bool get canPokerRaise => pokerOptions?.raise == true;
  bool get canPokerBetOrRaise => canPokerBet || canPokerRaise;
  bool get canPlay => pokerOptions?.play == true;
  bool get canDraw => pokerOptions?.draw == true;

  /// Whether the bet key says Raise rather than Bet: on turn the server's
  /// word, off turn whether anyone has bet this street.
  bool get pokerBetIsRaise {
    final o = pokerOptions;
    if (o != null) return o.raise && !o.bet;
    return (poker?.currentBet ?? 0) > 0;
  }

  /// The bet step: the big blind on a blinds game, the ante on the others,
  /// the boot when the block says neither.
  int get pokerBetStep {
    final p = poker;
    if (p == null) return 0;
    if (p.bigBlind > 0) return p.bigBlind;
    if (p.ante > 0) return p.ante;
    return room?.bootAmount ?? 0;
  }

  /// The least and most the bet key may place, as the server offers them —
  /// the bet's ends when a bet is offered, the raise's when a raise is. Off
  /// turn the ends are worked out from the block, so the dark key still
  /// reads a sensible figure: the big blind (or ante) to open, else the bet
  /// to match plus the least raise.
  (int, int) get pokerBetRange {
    final o = pokerOptions;
    if (o != null) {
      if (o.bet) return (o.minBet, o.maxBet);
      if (o.raise) return (o.minRaise, o.maxRaise);
    }
    final p = poker;
    final chips = room?.you?.chips ?? 0;
    final mine = room?.you?.streetBet ?? 0;
    if (p == null) return (0, 0);
    final min = p.currentBet > 0
        ? p.currentBet + (p.minRaise > 0 ? p.minRaise : pokerBetStep)
        : pokerBetStep;
    final max = mine + chips;
    return (min.clamp(0, max), max);
  }

  /// Where the stepper was last put, as a total street bet; null means the
  /// least the server allows. Reset with every turn and every deal.
  int? _pokerBetTo;

  /// What the bet / raise key will place: the stepper's figure, held between
  /// the server's two ends.
  int get pokerBetAmount {
    final (min, max) = pokerBetRange;
    if (max <= min) return min;
    return (_pokerBetTo ?? min).clamp(min, max);
  }

  bool get canPokerStepDown => myPokerTurn && pokerBetAmount > pokerBetRange.$1;
  bool get canPokerStepUp => myPokerTurn && pokerBetAmount < pokerBetRange.$2;

  /// Moves the bet by one step — the big blind or the ante — and never past
  /// either end.
  void pokerStepBet(int direction) {
    final (min, max) = pokerBetRange;
    if (max <= min) return;
    final step = pokerBetStep > 0 ? pokerBetStep : 1;
    _pokerBetTo = (pokerBetAmount + direction * step).clamp(min, max);
    notifyListeners();
  }

  /// Puts the bet at [amount] (a slider), held between the server's ends.
  void pokerBetTo(int amount) {
    final (min, max) = pokerBetRange;
    _pokerBetTo = max <= min ? min : amount.clamp(min, max);
    notifyListeners();
  }

  /// What a call costs right now: the server's figure on turn, the bet to
  /// match less what this seat already has in, off it.
  int get pokerCallAmount {
    final o = pokerOptions;
    if (o != null) return o.callAmount;
    final p = poker;
    if (p == null) return 0;
    final owed = p.currentBet - (room?.you?.streetBet ?? 0);
    final chips = room?.you?.chips ?? 0;
    return owed.clamp(0, chips);
  }

  /// What Play costs in 3-Card Poker: the ante again.
  int get pokerPlayAmount {
    final o = pokerOptions;
    if (o != null && o.playAmount > 0) return o.playAmount;
    return poker?.ante ?? room?.bootAmount ?? 0;
  }

  /// 5-Card Draw: the cards this player has marked to exchange, by code.
  /// Cleared with every deal and whenever the street is not the draw.
  final Set<String> discardSelection = {};

  /// How many cards may be exchanged: the server's figure on turn, the
  /// table's otherwise.
  int get maxDiscards => pokerOptions?.maxDiscards ?? poker?.maxDiscards ?? 0;

  /// Marks or unmarks [code] for the draw. Refuses a sixth card past the
  /// table's limit rather than letting the server refuse the whole draw.
  void toggleDiscard(String code) {
    if (!discardSelection.remove(code)) {
      if (discardSelection.length >= maxDiscards) return;
      discardSelection.add(code);
    }
    notifyListeners();
  }

  void clearDiscards() {
    if (discardSelection.isEmpty) return;
    discardSelection.clear();
    notifyListeners();
  }

  /// The finished hand as `poker:handEnded` (or `poker:showdown`) carried it,
  /// while its celebration is up. The snapshot's own copy (`poker.result`)
  /// stays until the next deal, so this is only a head start on it.
  PokerResult? _pokerResultNews;

  /// The hand whose result has been celebrated, by the table's hand number,
  /// so the event and the snapshot that repeats it start one celebration
  /// between them — and a lone winner's result, which the snapshot keeps for
  /// as long as nobody else sits down, is not celebrated again on every
  /// snapshot after.
  int? _pokerCelebratedFor;

  /// True from the hand's end until the next deal is due (or six seconds):
  /// the reveals are on the felt, the winners are marked and the pot flies.
  bool pokerCelebrating = false;

  /// The finished poker hand to draw: the event's copy, else the snapshot's.
  PokerResult? get pokerResult => _pokerResultNews ?? room?.poker?.result;

  /// Whether the finished hand is on show: cards face up, winners marked.
  bool get pokerShowing => pokerCelebrating && pokerResult != null;

  /// What a snapshot says of a finished poker hand: a result seen for the
  /// first time this hand starts the celebration, exactly as the event does,
  /// so a reconnect into the celebration still gets one — timed to the next
  /// deal the snapshot names, or six seconds.
  void _followPoker(RoomState s, {required bool newHand}) {
    if (newHand) _pokerCelebratedFor = null;
    if (s.poker?.street != PokerStreet.draw) discardSelection.clear();
    final result = s.poker?.result;
    if (result == null || _pokerCelebratedFor == s.handNo) return;
    // The server sends `poker:showdown`, settles, sends `poker:handEnded`
    // and only then the snapshot that repeats the result — so a client that
    // was connected has already celebrated this hand (above) and skips here;
    // one that reconnected into the celebration gets it from the snapshot
    // alone, timed to the deal the snapshot names.
    _pokerCelebratedFor = s.handNo;
    pokerCelebrating = true;
    _notePokerWinners(result, s);
    _armCelebration(s.startsAt);
  }

  /// `poker:showdown` and `poker:handEnded`: the reveal, then the result.
  @visibleForTesting
  void handlePokerShowdown(PokerShowdownNews news) {
    final r = room;
    if (r == null) return;
    // The showdown frame comes first with the reveals; the hand-ended frame
    // brings the pots and the winners. The later one is the fuller, and
    // either alone is enough to draw the hand — but a reveal frame must
    // never REPLACE a hand already drawn in full, or a client that had the
    // snapshot first would lose the pots it was about to pay out.
    final held = pokerResult;
    if (news.ended || held == null || held.reveals.isEmpty) {
      _pokerResultNews = news.result;
    }
    _pokerCelebratedFor = r.handNo;
    pokerCelebrating = true;
    _notePokerWinners(news.result, r);
    if (news.ended || showdownResult.isEmpty) {
      // A marker rather than a sentence: the poker felt draws the result
      // from [pokerResult], and this only says a hand has ended.
      showdownResult = news.reason.isEmpty ? 'poker' : news.reason;
    }
    _armCelebration(news.nextHandAt);
    notifyListeners();
    if (news.ended) unawaited(refreshUser());
  }

  /// For the sounds and the fireworks: whether this player is among the
  /// winners, and what they took — from the event or from the snapshot,
  /// whichever said so first.
  void _notePokerWinners(PokerResult result, RoomState r) {
    final me = user?.id;
    final mine = result.wonBy(me);
    final first = result.winners.firstOrNull;
    if (mine > 0 && me != null) {
      winnerId = me;
      winnerName = user?.displayName ?? '';
      winnerPot = mine;
    } else if (first != null) {
      winnerId = first.userId;
      winnerName =
          r.seats
              .where((seat) => seat.userId == first.userId)
              .map((seat) => seat.displayName)
              .firstOrNull ??
          '';
      winnerPot = first.amount;
    }
    if (showdownResult.isEmpty) {
      showdownResult = result.reason.isEmpty ? 'poker' : result.reason;
    }
  }

  /// The hand this player's clock folded, so the felt can say so for the
  /// rest of it — a toast is one glance long, and the fold is the one move
  /// at the table the player did not make. Null until it happens; cleared
  /// with the next deal.
  int? pokerTimedOutHand;

  /// A poker move as the room hears it. The snapshot already says what each
  /// move did; this only tells the player whose clock ran out that it did.
  @visibleForTesting
  void handlePokerAction(PokerActionNews a) {
    final r = room;
    if (r == null) return;
    if (a.reason == 'timeout' &&
        a.action == PokerAction.fold &&
        a.userId == user?.id) {
      pokerTimedOutHand = r.handNo;
      notice = t.pokerTimedOut;
      notifyListeners();
    }
  }

  /// Drops what a poker hand left behind, for a deal or a table that is
  /// over. The celebration is cleared by [_clearCelebration].
  void _clearPokerHand() {
    _pokerCelebratedFor = null;
    _pokerBetTo = null;
    pokerTimedOutHand = null;
    discardSelection.clear();
  }

  void pokerFold() => _conn.pokerAct(PokerAction.fold);
  void pokerCheck() => _conn.pokerAct(PokerAction.check);
  void pokerCall() => _conn.pokerAct(PokerAction.call);

  /// Bets the stepper's figure — a bet when nobody has bet this street, a
  /// raise TO that figure when somebody has. The server offers exactly one of
  /// the two, and its refusal is a toast like any other.
  void pokerBet() => _conn.pokerAct(PokerAction.bet, amount: pokerBetAmount);
  void pokerRaise() =>
      _conn.pokerAct(PokerAction.raise, amount: pokerBetAmount);
  void pokerBetOrRaise() => pokerBetIsRaise ? pokerRaise() : pokerBet();
  void pokerPlay() => _conn.pokerAct(PokerAction.play);

  /// Exchanges [codes] — or stands pat with none — and drops the selection,
  /// which the snapshot that follows would drop anyway.
  void pokerDraw(List<String> codes) {
    _conn.pokerAct(PokerAction.draw, cards: codes);
    discardSelection.clear();
    notifyListeners();
  }

  /// Draws whatever is marked.
  void pokerDrawSelected() => pokerDraw(discardSelection.toList());

  String? _token;
  String _deviceId = '';
  Timer? _ticker;

  /// Watches the worn picture's rental while the player is in the lobby.
  Timer? _rentalWatch;

  /// Which rung of the bet ladder the stepper is on.
  int raiseIndex = 0;

  bool get connected => _conn.isConnected;

  /// True from the moment an established connection drops until it is back.
  /// Unlike `!connected` it is false before the first connection, so nothing
  /// says "reconnecting" to a session that has not connected yet.
  bool offline = false;

  /// The server cannot be reached (owner, 28 Sep 2026: "when app shows
  /// service not available, it shows loader screen until it gets
  /// connected"): the whole app waits under the game's loader (main.dart's
  /// service veil) instead of saying "Service not available" in a toast.
  /// Raised by a handshake that got no answer ([GameConnection.unreachable]),
  /// a request that could not get through, or a start that could not reach
  /// the server ([reportUnreachable]); lowered the moment the socket
  /// connects or — with none expected — the server answers one of the checks
  /// made every [serviceProbeEvery] meanwhile.
  bool serviceDown = false;

  /// How often the server is asked, while it cannot be reached, whether it
  /// is back: `GET /api/app-config`, public, never gated and cheap.
  static const serviceProbeEvery = Duration(seconds: 3);
  Timer? _serviceProbe;
  bool _probing = false;
  Completer<void>? _serviceReachable;

  /// Something could not reach the server: up goes the loader, and the
  /// server is asked every [serviceProbeEvery] until it answers.
  void reportUnreachable() {
    if (_disposed) return;
    _serviceProbe ??= Timer.periodic(
      serviceProbeEvery,
      (_) => unawaited(_probeService()),
    );
    if (serviceDown) return;
    serviceDown = true;
    notifyListeners();
  }

  Future<void> _probeService() async {
    if (_probing || _disposed) return;
    _probing = true;
    try {
      await _api.appConfig();
    } catch (_) {
      // Still no answer; the next tick asks again.
      return;
    } finally {
      _probing = false;
    }
    // The server answers. A session whose socket is still trying waits for
    // it — socket_io_client keeps trying on its own, and its connect lowers
    // the loader; with no socket expected the server's answer is enough.
    if (_conn.hasSocket && !_conn.isConnected) return;
    _serviceBack();
  }

  /// The server can be reached again: the loader comes down, and a start or
  /// a maintenance check that was waiting for it carries on.
  void _serviceBack() {
    _serviceProbe?.cancel();
    _serviceProbe = null;
    final waiting = _serviceReachable;
    _serviceReachable = null;
    waiting?.complete();
    if (!serviceDown) return;
    serviceDown = false;
    notifyListeners();
    // The maintenance screen's Try again found no server: it asks again now,
    // unless a start that is itself waiting will.
    if (screen == Screen.maintenance && waiting == null) {
      unawaited(retryAppGate());
    }
  }

  /// Completes once the server can be reached again ([_serviceBack]).
  Future<void> _whenReachable() =>
      (_serviceReachable ??= Completer<void>()).future;

  /// Whether the viewer is playing a hand right now, so leaving or switching
  /// would pack their cards and leave their stake in the pot.
  bool get inLiveHand =>
      room?.state == TableState.betting &&
      room?.you?.status == SeatState.active;

  /// The Teen Patti ladder on this player's turn. Null at a poker table
  /// whatever the snapshot says: none of the Teen Patti keys may light there
  /// (the poker keys read [pokerOptions]).
  TurnOptions? get options => isPokerTable ? null : room?.you?.options;

  /// Whether it is this player's turn, whichever game the table plays.
  bool get myTurn => isPokerTable ? myPokerTurn : options != null;

  // ------------------------------------------------------------- lifecycle

  /// The splash holds at least this long, so the icon is seen as a moment
  /// rather than a flicker on a fast network.
  static const minSplash = Duration(milliseconds: 1400);

  /// Signs catalogue locations for the picture cache (POST /api/assets/sign)
  /// with this session's token. Signed out, nothing is signed: the files wait
  /// for a session, as the routes that name them do.
  Future<SignedAssets> _signAssets(List<String> locations) async {
    final token = _token;
    if (token == null) return SignedAssets.none;
    return _api.signAssets(token, locations);
  }

  Future<void> start() async {
    final splashShownAt = DateTime.now();
    _startPurchases();
    final prefs = await SharedPreferences.getInstance();

    // Guest play is keyed to a device id, so chips survive a restart.
    _deviceId = prefs.getString('deviceId') ?? const Uuid().v4();
    await prefs.setString('deviceId', _deviceId);

    themeMode = ThemePreference.read(prefs);
    // Read before the server is asked anything: the version gate judges this
    // build by the version it declares (net/app_version.dart).
    await _readPackageInfo();
    lang = AppLang.fromCode(prefs.getString('lang'));
    numbers = NumberSystem.fromName(prefs.getString('numbers'));
    _publishNumberFormat();
    restoreQuickOrder(prefs);

    // The menu this server last described, before anything can draw the
    // lobby: the first frame after the splash is the phone's copy, not
    // GameConfig.fallback. session:ready replaces it moments later if the
    // server has changed its tables since.
    restoreCachedMenu(prefs);

    _wire();
    // The catalogue's art is in a private bucket (owner, 1 Oct 2026): the
    // picture cache asks the server to sign each file it does not have yet.
    PictureCache.signer = _signAssets;
    unawaited(_loadPictures());

    // Asked alongside the rest of startup rather than before it: the check is
    // a Play round trip, and making the splash wait on it would add its
    // latency to every launch for the sake of an answer that is usually "no".
    final updateCheck = _update.check();

    // The app version gate (owner, 28 Sep 2026), before the player is asked
    // for or restored: a build the server will not let play — too old, or the
    // game in maintenance — stops here, on its screen, and never reaches the
    // lobby. Unreachable (offline, slow), the app carries on as it always did:
    // the server refuses an unsupported build at every door regardless.
    final gate = await _fetchAppGate();
    if (gate != null && gate.blocks) appGate = gate;
    // A saved session goes straight to the lobby.
    final next = gate != null && gate.blocks
        ? _gateScreen(gate)
        : await _restoreSession(prefs);

    updateStatus = await updateCheck;

    final shownFor = DateTime.now().difference(splashShownAt);
    if (shownFor < minSplash) await Future<void>.delayed(minSplash - shownFor);
    // A table snapshot may already have arrived and moved us on; only the
    // splash itself is replaced. A refusal heard meanwhile — the restored
    // session's `me`, or its socket's handshake — outranks everything.
    if (screen == Screen.splash) {
      final refused = appGate;
      screen = refused != null && refused.blocks ? _gateScreen(refused) : next;
    }
    // The optional update — the server's newer version, or Play's own nudge
    // — is offered once the app is up, and once per announcement.
    _offerSoftUpdate(prefs, gate);

    // One second is enough for a countdown that shows seconds.
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => notifyListeners(),
    );
    _rentalWatch = Timer.periodic(
      const Duration(seconds: 7),
      (_) => _checkRental(),
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
  /// exists to prevent. The build floor (`minClientBuild`) and the version
  /// gate's refusals all come to the one screen ([_appGateRefused]).
  void _forceUpdate() => _appGateRefused(
    AppGateVerdict(
      AppGateStatus.forceUpdate,
      storeUrl: _announced?.storeUrl,
      minimumVersion: _announced?.minimumVersion,
    ),
  );

  /// The screen a blocking verdict stands on.
  static Screen _gateScreen(AppGateVerdict v) =>
      v.status == AppGateStatus.maintenance
      ? Screen.maintenance
      : Screen.update;

  /// Reads this build's version from the package (pubspec's `version`) and
  /// declares it — with the platform — on every request and in the socket's
  /// handshake. Bounded: a plugin that does not answer leaves the build
  /// undeclared rather than holding the splash.
  Future<void> _readPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform().timeout(
        const Duration(seconds: 2),
      );
      appVersion = '${info.version} (${info.buildNumber})';
      _buildNumber = int.tryParse(info.buildNumber) ?? 0;
      _installedVersion = info.version;
    } catch (_) {}
    _declareBuild();
  }

  /// Hands this build's platform and version to the REST client and the
  /// socket — both, or neither: a build that cannot read its own version
  /// declares nothing, rather than an app platform with no version, which a
  /// server with a minimum set would have to refuse.
  void _declareBuild() {
    final platform = appPlatformName();
    final version = SemVer.tryParse(_installedVersion) != null
        ? _installedVersion
        : null;
    final declared = platform != null && version != null;
    _api
      ..appPlatform = declared ? platform : null
      ..appVersion = declared ? version : null;
    _conn
      ..appPlatform = declared ? platform : null
      ..appVersion = declared ? version : null;
  }

  /// Asks the server what this build may do (`GET /api/app-config`). Null
  /// when it could not be asked — offline, slow, refused — and the app
  /// carries on as it does offline; a server that predates the gate (404) is
  /// NORMAL, its build floor still in force through session:ready.
  Future<AppGateVerdict?> _fetchAppGate() async {
    try {
      final config = await _api.appConfig();
      if (config == null) return const AppGateVerdict(AppGateStatus.normal);
      return _announced = evaluateAppConfig(
        config,
        platform: _api.appPlatform,
        version: _api.appVersion,
      );
    } catch (_) {
      return null;
    }
  }

  /// A saved session, restored: `me`, then the socket, behind the splash
  /// (or the maintenance screen's Try again). The lobby when it holds, the
  /// sign-in screen when it does not. A refusal from the version gate is no
  /// verdict on the session: the token is kept for after the update or the
  /// maintenance, and the caller puts up the gate's screen.
  Future<Screen> _restoreSession(SharedPreferences prefs) async {
    final saved = prefs.getString('token');
    if (saved == null || saved.isEmpty) return Screen.login;
    _token = saved;
    try {
      user = await _api.me(saved);
      _seeStanding();
      unawaited(_loadPictures());
      // Every sign-in asks for the table catalogue again — a restored
      // session is a sign-in too — and a 304 makes that cheap.
      unawaited(_loadTableConfig());
      unawaited(loadLuckyDraw());
      // The ladder says where the player's level starts, which the
      // lobby's level bar measures from (owner, 27 Sep 2026).
      if (levelLadder == null) unawaited(loadLevelLadder());
      // The lobby's Friends key counts the requests waiting, read at
      // every sign-in (owner, 26 Sep 2026).
      unawaited(friends.refreshBadge());
      // An install that signed in before the statement existed meets it on
      // its next launch, once, like everyone else.
      await loadConsent(prefs);
      // If the app was closed mid-hand the seat may still be held, or the
      // table remembered; either way the answer comes with the connection,
      // which starts now, behind the splash.
      _beginResume();
      _conn.connect(saved);
      return Screen.lobby;
    } on AppGateRefusal {
      return Screen.login;
    } catch (e) {
      if (e is ApiException && (e.status ?? 0) < 500) {
        // The server answered and turned the token down: expired or revoked
        // — back to the sign-in screen.
        _token = null;
        await prefs.remove('token');
        return Screen.login;
      }
      // No answer — the network, a timeout, a gateway with no game behind it
      // (5xx): the token is kept, the app waits for the server under its
      // loader (owner, 28 Sep 2026), and the session is restored once it
      // answers. This used to drop the token too, signing the player out
      // over a network blip.
      reportUnreachable();
      await _whenReachable();
      if (_disposed) return Screen.login;
      return _restoreSession(prefs);
    }
  }

  /// The server will not let this build play: too old ([Screen.update]) or
  /// the game in maintenance ([Screen.maintenance]) — from a REST refusal,
  /// the socket handshake, the start-up check or the legacy build floor, all
  /// to the same screens. The socket is let go and nothing reconnects it —
  /// not the background-return, not a seat check — while the TOKEN IS KEPT:
  /// this is no verdict on the account, and after the maintenance (Try again)
  /// or the update the player is where they were. On a cold start the splash
  /// finishes first, and [start] puts the screen up.
  void _appGateRefused(AppGateVerdict v) {
    appGate = v;
    softUpdate = null;
    _conn.disconnect();
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    _closedForBackground = false;
    _seatCheck?.cancel();
    _resumeTimer?.cancel();
    resuming = false;
    room = null;
    seatedAt = null;
    chat.clear();
    _clearBubbles();
    _clearSideshow();
    _clearVariation();
    _clearMissile();
    _clearCelebration();
    _clearPokerHand();
    switching = false;
    if (screen != Screen.splash) screen = _gateScreen(v);
    notifyListeners();
  }

  /// A socket refusal or a REST 426 / 503, as the tests deliver them.
  @visibleForTesting
  void handleAppGate(AppGateVerdict v) => _appGateRefused(v);

  /// The maintenance screen's Try again: asks the server again, and — the
  /// game open once more — takes the player where they were (a saved session
  /// to the lobby and its table, else the sign-in screen). Still closed, or
  /// now too old, the right screen stays; unreachable, the screen stays and
  /// says so.
  Future<void> retryAppGate() async {
    if (checkingAppGate) return;
    checkingAppGate = true;
    notifyListeners();
    final gate = await _fetchAppGate();
    if (gate == null) {
      // No server: the loader until it answers, then this asks again
      // ([_serviceBack]).
      checkingAppGate = false;
      notifyListeners();
      reportUnreachable();
      return;
    }
    if (gate.blocks) {
      checkingAppGate = false;
      appGate = gate;
      screen = _gateScreen(gate);
      notifyListeners();
      return;
    }
    appGate = null;
    final prefs = await SharedPreferences.getInstance();
    final next = await _restoreSession(prefs);
    checkingAppGate = false;
    final refused = appGate;
    screen = refused != null && refused.blocks ? _gateScreen(refused) : next;
    notifyListeners();
    _offerSoftUpdate(prefs, gate);
  }

  /// Puts up the optional update once per announcement: the server's newer
  /// version (SOFT_UPDATE), or — Android — Play's own report of a newer
  /// build, which since the version gate is a nudge, never a block (only the
  /// server's minimum blocks). Answered Later, it is not asked again for the
  /// same announcement ([SoftUpdateMemory]).
  void _offerSoftUpdate(SharedPreferences prefs, AppGateVerdict? gate) {
    if (gate != null && gate.blocks) return;
    if (appGate?.blocks ?? false) return;
    String? key;
    AppGateVerdict? offer;
    if (gate != null && gate.status == AppGateStatus.softUpdate) {
      key = 'latest:${gate.latestVersion}';
      offer = gate;
    } else if (updateStatus != UpdateStatus.none) {
      key = 'play:$_installedVersion';
      offer = AppGateVerdict(
        AppGateStatus.softUpdate,
        storeUrl: gate?.storeUrl ?? _announced?.storeUrl,
      );
    }
    if (key == null || !SoftUpdateMemory.shouldOffer(prefs, key)) return;
    softUpdate = offer;
    _softUpdateKey = key;
    notifyListeners();
  }

  /// Later, on the optional update: put away until something newer is
  /// announced.
  Future<void> laterSoftUpdate() async {
    final key = _softUpdateKey;
    softUpdate = null;
    _softUpdateKey = null;
    notifyListeners();
    if (key != null) {
      await SoftUpdateMemory.later(await SharedPreferences.getInstance(), key);
    }
  }

  void _wire() {
    _subs.addAll([
      _conn.onSession.listen((s) {
        user = s.user;
        _seeStanding();
        final refetch = handleSessionMenu(s.config);
        _snapshotSinceSession = false;
        // The server's own floor, checked the moment it tells us what it is.
        // Play's update check answers "is there something newer"; this answers
        // "can this build still be talked to", which is the question that
        // matters when the wire has moved on — and only the server knows it.
        if (_belowMinimumBuild(config.minClientBuild)) {
          _forceUpdate();
          return;
        }
        // The server is enforcing a catalogue other than the one held: its
        // session menu is on screen meanwhile, and the full one is fetched.
        if (refetch) unawaited(_loadTableConfig());
        // Every session — a cold start, a sign-in, a reconnect — hands Play's
        // owned (paid, not yet banked) purchases to the server again: a credit
        // that failed on the network, or a purchase finished while the app was
        // closed, lands now. The server is idempotent on the purchase token.
        unawaited(purchases.redeliver());
        // The reward programs (owner, 30 Sep 2026): every session in the
        // lobby reads today's standing and puts a popup up for each program
        // whose day is still to collect, so a phone that only
        // reconnected across midnight is offered the new day. A cold start
        // reads once its lobby is up (_RewardsChip); at a table the lobby
        // asks when the player is back. Collecting is the player's tap.
        if (room == null && !resuming) unawaited(loadRewardPrograms());
        _snapshotSinceSession = false;
        if (!resuming && room != null) {
          final offer = s.resume;
          if (offer != null) {
            // The connection was down long enough for the seat to lapse, but
            // the table is still there: sit back down at it, as a cold start
            // does. It dropped the player to the lobby with "the table closed"
            // while the table played on (QA PIX-3, 14 Sep 2026). The server
            // offers this once, so it is taken now or not at all.
            _conn.joinByCode(offer.code);
            _armSeatCheck(after: const Duration(seconds: 4));
          } else {
            _armSeatCheck();
          }
        }
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
      _conn.onState.listen(handleState),
      // Heard just before the showdown news of the same hand-ended frame, so
      // the celebration it starts already knows what the winner paid.
      _conn.onHandTax.listen(handleHandTax),
      _conn.onPlayerLevel.listen(handlePlayerLevel),
      _conn.onShowdown.listen(handleShowdown),
      // Requirements 31 and 32: idled out, or out of chips for this table.
      // Shown out is not the same as leaving, so the reason is carried back to
      // the lobby rather than the player simply finding themselves there.
      _conn.onKicked.listen((kick) {
        notice = kickText(kick.reason, kick.message);
        switching = false;
        handleBackToLobby();
      }),

      _conn.onLeft.listen((_) {
        // Mid-switch, the next table's snapshot is already on its way, so a
        // room closing behind us is not a reason to walk back to the lobby.
        if (switching) return;
        handleBackToLobby();
      }),
      _conn.onSideshowAsked.listen((_) {
        // The request itself arrives in the table snapshot that follows; this
        // is only the cue to tick the clock the prompt counts down.
        notifyListeners();
      }),
      _conn.onSideshowReveal.listen(handleSideshowReveal),
      _conn.onSideshowDone.listen(handleSideshowDone),
      _conn.onVariationSelecting.listen((_) {
        // As with a sideshow request: the window itself is in the snapshot
        // that follows, and this is only the cue to start its clock.
        notifyListeners();
      }),
      _conn.onVariationSelected.listen(handleVariationSelected),
      _conn.onVariationAtShowdown.listen(handleVariationAtShowdown),
      _conn.onAction.listen(handleTableAction),
      _conn.onPokerShowdown.listen(handlePokerShowdown),
      // The cards themselves are in the snapshot that follows; this is only
      // the cue that they changed (a draw).
      _conn.onPokerCards.listen((_) => notifyListeners()),
      _conn.onPokerAction.listen(handlePokerAction),
      _conn.onChat.listen(handleChat),
      _conn.onChatHistory.listen((h) {
        // History is re-sent on a reconnect to the SAME table, where the
        // blocks are still standing, so it is filtered like a live message.
        chat
          ..clear()
          ..addAll(h.where((m) => !isBlocked(m.userId)));
        notifyListeners();
      }),
      _conn.onFriendRequest.listen(handleFriendRequest),
      _conn.onFriendAccepted.listen(handleFriendAccepted),
      _conn.onError.listen((e) {
        // No answer from the server at all: the app waits for it under the
        // loader, never a toast (owner, 28 Sep 2026).
        if (e.code == GameConnection.unreachable) {
          reportUnreachable();
          return;
        }
        // The server turned this session's token down at the handshake —
        // expired, revoked, or issued by another server: out to the sign-in
        // screen, as a start with such a token goes. Never the loader (this
        // session will not connect however long it waits), and no longer the
        // "Service not available" toast over a lobby that could do nothing.
        if (e.code == GameConnection.refused) {
          unawaited(signOut());
          return;
        }
        // The account was disabled while signed in: out, and the popup.
        if (e.code == accountDisabledCode) {
          _accountWasDisabled();
          return;
        }
        // Signed in on another device: out, and the popup that says so.
        if (e.code == sessionReplacedCode) {
          _sessionWasReplaced();
          return;
        }
        // A Force Sideshow reads these two refusals from its ack, which the
        // server sends first: no_hammers turns into an offer of the store and
        // persist_failed into a retry. Their game:error copies would only put
        // a toast over that.
        if (_forceQuiet(e.code) || _missileQuiet(e.code)) return;
        notice = refusalText(e.code, e.message);
        // A refused rejoin is an answer too: there is nothing to resume.
        if (resuming) _endResume();
        // An emoji refused as locked, retired or unknown means the catalogue
        // this phone holds is out of date — a rental ran out, a row was
        // retired — so the emoji page is re-read to show it as it now is.
        if (_emojiStale(e.code)) unawaited(_loadEmojis());
        notifyListeners();
      }),
      _conn.onConnected.listen((up) {
        offline = !up;
        if (up) _serviceBack();
        notifyListeners();
      }),
      // The handshake refused this build: the update or maintenance screen,
      // and no reconnect.
      _conn.onAppGate.listen(_appGateRefused),
    ]);
  }

  /// A chat line from the table — words, or an emoji (owner, 26 Sep 2026).
  ///
  /// A blocked player's line is dropped here, before it can raise a badge,
  /// bubble over their seat or sit in the drawer. The server is not told and
  /// keeps sending: blocking is this viewer's own view of the table, not a
  /// report.
  @visibleForTesting
  void handleChat(ChatMessage m) {
    if (isBlocked(m.userId)) return;
    chat.add(m);
    // The room keeps at most a hundred messages, and so does this.
    if (chat.length > 100) chat.removeAt(0);
    // Only other players' lines are unread. The server echoes the viewer's
    // own message back, and it lands after the chat drawer has closed on
    // sending (a quick message never opens the chat drawer at all), so
    // counting it raised a badge for something they had just sent.
    if (m.userId != user?.id) unreadChat++;

    // An emoji plays over the sender's seat, in the bubble's place, for a
    // few seconds — on every phone at the table, the sender's too — and a
    // second one sent while it plays waits for it, as a line of words does.
    if (m.isEmoji) {
      if (emojiShown.containsKey(m.userId)) {
        _emojiWaiting[m.userId] = m;
      } else {
        _showEmoji(m);
      }
      notifyListeners();
      return;
    }

    // Show it over the sender's seat for a moment, so a table that is
    // talking is visible without opening the chat. If their last line is
    // still up, this one waits its turn rather than cutting it short.
    //
    // At most ONE line waits. A bubble holds for 8s and a player may send
    // every 4s, so an unbounded queue drains slower than it fills and the
    // bubble drifts further behind real time with every message — a chatty
    // player would end up with the felt showing something they said a minute
    // ago. Keeping only the newest bounds how stale a bubble can be to one
    // hold. The full conversation is in the chat drawer, in order and
    // complete; the bubble is a glance, not a log.
    if (saidRecently.containsKey(m.userId)) {
      _bubbleQueue[m.userId] = [m];
    } else {
      _showBubble(m);
    }

    notifyListeners();
  }

  /// `friend:request`: somebody has just asked this player to be friends
  /// (owner, 26 Sep 2026: "do this async") — in the lobby or at a table.
  ///
  /// The request joins the ones waiting ([FriendsState.requestArrived]) and
  /// the toast says who. At a table the sender sits at, it also says where to
  /// answer — their seat, which wears the request's badge now. A player this
  /// viewer has blocked at the table is not heard from, a request included:
  /// no toast, though the request stands, on the Friends page and on the
  /// sender's seat.
  @visibleForTesting
  void handleFriendRequest(FriendRequestItem request) {
    friends.requestArrived(request);
    final sender = request.player;
    if (isBlocked(sender.userId) || sender.displayName.isEmpty) return;
    notice = seatedHere(sender.userId)
        ? t.friendRequestAtTable(sender.displayName)
        : t.friendRequestArrived(sender.displayName);
    notifyListeners();
  }

  /// `friend:accepted`: a request this player sent has been accepted — they
  /// are friends now ([FriendsState.requestAccepted]), and the toast says who.
  @visibleForTesting
  void handleFriendAccepted(FriendAccepted accepted) {
    friends.requestAccepted(accepted);
    final name = accepted.player.displayName;
    if (name.isEmpty) return;
    notice = t.friendAcceptedYours(name);
    notifyListeners();
  }

  /// Whether [userId] sits at the table this player is at.
  bool seatedHere(String? userId) {
    final r = room;
    if (r == null || screen != Screen.table) return false;
    if (userId == null || userId.isEmpty) return false;
    return r.seats.any((s) => s.occupied && s.userId == userId);
  }

  /// A hand's reveal, or its end.
  ///
  /// Held back while a missile volley is still in the air: the server sends
  /// the showdown in the same breath as the missile, and turning the cards over
  /// before the missiles land would show the result the volley is on its way
  /// to deliver. The held ones go out, in order, at the last impact.
  @visibleForTesting
  void handleShowdown(ShowdownNews s) {
    if (missileHoldsReveal) {
      _heldShowdowns.add(s);
      return;
    }
    _applyShowdown(s);
  }

  void _applyShowdown(ShowdownNews s) {
    // The hand is over, so a sideshow reveal still on its five seconds is
    // dropped rather than left to stack under the winner's banner. A hammer
    // still in the air goes with it, but the news it was carrying is still
    // news.
    final hammerNews = _hammerNotice;
    _clearSideshow();
    if (hammerNews != null) notice = hammerNews;
    if (s.reveals.isNotEmpty) showdown = s.reveals;
    if (s.result.isNotEmpty) showdownResult = s.result;
    if (s.winnerId != null) {
      winnerId = s.winnerId;
      winnerName = s.winnerName;
      winnerPot = s.pot;
      // The tax the same hand-ended frame named, for this winner only.
      final tax = _handTax;
      final paid = tax != null && tax.winnerId == s.winnerId && tax.tax > 0;
      winnerTax = paid ? tax.tax : 0;
      winnerTaxBps = paid ? tax.taxBps : 0;
      _handTax = null;
    }
    _armCelebration(s.nextHandAt);
    notifyListeners();
    unawaited(refreshUser());
  }

  /// `player:level`: the viewer's standing after an XP award the server has
  /// committed (owner, 26–27 Sep 2026) — their level, their badges and the
  /// rate they pay. It replaces the account's three whole, and when the level
  /// NUMBER rises (XP climbing the ladder; a badge is never reached by XP) the
  /// player is told — with the winning tax they pay now when the level changed
  /// it, and without when a badge keeps it lower than either level's.
  ///
  /// Every daily XP mission the award completed is queued for the bar at the
  /// top of the screen ([xpMissions], 27 Sep 2026) — once the level ladder is
  /// on the phone, which names them; a level up that came with one is said on
  /// that bar's last lines instead of a toast, with the winning tax it
  /// changed.
  @visibleForTesting
  void handlePlayerLevel(Standing standing) {
    final account = user;
    if (account == null) return;
    // Behind a missile volley the hand's end is not on screen yet: the news
    // of the award waits for it, as the cards and the winner do.
    if (missileHoldsReveal) {
      _heldStandings.add(standing);
      return;
    }
    final before = account.playerLevel;
    final paidBefore = account.paysTaxBps;
    final seen = _xpSeen;
    final mine = seen != null && seen.userId == account.id;
    final baseline = mine ? seen.level : before;
    user = account.withStanding(standing);
    final level = standing.playerLevel;
    // Only ever forward: lifetime XP never falls, so a standing with less XP
    // than the one held is an older award heard late (the play-time tracker
    // pushes from its own goroutine, a hand's settle from the table's) —
    // compared against, it would announce again what was already shown.
    if (!mine || seen.level == null || level.xp >= seen.level!.xp) {
      _xpSeen = (userId: account.id, level: level);
    }
    final paid = user!.paysTaxBps;
    final taxNow = paid != null && paid != paidBefore ? paid : null;
    // Which missions it completed is known now (the rule needs no ladder);
    // how they read waits for the ladder when it is not on the phone.
    final missions = XpMissions.completions(baseline, level, levelLadder);
    if (missions.isNotEmpty) {
      if (levelLadder == null) {
        _awardsAwaitingLadder.add((
          before: baseline,
          after: level,
          taxBps: taxNow,
        ));
        unawaited(loadLevelLadder().whenComplete(_queueAwardsAwaitingLadder));
      } else {
        // Any award still waiting on the read that has just brought the
        // ladder goes first: the bars keep the order the awards came in.
        _queueAwardsAwaitingLadder();
        xpMissions.award(baseline, level, levelLadder, levelUpTaxBps: taxNow);
      }
    }
    // A level up is congratulated in a popup (owner, 2 Oct 2026), which says
    // how much less winning tax the player pays now. It replaces the toast
    // ("Level up! … your winning tax is now 19.71%"): compared against the
    // standing last SEEN, as the missions are, so an account `/api/auth/me`
    // refreshed before the push still gets its popup, and a standing heard
    // again or heard late raises none. What was paid before is worked out
    // from that standing's level and the badges held; what is paid now is the
    // server's figure.
    if (baseline != null && level.level > baseline.level) {
      final now = user!;
      levelUps.raise(
        from: baseline,
        to: level,
        paidBefore: LevelUps.paidAt(baseline, now.badges, DateTime.now()),
        paidNow: now.paysTaxBps ?? level.taxBps,
        rateBadge: now.rateBadge,
      );
    }
    notifyListeners();
  }

  /// `game:handEnded`'s winning tax: what the hand's winner paid, heard just
  /// before the news that names them ([handleShowdown]), which takes it up.
  /// Kept rather than applied: that news may be held back behind a missile
  /// volley, and the tax belongs to the celebration it starts.
  @visibleForTesting
  void handleHandTax(HandTaxNews news) => _handTax = news;

  /// How long the table says a missed turn (owner, 27 Sep 2026: "missed turn
  /// text show only for 5 seconds only and warning text also show for 5
  /// seconds only"): the count after a miss and the last warning alike stand
  /// this long from the snapshot that counted the miss, then the status slot
  /// goes back to its line. The next miss shows it again.
  static const missedTurnsNoticeFor = Duration(seconds: 5);

  /// Whether the missed-turn notice is on the table now: true for
  /// [missedTurnsNoticeFor] from the first snapshot that carried this count
  /// at this table ([_trackMissedTurns]). The felts ask it before they draw
  /// the notice; the count itself stays the server's (`you.missedTurns`).
  bool get missedTurnsNoticeShowing => _missedNoticeShowing;
  bool _missedNoticeShowing = false;

  /// The count the notice was last raised for, and at which table — a
  /// snapshot repeating it (every move at the table, a reconnect) raises
  /// nothing.
  ({String roomId, int missed})? _missedNotice;
  Timer? _missedNoticeTimer;

  void _trackMissedTurns(RoomState s) {
    final missed = s.you?.missedTurns ?? 0;
    final max = s.you?.maxMissedTurns ?? 0;
    if (missed <= 0 || max <= 0) {
      _missedNotice = null;
      _missedNoticeTimer?.cancel();
      _missedNoticeShowing = false;
      return;
    }
    final seen = (roomId: s.roomId, missed: missed);
    if (_missedNotice == seen) return;
    _missedNotice = seen;
    _missedNoticeShowing = true;
    _missedNoticeTimer?.cancel();
    _missedNoticeTimer = Timer(missedTurnsNoticeFor, () {
      _missedNoticeShowing = false;
      notifyListeners();
    });
  }

  /// A table snapshot, already redacted for this viewer.
  @visibleForTesting
  void handleState(RoomState s) {
    // A snapshot that seats nobody as this player is a table they are no
    // longer at. After an out-of-chips kick one could still arrive behind the
    // room:kicked that had just taken them to the lobby — the bots were still
    // playing — and it put the table back on screen with no seat, no keys that
    // answered and no way out short of closing the app (QA 14 Sep 2026). Every
    // snapshot of a table this player is at carries their seat.
    if (s.you == null) return;
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
    // beginning — the Teen Patti ladder or the poker moves, whichever the
    // table deals in.
    final myTurnBegan =
        (room?.you?.options == null && s.you?.options != null) ||
        (room?.you?.pokerOptions == null && s.you?.pokerOptions != null);
    // A variation window seen open and now seen closed, within one hand.
    final windowClosed =
        !newHand && room?.variation?.selecting == true && !newTable;
    final wasChoosing = variationIsMine;
    room = s;
    _trackMissedTurns(s);
    if (newTable) {
      seatedAt = DateTime.now();
      // A different table is a different sitting, so the blocks go with the
      // old one. This covers the paths onLeft never sees: a room:switch (it
      // returns early while `switching`) and a resume onto another table.
      _clearBlocked();
    }
    if (newHand) {
      // A fresh deal cuts the last celebration short — a hammer or a missile
      // still in the air included.
      _clearSideshow();
      _clearVariation();
      _clearMissile();
      _clearCelebration();
      _clearPokerHand();
    } else if (newTable) {
      // Another table whose hand happens to carry the same number: what was
      // remembered of the last table's variation is not this one's.
      _clearVariation();
      _clearPokerHand();
    }
    // Every turn opens on the plain chaal. The stepper used to keep the
    // rung it was left on until the next deal, so a raise made on one turn
    // was quietly made again when the turn came back round — and for more,
    // because the ladder had climbed with the stake it had just raised. On
    // a blind table, where the ladder runs to the whole stack, that is a
    // hand-sized bet the player never asked for.
    if (newHand) {
      // A new deal asks its own 5-Card question; nothing is carried over.
      _pickSelection = const [];
      pickAnnounced = null;
      _pickTimer?.cancel();
    }
    // The 5-Card verdict rides on the snapshot, so it is raised wherever the
    // choice was made — by this player, or by the server's clock.
    _announcePick(room?.you?.hand);
    if (newHand || myTurnBegan) {
      raiseIndex = 0;
      // The poker stepper opens on the smallest bet or raise the server
      // offers, for the same reason.
      _pokerBetTo = null;
    }
    // A poker snapshot has no variation, no sideshow and no missile; a Teen
    // Patti one has no poker block. Each game's follow-ups run on its own
    // snapshots and never on the other's.
    if (s.isPoker) {
      _followPoker(s, newHand: newHand || newTable);
    } else {
      _followVariation(s, windowClosed: windowClosed);
    }
    // The picker is drawn on the felt, and a drawer left open — the chat,
    // usually — or a sheet opened between hands — the store, the rules — lies
    // over the felt: the chooser would spend their ten seconds not knowing
    // they had been asked. Closed once, as the window opens. The table itself
    // is the first route and is never popped (main.dart's _TableRoutes does
    // the same when the table goes).
    if (!s.isPoker && !wasChoosing && variationIsMine) {
      tableScaffold.currentState?.closeDrawer();
      tableScaffold.currentState?.closeEndDrawer();
      final table = tableScaffold.currentContext;
      if (table != null && table.mounted) {
        Navigator.of(
          table,
          rootNavigator: true,
        ).popUntil((route) => route.isFirst);
      }
    }
    final steps = s.you?.options?.raiseSteps ?? const [];
    if (steps.isNotEmpty && raiseIndex > steps.length - 1) {
      raiseIndex = steps.length - 1;
    }
    if (screen != Screen.table) {
      screen = Screen.table;
      chat.clear();
      unreadChat = 0;
      // The requests waiting for this player and their friends, read once as
      // the table opens: the seat of a player who asked wears a badge, a
      // friend's seat the friend mark (the player drawer's file). From here
      // they are kept by the pushes and the moves — nothing polls at a table.
      unawaited(friends.tableOpened());
    }
    if (restored) _endResume(welcome: true);
    notifyListeners();
  }

  /// What a snapshot says of the hand's variation.
  ///
  /// The snapshot is the truth, so the remembered variation is taken from it
  /// whenever it names one, and the announcement is raised from it when the
  /// window is seen to close — the event says the same thing a moment sooner,
  /// when it arrives at all.
  void _followVariation(RoomState s, {required bool windowClosed}) {
    final v = s.variation;
    final selected = v?.selected;
    if (v == null || v.selecting || selected == null) return;
    lastVariation = selected;
    lastTurnUp = v.turnUp;
    if (windowClosed) {
      _announceVariation((
        variation: selected,
        selectedBy: v.selectedBy ?? '',
        turnUp: v.turnUp,
      ));
    }
  }

  /// `game:variationSelected`: the window has closed.
  @visibleForTesting
  void handleVariationSelected(VariationNews news) {
    if (room == null) return;
    lastVariation = news.variation;
    lastTurnUp = news.turnUp;
    _announceVariation(news);
    notifyListeners();
  }

  /// The variation a hand's `game:showdown` or `game:handEnded` names. Only
  /// remembered, never announced: the hand is over, and the tag is where a
  /// player looks to see what it was decided by.
  @visibleForTesting
  void handleVariationAtShowdown(VariationNews news) {
    if (room == null) return;
    lastVariation = news.variation;
    lastTurnUp = news.turnUp;
    notifyListeners();
  }

  /// Raises the announcement, once per hand however many times it is heard.
  void _announceVariation(VariationNews news) {
    final hand = room?.handNo;
    if (hand == null || _variationAnnouncedFor == hand) return;
    _variationAnnouncedFor = hand;
    variationAnnounced = news;
    _variationTimer?.cancel();
    _variationTimer = Timer(variationAnnouncedFor, () {
      variationAnnounced = null;
      notifyListeners();
    });
  }

  /// Chooses the variation for this hand, and answers whether the server took
  /// it. Nothing is assumed here: the server decides whether the choice stood
  /// — its clock may already have chosen — and the snapshot that follows is
  /// what the table draws. A refusal is a toast like any other (the server
  /// echoes it as `game:error`); one that never reached the server has no echo,
  /// so it is said here.
  /// The cards a player has tapped while choosing which three of five play,
  /// in the order they were tapped. Cleared by every new hand and by the
  /// choice landing.
  List<String> _pickSelection = const [];
  List<String> get pickSelection => _pickSelection;

  /// True while this player still owes a 5-Card choice — the one flag the
  /// felt needs to put the picker in front of them.
  bool get pickingCards => room?.you?.hand?.picking ?? false;

  /// The player everyone else is waiting on: the seat ON TURN that is still
  /// choosing its three (owner, 19 Sep 2026: "while player is choosing best
  /// card and the turn is also his then, others should see that he is
  /// choosing"). Null for that player themselves — they have the picker in
  /// front of them — and null when the chooser is not the one holding the
  /// table up.
  Seat? get someoneChoosingCards {
    final r = room;
    final seatIndex = r?.turn?.seatIndex;
    if (r == null || seatIndex == null || seatIndex < 0) return null;
    for (final seat in r.seats) {
      if (seat.seatIndex != seatIndex || !seat.picking) continue;
      return seat.userId == user?.id ? null : seat;
    }
    return null;
  }

  /// Taps a card of the viewer's own hand while choosing. A tapped card is
  /// untapped by tapping it again, and the third tap fills the hand — a
  /// fourth is ignored rather than silently replacing one of the three.
  void togglePickCard(String code) {
    if (!pickingCards) return;
    final next = List<String>.from(_pickSelection);
    if (next.remove(code)) {
      _pickSelection = next;
    } else if (next.length < 3) {
      _pickSelection = [...next, code];
    } else {
      return;
    }
    notifyListeners();
  }

  /// Sends the three chosen cards. Answers whether the server took them; a
  /// refusal is shown as any refused move is, and leaves the selection alone
  /// so the player can change it.
  Future<bool> selectCards(List<String> cards) async {
    final reply = await _conn.selectCards(cards);
    if (reply['ok'] == true) {
      _pickSelection = const [];
      notifyListeners();
      return true;
    }
    final code = reply['code'];
    if (code == GameConnection.notConnected) {
      notice = t.notConnected;
      notifyListeners();
    } else if (code is! String) {
      notice = '${reply['message'] ?? t.notConnected}';
      notifyListeners();
    } else {
      notice = refusalText(code, '${reply['message'] ?? ''}');
      notifyListeners();
    }
    return false;
  }

  Future<bool> selectVariation(String variation) async {
    final reply = await _conn.selectVariation(variation);
    if (reply['ok'] == true) return true;
    final code = reply['code'];
    if (code == GameConnection.notConnected) {
      notice = t.notConnected;
      notifyListeners();
    } else if (code is! String) {
      notice = '${reply['message'] ?? t.notConnected}';
      notifyListeners();
    }
    return false;
  }

  /// The two hands of a sideshow this player was part of.
  @visibleForTesting
  void handleSideshowReveal(SideshowReveal reveal) {
    sideshowReveal = reveal;
    // A forced one is thrown across the table first, and its hands stay face
    // down until the hammer lands ([shownSideshowReveal]).
    if (reveal.forced && reveal.hands.length >= 2) {
      _strikeHammer(
        fromUserId: reveal.hands[0].userId,
        toUserId: reveal.hands[1].userId,
        packedUserId: reveal.packedUserId,
      );
    }
    _revealTimer?.cancel();
    // The five seconds to look are counted from when the cards turn over,
    // which for a forced one is when the hammer lands.
    _revealTimer = Timer(
      reveal.forced && hammerStrike != null
          ? revealFor + HammerTiming.impact
          : revealFor,
      () {
        sideshowReveal = null;
        notifyListeners();
      },
    );
    notifyListeners();
  }

  /// How a sideshow ended, as the whole table hears it.
  @visibleForTesting
  void handleSideshowDone(
    ({
      String fromUserId,
      String toUserId,
      bool accepted,
      String reason,
      String? packedUserId,
    })
    done,
  ) {
    if (done.reason == SideshowReason.forced) {
      // Everyone but the two players hears of a forced sideshow here first,
      // so this is where their hammer is thrown. A player's was thrown by the
      // reveal a moment ago, and the same sideshow is not struck twice.
      _strikeHammer(
        fromUserId: done.fromUserId,
        toUserId: done.toUserId,
        packedUserId: done.packedUserId,
      );
      // A forced sideshow is news to the whole table. Nobody saw a
      // request, so without a line the only sign of it is a player
      // packing out of turn. The two who compared hands are told too:
      // their cards alone read like a sideshow one of them agreed to.
      final line = forcedSideshowLine(
        t,
        viewerId: user?.id,
        fromUserId: done.fromUserId,
        toUserId: done.toUserId,
        seats: room?.seats ?? const [],
      );
      if (line != null) {
        // Said once the hammer has landed and the loser has folded: said
        // before, it gives away the result the hammer is on its way to show.
        if (hammerStrike != null && !_hammerResolved) {
          _hammerNotice = line;
        } else {
          notice = line;
        }
      }
    } else if (done.fromUserId == user?.id || done.toUserId == user?.id) {
      // An ordinary one tells only the two in it, and only when it did
      // not happen: one that did is already on screen as their cards. A
      // decline is news to the player who asked, not to the one who tapped
      // Decline — they were being told "Your sideshow was declined" about a
      // sideshow that was not theirs (QA 14 Sep 2026).
      final declinedByViewer =
          done.toUserId == user?.id && done.reason == SideshowReason.declined;
      if (!done.accepted && !declinedByViewer) {
        notice = _sideshowRefusedLine(done.reason);
      }
    }
    notifyListeners();
  }

  /// A move as the room hears it; read for a missile, which every viewer sees
  /// fly, and for a Force Sideshow's pack.
  ///
  /// The server packs the loser before it says the sideshow was resolved, so
  /// a bystander's snapshot folds that player a moment before this client
  /// knows there is a hammer to wait for. A pack for a sideshow with no
  /// sideshow pending can only be a forced one — an ordinary one is in the
  /// snapshot from its request until after this pack — so the fold is held
  /// from here. The two players heard the reveal first and are already held.
  @visibleForTesting
  void handleTableAction(({String userId, String action, String? reason}) a) {
    if (a.action == GameAction.missile) {
      _launchMissile(a.userId);
      return;
    }
    final r = room;
    if (r == null ||
        r.sideshow != null ||
        a.action != GameAction.pack ||
        a.reason != _packReasonSideshow ||
        a.userId.isEmpty ||
        _foldHeldFor == a.userId) {
      return;
    }
    _foldHeldFor = a.userId;
    _foldHoldTimer?.cancel();
    // The resolution follows within the same breath. If it never comes — an
    // older server, a dropped frame — the fold shows after all.
    _foldHoldTimer = Timer(const Duration(seconds: 1), () {
      if (hammerStrike == null && _foldHeldFor == a.userId) {
        _foldHeldFor = null;
        notifyListeners();
      }
    });
  }

  /// `game:action.reason` on the loser's pack, forced or not.
  static const _packReasonSideshow = 'sideshow';

  /// Throws the hammer for one forced sideshow, once, however many of its
  /// events arrive.
  void _strikeHammer({
    required String fromUserId,
    required String toUserId,
    required String? packedUserId,
  }) {
    final r = room;
    if (r == null || fromUserId.isEmpty || toUserId.isEmpty) return;
    if (!_hammersShown.add(
      HammerStrike.keyFor(r.handNo, fromUserId, toUserId),
    )) {
      return;
    }
    _clearHammer();
    hammerStrike = HammerStrike(
      handNo: r.handNo,
      fromUserId: fromUserId,
      toUserId: toUserId,
      packedUserId: packedUserId,
      startedAt: DateTime.now(),
    );
    _foldHeldFor = packedUserId;
    _hammerTimers.addAll([
      // The hit: the cards turn over.
      Timer(HammerTiming.impact, () {
        _hammerLanded = true;
        notifyListeners();
      }),
      // The result: the loser folds and the table is told.
      Timer(HammerTiming.result, () {
        _hammerResolved = true;
        _foldHeldFor = null;
        final news = _hammerNotice;
        _hammerNotice = null;
        if (news != null) notice = news;
        notifyListeners();
      }),
      Timer(HammerTiming.total, () {
        hammerStrike = null;
        _hammerTimers.clear();
        notifyListeners();
      }),
    ]);
  }

  /// Launches the volley for one missile, once, however many copies of its
  /// `game:action` arrive.
  ///
  /// Aimed at every other seat still in the hand as the table last showed it.
  /// Won and lost count as in the hand too: a snapshot that settled the hand
  /// can beat the action here.
  void _launchMissile(String fromUserId) {
    final r = room;
    if (r == null || fromUserId.isEmpty) return;
    if (!_missilesShown.add(MissileStrike.keyFor(r.handNo, fromUserId))) {
      return;
    }
    final targets = [
      for (final seat in r.seats)
        if (seat.userId != null &&
            seat.userId!.isNotEmpty &&
            seat.userId != fromUserId &&
            (seat.status == SeatState.active ||
                seat.status == SeatState.won ||
                seat.status == SeatState.lost))
          seat.userId!,
    ];
    if (targets.isEmpty) return;

    _clearMissile();
    final strike = MissileStrike(
      handNo: r.handNo,
      fromUserId: fromUserId,
      targetUserIds: targets,
      startedAt: DateTime.now(),
    );
    missileStrike = strike;
    _missilePot = r.pot;
    // Said at the launch: who fired is news, and it gives nothing away.
    final line = missileFiredLine(
      t,
      viewerId: user?.id,
      fromUserId: fromUserId,
      seats: r.seats,
    );
    if (line != null) notice = line;
    _missileTimers.addAll([
      // The explosions have played out, and a beat after: the cards turn
      // over and the winner is told (owner, 14 Sep 2026 — not the moment the
      // missiles land, over the blasts).
      Timer(MissileTiming.reveal(strike.count), () {
        _missileLanded = true;
        _missilePot = null;
        final held = List.of(_heldShowdowns);
        _heldShowdowns.clear();
        for (final news in held) {
          _applyShowdown(news);
        }
        // The award that came with the hand's end, now that the end is seen.
        _releaseHeldStandings();
        notifyListeners();
      }),
      Timer(MissileTiming.total(strike.count), () {
        missileStrike = null;
        _missileTimers.clear();
        notifyListeners();
      }),
    ]);
    notifyListeners();
  }

  /// Drops a volley and everything it was holding back, for a hand, a table or
  /// a seat that is over. A held showdown belongs to the hand that is gone,
  /// so it is dropped with it rather than shown over the next.
  void _clearMissile() {
    for (final timer in _missileTimers) {
      timer.cancel();
    }
    _missileTimers.clear();
    _heldShowdowns.clear();
    missileStrike = null;
    _missileLanded = false;
    _missilePot = null;
    // An award is the account's news, not the hand's: it is told now rather
    // than dropped with the volley.
    _releaseHeldStandings();
  }

  /// Lets the standings held behind a volley go, in the order they came.
  void _releaseHeldStandings() {
    if (_heldStandings.isEmpty) return;
    final held = List.of(_heldStandings);
    _heldStandings.clear();
    for (final standing in held) {
      handlePlayerLevel(standing);
    }
  }

  /// Drops a strike and everything it was holding back, for a hand, a table
  /// or a seat that is over.
  void _clearHammer() {
    for (final timer in _hammerTimers) {
      timer.cancel();
    }
    _hammerTimers.clear();
    _foldHoldTimer?.cancel();
    _foldHoldTimer = null;
    hammerStrike = null;
    _hammerLanded = false;
    _hammerResolved = false;
    _foldHeldFor = null;
    _hammerNotice = null;
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

  /// Plays [m]'s emoji over its sender's seat for [emojiBubbleFor], then the
  /// one waiting behind it, if any.
  void _showEmoji(ChatMessage m) {
    emojiShown[m.userId] = m;
    _emojiTimers[m.userId]?.cancel();
    _emojiTimers[m.userId] = Timer(emojiBubbleFor, () {
      emojiShown.remove(m.userId);
      final waiting = _emojiWaiting.remove(m.userId);
      if (waiting != null) {
        _showEmoji(waiting);
      } else {
        _emojiTimers.remove(m.userId);
      }
      notifyListeners();
    });
  }

  /// The emoji playing over [userId]'s seat right now, or null — for the
  /// seat pods, which play it in their bubble's place.
  ChatEmoji? emojiOver(String? userId) =>
      userId == null ? null : emojiShown[userId]?.emoji;

  /// Drops every bubble and everything queued behind one — for leaving a
  /// table, where the people who said them are no longer in view.
  void _clearBubbles() {
    for (final t in _bubbleTimers.values) {
      t.cancel();
    }
    _bubbleTimers.clear();
    _bubbleQueue.clear();
    saidRecently.clear();
    for (final t in _emojiTimers.values) {
      t.cancel();
    }
    _emojiTimers.clear();
    _emojiWaiting.clear();
    emojiShown.clear();
  }

  // ------------------------------------------------------------ seat check

  /// After a reconnect the server re-sends the table straight after
  /// `session:ready` if it still has us seated. If nothing follows, the seat
  /// is gone: back to the lobby, with a word about why, rather than a table
  /// that never moves again.
  void _armSeatCheck({Duration after = const Duration(milliseconds: 1800)}) {
    _seatCheck?.cancel();
    _seatCheck = Timer(after, () {
      if (_snapshotSinceSession || room == null) return;
      room = null;
      seatedAt = null;
      chat.clear();
      _clearBubbles();
      _clearSideshow();
      _clearVariation();
      _clearMissile();
      _clearCelebration();
      _clearPokerHand();
      switching = false;
      notice = t.tableLost;
      screen = Screen.lobby;
      notifyListeners();
      unawaited(refreshUser());
    });
  }

  // ------------------------------------------------------------- lifecycle

  /// How long the app may sit in the background at a table before its socket
  /// is closed (owner, 27 Sep 2026: "a locked or backgrounded phone keeps its
  /// way back").
  ///
  /// A locked or backgrounded phone used to keep its socket open, so the
  /// server saw a CONNECTED player who never moved: three turn clocks later
  /// (~83 s) they were idle-kicked with no way back, and the room:kicked went
  /// to a phone that was not listening. Closing the socket starts the
  /// server's reconnect grace instead — the seat is held, and if it lapses
  /// (or the turns run out meanwhile) the server keeps a resume offer, which
  /// the warm session:ready on [AppLifecycleState.resumed] takes up.
  ///
  /// Why a delay, and not at once: some trips out of the app are part of
  /// using it — Play's purchase sheet, Google sign-in, the privacy page or a
  /// support e-mail, the system's own dialogs — and are over in seconds. A
  /// phone back within the delay never dropped its socket at all. One away
  /// longer loses nothing either: the reconnect gets the held seat back
  /// (RECONNECT_GRACE_MS, 60 s) or the offer (RESUME_OFFER_MS, 10 min). The
  /// delay only spares a quick trip a reconnect. Eight seconds is under a
  /// third of a turn clock (25 s), so a player who has left keeps at most
  /// that much of a live connection while their turn runs down.
  static const backgroundGrace = Duration(seconds: 8);

  Timer? _backgroundTimer;

  /// True from closing the socket for the background until the app is back.
  bool _closedForBackground = false;

  /// Whether a flow that takes the player out of the app on purpose, and
  /// must not lose its connection meanwhile, is under way: a Play purchase
  /// with its sheet open ([Purchases.buying], capped at [Purchases.buyingFor]),
  /// or Play's in-app update. While it is, the socket is not closed; the check
  /// runs again one [backgroundGrace] later.
  ///
  /// A purchase Play reports as PENDING ([purchasePending] — a slow payment
  /// such as UPI) does not count: it can stay pending for days, or be
  /// abandoned and never reported again, and counting it kept a seated
  /// phone's socket open whenever it was put away for the rest of the session,
  /// which is exactly the idle kick with no way back this closing exists to
  /// prevent. Its receipt is banked over REST when Play delivers it, which
  /// needs no socket.
  bool get purchaseInFlight => purchases.buying || updating;

  /// The app's lifecycle, as the platform reports it (main.dart's
  /// [AppLifecycleListener]).
  ///
  /// Only [AppLifecycleState.paused] and [AppLifecycleState.resumed] matter:
  /// `inactive` is transient (a notification shade, a system dialog, the
  /// app switcher), and `hidden` always comes between the two. Paused while
  /// seated at a table arms [backgroundGrace]; resumed cancels it, or — when
  /// the socket was closed — connects again. In the lobby nothing happens:
  /// the socket there only brings friend requests, and nothing is at stake.
  void handleLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
        _backgroundTimer?.cancel();
        _backgroundTimer = null;
        if (room == null || _token == null) return;
        _backgroundTimer = Timer(backgroundGrace, _closeForBackground);
      case AppLifecycleState.resumed:
        _backgroundTimer?.cancel();
        _backgroundTimer = null;
        if (!_closedForBackground) return;
        _closedForBackground = false;
        final token = _token;
        // Signed out meanwhile (a disabled account, say): nothing to rejoin.
        if (token == null) return;
        // The warm session:ready that follows takes the player back: the
        // held seat's room:joined, or the resume offer (see _wire).
        _conn.connect(token);
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _closeForBackground() {
    _backgroundTimer = null;
    // Left the table while the timer ran (a kick heard in time, say).
    if (room == null || _token == null) return;
    if (purchaseInFlight) {
      _backgroundTimer = Timer(backgroundGrace, _closeForBackground);
      return;
    }
    _seatCheck?.cancel();
    _conn.disconnect();
    _closedForBackground = true;
    offline = true;
    notifyListeners();
  }

  /// Whether the socket is closed because the app went to the background.
  @visibleForTesting
  bool get closedForBackground => _closedForBackground;

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
      _seeStanding();
      // Re-read the catalogue now there is a token: ownership is resolved per
      // viewer, and the startup call was anonymous.
      unawaited(_loadPictures());
      unawaited(_loadTableConfig());
      unawaited(loadLuckyDraw());
      // The ladder says where the player's level starts, which the
      // lobby's level bar measures from (owner, 27 Sep 2026).
      if (levelLadder == null) unawaited(loadLevelLadder());
      unawaited(friends.refreshBadge());

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', r.token);
      await loadConsent(prefs);

      // A new account is shown what it was given — the welcome rewards
      // popup, after the no-winnings panel and before the weekly login's
      // ([welcomePending]); a returning one sees nothing.
      if (r.isNew) _welcomeGranted(r.welcome, welcomeChips: r.welcomeChips);

      _conn.connect(r.token);
      screen = Screen.lobby;
    } on ApiException catch (e) {
      // A disabled account gets the popup ([accountDisabled]), not a line.
      if (e.code != accountDisabledCode) loginError = e.message;
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

  /// Signs in with Google, Apple or Facebook.
  ///
  /// The provider hands back a credential, the server verifies it and answers
  /// with the same session guest play gets — so everything after this line is
  /// identical to [loginAsGuest], deliberately: one session shape means one
  /// set of behaviour to reason about, whichever door was used.
  ///
  /// `credential` is null when the player backed out of the provider's own
  /// sheet, which is not an error and must not be reported as one.
  ///
  /// `nameOf` is read once the credential is in hand, for a provider whose
  /// credential carries no name: Apple tells the APP a person's name, once,
  /// at their first authorisation, and never puts it in the token — so it is
  /// sent beside the token, and names the account if this login creates it.
  Future<void> loginWithProvider(
    String provider,
    Future<String?> Function() credentialOf, {
    String? Function()? nameOf,
  }) async {
    busy = true;
    loginError = null;
    notifyListeners();

    try {
      final credential = await credentialOf();
      if (credential == null) return;

      final r = await _api.loginProvider(
        provider: provider,
        credential: credential,
        displayName: nameOf?.call(),
      );
      _token = r.token;
      user = r.user;
      _seeStanding();
      // Re-read the catalogue now there is a token: ownership is resolved per
      // viewer, and the startup call was anonymous.
      unawaited(_loadPictures());
      unawaited(_loadTableConfig());
      unawaited(loadLuckyDraw());
      // The ladder says where the player's level starts, which the
      // lobby's level bar measures from (owner, 27 Sep 2026).
      if (levelLadder == null) unawaited(loadLevelLadder());
      unawaited(friends.refreshBadge());

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', r.token);
      await loadConsent(prefs);

      // A new account is shown what it was given — the welcome rewards
      // popup, after the no-winnings panel and before the weekly login's
      // ([welcomePending]); a returning one sees nothing.
      if (r.isNew) _welcomeGranted(r.welcome, welcomeChips: r.welcomeChips);

      _conn.connect(r.token);
      screen = Screen.lobby;
    } on SignInUnavailable catch (e) {
      // Not a failure of the network or the server: this build simply has no
      // credentials for that provider. Saying so keeps the player from
      // retrying something that cannot start working.
      loginError = t.signInUnavailable(e.provider);
    } on ApiException catch (e) {
      // A disabled account gets the popup ([accountDisabled]), not a line.
      if (e.code != accountDisabledCode) loginError = e.message;
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

  /// The server said this account is disabled. Signs it out (the token is
  /// dropped; the device id is KEPT, so a guest cannot sign straight into a
  /// fresh account) and raises [accountDisabled] for the sign-in screen's
  /// popup. On a cold start the splash is left to finish: [start] falls back
  /// to the sign-in screen by itself.
  void _accountWasDisabled() {
    accountDisabled = true;
    if (screen == Screen.splash) {
      notifyListeners();
      return;
    }
    if (_token != null || user != null) {
      unawaited(signOut());
      return;
    }
    notifyListeners();
  }

  /// The server said this device's sign-in was replaced: the account signed
  /// in on another device. Signs out — the token is dropped, so the phone
  /// never reconnects and takes the seat back from the device that now has
  /// it — and raises [sessionReplaced] for the sign-in screen's popup. On a
  /// cold start the splash is left to finish, as for a disabled account.
  /// Nothing when nobody is signed in here: that is a late word about a
  /// session this phone has already left.
  void _sessionWasReplaced() {
    if (_token == null && user == null) return;
    sessionReplaced = true;
    if (screen == Screen.splash) {
      notifyListeners();
      return;
    }
    unawaited(signOut());
  }

  /// The "signed in on another device" popup has been read.
  void dismissSessionReplaced() {
    if (!sessionReplaced) return;
    sessionReplaced = false;
    notifyListeners();
  }

  /// The popup has been read.
  void dismissAccountDisabled() {
    if (!accountDisabled) return;
    accountDisabled = false;
    notifyListeners();
  }

  Future<void> signOut() async {
    _statsCatchUp?.cancel();
    _statsCatchUp = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    _token = null;
    _conn.disconnect();
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    _closedForBackground = false;
    room = null;
    seatedAt = null;
    user = null;
    luckyDraw = null;
    luckyDrawFailed = false;
    rewardPrograms = null;
    rewardProgramsFailed = false;
    rewardsGranted = null;
    _forgetRewardOffers();
    welcomePending = null;
    consentPending = false;
    _consentKnownFor = null;
    // The next player on this phone never sees this one's friends.
    friends.reset();
    reports.reset();
    // Nor which card backs this one owns: `owned` is per viewer, and the
    // next sign-in reads the catalogue again.
    _forgetCardBackgrounds();
    xpMissions.clear();
    levelUps.clear();
    _awardsAwaitingLadder.clear();
    _heldStandings.clear();
    _xpSeen = null;
    // The next account starts at the front, not where this one stood.
    _lobbyEngine = null;
    _lobbyCategory = null;
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
    final id = user?.id;
    consentPending = await NoWinningsConsent.isPending(id, prefs);
    // Known now for this account: the reward popups may have been waiting
    // on the answer (offerRewards) — a lobby's read of the programs lands
    // before this on a fast link.
    _consentKnownFor = id;
    if (!consentPending && room == null) offerRewards();
  }

  /// The account whose consent [loadConsent] has answered for, so nothing
  /// that must wait behind the no-winnings panel is shown before the answer
  /// is in.
  String? _consentKnownFor;

  /// Records the confirmation for this account and lets the game open.
  ///
  /// Written before the flag clears, so a crash between the two leaves the
  /// player asked again rather than never asked.
  Future<void> acceptConsent() async {
    final id = user?.id;
    if (id != null) await NoWinningsConsent.record(id);
    consentPending = false;
    _consentKnownFor = id;
    // The welcome rewards popup stands next ([welcomePending], shown by
    // main.dart once the panel is down), and the reward popups waited behind
    // both (offerRewards: nothing while the welcome is pending).
    if (room == null) offerRewards();
    notifyListeners();
  }

  /// What a NEW account's sign-in granted, until the player has confirmed
  /// it (owner, 30 Sep 2026: "WHen user login with new account it should
  /// show first consent pop up "before you play", then after show pop up
  /// Welcome Rewards which user must select confirm otherwise not able to
  /// proceed then Weekly Login pop up"). main.dart shows the welcome rewards
  /// popup while this stands and the no-winnings panel is down; the reward
  /// popups are not offered until [confirmWelcome] clears it. A returning
  /// account never has one. Not kept across a restart: the grant comes with
  /// the login that created the account and with nothing else.
  WelcomeGrant? welcomePending;

  /// A new account's login has landed: what it was given, as the popup
  /// shows it — the server's `welcome` block, or, from a server before the
  /// grant, its `welcomeChips` alone (a grant of nothing is still welcomed).
  void _welcomeGranted(WelcomeGrant? grant, {int welcomeChips = 0}) {
    welcomePending =
        grant ??
        (welcomeChips > 0 ? WelcomeGrant(chips: welcomeChips) : null) ??
        const WelcomeGrant();
  }

  /// The welcome rewards popup has been confirmed: the reward popups may
  /// come now.
  void confirmWelcome() {
    if (welcomePending == null) return;
    welcomePending = null;
    if (room == null) offerRewards();
    notifyListeners();
  }

  /// The table is gone — the player left, was shown out, or it closed —
  /// and the lobby comes back: everything the table held is cleared, and the
  /// account is read at once and once more after the stats flush
  /// ([statsCatchUpAfter]).
  @visibleForTesting
  void handleBackToLobby() {
    room = null;
    seatedAt = null;
    chat.clear();
    _clearBubbles();
    _clearBlocked();
    _clearSideshow();
    _clearVariation();
    _clearMissile();
    _clearCelebration();
    _clearPokerHand();
    screen = Screen.lobby;
    notifyListeners();
    unawaited(refreshUser());
    _catchUpStats();
  }

  /// How long after leaving a table the account is read once more: the
  /// server's stats flusher (Player stats v2) moves a finished hand's counters
  /// into PostgreSQL up to STATS_FLUSH_MS (10 s) after the hand, so the read
  /// the lobby makes at once can miss the last hand in the Stats drawer. One
  /// more read just after the flush catches it up.
  static const statsCatchUpAfter = Duration(seconds: 11);
  Timer? _statsCatchUp;

  void _catchUpStats() {
    _statsCatchUp?.cancel();
    _statsCatchUp = Timer(statsCatchUpAfter, () {
      _statsCatchUp = null;
      if (_token != null) unawaited(refreshUser());
    });
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

  /// The 6-hour bonus's refusal code for a bonus still recharging.
  static const bonusNotReadyCode = 'reward_not_ready';

  /// Whether a bonus claim is out, so the chip is pressed once.
  bool claimingBonus = false;

  /// Collects the 6-hour bonus (owner, 30 Sep 2026: "IN Top left Add Again
  /// Every 6 hours bonus 25000 Coins"): the lobby's top-left chip, tapped
  /// while the server says it is ready. Success is `claimed`; the account in
  /// the answer carries the new clock, and the lobby's celebration shows the
  /// chips. A refusal keeps the server's own wording — "The bonus is still
  /// recharging", "Collect your reward from the lobby" — and a clock the
  /// phone had wrong is put right by reading the account again. Nothing is
  /// sent from a table: the chip is the lobby's, and the server would refuse
  /// a seated player anyway (a seated wallet only moves at the three
  /// checkpoints).
  Future<void> claimBonus() async {
    final token = _token;
    if (token == null || claimingBonus || room != null) return;
    claimingBonus = true;
    notifyListeners();
    try {
      final r = await _api.claimBonus(token);
      if (r.user != null) user = r.user;
      if (r.claimed) {
        rewardWon = (kind: 'bonus', amount: r.amount, missiles: 0, hammers: 0);
      } else {
        notice = r.message.isEmpty ? t.bonusRefused : r.message;
      }
    } on ApiException catch (e) {
      notice = e.message.isEmpty ? t.bonusRefused : e.message;
      // The server's clock, not the phone's guess, decides when the bonus is
      // ready: told it is not, take the account's clock afresh.
      if (e.code == bonusNotReadyCode) unawaited(refreshUser());
    } catch (_) {
      notice = t.bonusRefused;
    } finally {
      claimingBonus = false;
    }
    notifyListeners();
  }

  /// Loads the picture catalogue.
  ///
  /// Called once at startup and again after signing in, because ownership is
  /// resolved per viewer: the first call has no token and every premium
  /// picture comes back locked, and the second is what unlocks the ones this
  /// player has bought. Also re-run after a purchase.
  Future<void> _loadPictures() async {
    // The table catalogue rides along on every load of the face catalogue:
    // the same moments want both, and a failure of one must not empty the
    // other, so they are two requests.
    unawaited(_loadTablePictures());
    // And the emojis (owner, 26 Sep 2026), at the same moments for the same
    // reason: `owned` is per viewer, anonymous at start and this player's
    // once there is a token.
    unawaited(_loadEmojis());
    // And the card backs (owner, 3 Oct 2026), likewise.
    unawaited(_loadCardBackgrounds());
    // Ownership is per viewer: an answer to a request made under another
    // token — the anonymous one a cold start sends, overtaken by the sign-in's
    // — is about somebody else and must not overwrite this one's (a picture
    // the welcome grant gave would read locked). The emojis already do this.
    final token = _token;
    try {
      final got = await _api.profilePictures(token);
      if (_token != token) return;
      pictures = got;
      // Pull the faces down as soon as we know what they are, so the picker
      // opens on pictures rather than on fifteen placeholders. Not awaited:
      // the list renders either way, and a picture that is not down yet fills
      // itself in when it arrives.
      PictureCache.warm(pictures.map((p) => p.url));
      notifyListeners();
    } catch (_) {
      // The picker just stays empty.
    }
  }

  // ------------------------------------------------------------ the menu

  /// The one writer of [config]. Every menu the lobby shows — the phone's
  /// copy, a session's, a fetched catalogue — lands here, so the check that
  /// goes with a new menu cannot be skipped by one of them: a menu that no
  /// longer lists the category the lobby was showing (the server changed
  /// what it offers) would leave the player looking at an empty rail with
  /// only a way back, so the lobby goes back one level — to the engine's
  /// categories, or to the front when the engine itself has gone, or when
  /// that engine's categories ARE the front ([lobbyFrontEngine]).
  void _applyMenu(GameConfig next) {
    config = next;
    final engine = _lobbyEngine;
    if (engine == null) return;
    if (!lobbyEngines.contains(engine)) {
      _lobbyEngine = null;
      _lobbyCategory = null;
    } else if (_lobbyCategory != null &&
        !lobbyCategoriesIn(engine).contains(_lobbyCategory)) {
      _lobbyCategory = null;
    }
    // An engine's categories with no category open, where the front already
    // shows them, is the front.
    if (_lobbyCategory == null && lobbyFrontEngine != null) {
      _lobbyEngine = null;
    }
  }

  /// A cold start's menu: the phone's copy of the table catalogue, when it
  /// holds a usable one. Nothing when it does not — the lobby then opens on
  /// [GameConfig.fallback] as it always has, until the session's menu comes.
  @visibleForTesting
  void restoreCachedMenu(SharedPreferences prefs) {
    final cached = TableConfigCache.read(prefs);
    if (cached == null) return;
    handleCatalogue(cached.config);
  }

  /// `session:ready`'s part in the menu ([MenuPrecedence.onSession]). A
  /// session with no config keeps the menu already held. Answers whether the
  /// catalogue should be fetched, which the caller does once the build floor
  /// has let this build through.
  @visibleForTesting
  bool handleSessionMenu(GameConfig? session) {
    if (session == null) return false;
    _announcedVersion = session.tableConfigVersion;
    _sessionMinClientBuild = session.minClientBuild;
    final decision = MenuPrecedence.onSession(
      session: session,
      catalogue: _catalogue,
    );
    _applyMenu(decision.config);
    return decision.refetch;
  }

  /// A table catalogue arrived — fetched, confirmed by a 304, or read from
  /// the phone. It becomes the catalogue held either way; it goes on screen
  /// only when [MenuPrecedence.onCatalogue] says it is the one the server
  /// enforces.
  @visibleForTesting
  void handleCatalogue(GameConfig catalogue) {
    _catalogue = catalogue;
    final next = MenuPrecedence.onCatalogue(
      catalogue: catalogue,
      announced: _announcedVersion,
      minClientBuild: _sessionMinClientBuild,
    );
    if (next == null) return;
    _applyMenu(next);
    notifyListeners();
  }

  /// Fetches the table catalogue, once at a time.
  ///
  /// Run at every sign-in — both doors and a restored session — and whenever
  /// a session names a catalogue other than the one held. Never awaited by
  /// anything the player waits on: the menu already on screen is a working
  /// menu, and this only makes it richer.
  Future<void> _loadTableConfig() => _tableConfigFetch ??= _fetchTableConfig()
      .whenComplete(() => _tableConfigFetch = null);

  Future<void> _fetchTableConfig() async {
    try {
      final held = _catalogue;
      final answer = await _api.tableConfig(version: held?.tableConfigVersion);
      switch (answer) {
        case TableConfigFresh(:final body, config: final fetched):
          await TableConfigCache.write(body);
          handleCatalogue(fetched);
        case TableConfigNotModified():
          if (held != null) handleCatalogue(held);
        case TableConfigAbsent():
          // A server from before the catalogue: its session menu is the whole
          // menu. The phone's copy is left alone — a rollback is usually
          // brief, and session:ready overrules the copy on every connection.
          break;
      }
    } catch (_) {
      // Offline, slow, or an answer that is not a menu: the one on screen
      // stays, and the next sign-in asks again.
    }
  }

  /// Loads the table-picture catalogue, and warms both files of every row —
  /// the store's tiles show day and night side by side, and the felt needs
  /// whichever the theme wants the moment a table is joined.
  Future<void> _loadTablePictures() async {
    // As the faces are: an answer under another token is dropped.
    final token = _token;
    try {
      final got = await _api.tablePictures(token);
      if (_token != token) return;
      tablePictures = got;
      PictureCache.warm(
        tablePictures
            .expand((p) => [p.dayUrl, p.nightUrl])
            .map(absoluteUrl)
            .nonNulls,
      );
      notifyListeners();
    } catch (_) {
      // The Tables shelf just stays empty.
    }
  }

  // --------------------------------------------------------------- tables

  /// The table picture this player has laid on their own account, or null:
  /// what the store's Tables tab ticks. Read off the account, which the
  /// server resolves with both files.
  LaidTablePicture? get laidTablePicture => user?.tablePicture;

  /// The table picture the TABLE shows — the server's pick among everyone
  /// seated (owner, 15 Sep 2026: diamonds over hammers over coins, then the
  /// dearer), the same for every player at it, tagged with who laid it — or
  /// null when nobody has, or away from a table. It is what the felt draws:
  /// a player's own choice shows only when the table picks it.
  LaidTablePicture? get shownTablePicture => room?.tablePicture;

  /// The file the felt draws under [brightness], made absolute, or null when
  /// the table shows no picture: the day file on the light theme, the night
  /// file on the dark one (the ink on the table follows the theme, and a
  /// picture that reads under one is lost under the other).
  String? tablePictureUrl(Brightness brightness) =>
      absoluteUrl(shownTablePicture?.forBrightness(brightness));

  /// Lays a table picture, or null to go back to the table as it comes. The
  /// account comes back with the pair to draw; the catalogue is re-read
  /// unawaited, as after [chooseAvatar], so a lapsed rental re-locks itself.
  Future<void> chooseTablePicture(int? id) async {
    final token = _token;
    if (token == null) return;
    try {
      user = await _api.useTablePicture(token, id);
      // A poker room's felt shows no table picture (the board is where it
      // would go; the server keeps the choice on the account and nothing on
      // the poker felt changes), so laying one there says where it will
      // show rather than looking like a tap that did nothing.
      if (id != null && (room?.isPoker ?? false)) notice = t.tablePokerNote;
    } on ApiException catch (e) {
      notice = e.message;
    }
    notifyListeners();
    unawaited(_refreshPictures());
  }

  /// Set while a table picture is being bought, for that tile's spinner.
  int? buyingTablePicture;

  /// Buys a premium table picture and, when that works, lays it — two
  /// requests, as [buyPicture] makes, for the same reason.
  Future<PictureBuyResult> buyTablePicture(int id) async {
    final token = _token;
    if (token == null || buyingTablePicture != null) {
      return PictureBuyResult.refused;
    }
    buyingTablePicture = id;
    notifyListeners();
    try {
      final bought = await _api.buyTablePicture(token, id);
      user = bought.user;
      await _refreshPictures();
      await chooseTablePicture(id);
      return PictureBuyResult.bought;
    } on ApiException catch (e) {
      return tablePictureRefused(id, e);
    } catch (_) {
      notice = 'Could not reach the server.';
      return PictureBuyResult.refused;
    } finally {
      buyingTablePicture = null;
      notifyListeners();
    }
  }

  /// What a refused purchase of table picture [id] means to the player:
  /// [pictureRefused]'s reading for the table shelf — a hammer or diamond
  /// shortage is the offer of that wallet's shelf, a chip-priced table refused
  /// at a table is said in the player's language, anything else is the
  /// server's sentence.
  @visibleForTesting
  PictureBuyResult tablePictureRefused(int id, ApiException e) {
    final picture = tablePictures.where((p) => p.id == id).firstOrNull;
    if (e.code == 'picture_chips' &&
        picture != null &&
        (picture.pricedInHammers || picture.pricedInDiamonds)) {
      unawaited(refreshUser());
      return PictureBuyResult.notEnough;
    }
    notice = e.code == 'seated' ? t.tableChipsLobbyOnly : e.message;
    return PictureBuyResult.refused;
  }

  // ----------------------------------------------------------- card backs

  /// Loads the card-back catalogue and has every picture KEPT on the phone
  /// (owner, 3 Oct 2026: the Cards shelf shows them all, and a back somebody
  /// wears at a table is then drawn from the phone; the cache signs each R2
  /// location it does not have yet, all of them in one request).
  ///
  /// Kept on the disk, not warmed into memory (review, 3 Oct 2026): the
  /// thirteen backs are four megabytes of JPEG, none of them drawn in the
  /// lobby, and warmed they went through [PictureCache]'s 64 places in memory
  /// — beside 73 faces, table pictures and emojis — at every catalogue read,
  /// every seven seconds for a player wearing a rental in the lobby, pushing
  /// out pictures that then had to be read from the disk again. A back is
  /// read from the disk when a card needs it, and decoded then
  /// ([CardBackImages]); after the first run this costs a directory lookup a
  /// back.
  ///
  /// As the faces are: an answer to a request made under another token — a
  /// sign-out, or somebody else signing in — is dropped, since `owned` is
  /// per viewer.
  Future<void> _loadCardBackgrounds() async {
    final token = _token;
    try {
      final got = await _api.cardBackgrounds(token);
      if (_token != token) return;
      cardBackgrounds = got;
      unawaited(PictureCache.keep(got.map((c) => absoluteUrl(c.url)).nonNulls));
      notifyListeners();
    } catch (_) {
      // The Cards shelf keeps what it had — the Royal Fox at least.
    }
  }

  /// Re-reads the card-back catalogue: when the store is opened on its Cards
  /// shelf, so a rental that ran out shows its padlock again (the read is
  /// also where the server takes a lapsed back off).
  Future<void> reloadCardBackgrounds() => _loadCardBackgrounds();

  /// The card back this player has chosen, or null for the bundled Royal
  /// Fox: what the store's Cards tab ticks. Read off the account, which the
  /// server joins only while the rental runs — and let go of on this phone
  /// the moment it runs out ([liveCardBack]), before the account is read
  /// again ([_watchCardBackLapses]).
  CardBackArt? get chosenCardBack => liveCardBack(user?.cardBackground);

  /// The back on the viewer's OWN face-down cards: their seat's — the one
  /// every player at the table sees on them, which the server puts on the
  /// seat the moment it is chosen ([chooseCardBackground]) — or null, the
  /// bundled Royal Fox, where their seat wears none, at a poker room (whose
  /// felt keeps the Royal Fox), away from a table, or once the seat's back
  /// has run out ([liveCardBack]: from that moment, whatever a room:state
  /// still carries).
  CardBackArt? get ownCardBack {
    final r = room;
    final you = r?.you;
    if (r == null || you == null || r.isPoker) return null;
    for (final seat in r.seats) {
      if (seat.seatIndex == you.seatIndex) {
        return liveCardBack(seat.cardBackground);
      }
    }
    return null;
  }

  /// Wears a card back, or null to go back to the Royal Fox. Allowed at a
  /// table: the server puts it on the seat, and every player there sees it
  /// on the next snapshot. The account comes back with the back to draw; the
  /// catalogue is re-read unawaited, as after [chooseTablePicture], so a
  /// lapsed rental re-locks itself.
  Future<void> chooseCardBackground(int? id) async {
    final token = _token;
    if (token == null) return;
    try {
      final next = await _api.useCardBackground(token, id);
      // An answer for a session that has since ended is nobody's now.
      if (_token != token) return;
      user = next;
    } on ApiException catch (e) {
      if (_token != token) return;
      notice = e.message;
    } catch (_) {
      if (_token != token) return;
      notice = 'Could not reach the server.';
    }
    notifyListeners();
    unawaited(_refreshPictures());
  }

  /// Set while a card back is being bought, for that tile's spinner. One
  /// purchase at a time: [buyCardBackground] refuses a second meanwhile.
  int? buyingCardBackground;

  /// Buys a premium card back and, when that works, wears it — two
  /// requests, as [buyTablePicture] makes, for the same reason. The row the
  /// purchase answers with replaces the shelf's at once, so its padlock goes
  /// before the catalogue has been read again.
  Future<PictureBuyResult> buyCardBackground(int id) async {
    final token = _token;
    if (token == null || buyingCardBackground != null) {
      return PictureBuyResult.refused;
    }
    buyingCardBackground = id;
    notifyListeners();
    try {
      final bought = await _api.buyCardBackground(token, id);
      // Bought for a session that has since ended: the wallet and the row
      // are that account's, not the one on screen now.
      if (_token != token) return PictureBuyResult.refused;
      user = bought.user;
      final row = bought.cardBackground;
      if (row != null) {
        cardBackgrounds = [
          for (final c in cardBackgrounds) c.id == row.id ? row : c,
        ];
      }
      await _refreshPictures();
      await chooseCardBackground(id);
      return PictureBuyResult.bought;
    } on ApiException catch (e) {
      if (_token != token) return PictureBuyResult.refused;
      return cardBackgroundRefused(id, e);
    } catch (_) {
      if (_token != token) return PictureBuyResult.refused;
      notice = 'Could not reach the server.';
      return PictureBuyResult.refused;
    } finally {
      buyingCardBackground = null;
      notifyListeners();
    }
  }

  /// What a refused purchase of card back [id] means to the player —
  /// [tablePictureRefused]'s reading for the Cards shelf: a hammer or diamond
  /// shortage (`picture_chips`) is the offer of that wallet's shelf, which
  /// the caller makes, and the count held here is read again; a chip-priced
  /// back refused at a table (`seated` — seated, leaving one, or a last hand
  /// still being saved) is said in the player's language, as the shelf says
  /// it before asking; anything else is the server's sentence.
  @visibleForTesting
  PictureBuyResult cardBackgroundRefused(int id, ApiException e) {
    final card = cardBackgrounds.where((c) => c.id == id).firstOrNull;
    if (e.code == 'picture_chips' &&
        card != null &&
        (card.pricedInHammers || card.pricedInDiamonds)) {
      unawaited(refreshUser());
      return PictureBuyResult.notEnough;
    }
    notice = e.code == 'seated' ? t.cardChipsLobbyOnly : e.message;
    return PictureBuyResult.refused;
  }

  /// A session has ended (a sign-out, a deleted account): the card backs this
  /// account owns, and a purchase it had out, are nothing to the next — and
  /// the backs decoded for it are let go ([CardBackImages.release]): a card
  /// the next session draws decodes its back again, from the phone.
  void _forgetCardBackgrounds() {
    cardBackgrounds = const [];
    buyingCardBackground = null;
    CardBackImages.release();
  }

  /// Wakes at the next moment a card back this phone holds runs out (owner,
  /// 3 Oct 2026: "when validity of premium card expires, it restores default
  /// card"): a seat's at this table, the account's chosen one, or a rental
  /// the Cards shelf lists as this player's. Every reader of a back goes
  /// through the clock ([liveCardBack], [CardBackground.lapsedAt]), so the
  /// one notify this sends at that moment is all it takes for the felt, the
  /// viewer's own hand and an open Cards shelf to show the Royal Fox — the
  /// seat's cards before the server's next room:state, the shelf's tile its
  /// padlock and price and the Royal Fox's "In use" — and nothing rebuilds in
  /// between: one timer for the earliest moment, never a tick.
  ///
  /// When the back was the player's OWN — the account's, or one of their
  /// rentals — the catalogue and the account are read again, as the lobby's
  /// rental watch reads them ([checkRental]), in the lobby and at a table
  /// alike: the read is where the server takes a lapsed back off.
  Timer? _cardBackLapse;

  /// The moment [_cardBackLapse] is set for, epoch ms.
  int _cardBackLapseAt = 0;

  /// The furthest ahead [_cardBackLapse] is set: a rental ten days off is
  /// woken for once a day until its day comes, so no timer outlives what a
  /// platform's timer can hold.
  static const _cardBackLapseHorizon = Duration(days: 1);

  /// The table, account and catalogue the watch last looked at, and when:
  /// a notify that changed none of them — the one-second tick's — costs three
  /// comparisons and arms nothing.
  RoomState? _lapseRoom;
  User? _lapseUser;
  List<CardBackground>? _lapseCatalogue;
  int _lapseLookedAt = 0;

  /// Set by [_cardBacksLapsed]: the next look is due although nothing it
  /// reads has changed — the clock has.
  bool _lapseDue = false;

  /// Every change this state makes reaches the screen through here, so the
  /// card-back watch looks again whenever the table, the account or the
  /// catalogue may have changed ([_watchCardBackLapses]).
  @override
  void notifyListeners() {
    _watchCardBackLapses();
    super.notifyListeners();
  }

  /// Sets [_cardBackLapse] for the earliest card back still to run out, and
  /// reads the catalogue and the account again when one of the player's own
  /// has run out since the last look.
  void _watchCardBackLapses() {
    if (_disposed) return;
    final table = room;
    final account = user;
    final catalogue = cardBackgrounds;
    if (!_lapseDue &&
        identical(table, _lapseRoom) &&
        identical(account, _lapseUser) &&
        identical(catalogue, _lapseCatalogue)) {
      return;
    }
    _lapseDue = false;
    _lapseRoom = table;
    _lapseUser = account;
    _lapseCatalogue = catalogue;
    final now = cardBackClock().millisecondsSinceEpoch;
    // The first look counts nothing as run out since: a back that arrived
    // already over is the Royal Fox by the clock alone, and the read that
    // brought it is the server's word on it.
    final since = _lapseLookedAt == 0 ? now : _lapseLookedAt;
    _lapseLookedAt = now;
    var next = 0;
    var ownRanOut = false;
    void watch(int at, {bool own = false}) {
      if (at <= 0) return;
      if (at <= now) {
        if (own && at > since) ownRanOut = true;
        return;
      }
      if (next == 0 || at < next) next = at;
    }

    // A poker room's felt keeps the Royal Fox whatever its snapshot says.
    if (table != null && !table.isPoker) {
      for (final seat in table.seats) {
        watch(seat.cardBackground?.expiresAt ?? 0);
      }
    }
    watch(account?.cardBackground?.expiresAt ?? 0, own: true);
    for (final card in catalogue) {
      // A free back never runs out, whatever term its row still reports.
      if (card.owned && !card.free) watch(card.expiresAt, own: true);
    }
    _cardBackLapse?.cancel();
    _cardBackLapse = null;
    _cardBackLapseAt = next;
    if (next > 0) {
      final wait = Duration(milliseconds: next - now);
      _cardBackLapse = Timer(
        wait < _cardBackLapseHorizon ? wait : _cardBackLapseHorizon,
        _cardBacksLapsed,
      );
    }
    if (ownRanOut && _token != null) unawaited(_refreshPictures());
  }

  /// [_cardBackLapse] has fired: a back has run out — every listener reads
  /// the clock again — or it woke early (the horizon, or a timer a hair
  /// ahead of the wall clock), and it is set again without a word.
  void _cardBacksLapsed() {
    _cardBackLapse = null;
    if (_disposed) return;
    _lapseDue = true;
    if (cardBackClock().millisecondsSinceEpoch < _cardBackLapseAt) {
      _watchCardBackLapses();
      return;
    }
    notifyListeners();
  }

  // --------------------------------------------------------------- emojis

  /// Loads the emoji catalogue and warms every emoji into [PictureCache], so
  /// the store, the table's emoji page and a seat playing one draw it from
  /// the phone: a URL is fetched once and kept.
  ///
  /// The answer is dropped if the session changed while it was asked — a
  /// sign-out, or somebody else signing in — since `owned` is per viewer.
  Future<void> _loadEmojis() async {
    final token = _token;
    try {
      final got = await _api.emojis(token: token);
      if (_token != token) return;
      emojis = got;
      PictureCache.warm(got.map((e) => absoluteUrl(e.url)).nonNulls);
      notifyListeners();
    } catch (_) {
      // The Emojis shelf and the table's emoji page keep what they had.
    }
  }

  /// Re-reads the emoji catalogue: after the store is opened on it, and when
  /// a send is refused because this phone's copy was out of date.
  Future<void> reloadEmojis() => _loadEmojis();

  /// Whether a refusal says the emoji catalogue held here is out of date.
  static bool _emojiStale(String? code) =>
      code == 'emoji_locked' ||
      code == 'emoji_retired' ||
      code == 'unknown_emoji';

  /// Set while an emoji is being bought, for that tile's spinner.
  int? buyingEmoji;

  /// Buys a premium emoji. Owning it is all there is — an emoji is never
  /// worn — so one request, then the catalogue is re-read so the shelf and
  /// the table's emoji page stop drawing a padlock on it.
  Future<PictureBuyResult> buyEmoji(int id) async {
    final token = _token;
    if (token == null || buyingEmoji != null) {
      return PictureBuyResult.refused;
    }
    buyingEmoji = id;
    notifyListeners();
    try {
      final bought = await _api.buyEmoji(token, id);
      user = bought.user;
      await _loadEmojis();
      return PictureBuyResult.bought;
    } on ApiException catch (e) {
      return emojiRefused(id, e);
    } catch (_) {
      notice = 'Could not reach the server.';
      return PictureBuyResult.refused;
    } finally {
      buyingEmoji = null;
      notifyListeners();
    }
  }

  /// What a refused purchase of emoji [id] means to the player —
  /// [pictureRefused]'s reading for the emoji shelf: a hammer or diamond
  /// shortage (`emoji_unaffordable`) is the offer of that wallet's shelf,
  /// which the caller makes; a chip-priced emoji refused at a table
  /// (`seated`) is said in the player's language, and so is every other
  /// emoji refusal ([refusalText]).
  @visibleForTesting
  PictureBuyResult emojiRefused(int id, ApiException e) {
    final emoji = emojis.where((p) => p.id == id).firstOrNull;
    if (e.code == 'emoji_unaffordable' &&
        emoji != null &&
        (emoji.pricedInHammers || emoji.pricedInDiamonds)) {
      unawaited(refreshUser());
      return PictureBuyResult.notEnough;
    }
    notice = e.code == 'seated'
        ? t.emojiChipsLobbyOnly
        : refusalText(e.code, e.message);
    if (_emojiStale(e.code)) unawaited(_loadEmojis());
    return PictureBuyResult.refused;
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

  /// Deletes this account, permanently, at the player's request.
  ///
  /// Google Play requires an in-app route to this. The server refuses while
  /// the player is seated, so callers should only offer it from the lobby.
  ///
  /// The device id is replaced, not just the token cleared. Guest accounts are
  /// keyed to it, so a player who deletes and immediately plays again should
  /// arrive as somebody new rather than as the same device wearing a fresh
  /// account — which is what reusing the id would give them, since deletion
  /// frees the identity server-side for exactly that reason.
  ///
  /// Returns null on success, or a message to show when the server refused.
  Future<String?> deleteAccount() async {
    final token = _token;
    if (token == null) return null;
    try {
      await _api.deleteAccount(token);
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not reach the server.';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    // A NEW device id, not merely a cleared one. _deviceId is read into memory
    // once in start(), so removing the stored key alone leaves this session
    // still holding the deleted account's id — signing straight back in would
    // reuse it, and the rotation would only happen on the next cold start.
    // Replacing it here keeps memory and storage saying the same thing.
    _deviceId = const Uuid().v4();
    await prefs.setString('deviceId', _deviceId);
    _token = null;
    _conn.disconnect();
    room = null;
    seatedAt = null;
    user = null;
    luckyDraw = null;
    luckyDrawFailed = false;
    rewardPrograms = null;
    rewardProgramsFailed = false;
    rewardsGranted = null;
    _forgetRewardOffers();
    welcomePending = null;
    friends.reset();
    reports.reset();
    _forgetCardBackgrounds();
    xpMissions.clear();
    levelUps.clear();
    _awardsAwaitingLadder.clear();
    _heldStandings.clear();
    _xpSeen = null;
    screen = Screen.login;
    notifyListeners();
    return null;
  }

  /// Whether this table is closed to the player because of their stack.
  bool cappedOut(int boot, String category) =>
      config.cappedFor(user?.chips ?? 0, boot: boot, category: category);

  /// Whether [table] is shut to this player as they stand: they have outgrown
  /// its ceiling, or have not yet reached its floor.
  ///
  /// One answer for both jobs — the lobby orders its cards by this and each
  /// card draws itself by it — so the rail can never file a card under
  /// "you can join these" and then show it padlocked.
  bool tableShut(LobbyTable table) {
    final chips = user?.chips ?? 0;
    return table.tooRich(chips) ||
        table.tooPoor(chips) ||
        cappedOut(table.bootAmount, table.category);
  }

  // ---------------------------------------------------------- lobby levels

  /// The engine whose games the lobby is showing, or null at the front.
  ///
  /// The lobby is three levels in one rail (owner, 23 Sep 2026: "IN UI also
  /// give two cards: Teen Patti and Poker. inside TeenPatti give seen, blind
  /// and variation. Inside poker give three card poker, five card draw, texas
  /// holdem, omaha"): the ENGINES at the front, an engine's CATEGORIES inside
  /// it, a category's TABLES inside that. It was two levels from 18 Sep 2026,
  /// with Seen, Blind, Variation and Poker all on the front.
  ///
  /// Kept here rather than in the lobby's own State for two reasons: the
  /// system Back key (main.dart's `_BackGuard`) has to know a level is open so
  /// it can close it before it offers to quit, and it has to outlive the
  /// lobby widget — a player who leaves a Blind table comes back to the Blind
  /// tables, not to the front door. It is a place in the app, not a
  /// preference, so it is not saved: a fresh launch opens on the front.
  ///
  /// Since 27 Sep 2026 a build without the Poker family ([AppFeatures.poker],
  /// off by default) is two levels again: Teen Patti is the only engine left
  /// to show, so its categories stand on the front ([lobbyFrontEngine]) and
  /// this is set only while one of them is open.
  String? get lobbyEngine => _lobbyEngine;
  String? _lobbyEngine;

  /// The category whose tables the lobby is showing, inside [lobbyEngine];
  /// null while it shows that engine's categories, or the front. Never set
  /// without [lobbyEngine]: every way in goes through [openLobbyCategory].
  String? get lobbyCategory => _lobbyCategory;
  String? _lobbyCategory;

  /// The order the front cards are shown in when the server names no engines
  /// ([GameConfig.engines], which order them where it does).
  static const lobbyEngineOrder = [TableEngine.teenPatti, TableEngine.poker];

  /// Whether the lobby shows [engine]'s tables at all. Every engine does,
  /// but Poker only in a build with the Poker family ([AppFeatures.poker];
  /// owner, 27 Sep 2026: "In UI only show three cards seen, blind,
  /// variation"). The server still offers its poker tables: a hidden engine's
  /// tables are simply left out of everything the lobby reads — its cards,
  /// their counts, their table lists — so no card counts a table it will not
  /// show.
  static bool lobbyShowsEngine(String engine) =>
      AppFeatures.poker || engine != TableEngine.poker;

  /// The menu's tables the lobby shows ([lobbyShowsEngine]), in the server's
  /// order.
  Iterable<LobbyTable> get _lobbyMenu =>
      config.tables.where((table) => lobbyShowsEngine(lobbyEngineOf(table)));

  /// Which categories each engine plays, in the order its cards are shown,
  /// when the server names no engines — `session:ready`, an older server,
  /// the fallback menu. The same taxonomy the server seeds (`table_engines`,
  /// `table_categories`), so the lobby looks the same whichever source the
  /// menu came from.
  static const lobbyTaxonomy = <String, List<String>>{
    TableEngine.teenPatti: [
      TableCategory.seen,
      TableCategory.blind,
      TableCategory.variation,
    ],
    TableEngine.poker: [
      TableCategory.threeCardPoker,
      TableCategory.fiveCardDraw,
      TableCategory.texasHoldem,
      TableCategory.omaha,
    ],
  };

  /// The front card a menu entry is filed under: its engine.
  ///
  /// The table catalogue names it ([LobbyTable.engine], owner, 23 Sep 2026:
  /// "Teen Patti engines / Poker engines"), and an engine this build has never
  /// heard of gets a card of its own ([lobbyEngineServerName] names it). Where
  /// the server names none (`session:ready`, an older server), a poker table
  /// is Poker's and everything else Teen Patti's.
  static String lobbyEngineOf(LobbyTable table) {
    final engine = table.engine;
    if (engine != null && engine.isNotEmpty) return engine;
    return table.isPoker ? TableEngine.poker : TableEngine.teenPatti;
  }

  /// The category card a menu entry is filed under, inside its engine
  /// ([lobbyEngineOf]).
  ///
  /// Where the catalogue names the engine, the category is the server's own —
  /// a Teen Patti category this build has never heard of is a card of its
  /// own, named by the server ([lobbyServerName]). Where it does not, a poker
  /// table goes under its game, and a Teen Patti category this build has
  /// never heard of is a seen table everywhere else in the client (its card,
  /// its felt, its rules line), so it is one here too.
  static String lobbyCategoryOf(LobbyTable table) {
    final engine = lobbyEngineOf(table);
    final category = table.category;
    if (engine != TableEngine.teenPatti) {
      // A table with no category at all has nowhere else to go than a card
      // named by its engine.
      return category.isNotEmpty ? category : engine;
    }
    if (table.engine != null && category.isNotEmpty) return category;
    return category == TableCategory.blind ||
            category == TableCategory.variation
        ? category
        : TableCategory.seen;
  }

  /// The front cards: every engine the server offers at least one table in,
  /// and no other.
  ///
  /// In the order of [GameConfig.engines] when the server names them — by
  /// their sortOrder, so the order is the server's to change — else
  /// [lobbyEngineOrder], Teen Patti then Poker. An engine the list does not
  /// place (a table naming an engine the list leaves out) still comes, after
  /// the rest, rather than taking its tables away.
  List<String> get lobbyEngines {
    final offered = {for (final table in _lobbyMenu) lobbyEngineOf(table)};
    final cards = <String>[];
    void place(String card) {
      if (offered.contains(card) && !cards.contains(card)) cards.add(card);
    }

    for (final engine in _bySortOrder(config.engines, (e) => e.sortOrder)) {
      place(engine.code);
    }
    lobbyEngineOrder.forEach(place);
    offered.forEach(place);
    return cards;
  }

  /// The engine whose category cards stand on the FRONT of the lobby, in
  /// place of the engine cards — or null where the front shows the engines.
  ///
  /// A build without the Poker family ([AppFeatures.poker] off) shows one
  /// engine, and an engine card alone on the front would be a door to a
  /// corridor: the owner asked for Seen, Blind and Variation themselves
  /// (27 Sep 2026: "In UI only show three cards seen, blind, variation"). So
  /// where exactly one engine is left to show, the engine level is skipped.
  /// With the Poker family on the lobby is exactly the three levels of
  /// 23 Sep 2026, even on a menu that happens to offer one engine.
  String? get lobbyFrontEngine {
    if (AppFeatures.poker) return null;
    final engines = lobbyEngines;
    return engines.length == 1 ? engines.single : null;
  }

  /// One engine's category cards: every category of [engine] the server
  /// offers at least one table in, and no other.
  ///
  /// In the order of that engine's categories in [GameConfig.engines], by
  /// their sortOrder, when the server names them; else [lobbyTaxonomy] —
  /// Seen, Blind, Variation; 3-Card Poker, 5-Card Draw, Texas Hold'em, Omaha.
  /// A category neither places still comes, after the rest.
  List<String> lobbyCategoriesIn(String engine) {
    final offered = {
      for (final table in _lobbyMenu)
        if (lobbyEngineOf(table) == engine) lobbyCategoryOf(table),
    };
    final cards = <String>[];
    void place(String card) {
      if (offered.contains(card) && !cards.contains(card)) cards.add(card);
    }

    for (final info in config.engines) {
      if (info.code != engine) continue;
      for (final category in _bySortOrder(
        info.categories,
        (c) => c.sortOrder,
      )) {
        place(category.code);
      }
    }
    (lobbyTaxonomy[engine] ?? const <String>[]).forEach(place);
    offered.forEach(place);
    return cards;
  }

  /// [items] by [sortOrder], lower first, keeping the server's order among
  /// equals — Dart's List.sort is not stable, and a tie must not shuffle the
  /// lobby from one build of the menu to the next.
  static List<T> _bySortOrder<T>(List<T> items, int Function(T) sortOrder) {
    final indexed = items.indexed.toList()
      ..sort((a, b) {
        final bySort = sortOrder(a.$2).compareTo(sortOrder(b.$2));
        return bySort != 0 ? bySort : a.$1.compareTo(b.$1);
      });
    return [for (final (_, item) in indexed) item];
  }

  /// The server's own name for an ENGINE, from [GameConfig.engines], or null
  /// when it names none (no catalogue, or an empty name). An admin label, not
  /// a translation: the lobby names Teen Patti and Poker in the player's own
  /// language and reads this only for an engine it has never heard of, which
  /// is better named in English than passed off as one it knows.
  String? lobbyEngineServerName(String engine) {
    for (final info in config.engines) {
      if (info.code == engine) return info.name.isEmpty ? null : info.name;
    }
    return null;
  }

  /// The server's own name for a CATEGORY, from the categories of
  /// [GameConfig.engines], or null when it names none. Read, like
  /// [lobbyEngineServerName], only for a code this build has never heard of.
  String? lobbyServerName(String category) {
    for (final engine in config.engines) {
      for (final info in engine.categories) {
        if (info.code == category) return info.name.isEmpty ? null : info.name;
      }
    }
    return null;
  }

  /// Every table of [engine], as its front card counts them.
  List<LobbyTable> lobbyTablesOf(String engine) => [
    for (final table in _lobbyMenu)
      if (lobbyEngineOf(table) == engine) table,
  ];

  /// One category's tables as the lobby shows them: the ones this player can
  /// sit at, then the ones shut to their stack, each group in the server's
  /// order — which is the order of the stakes. [engine], when given, keeps a
  /// category code two engines might share to the one being shown.
  ///
  /// Bucketed rather than sorted because Dart's List.sort is not stable.
  /// Putting a padlocked card between two open ones makes a player scroll past
  /// a wall to reach a room they are allowed into; putting them last turns the
  /// same cards into the thing to play towards.
  List<LobbyTable> lobbyTablesIn(String category, {String? engine}) {
    final open = <LobbyTable>[];
    final shut = <LobbyTable>[];
    for (final table in _lobbyMenu) {
      if (lobbyCategoryOf(table) != category) continue;
      if (engine != null && lobbyEngineOf(table) != engine) continue;
      (tableShut(table) ? shut : open).add(table);
    }
    return [...open, ...shut];
  }

  /// Goes into [engine]'s categories, from wherever the lobby is. An engine
  /// the server does not offer is ignored. Where that engine's categories are
  /// the front ([lobbyFrontEngine]), that is the front.
  void openLobbyEngine(String engine) {
    if (!lobbyEngines.contains(engine)) return;
    final shown = engine == lobbyFrontEngine ? null : engine;
    if (_lobbyEngine == shown && _lobbyCategory == null) return;
    _lobbyEngine = shown;
    _lobbyCategory = null;
    notifyListeners();
  }

  /// Goes into [category]'s tables — inside [engine], or, when none is named,
  /// inside the engine that offers it (the open one first). Opens that engine
  /// too, so Back leaves the category for its engine's categories and only
  /// then for the front. A category the server does not offer is ignored.
  void openLobbyCategory(String category, {String? engine}) {
    final home = engine ?? _engineOffering(category);
    if (home == null || !lobbyCategoriesIn(home).contains(category)) return;
    if (_lobbyEngine == home && _lobbyCategory == category) return;
    _lobbyEngine = home;
    _lobbyCategory = category;
    notifyListeners();
  }

  String? _engineOffering(String category) {
    final open = _lobbyEngine;
    if (open != null && lobbyCategoriesIn(open).contains(category)) {
      return open;
    }
    for (final engine in lobbyEngines) {
      if (lobbyCategoriesIn(engine).contains(category)) return engine;
    }
    return null;
  }

  /// Back one level: from a category's tables to its engine's categories,
  /// from an engine's categories to the front. Where those categories ARE the
  /// front ([lobbyFrontEngine]), a category's tables go back to the front in
  /// one step. Answers whether there was a level to close, which is how the
  /// Back key knows it has been used.
  bool closeLobbyLevel() {
    if (_lobbyCategory != null) {
      _lobbyCategory = null;
      if (lobbyFrontEngine != null) _lobbyEngine = null;
    } else if (_lobbyEngine != null) {
      _lobbyEngine = null;
    } else {
      return false;
    }
    notifyListeners();
    return true;
  }

  /// Wears a catalogue picture, or null to go back to the provider photo.
  ///
  /// The catalogue is re-read afterwards, and not awaited: a premium picture is
  /// a rental, so the answer to "may I still wear this" changes with the clock
  /// rather than with anything the player did. Asking again on the way out of
  /// this action is what re-locks a term that ran out while the lobby was
  /// open — the listing is also where the server takes a lapsed picture off —
  /// and doing it unawaited keeps the tick itself instant.
  Future<void> chooseAvatar(int? id) async {
    final token = _token;
    if (token == null) return;
    try {
      user = await _api.setAvatar(token, id);
    } on ApiException catch (e) {
      notice = e.message;
    }
    notifyListeners();
    unawaited(_refreshPictures());
  }

  /// Watches the rental on the picture the player is wearing, in the lobby.
  ///
  /// Every seven seconds it re-reads the catalogue, which is where the server
  /// takes a lapsed picture off and re-locks it. If the term has run out the
  /// player is back on their default face and has to buy it again.
  ///
  /// It asks the SERVER rather than comparing the deadline it already holds,
  /// and that is the second attempt: deciding locally costs nothing and is
  /// right whenever the expiry is the one the client was told at purchase, but
  /// it cannot see a term that changed underneath it — an expiry edited
  /// directly, a clock that disagrees — and then the picture never comes off.
  /// The authority on when a rental ends is the server, so the watch asks it.
  ///
  /// Two things keep that from being a poll worth worrying about. It runs only
  /// in the LOBBY — at a table the picture cannot change anyway (requirement
  /// 21), and taking one off mid-hand would be a change nobody asked for — and
  /// only while the player is wearing a PREMIUM picture, which is the only kind
  /// that can lapse. A player on a free face never makes the call at all.
  ///
  /// A chosen card back is watched the same way (owner, 3 Oct 2026): the
  /// catalogue's read is where the server takes a lapsed back off, and the
  /// account read after it comes back without one.
  void _checkRental() => unawaited(checkRental());

  /// One look of the watch ([_checkRental]), answering when its re-read is
  /// done — at once when there is nothing that can lapse — so a test can
  /// await it.
  @visibleForTesting
  Future<void> checkRental() {
    if (screen != Screen.lobby || _rentalRefreshing) return Future.value();
    final worn = user?.activePictureId;
    final laid = user?.activeTablePictureId;
    final backed = user?.activeCardBackgroundId;
    if (worn == null && laid == null && backed == null) return Future.value();

    // Nothing to watch unless what they are wearing — on their face, on
    // their table or on their cards — can actually run out.
    final premium =
        pictures.any((p) => p.id == worn && !p.free) ||
        tablePictures.any((p) => p.id == laid && !p.free) ||
        cardBackgrounds.any((c) => c.id == backed && !c.free);
    if (!premium) return Future.value();

    _rentalRefreshing = true;
    return _refreshPictures().whenComplete(() {
      _rentalRefreshing = false;
    });
  }

  /// Guards the watch against stacking refreshes if one is slow.
  bool _rentalRefreshing = false;

  /// Re-reads the catalogue and the account together, so a rental that lapsed
  /// takes its picture off the player as well as re-locking it on the shelf.
  Future<void> _refreshPictures() async {
    await _loadPictures();
    final token = _token;
    if (token == null) return;
    try {
      user = await _api.me(token);
      notifyListeners();
    } catch (_) {
      // Offline or reconnecting; the next update catches up.
    }
  }

  /// Set while a picture purchase is with the server, so the picker can show
  /// progress on that one tile instead of looking unresponsive.
  int? buyingPicture;

  /// Buys a premium picture and, when that works, puts it on.
  ///
  /// Two requests rather than one: the server sells and dresses separately so
  /// the refusals stay separate, and this is the one place that wants both.
  /// Says [PictureBuyResult.bought] when the player ends up wearing it.
  Future<PictureBuyResult> buyPicture(int id) async {
    final token = _token;
    if (token == null || buyingPicture != null) {
      return PictureBuyResult.refused;
    }
    buyingPicture = id;
    notifyListeners();
    try {
      final bought = await _api.buyPicture(token, id);
      user = bought.user;
      // The catalogue carries `owned` per viewer, so it has to be re-read
      // before the picker can stop drawing a padlock on what was just bought.
      await _refreshPictures();
      await chooseAvatar(id);
      return PictureBuyResult.bought;
    } on ApiException catch (e) {
      return pictureRefused(id, e);
    } catch (_) {
      notice = 'Could not reach the server.';
      return PictureBuyResult.refused;
    } finally {
      buyingPicture = null;
      notifyListeners();
    }
  }

  /// What a refused purchase of picture [id] means to the player.
  ///
  /// The server answers every shortage with the one code `picture_chips`,
  /// whichever wallet came up short, in an English sentence — so the
  /// picture's own currency decides, never the message (owner, 14 Sep 2026).
  /// A hammer or diamond picture is not a notice but the offer of that
  /// wallet's shelf, which the caller makes; the count held here was wrong, so
  /// it is read again. A chip shortage keeps the server's sentence, and a
  /// chip-priced picture refused at a table (`seated`) is said in the player's
  /// language.
  @visibleForTesting
  PictureBuyResult pictureRefused(int id, ApiException e) {
    final picture = pictures.where((p) => p.id == id).firstOrNull;
    if (e.code == 'picture_chips' &&
        picture != null &&
        (picture.pricedInHammers || picture.pricedInDiamonds)) {
      unawaited(refreshUser());
      return PictureBuyResult.notEnough;
    }
    notice = e.code == 'seated' ? t.pictureChipsLobbyOnly : e.message;
    return PictureBuyResult.refused;
  }

  /// What just landed in a wallet in the lobby, while its celebration is on
  /// screen: a chip pack (`purchase`), a diamond or hammer pack, a Premium
  /// Package (`premium`), a missile trade (`missiles`). Null the rest of the
  /// time. (The lobby's three rewards — the 4-hour and daily bonuses and the
  /// milestone — celebrated here too until the owner took them away,
  /// 30 Sep 2026.)
  ///
  /// `amount` is the headline figure. `missiles` and `hammers` are what a
  /// Premium Package (kind `premium`, owner 14 Sep 2026) brought with its
  /// chips, shown under that figure; every other kind carries 0 or repeats
  /// its own count there.
  ({String kind, int amount, int missiles, int hammers})? rewardWon;

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

    // Otherwise send them to the store: the link the SERVER named for this
    // platform (the version gate's store_url — Play on Android, the App Store
    // on iOS), and only when it named none the app's own pair — the store app
    // first, its web page second (net/app_update.dart picks it).
    if (!ok) {
      final named = (appGate ?? softUpdate ?? _announced)?.storeUrl;
      for (final uri in named != null ? [named] : storeListingUris()) {
        try {
          ok = await openStoreUrl(Uri.parse(uri));
        } catch (_) {
          ok = false;
        }
        if (ok) break;
      }
    }

    updating = false;
    // No store could be opened: said, never a crash.
    if (!ok) notice = t.updateStoreUnavailable;
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
        notice = switch (message) {
          Purchases.notLaunched => t.purchaseNotLaunched,
          Purchases.finishingEarlier => t.purchaseFinishingEarlier,
          _ => message,
        };
        notifyListeners();
      }
      ..onDeliver = _deliverPurchase;
    unawaited(purchases.start());
  }

  /// Hands one receipt to the server and, if it banks the chips, reports true
  /// so the purchase can be consumed with Play.
  ///
  /// Returning false is not a failure to swallow — it leaves the purchase
  /// owned with Play, and the next session's `purchases.redeliver()` (on
  /// `session:ready`) posts it again. That is the safety net for dying, or
  /// losing the network, between paying and crediting, and the reason this
  /// must never return true on a path that did not credit.
  Future<bool> _deliverPurchase(PurchaseDetails purchase) async {
    final token = _token;
    if (token == null) return false; // signed out; Play will bring it back
    final receipt = purchase.verificationData.serverVerificationData;
    if (receipt.isEmpty) return false;

    try {
      final r = await _api.redeemPurchase(
        token,
        purchase.productID,
        receipt,
        appStore: purchases.store == Store.appStore,
      );
      if (r.user != null) user = r.user;
      purchasePending = false;
      // `credited` false means the server had already banked this receipt.
      // Still a success: the chips are in the wallet and the transaction
      // should be finished rather than delivered again.
      if (r.credited) {
        announcePurchase(
          chips: r.chips,
          diamonds: r.diamonds,
          hammers: r.hammers,
          missiles: r.missiles,
          badge: r.badge,
          badgeExpiresAt: r.badgeExpiresAt,
        );
      }
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      purchasePending = false;
      notice = e.message;
      notifyListeners();
      // The server refused the receipt itself — Google would not confirm it,
      // or the product is unknown: finishing it stops an endless redelivery
      // of something that will never be accepted. Any other refusal (a
      // lapsed session, Google or the server down) is not a verdict on the
      // purchase, which stays owned for the next session to post again.
      return receiptRefusalIsFinal(e.status);
    } catch (_) {
      // Network or server trouble: keep the purchase owned so the next
      // session retries. The player has paid and must not lose the chips.
      purchasePending = false;
      notifyListeners();
      return false;
    }
  }

  /// Tells the player what a credited Play purchase put in their wallet
  /// (the caller notifies).
  ///
  /// The product decided the wallets, and the server's answer says which: a
  /// Premium Package brings chips with missiles and hammers, a hammer pack
  /// hammers, a diamond pack diamonds, and a chip pack chips. Each is
  /// celebrated. A Premium Package bought at a table, where the celebration is
  /// not drawn, is a notice naming all three instead — as a missile trade
  /// there is.
  @visibleForTesting
  void announcePurchase({
    required int chips,
    required int diamonds,
    required int hammers,
    required int missiles,
    String? badge,
    int badgeExpiresAt = 0,
  }) {
    // A badge (owner, 27 Sep 2026: "Add a icon in Store to buy badges"): the
    // account the server answered with already holds it; the notice names
    // it, with its mark, and the day it runs out.
    if (badge != null) {
      PlayerBadge? held;
      for (final b in user?.badges ?? const <PlayerBadge>[]) {
        if (b.code == badge) held = b;
      }
      final name = held == null
          ? badge
          : held.icon.isEmpty
          ? held.title
          : '${held.icon} ${held.title}';
      final until = DateTime.fromMillisecondsSinceEpoch(
        badgeExpiresAt > 0 ? badgeExpiresAt : held?.expiresAt ?? 0,
      );
      notice = badgeExpiresAt > 0 || (held?.expiresAt ?? 0) > 0
          ? t.badgeBought(
              name,
              '${until.day.toString().padLeft(2, '0')}/'
              '${until.month.toString().padLeft(2, '0')}/${until.year}',
            )
          : name;
      return;
    }
    if (chips > 0 && (missiles > 0 || hammers > 0)) {
      if (screen == Screen.table) {
        notice = t.premiumAdded(formatChips(chips), missiles, hammers);
      } else {
        rewardWon = (
          kind: 'premium',
          amount: chips,
          missiles: missiles,
          hammers: hammers,
        );
      }
      return;
    }
    rewardWon = hammers > 0
        ? (kind: 'hammers', amount: hammers, missiles: 0, hammers: hammers)
        : diamonds > 0
        ? (kind: 'diamonds', amount: diamonds, missiles: 0, hammers: 0)
        : (kind: 'purchase', amount: chips, missiles: 0, hammers: 0);
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

  /// Takes up the quick messages this phone saved — the order
  /// ([moveQuickMessage]) and the player's own lines ([addCustomQuickMessage])
  /// — at start-up with the rest of the preferences.
  void restoreQuickOrder(SharedPreferences prefs) {
    _quickOrder = parseQuickOrder(prefs.getStringList(quickOrderPrefsKey));
    _quickCustom = decodeCustomQuickMessages(
      prefs.getString(quickCustomPrefsKey),
    );
  }

  /// Moves the quick message at position [from] of [quickMessageOrder] to
  /// [to], as the chat drawer's reorderable list reports a drag, and keeps the
  /// new order on this phone (owner, 25 Sep 2026: "save that order in UI
  /// only"). The list redraws at once; the write follows, and a write that
  /// fails leaves the order for this session, not an error.
  Future<void> moveQuickMessage(int from, int to) async {
    final next = moveInQuickOrder(quickMessageOrder, from, to);
    if (listEquals(next, quickMessageOrder)) return;
    _quickOrder = next;
    notifyListeners();
    await _saveQuickMessages();
  }

  /// Saves [raw] as a quick message of the player's own, at the top of the
  /// list, kept on this phone (owner, 25 Sep 2026: "when user clicks and type
  /// and save that typed message will be seen in quick message list"). It is
  /// kept as the server will read it ([cleanQuickMessage]), and refused when
  /// there is nothing left to say, when the list already says exactly that,
  /// or when the player already keeps [maxCustomQuickMessages] of their own.
  Future<QuickAddResult> addCustomQuickMessage(String raw) async {
    final text = cleanQuickMessage(raw);
    if (text.isEmpty) return QuickAddResult.empty;
    if (t.quickMessages.contains(text) ||
        _quickCustom.any((line) => line.text == text)) {
      return QuickAddResult.duplicate;
    }
    if (_quickCustom.length >= maxCustomQuickMessages) {
      return QuickAddResult.full;
    }
    final line = CustomQuickMessage(id: const Uuid().v4(), text: text);
    // The order as it stands, with the new line first — so an old install's
    // order, never saved, is written down whole here.
    final order = [customQuickKey(line.id), ...quickMessageOrder];
    _quickCustom = [..._quickCustom, line];
    _quickOrder = order;
    notifyListeners();
    await _saveQuickMessages();
    return QuickAddResult.added;
  }

  /// Takes the player's own quick message [id] off the list, and off the
  /// phone. A set line cannot be removed; an id that is not theirs does
  /// nothing.
  Future<void> removeCustomQuickMessage(String id) async {
    if (!_quickCustom.any((line) => line.id == id)) return;
    _quickCustom = [
      for (final line in _quickCustom)
        if (line.id != id) line,
    ];
    _quickOrder = quickMessageOrder;
    notifyListeners();
    await _saveQuickMessages();
  }

  /// Writes the quick messages down — the order and the player's own lines,
  /// both, so the two can never disagree after a restart. A write that fails
  /// leaves them for this session, not an error: only the next launch loses
  /// them.
  Future<void> _saveQuickMessages() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        quickCustomPrefsKey,
        encodeCustomQuickMessages(_quickCustom),
      );
      await prefs.setStringList(quickOrderPrefsKey, _quickOrder);
    } catch (_) {
      // Only the next launch loses it.
    }
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

  /// Joins a table by its code, once the code has the shape of one: exactly
  /// [tableCodeLength] letters or digits. The server refuses anything else as
  /// `invalid_room_code`; checking here as well saves the round trip and says
  /// so in the player's own language.
  void joinByCode(String code) {
    final normal = code.trim().toUpperCase();
    if (!isValidTableCode(normal)) {
      notice = t.invalidTableCode;
      notifyListeners();
      return;
    }
    _conn.joinByCode(normal);
  }

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
        notice = refusalText(
          reply['code'] is String ? reply['code'] as String : null,
          '${reply['message'] ?? 'Could not switch table'}',
        );
      }
    } finally {
      switching = false;
      notifyListeners();
    }
  }

  /// A server refusal in the player's language.
  ///
  /// The server's messages are English by design and its codes are stable, so
  /// the words are chosen here, by code. A refusal arrives twice — in the ack
  /// and as `game:error` — and both copies come through this, so they read the
  /// same and still show as one toast. A code with no words here keeps the
  /// server's own message.
  String refusalText(String? code, String message) {
    // The poker family's refusals, said in the player's language — at a poker
    // table only, so a Teen Patti refusal that shares a code
    // (`insufficient_chips` on a show) keeps the sentence it always had.
    if (isPokerTable) {
      final poker = t.pokerRefusal(code);
      if (poker != null) return poker;
    }
    if (code == 'invalid_pick') return t.pickThreeCards;
    if (code == 'no_hammers') return t.noHammers;
    if (code == 'no_missiles') return t.noMissiles;
    // A missile's refusal, and a sideshow's: both need three in the hand, so
    // one sentence serves either.
    if (code == 'too_few_players') return t.tooFewPlayers;
    // The player's own sideshow request is still waiting for its answer, and
    // a player still choosing their three cards under 5-Card holds back a
    // Sideshow, Force Sideshow, Missile or Show (24 Sep 2026).
    if (code == 'sideshow_pending') return t.sideshowPendingRefusal;
    if (code == 'pick_pending') return t.pickPendingRefusal;
    // The emoji store and the table's emoji key (owner, 26 Sep 2026).
    if (code == 'emoji_locked') return t.emojiLockedRefusal;
    if (code == 'unknown_emoji') return t.emojiUnknownRefusal;
    if (code == 'emoji_retired') return t.emojiRetiredRefusal;
    if (code == 'emoji_unaffordable') return t.emojiUnaffordableRefusal;
    if (code == GameConnection.notConnected) return t.notConnected;
    if (code == 'over_entry_cap' || code == 'below_table_minimum') {
      // The server writes the limit with Western grouping ("500,000"); the
      // lobby card beside the refusal says "5 Lakh". Said with the card's own
      // sentence, in the player's numbering (QA PIX-5, 14 Sep 2026).
      final digits = RegExp(r'\d[\d,]*').firstMatch(message)?.group(0);
      final limit = int.tryParse(digits?.replaceAll(',', '') ?? '');
      if (limit == null) return message;
      return code == 'over_entry_cap'
          ? t.cappedBody.replaceAll('{cap}', formatChips(limit))
          : t.lockedBody.replaceAll('{min}', formatChips(limit));
    }
    if (code == 'no_other_table') {
      // The server names the table's category in English; this names it the
      // way the player's language writes it, lower case where the script has
      // case ("seen" in the English sentence, सीन in the Hindi one).
      final category = room?.category;
      if (category == null) return message;
      // A poker game keeps its proper name ("Texas Hold'em"); the Teen Patti
      // categories are written lower case, as the English sentence has them.
      return t.noOtherTable(
        TableCategory.isPoker(category)
            ? t.pokerVariantName(category)
            : (category == TableCategory.blind
                      ? t.blind
                      : category == TableCategory.variation
                      ? t.variation
                      : t.seen)
                  .toLowerCase(),
      );
    }
    return message;
  }

  /// Why the table showed this player out, in their language (QA PIX-5,
  /// 14 Sep 2026). The server's reasons are stable codes and its sentences are
  /// English — and say "coins" where the game says chips — so the words are
  /// chosen here. The idle sentence carries the count the server used; a
  /// reason with no words here keeps the server's message.
  String kickText(String reason, String message) {
    switch (reason) {
      case 'insufficient_chips':
        return t.kickedNoChips;
      case 'idle':
        final turns = int.tryParse(
          RegExp(r'\d+').firstMatch(message)?.group(0) ?? '',
        );
        return turns == null ? message : t.kickedIdle(turns);
    }
    return message;
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

  // ------------------------------------------------------- force sideshow

  /// Whether the rules allow a Force Sideshow right now: the server's word,
  /// through `you.options`. Paying for it is a separate question — [hasHammer].
  bool get canForceSideshow => myTurn && (options?.canForceSideshow ?? false);

  /// Whether this player holds the hammer a Force Sideshow costs, by the last
  /// count the server gave. The server checks again, and its count is the one
  /// that is spent.
  bool get hasHammer => (user?.hammer ?? 0) >= forceSideshowCost;

  /// Set while a Force Sideshow is with the server, so the key cannot send a
  /// second one before the first is answered.
  bool forcingSideshow = false;

  /// Until when a `no_hammers` or `persist_failed` game:error belongs to a
  /// Force Sideshow this state is already dealing with. It runs a few seconds
  /// past each answer, because the server sends the ack first and its
  /// game:error copy straight after.
  DateTime? _forceQuietUntil;

  bool _forceQuiet(String? code) {
    final until = _forceQuietUntil;
    return (code == 'no_hammers' || code == 'persist_failed') &&
        until != null &&
        DateTime.now().isBefore(until);
  }

  /// Forces a sideshow with the player on the right: one hammer, no request,
  /// no answer to wait for (owner, 13 Sep 2026).
  ///
  /// The hands come back the way an accepted sideshow's do — the reveal to the
  /// two players, the pack to the room — so there is nothing new to draw. What
  /// this adds is the count: the ack says how many hammers are left, and the
  /// wallet takes that figure at once rather than at the next `/api/auth/me`.
  ///
  /// One actionId serves the move and its retry. The server keys the hammer it
  /// spends on it, so when the hammer was taken but the table move was not
  /// (`persist_failed`), or the answer never came, asking again with the same
  /// id resolves the sideshow without taking a second hammer. It retries
  /// once, and only while the table still offers the move: an answer lost
  /// after the move DID land has already used this turn's ask.
  Future<ForceSideshowResult> forceSideshow() async {
    if (forcingSideshow || !canForceSideshow) {
      return ForceSideshowResult.refused;
    }
    forcingSideshow = true;
    notifyListeners();
    final actionId = const Uuid().v4();
    try {
      var reply = await _sendForce(actionId);
      if (_worthRetrying(reply)) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        if (canForceSideshow) reply = await _sendForce(actionId);
      }

      if (reply['ok'] == true) {
        final left = reply['hammers'];
        final u = user;
        if (left is num && u != null) user = u.withHammer(left.toInt());
        return ForceSideshowResult.forced;
      }

      // Refused. Whatever the reason, the count held here may be the thing
      // that is wrong, so it is read again.
      unawaited(refreshUser());
      final code = reply['code'] is String ? reply['code'] as String : null;
      if (code == 'no_hammers') {
        final u = user;
        if (u != null) user = u.withHammer(0);
        return ForceSideshowResult.noHammers;
      }
      // Every other refusal has already reached the player as its game:error.
      // The one quieted above is said here, and so is a request that was never
      // answered, which has no game:error at all — but only while nothing has
      // happened at the table, since a move that did land explains itself.
      final message = '${reply['message'] ?? ''}';
      if (message.isNotEmpty &&
          (code == 'persist_failed' || (code == null && canForceSideshow))) {
        notice = refusalText(code, message);
      }
      return ForceSideshowResult.refused;
    } finally {
      forcingSideshow = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _sendForce(String actionId) async {
    _forceQuietUntil = DateTime.now().add(const Duration(seconds: 3));
    final reply = await _conn.forceSideshow(actionId);
    _forceQuietUntil = DateTime.now().add(const Duration(seconds: 3));
    return reply;
  }

  /// An answer that never came (no code at all), or a hammer spent whose table
  /// move was not: both are safe to send again with the same id. Nothing else
  /// is worth repeating — the server would refuse it the same way.
  static bool _worthRetrying(Map<String, dynamic> reply) =>
      reply['ok'] != true &&
      (reply['code'] == null || reply['code'] == 'persist_failed');

  // --------------------------------------------------------------- missile

  /// Whether the rules allow a missile right now: the server's word, through
  /// `you.canMissile`, on this player's turn. Paying for it is a separate
  /// question — [hasMissile].
  bool get canMissile => myTurn && (room?.you?.canMissile ?? false);

  /// Whether this player holds the missile firing one costs, by the last
  /// count the server gave. The server checks again.
  bool get hasMissile => (user?.missile ?? 0) >= missileCost;

  /// The chips a missile needs this player to hold: what a show would cost
  /// them, their chaal (owner, 14 Sep 2026 — held, not paid; the server refuses
  /// a missile to a player short of it). The Missile key carries it as the
  /// Chaal key carries its bet. On turn it is the server's first rung; off turn,
  /// or when the player cannot reach even that, the chaal from the table's
  /// stake, which is in blind units and doubles for a seen player.
  int get missileChips {
    final steps = options?.raiseSteps ?? const [];
    if (steps.isNotEmpty) return steps.first;
    final stake = room?.stake ?? 0;
    return room?.you?.isBlind == false ? stake * 2 : stake;
  }

  /// Set while a missile is with the server, so the key cannot fire a second
  /// before the first is answered.
  bool firingMissile = false;

  /// Until when a missile refusal's game:error belongs to a missile this state
  /// is already dealing with from its ack — see [_forceQuietUntil].
  DateTime? _missileQuietUntil;

  bool _missileQuiet(String? code) {
    final until = _missileQuietUntil;
    return (code == 'no_missiles' ||
            code == 'too_few_players' ||
            code == 'insufficient_chips' ||
            code == 'persist_failed') &&
        until != null &&
        DateTime.now().isBefore(until);
  }

  /// Fires a missile: one missile, no chips, every hand still in shown and the
  /// best one takes the pot (owner, 14 Sep 2026).
  ///
  /// The table hears it as `game:action` and the showdown after it, which is
  /// what draws the volley — for this player as for everyone else. What this
  /// adds is the count the ack reports.
  ///
  /// One actionId serves the move and its retry, as for [forceSideshow]: a
  /// missile spent whose table move was not (`persist_failed`), or an answer
  /// that never came, is sent again once with the same id, and only while the
  /// table still offers the move.
  Future<MissileResult> fireMissile() async {
    if (firingMissile || !canMissile) return MissileResult.refused;
    firingMissile = true;
    notifyListeners();
    final actionId = const Uuid().v4();
    try {
      var reply = await _sendMissile(actionId);
      if (_worthRetrying(reply)) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
        if (canMissile) reply = await _sendMissile(actionId);
      }

      if (reply['ok'] == true) {
        final left = reply['missiles'];
        final u = user;
        if (left is num && u != null) user = u.withMissile(left.toInt());
        return MissileResult.fired;
      }

      unawaited(refreshUser());
      final code = reply['code'] is String ? reply['code'] as String : null;
      if (code == 'no_missiles') {
        final u = user;
        if (u != null) user = u.withMissile(0);
        return MissileResult.noMissiles;
      }
      // A missile needs the chips a show would cost the firer, held rather
      // than paid (owner, 14 Sep 2026). The key is dark while they are short,
      // so this is only met when the stack changed as the missile was sent.
      if (code == 'insufficient_chips') {
        notice = t.missileNeedsShowChips;
        return MissileResult.refused;
      }
      // The refusals quieted above are said here, and so is a request that
      // was never answered — but only while nothing has happened at the
      // table, since a missile that did land explains itself.
      final message = '${reply['message'] ?? ''}';
      if (message.isNotEmpty &&
          (code == 'too_few_players' ||
              code == 'persist_failed' ||
              (code == null && canMissile))) {
        notice = refusalText(code, message);
      }
      return MissileResult.refused;
    } finally {
      firingMissile = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _sendMissile(String actionId) async {
    _missileQuietUntil = DateTime.now().add(const Duration(seconds: 3));
    final reply = await _conn.fireMissile(actionId);
    _missileQuietUntil = DateTime.now().add(const Duration(seconds: 3));
    return reply;
  }

  /// The pack id of a trade that is with the server, so the store can show
  /// progress on that one card and refuse a second tap.
  String? tradingMissiles;

  /// Trades diamonds for the missile pack [packId] (owner, 14 Sep 2026: from
  /// 1 missile for 5 diamonds to 30 for 100), in the lobby or at a table.
  ///
  /// One requestId per attempt, sent again if the request itself fails and is
  /// retried: the server answers a replay `charged: false` without charging
  /// twice. The wallet takes the server's figures. In the lobby the missiles
  /// are celebrated the way a pack from Play is; at a table, where the
  /// celebration is not drawn, they are a notice.
  Future<MissileTradeResult> tradeMissiles(String packId) async {
    final token = _token;
    if (token == null || tradingMissiles != null) {
      return MissileTradeResult.refused;
    }
    tradingMissiles = packId;
    notifyListeners();
    final requestId = const Uuid().v4();
    try {
      ({User user, bool charged, int diamonds, int missiles}) r;
      try {
        r = await _api.tradeMissiles(token, packId, requestId);
      } on ApiException {
        rethrow;
      } catch (_) {
        // The request never got an answer: it may or may not have landed,
        // and asking again with the same id is safe either way.
        await Future<void>.delayed(const Duration(milliseconds: 700));
        r = await _api.tradeMissiles(token, packId, requestId);
      }
      user = r.user;
      if (r.missiles > 0) {
        if (screen == Screen.table) {
          notice = t.missilesAdded(r.missiles);
        } else {
          rewardWon = (
            kind: 'missiles',
            amount: r.missiles,
            missiles: r.missiles,
            hammers: 0,
          );
        }
      }
      return MissileTradeResult.traded;
    } on ApiException catch (e) {
      if (e.code == 'not_enough_diamonds') {
        // The diamonds held here were wrong, so they are read again.
        unawaited(refreshUser());
        return MissileTradeResult.notEnoughDiamonds;
      }
      notice = e.message;
      return MissileTradeResult.refused;
    } catch (_) {
      unawaited(refreshUser());
      notice = t.notConnected;
      return MissileTradeResult.refused;
    } finally {
      tradingMissiles = null;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------ lucky draw

  /// The Lucky Draw (owner, 24 Sep 2026) as this player finds it: which draw,
  /// its six prizes, and when they may next spin. Null while the server has
  /// described none — no draw is open, or the server predates it — and then
  /// the lobby shows no Lucky Draw at all.
  LuckyDrawState? luckyDraw;

  /// True while [loadLuckyDraw] is asking.
  bool luckyDrawLoading = false;

  /// For tests: a session without the sign-in round trip, so a test can drive
  /// a REST call — the Lucky Draw's, say — through a fake client.
  @visibleForTesting
  set debugToken(String? token) => _token = token;

  /// True when the last [loadLuckyDraw] failed — the network, a refusal —
  /// rather than being told there is no draw; the screen offers Try again.
  bool luckyDrawFailed = false;

  /// True from the moment a spin is sent until the server has answered it.
  /// The wheel's turning after that is the screen's.
  bool luckySpinPending = false;

  /// Reads the Lucky Draw again. Called at every sign-in, when the screen
  /// opens, and after a spin whose answer was lost.
  Future<void> loadLuckyDraw() async {
    final token = _token;
    if (token == null) return;
    luckyDrawLoading = true;
    notifyListeners();
    try {
      final draw = await _api.luckyDraw(token);
      // Signed out, or somebody else signed in, while it was asked.
      if (_token != token) return;
      luckyDraw = draw;
      luckyDrawFailed = false;
    } catch (_) {
      // What is on screen stays; with nothing on screen, Try again.
      if (_token == token) luckyDrawFailed = true;
    } finally {
      luckyDrawLoading = false;
      notifyListeners();
    }
  }

  /// Spins the Lucky Draw. The SERVER draws the slot, grants its prize and
  /// records the spin; the answer says where the wheel must stop, and the
  /// wallet takes the server's figures.
  ///
  /// One actionId per spin, sent again when the request itself fails and is
  /// retried: the server answers a replay with the same spin and grants
  /// nothing twice. Returns the spin, or null when it was refused or never
  /// answered — the player has been told why, and the wheel, turning since the
  /// tap, runs down to rest with no prize shown.
  Future<LuckySpin?> spinLuckyDraw() async {
    final token = _token;
    final draw = luckyDraw;
    if (token == null || draw == null || luckySpinPending) return null;
    luckySpinPending = true;
    notifyListeners();
    final actionId = const Uuid().v4();
    try {
      LuckySpin spin;
      try {
        spin = await _api.spinLuckyDraw(token, actionId, code: draw.code);
      } on ApiException {
        rethrow;
      } catch (_) {
        // No answer: the spin may or may not have landed, and asking again
        // with the same id is safe either way.
        await Future<void>.delayed(const Duration(milliseconds: 700));
        spin = await _api.spinLuckyDraw(token, actionId, code: draw.code);
      }
      if (spin.user != null) user = spin.user;
      luckyDraw = (luckyDraw ?? draw).withNextSpinAt(spin.nextSpinAt);
      // A picture won is owned now: the shelves re-read who owns what.
      if (spin.prize.isPicture && !spin.alreadyOwned) {
        unawaited(_loadPictures());
      }
      return spin;
    } on LuckyDrawNotReady catch (e) {
      // The wheel had not recharged: count down to the server's moment.
      if (e.readyAt > 0) {
        luckyDraw = (luckyDraw ?? draw).withNextSpinAt(e.readyAt);
      }
      notice = t.luckyNotReady;
      return null;
    } on ApiException catch (e) {
      notice = switch (e.code) {
        'seated' => t.luckyLobbyOnly,
        'lucky_draw_unavailable' => t.luckyClosed,
        _ => e.message,
      };
      if (e.code == 'lucky_draw_unavailable') unawaited(loadLuckyDraw());
      return null;
    } catch (_) {
      // Twice without an answer. The spin may still have landed, so the
      // wheel and the wallet are read again, and they say so if it did.
      notice = t.notConnected;
      unawaited(loadLuckyDraw());
      unawaited(refreshUser());
      return null;
    } finally {
      luckySpinPending = false;
      notifyListeners();
    }
  }

  // --------------------------------------------------------- reward programs

  /// The reward programs (owner, 30 Sep 2026) as this player stands in
  /// them: the login streaks and the calendar rewards the server runs, each
  /// with its days and which are claimed. Null while the server has
  /// described none — none running, or a server that predates them — and
  /// then the lobby shows no rewards.
  List<RewardProgramState>? rewardPrograms;

  /// True while [loadRewardPrograms] is asking.
  bool rewardProgramsLoading = false;

  /// True when the last read failed — the network, a refusal — rather than
  /// being told there are none; the screen offers Try again.
  bool rewardProgramsFailed = false;

  /// True from the moment a claim is sent until the server has answered it.
  bool rewardClaimPending = false;

  /// The program a claim in flight names (a day's tile on the rewards
  /// screen); null for a claim of every program, or none in flight.
  String? rewardClaimProgram;

  /// Whether any program's today can be collected now — the server's
  /// verdict where it gives one ([RewardProgramState.canClaimToday]).
  bool get rewardsDue => rewardPrograms?.any((p) => p.canClaimToday) ?? false;

  /// What the last claim gave, while its celebration is on screen; null the
  /// rest of the time. Only a claim's answer sets it — the server says
  /// whether anything was granted — so reopening the app never shows a
  /// reward twice.
  List<RewardGrant>? rewardsGranted;

  /// The reward popup on screen (owner, 30 Sep 2026: "it should pop after
  /// login and if user has claimed it should not show when user start the
  /// app, otherwise show it"; 2 Oct 2026: "for every reward type sequential
  /// or calender there should be different pop up, not a single pup up to
  /// collect all reward"): one program whose today is still to collect, in a
  /// popup of its own — in its own look — that collects that program alone.
  /// Every program waiting today is offered, one after another in the
  /// server's order ([rewardOfferIndex] of [rewardOfferCount]), each once a
  /// day a session: set when the programs are read with one waiting and not
  /// yet offered that day; [dismissRewardOffer] — Continue, Close, a tap
  /// outside, Back — puts up the next. Null the rest of the time, and then
  /// the lobby shows no popup. A claim never clears it: the popup shows what
  /// the claim gave and is put away by the player.
  RewardProgramState? rewardOffer;

  /// Where [rewardOffer] stands in its run of popups (from 1) and how many
  /// the run holds: "2 of 3".
  int rewardOfferIndex = 0;
  int rewardOfferCount = 0;

  /// The programs still to offer after [rewardOffer], by code, in order.
  final List<String> _offerQueue = [];

  /// `<code>:<today>` of every program's day offered this session, so a day
  /// is offered once however many times the programs are read in a session
  /// (a session:ready, the lobby coming back from a table); the next start of
  /// the app offers it again while it is still unclaimed.
  final Set<String> _offeredFor = {};

  /// True while the rewards screen is open: a read it makes offers no popup,
  /// which would stand behind it unseen — each program can be collected on
  /// the screen itself.
  bool rewardsScreenOpen = false;

  /// Forgets every popup offered and waiting: a session's end.
  void _forgetRewardOffers() {
    rewardOffer = null;
    _offerQueue.clear();
    _offeredFor.clear();
    rewardOfferIndex = 0;
    rewardOfferCount = 0;
  }

  /// Reads the reward programs — as the lobby appears, at every
  /// `session:ready` in the lobby, when the rewards screen opens, and on the
  /// screen's Try again — and offers a popup for each program whose day is
  /// still to collect. Claims nothing: collecting is the player's tap.
  Future<void> loadRewardPrograms() async {
    final token = _token;
    if (token == null) return;
    rewardProgramsLoading = true;
    notifyListeners();
    try {
      final programs = await _api.rewardPrograms(token);
      // Signed out, or somebody else signed in, while it was asked.
      if (_token != token) return;
      rewardPrograms = programs;
      rewardProgramsFailed = false;
      offerRewards();
    } catch (_) {
      if (_token == token) rewardProgramsFailed = true;
    } finally {
      rewardProgramsLoading = false;
      notifyListeners();
    }
  }

  /// Reads the programs again because a new cycle has begun (a panel's
  /// countdown reached zero) — once, however many panels count to the same
  /// moment: not while a read is already out, nor again within
  /// [_cycleTurnRest] of the last such read, so an answer that still counts
  /// to that moment can never set off a run of reads.
  Future<void> rewardCycleTurned() async {
    final now = rewardClock();
    final last = _cycleTurnedAt;
    if (rewardProgramsLoading ||
        (last != null && now.difference(last).abs() < _cycleTurnRest)) {
      return;
    }
    _cycleTurnedAt = now;
    await loadRewardPrograms();
  }

  DateTime? _cycleTurnedAt;
  static const _cycleTurnRest = Duration(seconds: 10);

  /// The programs whose today can be collected now, in the server's order —
  /// by its verdict ([RewardProgramState.canClaimToday]), so a broken or
  /// completed cycle is never offered.
  List<RewardProgramState> get rewardOffersDue => [
    for (final p in rewardPrograms ?? const <RewardProgramState>[])
      if (p.canClaimToday) p,
  ];

  String _offerKey(RewardProgramState p) => '${p.program.code}:${p.today}';

  /// Puts up the popups of the programs still to collect today — those not
  /// yet offered this session, or every one when asked [again] (the lobby's
  /// REWARDS chip) — the first now and the others one after another as each
  /// is put away. Answers whether a popup stands. Not while the no-winnings
  /// panel covers the lobby — a popup's animation would play behind it
  /// unseen, so [acceptConsent] offers them then — nor while a new
  /// account's welcome waits to be confirmed ([confirmWelcome] offers them),
  /// nor behind the rewards screen.
  bool offerRewards({bool again = false}) {
    if (rewardOffer != null) return true;
    if (consentPending || rewardsScreenOpen) return false;
    // Not before this account's consent is known: the programs' read can
    // land first, and the popup would go up under the panel.
    if (_consentKnownFor != user?.id) return false;
    if (welcomePending != null) return false;
    final due = [
      for (final p in rewardOffersDue)
        if (again || !_offeredFor.contains(_offerKey(p))) p,
    ];
    if (due.isEmpty) return false;
    _offeredFor.addAll(due.map(_offerKey));
    rewardOffer = due.first;
    _offerQueue
      ..clear()
      ..addAll([for (final p in due.skip(1)) p.program.code]);
    rewardOfferIndex = 1;
    rewardOfferCount = due.length;
    notifyListeners();
    return true;
  }

  /// Puts the popup on screen away — Continue, Close, a tap outside, Back —
  /// and puts up the next program's, passing over one collected meanwhile
  /// (on the rewards screen, on another phone) or no longer running.
  void dismissRewardOffer() {
    if (rewardOffer == null) return;
    rewardOffer = null;
    while (_offerQueue.isNotEmpty) {
      final code = _offerQueue.removeAt(0);
      rewardOfferIndex++;
      final next = rewardPrograms
          ?.where((p) => p.program.code == code)
          .firstOrNull;
      if (next != null && next.canClaimToday) {
        rewardOffer = next;
        break;
      }
    }
    if (rewardOffer == null) {
      rewardOfferIndex = 0;
      rewardOfferCount = 0;
    }
    notifyListeners();
  }

  /// Claims today's reward of the one program [programCode] names — its own
  /// popup's Collect, or its day's tile on the rewards screen — or, named
  /// none, of every program the server runs; once a day a program, which the
  /// SERVER decides, on the player's tap. Answers what the claim gave
  /// (empty when today was already collected), or null when it could not be
  /// made; with [celebrate] the lobby's celebration shows the grants too. A
  /// named program the server will not claim — gone, not running, its cycle
  /// broken or completed — is said in the player's words ([notice]) and the
  /// programs are read again, so the screen shows the truth. Nothing is
  /// asked at a table: a reward may be chips, which only the lobby may
  /// credit.
  Future<List<RewardGrant>?> claimRewardPrograms({
    bool celebrate = true,
    String? programCode,
  }) async {
    final token = _token;
    if (token == null || rewardClaimPending || room != null) return null;
    rewardClaimPending = true;
    rewardClaimProgram = programCode;
    notifyListeners();
    try {
      final r = await _api.claimRewardPrograms(token, programCode: programCode);
      if (_token != token) return null;
      if (r == null) {
        // An older server, or none running: nothing to show.
        rewardPrograms = null;
        rewardProgramsFailed = false;
        return null;
      }
      rewardPrograms = r.programs;
      rewardProgramsFailed = false;
      if (r.user != null) user = r.user;
      if (r.granted.isNotEmpty) {
        if (celebrate) rewardsGranted = r.granted;
        // An item won is owned now: the shelves re-read who owns what.
        if (r.granted.any((g) => g.prize.isItem && !g.alreadyOwned)) {
          unawaited(_loadPictures());
        }
      }
      return r.granted;
    } on ApiException catch (e) {
      // At a table by the server's reckoning: the lobby will ask again.
      if (e.code == 'seated') return null;
      final words = rewardRefusalText(e.code);
      if (words != null) {
        // The program as the phone drew it is not the program as it stands:
        // say why, and read the truth.
        if (_token == token) {
          notice = words;
          unawaited(loadRewardPrograms());
        }
        return null;
      }
      if (rewardPrograms == null) rewardProgramsFailed = true;
      return null;
    } catch (_) {
      if (rewardPrograms == null) rewardProgramsFailed = true;
      return null;
    } finally {
      rewardClaimPending = false;
      rewardClaimProgram = null;
      notifyListeners();
    }
  }

  /// A named program's claim refused, in the player's words; null for any
  /// other refusal.
  String? rewardRefusalText(String? code) => switch (code) {
    'reward_program_not_found' => t.rewardProgramGone,
    'reward_program_not_running' => t.rewardProgramNotRunning,
    'reward_cycle_broken' => t.rewardCycleBrokenNotice,
    'reward_cycle_completed' => t.rewardCycleCompletedNotice,
    _ => null,
  };

  /// Closes the rewards celebration.
  void dismissRewardsGranted() {
    if (rewardsGranted == null) return;
    rewardsGranted = null;
    notifyListeners();
  }

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

  /// Whole seconds left of the viewer's unfunded grace (the seat held for a
  /// chip purchase), or null when there is none — never more than this
  /// table's own grace when the menu carries it (`unfundedGraceMs`, the table
  /// catalogue), whatever the phone's clock says of the server's deadline.
  int? unfundedGraceLeft(DateTime now) {
    final room = this.room;
    if (room == null) return null;
    final total = config
        .entryFor(
          category: room.category,
          bootAmount: room.bootAmount,
          isPrivate: room.isPrivate,
        )
        ?.unfundedGraceMs;
    return room.you?.unfundedSecondsLeft(now, totalMs: total ?? 0);
  }

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
    // Refused while the connection is down, before the cooldown starts: the
    // line stays in the field to send once it is back.
    if (offline) {
      notice = t.notConnected;
      notifyListeners();
      return false;
    }
    _conn.sendChat(text.trim());
    _startChatCooldown();
    notifyListeners();
    return true;
  }

  /// Sends emoji [id] to the table (owner, 26 Sep 2026) and starts the chat's
  /// cooldown: an emoji IS a chat line — the server counts it against the
  /// same limiter — so the two share one wait. False when nothing was sent:
  /// the cooldown still running, or the connection down.
  ///
  /// Ownership is not checked here: the emoji page offers only what the
  /// catalogue says is this player's, and the server checks again on every
  /// send (`emoji_locked`).
  bool sendEmoji(int id) {
    if (!canChat) return false;
    if (offline) {
      notice = t.notConnected;
      notifyListeners();
      return false;
    }
    _conn.sendEmoji(id);
    _startChatCooldown();
    notifyListeners();
    return true;
  }

  /// The wait after a chat line or an emoji goes out.
  void _startChatCooldown() {
    _chatReadyAt = DateTime.now().add(chatCooldown);
    _chatCooldownTimer?.cancel();
    // The one-second ticker redraws the countdown; this makes the moment it
    // reaches zero exact rather than up to a second late.
    _chatCooldownTimer = Timer(chatCooldown, notifyListeners);
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
    if (steps.isEmpty) {
      // Off turn there is no ladder, so the key shows the chaal from the
      // table's stake — which is in BLIND units. A seen player's chaal is
      // twice it; the dimmed key read "Chaal 400" between turns of "Chaal
      // 800" (QA 14 Sep 2026).
      final stake = room?.stake ?? 0;
      return room?.you?.isBlind == false ? stake * 2 : stake;
    }
    return steps[raiseIndex.clamp(0, steps.length - 1)];
  }

  /// Whether the Chaal key can place a bet: it is this player's turn and the
  /// server offered at least one rung they can pay (owner, 14 Sep 2026: a
  /// player without the chips for the chaal gets a dark key, not one that does
  /// nothing when tapped). The server builds the ladder from the chips the seat
  /// holds, so an empty one is exactly "cannot afford the chaal".
  bool get canChaal => myTurn && (options?.raiseSteps.isNotEmpty ?? false);

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
      // The hand's variation was kept only for this; the next deal picks its
      // own.
      if (room?.variation == null) _clearVariation();
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
    winnerTax = 0;
    winnerTaxBps = 0;
    _handTax = null;
    // The poker hand's result stays in the snapshot until the next deal;
    // only the celebration of it ends here.
    pokerCelebrating = false;
    _pokerResultNews = null;
  }

  /// Drops everything remembered about a hand's variation. Not called by the
  /// showdown, unlike [_clearSideshow]: the variation is what the showdown is
  /// read by.
  void _clearVariation() {
    _variationTimer?.cancel();
    _variationTimer = null;
    variationAnnounced = null;
    _variationAnnouncedFor = null;
    lastVariation = null;
    lastTurnUp = null;
  }

  void _clearSideshow() {
    _revealTimer?.cancel();
    _revealTimer = null;
    sideshowReveal = null;
    _clearHammer();
    _hammersShown.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _serviceProbe?.cancel();
    unawaited(purchases.dispose());
    friends.dispose();
    reports.dispose();
    xpMissions.dispose();
    levelUps.dispose();
    _rentalWatch?.cancel();
    _cardBackLapse?.cancel();
    _statsCatchUp?.cancel();
    _clearSideshow();
    _clearVariation();
    _heldStandings.clear();
    _clearMissile();
    _resumeTimer?.cancel();
    _seatCheck?.cancel();
    _backgroundTimer?.cancel();
    _chatCooldownTimer?.cancel();
    _missedNoticeTimer?.cancel();
    _celebrationTimer?.cancel();
    _ticker?.cancel();
    for (final t in _bubbleTimers.values) {
      t.cancel();
    }
    for (final t in _emojiTimers.values) {
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

/// What a NEW account's sign-in granted, in one line in the player's
/// language (30 Sep 2026) — what the server's welcome grant gave it and
/// nothing it did not: "Welcome! Added to your account: 10 Lakh chips · 9
/// diamonds · 20 hammers · 1 missile · 1 picture · 2 emojis"; a grant of
/// nothing is a plain welcome. A server from before the grant sends no
/// `welcome`, only `welcomeChips`: its chips alone, or nothing when it gave
/// none. It was the sign-in's toast until the welcome rewards popup
/// (`widgets/welcome_rewards.dart`) took its place the same day; it is now
/// the popup's one-line summary — what a screen reader hears.
String? welcomeNotice(Strings t, WelcomeGrant? grant, {int welcomeChips = 0}) {
  if (grant == null) {
    if (welcomeChips <= 0) return null;
    return t.welcomeAdded(
      t.priceIn(PictureCurrency.coin, formatChips(welcomeChips)),
    );
  }
  final items = [
    if (grant.chips > 0)
      t.priceIn(PictureCurrency.coin, formatChips(grant.chips)),
    if (grant.diamonds > 0)
      t.priceIn(PictureCurrency.diamond, formatChips(grant.diamonds)),
    if (grant.hammers > 0)
      t.priceIn(PictureCurrency.hammer, '${grant.hammers}'),
    if (grant.missiles > 0) t.countMissiles(grant.missiles),
    if (grant.pictures.isNotEmpty) t.countPictures(grant.pictures.length),
    if (grant.tablePictures.isNotEmpty)
      t.countTablePictures(grant.tablePictures.length),
    if (grant.emojis.isNotEmpty) t.countEmojis(grant.emojis.length),
  ];
  return items.isEmpty ? t.welcomePlain : t.welcomeAdded(items.join(' · '));
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
/// The whole part is grouped like any other figure, so 10,500 Crore reads the
/// way the owner writes it (the premium packages printed "10500 Crore").
String _trim(double value) {
  var text = value.toStringAsFixed(2);
  if (text.contains('.')) text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  final dot = text.indexOf('.');
  final whole = _grouped(int.parse(dot < 0 ? text : text.substring(0, dot)));
  return dot < 0 ? whole : '$whole${text.substring(dot)}';
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

/// A winning tax rate in basis points as a player reads it (owner, 26 Sep
/// 2026): two decimals, and a whole ".00" dropped — 2000 is "20%", 1971
/// "19.71%", 1905 "19.05%", 1810 "18.10%", 200 "2%". Only ever shown: the
/// server charges it.
String formatTaxRate(int bps) {
  final whole = bps ~/ 100;
  final cents = bps % 100;
  return cents == 0 ? '$whole%' : '$whole.${cents.toString().padLeft(2, '0')}%';
}

/// "3h 59m 54s" — with its units in the player's language when [t] is given
/// (a countdown read "3h 54m 9s" under a Hindi or Bengali label once).
/// Seconds are always shown, so the timer visibly ticks instead of resting on
/// a minute.
String formatCountdown(Duration d, [Strings? t]) {
  final hu = t?.unitHourShort ?? 'h';
  final mu = t?.unitMinuteShort ?? 'm';
  final su = t?.unitSecondShort ?? 's';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  if (h > 0) return '$h$hu $m$mu $s$su';
  if (m > 0) return '$m$mu $s$su';
  return '$s$su';
}
