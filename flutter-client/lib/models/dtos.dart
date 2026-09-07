/// Wire types, mirroring exactly what the Node server sends.
///
/// The server is the authority on every rule, so nothing here decides anything
/// — these are plain readers over its JSON. Fields the server may omit or send
/// as null are nullable here for the same reason: a blind table really does
/// send `chips: null` for everyone but you, and "hidden" has to stay
/// distinguishable from "broke".
library;

int _int(dynamic v) => v is num ? v.toInt() : 0;
String _str(dynamic v) => v is String ? v : '';

class SeatState {
  static const empty = 'empty';
  static const waiting = 'waiting';
  static const active = 'active';
  static const packed = 'packed';
  static const lost = 'lost';
  static const won = 'won';
}

class TableState {
  static const waiting = 'waiting';
  static const starting = 'starting';
  static const betting = 'betting';
  static const showdown = 'showdown';
}

class TableCategory {
  static const seen = 'seen';
  static const blind = 'blind';
}

class GameAction {
  static const see = 'see';
  static const chaal = 'chaal';
  static const raise = 'raise';
  static const pack = 'pack';
  static const show = 'show';
}

class Rewards {
  const Rewards({
    required this.milestoneAvailable,
    required this.milestoneReward,
    required this.handsToNextMilestone,
    required this.bonusReward,
    required this.bonusReadyAt,
    required this.bonusAvailable,
  });

  final bool milestoneAvailable;
  final int milestoneReward;
  final int handsToNextMilestone;
  final int bonusReward;

  /// Epoch ms the four-hour bonus unlocks; 0 means it is ready now. The server
  /// calls this `bonusReadyAt`.
  final int bonusReadyAt;

  /// The server's own verdict, which is what actually gates the claim.
  final bool bonusAvailable;

  bool get bonusReady =>
      bonusAvailable || bonusReadyAt <= DateTime.now().millisecondsSinceEpoch;

  Duration get untilBonus {
    final ms = bonusReadyAt - DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  factory Rewards.fromJson(Map<String, dynamic> j) => Rewards(
        milestoneAvailable: j['milestoneAvailable'] == true,
        milestoneReward: _int(j['milestoneReward']),
        handsToNextMilestone: _int(j['handsToNextMilestone']),
        bonusReward: _int(j['bonusReward']),
        bonusReadyAt: _int(j['bonusReadyAt']),
        bonusAvailable: j['bonusAvailable'] == true,
      );
}

class User {
  const User({
    required this.id,
    required this.provider,
    required this.displayName,
    required this.chips,
    required this.avatarUrl,
    required this.providerAvatarUrl,
    required this.avatarChoice,
    required this.handsPlayed,
    required this.handsWon,
    required this.handsLost,
    required this.handsLeftMid,
    required this.totalWinnings,
    required this.biggestPot,
    required this.rewards,
  });

  final String id;
  final String provider;
  final String displayName;
  final int chips;
  final String? avatarUrl;
  final String? providerAvatarUrl;
  final String? avatarChoice;
  final int handsPlayed;
  final int handsWon;
  final int handsLost;
  final int handsLeftMid;
  final int totalWinnings;
  final int biggestPot;
  final Rewards? rewards;

  factory User.fromJson(Map<String, dynamic> j) => User(
        id: _str(j['id']),
        provider: _str(j['provider']),
        displayName: _str(j['displayName']),
        chips: _int(j['chips']),
        avatarUrl: j['avatarUrl'] as String?,
        providerAvatarUrl: j['providerAvatarUrl'] as String?,
        avatarChoice: j['avatarChoice'] as String?,
        handsPlayed: _int(j['handsPlayed']),
        handsWon: _int(j['handsWon']),
        handsLost: _int(j['handsLost']),
        handsLeftMid: _int(j['handsLeftMid']),
        totalWinnings: _int(j['totalWinnings']),
        biggestPot: _int(j['biggestPot']),
        rewards: j['rewards'] is Map
            ? Rewards.fromJson(Map<String, dynamic>.from(j['rewards'] as Map))
            : null,
      );
}

class GameConfig {
  const GameConfig({
    required this.maxPlayers,
    required this.minPlayers,
    required this.bootAmount,
    required this.turnTimeoutMs,
    required this.categories,
    required this.stakes,
    required this.privateBoot,
    required this.privateMaxPot,
    required this.entryCapBoot,
    required this.entryCapCategory,
    required this.entryCapMaxChips,
  });

