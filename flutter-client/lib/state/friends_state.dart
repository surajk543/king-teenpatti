import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/strings.dart';
import '../models/friends.dart';
import '../net/api_client.dart';

/// A refusal of a Friends request that is not the server's: the request never
/// got an answer (no connection, a timeout, a body that was not JSON).
const friendsNoAnswer = 'no_answer';

/// Nothing was typed into the Player ID field — refused before any request.
const friendsEmptyId = 'empty_player_id';

/// A server refusal of a Friends request, or [friendsNoAnswer] /
/// [friendsEmptyId], in the player's language. Every code the contract names
/// has words of its own; a code this build does not know gets a plain "that
/// did not go through" rather than the server's English sentence.
String friendsRefusalText(Strings t, String? code) => switch (code) {
  'player_not_found' => t.friendRefusePlayerNotFound,
  'invalid_player_id' => t.friendRefuseInvalidId,
  'self_request' => t.friendRefuseSelf,
  'already_friends' => t.friendRefuseAlreadyFriends,
  'request_already_sent' => t.friendRefuseAlreadySent,
  'request_already_received' => t.friendRefuseAlreadyReceived,
  'request_not_found' => t.friendRefuseRequestGone,
  'request_not_pending' => t.friendRefuseNotPending,
  'not_friends' => t.friendRefuseNotFriends,
  'rate_limited' => t.friendRefuseRateLimited,
  friendsEmptyId => t.enterPlayerId,
  friendsNoAnswer => t.notConnected,
  _ => t.friendActionFailed,
};

/// Friends V1 on the phone (owner's brief, 26 Sep 2026): the friend list, the
/// requests both ways, the lobby key's count, a search by Player ID and a
/// player's profile — and every move on them.
///
/// A notifier of its own rather than more fields on [GameState], which ticks
/// once a second for its countdowns: the Friends page watches this and only
/// this, so it rebuilds when a friend's news changes and never merely because
/// a second passed. GameState owns it — it hands over its [ApiClient], its
/// session token and its strings, resets it at sign-out — so no provider was
/// added over the app, and every screen that already builds with GameState
/// alone still does.
///
/// Refresh, as the contract has it: the lobby key's count is read at every
/// sign-in, whenever the lobby appears ([lobbyShown] — sign-in, back from a
/// table), every [badgeEvery] while it shows, and when the page closes
/// ([pageClosed]); the page's two lists are read when it opens, every
/// [pollEvery] while it is open, and on a pull or a retry ([refresh]). No
/// timer runs while the page is shut but the lobby's, and none at all away
/// from the lobby.
///
/// Two pieces of news are pushed rather than asked for (owner, 26 Sep 2026:
/// "do this async"): a request that has just arrived ([requestArrived],
/// `friend:request`) and one of the player's own that has just been accepted
/// ([requestAccepted], `friend:accepted`). At a table the incoming requests
/// and the friends are read once as the table opens ([tableOpened]) and kept
/// by those two and by the moves; a seat's pod wears a badge while its
/// player's request waits ([hasRequestFrom]), a friend's pod wears the friend
/// mark ([isFriend]), and a tap on a pod opens the table's player drawer,
/// whose profile has a slot of its own here ([seatPlayer] and the rest) —
/// never the Friends page's.
class FriendsState extends ChangeNotifier {
  FriendsState({
    required this._api,
    required this._token,
    required this._strings,
    required this._say,
  });

  final ApiClient _api;
  final String? Function() _token;
  final Strings Function() _strings;
  final void Function(String message) _say;

  /// How often the open page reads its two lists again.
  static const pollEvery = Duration(seconds: 15);

  /// How often the lobby key's count is read again while the lobby shows.
  static const badgeEvery = Duration(seconds: 60);

  // ----------------------------------------------------------------- data

