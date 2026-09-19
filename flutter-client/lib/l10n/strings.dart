import 'package:flutter/widgets.dart';

/// The languages the game offers.
///
/// Teen Patti's own vocabulary — chaal, blind, seen, boot, pack, show — is
/// carried across all of them rather than translated. Those words are the game,
/// and players use them in every one of these languages.
enum AppLang {
  english('en', 'English', 'English'),
  hindi('hi', 'Hindi', 'हिन्दी'),
  bengali('bn', 'Bengali', 'বাংলা'),
  gujarati('gu', 'Gujarati', 'ગુજરાતી'),
  punjabi('pa', 'Punjabi', 'ਪੰਜਾਬੀ');

  const AppLang(this.code, this.englishName, this.nativeName);

  final String code;
  final String englishName;

  /// What the language calls itself, which is what a picker should show.
  final String nativeName;

  Locale get locale => Locale(code);

  static AppLang fromCode(String? code) => AppLang.values.firstWhere(
    (l) => l.code == code,
    orElse: () => AppLang.english,
  );
}

/// Every string the interface shows.
///
/// A plain map rather than generated ARB files: there is no build step to keep
/// in sync, and the whole vocabulary of the game is small enough to read in one
/// place. Anything missing from a translation falls back to English rather than
/// showing a key.
class Strings {
  const Strings(this.lang);

  final AppLang lang;

  String _(String key) => _table[lang.code]?[key] ?? _table['en']![key] ?? key;

  /// This language's own entry for [key], or null where [_] would fall back
  /// to English. For tests that a new word really was translated: the
  /// fallback otherwise hides a missing one behind the English.
  @visibleForTesting
  String? ownEntry(String key) => _table[lang.code]?[key];

  // --- login
  String get signInSubtitle => _('signInSubtitle');
  String get displayName => _('displayName');
  String get playerHint => _('playerHint');
  String get playAsGuest => _('playAsGuest');
  String get signingIn => _('signingIn');
  String get continueGoogle => _('continueGoogle');
  String get continueFacebook => _('continueFacebook');

  /// Opens the published privacy policy. Google's User Data policy wants
  /// this reachable from inside the app, not only from the store listing.
  String get privacyPolicy => _('privacyPolicy');

  /// Shown when a provider button is tapped in a build that carries no
  /// credentials for it. `{provider}` is substituted with 'Google'/'Facebook'.
  String signInUnavailable(String provider) =>
      _('signInUnavailable').replaceAll('{provider}', provider);

  // --- lobby
  String get boot => _('boot');

  // --- what a lobby card says about the room behind it
  String get maxBlindsLabel => _('maxBlindsLabel');
  String get potLimitLabel => _('potLimitLabel');
  String get potUnlimited => _('potUnlimited');
  String get tapToSit => _('tapToSit');
  String get everyoneChips => _('everyoneChips');
  String get onlyYourChips => _('onlyYourChips');
  String get seen => _('seen');
  String get blind => _('blind');
  String get privateTable => _('privateTable');
  String get create => _('create');
  String get orJoinCode => _('orJoinCode');
  String get tableCode => _('tableCode');
  String get invalidTableCode => _('invalidTableCode');
  String get join => _('join');
  String get yourPicture => _('yourPicture');
  String get yourRecord => _('yourRecord');
  String get handsPlayed => _('handsPlayed');
  String get won => _('won');
  String get lost => _('lost');
  String get leftMidHand => _('leftMidHand');
  String get totalWinnings => _('totalWinnings');
  String get biggestPot => _('biggestPot');
  String get playedNote => _('playedNote');
  String get fourHourBonus => _('fourHourBonus');
  String get dailyBonus => _('dailyBonus');
  String get milestone => _('milestone');
  String get collect => _('collect');

  // --- collecting a reward
  String get rewardCollected => _('rewardCollected');
  String get rewardComeBack => _('rewardComeBack');
  String get rewardComeBackDaily => _('rewardComeBackDaily');

  // --- a bonus tapped while it is still counting down
  String get bonusYouGet => _('bonusYouGet');
  String get bonusNextIn => _('bonusNextIn');
  String get bonusReadyNow => _('bonusReadyNow');
  String get bonusEveryFourHours => _('bonusEveryFourHours');
  String get bonusEveryDay => _('bonusEveryDay');
  String get rewardMilestoneAgain => _('rewardMilestoneAgain');
  String get rewardRefused => _('rewardRefused');
  String get rewardPurchased => _('rewardPurchased');
  String get rewardDiamondsPurchased => _('rewardDiamondsPurchased');
  String get rewardHammersPurchased => _('rewardHammersPurchased');
  String get tapToClose => _('tapToClose');

  // --- buying chips, not open yet
  String get buyChips => _('buyChips');

  /// The top bar's shop button.
  String get shop => _('shop');
  String get comingSoon => _('comingSoon');

  // --- the chip store
  String get storeTitle => _('storeTitle');
  String get storeBlurb => _('storeBlurb');
  String get storeTabChips => _('storeTabChips');
  String get storeTabPictures => _('storeTabPictures');
  String get storeTabAnimated => _('storeTabAnimated');
  String get storePicturesBlurb => _('storePicturesBlurb');

  /// The Pictures tab's blurb at a table, where the key sells the animated
  /// shelf alone and every picture on it is paid for in hammers (owner,
  /// 14 Sep 2026; they were diamonds before).
  String get storeAnimatedBlurb => _('storeAnimatedBlurb');
  String get storeTabDiamonds => _('storeTabDiamonds');
  String get storeDiamondsTitle => _('storeDiamondsTitle');
  String get storeDiamondsBlurb => _('storeDiamondsBlurb');
  String get storeTabHammers => _('storeTabHammers');
  String get storeHammersTitle => _('storeHammersTitle');
  String get storeHammersBlurb => _('storeHammersBlurb');
  String get storeBonus => _('storeBonus');
  String get storeNotLive => _('storeNotLive');
  String get posStarter => _('posStarter');
  String get posPopular => _('posPopular');
  String get posBestValue => _('posBestValue');
  String get posPremium => _('posPremium');
  String get comingSoonBody => _('comingSoonBody');
  String get handsToGo => _('handsToGo');
  String get handToGo => _('handToGo');
  String get forceSideshowTooLate => _('forceSideshowTooLate');
  String get settings => _('settings');
  String get language => _('language');

  // --- requirement 34: lakh/crore or million/billion
  String get numberSystem => _('numberSystem');
  String get numberIndian => _('numberIndian');
  String get numberInternational => _('numberInternational');
  String get unitLakh => _('unitLakh');
  String get unitCrore => _('unitCrore');
  String get unitMillion => _('unitMillion');
  String get unitBillion => _('unitBillion');
  String get switchTheme => _('switchTheme');
  String get signOut => _('signOut');
  String get signOutQ => _('signOutQ');
  String get signOutBody => _('signOutBody');
  String get providerGuest => _('providerGuest');
  String get unitHourShort => _('unitHourShort');
  String get unitMinuteShort => _('unitMinuteShort');
  String get unitSecondShort => _('unitSecondShort');
  String get serviceUnavailable => _('serviceUnavailable');
  String get soundLabel => _('soundLabel');
  String get vibrationLabel => _('vibrationLabel');
  String get useProviderPicture => _('useProviderPicture');

  /// The picture picker's line under "Your picture". A worn picture can be
  /// changed at a table since 13 Sep 2026, so it says so rather than warning
  /// that sitting down locks it.
  String get pictureChangeAnytime => _('pictureChangeAnytime');

  // --- table
  String get pot => _('pot');
  String get stake => _('stake');
  String get yourTurn => _('yourTurn');
  String get toAct => _('toAct');
  String get pack => _('pack');
  String get chaal => _('chaal');
  String get show => _('show');

  // --- sideshow: ask the player on your right to compare hands
  String get sideshow => _('sideshow');
  String get sideshowWith => _('sideshowWith');
  String get sideshowAsksYou => _('sideshowAsksYou');
  String get sideshowRunning => _('sideshowRunning');

  // --- variation tables: the first player picks the rules of the hand
  /// The category's name, on the lobby card and over the pot.
  String get variation => _('variation');
  String get variationTableNote => _('variationTableNote');

  /// The lobby's two levels (owner, 18 Sep 2026): the categories first, then
  /// one category's tables. [viewTables] is the category card's key, as
  /// [tapToSit] is the table card's; [tablesLabel] and [openToYouLabel] are its
  /// two facts; [backToCategories] is what the tile at the head of a
  /// category's rail is called.
  String get viewTables => _('viewTables');
  String get tablesLabel => _('tablesLabel');
  String get openToYouLabel => _('openToYouLabel');
  String get backToCategories => _('backToCategories');

  /// The rules sheet's second section (owner, 18 Sep 2026): what a variation
  /// table is, above the variations, each named and explained by
  /// [variationName] and [variationNote].
  String get variationRulesTitle => _('variationRulesTitle');
  String get variationRulesIntro => _('variationRulesIntro');

  /// A table card's info popup (owner, 18 Sep 2026: "every table give an info
  /// icon on the right top side … it tells all info"). The rows it shares with
  /// the card reuse the card's own labels ([boot], [entryLabel],
  /// [maxBlindsLabel], [potLimitLabel]).
  String get tableInfoTitle => _('tableInfoTitle');
  String get categoryLabel => _('categoryLabel');
  String get playersLabel => _('playersLabel');
  String get turnTimeLabel => _('turnTimeLabel');
  String get yourChipsLabel => _('yourChipsLabel');
  String get canSitHere => _('canSitHere');
  String playersUpTo(int n) => _('playersUpTo').replaceFirst('{n}', '$n');
  String secondsEach(int n) => _('secondsEach').replaceFirst('{n}', '$n');

  /// A table card's rules key (owner, 18 Sep 2026: "one more icon on the card;
  /// clicking it shows the rules according to the table he selected"): how THAT
  /// table plays, one sentence a rule, with the table's own figures in them.
  /// The word a table category goes by: SEEN, BLIND or VARIATION.
  String variationOrCategory(String category) => switch (category) {
    'blind' => blind,
    'variation' => variation,
    // The poker family, or one of its four games by name.
    'poker' => poker,
    'texas_holdem' ||
    'omaha' ||
    'five_card_draw' ||
    'three_card_poker' => pokerVariantName(category),
    _ => seen,
  };

  String get tableRulesTitle => _('tableRulesTitle');
  String get tableRulesKey => _('tableRulesKey');
  String ruleBlindMoves(int n) => _('ruleBlindMoves').replaceFirst('{n}', '$n');
  String get ruleRaiseOnce => _('ruleRaiseOnce');
  String get ruleRaiseFree => _('ruleRaiseFree');
  String rulePotCapped(String pot) =>
      _('rulePotCapped').replaceFirst('{pot}', pot);
  String get rulePotOpen => _('rulePotOpen');
  String get ruleRoundsEnd => _('ruleRoundsEnd');
  String get ruleShowTwo => _('ruleShowTwo');
  String get ruleVariationPick => _('ruleVariationPick');
  String get variationChooseTitle => _('variationChooseTitle');

  /// What everyone but the chooser reads in the middle of the table.
  String variationSelectingBy(String name) =>
      _('variationSelectingBy').replaceAll('{name}', name);

  /// "Variation: AK47" — [variation] is already in the player's language.
  String variationChosen(String variation) =>
      _('variationChosen').replaceAll('{variation}', variation);

  /// The server chose because nobody did (the clock, or the chooser leaving).
  String get variationAutoChosen => _('variationAutoChosen');

  /// The server chose because the chooser LEFT the table — the clock did not
  /// run out, so saying that it did would be a small lie.
  String variationLeftChosen(String name) =>
      _('variationLeftChosen').replaceAll('{name}', name);
  String get wildCard => _('wildCard');

  /// A variation's name from its wire value. An unknown one — a server newer
  /// than this build — is shown as sent rather than hidden.
  String variationName(String wire) => switch (wire) {
    'MUFLIS' => _('varMuflis'),
    'AK47' => _('varAk47'),
    'JOKER' => _('varJoker'),
    'HUKAM' => _('varHukam'),
    'LOWEST_JOKER' => _('varLowestJoker'),
    'HIGHEST_JOKER' => _('varHighestJoker'),
    'FIVE_CARD' => varFiveCard,
    _ => wire,
  };

  /// One line on what the variation changes; empty for one this build does
  /// not know.
  String variationNote(String wire) => switch (wire) {
    'MUFLIS' => _('varMuflisNote'),
    'AK47' => _('varAk47Note'),
    'JOKER' => _('varJokerNote'),
    'HUKAM' => _('varHukamNote'),
    'LOWEST_JOKER' => _('varLowestJokerNote'),
    'HIGHEST_JOKER' => _('varHighestJokerNote'),
    'FIVE_CARD' => varFiveCardNote,
    _ => '',
  };

  /// 5-Card Teen Patti (owner, 18 Sep 2026): every player holds five cards
  /// and the best three are played. The name is short because it is a picker
  /// key, one of four across on a 640dp phone; the note is its one-line rule.
  String get varFiveCard => _('varFiveCard');
  String get varFiveCardNote => _('varFiveCardNote');

  // --- the poker family (go-server/internal/poker): Texas Hold'em, Omaha,
  // 5-Card Draw and 3-Card Poker, one lobby category between them

  /// The category's name, on the lobby's front card.
  String get poker => _('poker');

  /// The front card's one line: the four games it holds.
  String get pokerTableNote => _('pokerTableNote');

  /// A poker game's name from its wire category. An unknown one — a server
  /// newer than this build — is shown as sent rather than hidden.
  String pokerVariantName(String wire) => switch (wire) {
    'texas_holdem' => _('pokerTexasHoldem'),
    'omaha' => _('pokerOmaha'),
    'five_card_draw' => _('pokerFiveCardDraw'),
    'three_card_poker' => _('pokerThreeCardPoker'),
    _ => wire,
  };

  /// One line on how that game is played; empty for one this build does not
  /// know.
  String pokerVariantNote(String wire) => switch (wire) {
    'texas_holdem' => _('pokerTexasHoldemNote'),
    'omaha' => _('pokerOmahaNote'),
    'five_card_draw' => _('pokerFiveCardDrawNote'),
    'three_card_poker' => _('pokerThreeCardPokerNote'),
    _ => '',
  };

  /// A poker table card's facts.
  String get blindsLabel => _('blindsLabel');
  String get anteLabel => _('anteLabel');
  String get buyInLabel => _('buyInLabel');
  String get holeCardsLabel => _('holeCardsLabel');
  String get maxDiscardsLabel => _('maxDiscardsLabel');
  String buyInFrom(String min) => _('buyInFrom').replaceAll('{min}', min);

  /// The keys.
  String get fold => _('fold');
  String get check => _('check');
  String get call => _('call');
  String get bet => _('bet');
  String get raise => _('raise');
  String get allIn => _('allIn');
  String get play => _('play');
  String get draw => _('draw');
  String get standPat => _('standPat');

  /// What the table says during a 5-Card Draw exchange and a 3-Card Poker
  /// decision.
  String exchangeUpTo(int n) => _('exchangeUpTo').replaceAll('{n}', '$n');
  String get playOrFold => _('playOrFold');

  /// 3-Card Poker's house hand.
  String get dealerLabel => _('dealerLabel');
  String get dealerQualifies => _('dealerQualifies');
  String get dealerNotQualified => _('dealerNotQualified');

  /// The result, for the viewer and on each pod.
  String youWon(String amount) => _('youWon').replaceAll('{amount}', amount);
  String get youLost => _('youLost');
  String get outcomeWin => _('outcomeWin');
  String get outcomeLose => _('outcomeLose');
  String get push => _('push');

  /// A 3-Card Poker outcome (`win`, `lose`, `push`) in words; empty for
  /// none.
  String pokerOutcome(String? outcome) => switch (outcome) {
    'win' => outcomeWin,
    'lose' => outcomeLose,
    'push' => push,
    _ => '',
  };

  String get potLabel => _('potLabel');
  String get sidePotLabel => _('sidePotLabel');
  String get boardLabel => _('boardLabel');

  /// A street's name for the tag over the pot; the wire value for one this
  /// build does not know, and empty between hands.
  String pokerStreetName(String street) => switch (street) {
    'preflop' => _('streetPreflop'),
    'flop' => _('streetFlop'),
    'turn' => _('streetTurn'),
    'river' => _('streetRiver'),
    'predraw' => _('streetPredraw'),
    'draw' => _('streetDraw'),
    'postdraw' => _('streetPostdraw'),
    'decision' => _('streetDecision'),
    'showdown' => _('streetShowdown'),
    _ => street,
  };

  /// Said to the player whose clock folded their hand.
  String get pokerTimedOut => _('pokerTimedOut');

  /// The rules sheet's poker section: the five-card ranking, strongest
  /// first, and the two rules that differ by game.
  String get pokerRulesTitle => _('pokerRulesTitle');
  String get pokerRulesIntro => _('pokerRulesIntro');
  String pokerRankName(String key) => switch (key) {
    'royalFlush' => _('pokerRankRoyalFlush'),
    'straightFlush' => _('pokerRankStraightFlush'),
    'fourOfAKind' => _('pokerRankFourOfAKind'),
    'fullHouse' => _('pokerRankFullHouse'),
    'flush' => _('pokerRankFlush'),
    'straight' => _('pokerRankStraight'),
    'threeOfAKind' => _('pokerRankThreeOfAKind'),
    'twoPair' => _('pokerRankTwoPair'),
    'pair' => _('pokerRankPair'),
    'highCard' => _('pokerRankHighCard'),
    _ => key,
  };
  String get pokerThreeCardRanking => _('pokerThreeCardRanking');

  /// How a poker table plays, a sentence a rule, with the table's own figures.
  String rulePokerBlinds(String small, String big) => _(
    'rulePokerBlinds',
  ).replaceAll('{small}', small).replaceAll('{big}', big);
  String rulePokerAnte(String ante) =>
      _('rulePokerAnte').replaceAll('{ante}', ante);
  String rulePokerBuyIn(String min) =>
      _('rulePokerBuyIn').replaceAll('{min}', min);
  String rulePokerHoleCards(int n) =>
      _('rulePokerHoleCards').replaceAll('{n}', '$n');
  String get rulePokerHoldemWin => _('rulePokerHoldemWin');
  String get rulePokerOmahaWin => _('rulePokerOmahaWin');
  String rulePokerDrawWin(int n) =>
      _('rulePokerDrawWin').replaceAll('{n}', '$n');
  String get rulePokerThreeCardWin => _('rulePokerThreeCardWin');
  String get rulePokerDealerQualifies => _('rulePokerDealerQualifies');
  String get rulePokerBestHandWins => _('rulePokerBestHandWins');

  /// The poker server's refusals, by code, in the player's language; null
  /// for a code this has no words for, which keeps the server's sentence.
  String? pokerRefusal(String? code) => switch (code) {
    'not_your_turn' => _('refuseNotYourTurn'),
    'invalid_action' => _('refuseInvalidAction'),
    'invalid_amount' => _('refuseInvalidAmount'),
    'invalid_discard' => _('refuseInvalidDiscard'),
    'insufficient_chips' => _('refuseInsufficientChips'),
    'no_hand' => _('refuseNoHand'),
    'not_in_hand' => _('refuseNotInHand'),
    'wrong_game' => _('refuseWrongGame'),
    'duplicate_action' => _('refuseDuplicateAction'),
    'unknown_action' => _('refuseUnknownAction'),
    _ => null,
  };
  String get accept => _('accept');
  String get decline => _('decline');
  String get sideshowDeclined => _('sideshowDeclined');
  String get sideshowTimedOut => _('sideshowTimedOut');
  String get sideshowCancelled => _('sideshowCancelled');
  String get sideshowYouLost => _('sideshowYouLost');
  String get sideshowYouWon => _('sideshowYouWon');

  // --- Force Sideshow, paid for with a hammer (owner, 13 Sep 2026)

  /// The key's own word, short enough for a key two steppers wide.
  String get force => _('force');

  /// The move's full name, for the key's tooltip.
  String get forceSideshow => _('forceSideshow');
  String get forceSideshowTitle => _('forceSideshowTitle');

  /// The confirmation. `{name}` is the player on the viewer's right.
  String forceSideshowBody(String name) =>
      _('forceSideshowBody').replaceAll('{name}', name);

  /// What the player is agreeing to, under the question.
  String get forceSideshowNote => _('forceSideshowNote');

  /// The offer of the store to a player with no hammers.
  String get noHammersTitle => _('noHammersTitle');
  String get noHammersBody => _('noHammersBody');
  String get getHammers => _('getHammers');

  /// The server's `no_hammers` refusal, in the player's language.
  String get noHammers => _('noHammers');

  /// What a Force Sideshow says at the table: to the player who forced it,
  /// to the player it was forced on, and to everyone else.
  String sideshowForcedByYou(String name) =>
      _('sideshowForcedByYou').replaceAll('{name}', name);
  String sideshowForcedOnYou(String name) =>
      _('sideshowForcedOnYou').replaceAll('{name}', name);
  String sideshowForcedOn(String from, String to) =>
      _('sideshowForcedOn').replaceAll('{from}', from).replaceAll('{to}', to);

  /// The table's wallet pill, as a screen reader says it. A single missile —
  /// what every new account holds — has its own line, so it is never read as
  /// "1 missiles".
  String walletSummary(int diamonds, int hammers, int missiles) =>
      _(missiles == 1 ? 'walletSummaryOneMissile' : 'walletSummary')
          .replaceAll('{diamonds}', '$diamonds')
          .replaceAll('{hammers}', '$hammers')
          .replaceAll('{missiles}', '$missiles');

  // --- the missile, paid for with missiles traded for diamonds (owner,
  // 14 Sep 2026)

  /// The key's word, and the move's name in its tooltip.
  String get missile => _('missile');

  /// The confirmation: its question, what it does, and the small print.
  String get fireMissileTitle => _('fireMissileTitle');
  String get fireMissileBody => _('fireMissileBody');
  String get fireMissileNote => _('fireMissileNote');

  /// The confirmation's acting key.
  String get fire => _('fire');

  /// Confirmed after the turn had already moved on: nothing was fired.
  String get missileTooLate => _('missileTooLate');

  /// The offer of the store to a player with no missiles.
  String get noMissilesTitle => _('noMissilesTitle');
  String get noMissilesBody => _('noMissilesBody');
  String get getMissiles => _('getMissiles');

  /// The server's `no_missiles` and `too_few_players` refusals.
  String get noMissiles => _('noMissiles');
  String get tooFewPlayers => _('tooFewPlayers');
  String get missileNeedsShowChips => _('missileNeedsShowChips');

  /// What a missile says at the table: to the player who fired it, and to
  /// everyone else.
  String get missileFiredByYou => _('missileFiredByYou');
  String missileFiredBy(String name) =>
      _('missileFiredBy').replaceAll('{name}', name);

  /// The store's Missiles shelf.
  String get storeTabMissiles => _('storeTabMissiles');
  String get storeMissilesTitle => _('storeMissilesTitle');
  String get storeMissilesBlurb => _('storeMissilesBlurb');

  /// Trading diamonds for a missile pack. `{s}` pluralises the English
  /// "diamond" and is absent from the other four languages, whose word does
  /// not change with the number. A pack of one missile has its own line in
  /// every language (`tradeMissileBodyOne`): Hindi and Punjabi change the
  /// noun and the verb with the number, so "1 missiles" cannot be avoided by
  /// substitution alone.
  String get tradeMissilesTitle => _('tradeMissilesTitle');
  String tradeMissilesBody(int diamonds, int missiles) =>
      _(missiles == 1 ? 'tradeMissileBodyOne' : 'tradeMissilesBody')
          .replaceAll('{diamonds}', '$diamonds')
          .replaceAll('{missiles}', '$missiles')
          .replaceAll('{s}', diamonds == 1 ? '' : 's');
  String get trade => _('trade');

  /// The offer of the Diamonds shelf to a player who cannot pay for a trade.
  String get notEnoughDiamondsTitle => _('notEnoughDiamondsTitle');
  String notEnoughDiamondsBody(int diamonds) => _('notEnoughDiamondsBody')
      .replaceAll('{diamonds}', '$diamonds')
      .replaceAll('{s}', diamonds == 1 ? '' : 's');
  String get getDiamonds => _('getDiamonds');

  /// A trade made at a table, where there is no celebration to show it. One
  /// missile has its own line (`missileAddedOne`).
  String missilesAdded(int n) =>
      _(n == 1 ? 'missileAddedOne' : 'missilesAdded').replaceAll('{n}', '$n');

  /// The celebration's line for a trade of [n] missiles made in the lobby.
  /// One missile has its own line (`rewardMissileTradedOne`).
  String rewardMissilesTraded(int n) =>
      _(n == 1 ? 'rewardMissileTradedOne' : 'rewardMissilesTraded');

  // --- Premium Packages: chips, missiles and hammers in one Play purchase
  // (owner, 14 Sep 2026)

  /// The heading over them on the Chips shelf.
  String get premiumPackages => _('premiumPackages');

  /// The plate across the top of each package's card.
  String get posPremiumPackage => _('posPremiumPackage');

  /// "+11 Missiles" under a package's chips. One missile has its own line in
  /// every language (`plusMissileOne`), so it is never "+1 Missiles".
  String plusMissiles(int n) =>
      _(n == 1 ? 'plusMissileOne' : 'plusMissiles').replaceAll('{n}', '$n');

  /// "+10 Hammers" under a package's chips. Every package holds at least ten.
  String plusHammers(int n) =>
      _(n == 1 ? 'plusHammerOne' : 'plusHammers').replaceAll('{n}', '$n');

  /// The celebration's line for a package bought in the lobby. It names the
  /// package rather than its wallets, so no word has to change with a count.
  String get rewardPremiumPurchased => _('rewardPremiumPurchased');

  /// A package bought at a table, where there is no celebration to show it.
  /// [chips] arrives already written out by `formatChips`. One missile has
  /// its own line (`premiumAddedOneMissile`).
  String premiumAdded(String chips, int missiles, int hammers) =>
      _(missiles == 1 ? 'premiumAddedOneMissile' : 'premiumAdded')
          .replaceAll('{chips}', chips)
          .replaceAll('{missiles}', '$missiles')
          .replaceAll('{hammers}', '$hammers');
  String get seeCards => _('seeCards');
  String get blindMovesLeft => _('blindMovesLeft');
  String get blindMovesLabel => _('blindMovesLabel');
  String get lastBlindMove => _('lastBlindMove');
  String get inPot => _('inPot');
  String get waiting => _('waiting');
  String get offline => _('offline');
  String get packed => _('packed');

  // --- requirement 31: auto-packs in a row, and the last warning
  String get autoPacked => _('autoPacked');
  String get autoPackedOne => _('autoPackedOne');
  String get lastWarning => _('lastWarning');
  String get missOneMore => _('missOneMore');
  String get missedTurnsLabel => _('missedTurnsLabel');
  String get resumingTable => _('resumingTable');
  String get welcomeBack => _('welcomeBack');
  String get appVersion => _('appVersion');
  String get tableLost => _('tableLost');
  String get notConnected => _('notConnected');
  String get reconnecting => _('reconnecting');
  String get kickedNoChips => _('kickedNoChips');
  String kickedIdle(int turns) => _('kickedIdle').replaceAll('{n}', '$turns');
  String get leaveStakeStays => _('leaveStakeStays');
  String get winner => _('winner');
  String get tableChat => _('tableChat');
  String get saySomething => _('saySomething');
  String get tableMenu => _('tableMenu');

  // --- quick messages: set lines a player sends from the table's rail
  String get quickMessagesTitle => _('quickMessagesTitle');
  String get quickMessagesTip => _('quickMessagesTip');
  String get quickPlayBlind => _('quickPlayBlind');
  String get quickPlayFast => _('quickPlayFast');
  String get quickHowToWin => _('quickHowToWin');
  String get quickUnlucky => _('quickUnlucky');
  String get quickYouGotLucky => _('quickYouGotLucky');
  String get quickOops => _('quickOops');
  String get quickTakeSideshow => _('quickTakeSideshow');
  String get quickTakeShow => _('quickTakeShow');
  String get quickSwitchTable => _('quickSwitchTable');
  String get quickHelpMe => _('quickHelpMe');

  /// The quick messages in panel order, in this language.
  ///
  /// The one list the panel draws and its test checks, so a line added here is
  /// on the table and under test together. Each goes out as ordinary chat, so
  /// it must fit the server's CHAT_MAX_LENGTH (140 UTF-16 units) — past that
  /// the server cuts it, and a set line arriving truncated reads as a fault.
  /// For the same reason a translation must hold nothing else the server's
  /// sanitiser rewrites: a format character (ZWJ and ZWNJ included) becomes a
  /// space, and a run of spaces closes up to one.
  List<String> get quickMessages => [
    quickPlayBlind,
    quickPlayFast,
    quickHowToWin,
    quickUnlucky,
    quickYouGotLucky,
    quickOops,
    quickTakeSideshow,
    quickTakeShow,
    quickSwitchTable,
    quickHelpMe,
  ];
  String get yourChips => _('yourChips');
  String get maxPot => _('maxPot');
  String get nightMode => _('nightMode');
  String get dayMode => _('dayMode');