  final int maxPlayers;
  final int minPlayers;
  final int bootAmount;
  final int turnTimeoutMs;
  final List<String> categories;
  final List<int> stakes;
  final int privateBoot;
  final int privateMaxPot;

  /// Requirement 30: the stake and category that are capped, and the largest
  /// stack allowed to sit there. A zero cap means no restriction.
  final int entryCapBoot;
  final String entryCapCategory;
  final int entryCapMaxChips;

  /// Whether this table is closed to a player holding [chips].
  bool cappedFor(int chips, {required int boot, required String category}) =>
      entryCapMaxChips > 0 &&
      boot == entryCapBoot &&
      category == entryCapCategory &&
      chips > entryCapMaxChips;

  static const fallback = GameConfig(
    maxPlayers: 5,
    minPlayers: 2,
    bootAmount: 200,
    turnTimeoutMs: 25000,
    categories: [TableCategory.seen, TableCategory.blind],
    stakes: [200, 5000],
    privateBoot: 200,
    privateMaxPot: 500000,
    entryCapBoot: 200,
    entryCapCategory: TableCategory.blind,
    entryCapMaxChips: 500000,
  );

  factory GameConfig.fromJson(Map<String, dynamic> j) => GameConfig(
        maxPlayers: _int(j['maxPlayers']),
        minPlayers: _int(j['minPlayers']),
        bootAmount: _int(j['bootAmount']),
        turnTimeoutMs: _int(j['turnTimeoutMs']),
        categories: (j['categories'] as List?)?.map((e) => '$e').toList() ??
            const [TableCategory.seen, TableCategory.blind],
        stakes: (j['stakes'] as List?)?.map(_int).toList() ?? const [200, 5000],
        privateBoot: _int(j['privateBoot']),
        privateMaxPot: _int(j['privateMaxPot']),
        entryCapBoot: _int(j['entryCapBoot']),
        entryCapCategory: _str(j['entryCapCategory']),
        entryCapMaxChips: _int(j['entryCapMaxChips']),
      );
}

class Seat {
  const Seat({
    required this.seatIndex,
    required this.userId,
    required this.displayName,
    required this.avatarUrl,
    required this.chips,
    required this.status,
    required this.isBlind,
    required this.lastBet,
    required this.lastAction,
    required this.contributed,
    required this.connected,
    required this.cardCount,
  });

  final int seatIndex;
  final String? userId;
  final String displayName;
  final String? avatarUrl;

  /// Null when withheld — a blind table, someone else's seat. Not the same as
  /// a player who is genuinely broke.
  final int? chips;
  final String status;
  final bool isBlind;

  /// The chips this player put in with their most recent move, and what that
  /// move was. Zero until they have bet — the boot is not a bet.
  final int lastBet;
  final String? lastAction;

  /// Everything they have put in this hand, boot included.
  final int contributed;
  final bool connected;
  final int cardCount;

  bool get occupied => status != SeatState.empty;
  bool get inHand => status == SeatState.active;

  factory Seat.fromJson(Map<String, dynamic> j) => Seat(
        seatIndex: _int(j['seatIndex']),
        userId: j['userId'] as String?,
        displayName: _str(j['displayName']),
        avatarUrl: j['avatarUrl'] as String?,
        chips: j['chips'] == null ? null : _int(j['chips']),
        status: _str(j['status']),
        isBlind: j['isBlind'] == true,
        lastBet: _int(j['lastBet']),
        lastAction: j['lastAction'] as String?,
        contributed: _int(j['contributed']),
        connected: j['connected'] != false,
        cardCount: _int(j['cardCount']),
      );
}

class TurnOptions {
  const TurnOptions({
    required this.canSee,
    required this.canPack,
    required this.raiseSteps,
    required this.show,
    required this.chips,
    required this.currentStake,
  });

  final bool canSee;
  final bool canPack;

  /// The whole +/- ladder, already capped to the player's stack and the table's
  /// pot limit, so the client never computes a bet of its own.
  final List<int> raiseSteps;
  final int? show;
  final int chips;
  final int currentStake;

  factory TurnOptions.fromJson(Map<String, dynamic> j) => TurnOptions(
        canSee: j['canSee'] == true,
        canPack: j['canPack'] != false,
        raiseSteps:
            (j['raiseSteps'] as List?)?.map(_int).toList() ?? const <int>[],
        show: j['show'] == null ? null : _int(j['show']),
        chips: _int(j['chips']),
        currentStake: _int(j['currentStake']),
      );
}

class Turn {
  const Turn({required this.seatIndex, required this.userId, required this.deadline});

  final int seatIndex;
  final String? userId;

