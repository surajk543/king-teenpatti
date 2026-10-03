/// Wire types, mirroring exactly what the Node server sends.
///
/// The server is the authority on every rule, so nothing here decides anything
/// — these are plain readers over its JSON. Fields the server may omit or send
/// as null are nullable here for the same reason: a blind table really does
/// send `chips: null` for everyone but you, and "hidden" has to stay
/// distinguishable from "broke".
library;

import 'dart:math' as math;
import 'dart:ui' show Brightness, Rect;

import 'player_stats.dart';

int _int(dynamic v) => v is num ? v.toInt() : 0;

/// Null stays null: a picture id of 0 would be a real-looking id the server
/// never issues, so "wearing nothing" must not collapse into it.
int? _intOrNull(dynamic v) => v is num ? v.toInt() : null;
String _str(dynamic v) => v is String ? v : '';

/// A name the server may leave out: anything but a non-empty string reads as
/// null, so "not sent" never passes for a name that is merely empty.
String? _strOrNull(dynamic v) => v is String && v.isNotEmpty ? v : null;

/// A rate in basis points — the winning tax (owner, 26 Sep 2026: 20.00% is
/// 2000) — or null when it is absent, not a number, or outside 0..10000: a
/// figure no table could charge is no figure at all, never a 0% that looks
/// real.
int? _bpsOrNull(dynamic v) {
  if (v is! num) return null;
  final n = v.toInt();
  return n < 0 || n > 10000 ? null : n;
}

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

  /// Variation Teen Patti: a table that hides other players' stacks as a
  /// blind one does (owner, 18 Sep 2026), bets as one does too since 28 Sep
  /// 2026 — a public one raises as far as the chips go, with no round cap and
  /// no per-bet ceiling, where it took the seen table's two rungs and seven
  /// rounds until then — has no pot limit, and opens every hand with one
  /// player choosing the rules it is decided by ([Variation],
  /// [VariationState]).
  static const variation = 'variation';

  /// The POKER family (server side: go-server/internal/poker). Four wire
  /// categories, each a game of its own at the table and one card each in the
  /// lobby's Poker category. A poker room's snapshot carries `game: "poker"`
  /// and a `poker` block ([PokerState]); a Teen Patti room's carries neither.
  static const threeCardPoker = 'three_card_poker';
  static const fiveCardDraw = 'five_card_draw';
  static const texasHoldem = 'texas_holdem';
  static const omaha = 'omaha';

  /// The lobby's name for the poker FAMILY — the Poker engine's front card,
  /// inside which each of the four games has a card of its own
  /// ([TableEngine.poker], the same string). Never a wire category: the
  /// server knows only the four above.
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

/// The ENGINES that play the categories (owner, 23 Sep 2026: "Make this
/// category is table/db level also: Teen Patti engines / Poker engines").
///
/// The server keeps them in `table_engines`, and every category in
/// `table_categories` under exactly one of them: seen, blind and variation
/// are Teen Patti's, the four poker games Poker's. The table catalogue sends
/// the pair as [GameConfig.engines] and names each table's own engine
/// ([LobbyTable.engine]); `session:ready` sends neither.
class TableEngine {
  static const teenPatti = 'teen_patti';

  /// The same string as [TableCategory.pokerFamily], and not by chance: the
  /// lobby's front card for an engine is named by the engine's code, and the
  /// Poker card already was.
  static const poker = 'poker';
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

/// The 6-hour bonus as the account carries it — `user.rewards` (owner, 30 Sep
/// 2026: "IN Top left Add Again Every 6 hours bonus 25000 Coins": requirement
/// 18's four-hour bonus, taken away that morning with the other two lobby
/// rewards, back as six hours and 25,000 chips). The server says what it pays
/// and when it unlocks; the lobby's top-left chip counts down to it and
/// collects it (`POST /api/rewards/bonus`). Null from a server without it.
class Rewards {
  const Rewards({
    required this.bonusReward,
    required this.bonusReadyAt,
    required this.bonusAvailable,
    this.bonusIntervalMs = 0,
  });

  /// What one collection pays, in chips.
  final int bonusReward;

  /// Epoch ms the bonus unlocks; 0 means it is ready now. The server calls
  /// this `bonusReadyAt`.
  final int bonusReadyAt;

  /// The server's own verdict, which is what actually gates the claim.
  final bool bonusAvailable;

  /// How long the bonus takes to recharge, in ms (six hours); 0 from a server
  /// that does not say.
  final int bonusIntervalMs;

  bool get bonusReady =>
      bonusAvailable || bonusReadyAt <= DateTime.now().millisecondsSinceEpoch;

  Duration get untilBonus {
    final ms = bonusReadyAt - DateTime.now().millisecondsSinceEpoch;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  /// The recharge as hours, for the words ("A new bonus every 6 hours."); 6
  /// where the server did not say.
  int get bonusEveryHours =>
      bonusIntervalMs > 0 ? (bonusIntervalMs / 3600000).round() : 6;

  factory Rewards.fromJson(Map<String, dynamic> j) => Rewards(
    bonusReward: _int(j['bonusReward']),
    bonusReadyAt: _int(j['bonusReadyAt']),
    bonusAvailable: j['bonusAvailable'] == true,
    bonusIntervalMs: _int(j['bonusIntervalMs']),
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
    this.tablePicture,
    this.cardBackground,
    required this.handsPlayed,
    required this.handsWon,
    required this.handsLost,
    required this.handsLeftMid,
    required this.totalWinnings,
    required this.biggestPot,
    this.totalTaxPaid = 0,
    this.stats = const StatsByCategory(),
    this.playerLevel,
    this.badges = const [],
    this.taxBps,
    this.rewards,
  });

  final String id;
  final String provider;
  final String displayName;
  final int chips;

  /// The 6-hour bonus as it stands for this player ([Rewards]); null from a
  /// server that offers none, and then the lobby draws no bonus chip.
  final Rewards? rewards;

  /// The player's level, their XP and the winning tax the level sets (owner,
  /// 26 Sep 2026) — this viewer's own and nobody else's: the server never
  /// sends another player's level. Null from a server that predates the
  /// levels.
  final PlayerLevel? playerLevel;

  /// The badges the player holds (owner, 27 Sep 2026: "Vip is not a level, it
  /// is badge, User can hold multiple badges"): Standard, which everyone
  /// holds, and any given to them — each until its grant runs out. Empty from
  /// a server that predates badges.
  final List<PlayerBadge> badges;

  /// The winning tax the player pays, in basis points: the lowest of their
  /// level's and their badges' (owner, 27 Sep 2026: "the tax will be applied
  /// acc to minimum of badge or player level"), as the server worked it out.
  /// Null from a server that does not say — then the level's is what they pay
  /// ([paysTaxBps]).
  final int? taxBps;

  /// The winning tax this player pays: the server's figure, else their
  /// level's; null where neither is known.
  int? get paysTaxBps => taxBps ?? playerLevel?.taxBps;

  /// The badge the table's pill names (owner, 27 Sep 2026: "In table top also
  /// the badge name current player holding"): of the badges the player holds,
  /// the one that brings their rate lowest — a Royal badge's holder's Royal
  /// badge, everybody else's Regular — the first of them in the server's
  /// order on a tie, and the
  /// first held where none carries a rate. Null where they hold none (a server
  /// that predates badges).
  PlayerBadge? get shownBadge {
    PlayerBadge? best;
    for (final b in badges) {
      final rate = b.taxBps;
      if (rate == null) continue;
      if (best == null || rate < best.taxBps!) best = b;
    }
    return best ?? (badges.isEmpty ? null : badges.first);
  }

  /// The badge that sets the rate the player pays — the held badge with the
  /// lowest rate, when that rate is BELOW the level's (so the badge is why
  /// they pay less) — or null when the level's rate is what they pay.
  PlayerBadge? get rateBadge {
    final level = playerLevel?.taxBps;
    PlayerBadge? best;
    for (final b in badges) {
      final rate = b.taxBps;
      if (rate == null) continue;
      if (best == null || rate < best.taxBps!) best = b;
    }
    if (best == null) return null;
    if (level != null && best.taxBps! >= level) return null;
    return best;
  }

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

  /// The table picture laid on this player's table (owner, 15 Sep 2026), or
  /// null for the table as it comes. Resolved by the server with both URLs,
  /// so the felt is drawn from the account alone — before the catalogue is
  /// down, and for a row since retired from it. An older server sends none.
  final LaidTablePicture? tablePicture;

  /// Which [TablePicture] is laid, or null: what the store's Tables tab ticks.
  int? get activeTablePictureId => tablePicture?.id;

  /// The card back this player has chosen (owner, 3 Oct 2026: "Add a table
  /// cards_background which users can buy just like user can buy
  /// profile_pictures"), or null for the bundled Royal Fox
  /// (`PlayingCard.backAsset`), which is everybody's and nobody's row. The
  /// server joins it only while its rental runs, so a lapsed one reads as
  /// none the moment it lapses. An older server sends none.
  final CardBackArt? cardBackground;

  /// Which [CardBackground] is chosen, or null: what the store's Cards tab
  /// ticks — "In use" on the Royal Fox tile when null.
  int? get activeCardBackgroundId => cardBackground?.id;
  final int handsPlayed;
  final int handsWon;
  final int handsLost;
  final int handsLeftMid;
  final int totalWinnings;
  final int biggestPot;

  /// The winning tax the player has paid in every game together (2 Oct 2026;
  /// the server's `totalTaxPaid`): their own figure, which no other player's
  /// profile carries. 0 from a server that does not count it yet.
  final int totalTaxPaid;

  /// The record game by game (player stats v2, owner, 27 Sep 2026): Teen
  /// Patti, Variation and Poker, each with its figures — the two chip figures
  /// included, this being the player's own account — Teen Patti's and
  /// Variation's hands held, and the variations played. The six figures above
  /// are the totals of the three.
  final StatsByCategory stats;

  /// The totals above as one record — every game together, the Stats
  /// drawer's "All". The account carries no win rate for them, and the
  /// player's own record shows none.
  CategoryStats get totals => CategoryStats(
    handsPlayed: handsPlayed,
    handsWon: handsWon,
    handsLost: handsLost,
    handsLeft: handsLeftMid,
    totalWinnings: totalWinnings,
    biggestPot: biggestPot,
    totalTaxPaid: totalTaxPaid,
  );

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
    tablePicture: tablePicture,
    cardBackground: cardBackground,
    handsPlayed: handsPlayed,
    handsWon: handsWon,
    handsLost: handsLost,
    handsLeftMid: handsLeftMid,
    totalWinnings: totalWinnings,
    biggestPot: biggestPot,
    totalTaxPaid: totalTaxPaid,
    stats: stats,
    playerLevel: playerLevel,
    badges: badges,
    taxBps: taxBps,
    rewards: rewards,
  );

  /// The same account at a new standing — what `player:level` reports after
  /// an XP award (level, badges and the rate paid), applied without waiting
  /// for the next `/api/auth/me`.
  User withStanding(Standing standing) => User(
    id: id,
    provider: provider,
    displayName: displayName,
    chips: chips,
    diamond: diamond,
    hammer: hammer,
    missile: missile,
    avatarUrl: avatarUrl,
    providerAvatarUrl: providerAvatarUrl,
    activePictureId: activePictureId,
    tablePicture: tablePicture,
    cardBackground: cardBackground,
    handsPlayed: handsPlayed,
    handsWon: handsWon,
    handsLost: handsLost,
    handsLeftMid: handsLeftMid,
    totalWinnings: totalWinnings,
    biggestPot: biggestPot,
    totalTaxPaid: totalTaxPaid,
    stats: stats,
    playerLevel: standing.playerLevel,
    badges: standing.badges,
    taxBps: standing.taxBps,
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
    tablePicture: tablePicture,
    cardBackground: cardBackground,
    handsPlayed: handsPlayed,
    handsWon: handsWon,
    handsLost: handsLost,
    handsLeftMid: handsLeftMid,
    totalWinnings: totalWinnings,
    biggestPot: biggestPot,
    totalTaxPaid: totalTaxPaid,
    stats: stats,
    playerLevel: playerLevel,
    badges: badges,
    taxBps: taxBps,
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
    tablePicture: j['tablePicture'] is Map
        ? LaidTablePicture.fromJson(
            Map<String, dynamic>.from(j['tablePicture'] as Map),
          )
        : null,
    cardBackground: CardBackArt.fromJson(j['cardBackground']),
    handsPlayed: _int(j['handsPlayed']),
    handsWon: _int(j['handsWon']),
    handsLost: _int(j['handsLost']),
    handsLeftMid: _int(j['handsLeftMid']),
    totalWinnings: _int(j['totalWinnings']),
    biggestPot: _int(j['biggestPot']),
    totalTaxPaid: _int(j['totalTaxPaid']),
    stats: j['stats'] is Map
        ? StatsByCategory.fromJson(Map<String, dynamic>.from(j['stats'] as Map))
        : const StatsByCategory(),
    playerLevel: PlayerLevel.maybe(j['playerLevel']),
    badges: PlayerBadge.listOf(j['badges']),
    taxBps: _bpsOrNull(j['taxBps']),
    rewards: j['rewards'] is Map
        ? Rewards.fromJson(Map<String, dynamic>.from(j['rewards'] as Map))
        : null,
  );
}

/// One rung of the level ladder above the player's own — the next level they
/// can reach by XP (owner, 26 Sep 2026): its number, name and mark, the XP
/// that reaches it and the winning tax it sets.
class LevelStep {
  const LevelStep({
    required this.level,
    required this.title,
    required this.minXp,
    required this.taxBps,
    this.icon = '',
    this.assetUrl = '',
    this.assetFormat = '',
  });

