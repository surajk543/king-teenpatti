/// Wire types, mirroring exactly what the Node server sends.
///
/// The server is the authority on every rule, so nothing here decides anything
/// — these are plain readers over its JSON. Fields the server may omit or send
/// as null are nullable here for the same reason: a blind table really does
/// send `chips: null` for everyone but you, and "hidden" has to stay
/// distinguishable from "broke".
library;

import 'dart:math' as math;

int _int(dynamic v) => v is num ? v.toInt() : 0;

/// Null stays null: a picture id of 0 would be a real-looking id the server
/// never issues, so "wearing nothing" must not collapse into it.
int? _intOrNull(dynamic v) => v is num ? v.toInt() : null;
String _str(dynamic v) => v is String ? v : '';

/// A list of card codes off the wire ("As", "Td"), tolerant as every DTO here:
/// anything that is not a list reads as empty, and anything in it that is not
/// a usable code is dropped rather than drawn as a broken card.
List<String> cardCodes(Object? raw) => raw is List
    ? raw.whereType<String>().where((e) => e.length >= 2).toList()
    : const [];

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

  /// Variation Teen Patti: a table that bets as a seen one does, hides other
  /// players' stacks as a blind one does (owner, 18 Sep 2026), and whose every
  /// hand opens with one player choosing the rules it is decided by
  /// ([Variation], [VariationState]).
  static const variation = 'variation';

  /// The POKER family (server side: go-server/internal/poker). Four wire
  /// categories, each a game of its own at the table and one card each in the
  /// lobby's Poker category. A poker room's snapshot carries `game: "poker"`
  /// and a `poker` block ([PokerState]); a Teen Patti room's carries neither.
  static const threeCardPoker = 'three_card_poker';
  static const fiveCardDraw = 'five_card_draw';
  static const texasHoldem = 'texas_holdem';
  static const omaha = 'omaha';

  /// The lobby's name for the poker FAMILY — the front card the four poker
  /// tables are filed under. Never a wire category: the server knows only the
  /// four above.
  static const pokerFamily = 'poker';

  /// The four poker categories, in the order the lobby and the rules name
  /// them.
  static const pokerCategories = [
    texasHoldem,
    omaha,
    fiveCardDraw,
    threeCardPoker,
  ];

  /// Whether [category] is one of the poker games.
  static bool isPoker(String category) => pokerCategories.contains(category);
}

/// The four poker games, by the string the server uses for both the lobby
/// category and `poker.variant`. The same values as [TableCategory]'s poker
/// constants, named here for the table.
class PokerVariant {
  static const texasHoldem = TableCategory.texasHoldem;
  static const omaha = TableCategory.omaha;
  static const fiveCardDraw = TableCategory.fiveCardDraw;
  static const threeCardPoker = TableCategory.threeCardPoker;

  /// Blinds rather than an ante: Hold'em and Omaha.
  static bool usesBlinds(String variant) =>
      variant == texasHoldem || variant == omaha;

  /// A board of five community cards: Hold'em and Omaha.
  static bool hasBoard(String variant) => usesBlinds(variant);
}

/// The streets a poker hand moves through, as `poker.street` names them.
/// Empty between hands.
class PokerStreet {
  static const none = '';

  // Hold'em and Omaha.
  static const preflop = 'preflop';
  static const flop = 'flop';
  static const turn = 'turn';
  static const river = 'river';

  // 5-Card Draw.
  static const predraw = 'predraw';
  static const draw = 'draw';
  static const postdraw = 'postdraw';

  // 3-Card Poker: play for the ante, or fold.
  static const decision = 'decision';

  static const showdown = 'showdown';
}

/// The moves a poker player can make, as `poker:action.action` names them.
class PokerAction {
  static const fold = 'fold';
  static const check = 'check';
  static const call = 'call';
  static const bet = 'bet';
  static const raise = 'raise';

  /// 3-Card Poker: match the ante to play the hand against the dealer.
  static const play = 'play';

  /// 5-Card Draw: exchange the cards named, or none to stand pat.
  static const draw = 'draw';
}

/// The seven rule sets a variation table's hand can be played under.
///
/// These are the server's wire values and they are matched EXACTLY — the
/// server refuses `muflis`, `Lowest Joker` and every other near miss as
/// `invalid_variation` rather than guessing. The client never invents one: the
/// picker is drawn from the list the server sends ([VariationState.options]),
/// and these constants exist for naming them in the player's language.
class Variation {
  static const muflis = 'MUFLIS';
  static const ak47 = 'AK47';
  static const joker = 'JOKER';
  static const hukam = 'HUKAM';
  static const lowestJoker = 'LOWEST_JOKER';
  static const highestJoker = 'HIGHEST_JOKER';

  /// 5-Card Teen Patti (owner, 18 Sep 2026): every player holds FIVE cards and
  /// plays the best three of them. The SERVER finds those three — the strongest
  /// of the ten three-card hands the five hold, by the ordinary ranking — and
  /// names them in `best`; the player never picks, and the client never decides
  /// how many cards anybody holds ([VariationState.cardsPerPlayer]).
  static const fiveCard = 'FIVE_CARD';

  /// The menu in the server's order, for a snapshot that carries no options.
  /// [fiveCard] is last, as the server lists it, so the six older keys keep
  /// their places on the picker.
  static const all = [
    muflis,
    ak47,
    joker,
    hukam,
    lowestJoker,
    highestJoker,
    fiveCard,
  ];

  /// Whether the variation is decided by the card turned up from the deck.
  static bool usesTurnUp(String? v) => v == joker || v == hukam;
}

/// How a variation window closed.
class VariationSelectedBy {
  static const player = 'PLAYER';

  /// The ten seconds ran out and the server chose Muflis.
  static const timeout = 'TIMEOUT';

  /// The chooser left the table and the server chose Muflis.
  static const left = 'LEFT';
}

class GameAction {
  static const see = 'see';
  static const chaal = 'chaal';
  static const raise = 'raise';
  static const pack = 'pack';
  static const show = 'show';
  static const sideshow = 'sideshow';

  /// A sideshow nobody is asked to accept (owner, 13 Sep 2026). It costs one
  /// hammer, compares at once, and the server answers in the ack with the
  /// hammers left — see `GameConnection.forceSideshow`.
  static const forceSideshow = 'forceSideshow';