  /// Unix ms. Sent for whoever is to act, not just for you, so every seat can
  /// run its own clock.
  final int deadline;

  factory Turn.fromJson(Map<String, dynamic> j) => Turn(
        seatIndex: _int(j['seatIndex']),
        userId: j['userId'] as String?,
        deadline: _int(j['deadline']),
      );
}

class You {
  const You({
    required this.seatIndex,
    required this.chips,
    required this.status,
    required this.isBlind,
    required this.blindMovesLeft,
    required this.contributed,
    required this.cards,
    required this.options,
  });

  final int seatIndex;
  final int chips;
  final String status;
  final bool isBlind;

  /// Blind bets still allowed before the cards turn face up by themselves.
  final int blindMovesLeft;
  final int contributed;

  /// Empty until this player has looked — the server never sends a card early.
  final List<String> cards;
  final TurnOptions? options;

  factory You.fromJson(Map<String, dynamic> j) => You(
        seatIndex: _int(j['seatIndex']),
        chips: _int(j['chips']),
        status: _str(j['status']),
        isBlind: j['isBlind'] == true,
        blindMovesLeft: _int(j['blindMovesLeft']),
        contributed: _int(j['contributed']),
        cards: (j['cards'] as List?)?.map((e) => '$e').toList() ?? const [],
        options: j['options'] is Map
            ? TurnOptions.fromJson(Map<String, dynamic>.from(j['options'] as Map))
            : null,
      );
}

class RoomState {
  const RoomState({
    required this.roomId,
    required this.code,
    required this.category,
    required this.chipsHidden,
    required this.state,
    required this.handNo,
    required this.dealerSeat,
    required this.minPlayers,
    required this.bootAmount,
    required this.turnTimeoutMs,
    required this.startsAt,
    required this.pot,
    required this.maxPot,
    required this.stake,
    required this.turn,
    required this.you,
    required this.seats,
  });

  final String roomId;
  final String code;
  final String category;
  final bool chipsHidden;
  final String state;
  final int handNo;
  final int dealerSeat;
  final int minPlayers;
  final int bootAmount;
  final int turnTimeoutMs;
  final int startsAt;
  final int pot;
  final int maxPot;
  final int stake;
  final Turn? turn;
  final You? you;
  final List<Seat> seats;

  bool get seated => you != null;

  factory RoomState.fromJson(Map<String, dynamic> j) => RoomState(
        roomId: _str(j['roomId']),
        code: _str(j['code']),
        category: _str(j['category']),
        chipsHidden: j['chipsHidden'] == true,
        state: _str(j['state']),
        handNo: _int(j['handNo']),
        dealerSeat: _int(j['dealerSeat']),
        minPlayers: _int(j['minPlayers']),
        bootAmount: _int(j['bootAmount']),
        turnTimeoutMs: _int(j['turnTimeoutMs']),
        startsAt: _int(j['startsAt']),
        pot: _int(j['pot']),
        maxPot: _int(j['maxPot']),
        stake: _int(j['stake']),
        turn: j['turn'] is Map
            ? Turn.fromJson(Map<String, dynamic>.from(j['turn'] as Map))
            : null,
        you: j['you'] is Map
            ? You.fromJson(Map<String, dynamic>.from(j['you'] as Map))
            : null,
        seats: (j['seats'] as List?)
                ?.map((e) => Seat.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            const [],
      );
}

class Reveal {
  const Reveal({
    required this.userId,
    required this.displayName,
    required this.cards,
    required this.handName,
    required this.won,
  });

  final String userId;
  final String displayName;
  final List<String> cards;
  final String handName;
  final bool won;

  factory Reveal.fromJson(Map<String, dynamic> j) => Reveal(
        userId: _str(j['userId']),
        displayName: _str(j['displayName']),
        cards: (j['cards'] as List?)?.map((e) => '$e').toList() ?? const [],
        handName: _str(j['handName']),
        won: j['won'] == true,
      );
}

class ChatMessage {
  const ChatMessage({
    required this.userId,
    required this.displayName,
    required this.text,
    required this.at,
  });

  final String userId;
  final String displayName;
  final String text;
  final int at;

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        userId: _str(j['userId']),
        displayName: _str(j['displayName']),
        text: _str(j['text']),
        at: _int(j['at']),
      );
}

class ProfilePicture {
  const ProfilePicture({required this.id, required this.url});

  final String id;
  final String url;

  factory ProfilePicture.fromJson(Map<String, dynamic> j) =>
      ProfilePicture(id: _str(j['id']), url: _str(j['url']));
}