  final int level;

  /// The server's name for the level ("Pro Player"). English, as the owner
  /// wrote the ladder: a title, like a hand's name, is never translated.
  final String title;

  /// The level's mark: one or two emoji ("🏅", "👑⚔️") the phone draws from
  /// its colour emoji font, before the title. Empty when the server sent
  /// none, and the title stands alone.
  final String icon;

  /// The level's art (owner, 29 Sep 2026: "Instead of using icons use lottie
  /// animations json for showing player Level"): the owner's Lottie at
  /// [assetUrl], which the app draws wherever it showed [icon] (LevelArt).
  /// Empty while the owner has not given one, and the app shows an empty
  /// mark.
  final String assetUrl;
  final String assetFormat;

  /// Whether [assetUrl] is art the app can draw: a Lottie.
  bool get hasArt => assetUrl.isNotEmpty && assetFormat == 'LOTTIE';

  /// The XP that reaches it.
  final int minXp;

  /// The winning tax at that level, in basis points (1714 is 17.14%).
  final int taxBps;

  /// Null unless the server sent a level worth showing: a level number above
  /// 0 and a rate in 0..10000.
  static LevelStep? maybe(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final level = _int(j['level']);
    final bps = _bpsOrNull(j['taxBps']);
    if (level <= 0 || bps == null) return null;
    return LevelStep(
      level: level,
      title: _str(j['title']),
      icon: _str(j['icon']).trim(),
      assetUrl: _str(j['assetUrl']).trim(),
      assetFormat: _str(j['assetFormat']).trim().toUpperCase(),
      minXp: _int(j['minXp']),
      taxBps: bps,
    );
  }
}

/// Today's XP (owner, 26 Sep 2026: "daily xp cap limit is 50XP for each
/// user … reset after 24 hours"): what the player's current 24-hour window
/// has earned, the most it may earn, and when it ends — epoch ms, 0 while no
/// window is running (the next completed hand opens one). The server counts
/// it; the app only shows it.
class XpToday {
  const XpToday({required this.xp, required this.cap, this.resetsAt = 0});

  final int xp;
  final int cap;
  final int resetsAt;

  /// Whether the day's XP is all earned: nothing more comes until it resets.
  bool get full => cap > 0 && xp >= cap;

  /// How long until the window ends, or null when none is running or it has
  /// already ended by [now].
  Duration? leftAt(DateTime now) {
    if (resetsAt <= 0) return null;
    final ms = resetsAt - now.millisecondsSinceEpoch;
    return ms <= 0 ? null : Duration(milliseconds: ms);
  }

  /// Null unless the server sent a window worth showing: a cap above 0.
  static XpToday? maybe(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final cap = _int(j['cap']);
    if (cap <= 0) return null;
    return XpToday(
      xp: math.max(0, _int(j['xp'])),
      cap: cap,
      resetsAt: math.max(0, _int(j['resetsAt'])),
    );
  }
}

/// What the player has earned of the daily XP in their current window (owner,
/// 27 Sep 2026: "Daily XP user can get … After 24 hours this will be reset, so
/// user can claim this again"): how many times each source — by its code —
/// and when the window resets, epoch ms. The server counts it; the app only
/// shows it. Absent (null on [PlayerLevel.daily]) while no window is running,
/// when every source is there to be earned.
class XpDaily {
  const XpDaily({this.claimed = const {}, this.resetsAt = 0});

  /// Times earned in the window, by source code; a source not in it has not
  /// been earned.
  final Map<String, int> claimed;
  final int resetsAt;

  /// How many times [code] has been earned in the window.
  int claimsOf(String code) => claimed[code] ?? 0;

  /// How long until the window ends, or null when it already has by [now] —
  /// and then everything is there to be earned again.
  Duration? leftAt(DateTime now) {
    if (resetsAt <= 0) return null;
    final ms = resetsAt - now.millisecondsSinceEpoch;
    return ms <= 0 ? null : Duration(milliseconds: ms);
  }

  /// Null unless the server sent a window: a reset time above 0.
  static XpDaily? maybe(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final resetsAt = _int(j['resetsAt']);
    if (resetsAt <= 0) return null;
    final claimed = <String, int>{};
    if (j['claimed'] case final Map<dynamic, dynamic> m) {
      for (final e in m.entries) {
        final code = '${e.key}'.trim();
        final n = _int(e.value);
        if (code.isNotEmpty && n > 0) claimed[code] = n;
      }
    }
    return XpDaily(claimed: Map.unmodifiable(claimed), resetsAt: resetsAt);
  }
}

/// Where the viewer stands on one ONE_TIME mission (owner, 28 Sep 2026:
/// "One-time missions are permanent missions that a player can complete only
/// once"): `user.playerLevel.missions[]` — how far they have come against
/// its target and, once completed, when and the XP it gave. The server
/// counts it and awards it (in the same hand-end write); the app only shows
/// it. There is no reset and no expiry: a completed mission stays completed.
class MissionProgress {
  const MissionProgress({
    required this.code,
    required this.progress,
    required this.target,
    this.completed = false,
    this.completedAt = 0,
    this.xpAwarded = 0,
  });

  final String code;
  final int progress;

  /// The mission's target as the server read it with the progress; 0 where
  /// it did not say (the ladder's own figure is used then).
  final int target;
  final bool completed;

  /// When it was completed, epoch ms; 0 until it is.
  final int completedAt;

  /// The XP the completion gave; 0 until it is.
  final int xpAwarded;

  /// The server's list, tolerant: anything without a code is dropped, and a
  /// list that is not a list is none.
  static List<MissionProgress> listOf(Object? raw) {
    if (raw is! List) return const [];
    final out = <MissionProgress>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final j = Map<String, dynamic>.from(e);
      final code = _str(j['code']).trim();
      if (code.isEmpty) continue;
      out.add(
        MissionProgress(
          code: code,
          progress: math.max(0, _int(j['progress'])),
          target: math.max(0, _int(j['target'])),
          completed: j['completed'] == true,
          completedAt: math.max(0, _int(j['completedAt'])),
          xpAwarded: math.max(0, _int(j['xpAwarded'])),
        ),
      );
    }
    return List.unmodifiable(out);
  }
}

/// The viewer's own level (owner, 26 Sep 2026: "create table which stores
/// every player xp and ac to their level, tax will be applied"): the level
/// their XP has reached, its name and mark, the XP itself, and the winning tax
/// the LEVEL sets, in basis points. A level is XP alone — it never expires,
/// and VIP is not one (owner, 27 Sep 2026: "Vip is not a level, it is badge"):
/// what the player pays is [User.paysTaxBps], which a badge may bring lower;
/// what a seat pays is the server's to say ([You.taxBps]).
class PlayerLevel {
  const PlayerLevel({
    required this.level,
    required this.title,
    required this.xp,
    required this.taxBps,
    this.icon = '',
    this.assetUrl = '',
    this.assetFormat = '',
    this.next,
    this.today,
    this.daily,
    this.missions = const [],
  });

  final int level;

  /// "Rising Star", "Pro Player" — the server's, never translated.
  final String title;

  /// The level's mark ("🌟", "🏅"), drawn before the title; empty when the
  /// server sent none.
  final String icon;

  /// The level's art (owner, 29 Sep 2026: "Instead of using icons use lottie
  /// animations json for showing player Level"): the owner's Lottie at
  /// [assetUrl], which the app draws wherever it showed [icon] (LevelArt).
  /// Empty while the owner has not given one, and the app shows an empty
  /// mark.
  final String assetUrl;
  final String assetFormat;

  /// Whether [assetUrl] is art the app can draw: a Lottie.
  bool get hasArt => assetUrl.isNotEmpty && assetFormat == 'LOTTIE';

  final int xp;

  /// The winning tax this level sets, in basis points.
  final int taxBps;

  /// The next level XP reaches, or null at the top of the ladder.
  final LevelStep? next;

  /// What today's window has earned against its cap; null where the server
  /// sets no daily cap (as it does not, since the owner's "Don't set any
  /// daily limit to xp").
  final XpToday? today;

  /// What the player has earned of the daily XP in the running window; null
  /// while none is running.
  final XpDaily? daily;

  /// Where the player stands on the ONE_TIME missions they have moved on or
  /// completed (28 Sep 2026); a mission not listed is at 0 of its target.
  /// Never reset by a window: [daily] going away leaves these as they are.
  final List<MissionProgress> missions;

  /// The player's progress on mission [code], or null where they have not
  /// moved it.
  MissionProgress? missionOf(String code) {
    for (final m in missions) {
      if (m.code == code) return m;
    }
    return null;
  }

  /// Null unless the server sent a level worth showing: a level number above
  /// 0 and a rate in 0..10000.
  static PlayerLevel? maybe(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final level = _int(j['level']);
    final bps = _bpsOrNull(j['taxBps']);
    if (level <= 0 || bps == null) return null;
    return PlayerLevel(
      level: level,
      title: _str(j['title']),
      icon: _str(j['icon']).trim(),
      assetUrl: _str(j['assetUrl']).trim(),
      assetFormat: _str(j['assetFormat']).trim().toUpperCase(),
      xp: math.max(0, _int(j['xp'])),
      taxBps: bps,
      next: LevelStep.maybe(j['next']),
      today: XpToday.maybe(j['today']),
      daily: XpDaily.maybe(j['daily']),
      missions: MissionProgress.listOf(j['missions']),
    );
  }
}

/// A badge the viewer holds (owner, 27 Sep 2026: "Vip is not a level, it is
/// badge, User can hold multiple badges"): Regular, everyone's for life at 20%
/// ("By default every user will hold this Regular badge 20 percent tax …
/// validaity life time"); and a Royal badge where one has been given or bought
/// — bringing the holder's winning tax down to its own rate until the grant
/// runs out ("add validity column in badges so that when it expires, player
/// will not get tax benefit"). Never earned by XP.
class PlayerBadge {
  const PlayerBadge({
    required this.code,
    required this.title,
    this.icon = '',
    this.taxBps,
    this.expiresAt = 0,
    this.isDefault = false,
    this.assetUrl = '',
    this.assetFormat = '',
  });

  /// "REGULAR", "ROYAL_KING" — what the app knows it by.
  final String code;

  /// "Regular", "Royal King" — the server's, never translated, like a
  /// level's.
  final String title;

  /// The badge's mark (an emoji), drawn before the title; empty for none.
  final String icon;

  /// The winning tax the badge brings its holder's down to, in basis points;
  /// null for a badge that sets no rate.
  final int? taxBps;

  /// When the grant runs out, epoch ms; 0 for a badge held for ever.
  final int expiresAt;

  /// The badge every player holds, for life (Standard).
  final bool isDefault;

  /// The badge's art — a Royal badge's Lottie — and how it is drawn; empty
  /// for a badge shown by its [icon] alone.
  final String assetUrl;
  final String assetFormat;

  /// How long the grant has left at [now], or null when it never runs out or
  /// already has.
  Duration? leftAt(DateTime now) {
    if (expiresAt <= 0) return null;
    final ms = expiresAt - now.millisecondsSinceEpoch;
    return ms <= 0 ? null : Duration(milliseconds: ms);
  }

  /// The server's list, tolerant: anything that is not a badge with a code is
  /// dropped, and a list that is not a list is none.
  static List<PlayerBadge> listOf(Object? raw) {
    if (raw is! List) return const [];
    final out = <PlayerBadge>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final j = Map<String, dynamic>.from(e);
      final code = _str(j['code']).trim();
      if (code.isEmpty) continue;
      out.add(
        PlayerBadge(
          code: code,
          title: _str(j['title']),
          icon: _str(j['icon']).trim(),
          taxBps: _bpsOrNull(j['taxBps']),
          expiresAt: math.max(0, _int(j['expiresAt'])),
          isDefault: j['isDefault'] == true,
          assetUrl: _str(j['assetUrl']).trim(),
          assetFormat: _str(j['assetFormat']).trim(),
        ),
      );
    }
    return List.unmodifiable(out);
  }
}

/// What `player:level` carries (owner, 26–27 Sep 2026): the viewer's level
/// and XP, the badges they hold, and the winning tax they pay — the user
/// object's `playerLevel`, `badges` and `taxBps`, which it replaces
/// ([User.withStanding]).
class Standing {
  const Standing({
    required this.playerLevel,
    this.badges = const [],
    this.taxBps,
  });

  final PlayerLevel playerLevel;
  final List<PlayerBadge> badges;
  final int? taxBps;

  /// Null unless the payload carries a level worth showing.
  static Standing? maybe(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final level = PlayerLevel.maybe(j['playerLevel']);
    if (level == null) return null;
    return Standing(
      playerLevel: level,
      badges: PlayerBadge.listOf(j['badges']),
      taxBps: _bpsOrNull(j['taxBps']),
    );
  }
}

/// The whole level ladder (`GET /api/levels`, owner, 27 Sep 2026: the table's
/// tax pill, tapped, "show everything in detail and it also show all levels
/// and taxes"): every level with the XP that reaches it and the winning tax it
/// carries, every badge with the rate it brings a holder's down to and how
/// long a grant of it lasts, the ways XP is earned, and the day's cap.
/// Configuration: the same for every player.
class LevelLadder {
  const LevelLadder({
    required this.levels,
    this.badges = const [],
    this.sources = const [],
    this.missions = const [],
    this.dailyCap = 0,
    this.windowMs = 0,
  });

  /// Levels 1 up, in order.
  final List<LadderLevel> levels;
  final List<LadderBadge> badges;