  /// Every player still in the hand shows, and the best hand takes the pot
  /// (owner, 14 Sep 2026). Costs one missile and no chips; the ack carries
  /// the missiles left — see `GameConnection.fireMissile`.
  static const missile = 'missile';
}

/// How many hammers a Force Sideshow spends. The server charges it; the client
/// only needs the figure to grey the key and to write the price on it.
const forceSideshowCost = 1;

/// How many missiles firing one spends. The server charges it.
const missileCost = 1;

class Rewards {
  const Rewards({
    required this.milestoneAvailable,
    required this.milestoneReward,
    required this.handsToNextMilestone,
    required this.bonusReward,
    required this.bonusReadyAt,
    required this.bonusAvailable,
    this.dailyReward = 0,
    this.dailyHammers = 0,
    this.dailyReadyAt = 0,
    this.dailyAvailable = false,
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

  /// The daily bonus beside it (owner, 14 Sep 2026): [dailyReward] chips and
  /// [dailyHammers] hammers every 24 hours, collected through
  /// `POST /api/rewards/daily`. A server that sends none of it offers none.
  final int dailyReward;
  final int dailyHammers;

  /// Epoch ms the daily bonus unlocks; 0 means it is ready now.
  final int dailyReadyAt;
  final bool dailyAvailable;

  bool get bonusReady =>
      bonusAvailable || bonusReadyAt <= DateTime.now().millisecondsSinceEpoch;

  Duration get untilBonus {
    final ms = bonusReadyAt - DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  /// Whether the server offers a daily bonus at all (one that predates it
  /// sends no reward), and whether it can be collected now.
  bool get hasDaily => dailyReward > 0;
  bool get dailyReady =>
      dailyAvailable || dailyReadyAt <= DateTime.now().millisecondsSinceEpoch;

  Duration get untilDaily {
    final ms = dailyReadyAt - DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  factory Rewards.fromJson(Map<String, dynamic> j) => Rewards(
    milestoneAvailable: j['milestoneAvailable'] == true,
    milestoneReward: _int(j['milestoneReward']),
    handsToNextMilestone: _int(j['handsToNextMilestone']),
    bonusReward: _int(j['bonusReward']),
    bonusReadyAt: _int(j['bonusReadyAt']),
    bonusAvailable: j['bonusAvailable'] == true,
    dailyReward: _int(j['dailyReward']),
    dailyHammers: _int(j['dailyHammers']),
    dailyReadyAt: _int(j['dailyReadyAt']),
    dailyAvailable: j['dailyAvailable'] == true,
  );
}

class User {
  const User({
    required this.id,
    required this.provider,
    required this.displayName,
    required this.chips,
    required this.diamond,
    this.hammer = 0,
    this.missile = 0,
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

  /// Premium soft currency. Every account starts with 1; spends on
  /// DIAMOND-priced catalogue rows.
  final int diamond;

  /// What a Force Sideshow is paid in (owner, 13 Sep 2026). Every account,
  /// new or old, starts with 20; more come in packs from the store. The
  /// server is the authority on the count — this only greys the key at 0.
  /// An older server sends no `hammer`, which reads as 0.
  final int hammer;

  /// What firing a missile is paid in (owner, 14 Sep 2026): 1 diamond trades
  /// for 2 in the store, and a new account starts with 1. The server's count
  /// is the one spent; an older server sends no `missile`, which reads as 0.
  final int missile;

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

  /// The same account with a new hammer count — what a Force Sideshow's ack
  /// reports, applied without waiting for the next `/api/auth/me`.
  User withHammer(int hammer) => User(
    id: id,
    provider: provider,
    displayName: displayName,
    chips: chips,
    diamond: diamond,
    hammer: hammer < 0 ? 0 : hammer,
    missile: missile,
    avatarUrl: avatarUrl,
    providerAvatarUrl: providerAvatarUrl,
    activePictureId: activePictureId,
    handsPlayed: handsPlayed,
    handsWon: handsWon,
    handsLost: handsLost,
    handsLeftMid: handsLeftMid,
    totalWinnings: totalWinnings,
    biggestPot: biggestPot,
    rewards: rewards,
  );

  /// The same account with a new missile count — what firing one reports in
  /// its ack, applied without waiting for the next `/api/auth/me`.
  User withMissile(int missile) => User(
    id: id,
    provider: provider,
    displayName: displayName,
    chips: chips,
    diamond: diamond,
    hammer: hammer,
    missile: missile < 0 ? 0 : missile,
    avatarUrl: avatarUrl,
    providerAvatarUrl: providerAvatarUrl,
    activePictureId: activePictureId,
    handsPlayed: handsPlayed,
    handsWon: handsWon,
    handsLost: handsLost,
    handsLeftMid: handsLeftMid,
    totalWinnings: totalWinnings,
    biggestPot: biggestPot,
    rewards: rewards,
  );

  factory User.fromJson(Map<String, dynamic> j) => User(
    id: _str(j['id']),
    provider: _str(j['provider']),
    displayName: _str(j['displayName']),
    chips: _int(j['chips']),
    diamond: _int(j['diamond']),
    hammer: _int(j['hammer']),
    missile: _int(j['missile']),
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
    this.game = '',
    this.smallBlind = 0,
    this.bigBlind = 0,
    this.ante = 0,
    this.minBuyIn = 0,
    this.holeCards = 0,
    this.maxDiscards = 0,
  });

  final String category;
  final int bootAmount;

  /// `"poker"` on a poker table's entry, empty on a Teen Patti one (the server
  /// sends nothing there). [isPoker] is the question to ask.
  final String game;

  /// A poker table's blinds (Hold'em, Omaha; the big blind is [bootAmount])
  /// or its ante (5-Card Draw, 3-Card Poker; the ante is [bootAmount]). Zero
  /// where the game has none, and on every Teen Patti table.
  final int smallBlind;
  final int bigBlind;
  final int ante;

  /// The smallest stack that may sit at a poker table. The server has already
  /// raised [minChips] to it, so the door and the card agree; this is the
  /// figure the card names as the buy-in.
  final int minBuyIn;

  /// How many cards each poker player is dealt: 2 (Hold'em), 4 (Omaha),
  /// 5 (5-Card Draw) or 3 (3-Card Poker). 0 on a Teen Patti table.
  final int holeCards;

  /// 5-Card Draw only: how many cards a player may exchange. 0 elsewhere.
  final int maxDiscards;

  /// Whether this is a poker table: the server says so with `game`, and a
  /// poker category says the same without it.
  bool get isPoker => game == 'poker' || TableCategory.isPoker(category);

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
      (minChips <= 0 || chips >= minChips) &&
      (maxChips <= 0 || chips <= maxChips);

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
    game: _str(j['game']),
    smallBlind: _int(j['smallBlind']),
    bigBlind: _int(j['bigBlind']),
    ante: _int(j['ante']),
    minBuyIn: _int(j['minBuyIn']),
    holeCards: _int(j['holeCards']),
    maxDiscards: _int(j['maxDiscards']),
  );

  /// The menu entry a poker ROOM would have had, read off the room's own
  /// snapshot.
  ///
  /// The rules sheet is written against a [LobbyTable] and a player sitting at
  /// a table has a [RoomState] instead — but `room:state.poker` carries every
  /// term the menu entry did (the blinds, the ante, the buy-in, the cards
  /// dealt, the exchange limit), so the sheet can be opened on the table being
  /// played without a second copy of the rules text. Null for a Teen Patti
  /// room, which has its own sheet.
  static LobbyTable? ofRoom(RoomState room) {
    final p = room.poker;
    if (p == null || !room.isPoker) return null;
    return LobbyTable(
      category: p.variant.isNotEmpty ? p.variant : room.category,
      bootAmount: room.bootAmount,
      maxPot: 0, // a poker room has no pot limit (§6.5)
      maxBlindMoves: 0,
      game: 'poker',
      smallBlind: p.smallBlind,
      bigBlind: p.bigBlind,
      ante: p.ante,
      minBuyIn: p.minBuyIn,
      holeCards: p.holeCards,
      maxDiscards: p.maxDiscards,
    );
  }
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
        maxBlindMoves: 4,
      ),
      LobbyTable(
        category: TableCategory.blind,
        bootAmount: 200,
        maxPot: 0,
        maxBlindMoves: 4,
      ),
      LobbyTable(
        category: TableCategory.blind,
        bootAmount: 5000,
        maxPot: 0,
        maxBlindMoves: 4,
      ),
    ],
  );

  factory GameConfig.fromJson(Map<String, dynamic> j) => GameConfig(
    maxPlayers: _int(j['maxPlayers']),
    minPlayers: _int(j['minPlayers']),
    bootAmount: _int(j['bootAmount']),
    turnTimeoutMs: _int(j['turnTimeoutMs']),
    sideshowTimeoutMs: j['sideshowTimeoutMs'] == null
        ? 6000
        : _int(j['sideshowTimeoutMs']),
    minClientBuild: _int(j['minClientBuild']),
    categories:
        (j['categories'] as List?)?.map((e) => '$e').toList() ??
        const [TableCategory.seen, TableCategory.blind],
    stakes: (j['stakes'] as List?)?.map(_int).toList() ?? const [200, 5000],
    tables:
        (j['tables'] as List?)
            ?.map(
              (e) => LobbyTable.fromJson(Map<String, dynamic>.from(e as Map)),
            )
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
    this.picking = false,
    this.streetBet = 0,
    this.allIn = false,
    this.dealer = false,
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

  /// 5-Card Teen Patti: this player is still choosing which three of their
  /// five cards play (owner, 19 Sep 2026). Public so the table can say who it
  /// is waiting on; WHICH cards they are choosing is never public.
  final bool picking;

  /// A poker seat: what it has put in on the CURRENT street, whether its
  /// whole stack is in, and whether it holds the dealer button. A Teen Patti
  /// snapshot sends none of these, and they read 0 / false there.
  final int streetBet;
  final bool allIn;
  final bool dealer;

  bool get occupied => status != SeatState.empty;
  bool get inHand => status == SeatState.active;

  /// The same seat drawn with another status. For the table only, which holds
  /// a Force Sideshow's fold back until the hammer has landed; nothing sent to
  /// the server is ever built from one.
  Seat withStatus(String status) => Seat(
    seatIndex: seatIndex,
    userId: userId,
    displayName: displayName,
    avatarUrl: avatarUrl,
    chips: chips,
    status: status,
    isBlind: isBlind,
    lastBet: lastBet,
    lastAction: lastAction,
    contributed: contributed,
    connected: connected,
    cardCount: cardCount,
    picking: picking,
    streetBet: streetBet,
    allIn: allIn,
    dealer: dealer,
  );

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
    picking: j['picking'] == true,
    streetBet: _int(j['streetBet']),
    allIn: j['allIn'] == true,
    dealer: j['dealer'] == true,
  );
}

/// What a poker player may do on their turn: `you.options` at a poker table.
///
/// The booleans say which moves the server will accept; the amounts are what
/// it accepts them at. [minBet]/[maxBet] and [minRaise]/[maxRaise] are TOTAL
/// street bets — a raise is "raise TO", never "raise BY". The client never
/// computes a legal amount of its own: the stepper walks between the server's
/// two ends, and its top end IS the whole stack, which is why there is no
/// separate all-in move (owner, 19 Sep 2026).
class PokerOptions {
  const PokerOptions({
    required this.street,
    required this.fold,
    required this.check,
    required this.call,
    required this.callAmount,
    required this.bet,
    required this.minBet,
    required this.maxBet,
    required this.raise,
    required this.minRaise,
    required this.maxRaise,
    required this.play,
    required this.playAmount,
    required this.draw,
    required this.maxDiscards,
  });

