/// Wire types, mirroring exactly what the Node server sends.
///
/// The server is the authority on every rule, so nothing here decides anything
/// — these are plain readers over its JSON. Fields the server may omit or send
/// as null are nullable here for the same reason: a blind table really does
/// send `chips: null` for everyone but you, and "hidden" has to stay
/// distinguishable from "broke".
library;

int _int(dynamic v) => v is num ? v.toInt() : 0;

/// Null stays null: a picture id of 0 would be a real-looking id the server
/// never issues, so "wearing nothing" must not collapse into it.
int? _intOrNull(dynamic v) => v is num ? v.toInt() : null;
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
  static const sideshow = 'sideshow';
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
    required this.activePictureId,
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
  /// Already resolved by the server: the catalogue picture being worn if
  /// there is one, else the provider photo, else null.
  final String? avatarUrl;

  /// The Google or Facebook photo, kept separately so "use my social picture"
  /// has something to go back to.
  final String? providerAvatarUrl;

  /// Which [ProfilePicture] is being worn, or null for none. This is what the
  /// picker ticks — it used to be the `/profiles/x.svg` path, which never
  /// matched the id the picker had and so nothing ever showed as selected.
  final int? activePictureId;
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
        activePictureId: _intOrNull(j['activePictureId']),
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

/// One room on the lobby's menu.
///
/// The server lists the pairs it offers rather than the client crossing every
/// category with every stake: the two are only meaningful together, and 5,000
/// existing as a stake does not mean a seen table exists at it.
class LobbyTable {
  const LobbyTable({
    required this.category,
    required this.bootAmount,
    required this.maxPot,
    required this.maxBlindMoves,
    this.minChips = 0,
    this.maxChips = 0,
  });

  final String category;
  final int bootAmount;

  /// The pot ceiling on this table, or 0 when the pot is uncapped. It comes
  /// from the server alongside the room itself, so the card and the table it
  /// opens cannot state different rules.
  final int maxPot;

  /// How many blind bets a player gets before their cards turn face up.
  final int maxBlindMoves;

  /// The stack this table is for. [minChips] is the floor and [maxChips] the
  /// ceiling, 0 meaning no limit at that end. Both come from the server so a
  /// card cannot advertise terms the door does not enforce — and the door is
  /// what enforces them: greying a card out is a courtesy, not the rule.
  final int minChips;
  final int maxChips;

  bool get potUncapped => maxPot <= 0;

  /// Whether a player holding [chips] may sit here. The limits are exclusive
  /// of themselves, matching the server: exactly the ceiling still fits, and
  /// exactly the floor is enough.
  bool admits(int chips) =>
      (minChips <= 0 || chips >= minChips) && (maxChips <= 0 || chips <= maxChips);

  /// Why they cannot, for a card that has to explain itself.
  bool tooRich(int chips) => maxChips > 0 && chips > maxChips;
  bool tooPoor(int chips) => minChips > 0 && chips < minChips;

  /// Whether this table states any entry requirement at all.
  bool get hasBand => minChips > 0 || maxChips > 0;

  factory LobbyTable.fromJson(Map<String, dynamic> j) => LobbyTable(
        category: _str(j['category']),
        bootAmount: _int(j['bootAmount']),
        maxPot: _int(j['maxPot']),
        maxBlindMoves: j['maxBlindMoves'] == null ? 4 : _int(j['maxBlindMoves']),
        minChips: _int(j['minChips']),
        maxChips: _int(j['maxChips']),
      );
}

/// The table the server remembers a player falling off. It comes with
/// `session:ready` on the next sign-in once their held seat has lapsed, so a
/// force-closed app can sit them straight back down there.
class ResumeHint {
  const ResumeHint({
    required this.roomId,
    required this.code,
    required this.category,
    required this.bootAmount,
  });

  final String roomId;
  final String code;
  final String category;
  final int bootAmount;