  /// The DAILY sources: earned again every window.
  final List<LadderSource> sources;

  /// The ONE_TIME missions (owner, 28 Sep 2026): each earned once in a
  /// player's life, never reset — the server's `missions`, beside its
  /// `xpSources` and never among them, so an older app's daily sum (the
  /// "108 XP a window") never counted one.
  final List<LadderSource> missions;

  /// The source or mission [code], or null.
  LadderSource? sourceOf(String code) {
    for (final s in sources) {
      if (s.code == code) return s;
    }
    for (final m in missions) {
      if (m.code == code) return m;
    }
    return null;
  }

  /// The most XP a player earns in one window; 0 where the server sets no
  /// daily cap (owner, 27 Sep 2026: "Don't set any daily limit to xp").
  final int dailyCap;

  /// How long a window lasts, in ms.
  final int windowMs;

  /// The most XP the daily sources give in one window: each source's XP as
  /// many times as it can be earned — 108 as seeded (owner, 27 Sep 2026) —
  /// or the daily cap where an owner has set a lower one.
  int get dailyMax {
    var sum = 0;
    for (final s in sources) {
      sum += s.xp * s.times;
    }
    return dailyCap > 0 ? math.min(dailyCap, sum) : sum;
  }

  /// The rung [level] is on, or null.
  LadderLevel? levelOf(int level) {
    for (final l in levels) {
      if (l.level == level) return l;
    }
    return null;
  }

  /// Null unless the server described at least one level.
  static LevelLadder? maybe(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final levels = <LadderLevel>[
      for (final e in (j['levels'] is List ? j['levels'] as List : const []))
        ?LadderLevel.maybe(e),
    ]..sort((a, b) => a.level.compareTo(b.level));
    if (levels.isEmpty) return null;
    // Every source by its type, wherever the server listed it: a ONE_TIME
    // one among the daily sources would otherwise be summed into the day's
    // most and listed as a daily way to earn XP.
    final all = <LadderSource>[
      for (final e
          in (j['xpSources'] is List ? j['xpSources'] as List : const []))
        ?LadderSource.maybe(e),
      for (final e
          in (j['missions'] is List ? j['missions'] as List : const []))
        ?LadderSource.maybe(e, type: LadderSource.typeOneTime),
    ];
    return LevelLadder(
      levels: List.unmodifiable(levels),
      badges: List.unmodifiable(<LadderBadge>[
        for (final e in (j['badges'] is List ? j['badges'] as List : const []))
          ?LadderBadge.maybe(e),
      ]),
      sources: List.unmodifiable([
        for (final s in all)
          if (!s.oneTime) s,
      ]),
      missions: List.unmodifiable([
        for (final s in all)
          if (s.oneTime && (s.target ?? 0) > 0) s,
      ]),
      dailyCap: math.max(0, _int(j['dailyCap'])),
      windowMs: math.max(0, _int(j['windowMs'])),
    );
  }
}

/// One rung of [LevelLadder].
class LadderLevel {
  const LadderLevel({
    required this.level,
    required this.title,
    required this.minXp,
    required this.taxBps,
    this.icon = '',
    this.assetUrl = '',
    this.assetFormat = '',
  });

  final int level;
  final String title;
  final String icon;

  /// The level's art (owner, 29 Sep 2026: "Instead of using icons use lottie
  /// animations json for showing player Level"): the owner's Lottie at
  /// [assetUrl], which the app draws wherever it showed [icon] (LevelArt).
  /// Empty while the owner has not given one, and the app shows an empty
  /// mark.
  final String assetUrl;
  final String assetFormat;

  /// Whether [assetUrl] is art the app can draw: a Lottie.
  bool get hasArt => assetUrl.isNotEmpty && assetFormat == 'LOTTIE';

  final int minXp;
  final int taxBps;

  static LadderLevel? maybe(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final level = _int(j['level']);
    final bps = _bpsOrNull(j['taxBps']);
    if (level <= 0 || bps == null || j['minXp'] is! num) return null;
    return LadderLevel(
      level: level,
      title: _str(j['title']),
      icon: _str(j['icon']).trim(),
      assetUrl: _str(j['assetUrl']).trim(),
      assetFormat: _str(j['assetFormat']).trim().toUpperCase(),
      minXp: math.max(0, _int(j['minXp'])),
      taxBps: bps,
    );
  }
}

/// One badge of [LevelLadder]: the rate it brings a holder's down to (null:
/// none), how long a grant lasts (0: for ever — Standard's lifetime), whether
/// every player holds it, its price and — for the badges the store sells — the
/// Play product it is bought as.
class LadderBadge {
  const LadderBadge({
    required this.code,
    required this.title,
    this.icon = '',
    this.taxBps,
    this.validityDays = 0,
    this.isDefault = false,
    this.priceInr,
    this.productId = '',
    this.assetUrl = '',
    this.assetFormat = '',
  });

  final String code;
  final String title;
  final String icon;
  final int? taxBps;
  final int validityDays;
  final bool isDefault;

  /// The badge's art — a Royal badge's Lottie (owner, 27 Sep 2026: "with
  /// their lottie animation") — and how it is drawn (`LOTTIE`, `IMAGE`,
  /// `SVG`); empty for a badge shown by its [icon] alone.
  final String assetUrl;
  final String assetFormat;

  /// What the badge costs in whole rupees — always INR (owner, 27 Sep 2026:
  /// "price in badges will always be in inr currency") — or null where none
  /// is set (a badge an owner only gives by hand).
  final int? priceInr;

  /// The Google Play product the store sells the badge as; empty where the
  /// store does not sell it — a badge given by hand, whose shelf card offers
  /// support instead (owner, 27 Sep 2026: "for all type of royal badges Add a
  /// button to contact support in store").
  final String productId;

  /// Whether the app sells it, through Play.
  bool get buyable => productId.isNotEmpty;

  /// Whether the store's Badges shelf lists it: every badge but the one
  /// everybody holds that has a price (owner, 27 Sep 2026: "for badges use
  /// this entry, not vips entry" — the Royal badges). One the app does not
  /// sell asks for support.
  bool get listed => !isDefault && priceInr != null;

  static LadderBadge? maybe(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final code = _str(j['code']).trim();
    if (code.isEmpty) return null;
    return LadderBadge(
      code: code,
      title: _str(j['title']),
      icon: _str(j['icon']).trim(),
      taxBps: _bpsOrNull(j['taxBps']),
      validityDays: math.max(0, _int(j['validityDays'])),
      isDefault: j['isDefault'] == true,
      priceInr: switch (_intOrNull(j['priceInr'])) {
        final p? when p >= 0 => p,
        _ => null,
      },
      productId: _str(j['productId']).trim(),
      assetUrl: _str(j['assetUrl']).trim(),
      assetFormat: _str(j['assetFormat']).trim(),
    );
  }
}

/// One source of the daily XP (owner, 27 Sep 2026: "🎮 Play 15 active
/// minutes +3 XP … 🔥 Win by Trail +20 XP … After 24 hours this will be reset,
/// so user can claim this again"): its code, its mark, what earns it — so
/// many minutes of active play in the window ([kindPlayTime], [playMinutes])
/// or a hand won with a given Teen Patti hand ([kindWinHand], [hand]) —
/// the XP it gives and how many times a window it can be earned. The app
/// names the kinds it knows in its own five languages, and any other by the
/// server's admin [name].
///
/// Since 28 Sep 2026 a source has a [type]: DAILY (every source before it,
/// and what a server that sends none means) or ONE_TIME — a mission earned
/// once in a player's life when their progress reaches its [target], counted
/// in hands played or won, or different games or variations played, at the
/// tables its [scope] names (an engine — `poker` — or a category —
/// `texas_holdem`; empty for any). A one-time mission's [name] is its title
/// ("First Hand"), shown as the server wrote it, as a level's title is; what
/// it asks is the app's own words (`missionTask`, table_tax.dart).
class LadderSource {
  const LadderSource({
    required this.code,
    required this.xp,
    this.name = '',
    this.icon = '',
    this.kind = '',
    this.type = typeDaily,
    this.playMinutes,
    this.hand = '',
    this.target,
    this.scope = '',
    this.times = 1,
  });

  static const String kindPlayTime = 'PLAY_TIME';
  static const String kindWinHand = 'WIN_HAND';

  /// The one-time kinds.
  static const String kindHandsPlayed = 'HANDS_PLAYED';
  static const String kindHandsWon = 'HANDS_WON';
  static const String kindCategoriesPlayed = 'CATEGORIES_PLAYED';
  static const String kindVariationsPlayed = 'VARIATIONS_PLAYED';

  static const String typeDaily = 'DAILY';
  static const String typeOneTime = 'ONE_TIME';

  final String code;
  final String name;

  /// The source's mark (an emoji, "🎮"), drawn before its name; empty for
  /// none.
  final String icon;
  final String kind;

  /// DAILY or ONE_TIME.
  final String type;

  /// A ONE_TIME mission's target: the hands, or the different games or
  /// variations, that complete it; null on a daily source.
  final int? target;

  /// A ONE_TIME mission's tables: an engine or a category code; empty for
  /// any table.
  final String scope;

  /// Whether this is a ONE_TIME mission.
  bool get oneTime => type == typeOneTime;

  /// PLAY_TIME: the minutes of active play in the window that earn it.
  final int? playMinutes;

  /// WIN_HAND: the hand — `PAIR`, `COLOR`, `SEQUENCE`, `PURE_SEQUENCE`,
  /// `TRAIL` — a win with which earns it, as the server named it; the app
  /// only names it, never works it out.
  final String hand;
  final int xp;

  /// How many times a window it can be earned (1 as seeded).
  final int times;

  /// The server's source, tolerant; [type] is what a source that names none
  /// is (a daily source from a server before one-time missions).
  static LadderSource? maybe(Object? raw, {String type = typeDaily}) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final code = _str(j['code']).trim();
    if (code.isEmpty) return null;
    final minutes = _intOrNull(j['playMinutes']);
    final target = _intOrNull(j['target']);
    final sent = _str(j['type']).trim();
    return LadderSource(
      code: code,
      name: _str(j['name']),
      icon: _str(j['icon']).trim(),
      kind: _str(j['kind']).trim(),
      type: sent == typeOneTime || sent == typeDaily ? sent : type,
      playMinutes: minutes != null && minutes > 0 ? minutes : null,
      hand: _str(j['hand']).trim(),
      target: target != null && target > 0 ? target : null,
      scope: _str(j['scope']).trim(),
      xp: math.max(0, _int(j['xp'])),
      times: math.max(1, _int(j['times'])),
    );
  }
}

/// One room on the lobby's menu.
///
/// The server lists the pairs it offers rather than the client crossing every
/// category with every stake: the two are only meaningful together, and 5,000
/// existing as a stake does not mean a seen table exists at it.
///
/// `session:ready.config.tables` carries the keys up to [maxDiscards]. The
/// table catalogue (`GET /api/tables`, since 23 Sep 2026) carries the same
/// entries with the engine that plays them and every figure the table plays
/// by beside them — [engine], then [key] through [fiveCardPickTimeoutMs] —
/// and lists the private templates too
/// ([GameConfig.privateTables]). Those extra figures are NULL wherever the
/// server did not send them (session:ready, an older server), which is what
/// lets a widget prefer the table's own figure and fall back to today's
/// table-wide one without mistaking "not sent" for a real zero.
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
    this.winnerTax = false,
    this.winnerTaxMinWinnings = 0,
    this.engine,
    this.key,
    this.isPrivate,
    this.sortOrder,
    this.maxRaiseSteps,
    this.maxBetRounds,
    this.potLimitMultiplier,
    this.turnTimeoutMs,
    this.maxMissedTurns,
    this.sideshowTimeoutMs,
    this.sideshowMinPlayers,
    this.nextHandDelayMs,
    this.unfundedGraceMs,
    this.missileRevealExtraMs,
    this.variationSelectTimeoutMs,
    this.fiveCardPickTimeoutMs,
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

  /// Whether the winner of each hand here pays winning tax on what they win
  /// — the pot less their own chips — at the rate they pay (owner, 26–27 Sep
  /// 2026; [User.paysTaxBps]). The server marks such a table `winnerTax:
  /// true` and leaves the key off every other, so false is every table from a
  /// server that predates it.
  final bool winnerTax;

  /// The smallest winnings such a table taxes (owner, 27 Sep 2026: "30 lakh
  /// is the limit on winning amount not on pot limit"); 0 where any are.
  final int winnerTaxMinWinnings;

  /// [winnerTax], and never at a poker table, whose games do not read it.
  bool get taxesWinner => winnerTax && !isPoker;

  /// Whether this is a poker table: the server says so with `game` (and, in
  /// the table catalogue, with [engine]), and a poker category says the same
  /// without either.
  bool get isPoker =>
      game == 'poker' ||
      engine == TableEngine.poker ||
      TableCategory.isPoker(category);

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

  // ---- the catalogue's figures: null when the server did not send them ----

  /// The engine that plays this table's category — [TableEngine.teenPatti]
  /// or [TableEngine.poker], or one this build has never heard of. The lobby
  /// files the table under that engine's front card
  /// ([GameState.lobbyEngineOf]); null (session:ready, an older server) files
  /// it by its category — a poker game under Poker, everything else under
  /// Teen Patti.
  final String? engine;

  /// The server's name for the table: `"seen:200"` for a public one,
  /// `"private:seen"` for a private template.
  final String? key;

  /// Whether this is a private template (room:create) rather than a lobby
  /// table. True only on [GameConfig.privateTables] entries.
  final bool? isPrivate;

  /// Where the table stands on the server's menu. The menu already arrives in
  /// that order, so nothing sorts by it; it is here to be read, not used.
  final int? sortOrder;

  /// The ladder: how many rungs a bet may climb (0 = to the stack), how many
  /// rounds before the forced showdown (0 = never), and the per-bet ceiling
  /// as a multiple of the boot (0 = none).
  final int? maxRaiseSteps;
  final int? maxBetRounds;
  final int? potLimitMultiplier;

  /// This table's turn clock. A poker room's clock is its own and not the
  /// Teen Patti one [GameConfig.turnTimeoutMs] names, which is why the table
  /// info popup reads this first.
  final int? turnTimeoutMs;

  /// Missed turns before the idle kick (requirement 31).
  final int? maxMissedTurns;

  /// How long a sideshow request stands, and how many players must still be
  /// in the hand for one to be asked.
  final int? sideshowTimeoutMs;
  final int? sideshowMinPlayers;

  /// The pause between hands, the grace a short stack gets to buy chips
  /// before it is shown out, and the extra pause after a missile's reveal.
  final int? nextHandDelayMs;
  final int? unfundedGraceMs;
  final int? missileRevealExtraMs;

  /// A variation table's two windows: choosing the hand's variation, and
  /// choosing three of five under 5-Card. 0 on every other table.
  final int? variationSelectTimeoutMs;
  final int? fiveCardPickTimeoutMs;

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
    winnerTax: j['winnerTax'] == true,
    winnerTaxMinWinnings: math.max(0, _int(j['winnerTaxMinWinnings'])),
    engine: _strOrNull(j['engine']),
    key: _strOrNull(j['key']),
    isPrivate: j['isPrivate'] is bool ? j['isPrivate'] as bool : null,
    sortOrder: _intOrNull(j['sortOrder']),
    maxRaiseSteps: _intOrNull(j['maxRaiseSteps']),
    maxBetRounds: _intOrNull(j['maxBetRounds']),
    potLimitMultiplier: _intOrNull(j['potLimitMultiplier']),
    turnTimeoutMs: _intOrNull(j['turnTimeoutMs']),
    maxMissedTurns: _intOrNull(j['maxMissedTurns']),
    sideshowTimeoutMs: _intOrNull(j['sideshowTimeoutMs']),
    sideshowMinPlayers: _intOrNull(j['sideshowMinPlayers']),
    nextHandDelayMs: _intOrNull(j['nextHandDelayMs']),
    unfundedGraceMs: _intOrNull(j['unfundedGraceMs']),
    missileRevealExtraMs: _intOrNull(j['missileRevealExtraMs']),
    variationSelectTimeoutMs: _intOrNull(j['variationSelectTimeoutMs']),
    fiveCardPickTimeoutMs: _intOrNull(j['fiveCardPickTimeoutMs']),
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