  /// The friend list, PLAYING first, then ONLINE, then OFFLINE, by name — and
  /// the ONE answer to "is this player my friend" ([isFriend]). Every change
  /// to it comes through here — a read of the list, an accept, the
  /// `friend:accepted` push, a removal, a sign-out — so the Friends page's
  /// list and the marks a table puts on friends' seats can never disagree.
  List<FriendItem> get friends => _friends;
  set friends(List<FriendItem> list) {
    _friends = list;
    _friendIds = {
      for (final f in list)
        if (f.userId.isNotEmpty) f.userId,
    };
  }

  List<FriendItem> _friends = const [];

  /// The ids on [friends], kept with it: what [isFriend] reads.
  Set<String> _friendIds = const {};

  /// Whether [userId] is this player's friend, as their own friend list has
  /// it. A table asks it of every seat for the mark a friend's pod wears
  /// ([FriendsState.tableOpened]) — decided here, on this phone, and sent to
  /// nobody.
  bool isFriend(String? userId) =>
      userId != null && userId.isNotEmpty && _friendIds.contains(userId);

  /// When this player and [userId] became friends (epoch ms), as the friend
  /// list has it — the same moment for both of them — or null when they are
  /// not friends or the list does not know. The player drawer's "Friends for
  /// 3 days" (owner, 26 Sep 2026).
  int? friendsSinceOf(String? userId) {
    if (!isFriend(userId)) return null;
    for (final f in _friends) {
      if (f.userId == userId) return f.friendsSince > 0 ? f.friendsSince : null;
    }
    return null;
  }

  /// Requests addressed to this player — the ones Accept and Reject answer —
  /// and the ones they sent, newest first.
  List<FriendRequestItem> incoming = const [];
  List<FriendRequestItem> outgoing = const [];

  /// The lobby key's badge: how many requests wait for this player.
  int incomingCount = 0;

  /// True once the page's lists have been read this session.
  bool loaded = false;

  /// True while the page's lists are being read.
  bool loading = false;

  /// True when the last read of the lists failed and there were none on
  /// screen to keep: the page offers Retry.
  bool failed = false;

  /// False once the server has answered a Friends route with `not_found` — a
  /// server from before Friends — and then the lobby shows no Friends key.
  /// True until then: the key is there from the first frame.
  bool available = true;

  /// Requests being accepted or rejected, and friends being removed, by id:
  /// their keys wait for the answer rather than being pressed twice.
  final Set<String> busyRequests = {};
  final Set<String> removing = {};

  /// The player a request is being sent to, while it is.
  String? sendingTo;

  // --------------------------------------------------------------- search

  /// The player the Add Friend page found, or null.
  PlayerLookup? lookup;

  /// True while a search is out.
  bool searching = false;

  /// Why the last search found nobody — a refusal code
  /// ([friendsRefusalText]) — or null.
  String? searchError;

  /// What the last move on [lookup]'s player was refused with, to say under
  /// the card; cleared by the next search.
  String? lookupNote;

  // -------------------------------------------------------------- profile

  /// The profile on show, for the player [profileFor].
  PublicProfile? profile;

  /// Whose profile is being shown, or null when none is.
  String? profileFor;
  bool profileLoading = false;

  /// Why the profile could not be read — a refusal code — or null.
  String? profileError;

  /// What the last move from the profile was refused with, to say on it.
  String? profileNote;

  // ------------------------------------------------------------ the seat

  /// The player whose seat was tapped at a table — the player drawer's — as
  /// the seat drew them: their name and picture, shown at once while their
  /// profile is read. Null when the drawer is shut. A slot of its own, so the
  /// table never borrows (or clears) the Friends page's profile or search.
  PlayerCard? seatPlayer;

  /// [seatPlayer]'s profile, once read: what they are to the viewer and
  /// their record. Its presence, when a friend's profile carries one, is
  /// never shown at a table.
  PublicProfile? seatProfile;
  bool seatLoading = false;

  /// Why [seatProfile] could not be read — a refusal code — or null.
  String? seatError;

  /// What the last move from the drawer was refused with, to say in it.
  String? seatNote;

  // ------------------------------------------------------------ lifecycle

  Timer? _poll;
  Timer? _badgeTimer;
  bool _pageOpen = false;
  bool _disposed = false;