  final String street;
  final bool fold;
  final bool check;
  final bool call;
  final int callAmount;
  final bool bet;
  final int minBet;
  final int maxBet;
  final bool raise;
  final int minRaise;
  final int maxRaise;

  /// 3-Card Poker's decision: match the ante and play, or fold.
  final bool play;
  final int playAmount;

  /// 5-Card Draw's draw street: exchange up to [maxDiscards] cards.
  final bool draw;
  final int maxDiscards;

  /// Whether the map is a poker player's options at all: a Teen Patti ladder
  /// has no street and none of the fold / check / call keys.
  static bool isPokerMap(Map<String, dynamic> j) =>
      j.containsKey('street') ||
      j.containsKey('fold') ||
      j.containsKey('check') ||
      j.containsKey('call');

  factory PokerOptions.fromJson(Map<String, dynamic> j) => PokerOptions(
    street: _str(j['street']),
    fold: j['fold'] == true,
    check: j['check'] == true,
    call: j['call'] == true,
    callAmount: _int(j['callAmount']),
    bet: j['bet'] == true,
    minBet: _int(j['minBet']),
    maxBet: _int(j['maxBet']),
    raise: j['raise'] == true,
    minRaise: _int(j['minRaise']),
    maxRaise: _int(j['maxRaise']),
    play: j['play'] == true,
    playAmount: _int(j['playAmount']),
    draw: j['draw'] == true,
    maxDiscards: _int(j['maxDiscards']),
  );
}

/// One pot on a poker table — the main pot, or a side pot a short stack could
/// not reach — and who may win it. In a finished hand's [PokerResult] it also
/// says who did.
class PokerPot {
  const PokerPot({
    required this.amount,
    required this.eligible,
    this.winners = const [],
  });