  // --- the three-way appearance setting
  String get appearance => _('appearance');
  String get themeSystem => _('themeSystem');
  String get themeDark => _('themeDark');
  String get themeLight => _('themeLight');
  String get waitingForPlayers => _('waitingForPlayers');
  String get startingGame => _('startingGame');
  String buyChipsToStay(int seconds) =>
      _('buyChipsToStay').replaceAll('{seconds}', '$seconds');

  /// The premium-picture tier (requirement 21).
  String get unlock => _('unlock');
  String get unlockTitle => _('unlockTitle');
  String unlockBody(String name, String cost) =>
      _('unlockBody').replaceAll('{name}', name).replaceAll('{cost}', cost);

  /// The word on a premium picture this player has already paid for.
  String get pictureUnlocked => _('pictureUnlocked');

  /// Diamond-priced wording: the same two offers, paid from the diamond
  /// wallet instead of chips. `{s}` pluralises the English unit ("1 diamond",
  /// "5 diamonds") and is absent from the other four languages, whose word
  /// does not change with the number. [cost] arrives formatted, and "1" is the
  /// only singular formatChips produces.
  String unlockBodyDiamond(String name, String cost) => _('unlockBodyDiamond')
      .replaceAll('{name}', name)
      .replaceAll('{cost}', cost)
      .replaceAll('{s}', cost == '1' ? '' : 's');
  String unlockRentBodyDiamond(
    String name,
    String cost,
    int days, {
    int hours = 0,
  }) => _('unlockRentBodyDiamond')
      .replaceAll('{name}', name)
      .replaceAll('{cost}', cost)
      .replaceAll('{s}', cost == '1' ? '' : 's')
      .replaceAll('{time}', rentalTerm(days, hours));

  /// Hammer-priced wording (owner, 14 Sep 2026: the animated rentals are paid
  /// for in hammers). One hammer has its own line in every language
  /// (`…HammerOne`), as one missile does: Hindi and Punjabi change the noun
  /// with the number, so "1 hammers" cannot be avoided by substitution alone.
  /// [hammers] is a bare count, never large enough to want lakh grouping.
  String unlockBodyHammers(String name, int hammers) => _(
    hammers == 1 ? 'unlockBodyHammerOne' : 'unlockBodyHammers',
  ).replaceAll('{name}', name).replaceAll('{cost}', '$hammers');
  String unlockRentBodyHammers(
    String name,
    int hammers,
    int days, {
    int hours = 0,
  }) => _(hammers == 1 ? 'unlockRentBodyHammerOne' : 'unlockRentBodyHammers')
      .replaceAll('{name}', name)
      .replaceAll('{cost}', '$hammers')
      .replaceAll('{time}', rentalTerm(days, hours));

  /// The offer of the store's Hammers shelf to a player who cannot pay for a
  /// hammer-priced picture: its title, and its body with one hammer on a line
  /// of its own. A diamond-priced picture's offer reuses
  /// [notEnoughDiamondsTitle] and [getDiamonds] around a body of its own,
  /// whose [cost] arrives written out as in [unlockBodyDiamond].
  String get notEnoughHammersTitle => _('notEnoughHammersTitle');
  String notEnoughHammersBody(String name, int hammers) => _(
    hammers == 1 ? 'notEnoughHammersBodyOne' : 'notEnoughHammersBody',
  ).replaceAll('{name}', name).replaceAll('{cost}', '$hammers');
  String notEnoughDiamondsPictureBody(String name, String cost) =>
      _('notEnoughDiamondsPictureBody')
          .replaceAll('{name}', name)
          .replaceAll('{cost}', cost)
          .replaceAll('{s}', cost == '1' ? '' : 's');

  /// Said instead of asking when a chip-priced picture is tapped at a table:
  /// the server sells a seated player only the pictures priced in hammers or
  /// diamonds, whose wallets sit outside the table's chip checkpoints.
  String get pictureChipsLobbyOnly => _('pictureChipsLobbyOnly');

  /// The caption under the big picture in Settings.
  String get tapToChangePicture => _('tapToChangePicture');

  /// Rental wording for a premium picture. A term is days, hours or both
  /// (owner, 14 Sep 2026: pictures rented by the hour); a term of days alone
  /// keeps the price tag's short form.
  String rentForDays(int days, {int hours = 0}) => hours > 0
      ? rentalTerm(days, hours)
      : _('rentForDays').replaceAll('{days}', '$days');
  String daysLeft(int days) => _('daysLeft').replaceAll('{days}', '$days');
  String hoursLeft(int hours) => _('hoursLeft').replaceAll('{n}', '$hours');
  String minutesLeft(int minutes) =>
      _('minutesLeft').replaceAll('{n}', '$minutes');
  String unlockRentBody(String name, String cost, int days, {int hours = 0}) =>
      _('unlockRentBody')
          .replaceAll('{name}', name)
          .replaceAll('{cost}', cost)
          .replaceAll('{time}', rentalTerm(days, hours));

  /// A rental term in words — "10 days", "1 hour", "1 day 12 hours" — the
  /// `{time}` of the unlock sentences.
  String rentalTerm(int days, int hours) => switch ((days, hours)) {
    (> 0, > 0) => '${timeDays(days)} ${timeHours(hours)}',
    (_, > 0) => timeHours(hours),
    _ => timeDays(days),
  };

  /// The picture picker's shelves, as named in the menu above its grid.
  String get pictureAll => _('pictureAll');
  String get picturePremium => _('picturePremium');

  /// The order menu beside the shelf menu (owner, 14 Sep 2026).
  String get priceLowToHigh => _('priceLowToHigh');
  String get priceHighToLow => _('priceHighToLow');
  String get picturePremiumAnimated => _('picturePremiumAnimated');
  String get pictureShelfEmpty => _('pictureShelfEmpty');

  /// The popup over a premium picture this player has already paid for.
  String get pictureOwnedTitle => _('pictureOwnedTitle');

  /// The three units a rental's time left is counted in, each with its own
  /// singular key, so the popup can pair any two — "3 days 4 hours", "1 hour
  /// 20 minutes". Hindi and Punjabi change the hour's word with the number;
  /// the other languages repeat one form in both keys.
  String timeDays(int n) =>
      _(n == 1 ? 'timeDay' : 'timeDays').replaceAll('{n}', '$n');
  String timeHours(int n) =>
      _(n == 1 ? 'timeHour' : 'timeHours').replaceAll('{n}', '$n');
  String timeMinutes(int n) =>
      _(n == 1 ? 'timeMinute' : 'timeMinutes').replaceAll('{n}', '$n');

  /// Wraps a counted [time] as time remaining. A template of its own rather
  /// than "left" glued on, so each language keeps its own word order.
  String timeLeft(String time) => _('timeLeft').replaceAll('{time}', time);

  /// Said instead of a time for a premium picture that never runs out.
  String get pictureKeeps => _('pictureKeeps');

  /// Said when the rental ends while the popup is open.
  String get rentalLapsed => _('rentalLapsed');

  /// The rental's end, with `{date}` already written as numbers.
  String rentalEnds(String date) => _('rentalEnds').replaceAll('{date}', date);
  String rentalEnded(String date) =>
      _('rentalEnded').replaceAll('{date}', date);

  /// The popup's key, and what it reads when that picture is already on.
  String get wear => _('wear');
  String get wearing => _('wearing');
  String get youAreWinner => _('youAreWinner');
  String get isTheWinner => _('isTheWinner');

  // --- dialogs
  String get leaveTable => _('leaveTable');
  String get leaveTableQ => _('leaveTableQ');
  String get leaveMidHand => _('leaveMidHand');
  String get leaveAnytime => _('leaveAnytime');
  String get stay => _('stay');
  String get leave => _('leave');
  String get switchTable => _('switchTable');
  String get switchTableQ => _('switchTableQ');
  String get switchMidHand => _('switchMidHand');
  String get switchIdle => _('switchIdle');
  String get switchAction => _('switchAction');
  String get quitGameQ => _('quitGameQ');
  String get quitGameBody => _('quitGameBody');
  String get quit => _('quit');
  String get cancel => _('cancel');
  String get joinAnother => _('joinAnother');

  /// The server's `no_other_table` refusal to a table switch, in the
  /// player's language. `{category}` is the table's category as this
  /// language writes it.
  String noOtherTable(String category) =>
      _('noOtherTable').replaceAll('{category}', category);

  // --- the one-time no-winnings confirmation after sign-in
  String get consentTitle => _('consentTitle');
  String get consentBody => _('consentBody');
  String get consentNote => _('consentNote');
  String get consentAccept => _('consentAccept');

  // --- rules
  String get rules => _('rules');
  String get rulesTitle => _('rulesTitle');
  String get rulesBeats => _('rulesBeats');
  String get rankTrail => _('rankTrail');
  String get rankTrailNote => _('rankTrailNote');
  String get rankPureSeq => _('rankPureSeq');
  String get rankPureSeqNote => _('rankPureSeqNote');
  String get rankSeq => _('rankSeq');
  String get rankSeqNote => _('rankSeqNote');
  String get rankColor => _('rankColor');
  String get rankColorNote => _('rankColorNote');
  String get rankPair => _('rankPair');
  String get rankPairNote => _('rankPairNote');
  String get rankHigh => _('rankHigh');
  String get rankHighNote => _('rankHighNote');
  String get runOrder => _('runOrder');
  String get runOrderNote => _('runOrderNote');
  String get close => _('close');

  // --- a newer build is waiting on Play
  String get updateTitle => _('updateTitle');
  String get updateBody => _('updateBody');
  String get updateNow => _('updateNow');
  String get updateOpenStore => _('updateOpenStore');
  String get updateOpenAppStore => _('updateOpenAppStore');
  String get updateFailed => _('updateFailed');

  // --- name and the entry cap
  String get changeName => _('changeName');
  String get save => _('save');
  String get nameSaved => _('nameSaved');
  String get cappedTitle => _('cappedTitle');
  String get cappedBody => _('cappedBody');
  String get lockedTitle => _('lockedTitle');
  String get lockedBody => _('lockedBody');
  String get entryLabel => _('entryLabel');
  String get entryOpen => _('entryOpen');
  String get entryUpTo => _('entryUpTo');
  String get entryFrom => _('entryFrom');
  String get useSocialPicture => _('useSocialPicture');
  String get guestNoSocial => _('guestNoSocial');