  /// Bumped by every change the app makes to the lists itself (an accept, a
  /// reject, a removal), so a read that set out before it — and so describes
  /// the lists as they were — is not laid over it when it lands.
  int _edits = 0;

  /// Stamps for the latest search and profile read: a slower answer to an
  /// older question is dropped.
  int _searchSeq = 0;
  int _profileSeq = 0;
  int _seatSeq = 0;

  /// The read of the lists, and of the count, out now, and the [_edits] each
  /// set out at: a second call while one is out waits for it — unless the
  /// app has changed the lists since it set out, when its answer will be
  /// dropped and a fresh read goes.
  Future<void>? _refreshing;
  int _refreshingAt = -1;
  Future<void>? _badgeFetch;
  int _badgeAt = -1;

  /// Whether the Friends page is open.
  bool get pageOpen => _pageOpen;

  /// The Friends page has opened: its lists are read now and every
  /// [pollEvery] until it closes. The page calls this once it is on screen,
  /// never while it is being built: the read says so at once.
  void pageOpened() {
    _pageOpen = true;
    _poll?.cancel();
    _poll = Timer.periodic(pollEvery, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  /// The Friends page has closed: the polling stops, and the lobby key's
  /// count is read once more for the lobby it returns to. Quiet — called as
  /// the page is taken down, when nothing may be marked to rebuild — and the
  /// count's answer, when it lands, is what tells the lobby.
  void pageClosed() {
    _pageOpen = false;
    _poll?.cancel();
    _poll = null;
    // Its sub-pages go with it: the page opens on the list next time.
    clearSearch(notify: false);
    closeProfile(notify: false);
    unawaited(refreshBadge());
  }

  /// The lobby is on screen (its Friends key has appeared): the count is read
  /// now and every [badgeEvery] while it stays.
  void lobbyShown() {
    _badgeTimer?.cancel();
    _badgeTimer = Timer.periodic(badgeEvery, (_) {
      // The open page reads the requests every fifteen seconds already.
      if (!_pageOpen) unawaited(refreshBadge());
    });
    unawaited(refreshBadge());
  }

  /// The lobby has gone — a table, the sign-in screen.
  void lobbyHidden() {
    _badgeTimer?.cancel();
    _badgeTimer = null;
  }

  /// Everything of the account that was signed in, forgotten: at sign-out
  /// and when the account is deleted, so the next player on this phone never
  /// sees the last one's friends.
  void reset() {
    _poll?.cancel();
    _poll = null;
    _pageOpen = false;
    _edits++;
    _searchSeq++;
    _profileSeq++;
    friends = const [];
    incoming = const [];
    outgoing = const [];
    incomingCount = 0;
    loaded = false;
    loading = false;
    failed = false;
    available = true;
    busyRequests.clear();
    removing.clear();
    sendingTo = null;
    clearSearch(notify: false);
    closeProfile(notify: false);
    closeSeat(notify: false);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _badgeTimer?.cancel();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// A toast, through the app's one notice; never once the session that
  /// raised it is gone with its state.
  void _tell(String message) {
    if (!_disposed) _say(message);
  }

  /// A refusal's code: the server's, or [friendsNoAnswer] for anything that
  /// was not an answer at all.
  static String _codeOf(Object error) =>
      error is ApiException ? (error.code ?? friendsNoAnswer) : friendsNoAnswer;

  /// A route this server does not have: every Friends route answers 404
  /// `not_found` on a server from before Friends.
  static bool _unsupported(Object error) =>
      error is ApiException && error.status == 404 && error.code == 'not_found';

  // --------------------------------------------------------------- reading

  /// Reads the friend list and the requests again — the page's poll, its
  /// pull and its Retry. One read at a time: a second call while one is out
  /// waits for that one.
  Future<void> refresh() {
    final running = _refreshing;
    if (running != null && _refreshingAt == _edits) return running;
    _refreshingAt = _edits;
    late final Future<void> read;
    read = _refresh().whenComplete(() {
      if (identical(_refreshing, read)) _refreshing = null;
    });
    return _refreshing = read;
  }

  Future<void> _refresh() async {
    final token = _token();
    if (token == null) return;
    final edits = _edits;
    loading = true;
    _notify();
    try {
      final got = await Future.wait<Object>([
        _api.friends(token),
        _api.friendRequests(token),
      ]);
      // Signed out, or another account signed in, while it was asked.
      if (_token() != token) return;
      available = true;
      // A move the app made while this was out already changed the lists;
      // this answer describes them as they were, so the next read is waited
      // for rather than letting it put the old ones back.
      if (_edits != edits) return;
      final requests = got[1] as FriendRequests;
      friends = sortFriends(got[0] as List<FriendItem>);
      incoming = requests.incoming;
      outgoing = requests.outgoing;
      incomingCount = incoming.length;
      loaded = true;
      failed = false;
    } catch (e) {
      if (_token() != token) return;
      if (_unsupported(e)) available = false;
      // A poll that fails leaves the lists on screen as they were; only a
      // page with nothing to show says it could not load.
      if (!loaded) failed = true;
    } finally {
      if (_token() == token) {
        loading = false;
        _notify();
      }
    }
  }

  /// A table has opened: both lists are read, once — the requests waiting,
  /// for the badge a seat wears while its player's request waits, and the
  /// friends, for the mark a friend's seat wears ([isFriend]). Nothing reads
  /// them again at the table: a request is pushed as it arrives, an
  /// acceptance is pushed to the player who asked, and the player's own
  /// Accept and Reject in the drawer change the lists themselves.
  ///
  /// A friendship only ever ends in the lobby — a table offers no Remove, and
  /// nothing is pushed when one ends — so for everyone seated with this player
  /// the list read here holds for the whole sitting. The one case it misses is
  /// a friend who gets up, ends the friendship from their Friends page and
  /// sits down again: their mark stays until the next table opens.
  ///
  /// A server from before Friends answers `not_found`, and then there is no
  /// list, no mark and no drawer ([available]).
  Future<void> tableOpened() => refresh();

  /// Reads the lobby key's count again: the requests waiting for this
  /// player. Quiet: a failure keeps the count it had.
  Future<void> refreshBadge() {
    final running = _badgeFetch;
    if (running != null && _badgeAt == _edits) return running;
    _badgeAt = _edits;
    late final Future<void> read;
    read = _fetchBadge().whenComplete(() {
      if (identical(_badgeFetch, read)) _badgeFetch = null;
    });
    return _badgeFetch = read;
  }

  Future<void> _fetchBadge() async {
    final token = _token();
    if (token == null) return;
    final edits = _edits;
    try {
      final requests = await _api.friendRequests(token);
      if (_token() != token) return;
      available = true;
      if (_edits != edits) return;
      incoming = requests.incoming;
      outgoing = requests.outgoing;
      incomingCount = incoming.length;
      _notify();
    } catch (e) {
      if (_token() != token) return;
      if (_unsupported(e)) {
        available = false;
        _notify();
      }
    }
  }

  // ---------------------------------------------------------------- moves

  /// Accepts request [requestId]: it leaves the requests and its player joins
  /// the friend list at once. False when it was refused — the player has
  /// been told why, and the lists are read again.
  Future<bool> accept(String requestId) async {
    final token = _token();
    if (token == null || busyRequests.contains(requestId)) return false;
    busyRequests.add(requestId);
    _clearSeatNoteFor(_userOfRequest(requestId));
    _notify();
    try {
      final friend = await _api.acceptFriendRequest(token, requestId);
      if (_token() != token) return false;
      _edits++;
      final asked = _requestById(requestId);
      final from = _userOfRequest(requestId);
      _dropRequest(requestId);
      final userId = friend.userId.isNotEmpty ? friend.userId : from ?? '';
      if (friend.userId.isNotEmpty) {
        friends = sortFriends([
          ...friends.where((f) => f.userId != friend.userId),
          friend,
        ]);
      } else {
        // An answer with no friend in it: the list says who, once read.
        unawaited(refresh());
      }
      final name = friend.displayName.isNotEmpty
          ? friend.displayName
          : asked?.player.displayName ?? _nameOf(userId);
      _nowFriends(userId);
      if (name.isNotEmpty) _tell(_strings().friendAdded(name));
      return true;
    } catch (e) {
      if (_token() != token) return false;
      _refusedOnRequest(requestId, e);
      return false;
    } finally {
      busyRequests.remove(requestId);
      _notify();
    }
  }

  /// Rejects request [requestId]: it leaves the requests at once. Nothing is
  /// said when it worked — the row going is the answer.
  Future<bool> reject(String requestId) async {
    final token = _token();
    if (token == null || busyRequests.contains(requestId)) return false;
    busyRequests.add(requestId);
    _clearSeatNoteFor(_userOfRequest(requestId));
    _notify();
    try {
      await _api.rejectFriendRequest(token, requestId);
      if (_token() != token) return false;
      _edits++;
      final from = _userOfRequest(requestId);
      _dropRequest(requestId);
      if (from != null) _noLongerPending(from);
      return true;
    } catch (e) {
      if (_token() != token) return false;
      _refusedOnRequest(requestId, e);
      return false;
    } finally {
      busyRequests.remove(requestId);
      _notify();
    }
  }

  /// Ends the friendship with [userId], both ways: they leave the list at
  /// once. False when it was refused.
  Future<bool> remove(String userId) async {
    final token = _token();
    if (token == null || removing.contains(userId)) return false;
    removing.add(userId);
    _notify();
    final name = _nameOf(userId);
    try {
      await _api.removeFriend(token, userId);
      if (_token() != token) return false;
      _edits++;
      _dropFriend(userId);
      if (name.isNotEmpty) _tell(_strings().friendRemoved(name));
      return true;
    } catch (e) {
      if (_token() != token) return false;
      final code = _codeOf(e);
      if (code == 'not_friends') {
        // Already not friends — the other player ended it. Say so, and show
        // it: they are not on the list any more either way.
        _edits++;
        _dropFriend(userId);
        unawaited(refresh());
      }
      _tell(friendsRefusalText(_strings(), code));
      return false;
    } finally {
      removing.remove(userId);
      _notify();
    }
  }

  /// Asks [userId] to be friends — from the Add Friend page's card, a
  /// profile, or the table's player drawer. On success the player stands as
  /// PENDING_SENT; a refusal moves them to whatever it says they are (already
  /// friends, already asked, a request of theirs to accept) and is said on
  /// the page that asked — in the drawer, which reads the profile again to
  /// offer the move that fits now.
  Future<bool> sendRequest(String userId) async {
    final token = _token();
    if (token == null || sendingTo != null) return false;
    sendingTo = userId;
    lookupNote = null;
    profileNote = null;
    _clearSeatNoteFor(userId);
    _notify();
    try {
      final sent = await _api.sendFriendRequest(token, userId);
      if (_token() != token) return false;
      _restate(userId, sent.friendStatus, requestId: sent.requestId);
      return true;
    } catch (e) {
      if (_token() != token) return false;
      final code = _codeOf(e);
      final requestId = e is FriendRefusal ? e.requestId : null;
      switch (code) {
        case 'already_friends':
          _restate(userId, FriendStatus.friends);
          unawaited(refresh());
        case 'request_already_sent':
          _restate(userId, FriendStatus.pendingSent, requestId: requestId);
        case 'request_already_received':
          _restate(userId, FriendStatus.pendingReceived, requestId: requestId);
          unawaited(refreshBadge());
        case 'self_request':
          _restate(userId, FriendStatus.self);
        case 'player_not_found':
          // Gone since they were found: said where the card or the
          // profile stood.
          if (lookup?.player.userId == userId) {
            lookup = null;
            searchError = code;
          }
          if (profileFor == userId) {
            profile = null;
            profileError = code;
          }
      }
      if (lookup?.player.userId == userId) lookupNote = code;
      if (profileFor == userId && profile != null) profileNote = code;
      if (seatPlayer?.userId == userId) {
        if (code == 'player_not_found') {
          // Gone: there is no profile left to offer a move on.
          _seatSeq++;
          seatProfile = null;
          seatLoading = false;
          seatError = code;
        } else {
          _refusedAtSeat(code);
        }
      }
      return false;
    } finally {
      sendingTo = null;
      _notify();
    }
  }

  // --------------------------------------------------------------- search

  /// Finds a player by the Player ID typed: trimmed, and refused before any
  /// request when nothing is left.
  Future<void> search(String raw) async {
    final id = raw.trim();
    final seq = ++_searchSeq;
    lookup = null;
    lookupNote = null;
    if (id.isEmpty) {
      searching = false;
      searchError = friendsEmptyId;
      _notify();
      return;
    }
    final token = _token();
    if (token == null) return;
    searching = true;
    searchError = null;
    _notify();
    try {
      final found = await _api.findPlayer(token, id);
      if (seq != _searchSeq || _token() != token) return;
      lookup = found;
    } catch (e) {
      if (seq != _searchSeq || _token() != token) return;
      searchError = _codeOf(e);
    } finally {
      if (seq == _searchSeq) {
        searching = false;
        _notify();
      }
    }
  }

  /// The Add Friend page is closing: its search goes with it.
  void clearSearch({bool notify = true}) {
    _searchSeq++;
    lookup = null;
    searching = false;
    searchError = null;
    lookupNote = null;
    if (notify) _notify();
  }

  // -------------------------------------------------------------- profile

  /// Reads [userId]'s profile for the page to show.
  Future<void> openProfile(String userId) async {
    final seq = ++_profileSeq;
    if (profileFor != userId) profile = null;
    profileFor = userId;
    profileError = null;
    profileNote = null;
    final token = _token();
    if (token == null) return;
    profileLoading = true;
    _notify();
    try {
      final got = await _api.playerProfile(token, userId);
      if (seq != _profileSeq || _token() != token) return;
      profile = got;
    } catch (e) {
      if (seq != _profileSeq || _token() != token) return;
      profileError = _codeOf(e);
    } finally {
      if (seq == _profileSeq) {
        profileLoading = false;
        _notify();
      }
    }
  }

  /// The profile has been left.
  void closeProfile({bool notify = true}) {
    _profileSeq++;
    profile = null;
    profileFor = null;
    profileLoading = false;
    profileError = null;
    profileNote = null;
    if (notify) _notify();
  }

  /// Where [userId] is, as the friend list last had it — fresher than the
  /// profile's own, which is read once, since the list is read every
  /// [pollEvery] while the page is open. Null when they are not on it.
  FriendPresence? presenceOf(String userId) {
    for (final friend in friends) {
      if (friend.userId == userId) return friend.presence;
    }
    return null;
  }

  // ------------------------------------------------------------ the seat

  /// Whether a request from [userId] waits for this player: what puts the
  /// badge on that player's pod at a table.
  bool hasRequestFrom(String? userId) =>
      userId != null && requestFrom(userId) != null;

  /// The request [userId] sent this player, while it waits for an answer.
  FriendRequestItem? requestFrom(String userId) {
    if (userId.isEmpty) return null;
    for (final r in incoming) {
      if (r.player.userId == userId) return r;
    }
    return null;
  }

  /// A seat was tapped at a table: the player drawer opens on [who], drawn at
  /// once as the seat has them, and their profile is read now. A second tap
  /// on the same player keeps what is on show while it is read again.
  Future<void> openSeat(PlayerCard who) {
    if (seatPlayer?.userId != who.userId) seatProfile = null;
    seatPlayer = who;
    seatError = null;
    seatNote = null;
    return _readSeat();
  }

  /// The drawer's Retry: its player's profile read again.
  Future<void> retrySeat() => _readSeat();

  Future<void> _readSeat({bool keepNote = false}) async {
    final who = seatPlayer;
    if (who == null) return;
    final seq = ++_seatSeq;
    if (!keepNote) seatNote = null;
    final token = _token();
    if (token == null) {
      seatLoading = false;
      seatError = friendsNoAnswer;
      _notify();
      return;
    }
    seatLoading = true;
    seatError = null;
    _notify();
    try {
      final got = await _api.playerProfile(token, who.userId);
      if (seq != _seatSeq || _token() != token) return;
      seatProfile = got;
    } catch (e) {
      if (seq != _seatSeq || _token() != token) return;
      final code = _codeOf(e);
      seatError = code;
      // A player the server no longer knows has no profile left to show.
      if (code == 'player_not_found') seatProfile = null;
    } finally {
      if (seq == _seatSeq) {
        seatLoading = false;
        _notify();
      }
    }
  }

  /// The drawer has shut, and its player goes with it; an answer still on
  /// its way for them is dropped when it lands. Quiet when [notify] is false:
  /// the drawer calls this as it is taken down, when nothing may be marked
  /// to rebuild.
  void closeSeat({bool notify = true}) {
    _seatSeq++;
    seatPlayer = null;
    seatProfile = null;
    seatLoading = false;
    seatError = null;
    seatNote = null;
    if (notify) _notify();
  }

  // ---------------------------------------------------------- pushed news

  /// A request has just arrived (`friend:request`), in the lobby or at a
  /// table. It joins [incoming] at the top — the lobby key's count goes up,
  /// and at a table the sender's pod wears its badge — its sender stands as
  /// PENDING_RECEIVED wherever they are on show (an open player drawer for
  /// them reads their profile again), and an open Friends page reads its
  /// lists. What is SAID about it is the caller's: only GameState knows
  /// whether the sender sits at this player's table, and whom they have
  /// blocked there.
  void requestArrived(FriendRequestItem request) {
    final from = request.player.userId;
    if (request.requestId.isEmpty || from.isEmpty) return;
    // A read already out describes the requests as they were before this
    // one: it is dropped when it lands, and the next read brings this too.
    _edits++;
    available = true;
    incoming = [
      request,
      for (final r in incoming)
        if (r.requestId != request.requestId && r.player.userId != from) r,
    ];
    incomingCount = incoming.length;
    _restate(from, FriendStatus.pendingReceived, requestId: request.requestId);
    if (seatPlayer?.userId == from) unawaited(_readSeat());
    if (_pageOpen) unawaited(refresh());
    _notify();
  }

  /// A request this player sent has been accepted (`friend:accepted`): the
  /// player who accepted is a friend now — on the list, and wherever they
  /// are on show; an open player drawer for them reads their profile again,
  /// and an open Friends page its lists.
  void requestAccepted(FriendAccepted accepted) {
    final who = accepted.player.userId;
    if (who.isEmpty) return;
    _edits++;
    available = true;
    outgoing = [
      for (final r in outgoing)
        if (r.requestId != accepted.requestId && r.player.userId != who) r,
    ];
    // Friends have nothing left to ask each other.
    incoming = [
      for (final r in incoming)
        if (r.player.userId != who) r,
    ];
    incomingCount = incoming.length;
    if (!friends.any((f) => f.userId == who)) {
      friends = sortFriends([
        ...friends,
        FriendItem(
          player: accepted.player,
          // The push says nothing of where they are. They accepted a moment
          // ago, which only a player signed in can do; the list's own read
          // says exactly — now, when the page is open, and the moment it
          // next opens otherwise.
          presence: const FriendPresence(
            status: PresenceStatus.online,
            online: true,
          ),
          friendsSince: accepted.friendsSince,
        ),
      ]);
    }
    _nowFriends(who);
    if (seatPlayer?.userId == who) unawaited(_readSeat());
    if (_pageOpen) unawaited(refresh());
    _notify();
  }

  // ------------------------------------------------------------- helpers

  FriendRequestItem? _requestById(String requestId) {
    for (final r in incoming) {
      if (r.requestId == requestId) return r;
    }
    return null;
  }

  /// Whose request [requestId] is — as the requests, the search card, the
  /// profile or the player drawer last had it — or null.
  String? _userOfRequest(String requestId) {
    final asked = _requestById(requestId);
    if (asked != null) return asked.player.userId;
    if (lookup?.requestId == requestId) return lookup!.player.userId;
    if (profile?.requestId == requestId) return profile!.userId;
    if (seatProfile?.requestId == requestId) return seatProfile!.userId;
    return null;
  }

  String _nameOf(String userId) {
    for (final f in friends) {
      if (f.userId == userId) return f.displayName;
    }
    if (profile?.userId == userId) return profile!.player.displayName;
    if (seatPlayer?.userId == userId) return seatPlayer!.displayName;
    return '';
  }

  /// A move on [userId] is setting out: what the drawer said about the last
  /// one goes.
  void _clearSeatNoteFor(String? userId) {
    if (userId != null && seatPlayer?.userId == userId) seatNote = null;
  }

  /// A move made from the player drawer was refused: [code] is said in the
  /// drawer, where the move was made, and the profile is read again so the
  /// drawer offers the move that fits now.
  void _refusedAtSeat(String code) {
    seatNote = code;
    unawaited(_readSeat(keepNote: true));
  }

  void _dropRequest(String requestId) {
    incoming = incoming.where((r) => r.requestId != requestId).toList();
    incomingCount = incoming.length;
  }

  void _dropFriend(String userId) {
    friends = friends.where((f) => f.userId != userId).toList();
    _restate(userId, FriendStatus.none);
  }

  /// [userId] is a friend now, wherever they are on show.
  void _nowFriends(String userId) {
    if (userId.isEmpty) return;
    _restate(userId, FriendStatus.friends);
  }

  /// A request from [userId] is gone: they are nobody in particular again.
  void _noLongerPending(String userId) {
    if (lookup?.player.userId == userId &&
        FriendStatus.isPending(lookup!.friendStatus)) {
      lookup = lookup!.withStatus(FriendStatus.none);
    }
    if (profile?.userId == userId &&
        FriendStatus.isPending(profile!.friendStatus)) {
      profile = profile!.withStatus(FriendStatus.none);
    }
    if (seatProfile?.userId == userId &&
        FriendStatus.isPending(seatProfile!.friendStatus)) {
      _restateSeat(seatProfile!.withStatus(FriendStatus.none));
    }
  }

  /// What [userId] now is to this player, on the search card, the profile
  /// and the player drawer alike.
  void _restate(String userId, String status, {String? requestId}) {
    if (lookup?.player.userId == userId) {
      lookup = lookup!.withStatus(status, requestId: requestId);
    }
    if (profile?.userId == userId) {
      profile = profile!.withStatus(
        status,
        requestId: requestId,
        presence: presenceOf(userId),
      );
    }
    if (seatProfile?.userId == userId) {
      _restateSeat(
        seatProfile!.withStatus(
          status,
          requestId: requestId,
          presence: presenceOf(userId),
        ),
      );
    }
  }

  /// The drawer's player as a move has just left them. A read of their
  /// profile still out set off before the move, and would put the old
  /// relationship back when it landed: it is dropped.
  void _restateSeat(PublicProfile now) {
    _seatSeq++;
    seatLoading = false;
    seatProfile = now;
  }

  /// An accept or a reject refused: said in the player's language, and where
  /// the request is gone or answered, gone from the page too — the lists are
  /// read again to show what became of it. Refused from the player drawer, it
  /// is said there instead ([_refusedAtSeat]).
  void _refusedOnRequest(String requestId, Object error) {
    final code = _codeOf(error);
    final from = _userOfRequest(requestId);
    if (code == 'request_not_found' || code == 'request_not_pending') {
      _edits++;
      _dropRequest(requestId);
      unawaited(refresh());
    }
    if (from != null && from == seatPlayer?.userId) {
      _refusedAtSeat(code);
      return;
    }
    _tell(friendsRefusalText(_strings(), code));
  }
}