  factory ResumeHint.fromJson(Map<String, dynamic> j) => ResumeHint(
        roomId: '${j['roomId'] ?? ''}',
        code: '${j['code'] ?? ''}',
        category: '${j['category'] ?? 'seen'}',
        bootAmount: (j['bootAmount'] as num?)?.toInt() ?? 0,
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
    required this.sideshowTimeoutMs,
    required this.tables,
    this.minClientBuild = 0,
  });

  final int maxPlayers;
  final int minPlayers;
  final int bootAmount;
  final int turnTimeoutMs;
  final List<String> categories;
  final List<int> stakes;

  /// The rooms to show, in the order the server listed them.
  final List<LobbyTable> tables;
  final int privateBoot;
  final int privateMaxPot;

  /// Requirement 30: the stake and category that are capped, and the largest
  /// stack allowed to sit there. A zero cap means no restriction.
  final int entryCapBoot;
  final String entryCapCategory;
  final int entryCapMaxChips;

  /// How long a sideshow request stands before the server drops it. Only used
  /// to draw the countdown; the expiry itself is the server's.
  final int sideshowTimeoutMs;

  /// The oldest Android versionCode this server will talk to; 0 means no
  /// floor. Only the server can answer this — Play knows a newer build exists
  /// but not that the wire changed this morning.
  final int minClientBuild;

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
    sideshowTimeoutMs: 6000,
    tables: [
      LobbyTable(
          category: TableCategory.seen,
          bootAmount: 200,
          maxPot: 1200000,
          maxBlindMoves: 4),
      LobbyTable(
          category: TableCategory.blind,
          bootAmount: 200,
          maxPot: 0,
          maxBlindMoves: 4),
      LobbyTable(
          category: TableCategory.blind,
          bootAmount: 5000,
          maxPot: 0,
          maxBlindMoves: 4),
    ],
  );

  factory GameConfig.fromJson(Map<String, dynamic> j) => GameConfig(
        maxPlayers: _int(j['maxPlayers']),
        minPlayers: _int(j['minPlayers']),
        bootAmount: _int(j['bootAmount']),
        turnTimeoutMs: _int(j['turnTimeoutMs']),
        sideshowTimeoutMs:
            j['sideshowTimeoutMs'] == null ? 6000 : _int(j['sideshowTimeoutMs']),
        minClientBuild: _int(j['minClientBuild']),
        categories: (j['categories'] as List?)?.map((e) => '$e').toList() ??
            const [TableCategory.seen, TableCategory.blind],
        stakes: (j['stakes'] as List?)?.map(_int).toList() ?? const [200, 5000],
        tables: (j['tables'] as List?)
                ?.map((e) => LobbyTable.fromJson(Map<String, dynamic>.from(e as Map)))
                .toList() ??
            fallback.tables,
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
    required this.canSideshow,
    required this.sideshowWith,
    required this.raiseSteps,
    required this.show,
    required this.chips,
    required this.currentStake,
  });

  final bool canSee;
  final bool canPack;

  /// Whether a sideshow may be asked for right now. The server weighs up all
  /// of it — three players in the hand, both hands seen, one ask per turn —
  /// so the button only has to follow this.
  final bool canSideshow;

  /// Who the request would go to: the player on the viewer's right.
  final String? sideshowWith;

  /// The whole +/- ladder, already capped to the player's stack and the table's
  /// pot limit, so the client never computes a bet of its own.
  final List<int> raiseSteps;
  final int? show;
  final int chips;
  final int currentStake;

  factory TurnOptions.fromJson(Map<String, dynamic> j) => TurnOptions(
        canSee: j['canSee'] == true,
        canPack: j['canPack'] != false,
        canSideshow: j['canSideshow'] == true,
        sideshowWith: j['sideshowWith'] as String?,
        raiseSteps:
            (j['raiseSteps'] as List?)?.map(_int).toList() ?? const <int>[],
        show: j['show'] == null ? null : _int(j['show']),
        chips: _int(j['chips']),
        currentStake: _int(j['currentStake']),
      );
}

/// A sideshow waiting to be answered.
///
/// Public knowledge, cards excepted: it is in every viewer's snapshot so the
/// table can animate the request, and so a client that reconnects mid-request
/// puts the prompt back up rather than losing it.
class PendingSideshow {
  const PendingSideshow({
    required this.fromUserId,
    required this.fromSeat,
    required this.toUserId,
    required this.toSeat,
    required this.expiresAt,
  });

  final String fromUserId;
  final int fromSeat;
  final String toUserId;
  final int toSeat;

  /// Unix ms. The server drops the request at this point whatever the client
  /// does, so the countdown shown is a readout, never the thing that decides.
  final int expiresAt;

  factory PendingSideshow.fromJson(Map<String, dynamic> j) => PendingSideshow(
        fromUserId: _str(j['fromUserId']),
        fromSeat: _int(j['fromSeat']),
        toUserId: _str(j['toUserId']),
        toSeat: _int(j['toSeat']),
        expiresAt: _int(j['expiresAt']),
      );
}

/// One hand in a sideshow reveal. Only ever sent to the two players involved.
class SideshowHand {
  const SideshowHand({
    required this.userId,
    required this.displayName,
    required this.cards,
    required this.handName,
  });

  final String userId;
  final String displayName;
  final List<String> cards;
  final String handName;

  factory SideshowHand.fromJson(Map<String, dynamic> j) => SideshowHand(
        userId: _str(j['userId']),
        displayName: _str(j['displayName']),
        cards: (j['cards'] as List? ?? const []).map((e) => '$e').toList(),
        handName: _str(j['handName']),
      );
}

class SideshowReveal {
  const SideshowReveal({required this.hands, required this.packedUserId});

  final List<SideshowHand> hands;
  final String? packedUserId;