  final int amount;

  /// The seat indexes still in for this pot.
  final List<int> eligible;

  /// Who took it, once the hand is decided; empty while it is being played.
  final List<PokerPotWinner> winners;

  factory PokerPot.fromJson(Map<String, dynamic> j) => PokerPot(
    amount: _int(j['amount']),
    eligible: _ints(j['eligible']),
    winners: _list(j['winners'], PokerPotWinner.fromJson),
  );
}

/// One winner of one pot, and their share of it.
class PokerPotWinner {
  const PokerPotWinner({
    required this.userId,
    required this.seatIndex,
    required this.amount,
    required this.handName,
  });

  final String userId;
  final int seatIndex;
  final int amount;

  /// What they won with; empty when the hand never reached a showdown.
  final String handName;

  factory PokerPotWinner.fromJson(Map<String, dynamic> j) => PokerPotWinner(
    userId: _str(j['userId']),
    seatIndex: _int(j['seatIndex']),
    amount: _int(j['amount']),
    handName: _str(j['handName']),
  );
}

/// 3-Card Poker's dealer: a house hand every player plays against. Face down
/// ([cards] empty, [cardCount] backs) until the reveal.
class PokerDealer {
  const PokerDealer({
    required this.cardCount,
    required this.cards,
    required this.handName,
    required this.category,
    required this.qualified,
  });

  final int cardCount;
  final List<String> cards;
  final String handName;
  final int category;

  /// Whether the dealer's hand reaches Queen-high, which is what it needs to
  /// play; null until the reveal says.
  final bool? qualified;

  factory PokerDealer.fromJson(Map<String, dynamic> j) => PokerDealer(
    cardCount: _int(j['cardCount']),
    cards: cardCodes(j['cards']),
    handName: _str(j['handName']),
    category: _int(j['category']),
    qualified: j['qualified'] is bool ? j['qualified'] as bool : null,
  );

  /// The dealer's hand to draw, from the **two** places the wire puts it.
  ///
  /// While the hand runs it is `poker.dealer` ([live]): the card count before
  /// the reveal, the cards and the verdict at it. The moment the hand is
  /// SETTLED the server empties that block — `internal/poker/view.go` takes
  /// the `else if v.HasDealer` branch and sends `{cardCount: 0, cards: []}` —
  /// and the revealed dealer lives only in `poker.result.dealer`
  /// ([finished]), which is kept until the next deal. Neither is right at
  /// every instant, so this takes the cards and the verdict from whichever
  /// holds them and the count from whichever knows it. Null only when the
  /// game has no dealer at all.
  static PokerDealer? shown({PokerDealer? live, PokerDealer? finished}) {
    if (live == null) return finished;
    if (finished == null) return live;
    final held = finished.cards.isNotEmpty ? finished : live;
    final named = finished.handName.isNotEmpty || finished.qualified != null
        ? finished
        : live;
    return PokerDealer(
      cardCount: math.max(
        math.max(live.cardCount, finished.cardCount),
        held.cards.length,
      ),
      cards: held.cards,
      handName: named.handName,
      category: named.category,
      qualified: named.qualified,
    );
  }
}

/// One hand turned over at a poker showdown.
class PokerReveal {
  const PokerReveal({
    required this.userId,
    required this.seatIndex,
    required this.cards,
    required this.best,
    required this.handName,
    required this.category,
    required this.won,
    required this.outcome,
  });

  final String userId;
  final int seatIndex;

  /// The hole cards.
  final List<String> cards;

  /// The cards that made the hand — hole cards and board cards together on a
  /// board game, the best three of five in 5-Card Draw.
  final List<String> best;
  final String handName;
  final int category;

  /// What this player took from the pots; 0 for a loser.
  final int won;

  /// 3-Card Poker: `win`, `lose` or `push` against the dealer. Null on the
  /// other games, where the pots say it.
  final String? outcome;

  factory PokerReveal.fromJson(Map<String, dynamic> j) => PokerReveal(
    userId: _str(j['userId']),
    seatIndex: _int(j['seatIndex']),
    cards: cardCodes(j['cards']),
    best: cardCodes(j['best']),
    handName: _str(j['handName']),
    category: _int(j['category']),
    won: _int(j['won']),
    outcome: j['outcome'] is String ? j['outcome'] as String : null,
  );
}

/// A poker player's outcome against the dealer (3-Card Poker).
class PokerOutcome {
  static const win = 'win';
  static const lose = 'lose';
  static const push = 'push';
}

/// How a poker hand ended: `poker.result`, and the body of `poker:showdown`
/// and `poker:handEnded`. The snapshot keeps it until the next deal, so a
/// player who reconnects into the celebration can draw the finished hand.
class PokerResult {
  const PokerResult({
    required this.handId,
    required this.reason,
    required this.pots,
    required this.reveals,
    required this.community,
    required this.dealer,
  });

  final String handId;

  /// `showdown`, `last_standing`, `dealer` or `all_left`.
  final String reason;
  final List<PokerPot> pots;
  final List<PokerReveal> reveals;
  final List<String> community;
  final PokerDealer? dealer;

