import 'dart:async';

import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../config/server_config.dart';
import '../l10n/strings.dart';
import '../models/dtos.dart';
import '../net/picture_cache.dart';
import '../net/api_client.dart';
import '../net/app_update.dart';
import '../net/connection_failure.dart';
import '../net/game_connection.dart';
import '../net/purchases.dart';
import '../net/social_sign_in.dart';
import 'consent.dart';
import 'hammer_strike.dart';
import 'missile_strike.dart';
import 'table_config_cache.dart';
import 'theme_preference.dart';

enum Screen { splash, update, login, lobby, table }

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
  GameState({String? serverUrl})
    : serverUrl = serverUrl ?? defaultServerUrl,
      _api = ApiClient(serverUrl ?? defaultServerUrl),
      _conn = GameConnection(serverUrl ?? defaultServerUrl);

  /// The backend this build was made against — [ServerConfig.url]: preprod
  /// unless a `--dart-define` (or `--dart-define-from-file=config/<env>.json`)
  /// says otherwise; the store build names production explicitly.
  static const defaultServerUrl = ServerConfig.url;

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
    if (no == null || hand == null || hand.picking || hand.pickedBy.isEmpty) return;
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

    // The menu this server last described, before anything can draw the
    // lobby: the first frame after the splash is the phone's copy, not
    // GameConfig.fallback. session:ready replaces it moments later if the
    // server has changed its tables since.
    restoreCachedMenu(prefs);

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
        // Every sign-in asks for the table catalogue again — a restored
        // session is a sign-in too — and a 304 makes that cheap.
        unawaited(_loadTableConfig());
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
      _conn.onShowdown.listen(handleShowdown),
      // Requirements 31 and 32: idled out, or out of chips for this table.
      // Shown out is not the same as leaving, so the reason is carried back to
      // the lobby rather than the player simply finding themselves there.
      _conn.onKicked.listen((kick) {
        notice = kickText(kick.reason, kick.message);
        switching = false;
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
      }),

      _conn.onLeft.listen((_) {
        // Mid-switch, the next table's snapshot is already on its way, so a
        // room closing behind us is not a reason to walk back to the lobby.
        if (switching) return;
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
      _conn.onChat.listen((m) {
        // A blocked player's line is dropped here, before it can raise a
        // badge, bubble over their seat or sit in the drawer. The server is
        // not told and keeps sending: blocking is this viewer's own view of
        // the table, not a report.
        if (isBlocked(m.userId)) return;
        chat.add(m);
        // The room keeps at most a hundred messages, and so does this.
        if (chat.length > 100) chat.removeAt(0);
        // Only other players' lines are unread. The server echoes the viewer's
        // own message back, and it lands after the chat drawer has closed on
        // sending (a quick message never opens the chat drawer at all), so
        // counting it raised a badge for something they had just sent.
        if (m.userId != user?.id) unreadChat++;

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
        // History is re-sent on a reconnect to the SAME table, where the
        // blocks are still standing, so it is filtered like a live message.
        chat
          ..clear()
          ..addAll(h.where((m) => !isBlocked(m.userId)));
        notifyListeners();
      }),
      _conn.onError.listen((e) {
        // A Force Sideshow reads these two refusals from its ack, which the
        // server sends first: no_hammers turns into an offer of the store and
        // persist_failed into a retry. Their game:error copies would only put
        // a toast over that.
        if (_forceQuiet(e.code) || _missileQuiet(e.code)) return;
        notice = refusalText(e.code, e.message);
        // A refused rejoin is an answer too: there is nothing to resume.
        if (resuming) _endResume();
        notifyListeners();
      }),
      _conn.onConnected.listen((up) {
        offline = !up;
        notifyListeners();
      }),
    ]);
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
    }
    _armCelebration(s.nextHandAt);
    notifyListeners();
    unawaited(refreshUser());
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
      unawaited(_loadTableConfig());

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
      unawaited(_loadTableConfig());

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
    // The table catalogue rides along on every load of the face catalogue:
    // the same moments want both, and a failure of one must not empty the
    // other, so they are two requests.
    unawaited(_loadTablePictures());
    try {
      pictures = await _api.profilePictures(_token);
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
  /// categories, or to the front when the engine itself has gone.
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
    try {
      tablePictures = await _api.tablePictures(_token);
      PictureCache.warm(
        tablePictures.expand((p) => [p.dayUrl, p.nightUrl]).map(absoluteUrl).nonNulls,
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
    final offered = {for (final table in config.tables) lobbyEngineOf(table)};
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

  /// One engine's category cards: every category of [engine] the server
  /// offers at least one table in, and no other.
  ///
  /// In the order of that engine's categories in [GameConfig.engines], by
  /// their sortOrder, when the server names them; else [lobbyTaxonomy] —
  /// Seen, Blind, Variation; 3-Card Poker, 5-Card Draw, Texas Hold'em, Omaha.
  /// A category neither places still comes, after the rest.
  List<String> lobbyCategoriesIn(String engine) {
    final offered = {
      for (final table in config.tables)
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
    for (final table in config.tables)
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
    for (final table in config.tables) {
      if (lobbyCategoryOf(table) != category) continue;
      if (engine != null && lobbyEngineOf(table) != engine) continue;
      (tableShut(table) ? shut : open).add(table);
    }
    return [...open, ...shut];
  }

  /// Goes into [engine]'s categories, from wherever the lobby is. An engine
  /// the server does not offer is ignored.
  void openLobbyEngine(String engine) {
    if (!lobbyEngines.contains(engine)) return;
    if (_lobbyEngine == engine && _lobbyCategory == null) return;
    _lobbyEngine = engine;
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
  /// from an engine's categories to the front. Answers whether there was a
  /// level to close, which is how the Back key knows it has been used.
  bool closeLobbyLevel() {
    if (_lobbyCategory != null) {
      _lobbyCategory = null;
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
  void _checkRental() {
    if (screen != Screen.lobby || _rentalRefreshing) return;
    final worn = user?.activePictureId;
    final laid = user?.activeTablePictureId;
    if (worn == null && laid == null) return;

    // Nothing to watch unless what they are wearing — on their face or on
    // their table — can actually run out.
    final premium =
        pictures.any((p) => p.id == worn && !p.free) ||
        tablePictures.any((p) => p.id == laid && !p.free);
    if (!premium) return;

    _rentalRefreshing = true;
    unawaited(_refreshPictures().whenComplete(() => _rentalRefreshing = false));
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

  /// The reward just collected, while its celebration is on screen. Null the
  /// rest of the time. `readyAt` is epoch ms for the timed bonus and 0 for the
  /// milestone, which has no clock.
  ///
  /// `amount` is the headline figure. `missiles` and `hammers` are what a
  /// Premium Package (kind `premium`, owner 14 Sep 2026) brought with its
  /// chips, shown under that figure; every other kind carries 0 or repeats
  /// its own count there.
  ({String kind, int amount, int readyAt, int missiles, int hammers})?
  rewardWon;

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
      final r = await _api.redeemPurchase(token, purchase.productID, receipt);
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
  }) {
    if (chips > 0 && (missiles > 0 || hammers > 0)) {
      if (screen == Screen.table) {
        notice = t.premiumAdded(formatChips(chips), missiles, hammers);
      } else {
        rewardWon = (
          kind: 'premium',
          amount: chips,
          readyAt: 0,
          missiles: missiles,
          hammers: hammers,
        );
      }
      return;
    }
    rewardWon = hammers > 0
        ? (
            kind: 'hammers',
            amount: hammers,
            readyAt: 0,
            missiles: 0,
            hammers: hammers,
          )
        : diamonds > 0
        ? (
            kind: 'diamonds',
            amount: diamonds,
            readyAt: 0,
            missiles: 0,
            hammers: 0,
          )
        : (
            kind: 'purchase',
            amount: chips,
            readyAt: 0,
            missiles: 0,
            hammers: 0,
          );
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
        rewardWon = (
          kind: kind,
          amount: r.amount,
          readyAt: r.readyAt,
          missiles: 0,
          // The daily bonus pays a hammer beside its chips (owner, 14 Sep
          // 2026), and the celebration shows it under them.
          hammers: kind == 'daily' ? (user?.rewards?.dailyHammers ?? 0) : 0,
        );
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
            readyAt: 0,
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
    // Refused while the connection is down, before the cooldown starts: the
    // line stays in the field to send once it is back.
    if (offline) {
      notice = t.notConnected;
      notifyListeners();
      return false;
    }
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
    unawaited(purchases.dispose());
    _rentalWatch?.cancel();
    _clearSideshow();
    _clearVariation();
    _clearMissile();
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

/// "3h 59m 54s" — with its units in the player's language when [t] is given
/// (the lobby's bonus chip read "3h 54m 9s" under a Hindi or Bengali label).
/// Seconds are always shown (requirement 26), so the timer visibly ticks
/// instead of resting on a minute.
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
