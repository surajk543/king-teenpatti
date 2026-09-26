/// Friends V1 on the wire (owner's brief, 26 Sep 2026): a player found by
/// their Player ID, the requests between two players, the friend list with
/// each friend's presence, and a player's public profile.
///
/// Plain readers over the server's JSON, tolerant as every DTO in the app:
/// anything missing or of the wrong type reads as empty rather than throwing,
/// and nothing here decides anything — who may add whom, who is online and
/// what a friend is playing are the server's answers. None of these carries a
/// wallet figure: the server sends none (the contract's "never chips, diamond,
/// hammer, missile …") and nothing here would read one.
library;

int _int(dynamic v) => v is num && v.isFinite ? v.toInt() : 0;
int? _intOrNull(dynamic v) => v is num && v.isFinite ? v.toInt() : null;
String _str(dynamic v) => v is String ? v : '';
String? _strOrNull(dynamic v) => v is String && v.isNotEmpty ? v : null;
Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

/// A request's id as text, whichever way the server writes it: the table's
/// key is a BIGSERIAL, so a number is expected, and a string is taken as it
/// is. Null for anything else — an id that is not there is never a "0".
String? friendRequestIdOf(Object? v) {
  if (v is num && v.isFinite) return v.toInt().toString();
  if (v is String && v.trim().isNotEmpty) return v.trim();
  return null;
}

/// What a player is to the one looking at them (`friendStatus`).
abstract final class FriendStatus {
  static const none = 'NONE';

  /// The viewer asked them and is waiting for an answer.
  static const pendingSent = 'PENDING_SENT';

  /// They asked the viewer: the viewer may accept.
  static const pendingReceived = 'PENDING_RECEIVED';
  static const friends = 'FRIENDS';

  /// The viewer's own card.
  static const self = 'SELF';

  static const values = [none, pendingSent, pendingReceived, friends, self];

  /// [raw] when it is one of [values], else [none]: a status this build does
  /// not know offers the one action that is always safe to offer again.
  static String read(Object? raw) =>
      raw is String && values.contains(raw) ? raw : none;

  /// Whether a request stands between the two, either way.
  static bool isPending(String status) =>
      status == pendingSent || status == pendingReceived;
}

/// Where a friend is (`status` on a friend and a profile's `presence`).
abstract final class PresenceStatus {
  static const playing = 'PLAYING';
  static const online = 'ONLINE';
  static const offline = 'OFFLINE';

  /// The friend list's order: PLAYING, then ONLINE, then OFFLINE.
  static int rank(String status) => switch (status) {
    playing => 0,
    online => 1,
    _ => 2,
  };
}

/// The game a playing friend is at (`game`), as the server writes it.
abstract final class PresenceGame {
  static const teenPatti = 'TEEN_PATTI';
  static const poker = 'POKER';
}

/// The one picture of a player every friends answer carries: who they are
/// and what they wear. Never anything of their account beyond that.
class PlayerCard {
  const PlayerCard({
    required this.userId,
    required this.displayName,
    this.pictureId,
    this.pictureUrl,
  });

  /// Their Player ID.
  final String userId;
  final String displayName;

  /// The catalogue picture they wear, or null for none.
  final int? pictureId;

  /// The picture as the server resolved it — the worn picture, else the
  /// provider's photo — server-relative or absolute; null for none, when the
  /// player's initial is drawn instead.
  final String? pictureUrl;

  factory PlayerCard.fromJson(Map<String, dynamic> j) {
    final picture = _map(j['profilePicture']);
    return PlayerCard(
      userId: _str(j['userId']),
      displayName: _str(j['displayName']),
      pictureId: _intOrNull(picture['id']),
      pictureUrl: _strOrNull(picture['url']),
    );
  }
}

/// Where a friend is and, while they play, at what: the status, the two
/// flags, and the game and variant the server names (`TEEN_PATTI` / `SEEN`).
/// Never a table or a room.
class FriendPresence {
  const FriendPresence({
    required this.status,
    this.online = false,
    this.playing = false,
    this.game,
    this.variant,
  });

  static const offline = FriendPresence(status: PresenceStatus.offline);

  /// One of [PresenceStatus].
  final String status;
  final bool online;
  final bool playing;

  /// [PresenceGame.teenPatti] or [PresenceGame.poker]; null unless playing.
  final String? game;

  /// The category upper-cased — `SEEN`, `TEXAS_HOLDEM` …; null unless
  /// playing.
  final String? variant;