/// One engine of the table catalogue's taxonomy (`GET /api/tables` →
/// `engines`, 23 Sep 2026): a family of categories played by one engine —
/// Teen Patti, Poker — with the categories it plays, as the server's
/// `table_engines` and `table_categories` hold them. Only ACTIVE ones are
/// sent: switching an engine or a category off on the server takes it, and
/// every table of it, off the menu.
///
/// [name] is the server's ADMIN label ("Teen Patti", "Poker"). The lobby
/// names every card it knows in the player's own language and reads [name]
/// only for a code this build has never heard of.
class TableEngineInfo {
  const TableEngineInfo({
    required this.code,
    required this.name,
    required this.sortOrder,
    this.categories = const [],
  });

  /// [TableEngine.teenPatti], [TableEngine.poker], or an engine added after
  /// this build.
  final String code;
  final String name;

  /// Where the engine stands among the engines; lower first.
  final int sortOrder;

  /// The categories this engine plays, each once.
  final List<TableCategoryInfo> categories;

  /// Tolerant as every DTO here: a category without a code names nothing and
  /// is dropped, and anything that is not a list of them reads as none.
  factory TableEngineInfo.fromJson(Map<String, dynamic> j) => TableEngineInfo(
    code: _str(j['code']),
    name: _str(j['name']),
    sortOrder: _int(j['sortOrder']),
    categories: [
      for (final category in _list(j['categories'], TableCategoryInfo.fromJson))
        if (category.code.isNotEmpty) category,
    ],
  );
}

/// One category of the taxonomy, under its [TableEngineInfo]: its wire code
/// (the `category` a table entry carries), the server's admin label for it,
/// and where it stands among its engine's categories.
class TableCategoryInfo {
  const TableCategoryInfo({
    required this.code,
    required this.name,
    required this.sortOrder,
  });

  final String code;
  final String name;

  /// Lower first, within its engine.
  final int sortOrder;

  factory TableCategoryInfo.fromJson(Map<String, dynamic> j) =>
      TableCategoryInfo(
        code: _str(j['code']),
        name: _str(j['name']),
        sortOrder: _int(j['sortOrder']),
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
    this.tableConfigVersion,
    this.privateTables = const [],
    this.engines = const [],
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
  ///
  /// Session-scoped: it comes from `session:ready` and nowhere else. The
  /// table catalogue does not carry it, so a menu read from the catalogue (or
  /// from the phone's copy of it) holds 0 here until a session says otherwise.
  final int minClientBuild;

  /// Which table catalogue this menu is: `session:ready.config.tableConfigVersion`,
  /// or the `version` of a `GET /api/tables` body. The two are the same
  /// string when they describe the same menu, which is how the client knows
  /// whether the catalogue it holds is the one the server is enforcing. Null
  /// from a server that predates the catalogue.
  final String? tableConfigVersion;

  /// The private templates (room:create), one per category that has one.
  /// Only the table catalogue lists them; empty from `session:ready` and from
  /// an older server.
  final List<LobbyTable> privateTables;

  /// The engines and the categories each plays (owner, 23 Sep 2026), which
  /// the lobby reads for the ORDER of its engine cards
  /// ([GameState.lobbyEngines]) and of the category cards inside each
  /// ([GameState.lobbyCategoriesIn]), and for the name of a card this build
  /// does not know. Only the table catalogue sends them; empty from
  /// `session:ready` and from an older server, and the lobby then files by
  /// the fixed taxonomy ([GameState.lobbyTaxonomy]) — the same cards.
  final List<TableEngineInfo> engines;

  /// The menu entry a room was opened from: a PRIVATE table's template by its
  /// category, a public table's entry by its category and stake. Null when
  /// this menu does not carry it — a private table on a server that lists no
  /// templates falls back to the public entry of the same pair, which is what
  /// the client did before the catalogue existed.
  LobbyTable? entryFor({
    required String category,
    required int bootAmount,
    required bool isPrivate,
  }) {
    if (isPrivate) {
      for (final table in privateTables) {
        if (table.category == category) return table;
      }
    }
    for (final table in tables) {
      if (table.category == category && table.bootAmount == bootAmount) {
        return table;
      }
    }
    return null;
  }

  GameConfig copyWith({
    int? maxPlayers,
    int? minPlayers,
    int? bootAmount,
    int? turnTimeoutMs,
    List<String>? categories,
    List<int>? stakes,
    int? privateBoot,
    int? privateMaxPot,
    int? entryCapBoot,
    String? entryCapCategory,
    int? entryCapMaxChips,
    int? sideshowTimeoutMs,
    List<LobbyTable>? tables,
    int? minClientBuild,
    String? tableConfigVersion,
    List<LobbyTable>? privateTables,
    List<TableEngineInfo>? engines,
  }) => GameConfig(
    maxPlayers: maxPlayers ?? this.maxPlayers,
    minPlayers: minPlayers ?? this.minPlayers,
    bootAmount: bootAmount ?? this.bootAmount,
    turnTimeoutMs: turnTimeoutMs ?? this.turnTimeoutMs,
    categories: categories ?? this.categories,
    stakes: stakes ?? this.stakes,
    privateBoot: privateBoot ?? this.privateBoot,
    privateMaxPot: privateMaxPot ?? this.privateMaxPot,
    entryCapBoot: entryCapBoot ?? this.entryCapBoot,
    entryCapCategory: entryCapCategory ?? this.entryCapCategory,
    entryCapMaxChips: entryCapMaxChips ?? this.entryCapMaxChips,
    sideshowTimeoutMs: sideshowTimeoutMs ?? this.sideshowTimeoutMs,
    tables: tables ?? this.tables,
    minClientBuild: minClientBuild ?? this.minClientBuild,
    tableConfigVersion: tableConfigVersion ?? this.tableConfigVersion,
    privateTables: privateTables ?? this.privateTables,
    engines: engines ?? this.engines,
  );

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
    // Blind 200 is open up to 20 Lakh (owner, 27 Sep 2026), as the server's
    // default says.
    entryCapMaxChips: 2000000,
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
    tableConfigVersion: _strOrNull(j['tableConfigVersion']),
    privateTables: j['privateTables'] is List
        ? (j['privateTables'] as List)
              .whereType<Map>()
              .map((e) => LobbyTable.fromJson(Map<String, dynamic>.from(e)))
              .toList()
        : const [],
    // An engine without a code names nothing a table could be filed under.
    engines: [
      for (final engine in _list(j['engines'], TableEngineInfo.fromJson))
        if (engine.code.isNotEmpty) engine,
    ],
  );

  /// The menu a `GET /api/tables` body describes, or null when [json] is not
  /// one worth keeping.
  ///
  /// The body is `session:ready.config`'s shape plus `version`, `source`,
  /// `privateTables`, `engines` and the richer per-table figures, so it is
  /// read by the same [GameConfig.fromJson] — with its `version` as
  /// [tableConfigVersion]. Checked on the RAW JSON first, because what passes
  /// here is cached on the phone and opens the lobby on the next cold start: a
  /// non-empty `version` string, `tables` and `privateTables` lists of
  /// objects, a positive `maxPlayers`, and `categories`/`stakes` lists where
  /// present. A body that fails any of it is a broken answer, not a menu, and
  /// must never replace a good one. The `engines` are read tolerantly and
  /// refuse nothing: without them the lobby is what it was before they
  /// existed, which is a working lobby.
  static GameConfig? fromCatalogue(Object? json) {
    if (json is! Map) return null;
    final j = Map<String, dynamic>.from(json);
    final version = j['version'];
    if (version is! String || version.isEmpty) return null;
    bool objects(Object? v) => v is List && v.every((e) => e is Map);
    if (!objects(j['tables']) || !objects(j['privateTables'])) return null;
    final players = j['maxPlayers'];
    if (players is! num || players <= 0) return null;
    for (final key in const ['categories', 'stakes']) {
      if (j[key] != null && j[key] is! List) return null;
    }
    return GameConfig.fromJson(j).copyWith(tableConfigVersion: version);
  }
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
    this.level,
    this.cardBackground,
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

  /// The player's level on their pod — its number and art — which every
  /// viewer's snapshot carries (owner, 29 Sep 2026: "In gametable In every
  /// player pod show their game level icon on top right of player pod").
  /// Null where the server sent none (an empty seat, a server from before).
  final SeatLevel? level;

  /// The card back this player has chosen (owner, 3 Oct 2026), which every
  /// viewer at the table sees on THIS player's face-down cards — as each
  /// seat's worn picture is seen by everyone. Null where the seat wears the
  /// bundled Royal Fox: none chosen, an empty chair, a poker room (whose
  /// snapshot carries none), or a server from before card backs.
  final CardBackArt? cardBackground;

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
    level: level,
    cardBackground: cardBackground,
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
    level: SeatLevel.maybe(j['level']),
    cardBackground: CardBackArt.fromJson(j['cardBackground']),
  );
}

/// A seated player's level as the table shows it on their pod: the number
/// and the level's art (the owner's Lottie); never their XP, rate or badges.
class SeatLevel {
  const SeatLevel({
    required this.level,
    this.assetUrl = '',
    this.assetFormat = '',
  });

  final int level;
  final String assetUrl;
  final String assetFormat;

  /// Whether [assetUrl] is art the app can draw: a Lottie.
  bool get hasArt => assetUrl.isNotEmpty && assetFormat == 'LOTTIE';