  /// Every winner across every pot, each once, in pot order.
  List<PokerPotWinner> get winners {
    final seen = <String>{};
    return [
      for (final pot in pots)
        for (final w in pot.winners)
          if (seen.add(w.userId)) w,
    ];
  }

  /// What [userId] took across every pot.
  int wonBy(String? userId) {
    if (userId == null) return 0;
    var total = 0;
    for (final pot in pots) {
      for (final w in pot.winners) {
        if (w.userId == userId) total += w.amount;
      }
    }
    return total;
  }

  /// This player's reveal, if their hand was turned over.
  PokerReveal? revealOf(String? userId) =>
      userId == null ? null : reveals.where((r) => r.userId == userId).firstOrNull;

  factory PokerResult.fromJson(Map<String, dynamic> j) => PokerResult(
    handId: _str(j['handId']),
    reason: _str(j['reason']),
    pots: _list(j['pots'], PokerPot.fromJson),
    reveals: _list(j['reveals'], PokerReveal.fromJson),
    community: cardCodes(j['community']),
    dealer: j['dealer'] is Map
        ? PokerDealer.fromJson(Map<String, dynamic>.from(j['dealer'] as Map))
        : null,
  );
}

/// A poker room's own block of the snapshot: `room:state.poker`. Absent on
/// every Teen Patti table, so [RoomState.poker] is null there and nothing
/// about those tables changes.
class PokerState {
  const PokerState({
    required this.variant,
    required this.street,
    required this.community,
    required this.pots,
    required this.currentBet,
    required this.minRaise,
    required this.smallBlind,
    required this.bigBlind,
    required this.ante,
    required this.holeCards,
    required this.maxDiscards,
    required this.minBuyIn,
    required this.dealer,
    required this.result,
  });

  /// The game, the same string as the room's category ([PokerVariant]).
  final String variant;

  /// A [PokerStreet]; empty between hands.
  final String street;

  /// The board, in the order dealt. Empty when there is none yet, and on the
  /// games that have none.
  final List<String> community;

  /// The main pot first, then any side pots.
  final List<PokerPot> pots;

  /// The bet to match on this street, and the least a raise may add to it.
  final int currentBet;
  final int minRaise;
  final int smallBlind;
  final int bigBlind;
  final int ante;
  final int holeCards;
  final int maxDiscards;
  final int minBuyIn;

  /// 3-Card Poker's house hand; null on the other games.
  final PokerDealer? dealer;

  /// The finished hand, kept until the next deal; null while one is played.
  final PokerResult? result;

  /// Everything in the pots.
  int get potTotal => pots.fold(0, (sum, pot) => sum + pot.amount);

  bool get usesBlinds => PokerVariant.usesBlinds(variant);
  bool get hasBoard => PokerVariant.hasBoard(variant);

  factory PokerState.fromJson(Map<String, dynamic> j) => PokerState(
    variant: _str(j['variant']),
    street: _str(j['street']),
    community: cardCodes(j['community']),
    pots: _list(j['pots'], PokerPot.fromJson),
    currentBet: _int(j['currentBet']),
    minRaise: _int(j['minRaise']),
    smallBlind: _int(j['smallBlind']),
    bigBlind: _int(j['bigBlind']),
    ante: _int(j['ante']),
    holeCards: _int(j['holeCards']),
    maxDiscards: _int(j['maxDiscards']),
    minBuyIn: _int(j['minBuyIn']),
    dealer: j['dealer'] is Map
        ? PokerDealer.fromJson(Map<String, dynamic>.from(j['dealer'] as Map))
        : null,
    result: j['result'] is Map
        ? PokerResult.fromJson(Map<String, dynamic>.from(j['result'] as Map))
        : null,
  );
}

/// A list of whole numbers off the wire; anything else reads as empty.
List<int> _ints(Object? raw) =>
    raw is List ? [for (final e in raw) if (e is num) e.toInt()] : const [];

/// A list of objects off the wire, each parsed by [parse]; anything that is
/// not an object is dropped, and anything that is not a list is empty.
List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) parse) =>
    raw is List
    ? [
        for (final e in raw)
          if (e is Map) parse(Map<String, dynamic>.from(e)),
      ]
    : const [];