  bool get isPlaying => status == PresenceStatus.playing;

  /// Online counts a player who is playing: the server says so too.
  bool get isOnline => status != PresenceStatus.offline;

  /// Read from an object carrying `status`, `online`, `playing`, `game` and
  /// `variant` — a friend, or a profile's `presence`. A status this build does
  /// not know is worked out from the two flags, the way the server works it
  /// out: playing, else online, else offline.
  factory FriendPresence.fromJson(Map<String, dynamic> j) {
    final playing = j['playing'] == true;
    final online = j['online'] == true;
    final raw = j['status'];
    final status =
        raw == PresenceStatus.playing ||
            raw == PresenceStatus.online ||
            raw == PresenceStatus.offline
        ? raw as String
        : playing
        ? PresenceStatus.playing
        : online
        ? PresenceStatus.online
        : PresenceStatus.offline;
    final isPlaying = status == PresenceStatus.playing;
    return FriendPresence(
      status: status,
      online: online || status != PresenceStatus.offline,
      playing: isPlaying,
      game: isPlaying ? _strOrNull(j['game']) : null,
      variant: isPlaying ? _strOrNull(j['variant']) : null,
    );
  }
}

/// One friend on the list (`GET /api/friends`, and an accepted request's
/// answer): their card, where they are, and since when they are friends.
class FriendItem {
  const FriendItem({
    required this.player,
    required this.presence,
    this.friendsSince = 0,
  });

  final PlayerCard player;
  final FriendPresence presence;

  /// Epoch ms the two became friends; 0 when not sent.
  final int friendsSince;

  String get userId => player.userId;
  String get displayName => player.displayName;

  factory FriendItem.fromJson(Map<String, dynamic> j) => FriendItem(
    player: PlayerCard.fromJson(j),
    presence: FriendPresence.fromJson(j),
    friendsSince: _int(j['friendsSince']),
  );
}

/// The friend list in the order the page shows it: PLAYING, then ONLINE,
/// then OFFLINE, and by name within each (case-insensitive) — the server's
/// own order, kept when the app adds or moves a friend itself.
List<FriendItem> sortFriends(Iterable<FriendItem> friends) {
  final list = friends.toList();
  list.sort((a, b) {
    final byStatus = PresenceStatus.rank(
      a.presence.status,
    ).compareTo(PresenceStatus.rank(b.presence.status));
    if (byStatus != 0) return byStatus;
    final byName = a.displayName.toLowerCase().compareTo(
      b.displayName.toLowerCase(),
    );
    if (byName != 0) return byName;
    // Two friends of one name keep one order between polls.
    return a.userId.compareTo(b.userId);
  });
  return list;
}

/// One pending request (`GET /api/friends/requests`): who, and when.
class FriendRequestItem {
  const FriendRequestItem({
    required this.requestId,
    required this.player,
    this.createdAt = 0,
  });

  /// What accepting or rejecting it names in the URL.
  final String requestId;

  /// The other player: who asked, on an incoming request; who was asked, on
  /// an outgoing one.
  final PlayerCard player;

  /// Epoch ms it was sent.
  final int createdAt;

  factory FriendRequestItem.fromJson(Map<String, dynamic> j) =>
      FriendRequestItem(
        requestId: friendRequestIdOf(j['requestId']) ?? '',
        player: PlayerCard.fromJson(_map(j['player'])),
        createdAt: _int(j['createdAt']),
      );
}

/// A request the viewer sent, accepted (`friend:accepted`, pushed to its
/// sender the moment the other player accepts it — at a table or in the
/// lobby): which request, who accepted it, and since when the two are
/// friends. The server sends no presence with it, and nothing here guesses one.
class FriendAccepted {
  const FriendAccepted({
    required this.requestId,
    required this.player,
    this.friendsSince = 0,
  });

  final String requestId;

  /// The player who accepted.
  final PlayerCard player;

  /// Epoch ms the two became friends; 0 when not sent.
  final int friendsSince;

  factory FriendAccepted.fromJson(Map<String, dynamic> j) => FriendAccepted(
    requestId: friendRequestIdOf(j['requestId']) ?? '',
    player: PlayerCard.fromJson(_map(j['player'])),
    friendsSince: _int(j['friendsSince']),
  );
}

/// Every pending request of the viewer's, both ways, newest first.
class FriendRequests {
  const FriendRequests({this.incoming = const [], this.outgoing = const []});

  final List<FriendRequestItem> incoming;
  final List<FriendRequestItem> outgoing;