  factory SideshowReveal.fromJson(Map<String, dynamic> j) => SideshowReveal(
        hands: (j['hands'] as List? ?? const [])
            .map((e) => SideshowHand.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        packedUserId: j['packedUserId'] as String?,
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
    required this.missedTurns,
    required this.maxMissedTurns,
    required this.cards,
    required this.options,
    this.unfundedDeadline,
  });

  final int seatIndex;
  final int chips;
  final String status;
  final bool isBlind;

  /// Blind bets still allowed before the cards turn face up by themselves.
  final int blindMovesLeft;
  final int contributed;

  /// Requirement 31: turns auto-packed in a row, and how many the table allows
  /// before the seat is given back. Sent only to the player it concerns.
  final int missedTurns;
  final int maxMissedTurns;

  /// How many more can be missed before being shown out. Zero means the next
  /// one does it.
  int get missesLeft =>
      maxMissedTurns <= 0 ? 1 : (maxMissedTurns - missedTurns - 1).clamp(0, 99);

  /// True when one more missed turn costs them the seat.
  bool get onLastWarning => missedTurns > 0 && missesLeft == 0;

  /// Empty until this player has looked — the server never sends a card early.
  final List<String> cards;
  final TurnOptions? options;

  /// Epoch ms. Set while this player cannot cover the boot and the table is
  /// holding their seat for a chip purchase; the seat goes when it passes.
  final int? unfundedDeadline;

  /// Whole seconds left of that grace, or null when there is none.
  int? unfundedSecondsLeft(DateTime now) {
    final deadline = unfundedDeadline;
    if (deadline == null) return null;
    final ms = deadline - now.millisecondsSinceEpoch;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  factory You.fromJson(Map<String, dynamic> j) => You(
        seatIndex: _int(j['seatIndex']),
        chips: _int(j['chips']),
        status: _str(j['status']),
        isBlind: j['isBlind'] == true,
        blindMovesLeft: _int(j['blindMovesLeft']),
        contributed: _int(j['contributed']),
        missedTurns: _int(j['missedTurns']),
        maxMissedTurns:
            j['maxMissedTurns'] == null ? 3 : _int(j['maxMissedTurns']),
        cards: (j['cards'] as List?)?.map((e) => '$e').toList() ?? const [],
        options: j['options'] is Map
            ? TurnOptions.fromJson(Map<String, dynamic>.from(j['options'] as Map))
            : null,
        unfundedDeadline:
            j['unfundedDeadline'] == null ? null : _int(j['unfundedDeadline']),
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
    required this.sideshow,
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

  /// The sideshow awaiting an answer, if any. At most one at a time.
  final PendingSideshow? sideshow;
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
        sideshow: j['sideshow'] is Map
            ? PendingSideshow.fromJson(
                Map<String, dynamic>.from(j['sideshow'] as Map))
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

/// One row of the server's picture catalogue (GET /api/profiles).
class ProfilePicture {
  const ProfilePicture({
    required this.id,
    required this.name,
    required this.url,
    required this.type,
    required this.cost,
    required this.durationDays,
    required this.owned,
    required this.expiresAt,
  });

  final int id;

  /// What to call it in the picker — "Bear", "Wolf".
  final String name;

  /// Server-relative ("/profiles/bear.svg") or absolute.
  final String url;

  /// 'FREE' or 'PREMIUM'.
  final String type;

  /// Chips it costs. Always 0 when [free].
  final int cost;

  /// How long a purchase lasts. 0 means for ever, which every free picture is
  /// and a premium one is until somebody prices it as a rental.
  final int durationDays;

  /// Whether this player may wear it: every free picture, plus the premium
  /// ones they have bought. The server decides this per viewer — the client
  /// never works it out from the wallet.
  final bool owned;

  /// Epoch ms this player's rental runs out; 0 when they do not own it, or own
  /// it for ever.
  final int expiresAt;

  bool get free => type == 'FREE';

  /// Whether buying this one rents it rather than keeps it.
  bool get rented => durationDays > 0;

  /// Whole days left on this player's rental, or null when it never runs out.
  /// Rounded UP, so the last few hours read as "1 day left" rather than "0".
  int? daysLeft(DateTime now) {
    if (expiresAt <= 0) return null;
    final left = expiresAt - now.millisecondsSinceEpoch;
    if (left <= 0) return 0;
    return (left / Duration.millisecondsPerDay).ceil();
  }

  /// Locked = premium and not yet bought: the picker draws a padlock and the
  /// price, and tapping it offers to buy.
  bool get locked => !owned;

  factory ProfilePicture.fromJson(Map<String, dynamic> j) => ProfilePicture(
        id: _int(j['id']),
        name: _str(j['name']),
        url: _str(j['url']),
        type: _str(j['type']).isEmpty ? 'FREE' : _str(j['type']),
        cost: _int(j['cost']),
        durationDays: _int(j['durationDays']),
        expiresAt: _int(j['expiresAt']),
        // Absent means the server did not say, and the safe reading of that is
        // "not owned" — a free picture is only ever sent with owned true.
        owned: j['owned'] == true,
      );
}