class TurnOptions {
  const TurnOptions({
    required this.canSee,
    required this.canPack,
    required this.canSideshow,
    this.canForceSideshow = false,
    this.canMissile = false,
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

  /// Whether a Force Sideshow would be allowed by the rules right now. Its
  /// own key rather than read off [canSideshow], though the server sends the
  /// two equal today: the rules are the same, and one ask per turn covers
  /// both. It says nothing about hammers — the table never holds the wallet,
  /// so the key is greyed from the viewer's own [User.hammer]. An older
  /// server sends nothing, which reads as false and keeps the key dark.
  final bool canForceSideshow;

  /// A copy of [You.canMissile], read only when the server puts it among the
  /// options rather than on `you` itself. Absent reads as false.
  final bool canMissile;

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
    canForceSideshow: j['canForceSideshow'] == true,
    canMissile: j['canMissile'] == true,
    sideshowWith: j['sideshowWith'] as String?,
    raiseSteps: (j['raiseSteps'] as List?)?.map(_int).toList() ?? const <int>[],
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

/// A variation table's window, and what came of it: `room:state.variation`.
///
/// Absent from the snapshot of a seen or blind table and between hands, so
/// [RoomState.variation] is null there and nothing about those tables changes.
///
/// While [selecting], nobody is on turn: the server has dealt the hand and is
/// waiting for [userId] to choose its rules, until [deadline]. That deadline is
/// the SERVER's — the countdown drawn from it is a readout, never the thing
/// that decides, exactly as a sideshow's is. Everything a client needs to draw
/// the chooser's picker, everyone else's "… is selecting variation", and both
/// countdowns is here, which is what lets a player who reconnects mid-window
/// rebuild all of it from one snapshot.
class VariationState {
  const VariationState({
    required this.selecting,
    required this.userId,
    required this.displayName,
    required this.seatIndex,
    required this.startedAt,
    required this.deadline,
    required this.timeoutMs,
    required this.options,
    required this.selected,
    required this.selectedBy,
    required this.turnUp,
    this.cardsPerPlayer = 3,
  });

  /// How many cards each player in the hand holds: 3 while the window is open
  /// and under the six older variations, 5 once [Variation.fiveCard] has been
  /// chosen — every hand is dealt three and the server tops each up to five at
  /// that moment. It is the server's figure and the only one the table draws
  /// face-down cards from; a server that predates it sends nothing, which reads
  /// as three. Held to 3..5 so a nonsense value can never draw a fan the felt
  /// has no room for.
  final int cardsPerPlayer;

  /// True while the window is open.
  final bool selecting;

  /// The CHOOSER — and still the chooser after the window has closed, however
  /// it closed.
  final String userId;
  final String displayName;
  final int seatIndex;

  /// Unix ms.
  final int startedAt;

  /// Unix ms, or 0 when the server runs the window with no timeout.
  final int deadline;
  final int timeoutMs;

  /// The menu, in the order the server offers it. Never empty: a snapshot
  /// without one falls back to [Variation.all].
  final List<String> options;

  /// Null while [selecting].
  final String? selected;

  /// A [VariationSelectedBy] value; null while [selecting].
  final String? selectedBy;

  /// The card turned up from the deck ("9h"), present only once a variation
  /// decided by it has been chosen: its rank is wild under Joker, its suit
  /// under Hukam. Until then the card is the server's alone.
  final String? turnUp;

  /// Seconds left on the window, never negative; 0 when it has no deadline.
  int get secondsLeft {
    if (!selecting || deadline <= 0) return 0;
    final ms = deadline - DateTime.now().millisecondsSinceEpoch;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  /// Whether the server chose because the player did not.
  bool get chosenByServer =>
      selectedBy == VariationSelectedBy.timeout ||
      selectedBy == VariationSelectedBy.left;

  factory VariationState.fromJson(Map<String, dynamic> j) {
    // `is List`, not `as List?`: a cast throws on a value that is present but
    // is not a list, and a snapshot that cannot be parsed takes the whole
    // table down with it. Anything unusable falls back to the full menu.
    final raw = j['options'];
    final options = raw is List
        ? raw.whereType<String>().where((e) => e.isNotEmpty).toList()
        : const <String>[];
    return VariationState(
      selecting: j['selecting'] == true,
      userId: _str(j['userId']),
      displayName: _str(j['displayName']),
      seatIndex: _int(j['seatIndex']),
      startedAt: _int(j['startedAt']),
      deadline: _int(j['deadline']),
      timeoutMs: _int(j['timeoutMs']),
      options: options.isEmpty ? Variation.all : options,
      selected: j['selected'] is String ? j['selected'] as String : null,
      selectedBy: j['selectedBy'] is String ? j['selectedBy'] as String : null,
      turnUp: j['turnUp'] is String ? j['turnUp'] as String : null,
      cardsPerPlayer: _cardsPerPlayer(j['cardsPerPlayer']),
    );
  }

  /// Absent, not a number, or out of range → the nearest sane figure. Read
  /// from the raw value rather than through `_int`, whose 0 for "absent" would
  /// be indistinguishable from a server that really said 0.
  static int _cardsPerPlayer(Object? raw) =>
      raw is num && raw.isFinite ? raw.toInt().clamp(3, 5) : 3;
}

/// One hand in a sideshow reveal. Only ever sent to the two players involved.
class SideshowHand {
  const SideshowHand({
    required this.userId,
    required this.displayName,
    required this.cards,
    required this.handName,
    this.wild = const [],
    this.best = const [],
  });

  final String userId;
  final String displayName;
  final List<String> cards;
  final String handName;

  /// Which of [cards] played as wild cards — a variation table only, and only
  /// under a variation that has any. [handName] is what the hand MADE with
  /// them, so it can differ from what the bare cards would be.
  final List<String> wild;

  /// The three of [cards] that were counted, under 5-Card only (where [cards]
  /// holds five). Empty everywhere else.
  final List<String> best;

  factory SideshowHand.fromJson(Map<String, dynamic> j) => SideshowHand(
    userId: _str(j['userId']),
    displayName: _str(j['displayName']),
    cards: (j['cards'] as List? ?? const []).map((e) => '$e').toList(),
    handName: _str(j['handName']),
    wild: (j['wild'] as List? ?? const []).map((e) => '$e').toList(),
    best: cardCodes(j['best']),
  );
}

class SideshowReveal {
  const SideshowReveal({
    required this.hands,
    required this.packedUserId,
    this.reason = SideshowReason.accepted,
  });

  /// The asker's hand first, then the asked player's.
  final List<SideshowHand> hands;
  final String? packedUserId;

  /// [SideshowReason.accepted], or [SideshowReason.forced] when the asker paid
  /// a hammer and nobody was asked.
  final String reason;

  bool get forced => reason == SideshowReason.forced;

  factory SideshowReveal.fromJson(Map<String, dynamic> j) => SideshowReveal(
    hands: (j['hands'] as List? ?? const [])
        .map((e) => SideshowHand.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    packedUserId: j['packedUserId'] as String?,
    reason: _str(j['reason']).isEmpty
        ? SideshowReason.accepted
        : _str(j['reason']),
  );
}

/// How a sideshow ended, as `game:sideshowResolved.reason` and
/// `game:sideshowReveal.reveal.reason` say it.
class SideshowReason {
  static const accepted = 'accepted';
  static const declined = 'declined';
  static const timeout = 'timeout';
  static const left = 'left';

  /// A Force Sideshow: paid for with a hammer, never asked, always compared.
  /// It arrives with `accepted: true`, so a client that predates it shows the
  /// reveal and no "declined" line.
  static const forced = 'forced';
}

class Turn {
  const Turn({
    required this.seatIndex,
    required this.userId,
    required this.deadline,
  });

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

/// `you.hand`: the viewer's own seen cards as the hand's variation counts them
/// (owner, 18 Sep 2026). The server sends it to that player alone.
///
/// [playsAs] runs index for index with `you.cards`: a wild card is replaced by
/// the card it stood for — under AK47 a J-Q-4 is a Sequence because the 4
/// played as a king — and every other card is itself. It is what the table
/// turns the wild cards into once the player has looked.
class OwnHand {
  const OwnHand({
    required this.handName,
    required this.wild,
    required this.playsAs,
    this.best = const [],
    this.picking = false,
    this.pickDeadline = 0,
    this.pickTimeoutMs = 0,
    this.pickedBy = '',
    this.bestPossible = const [],
  });

  /// The codes of the `you.cards` that are COUNTED, in the order held: all
  /// three of a three-card hand, the best three of five under 5-Card. The
  /// server chooses them; the table only lifts them. Empty from a server that
  /// predates it, which draws the hand with nothing singled out.
  final List<String> best;

  /// What the hand made, wild cards included: "Sequence". English, like every
  /// hand name on the wire.
  final String handName;

  /// Which of `you.cards` played as wild cards. Empty when none did.
  final List<String> wild;

  /// `you.cards` as they were counted.
  final List<String> playsAs;

  /// 5-Card Teen Patti: true while this player still owes a choice of which
  /// three of their five cards play (owner, 19 Sep 2026). [handName] and
  /// [best] are both empty while it is true — naming the hand would hand the
  /// player the answer — so the felt asks instead of showing.
  final bool picking;

  /// When the server plays the first three for them, epoch ms, and how long
  /// was left when the snapshot was made. Both 0 when no clock is running.
  final int pickDeadline;
  final int pickTimeoutMs;

  /// "PLAYER" when they chose and "TIMEOUT" when the clock did; empty until
  /// the choice is made.
  final String pickedBy;

  /// The strongest three those five could have made, sent only once the choice
  /// is made. Equal to [best] when they chose well, which is how the table
  /// knows whether to congratulate them or show them what they missed.
  final List<String> bestPossible;

  /// Whether the three that play are the strongest three that could have.
  /// True when nothing better was on offer, and true for a three-card hand,
  /// which plays all of itself.
  bool get pickedTheBest =>
      bestPossible.isEmpty ||
      (best.length == bestPossible.length &&
          List.generate(best.length, (i) => best[i] == bestPossible[i])
              .every((same) => same));

  /// The card [code] (one of `you.cards`, at [index]) stood for, or null when
  /// it is not wild, the server said nothing usable, or it stood for itself.
  String? standInFor(String code, int index) {
    if (!wild.contains(code) || index < 0 || index >= playsAs.length) {
      return null;
    }
    final stood = playsAs[index];
    return stood.length < 2 || stood == code ? null : stood;
  }

  /// Tolerant, like every DTO here: anything unusable reads as "nothing wild".
  factory OwnHand.fromJson(Map<String, dynamic> j) {
    return OwnHand(
      handName: _str(j['handName']),
      wild: cardCodes(j['wild']),
      playsAs: cardCodes(j['playsAs']),
      best: cardCodes(j['best']),
      picking: j['picking'] == true,
      pickDeadline: _int(j['pickDeadline']),
      pickTimeoutMs: _int(j['pickTimeoutMs']),
      pickedBy: _str(j['pickedBy']),
      bestPossible: cardCodes(j['bestPossible']),
    );
  }
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
    this.canMissile = false,
    this.hand,
    this.streetBet = 0,
    this.allIn = false,
    this.pokerOptions,
  });

  final int seatIndex;
  final int chips;
  final String status;
  final bool isBlind;

  /// A poker seat's bet on the current street, and whether the whole stack is
  /// in. 0 / false on a Teen Patti table, which sends neither.
  final int streetBet;
  final bool allIn;

  /// A poker player's moves, on their turn and only then ([PokerOptions]).
  /// The server sends one `options` map whatever the game; a map with a poker
  /// street in it is read as this and NEVER as [options], so no Teen Patti key
  /// — `canPack`, which reads true when absent — can light at a poker table.
  final PokerOptions? pokerOptions;

  /// What this player's own cards make under the hand's variation — which of
  /// them played wild and what they stood for. Only on a variation table, and
  /// only once the player has looked AND the variation is chosen; null
  /// otherwise, and always on a seen or blind table.
  final OwnHand? hand;

  /// Whether the rules allow this player to fire a missile right now — their
  /// turn, three or more still in the hand, nothing pending (owner, 14 Sep
  /// 2026). It says nothing about the wallet: the key is greyed from the
  /// viewer's own [User.missile]. An older server sends nothing, which reads
  /// as false and keeps the key dark.
  final bool canMissile;

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

  factory You.fromJson(Map<String, dynamic> j) {
    // One `options` map, two games: a poker one carries a street and is read
    // as poker options ALONE; anything else is a Teen Patti ladder.
    final rawOptions = j['options'] is Map
        ? Map<String, dynamic>.from(j['options'] as Map)
        : null;
    final pokerMap = rawOptions != null && PokerOptions.isPokerMap(rawOptions);
    return You(
      // `you.canMissile` is the contract; the same flag among the options is
      // accepted too, so either placement lights the key.
      canMissile:
          j['canMissile'] == true ||
          (rawOptions != null && rawOptions['canMissile'] == true),
      seatIndex: _int(j['seatIndex']),
      chips: _int(j['chips']),
      status: _str(j['status']),
      isBlind: j['isBlind'] == true,
      blindMovesLeft: _int(j['blindMovesLeft']),
      contributed: _int(j['contributed']),
      missedTurns: _int(j['missedTurns']),
      maxMissedTurns: j['maxMissedTurns'] == null
          ? 3
          : _int(j['maxMissedTurns']),
      cards: (j['cards'] as List?)?.map((e) => '$e').toList() ?? const [],
      options: rawOptions != null && !pokerMap
          ? TurnOptions.fromJson(rawOptions)
          : null,
      pokerOptions: pokerMap ? PokerOptions.fromJson(rawOptions) : null,
      hand: j['hand'] is Map
          ? OwnHand.fromJson(Map<String, dynamic>.from(j['hand'] as Map))
          : null,
      unfundedDeadline: j['unfundedDeadline'] == null
          ? null
          : _int(j['unfundedDeadline']),
      streetBet: _int(j['streetBet']),
      allIn: j['allIn'] == true,
    );
  }
}

class RoomState {
  const RoomState({
    required this.roomId,
    required this.code,
    this.isPrivate = false,
    this.variation,
    this.game = '',
    this.poker,
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

  /// A table reached by its code alone (requirement 22). Its code is worth
  /// showing, since it is how friends are let in; a public table's is not.
  final bool isPrivate;
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

  /// A variation table's window and its outcome; null on every other table
  /// and between hands.
  final VariationState? variation;

  /// `"poker"` on a poker room, empty on a Teen Patti one.
  final String game;

  /// A poker room's own block; null on every Teen Patti table, whose snapshot
  /// never carries one.
  final PokerState? poker;
  final You? you;
  final List<Seat> seats;

  bool get seated => you != null;

  /// Whether this is a poker room. Either mark is enough: the server sends
  /// both, and a snapshot with one and not the other is still a poker table.
  bool get isPoker => game == 'poker' || poker != null;

  factory RoomState.fromJson(Map<String, dynamic> j) => RoomState(
    roomId: _str(j['roomId']),
    code: _str(j['code']),
    isPrivate: j['isPrivate'] == true,
    game: _str(j['game']),
    poker: j['poker'] is Map
        ? PokerState.fromJson(Map<String, dynamic>.from(j['poker'] as Map))
        : null,
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
            Map<String, dynamic>.from(j['sideshow'] as Map),
          )
        : null,
    // Absent on a seen or blind table, and anything that is not an object —
    // a string, a list, null — is no window rather than a crash.
    variation: j['variation'] is Map
        ? VariationState.fromJson(
            Map<String, dynamic>.from(j['variation'] as Map),
          )
        : null,
    you: j['you'] is Map
        ? You.fromJson(Map<String, dynamic>.from(j['you'] as Map))
        : null,
    seats:
        (j['seats'] as List?)
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
    this.wild = const [],
    this.best = const [],
  });

  final String userId;
  final String displayName;
  final List<String> cards;
  final String handName;
  final bool won;

  /// Which of [cards] played as wild cards (see [SideshowHand.wild]).
  final List<String> wild;

  /// The three of [cards] that were counted — present only under 5-Card, where
  /// [cards] holds all five. Empty on every other table and variation.
  final List<String> best;

  factory Reveal.fromJson(Map<String, dynamic> j) => Reveal(
    userId: _str(j['userId']),
    displayName: _str(j['displayName']),
    cards: (j['cards'] as List?)?.map((e) => '$e').toList() ?? const [],
    handName: _str(j['handName']),
    won: j['won'] == true,
    wild: (j['wild'] as List?)?.map((e) => '$e').toList() ?? const [],
    best: cardCodes(j['best']),
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

/// The wallets a catalogue picture can be priced in (GET /api/profiles).
///
/// Hammers joined chips and diamonds on 14 Sep 2026 (owner), when the
/// animated rentals were re-priced in them. A currency this build does not
/// know is kept as the server sent it and drawn as chips, which is how every
/// row read before the soft currencies existed.
class PictureCurrency {
  static const String coin = 'COIN';
  static const String diamond = 'DIAMOND';
  static const String hammer = 'HAMMER';
}

/// One row of the server's picture catalogue (GET /api/profiles).
class ProfilePicture {
  const ProfilePicture({
    required this.id,
    required this.name,
    required this.url,
    this.assetFormat = 'IMAGE',
    this.currency = 'COIN',
    required this.type,
    required this.cost,
    required this.durationDays,
    this.durationHours = 0,
    required this.owned,
    required this.expiresAt,
  });

  final int id;

  /// What to call it in the picker — "Bear", "Wolf".
  final String name;

  /// Server-relative ("/profiles/bear.svg") or absolute.
  final String url;

  /// How the client renders what [url] serves: 'IMAGE' (jpg/jpeg/png — one
  /// loader), 'SVG', 'LOTTIE' (a Lottie JSON or .lottie zip fetched and
  /// played) or 'RIVE' (a Rive .riv binary; no Rive runtime ships in the app
  /// yet, so such a row falls back to the bundled default). Declared by the
  /// server because hosted URLs rarely carry an extension to sniff.
  final String assetFormat;

  /// Which wallet [cost] is paid from: [PictureCurrency.coin] (chips),
  /// [PictureCurrency.diamond] or [PictureCurrency.hammer]. Always 'COIN' for
  /// a free row — nothing is charged. Kept as the server sent it, so a
  /// currency this build does not know survives parsing and is drawn as chips.
  final String currency;

  /// 'FREE' or 'PREMIUM'.
  final String type;

  /// What it costs, in [currency]: chips, diamonds or hammers. Always 0 when
  /// [free].
  final int cost;

  /// How long a purchase lasts: [durationDays] days plus [durationHours] hours.
  /// Both 0 means for ever, which every free picture is and a premium one is
  /// until somebody prices it as a rental.
  final int durationDays;

  /// The hours of the term, beside [durationDays] — 1 for a picture rented for
  /// an hour (owner, 14 Sep 2026). A server that does not send it means 0.
  final int durationHours;

  /// Whether this player may wear it: every free picture, plus the premium
  /// ones they have bought. The server decides this per viewer — the client
  /// never works it out from the wallet.
  final bool owned;

  /// Epoch ms this player's rental runs out; 0 when they do not own it, or own
  /// it for ever.
  final int expiresAt;

  bool get free => type == 'FREE';

  /// Whether it moves: a Lottie or a Rive file rather than a still. The picker
  /// shelves premium pictures by this.
  bool get animated => assetFormat == 'LOTTIE' || assetFormat == 'RIVE';

  /// Whether buying this one rents it rather than keeps it.
  bool get rented => durationDays > 0 || durationHours > 0;

  /// Priced in diamonds, or in hammers. A picture that is neither — chips,
  /// or a currency this build does not know — is drawn and worded as chips.
  bool get pricedInDiamonds => currency == PictureCurrency.diamond;
  bool get pricedInHammers => currency == PictureCurrency.hammer;

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
    assetFormat: _str(j['assetFormat'] ?? 'IMAGE'),
    currency: _str(j['currency'] ?? 'COIN'),
    type: _str(j['type']).isEmpty ? 'FREE' : _str(j['type']),
    cost: _int(j['cost']),
    durationDays: _int(j['durationDays']),
    durationHours: _int(j['durationHours']),
    expiresAt: _int(j['expiresAt']),
    // Absent means the server did not say, and the safe reading of that is
    // "not owned" — a free picture is only ever sent with owned true.
    owned: j['owned'] == true,
  );
}