  static List<FriendRequestItem> _read(Object? raw) => raw is List
      ? raw
            .whereType<Map>()
            .map(
              (e) => FriendRequestItem.fromJson(Map<String, dynamic>.from(e)),
            )
            // A request with no id could be neither accepted nor rejected.
            .where((r) => r.requestId.isNotEmpty)
            .toList()
      : const [];

  factory FriendRequests.fromJson(Map<String, dynamic> j) => FriendRequests(
    incoming: _read(j['incoming']),
    outgoing: _read(j['outgoing']),
  );
}

/// A player found by their Player ID (`GET /api/players/{playerId}`): their
/// card and what they are to the viewer — with the request's id while one is
/// pending, so the answer can act on it.
class PlayerLookup {
  const PlayerLookup({
    required this.player,
    required this.friendStatus,
    this.requestId,
  });

  final PlayerCard player;

  /// One of [FriendStatus].
  final String friendStatus;

  /// The pending request between the two; null unless [friendStatus] is
  /// PENDING_SENT or PENDING_RECEIVED.
  final String? requestId;

  /// The same player, as they now stand to the viewer.
  PlayerLookup withStatus(String status, {String? requestId}) => PlayerLookup(
    player: player,
    friendStatus: status,
    requestId: FriendStatus.isPending(status) ? requestId : null,
  );

  factory PlayerLookup.fromJson(Map<String, dynamic> j) {
    final status = FriendStatus.read(j['friendStatus']);
    return PlayerLookup(
      player: PlayerCard.fromJson(_map(j['player'])),
      friendStatus: status,
      requestId: FriendStatus.isPending(status)
          ? friendRequestIdOf(j['requestId'])
          : null,
    );
  }
}

/// A player's gameplay record, as their profile shows it: counts of hands
/// and a win rate. Deliberately no chip figure (no winnings, no biggest pot).
class PlayerStats {
  const PlayerStats({
    this.handsPlayed = 0,
    this.handsWon = 0,
    this.handsLost = 0,
    this.handsLeft = 0,
    this.winRate = 0,
  });

  final int handsPlayed;
  final int handsWon;
  final int handsLost;

  /// Hands they left before the end.
  final int handsLeft;

  /// Per cent of the hands played that they won, 0 to 100, to two places.
  final double winRate;

  factory PlayerStats.fromJson(Map<String, dynamic> j) {
    final rate = j['winRate'];
    return PlayerStats(
      handsPlayed: _int(j['handsPlayed']),
      handsWon: _int(j['handsWon']),
      handsLost: _int(j['handsLost']),
      handsLeft: _int(j['handsLeft']),
      winRate: rate is num && rate.isFinite
          ? rate.toDouble().clamp(0.0, 100.0)
          : 0,
    );
  }
}

/// A player's public profile (`GET /api/players/{playerId}/profile`).
class PublicProfile {
  const PublicProfile({
    required this.player,
    required this.friendStatus,
    this.requestId,
    this.presence,
    this.stats = const PlayerStats(),
  });

  final PlayerCard player;

  /// One of [FriendStatus].
  final String friendStatus;

  /// The pending request between the two, while there is one.
  final String? requestId;

  /// Where they are — sent only to a friend and to the player themselves, so
  /// null for everyone else, and never guessed at.
  final FriendPresence? presence;
  final PlayerStats stats;

  String get userId => player.userId;

  /// The same profile as it now stands to the viewer: what a request sent,
  /// accepted or a friend removed changes. Presence goes with the friendship.
  PublicProfile withStatus(
    String status, {
    String? requestId,
    FriendPresence? presence,
  }) => PublicProfile(
    player: player,
    friendStatus: status,
    requestId: FriendStatus.isPending(status) ? requestId : null,
    presence: status == FriendStatus.friends || status == FriendStatus.self
        ? presence ?? this.presence
        : null,
    stats: stats,
  );

  factory PublicProfile.fromJson(Map<String, dynamic> j) {
    final p = _map(j['profile']);
    final status = FriendStatus.read(p['friendStatus']);
    final presence = p['presence'];
    return PublicProfile(
      player: PlayerCard.fromJson(p),
      friendStatus: status,
      requestId: FriendStatus.isPending(status)
          ? friendRequestIdOf(p['requestId'])
          : null,
      presence: presence is Map
          ? FriendPresence.fromJson(Map<String, dynamic>.from(presence))
          : null,
      stats: PlayerStats.fromJson(_map(p['stats'])),
    );
  }
}