  /// Null unless [raw] names a level of 1 or above.
  static SeatLevel? maybe(Object? raw) {
    if (raw is! Map) return null;
    final j = Map<String, dynamic>.from(raw);
    final level = _int(j['level']);
    if (level < 1) return null;
    return SeatLevel(
      level: level,
      assetUrl: _str(j['assetUrl']).trim(),
      assetFormat: _str(j['assetFormat']).trim().toUpperCase(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SeatLevel &&
      other.level == level &&
      other.assetUrl == assetUrl &&
      other.assetFormat == assetFormat;

  @override
  int get hashCode => Object.hash(level, assetUrl, assetFormat);
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
  PokerReveal? revealOf(String? userId) => userId == null
      ? null
      : reveals.where((r) => r.userId == userId).firstOrNull;

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
List<int> _ints(Object? raw) => raw is List
    ? [
        for (final e in raw)
          if (e is num) e.toInt(),
      ]
    : const [];

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
  /// Never more than the window's own whole seconds ([timeoutMs]): the
  /// deadline is the server's clock, and a phone running behind it would
  /// otherwise count a 10 s window from 11 (24 Sep 2026).
  int get secondsLeft {
    if (!selecting || deadline <= 0) return 0;
    final ms = deadline - DateTime.now().millisecondsSinceEpoch;
    if (ms <= 0) return 0;
    final seconds = (ms / 1000).ceil();
    return timeoutMs > 0
        ? math.min(seconds, (timeoutMs / 1000).ceil())
        : seconds;
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
    this.playsAs = const [],
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

  /// The hand as it was COUNTED, index for index with [cards]: a wild card
  /// replaced by the card it stood for, every other card itself. Sent exactly
  /// when [wild] is (owner, 24 Sep 2026: "on show or sideshow, show updated
  /// cards not the base cards"); empty from a server that predates it.
  final List<String> playsAs;

  /// The three of [cards] that were counted, under 5-Card only (where [cards]
  /// holds five). Empty everywhere else.
  final List<String> best;

  factory SideshowHand.fromJson(Map<String, dynamic> j) => SideshowHand(
    userId: _str(j['userId']),
    displayName: _str(j['displayName']),
    cards: (j['cards'] as List? ?? const []).map((e) => '$e').toList(),
    handName: _str(j['handName']),
    wild: (j['wild'] as List? ?? const []).map((e) => '$e').toList(),
    playsAs: cardCodes(j['playsAs']),
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
    this.category = -1,
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

  /// The same, as the server ranks it (its HandCategory: HIGH_CARD 0, PAIR 1,
  /// COLOR 2, SEQUENCE 3, PURE_SEQUENCE 4, TRAIL 5) — read as sent, never
  /// worked out here; what the viewer's own look animates by at a Variation
  /// table (`table_screen.dart` `_FeltState._ownLook`). -1 when the payload
  /// carries none; 0, like an empty [handName], while [picking].
  final int category;

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
          List.generate(
            best.length,
            (i) => best[i] == bestPossible[i],
          ).every((same) => same));

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
      category: j['category'] is num ? (j['category'] as num).toInt() : -1,
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
    this.taxBps,
  });

  final int seatIndex;
  final int chips;
  final String status;
  final bool isBlind;

  /// The winning tax THIS viewer's seat pays if they win a hand here, in
  /// basis points (owner, 26 Sep 2026): their level's rate as of this hand.
  /// Sent at a table that taxes its winners ([RoomState.winnerTax]) and
  /// nowhere else, so null means "no tax here".
  final int? taxBps;

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

  /// Whole seconds left of that grace, or null when there is none. Never more
  /// than the grace's own whole seconds when its length [totalMs] is known:
  /// the deadline is the server's clock, and a phone running behind it would
  /// otherwise count from one second more than the table gives (24 Sep 2026).
  int? unfundedSecondsLeft(DateTime now, {int totalMs = 0}) {
    final deadline = unfundedDeadline;
    if (deadline == null) return null;
    final ms = deadline - now.millisecondsSinceEpoch;
    if (ms <= 0) return 0;
    final seconds = (ms / 1000).ceil();
    return totalMs > 0 ? math.min(seconds, (totalMs / 1000).ceil()) : seconds;
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
      taxBps: _bpsOrNull(j['taxBps']),
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
    this.tablePicture,
    this.winnerTax = false,
    this.winnerTaxMinWinnings = 0,
  });

  final String roomId;
  final String code;

  /// Whether the winner of each hand here pays winning tax on what they win
  /// — the pot less their own chips (owner, 26–27 Sep 2026); what THIS viewer
  /// would pay is [You.taxBps]. The server sends it on a Teen Patti table
  /// that taxes and nowhere else.
  final bool winnerTax;

  /// The smallest winnings this table taxes (owner, 27 Sep 2026: "30 lakh is
  /// the limit on winning amount not on pot limit"); 0 where any are.
  final int winnerTaxMinWinnings;

  /// [winnerTax], and never at a poker room.
  bool get taxesWinner => winnerTax && !isPoker;

  /// A table reached by its code alone (requirement 22). Its code is worth
  /// showing, since it is how friends are let in; a public table's is not.
  final bool isPrivate;

  /// The table picture the table shows — the server's pick among the
  /// pictures its seated players have laid, the same for every viewer,
  /// tagged with who laid it — or null when nobody has (owner, 15 Sep 2026).
  /// The felt draws this, never the viewer's own choice on its own.
  final LaidTablePicture? tablePicture;
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
    tablePicture: j['tablePicture'] is Map
        ? LaidTablePicture.fromJson(
            Map<String, dynamic>.from(j['tablePicture'] as Map),
          )
        : null,
    winnerTax: j['winnerTax'] == true,
    winnerTaxMinWinnings: math.max(0, _int(j['winnerTaxMinWinnings'])),
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
    this.playsAs = const [],
    this.best = const [],
  });

  final String userId;
  final String displayName;
  final List<String> cards;
  final String handName;
  final bool won;

  /// Which of [cards] played as wild cards (see [SideshowHand.wild]).
  final List<String> wild;

  /// The hand as it was counted (see [SideshowHand.playsAs]).
  final List<String> playsAs;

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
    playsAs: cardCodes(j['playsAs']),
    best: cardCodes(j['best']),
  );
}

class ChatMessage {
  const ChatMessage({
    required this.userId,
    required this.displayName,
    required this.text,
    required this.at,
    this.emoji,
  });

  final String userId;
  final String displayName;

  /// What was said. On an emoji line, the emoji's NAME — so an app that knows
  /// nothing of emojis still shows a word, not a blank line.
  final String text;
  final int at;

  /// The emoji this line sends (owner, 26 Sep 2026: "that emoji message will
  /// send to all players just like chat messages"), or null on a plain line —
  /// the server leaves the key out of every line that is not one.
  final ChatEmoji? emoji;

  /// Whether this line is an emoji rather than words.
  bool get isEmoji => emoji != null;

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    userId: _str(j['userId']),
    displayName: _str(j['displayName']),
    text: _str(j['text']),
    at: _int(j['at']),
    emoji: ChatEmoji.maybe(j['emoji']),
  );
}

/// The emoji a chat line carries (`chat:message.emoji`): which one, what it
/// is called, and the Lottie to play. Only what is needed to draw it — the
/// price and the rental are the catalogue's ([EmojiItem]), not the line's.
class ChatEmoji {
  const ChatEmoji({
    required this.id,
    required this.name,
    required this.url,
    this.assetFormat = 'LOTTIE',
  });

  final int id;
  final String name;

  /// Server-relative or absolute, as sent.
  final String url;

  /// 'LOTTIE' — the only format an emoji comes in.
  final String assetFormat;

  factory ChatEmoji.fromJson(Map<String, dynamic> j) => ChatEmoji(
    id: _int(j['id']),
    name: _str(j['name']),
    url: _str(j['url']),
    assetFormat: _str(j['assetFormat']).isEmpty
        ? 'LOTTIE'
        : _str(j['assetFormat']),
  );

  /// The emoji of a line, or null when [raw] is not one — absent, null, not
  /// an object, or naming no file to play. A line whose emoji cannot be drawn
  /// is shown as the words it carries rather than as an empty bubble.
  static ChatEmoji? maybe(Object? raw) {
    if (raw is! Map) return null;
    final emoji = ChatEmoji.fromJson(Map<String, dynamic>.from(raw));
    return emoji.url.isEmpty ? null : emoji;
  }
}

/// One row of the emoji catalogue (`GET /api/emojis`, owner 26 Sep 2026): an
/// animated emoji a player can own and SEND at a table. The picture
/// catalogue's shape ([ProfilePicture]) — the same FREE/PREMIUM rule, the
/// same three wallets, the same rentals, `owned` decided by the server per
/// viewer — except that an emoji is a Lottie and is never worn.
class EmojiItem {
  const EmojiItem({
    required this.id,
    required this.name,
    required this.url,
    this.assetFormat = 'LOTTIE',
    this.currency = 'COIN',
    this.type = 'FREE',
    this.cost = 0,
    this.durationDays = 0,
    this.durationHours = 0,
    this.sortOrder = 0,
    required this.owned,
    this.expiresAt = 0,
  });

  final int id;

  /// What to call it — "Laughing".
  final String name;

  /// The Lottie JSON: server-relative ("/emojis/laugh.json") or absolute.
  final String url;

  /// 'LOTTIE'.
  final String assetFormat;

  /// Which wallet [cost] is paid from: [PictureCurrency.coin] (chips),
  /// [PictureCurrency.diamond] or [PictureCurrency.hammer]. Kept as sent, so
  /// a currency this build does not know is drawn as chips.
  final String currency;

  /// 'FREE' or 'PREMIUM'.
  final String type;

  /// In [currency]; 0 on a free emoji.
  final int cost;

  /// How long a purchase lasts; both 0 means for ever.
  final int durationDays;
  final int durationHours;

  /// The catalogue's own order.
  final int sortOrder;

  /// Whether this player may send it: every free emoji, and the premium ones
  /// they have bought whose rental is running. Decided by the server.
  final bool owned;

  /// Epoch ms this player's rental runs out; 0 when they do not own it, or
  /// own it for ever.
  final int expiresAt;

  bool get free => type == 'FREE';
  bool get locked => !owned;
  bool get rented => durationDays > 0 || durationHours > 0;
  bool get pricedInDiamonds => currency == PictureCurrency.diamond;
  bool get pricedInHammers => currency == PictureCurrency.hammer;

  factory EmojiItem.fromJson(Map<String, dynamic> j) => EmojiItem(
    id: _int(j['id']),
    name: _str(j['name']),
    url: _str(j['url']),
    assetFormat: _str(j['assetFormat']).isEmpty
        ? 'LOTTIE'
        : _str(j['assetFormat']),
    currency: _str(j['currency']).isEmpty ? 'COIN' : _str(j['currency']),
    type: _str(j['type']).isEmpty ? 'FREE' : _str(j['type']),
    cost: _int(j['cost']),
    durationDays: _int(j['durationDays']),
    durationHours: _int(j['durationHours']),
    sortOrder: _int(j['sortOrder']),
    expiresAt: _int(j['expiresAt']),
    // Absent reads as "not owned", as a picture's does: a free emoji is only
    // ever sent with owned true.
    owned: j['owned'] == true,
  );
}

/// The table picture a player has laid, as `user.tablePicture` carries it:
/// the pair of files and how to draw them. [dayUrl] is drawn on the light
/// theme, [nightUrl] on the dark one ([forBrightness]).
class LaidTablePicture {
  const LaidTablePicture({
    required this.id,
    required this.dayUrl,
    required this.nightUrl,
    this.assetFormat = 'IMAGE',
    this.userId = '',
  });

  final int id;
  final String dayUrl;
  final String nightUrl;

  /// 'IMAGE' | 'SVG' | 'LOTTIE' | 'RIVE', one loader for both files.
  final String assetFormat;

  /// Who laid it, on `room:state.tablePicture` — the table shows the
  /// server's pick among everyone seated (owner, 15 Sep 2026) — and empty on
  /// the account's own `user.tablePicture`.
  final String userId;

  /// The file the theme wants: a pale cloth for dark ink by day, a deep one
  /// for light ink by night. Server-relative or absolute, as sent.
  String forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? nightUrl : dayUrl;

  factory LaidTablePicture.fromJson(Map<String, dynamic> j) => LaidTablePicture(
    id: _int(j['id']),
    dayUrl: _str(j['dayUrl']),
    nightUrl: _str(j['nightUrl']),
    assetFormat: _str(j['assetFormat'] ?? 'IMAGE'),
    userId: _str(j['userId']),
  );
}