  static const Map<String, Map<String, String>> _table = {
    'en': {
      'signInSubtitle': 'Sign in to take a seat.',
      'displayName': 'Display name',
      'playerHint': 'Player',
      'playAsGuest': 'Play as Guest',
      'signingIn': 'Signing in…',
      'continueGoogle': 'Continue with Google',
      'continueFacebook': 'Continue with Facebook',
      'privacyPolicy': 'Privacy policy',
      'signInUnavailable':
          '{provider} sign-in is not available in this version. Please play as guest for now.',
      'boot': 'boot',
      'maxBlindsLabel': 'blind moves max',
      'potLimitLabel': 'pot limit',
      'potUnlimited': 'Unlimited',
      'tapToSit': 'Tap to sit down',
      'everyoneChips': "Everyone's chips are visible",
      'onlyYourChips': 'Only your own chips are visible',
      'seen': 'SEEN',
      'blind': 'BLIND',
      'privateTable': 'Private table',
      'create': 'Create',
      'orJoinCode': 'Or join one with its code:',
      'tableCode': 'TABLE CODE',
      'invalidTableCode': 'Table codes are 8 letters and numbers.',
      'join': 'Join',
      'yourPicture': 'Your picture',
      'yourRecord': 'Your record',
      'handsPlayed': 'Hands played',
      'won': 'Won',
      'lost': 'Lost',
      'leftMidHand': 'Left mid-hand',
      'totalWinnings': 'Total winnings',
      'biggestPot': 'Biggest pot',
      'playedNote': 'A hand counts as played once you have made a move in it.',
      'fourHourBonus': '4-HOUR BONUS',
      'dailyBonus': 'DAILY BONUS',
      'milestone': 'MILESTONE',
      'collect': 'Collect',
      'rewardCollected': 'Reward collected!',
      'rewardComeBack': 'Come again after 4 hours.',
      'rewardComeBackDaily': 'Come again after 24 hours.',
      'bonusYouGet': 'You will get',
      'bonusNextIn': 'Next reward in',
      'bonusReadyNow': 'Ready to collect now',
      'bonusEveryFourHours': 'A new bonus every 4 hours.',
      'bonusEveryDay': 'A new bonus every 24 hours.',
      'rewardPurchased': 'The chips are in your wallet. Good luck.',
      'rewardDiamondsPurchased':
          'The diamonds are in your wallet. Trade them for missiles.',
      'rewardMilestoneAgain': 'Another 25 hands earns the next one.',
      'rewardRefused': 'Not ready to collect yet.',
      'tapToClose': 'Tap to close',
      'buyChips': 'Buy chips',
      'shop': 'Shop',
      'comingSoon': 'Coming soon',
      'updateTitle': 'A new version is ready',
      'updateBody':
          'Update to keep playing. This version is no longer up to date.',
      'updateNow': 'Update now',
      'updateOpenStore': 'Open Play Store',
      'updateOpenAppStore': 'Open App Store',
      'updateFailed': 'The update did not finish. Please try again.',
      'storeTitle': 'Chip Store',
      'storeBlurb': 'The bigger the pack, the bigger the bonus.',
      'storeTabChips': 'Chips',
      'storeTabPictures': 'Pictures',
      'storeTabAnimated': 'Animated',
      'storePicturesBlurb': 'Unlock a picture with chips or hammers.',
      'storeAnimatedBlurb': 'Unlock an animated picture with hammers.',
      'storeTabDiamonds': 'Diamonds',
      'storeDiamondsTitle': 'Diamond Store',
      'storeDiamondsBlurb': 'Diamonds trade for missiles.',
      'storeTabHammers': 'Hammers',
      'storeHammersTitle': 'Hammer Store',
      'storeHammersBlurb': 'A hammer forces a sideshow — nobody is asked.',
      'rewardHammersPurchased':
          'The hammers are in your wallet. Force a sideshow at the table.',
      'walletSummary':
          '{diamonds} diamonds, {hammers} hammers, {missiles} missiles',
      'storeBonus': 'BONUS',
      'storeNotLive': 'Payments are not live yet — nothing was charged.',
      'posStarter': 'STARTER',
      'posPopular': 'POPULAR',
      'posBestValue': 'BEST VALUE',
      'posPremium': 'PREMIUM',
      'comingSoonBody':
          'Buying chips is not open yet. Collect your rewards in the meantime.',
      'handsToGo': 'hands to go',
      'handToGo': 'hand to go',
      'forceSideshowTooLate':
          'Too late — that sideshow is no longer open. No hammer was spent.',
      'settings': 'Settings',
      'language': 'Language',
      'numberSystem': 'Number format',
      'numberIndian': 'Indian  ·  Lakh, Crore',
      'numberInternational': 'International  ·  Million, Billion',
      'unitLakh': 'Lakh',
      'unitCrore': 'Crore',
      'unitMillion': 'Million',
      'unitBillion': 'Billion',
      'switchTheme': 'Switch theme',
      'signOut': 'Sign out',
      'signOutQ': 'Sign out?',
      'signOutBody':
          'Your chips, diamonds, hammers and pictures stay with this account.',
      'providerGuest': 'Guest',
      'unitHourShort': 'h',
      'unitMinuteShort': 'm',
      'unitSecondShort': 's',
      'serviceUnavailable': 'Service not available',
      'soundLabel': 'Sound',
      'vibrationLabel': 'Vibration',
      'useProviderPicture': 'Use my Google/Facebook picture',
      'pictureChangeAnytime': 'You can change it any time, even at a table.',
      'pot': 'POT',
      'stake': 'stake',
      'yourTurn': 'YOUR TURN',
      'toAct': 'to act',
      'pack': 'Pack',
      'chaal': 'Chaal',
      'show': 'Show',
      'sideshow': 'Sideshow',
      'sideshowWith': 'Compare with',
      'sideshowAsksYou': 'wants to compare hands with you',
      // variation tables: the first player picks the rules of the hand
      'variation': 'VARIATION',
      'variationTableNote': 'First player picks each hand\'s rules',
      'viewTables': 'View tables',
      'tablesLabel': 'tables',
      'openToYouLabel': 'open to you',
      'backToCategories': 'All games',
      'variationRulesTitle': 'Variation tables',
      'tableInfoTitle': 'Table info',
      'tableRulesTitle': 'How this table plays',
      'tableRulesKey': 'Table rules',
      'ruleBlindMoves':
          'You can bet blind up to {n} times; after that your cards open for you.',
      'ruleRaiseOnce': 'On your turn: chaal, or raise once to double.',
      'ruleRaiseFree':
          'On your turn: chaal, or keep doubling the raise as far as your chips go.',
      'rulePotCapped':
          'When the pot reaches {pot}, every hand is shown and the best one wins.',
      'rulePotOpen': 'The pot has no limit.',
      'ruleRoundsEnd':
          'If the betting runs all its rounds, every hand is shown and the best one wins.',
      'ruleShowTwo':
          'When only two players are left, either can pay for a show.',
      'ruleVariationPick':
          'The first player to act has 10 seconds to choose how the hand is decided; otherwise it is Muflis.',
      'categoryLabel': 'game',
      'playersLabel': 'players',
      'turnTimeLabel': 'turn time',
      'yourChipsLabel': 'your chips',
      'canSitHere': 'You can sit at this table.',
      'playersUpTo': 'Up to {n}',
      'secondsEach': '{n} seconds',
      'variationRulesIntro':
          'The first player to act has 10 seconds to choose how the hand is decided; if they do not, it is Muflis. A wild card counts as whichever card makes your hand best. Other players\' chips are hidden and the pot has no limit.',
      'variationChooseTitle': 'Choose Variation',
      'variationSelectingBy': '{name} is selecting variation…',
      'variationChosen': 'Variation: {variation}',
      'variationLeftChosen': '{name} left the table — Muflis was chosen',
      'variationAutoChosen': 'Time ran out — Muflis was chosen',
      'varMuflis': 'Muflis',
      'varAk47': 'AK47',
      'varJoker': 'Joker',
      'varHukam': 'Hukam',
      'varLowestJoker': 'Lowest Joker',
      'varHighestJoker': 'Highest Joker',
      'varFiveCard': '5-Card',
      'varMuflisNote': 'Lowest hand wins',
      'varAk47Note': 'A, K, 4 and 7 are wild',
      'varJokerNote': 'The turned-up rank is wild',
      'varHukamNote': 'The turned-up suit is wild',
      'varLowestJokerNote': 'Your lowest card is wild',
      'varHighestJokerNote': 'Your highest card is wild',
      'varFiveCardNote': 'Best 3 of your 5 cards',
      'wildCard': 'Wild',
      'sideshowRunning': 'Sideshow',
      'accept': 'Accept',
      'decline': 'Decline',
      'sideshowDeclined': 'Your sideshow was declined',
      'sideshowTimedOut': 'No answer — the sideshow lapsed',
      'sideshowCancelled': 'The sideshow was called off',
      'sideshowYouLost': 'Your hand was lower — you packed',
      'sideshowYouWon': 'Your hand was higher — they packed',
      'force': 'Force',
      'forceSideshow': 'Force Sideshow',
      'forceSideshowTitle': 'Force a sideshow?',
      'forceSideshowBody': 'Spend 1 hammer to force a sideshow with {name}?',
      'forceSideshowNote': 'They cannot refuse, and a tie goes against you.',
      'noHammersTitle': 'No hammers left',
      'noHammersBody':
          'A forced sideshow costs 1 hammer. Get more in the store?',
      'getHammers': 'Get hammers',
      'noHammers': 'You need a hammer to force a sideshow',
      'sideshowForcedByYou': 'You forced a sideshow with {name}',
      'sideshowForcedOnYou': '{name} forced a sideshow with you',
      'sideshowForcedOn': '{from} forced a sideshow on {to}',
      'missile': 'Missile',
      'fireMissileTitle': 'Fire a missile?',
      'fireMissileBody':
          'Every player still in the hand shows their cards and the best hand takes the pot. Costs 1 missile.',
      'fireMissileNote': 'A tie goes against you.',
      'fire': 'Fire',
      'missileTooLate':
          'Too late — the missile was not fired. No missile was spent.',
      'noMissilesTitle': 'No missiles left',
      'noMissilesBody':
          'Firing a missile costs 1 missile. Trade diamonds for more in the store?',
      'getMissiles': 'Get missiles',
      'noMissiles': 'You need a missile to fire one',
      'tooFewPlayers': 'That needs at least 3 players still in the hand',
      'missileNeedsShowChips':
          'You need enough chips for a show to fire a missile',
      'missileFiredByYou': 'You fired a missile',
      'missileFiredBy': '{name} fired a missile',
      'storeTabMissiles': 'Missiles',
      'storeMissilesTitle': 'Missile Store',
      'storeMissilesBlurb': 'Trade diamonds: 15 diamonds = 1 missile.',
      'tradeMissilesTitle': 'Trade diamonds?',
      'tradeMissilesBody':
          'Trade {diamonds} diamond{s} for {missiles} missiles?',
      'tradeMissileBodyOne': 'Trade {diamonds} diamond{s} for 1 missile?',
      'trade': 'Trade',
      'notEnoughDiamondsTitle': 'Not enough diamonds',
      'notEnoughDiamondsBody':
          'This trade needs {diamonds} diamond{s}. Get more diamonds?',
      'getDiamonds': 'Get diamonds',
      'missilesAdded': '{n} missiles added to your wallet',
      'missileAddedOne': '1 missile added to your wallet',
      'rewardMissileTradedOne':
          'The missile is in your wallet. Fire it at the table.',
      'walletSummaryOneMissile':
          '{diamonds} diamonds, {hammers} hammers, 1 missile',
      'rewardMissilesTraded':
          'The missiles are in your wallet. Fire one at the table.',
      'premiumPackages': 'Premium Packages',
      'posPremiumPackage': 'PREMIUM PACKAGE',
      'plusMissileOne': '+1 Missile',
      'plusMissiles': '+{n} Missiles',
      'plusHammers': '+{n} Hammers',
      'plusHammerOne': '+{n} Hammer',
      'rewardPremiumPurchased':
          'Your Premium Package is in your wallet. Good luck.',
      'premiumAdded':
          'Premium Package added: {chips} chips, {missiles} missiles and {hammers} hammers',
      'premiumAddedOneMissile':
          'Premium Package added: {chips} chips, 1 missile and {hammers} hammers',
      'seeCards': 'See cards',
      'blindMovesLeft': 'blind moves left',
      'blindMovesLabel': 'Blind moves left',
      'lastBlindMove': 'last blind move',
      'inPot': 'In Pot',
      'waiting': 'waiting',
      'offline': 'offline',
      'packed': 'PACKED',
      'autoPacked': 'turns missed in a row',
      'autoPackedOne': 'turn missed',
      'lastWarning': 'Last warning',
      'missOneMore': 'Miss this turn and you leave the table.',
      'missedTurnsLabel': 'Missed turns',
      'resumingTable': 'Returning to your table…',
      'welcomeBack': "Welcome back — you're back at your table.",
      'appVersion': 'App version',
      'tableLost': 'You lost your seat while you were away.',
      'notConnected': 'No connection. That did not go through.',
      'reconnecting': 'Connection lost. Reconnecting…',
      'kickedNoChips': "You don't have enough chips to stay at this table.",
      'kickedIdle': 'You left the table after {n} missed turns.',
      'leaveStakeStays': 'Your stake stays in the pot',
      'winner': 'Winner',
      'tableChat': 'Table chat',
      'saySomething': 'Say something…',
      'tableMenu': 'Table menu',
      // The panel's own title and its key's tooltip. The owner gave only the
      // ten lines below, so this wording is ours and free to change.
      'quickMessagesTitle': 'Quick messages',
      'quickMessagesTip': 'Send a quick message',
      // The owner's wording, capitals and apostrophes as given.
      'quickPlayBlind': 'Please Play Blind.',
      'quickPlayFast': 'Please Play fast.',
      'quickHowToWin': "That's how you win it.",
      'quickUnlucky': 'I am unlucky.',
      'quickYouGotLucky': 'You got lucky.',
      'quickOops': "Oops! I shouldn't have played it.",
      'quickTakeSideshow': 'Please take sideshow.',
      'quickTakeShow': 'Please take show.',
      'quickSwitchTable': 'Switch Table.',
      'quickHelpMe': 'Please help me.',
      'yourChips': 'Your chips',
      'maxPot': 'Max pot',
      'nightMode': 'Night mode',
      'dayMode': 'Day mode',
      'appearance': 'Appearance',
      'themeSystem': 'System',
      'themeDark': 'Dark',
      'themeLight': 'Light',
      'waitingForPlayers': 'Waiting for players',
      'startingGame': 'Starting game…',
      'buyChipsToStay': 'Buy chips in {seconds}s to keep your seat',
      'unlock': 'Unlock',
      'unlockTitle': 'Unlock this picture?',
      'unlockBody': '{name} costs {cost} chips. Unlock it and wear it now?',
      'unlockBodyDiamond':
          '{name} costs {cost} diamond{s}. Unlock it and wear it now?',
      'pictureUnlocked': 'Unlocked',
      'tapToChangePicture': 'Tap to change your picture',
      'rentForDays': '{days} days',
      'daysLeft': '{days}d left',
      'hoursLeft': '{n}h left',
      'minutesLeft': '{n}m left',
      'unlockRentBody':
          '{name} costs {cost} chips and is yours for {time}. Unlock it and wear it now?',
      'unlockRentBodyDiamond':
          '{name} costs {cost} diamond{s} and is yours for {time}. Unlock it and wear it now?',
      'unlockBodyHammers':
          '{name} costs {cost} hammers. Unlock it and wear it now?',
      'unlockBodyHammerOne':
          '{name} costs 1 hammer. Unlock it and wear it now?',
      'unlockRentBodyHammers':
          '{name} costs {cost} hammers and is yours for {time}. Unlock it and wear it now?',
      'unlockRentBodyHammerOne':
          '{name} costs 1 hammer and is yours for {time}. Unlock it and wear it now?',
      'notEnoughHammersTitle': 'Not enough hammers',
      'notEnoughHammersBody': '{name} costs {cost} hammers. Get more hammers?',
      'notEnoughHammersBodyOne': '{name} costs 1 hammer. Get more hammers?',
      'notEnoughDiamondsPictureBody':
          '{name} costs {cost} diamond{s}. Get more diamonds?',
      'pictureChipsLobbyOnly':
          'You can only buy a chip-priced picture in the lobby.',
      'pictureAll': 'All',
      'picturePremium': 'Premium',
      'priceLowToHigh': 'Price: Low to High',
      'priceHighToLow': 'Price: High to Low',
      'picturePremiumAnimated': 'Premium (Animated)',
      'pictureShelfEmpty': 'No pictures here yet.',
      'pictureOwnedTitle': 'Already unlocked',
      'timeDay': '{n} day',
      'timeDays': '{n} days',
      'timeHour': '{n} hour',
      'timeHours': '{n} hours',
      'timeMinute': '{n} minute',
      'timeMinutes': '{n} minutes',
      'timeLeft': '{time} left',
      'pictureKeeps': 'Yours to keep',
      'rentalLapsed': 'Your rental has run out',
      'rentalEnds': 'Ends {date}',
      'rentalEnded': 'Ended {date}',
      'wear': 'Wear',
      'wearing': 'Wearing',
      'youAreWinner': 'You are the winner',
      'isTheWinner': 'is the winner',
      'leaveTable': 'Leave table',
      'leaveTableQ': 'Leave this table?',
      'leaveMidHand':
          'You are in a hand. Leaving packs your cards and your stake stays in the pot.',
      'leaveAnytime': 'You can join another table straight away.',
      'stay': 'Stay',
      'leave': 'Leave',
      'switchTable': 'Switch table',
      'switchTableQ': 'Switch table?',
      'switchMidHand':
          'You are in a hand. Moving packs your cards and your stake stays in the pot.',
      'switchIdle':
          'You will be seated at another table of the same kind. If none has a free seat, you keep this one.',
      'switchAction': 'Switch',
      'quitGameQ': 'Quit the game?',
      'quitGameBody': 'You can come back any time — your chips are saved.',
      'quit': 'Quit',
      'cancel': 'Cancel',
      'consentTitle': 'Before you play',
      'consentBody':
          'I confirm that I do not have any expectations of winning any monetary or other enrichment from playing this game.',
      'consentNote':
          'This game is for entertainment only. Chips have no cash value and cannot be exchanged for money or anything else.',
      'consentAccept': 'I confirm',
      'joinAnother': 'You can join another straight away',
      'noOtherTable':
          'No other {category} table at this stake has a free seat right now',
      'rules': 'Rules',
      'rulesTitle': 'Card ranking',
      'rulesBeats':
          'Strongest at the top. Every hand beats everything below it.',
      'rankTrail': 'Trail',
      'rankTrailNote': 'Three of the same rank',
      'rankPureSeq': 'Pure Sequence',
      'rankPureSeqNote': 'A run, all one suit',
      'rankSeq': 'Sequence',
      'rankSeqNote': 'A run of three, any suits',
      'rankColor': 'Color',
      'rankColorNote': 'Three of one suit, not a run',
      'rankPair': 'Pair',
      'rankPairNote': 'Two of the same rank',
      'rankHigh': 'High Card',
      'rankHighNote': 'None of the above; highest card wins',
      'runOrder': 'Run order',
      'runOrderNote':
          'A-K-Q is the highest run, then A-2-3, then K-Q-J down to 4-3-2.',
      'close': 'Close',
      'changeName': 'Change name',
      'save': 'Save',
      'nameSaved': 'Name updated.',
      'cappedTitle': 'Table closed to you',
      'cappedBody':
          'Players holding more than {cap} chips cannot join this table.',
      'lockedTitle': 'Table not open yet',
      'lockedBody': 'You need {min} chips to sit at this table.',
      'entryLabel': 'Entry',
      'entryOpen': 'Open to all',
      'entryUpTo': 'Up to {cap}',
      'entryFrom': '{min} or more',
      'useSocialPicture': 'Use my Google or Facebook picture',
      'guestNoSocial': 'Sign in with Google or Facebook to use your own photo.',

      // --- the poker family
      'poker': 'POKER',
      'pokerTableNote': "Hold'em, Omaha, 5-Card Draw and 3-Card Poker",
      'pokerTexasHoldem': "Texas Hold'em",
      'pokerOmaha': 'Omaha',
      'pokerFiveCardDraw': '5-Card Draw',
      'pokerThreeCardPoker': '3-Card Poker',
      'pokerTexasHoldemNote': 'Two cards each, five on the board',
      'pokerOmahaNote': 'Four cards each, play exactly two of them',
      'pokerFiveCardDrawNote':
          'Five cards each, exchange the ones you do not want',
      'pokerThreeCardPokerNote': 'Three cards each, against the dealer',
      'blindsLabel': 'blinds',
      'anteLabel': 'ante',
      'buyInLabel': 'buy-in',
      'holeCardsLabel': 'cards each',
      'maxDiscardsLabel': 'exchange up to',
      'buyInFrom': 'from {min}',
      'fold': 'Fold',
      'check': 'Check',
      'call': 'Call',
      'bet': 'Bet',
      'raise': 'Raise',
      'allIn': 'All-in',
      'play': 'Play',
      'draw': 'Draw',
      'standPat': 'Stand pat',
      'exchangeUpTo': 'Choose up to {n} cards to exchange',
      'playOrFold': 'Play or fold?',
      'dealerLabel': 'Dealer',
      'dealerQualifies': 'Dealer qualifies',
      'dealerNotQualified': 'Dealer does not qualify',
      'youWon': 'You won {amount}',
      'youLost': 'You lost',
      'outcomeWin': 'Win',
      'outcomeLose': 'Lose',
      'push': 'Push',
      'potLabel': 'Pot',
      'sidePotLabel': 'Side pot',
      'boardLabel': 'Board',
      'streetPreflop': 'Pre-flop',
      'streetFlop': 'Flop',
      'streetTurn': 'Turn',
      'streetRiver': 'River',
      'streetPredraw': 'Before the draw',
      'streetDraw': 'Draw',
      'streetPostdraw': 'After the draw',
      'streetDecision': 'Decision',
      'streetShowdown': 'Showdown',
      'pokerTimedOut': 'Your time ran out and your hand was folded',
      'pokerRulesTitle': 'Poker tables',
      'pokerRulesIntro':
          'Four poker games, all scored by the same five-card ranking. A hand '
          'is the best five cards you can make.',
      'pokerRankRoyalFlush': 'Royal Flush',
      'pokerRankStraightFlush': 'Straight Flush',
      'pokerRankFourOfAKind': 'Four of a Kind',
      'pokerRankFullHouse': 'Full House',
      'pokerRankFlush': 'Flush',
      'pokerRankStraight': 'Straight',
      'pokerRankThreeOfAKind': 'Three of a Kind',
      'pokerRankTwoPair': 'Two Pair',
      'pokerRankPair': 'Pair',
      'pokerRankHighCard': 'High Card',
      'pokerThreeCardRanking':
          'In 3-Card Poker a straight beats a flush, and three of a kind beats '
          'both.',
      'rulePokerBlinds': 'Blinds of {small} and {big} start every hand',
      'rulePokerAnte': 'Everyone puts in an ante of {ante} before the deal',
      'rulePokerBuyIn': 'Sit down with at least {min}',
      'rulePokerHoleCards': 'Each player is dealt {n} cards',
      'rulePokerHoldemWin':
          'Make your best five from your two cards and the five on the board',
      'rulePokerOmahaWin':
          'Exactly two of your four cards and three from the board make the '
          'hand',
      'rulePokerDrawWin': 'Bet, exchange up to {n} cards once, then bet again',
      'rulePokerThreeCardWin':
          "Play for the ante or fold; your three cards are compared with the "
          "dealer's",
      'rulePokerDealerQualifies':
          'The dealer needs Queen-high to play; if not, your play bet comes '
          'back and your ante wins',
      'rulePokerBestHandWins':
          'The best hand at the showdown takes the pot; the last player '
          'standing takes it without one',
      'refuseNotYourTurn': 'It is not your turn',
      'refuseInvalidAction': 'That move is not allowed right now',
      'refuseInvalidAmount': 'That amount is not allowed',
      'refuseInvalidDiscard': 'Those cards cannot be exchanged',
      'refuseInsufficientChips': 'Not enough chips for that',
      'refuseNoHand': 'No hand is being played',
      'refuseNotInHand': 'You are not in this hand',
      'refuseWrongGame': 'That move belongs to another game',
      'refuseDuplicateAction': 'That move was already sent',
      'refuseUnknownAction': 'That move is not one the table knows',
    },
    'hi': {
      'signInSubtitle': 'खेलने के लिए साइन इन करें।',
      'displayName': 'नाम',
      'playerHint': 'खिलाड़ी',
      'playAsGuest': 'मेहमान के रूप में खेलें',
      'signingIn': 'साइन इन हो रहा है…',
      'continueGoogle': 'Google से जारी रखें',
      'continueFacebook': 'Facebook से जारी रखें',
      'privacyPolicy': 'गोपनीयता नीति',
      'signInUnavailable':
          'इस वर्शन में {provider} साइन-इन उपलब्ध नहीं है। फ़िलहाल गेस्ट के रूप में खेलें।',
      'boot': 'बूट',
      'maxBlindsLabel': 'ब्लाइंड चालें अधिकतम',
      'potLimitLabel': 'पॉट सीमा',
      'potUnlimited': 'असीमित',
      'tapToSit': 'बैठने के लिए टैप करें',
      'everyoneChips': 'सबके चिप्स दिखते हैं',
      'onlyYourChips': 'सिर्फ़ आपके चिप्स दिखते हैं',
      'seen': 'सीन',
      'blind': 'ब्लाइंड',
      'privateTable': 'प्राइवेट टेबल',
      'create': 'बनाएँ',
      'orJoinCode': 'या कोड से जुड़ें:',
      'tableCode': 'टेबल कोड',
      'invalidTableCode': 'टेबल कोड 8 अक्षरों और अंकों का होता है।',
      'join': 'जुड़ें',
      'yourPicture': 'आपकी तस्वीर',
      'yourRecord': 'आपका रिकॉर्ड',
      'handsPlayed': 'खेले गए हाथ',
      'won': 'जीते',
      'lost': 'हारे',
      'leftMidHand': 'बीच में छोड़े',
      'totalWinnings': 'कुल जीत',
      'biggestPot': 'सबसे बड़ा पॉट',
      'playedNote': 'हाथ तभी गिना जाता है जब आपने उसमें कोई चाल चली हो।',
      'fourHourBonus': '4-घंटे का बोनस',
      'dailyBonus': 'दैनिक बोनस',
      'milestone': 'माइलस्टोन',
      'collect': 'लें',
      'rewardCollected': 'इनाम मिल गया!',
      'rewardComeBack': '4 घंटे बाद फिर आइए।',
      'rewardComeBackDaily': '24 घंटे बाद फिर आइए।',
      'bonusYouGet': 'आपको मिलेगा',
      'bonusNextIn': 'अगला इनाम मिलेगा',
      'bonusReadyNow': 'अभी लेने के लिए तैयार',
      'bonusEveryFourHours': 'हर 4 घंटे में नया बोनस।',
      'bonusEveryDay': 'हर 24 घंटे में नया बोनस।',
      'rewardPurchased': 'चिप्स आपके वॉलेट में हैं। शुभकामनाएँ।',
      'rewardDiamondsPurchased': 'हीरे आपके वॉलेट में हैं। इनसे मिसाइलें लें।',
      'rewardMilestoneAgain': 'अगले के लिए 25 हाथ और खेलें।',
      'rewardRefused': 'अभी लेने के लिए तैयार नहीं।',
      'tapToClose': 'बंद करने के लिए टैप करें',
      'buyChips': 'चिप्स खरीदें',
      'shop': 'दुकान',
      'comingSoon': 'जल्द आ रहा है',
      'updateTitle': 'नया वर्ज़न तैयार है',
      'updateBody': 'खेलते रहने के लिए अपडेट करें। यह वर्ज़न अब पुराना है।',
      'updateNow': 'अभी अपडेट करें',
      'updateOpenStore': 'प्ले स्टोर खोलें',
      'updateOpenAppStore': 'ऐप स्टोर खोलें',
      'updateFailed': 'अपडेट पूरा नहीं हुआ। कृपया फिर कोशिश करें।',
      'storeTitle': 'चिप स्टोर',
      'storeBlurb': 'जितना बड़ा पैक, उतना बड़ा बोनस।',
      'storeTabChips': 'चिप्स',
      'storeTabPictures': 'तस्वीरें',
      'storeTabAnimated': 'एनिमेटेड',
      'storePicturesBlurb': 'चिप्स या हथौड़ों से तस्वीर अनलॉक करें।',
      'storeAnimatedBlurb': 'हथौड़ों से एनिमेटेड तस्वीर अनलॉक करें।',
      'storeTabDiamonds': 'हीरे',
      'storeDiamondsTitle': 'हीरा स्टोर',
      'storeDiamondsBlurb': 'हीरे देकर मिसाइलें लें।',
      'storeTabHammers': 'हथौड़े',
      'storeHammersTitle': 'हथौड़ा स्टोर',
      'storeHammersBlurb': 'हथौड़े से साइडशो बिना पूछे होता है।',
      'rewardHammersPurchased':
          'हथौड़े आपके वॉलेट में हैं। टेबल पर फ़ोर्स साइडशो करें।',
      'walletSummary': '{diamonds} हीरे, {hammers} हथौड़े, {missiles} मिसाइलें',
      'storeBonus': 'बोनस',
      'storeNotLive': 'भुगतान अभी चालू नहीं है — कोई शुल्क नहीं लिया गया।',
      'posStarter': 'शुरुआत',
      'posPopular': 'लोकप्रिय',
      'posBestValue': 'सबसे बढ़िया',
      'posPremium': 'प्रीमियम',
      'comingSoonBody':
          'चिप्स खरीदना अभी शुरू नहीं हुआ है। तब तक अपने इनाम लेते रहें।',
      'handsToGo': 'हाथ बाकी',
      'handToGo': 'हाथ बाकी',
      'forceSideshowTooLate':
          'देर हो गई — अब वह साइडशो नहीं हो सकता। कोई हथौड़ा खर्च नहीं हुआ।',
      'settings': 'सेटिंग्स',
      'language': 'भाषा',
      'numberSystem': 'संख्या प्रारूप',
      'numberIndian': 'भारतीय  ·  लाख, करोड़',
      'numberInternational': 'अंतरराष्ट्रीय  ·  मिलियन, बिलियन',
      'unitLakh': 'लाख',
      'unitCrore': 'करोड़',
      'unitMillion': 'मिलियन',
      'unitBillion': 'बिलियन',
      'switchTheme': 'थीम बदलें',
      'signOut': 'साइन आउट',
      'signOutQ': 'साइन आउट करें?',
      'signOutBody':
          'आपके चिप्स, हीरे, हथौड़े और तस्वीरें इसी खाते में रहेंगे।',
      'providerGuest': 'मेहमान',
      'unitHourShort': 'घं',
      'unitMinuteShort': 'मि',
      'unitSecondShort': 'से',
      'serviceUnavailable': 'सेवा उपलब्ध नहीं है',
      'soundLabel': 'आवाज़',
      'vibrationLabel': 'कंपन',
      'useProviderPicture': 'मेरी Google/Facebook तस्वीर लगाएँ',
      'pictureChangeAnytime': 'आप इसे कभी भी बदल सकते हैं, टेबल पर भी।',
      'pot': 'पॉट',
      'stake': 'दांव',
      'yourTurn': 'आपकी बारी',
      'toAct': 'की बारी',
      'pack': 'पैक',
      'chaal': 'चाल',
      'show': 'शो',
      'sideshow': 'साइडशो',
      'sideshowWith': 'तुलना करें',
      'sideshowAsksYou': 'आपके साथ पत्ते मिलाना चाहता है',
      // variation tables: the first player picks the rules of the hand
      'variation': 'वेरिएशन',
      'variationTableNote': 'हर हाथ के नियम पहला खिलाड़ी चुनता है',
      'viewTables': 'टेबल देखें',
      'tablesLabel': 'टेबल',
      'openToYouLabel': 'आपके लिए खुली',
      'backToCategories': 'सभी खेल',
      'variationRulesTitle': 'वेरिएशन टेबल',
      'tableInfoTitle': 'टेबल की जानकारी',
      'tableRulesTitle': 'यह टेबल कैसे खेली जाती है',
      'tableRulesKey': 'टेबल के नियम',
      'ruleBlindMoves':
          'आप {n} बार तक ब्लाइंड चाल चल सकते हैं; उसके बाद आपके पत्ते आपके लिए खुल जाते हैं।',
      'ruleRaiseOnce': 'अपनी बारी पर: चाल, या एक बार दुगना रेज़।',
      'ruleRaiseFree':
          'अपनी बारी पर: चाल, या जितने चिप्स हों उतना दुगना करते जाएँ।',
      'rulePotCapped':
          'पॉट {pot} पहुँचते ही सभी हाथ दिखाए जाते हैं और सबसे अच्छा हाथ जीतता है।',
      'rulePotOpen': 'पॉट की कोई सीमा नहीं है।',
      'ruleRoundsEnd':
          'सारे राउंड पूरे हो जाएँ तो सभी हाथ दिखाए जाते हैं और सबसे अच्छा हाथ जीतता है।',
      'ruleShowTwo':
          'जब सिर्फ़ दो खिलाड़ी बचें, तो कोई भी शो के लिए भुगतान कर सकता है।',
      'ruleVariationPick':
          'पहली चाल वाले खिलाड़ी के पास 10 सेकंड होते हैं यह चुनने के लिए कि हाथ कैसे तय होगा; वरना मुफ़लिस।',
      'categoryLabel': 'खेल',
      'playersLabel': 'खिलाड़ी',
      'turnTimeLabel': 'चाल का समय',
      'yourChipsLabel': 'आपके चिप्स',
      'canSitHere': 'आप इस टेबल पर बैठ सकते हैं।',
      'playersUpTo': '{n} तक',
      'secondsEach': '{n} सेकंड',
      'variationRulesIntro':
          'पहली चाल वाले खिलाड़ी के पास यह चुनने के लिए 10 सेकंड होते हैं कि हाथ किस नियम से तय होगा; न चुनने पर मुफ़लिस खेला जाता है। जोकर पत्ता वही पत्ता माना जाता है जिससे आपका हाथ सबसे अच्छा बने। दूसरों के चिप्स छिपे रहते हैं और पॉट की कोई सीमा नहीं है।',
      'variationChooseTitle': 'वेरिएशन चुनें',
      'variationSelectingBy': '{name} वेरिएशन चुन रहे हैं…',
      'variationChosen': 'वेरिएशन: {variation}',
      'variationLeftChosen': '{name} टेबल छोड़ गए — मुफ़लिस चुना गया',
      'variationAutoChosen': 'समय समाप्त — मुफ़लिस चुना गया',
      'varMuflis': 'मुफ़लिस',
      'varAk47': 'AK47',
      'varJoker': 'जोकर',
      'varHukam': 'हुकुम',
      'varLowestJoker': 'सबसे छोटा जोकर',
      'varHighestJoker': 'सबसे बड़ा जोकर',
      'varFiveCard': '5-पत्ती',
      'varMuflisNote': 'सबसे कमज़ोर हाथ जीतता है',
      'varAk47Note': 'A, K, 4 और 7 जोकर हैं',
      'varJokerNote': 'खुले पत्ते की रैंक जोकर है',
      'varHukamNote': 'खुले पत्ते का रंग जोकर है',
      'varLowestJokerNote': 'आपका सबसे छोटा पत्ता जोकर है',
      'varHighestJokerNote': 'आपका सबसे बड़ा पत्ता जोकर है',
      'varFiveCardNote': 'आपके 5 पत्तों में से सबसे अच्छे 3',
      'wildCard': 'जोकर',
      'sideshowRunning': 'साइडशो',
      'accept': 'स्वीकारें',
      'decline': 'मना करें',
      'sideshowDeclined': 'आपका साइडशो मना कर दिया गया',
      'sideshowTimedOut': 'कोई जवाब नहीं — साइडशो रद्द',
      'sideshowCancelled': 'साइडशो रद्द हो गया',
      'sideshowYouLost': 'आपके पत्ते कमज़ोर थे — आप पैक हुए',
      'sideshowYouWon': 'आपके पत्ते बेहतर थे — वे पैक हुए',
      'force': 'फ़ोर्स',
      'forceSideshow': 'फ़ोर्स साइडशो',
      'forceSideshowTitle': 'फ़ोर्स साइडशो करें?',
      'forceSideshowBody':
          '{name} के साथ फ़ोर्स साइडशो के लिए 1 हथौड़ा खर्च करें?',
      'forceSideshowNote': 'वे मना नहीं कर सकते, और बराबरी पर आप हारेंगे।',
      'noHammersTitle': 'कोई हथौड़ा नहीं बचा',
      'noHammersBody': 'फ़ोर्स साइडशो में 1 हथौड़ा लगता है। स्टोर से और लें?',
      'getHammers': 'हथौड़े लें',
      'noHammers': 'फ़ोर्स साइडशो के लिए हथौड़ा चाहिए',
      'sideshowForcedByYou': 'आपने {name} के साथ फ़ोर्स साइडशो किया',
      'sideshowForcedOnYou': '{name} ने आपके साथ फ़ोर्स साइडशो किया',
      'sideshowForcedOn': '{from} ने {to} पर फ़ोर्स साइडशो किया',
      'missile': 'मिसाइल',
      'fireMissileTitle': 'मिसाइल दागें?',
      'fireMissileBody':
          'हाथ में बचे सभी खिलाड़ियों के पत्ते खुलेंगे और सबसे अच्छे पत्ते पॉट जीतेंगे। 1 मिसाइल लगेगी।',
      'fireMissileNote': 'बराबरी पर आप हारेंगे।',
      'fire': 'दागें',
      'missileTooLate':
          'देर हो गई — मिसाइल नहीं दागी गई। कोई मिसाइल खर्च नहीं हुई।',
      'noMissilesTitle': 'कोई मिसाइल नहीं बची',
      'noMissilesBody':
          'मिसाइल दागने में 1 मिसाइल लगती है। स्टोर में हीरों से और लें?',
      'getMissiles': 'मिसाइलें लें',
      'noMissiles': 'मिसाइल दागने के लिए मिसाइल चाहिए',
      'tooFewPlayers': 'इसके लिए हाथ में कम से कम 3 खिलाड़ी होने चाहिए',
      'missileNeedsShowChips': 'मिसाइल दागने के लिए शो जितनी चिप्स चाहिए',
      'missileFiredByYou': 'आपने मिसाइल दागी',
      'missileFiredBy': '{name} ने मिसाइल दागी',
      'storeTabMissiles': 'मिसाइलें',
      'storeMissilesTitle': 'मिसाइल स्टोर',
      'storeMissilesBlurb': 'हीरे बदलें: 15 हीरे = 1 मिसाइल।',
      'tradeMissilesTitle': 'हीरे बदलें?',
      'tradeMissilesBody': '{diamonds} हीरे देकर {missiles} मिसाइलें लें?',
      'tradeMissileBodyOne': '{diamonds} हीरे देकर 1 मिसाइल लें?',
      'trade': 'बदलें',
      'notEnoughDiamondsTitle': 'पर्याप्त हीरे नहीं',
      'notEnoughDiamondsBody':
          'इस सौदे के लिए {diamonds} हीरे चाहिए। और हीरे लें?',
      'getDiamonds': 'हीरे लें',
      'missilesAdded': '{n} मिसाइलें आपके वॉलेट में जुड़ गईं',
      'missileAddedOne': '1 मिसाइल आपके वॉलेट में जुड़ गई',
      'rewardMissileTradedOne': 'मिसाइल आपके वॉलेट में है। टेबल पर इसे दागें।',
      'walletSummaryOneMissile': '{diamonds} हीरे, {hammers} हथौड़े, 1 मिसाइल',
      'rewardMissilesTraded':
          'मिसाइलें आपके वॉलेट में हैं। टेबल पर मिसाइल दागें।',
      'premiumPackages': 'प्रीमियम पैकेज',
      'posPremiumPackage': 'प्रीमियम पैकेज',
      'plusMissileOne': '+1 मिसाइल',
      'plusMissiles': '+{n} मिसाइलें',
      'plusHammers': '+{n} हथौड़े',
      'plusHammerOne': '+{n} हथौड़ा',
      'rewardPremiumPurchased':
          'आपका प्रीमियम पैकेज आपके वॉलेट में है। शुभकामनाएँ।',
      'premiumAdded':
          'प्रीमियम पैकेज जुड़ गया: {chips} चिप्स, {missiles} मिसाइलें और {hammers} हथौड़े',
      'premiumAddedOneMissile':
          'प्रीमियम पैकेज जुड़ गया: {chips} चिप्स, 1 मिसाइल और {hammers} हथौड़े',
      'seeCards': 'पत्ते देखें',
      'blindMovesLeft': 'ब्लाइंड चालें बाकी',
      'blindMovesLabel': 'ब्लाइंड चालें बाकी',
      'lastBlindMove': 'आख़िरी ब्लाइंड चाल',
      'inPot': 'पॉट में',
      'waiting': 'इंतज़ार',
      'offline': 'ऑफ़लाइन',
      'packed': 'पैक',
      'autoPacked': 'लगातार चालें चूकीं',
      'autoPackedOne': 'चाल चूकी',
      'lastWarning': 'आखिरी चेतावनी',
      'missOneMore': 'यह चाल चूके तो आप टेबल से बाहर हो जाएंगे।',
      'missedTurnsLabel': 'चूकी चालें',
      'resumingTable': 'आपकी टेबल पर वापस जा रहे हैं…',
      'welcomeBack': 'वापसी पर स्वागत है — आप अपनी टेबल पर वापस हैं।',
      'appVersion': 'ऐप संस्करण',
      'tableLost': 'आप दूर थे तब आपकी सीट छूट गई।',
      'notConnected': 'कनेक्शन नहीं है। यह नहीं भेजा गया।',
      'reconnecting': 'कनेक्शन टूट गया। फिर से जुड़ रहे हैं…',
      'kickedNoChips':
          'इस टेबल पर बने रहने के लिए आपके पास पर्याप्त चिप्स नहीं हैं।',
      'kickedIdle': 'लगातार {n} चालें चूकने पर आप टेबल से हट गए।',
      'leaveStakeStays': 'आपका दांव पॉट में रहेगा',
      'winner': 'विजेता',
      'tableChat': 'टेबल चैट',
      'saySomething': 'कुछ कहें…',
      'tableMenu': 'टेबल मेनू',
      'quickMessagesTitle': 'झटपट संदेश',
      'quickMessagesTip': 'झटपट संदेश भेजें',
      'quickPlayBlind': 'कृपया ब्लाइंड खेलें।',
      'quickPlayFast': 'कृपया जल्दी खेलें।',
      'quickHowToWin': 'ऐसे जीतते हैं।',
      'quickUnlucky': 'मेरी क़िस्मत ख़राब है।',
      'quickYouGotLucky': 'आपकी क़िस्मत अच्छी थी।',
      'quickOops': 'उफ़! मुझे यह नहीं खेलना चाहिए था।',
      'quickTakeSideshow': 'कृपया साइडशो करें।',
      'quickTakeShow': 'कृपया शो करें।',
      'quickSwitchTable': 'टेबल बदलें।',
      'quickHelpMe': 'कृपया मेरी मदद करें।',
      'yourChips': 'आपके चिप्स',
      'maxPot': 'अधिकतम पॉट',
      'nightMode': 'रात मोड',
      'dayMode': 'दिन मोड',
      'appearance': 'रूप',
      'themeSystem': 'सिस्टम',
      'unlock': 'अनलॉक करें',
      'unlockTitle': 'यह तस्वीर अनलॉक करें?',
      'unlockBody': '{name} की कीमत {cost} चिप्स है। अभी अनलॉक करके लगाएँ?',
      'unlockBodyDiamond':
          '{name} की कीमत {cost} डायमंड है। अभी अनलॉक करके लगाएँ?',
      'pictureUnlocked': 'अनलॉक',
      'tapToChangePicture': 'तस्वीर बदलने के लिए टैप करें',
      'rentForDays': '{days} दिन',
      'daysLeft': '{days} दिन बाकी',
      'hoursLeft': '{n} घंटे बाकी',
      'minutesLeft': '{n} मिनट बाकी',
      'unlockRentBody':
          '{name} की कीमत {cost} चिप्स है और यह {time} तक आपका रहेगा। अभी अनलॉक करके लगाएँ?',
      'unlockRentBodyDiamond':
          '{name} की कीमत {cost} डायमंड है और यह {time} तक आपका रहेगा। अभी अनलॉक करके लगाएँ?',
      'unlockBodyHammers':
          '{name} की कीमत {cost} हथौड़े है। अभी अनलॉक करके लगाएँ?',
      'unlockBodyHammerOne':
          '{name} की कीमत 1 हथौड़ा है। अभी अनलॉक करके लगाएँ?',
      'unlockRentBodyHammers':
          '{name} की कीमत {cost} हथौड़े है और यह {time} तक आपका रहेगा। अभी अनलॉक करके लगाएँ?',
      'unlockRentBodyHammerOne':
          '{name} की कीमत 1 हथौड़ा है और यह {time} तक आपका रहेगा। अभी अनलॉक करके लगाएँ?',
      'notEnoughHammersTitle': 'पर्याप्त हथौड़े नहीं',
      'notEnoughHammersBody': '{name} की कीमत {cost} हथौड़े है। और हथौड़े लें?',
      'notEnoughHammersBodyOne': '{name} की कीमत 1 हथौड़ा है। और हथौड़े लें?',
      'notEnoughDiamondsPictureBody':
          '{name} की कीमत {cost} डायमंड है। और हीरे लें?',
      'pictureChipsLobbyOnly':
          'चिप्स वाली तस्वीर सिर्फ़ लॉबी में खरीदी जा सकती है।',
      'pictureAll': 'सभी',
      'picturePremium': 'प्रीमियम',
      'priceLowToHigh': 'कीमत: कम से ज़्यादा',
      'priceHighToLow': 'कीमत: ज़्यादा से कम',
      'picturePremiumAnimated': 'प्रीमियम (एनिमेटेड)',
      'pictureShelfEmpty': 'यहाँ अभी कोई तस्वीर नहीं है।',
      'pictureOwnedTitle': 'पहले से अनलॉक है',
      'timeDay': '{n} दिन',
      'timeDays': '{n} दिन',
      'timeHour': '{n} घंटा',
      'timeHours': '{n} घंटे',
      'timeMinute': '{n} मिनट',
      'timeMinutes': '{n} मिनट',
      'timeLeft': '{time} बाकी',
      'pictureKeeps': 'हमेशा के लिए आपकी',
      'rentalLapsed': 'किराये की अवधि ख़त्म हो गई',
      'rentalEnds': 'समाप्ति: {date}',
      'rentalEnded': 'समाप्त हुई: {date}',
      'wear': 'लगाएँ',
      'wearing': 'लगी हुई है',
      'themeDark': 'डार्क',
      'themeLight': 'लाइट',
      'waitingForPlayers': 'खिलाड़ियों का इंतज़ार',
      'startingGame': 'खेल शुरू हो रहा है…',
      'buyChipsToStay': 'सीट बचाने के लिए {seconds} सेकंड में चिप्स खरीदें',
      'youAreWinner': 'आप जीत गए',
      'isTheWinner': 'जीत गए',
      'leaveTable': 'टेबल छोड़ें',
      'leaveTableQ': 'यह टेबल छोड़ें?',
      'leaveMidHand':
          'आप एक हाथ में हैं। छोड़ने पर आपके पत्ते पैक हो जाएँगे और आपका दांव पॉट में रहेगा।',
      'leaveAnytime': 'आप तुरंत दूसरी टेबल पर जुड़ सकते हैं।',
      'stay': 'रुकें',
      'leave': 'छोड़ें',
      'switchTable': 'टेबल बदलें',
      'switchTableQ': 'टेबल बदलें?',
      'switchMidHand':
          'आप एक हाथ में हैं। हटने पर आपके पत्ते पैक हो जाएँगे और आपका दांव पॉट में रहेगा।',
      'switchIdle':
          'आपको उसी तरह की दूसरी टेबल पर बैठाया जाएगा। अगर कहीं जगह नहीं हुई, तो यही टेबल बनी रहेगी।',
      'switchAction': 'बदलें',
      'quitGameQ': 'गेम बंद करें?',
      'quitGameBody': 'आप कभी भी लौट सकते हैं — आपके चिप्स सुरक्षित हैं।',
      'quit': 'बंद करें',
      'cancel': 'रद्द करें',
      'consentTitle': 'खेलने से पहले',
      'consentBody':
          'मैं पुष्टि करता/करती हूँ कि इस गेम को खेलने से मुझे किसी भी तरह का पैसा या अन्य लाभ जीतने की कोई अपेक्षा नहीं है।',
      'consentNote':
          'यह गेम केवल मनोरंजन के लिए है। चिप्स का कोई नकद मूल्य नहीं है और इन्हें पैसे या किसी और चीज़ से बदला नहीं जा सकता।',
      'consentAccept': 'पुष्टि करें',
      'joinAnother': 'आप तुरंत दूसरी टेबल पर जुड़ सकते हैं',
      'noOtherTable':
          'इस दांव पर अभी किसी और {category} टेबल पर सीट खाली नहीं है',
      'rules': 'नियम',
      'rulesTitle': 'पत्तों की रैंकिंग',
      'rulesBeats': 'सबसे ऊपर सबसे मज़बूत। ऊपर वाला हाथ नीचे वाले सब पर भारी।',
      'rankTrail': 'ट्रेल',
      'rankTrailNote': 'एक ही रैंक के तीन पत्ते',
      'rankPureSeq': 'प्योर सीक्वेंस',
      'rankPureSeqNote': 'लगातार तीन, एक ही रंग के',
      'rankSeq': 'सीक्वेंस',
      'rankSeqNote': 'लगातार तीन, किसी भी रंग के',
      'rankColor': 'कलर',
      'rankColorNote': 'एक ही रंग के तीन, लगातार नहीं',
      'rankPair': 'पेयर',
      'rankPairNote': 'एक ही रैंक के दो पत्ते',
      'rankHigh': 'हाई कार्ड',
      'rankHighNote': 'कुछ नहीं बना; सबसे बड़ा पत्ता जीतता है',
      'runOrder': 'सीक्वेंस का क्रम',
      'runOrderNote': 'A-K-Q सबसे ऊँचा, फिर A-2-3, फिर K-Q-J से लेकर 4-3-2 तक।',
      'close': 'बंद करें',
      'changeName': 'नाम बदलें',
      'save': 'सहेजें',
      'nameSaved': 'नाम बदल गया।',
      'cappedTitle': 'यह टेबल आपके लिए बंद है',
      'cappedBody':
          '{cap} से ज़्यादा चिप्स रखने वाले खिलाड़ी इस टेबल पर नहीं बैठ सकते।',
      'lockedTitle': 'यह टेबल अभी बंद है',
      'lockedBody': 'इस टेबल पर बैठने के लिए {min} चिप्स चाहिए।',
      'entryLabel': 'प्रवेश',
      'entryOpen': 'सबके लिए खुला',
      'entryUpTo': '{cap} तक',
      'entryFrom': '{min} या ज़्यादा',
      'useSocialPicture': 'मेरी Google या Facebook तस्वीर लगाएँ',
      'guestNoSocial':
          'अपनी तस्वीर लगाने के लिए Google या Facebook से साइन इन करें।',

      // --- the poker family
      'poker': 'पोकर',
      'pokerTableNote': 'होल्डम, ओमाहा, 5-कार्ड ड्रॉ और 3-कार्ड पोकर',
      'pokerTexasHoldem': 'टेक्सस होल्डम',
      'pokerOmaha': 'ओमाहा',
      'pokerFiveCardDraw': '5-कार्ड ड्रॉ',
      'pokerThreeCardPoker': '3-कार्ड पोकर',
      'pokerTexasHoldemNote': 'हर एक को दो पत्ते, बोर्ड पर पाँच',
      'pokerOmahaNote': 'हर एक को चार पत्ते, उनमें से ठीक दो खेलें',
      'pokerFiveCardDrawNote': 'हर एक को पाँच पत्ते, जो नहीं चाहिए उन्हें बदलें',
      'pokerThreeCardPokerNote': 'हर एक को तीन पत्ते, डीलर के खिलाफ़',
      'blindsLabel': 'ब्लाइंड्स',
      'anteLabel': 'एंटी',
      'buyInLabel': 'बाय-इन',
      'holeCardsLabel': 'हर एक को पत्ते',
      'maxDiscardsLabel': 'अधिकतम बदलें',
      'buyInFrom': '{min} से',
      'fold': 'फ़ोल्ड',
      'check': 'चेक',
      'call': 'कॉल',
      'bet': 'बेट',
      'raise': 'रेज़',
      'allIn': 'ऑल-इन',
      'play': 'प्ले',
      'draw': 'ड्रॉ',
      'standPat': 'पत्ते रखें',
      'exchangeUpTo': 'बदलने के लिए {n} तक पत्ते चुनें',
      'playOrFold': 'प्ले या फ़ोल्ड?',
      'dealerLabel': 'डीलर',
      'dealerQualifies': 'डीलर क्वालिफ़ाई',
      'dealerNotQualified': 'डीलर क्वालिफ़ाई नहीं',
      'youWon': 'आपने {amount} जीते',
      'youLost': 'आप हारे',
      'outcomeWin': 'जीत',
      'outcomeLose': 'हार',
      'push': 'बराबर',
      'potLabel': 'पॉट',
      'sidePotLabel': 'साइड पॉट',
      'boardLabel': 'बोर्ड',
      'streetPreflop': 'प्री-फ़्लॉप',
      'streetFlop': 'फ़्लॉप',
      'streetTurn': 'टर्न',
      'streetRiver': 'रिवर',
      'streetPredraw': 'ड्रॉ से पहले',
      'streetDraw': 'ड्रॉ',
      'streetPostdraw': 'ड्रॉ के बाद',
      'streetDecision': 'फ़ैसला',
      'streetShowdown': 'शोडाउन',
      'pokerTimedOut': 'आपका समय खत्म हो गया और आपका हाथ फ़ोल्ड हो गया',
      'pokerRulesTitle': 'पोकर टेबल',
      'pokerRulesIntro':
          'चार पोकर खेल, सब एक ही पाँच-पत्ती रैंकिंग से आँके जाते हैं। हाथ वह '
          'सबसे अच्छे पाँच पत्ते हैं जो आप बना सकें।',
      'pokerRankRoyalFlush': 'रॉयल फ़्लश',
      'pokerRankStraightFlush': 'स्ट्रेट फ़्लश',
      'pokerRankFourOfAKind': 'फ़ोर ऑफ़ अ काइंड',
      'pokerRankFullHouse': 'फ़ुल हाउस',
      'pokerRankFlush': 'फ़्लश',
      'pokerRankStraight': 'स्ट्रेट',
      'pokerRankThreeOfAKind': 'थ्री ऑफ़ अ काइंड',
      'pokerRankTwoPair': 'टू पेयर',
      'pokerRankPair': 'पेयर',
      'pokerRankHighCard': 'हाई कार्ड',
      'pokerThreeCardRanking':
          '3-कार्ड पोकर में स्ट्रेट फ़्लश से बड़ा है, और थ्री ऑफ़ अ काइंड दोनों से।',
      'rulePokerBlinds': 'हर हाथ {small} और {big} के ब्लाइंड्स से शुरू होता है',
      'rulePokerAnte': 'बाँटने से पहले हर कोई {ante} की एंटी लगाता है',
      'rulePokerBuyIn': 'कम से कम {min} लेकर बैठें',
      'rulePokerHoleCards': 'हर खिलाड़ी को {n} पत्ते बाँटे जाते हैं',
      'rulePokerHoldemWin':
          'अपने दो पत्तों और बोर्ड के पाँच से अपने सबसे अच्छे पाँच बनाएँ',
      'rulePokerOmahaWin':
          'आपके चार में से ठीक दो पत्ते और बोर्ड के तीन से हाथ बनता है',
      'rulePokerDrawWin': 'बेट करें, एक बार {n} तक पत्ते बदलें, फिर दोबारा बेट करें',
      'rulePokerThreeCardWin':
          'एंटी के बराबर प्ले करें या फ़ोल्ड; आपके तीन पत्ते डीलर से मिलाए जाते हैं',
      'rulePokerDealerQualifies':
          'डीलर को खेलने के लिए क्वीन-हाई चाहिए; न हो तो आपका प्ले बेट वापस और '
          'एंटी जीतती है',
      'rulePokerBestHandWins':
          'शोडाउन में सबसे अच्छा हाथ पॉट लेता है; अकेला बचा खिलाड़ी बिना शोडाउन के',
      'refuseNotYourTurn': 'आपकी बारी नहीं है',
      'refuseInvalidAction': 'यह चाल अभी नहीं चल सकती',
      'refuseInvalidAmount': 'यह रकम मान्य नहीं है',
      'refuseInvalidDiscard': 'ये पत्ते बदले नहीं जा सकते',
      'refuseInsufficientChips': 'इसके लिए चिप्स काफ़ी नहीं हैं',
      'refuseNoHand': 'अभी कोई हाथ नहीं चल रहा',
      'refuseNotInHand': 'आप इस हाथ में नहीं हैं',
      'refuseWrongGame': 'यह चाल किसी और खेल की है',
      'refuseDuplicateAction': 'यह चाल पहले ही भेजी जा चुकी है',
      'refuseUnknownAction': 'यह चाल टेबल नहीं जानती',
    },
    'bn': {
      'signInSubtitle': 'খেলতে সাইন ইন করুন।',
      'displayName': 'নাম',
      'playerHint': 'খেলোয়াড়',
      'playAsGuest': 'অতিথি হিসেবে খেলুন',
      'signingIn': 'সাইন ইন হচ্ছে…',
      'continueGoogle': 'Google দিয়ে চালিয়ে যান',
      'continueFacebook': 'Facebook দিয়ে চালিয়ে যান',
      'privacyPolicy': 'গোপনীয়তা নীতি',
      'signInUnavailable':
          'এই সংস্করণে {provider} সাইন-ইন উপলব্ধ নয়। আপাতত গেস্ট হিসেবে খেলুন।',
      'boot': 'বুট',
      'maxBlindsLabel': 'ব্লাইন্ড চাল সর্বোচ্চ',
      'potLimitLabel': 'পট সীমা',
      'potUnlimited': 'সীমাহীন',
      'tapToSit': 'বসতে ট্যাপ করুন',
      'everyoneChips': 'সবার চিপ দেখা যায়',
      'onlyYourChips': 'শুধু আপনার চিপ দেখা যায়',
      'seen': 'সিন',
      'blind': 'ব্লাইন্ড',
      'privateTable': 'প্রাইভেট টেবিল',
      'create': 'তৈরি করুন',
      'orJoinCode': 'অথবা কোড দিয়ে যোগ দিন:',
      'tableCode': 'টেবিল কোড',
      'invalidTableCode': 'টেবিল কোড ৮টি অক্ষর ও সংখ্যা দিয়ে হয়।',
      'join': 'যোগ দিন',
      'yourPicture': 'আপনার ছবি',
      'yourRecord': 'আপনার রেকর্ড',
      'handsPlayed': 'খেলা হাত',
      'won': 'জিতেছেন',
      'lost': 'হেরেছেন',
      'leftMidHand': 'মাঝপথে ছেড়েছেন',
      'totalWinnings': 'মোট জেতা',
      'biggestPot': 'সবচেয়ে বড় পট',
      'playedNote': 'কোনো চাল দিলে তবেই হাতটি গোনা হয়।',
      'fourHourBonus': '4-ঘণ্টার বোনাস',
      'dailyBonus': 'দৈনিক বোনাস',
      'milestone': 'মাইলস্টোন',
      'collect': 'নিন',
      'rewardCollected': 'পুরস্কার সংগ্রহ হয়েছে!',
      'rewardComeBack': '৪ ঘণ্টা পরে আবার আসুন।',
      'rewardComeBackDaily': '২৪ ঘণ্টা পরে আবার আসুন।',
      'bonusYouGet': 'আপনি পাবেন',
      'bonusNextIn': 'পরের পুরস্কার পাবেন',
      'bonusReadyNow': 'এখনই নেওয়া যাবে',
      'bonusEveryFourHours': 'প্রতি ৪ ঘণ্টায় নতুন বোনাস।',
      'bonusEveryDay': 'প্রতি ২৪ ঘণ্টায় নতুন বোনাস।',
      'rewardPurchased': 'চিপ আপনার ওয়ালেটে আছে। শুভকামনা।',
      'rewardDiamondsPurchased':
          'হীরে আপনার ওয়ালেটে আছে। এগুলো দিয়ে মিসাইল নিন।',
      'rewardMilestoneAgain': 'পরেরটির জন্য আরও ২৫ হাত।',
      'rewardRefused': 'এখনও নেওয়ার জন্য প্রস্তুত নয়।',
      'tapToClose': 'বন্ধ করতে ট্যাপ করুন',
      'buyChips': 'চিপ কিনুন',
      'shop': 'দোকান',
      'comingSoon': 'শীঘ্রই আসছে',
      'updateTitle': 'নতুন সংস্করণ প্রস্তুত',
      'updateBody':
          'খেলা চালিয়ে যেতে আপডেট করুন। এই সংস্করণটি আর সর্বশেষ নয়।',
      'updateNow': 'এখনই আপডেট করুন',
      'updateOpenStore': 'প্লে স্টোর খুলুন',
      'updateOpenAppStore': 'অ্যাপ স্টোর খুলুন',
      'updateFailed': 'আপডেট শেষ হয়নি। আবার চেষ্টা করুন।',
      'storeTitle': 'চিপ স্টোর',
      'storeBlurb': 'প্যাক যত বড়, বোনাসও তত বড়।',
      'storeTabChips': 'চিপস',
      'storeTabPictures': 'ছবি',
      'storeTabAnimated': 'অ্যানিমেটেড',
      'storePicturesBlurb': 'চিপস বা হাতুড়ি দিয়ে ছবি আনলক করুন।',
      'storeAnimatedBlurb': 'হাতুড়ি দিয়ে একটি অ্যানিমেটেড ছবি আনলক করুন।',
      'storeTabDiamonds': 'হীরে',
      'storeDiamondsTitle': 'হীরের দোকান',
      'storeDiamondsBlurb': 'হীরে দিয়ে মিসাইল নিন।',
      'storeTabHammers': 'হাতুড়ি',
      'storeHammersTitle': 'হাতুড়ি স্টোর',
      'storeHammersBlurb': 'হাতুড়ি দিয়ে না জিজ্ঞেস করেই সাইডশো হয়।',
      'rewardHammersPurchased':
          'হাতুড়ি আপনার ওয়ালেটে আছে। টেবিলে ফোর্স সাইডশো করুন।',
      'walletSummary':
          '{diamonds}টি হীরে, {hammers}টি হাতুড়ি, {missiles}টি মিসাইল',
      'storeBonus': 'বোনাস',
      'storeNotLive': 'পেমেন্ট এখনও চালু নয় — কোনও চার্জ হয়নি।',
      'posStarter': 'শুরু',
      'posPopular': 'জনপ্রিয়',
      'posBestValue': 'সেরা মূল্য',
      'posPremium': 'প্রিমিয়াম',
      'comingSoonBody':
          'চিপ কেনা এখনও চালু হয়নি। ততক্ষণ আপনার পুরস্কার নিতে থাকুন।',
      'handsToGo': 'হাত বাকি',
      'handToGo': 'হাত বাকি',
      'forceSideshowTooLate':
          'দেরি হয়ে গেছে — সেই সাইডশো আর সম্ভব নয়। কোনো হাতুড়ি খরচ হয়নি।',
      'settings': 'সেটিংস',
      'language': 'ভাষা',
      'numberSystem': 'সংখ্যা বিন্যাস',
      'numberIndian': 'ভারতীয়  ·  লাখ, কোটি',
      'numberInternational': 'আন্তর্জাতিক  ·  মিলিয়ন, বিলিয়ন',
      'unitLakh': 'লাখ',
      'unitCrore': 'কোটি',
      'unitMillion': 'মিলিয়ন',
      'unitBillion': 'বিলিয়ন',
      'switchTheme': 'থিম বদলান',
      'signOut': 'সাইন আউট',
      'signOutQ': 'সাইন আউট করবেন?',
      'signOutBody': 'আপনার চিপস, হীরে, হাতুড়ি আর ছবি এই অ্যাকাউন্টেই থাকবে।',
      'providerGuest': 'অতিথি',
      'unitHourShort': 'ঘ',
      'unitMinuteShort': 'মি',
      'unitSecondShort': 'সে',
      'serviceUnavailable': 'পরিষেবা উপলব্ধ নেই',
      'soundLabel': 'শব্দ',
      'vibrationLabel': 'কম্পন',
      'useProviderPicture': 'আমার Google/Facebook ছবি ব্যবহার করুন',
      'pictureChangeAnytime': 'আপনি এটি যেকোনো সময় বদলাতে পারেন, টেবিলে বসেও।',
      'pot': 'পট',
      'stake': 'বাজি',
      'yourTurn': 'আপনার পালা',
      'toAct': 'এর পালা',
      'pack': 'প্যাক',
      'chaal': 'চাল',
      'show': 'শো',
      'sideshow': 'সাইডশো',
      'sideshowWith': 'তুলনা করুন',
      'sideshowAsksYou': 'আপনার সঙ্গে তাস মেলাতে চায়',
      // variation tables: the first player picks the rules of the hand
      'variation': 'ভেরিয়েশন',
      'variationTableNote': 'প্রতিটি হাতের নিয়ম প্রথম খেলোয়াড় বেছে নেন',
      'viewTables': 'টেবিল দেখুন',
      'tablesLabel': 'টেবিল',
      'openToYouLabel': 'আপনার জন্য খোলা',
      'backToCategories': 'সব খেলা',
      'variationRulesTitle': 'ভেরিয়েশন টেবিল',
      'tableInfoTitle': 'টেবিলের তথ্য',
      'tableRulesTitle': 'এই টেবিল যেভাবে খেলা হয়',
      'tableRulesKey': 'টেবিলের নিয়ম',
      'ruleBlindMoves':
          'আপনি {n} বার পর্যন্ত ব্লাইন্ড চাল দিতে পারেন; তারপর আপনার তাস আপনার জন্য খুলে যায়।',
      'ruleRaiseOnce': 'নিজের পালায়: চাল, অথবা একবার দ্বিগুণ রেইজ।',
      'ruleRaiseFree':
          'নিজের পালায়: চাল, অথবা চিপস যতদূর যায় ততবার দ্বিগুণ করুন।',
      'rulePotCapped': 'পট {pot} হলে সব হাত দেখানো হয় এবং সেরা হাত জেতে।',
      'rulePotOpen': 'পটের কোনো সীমা নেই।',
      'ruleRoundsEnd': 'সব রাউন্ড শেষ হলে সব হাত দেখানো হয় এবং সেরা হাত জেতে।',
      'ruleShowTwo':
          'মাত্র দুজন খেলোয়াড় বাকি থাকলে যে কেউ শো-এর জন্য দিতে পারেন।',
      'ruleVariationPick':
          'প্রথম চালের খেলোয়াড় ১০ সেকেন্ড সময় পান হাত কীভাবে ঠিক হবে তা বাছতে; নইলে মুফলিস।',
      'categoryLabel': 'খেলা',
      'playersLabel': 'খেলোয়াড়',
      'turnTimeLabel': 'চালের সময়',
      'yourChipsLabel': 'আপনার চিপস',
      'canSitHere': 'আপনি এই টেবিলে বসতে পারেন।',
      'playersUpTo': '{n} জন পর্যন্ত',
      'secondsEach': '{n} সেকেন্ড',
      'variationRulesIntro':
          'প্রথম চালের খেলোয়াড় ১০ সেকেন্ড সময় পান হাতটি কোন নিয়মে ঠিক হবে তা বেছে নিতে; না বাছলে মুফলিস খেলা হয়। জোকার তাস সেই তাস হিসেবে গণ্য হয় যাতে আপনার হাত সবচেয়ে ভালো হয়। অন্যদের চিপস লুকানো থাকে এবং পটের কোনো সীমা নেই।',
      'variationChooseTitle': 'ভেরিয়েশন বেছে নিন',
      'variationSelectingBy': '{name} ভেরিয়েশন বেছে নিচ্ছেন…',
      'variationChosen': 'ভেরিয়েশন: {variation}',
      'variationLeftChosen':
          '{name} টেবিল ছেড়ে গেছেন — মুফলিস বেছে নেওয়া হলো',
      'variationAutoChosen': 'সময় শেষ — মুফলিস বেছে নেওয়া হলো',
      'varMuflis': 'মুফলিস',
      'varAk47': 'AK47',
      'varJoker': 'জোকার',
      'varHukam': 'হুকুম',
      'varLowestJoker': 'সবচেয়ে ছোট জোকার',
      'varHighestJoker': 'সবচেয়ে বড় জোকার',
      'varFiveCard': '৫-তাস',
      'varMuflisNote': 'সবচেয়ে দুর্বল হাত জেতে',
      'varAk47Note': 'A, K, 4 ও 7 জোকার',
      'varJokerNote': 'খোলা তাসের র‍্যাঙ্ক জোকার',
      'varHukamNote': 'খোলা তাসের রং জোকার',
      'varLowestJokerNote': 'আপনার সবচেয়ে ছোট তাস জোকার',
      'varHighestJokerNote': 'আপনার সবচেয়ে বড় তাস জোকার',
      'varFiveCardNote': 'আপনার ৫ তাসের সেরা ৩টি',
      'wildCard': 'জোকার',
      'sideshowRunning': 'সাইডশো',
      'accept': 'গ্রহণ করুন',
      'decline': 'প্রত্যাখ্যান',
      'sideshowDeclined': 'আপনার সাইডশো প্রত্যাখ্যান করা হয়েছে',
      'sideshowTimedOut': 'কোনও উত্তর নেই — সাইডশো বাতিল',
      'sideshowCancelled': 'সাইডশো বাতিল হয়েছে',
      'sideshowYouLost': 'আপনার তাস দুর্বল ছিল — আপনি প্যাক হলেন',
      'sideshowYouWon': 'আপনার তাস ভালো ছিল — তিনি প্যাক হলেন',
      'force': 'ফোর্স',
      'forceSideshow': 'ফোর্স সাইডশো',
      'forceSideshowTitle': 'ফোর্স সাইডশো করবেন?',
      'forceSideshowBody':
          '{name}-এর সঙ্গে ফোর্স সাইডশো করতে 1টি হাতুড়ি খরচ করবেন?',
      'forceSideshowNote': 'তিনি না বলতে পারবেন না, আর সমান হলে আপনি হারবেন।',
      'noHammersTitle': 'কোনও হাতুড়ি নেই',
      'noHammersBody':
          'ফোর্স সাইডশো করতে 1টি হাতুড়ি লাগে। স্টোর থেকে আরও নেবেন?',
      'getHammers': 'হাতুড়ি নিন',
      'noHammers': 'ফোর্স সাইডশো করতে একটি হাতুড়ি লাগবে',
      'sideshowForcedByYou': 'আপনি {name}-এর সঙ্গে ফোর্স সাইডশো করলেন',
      'sideshowForcedOnYou': '{name} আপনার সঙ্গে ফোর্স সাইডশো করলেন',
      'sideshowForcedOn': '{from} {to}-এর সঙ্গে ফোর্স সাইডশো করলেন',
      'missile': 'মিসাইল',
      'fireMissileTitle': 'মিসাইল ছুড়বেন?',
      'fireMissileBody':
          'হাতে থাকা সব খেলোয়াড়ের তাস খুলবে এবং সেরা হাত পট জিতবে। খরচ 1টি মিসাইল।',
      'fireMissileNote': 'টাই হলে আপনি হারবেন।',
      'fire': 'ছুড়ুন',
      'missileTooLate':
          'দেরি হয়ে গেছে — মিসাইল ছোড়া হয়নি। কোনো মিসাইল খরচ হয়নি।',
      'noMissilesTitle': 'কোনো মিসাইল বাকি নেই',
      'noMissilesBody':
          'মিসাইল ছুড়তে 1টি মিসাইল লাগে। স্টোরে হীরে দিয়ে আরও নেবেন?',
      'getMissiles': 'মিসাইল নিন',
      'noMissiles': 'মিসাইল ছুড়তে একটি মিসাইল লাগবে',
      'tooFewPlayers': 'এর জন্য হাতে অন্তত 3 জন খেলোয়াড় থাকতে হবে',
      'missileNeedsShowChips': 'মিসাইল ছুড়তে শো-এর মতো চিপ লাগবে',
      'missileFiredByYou': 'আপনি মিসাইল ছুড়লেন',
      'missileFiredBy': '{name} মিসাইল ছুড়লেন',
      'storeTabMissiles': 'মিসাইল',
      'storeMissilesTitle': 'মিসাইল স্টোর',
      'storeMissilesBlurb': 'হীরে বদলান: 15টি হীরে = 1টি মিসাইল।',
      'tradeMissilesTitle': 'হীরে বদলাবেন?',
      'tradeMissilesBody': '{diamonds}টি হীরে দিয়ে {missiles}টি মিসাইল নেবেন?',
      'tradeMissileBodyOne': '{diamonds}টি হীরে দিয়ে 1টি মিসাইল নেবেন?',
      'trade': 'বদলান',
      'notEnoughDiamondsTitle': 'যথেষ্ট হীরে নেই',
      'notEnoughDiamondsBody':
          'এই বিনিময়ে {diamonds}টি হীরে লাগবে। আরও হীরে নেবেন?',
      'getDiamonds': 'হীরে নিন',
      'missilesAdded': '{n}টি মিসাইল আপনার ওয়ালেটে যোগ হয়েছে',
      'missileAddedOne': '1টি মিসাইল আপনার ওয়ালেটে যোগ হয়েছে',
      'rewardMissileTradedOne':
          'মিসাইলটি আপনার ওয়ালেটে আছে। টেবিলে এটি ছুড়ুন।',
      'walletSummaryOneMissile':
          '{diamonds}টি হীরে, {hammers}টি হাতুড়ি, 1টি মিসাইল',
      'rewardMissilesTraded':
          'মিসাইল আপনার ওয়ালেটে আছে। টেবিলে মিসাইল ছুড়ুন।',
      'premiumPackages': 'প্রিমিয়াম প্যাকেজ',
      'posPremiumPackage': 'প্রিমিয়াম প্যাকেজ',
      'plusMissileOne': '+1টি মিসাইল',
      'plusMissiles': '+{n}টি মিসাইল',
      'plusHammers': '+{n}টি হাতুড়ি',
      'plusHammerOne': '+{n}টি হাতুড়ি',
      'rewardPremiumPurchased':
          'আপনার প্রিমিয়াম প্যাকেজ ওয়ালেটে আছে। শুভকামনা।',
      'premiumAdded':
          'প্রিমিয়াম প্যাকেজ যোগ হয়েছে: {chips} চিপ, {missiles}টি মিসাইল ও {hammers}টি হাতুড়ি',
      'premiumAddedOneMissile':
          'প্রিমিয়াম প্যাকেজ যোগ হয়েছে: {chips} চিপ, 1টি মিসাইল ও {hammers}টি হাতুড়ি',
      'seeCards': 'তাস দেখুন',
      'blindMovesLeft': 'ব্লাইন্ড চাল বাকি',
      'blindMovesLabel': 'ব্লাইন্ড চাল বাকি',
      'lastBlindMove': 'শেষ ব্লাইন্ড চাল',
      'inPot': 'পটে',
      'waiting': 'অপেক্ষা',
      'offline': 'অফলাইন',
      'packed': 'প্যাক',
      'autoPacked': 'পরপর চাল মিস',
      'autoPackedOne': 'চাল মিস',
      'lastWarning': 'শেষ সতর্কতা',
      'missOneMore': 'এই চাল মিস করলে আপনি টেবিল ছাড়বেন।',
      'missedTurnsLabel': 'মিস করা চাল',
      'resumingTable': 'আপনার টেবিলে ফিরছি…',
      'welcomeBack': 'ফিরে আসায় স্বাগত — আপনি আপনার টেবিলে ফিরে এসেছেন।',
      'appVersion': 'অ্যাপ সংস্করণ',
      'tableLost': 'আপনি দূরে থাকাকালীন আপনার আসন চলে গেছে।',
      'notConnected': 'সংযোগ নেই। এটি পাঠানো যায়নি।',
      'reconnecting': 'সংযোগ বিচ্ছিন্ন। আবার যুক্ত হচ্ছে…',
      'kickedNoChips': 'এই টেবিলে থাকার মতো যথেষ্ট চিপ আপনার নেই।',
      'kickedIdle': 'পরপর {n}টি চাল মিস করায় আপনি টেবিল ছেড়েছেন।',
      'leaveStakeStays': 'আপনার বাজি পটেই থাকবে',
      'winner': 'বিজয়ী',
      'tableChat': 'টেবিল চ্যাট',
      'saySomething': 'কিছু বলুন…',
      'tableMenu': 'টেবিল মেনু',
      'quickMessagesTitle': 'দ্রুত বার্তা',
      'quickMessagesTip': 'দ্রুত বার্তা পাঠান',
      'quickPlayBlind': 'দয়া করে ব্লাইন্ড খেলুন।',
      'quickPlayFast': 'দয়া করে তাড়াতাড়ি খেলুন।',
      'quickHowToWin': 'এভাবেই জিততে হয়।',
      'quickUnlucky': 'আমার ভাগ্য খারাপ।',
      'quickYouGotLucky': 'আপনার ভাগ্য ভালো ছিল।',
      'quickOops': 'উফ! এটা খেলা আমার উচিত হয়নি।',
      'quickTakeSideshow': 'দয়া করে সাইডশো করুন।',
      'quickTakeShow': 'দয়া করে শো করুন।',
      'quickSwitchTable': 'টেবিল বদলান।',
      'quickHelpMe': 'দয়া করে আমাকে সাহায্য করুন।',
      'unlock': 'আনলক করুন',
      'unlockTitle': 'এই ছবিটি আনলক করবেন?',
      'unlockBody': '{name} এর দাম {cost} চিপস। এখনই আনলক করে ব্যবহার করবেন?',
      'unlockBodyDiamond':
          '{name} এর দাম {cost} ডায়মন্ড। এখনই আনলক করে ব্যবহার করবেন?',
      'pictureUnlocked': 'আনলক',
      'tapToChangePicture': 'ছবি বদলাতে ট্যাপ করুন',
      'rentForDays': '{days} দিন',
      'daysLeft': '{days} দিন বাকি',
      'hoursLeft': '{n} ঘণ্টা বাকি',
      'minutesLeft': '{n} মিনিট বাকি',
      'unlockRentBody':
          '{name} এর দাম {cost} চিপস এবং এটি {time} আপনার থাকবে। এখনই আনলক করে ব্যবহার করবেন?',
      'unlockRentBodyDiamond':
          '{name} এর দাম {cost} ডায়মন্ড এবং এটি {time} আপনার থাকবে। এখনই আনলক করে ব্যবহার করবেন?',
      'unlockBodyHammers':
          '{name} এর দাম {cost}টি হাতুড়ি। এখনই আনলক করে ব্যবহার করবেন?',
      'unlockBodyHammerOne':
          '{name} এর দাম 1টি হাতুড়ি। এখনই আনলক করে ব্যবহার করবেন?',
      'unlockRentBodyHammers':
          '{name} এর দাম {cost}টি হাতুড়ি এবং এটি {time} আপনার থাকবে। এখনই আনলক করে ব্যবহার করবেন?',
      'unlockRentBodyHammerOne':
          '{name} এর দাম 1টি হাতুড়ি এবং এটি {time} আপনার থাকবে। এখনই আনলক করে ব্যবহার করবেন?',
      'notEnoughHammersTitle': 'যথেষ্ট হাতুড়ি নেই',
      'notEnoughHammersBody':
          '{name} এর দাম {cost}টি হাতুড়ি। আরও হাতুড়ি নেবেন?',
      'notEnoughHammersBodyOne':
          '{name} এর দাম 1টি হাতুড়ি। আরও হাতুড়ি নেবেন?',
      'notEnoughDiamondsPictureBody':
          '{name} এর দাম {cost}টি হীরে। আরও হীরে নেবেন?',
      'pictureChipsLobbyOnly': 'চিপসের দামের ছবি শুধু লবিতে কেনা যায়।',
      'pictureAll': 'সব',
      'picturePremium': 'প্রিমিয়াম',
      'priceLowToHigh': 'দাম: কম থেকে বেশি',
      'priceHighToLow': 'দাম: বেশি থেকে কম',
      'picturePremiumAnimated': 'প্রিমিয়াম (অ্যানিমেটেড)',
      'pictureShelfEmpty': 'এখানে এখনও কোনো ছবি নেই।',
      'pictureOwnedTitle': 'আগেই আনলক করা',
      'timeDay': '{n} দিন',
      'timeDays': '{n} দিন',
      'timeHour': '{n} ঘণ্টা',
      'timeHours': '{n} ঘণ্টা',
      'timeMinute': '{n} মিনিট',
      'timeMinutes': '{n} মিনিট',
      'timeLeft': '{time} বাকি',
      'pictureKeeps': 'চিরকাল আপনার',
      'rentalLapsed': 'ভাড়ার মেয়াদ শেষ হয়েছে',
      'rentalEnds': 'মেয়াদ শেষ: {date}',
      'rentalEnded': 'শেষ হয়েছে: {date}',
      'wear': 'ব্যবহার করুন',
      'wearing': 'ব্যবহার হচ্ছে',
      'yourChips': 'আপনার চিপ',
      'maxPot': 'সর্বোচ্চ পট',
      'nightMode': 'রাত মোড',
      'dayMode': 'দিন মোড',
      'appearance': 'চেহারা',
      'themeSystem': 'সিস্টেম',
      'themeDark': 'ডার্ক',
      'themeLight': 'লাইট',
      'waitingForPlayers': 'খেলোয়াড়ের অপেক্ষা',
      'startingGame': 'খেলা শুরু হচ্ছে…',
      'buyChipsToStay': 'আসন রাখতে {seconds} সেকেন্ডের মধ্যে চিপস কিনুন',
      'youAreWinner': 'আপনি জিতেছেন',
      'isTheWinner': 'জিতেছেন',
      'leaveTable': 'টেবিল ছাড়ুন',
      'leaveTableQ': 'এই টেবিল ছাড়বেন?',
      'leaveMidHand':
          'আপনি একটি হাতে আছেন। ছাড়লে তাস প্যাক হবে এবং আপনার বাজি পটেই থাকবে।',
      'leaveAnytime': 'আপনি সঙ্গে সঙ্গে অন্য টেবিলে যোগ দিতে পারেন।',
      'stay': 'থাকুন',
      'leave': 'ছাড়ুন',
      'switchTable': 'টেবিল বদলান',
      'switchTableQ': 'টেবিল বদলাবেন?',
      'switchMidHand':
          'আপনি একটি হাতে আছেন। সরলে তাস প্যাক হবে এবং আপনার বাজি পটেই থাকবে।',
      'switchIdle':
          'আপনাকে একই ধরনের অন্য টেবিলে বসানো হবে। কোথাও জায়গা না থাকলে এই টেবিলই থাকবে।',
      'switchAction': 'বদলান',
      'quitGameQ': 'গেম বন্ধ করবেন?',
      'quitGameBody': 'যে কোনো সময় ফিরে আসতে পারেন — আপনার চিপ সংরক্ষিত।',
      'quit': 'বন্ধ করুন',
      'cancel': 'বাতিল',
      'consentTitle': 'খেলার আগে',
      'consentBody':
          'আমি নিশ্চিত করছি যে এই গেম খেলে কোনো অর্থ বা অন্য কোনো লাভ জেতার কোনো প্রত্যাশা আমার নেই।',
      'consentNote':
          'এই গেম শুধুমাত্র বিনোদনের জন্য। চিপের কোনো নগদ মূল্য নেই এবং টাকা বা অন্য কিছুর বিনিময়ে বদলানো যায় না।',
      'consentAccept': 'নিশ্চিত করছি',
      'joinAnother': 'আপনি সঙ্গে সঙ্গে অন্য টেবিলে যোগ দিতে পারেন',
      'noOtherTable': 'এই বাজিতে এখন অন্য কোনো {category} টেবিলে খালি আসন নেই',
      'rules': 'নিয়ম',
      'rulesTitle': 'তাসের র‍্যাঙ্কিং',
      'rulesBeats':
          'উপরেরটি সবচেয়ে শক্তিশালী। প্রতিটি হাত নিচের সবগুলিকে হারায়।',
      'rankTrail': 'ট্রেইল',
      'rankTrailNote': 'একই র‍্যাঙ্কের তিনটি তাস',
      'rankPureSeq': 'পিওর সিকোয়েন্স',
      'rankPureSeqNote': 'পরপর তিনটি, একই রঙের',
      'rankSeq': 'সিকোয়েন্স',
      'rankSeqNote': 'পরপর তিনটি, যেকোনো রঙের',
      'rankColor': 'কালার',
      'rankColorNote': 'একই রঙের তিনটি, পরপর নয়',
      'rankPair': 'পেয়ার',
      'rankPairNote': 'একই র‍্যাঙ্কের দুটি তাস',
      'rankHigh': 'হাই কার্ড',
      'rankHighNote': 'কিছুই হয়নি; সবচেয়ে বড় তাস জেতে',
      'runOrder': 'সিকোয়েন্সের ক্রম',
      'runOrderNote':
          'A-K-Q সবচেয়ে উঁচু, তারপর A-2-3, তারপর K-Q-J থেকে 4-3-2 পর্যন্ত।',
      'close': 'বন্ধ করুন',
      'changeName': 'নাম বদলান',
      'save': 'সেভ করুন',
      'nameSaved': 'নাম বদলে গেছে।',
      'cappedTitle': 'এই টেবিল আপনার জন্য বন্ধ',
      'cappedBody':
          '{cap} এর বেশি চিপ থাকা খেলোয়াড়েরা এই টেবিলে বসতে পারেন না।',
      'lockedTitle': 'এই টেবিল এখনো বন্ধ',
      'lockedBody': 'এই টেবিলে বসতে {min} চিপ দরকার।',
      'entryLabel': 'প্রবেশ',
      'entryOpen': 'সবার জন্য খোলা',
      'entryUpTo': '{cap} পর্যন্ত',
      'entryFrom': '{min} বা বেশি',
      'useSocialPicture': 'আমার Google বা Facebook ছবি ব্যবহার করুন',
      'guestNoSocial':
          'নিজের ছবি ব্যবহার করতে Google বা Facebook দিয়ে সাইন ইন করুন।',

      // --- the poker family
      'poker': 'পোকার',
      'pokerTableNote': 'হোল্ডেম, ওমাহা, ৫-কার্ড ড্র ও ৩-কার্ড পোকার',
      'pokerTexasHoldem': 'টেক্সাস হোল্ডেম',
      'pokerOmaha': 'ওমাহা',
      'pokerFiveCardDraw': '৫-কার্ড ড্র',
      'pokerThreeCardPoker': '৩-কার্ড পোকার',
      'pokerTexasHoldemNote': 'প্রত্যেকের দুটি তাস, বোর্ডে পাঁচটি',
      'pokerOmahaNote': 'প্রত্যেকের চারটি তাস, তার ঠিক দুটি খেলুন',
      'pokerFiveCardDrawNote': 'প্রত্যেকের পাঁচটি তাস, যেগুলো চান না বদলে নিন',
      'pokerThreeCardPokerNote': 'প্রত্যেকের তিনটি তাস, ডিলারের বিরুদ্ধে',
      'blindsLabel': 'ব্লাইন্ডস',
      'anteLabel': 'অ্যান্টি',
      'buyInLabel': 'বাই-ইন',
      'holeCardsLabel': 'প্রত্যেকের তাস',
      'maxDiscardsLabel': 'সর্বোচ্চ বদল',
      'buyInFrom': '{min} থেকে',
      'fold': 'ফোল্ড',
      'check': 'চেক',
      'call': 'কল',
      'bet': 'বেট',
      'raise': 'রেইজ',
      'allIn': 'অল-ইন',
      'play': 'প্লে',
      'draw': 'ড্র',
      'standPat': 'তাস রাখুন',
      'exchangeUpTo': 'বদলাতে {n}টি পর্যন্ত তাস বেছে নিন',
      'playOrFold': 'প্লে না ফোল্ড?',
      'dealerLabel': 'ডিলার',
      'dealerQualifies': 'ডিলার কোয়ালিফাই',
      'dealerNotQualified': 'ডিলার কোয়ালিফাই নয়',
      'youWon': 'আপনি {amount} জিতেছেন',
      'youLost': 'আপনি হেরেছেন',
      'outcomeWin': 'জয়',
      'outcomeLose': 'হার',
      'push': 'সমান',
      'potLabel': 'পট',
      'sidePotLabel': 'সাইড পট',
      'boardLabel': 'বোর্ড',
      'streetPreflop': 'প্রি-ফ্লপ',
      'streetFlop': 'ফ্লপ',
      'streetTurn': 'টার্ন',
      'streetRiver': 'রিভার',
      'streetPredraw': 'ড্র-এর আগে',
      'streetDraw': 'ড্র',
      'streetPostdraw': 'ড্র-এর পরে',
      'streetDecision': 'সিদ্ধান্ত',
      'streetShowdown': 'শোডাউন',
      'pokerTimedOut': 'আপনার সময় শেষ, হাত ফোল্ড হয়ে গেছে',
      'pokerRulesTitle': 'পোকার টেবিল',
      'pokerRulesIntro':
          'চারটি পোকার খেলা, সবই একই পাঁচ-তাসের র‍্যাঙ্কিং দিয়ে বিচার হয়। হাত '
          'হলো সেরা পাঁচটি তাস যা আপনি বানাতে পারেন।',
      'pokerRankRoyalFlush': 'রয়্যাল ফ্লাশ',
      'pokerRankStraightFlush': 'স্ট্রেট ফ্লাশ',
      'pokerRankFourOfAKind': 'ফোর অফ আ কাইন্ড',
      'pokerRankFullHouse': 'ফুল হাউস',
      'pokerRankFlush': 'ফ্লাশ',
      'pokerRankStraight': 'স্ট্রেট',
      'pokerRankThreeOfAKind': 'থ্রি অফ আ কাইন্ড',
      'pokerRankTwoPair': 'টু পেয়ার',
      'pokerRankPair': 'পেয়ার',
      'pokerRankHighCard': 'হাই কার্ড',
      'pokerThreeCardRanking':
          '৩-কার্ড পোকারে স্ট্রেট ফ্লাশকে হারায়, আর থ্রি অফ আ কাইন্ড দুটোকেই।',
      'rulePokerBlinds': 'প্রতিটি হাত {small} ও {big} ব্লাইন্ডস দিয়ে শুরু হয়',
      'rulePokerAnte': 'বিলি করার আগে সবাই {ante} অ্যান্টি দেন',
      'rulePokerBuyIn': 'অন্তত {min} নিয়ে বসুন',
      'rulePokerHoleCards': 'প্রতিটি খেলোয়াড় {n}টি তাস পান',
      'rulePokerHoldemWin':
          'আপনার দুটি তাস ও বোর্ডের পাঁচটি থেকে সেরা পাঁচ বানান',
      'rulePokerOmahaWin':
          'আপনার চারটির ঠিক দুটি ও বোর্ডের তিনটি দিয়ে হাত হয়',
      'rulePokerDrawWin':
          'বেট করুন, একবার {n}টি পর্যন্ত তাস বদলান, তারপর আবার বেট',
      'rulePokerThreeCardWin':
          'অ্যান্টির সমান প্লে করুন বা ফোল্ড; আপনার তিনটি তাস ডিলারের সঙ্গে '
          'মেলানো হয়',
      'rulePokerDealerQualifies':
          'ডিলারের খেলতে কুইন-হাই লাগে; না হলে আপনার প্লে বেট ফেরত আর অ্যান্টি '
          'জেতে',
      'rulePokerBestHandWins':
          'শোডাউনে সেরা হাত পট নেয়; একা টিকে থাকা খেলোয়াড় শোডাউন ছাড়াই',
      'refuseNotYourTurn': 'আপনার পালা নয়',
      'refuseInvalidAction': 'এই চাল এখন দেওয়া যাবে না',
      'refuseInvalidAmount': 'এই পরিমাণ গ্রহণযোগ্য নয়',
      'refuseInvalidDiscard': 'এই তাসগুলো বদলানো যাবে না',
      'refuseInsufficientChips': 'এর জন্য যথেষ্ট চিপ নেই',
      'refuseNoHand': 'এখন কোনো হাত চলছে না',
      'refuseNotInHand': 'আপনি এই হাতে নেই',
      'refuseWrongGame': 'এই চাল অন্য খেলার',
      'refuseDuplicateAction': 'এই চাল আগেই পাঠানো হয়েছে',
      'refuseUnknownAction': 'এই চাল টেবিলের জানা নেই',
    },
    'gu': {
      'signInSubtitle': 'રમવા માટે સાઇન ઇન કરો.',
      'displayName': 'નામ',
      'playerHint': 'ખેલાડી',
      'playAsGuest': 'મહેમાન તરીકે રમો',
      'signingIn': 'સાઇન ઇન થઈ રહ્યું છે…',
      'continueGoogle': 'Google થી ચાલુ રાખો',
      'continueFacebook': 'Facebook થી ચાલુ રાખો',
      'privacyPolicy': 'ગોપનીયતા નીતિ',
      'signInUnavailable':
          'આ વર્ઝનમાં {provider} સાઇન-ઇન ઉપલબ્ધ નથી. હાલ પૂરતું ગેસ્ટ તરીકે રમો.',
      'boot': 'બૂટ',
      'maxBlindsLabel': 'બ્લાઇન્ડ ચાલ મહત્તમ',
      'potLimitLabel': 'પોટ મર્યાદા',
      'potUnlimited': 'અમર્યાદિત',
      'tapToSit': 'બેસવા માટે ટૅપ કરો',
      'everyoneChips': 'બધાના ચિપ્સ દેખાય છે',
      'onlyYourChips': 'ફક્ત તમારા ચિપ્સ દેખાય છે',
      'seen': 'સીન',
      'blind': 'બ્લાઇન્ડ',
      'privateTable': 'પ્રાઇવેટ ટેબલ',
      'create': 'બનાવો',
      'orJoinCode': 'અથવા કોડથી જોડાઓ:',
      'tableCode': 'ટેબલ કોડ',
      'invalidTableCode': 'ટેબલ કોડ 8 અક્ષરો અને અંકોનો હોય છે.',
      'join': 'જોડાઓ',
      'yourPicture': 'તમારો ફોટો',
      'yourRecord': 'તમારો રેકોર્ડ',
      'handsPlayed': 'રમેલા હાથ',
      'won': 'જીત્યા',
      'lost': 'હાર્યા',
      'leftMidHand': 'વચ્ચે છોડ્યા',
      'totalWinnings': 'કુલ જીત',
      'biggestPot': 'સૌથી મોટો પોટ',
      'playedNote': 'કોઈ ચાલ ચાલો ત્યારે જ હાથ ગણાય છે.',
      'fourHourBonus': '4-કલાકનું બોનસ',
      'dailyBonus': 'દૈનિક બોનસ',
      'milestone': 'માઇલસ્ટોન',
      'collect': 'લો',
      'rewardCollected': 'ઇનામ મળી ગયું!',
      'rewardComeBack': '4 કલાક પછી ફરી આવો.',
      'rewardComeBackDaily': '24 કલાક પછી ફરી આવો.',
      'bonusYouGet': 'તમને મળશે',
      'bonusNextIn': 'આગલું ઇનામ મળશે',
      'bonusReadyNow': 'હવે લઈ શકો છો',
      'bonusEveryFourHours': 'દર 4 કલાકે નવું બોનસ.',
      'bonusEveryDay': 'દર 24 કલાકે નવું બોનસ.',
      'rewardPurchased': 'ચિપ્સ તમારા વૉલેટમાં છે. શુભકામના.',
      'rewardDiamondsPurchased': 'હીરા તમારા વૉલેટમાં છે. તેનાથી મિસાઇલ લો.',
      'rewardMilestoneAgain': 'આગલા માટે વધુ 25 હાથ.',
      'rewardRefused': 'હજી લેવા માટે તૈયાર નથી.',
      'tapToClose': 'બંધ કરવા ટૅપ કરો',
      'buyChips': 'ચિપ્સ ખરીદો',
      'shop': 'દુકાન',
      'comingSoon': 'ટૂંક સમયમાં',
      'updateTitle': 'નવું વર્ઝન તૈયાર છે',
      'updateBody': 'રમવાનું ચાલુ રાખવા અપડેટ કરો. આ વર્ઝન હવે જૂનું છે.',
      'updateNow': 'હમણાં અપડેટ કરો',
      'updateOpenStore': 'પ્લે સ્ટોર ખોલો',
      'updateOpenAppStore': 'એપ સ્ટોર ખોલો',
      'updateFailed': 'અપડેટ પૂરું થયું નથી. ફરી પ્રયાસ કરો.',
      'storeTitle': 'ચિપ સ્ટોર',
      'storeBlurb': 'પૅક જેટલું મોટું, બોનસ એટલું મોટું.',
      'storeTabChips': 'ચિપ્સ',
      'storeTabPictures': 'ફોટા',
      'storeTabAnimated': 'એનિમેટેડ',
      'storePicturesBlurb': 'ચિપ્સ અથવા હથોડીથી ફોટો અનલૉક કરો.',
      'storeAnimatedBlurb': 'હથોડીથી એનિમેટેડ ફોટો અનલૉક કરો.',
      'storeTabDiamonds': 'હીરા',
      'storeDiamondsTitle': 'હીરા સ્ટોર',
      'storeDiamondsBlurb': 'હીરા આપીને મિસાઇલ લો.',
      'storeTabHammers': 'હથોડી',
      'storeHammersTitle': 'હથોડી સ્ટોર',
      'storeHammersBlurb': 'હથોડીથી પૂછ્યા વગર સાઇડશો થાય છે.',
      'rewardHammersPurchased':
          'હથોડી તમારા વૉલેટમાં છે. ટેબલ પર ફોર્સ સાઇડશો કરો.',
      'walletSummary': '{diamonds} હીરા, {hammers} હથોડી, {missiles} મિસાઇલ',
      'storeBonus': 'બોનસ',
      'storeNotLive': 'પેમેન્ટ હજી ચાલુ નથી — કોઈ ચાર્જ લેવાયો નથી.',
      'posStarter': 'શરૂઆત',
      'posPopular': 'લોકપ્રિય',
      'posBestValue': 'સૌથી સારું',
      'posPremium': 'પ્રીમિયમ',
      'comingSoonBody':
          'ચિપ્સ ખરીદવાનું હજી શરૂ થયું નથી. ત્યાં સુધી તમારાં ઇનામ લેતા રહો.',
      'handsToGo': 'હાથ બાકી',
      'handToGo': 'હાથ બાકી',
      'forceSideshowTooLate':
          'મોડું થઈ ગયું — હવે એ સાઇડશો શક્ય નથી. કોઈ હથોડી વપરાઈ નથી.',
      'settings': 'સેટિંગ્સ',
      'language': 'ભાષા',
      'numberSystem': 'સંખ્યા ફોર્મેટ',
      'numberIndian': 'ભારતીય  ·  લાખ, કરોડ',
      'numberInternational': 'આંતરરાષ્ટ્રીય  ·  મિલિયન, બિલિયન',
      'unitLakh': 'લાખ',
      'unitCrore': 'કરોડ',
      'unitMillion': 'મિલિયન',
      'unitBillion': 'બિલિયન',
      'switchTheme': 'થીમ બદલો',
      'signOut': 'સાઇન આઉટ',
      'signOutQ': 'સાઇન આઉટ કરશો?',
      'signOutBody': 'તમારી ચિપ્સ, હીરા, હથોડી અને ફોટા આ જ ખાતામાં રહેશે.',
      'providerGuest': 'મહેમાન',
      'unitHourShort': 'ક',
      'unitMinuteShort': 'મિ',
      'unitSecondShort': 'સે',
      'serviceUnavailable': 'સેવા ઉપલબ્ધ નથી',
      'soundLabel': 'અવાજ',
      'vibrationLabel': 'કંપન',
      'useProviderPicture': 'મારો Google/Facebook ફોટો વાપરો',
      'pictureChangeAnytime': 'તમે આ ગમે ત્યારે બદલી શકો છો, ટેબલ પર પણ.',
      'pot': 'પોટ',
      'stake': 'દાવ',
      'yourTurn': 'તમારો વારો',
      'toAct': 'નો વારો',
      'pack': 'પૅક',
      'chaal': 'ચાલ',
      'show': 'શો',
      'sideshow': 'સાઇડશો',
      'sideshowWith': 'સરખાવો',
      'sideshowAsksYou': 'તમારી સાથે પત્તાં સરખાવવા માંગે છે',
      // variation tables: the first player picks the rules of the hand
      'variation': 'વેરિએશન',
      'variationTableNote': 'દરેક હાથના નિયમ પહેલો ખેલાડી પસંદ કરે છે',
      'viewTables': 'ટેબલ જુઓ',
      'tablesLabel': 'ટેબલ',
      'openToYouLabel': 'તમારા માટે ખુલ્લાં',
      'backToCategories': 'બધી રમતો',
      'variationRulesTitle': 'વેરિએશન ટેબલ',
      'tableInfoTitle': 'ટેબલની માહિતી',
      'tableRulesTitle': 'આ ટેબલ કેવી રીતે રમાય છે',
      'tableRulesKey': 'ટેબલના નિયમો',
      'ruleBlindMoves':
          'તમે {n} વખત સુધી બ્લાઇન્ડ ચાલ ચાલી શકો છો; પછી તમારાં પત્તાં તમારા માટે ખૂલી જાય છે.',
      'ruleRaiseOnce': 'તમારા વારામાં: ચાલ, અથવા એક વાર બમણો રેઇઝ.',
      'ruleRaiseFree':
          'તમારા વારામાં: ચાલ, અથવા ચિપ્સ હોય ત્યાં સુધી બમણું કરતા જાઓ.',
      'rulePotCapped':
          'પોટ {pot} થાય ત્યારે બધા હાથ બતાવાય છે અને શ્રેષ્ઠ હાથ જીતે છે.',
      'rulePotOpen': 'પોટની કોઈ મર્યાદા નથી.',
      'ruleRoundsEnd':
          'બધા રાઉન્ડ પૂરા થાય તો બધા હાથ બતાવાય છે અને શ્રેષ્ઠ હાથ જીતે છે.',
      'ruleShowTwo':
          'ફક્ત બે ખેલાડી બાકી રહે ત્યારે કોઈ પણ શો માટે ચૂકવી શકે છે.',
      'ruleVariationPick':
          'પહેલી ચાલવાળા ખેલાડીને હાથ કેવી રીતે નક્કી થશે તે પસંદ કરવા 10 સેકન્ડ મળે છે; નહીંતર મુફલિસ.',
      'categoryLabel': 'રમત',
      'playersLabel': 'ખેલાડીઓ',
      'turnTimeLabel': 'ચાલનો સમય',
      'yourChipsLabel': 'તમારી ચિપ્સ',
      'canSitHere': 'તમે આ ટેબલ પર બેસી શકો છો.',
      'playersUpTo': '{n} સુધી',
      'secondsEach': '{n} સેકન્ડ',
      'variationRulesIntro':
          'પહેલી ચાલવાળા ખેલાડીને હાથ કયા નિયમથી નક્કી થશે તે પસંદ કરવા 10 સેકન્ડ મળે છે; ન પસંદ કરે તો મુફલિસ રમાય છે. જોકર પત્તું એ પત્તું ગણાય છે જેનાથી તમારો હાથ સૌથી સારો બને. બીજાની ચિપ્સ છુપાયેલી રહે છે અને પોટની કોઈ મર્યાદા નથી.',
      'variationChooseTitle': 'વેરિએશન પસંદ કરો',
      'variationSelectingBy': '{name} વેરિએશન પસંદ કરી રહ્યા છે…',
      'variationChosen': 'વેરિએશન: {variation}',
      'variationLeftChosen': '{name} ટેબલ છોડી ગયા — મુફલિસ પસંદ થયું',
      'variationAutoChosen': 'સમય પૂરો — મુફલિસ પસંદ થયું',
      'varMuflis': 'મુફલિસ',
      'varAk47': 'AK47',
      'varJoker': 'જોકર',
      'varHukam': 'હુકમ',
      'varLowestJoker': 'સૌથી નાનો જોકર',
      'varHighestJoker': 'સૌથી મોટો જોકર',
      'varFiveCard': '5-પત્તી',
      'varMuflisNote': 'સૌથી નબળો હાથ જીતે છે',
      'varAk47Note': 'A, K, 4 અને 7 જોકર છે',
      'varJokerNote': 'ખુલ્લા પત્તાનો રેન્ક જોકર છે',
      'varHukamNote': 'ખુલ્લા પત્તાનો રંગ જોકર છે',
      'varLowestJokerNote': 'તમારું સૌથી નાનું પત્તું જોકર છે',
      'varHighestJokerNote': 'તમારું સૌથી મોટું પત્તું જોકર છે',
      'varFiveCardNote': 'તમારાં 5 પત્તાંમાંથી શ્રેષ્ઠ 3',
      'wildCard': 'જોકર',
      'sideshowRunning': 'સાઇડશો',
      'accept': 'સ્વીકારો',
      'decline': 'નકારો',
      'sideshowDeclined': 'તમારો સાઇડશો નકારાયો',
      'sideshowTimedOut': 'જવાબ નથી — સાઇડશો રદ',
      'sideshowCancelled': 'સાઇડશો રદ થયો',
      'sideshowYouLost': 'તમારાં પત્તાં નબળાં હતાં — તમે પૅક થયા',
      'sideshowYouWon': 'તમારાં પત્તાં સારાં હતાં — તે પૅક થયા',
      'force': 'ફોર્સ',
      'forceSideshow': 'ફોર્સ સાઇડશો',
      'forceSideshowTitle': 'ફોર્સ સાઇડશો કરશો?',
      'forceSideshowBody': '{name} સાથે ફોર્સ સાઇડશો માટે 1 હથોડી વાપરશો?',
      'forceSideshowNote': 'તે ના પાડી શકતા નથી, અને બરાબરી થાય તો તમે હારશો.',
      'noHammersTitle': 'કોઈ હથોડી બાકી નથી',
      'noHammersBody': 'ફોર્સ સાઇડશોમાં 1 હથોડી લાગે છે. સ્ટોરમાંથી વધુ લેશો?',
      'getHammers': 'હથોડી લો',
      'noHammers': 'ફોર્સ સાઇડશો માટે હથોડી જોઈએ',
      'sideshowForcedByYou': 'તમે {name} સાથે ફોર્સ સાઇડશો કર્યો',
      'sideshowForcedOnYou': '{name} એ તમારી સાથે ફોર્સ સાઇડશો કર્યો',
      'sideshowForcedOn': '{from} એ {to} સાથે ફોર્સ સાઇડશો કર્યો',
      'missile': 'મિસાઇલ',
      'fireMissileTitle': 'મિસાઇલ છોડશો?',
      'fireMissileBody':
          'હાથમાં બાકી બધા ખેલાડીઓના પત્તા ખુલશે અને શ્રેષ્ઠ હાથ પોટ જીતશે. 1 મિસાઇલ લાગશે.',
      'fireMissileNote': 'ટાઇ થાય તો તમે હારશો.',
      'fire': 'છોડો',
      'missileTooLate':
          'મોડું થઈ ગયું — મિસાઇલ છોડાઈ નથી. કોઈ મિસાઇલ વપરાઈ નથી.',
      'noMissilesTitle': 'કોઈ મિસાઇલ બાકી નથી',
      'noMissilesBody':
          'મિસાઇલ છોડવા 1 મિસાઇલ લાગે છે. સ્ટોરમાં હીરાથી વધુ લેશો?',
      'getMissiles': 'મિસાઇલ લો',
      'noMissiles': 'મિસાઇલ છોડવા માટે મિસાઇલ જોઈએ',
      'tooFewPlayers': 'આ માટે હાથમાં ઓછામાં ઓછા 3 ખેલાડી હોવા જોઈએ',
      'missileNeedsShowChips': 'મિસાઇલ છોડવા માટે શો જેટલી ચિપ્સ જોઈએ',
      'missileFiredByYou': 'તમે મિસાઇલ છોડી',
      'missileFiredBy': '{name} એ મિસાઇલ છોડી',
      'storeTabMissiles': 'મિસાઇલ',
      'storeMissilesTitle': 'મિસાઇલ સ્ટોર',
      'storeMissilesBlurb': 'હીરા બદલો: 15 હીરા = 1 મિસાઇલ.',
      'tradeMissilesTitle': 'હીરા બદલશો?',
      'tradeMissilesBody': '{diamonds} હીરા આપીને {missiles} મિસાઇલ લેશો?',
      'tradeMissileBodyOne': '{diamonds} હીરા આપીને 1 મિસાઇલ લેશો?',
      'trade': 'બદલો',
      'notEnoughDiamondsTitle': 'પૂરતા હીરા નથી',
      'notEnoughDiamondsBody':
          'આ સોદા માટે {diamonds} હીરા જોઈએ. વધુ હીરા લેશો?',
      'getDiamonds': 'હીરા લો',
      'missilesAdded': '{n} મિસાઇલ તમારા વૉલેટમાં ઉમેરાઈ',
      'missileAddedOne': '1 મિસાઇલ તમારા વૉલેટમાં ઉમેરાઈ',
      'rewardMissileTradedOne': 'મિસાઇલ તમારા વૉલેટમાં છે. ટેબલ પર તેને છોડો.',
      'walletSummaryOneMissile': '{diamonds} હીરા, {hammers} હથોડી, 1 મિસાઇલ',
      'rewardMissilesTraded': 'મિસાઇલ તમારા વૉલેટમાં છે. ટેબલ પર મિસાઇલ છોડો.',
      'premiumPackages': 'પ્રીમિયમ પૅકેજ',
      'posPremiumPackage': 'પ્રીમિયમ પૅકેજ',
      'plusMissileOne': '+1 મિસાઇલ',
      'plusMissiles': '+{n} મિસાઇલ',
      'plusHammers': '+{n} હથોડી',
      'plusHammerOne': '+{n} હથોડી',
      'rewardPremiumPurchased':
          'તમારું પ્રીમિયમ પૅકેજ તમારા વૉલેટમાં છે. શુભકામના.',
      'premiumAdded':
          'પ્રીમિયમ પૅકેજ ઉમેરાયું: {chips} ચિપ્સ, {missiles} મિસાઇલ અને {hammers} હથોડી',
      'premiumAddedOneMissile':
          'પ્રીમિયમ પૅકેજ ઉમેરાયું: {chips} ચિપ્સ, 1 મિસાઇલ અને {hammers} હથોડી',
      'seeCards': 'પત્તા જુઓ',
      'blindMovesLeft': 'બ્લાઇન્ડ ચાલ બાકી',
      'blindMovesLabel': 'બ્લાઇન્ડ ચાલ બાકી',
      'lastBlindMove': 'છેલ્લી બ્લાઇન્ડ ચાલ',
      'inPot': 'પોટમાં',
      'waiting': 'રાહ',
      'offline': 'ઑફલાઇન',
      'packed': 'પૅક',
      'autoPacked': 'સળંગ ચાલ ચૂક્યા',
      'autoPackedOne': 'ચાલ ચૂક્યા',
      'lastWarning': 'છેલ્લી ચેતવણી',
      'missOneMore': 'આ ચાલ ચૂકશો તો તમે ટેબલ છોડશો.',
      'missedTurnsLabel': 'ચૂકેલી ચાલો',
      'resumingTable': 'તમારા ટેબલ પર પાછા જઈ રહ્યા છીએ…',
      'welcomeBack': 'પરત સ્વાગત — તમે તમારા ટેબલ પર પાછા છો.',
      'unlock': 'અનલૉક કરો',
      'unlockTitle': 'આ ફોટો અનલૉક કરવો છે?',
      'unlockBody':
          '{name} ની કિંમત {cost} ચિપ્સ છે. હમણાં અનલૉક કરીને વાપરવો?',
      'unlockBodyDiamond':
          '{name} ની કિંમત {cost} ડાયમંડ છે. હમણાં અનલૉક કરીને વાપરવો?',
      'pictureUnlocked': 'અનલૉક',
      'tapToChangePicture': 'ફોટો બદલવા ટૅપ કરો',
      'rentForDays': '{days} દિવસ',
      'daysLeft': '{days} દિવસ બાકી',
      'hoursLeft': '{n} કલાક બાકી',
      'minutesLeft': '{n} મિનિટ બાકી',
      'unlockRentBody':
          '{name} ની કિંમત {cost} ચિપ્સ છે અને તે {time} તમારો રહેશે. હમણાં અનલૉક કરીને વાપરવો?',
      'unlockRentBodyDiamond':
          '{name} ની કિંમત {cost} ડાયમંડ છે અને તે {time} તમારો રહેશે. હમણાં અનલૉક કરીને વાપરવો?',
      'unlockBodyHammers':
          '{name} ની કિંમત {cost} હથોડી છે. હમણાં અનલૉક કરીને વાપરવો?',
      'unlockBodyHammerOne':
          '{name} ની કિંમત 1 હથોડી છે. હમણાં અનલૉક કરીને વાપરવો?',
      'unlockRentBodyHammers':
          '{name} ની કિંમત {cost} હથોડી છે અને તે {time} તમારો રહેશે. હમણાં અનલૉક કરીને વાપરવો?',
      'unlockRentBodyHammerOne':
          '{name} ની કિંમત 1 હથોડી છે અને તે {time} તમારો રહેશે. હમણાં અનલૉક કરીને વાપરવો?',
      'notEnoughHammersTitle': 'પૂરતી હથોડી નથી',
      'notEnoughHammersBody':
          '{name} ની કિંમત {cost} હથોડી છે. વધુ હથોડી લેશો?',
      'notEnoughHammersBodyOne': '{name} ની કિંમત 1 હથોડી છે. વધુ હથોડી લેશો?',
      'notEnoughDiamondsPictureBody':
          '{name} ની કિંમત {cost} હીરા છે. વધુ હીરા લેશો?',
      'pictureChipsLobbyOnly':
          'ચિપ્સની કિંમતવાળો ફોટો ફક્ત લૉબીમાં ખરીદી શકાય છે.',
      'pictureAll': 'બધા',
      'picturePremium': 'પ્રીમિયમ',
      'priceLowToHigh': 'કિંમત: ઓછીથી વધુ',
      'priceHighToLow': 'કિંમત: વધુથી ઓછી',
      'picturePremiumAnimated': 'પ્રીમિયમ (એનિમેટેડ)',
      'pictureShelfEmpty': 'અહીં હજી કોઈ ફોટો નથી.',
      'pictureOwnedTitle': 'પહેલેથી અનલૉક છે',
      'timeDay': '{n} દિવસ',
      'timeDays': '{n} દિવસ',
      'timeHour': '{n} કલાક',
      'timeHours': '{n} કલાક',
      'timeMinute': '{n} મિનિટ',
      'timeMinutes': '{n} મિનિટ',
      'timeLeft': '{time} બાકી',
      'pictureKeeps': 'હંમેશા માટે તમારો',
      'rentalLapsed': 'ભાડાની મુદત પૂરી થઈ ગઈ',
      'rentalEnds': 'મુદત પૂરી: {date}',
      'rentalEnded': 'પૂરી થઈ: {date}',
      'wear': 'વાપરો',
      'wearing': 'વપરાય છે',
      'appVersion': 'એપ આવૃત્તિ',
      'tableLost': 'તમે દૂર હતા ત્યારે તમારી બેઠક જતી રહી.',
      'notConnected': 'કનેક્શન નથી. આ મોકલાયું નથી.',
      'reconnecting': 'કનેક્શન તૂટી ગયું. ફરી જોડાઈ રહ્યા છીએ…',
      'kickedNoChips': 'આ ટેબલ પર રહેવા માટે તમારી પાસે પૂરતી ચિપ્સ નથી.',
      'kickedIdle': 'સળંગ {n} ચાલ ચૂકી જતાં તમે ટેબલ છોડ્યું.',
      'leaveStakeStays': 'તમારો દાવ પોટમાં જ રહેશે',
      'winner': 'વિજેતા',
      'tableChat': 'ટેબલ ચૅટ',
      'saySomething': 'કંઈક કહો…',
      'tableMenu': 'ટેબલ મેનૂ',
      'quickMessagesTitle': 'ઝટપટ સંદેશા',
      'quickMessagesTip': 'ઝટપટ સંદેશો મોકલો',
      'quickPlayBlind': 'કૃપા કરીને બ્લાઇન્ડ રમો.',
      'quickPlayFast': 'કૃપા કરીને ઝડપથી રમો.',
      'quickHowToWin': 'આમ જ જીતાય છે.',
      'quickUnlucky': 'મારું નસીબ ખરાબ છે.',
      'quickYouGotLucky': 'તમારું નસીબ સારું હતું.',
      'quickOops': 'અરેરે! મારે આ નહોતું રમવું જોઈતું.',
      'quickTakeSideshow': 'કૃપા કરીને સાઇડશો કરો.',
      'quickTakeShow': 'કૃપા કરીને શો કરો.',
      'quickSwitchTable': 'ટેબલ બદલો.',
      'quickHelpMe': 'કૃપા કરીને મારી મદદ કરો.',
      'yourChips': 'તમારા ચિપ્સ',
      'maxPot': 'મહત્તમ પોટ',
      'nightMode': 'રાત મોડ',
      'dayMode': 'દિવસ મોડ',
      'appearance': 'દેખાવ',
      'themeSystem': 'સિસ્ટમ',
      'themeDark': 'ડાર્ક',
      'themeLight': 'લાઇટ',
      'waitingForPlayers': 'ખેલાડીઓની રાહ',
      'startingGame': 'રમત શરૂ થાય છે…',
      'buyChipsToStay': 'સીટ રાખવા {seconds} સેકન્ડમાં ચિપ્સ ખરીદો',
      'youAreWinner': 'તમે જીત્યા',
      'isTheWinner': 'જીત્યા',
      'leaveTable': 'ટેબલ છોડો',
      'leaveTableQ': 'આ ટેબલ છોડવું છે?',
      'leaveMidHand':
          'તમે એક હાથમાં છો. છોડશો તો પત્તા પૅક થશે અને તમારો દાવ પોટમાં જ રહેશે.',
      'leaveAnytime': 'તમે તરત જ બીજા ટેબલ પર જોડાઈ શકો છો.',
      'stay': 'રહો',
      'leave': 'છોડો',
      'switchTable': 'ટેબલ બદલો',
      'switchTableQ': 'ટેબલ બદલવું છે?',
      'switchMidHand':
          'તમે એક હાથમાં છો. ખસશો તો પત્તા પૅક થશે અને તમારો દાવ પોટમાં જ રહેશે.',
      'switchIdle':
          'તમને એ જ પ્રકારના બીજા ટેબલ પર બેસાડવામાં આવશે. ક્યાંય જગ્યા ન હોય તો આ ટેબલ જ રહેશે.',
      'switchAction': 'બદલો',
      'quitGameQ': 'ગેમ બંધ કરવી છે?',
      'quitGameBody':
          'તમે ગમે ત્યારે પાછા આવી શકો છો — તમારા ચિપ્સ સચવાયેલા છે.',
      'quit': 'બંધ કરો',
      'cancel': 'રદ કરો',
      'consentTitle': 'રમતા પહેલાં',
      'consentBody':
          'હું પુષ્ટિ કરું છું કે આ ગેમ રમીને મને કોઈ પૈસા કે અન્ય લાભ જીતવાની કોઈ અપેક્ષા નથી.',
      'consentNote':
          'આ ગેમ માત્ર મનોરંજન માટે છે. ચિપ્સનું કોઈ રોકડ મૂલ્ય નથી અને તેને પૈસા કે બીજી કોઈ વસ્તુ સાથે બદલી શકાતી નથી.',
      'consentAccept': 'પુષ્ટિ કરું છું',
      'joinAnother': 'તમે તરત જ બીજા ટેબલ પર જોડાઈ શકો છો',
      'noOtherTable':
          'આ દાવ પર હાલમાં બીજા કોઈ {category} ટેબલ પર સીટ ખાલી નથી',
      'rules': 'નિયમો',
      'rulesTitle': 'પત્તાંની રેન્કિંગ',
      'rulesBeats': 'ઉપરનું સૌથી મજબૂત. દરેક હાથ નીચેના બધાને હરાવે છે.',
      'rankTrail': 'ટ્રેલ',
      'rankTrailNote': 'એક જ રેન્કનાં ત્રણ પત્તાં',
      'rankPureSeq': 'પ્યોર સિક્વન્સ',
      'rankPureSeqNote': 'સળંગ ત્રણ, એક જ રંગનાં',
      'rankSeq': 'સિક્વન્સ',
      'rankSeqNote': 'સળંગ ત્રણ, કોઈ પણ રંગનાં',
      'rankColor': 'કલર',
      'rankColorNote': 'એક જ રંગનાં ત્રણ, સળંગ નહીં',
      'rankPair': 'પેર',
      'rankPairNote': 'એક જ રેન્કનાં બે પત્તાં',
      'rankHigh': 'હાઈ કાર્ડ',
      'rankHighNote': 'કંઈ બન્યું નહીં; સૌથી મોટું પત્તું જીતે',
      'runOrder': 'સિક્વન્સનો ક્રમ',
      'runOrderNote': 'A-K-Q સૌથી ઊંચું, પછી A-2-3, પછી K-Q-J થી 4-3-2 સુધી.',
      'close': 'બંધ કરો',
      'changeName': 'નામ બદલો',
      'save': 'સાચવો',
      'nameSaved': 'નામ બદલાઈ ગયું.',
      'cappedTitle': 'આ ટેબલ તમારા માટે બંધ છે',
      'cappedBody':
          '{cap} થી વધુ ચિપ્સ ધરાવતા ખેલાડીઓ આ ટેબલ પર બેસી શકતા નથી.',
      'lockedTitle': 'આ ટેબલ હજી બંધ છે',
      'lockedBody': 'આ ટેબલ પર બેસવા {min} ચિપ્સ જોઈએ.',
      'entryLabel': 'પ્રવેશ',
      'entryOpen': 'બધા માટે ખુલ્લું',
      'entryUpTo': '{cap} સુધી',
      'entryFrom': '{min} કે વધુ',
      'useSocialPicture': 'મારો Google કે Facebook ફોટો વાપરો',
      'guestNoSocial': 'તમારો ફોટો વાપરવા Google કે Facebook થી સાઇન ઇન કરો.',

      // --- the poker family
      'poker': 'પોકર',
      'pokerTableNote': 'હોલ્ડમ, ઓમાહા, 5-કાર્ડ ડ્રૉ અને 3-કાર્ડ પોકર',
      'pokerTexasHoldem': 'ટેક્સાસ હોલ્ડમ',
      'pokerOmaha': 'ઓમાહા',
      'pokerFiveCardDraw': '5-કાર્ડ ડ્રૉ',
      'pokerThreeCardPoker': '3-કાર્ડ પોકર',
      'pokerTexasHoldemNote': 'દરેકને બે પત્તાં, બોર્ડ પર પાંચ',
      'pokerOmahaNote': 'દરેકને ચાર પત્તાં, તેમાંથી બરાબર બે રમો',
      'pokerFiveCardDrawNote': 'દરેકને પાંચ પત્તાં, જે ન જોઈએ તે બદલો',
      'pokerThreeCardPokerNote': 'દરેકને ત્રણ પત્તાં, ડીલર સામે',
      'blindsLabel': 'બ્લાઇન્ડ્સ',
      'anteLabel': 'એન્ટી',
      'buyInLabel': 'બાય-ઇન',
      'holeCardsLabel': 'દરેકને પત્તાં',
      'maxDiscardsLabel': 'મહત્તમ બદલો',
      'buyInFrom': '{min} થી',
      'fold': 'ફોલ્ડ',
      'check': 'ચેક',
      'call': 'કૉલ',
      'bet': 'બેટ',
      'raise': 'રેઇઝ',
      'allIn': 'ઑલ-ઇન',
      'play': 'પ્લે',
      'draw': 'ડ્રૉ',
      'standPat': 'પત્તાં રાખો',
      'exchangeUpTo': 'બદલવા માટે {n} સુધી પત્તાં પસંદ કરો',
      'playOrFold': 'પ્લે કે ફોલ્ડ?',
      'dealerLabel': 'ડીલર',
      'dealerQualifies': 'ડીલર ક્વૉલિફાય',
      'dealerNotQualified': 'ડીલર ક્વૉલિફાય નહીં',
      'youWon': 'તમે {amount} જીત્યા',
      'youLost': 'તમે હાર્યા',
      'outcomeWin': 'જીત',
      'outcomeLose': 'હાર',
      'push': 'બરાબર',
      'potLabel': 'પોટ',
      'sidePotLabel': 'સાઇડ પોટ',
      'boardLabel': 'બોર્ડ',
      'streetPreflop': 'પ્રી-ફ્લોપ',
      'streetFlop': 'ફ્લોપ',
      'streetTurn': 'ટર્ન',
      'streetRiver': 'રિવર',
      'streetPredraw': 'ડ્રૉ પહેલાં',
      'streetDraw': 'ડ્રૉ',
      'streetPostdraw': 'ડ્રૉ પછી',
      'streetDecision': 'નિર્ણય',
      'streetShowdown': 'શોડાઉન',
      'pokerTimedOut': 'તમારો સમય પૂરો થયો અને તમારો હાથ ફોલ્ડ થયો',
      'pokerRulesTitle': 'પોકર ટેબલ',
      'pokerRulesIntro':
          'ચાર પોકર રમતો, બધી એક જ પાંચ-પત્તાંની રેન્કિંગથી અંકાય છે. હાથ એટલે '
          'તમે બનાવી શકો તે શ્રેષ્ઠ પાંચ પત્તાં.',
      'pokerRankRoyalFlush': 'રૉયલ ફ્લશ',
      'pokerRankStraightFlush': 'સ્ટ્રેટ ફ્લશ',
      'pokerRankFourOfAKind': 'ફોર ઑફ અ કાઇન્ડ',
      'pokerRankFullHouse': 'ફુલ હાઉસ',
      'pokerRankFlush': 'ફ્લશ',
      'pokerRankStraight': 'સ્ટ્રેટ',
      'pokerRankThreeOfAKind': 'થ્રી ઑફ અ કાઇન્ડ',
      'pokerRankTwoPair': 'ટુ પેર',
      'pokerRankPair': 'પેર',
      'pokerRankHighCard': 'હાઈ કાર્ડ',
      'pokerThreeCardRanking':
          '3-કાર્ડ પોકરમાં સ્ટ્રેટ ફ્લશને હરાવે છે, અને થ્રી ઑફ અ કાઇન્ડ બંનેને.',
      'rulePokerBlinds': 'દરેક હાથ {small} અને {big} ના બ્લાઇન્ડ્સથી શરૂ થાય છે',
      'rulePokerAnte': 'વહેંચતા પહેલાં દરેક {ante} ની એન્ટી મૂકે છે',
      'rulePokerBuyIn': 'ઓછામાં ઓછા {min} લઈને બેસો',
      'rulePokerHoleCards': 'દરેક ખેલાડીને {n} પત્તાં વહેંચાય છે',
      'rulePokerHoldemWin':
          'તમારાં બે પત્તાં અને બોર્ડનાં પાંચમાંથી શ્રેષ્ઠ પાંચ બનાવો',
      'rulePokerOmahaWin':
          'તમારાં ચારમાંથી બરાબર બે અને બોર્ડનાં ત્રણથી હાથ બને છે',
      'rulePokerDrawWin': 'બેટ કરો, એક વાર {n} સુધી પત્તાં બદલો, પછી ફરી બેટ કરો',
      'rulePokerThreeCardWin':
          'એન્ટી જેટલું પ્લે કરો કે ફોલ્ડ; તમારાં ત્રણ પત્તાં ડીલર સાથે સરખાવાય છે',
      'rulePokerDealerQualifies':
          'ડીલરને રમવા ક્વીન-હાઈ જોઈએ; ન હોય તો તમારો પ્લે બેટ પાછો અને એન્ટી '
          'જીતે',
      'rulePokerBestHandWins':
          'શોડાઉનમાં શ્રેષ્ઠ હાથ પોટ લે છે; એકલો બચેલો ખેલાડી શોડાઉન વિના',
      'refuseNotYourTurn': 'તમારો વારો નથી',
      'refuseInvalidAction': 'આ ચાલ અત્યારે ચાલી શકે નહીં',
      'refuseInvalidAmount': 'આ રકમ માન્ય નથી',
      'refuseInvalidDiscard': 'આ પત્તાં બદલી શકાય નહીં',
      'refuseInsufficientChips': 'આ માટે પૂરતા ચિપ્સ નથી',
      'refuseNoHand': 'અત્યારે કોઈ હાથ ચાલતો નથી',
      'refuseNotInHand': 'તમે આ હાથમાં નથી',
      'refuseWrongGame': 'આ ચાલ બીજી રમતની છે',
      'refuseDuplicateAction': 'આ ચાલ પહેલેથી મોકલાઈ ગઈ છે',
      'refuseUnknownAction': 'આ ચાલ ટેબલ જાણતું નથી',
    },
    'pa': {
      'signInSubtitle': 'ਖੇਡਣ ਲਈ ਸਾਈਨ ਇਨ ਕਰੋ।',
      'displayName': 'ਨਾਮ',
      'playerHint': 'ਖਿਡਾਰੀ',
      'playAsGuest': 'ਮਹਿਮਾਨ ਵਜੋਂ ਖੇਡੋ',
      'signingIn': 'ਸਾਈਨ ਇਨ ਹੋ ਰਿਹਾ ਹੈ…',
      'continueGoogle': 'Google ਨਾਲ ਜਾਰੀ ਰੱਖੋ',
      'continueFacebook': 'Facebook ਨਾਲ ਜਾਰੀ ਰੱਖੋ',
      'privacyPolicy': 'ਪਰਦੇਦਾਰੀ ਨੀਤੀ',
      'signInUnavailable':
          'ਇਸ ਵਰਜ਼ਨ ਵਿੱਚ {provider} ਸਾਈਨ-ਇਨ ਉਪਲਬਧ ਨਹੀਂ ਹੈ। ਫ਼ਿਲਹਾਲ ਗੈਸਟ ਵਜੋਂ ਖੇਡੋ।',
      'boot': 'ਬੂਟ',
      'maxBlindsLabel': 'ਬਲਾਈਂਡ ਚਾਲਾਂ ਵੱਧ ਤੋਂ ਵੱਧ',
      'potLimitLabel': 'ਪੌਟ ਸੀਮਾ',
      'potUnlimited': 'ਅਸੀਮਤ',
      'tapToSit': 'ਬੈਠਣ ਲਈ ਟੈਪ ਕਰੋ',
      'everyoneChips': 'ਸਭ ਦੇ ਚਿਪਸ ਦਿਸਦੇ ਹਨ',
      'onlyYourChips': 'ਸਿਰਫ਼ ਤੁਹਾਡੇ ਚਿਪਸ ਦਿਸਦੇ ਹਨ',
      'seen': 'ਸੀਨ',
      'blind': 'ਬਲਾਈਂਡ',
      'privateTable': 'ਪ੍ਰਾਈਵੇਟ ਟੇਬਲ',
      'create': 'ਬਣਾਓ',
      'orJoinCode': 'ਜਾਂ ਕੋਡ ਨਾਲ ਜੁੜੋ:',
      'tableCode': 'ਟੇਬਲ ਕੋਡ',
      'invalidTableCode': 'ਟੇਬਲ ਕੋਡ 8 ਅੱਖਰਾਂ ਅਤੇ ਅੰਕਾਂ ਦਾ ਹੁੰਦਾ ਹੈ।',
      'join': 'ਜੁੜੋ',
      'yourPicture': 'ਤੁਹਾਡੀ ਤਸਵੀਰ',
      'yourRecord': 'ਤੁਹਾਡਾ ਰਿਕਾਰਡ',
      'handsPlayed': 'ਖੇਡੇ ਹੱਥ',
      'won': 'ਜਿੱਤੇ',
      'lost': 'ਹਾਰੇ',
      'leftMidHand': 'ਵਿਚਾਲੇ ਛੱਡੇ',
      'totalWinnings': 'ਕੁੱਲ ਜਿੱਤ',
      'biggestPot': 'ਸਭ ਤੋਂ ਵੱਡਾ ਪੌਟ',
      'playedNote': 'ਹੱਥ ਤਾਂ ਹੀ ਗਿਣਿਆ ਜਾਂਦਾ ਹੈ ਜਦੋਂ ਤੁਸੀਂ ਕੋਈ ਚਾਲ ਚੱਲੀ ਹੋਵੇ।',
      'fourHourBonus': '4-ਘੰਟੇ ਦਾ ਬੋਨਸ',
      'dailyBonus': 'ਰੋਜ਼ਾਨਾ ਬੋਨਸ',
      'milestone': 'ਮਾਈਲਸਟੋਨ',
      'collect': 'ਲਓ',
      'rewardCollected': 'ਇਨਾਮ ਮਿਲ ਗਿਆ!',
      'rewardComeBack': '4 ਘੰਟੇ ਬਾਅਦ ਫਿਰ ਆਓ।',
      'rewardComeBackDaily': '24 ਘੰਟੇ ਬਾਅਦ ਫਿਰ ਆਓ।',
      'bonusYouGet': 'ਤੁਹਾਨੂੰ ਮਿਲੇਗਾ',
      'bonusNextIn': 'ਅਗਲਾ ਇਨਾਮ ਮਿਲੇਗਾ',
      'bonusReadyNow': 'ਹੁਣੇ ਲੈ ਸਕਦੇ ਹੋ',
      'bonusEveryFourHours': 'ਹਰ 4 ਘੰਟੇ ਬਾਅਦ ਨਵਾਂ ਬੋਨਸ।',
      'bonusEveryDay': 'ਹਰ 24 ਘੰਟੇ ਬਾਅਦ ਨਵਾਂ ਬੋਨਸ।',
      'rewardPurchased': 'ਚਿੱਪਾਂ ਤੁਹਾਡੇ ਵਾਲਿਟ ਵਿੱਚ ਹਨ। ਸ਼ੁਭਕਾਮਨਾਵਾਂ।',
      'rewardDiamondsPurchased':
          'ਹੀਰੇ ਤੁਹਾਡੇ ਵਾਲਿਟ ਵਿੱਚ ਹਨ। ਇਨ੍ਹਾਂ ਨਾਲ ਮਿਜ਼ਾਈਲਾਂ ਲਓ।',
      'rewardMilestoneAgain': 'ਅਗਲੇ ਲਈ ਹੋਰ 25 ਹੱਥ।',
      'rewardRefused': 'ਹਾਲੇ ਲੈਣ ਲਈ ਤਿਆਰ ਨਹੀਂ।',
      'tapToClose': 'ਬੰਦ ਕਰਨ ਲਈ ਟੈਪ ਕਰੋ',
      'buyChips': 'ਚਿਪਸ ਖਰੀਦੋ',
      'shop': 'ਦੁਕਾਨ',
      'comingSoon': 'ਜਲਦੀ ਆ ਰਿਹਾ ਹੈ',
      'updateTitle': 'ਨਵਾਂ ਵਰਜਨ ਤਿਆਰ ਹੈ',
      'updateBody': 'ਖੇਡਦੇ ਰਹਿਣ ਲਈ ਅੱਪਡੇਟ ਕਰੋ। ਇਹ ਵਰਜਨ ਹੁਣ ਪੁਰਾਣਾ ਹੈ।',
      'updateNow': 'ਹੁਣੇ ਅੱਪਡੇਟ ਕਰੋ',
      'updateOpenStore': 'ਪਲੇ ਸਟੋਰ ਖੋਲ੍ਹੋ',
      'updateOpenAppStore': 'ਐਪ ਸਟੋਰ ਖੋਲ੍ਹੋ',
      'updateFailed': 'ਅੱਪਡੇਟ ਪੂਰਾ ਨਹੀਂ ਹੋਇਆ। ਦੁਬਾਰਾ ਕੋਸ਼ਿਸ਼ ਕਰੋ।',
      'storeTitle': 'ਚਿੱਪ ਸਟੋਰ',
      'storeBlurb': 'ਪੈਕ ਜਿੰਨਾ ਵੱਡਾ, ਬੋਨਸ ਓਨਾ ਵੱਡਾ।',
      'storeTabChips': 'ਚਿਪਸ',
      'storeTabPictures': 'ਤਸਵੀਰਾਂ',
      'storeTabAnimated': 'ਐਨੀਮੇਟਿਡ',
      'storePicturesBlurb': 'ਚਿਪਸ ਜਾਂ ਹਥੌੜਿਆਂ ਨਾਲ ਤਸਵੀਰ ਅਨਲੌਕ ਕਰੋ।',
      'storeAnimatedBlurb': 'ਹਥੌੜਿਆਂ ਨਾਲ ਐਨੀਮੇਟਿਡ ਤਸਵੀਰ ਅਨਲੌਕ ਕਰੋ।',
      'storeTabDiamonds': 'ਹੀਰੇ',
      'storeDiamondsTitle': 'ਹੀਰਾ ਸਟੋਰ',
      'storeDiamondsBlurb': 'ਹੀਰੇ ਦੇ ਕੇ ਮਿਜ਼ਾਈਲਾਂ ਲਓ।',
      'storeTabHammers': 'ਹਥੌੜੇ',
      'storeHammersTitle': 'ਹਥੌੜਾ ਸਟੋਰ',
      'storeHammersBlurb': 'ਹਥੌੜੇ ਨਾਲ ਬਿਨਾਂ ਪੁੱਛੇ ਸਾਈਡਸ਼ੋ ਹੁੰਦਾ ਹੈ।',
      'rewardHammersPurchased':
          'ਹਥੌੜੇ ਤੁਹਾਡੇ ਵਾਲਿਟ ਵਿੱਚ ਹਨ। ਟੇਬਲ ’ਤੇ ਫੋਰਸ ਸਾਈਡਸ਼ੋ ਕਰੋ।',
      'walletSummary': '{diamonds} ਹੀਰੇ, {hammers} ਹਥੌੜੇ, {missiles} ਮਿਜ਼ਾਈਲਾਂ',
      'storeBonus': 'ਬੋਨਸ',
      'storeNotLive': 'ਭੁਗਤਾਨ ਹਾਲੇ ਚਾਲੂ ਨਹੀਂ — ਕੋਈ ਚਾਰਜ ਨਹੀਂ ਲਿਆ ਗਿਆ।',
      'posStarter': 'ਸ਼ੁਰੂਆਤ',
      'posPopular': 'ਹਰਮਨ ਪਿਆਰਾ',
      'posBestValue': 'ਵਧੀਆ ਮੁੱਲ',
      'posPremium': 'ਪ੍ਰੀਮੀਅਮ',
      'comingSoonBody':
          'ਚਿਪਸ ਖਰੀਦਣਾ ਅਜੇ ਸ਼ੁਰੂ ਨਹੀਂ ਹੋਇਆ। ਉਦੋਂ ਤੱਕ ਆਪਣੇ ਇਨਾਮ ਲੈਂਦੇ ਰਹੋ।',
      'handsToGo': 'ਹੱਥ ਬਾਕੀ',
      'handToGo': 'ਹੱਥ ਬਾਕੀ',
      'forceSideshowTooLate':
          'ਦੇਰ ਹੋ ਗਈ — ਹੁਣ ਉਹ ਸਾਈਡਸ਼ੋ ਨਹੀਂ ਹੋ ਸਕਦਾ। ਕੋਈ ਹਥੌੜਾ ਖਰਚ ਨਹੀਂ ਹੋਇਆ।',
      'settings': 'ਸੈਟਿੰਗਾਂ',
      'language': 'ਭਾਸ਼ਾ',
      'numberSystem': 'ਨੰਬਰ ਫਾਰਮੈਟ',
      'numberIndian': 'ਭਾਰਤੀ  ·  ਲੱਖ, ਕਰੋੜ',
      'numberInternational': 'ਅੰਤਰਰਾਸ਼ਟਰੀ  ·  ਮਿਲੀਅਨ, ਬਿਲੀਅਨ',
      'unitLakh': 'ਲੱਖ',
      'unitCrore': 'ਕਰੋੜ',
      'unitMillion': 'ਮਿਲੀਅਨ',
      'unitBillion': 'ਬਿਲੀਅਨ',
      'switchTheme': 'ਥੀਮ ਬਦਲੋ',
      'signOut': 'ਸਾਈਨ ਆਊਟ',
      'signOutQ': 'ਸਾਈਨ ਆਊਟ ਕਰਨਾ ਹੈ?',
      'signOutBody':
          'ਤੁਹਾਡੇ ਚਿਪਸ, ਹੀਰੇ, ਹਥੌੜੇ ਅਤੇ ਤਸਵੀਰਾਂ ਇਸੇ ਖਾਤੇ ਵਿੱਚ ਰਹਿਣਗੇ।',
      'providerGuest': 'ਮਹਿਮਾਨ',
      'unitHourShort': 'ਘੰ',
      'unitMinuteShort': 'ਮਿੰ',
      'unitSecondShort': 'ਸ',
      'serviceUnavailable': 'ਸੇਵਾ ਉਪਲਬਧ ਨਹੀਂ ਹੈ',
      'soundLabel': 'ਆਵਾਜ਼',
      'vibrationLabel': 'ਕੰਪਨ',
      'useProviderPicture': 'ਮੇਰੀ Google/Facebook ਤਸਵੀਰ ਵਰਤੋ',
      'pictureChangeAnytime': 'ਤੁਸੀਂ ਇਹ ਕਦੇ ਵੀ ਬਦਲ ਸਕਦੇ ਹੋ, ਟੇਬਲ ਉੱਤੇ ਵੀ।',
      'pot': 'ਪੌਟ',
      'stake': 'ਦਾਅ',
      'yourTurn': 'ਤੁਹਾਡੀ ਵਾਰੀ',
      'toAct': 'ਦੀ ਵਾਰੀ',
      'pack': 'ਪੈਕ',
      'chaal': 'ਚਾਲ',
      'show': 'ਸ਼ੋ',
      'sideshow': 'ਸਾਈਡਸ਼ੋ',
      'sideshowWith': 'ਮਿਲਾਓ',
      'sideshowAsksYou': 'ਤੁਹਾਡੇ ਨਾਲ ਪੱਤੇ ਮਿਲਾਉਣਾ ਚਾਹੁੰਦਾ ਹੈ',
      // variation tables: the first player picks the rules of the hand
      'variation': 'ਵੇਰੀਏਸ਼ਨ',
      'variationTableNote': 'ਹਰ ਹੱਥ ਦੇ ਨਿਯਮ ਪਹਿਲਾ ਖਿਡਾਰੀ ਚੁਣਦਾ ਹੈ',
      'viewTables': 'ਟੇਬਲ ਵੇਖੋ',
      'tablesLabel': 'ਟੇਬਲ',
      'openToYouLabel': 'ਤੁਹਾਡੇ ਲਈ ਖੁੱਲ੍ਹੇ',
      'backToCategories': 'ਸਾਰੀਆਂ ਖੇਡਾਂ',
      'variationRulesTitle': 'ਵੇਰੀਏਸ਼ਨ ਟੇਬਲ',
      'tableInfoTitle': 'ਟੇਬਲ ਦੀ ਜਾਣਕਾਰੀ',
      'tableRulesTitle': 'ਇਹ ਟੇਬਲ ਕਿਵੇਂ ਖੇਡੀ ਜਾਂਦੀ ਹੈ',
      'tableRulesKey': 'ਟੇਬਲ ਦੇ ਨਿਯਮ',
      'ruleBlindMoves':
          'ਤੁਸੀਂ {n} ਵਾਰ ਤੱਕ ਬਲਾਇੰਡ ਚਾਲ ਚੱਲ ਸਕਦੇ ਹੋ; ਉਸ ਤੋਂ ਬਾਅਦ ਤੁਹਾਡੇ ਪੱਤੇ ਤੁਹਾਡੇ ਲਈ ਖੁੱਲ੍ਹ ਜਾਂਦੇ ਹਨ।',
      'ruleRaiseOnce': 'ਆਪਣੀ ਵਾਰੀ ਤੇ: ਚਾਲ, ਜਾਂ ਇੱਕ ਵਾਰ ਦੁੱਗਣਾ ਰੇਜ਼।',
      'ruleRaiseFree':
          'ਆਪਣੀ ਵਾਰੀ ਤੇ: ਚਾਲ, ਜਾਂ ਜਿੰਨੇ ਚਿਪਸ ਹੋਣ ਓਨਾ ਦੁੱਗਣਾ ਕਰਦੇ ਜਾਓ।',
      'rulePotCapped':
          'ਪੌਟ {pot} ਹੁੰਦੇ ਹੀ ਸਾਰੇ ਹੱਥ ਦਿਖਾਏ ਜਾਂਦੇ ਹਨ ਅਤੇ ਸਭ ਤੋਂ ਵਧੀਆ ਹੱਥ ਜਿੱਤਦਾ ਹੈ।',
      'rulePotOpen': 'ਪੌਟ ਦੀ ਕੋਈ ਸੀਮਾ ਨਹੀਂ।',
      'ruleRoundsEnd':
          'ਸਾਰੇ ਰਾਊਂਡ ਪੂਰੇ ਹੋ ਜਾਣ ਤਾਂ ਸਾਰੇ ਹੱਥ ਦਿਖਾਏ ਜਾਂਦੇ ਹਨ ਅਤੇ ਸਭ ਤੋਂ ਵਧੀਆ ਹੱਥ ਜਿੱਤਦਾ ਹੈ।',
      'ruleShowTwo':
          'ਜਦੋਂ ਸਿਰਫ਼ ਦੋ ਖਿਡਾਰੀ ਬਚਣ, ਕੋਈ ਵੀ ਸ਼ੋਅ ਲਈ ਭੁਗਤਾਨ ਕਰ ਸਕਦਾ ਹੈ।',
      'ruleVariationPick':
          'ਪਹਿਲੀ ਚਾਲ ਵਾਲੇ ਖਿਡਾਰੀ ਕੋਲ 10 ਸਕਿੰਟ ਹੁੰਦੇ ਹਨ ਇਹ ਚੁਣਨ ਲਈ ਕਿ ਹੱਥ ਕਿਵੇਂ ਤੈਅ ਹੋਵੇਗਾ; ਨਹੀਂ ਤਾਂ ਮੁਫ਼ਲਿਸ।',
      'categoryLabel': 'ਖੇਡ',
      'playersLabel': 'ਖਿਡਾਰੀ',
      'turnTimeLabel': 'ਚਾਲ ਦਾ ਸਮਾਂ',
      'yourChipsLabel': 'ਤੁਹਾਡੇ ਚਿਪਸ',
      'canSitHere': 'ਤੁਸੀਂ ਇਸ ਟੇਬਲ ਤੇ ਬੈਠ ਸਕਦੇ ਹੋ।',
      'playersUpTo': '{n} ਤੱਕ',
      'secondsEach': '{n} ਸਕਿੰਟ',
      'variationRulesIntro':
          'ਪਹਿਲੀ ਚਾਲ ਵਾਲੇ ਖਿਡਾਰੀ ਕੋਲ ਇਹ ਚੁਣਨ ਲਈ 10 ਸਕਿੰਟ ਹੁੰਦੇ ਹਨ ਕਿ ਹੱਥ ਕਿਸ ਨਿਯਮ ਨਾਲ ਤੈਅ ਹੋਵੇਗਾ; ਨਾ ਚੁਣੇ ਤਾਂ ਮੁਫ਼ਲਿਸ ਖੇਡਿਆ ਜਾਂਦਾ ਹੈ। ਜੋਕਰ ਪੱਤਾ ਉਹੀ ਪੱਤਾ ਗਿਣਿਆ ਜਾਂਦਾ ਹੈ ਜਿਸ ਨਾਲ ਤੁਹਾਡਾ ਹੱਥ ਸਭ ਤੋਂ ਵਧੀਆ ਬਣੇ। ਦੂਜਿਆਂ ਦੇ ਚਿਪਸ ਲੁਕੇ ਰਹਿੰਦੇ ਹਨ ਅਤੇ ਪੌਟ ਦੀ ਕੋਈ ਸੀਮਾ ਨਹੀਂ।',
      'variationChooseTitle': 'ਵੇਰੀਏਸ਼ਨ ਚੁਣੋ',
      'variationSelectingBy': '{name} ਵੇਰੀਏਸ਼ਨ ਚੁਣ ਰਹੇ ਹਨ…',
      'variationChosen': 'ਵੇਰੀਏਸ਼ਨ: {variation}',
      'variationLeftChosen': '{name} ਟੇਬਲ ਛੱਡ ਗਏ — ਮੁਫ਼ਲਿਸ ਚੁਣਿਆ ਗਿਆ',
      'variationAutoChosen': 'ਸਮਾਂ ਖਤਮ — ਮੁਫ਼ਲਿਸ ਚੁਣਿਆ ਗਿਆ',
      'varMuflis': 'ਮੁਫ਼ਲਿਸ',
      'varAk47': 'AK47',
      'varJoker': 'ਜੋਕਰ',
      'varHukam': 'ਹੁਕਮ',
      'varLowestJoker': 'ਸਭ ਤੋਂ ਛੋਟਾ ਜੋਕਰ',
      'varHighestJoker': 'ਸਭ ਤੋਂ ਵੱਡਾ ਜੋਕਰ',
      'varFiveCard': '5-ਪੱਤੀ',
      'varMuflisNote': 'ਸਭ ਤੋਂ ਕਮਜ਼ੋਰ ਹੱਥ ਜਿੱਤਦਾ ਹੈ',
      'varAk47Note': 'A, K, 4 ਅਤੇ 7 ਜੋਕਰ ਹਨ',
      'varJokerNote': 'ਖੁੱਲ੍ਹੇ ਪੱਤੇ ਦਾ ਰੈਂਕ ਜੋਕਰ ਹੈ',
      'varHukamNote': 'ਖੁੱਲ੍ਹੇ ਪੱਤੇ ਦਾ ਰੰਗ ਜੋਕਰ ਹੈ',
      'varLowestJokerNote': 'ਤੁਹਾਡਾ ਸਭ ਤੋਂ ਛੋਟਾ ਪੱਤਾ ਜੋਕਰ ਹੈ',
      'varHighestJokerNote': 'ਤੁਹਾਡਾ ਸਭ ਤੋਂ ਵੱਡਾ ਪੱਤਾ ਜੋਕਰ ਹੈ',
      'varFiveCardNote': 'ਤੁਹਾਡੇ 5 ਪੱਤਿਆਂ ਵਿੱਚੋਂ ਸਭ ਤੋਂ ਵਧੀਆ 3',
      'wildCard': 'ਜੋਕਰ',
      'sideshowRunning': 'ਸਾਈਡਸ਼ੋ',
      'accept': 'ਮੰਨੋ',
      'decline': 'ਨਾਂਹ ਕਰੋ',
      'sideshowDeclined': 'ਤੁਹਾਡਾ ਸਾਈਡਸ਼ੋ ਨਾਂਹ ਕੀਤਾ ਗਿਆ',
      'sideshowTimedOut': 'ਕੋਈ ਜਵਾਬ ਨਹੀਂ — ਸਾਈਡਸ਼ੋ ਰੱਦ',
      'sideshowCancelled': 'ਸਾਈਡਸ਼ੋ ਰੱਦ ਹੋ ਗਿਆ',
      'sideshowYouLost': 'ਤੁਹਾਡੇ ਪੱਤੇ ਕਮਜ਼ੋਰ ਸਨ — ਤੁਸੀਂ ਪੈਕ ਹੋਏ',
      'sideshowYouWon': 'ਤੁਹਾਡੇ ਪੱਤੇ ਵਧੀਆ ਸਨ — ਉਹ ਪੈਕ ਹੋਏ',
      'force': 'ਫੋਰਸ',
      'forceSideshow': 'ਫੋਰਸ ਸਾਈਡਸ਼ੋ',
      'forceSideshowTitle': 'ਫੋਰਸ ਸਾਈਡਸ਼ੋ ਕਰਨਾ ਹੈ?',
      'forceSideshowBody': '{name} ਨਾਲ ਫੋਰਸ ਸਾਈਡਸ਼ੋ ਲਈ 1 ਹਥੌੜਾ ਖਰਚ ਕਰਨਾ ਹੈ?',
      'forceSideshowNote': 'ਉਹ ਨਾਂਹ ਨਹੀਂ ਕਰ ਸਕਦੇ, ਅਤੇ ਬਰਾਬਰੀ ’ਤੇ ਤੁਸੀਂ ਹਾਰੋਗੇ।',
      'noHammersTitle': 'ਕੋਈ ਹਥੌੜਾ ਨਹੀਂ ਬਚਿਆ',
      'noHammersBody':
          'ਫੋਰਸ ਸਾਈਡਸ਼ੋ ਲਈ 1 ਹਥੌੜਾ ਲੱਗਦਾ ਹੈ। ਸਟੋਰ ਤੋਂ ਹੋਰ ਲੈਣੇ ਹਨ?',
      'getHammers': 'ਹਥੌੜੇ ਲਓ',
      'noHammers': 'ਫੋਰਸ ਸਾਈਡਸ਼ੋ ਲਈ ਹਥੌੜਾ ਚਾਹੀਦਾ ਹੈ',
      'sideshowForcedByYou': 'ਤੁਸੀਂ {name} ਨਾਲ ਫੋਰਸ ਸਾਈਡਸ਼ੋ ਕੀਤਾ',
      'sideshowForcedOnYou': '{name} ਨੇ ਤੁਹਾਡੇ ਨਾਲ ਫੋਰਸ ਸਾਈਡਸ਼ੋ ਕੀਤਾ',
      'sideshowForcedOn': '{from} ਨੇ {to} ਨਾਲ ਫੋਰਸ ਸਾਈਡਸ਼ੋ ਕੀਤਾ',
      'missile': 'ਮਿਜ਼ਾਈਲ',
      'fireMissileTitle': 'ਮਿਜ਼ਾਈਲ ਚਲਾਉਣੀ ਹੈ?',
      'fireMissileBody':
          'ਹੱਥ ਵਿੱਚ ਬਾਕੀ ਸਾਰੇ ਖਿਡਾਰੀਆਂ ਦੇ ਪੱਤੇ ਖੁੱਲ੍ਹਣਗੇ ਅਤੇ ਸਭ ਤੋਂ ਵਧੀਆ ਹੱਥ ਪੌਟ ਜਿੱਤੇਗਾ। 1 ਮਿਜ਼ਾਈਲ ਲੱਗੇਗੀ।',
      'fireMissileNote': 'ਬਰਾਬਰੀ ’ਤੇ ਤੁਸੀਂ ਹਾਰੋਗੇ।',
      'fire': 'ਚਲਾਓ',
      'missileTooLate':
          'ਦੇਰ ਹੋ ਗਈ — ਮਿਜ਼ਾਈਲ ਨਹੀਂ ਚਲਾਈ ਗਈ। ਕੋਈ ਮਿਜ਼ਾਈਲ ਖਰਚ ਨਹੀਂ ਹੋਈ।',
      'noMissilesTitle': 'ਕੋਈ ਮਿਜ਼ਾਈਲ ਬਾਕੀ ਨਹੀਂ',
      'noMissilesBody':
          'ਮਿਜ਼ਾਈਲ ਚਲਾਉਣ ਲਈ 1 ਮਿਜ਼ਾਈਲ ਲੱਗਦੀ ਹੈ। ਸਟੋਰ ਵਿੱਚ ਹੀਰਿਆਂ ਨਾਲ ਹੋਰ ਲਓ?',
      'getMissiles': 'ਮਿਜ਼ਾਈਲਾਂ ਲਓ',
      'noMissiles': 'ਮਿਜ਼ਾਈਲ ਚਲਾਉਣ ਲਈ ਮਿਜ਼ਾਈਲ ਚਾਹੀਦੀ ਹੈ',
      'tooFewPlayers': 'ਇਸ ਲਈ ਹੱਥ ਵਿੱਚ ਘੱਟੋ-ਘੱਟ 3 ਖਿਡਾਰੀ ਹੋਣੇ ਚਾਹੀਦੇ ਹਨ',
      'missileNeedsShowChips': 'ਮਿਜ਼ਾਈਲ ਚਲਾਉਣ ਲਈ ਸ਼ੋ ਜਿੰਨੀਆਂ ਚਿਪਸ ਚਾਹੀਦੀਆਂ ਹਨ',
      'missileFiredByYou': 'ਤੁਸੀਂ ਮਿਜ਼ਾਈਲ ਚਲਾਈ',
      'missileFiredBy': '{name} ਨੇ ਮਿਜ਼ਾਈਲ ਚਲਾਈ',
      'storeTabMissiles': 'ਮਿਜ਼ਾਈਲਾਂ',
      'storeMissilesTitle': 'ਮਿਜ਼ਾਈਲ ਸਟੋਰ',
      'storeMissilesBlurb': 'ਹੀਰੇ ਬਦਲੋ: 15 ਹੀਰੇ = 1 ਮਿਜ਼ਾਈਲ।',
      'tradeMissilesTitle': 'ਹੀਰੇ ਬਦਲਣੇ ਹਨ?',
      'tradeMissilesBody':
          '{diamonds} ਹੀਰੇ ਦੇ ਕੇ {missiles} ਮਿਜ਼ਾਈਲਾਂ ਲੈਣੀਆਂ ਹਨ?',
      'tradeMissileBodyOne': '{diamonds} ਹੀਰੇ ਦੇ ਕੇ 1 ਮਿਜ਼ਾਈਲ ਲੈਣੀ ਹੈ?',
      'trade': 'ਬਦਲੋ',
      'notEnoughDiamondsTitle': 'ਕਾਫ਼ੀ ਹੀਰੇ ਨਹੀਂ',
      'notEnoughDiamondsBody':
          'ਇਸ ਸੌਦੇ ਲਈ {diamonds} ਹੀਰੇ ਚਾਹੀਦੇ ਹਨ। ਹੋਰ ਹੀਰੇ ਲਓ?',
      'getDiamonds': 'ਹੀਰੇ ਲਓ',
      'missilesAdded': '{n} ਮਿਜ਼ਾਈਲਾਂ ਤੁਹਾਡੇ ਵਾਲਿਟ ਵਿੱਚ ਜੁੜ ਗਈਆਂ',
      'missileAddedOne': '1 ਮਿਜ਼ਾਈਲ ਤੁਹਾਡੇ ਵਾਲਿਟ ਵਿੱਚ ਜੁੜ ਗਈ',
      'rewardMissileTradedOne':
          'ਮਿਜ਼ਾਈਲ ਤੁਹਾਡੇ ਵਾਲਿਟ ਵਿੱਚ ਹੈ। ਟੇਬਲ ’ਤੇ ਇਸਨੂੰ ਚਲਾਓ।',
      'walletSummaryOneMissile': '{diamonds} ਹੀਰੇ, {hammers} ਹਥੌੜੇ, 1 ਮਿਜ਼ਾਈਲ',
      'rewardMissilesTraded':
          'ਮਿਜ਼ਾਈਲਾਂ ਤੁਹਾਡੇ ਵਾਲਿਟ ਵਿੱਚ ਹਨ। ਟੇਬਲ ’ਤੇ ਮਿਜ਼ਾਈਲ ਚਲਾਓ।',
      'premiumPackages': 'ਪ੍ਰੀਮੀਅਮ ਪੈਕੇਜ',
      'posPremiumPackage': 'ਪ੍ਰੀਮੀਅਮ ਪੈਕੇਜ',
      'plusMissileOne': '+1 ਮਿਜ਼ਾਈਲ',
      'plusMissiles': '+{n} ਮਿਜ਼ਾਈਲਾਂ',
      'plusHammers': '+{n} ਹਥੌੜੇ',
      'plusHammerOne': '+{n} ਹਥੌੜਾ',
      'rewardPremiumPurchased':
          'ਤੁਹਾਡਾ ਪ੍ਰੀਮੀਅਮ ਪੈਕੇਜ ਤੁਹਾਡੇ ਵਾਲਿਟ ਵਿੱਚ ਹੈ। ਸ਼ੁਭਕਾਮਨਾਵਾਂ।',
      'premiumAdded':
          'ਪ੍ਰੀਮੀਅਮ ਪੈਕੇਜ ਜੁੜ ਗਿਆ: {chips} ਚਿੱਪਾਂ, {missiles} ਮਿਜ਼ਾਈਲਾਂ ਅਤੇ {hammers} ਹਥੌੜੇ',
      'premiumAddedOneMissile':
          'ਪ੍ਰੀਮੀਅਮ ਪੈਕੇਜ ਜੁੜ ਗਿਆ: {chips} ਚਿੱਪਾਂ, 1 ਮਿਜ਼ਾਈਲ ਅਤੇ {hammers} ਹਥੌੜੇ',
      'seeCards': 'ਪੱਤੇ ਵੇਖੋ',
      'blindMovesLeft': 'ਬਲਾਈਂਡ ਚਾਲਾਂ ਬਾਕੀ',
      'blindMovesLabel': 'ਬਲਾਈਂਡ ਚਾਲਾਂ ਬਾਕੀ',
      'lastBlindMove': 'ਆਖ਼ਰੀ ਬਲਾਈਂਡ ਚਾਲ',
      'inPot': 'ਪੌਟ ਵਿੱਚ',
      'waiting': 'ਉਡੀਕ',
      'offline': 'ਔਫ਼ਲਾਈਨ',
      'packed': 'ਪੈਕ',
      'autoPacked': 'ਲਗਾਤਾਰ ਚਾਲਾਂ ਖੁੰਝੀਆਂ',
      'autoPackedOne': 'ਚਾਲ ਖੁੰਝੀ',
      'lastWarning': 'ਆਖਰੀ ਚੇਤਾਵਨੀ',
      'missOneMore': 'ਇਹ ਚਾਲ ਖੁੰਝੀ ਤਾਂ ਤੁਸੀਂ ਟੇਬਲ ਛੱਡ ਦਿਓਗੇ।',
      'unlock': 'ਅਨਲਾਕ ਕਰੋ',
      'unlockTitle': 'ਇਹ ਤਸਵੀਰ ਅਨਲਾਕ ਕਰਨੀ ਹੈ?',
      'unlockBody': '{name} ਦੀ ਕੀਮਤ {cost} ਚਿਪਸ ਹੈ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣੀ ਹੈ?',
      'unlockBodyDiamond':
          '{name} ਦੀ ਕੀਮਤ {cost} ਹੀਰੇ ਹੈ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣੀ ਹੈ?',
      'pictureUnlocked': 'ਅਨਲਾਕ',
      'tapToChangePicture': 'ਤਸਵੀਰ ਬਦਲਣ ਲਈ ਟੈਪ ਕਰੋ',
      'rentForDays': '{days} ਦਿਨ',
      'daysLeft': '{days} ਦਿਨ ਬਾਕੀ',
      'hoursLeft': '{n} ਘੰਟੇ ਬਾਕੀ',
      'minutesLeft': '{n} ਮਿੰਟ ਬਾਕੀ',
      'unlockRentBody':
          '{name} ਦੀ ਕੀਮਤ {cost} ਚਿਪਸ ਹੈ ਅਤੇ ਇਹ {time} ਤੁਹਾਡੀ ਰਹੇਗੀ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣੀ ਹੈ?',
      'unlockRentBodyDiamond':
          '{name} ਦੀ ਕੀਮਤ {cost} ਹੀਰੇ ਹੈ ਅਤੇ ਇਹ {time} ਤੁਹਾਡੀ ਰਹੇਗੀ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣੀ ਹੈ?',
      'unlockBodyHammers':
          '{name} ਦੀ ਕੀਮਤ {cost} ਹਥੌੜੇ ਹੈ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣੀ ਹੈ?',
      'unlockBodyHammerOne':
          '{name} ਦੀ ਕੀਮਤ 1 ਹਥੌੜਾ ਹੈ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣੀ ਹੈ?',
      'unlockRentBodyHammers':
          '{name} ਦੀ ਕੀਮਤ {cost} ਹਥੌੜੇ ਹੈ ਅਤੇ ਇਹ {time} ਤੁਹਾਡੀ ਰਹੇਗੀ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣੀ ਹੈ?',
      'unlockRentBodyHammerOne':
          '{name} ਦੀ ਕੀਮਤ 1 ਹਥੌੜਾ ਹੈ ਅਤੇ ਇਹ {time} ਤੁਹਾਡੀ ਰਹੇਗੀ। ਹੁਣੇ ਅਨਲਾਕ ਕਰਕੇ ਲਗਾਉਣੀ ਹੈ?',
      'notEnoughHammersTitle': 'ਕਾਫ਼ੀ ਹਥੌੜੇ ਨਹੀਂ',
      'notEnoughHammersBody': '{name} ਦੀ ਕੀਮਤ {cost} ਹਥੌੜੇ ਹੈ। ਹੋਰ ਹਥੌੜੇ ਲਓ?',
      'notEnoughHammersBodyOne': '{name} ਦੀ ਕੀਮਤ 1 ਹਥੌੜਾ ਹੈ। ਹੋਰ ਹਥੌੜੇ ਲਓ?',
      'notEnoughDiamondsPictureBody':
          '{name} ਦੀ ਕੀਮਤ {cost} ਹੀਰੇ ਹੈ। ਹੋਰ ਹੀਰੇ ਲਓ?',
      'pictureChipsLobbyOnly':
          'ਚਿਪਸ ਵਾਲੀ ਤਸਵੀਰ ਸਿਰਫ਼ ਲਾਬੀ ਵਿੱਚ ਖਰੀਦੀ ਜਾ ਸਕਦੀ ਹੈ।',
      'pictureAll': 'ਸਾਰੇ',
      'picturePremium': 'ਪ੍ਰੀਮੀਅਮ',
      'priceLowToHigh': 'ਕੀਮਤ: ਘੱਟ ਤੋਂ ਵੱਧ',
      'priceHighToLow': 'ਕੀਮਤ: ਵੱਧ ਤੋਂ ਘੱਟ',
      'picturePremiumAnimated': 'ਪ੍ਰੀਮੀਅਮ (ਐਨੀਮੇਟਿਡ)',
      'pictureShelfEmpty': 'ਇੱਥੇ ਹਾਲੇ ਕੋਈ ਤਸਵੀਰ ਨਹੀਂ ਹੈ।',
      'pictureOwnedTitle': 'ਪਹਿਲਾਂ ਹੀ ਅਨਲਾਕ ਹੈ',
      'timeDay': '{n} ਦਿਨ',
      'timeDays': '{n} ਦਿਨ',
      'timeHour': '{n} ਘੰਟਾ',
      'timeHours': '{n} ਘੰਟੇ',
      'timeMinute': '{n} ਮਿੰਟ',
      'timeMinutes': '{n} ਮਿੰਟ',
      'timeLeft': '{time} ਬਾਕੀ',
      'pictureKeeps': 'ਹਮੇਸ਼ਾ ਲਈ ਤੁਹਾਡੀ',
      'rentalLapsed': 'ਕਿਰਾਏ ਦੀ ਮਿਆਦ ਖਤਮ ਹੋ ਗਈ',
      'rentalEnds': 'ਮਿਆਦ ਖਤਮ: {date}',
      'rentalEnded': 'ਖਤਮ ਹੋਈ: {date}',
      'wear': 'ਲਗਾਓ',
      'wearing': 'ਲੱਗੀ ਹੋਈ ਹੈ',
      'missedTurnsLabel': 'ਖੁੰਝੀਆਂ ਚਾਲਾਂ',
      'resumingTable': 'ਤੁਹਾਡੇ ਟੇਬਲ ਤੇ ਵਾਪਸ ਜਾ ਰਹੇ ਹਾਂ…',
      'welcomeBack': 'ਵਾਪਸੀ ਤੇ ਸਵਾਗਤ — ਤੁਸੀਂ ਆਪਣੇ ਟੇਬਲ ਤੇ ਵਾਪਸ ਹੋ।',
      'appVersion': 'ਐਪ ਵਰਜਨ',
      'tableLost': 'ਤੁਸੀਂ ਦੂਰ ਸੀ ਤਾਂ ਤੁਹਾਡੀ ਸੀਟ ਚਲੀ ਗਈ।',
      'notConnected': 'ਕਨੈਕਸ਼ਨ ਨਹੀਂ ਹੈ। ਇਹ ਨਹੀਂ ਭੇਜਿਆ ਗਿਆ।',
      'reconnecting': 'ਕਨੈਕਸ਼ਨ ਟੁੱਟ ਗਿਆ। ਮੁੜ ਜੁੜ ਰਹੇ ਹਾਂ…',
      'kickedNoChips': 'ਇਸ ਟੇਬਲ ਉੱਤੇ ਰਹਿਣ ਲਈ ਤੁਹਾਡੇ ਕੋਲ ਲੋੜੀਂਦੇ ਚਿਪਸ ਨਹੀਂ ਹਨ।',
      'kickedIdle': 'ਲਗਾਤਾਰ {n} ਚਾਲਾਂ ਖੁੰਝਣ ਕਾਰਨ ਤੁਸੀਂ ਟੇਬਲ ਛੱਡ ਦਿੱਤਾ।',
      'leaveStakeStays': 'ਤੁਹਾਡਾ ਦਾਅ ਪੌਟ ਵਿੱਚ ਹੀ ਰਹੇਗਾ',
      'winner': 'ਜੇਤੂ',
      'tableChat': 'ਟੇਬਲ ਚੈਟ',
      'saySomething': 'ਕੁਝ ਕਹੋ…',
      'tableMenu': 'ਟੇਬਲ ਮੀਨੂ',
      'quickMessagesTitle': 'ਝਟਪਟ ਸੁਨੇਹੇ',
      'quickMessagesTip': 'ਝਟਪਟ ਸੁਨੇਹਾ ਭੇਜੋ',
      'quickPlayBlind': 'ਕਿਰਪਾ ਕਰਕੇ ਬਲਾਈਂਡ ਖੇਡੋ।',
      'quickPlayFast': 'ਕਿਰਪਾ ਕਰਕੇ ਜਲਦੀ ਖੇਡੋ।',
      'quickHowToWin': 'ਇੰਝ ਜਿੱਤੀਦਾ ਹੈ।',
      'quickUnlucky': 'ਮੇਰੀ ਕਿਸਮਤ ਮਾੜੀ ਹੈ।',
      'quickYouGotLucky': 'ਤੁਹਾਡੀ ਕਿਸਮਤ ਚੰਗੀ ਸੀ।',
      'quickOops': 'ਓਹੋ! ਮੈਨੂੰ ਇਹ ਨਹੀਂ ਖੇਡਣਾ ਚਾਹੀਦਾ ਸੀ।',
      'quickTakeSideshow': 'ਕਿਰਪਾ ਕਰਕੇ ਸਾਈਡਸ਼ੋ ਕਰੋ।',
      'quickTakeShow': 'ਕਿਰਪਾ ਕਰਕੇ ਸ਼ੋ ਕਰੋ।',
      'quickSwitchTable': 'ਟੇਬਲ ਬਦਲੋ।',
      'quickHelpMe': 'ਕਿਰਪਾ ਕਰਕੇ ਮੇਰੀ ਮਦਦ ਕਰੋ।',
      'yourChips': 'ਤੁਹਾਡੇ ਚਿਪਸ',
      'maxPot': 'ਵੱਧ ਤੋਂ ਵੱਧ ਪੌਟ',
      'nightMode': 'ਰਾਤ ਮੋਡ',
      'dayMode': 'ਦਿਨ ਮੋਡ',
      'appearance': 'ਦਿੱਖ',
      'themeSystem': 'ਸਿਸਟਮ',
      'themeDark': 'ਡਾਰਕ',
      'themeLight': 'ਲਾਈਟ',
      'waitingForPlayers': 'ਖਿਡਾਰੀਆਂ ਦੀ ਉਡੀਕ',
      'startingGame': 'ਖੇਡ ਸ਼ੁਰੂ ਹੋ ਰਹੀ ਹੈ…',
      'buyChipsToStay': 'ਸੀਟ ਰੱਖਣ ਲਈ {seconds} ਸਕਿੰਟ ਵਿੱਚ ਚਿਪਸ ਖਰੀਦੋ',
      'youAreWinner': 'ਤੁਸੀਂ ਜਿੱਤ ਗਏ',
      'isTheWinner': 'ਜਿੱਤ ਗਏ',
      'leaveTable': 'ਟੇਬਲ ਛੱਡੋ',
      'leaveTableQ': 'ਇਹ ਟੇਬਲ ਛੱਡਣਾ ਹੈ?',
      'leaveMidHand':
          'ਤੁਸੀਂ ਇੱਕ ਹੱਥ ਵਿੱਚ ਹੋ। ਛੱਡਣ ਨਾਲ ਪੱਤੇ ਪੈਕ ਹੋ ਜਾਣਗੇ ਅਤੇ ਤੁਹਾਡਾ ਦਾਅ ਪੌਟ ਵਿੱਚ ਹੀ ਰਹੇਗਾ।',
      'leaveAnytime': 'ਤੁਸੀਂ ਤੁਰੰਤ ਕਿਸੇ ਹੋਰ ਟੇਬਲ ਉੱਤੇ ਜੁੜ ਸਕਦੇ ਹੋ।',
      'stay': 'ਰੁਕੋ',
      'leave': 'ਛੱਡੋ',
      'switchTable': 'ਟੇਬਲ ਬਦਲੋ',
      'switchTableQ': 'ਟੇਬਲ ਬਦਲਣਾ ਹੈ?',
      'switchMidHand':
          'ਤੁਸੀਂ ਇੱਕ ਹੱਥ ਵਿੱਚ ਹੋ। ਹਟਣ ਨਾਲ ਪੱਤੇ ਪੈਕ ਹੋ ਜਾਣਗੇ ਅਤੇ ਤੁਹਾਡਾ ਦਾਅ ਪੌਟ ਵਿੱਚ ਹੀ ਰਹੇਗਾ।',
      'switchIdle':
          'ਤੁਹਾਨੂੰ ਉਸੇ ਕਿਸਮ ਦੇ ਹੋਰ ਟੇਬਲ ਉੱਤੇ ਬਿਠਾਇਆ ਜਾਵੇਗਾ। ਜੇ ਕਿਤੇ ਥਾਂ ਨਾ ਹੋਈ, ਤਾਂ ਇਹੀ ਟੇਬਲ ਰਹੇਗਾ।',
      'switchAction': 'ਬਦਲੋ',
      'quitGameQ': 'ਗੇਮ ਬੰਦ ਕਰਨੀ ਹੈ?',
      'quitGameBody': 'ਤੁਸੀਂ ਕਦੇ ਵੀ ਵਾਪਸ ਆ ਸਕਦੇ ਹੋ — ਤੁਹਾਡੇ ਚਿਪਸ ਸੁਰੱਖਿਅਤ ਹਨ।',
      'quit': 'ਬੰਦ ਕਰੋ',
      'cancel': 'ਰੱਦ ਕਰੋ',
      'consentTitle': 'ਖੇਡਣ ਤੋਂ ਪਹਿਲਾਂ',
      'consentBody':
          'ਮੈਂ ਪੁਸ਼ਟੀ ਕਰਦਾ/ਕਰਦੀ ਹਾਂ ਕਿ ਇਹ ਗੇਮ ਖੇਡ ਕੇ ਮੈਨੂੰ ਕੋਈ ਪੈਸਾ ਜਾਂ ਹੋਰ ਲਾਭ ਜਿੱਤਣ ਦੀ ਕੋਈ ਉਮੀਦ ਨਹੀਂ ਹੈ।',
      'consentNote':
          'ਇਹ ਗੇਮ ਸਿਰਫ਼ ਮਨੋਰੰਜਨ ਲਈ ਹੈ। ਚਿਪਸ ਦੀ ਕੋਈ ਨਕਦ ਕੀਮਤ ਨਹੀਂ ਹੈ ਅਤੇ ਇਹਨਾਂ ਨੂੰ ਪੈਸੇ ਜਾਂ ਕਿਸੇ ਹੋਰ ਚੀਜ਼ ਨਾਲ ਬਦਲਿਆ ਨਹੀਂ ਜਾ ਸਕਦਾ।',
      'consentAccept': 'ਪੁਸ਼ਟੀ ਕਰੋ',
      'joinAnother': 'ਤੁਸੀਂ ਤੁਰੰਤ ਕਿਸੇ ਹੋਰ ਟੇਬਲ ਉੱਤੇ ਜੁੜ ਸਕਦੇ ਹੋ',
      'noOtherTable':
          'ਇਸ ਦਾਅ ਉੱਤੇ ਹੁਣ ਕਿਸੇ ਹੋਰ {category} ਟੇਬਲ ਉੱਤੇ ਸੀਟ ਖਾਲੀ ਨਹੀਂ ਹੈ',
      'rules': 'ਨਿਯਮ',
      'rulesTitle': 'ਪੱਤਿਆਂ ਦੀ ਰੈਂਕਿੰਗ',
      'rulesBeats':
          'ਉੱਪਰ ਵਾਲਾ ਸਭ ਤੋਂ ਤਕੜਾ। ਹਰ ਹੱਥ ਹੇਠਲੇ ਸਾਰਿਆਂ ਨੂੰ ਹਰਾਉਂਦਾ ਹੈ।',
      'rankTrail': 'ਟ੍ਰੇਲ',
      'rankTrailNote': 'ਇੱਕੋ ਰੈਂਕ ਦੇ ਤਿੰਨ ਪੱਤੇ',
      'rankPureSeq': 'ਪਿਓਰ ਸੀਕਵੈਂਸ',
      'rankPureSeqNote': 'ਲਗਾਤਾਰ ਤਿੰਨ, ਇੱਕੋ ਰੰਗ ਦੇ',
      'rankSeq': 'ਸੀਕਵੈਂਸ',
      'rankSeqNote': 'ਲਗਾਤਾਰ ਤਿੰਨ, ਕਿਸੇ ਵੀ ਰੰਗ ਦੇ',
      'rankColor': 'ਕਲਰ',
      'rankColorNote': 'ਇੱਕੋ ਰੰਗ ਦੇ ਤਿੰਨ, ਲਗਾਤਾਰ ਨਹੀਂ',
      'rankPair': 'ਪੇਅਰ',
      'rankPairNote': 'ਇੱਕੋ ਰੈਂਕ ਦੇ ਦੋ ਪੱਤੇ',
      'rankHigh': 'ਹਾਈ ਕਾਰਡ',
      'rankHighNote': 'ਕੁਝ ਨਹੀਂ ਬਣਿਆ; ਸਭ ਤੋਂ ਵੱਡਾ ਪੱਤਾ ਜਿੱਤਦਾ ਹੈ',
      'runOrder': 'ਸੀਕਵੈਂਸ ਦਾ ਕ੍ਰਮ',
      'runOrderNote': 'A-K-Q ਸਭ ਤੋਂ ਉੱਚਾ, ਫਿਰ A-2-3, ਫਿਰ K-Q-J ਤੋਂ 4-3-2 ਤੱਕ।',
      'close': 'ਬੰਦ ਕਰੋ',
      'changeName': 'ਨਾਮ ਬਦਲੋ',
      'save': 'ਸੰਭਾਲੋ',
      'nameSaved': 'ਨਾਮ ਬਦਲ ਗਿਆ।',
      'cappedTitle': 'ਇਹ ਟੇਬਲ ਤੁਹਾਡੇ ਲਈ ਬੰਦ ਹੈ',
      'cappedBody':
          '{cap} ਤੋਂ ਵੱਧ ਚਿਪਸ ਰੱਖਣ ਵਾਲੇ ਖਿਡਾਰੀ ਇਸ ਟੇਬਲ ਉੱਤੇ ਨਹੀਂ ਬੈਠ ਸਕਦੇ।',
      'lockedTitle': 'ਇਹ ਟੇਬਲ ਹਾਲੇ ਬੰਦ ਹੈ',
      'lockedBody': 'ਇਸ ਟੇਬਲ ਉੱਤੇ ਬੈਠਣ ਲਈ {min} ਚਿਪਸ ਚਾਹੀਦੇ ਹਨ।',
      'entryLabel': 'ਦਾਖ਼ਲਾ',
      'entryOpen': 'ਸਾਰਿਆਂ ਲਈ ਖੁੱਲ੍ਹਾ',
      'entryUpTo': '{cap} ਤੱਕ',
      'entryFrom': '{min} ਜਾਂ ਵੱਧ',
      'useSocialPicture': 'ਮੇਰੀ Google ਜਾਂ Facebook ਤਸਵੀਰ ਵਰਤੋ',
      'guestNoSocial':
          'ਆਪਣੀ ਤਸਵੀਰ ਵਰਤਣ ਲਈ Google ਜਾਂ Facebook ਨਾਲ ਸਾਈਨ ਇਨ ਕਰੋ।',

      // --- the poker family
      'poker': 'ਪੋਕਰ',
      'pokerTableNote': 'ਹੋਲਡਮ, ਓਮਾਹਾ, 5-ਕਾਰਡ ਡਰਾਅ ਅਤੇ 3-ਕਾਰਡ ਪੋਕਰ',
      'pokerTexasHoldem': 'ਟੈਕਸਸ ਹੋਲਡਮ',
      'pokerOmaha': 'ਓਮਾਹਾ',
      'pokerFiveCardDraw': '5-ਕਾਰਡ ਡਰਾਅ',
      'pokerThreeCardPoker': '3-ਕਾਰਡ ਪੋਕਰ',
      'pokerTexasHoldemNote': 'ਹਰੇਕ ਨੂੰ ਦੋ ਪੱਤੇ, ਬੋਰਡ ਉੱਤੇ ਪੰਜ',
      'pokerOmahaNote': 'ਹਰੇਕ ਨੂੰ ਚਾਰ ਪੱਤੇ, ਉਨ੍ਹਾਂ ਵਿੱਚੋਂ ਠੀਕ ਦੋ ਖੇਡੋ',
      'pokerFiveCardDrawNote': 'ਹਰੇਕ ਨੂੰ ਪੰਜ ਪੱਤੇ, ਜੋ ਨਹੀਂ ਚਾਹੀਦੇ ਉਹ ਬਦਲੋ',
      'pokerThreeCardPokerNote': 'ਹਰੇਕ ਨੂੰ ਤਿੰਨ ਪੱਤੇ, ਡੀਲਰ ਦੇ ਖ਼ਿਲਾਫ਼',
      'blindsLabel': 'ਬਲਾਈਂਡਸ',
      'anteLabel': 'ਐਂਟੀ',
      'buyInLabel': 'ਬਾਇ-ਇਨ',
      'holeCardsLabel': 'ਹਰੇਕ ਨੂੰ ਪੱਤੇ',
      'maxDiscardsLabel': 'ਵੱਧ ਤੋਂ ਵੱਧ ਬਦਲੋ',
      'buyInFrom': '{min} ਤੋਂ',
      'fold': 'ਫ਼ੋਲਡ',
      'check': 'ਚੈੱਕ',
      'call': 'ਕਾਲ',
      'bet': 'ਬੈੱਟ',
      'raise': 'ਰੇਜ਼',
      'allIn': 'ਆਲ-ਇਨ',
      'play': 'ਪਲੇ',
      'draw': 'ਡਰਾਅ',
      'standPat': 'ਪੱਤੇ ਰੱਖੋ',
      'exchangeUpTo': 'ਬਦਲਣ ਲਈ {n} ਤੱਕ ਪੱਤੇ ਚੁਣੋ',
      'playOrFold': 'ਪਲੇ ਜਾਂ ਫ਼ੋਲਡ?',
      'dealerLabel': 'ਡੀਲਰ',
      'dealerQualifies': 'ਡੀਲਰ ਕੁਆਲੀਫ਼ਾਈ',
      'dealerNotQualified': 'ਡੀਲਰ ਕੁਆਲੀਫ਼ਾਈ ਨਹੀਂ',
      'youWon': 'ਤੁਸੀਂ {amount} ਜਿੱਤੇ',
      'youLost': 'ਤੁਸੀਂ ਹਾਰੇ',
      'outcomeWin': 'ਜਿੱਤ',
      'outcomeLose': 'ਹਾਰ',
      'push': 'ਬਰਾਬਰ',
      'potLabel': 'ਪੌਟ',
      'sidePotLabel': 'ਸਾਈਡ ਪੌਟ',
      'boardLabel': 'ਬੋਰਡ',
      'streetPreflop': 'ਪ੍ਰੀ-ਫ਼ਲਾਪ',
      'streetFlop': 'ਫ਼ਲਾਪ',
      'streetTurn': 'ਟਰਨ',
      'streetRiver': 'ਰਿਵਰ',
      'streetPredraw': 'ਡਰਾਅ ਤੋਂ ਪਹਿਲਾਂ',
      'streetDraw': 'ਡਰਾਅ',
      'streetPostdraw': 'ਡਰਾਅ ਤੋਂ ਬਾਅਦ',
      'streetDecision': 'ਫ਼ੈਸਲਾ',
      'streetShowdown': 'ਸ਼ੋਡਾਊਨ',
      'pokerTimedOut': 'ਤੁਹਾਡਾ ਸਮਾਂ ਖ਼ਤਮ ਹੋ ਗਿਆ ਅਤੇ ਤੁਹਾਡਾ ਹੱਥ ਫ਼ੋਲਡ ਹੋ ਗਿਆ',
      'pokerRulesTitle': 'ਪੋਕਰ ਟੇਬਲ',
      'pokerRulesIntro':
          'ਚਾਰ ਪੋਕਰ ਖੇਡਾਂ, ਸਾਰੀਆਂ ਇੱਕੋ ਪੰਜ-ਪੱਤੀ ਰੈਂਕਿੰਗ ਨਾਲ ਅੰਕੀਆਂ ਜਾਂਦੀਆਂ ਹਨ। '
          'ਹੱਥ ਉਹ ਸਭ ਤੋਂ ਵਧੀਆ ਪੰਜ ਪੱਤੇ ਹਨ ਜੋ ਤੁਸੀਂ ਬਣਾ ਸਕੋ।',
      'pokerRankRoyalFlush': 'ਰਾਇਲ ਫ਼ਲੱਸ਼',
      'pokerRankStraightFlush': 'ਸਟ੍ਰੇਟ ਫ਼ਲੱਸ਼',
      'pokerRankFourOfAKind': 'ਫ਼ੋਰ ਆਫ਼ ਏ ਕਾਈਂਡ',
      'pokerRankFullHouse': 'ਫ਼ੁੱਲ ਹਾਊਸ',
      'pokerRankFlush': 'ਫ਼ਲੱਸ਼',
      'pokerRankStraight': 'ਸਟ੍ਰੇਟ',
      'pokerRankThreeOfAKind': 'ਥ੍ਰੀ ਆਫ਼ ਏ ਕਾਈਂਡ',
      'pokerRankTwoPair': 'ਟੂ ਪੇਅਰ',
      'pokerRankPair': 'ਪੇਅਰ',
      'pokerRankHighCard': 'ਹਾਈ ਕਾਰਡ',
      'pokerThreeCardRanking':
          '3-ਕਾਰਡ ਪੋਕਰ ਵਿੱਚ ਸਟ੍ਰੇਟ ਫ਼ਲੱਸ਼ ਨੂੰ ਹਰਾਉਂਦਾ ਹੈ, ਅਤੇ ਥ੍ਰੀ ਆਫ਼ ਏ ਕਾਈਂਡ '
          'ਦੋਹਾਂ ਨੂੰ।',
      'rulePokerBlinds': 'ਹਰ ਹੱਥ {small} ਅਤੇ {big} ਦੇ ਬਲਾਈਂਡਸ ਨਾਲ ਸ਼ੁਰੂ ਹੁੰਦਾ ਹੈ',
      'rulePokerAnte': 'ਵੰਡਣ ਤੋਂ ਪਹਿਲਾਂ ਹਰ ਕੋਈ {ante} ਦੀ ਐਂਟੀ ਲਾਉਂਦਾ ਹੈ',
      'rulePokerBuyIn': 'ਘੱਟੋ-ਘੱਟ {min} ਲੈ ਕੇ ਬੈਠੋ',
      'rulePokerHoleCards': 'ਹਰ ਖਿਡਾਰੀ ਨੂੰ {n} ਪੱਤੇ ਵੰਡੇ ਜਾਂਦੇ ਹਨ',
      'rulePokerHoldemWin':
          'ਆਪਣੇ ਦੋ ਪੱਤਿਆਂ ਅਤੇ ਬੋਰਡ ਦੇ ਪੰਜ ਵਿੱਚੋਂ ਆਪਣੇ ਸਭ ਤੋਂ ਵਧੀਆ ਪੰਜ ਬਣਾਓ',
      'rulePokerOmahaWin':
          'ਤੁਹਾਡੇ ਚਾਰ ਵਿੱਚੋਂ ਠੀਕ ਦੋ ਪੱਤੇ ਅਤੇ ਬੋਰਡ ਦੇ ਤਿੰਨ ਨਾਲ ਹੱਥ ਬਣਦਾ ਹੈ',
      'rulePokerDrawWin':
          'ਬੈੱਟ ਕਰੋ, ਇੱਕ ਵਾਰ {n} ਤੱਕ ਪੱਤੇ ਬਦਲੋ, ਫਿਰ ਦੁਬਾਰਾ ਬੈੱਟ ਕਰੋ',
      'rulePokerThreeCardWin':
          'ਐਂਟੀ ਜਿੰਨਾ ਪਲੇ ਕਰੋ ਜਾਂ ਫ਼ੋਲਡ; ਤੁਹਾਡੇ ਤਿੰਨ ਪੱਤੇ ਡੀਲਰ ਨਾਲ ਮਿਲਾਏ ਜਾਂਦੇ ਹਨ',
      'rulePokerDealerQualifies':
          'ਡੀਲਰ ਨੂੰ ਖੇਡਣ ਲਈ ਕੁਈਨ-ਹਾਈ ਚਾਹੀਦਾ ਹੈ; ਨਾ ਹੋਵੇ ਤਾਂ ਤੁਹਾਡਾ ਪਲੇ ਬੈੱਟ ਵਾਪਸ '
          'ਅਤੇ ਐਂਟੀ ਜਿੱਤਦੀ ਹੈ',
      'rulePokerBestHandWins':
          'ਸ਼ੋਡਾਊਨ ਵਿੱਚ ਸਭ ਤੋਂ ਵਧੀਆ ਹੱਥ ਪੌਟ ਲੈਂਦਾ ਹੈ; ਇਕੱਲਾ ਬਚਿਆ ਖਿਡਾਰੀ ਬਿਨਾਂ '
          'ਸ਼ੋਡਾਊਨ ਦੇ',
      'refuseNotYourTurn': 'ਤੁਹਾਡੀ ਵਾਰੀ ਨਹੀਂ ਹੈ',
      'refuseInvalidAction': 'ਇਹ ਚਾਲ ਹੁਣ ਨਹੀਂ ਚੱਲ ਸਕਦੀ',
      'refuseInvalidAmount': 'ਇਹ ਰਕਮ ਮਨਜ਼ੂਰ ਨਹੀਂ ਹੈ',
      'refuseInvalidDiscard': 'ਇਹ ਪੱਤੇ ਬਦਲੇ ਨਹੀਂ ਜਾ ਸਕਦੇ',
      'refuseInsufficientChips': 'ਇਸ ਲਈ ਚਿਪਸ ਕਾਫ਼ੀ ਨਹੀਂ ਹਨ',
      'refuseNoHand': 'ਹੁਣ ਕੋਈ ਹੱਥ ਨਹੀਂ ਚੱਲ ਰਿਹਾ',
      'refuseNotInHand': 'ਤੁਸੀਂ ਇਸ ਹੱਥ ਵਿੱਚ ਨਹੀਂ ਹੋ',
      'refuseWrongGame': 'ਇਹ ਚਾਲ ਕਿਸੇ ਹੋਰ ਖੇਡ ਦੀ ਹੈ',
      'refuseDuplicateAction': 'ਇਹ ਚਾਲ ਪਹਿਲਾਂ ਹੀ ਭੇਜੀ ਜਾ ਚੁੱਕੀ ਹੈ',
      'refuseUnknownAction': 'ਇਹ ਚਾਲ ਟੇਬਲ ਨਹੀਂ ਜਾਣਦਾ',
    },
  };
}