/// One row of the server's table-picture catalogue (GET /api/table-pictures,
/// owner 15 Sep 2026): a cloth for the player's own table, in two palettes.
///
/// [ProfilePicture] with the one URL split in two: [dayUrl] for the light
/// theme and [nightUrl] for the dark one, since the ink on the table follows
/// the theme and one picture cannot read under both. Everything else — the
/// wallet, the price, the term, who owns it — is the same catalogue.
class TablePicture {
  const TablePicture({
    required this.id,
    required this.name,
    required this.dayUrl,
    required this.nightUrl,
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
  final String name;
  final String dayUrl;
  final String nightUrl;
  final String assetFormat;

  /// Which wallet [cost] is paid from — [PictureCurrency.coin], `diamond` or
  /// `hammer`; 'COIN' on a free row.
  final String currency;

  /// 'FREE' or 'PREMIUM'.
  final String type;
  final int cost;
  final int durationDays;
  final int durationHours;

  /// Whether this player may lay it: every free picture, plus the premium
  /// ones they have bought whose rental is running. Decided by the server.
  final bool owned;

  /// Epoch ms this player's rental runs out; 0 when they do not own it, or
  /// own it for ever.
  final int expiresAt;

  bool get free => type == 'FREE';
  bool get locked => !owned;
  bool get rented => durationDays > 0 || durationHours > 0;
  bool get pricedInDiamonds => currency == PictureCurrency.diamond;
  bool get pricedInHammers => currency == PictureCurrency.hammer;

  /// The file the theme wants ([LaidTablePicture.forBrightness]).
  String forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? nightUrl : dayUrl;

  factory TablePicture.fromJson(Map<String, dynamic> j) => TablePicture(
    id: _int(j['id']),
    name: _str(j['name']),
    dayUrl: _str(j['dayUrl']),
    nightUrl: _str(j['nightUrl']),
    assetFormat: _str(j['assetFormat'] ?? 'IMAGE'),
    currency: _str(j['currency'] ?? 'COIN'),
    type: _str(j['type']).isEmpty ? 'FREE' : _str(j['type']),
    cost: _int(j['cost']),
    durationDays: _int(j['durationDays']),
    durationHours: _int(j['durationHours']),
    expiresAt: _int(j['expiresAt']),
    owned: j['owned'] == true,
  );
}

/// Where the card is inside a card back's picture, as fractions of the
/// picture (owner, 3 Oct 2026): [x] and [y] its top-left corner, [w] and [h]
/// its size.
///
/// Every card back in the R2 bucket is a 1024x1024 product shot, the card on
/// a dark ground at a different size and place in each, so the row says
/// where the card is — measured by hand to the card's own 5:7
/// (`PlayingCard.aspect`) in the picture's pixels, so a client draws the
/// crop stretched to the card and no ground shows at any edge.
class CardCrop {
  const CardCrop({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  final double x;
  final double y;
  final double w;
  final double h;

  /// How far past 1 a sum `x + w` (or `y + h`) may come and still be read:
  /// room for the rounding in adding two decimals, never for a crop that
  /// leaves the picture.
  static const double slack = 1e-6;

  /// The crop in a picture [width] by [height] pixels.
  Rect rectIn(double width, double height) =>
      Rect.fromLTWH(x * width, y * height, w * width, h * height);

  /// The crop off the wire (`crop: {x, y, w, h}`), or null — the whole
  /// picture is the card — when it is absent or is not a crop: anything that
  /// is not an object, a corner or a size that is not a finite number, a
  /// size of 0 or less, or a rectangle that leaves the picture (a corner
  /// below 0, `x + w` or `y + h` past 1). Tolerant, as every reader here is:
  /// a row the server would never send is no crop rather than a crash.
  static CardCrop? fromJson(Object? raw) {
    if (raw is! Map) return null;
    double? fraction(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
    final x = fraction(raw['x']);
    final y = fraction(raw['y']);
    final w = fraction(raw['w']);
    final h = fraction(raw['h']);
    if (x == null || y == null || w == null || h == null) return null;
    if (x < 0 || y < 0 || w <= 0 || h <= 0) return null;
    if (x + w > 1 + slack || y + h > 1 + slack) return null;
    return CardCrop(x: x, y: y, w: w, h: h);
  }

  @override
  bool operator ==(Object other) =>
      other is CardCrop &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h;

  @override
  int get hashCode => Object.hash(x, y, w, h);

  @override
  String toString() => 'CardCrop($x, $y, $w, $h)';
}

/// A card back as a seat or the account wears it (owner, 3 Oct 2026: "Add a
/// table cards_background which users can buy just like user can buy
/// profile_pictures"): which row, the picture, and where the card is in it —
/// all a card needs to draw it ([Seat.cardBackground], [User.cardBackground],
/// [CardBackground.art]).
///
/// Null wherever one is expected means the bundled Royal Fox
/// (`PlayingCard.backAsset`), the free default, which is not a row.
class CardBackArt {
  const CardBackArt({this.id, required this.url, this.crop});

  /// The catalogue row it is, where known.
  final int? id;

  /// The picture's location as the database stores it: a file of the
  /// private R2 bucket (".../king-teenpatti/cards/Brutal%20Demon.jpg"),
  /// absolute, which `PictureCache` downloads through a URL the server signs
  /// and keeps under this location.
  final String url;

  /// Where the card is in the picture; null when the whole picture is the
  /// card.
  final CardCrop? crop;

  /// A card back off the wire (`{id, url, assetFormat, crop?}`), or null —
  /// the Royal Fox — when [raw] is not one: absent, null, not an object,
  /// naming no picture, or in a format other than IMAGE (a back is a raster;
  /// a file this build cannot draw is no back rather than a broken card).
  static CardBackArt? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    if (url is! String || url.trim().isEmpty) return null;
    final format = raw['assetFormat'];
    if (format is String &&
        format.trim().isNotEmpty &&
        format.trim().toUpperCase() != 'IMAGE') {
      return null;
    }
    return CardBackArt(
      id: _intOrNull(raw['id']),
      url: url.trim(),
      crop: CardCrop.fromJson(raw['crop']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CardBackArt &&
      other.id == id &&
      other.url == url &&
      other.crop == crop;

  @override
  int get hashCode => Object.hash(id, url, crop);

  @override
  String toString() => 'CardBackArt($id, $url, $crop)';
}

/// One row of the card-back catalogue (`GET /api/card-backgrounds`, owner
/// 3 Oct 2026): a back a player can buy and wear on their cards, which every
/// player at their table then sees.
///
/// [TablePicture]'s catalogue — the same FREE/PREMIUM rule, the same three
/// wallets, the same rentals, `owned` decided by the server per viewer —
/// with one picture ([url], always a raster) and where the card is in it
/// ([crop]). The seeded eight are 5 hammers for 10 days each; the bundled
/// Royal Fox, everybody's for nothing, is not a row.
class CardBackground {
  const CardBackground({
    required this.id,
    required this.name,
    required this.url,
    this.assetFormat = 'IMAGE',
    this.crop,
    this.currency = 'COIN',
    this.type = 'FREE',
    this.cost = 0,
    this.durationDays = 0,
    this.durationHours = 0,
    this.sortOrder = 0,
    required this.owned,
    this.expiresAt = 0,
  });

  final int id;

  /// What to call it — "Brutal Demon".
  final String name;

  /// The picture's location ([CardBackArt.url]).
  final String url;

  /// 'IMAGE' — the only format a card back comes in.
  final String assetFormat;

  /// Where the card is in the picture; null when the whole picture is it.
  final CardCrop? crop;

  /// Which wallet [cost] is paid from: [PictureCurrency.coin] (chips),
  /// [PictureCurrency.diamond] or [PictureCurrency.hammer]. Kept as sent, so
  /// a currency this build does not know is drawn as chips.
  final String currency;

  /// 'FREE' or 'PREMIUM'.
  final String type;

  /// In [currency]; 0 on a free row.
  final int cost;

  /// How long a purchase lasts; both 0 means for ever.
  final int durationDays;
  final int durationHours;

  /// The catalogue's own order.
  final int sortOrder;

  /// Whether this player may wear it: every free row, and the premium ones
  /// they have bought whose rental is running. Decided by the server.
  final bool owned;

  /// Epoch ms this player's rental runs out; 0 when they do not own it, or
  /// own it for ever.
  final int expiresAt;

  bool get free => type == 'FREE';
  bool get locked => !owned;
  bool get rented => durationDays > 0 || durationHours > 0;
  bool get pricedInDiamonds => currency == PictureCurrency.diamond;
  bool get pricedInHammers => currency == PictureCurrency.hammer;

  /// The back as a card draws it.
  CardBackArt get art => CardBackArt(id: id, url: url, crop: crop);

  factory CardBackground.fromJson(Map<String, dynamic> j) => CardBackground(
    id: _int(j['id']),
    name: _str(j['name']),
    url: _str(j['url']).trim(),
    assetFormat: _str(j['assetFormat']).isEmpty
        ? 'IMAGE'
        : _str(j['assetFormat']),
    crop: CardCrop.fromJson(j['crop']),
    currency: _str(j['currency']).isEmpty ? 'COIN' : _str(j['currency']),
    type: _str(j['type']).isEmpty ? 'FREE' : _str(j['type']),
    cost: _int(j['cost']),
    durationDays: _int(j['durationDays']),
    durationHours: _int(j['durationHours']),
    sortOrder: _int(j['sortOrder']),
    expiresAt: _int(j['expiresAt']),
    // Absent reads as "not owned", as a picture's does: a free row is only
    // ever sent with owned true.
    owned: j['owned'] == true,
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

/// What a NEW account was given as it was made (30 Sep 2026): the login's
/// `welcome` block, which the server writes from its `welcome_rewards` rows
/// and sends only on the login that created the account. Any figure may be 0
/// and any list empty — a deployment may grant some of the wallets, all of
/// them, or none — and the pictures and emojis come as the catalogues' own
/// rows (`GET /api/profiles`, `/api/table-pictures`, `/api/emojis`), `owned`
/// resolved for this player.
///
/// Read tolerantly: a figure that is not a whole number reads 0 (and a
/// negative one 0, since nothing is taken at a welcome), a list that is not a
/// list reads empty, and an entry that is not an object is skipped — so a
/// broken block says less rather than failing the sign-in.
class WelcomeGrant {
  const WelcomeGrant({
    this.chips = 0,
    this.diamonds = 0,
    this.hammers = 0,
    this.missiles = 0,
    this.pictures = const [],
    this.tablePictures = const [],
    this.emojis = const [],
  });

  final int chips;
  final int diamonds;
  final int hammers;
  final int missiles;
  final List<ProfilePicture> pictures;
  final List<TablePicture> tablePictures;
  final List<EmojiItem> emojis;

  /// Whether nothing at all was granted.
  bool get isEmpty =>
      chips == 0 &&
      diamonds == 0 &&
      hammers == 0 &&
      missiles == 0 &&
      pictures.isEmpty &&
      tablePictures.isEmpty &&
      emojis.isEmpty;

  /// The login's `welcome`, or null when there is none — a returning
  /// account, or a server from before the welcome grant. Anything but an
  /// object is none.
  static WelcomeGrant? fromJson(Object? json) {
    if (json is! Map) return null;
    int count(Object? v) => v is num && v > 0 ? v.toInt() : 0;
    List<T> rows<T>(Object? v, T Function(Map<String, dynamic>) parse) => [
      if (v is List)
        for (final e in v)
          if (e is Map) parse(Map<String, dynamic>.from(e)),
    ];
    return WelcomeGrant(
      chips: count(json['chips']),
      diamonds: count(json['diamonds']),
      hammers: count(json['hammers']),
      missiles: count(json['missiles']),
      pictures: rows(json['pictures'], ProfilePicture.fromJson),
      tablePictures: rows(json['tablePictures'], TablePicture.fromJson),
      emojis: rows(json['emojis'], EmojiItem.fromJson),
    );
  }
}

/// The prize kinds a Lucky Draw slot can hold (owner, 24 Sep 2026), as the
/// server names them. A kind this build does not know is never sent: the
/// server leaves such a slot off the wheel, so the client only has to draw
/// these.
class LuckyReward {
  static const String chips = 'CHIPS';
  static const String diamond = 'DIAMOND';
  static const String hammer = 'HAMMER';
  static const String missile = 'MISSILE';
  static const String profilePicture = 'PROFILE_PICTURE';
  static const String tablePicture = 'TABLE_PICTURE';

  /// The empty slot: a spin that lands on it wins nothing.
  static const String none = 'NO_REWARD';
}

/// What a Lucky Draw slot pays, or what a spin won: a kind, an amount for the
/// four wallets, and the catalogue row for a picture — the same row the store
/// shows, `owned` resolved for this player.
class LuckyPrize {
  const LuckyPrize({
    required this.type,
    this.value,
    this.refId,
    this.picture,
    this.tablePicture,
  });

  /// One of [LuckyReward].
  final String type;

  /// The amount for CHIPS, DIAMOND, HAMMER and MISSILE; null for a picture.
  final int? value;

  /// The catalogue id of a picture prize, as text.
  final String? refId;
  final ProfilePicture? picture;
  final TablePicture? tablePicture;

  bool get isNothing => type == LuckyReward.none;
  bool get isPicture =>
      type == LuckyReward.profilePicture || type == LuckyReward.tablePicture;

  /// The amount, 0 where the prize has none.
  int get amount => value ?? 0;

  /// The picture's name, for a picture prize.
  String get pictureName => picture?.name ?? tablePicture?.name ?? '';

  factory LuckyPrize.fromJson(
    Map<String, dynamic> j, {
    String typeKey = 'type',
    String valueKey = 'value',
    String refKey = 'refId',
  }) => LuckyPrize(
    type: _str(j[typeKey]),
    value: _intOrNull(j[valueKey]),
    refId: _strOrNull(j[refKey]),
    picture: j['picture'] is Map
        ? ProfilePicture.fromJson(
            Map<String, dynamic>.from(j['picture'] as Map),
          )
        : null,
    tablePicture: j['tablePicture'] is Map
        ? TablePicture.fromJson(
            Map<String, dynamic>.from(j['tablePicture'] as Map),
          )
        : null,
  );
}

/// One slot of the wheel, in wheel order (GET /api/lucky-draw). How likely it
/// is never reaches the client: the server draws.
class LuckySlot {
  const LuckySlot({required this.slotNumber, required this.prize});

  /// 1 to 6; slot 1 is the wedge at the top when the wheel is at rest.
  final int slotNumber;
  final LuckyPrize prize;

  factory LuckySlot.fromJson(Map<String, dynamic> j) => LuckySlot(
    slotNumber: _int(j['slotNumber']),
    prize: LuckyPrize.fromJson(
      j,
      typeKey: 'rewardType',
      valueKey: 'rewardValue',
      refKey: 'rewardRefId',
    ),
  );
}

/// The Lucky Draw as this player finds it (owner, 24 Sep 2026): which draw,
/// its six slots, and when they may next spin.
class LuckyDrawState {
  const LuckyDrawState({
    required this.code,
    required this.name,
    required this.spinnerType,
    required this.cooldownMs,
    required this.slots,
    required this.nextSpinAt,
  });

  /// BEGINNER_LUCKY_DRAW today; the draw a spin is made on.
  final String code;

  /// The owner's name for it. The screen names it in the player's language
  /// ("Lucky Draw") and shows this only as the draw's own label.
  final String name;

  /// BEGINNER, VIP… — a label for how the wheel may one day be dressed.
  final String spinnerType;
  final int cooldownMs;
  final List<LuckySlot> slots;

  /// Epoch ms the next spin is allowed; 0 = now. The server enforces it.
  final int nextSpinAt;

  /// Whether a spin is due by the phone's clock. The server has the last word.
  bool readyAt(DateTime now) => nextSpinAt <= now.millisecondsSinceEpoch;

  Duration untilNext(DateTime now) {
    final ms = nextSpinAt - now.millisecondsSinceEpoch;
    return Duration(milliseconds: ms < 0 ? 0 : ms);
  }

  /// The slot numbered [slotNumber], or null when the wheel has none.
  LuckySlot? slot(int slotNumber) {
    for (final s in slots) {
      if (s.slotNumber == slotNumber) return s;
    }
    return null;
  }

  /// The same draw with a new wait, as a spin or a refusal reports it.
  LuckyDrawState withNextSpinAt(int at) => LuckyDrawState(
    code: code,
    name: name,
    spinnerType: spinnerType,
    cooldownMs: cooldownMs,
    slots: slots,
    nextSpinAt: at,
  );

  factory LuckyDrawState.fromJson(Map<String, dynamic> j) {
    final draw = j['draw'] is Map
        ? Map<String, dynamic>.from(j['draw'] as Map)
        : const <String, dynamic>{};
    final slots =
        (j['slots'] is List ? j['slots'] as List : const [])
            .whereType<Map>()
            .map((e) => LuckySlot.fromJson(Map<String, dynamic>.from(e)))
            .where((s) => s.slotNumber >= 1 && s.slotNumber <= 6)
            .toList()
          ..sort((a, b) => a.slotNumber.compareTo(b.slotNumber));
    return LuckyDrawState(
      code: _str(draw['code']),
      name: _str(draw['name']),
      spinnerType: _str(draw['spinnerType']),
      cooldownMs: _int(draw['cooldownMs']),
      slots: slots,
      nextSpinAt: _int(j['nextSpinAt']),
    );
  }
}

/// What one spin drew (POST /api/lucky-draw/spin): the slot the wheel must
/// stop on, the prize, and the account after it.
class LuckySpin {
  const LuckySpin({
    required this.actionId,
    required this.slotNumber,
    required this.prize,
    required this.alreadyOwned,
    required this.replayed,
    required this.nextSpinAt,
    this.user,
  });

  final String actionId;

  /// The server's draw. The wheel stops here and nowhere else.
  final int slotNumber;
  final LuckyPrize prize;

  /// A picture the player already had: the spin counted, nothing new was
  /// unlocked.
  final bool alreadyOwned;

  /// A retry of a spin that had already landed: the same answer again.
  final bool replayed;
  final int nextSpinAt;
  final User? user;

  factory LuckySpin.fromJson(Map<String, dynamic> j) => LuckySpin(
    actionId: _str(j['actionId']),
    slotNumber: _int(j['slotNumber']),
    prize: j['reward'] is Map
        ? LuckyPrize.fromJson(Map<String, dynamic>.from(j['reward'] as Map))
        : const LuckyPrize(type: LuckyReward.none),
    alreadyOwned: j['alreadyOwned'] == true,
    replayed: j['replayed'] == true,
    nextSpinAt: _int(j['nextSpinAt']),
    user: j['user'] is Map
        ? User.fromJson(Map<String, dynamic>.from(j['user'] as Map))
        : null,
  );
}

// ---------------------------------------------------------- reward programs
//
// The reward programs (owner, 30 Sep 2026): login streaks and calendar
// rewards, weekly and monthly, in ONE shape (GET /api/reward-programs, POST
// /api/reward-programs/claim). The SERVER works out every period, every day
// and every reward, and grants once a day a program; the app draws what it
// is told and never decides a day itself.

/// A program's mode: what its day numbers mean.
class RewardMode {
  /// The day number is the consecutive login day — Mon Day 1, Tue Day 2, Wed
  /// missed, Thu Day 1 again.
  static const loginStreak = 'LOGIN_STREAK';

  /// The day number is the day's place in the week or month — Mon Day 1, Tue
  /// Day 2, Wed missed, Thu Day 4.
  static const calendar = 'CALENDAR';
}

/// A program's period: a calendar week, or a calendar month.
class RewardPeriod {
  static const weekly = 'WEEKLY';
  static const monthly = 'MONTHLY';
}

/// How a program goes on past a missed day (owner, 1 Oct 2026: "mode = WHAT
/// triggers progress, progression_type = HOW progress behaves"). An older
/// server sends none, and [RewardProgramInfo.progression] reads it from what
/// that server does send.
class RewardProgression {
  /// A missed day sends the run back to Day 1 — the classic login streak.
  static const reset = 'RESET';

  /// A missed day costs nothing: a login program's next claim is the next
  /// unclaimed day, and a calendar's missed date is simply missed while the
  /// rest still wait — the calendar of 30 Sep 2026.
  static const sequential = 'SEQUENTIAL';

  /// A missed required day ends the cycle: nothing more can be claimed until
  /// the next period starts. (`break` is a word Dart keeps for itself.)
  static const breaks = 'BREAK';

  static const values = {reset, sequential, breaks};
}

/// Where a player stands in a program's current period (`status`).
class RewardStatus {
  /// The cycle runs: a day can be collected today, or was.
  static const active = 'ACTIVE';

  /// Every day of the cycle has been collected.
  static const completed = 'COMPLETED';

  /// A BREAK program's required day was missed: nothing more until the next
  /// period.
  static const broken = 'BROKEN';

  static const values = {active, completed, broken};
}

/// A day's standing as the server judges it (`rewards[].state`): the app
/// draws it and never works it out.
class RewardDayState {
  static const claimed = 'CLAIMED';

  /// Can be collected right now.
  static const available = 'AVAILABLE';

  /// A day that was required and not claimed — on a BROKEN cycle, the day
  /// that broke it.
  static const missed = 'MISSED';

  /// Not reached yet, or no longer reachable.
  static const locked = 'LOCKED';

  static const values = {claimed, available, missed, locked};
}

/// What one claim did for one program (`results[].outcome`).
class RewardOutcome {
  static const granted = 'GRANTED';

  /// Today was collected already: the claim it made is carried.
  static const alreadyClaimed = 'ALREADY_CLAIMED';
  static const broken = 'BROKEN';
  static const completed = 'COMPLETED';
}

/// The clock the reward programs are counted on — when an answer arrived,
/// and how long until the next period starts: [DateTime.now]; a test sets
/// its own (the fake clock its pumps advance).
DateTime Function() rewardClock = DateTime.now;

/// [v] when it is one of [values]; null for anything else, so a word this
/// build has never heard of reads as nothing rather than as a guess.
String? _oneOf(dynamic v, Set<String> values) =>
    v is String && values.contains(v) ? v : null;

/// A date the server wrote in a program's own zone, "2026-10-05", as that
/// calendar date at UTC midnight — for labels only; null for anything else.
DateTime? rewardCivilDate(String text) {
  final parts = text.split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  final date = DateTime.utc(y, m, d);
  // "2026-02-31" is no date: DateTime would roll it into March.
  return date.month == m && date.day == d ? date : null;
}

/// A period as the server dates it (`period`): its bounds, and its first
/// and last dates in the program's own zone — labels only; the app does no
/// zone arithmetic.
class RewardCycle {
  const RewardCycle({
    this.startAt = 0,
    this.endAt = 0,
    required this.startDate,
    required this.endDate,
  });

  /// Epoch ms; [endAt] is exclusive — the next period's start.
  final int startAt;
  final int endAt;

  /// "2026-10-05" and "2026-10-11": the period's first and LAST day.
  final String startDate;
  final String endDate;

  DateTime? get firstDay => rewardCivilDate(startDate);
  DateTime? get lastDay => rewardCivilDate(endDate);

  /// The wire's `period`; null for anything that does not name both dates.
  static RewardCycle? fromJson(Object? j) {
    if (j is! Map) return null;
    final cycle = RewardCycle(
      startAt: _int(j['startAt']),
      endAt: _int(j['endAt']),
      startDate: _str(j['startDate']),
      endDate: _str(j['endDate']),
    );
    return cycle.firstDay == null || cycle.lastDay == null ? null : cycle;
  }
}

/// The period after this one (`nextPeriod`): when it starts, and how long
/// until then — counted from the moment the answer arrived on this phone,
/// never from the phone's own clock against [startAt].
class RewardNextCycle {
  const RewardNextCycle({
    this.startAt = 0,
    required this.startDate,
    this.startsInMs,
    required this.receivedAt,
  });

  /// Epoch ms, on the server's clock.
  final int startAt;

  /// "2026-10-12", in the program's own zone.
  final String startDate;

  /// How long until it starts, as the server counted it when it answered;
  /// null when it said nothing that can be counted.
  final int? startsInMs;

  /// When the answer arrived, on [rewardClock].
  final DateTime receivedAt;

  DateTime? get firstDay => rewardCivilDate(startDate);

  /// When it starts on this phone's clock: the server's wait added to the
  /// moment its answer arrived, so a phone whose clock is wrong still counts
  /// to the server's moment. Null when there is nothing to count.
  DateTime? get startsAt {
    final ms = startsInMs;
    return ms == null ? null : receivedAt.add(Duration(milliseconds: ms));
  }

  /// How long until it starts at [now] — zero once it has — or null when
  /// there is nothing to count.
  Duration? leftAt(DateTime now) {
    final at = startsAt;
    if (at == null) return null;
    final left = at.difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// The wire's `nextPeriod`; null for anything else (a campaign that ends
  /// before it). [serverTime] — the answer's own `serverTime` — counts the
  /// wait from `startAt` where the server sent no `startsInMs`.
  static RewardNextCycle? fromJson(
    Object? j, {
    required DateTime receivedAt,
    int serverTime = 0,
  }) {
    if (j is! Map) return null;
    final startAt = _int(j['startAt']);
    final wait = j['startsInMs'];
    return RewardNextCycle(
      startAt: startAt,
      startDate: _str(j['startDate']),
      startsInMs: wait is num
          ? wait.toInt()
          : serverTime > 0 && startAt > 0
          ? startAt - serverTime
          : null,
      receivedAt: receivedAt,
    );
  }
}

/// What a day gives (reward_program_rewards.reward_type): the Lucky Draw's
/// kinds, an emoji and a badge. A kind this build does not know is drawn as
/// a plain gift.
class RewardKind {
  static const chips = 'CHIPS';
  static const hammer = 'HAMMER';
  static const diamond = 'DIAMOND';
  static const missile = 'MISSILE';
  static const emoji = 'EMOJI';
  static const profilePicture = 'PROFILE_PICTURE';
  static const tablePicture = 'TABLE_PICTURE';
  static const badge = 'BADGE';
  static const none = 'NO_REWARD';
}

/// A badge as a reward names it, and whether this player holds it now.
class RewardBadge {
  const RewardBadge({
    required this.code,
    required this.title,
    this.icon = '',
    this.validityDays = 0,
    this.assetUrl = '',
    this.assetFormat = '',
    this.held = false,
    this.expiresAt = 0,
  });

  final String code;
  final String title;
  final String icon;

  /// How many days a grant of it lasts; 0 for ever.
  final int validityDays;
  final String assetUrl;
  final String assetFormat;

  /// Whether this player holds it now, and until when (epoch ms; 0 for ever).
  final bool held;
  final int expiresAt;

  factory RewardBadge.fromJson(Map<String, dynamic> j) => RewardBadge(
    code: _str(j['code']),
    title: _str(j['title']),
    icon: _str(j['icon']),
    validityDays: _int(j['validityDays']),
    assetUrl: _str(j['assetUrl']),
    assetFormat: _str(j['assetFormat']),
    held: j['held'] == true,
    expiresAt: _int(j['expiresAt']),
  );
}

/// One reward: its kind, an amount for a wallet, or the catalogue item — the
/// row exactly as its catalogue route serves it, so the app draws it with
/// the loaders it already has.
class RewardPrize {
  const RewardPrize({
    required this.kind,
    this.value,
    this.refId,
    this.picture,
    this.tablePicture,
    this.emoji,
    this.badge,
  });

  /// One of [RewardKind].
  final String kind;

  /// The amount of a wallet reward; null for an item.
  final int? value;

  /// The catalogue id of an item, as text (a badge's code).
  final String? refId;
  final ProfilePicture? picture;
  final TablePicture? tablePicture;
  final EmojiItem? emoji;
  final RewardBadge? badge;

  bool get isNothing => kind == RewardKind.none;
  bool get isWallet =>
      kind == RewardKind.chips ||
      kind == RewardKind.hammer ||
      kind == RewardKind.diamond ||
      kind == RewardKind.missile;
  bool get isItem =>
      kind == RewardKind.emoji ||
      kind == RewardKind.profilePicture ||
      kind == RewardKind.tablePicture ||
      kind == RewardKind.badge;

  /// The amount, 0 where the reward has none.
  int get amount => value ?? 0;

  /// The item's name, for an item reward.
  String get itemName =>
      emoji?.name ?? picture?.name ?? tablePicture?.name ?? badge?.title ?? '';

  factory RewardPrize.fromJson(Map<String, dynamic> j) => RewardPrize(
    kind: _str(j['rewardType']),
    value: _intOrNull(j['rewardValue']),
    refId: _strOrNull(j['rewardRefId']),
    picture: j['picture'] is Map
        ? ProfilePicture.fromJson(
            Map<String, dynamic>.from(j['picture'] as Map),
          )
        : null,
    tablePicture: j['tablePicture'] is Map
        ? TablePicture.fromJson(
            Map<String, dynamic>.from(j['tablePicture'] as Map),
          )
        : null,
    emoji: j['emoji'] is Map
        ? EmojiItem.fromJson(Map<String, dynamic>.from(j['emoji'] as Map))
        : null,
    badge: j['badge'] is Map
        ? RewardBadge.fromJson(Map<String, dynamic>.from(j['badge'] as Map))
        : null,
  );
}

/// One day of a program that carries a reward, and whether this player has
/// claimed it in the current period. For a login streak `claimed` marks the
/// days of the CURRENT run, not the history.
class RewardDay {
  const RewardDay({
    required this.day,
    required this.prize,
    required this.claimed,
    this.state,
  });

  final int day;
  final RewardPrize prize;
  final bool claimed;

  /// The server's verdict on the day ([RewardDayState]), or null from a
  /// server that sends none — then the screen reads the day from the
  /// program's figures, as it always did.
  final String? state;

  factory RewardDay.fromJson(Map<String, dynamic> j) => RewardDay(
    day: _int(j['day']),
    prize: RewardPrize.fromJson(j),
    claimed: j['claimed'] == true,
    state: _oneOf(j['state'], RewardDayState.values),
  );
}

/// A program as the server describes it, with the period it is in now.
class RewardProgramInfo {
  const RewardProgramInfo({
    required this.id,
    required this.code,
    required this.name,
    required this.mode,
    required this.periodType,
    this.timezone = 'UTC',
    this.weekStartDay = 1,
    this.resetOnMissedDay = false,
    this.progressionType = '',
    this.startsAt,
    this.endsAt,
    this.periodStart = 0,
    this.periodEnd = 0,
  });

  final int id;

  /// WEEKLY_LOGIN, MONTHLY_CALENDAR, DECEMBER_2026 … — what the app names
  /// the four it knows by; the server's [name] for any other.
  final String code;
  final String name;

  /// One of [RewardMode].
  final String mode;

  /// One of [RewardPeriod].
  final String periodType;
  final String timezone;

  /// 1 Monday … 7 Sunday; a weekly program's first day.
  final int weekStartDay;
  final bool resetOnMissedDay;

  /// The server's `progressionType` ([RewardProgression]) as sent; empty from
  /// a server that sends none. [progression] is what the program goes by.
  final String progressionType;

  /// A campaign's window (epoch ms); null on a recurring program.
  final int? startsAt;
  final int? endsAt;

  /// The current period's bounds, epoch ms.
  final int periodStart;
  final int periodEnd;

  bool get isStreak => mode == RewardMode.loginStreak;
  bool get isWeekly => periodType == RewardPeriod.weekly;

  /// What a missed day does here ([RewardProgression]): the server's word,
  /// or — from a server that sends none — RESET where a missed day reset the
  /// run, SEQUENTIAL otherwise (a calendar's SEQUENTIAL is the calendar it
  /// always was: a missed date missed, the rest still waiting).
  String get progression => RewardProgression.values.contains(progressionType)
      ? progressionType
      : resetOnMissedDay
      ? RewardProgression.reset
      : RewardProgression.sequential;

  factory RewardProgramInfo.fromJson(Map<String, dynamic> j) =>
      RewardProgramInfo(
        id: _int(j['id']),
        code: _str(j['code']),
        name: _str(j['name']),
        mode: _str(j['mode']),
        periodType: _str(j['periodType']),
        timezone: _str(j['timezone']).isEmpty ? 'UTC' : _str(j['timezone']),
        weekStartDay: _int(j['weekStartDay']).clamp(1, 7),
        resetOnMissedDay: j['resetOnMissedDay'] == true,
        progressionType: _str(j['progressionType']),
        startsAt: _intOrNull(j['startsAt']),
        endsAt: _intOrNull(j['endsAt']),
        periodStart: _int(j['periodStart']),
        periodEnd: _int(j['periodEnd']),
      );
}

/// One program as it stands for this player.
class RewardProgramState {
  const RewardProgramState({
    required this.program,
    required this.today,
    required this.dayOfPeriod,
    required this.periodDays,
    required this.currentDay,
    required this.claimedToday,
    required this.claimedDays,
    required this.rewards,
    this.status = RewardStatus.active,
    this.canClaim,
    this.serverNextDay,
    this.cycle,
    this.nextCycle,
    this.serverTime = 0,
  });

  final RewardProgramInfo program;

  /// Today's date in the program's zone, "2006-01-02".
  final String today;

  /// Today's place in the period: 1..7 in a week, the date in a month.
  final int dayOfPeriod;

  /// How many days the period has: 7, or the month's 28 to 31.
  final int periodDays;

  /// The day today's claim counts (or counted) as: a streak's consecutive
  /// login day, a calendar's [dayOfPeriod] — while the cycle runs. While it
  /// is BROKEN, the day that was missed ("You missed Day 3"); once it is
  /// COMPLETED, the last day.
  final int currentDay;
  final bool claimedToday;

  /// The days that count now: a streak's current run ("3 day streak"), a
  /// calendar's days claimed this period.
  final int claimedDays;

  /// The days that carry a reward, in day order.
  final List<RewardDay> rewards;

  /// Where the player stands in the cycle ([RewardStatus]): ACTIVE from a
  /// server that sends none.
  final String status;

  /// The server's verdict: a claim now would grant today's day. Null from a
  /// server that sends none — [canClaimToday] reads it then.
  final bool? canClaim;

  /// The server's `nextDay`: the day the next claim will count as — today's
  /// while one can be made, tomorrow's once today is collected and the cycle
  /// goes on — 0 for none this period. Null from a server that sends none;
  /// [nextDay] is what the screen reads.
  final int? serverNextDay;

  /// The current period's dates ("Oct 5 – Oct 11"), or null from a server
  /// that sends none.
  final RewardCycle? cycle;

  /// The next period, or null: a server that sends none, or a campaign that
  /// ends before it.
  final RewardNextCycle? nextCycle;

  /// The answer's own clock, epoch ms; 0 when it sent none.
  final int serverTime;

  bool get isActive => status == RewardStatus.active;
  bool get isBroken => status == RewardStatus.broken;
  bool get isCompleted => status == RewardStatus.completed;

  /// Whether a claim now would grant today's day: the server's word, or —
  /// from a server that says nothing of it — whether today is still to
  /// collect, as it always was. The app never works it out otherwise.
  bool get canClaimToday => canClaim ?? !claimedToday;

  /// The day a BROKEN cycle missed; 0 for any other.
  int get missedDay => isBroken ? currentDay : 0;

  RewardDay? rewardFor(int day) {
    for (final r in rewards) {
      if (r.day == day) return r;
    }
    return null;
  }

  /// Today as the program's zone has it, at UTC midnight — for the labels'
  /// calendar arithmetic only; every decision is the server's.
  DateTime get todayDate {
    final date = rewardCivilDate(today);
    if (date != null) return date;
    final now = DateTime.now().toUtc();
    return DateTime.utc(now.year, now.month, now.day);
  }

  /// The date day [k] stands for: for a streak, the day the run reaches (or
  /// reached) it, counted from today's [currentDay]; for a calendar, the
  /// date at that place in the period.
  DateTime dateOfDay(int k) {
    final offset = program.isStreak ? k - currentDay : k - dayOfPeriod;
    return todayDate.add(Duration(days: offset));
  }

  /// The ISO weekday (1 Monday … 7 Sunday) of day [k].
  int weekdayOfDay(int k) => dateOfDay(k).weekday;

  /// The next day the player can earn — the server's `nextDay` where it
  /// sends one (none once a cycle is broken, completed or over); else
  /// today's while it is unclaimed, tomorrow's once collected — or null past
  /// the period's end.
  int? get nextDay {
    final server = serverNextDay;
    if (server != null) return server >= 1 ? server : null;
    final next = program.isStreak
        ? (claimedToday ? currentDay + 1 : currentDay)
        : (claimedToday ? dayOfPeriod + 1 : dayOfPeriod);
    return next < 1 || next > periodDays ? null : next;
  }

  RewardDay? get nextReward {
    final next = nextDay;
    return next == null ? null : rewardFor(next);
  }

  /// One program off the wire. [receivedAt] is when its answer arrived (on
  /// [rewardClock] by default) and [serverTime] that answer's own clock —
  /// what the next period's countdown is counted from.
  factory RewardProgramState.fromJson(
    Map<String, dynamic> j, {
    DateTime? receivedAt,
    int serverTime = 0,
  }) {
    final rewards =
        (j['rewards'] is List ? j['rewards'] as List : const [])
            .whereType<Map>()
            .map((e) => RewardDay.fromJson(Map<String, dynamic>.from(e)))
            .where((d) => d.day >= 1)
            .toList()
          ..sort((a, b) => a.day.compareTo(b.day));
    final canClaim = j['canClaim'];
    final nextDay = j['nextDay'];
    return RewardProgramState(
      program: RewardProgramInfo.fromJson(
        j['program'] is Map
            ? Map<String, dynamic>.from(j['program'] as Map)
            : const <String, dynamic>{},
      ),
      today: _str(j['today']),
      dayOfPeriod: _int(j['dayOfPeriod']),
      periodDays: _int(j['periodDays']),
      currentDay: _int(j['currentDay']),
      claimedToday: j['claimedToday'] == true,
      claimedDays: _int(j['claimedDays']),
      rewards: rewards,
      status: _oneOf(j['status'], RewardStatus.values) ?? RewardStatus.active,
      canClaim: canClaim is bool ? canClaim : null,
      serverNextDay: nextDay is num ? nextDay.toInt() : null,
      cycle: RewardCycle.fromJson(j['period']),
      nextCycle: RewardNextCycle.fromJson(
        j['nextPeriod'],
        receivedAt: receivedAt ?? rewardClock(),
        serverTime: serverTime,
      ),
      serverTime: serverTime,
    );
  }
}

/// A reward one claim gave (POST /api/reward-programs/claim's `granted`).
class RewardGrant {
  const RewardGrant({
    required this.programCode,
    required this.programName,
    required this.mode,
    required this.periodType,
    required this.day,
    required this.prize,
    this.alreadyOwned = false,
    this.claimedAt = 0,
  });

  final String programCode;
  final String programName;
  final String mode;
  final String periodType;
  final int day;
  final RewardPrize prize;

  /// An item the player already had: the day is claimed, nothing more was
  /// given.
  final bool alreadyOwned;
  final int claimedAt;

  factory RewardGrant.fromJson(Map<String, dynamic> j) => RewardGrant(
    programCode: _str(j['programCode']),
    programName: _str(j['programName']),
    mode: _str(j['mode']),
    periodType: _str(j['periodType']),
    day: _int(j['day']),
    prize: RewardPrize.fromJson(j),
    alreadyOwned: j['alreadyOwned'] == true,
    claimedAt: _int(j['claimedAt']),
  );
}

/// What one claim did for one program (`results[]`): granted today's day,
/// found it already collected (the claim made then is carried), or nothing —
/// the cycle broken, or completed.
class RewardClaimOutcome {
  const RewardClaimOutcome({
    required this.programCode,
    required this.outcome,
    this.day = 0,
    this.prize,
    this.claimedAt = 0,
  });

  final String programCode;

  /// One of [RewardOutcome]; a word this build does not know is kept as sent.
  final String outcome;

  /// The day claimed, 0 where none was.
  final int day;

  /// What that day gives, where the server named it.
  final RewardPrize? prize;
  final int claimedAt;

  factory RewardClaimOutcome.fromJson(Map<String, dynamic> j) =>
      RewardClaimOutcome(
        programCode: _str(j['programCode']),
        outcome: _str(j['outcome']),
        day: _int(j['day']),
        prize: _str(j['rewardType']).isEmpty ? null : RewardPrize.fromJson(j),
        claimedAt: _int(j['claimedAt']),
      );
}

/// What one claim did: what it gave, every program after, the account after.
class RewardClaimResult {
  const RewardClaimResult({
    required this.granted,
    required this.programs,
    this.user,
    this.results = const [],
    this.serverTime = 0,
  });

  /// What THIS call gave — empty on a replay: what to celebrate.
  final List<RewardGrant> granted;
  final List<RewardProgramState> programs;
  final User? user;

  /// What the claim did for each program it asked of; empty from a server
  /// that sends none.
  final List<RewardClaimOutcome> results;

  /// The answer's own clock, epoch ms; 0 when it sent none.
  final int serverTime;

  /// The claim's answer; [receivedAt] is when it arrived ([rewardClock] by
  /// default).
  factory RewardClaimResult.fromJson(
    Map<String, dynamic> j, {
    DateTime? receivedAt,
  }) => RewardClaimResult(
    granted: (j['granted'] is List ? j['granted'] as List : const [])
        .whereType<Map>()
        .map((e) => RewardGrant.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    programs: rewardProgramsFromJson(
      j['programs'],
      serverTime: j['serverTime'],
      receivedAt: receivedAt,
    ),
    user: j['user'] is Map
        ? User.fromJson(Map<String, dynamic>.from(j['user'] as Map))
        : null,
    results: (j['results'] is List ? j['results'] as List : const [])
        .whereType<Map>()
        .map((e) => RewardClaimOutcome.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    serverTime: _int(j['serverTime']),
  );
}

/// The programs of GET /api/reward-programs or a claim's answer.
/// [serverTime] is the answer's own `serverTime`; [receivedAt] when it
/// arrived on this phone ([rewardClock] by default) — the next period's
/// countdown is counted from that moment.
List<RewardProgramState> rewardProgramsFromJson(
  Object? programs, {
  Object? serverTime,
  DateTime? receivedAt,
}) {
  final at = receivedAt ?? rewardClock();
  final server = _int(serverTime);
  return (programs is List ? programs : const [])
      .whereType<Map>()
      .map(
        (e) => RewardProgramState.fromJson(
          Map<String, dynamic>.from(e),
          receivedAt: at,
          serverTime: server,
        ),
      )
      .toList();
}
